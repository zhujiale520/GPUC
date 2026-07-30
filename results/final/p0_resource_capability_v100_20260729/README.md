# P0 资源与设备能力审计

审计日期：2026-07-29。

## 可测指标

- CPU/GPU 同吞吐实验已统一记录进程 CPU 时间、submit/worker CPU 时间、最大
  RSS、minor/major fault、自愿/非自愿上下文切换、GPU 利用率与板卡功耗。
- GPU 路径额外记录 queue、pack、H2D、kernel、D2H、unpack 和请求总耗时。
- 对应五轮原始 CSV 与摘要位于
  `../cpu_offload_fixed4g_isolated_v100_20260729/` 和
  `../cpu_offload_fixed4g_samecore_v100_20260729/`。
- `sar -r` 与 `sar -B` 可运行；审计时系统平均内存使用约 1.75 GiB、
  major fault 为 0。它们是全机观测，不作为 CPU/GPU 路径的归因数据。

## 2026-07-30 后续状态

- `/usr/bin/perf` 只是缺失内核配套工具的包装器，执行 `perf stat` 报告
  `perf not found for kernel 5.15.0`。
- 2026-07-30 已从 Intel 官方仓库固定
  `4246ea47f27c471bcc8484c065886f31f449933e` 并在
  `third_party/manual/pcm/build/` 成功编译 PCM。`pcm-memory` 正确识别
  Xeon 6505P（Granite Rapids），但当前会话缺少 `/dev/cpu/*/msr`、ACPI MCFG
  和 uncore PCI 配置空间；`PCM_NO_MSR=1` 也明确报告无法访问内存控制器。
  随后管理员已在宿主机加载 MSR 并完成五轮正式实验，结果见
  `../pcm_dram_v100_20260730/`。DRAM bandwidth 阻塞已经解除，结果显示 GPU
  路径显著增加主机 DRAM 写带宽。

当前只剩 cycles/LLC miss 仍受匹配内核 perf 缺失影响；不能把 PCM IMC 带宽
替代为 cache miss。

## 存储设备

- 项目工作目录：`/dev/sda2`，ext4，SATA SSD。
- 机器存在 `nvme0n1`（Fanxiang S500Pro 1TB，已有 ext4），但未挂载。
- 当前会话既不能通过 sudo 挂载，也不能连接 udisks daemon。为避免破坏未知数据，
  没有直接读写裸块设备。
- 对齐格式的 `O_DIRECT` 正确性与 fio 结果因此在 `/dev/sda2` 上完成，见
  `../odirect_aligned_v100_20260729/`；它证明 direct I/O 路径生效，不代表 NVMe
  性能。
