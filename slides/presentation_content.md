# GPUC 项目答辩 PPT 内容脚本

> 本文件为 PPT 制作提供逐页内容、配图建议与实验数据。可直接据此生成 `.pptx` 或 PDF。
> 演讲时长建议：10–12 分钟

---

## 第 1 页：封面

**标题**：基于 GPU 的服务资源卸载技术探索 — 透明存储压缩卸载系统 GPUC

**副标题**：
- 2026 全国大学生计算机系统能力大赛 — OS 功能挑战赛道
- 西安交通大学 · 404notfound
- 指导老师：[可填写]

**视觉建议**：深色科技风背景，放项目 logo 或架构简图。

---

## 第 2 页：项目背景与问题

**标题**：为什么需要 GPU 存储压缩卸载？

**要点**：
1. 大数据、日志、数据库、编译缓存等场景中，磁盘 I/O 是瓶颈。
2. 存储压缩可减少磁盘占用、提升有效读带宽，但传统方案存在局限：
   - 文件系统内置压缩（btrfs/zstd）：需格式化迁移，侵入性强。
   - 应用层压缩：需修改业务代码，无法通用。
   - FUSE/device-mapper/内核模块：部署复杂或风险高。
3. GPU 具有高并行、高内存带宽，适合解压任务卸载。

**关键问题**：如何在**不修改内核、文件系统、应用**的前提下，透明地把存储压缩/解压卸载到 GPU？

---

## 第 3 页：核心思路

**标题**：非侵入式透明 GPU 压缩卸载

**方案**：
- `LD_PRELOAD` 用户态拦截层
- 写路径只写 RAW，后台 Daemon 异步 GPU 压缩
- 读路径对压缩文件自动 GPU 批量解压

**三大组件**：
1. `libgpuhook.so`：拦截 25+ POSIX 调用
2. `gpu_compress_daemon`：离线 GPU 压缩守护进程
3. ext4/xfs：完全不改

**配图**：`docs/architecture.png` 或 `docs/architecture.svg`

---

## 第 4 页：GPUC 文件格式

**标题**：自描述的 GPUC 压缩文件格式

**结构**：
- Header（56 B）：magic、version、orig_size、state、comp_algo、header_size、mtime、ctime
- Block Index Table：`num_blocks × 24 B`
- 压缩数据：紧凑格式存储，稀疏文件空洞保持 128 KB 逻辑对齐

**状态机**：
- RAW → Daemon 压缩 → COMPRESSED / INLINE
- 低可压缩率文件保持 RAW

**配图**：可手绘 Header + Block Table + 数据布局示意图

---

## 第 5 页：系统架构与数据流

**标题**：系统架构与三条核心路径

**写路径**：
应用 `write()` → Hook 附加 RAW header → 物理写入 → Daemon 后台压缩

**读路径**：
应用 `read()` → Hook 读取 header → 查 block table → GPU batch 解压 → 返回原始数据

**mmap 路径**：
应用 `mmap()` → 分配匿名内存 → 同步预加载 16 MB + 后台异步解压 → 立即返回地址

**配图**：`docs/architecture.png`

---

## 第 6 页：SGLZ 压缩算法

**标题**：自研 SGLZ 压缩算法

**设计**：
- 128 KB block = 32 × 4 KB chunks
- 每 chunk 独立 LZ77 压缩/解压
- 3-byte hash，256 槽位，滑动窗口 2048 B
- 不可压缩 chunk 用 `0xFFFF` 标记 fallback

**优势**：
- 不依赖闭源 nvCOMP，体现 GPU 通用算力
- 对高重复数据压缩率极好

**数据**：
- 全零数据压缩率：**3.2%**
- 可压缩重复模式压缩率：**3.2%**

---

## 第 7 页：可插拔后端 — nvCOMP LZ4

**标题**：可选 NVIDIA nvCOMP LZ4 后端

**切换方式**：
```bash
GPUC_ALGO=lz4 ./bin/gpu_compress_daemon <dir>
```

