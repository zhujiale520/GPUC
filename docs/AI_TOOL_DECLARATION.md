> 本文件用于满足大赛对 **AI 工具使用说明** 的合规要求。

# AI 工具使用声明

## 1. 使用的大模型 / AI 工具

| 工具名称 | 提供方 | 使用版本/形态 |
|---------|--------|--------------|
| Kimi Code CLI | 月之暗面（Moonshot AI） | 命令行交互式 AI 编程助手 |
| OpenAI Codex | OpenAI | 仓库内交互式代码审查、实验修复与材料整理助手（2026-07-25 至 2026-07-30） |

## 2. 使用场景

在本项目开发与文档整理过程中，Kimi Code CLI 主要用于以下场景：

1. **代码实现辅助**
   - 设计并实现 `src/gpu_lz4.cu`（NVIDIA nvCOMP LZ4 GPU 压缩/解压封装）。
   - 设计并实现 `src/cpu_lz4.c`（基于 liblz4 的 CPU fallback 解压）。
   - 修改 `src/daemon.c` 与 `src/hook.c`，增加 `GPUC_ALGO=lz4` 后端切换与读取路径。
   - 修改 `Makefile` 以链接 nvCOMP 与 liblz4。

2. **调试与问题定位**
   - 定位并修复 `gpu_lz4.cu` 中 `nvcompBatchedLZ4CompressAsync` 因传入栈上指针数组导致的 `nvcompErrorInvalidValue` 问题。
   - 分析 `tests/nvcomp_lz4.sh` 中 `dd`/`cat` 读取差异的原因（Hook 对新写入的普通文件会附加 RAW header）。

3. **测试与验证**
   - 编写 `tests/nvcomp_lz4.sh` 集成测试脚本。
   - 运行 `make test`、`bash tests/nvcomp_lz4.sh` 并迭代修复失败项。

4. **文档整理**
   - 更新 `实验结果报告.md` 中 4.8c、4.13、4.24b 等章节，补充 LZ4 后端实验数据。
   - 根据 `提交要求.md` 梳理缺项，编写 `LICENSE`、`LICENSE-docs`、`docs/THIRD_PARTY.md` 等合规文件。

5. **决赛前可信度审查与修复（OpenAI Codex）**
   - 审查构建脚本、POSIX Hook、Daemon、实验脚本和报告中的实现—表述一致性。
   - 修复 GPU 架构检测、依赖准备、mmap 返回前数据可见性、header 防御性校验、
     `dup` 缓存所有权、`truncate`/写路径边界与 Daemon 元数据保留等问题。
   - 重写高并发和 mmap 核心实验，使不同方案使用独立同内容文件，记录 SHA-256、
     header 状态、物理占用，并输出多次重复的统计量。
   - 在 Tesla V100-SXM2-32GB 上重新编译、运行测试和实验，协助清理与实现不符或
     尚未公平复测的结论。最终数据筛选、比赛表述与提交责任仍由团队成员确认。
   - 修复多线程共享 io_uring/CQE 归属、CUDA stream 重用、白名单原子 rename、
     LZ4 batch read-ahead 和 O_DIRECT 探测等问题。
   - 实现长期 LZ4 GPU worker、持久化 CUDA/pinned buffer、分段 profile、
     4 KiB 对齐 O_DIRECT 格式，并新增同吞吐 CPU/GPU 与 SQLite 业务实验。
   - 补齐 fio 预分配相关 64 位 POSIX 接口，新增随机/写入/尾延迟矩阵、公开
     Gutenberg 数据集、pidstat/sar 原始采样与 V100 板卡 J/GiB 边界实验；
     对缺少权限、许可软件或硬件计数器的项目保留可复核阻塞记录。
   - 实现 userfaultfd mmap 的 128 KiB block 缺页填充与同步回退，补充并发
     pattern 正确性、首次 fault 和完整扫描实验。
   - 增加 Daemon ENOSPC/SIGKILL/重启、GPU 不可见降级、长稳 SHA，以及 GCC
     gcov/CI 覆盖率门槛；统一只读归档模型和 LD_PRELOAD 支持矩阵。
   - 接入用户提供的许可版 Vdbench 5.04.07 与项目私有 Java，修复共享 fd
     COMPRESSED 并发读状态竞争和 `/proc/stat` 伪文件误接管，完成三类 workload、
     4 线程、五轮共 50 个正式样本并整理原始结果与边界。
   - 从 Intel 官方仓库构建 PCM，编写管理员权限下的分场景 DRAM bandwidth
     runner；团队成员执行 sudo 后，核验 Baseline/CPU/GPU 各五轮 IMC 原始数据。
     第一版 16 MiB 方法被识别为可能驻留 LLC，随后改为 512 MiB 轮转工作集和
     稳态区间采样并重新完成五轮。
   - 将资源实验扩展为 512 MiB 轮转工作集和稳态阶段计数，增加进程及继承线程的
     Linux 通用 perf 事件；合并连续 D2H 返回区间并完成五轮开关 A/B。
