# GPUC 决赛优化 TODO

> 原则：先保证正确性与实验可信度，再优化性能；PPT 和视频最后统一。
>
> 状态：`[ ]` 未开始，`[-]` 进行中，`[x]` 已完成，`[!]` 阻塞。

## P0：决赛前必须完成

### P0 核心赛题闭环（2026-07-29）

- [x] nvCOMP LZ4 改为长期 worker，请求通过队列提交。
- [x] 建立持久化 CUDA stream/event/device buffer 与 pinned host buffer。
- [x] 增加 queue/pack/H2D/kernel/D2H/unpack/total 分段 profile。
- [x] CPU/GPU 使用同一 LZ4 输入、同一约 4096 MiB/s 吞吐和相同核心亲和性，
  重复 5 次并保存 95% CI。
  - 同 core 争用：CPU/GPU 分别保留 89.85%/97.17% 业务吞吐。
  - 隔离核心：GPU 额外主机 CPU 约 0.403 core，CPU 为 0.566 core。
- [x] 增加 SQLite range aggregate 真实业务：GPU 相对 CPU 路径 QPS 约 +7.3%，
  p99 约 -50.5%；同时保留无解压 baseline。
- [x] 重设计 4 KiB 对齐 header、block offset 与 padded span；验证
  `O_DIRECT` 标志保留、逻辑内容正确和 fio 0 error。
- [x] 输出统一 CPU time、RSS、page fault、context switch、GPU utilization/power
  和 pipeline profile CSV。
- [!] DRAM IMC bandwidth/LLC miss：当前缺少匹配内核的 perf/Intel PCM，
  `perf_event_paranoid=2` 且无提权权限；能力审计已留证，不能伪造结果。
- [!] 独占 NVMe 性能：机器有未挂载的 `nvme0n1`，当前会话不能挂载；
  O_DIRECT 软件路径已验收，正式 NVMe 性能需在有设备权限环境复跑。

### A. 构建与复现

- [x] 修复 GPU 架构自动检测：`nvidia-smi` 异常时不得生成非法 `sm_*` 参数。
  - 验收：有 GPU 时检测到正确计算能力；无 GPU/驱动异常时稳定回退 `sm_70`。
- [x] 消除 Makefile 对调用者 `PWD` 的依赖，统一使用项目绝对路径。
- [x] 增加 nvCOMP/liblz4 依赖检查与准备脚本。
  - 验收：干净 clone 后按文档可完成依赖准备、编译、测试。
- [x] 修正“CPU-only”构建命令，确保不触发 nvcc/nvCOMP。
- [x] 增加 `make smoke-test`，覆盖 CPU Hook 的最小闭环；GPU 闭环由 `make test` 覆盖。

### B. 实验可信度

- [x] 修复高并发实验：Baseline、Hook RAW、GPU Compressed 使用独立且内容一致的文件。
  - 验收：每轮记录 header state、逻辑大小、物理占用和 SHA-256。
- [x] 修复消融与 Batch Sweep 的 header state 偏移读取错误。
- [x] 所有核心实验至少重复 5 次，输出 mean/std/95% CI。
- [x] 分开报告 warm-cache、cold-cache、O_DIRECT，不混合解释。
- [x] 把 CSV、fio JSON、环境信息、Git commit 和命令行保存到仓库 `results/`。
- [x] 旧格式核验：不满足对齐时清除 `O_DIRECT`，不发布伪结果；随后已实现并验证
  新版 4 KiB 对齐 COMPRESSED 格式。
- [x] 在修复后重跑以下核心实验：
  - [x] 正确性与基础 DEMO（V100 `make test`、CPU `make smoke-test`）
  - [x] Baseline / RAW / SGLZ / LZ4 顺序读
  - [x] jobs=1/4/8/16/32 扩展性
  - [x] Ablation Study
  - [x] Batch Size Sweep
  - [x] mmap 正确性与延迟
  - [x] CPU LZ4 vs GPU LZ4 同算法公平对比

本轮已固化结果：

- `results/final/high_concurrency_v100_20260725/`
- `results/final/mmap_v100_20260725/`
- `results/final/lz4_cpu_gpu_v100_20260725/`
- `results/final/high_concurrency_warm_v100_20260729/`
- `results/final/cold_cache_v100_20260729/`
- `results/final/ablation_v100_20260729/`
- `results/final/batch_size_v100_20260729/`
- `results/final/compressibility_v100_20260729/`
- `results/final/backends_v100_20260729/`
- `results/final/cpu_offload_4workers_v100_20260729/`

### C. mmap 正确性

