# GPUC 研发过程中的问题与解决方法

本文档系统记录 GPUC 项目在研发过程中遇到的关键技术问题、根因分析、解决方案及验证结果，体现项目的迭代过程与工程思考。

---

## 1. jobs=32 高并发下 GPUC 读带宽骤降

### 现象

多线程并发读取 512 MB 已压缩文件时：
- jobs=16：GPU Compressed 与 Baseline 基本持平（~3797 MB/s）；
- jobs=32：Baseline 继续扩展至 ~18-19 GB/s（page cache 命中），但 GPUC 骤降至 **~267 MB/s**，仅为 jobs=16 时的 7%。

### 根因分析

1. **单/少 Stream 竞争**：早期 `gpu_compress.cu` 仅创建 2 个 CUDA Stream，32 个线程阻塞等待 `cudaStreamSynchronize()`；
2. **batch 无法合并**：每次 `read()` 仅处理 1 个 128 KB block，大量线程各自提交小 batch，kernel 启动开销无法摊销；
3. **I/O 与 GPU 计算未重叠**：同步 `pread` + 同步 kernel 执行，线程大量空闲等待。

### 解决方案

组合使用三项优化：

1. **扩展至 16 个 CUDA Stream**：
   - 每线程 TLS 独占 2 个 stream（双缓冲 pipe 0/1）；
   - `get_stream_id()` 按线程 ID 分配，减少竞争。

2. **io_uring 异步批量 I/O**：
   - ring 深度从 32 提升至 128；
   - 批量提交最多 16 个 block 的 `pread`，减少 syscall 阻塞。

3. **激进自适应 Read-Ahead**：
   - 顺序访问检测；
   - `seq_count≥1` 时启动 4 block 预读，`seq_count≥4` 时扩展至 MAX_BATCH_BLOCKS（16）；
   - 随机访问或 `lseek` 时立即重置窗口。

### 验证

使用 `tests/benchmark_high_concurrency.sh`，`direct=1` 条件下：

| 数据 | bs | Baseline | GPUC | 比例 |
|-----|-----|---------|------|------|
| zero | 128k | 4900.2 MB/s | 4889.1 MB/s | **99.8%** |
| zero | 1M | 414.3 MB/s | 412.9 MB/s | **99.7%** |
| rand | 128k | 396.6 MB/s | 395.8 MB/s | **99.8%** |
| rand | 1M | 435.2 MB/s | 425.2 MB/s | **97.7%** |

### 关键结论

单一“多 Stream”优化在早期测试中未见效（270→270 MB/s），因为每次 read 仍只处理 1 block。必须结合 **io_uring 批量 I/O** 与 **激进 read-ahead**，让多个 block 形成 batch，才能真正摊销 kernel 启动开销。

---

## 2. 逐块 cudaMalloc/cudaFree 成为性能瓶颈

### 现象

早期 Hook 每解压一个 block 需执行 3 次 `cudaMalloc`/`cudaFree` 及 1 次 kernel 启动。512 MB 文件（4096 blocks）累计产生 12288 次设备内存分配/释放。

### 根因分析

CUDA driver 的内存池优化在间隔调用时效果失效，单次 `cudaMalloc` 耗时约 0.7 ms，大量累计后成为显著延迟。

### 解决方案

在 `sglz_init()` 中预分配最大 batch 所需的 device 内存池：
- `g_d_batch_in`：输入缓冲区（16 × 32 × 4352 B）；
- `g_d_batch_out`：输出缓冲区（16 × 128 KB）；
- `g_d_batch_out_lens`：输出长度数组；
- 16 个 stream 各自独立内存池。

`sglz_decompress_batch()` / `sglz_compress_batch()` 直接复用预分配内存，运行时不再调用 `cudaMalloc`/`cudaFree`。

### 验证

- 压缩 512 MB zero 文件耗时从数秒降至 **2.137 s**，吞吐 **234 MB/s**；
- 解压路径零分配延迟，Ablation Study 中该优化与 batch 化合计贡献约 25% 带宽提升。

---

## 3. 紧凑格式到 slot 布局的 CPU 侧 memcpy

### 现象

磁盘采用紧凑格式（只写实际压缩长度），但 GPU kernel 需要固定 slot 布局（每个 chunk 固定 4352 B）。早期实现需在 CPU 侧逐 chunk `memcpy` 展开。

### 根因分析

紧凑格式节省磁盘空间，但 slot 布局便于 GPU kernel 按索引直接寻址。CPU 侧展开引入额外内存拷贝开销。

### 解决方案

引入 `sglz_decompress_compact_kernel()`：
- CPU 侧只构建 `chunk_offsets` 索引表；
- 在 GPU kernel 中通过索引表直接定位每个 chunk 的紧凑数据起始位置；
- kernel 内部完成紧凑格式到 slot 的“零拷贝”解析。

### 验证

顺序读 128k zero 数据达到 **458.3 MB/s**，与 Baseline（450.9 MB/s）持平，紧凑格式解析 overhead 被完全消除。

