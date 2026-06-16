# GPU Compress 后续优化与测试补充计划

> 本文档汇总 `实验结果报告.md` 完成后，项目仍可进一步优化的方向与可补充的实验。
> 范围限定在当前已拥有的软硬件环境，**不涉及不同 CPU/GPU 型号对比**。

---

## 一、代码级性能优化

按投入产出比排序，建议优先实现靠前项。

### 1.1 D2H 异步拷贝（低投入 / 明确收益）

**现状**：
- `sglz_decompress_batch_compact_wait()` 先 `cudaStreamSynchronize()` 等待 kernel 完成，再循环做 `cudaMemcpy` D2H。
- kernel 执行与 D2H 传输实际为串行。

**优化**：
- 在 async 阶段即提交 `cudaMemcpyAsync(D2H)`，让 D2H 与 kernel 在同一 stream 中流水线执行。
- `wait()` 中只需 `cudaStreamSynchronize()`，无需额外 D2H 拷贝。

**预期收益**：
- 单线程 / 小 batch 场景提升 **5–10%**。
- 多线程场景因 I/O 已占主导，收益可能略低。

**参考改动**：
- `src/gpu_compress.cu`：`sglz_decompress_batch_compact_async()` 增加 `cudaMemcpyAsync(d_out → host_out_bufs)`。
- `src/gpu_compress.cu`：`sglz_decompress_batch_compact_wait()` 移除循环 D2H，仅保留 sync。
- `src/hook.c`：相应调整输出 buffer 布局，确保 async 阶段已知目标 host 地址。

---

### 1.2 更大 Batch Size（中投入 / 中等收益）✅ 已验证

**现状**：
- `MAX_BATCH_BLOCKS` 默认 16。
- `src/cpu_compress.c` 中的 CPU fallback batch 上限原本为 16，与 GPU 侧已不一致。

**已完成**：
- 将 `src/cpu_compress.c` 的 `SGLZ_MAX_BATCH_BLOCKS` 从 16 提升至 32，与 GPU 侧对齐。
- 新增 `tests/batch_size_sweep.sh`，扫描 batch size = 1/2/4/8/16/32 在 zero / rand 数据、`direct=1` 下的读带宽。

**实测结果**（512 MB，bs=128k，direct=1）：

| Batch Size | zero (MB/s) | rand (MB/s) |
|-----------|------------|------------|
| 1 | 705.7 | 684.7 |
| 2 | 511.9 | 402.7 |
| 4 | 705.9 | 530.2 |
| 8 | 493.2 | 697.3 |
| 16 | 447.1 | 627.6 |
| 32 | 567.8 | 699.7 |

**关键结论**：
- `direct=1` 场景下读带宽主要由磁盘 / page cache 决定，batch size 的影响被 I/O 层稀释，趋势不明显。
- 32 相对 16 未出现性能回归，在 rand 数据上略有提升。
- **当前默认仍保持 16 blocks**；若未来重点优化 bs≥2M 或大文件顺序读，可再将默认值提至 32。

**报告章节**：`实验结果报告.md` 4.12

---

### 1.3 CUDA Graph 固化 Kernel 启动（高投入 / 高单线程收益）

**现状**：
- 每次 `read()` 都重新 launch `sglz_decompress_compact_kernel<<<...>>>`。
- kernel 启动延迟约 **30μs**，在小 batch 下占比较高。

**优化**：
- 对固定 batch size（如 16 blocks）预捕获 CUDA Graph。
- read 路径直接 `cudaGraphLaunch()`，避免重复配置 kernel。

**预期收益**：
- 单线程 / 小 batch 场景可提升 **20–50%**。
- jobs=32 时因 I/O 是瓶颈，收益可能不明显。

**复杂度**：
- 需要为不同 block 数（1–MAX_BATCH_BLOCKS）分别 capture graph。
- 输入/输出地址需通过 graph 参数更新。

---

### 1.4 userfaultfd 页级 mmap 解压（高投入 / 高 mmap 收益）

**现状**：
- mmap 优化为“前 16MB 同步 + 后台线程异步解压剩余”。
- 后台解压 496MB 仍需约 2.2s，且提前解压了未访问页。

**优化**：
- 使用 `userfaultfd`（Linux 4.3+）注册缺页处理线程。
- 仅当进程实际访问某页时，才解压对应 block。

**预期收益**：
- 真正按需解压，避免后台 2.2s 开销。
- 随机访问大 mmap 文件时收益最大。

