# GPUC 决赛优化 TODO

> 原则：先保证正确性与实验可信度，再优化性能；本文件不安排 PPT 和视频制作。
>
> 状态：`[ ]` 未开始，`[-]` 进行中，`[x]` 已完成，`[!]` 阻塞。
>
> 最新核对：2026-07-31；依据 `tmp/赛题说明.md`、最新
> `docs/EXPERIMENTAL_REPORT.md` 和 `results/final/`。PPT 与视频由团队自行
> 制作，本清单只维护代码、实验和技术文档。

## 当前剩余事项总览

### 现有 V100/x86 环境已完成的证据

- [x] **补 CPU/GPU 压缩侧公平实验**：同一 LZ4 输入五轮的吞吐、压缩率、
  主机 CPU、RSS、GPU 功耗和 95% CI 已完成；真 batch 相对旧 serial 至少
  18.34 倍，但同为 1024 MiB/s 时 GPU/CPU 为 0.365/0.276 host core，压缩侧
  没有 CPU 卸载收益。PCM 进一步显示 GPU/CPU 总 DRAM 为
  1809.39/1396.85 MB/s，GPU 高 29.53%，负结论证据已经闭环。
- [x] **补方案层级与内核接入设计**：明确当前 LD_PRELOAD 是用户态机制探索，
  COMPRESSED/INLINE 是只读归档；增加 DM/Btrfs/ZFS 接入时的数据流、队列、
  metadata、回写、崩溃一致性与并发设计，见
  `docs/KERNEL_INTEGRATION_DESIGN.md`。
- [x] **做一次独立从零部署验收**：全新临时路径中 check-env、CPU smoke、
  docs check、GPU build 和 GPU unit/integration 全部 PASS，总耗时约 46 秒。
- [x] **补一种真实二进制/日志扫描 workload**：真实 dpkg status + Bash ELF
  五轮完成，15/15 业务 hash/marker 一致；CPU/GPU 约 156.5/157.3 MiB/s，
  95% CI 重叠，压缩空间占用约 54.52%。
- [x] **整理公开参考区间**：已整理 nvCOMP、Btrfs、OpenZFS 和 Linux DM 官方
  文档及不可直接横比边界，见 `docs/EXTERNAL_BASELINES.md`。

### 需要管理员和明确可销毁存储目标

- [x] **Btrfs zstd 基线**：安全 loop 五轮已完成，30/30 fio/SHA 通过；
  `compsize`/`filefrag` 验证 zstd extent，Btrfs/GPUC 占用比为
  3.125%/6.284%。性能为 warm-cache 应用路径，不是 NVMe 介质吞吐。
- [!] **正式 NVMe 性能**：软件 O_DIRECT 路径已通过；机器存在未挂载 NVMe，
  但尚未确认分区、文件系统和数据归属。确认前禁止格式化或写裸盘。
- [!] **CPU package/整机能效**：仍需要 RAPL、IPMI 或外部功率计；现有
  0.482 J/GiB 只是 V100 板卡增量边界。

### 需要外部硬件

- [!] **鲲鹏 920/AArch64 实测**：当前没有对应硬件。
- [!] **赛题指定 RTX 实测**：至少需要 RTX 3060/4060/5060 之一；计划中的
  3050/4090 只能补充跨代趋势，不能替代指定型号。
- [!] **非 NVIDIA GPU 后端**：当前依赖 CUDA/nvCOMP，按赛程安排暂缓。

### 已形成的核心结论

- [x] 固定约 4096 MiB/s 解压吞吐下，GPU 额外主机 CPU 成本较 CPU LZ4
  降低约 28.8%；
- [x] 同 core 争用下 GPU/CPU 分别保留 97.17%/89.85% 业务吞吐；
- [x] SQLite 并行场景 GPU 相对 CPU QPS +7.3%、p99 -50.5%；
- [x] SQLite旧实验算法标签错误已审计：原329.86/21.79 QPS实际为SGLZ，不得
  标作LZ4。修正后的真实LZ4五轮中CPU/GPU-only为108.92/55.67 QPS；单block
  CPU分流达到108.33 QPS、p99较GPU-only降低52.52%，但仍比普通文件慢99%以上；
