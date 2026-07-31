# Btrfs zstd:3 与 ext4+GPUC LZ4 基线

命令：

```bash
sudo env GPUC_RESULT_DIR="$PWD/results/local/btrfs_zstd_v100_20260731" \
GPUC_SIZE_MIB=256 GPUC_RUNTIME=5 GPUC_REPEATS=5 \
bash tests/btrfs_compare.sh
```

脚本只格式化自行创建且通过 `losetup -O BACK-FILE` 反查一致的 loop image，
不操作 NVMe。三条路径使用相同 256 MiB 源文件与 SHA-256。Btrfs 使用
`compress-force=zstd:3` 并显式 defrag；`compsize -b` 检测到全部 extent 为
zstd，8,388,608 B disk usage / 268,435,456 B uncompressed，即 3.125%。
`filefrag` 同时记录 `encoded` 标志。

输入是每 4 KiB 页带不同请求编号、但主体字节高度重复的合成日志型 pattern，
用于稳定验证压缩机制和路径差异；3.125%/6.284% 的空间比不能外推到普通日志、
数据库或二进制数据。

五轮 buffered warm-cache fio：

| 路径 | 128 KiB 顺序 MiB/s | 95% CI | 4 KiB 随机 MiB/s | 95% CI | 数据占用比 |
|---|---:|---:|---:|---:|---:|
| ext4 plain | 8256.55 | ±87.88 | 3652.34 | ±47.28 | 100.006% |
| ext4 + GPUC LZ4 | 383.73 | ±6.95 | 2.114 | ±0.054 | 6.284% |
| Btrfs zstd:3 | 8761.48 | ±150.49 | 3786.70 | ±24.85 | 3.125% |

这些不是磁盘介质吞吐：`invalidate=0`，且准备阶段已将数据带入 page cache。
Btrfs/普通文件的计时读主要命中内核中的未压缩页；GPUC 的用户态 Hook 不持有同等
大小的完整逻辑 page cache，每次 cache miss 仍需索引、CUDA 调度、至少一个
128 KiB block 解压、D2H 和应用拷贝。4 KiB 请求相对 128 KiB 压缩单元有至少
32 倍解压粒度放大，因此 Btrfs/GPUC 的随机读差距达到约 1791 倍。

Btrfs 相对 plain 的 +6.12% 顺序和 +3.68% 随机差异只能描述为本机 warm-cache
观测，不能归因为 zstd 或外推到 NVMe。公平的介质性能比较仍需 cold-cache 或独占
设备；本实验最可靠的结论是：Btrfs 压缩真实生效、空间优于本项目 LZ4，同时内核
页缓存路径没有暴露 GPUC 当前的用户态逐请求开销。
