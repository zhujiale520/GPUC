# V100 CPU/GPU LZ4 压缩公平实验

命令：

```bash
GPUC_RUNTIME=5 GPUC_REPEATS=5 GPUC_WORKSET_MIB=512 \
GPUC_BATCH_BLOCKS=32 GPUC_TARGET_MIB_S=1024 \
bash tests/lz4_compress_fair.sh
```

CPU 与 GPU batch 使用相同的确定性 512 MiB 工作集、128 KiB block、batch=32 和
1024 MiB/s 逻辑吞吐。`gpu_serial` 为旧“每块一次提交并同步”的严格消融，因最大
吞吐不足 1024 MiB/s，按最大能力运行。

五轮结果：

- CPU：1023.983 MiB/s，0.276±0.003 host core；
- GPU batch：1023.984 MiB/s，0.365±0.002 host core；
- GPU serial：55.821±0.313 MiB/s，0.539±0.005 host core；
- 真 batch 相对旧 serial 至少 18.34 倍；由于 batch 被 1024 MiB/s 限速，实际
  最大吞吐加速可能更高；
- CPU/GPU 压缩率完全一致（0.4936%），但 GPU batch 在相同吞吐下的主机 CPU
  比 CPU liblz4 高 32.0%。因此本实验不支持“压缩侧降低主机 CPU”的结论。

`nvidia-smi` 能量为 V100 板卡总功耗积分，包含空闲功耗；没有 CPU package 或
整机能耗，不能用于整机能效排名。