## 3. 成果说明

AI 工具辅助产生的关键成果包括：

- 完成 **nvCOMP LZ4 GPU 压缩后端** 的端到端集成（压缩 → 存储 → 解压 → 校验）。
- 在本机 Linux headers 固定归档上，LZ4 allocated bytes 约为原始文件的
  **38.1%**，SGLZ 约为 **81.8%**。
- LZ4 Hook 在长期 worker、持久 buffer 和 32-block read-ahead 后，正式五轮
  均值由 **81.0 MiB/s** 提升到 **178.6 MiB/s**；该整体提升不能拆分归因给
  单一优化，且仍远低于普通文件 warm Baseline。
- 新增并发、损坏格式、POSIX 语义、sanitizer、冷缓存、消融、批大小、压缩率梯度
  与 CPU 业务卸载测试。修复后的同吞吐实验显示 GPU 额外主机 CPU 成本降低约
  28.8%，SQLite 相对 CPU 路径 QPS 高约 7.3%、p99 低约 50.5%；结果边界和
  NVMe 与精确型号化 LLC 事件缺口均在报告中保留；通用 cycles/instructions/
  cache 事件已经五轮补齐。512 MiB 稳态 PCM 显示 GPU 总 DRAM bandwidth
  比 CPU 低约 47.75%，同时保留 D2H 写回和 RSS 没有降低的边界。
- userfaultfd 将 256 MiB COMPRESSED 的 `mmap()` 返回降到约 0.215 ms，同时
  单独保留约 147 ms 首次 fault 和约 5.65 s 完整扫描成本；确定性故障恢复五项
  PASS，CPU Hook gcov 行覆盖率为 41.38%。
- Vdbench 三类 workload 的 50/50 样本状态和 SHA-256 校验通过；同时保留
  COMPRESSED 共享 fd 随机读取明显较慢的负面结果，不将页缓存数据解释为 NVMe。
- 512 MiB 稳态 PCM 五轮显示 GPU/CPU 总 DRAM 带宽约为
  4569.51/8745.46 MB/s；材料只主张总 bandwidth 降低约 47.75%，同时明确
  GPU 写带宽约 4.48 GB/s、RSS 高约 8.94%，不扩张为容量节省或消除写回。
- 连续 D2H 合并五轮 A/B 将单批回传由 8.522 ms 降到 2.669 ms，最大吞吐由
  1822.98 MiB/s 提高到 4895.29 MiB/s；完整原始输出和 95% CI 已保存。

AI 辅助内容已完成编译、自动测试和结果交叉核验；最终提交前仍由团队进行人工审查
并决定是否纳入 git 版本管理。

## 4. 交互记录

Kimi Code CLI 的主要交互记录保存在其会话历史中；Codex 本轮操作可由工作区
diff、实验目录及终端日志复核。核心操作包括：

- 代码导读与仓库结构分析；
- 多轮 `nvcompBatchedLZ4CompressAsync` 参数调试；
- `tests/nvcomp_lz4.sh` 的编写与失败项修复；
- 实验数据收集与报告章节更新；
- 根据 `提交要求.md` 进行缺项梳理与合规文件编写。

## 5. 责任声明

本队对使用 AI 工具生成的内容承担最终责任，已全部进行人工核验与功能测试。
任何因 AI 生成内容导致的错误、遗漏或合规问题由本队负责修正。
