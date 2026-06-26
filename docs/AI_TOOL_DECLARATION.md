> 本文件用于满足大赛对 **AI 工具使用说明** 的合规要求。

# AI 工具使用声明

## 1. 使用的大模型 / AI 工具

| 工具名称 | 提供方 | 使用版本/形态 |
|---------|--------|--------------|
| Kimi Code CLI | 月之暗面（Moonshot AI） | 命令行交互式 AI 编程助手 |

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

## 3. 成果说明

AI 工具辅助产生的关键成果包括：

- 完成 **nvCOMP LZ4 GPU 压缩后端** 的端到端集成（压缩 → 存储 → 解压 → 校验）。
- 在 Linux headers 数据集上将压缩率从 SGLZ 的 **82.5%** 降至 LZ4 的 **38.6%**，128k 顺序读带宽从 **279 MB/s** 提升至 **581 MB/s**。
- 新增测试脚本通过全部读写一致性校验。

所有 AI 生成的代码均经过人工审查、编译、测试验证，并纳入本队 git 版本管理。

## 4. 交互记录

主要交互记录保存在 Kimi Code CLI 会话历史中，核心操作包括：

- 代码导读与仓库结构分析；
- 多轮 `nvcompBatchedLZ4CompressAsync` 参数调试；
- `tests/nvcomp_lz4.sh` 的编写与失败项修复；
- 实验数据收集与报告章节更新；
- 根据 `提交要求.md` 进行缺项梳理与合规文件编写。

## 5. 责任声明

本队对使用 AI 工具生成的内容承担最终责任，已全部进行人工核验与功能测试。
任何因 AI 生成内容导致的错误、遗漏或合规问题由本队负责修正。