- [x] LZ4 H2D合并五轮使吞吐4805.13→5275.91 MiB/s（+9.80%），H2D阶段
  0.2713→0.0393 ms（-85.51%）；
- [x] PCM 显示 GPU/CPU 总 DRAM bandwidth 约为
  4569.51/8745.46 MB/s，GPU 低约 47.75%，但 RSS 高约 8.94% 且 D2H 写回仍在；
- [x] PCM代表组完成45条样本：不可压缩1024 MiB/s、50%压缩率2048 MiB/s、
  高可压缩4096 MiB/s下GPU总DRAM相对CPU分别为−0.11%、−5.69%、−47.42%，
  证明带宽收益强依赖压缩率和吞吐；
- [x] LZ4 请求感知预读使 4 KiB 随机读吞吐提高 4.19–4.90 倍、p99 降约 90%，
  但压缩读取绝对性能仍低于普通文件 Baseline。
- [x] 压缩侧 PCM 显示 GPU 总 DRAM bandwidth 高 29.53%、主机 CPU 高 26.95%、
  RSS 高 20.17%，因此明确保留压缩侧负结论。
- [x] Btrfs zstd:3 空间占用 3.125%，GPUC LZ4 为 6.284%；暖缓存速度差距暴露
  GPUC 用户态逐请求和 128 KiB 解压粒度开销，不包装为磁盘结论。
- [x] Btrfs真实dpkg status+Bash ELF corpus文件级失效完成30/30样本：Btrfs/GPUC
  空间占用36.36%/54.61%，GPUC顺序/随机均落后；loop结果不包装为NVMe性能。
- [x] 解压敏感性矩阵完成 95 个样本：业务收益随吞吐和压缩率增强；4 GiB/s、
  高可压缩输入 GPU/CPU 业务保留 91.27%/87.77%，GPU 解压 host CPU 低 27.5%；
  低压缩率低吞吐组不支持业务收益，部分 4 GiB/s 组进入饱和。
- [x] 不限速压缩峰值与三档压缩率完成：GPU batch 为 423–1301 MiB/s，仅为
  单核 CPU liblz4 的 7.3%–16.6%，压缩侧负结论进一步确认。

## 实验数据结果仍存在的问题（2026-07-31）

> 数据 QA 结论：**可带限定条件用于决赛（Share with caveats）**。
> 已有数据足以支持“固定 LZ4 解压吞吐下减少主机 CPU 和总 DRAM
> bandwidth”，但不足以支持“压缩存储更快”或“所有场景都能卸载”。

