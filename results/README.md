# 实验结果目录说明

自动化测试产生的本地结果统一写入：

```text
results/local/<实验名称>_<UTC 时间戳>/
```

`results/local/` 已加入 Git 忽略规则，重复运行实验不会污染工作区。

用于正式报告和答辩的数据保存在：

```text
results/final/<实验名称>/<运行编号>/
```

每组正式实验结果应完整保留以下内容：

- `environment.txt`：Git 提交、内核、CPU、GPU、驱动、CUDA、fio 版本和实验参数；
- fio JSON、Vdbench 输出、PCM CSV 或其他工具的原始结果；
- `runs.csv`：每次重复实验一行；
- `summary.csv`：样本数、均值、标准差和 95% 置信区间；
- 输入文件的校验和、逻辑大小、物理占用和 GPUC 状态；
- 简短的 `README.md`：记录完整执行命令、数据集、缓存状态，以及 buffered、
  cold-cache 或 `O_DIRECT` 等实验口径。

正式图表应能够追溯到对应的原始数据、运行参数和生成脚本。项目最终结果的总索引
位于 [`final/README.md`](final/README.md)，完整分析见
[`../docs/实验结果报告.md`](../docs/实验结果报告.md)。
