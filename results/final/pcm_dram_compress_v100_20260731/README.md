# CPU/GPU LZ4 压缩侧 PCM DRAM 实验

命令：

```bash
sudo env GPUC_RESULT_DIR="$PWD/results/local/pcm_dram_compress_v100_20260731" \
GPUC_RUNTIME=10 GPUC_REPEATS=5 GPUC_TARGET_MIB_S=1024 \
GPUC_WORKSET_MIB=512 GPUC_BATCH_BLOCKS=32 \
bash tests/pcm_dram_compress.sh
```

CPU liblz4 与 GPU nvCOMP 使用相同 512 MiB 工作集、128 KiB block、batch=32、
0.4936% stored ratio 和约 1024 MiB/s 逻辑吞吐。每轮只汇总完整处于十秒稳态
区间内的 9 个 PCM 一秒样本：

| 路径 | DRAM Read MB/s | 95% CI | DRAM Write MB/s | 95% CI | DRAM Total MB/s | 95% CI |
|---|---:|---:|---:|---:|---:|---:|
| CPU | 1288.02 | ±4.85 | 108.83 | ±0.86 | 1396.85 | ±5.60 |
| GPU | 1302.01 | ±31.77 | 507.38 | ±46.92 | 1809.39 | ±69.25 |

GPU 相对 CPU 总 DRAM bandwidth 高约 29.53%，主要来自写带宽高约 366.22%；
读带宽差约 1.09%，95% CI 重叠。相同吞吐下 GPU/CPU 主机成本为
0.358/0.282 core（GPU 高约 26.95%），最大 RSS 高约 20.17%。因此本数据集和
当前实现下，压缩侧没有主机 CPU、DRAM bandwidth 或 RSS 优势；解压侧已经验证
的收益不能外推到压缩侧。

PCM 为全系统 IMC 口径，不是单进程精确流量。数据高度可压缩，结论只适用于本
实验输入与软件版本。