- [x] 停止把“后台顺序预解压”称为“按需解压”。
- [x] 修复应用提前访问 16 MB 之后区域可能读到未完成数据的问题。
- [x] mmap 测试改用逐页唯一、非零 pattern，并在 `mmap()` 返回后立即扫描全部页。
- [x] 先以同步完整填充修复可见性，再实现 userfaultfd 按 128 KiB block 缺页
  填充；同步路径保留为不支持 userfaultfd 时的兼容回退。

### D. 文件语义与并发安全

- [x] 修复 `dup/dup2/dup3` 对缓存指针的浅复制、double-free 和共享偏移风险。
- [x] 修复 `truncate/ftruncate` 对 COMPRESSED 文件的破坏风险。
- [x] 明确并测试压缩文件的写策略：COMPRESSED/INLINE 拒绝破坏性修改并返回 `EROFS`。
- [x] 修复 `O_APPEND`、`writev`、`pwrite` 后逻辑偏移和文件大小维护。
- [x] 白名单 rename 使用同目录临时文件 + fsync + 原子 rename，保留 mode/owner/time/xattr。
- [x] Daemon 保留原文件权限、owner、时间戳和扩展属性。
- [x] 同一文件并发读/Daemon 压缩测试，不再用两个不同文件代替。
- [x] 增加非协作应用（未持有 flock）的并发边界说明和测试。
- [x] 已增加损坏 header/block table、超大字段、非法 offset 的防御性测试，
  并加入 2000 个确定性变异格式的 fuzz smoke。

### E. 文档真实性

- [x] 删除未实现的工作窃取、共享内存环形队列、Deflate/Cascaded/Selective Gdeflate 等表述。
- [x] 删除“仅对实际访问页解压”“LevelDB 延迟降低 40%”等无实验依据的表述。
- [-] 团队成员与分工已按原 PPT 统一，Git 时间线已核对为 49 commits；
  仓库没有可验证工时，提交前需团队按真实记录补充，不能由工具推断。
- [x] 将“完全透明/任意应用/零侵入/生产级/最优解”改为有边界的准确表述。
- [x] 重写 `docs/EXPERIMENTAL_REPORT.md`，仅引用可复核结果，不再依赖失效图片。
- [x] 统一 `.gpuc_tmp` 名称、文档文件名和交叉链接。
- [x] 若采用 Codex 生成或修改的内容，更新 AI 工具使用声明。

## P1：增强决赛说服力

### P1 补充实验（2026-07-29）

- [!] 鲲鹏 920/AArch64：按用户安排暂不实施；当前没有对应硬件，不能用 x86
  交叉编译冒充实测。
- [!] RTX 3050/4090：脚本可直接复跑，按用户安排等个人电脑和实验室 4090
  最后补；当前正式数据仍为 V100。
- [!] Btrfs/ZFS/DM 公平基线：已增加只读能力审计并保存
  `results/final/storage_baseline_capability_v100_20260729/`。本机无 root/CAP_SYS_ADMIN、
  无可见 loop 节点，ZFS/zpool 不存在，因此没有格式化或伪造文件系统结果。
- [!] vdbench：已增加顺序读、4 KiB 随机读和 70:30 混合读写参数及运行脚本；
  Oracle Vdbench 需要接受许可证且本机没有 Java/Vdbench，阻塞证据保存在
  `results/final/vdbench_capability_v100_20260729/`。
- [x] fio I/O 矩阵：4/16/128 KiB，顺序/随机读、顺序/随机/70:30 混合写，
  1/4 应用线程，Baseline libaio QD 1/8/32，五轮、p95/p99/p99.9 和 95% CI。
  压缩读固定单线程；并发扩展沿用独立的 128 KiB 五轮实验。
- [!] 新矩阵中 fio thread 模式的 COMPRESSED 多线程读出现超长不返回；为避免
  混淆变量，本矩阵固定压缩读单线程。现有 128 KiB 并发专项结果仍有效，但该
  thread-mode 卡顿需作为独立稳定性问题继续定位。
- [x] 修复 fio 混合读写触发的 RAW 长度错误：补齐 `ftruncate64`、
  `fallocate(64)`、`posix_fallocate(64)`，并禁止内部物理长度查询再次经过 Hook。
- [x] 公开真实数据集：Project Gutenberg #2600，固定 URL、许可证、更新时间、
  3,359,610 字节及 SHA-256；五轮结果保存在
  `results/final/public_dataset_pg2600_v100_20260729/`。
- [x] 系统资源：五轮保存 pidstat `-u -r -w`、sar `-u -r -B -W`、
  nvidia-smi 200 ms 原始日志和统一摘要，见
  `results/final/system_resource_v100_20260729/`。
