# GPUC 支持矩阵与能力边界

> 适用版本：2026-07-30。本文是 README、设计报告、实验报告和 Demo 的统一口径。
> “支持”表示已有自动测试；“有限支持”表示必须满足表中前提；“不支持”不会静默
> 退化为可能破坏数据的行为。

## 1. 产品定位

GPUC 是面向指定动态链接进程的用户态存储压缩卸载原型，不是 block 层或文件系统。
它适合由 GPUC Daemon 将写完、进入冷态的普通文件转换为只读压缩对象，再由加载
Hook 的应用透明读取。启用范围由 `LD_PRELOAD` 精确控制，因此无需 root、无需
格式化卷，也不会自动覆盖整台机器的所有 I/O。

当前已经证明的核心价值是：在固定处理量和相同 CPU 亲和性下，把 LZ4 解压工作
卸载到 V100 可降低主机 CPU 成本并减轻对并行业务的干扰。当前实现不宣称压缩读
绝对吞吐高于普通文件，也不宣称对任意应用完全透明。

## 2. 应用与 I/O 接口

| 能力 | 状态 | 边界与行为 | 验证 |
|---|---|---|---|
| 动态链接的 libc 应用 | 支持 | 进程必须显式加载 `libgpuhook.so` 或 `libcpuhook.so` | cp、dd、fio、测试程序 |
| 未加载 Hook 的进程 | 不支持透明读 | 看到的是 GPUC 物理格式，不应直接消费压缩对象 | 设计边界 |
| 静态链接程序 | 不支持 | `LD_PRELOAD` 无法拦截 | 设计边界 |
| 直接 `syscall` I/O | 不支持 | 绕过 libc 符号的调用不进入 Hook | 设计边界 |
| 应用自行提交 io_uring | 不支持透明拦截 | Hook 内部 io_uring 只是实现细节，不会拦截应用 SQE | 设计边界 |
| `open/read/pread/readv/lseek/stat` | 支持 | 对 GPUC 对象呈现逻辑内容和逻辑大小 | 集成/POSIX 测试 |
| RAW `write/pwrite/writev/truncate/fallocate` | 支持 | 保持逻辑 offset、append、dup 和长度语义 | `test_posix_semantics` |
| COMPRESSED/INLINE 修改 | 只读策略 | `write/pwrite/writev/truncate/ftruncate/fallocate/posix_fallocate` 返回 `EROFS` | `test_posix_semantics compressed` |
| `sendfile` | 有限支持 | 压缩对象通过用户态 read/write 回退，不是内核零拷贝 | 集成测试 |
| 多进程/多线程读 | 有限支持 | 已验证 32 个独立 fd；同一 fd 的共享 read-ahead 状态加锁保证正确性，但调用会序列化 | 并发实验、4 线程共享 fd 随机 pread |
| `/proc`/`sysfs` 空只读伪文件 | 透传 | `st_size=0` 且只读时不注册为 GPUC RAW，避免破坏监控工具 | Vdbench CPU 指标、procstat 回归 |
| 数据库原生文件 | 透传 | `.db/.wal/.sst/.log` 等白名单不添加 GPUC header | rename/POSIX 测试 |

## 3. mmap

| 模式 | 配置 | 行为 |
|---|---|---|
| 自动 | `GPUC_MMAP_MODE` 未设置 | 优先 `userfaultfd`；不可用时回退同步完整填充 |
| 强制按需 | `GPUC_MMAP_MODE=userfaultfd` | 注册 missing-page fault；失败时返回 `EOPNOTSUPP`，不静默回退 |
| 强制同步 | `GPUC_MMAP_MODE=sync` | 在 `mmap()` 返回前填充整个逻辑映射 |

共同边界：

- 支持 RAW、INLINE、COMPRESSED 的只读 `MAP_PRIVATE`；
- fault handler 以 GPUC 的 128 KiB block 为填充单元，应用仍按普通页访问；
- `MAP_SHARED` 和 `MAP_FIXED` 对受管文件返回 `EOPNOTSUPP`，防止共享写或覆盖地址
  暴露压缩物理数据；
- 每个映射使用独立 userfaultfd handler；`munmap()` 负责停止并回收 handler；
- 只支持一次性完整 `munmap()`；部分解除映射返回 `EOPNOTSUPP`，避免拆分
  userfaultfd 注册区间后留下悬空状态；
- 不支持将尚未完成 fault 的受管映射跨 `fork()` 继承；子进程应重新 open/mmap；
- Linux 5.11 及以上可使用 `UFFD_USER_MODE_ONLY` 处理用户态缺页。本机即使
  `vm.unprivileged_userfaultfd=0` 仍可运行该模式；