| ID | 优先级 | 数据问题 | 当前证据 | 影响 | 下一步 |
|---|---|---|---|---|---|
| E1 | 高 | 压缩文件读取绝对性能仍低于 Baseline | H2D合并使批量吞吐+9.80%；小请求分流使Vdbench 2.076→12.239 MB/s，但fio、真实扫描和break-even仍没有正交叉点 | 不能声称改善普通文件 I/O 性能 | 下一步重点是128 KiB粒度、热点缓存和内核接入；H2D与单block分流已完成 |
| E2 | 已解决·限定结果 | Btrfs曾只有高度可压缩合成数据的warm-cache结果 | 真实dpkg status+Bash ELF corpus、`invalidate=1`、三路径两workload各五轮已完成；Btrfs/GPUC空间36.36%/54.61% | 真实数据与文件页缓存失效缺口已补，但loop backing和设备缓存未刷新，仍不能称NVMe冷盘性能 | 保留限定条件；正式介质结论合并到E5的独占NVMe任务，不再重复loop实验 |
| E3 | 低·数据集边界 | 真实corpus上的CPU/DRAM卸载敏感性仍未完成 | CPU/业务95样本和PCM代表组45样本均完成；GPU总DRAM差从不可压缩−0.11%到高可压缩−47.42% | 合成输入适用边界已经明确，但PCM梯度仍不能完全外推真实业务内容 | 若时间允许，在真实corpus只复核1–2个代表点；无需重复现有140个CPU/PCM样本 |
| E4 | 已解决·优化后仍负 | 旧SQLite实验误把SGLZ标作LZ4，现已修正 | 新runner强制校验算法ID=2；真实LZ4 GPU-only 55.67 QPS，混合分流108.33 QPS、p99 -52.52%，普通文件仍约22197 QPS | 兼容性和优化收益已证明，但绝不能写成数据库加速；混合结果使用CPU | 若要支持可写DB或接近Baseline，需要文件系统/DM层和更细粒度缓存 |
| E5 | 高·阻塞 | 没有正式 NVMe 介质数据 | O_DIRECT 语义已验收，正式结果来自 SATA/ext4；未挂载 NVMe 归属未确认 | 无法回答赛题的高性能 NVMe 服务器场景 | 只在确认可写/可销毁目标后复跑 fio/Vdbench direct I/O，禁止操作未确认裸盘 |
| E6 | 高·外部 | 缺鲲鹏 920、赛题指定 RTX 和跨 GPU 代际数据 | 目前只有 x86 + V100 正式数据 | 不能回答国产 CPU 收益和指定平台适配 | 在鲲鹏 920、至少一款 3060/4060/5060 复跑核心子集；3050/4090 只作补充 |
| E7 | 中·性能 | 压缩侧已经不是数据缺失，而是绝对性能仍为负 | 三档压缩率不限速五轮：GPU 423–1301 MiB/s，只有单核 CPU 的 7.3%–16.6%；固定 1024 MiB/s 时 CPU/DRAM/RSS 也更差 | 不能把较低 GPU peak host CPU 包装为卸载，因为 GPU 同时处理得更少 | 先优化压缩 pipeline、拷贝和 batch，再用现有脚本回归；当前无需重复相同实验 |
| E8 | 中 | 整机能效数据不完整 | 只有 V100 板卡增量约 0.482 J/GiB | 无法比较 CPU package/整机 J/GiB | 使用 RAPL、IPMI 或外部功率计同时采集 CPU/GPU/整机能耗 |
| E9 | 中 | 长时稳定性正式数据只有 10 分钟 | 600 秒、600 样本、fio error=0、SHA 一致 | 能支持短时 Demo，不能写成已执行 1 小时/数小时稳定性 | 现有 V100 可再跑实际 1 小时；GPU reset/断电仍需隔离环境 |
| E10 | 低·能力限制 | 没有精确型号化 LLC-load-misses | 通用 cycles/instructions/cache 事件已有，PCM 也已有 | 不能将通用 cache-misses 写成 LLC miss | 仅在支持该 PMU 事件的内核/硬件环境补测 |
| E11 | 中·长期 | 没有 ZFS/DM 实现与性能数据 | 只有 Btrfs loop 空间/暖缓存基线和内核接入设计 | 文件系统/block 层任务仍只完成部分 | 未实现前不生成伪性能数据；按赛程决定是否继续 |
| E12 | 低 | `results/final/` 仍保留明确作废的历史目录 | README 已标注旧 jobs=32/mmap 结果无效 | 评审或团队仍可能误用旧 CSV | 最终封版时移入明确的 `historical_invalid/` 或生成只含有效数据的交付清单 |

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
- [x] 512 MiB 稳态 DRAM IMC bandwidth：脚本排除初始化阶段，三场景各五轮。
  CPU/GPU 同为约 4094 MiB/s 时，总带宽分别为 8745.46±29.06 和
  4569.51±7.15 MB/s，GPU 低约 47.75%；但 D2H 写带宽仍约 4483.11 MB/s，
  最大 RSS 高约 8.94%。结果见 `results/final/pcm_dram_512m_v100_20260730/`。
  第一版 16 MiB 结果仅作为 cache-resident 方法学反例保留。
- [x] 进程级 perf：使用内核 `perf_event_open` 在稳态区间采集进程及继承线程，
  512 MiB 工作集、三场景各五轮；cycles/instructions/通用 cache 事件已保存。
  本机不支持精确 `LLC-load-misses`，不得把通用 cache-misses 改名。
- [!] 独占 NVMe 性能：机器有未挂载的 `nvme0n1`，用户具备管理员权限，但设备
  内容和可销毁性尚未确认；O_DIRECT 软件路径已验收。确认安全目标后再挂载或复跑，
  不得因为有 sudo 就直接格式化未知设备。

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

### P1 补充实验（2026-07-30）

