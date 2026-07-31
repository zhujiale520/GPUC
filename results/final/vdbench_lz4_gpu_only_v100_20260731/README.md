# Vdbench LZ4 4 KiB随机读严格GPU-only对照

与混合分流目录相同的128 MiB fixture和Vdbench口径，设置
`GPUC_LZ4_SMALL_READ_CPU_BLOCKS=0`。五轮均值为2.076±0.136 MB/s，平均响应
6.947±0.377 ms，p99直方图桶上界均值92 ms。该结果保留用于证明细粒度请求直接
提交GPU的固定开销。