---

## 4. mmap 读取压缩文件过慢

### 现象

数据库、编译器等应用大量使用 `mmap`。早期实现需在 `mmap()` 时一次性预解压整个文件：
- 64 MB 文件：`mmap()` 返回 420.9 ms（Baseline 58.1 ms），减速 7.0x；
- 512 MB 文件：`mmap()` 返回 2414.5 ms（Baseline 264.2 ms），减速 12.1x。

### 根因分析

`mmap()` 是同步调用，应用期望立即返回映射地址。全量预解压使整个调用阻塞，且提前解压了未访问页。

### 解决方案

改为**同步预加载前 16 MB + 后台 pthread 异步解压剩余部分**：
- `mmap()` 中先解压前 `MMAP_PRELOAD_SIZE`；
- 对超出部分启动后台 `pthread` 继续解压；
- 立即返回匿名映射地址；
- `munmap()` 时 `pthread_join` 等待完成；
- 若请求保护位非 `PROT_READ|PROT_WRITE`，后台完成后 `mprotect` 解除限制。

### 验证

| 文件大小 | 优化前 | 优化后 | 提升 |
|---------|--------|--------|------|
| 64 MB | 420.9 ms | 226.3 ms | 1.9x |
| 256 MB | 1263.3 ms | 229.8 ms | 5.5x |
| 512 MB | 2414.5 ms | 231.4 ms | **10.4x** |

### 遗留方向

未来可引入 `userfaultfd`（Linux 4.3+）实现真正的按需页级解压。

---

## 5. GPU 高负载时实时解压性能断崖

### 现象

GPU 完全空闲时顺序读 128k 可达 **458.3 MB/s**；当 GPU 被其他任务占满（GPU-Util 100%，14 GB 显存占用）时，带宽骤降至 **80.6 MB/s**，下降约 82%。

### 根因分析

- GPU-Util（计算利用率）是性能断崖的关键，而非显存占用量；
- 单 Stream 被其他 CUDA 任务抢占，kernel 调度延迟显著增加；
- 此时继续使用 GPU 解压反而不如 CPU 后端（177 MB/s）。

### 解决方案

1. **高优先级 CUDA Stream**：`cudaStreamCreateWithPriority(..., greatestPriority)` 创建最高优先级 stream；
2. **GPU 负载自动 fallback**：`should_cpu_fallback()` 每秒通过 `nvidia-smi` 检测 GPU-Util，>80% 时切换到 CPU 后端；
3. `read_compressed()` 中通过局部函数指针动态选择 GPU/CPU 解压路径。

### 验证

| 场景 | GPU 显存 | GPU-Util | 顺序读 128k |
|------|---------|---------|------------|
| 完全空闲 | 10 MiB | 0% | 458.3 MB/s |
| 中等负载 | 3 GB | 100% | 438.4 MB/s |
| 高负载 | 14 GB | 100% | 80.6 MB/s → fallback CPU 177 MB/s |
| 计算负载验证 | 1.4 GB | 100% | 79.8 MB/s |

结论：GPU-Util 100% 是性能断崖的充分条件，自动 fallback 机制保证极端负载下仍有稳定表现。

---

## 6. 首次 I/O CUDA 初始化延迟

### 现象

每个进程首次调用 read 时，需完成 `cudaSetDevice` + `cudaStreamCreate` + `cudaMalloc`，耗时约 **200 ms**。对 `ls`/`cat` 等短生命周期命令不友好。

### 根因分析

Lazy Init 虽然避免了 constructor 阶段 CUDA 未就绪导致的崩溃，但将初始化成本转移到首次 I/O。

### 解决方案

1. **Lazy Init**：`hook_init` 不立即初始化 CUDA，第一次 I/O 时触发；
2. **后台预初始化线程**：`hook_init` 启动 `pthread`，延迟 100ms 后调用 `gpu_compress_init()`；
3. 若后台成功，首次 I/O 几乎无惩罚；若失败，前台线程重试或 fallback CPU。

### 验证

- 后台预初始化成功后，长生命周期应用首次 I/O 降至 **<10 ms**；
- 短生命周期命令仍可能遇到 200 ms 惩罚，但这是可接受的权衡。

---

## 7. 数据库文件被 56 B RAW header 破坏

### 现象

真实 workload 测试中：
- SQLite 报错 "database disk image is malformed"；
- LevelDB 报错 "bad magic number"。

### 根因分析

SQLite / LevelDB 文件在 offset 0 处具有严格的 magic / header 格式，Hook 在该位置写入 56 B RAW header 会破坏格式。

### 解决方案

`src/hook.c` 中实现数据库文件白名单：
- 后缀白名单：`.db`、`.db-journal`、`.db-wal`、`.wal`、`.log`、`.ldb`、`.sst`；
- 文件名白名单：`CURRENT`、`MANIFEST-*`；
- 命中白名单的 fd 直接透传，不附加 GPUC header；
- 拦截 `rename()`：临时文件 rename 到白名单目标时，若源为 RAW 状态，跳过 56 B header 复制真实内容。

