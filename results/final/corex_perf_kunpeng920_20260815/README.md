# 鲲鹏 920 + CoreX 第二阶段性能与压力验证

## 结论

- 32-block batch 的持久 Pinned staging 与合并 H2D/D2H 已启用；
- 同一二进制通过 `GPUC_SGLZ_COALESCE=0/1` 完成优化前后 A/B；
- 压缩吞吐提升 1.165x，解压吞吐提升 1.044x；
- 累计 16 GiB、131072 个 128 KiB block 的 round-trip 全部一致；
- 1 GiB 实际 GPUC 文件经 Daemon 压缩后连续透明读取 3 次，SHA-256 一致；
- 优化后的 `make GPU_PLATFORM=corex test` 全部通过。

## 口径

A/B 输入为确定性高可压缩合成数据，batch size 为 32，吞吐包含主机打包、H2D、
Kernel、D2H 和输出散布，不包含磁盘 I/O。压力测试使用相同热路径反复处理远大于
单批显存工作集的逻辑总量，并逐 batch 做字节比较。大文件测试单独覆盖 Hook、文件格式、
Daemon 和透明读取。

这些结果证明数据搬运优化有效且未破坏正确性，但不代表真实 NVMe、并发业务或整机
能效结果。原始运行目录为 `results/local/corex_perf_20260815T065008Z/`。

## 复现

```bash
export COREX_HOME=/usr/local/corex-4.4.0
export PATH="$COREX_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$COREX_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
bash tests/corex_performance_stress.sh
```