- [-] 能效：已输出 GPU 板卡总功耗边界和相对空闲板卡的增量 J/GiB；
  V100 GPU 路径约 0.482 J/GiB（增量板卡边界）。本机无 RAPL/IPMI/外部功率计，
  因而尚不能称为 CPU package 或整机能效。

### F. 证明“GPU 资源卸载”的核心价值

- [x] 使用同一 LZ4 数据与格式对比 CPU liblz4 和 GPU nvCOMP LZ4。
- [x] 同时运行 CPU 业务任务，测量 GPU 卸载后业务吞吐是否提升。
  - 旧同步实现为负；长期 worker 后同吞吐同 core 场景 CPU/GPU 分别保留
    89.85%/97.17%，95% CI 不重叠。
- [x] 已记录解压带宽、CPU user/sys、worker/submit CPU、RSS、fault、context
  switch、GPU 利用率/功耗和 pipeline profile。
- [x] 增加压缩耗时并计算读取摊销：所有已测 COMPRESSED 读取慢于 Baseline，
  当前不存在正的性能 break-even，见 `results/final/break_even.csv`。
- [!] 文件大小 × 可压缩率 × 并发数的正向 break-even 图：当前没有交叉点，
  不能制造图形；等读路径快于 Baseline 后再绘制。

### G. 真实 workload

- [x] 已增加 Project Gutenberg #2600 公开真实文本，记录固定下载 URL、目录页、
  许可证页、版本日期、字节数和 SHA-256，并完成五轮空间、压缩及 cold/warm 读取。
- [x] 不再把 `/dev/urandom` 文件称为 ImageNet 风格 workload；相关旧结果已从核心报告移除。
- [x] ccache、小文件和旧日志结果未达到当前方法学要求，已从核心报告/PPT移除；
  若后续恢复，必须分开 cold/warm 并重新五轮测试。
- [x] btrfs zstd 未在独立压缩卷复核生效，已从核心报告和 PPT 移除。

## P2：工程化与展示

- [x] 增加 CI：shell syntax、CPU build、格式解析、单元测试、文档链接检查。
- [x] 增加 ASan/UBSan CPU 路径测试；CI 环境同时开启 LSAN。
- [x] 整理 `results/` 数据规范与最终结果索引；自动绘图留到 PPT 阶段统一完成。
- [x] 精简实验报告，移除失效历史表，只保留可审计结果。
- [x] 明确 LD_PRELOAD 是指定动态链接进程的用户态原型，不覆盖静态链接、直接
  syscall 和应用自行提交的 io_uring；新增 `docs/SUPPORT_MATRIX.md`。
- [x] 将 COMPRESSED/INLINE 固化为只读归档对象：写、截断、预分配返回
  `EROFS`，`MAP_SHARED`/`MAP_FIXED` 返回 `EOPNOTSUPP`；本轮不实现隐式 COW。
- [x] 实现 userfaultfd mmap 缺页填充，按 128 KiB GPUC block 读取/解压；
  auto 模式不可用时同步回退，强制模式明确失败。
  - 256 MiB COMPRESSED 五轮：`mmap()` 0.215±0.011 ms，首次 fault
    146.502±3.836 ms，完整扫描 5651.449±367.254 ms，mismatch=0。
- [x] 增加确定性故障恢复：Daemon ENOSPC、SIGKILL、残留临时文件重启、
  GPU 不可见 CPU fallback、`/dev/full` 五项全部 PASS。
- [x] V100 10 分钟正式稳定性验收：fio error=0、实际 runtime 600002 ms、
  600 个带宽样本、变异系数 9.05%、前后逻辑 SHA 一致；脚本默认 1 小时，但
  不将默认配置冒充已执行时长。
- [x] 增加 GCC gcov CPU 覆盖率和 CI 门槛：Hook 行覆盖率 41.38%，门槛 35%；
  CPU Daemon/SGLZ/LZ4 分别为 62.15%/85.52%/70.83%。
- [!] AMD/Intel/其他 GPU 供应商后端按用户安排暂缓；当前仍只支持 NVIDIA
  CUDA/nvCOMP，不能宣称跨供应商。

## 最后阶段：PPT 与视频

- [ ] 在上述 P0 实验完成后再更新 PPT。
- [ ] PPT 从 19 页压缩至约 12–14 页，增大字号。
- [ ] 删除或替换未经公平重测的 jobs=32 99.8%。
- [ ] “mmap 按需解压”改为真实实现名称。
- [ ] 删除“5 项全 PASS/无数据竞争/生产级保证”等过强结论。
- [ ] 增加一页适用场景与限制。
- [ ] 增加一张“CPU 资源释放”核心结果图。
- [ ] 统一成员分工、时间线、原创与 AI 声明。
- [ ] 最后重写视频脚本，只录制已验证且可现场复现的命令。