### 验证

`tests/db_whitelist.sh`：
- SQLite：创建表、插入 1000 行、SELECT → **PASS**；
- LevelDB：`fillseq` / `readseq` / `readrandom` → **PASS**。

---

## 8. 低可压缩率数据“越压越慢”

### 现象

可压缩率梯度测试显示：
- 0% 全随机：解压读带宽 **296.3 MB/s**（RAW fallback，无 GPU 解压）；
- 25% 可压缩：解压读带宽 **224.1 MB/s**（GPU 解压，反而更慢）。

### 根因分析

25% 可压缩数据既未触发 RAW fallback，又无法充分减少 I/O，GPU 解压计算 overhead 超过了 I/O 节省收益。

### 解决方案

文件级自适应 fallback：
- Daemon 压缩时累计 `total_orig` 与 `total_comp`；
- 压缩完成后计算整体压缩率；
- 若 `total_comp / total_orig > GPUC_MIN_FILE_COMP_RATIO_PCT`（默认 85%），丢弃压缩结果，保持 RAW；
- 阈值可通过环境变量调整，`GPUC_MIN_FILE_COMP_RATIO_PCT=100` 关闭该策略。

### 验证

`tests/low_compressibility_fallback.sh`：
- 0% / 25% / 50% 可压缩率文件 → 保持 **RAW**；
- 100% 全零文件 → 进入 **COMPRESSED**。

---

## 9. 显存不足导致解压崩溃

### 现象

容错测试中，用 CUDA helper 占用 99.5% GPU 显存后，Hook 读取已压缩文件出现段错误或空指针访问。

### 根因分析

`src/gpu_compress.cu` 中 `sglz_init()` 预分配 device memory pool 时未检查 `cudaMalloc` 返回值。即使分配失败也返回 0，后续解压使用空指针。

### 解决方案

修复 `sglz_init()`：
- 每个 `cudaMalloc` 后检查返回值；
- 任一分配失败时，清理已分配资源并返回 -1；
- Hook 检测到 `gpu_compress_init()` 失败后触发 CPU fallback。

### 验证

`tests/fault_tolerance_boundary.sh` 中显存不足场景：
- 自动 fallback CPU 后端；
- 数据验证通过；
- 不再崩溃。

---

## 10. 小 bs 随机读 IOPS 锁定在 ~800

### 现象

GPU Compressed 小 bs 随机读测试中：
- 4k / 16k / 64k / 128k bs 的 IOPS 基本锁定在 **~800**；
- 单次延迟约 1.2 ms。

### 根因分析

即使应用只读 4 KB，Hook 仍需按 128 KB block 解压并裁剪，解压/元数据解析 overhead 成为瓶颈，IOPS 无法随 bs 减小而提升。

### 解决方案

引入 **per-fd single-block cache**：
- `fd_info_t` 中增加 `cache_block_id` / `cache_buf` / `cache_valid`；
- 单 block 读取时先查 cache，命中直接 `memcpy` 返回；
- miss 时解压后缓存该 block。

### 验证

有局部性时 IOPS 从 ~800 提升至 **2000-3000**；纯 uniform random 下命中率低，无显著改善。

### 后续方向

可扩展为 per-fd 多 block LRU cache（4-8 blocks），进一步提升有局部性场景。

---

## 11. 其他已解决的小问题

| 问题 | 原因 | 解决 |
|---|---|---|
| `fio` 段错误 | Hook 对特定 I/O 模式处理不完善 | 增加边界检查与 `GPUC_NO_HOOK=1` 调试开关 |
| `sendfile` 读取压缩文件错误 | 未拦截 sendfile，直接读取物理数据 | 实现 `sendfile` 拦截，对 GPUC 文件 fallback 到 `read`/`write` 循环 |
| `stat` 报告物理大小 | 未拦截 stat 或调整后逻辑大小 | `adjust_stat_size()` 将 `st_size` 替换为 `orig_size` |
| `O_DIRECT` 对齐问题 | GPU 解压后写入非页对齐缓冲区 | 使用 `posix_memalign` 分配对齐缓冲区 |
| Daemon 与应用并发冲突 | Daemon `rename()` 替换时应用仍持有 fd | Daemon 尝试非阻塞 `flock`，失败则跳过 |

---

## 12. 仍未完全解决的问题（已知限制）

| 限制 | 说明 | 优先级 |
|---|---|---|
| `MAP_SHARED` mmap | 共享写映射暂不支持 | P2 |
| 小文件海量随机读 | 1000 个 1MB 文件 ML 加载场景 overhead 大 | P1 |
| 单 GPU | 当前固定 `cudaSetDevice(0)` | P3 |
| 首次 I/O 惩罚 | 短生命周期命令仍可能遇到 ~200 ms | P1（已缓解） |

详见 `实验结果报告.md` 第六章。