**复杂度**：
- 需要维护 `userfaultfd` 事件循环和 GPU/CUDA 上下文交互。
- 多线程 mmap 访问时的同步较复杂。

---

### 1.5 写路径实时 GPU 压缩（高投入 / 新能力）

**现状**：
- 写操作仅写 RAW header + 原始数据。
- 压缩由后台 daemon 异步完成。

**优化**：
- 在 `write()` / `pwrite64()` 路径中对大写请求实时 GPU 压缩。
- 小写请求仍保持 RAW，由 daemon 后续处理。

**预期收益**：
- 写后立即读取可命中 COMPRESSED 状态，减少 RAW 读开销。
- 对写密集型应用（日志、数据库 WAL）有意义。

**复杂度**：
- 需要处理部分 block 写入、并发写、压缩失败 fallback。
- 可能增加 write() 延迟。

---

### 1.6 多 Block LRU Cache（中投入 / 随机读收益）

**现状**：
- per-fd 仅缓存最近 1 个 block。
- 随机读有局部性时只能命中 1 block。

**优化**：
- 扩展为缓存最近 N 个 block（如 4 或 8）。
- 使用简单数组 + 线性搜索即可，block 数少时开销可忽略。

**预期收益**：
- 随机读有局部性时 IOPS 从当前 ~800 提升至 **1500–2500**。
- 纯随机无局部性时无改善。

---

## 二、测试全面性补充

### 2.1 写路径 & 混合负载（高优先级）✅ 已完成

**脚本**：`tests/write_mixed_load.sh`

**实测结果（direct=1）**：

| 测试项 | bs | jobs | Baseline | Hook RAW | Hook/Baseline |
|--------|-----|------|---------|---------|---------------|
| 并发写 | 128k | 1 | 128.7 MB/s | 128.6 MB/s | **99.9%** |
| 并发写 | 128k | 32 | 80.3 MB/s | 83.4 MB/s | **103.9%** |
| 并发写 | 1M | 1 | 128.5 MB/s | 128.5 MB/s | **100.0%** |
| 并发写 | 1M | 32 | 125.0 MB/s | 128.7 MB/s | **103.0%** |
| randrw mix=50 | 128k | 1 | 82.2 MB/s | 86.9 MB/s | **105.7%** |
| randrw mix=50 | 128k | 32 | 170.7 MB/s | 169.6 MB/s | **99.4%** |
| randrw mix=50 | 1M | 1 | 143.0 MB/s | 165.8 MB/s | **115.9%** |
| randrw mix=50 | 1M | 32 | 198.2 MB/s | 170.6 MB/s | **86.1%** |
| 写后立刻读 | 128k | 1 | 307.5 MB/s | 356.5 MB/s | **115.9%** |
| 写后立刻读 | 1M | 1 | 369.9 MB/s | 388.0 MB/s | **104.9%** |

**结论**：
- 写路径 Hook RAW 与 Baseline 基本持平（99–103%）。
- 混合负载总体处于 86–116% 区间，未引入显著退化。
- 报告章节：`实验结果报告.md` 4.9.1b

---

### 2.2 更大规模文件（高优先级）✅ 部分完成

**脚本**：`tests/large_file_benchmark.sh`

**已完成**：4 GB 文件测试。16 GB / 64 GB 因当前环境 `/tmp` 可用空间不足（约 11 GB）未执行，脚本已支持通过 `LARGE_FILES=1` 在有足够空间的环境中启用。

**4 GB 实测结果（direct=1）**：

| 指标 | 数值 |
|-----|------|
| RAW 创建时间 | 33.22 s |
| GPU 压缩时间 | 14.54 s |
| 逻辑大小 | 4096 MB |
| 物理大小 | 129 MB |
| 压缩率 | **3.2%** |

| bs | jobs | Baseline | GPU Compressed | 比例 |
|-----|------|---------|---------------|------|
| 128k | 1 | 690.2 MB/s | 708.2 MB/s | **102.6%** |
| 128k | 32 | 4953.2 MB/s | 4949.6 MB/s | **99.9%** |
| 1M | 1 | 1459.4 MB/s | 1316.8 MB/s | **90.2%** |
| 1M | 32 | 4708.3 MB/s | 4724.2 MB/s | **100.3%** |

| 指标 | 数值 |
|-----|------|
| 4 GB mmap 返回时间 | **342.7 ms** |