- [!] 鲲鹏 920/AArch64：按用户安排暂不实施；当前没有对应硬件，不能用 x86
  交叉编译冒充实测。
- [!] RTX 平台：脚本可在个人电脑 3050 和实验室 4090 复跑，二者可作为跨代
  补充；赛题指定的是 3060/4060/5060，仍应争取其中至少一款。当前正式数据为 V100。
- [-] Btrfs/ZFS/DM 公平基线：Btrfs 安全 loop 五轮已经完成，30/30 fio/SHA
  通过并验证 zstd extent；这只覆盖 warm-cache 和空间基线。ZFS/zpool 和
  DM target 仍未实现，因此组合项继续标为部分完成。
- [x] vdbench：使用用户提供、已接受 Oracle 许可的 Vdbench 5.04.07 和项目私有
  Temurin Java 8 完成自检及 V100 正式实验。覆盖 128 KiB 顺序读、4 KiB 随机读、
  70:30 随机混合读写，4 线程、每组五轮、50/50 样本通过，所有逻辑 SHA-256
  一致；原始 HTML、直方图、CPU 指标和 95% CI 保存在
  `results/final/vdbench_v100_20260730/`。许可包和 Java 不进入仓库。
- [x] 修复 Vdbench 暴露的共享 fd 并发读错误：为同一 open file description 的
  COMPRESSED 读取状态增加互斥保护，新增 4 线程共享一个 fd、随机 `pread`
  的 SGLZ/LZ4 回归并纳入 `make test`。
- [x] 修复 Hook 将 `/proc/stat` 等 `st_size=0` 的只读伪文件误识别为 RAW：
  空只读对象现在直接透传；Vdbench Hook 场景的 CPU 指标恢复为数值。
- [x] fio I/O 矩阵：4/16/128 KiB，顺序/随机读、顺序/随机/70:30 混合写，
  1/4 应用线程，Baseline libaio QD 1/8/32，五轮、p95/p99/p99.9 和 95% CI。
  旧正式矩阵的压缩读固定单线程；修复后 runner 已恢复 1/4 线程覆盖。
- [x] 修复 fio thread 模式 COMPRESSED 多线程读退出卡死：根因是 `close()` 在
  fd 表全局锁内调用 `cudaFreeHost()`，CUDA 同步期间其余线程全部等待同一锁。
  当前只在锁内摘除 fd 引用，页锁定缓冲区在锁外释放。V100 正式回归覆盖
  SGLZ/LZ4、4/16/128 KiB、1/4 线程、每组五轮，共 60/60 样本无超时、
  fio error=0、逻辑 SHA-256 一致，最大墙钟时间 3.785 s（fio runtime 3 s）。
  结果见 `results/final/fio_compressed_threads_v100_20260730/`。
- [x] 修复 LZ4 小请求读取放大：旧路径一次 4 KiB cache miss 固定读取和解压
  `32 × 128 KiB = 4 MiB`。新路径随机访问只处理请求覆盖 block，连续访问窗口按
  1/8/16/32 增长，并让 TLS batch buffer 按需扩容。严格 fio A/B 共 60/60
  样本通过；4 KiB 随机读提高 4.19–4.90 倍、p99 降低 89.5%–91.0%，顺序读
  95% CI 重叠。Vdbench 五轮随机/顺序读提高到 2.156/65.278 MB/s。
- [x] 修复 Vdbench runner 的场景隔离：只准备选定格式，SGLZ/LZ4 daemon
  显式指定算法，末尾只校验已准备文件，避免环境变量污染和无关场景耗时。
- [x] 修复 fio 混合读写触发的 RAW 长度错误：补齐 `ftruncate64`、
  `fallocate(64)`、`posix_fallocate(64)`，并禁止内部物理长度查询再次经过 Hook。
- [x] 公开真实数据集：Project Gutenberg #2600，固定 URL、许可证、更新时间、
  3,359,610 字节及 SHA-256；五轮结果保存在
  `results/final/public_dataset_pg2600_v100_20260729/`。
- [x] 系统资源：五轮保存 pidstat `-u -r -w`、sar `-u -r -B -W`、
  nvidia-smi 200 ms 原始日志和统一摘要，见
  `results/final/system_resource_v100_20260729/`；另以 Intel PCM 完成五轮
  全系统 IMC 带宽，见 `results/final/pcm_dram_v100_20260730/`。
