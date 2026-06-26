% GPU 存储压缩卸载
% 西安交通大学 · 404notfound
% 2026 全国大学生计算机系统能力大赛 — OS 功能挑战赛道

---

## 项目目标

在不修改内核、不改动现有文件系统的前提下，通过 `LD_PRELOAD` 用户态透明拦截层实现 GPU offload 存储压缩：

- **写路径**：应用透明写入，后台 Daemon 异步 GPU 压缩
- **读路径**：压缩文件自动 GPU 实时解压，用户无感知
- **mmap 路径**：支持 `mmap/munmap/msync` 透明映射
- **可插拔后端**：默认 SGLZ，可选 `GPUC_ALGO=lz4` 启用 NVIDIA nvCOMP LZ4
- **高可用**：GPU 失败时自动 fallback 到 CPU

---

## 系统架构

```
应用 (fio, cp, dd, 数据库...)
    │
    ▼
LD_PRELOAD Hook (libgpuhook.so)
    ├─ open/write/close
    ├─ read/pread64 → RAW 透传 / COMPRESSED 自动解压
    ├─ mmap/munmap/msync
    └─ fstat → 报告逻辑大小
    │
    ▼
Offline Daemon (gpu_compress_daemon)
    ├─ SGLZ（自定义 CUDA）
    ├─ LZ4（NVIDIA nvCOMP，可选）
    └─ atomic rename 替换
    │
    ▼
ext4 / xfs（无需改动）
```

---

## GPUC 文件格式

| 字段 | 说明 |
|------|------|
| Magic | `0x47505543` ("GPUC") |
| block_size | 固定 128 KB |
| state | RAW / COMPRESSED / INLINE / BUSY |
| comp_algo | NONE / SGLZ / LZ4 / Snappy |
| 布局 | Header (56 B) + Block Index Table + 稀疏对齐数据 |

- 压缩后不足 128 KB 的块用 `lseek` 留空洞，保持逻辑对齐
- Daemon 使用 `rename()` 原子替换，保证文件始终可用

---

## 核心优化

| 优化项 | 效果 |
|--------|------|
| Batch GPU Decompress | 一次处理 16 blocks，消除 cudaMalloc/Free |
| Device Memory Pool | 512MB 连续读从 ~40 MB/s → **495 MB/s** |
| Pinned Memory | batch decompress 达 **1595 MB/s** |
| io_uring 批量 pread | 减少 syscall 次数 |
| 自适应 Read-Ahead | 顺序检测，动态窗口 0→4→8→16 blocks |
| CPU Fallback | GPU 不可用时自动切换，数据一致 |

---

## 新增：nvCOMP LZ4 后端

- `GPUC_ALGO=lz4 ./bin/gpu_compress_daemon <dir>`
- Hook 读取时根据 `comp_algo` 自动选择 SGLZ / LZ4 解压
- CPU fallback 基于 liblz4

### Linux headers（~35.7 MB）对比

| 方案 | 压缩率 | 128k 顺序读带宽 |
|------|--------|----------------|
| GPUC (SGLZ) | **82.5%** | **279 MB/s** |
| GPUC (LZ4) | **38.6%** | **581 MB/s** |

压缩率提升 **53.2%**（相对 SGLZ），读带宽同时翻倍。

---

## 关键性能数据

### fio 顺序读 128k（512 MB，page cache 命中）

| 场景 | zero | rand | rep |
|------|------|------|-----|
| Baseline | 450.9 MB/s | 448.0 MB/s | 451.5 MB/s |
| Hook RAW | 451.7 MB/s | 443.0 MB/s | 447.2 MB/s |
| GPU Compressed | **458.3 MB/s** | **433.0 MB/s** | **442.4 MB/s** |

### 多线程并发读取（zero, 128KB）

| jobs | Baseline | GPU Compressed | 扩展比 |
|------|---------|---------------|--------|
| 1 | 456.3 | 466.3 | 1.00x |
| 16 | 3768.1 | **3797.7** | **8.14x** |

---

## 压缩率

| 数据类型 | SGLZ | LZ4 |
|---------|------|-----|
| 全零数据 | **3.2%** | **3.2%** |
| Linux headers | 82.5% | **38.6%** |
| 混合数据 | 53.1% | — |
| 随机数据 | 100% (fallback) | 100% (fallback) |

