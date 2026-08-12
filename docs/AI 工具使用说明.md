# AI 工具使用说明

## 1. 使用的 AI 工具

| 工具 | 使用方式 |
|---|---|
| Kimi Code CLI | 辅助早期代码实现、接口接入和问题定位 |
| OpenAI Codex | 辅助代码审阅、功能完善、测试脚本编写和文档整理 |

AI 工具仅用于研发辅助，不属于 GPUC 的编译依赖或运行时依赖。

## 2. AI 辅助实现的代码

项目开发过程中，AI 工具参与了以下代码的设计、生成或修改：

| 模块 | 主要文件 | AI 辅助完成的内容 |
|---|---|---|
| GPU/CPU 压缩后端 | `src/gpu_compress.cu`、`src/gpu_lz4.cu`、`src/cpu_compress.c`、`src/cpu_lz4.c` | SGLZ 与 nvCOMP LZ4 的压缩、解压和 CPU fallback；Batch 接口、Pinned Buffer、CUDA Stream 及数据传输优化 |
| 透明 I/O Hook | `src/hook.c` | GPUC 文件识别、透明读语义、算法路由、逻辑 offset、并发 fd 管理、CPU/GPU 回退及只读 mmap/userfaultfd 支持 |
| 后台压缩服务 | `src/daemon.c`、`src/cpu_daemon.c` | RAW 文件扫描、离线压缩、状态维护、校验、临时文件写入和原子替换流程 |
| 公共格式与接口 | `include/file_header.h`、`include/gpu_compress_api.h` | 文件头、块索引、算法 ID、校验字段及 CPU/GPU 统一调用接口的补充和一致性检查 |
| 构建与环境检查 | `Makefile`、`scripts/check_env.sh`、`scripts/setup_dependencies.sh` | CUDA 架构检测、依赖链接、CPU-only 构建和环境诊断逻辑 |
| 功能与稳定性测试 | `tests/` 下的集成、并发、mmap、故障恢复和长期稳定性脚本 | 测试流程、结果校验、SHA-256 检查、重复运行和 CSV 汇总逻辑 |
| 性能与资源实验 | `tests/` 下的 fio、Vdbench、SQLite、PCM、perf 和敏感性实验脚本 | Baseline/CPU/GPU 对照、参数化运行、资源采样和结果汇总逻辑 |
| 文档辅助脚本 | `scripts/build_word_docs.py`、`scripts/check_docs_links.py` | Markdown 到 Word 的统一排版、目录生成和文档链接检查 |

上述内容并非由 AI 独立完成。系统架构、技术路线、实验方案和最终取舍由参赛队员
确定，AI 生成或修改的代码均经过人工检查后才纳入项目。

## 3. 主要使用场景

- 根据既定设计补充函数实现、测试脚本和构建配置；
- 协助定位 CUDA、nvCOMP、并发读取、文件状态和 POSIX 语义问题；
- 对 Hook、Daemon、GPU Worker 和实验脚本进行代码审阅；
- 整理实验结果、复现步骤和项目文档格式。

## 4. 人工复核

AI 辅助代码通过编译检查、单元与集成测试、CPU/GPU 数据一致性校验、fio/Vdbench
测试、故障注入和长期稳定性实验进行验证。实验结论均以仓库中保存的原始结果和
汇总文件为依据，最终源码、文档和参赛材料由团队成员审核确认。

本队对提交作品及 AI 辅助产生的内容承担最终责任。
