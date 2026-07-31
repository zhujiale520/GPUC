# SQLite 真实 LZ4 小请求混合分流

runner 强制检查GPUC文件头`comp_algo=2`，确认fixture为真实LZ4。100000行mixed
payload、单worker、256行indexed range aggregate，每场景五轮、每轮3秒。
`GPUC_LZ4_SMALL_READ_CPU_BLOCKS=1`：应用请求只覆盖一个128 KiB block时使用
liblz4；较大或批量请求仍走GPU。

| 路径 | QPS | 95% CI | p99 us | 95% CI | host cores |
|---|---:|---:|---:|---:|---:|
| 普通文件 | 22197.22 | ±71.97 | 102.34 | ±1.71 | 1.084 |
| CPU LZ4 | 109.34 | ±1.33 | 11865.45 | ±861.96 | 1.037 |
| 混合分流 | 108.33 | ±0.30 | 11619.09 | ±127.25 | 1.034 |

相对相同口径严格GPU-only，混合分流QPS提高94.58%，p99降低52.52%。它仍比普通
文件慢99%以上，因此该结果证明策略缓解小请求开销，不证明数据库被GPUC加速。
