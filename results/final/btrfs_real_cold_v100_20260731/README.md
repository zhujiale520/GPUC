# Btrfs zstd真实corpus与文件页缓存失效对比

256 MiB corpus由本机 `/var/lib/dpkg/status` 和 `/usr/bin/bash` 的可追溯字节重复
组成，源SHA-256见 `corpus_sources.sha256`。三条路径为ext4普通文件、ext4+GPUC
LZ4、loop Btrfs zstd:3；fio使用 `invalidate=1`，顺序128 KiB和随机4 KiB各五轮。
30/30样本 `error=0`，三条路径逻辑SHA一致。

| 路径 | allocated bytes | 空间占用 | 顺序128 KiB | 随机4 KiB |
|---|---:|---:|---:|---:|
| ext4普通文件 | 268,460,032 | 100.01% | 354.22±3.58 MiB/s | 21.65±1.93 MiB/s |
| ext4+GPUC LZ4 | 146,579,456 | 54.61% | 89.41±5.81 MiB/s | 0.541±0.003 MiB/s |
| Btrfs zstd:3 | 97,607,680 | 36.36% | 1906.51±61.23 MiB/s | 11.37±0.79 MiB/s |

Btrfs空间数字来自 `compsize -b` 的zstd extent，证明真实corpus下Btrfs zstd的
空间效率优于当前GPUC LZ4。GPUC在两种读取中都明显落后，尤其4 KiB随机读仍是
主要性能短板。

“cold”仅指fio对每个文件执行页缓存失效；脚本没有写全系统 `drop_caches`，没有
刷新设备缓存，而且Btrfs位于loop backing file上。因此Btrfs的1906 MiB/s不能解释
为磁盘或NVMe吞吐，也不能与独占裸设备成绩等同。该结果可以用于应用路径和空间
基线，不能用于宣称介质性能。