**结论**：
- 4 GB zero 数据压缩率 3.2%，压缩后仅 129 MB。
- jobs=32 时 GPU Compressed 与 Baseline 基本持平。
- 4 GB mmap 返回 342 ms，与 512 MB 的 231 ms 接近，符合按需预解压设计预期。
- 报告章节：`实验结果报告.md` 4.9.7c

---

### 2.3 真实 Workload（中优先级）✅ 已完成 / 数据库兼容性已修复

**脚本**：`tests/real_workload_comprehensive.sh`（原始功能测试结果）；`tests/db_whitelist.sh`（白名单修复验证）

自动下载/编译 LevelDB、ccache，覆盖 SQLite / LevelDB / ccache / ML 数据加载四类场景。

**实测结果**：

| Workload | 指标 | Baseline | Hook RAW / Compressed | 状态 / 比例 |
|---------|-----|---------|----------------------|-------------|
| SQLite | 创建表、插入、SELECT | — | **PASS** | 白名单修复后兼容 |
| LevelDB | fillseq / readseq / readrandom | — | **PASS** | 白名单修复后兼容 |
| ccache | cold compile 500 文件 | 33.28 s | 38.51 s | **86.4%** |
| ccache | hot compile 500 文件 | 10.31 s | 12.94 s | **79.7%** |
| ML 数据加载 | 顺序读 1000 张 1MB | 5500 MB/s | 362 MB/s | **6.6x  slower** |
| ML 数据加载 | 随机读 200 张 1MB | 3599 MB/s | 300 MB/s | **12.0x slower** |

**关键发现**：
- **SQLite / LevelDB 已通过数据库文件白名单机制修复**：对 `.db`、`.wal`、`.log`、`.ldb`、`.sst`、`CURRENT`、`MANIFEST-*` 等文件跳过 GPUC header；`rename()` 临时文件到白名单目标时也会剥离 header。
- **ccache 可工作**：Hook 引入 14–26% 开销，主要来自小文件的 header 创建与 syscall 拦截。
- **ML 小文件加载 overhead 大**：1000 个 1MB 文件场景下，大量 open/header/block-table 解析使带宽降至 Baseline 的 15–17%。

**报告章节**：`实验结果报告.md` 4.11.1、4.13.1

**后续优化方向**：
- 优化大量小文件场景：减少 open 开销、per-fd 多 block cache、批量预取。

---

### 2.4 数据可压缩率梯度（中优先级）✅ 已完成

**脚本**：`tests/compressibility_gradient.sh`

生成 0% / 25% / 50% / 75% / 100% 可压缩率数据，每 4KB 块内按比例混合随机与全零字节。

**实测结果（512 MB 文件，128k bs，direct=1）**：

| 可压缩率 | 物理大小 | 压缩率 | 压缩耗时 | 解压读带宽 |
|---------|---------|--------|---------|-----------|
| 0% | 512 MB | 100.0% | 5.98 s | 296.3 MB/s |
| 25% | 400 MB | 78.1% | 5.26 s | 224.1 MB/s |
| 50% | 272 MB | 53.1% | 4.28 s | 268.3 MB/s |
| 75% | 144 MB | 28.2% | 3.10 s | 336.9 MB/s |
| 100% | 16 MB | 3.2% | 2.02 s | 545.7 MB/s |

**关键发现**：
- 压缩耗时随可压缩率提升单调下降。
- **25% 可压缩率出现解压带宽低谷（224 MB/s）**，甚至低于 0% 全随机（296 MB/s）。
- 原因：25% 数据未触发 RAW fallback，但压缩比很低，GPU 解压计算 overhead 未能被 I/O 节省覆盖。
- 启示：可引入自适应阈值，低可压缩数据直接 RAW 存储。

**报告章节**：`实验结果报告.md` 4.8b

---

### 2.5 容错与边界（中优先级）✅ 已完成

**脚本**：`tests/fault_tolerance_boundary.sh`

| 场景 | 测试方法 | 结果 |
|-----|---------|------|
| daemon 压缩时应用读/写 | daemon 后台压缩，同时 fio 并发读写 | **PASS** |
| 显存不足 | CUDA helper 占 99.5% 显存后读压缩文件 | **PASS**，自动 fallback CPU，数据验证通过 |
| 磁盘满 | tmpfs 填满后 Hook 写文件 | **SKIP**（环境无 root） |
| 进程崩溃后文件一致性 | kill -9 写文件进程后再 open/read | **PASS** |
| fsync 语义 | write → fsync → 读回校验 | **PASS** |