**效果对比（Linux headers，~35.7 MB）**：

| 方案 | 压缩率 | 128k 顺序读带宽 |
|---|---|---|
| GPUC (SGLZ) | 82.5% | 279 MB/s |
| GPUC (LZ4) | **38.6%** | **581 MB/s** |

**结论**：
- 文本类数据压缩率提升 **53.2%**（相对 SGLZ）
- 读带宽同时翻倍，实现“压缩率更高、读带宽更高”的双赢
- Hook 读取时根据 `comp_algo` 自动选择解压路径

---

## 第 8 页：核心优化体系

**标题**：从 267 MB/s 到 4889 MB/s 的性能优化

**关键优化**：

| 优化项 | 解决问题 | 效果 |
|---|---|---|
| 16 CUDA Stream + TLS | 32 线程竞争单 Stream | 消除同步瓶颈 |
| Device Memory Pool | 逐块 cudaMalloc/Free | 零动态分配开销 |
| io_uring 批量 pread | syscall 开销高 | 减少系统调用次数 |
| 自适应 Read-Ahead | 小 bs 无法形成 batch | 动态窗口 0→4→8→16 blocks |
| Pinned Memory | driver 中转 memcpy | 消除冗余拷贝 |
| Compact Kernel | CPU 侧紧凑格式展开 | 消除 CPU memcpy |
| mmap 按需解压 | 全量预解压阻塞 mmap() | 返回时间 2414 ms → 231 ms |

---

## 第 9 页：关键性能数据 — 顺序读

**标题**：fio 顺序读 128k（512 MB，page cache 命中）

**数据表**：

| 场景 | zero | rand | rep |
|---|---|---|---|
| Baseline | 450.9 MB/s | 448.0 MB/s | 451.5 MB/s |
| Hook RAW | 451.7 MB/s | 443.0 MB/s | 447.2 MB/s |
| GPU Compressed | **458.3 MB/s** | 433.0 MB/s | 442.4 MB/s |

**结论**：
- GPU Compressed 与 Baseline 基本持平
- GPU 解压 overhead 已被完全摊销

---

## 第 10 页：关键性能数据 — 高并发扩展性

**标题**：jobs=32 高并发下恢复至 Baseline 的 99.8%

**问题**：早期 jobs=32 时 GPUC 骤降至 267 MB/s

**优化后（direct=1）**：

| 数据 | bs | Baseline | GPUC | 比例 |
|---|---|---|---|---|
| zero | 128k | 4900.2 MB/s | **4889.1 MB/s** | **99.8%** |
| zero | 1M | 414.3 MB/s | **412.9 MB/s** | **99.7%** |
| rand | 128k | 396.6 MB/s | **395.8 MB/s** | **99.8%** |
| rand | 1M | 435.2 MB/s | **425.2 MB/s** | **97.7%** |

**配图**：`docs/figures/multithread_scalability.png`

---

## 第 11 页：mmap 与压缩率

**标题**：mmap 按需解压与压缩效果

**mmap 优化效果**：

| 文件大小 | 优化前 | 优化后 | 提升 |
|---|---|---|---|
| 64 MB | 420.9 ms | 226.3 ms | 1.9x |
| 256 MB | 1263.3 ms | 229.8 ms | 5.5x |
| 512 MB | 2414.5 ms | **231.4 ms** | **10.4x** |

**压缩率**：

| 数据类型 | SGLZ | LZ4 |
|---|---|---|
| 全零数据 | **3.2%** | **3.2%** |
| Linux headers | 82.5% | **38.6%** |
| 混合数据 | 53.1% | — |
| 随机数据 | 100% (fallback) | 100% (fallback) |

**配图**：`docs/figures/mmap_size_sweep.png`

---

## 第 12 页：真实 Workload 评估

**标题**：数据库、编译缓存、ML 数据加载

**结果**：