- [!] 能效：已输出 GPU 板卡总功耗边界和相对空闲板卡的增量 J/GiB；
  V100 GPU 路径约 0.482 J/GiB（增量板卡边界）。本机无 RAPL/IPMI/外部功率计，
  因而尚不能称为 CPU package 或整机能效。

### F. 证明“GPU 资源卸载”的核心价值

- [x] 使用同一 LZ4 数据与格式对比 CPU liblz4 和 GPU nvCOMP LZ4。
- [x] 补充压缩侧严格公平实验：真 batch 相对逐块同步至少提高 18.34 倍；
  同为 1024 MiB/s 时 GPU/CPU 主机 CPU 为 0.365/0.276 core，因此如实保留
  “压缩侧没有 CPU 卸载收益”的负结论，不能外推解压侧收益。
- [x] 补充不限速压缩峰值与压缩率梯度：0%/50%/100% 可压缩页下 GPU 为
  423.45/459.51/1300.61 MiB/s，CPU 为 4850.92/6283.75/7842.97 MiB/s；
  GPU 绝对吞吐仅为 CPU 的 7.3%–16.6%。
- [x] 同时运行 CPU 业务任务，测量 GPU 卸载后业务吞吐是否提升。
  - 旧同步实现为负；长期 worker 后同吞吐同 core 场景 CPU/GPU 分别保留
    89.85%/97.17%，95% CI 不重叠。
- [x] 已记录解压带宽、CPU user/sys、worker/submit CPU、RSS、fault、context
  switch、GPU 利用率/功耗和 pipeline profile。
- [x] 合并连续 D2H：512 MiB 五轮 A/B 中单批 D2H 8.522→2.669 ms（-68.7%），
  最大吞吐 1822.98→4895.29 MiB/s（+168.5%）。
- [x] 增加压缩耗时并计算读取摊销：所有已测 COMPRESSED 读取慢于 Baseline，
  当前不存在正的性能 break-even，见 `results/final/break_even.csv`。
- [!] 文件大小 × 可压缩率 × 并发数的正向 break-even 图：当前没有交叉点，
  不能制造图形；等读路径快于 Baseline 后再绘制。

### G. 真实 workload

- [x] 已增加 Project Gutenberg #2600 公开真实文本，记录固定下载 URL、目录页、
  许可证页、版本日期、字节数和 SHA-256，并完成五轮空间、压缩及 cold/warm 读取。
- [x] 真实 dpkg status + Bash ELF 扫描已在 V100 完成五轮，业务 hash、marker、
  吞吐、完整扫描 p99、CPU cores 和 CI 已保存；CPU/GPU 性能 CI 重叠，不能
  包装为 GPU 加速。
- [x] 不再把 `/dev/urandom` 文件称为 ImageNet 风格 workload；相关旧结果已从核心报告移除。
- [x] ccache、小文件和旧日志结果未达到当前方法学要求，已从核心报告/PPT移除；
  若后续恢复，必须分开 cold/warm 并重新五轮测试。
- [x] btrfs zstd 已产生正式五轮数字并完成 extent 验证；报告只将其用于空间
  效率与暖缓存架构差距，不称为 NVMe 或冷缓存性能。

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

## 最后阶段：团队自行完成的 PPT 与视频

> 按团队要求，PPT 和视频不由 Codex 修改。技术材料提供以下事实边界供团队引用：

- 固定吞吐下主机 CPU 成本约降低 28.8%，SQLite QPS +7.3%、p99 -50.5%；
- PCM 总 DRAM bandwidth 约降低 47.75%，但 RSS 未降低且 D2H 写回仍存在；
- LZ4 随机读相对旧实现提高 4.19–4.90 倍，但仍远慢于普通文件 Baseline；
- 当前是 LD_PRELOAD 用户态、只读压缩归档原型，不是 DM/Btrfs/ZFS 或生产级实现；
- V100 证明兼容旧 GPU，但不等于完成赛题指定 RTX 或鲲鹏平台；
- PPT/视频中的所有命令应只使用已验证且可现场复现的路径。
