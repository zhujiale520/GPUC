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

### 1.2 更大 Batch Size（中投入 / 中等收益）

**现状**：
- `MAX_BATCH_BLOCKS` 默认 16。
- bs=1M 时覆盖 8 blocks，bs=2M 时只能覆盖 8/16，未充分利用。

**优化**：
- 将 `MAX_BATCH_BLOCKS` 提升至 32 或 64。
- 同步增大 io_uring ring depth（`GPUC_IOURING_DEPTH`）、per-fd read-ahead 上限、device 内存池。

**预期收益**：
- bs≥2M 或大文件顺序读时，kernel 启动开销进一步摊销。
- 对 bs=128k/1M 收益有限（read-ahead 已覆盖）。

**注意**：
- 每个线程内存占用会增加约 (batch_size/16)×24 MB，32 线程高并发下需谨慎。

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

### 2.1 写路径 & 混合负载（高优先级）

当前报告以读测试为主，写路径数据不足。

| 补充实验 | 测试命令 | 关注指标 |
|---------|---------|---------|
| 随机读写混合 | `fio --rw=randrw --rwmixread=70` | 带宽、IOPS、延迟 |
| 顺序读写混合 | `fio --rw=rw --rwmixread=50` | 带宽稳定性 |
| 多线程并发写 | `fio --rw=write --numjobs=32` | 写带宽 vs Baseline |
| 写后立刻读 | 自定义脚本：write → fsync → read | fresh data 路径正确性 |

**说明**：
- Hook 写路径仅跳过 header，理论上 overhead 很小，但需数据验证。
- 混合负载可暴露 read-ahead 与 write 之间的缓存一致性问题。

---

### 2.2 更大规模文件（高优先级）

当前最大测试文件为 512MB，难以反映大文件行为。

| 文件大小 | 关注点 |
|---------|--------|
| 4 GB | header + block 表内存占用、mmap 行为 |
| 16 GB | page cache 换出后的真实磁盘 I/O |
| 64 GB | 长时间运行的 GPU 稳定性、显存泄漏 |

**测试项**：
- 顺序读带宽是否随文件大小下降
- mmap 按需解压在 16G/64G 下的返回时间
- block 表（~1.5 MB/GB）对内存的影响

---

### 2.3 真实 Workload（中优先级）

当前 `real_workload_study.sh` 较简单，可替换/补充为：

| Workload | 测试方式 | 价值 |
|---------|---------|------|
| RocksDB / LevelDB | YCSB load + run | 验证数据库场景 |
| SQLite | TPC-C / 导入导出 | 验证事务日志 + 表文件 |
| 编译缓存 (ccache) | 大量小文件读写 | 验证元数据 + inline 路径 |
| ML 数据加载 | ImageNet 风格顺序/随机读 | 验证大文件 + mmap |

**注意**：
- 需要配置 workload 使用 hook 创建的文件目录。
- 重点关注 IOPS 和尾延迟，而非原始压缩率。

---

### 2.4 数据可压缩率梯度（中优先级）

当前 mostly zero / rand / mixed，缺少中间梯度。

| 可压缩率 | 生成方式 | 用途 |
|---------|---------|------|
| 0% | `/dev/urandom` | 最坏情况 |
| 25% | 每 4KB 块中 3KB 随机 + 1KB 零 | 验证 comp_len ≈ 75% 时的性能 |
| 50% | 交替 zero / random chunk | 中点 |
| 75% | 每 4KB 块中 1KB 随机 + 3KB 零 | 常见日志数据 |
| 100% | `/dev/zero` | 最好情况 |

**输出**：
- 压缩率 vs 解压带宽曲线
- 压缩率 vs GPU 利用率曲线

---

### 2.5 容错与边界（中优先级）

| 场景 | 测试方法 | 预期结果 |
|-----|---------|---------|
| daemon 压缩时应用读/写 | 扩展 `daemon_concurrent_safety.sh` | 无数据损坏、无崩溃 |
| 显存不足 | 运行其他 CUDA 程序占满显存后读压缩文件 | 优雅 fallback CPU 或报错 |
| 磁盘满 | fio 写满磁盘后创建文件 | 正确返回 ENOSPC |
| 进程崩溃后文件一致性 | kill -9 测试程序后校验文件 | 数据可恢复或明确损坏 |
| fsync 语义 | write → fsync → 断电模拟 | 数据持久化正确 |

---

### 2.6 生产级指标（低优先级）

| 指标 | 工具 | 用途 |
|-----|------|------|
| p99 / p999 尾延迟 | fio JSON `lat_ns.percentile` | 发现尾延迟问题 |
| CPU 使用率 | `mpstat -P ALL 1` | 量化 hook CPU 开销 |
| 上下文切换 | `vmstat 1` / `pidstat -w 1` | 发现锁竞争 |
| syscall 次数 | `strace -c` | 量化 io_uring 收益 |
| 内存带宽 | `perf stat -e uncore_imc` | 判断内存是否为瓶颈 |

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

1. **实现 D2H 异步拷贝**（约 1 小时，收益确定）
2. **补充写路径 & 混合负载测试**（约 2 小时，完善报告）
3. **补充 4G/16G 大文件测试**（约 2 小时，证明扩展性）
4. **重写/精简实验报告**，加入 Executive Summary 和统一对比表（约 3 小时）
5. **可选**：多 block LRU cache、可压缩率梯度测试

如果目标是**冲击更高性能**，建议：

1. **CUDA Graph**（约 1–2 天）
2. **userfaultfd mmap**（约 2–3 天）
3. **更大 batch + 写路径实时压缩**（约 3–5 天）
