# GPUC 从用户态原型到内核存储路径的接入设计

> 状态：设计方案，不代表当前仓库已经实现 DM/Btrfs/ZFS 内核模块。
> 当前可运行实现仍是 `LD_PRELOAD + 离线 Daemon + 只读压缩对象`。

## 1. 为什么不能直接把当前实现称为 block/fs 层方案

当前 Hook 只拦截加载了动态库且经过 libc 的进程；静态链接、直接 syscall、内核
客户端和应用自行提交的 io_uring 不在透明范围内。COMPRESSED/INLINE 为只读归档
对象，写入需要先生成 RAW，再由 Daemon 原子转换。因此它已经验证 GPU 批处理、
内存池、CPU fallback、格式校验和资源卸载机制，但没有完成赛题所述“通过 dm 在
block 层作压缩”或“通过 Btrfs/ZFS 在文件系统层作压缩”。

## 2. 推荐演进路线

| 阶段 | 接入点 | 用途 | 关键限制 |
|---|---|---|---|
| 当前 | LD_PRELOAD + Daemon | 快速验证 GPU offload、格式和资源模型 | 仅指定用户进程，只读归档 |
| 第一阶段 | Btrfs encoded I/O 辅助服务 | 利用文件系统已有 extent、校验和与 COW | 仍需解决内核与用户态加速器通信 |
| 第二阶段 | DM 压缩 target | 向 ext4/XFS 等上层提供块设备 | 必须自建逻辑到物理映射和事务元数据 |
| 可选 | OpenZFS accelerator interface | 在 ZFS record 压缩点替换计算后端 | 依赖 OpenZFS 版本与接入接口稳定性 |

不建议在决赛前把未经故障注入和掉电测试的实验性 DM target 描述为已完成。当前更
可信的交付是：运行原型、Btrfs 基线、完整接口设计和可复现实验。

## 3. DM target 设计

### 3.1 设备布局

- data device：保存变长压缩 payload，以 4 KiB extent 分配；
- metadata device：持久化 `logical_chunk -> physical_extent, stored_len,
  original_len, algorithm, checksum, generation`；
- journal/superblock：双 superblock + generation，元数据使用 copy-on-write
  B-tree 或 device-mapper persistent-data transaction manager；
- chunk：建议从 128 KiB 起步，与当前 GPUC/nvCOMP LZ4 和 Btrfs 压缩单元一致。

块层变长压缩不能把压缩块直接放回原逻辑扇区：否则任何一次压缩率变化都会覆盖
相邻数据。因此 metadata/data 分离不是优化项，而是正确性前提。

### 3.2 写路径

1. `map()` 将 bio 按 chunk 切分；未覆盖完整 chunk 时先读取旧版本并合并；
2. 将请求放入有界 per-NUMA submission queue，达到 batch、超时或 flush 屏障时
   提交；
3. pinned staging pool 聚合 H2D，GPU LZ4 批量压缩；
4. 若 GPU 不可用、队列超时、输入过小或压缩不省空间，切到 CPU LZ4/RAW；
5. 分配新 data extent 并写 payload，等待数据落盘；
6. COW 更新 mapping/checksum，提交 journal，再回收旧 extent；
7. FUA/flush 必须等待此前数据和 metadata commit 完成后才向上层完成。

任何队列满都必须产生背压或 CPU fallback，不能无界积压 bio。GPU callback 只负责
完成状态转换，不能在原子上下文执行可能睡眠的 CUDA 调用。

### 3.3 读路径

1. metadata lookup 找到 payload；RAW 直接映射到底层设备；
2. 合并相邻压缩 chunk 的底层读，校验长度、范围和 checksum；
3. 进入批量解压队列；为 4 KiB 随机读采用请求覆盖块，不固定预读 4 MiB；
4. GPU 完成后校验输出并拷贝到 bio pages；
5. GPU 失败时，标准 LZ4 数据可由 CPU 解压；校验失败返回 `-EIO`，不得静默输出。

