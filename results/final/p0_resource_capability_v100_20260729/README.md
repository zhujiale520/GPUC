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

## 当前无法可靠测量的指标

- `/usr/bin/perf` 只是缺失内核配套工具的包装器，执行 `perf stat` 报告
  `perf not found for kernel 5.15.0`。
- `kernel.perf_event_paranoid=2`，且当前容器没有可用的 sudo 权限。
- 未安装 Intel PCM；当前 Xeon 6505P 的 uncore PMU 没有内核导出的命名 IMC
  event。不能猜测 raw event 编号后把结果称为 DRAM 带宽。

因此，本轮可以比较主机 CPU 时间、进程内存容量、缺页和上下文切换，但不能声称
已经测得 DRAM 控制器带宽或 LLC miss。部署环境补齐匹配内核的 `linux-tools` 或
Intel PCM 后，应按相同场景补测。

## 存储设备

- 项目工作目录：`/dev/sda2`，ext4，SATA SSD。
- 机器存在 `nvme0n1`（Fanxiang S500Pro 1TB，已有 ext4），但未挂载。
- 当前会话既不能通过 sudo 挂载，也不能连接 udisks daemon。为避免破坏未知数据，
  没有直接读写裸块设备。
- 对齐格式的 `O_DIRECT` 正确性与 fio 结果因此在 `/dev/sda2` 上完成，见
  `../odirect_aligned_v100_20260729/`；它证明 direct I/O 路径生效，不代表 NVMe
  性能。
