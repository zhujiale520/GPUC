# CPU/GPU LZ4 压缩峰值与压缩率梯度

CPU liblz4 与 GPU nvCOMP batch 使用同一确定性 512 MiB 工作集、128 KiB block、
batch=32，不限速运行 5 秒、各五轮。输入由重复字节页和确定性伪随机页组成，
请求可压缩页比例为 0%/50%/100%。每次正式计时前均用 CPU LZ4 解压并逐字节验证
当前 backend 的输出。

命令：

```bash
GPUC_RESULT_DIR="$PWD/results/local/lz4_compress_sensitivity_v100_20260731" \
GPUC_RUNTIME=5 GPUC_REPEATS=5 GPUC_WORKSET_MIB=512 \
GPUC_BATCH_BLOCKS=32 GPUC_COMPRESSIBLE_PCTS='0 50 100' \
bash tests/lz4_compress_sensitivity.sh
```

| 可压缩页 | CPU 存储比 | GPU 存储比 | CPU 峰值 MiB/s | 95% CI | GPU 峰值 MiB/s | 95% CI | GPU/CPU | CPU host core | GPU host core |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0% | 100.0008% | 100.0008% | 4850.92 | ±161.81 | 423.45 | ±1.64 | 0.087× | 1.000 | 0.243 |
| 50% | 50.3636% | 50.3533% | 6283.75 | ±316.97 | 459.51 | ±2.37 | 0.073× | 1.000 | 0.209 |
| 100% | 0.4936% | 0.4936% | 7842.97 | ±497.24 | 1300.61 | ±13.79 | 0.166× | 1.000 | 0.448 |

GPU batch 的主机 CPU 较低，但它同时只完成 CPU 吞吐的 7.3%–16.6%，所以不能据此
宣称固定工作量下的 CPU 卸载。结合此前同为 1024 MiB/s、高可压缩输入的公平实验
（GPU/CPU host core 为 0.365/0.276）和压缩侧 PCM（GPU 总 DRAM 高 29.53%），
当前准确结论是：真正 batch 已修复旧 serial 路径，但 V100 上 nvCOMP LZ4 压缩的
绝对吞吐仍明显低于单核 liblz4，并且固定吞吐下没有 CPU/DRAM/RSS 优势。

50% 输入下 CPU/GPU 产生的合法 LZ4 流大小略有不同，因此存储比不要求逐字节相等；
所有 backend 均通过解压内容校验。GPU 功耗是包含空闲功耗的板卡口径，不是整机能效。