---

## 高可用与一致性

- **CRC32 校验**：每 block 压缩前计算，Hook 解压后验证
- **CPU Fallback**：`CUDA_VISIBLE_DEVICES=""` 仍可正常运行
- **原子替换**：temp file + `rename()`，避免半完成文件
- **flock 并发安全**：文件被占用时 Daemon 自动跳过
- **白名单机制**：数据库文件不附加 GPUC header，避免兼容性问题

---

## 团队分工

| 角色 | 职责 | 联系人 |
|------|------|--------|
| 队长 / 系统架构 | 整体架构、Hook 与 Daemon 设计、项目整合 | 朱嘉乐 <zhujiale@email.cn> |
| GPU 后端开发 | SGLZ CUDA kernel、nvCOMP LZ4 后端集成 | 队员 B |
| 存储与 I/O 优化 | io_uring、内存池、read-ahead、mmap 优化 | 队员 C |
| 测试与评测 | fio 基准、消融实验、稳定性与边界测试 | 队员 D |
| 文档与答辩材料 | README、部署文档、PPT、演示视频 | 队员 E |

队伍：**404notfound** · 西安交通大学 · 2026 全国大学生计算机系统能力大赛

---

## 时间安排

| 阶段 | 时间 | 关键产出 |
|------|------|----------|
| 立项与调研 | 2026-05-05 | 项目架构方案、README 初稿 |
| 核心系统 | 2026-06-09 | LD_PRELOAD Hook + GPU Daemon + SGLZ 压缩 |
| 全面评测 | 2026-06-10 | 消融实验、Batch Size 扫描、P1/P2 workload、图表 |
| 性能优化 | 2026-06-11 | 多 CUDA Stream、CRC32 跳过、mmap 按需分页（10.4x） |
| 生产验证 | 2026-06-12 ~ 06-16 | 真实负载、可压缩率梯度、DB 白名单、自适应降级、稳定性 |
| 最终集成 | 2026-06-17 | 集成 NVIDIA nvCOMP LZ4 GPU 后端 |

---

## 创新点 / 增量贡献

本项目代码均为团队原创开发，未基于任何往届作品或开源项目二次开发：

1. **自研 GPUC 文件格式**（`include/file_header.h`）— 含 magic、block table、CRC32、状态机、多算法标记
2. **自研 SGLZ GPU 压缩/解压内核**（`src/gpu_compress.cu`, `src/cpu_compress.c`）— CUDA 实现
3. **自研 LD_PRELOAD 透明拦截层**（`src/hook.c`）— 25+ 系统调用转发，包括 open/write/read/mmap/fstat/xstat/fallocate/ftruncate
4. **自研离线压缩 Daemon**（`src/daemon.c`, `src/cpu_daemon.c`）— 原子 rename、block 索引、CRC32、自适应 fallback
5. **自集成 nvCOMP LZ4 可插拔后端**（`src/gpu_lz4.cu`, `src/cpu_lz4.c`, `GPUC_ALGO=lz4`）— NVIDIA nvCOMP 4.2.0.11
6. **全自主测试体系与文档** — 测试脚本、基准、消融实验报告、架构文档、答辩材料

---

## 合规声明

- 源代码许可证：**Apache-2.0**（`LICENSE`）
- 文档/答辩材料许可证：**CC BY-SA 4.0**（`LICENSE-docs`）
- 第三方依赖说明：`docs/THIRD_PARTY.md`
- AI 工具使用声明：`docs/AI_TOOL_DECLARATION.md`
- 项目为原创，未基于往届作品或开源项目

---

## 复现方式

```bash
bash scripts/check_env.sh
make clean && make all
make test
bash tests/nvcomp_lz4.sh      # LZ4 后端验证
bash tests/benchmark_fio.sh   # 性能基准
bash scripts/demo.sh          # 一键演示
```

---

## 总结

1. 通过 `LD_PRELOAD` 实现了非侵入式 GPU 存储压缩卸载
2. 多 CUDA Stream、内存池、io_uring、read-ahead 等优化使读性能达到 Baseline 水平
3. 新增 nvCOMP LZ4 后端，文本类数据压缩率从 82.5% 降至 38.6%，读带宽提升至 581 MB/s
4. 具备 CPU fallback、CRC32、原子替换、并发安全等生产级基础