| Workload | 关键指标 | 状态 |
|---|---|---|
| SQLite | 建表/插入/SELECT | **PASS**（白名单修复后） |
| LevelDB | fillseq/readseq/readrandom | **PASS**（白名单修复后） |
| ccache cold compile | Hook/Baseline = 86.4% | 可接受 |
| ccache hot compile | Hook/Baseline = 79.7% | 可接受 |
| ML 小文件加载 | Hook/Baseline = 15–17% | 大量小文件 overhead 大 |

**关键修复**：
- 数据库文件白名单：`.db`、`.wal`、`.log`、`.ldb`、`.sst`、`CURRENT`、`MANIFEST-*`
- 避免 56 B RAW header 破坏数据库 magic

---

## 第 13 页：生产级指标与稳定性

**标题**：尾延迟、容错与长期稳定性

**尾延迟（randread 128k）**：
- p99：**457 µs**
- p999：**578 µs**
- IOPS：**~3355**
- 均低于 Baseline

**容错边界测试（5 项全 PASS）**：
- Daemon 压缩时应用并发读/写
- GPU 显存不足自动 fallback CPU
- 磁盘空间不足正确返回 ENOSPC
- kill -9 后文件一致性
- fsync 语义正确

**长期稳定性**：
- 连续读取 1 GB 压缩文件 30 分钟
- 带宽稳定 159.2 MB/s，零 CRC32 错误

---

## 第 14 页：与现有方案对比

**标题**：GPUC 与 btrfs zstd / 用户态压缩对比

**对比表**：

| 维度 | btrfs zstd | 应用层压缩 | GPUC（本方案） |
|---|---|---|---|
| 侵入性 | 高 | 高 | 无 |
| 部署难度 | 中 | 高 | 低 |
| 性能上限 | 高（内核态） | 取决于实现 | 中（用户态+GPU） |
| GPU 卸载 | 否 | 可选 | 是 |
| 适用场景 | 新建系统 | 特定应用 | 现有系统透明叠加 |

**结论**：
- 内核态方案性能最优但侵入性强
- GPUC 以部署灵活性为核心价值，适合无法改造底层存储的环境

---

## 第 15 页：创新点

**标题**：项目创新点

1. **非侵入式 GPU 存储压缩卸载**：通过 `LD_PRELOAD` 实现透明 GPU 压缩/解压，无需改内核/文件系统/应用。
2. **自研 SGLZ CUDA 算法**：不依赖 nvCOMP，体现 GPU 通用算力，高重复数据压缩率达 3.2%。
3. **完整性能优化体系**：16-stream、内存池、io_uring、read-ahead、紧凑 kernel，jobs=32 恢复至 Baseline 99.8%。
4. **mmap 按需解压**：同步 16 MB + 后台异步解压，512 MB 文件 mmap 返回时间从 2414 ms 降至 231 ms。
5. **可插拔双后端**：SGLZ 与 nvCOMP LZ4 共存，兼顾自主知识产权与真实数据压缩率。
6. **自适应高可用**：GPU 高负载、显存不足、低可压缩率等场景自动降级，保证鲁棒性。
7. **完整工程化测试体系**：17+ 自动化测试脚本覆盖性能、稳定性、容错、真实 workload。

---

## 第 16 页：团队分工

**标题**：团队分工与协作

| 角色 | 职责 | 成员 |
|---|---|---|
| 队长 / 系统架构 | 整体架构、Hook 与 Daemon 设计、项目整合 | 朱嘉乐 |
| GPU 后端开发 | SGLZ CUDA kernel、nvCOMP LZ4 后端集成 | [队员 B] |
| 存储与 I/O 优化 | io_uring、内存池、read-ahead、mmap 优化 | [队员 C] |
| 测试与评测 | fio 基准、消融实验、稳定性与边界测试 | [队员 D] |
| 文档与答辩材料 | README、开发文档、PPT、演示视频 | [队员 E] |

**说明**：请根据实际情况填写成员姓名。

---

## 第 17 页：开发时间线

**标题**：项目开发时间线

