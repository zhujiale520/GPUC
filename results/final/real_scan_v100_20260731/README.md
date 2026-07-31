# 真实日志与 ELF 扫描 workload

命令：

```bash
GPUC_RUNTIME=5 GPUC_REPEATS=5 GPUC_CORPUS_MIB=64 \
bash tests/real_scan_workload.sh
```

数据由本机 `/var/lib/dpkg/status` 和 `/usr/bin/bash` 的真实字节组成，固定顺序重复
至 64 MiB 以获得稳定计时。`environment.txt` 保存两个源文件及 corpus SHA-256。
扫描器逐字节计算 FNV-1a，并计数大小写不敏感的 `error` marker；普通文件、
CPU LZ4 Hook 和 GPU LZ4 Hook 每轮输出均为同一 hash
`16268688394177817545`、4188 markers 和 67108864 logical bytes。

五轮结果：

| 路径 | 吞吐 MiB/s | 95% CI | 完整扫描 p99 ms | 95% CI | CPU cores |
|---|---:|---:|---:|---:|---:|
| 普通文件 | 718.520 | ±4.059 | 210.495 | ±1.553 | 1.000 |
| CPU LZ4 Hook | 156.487 | ±4.476 | 662.763 | ±46.295 | 0.719 |
| GPU LZ4 Hook | 157.252 | ±7.322 | 606.939 | ±40.831 | 0.720 |

压缩对象 allocated bytes 为 36,585,472，即原始逻辑大小的约 54.52%。CPU/GPU
吞吐的 95% CI 重叠，不能声称 GPU 在该扫描中更快；该实验的有效结论是二进制与
半结构化真实内容能够经两种 LZ4 后端得到完全一致的业务输出，并明确显示压缩读取
仍显著慢于普通文件。