- 首次缺页包含 CUDA lazy-init 成本。256 MiB V100 正式实验中，`mmap()` 返回由
  旧同步路径约 1.21 s 降至约 0.22 ms，但首次 fault 约 0.15 s；完整扫描成本只是
  被后移，并未消失。

## 4. 存储、格式与修改模型

| 项目 | 状态 | 说明 |
|---|---|---|
| ext4/xfs 上的普通文件 | 支持 | 不修改文件系统 |
| COMPRESSED/INLINE 只读归档 | 支持 | 本轮明确选择只读对象模型 |
| 压缩后原地修改/COW | 不支持 | 应先解归档或生成新 RAW 文件，再由 Daemon 重新压缩 |
| 原子替换 | 支持 | 同目录临时文件、`fsync(temp)`、`rename`、`fsync(parent)` |
| 元数据 | 有限支持 | 保留 mode/owner/mtime/xattr；ACL/SELinux label 需目标环境复核 |
| 稀疏文件语义 | 不承诺 | 逻辑数据正确；原始 hole 布局不保证保持 |
| `O_DIRECT` | 有限支持 | 新版 4 KiB 对齐格式、对齐用户缓冲已验证；旧格式自动清除标志 |
| NVMe 性能 | 未验证 | 本机 NVMe 未挂载且无挂载权限；现有正式 direct 数据来自 SATA/ext4 |
| btrfs/ZFS/DM | 未验证 | 当前环境缺挂载权限、ZFS 和有效压缩卷 |

## 5. 后端、硬件与降级

| 项目 | 状态 | 说明 |
|---|---|---|
| NVIDIA CUDA SGLZ | 支持 | 自研通用 CUDA kernel，V100 sm_70 已验证 |
| NVIDIA nvCOMP LZ4 | 支持 | 可选后端，V100 已验证 |
| CPU SGLZ/LZ4 | 支持 | CPU-only 构建和 GPU 初始化失败后的读 fallback |
| GPU 运行时不可见 | 有限支持 | GPU Hook 初始化失败后可回退 CPU 解码，已用隐藏设备验证 SHA |
| AMD/Intel/其他 GPU | 暂不支持 | HIP/SYCL/其他供应商后端按本轮安排保留为后续工作 |
| 多 GPU | 不支持 | 当前固定 device 0 |
| RTX 3050/4090 | 待复测 | 脚本已准备；当前正式结果来自 V100 |
| AArch64/鲲鹏 920 | 待硬件 | 当前没有目标硬件，不用交叉编译冒充实测 |

## 6. 故障与恢复

| 故障 | 预期行为 | 自动验证 |
|---|---|---|
| Daemon 压缩中 `SIGKILL` | 原 inode/RAW 内容和 SHA 不变；可能残留临时文件 | 支持 |
| 重启遇到残留临时文件 | 截断并重建临时文件，最终原子替换 | 支持 |
| 注入 `ENOSPC` | 放弃替换，保留原 RAW，正常失败路径删除临时文件 | 支持 |
| `/dev/full` 写失败 | 向调用者传播内核错误 | 支持 |
| GPU 初始化失败/不可见 | CPU fallback 解码，逻辑 SHA 不变 | 支持 |
| GPU reset | 未执行真实 reset | 需要管理员权限并可能影响其他任务；当前只验证设备不可用边界 |
| 主机掉电 | 部分覆盖 | 已有 fsync/rename 协议，未做真实断电或虚拟机电源故障注入 |

## 7. 测试与质量门槛

- `make smoke-test`：CPU 最小闭环；
- `make test`：V100 GPU 功能与集成回归；
- `make sanitizer-test`：ASan/UBSan；
- `make coverage-test`：gcov CPU Hook/Daemon/算法路径，Hook 行覆盖率不得低于
  35%；正式结果保留行和分支统计；
- `bash tests/fault_recovery.sh`：无 root 的确定性故障恢复；
- `bash tests/long_term_stability.sh`：默认 1 小时，保留 fio JSON、1 秒带宽、
  500 ms GPU 指标和运行前后逻辑 SHA；
- `bash tests/mmap_size_sweep.sh`：按大小、重复次数和线程数记录 mmap 返回、
  首次 fault 与完整扫描延迟。

上述矩阵界定的是当前原型的可验证范围。若要覆盖全机 I/O、静态程序、应用
io_uring 或可写压缩对象，应迁移到 FUSE/ublk/device-mapper/文件系统层，或实现
独立的解归档与事务性 COW 层，而不是继续扩大 `LD_PRELOAD` 的宣传口径。
