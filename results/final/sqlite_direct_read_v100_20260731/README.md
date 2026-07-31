# 历史无效：算法标记错误的 SQLite 结果

本目录不得用于报告或决赛图表。旧 runner 设置了 `GPUC_ALGO=lz4`，但实际调用只
生成 SGLZ 的 `cpu_compress_daemon`；文件头 `comp_algo=1`，不是 LZ4 的
`comp_algo=2`。因此原 README 将 329.86/21.79 QPS 标为 CPU/GPU LZ4 是错误的。

修复后的 runner 改用 `gpu_compress_daemon` 生成对象，并强制校验算法 ID。有效
结果见：

- `../sqlite_direct_lz4_gpu_only_v100_20260731/`；
- `../sqlite_direct_lz4_hybrid_v100_20260731/`。

旧 CSV 仅保留用于审计错误来源，不再进入任何结论。