| 阶段 | 时间 | 关键产出 |
|---|---|---|
| 立项与调研 | 2026-05-05 | 项目架构方案、README 初稿 |
| 核心系统 | 2026-06-09 | LD_PRELOAD Hook + GPU Daemon + SGLZ 压缩 |
| 全面评测 | 2026-06-10 | 消融实验、Batch Size 扫描、P1/P2 workload |
| 性能优化 | 2026-06-11 | 多 CUDA Stream、mmap 按需解压（10.4x） |
| 生产验证 | 2026-06-12 ~ 06-16 | 真实负载、DB 白名单、自适应降级、稳定性 |
| 最终集成 | 2026-06-17 | 集成 NVIDIA nvCOMP LZ4 GPU 后端 |
| 文档整理 | 2026-06-26 | 补齐设计方案开发文档 |

**git 提交**：当前 20+ 次提交，完整记录迭代过程。

---

## 第 18 页：合规声明

**标题**：开源协议与合规声明

- 源代码许可证：**Apache-2.0**（`LICENSE`）
- 文档/答辩材料许可证：**CC BY-SA 4.0**（`LICENSE-docs`）
- 第三方依赖说明：`docs/THIRD_PARTY.md`
- AI 工具使用声明：`docs/AI_TOOL_DECLARATION.md`
- 项目为原创，未基于往届作品或开源项目

**说明**：本页用于满足大赛对开源协议、引用来源、AI 工具声明的要求。

---

## 第 19 页：复现方式

**标题**：一键复现

```bash
# 环境检查
bash scripts/check_env.sh

# 编译
make clean && make all

# 运行测试
make test

# 一键 DEMO
bash scripts/demo.sh

# 性能基准
bash tests/benchmark_fio.sh

# LZ4 后端
bash tests/nvcomp_lz4.sh
```

---

## 第 20 页：总结与展望

**标题**：总结与未来展望

**总结**：
1. 通过 `LD_PRELOAD` 实现了非侵入式 GPU 存储压缩卸载。
2. 多 CUDA Stream、内存池、io_uring、read-ahead 等优化使读性能达到 Baseline 水平。
3. nvCOMP LZ4 后端将文本类数据压缩率从 82.5% 降至 38.6%，读带宽提升至 581 MB/s。
4. 具备 CPU fallback、CRC32、原子替换、并发安全等生产级基础。

**未来方向**：
- CUDA Graph 固化 kernel 启动
- `userfaultfd` 页级 mmap 按需解压
- 写路径实时 GPU 压缩
- per-fd 多 block LRU cache

**致谢**：感谢大赛组委会、指导老师、开源社区。

---

## 配图清单

| 页面 | 建议图片 | 文件路径 |
|---|---|---|
| 第 3、5 页 | 系统架构图 | `docs/architecture.png` / `docs/architecture.svg` |
| 第 4 页 | GPUC 文件格式示意图 | 手绘或基于 `include/file_header.h` 制作 |
| 第 10 页 | 多线程扩展性 | `docs/figures/multithread_scalability.png` |
| 第 11 页 | mmap 大小扫描 | `docs/figures/mmap_size_sweep.png` |
| 第 12 页 | 小 bs 随机读 | `docs/figures/random_read_small_bs.png`（可选） |
| 第 13 页 | 显存压力扫描 | `docs/figures/mem_pressure_scan.png`（可选） |
| 第 15 页 | 消融实验 | `docs/figures/ablation_study.png`（可选） |

---

## 演讲建议

1. **第 1–3 页**（2 分钟）：背景 + 核心思路，快速建立认知。
2. **第 4–7 页**（3 分钟）：文件格式、架构、算法、双后端，体现技术深度。
3. **第 8–13 页**（4 分钟）：优化 + 实验数据，重点讲 jobs=32 优化和 mmap 10.4x。
4. **第 14–20 页**（2 分钟）：对比、创新点、分工、合规、总结。

> 注意：PPT 中所有数据均来自 `实验结果报告.md`，环境为 Tesla V100-SXM2-32GB、CUDA 12.8、ext4。
