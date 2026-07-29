# CPU 路径 gcov 覆盖率

使用 GCC/gcov 的 `--coverage -O0 -fno-inline` 构建 CPU Hook、CPU Daemon、
CPU SGLZ 与 CPU LZ4。测试覆盖 RAW POSIX 语义、白名单 rename、COMPRESSED
只读修改、混合内容读回、INLINE 和 LZ4 压缩/RAW/malformed 分支。

| 源文件 | 行覆盖率 | 分支执行率 |
|---|---:|---:|
| `src/hook.c` | 41.38% | 50.06% |
| `src/cpu_daemon.c` | 62.15% | 77.27% |
| `src/cpu_compress.c` | 85.52% | 88.00% |
| `src/cpu_lz4.c` | 70.83% | 94.74% |

CI 的 Hook 行覆盖率最低门槛为 35%。`gcov/` 保留逐行明细。该结果不代表 CUDA
kernel 行覆盖率，GPU 路径由功能、CRC/SHA 和集成测试验证。
