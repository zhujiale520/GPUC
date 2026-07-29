# userfaultfd mmap 八线程扫描正式结果

与单线程实验使用相同 V100、64/256 MiB 数据和五轮方法，只将页扫描线程设为 8。
256 MiB GPU COMPRESSED 的 `mmap()` 为 0.221 ± 0.010 ms，首次 fault 为
144.993 ± 2.247 ms，完整扫描为 5376.272 ± 159.080 ms，mismatch 均为 0。

相对单线程 5651.449 ± 367.254 ms，八线程没有稳定线性扩展；当前每个映射只有一个
userfaultfd handler，线程主要并发触发 fault，不能据此宣称 8 倍解压能力。
