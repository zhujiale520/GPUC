# V100 LZ4 请求感知 read-ahead 与按需 TLS 缓冲 A/B

- 输入：256 MiB 确定性、可压缩、逐页不同的非零数据。
- 模式：
  - `legacy`：每次 cache miss 固定读取并解压 32 × 128 KiB。
  - `adaptive`：随机访问只处理请求覆盖的 block；连续访问窗口逐步扩展为
    1/8/16/32 blocks；TLS compressed/decompressed buffers 随窗口按需增长。
- 负载：fio buffered warm-cache，4 KiB/128 KiB 随机读和 128 KiB 顺序读，
  1/4 threads，各五轮，每轮 3 秒。
- 校验：准备完成及每种模式均使用同一 COMPRESSED LZ4 文件；逻辑 SHA-256 一致，
  60/60 样本 fio error=0。

核心结果：

| 负载 | Threads | Legacy MiB/s | Adaptive MiB/s | 吞吐变化 | p99 变化 | RSS 变化 |
|---|---:|---:|---:|---:|---:|---:|
| 4 KiB randread | 1 | 0.380 | 2.246 | +490.2% | -91.0% | -2.2% |
| 4 KiB randread | 4 | 1.479 | 7.670 | +418.7% | -89.5% | -8.5% |
| 128 KiB randread | 1 | 12.036 | 70.242 | +483.6% | -92.1% | -2.1% |
| 128 KiB randread | 4 | 47.561 | 254.341 | +434.8% | -89.2% | -7.0% |
| 128 KiB sequential | 1 | 381.400 | 379.732 | -0.4% | 0.0% | +0.9% |
| 128 KiB sequential | 4 | 1482.186 | 1450.575 | -2.1% | 0.0% | +0.7% |

顺序读差异的 95% CI 重叠，不能解释为稳定退化；顺序负载最终增长到 32-block
窗口，因此不会获得随机负载的 RSS 降幅。`runs.csv` 保存逐轮数据，
`summary.csv` 保存 mean 和 95% CI，`json/` 与 `time/` 保存 fio 和 GNU time
原始输出。
