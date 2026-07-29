# CPU liblz4 vs GPU nvCOMP LZ4（2026-07-25）

该测试让 CPU 和 GPU 解压同一份由 liblz4 生成的 LZ4 block 数据，输出格式、逻辑
数据和校验完全相同；CUDA 初始化和一次完整 batch 预热不计入计时。

- GPU：Tesla V100-SXM2-32GB
- 数据：16 MiB，128 × 128 KiB block，确定性逐页 pattern
- 存储：82,816 B，压缩后/原始 = 0.49%
- 重复：5 次

| 后端 | 中位有效解压带宽 |
|---|---:|
| CPU liblz4（单进程串行 block） | 15,633.855 MiB/s |
| GPU nvCOMP LZ4（单次真正 batch） | 4,773.384 MiB/s |

GPU/CPU = 0.305。该结果说明：对只有 16 MiB、极高压缩率且 CPU 空闲的数据，
CPU liblz4 更快，GPU 卸载不能宣传成无条件加速。项目更合理的价值假设是释放 CPU
给业务任务，需在“解压 + CPU 业务并行”的实验中验证。

修复前 `gpu_lz4_decompress_batch()` 内部逐 block 同步，GPU 中位数仅
656.521 MiB/s；改成一次真实 nvCOMP batch 后达到 4,773.384 MiB/s，提升约
7.27×。端到端 `tests/nvcomp_lz4.sh` 随后通过，Linux headers 压缩率 38.6%，
读回校验一致。