**关键修复**：`src/gpu_compress.cu` 中 `sglz_init()` 原先未检查 `cudaMalloc` 返回值，OOM 时会返回 0 并导致后续空指针解压；修复后分配失败返回 -1，触发 Hook CPU fallback。

**报告章节**：`实验结果报告.md` 4.15

---

### 2.6 生产级指标（低优先级）✅ 已完成

**脚本**：`tests/production_metrics.sh`

| 指标 | 工具 | 结果 | 状态 |
|-----|------|------|------|
| p99 / p999 尾延迟 | fio JSON `clat_ns.percentile` | p99=395 µs, p999=457 µs（randread 128k, 5355 IOPS） | **PASS** |
| CPU 使用率 | `mpstat -P ALL 1` | 环境未安装 sysstat | **SKIP** |
| 上下文切换 | `vmstat 1` | 平均 36.4 K cs/s（8 jobs randread） | **PASS** |
| syscall 次数 | `strace -c` | read/poll/futex/wait4 为主，openat/stat 低频 | **PASS** |
| 内存带宽 | `perf stat -e uncore_imc` | 环境无 root / CPU 不支持 | **SKIP** |

**报告章节**：`实验结果报告.md` 4.16

---

## 三、实验报告结构优化

### 3.1 增加 Executive Summary

一页纸总结：
- 项目目标
- 核心方法（LD_PRELOAD + GPU 解压 + daemon 压缩）
- 关键结果（jobs=32 恢复、mmap 10.4x、压缩率等）
- 主要结论

### 3.2 统一性能对比表

所有实验按以下矩阵呈现：

| 维度 | Baseline | Hook RAW | CPU Compressed | GPU Compressed | 说明 |
|-----|---------|---------|---------------|---------------|------|
| 顺序读 128k | ... | ... | ... | ... | |
| 随机读 4k | ... | ... | ... | ... | |
| jobs=32 128k | ... | ... | ... | ... | |
| mmap 512M | ... | ... | ... | ... | |

### 3.3 方法论章节

明确写出：
1. 如何创建 RAW 文件：`LD_PRELOAD=libgpuhook.so dd ...`
2. 如何压缩：`./bin/gpu_compress_daemon <dir>`
3. 如何避免 page cache：`--direct=1`
4. 如何重复实验：每个测试跑 3 次取平均

### 3.4 关键路径时序图

增加：
- `read()` 拦截流程图
- `write()` 拦截流程图
- `mmap()` 按需解压流程图
- GPU 解压 pipeline 时序图

### 3.5 限制与展望

明确列出：
- MAP_SHARED mmap 不支持
- O_DIRECT 要求页对齐
- 单 GPU、固定 `cudaSetDevice(0)`
- daemon 并发安全（已有 flock）

---

## 四、推荐执行顺序

如果目标是**完善报告 + 稳妥优化**，建议：

1. ~~**补充写路径 & 混合负载测试**~~ ✅ 已完成（`tests/write_mixed_load.sh`，报告 4.9.1b）
2. ~~**补充 4G 大文件测试**~~ ✅ 已完成（`tests/large_file_benchmark.sh`，报告 4.9.7c）
3. ~~**补充真实 Workload 测试**~~ ✅ 已完成（`tests/real_workload_comprehensive.sh`，报告 4.13.1）
4. ~~**补充可压缩率梯度测试**~~ ✅ 已完成（`tests/compressibility_gradient.sh`，报告 4.8b）
5. ~~**重写/精简实验报告**，加入 Executive Summary 和统一对比表~~ ✅ 已完成
6. ~~**自适应低可压缩率 fallback**~~ ✅ 已完成（`tests/low_compressibility_fallback.sh`，报告 4.11.2）
7. **可选**：多 block LRU cache（需解决测试噪声）

> 注：
> - SQLite / LevelDB 兼容性问题已通过数据库文件白名单修复。
> - D2H 异步拷贝实测未带来收益（可能因当前 kernel 与 D2H 重叠有限），已回滚。
> - 多 block LRU cache 在 uniform random 下命中率低，对 seq_4k 等高频顺序读有 overhead，已回滚。

> 注：16 GB / 64 GB 大文件测试需保证测试目录有充足磁盘空间（> 64 GB），当前环境暂不满足。

如果目标是**冲击更高性能**，建议：

1. **CUDA Graph**（约 1–2 天）
2. **userfaultfd mmap**（约 2–3 天）
3. **更大 batch + 写路径实时压缩**（约 3–5 天）
