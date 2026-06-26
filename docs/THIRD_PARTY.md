# 第三方来源与依赖说明

## 1. 基础版本声明

本项目 **proj35 - 基于 GPU 的服务资源卸载技术探索** 为参赛队独立原创作品，
**未基于往届参赛作品、未 fork 或复制其他开源项目** 作为基础版本。
系统架构、GPUC 文件格式、SGLZ 压缩算法、LD_PRELOAD 拦截层、离线 Daemon 等核心设计均为本队自主实现。

## 2. 非本队来源代码/库使用说明

### 2.1 运行时依赖库

| 依赖 | 用途 | 许可证 | 说明 |
|------|------|--------|------|
| NVIDIA CUDA Toolkit / CUDA Runtime | GPU 并行计算 | NVIDIA CUDA Toolkit EULA | 系统自带或 NVIDIA 官网安装 |
| NVIDIA nvCOMP | `GPUC_ALGO=lz4` 时提供 GPU LZ4 压缩/解压 | NVIDIA Proprietary（闭源，随 CUDA / 独立 deb 分发） | 本队仅通过其公开 C API 调用，未修改其源码；`third_party/nvcomp` 为本地解压的发行包，未随源码提交 |
| liblz4 | `src/cpu_lz4.c` CPU fallback 解压 | BSD-2-Clause | 系统运行库或本地符号链接 `third_party/lz4/liblz4.so` |
| glibc / libdl / libpthread | 系统调用与动态链接 | LGPL / GPL（系统库例外） | 标准系统库 |

### 2.2 测试/样例依赖

| 依赖 | 用途 | 许可证 | 说明 |
|------|------|--------|------|
| fio | I/O 性能基准测试 | GPL-2.0 | 命令行工具，非链接依赖 |
| LevelDB（`deps/leveldb`） | 真实 workload 测试 | BSD-3-Clause | 已保留原 `LICENSE` 文件 |
| ccache（`deps/ccache`） | 编译缓存 workload 测试 | GPL-3.0+ / 其他（见 `deps/ccache/LICENSE.*`） | 已保留原许可证文件 |

### 2.3 公开资料与算法参考

- **LZ4 块格式与压缩原理**：参考 Yann Collet 发布的 [LZ4 Frame Format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md) 及 [LZ4 Block Format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Block_format.md) 公开文档，用于理解 liblz4 数据布局；本队未直接复制其源码。
- **NVIDIA nvCOMP LZ4 API**：参考 `third_party/nvcomp/usr/include/nvcomp_12/nvcomp/lz4.h` 头文件及 [nvCOMP Samples](https://github.com/NVIDIA/CUDALibrarySamples/tree/master/nvCOMP) 公开示例的接口用法。
- **LD_PRELOAD 透明拦截技术**：参考 glibc 文档及公开技术博客中关于 `RTLD_NEXT`、`dlsym` 的用法。

## 3. 增量贡献说明

本队在上述第三方库/工具之上完成的增量工作包括但不限于：

1. 自主设计并实现的 **GPUC 文件格式**（`include/file_header.h`）。
2. 自主实现的 **SGLZ GPU 压缩/解压算法**（`src/gpu_compress.cu`、`src/cpu_compress.c`）。
3. 自主实现的 **LD_PRELOAD 用户态透明拦截层**（`src/hook.c`），覆盖 25+ 个系统调用。
4. 自主实现的 **离线压缩 Daemon**（`src/daemon.c`、`src/cpu_daemon.c`），含原子替换、块索引、CRC32、自适应 fallback 等机制。
5. 自主集成的 **nvCOMP LZ4 可插拔后端**（`src/gpu_lz4.cu`、`src/cpu_lz4.c`），通过 `GPUC_ALGO` 环境变量与 SGLZ 共存切换。
6. 全部测试脚本、性能基准、实验报告、架构文档与演示材料。

## 4. 合规性承诺

- 本队已按大赛要求在源代码仓库根目录提供 `LICENSE`（Apache-2.0）与 `LICENSE-docs`（CC-BY-SA 4.0）。
- 所有非本队来源的代码、库、公开资料均已在本文件及 `docs/AI_TOOL_DECLARATION.md` 中说明。
- 未将第三方闭源二进制（如 nvCOMP deb 包）随源代码仓库提交；`third_party/` 已加入 `.gitignore`。
