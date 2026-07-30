# V100 LZ4 自适应预读 Vdbench 复测

- Vdbench 5.04.07，256 MiB 确定性非零可压缩数据；
- 4 threads，2 秒 warmup、10 秒计时，顺序读 128 KiB、随机读 4 KiB；
- 每种 workload 五轮，10/10 样本通过，逻辑 SHA-256 一致；
- 只运行 LZ4 COMPRESSED 读取，不混入 Baseline/RAW 混合写负载。

| workload | n | 吞吐均值 MB/s | 95% CI | 平均响应 ms | 旧固定 32-block MB/s | 变化 |
|---|---:|---:|---:|---:|---:|---:|
| 4 KiB random read | 5 | 2.156 | ±0.038 | 7.053 | 0.40 | +439.0% |
| 128 KiB sequential read | 5 | 65.278 | ±3.795 | 7.641 | 44.48 | +46.8% |

旧值来自 `results/final/vdbench_v100_20260730/`，其 LZ4 路径在每次 miss
固定读取并解压 32 个 128 KiB block。新路径对随机请求只处理请求覆盖 block，
连续访问逐步增长到 32-block 窗口。两轮实验的软件版本除该读取策略及按需 TLS
缓冲优化外并非完全相同，因此这里是工程前后对比，不是单变量学术消融；严格
单变量 A/B 见相邻的 fio 正式结果。

`runs.csv` 保存五轮原始摘要，`summary.csv` 保存 mean 和 95% CI，各样本目录
保留 Vdbench flatfile、HTML 与直方图。
