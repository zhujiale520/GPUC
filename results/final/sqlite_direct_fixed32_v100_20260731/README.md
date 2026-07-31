# 历史无效：算法标记错误的固定预读结果

本目录继承了旧 `sqlite_direct_read.sh` 的 fixture 错误：实际对象是 SGLZ
（`comp_algo=1`），不是 README 曾声明的 LZ4（`comp_algo=2`）。原来的
329.86/21.79 与 331.34/21.69 QPS 对照不得继续引用。

目录仅用于错误审计。真实 LZ4 小请求的有效 GPU-only/混合分流结果见相邻的
`sqlite_direct_lz4_*_v100_20260731/` 目录。