### 3.4 崩溃一致性

采用“data first, metadata second”：新 payload 完整落盘前，旧 mapping 始终有效；
metadata transaction 提交后才允许释放旧 extent。恢复时选择 checksum 正确且
generation 最大的 superblock，重放已提交 journal，扫描并回收未被 mapping 引用
的孤儿 extent。discard 只能发生在元数据提交之后。

### 3.5 并发与内存

- 同一 logical chunk 以 hashed lock 或 range lock 串行化 read-modify-write；
- 不相交 chunk 可并行；元数据提交可 group commit；
- staging/device buffer 全部预分配并设置硬上限；
- 每个请求记录排队、H2D、kernel、D2H、metadata 和 block I/O 时间；
- NUMA 机器上将 submission queue、CPU fallback、pinned memory 和 GPU PCIe
  locality 对齐，并公开跨 NUMA 路径结果。

## 4. Btrfs 接入设计

Btrfs 已提供 extent 级透明压缩、COW、checksum、压缩失败 RAW 回退和 128 KiB
压缩单元。更合理的 GPU 接入点是压缩/解压 workqueue 的算法后端，而不是再实现一
套块映射：

- 写：delalloc extent -> 内容启发式 -> GPU batch -> compressed bio；
- 读：compressed extent read -> checksum -> GPU batch decompress -> folio；
- 小批、内存回收、GPU reset、挂起/恢复期间必须使用内核 CPU LZ4/Zstd fallback；
- 磁盘格式必须保持标准 LZ4/Zstd，不能写仅 GPUC 能识别的私有编码；
- reclaim、writeback 和 filesystem freeze 路径不能依赖可能永久阻塞的用户进程。

若使用用户态 GPU 服务，应采用有界共享队列和预注册内存，并保证服务死亡后可取消
请求和回退；这比纯内核调用 CUDA 更现实，但必须证明不会死锁 writeback/reclaim。

## 5. OpenZFS 接入设计

ZFS 在 record 层天然知道逻辑内容边界，并已有 checksum、事务组和 RAW fallback。
接入点应位于 ARC buffer 与压缩算法之间，保持标准 LZ4/Zstd on-disk 格式。提交给
加速器的任务携带 record identity、generation、deadline 和 checksum；事务组同步
时等待已接受任务完成或转 CPU，不能让 GPU 故障阻止 txg sync。由于本仓库没有
OpenZFS 构建和 zpool 环境，该路线只作为设计，不计入已验证功能。

## 6. 验收门槛

1. ext4/XFS（DM）或原生 Btrfs 上可写、卸载、重挂载并保持 fsck/checksum 正确；
2. 4 KiB–1 MiB、顺序/随机、读写混合、flush/FUA/discard 全覆盖；
3. GPU 不可见、超时、进程死亡、OOM、元数据 ENOSPC、掉电注入后可恢复；
4. CPU/GPU 使用相同算法、数据、吞吐和存储设备，至少五轮并报告 95% CI；
5. 除吞吐外报告主机 CPU、DRAM、RSS/pinned memory、尾延迟和整机能耗；
6. 任何结果明确区分用户态原型、Btrfs 基线和真正内核接入，禁止混称。

## 7. 设计依据

- Linux Device Mapper 文档：
  <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/index.html>
- Device Mapper persistent-data 的 COW transaction/commit 语义：
  <https://www.kernel.org/doc/html/latest/admin-guide/device-mapper/persistent-data.html>
- Btrfs 透明压缩、128 KiB chunk、compress-force 和 RAW 回退：
  <https://btrfs.readthedocs.io/en/latest/Compression.html>
- OpenZFS record 压缩和算法属性：
  <https://openzfs.github.io/openzfs-docs/Basic%20Concepts/Data%20Storage/Compression.html>
- nvCOMP batched API（多个小输入应合并为一次批量调用）：
  <https://docs.nvidia.com/cuda/nvcomp/samples/lowlevel_c_quickstart.html>

以上链接核对日期：2026-07-30。
