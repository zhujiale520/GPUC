# GPUC 最终作品演示视频录制大纲

> 版本：2026-08-09。建议时长 7–9 分钟。
> 视频必须完整覆盖：**运行环境介绍、项目源码与构建产物、符合赛题要求的运行演示、
> 正式结果说明**。长实验展示已保存结果，不在录制时重跑。

## 一、录制前准备

在项目根目录打开终端，调大字体并关闭可能出现密码、令牌、个人聊天和无关路径的
窗口。先在不录屏时完整走一遍短 Demo，确认命令和两个 SHA 正确。

```bash
cd /home/dell/zhujiale/project3136859-386240

export GPUC_DEMO_DIR="/tmp/gpuc_final_demo_$$"
export GPUC_PHYSICAL_GPU=1
export CUDA_VISIBLE_DEVICES=1
mkdir -p "$GPUC_DEMO_DIR/source" "$GPUC_DEMO_DIR/archive"

test -x bin/gpu_compress_daemon
test -f bin/libgpuhook.so
```

录制结束后，只删除本次创建的明确目录：

```bash
test -n "$GPUC_DEMO_DIR" && rm -rf -- "$GPUC_DEMO_DIR"
```

## 二、镜头安排

### 镜头 1：项目、运行环境与硬件（约 55 秒）

画面：README 标题和终端，依次执行：

```bash
uname -srmo
lscpu | sed -n '1,14p'
nvidia-smi --query-gpu=index,name,memory.total,driver_version --format=csv,noheader
nvcc --version | tail -n 1
fio --version
java -version 2>&1 | head -n 1
```

旁白：

> GPUC 是西安交通大学 404notfound 队面向 proj35 开发的 GPU 服务资源卸载原型。
> 本次现场演示运行在 x86_64 Ubuntu、NVIDIA RTX 4090 和 CUDA 环境中；项目还在
> Tesla V100 上完成了跨 GPU 验证。fio 用于存储 I/O，Java 环境用于 Vdbench。

画面检查：CPU 架构、GPU 型号、显存、驱动和 CUDA 信息保持清晰可读。

### 镜头 2：源码、构建产物与项目结构（约 45 秒）

执行：

```bash
find include src -maxdepth 1 -type f | sort
ls -lh bin/libgpuhook.so bin/gpu_compress_daemon
find tests -maxdepth 1 -type f | wc -l
```

画面：同时打开 `docs/项目设计方案.md` 的“实现描述与代码说明”。

旁白：

> Hook 拦截动态链接应用的文件接口，Daemon 负责离线压缩和原子替换；CUDA 源码中
> 包含本队 SGLZ 后端和可选 nvCOMP LZ4 后端，CPU 后端用于对照与回退。tests 目录
> 覆盖功能、fio、Vdbench、SQLite、稳定性、故障恢复和资源测量。现场使用仓库已经
> 编译好的共享库与 Daemon，避免把视频时间花在重复编译上。

### 镜头 3：架构、技术路线与边界（约 50 秒）

画面：全屏展示 `docs/architecture.png`，随后定位到 `docs/项目设计方案.md` 的
“总体设计”和“能力边界”。

旁白：

> 应用写入时，Hook 创建 RAW 对象；后台 Daemon 将其压缩到临时文件，在完成校验
> 和 fsync 后原子替换。读取时 Hook 根据文件头和块索引选择 SGLZ 或 LZ4，通过
> GPU 或 CPU 后端还原逻辑内容。mmap 原型使用 userfaultfd 按块填充。当前是按进程
> 启用的用户态机制验证，压缩对象采用只读归档模型；它不是生产级 DM、Btrfs 或
> ZFS，也不覆盖静态程序、直接 syscall 和应用自行提交的 io_uring。

### 镜头 4：现场运行——写入、压缩、透明读取与校验（约 110 秒）

先创建 64 MiB 可追溯源文件并记录 SHA：

```bash
dd if=/dev/zero of="$GPUC_DEMO_DIR/source/source.bin" bs=1M count=64 status=none
SOURCE_SHA="$(sha256sum "$GPUC_DEMO_DIR/source/source.bin" | awk '{print $1}')"
echo "source_sha=$SOURCE_SHA"
```

通过 Hook 写入 RAW 对象，再用 LZ4 后端离线压缩：

```bash
LD_PRELOAD="$PWD/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
  dd if="$GPUC_DEMO_DIR/source/source.bin" \
  of="$GPUC_DEMO_DIR/archive/archive.bin" bs=1M status=none

GPUC_ALGO=lz4 ./bin/gpu_compress_daemon "$GPUC_DEMO_DIR/archive"
xxd -l 64 "$GPUC_DEMO_DIR/archive/archive.bin"
```

再次通过 Hook 透明读取并比较 SHA：

```bash
READ_SHA="$(LD_PRELOAD="$PWD/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
  dd if="$GPUC_DEMO_DIR/archive/archive.bin" bs=1M status=none | sha256sum | awk '{print $1}')"
echo "read_sha=$READ_SHA"
test "$SOURCE_SHA" = "$READ_SHA" && echo "SHA256_MATCH: PASS"

ls -lh "$GPUC_DEMO_DIR/source/source.bin" "$GPUC_DEMO_DIR/archive/archive.bin"
du -h "$GPUC_DEMO_DIR/source/source.bin" "$GPUC_DEMO_DIR/archive/archive.bin"
```

旁白：

> 文件头记录逻辑大小、算法、块索引和校验信息。普通应用只加载共享库，不需要修改
> 读取代码；屏幕上的 PASS 证明透明读取结果与源文件一致。磁盘占用下降来自当前
> 高可压缩输入，实际压缩率取决于数据内容。Daemon 只扫描 archive 目录，源文件不
> 参与替换。

录制要求：必须同时拍到 `SHA256_MATCH: PASS`、GPUC 文件头和压缩前后占用；若任一
命令失败，停止录制并排查，不剪接伪造成功过程。

### 镜头 5：核心性能结果——CPU 卸载（约 55 秒）

画面：打开
`results/final/resource_rtx4090_gpu1_final_20260806T145935Z/summary.csv`，随后切换到
最终 PPT 的对应柱状图。

旁白：

> 在 RTX 4090、高可压缩输入和约 4 GiB/s 持续解压压力下，GPU 路径相对 CPU
> 路径多保留 13.05% 的并行业务吞吐，解压进程 CPU 时间降低 96.4%。它证明 GPU
> 在该高压力工作点减少了主 CPU 竞争。低吞吐或低压缩率下收益不一定明显，相关
> 负结果也完整保留。

结果说明同时给出比较对象、约 4 GiB/s 工作点、压缩率与 CPU affinity。

### 镜头 6：真实并行业务——SQLite（约 45 秒）

画面：
`results/final/sqlite_range_offload_rtx4090_gpu1_20260807T153922Z/summary.csv` 和 QPS/p99 图。

旁白：

> 当 SQLite 与固定解压任务竞争 CPU 时，4090 GPU 路径相对 CPU 路径的 QPS 提高
> 11.21%，p99 降低 81.66%，解压进程 CPU 时间降低 88%。GPU 路径仍比没有解压
> 压力的 Baseline 低 5.14%。因此它证明的是资源竞争得到缓解，而不是数据库文件
> 本身被 GPU 直接加速。

### 镜头 7：fio、Vdbench、稳定性与故障恢复（约 75 秒）

依次展示正式汇总，不重跑长实验：

```bash
cat results/final/fio_threads_rtx4090_gpu1_final_20260806T151148Z/summary.csv
cat results/final/vdbench_rtx4090_gpu1_final_20260806T151148Z/summary.csv
cat results/final/stability_1h_rtx4090_gpu1_final_20260806T151148Z/summary.csv
cat results/final/fault_recovery_rtx4090_gpu1_gap_20260807T143659Z/summary.csv
```

旁白：

> fio 多线程两种格式、三种块大小和 1/4 线程共 60 个样本全部正确退出；Vdbench
> 四路径、顺序与随机读取五轮共 50 个样本完成。一小时持续读 error 为零且前后
> SHA 相同，确定性故障恢复五项通过。完整 fio 矩阵还有 465 个 JSON、525 行指标
> 和 105 个五轮组，所有路径的逻辑 SHA 一致。

### 镜头 8：mmap、DRAM 与负结果（约 60 秒）

画面：`docs/实验结果报告.md` 中 mmap、PCM、压缩侧和适用边界章节。

旁白：

> userfaultfd mmap 在 4090 上 60 个样本 mismatch 为零，但 256 MiB 完整扫描的
> 单线程与 8 线程约为 2.31 和 2.32 秒，没有扩展收益。V100 的公平同吞吐 PCM
> 实验显示 GPU 总 DRAM 带宽比 CPU 低约 47.75%；4090 PCM 记录了两条路径的实际
> 吞吐与平台饱和状态。压缩侧峰值、PG2600、Btrfs 和 4 KiB 实验共同展示当前方案
> 在不同压缩率、数据集和请求粒度下的表现。

### 镜头 9：总结与材料闭环（约 35 秒）

画面：最终 PPT 总结页，再展示 `docs/` 下三份中文文档。

旁白：

> GPUC 已在 V100 和 RTX 4090 上完成从功能、性能、稳定性到资源的实验闭环。核心
> 结论是 GPU 能在高压力解压任务中释放主 CPU，并改善与其并行的真实业务。设计
> 方案、实验结果和复现指南已经随源码提交；下一步将探索内核存储路径、更细粒度
> 小请求优化、指定 RTX 与鲲鹏平台、独占 NVMe 和整机能耗。

## 三、官方要求对照检查

| 官方要求 | 视频对应内容 | 完成判据 |
|---|---|---|
| 项目源代码运行环境介绍 | 镜头 1 | CPU/GPU/OS/驱动/CUDA/fio/Java 可读 |
| 源码与实现介绍 | 镜头 2、3 | 核心目录、二进制、架构、读写路径和边界明确 |
| 符合任务要求的运行演示 | 镜头 4 | 写入、Daemon 压缩、透明读取、SHA PASS 连续出现 |
| 演示效果及结果说明 | 镜头 5—8 | 核心数字有条件、有比较对象、有边界 |
| 项目总结 | 镜头 9 | 功能—性能—稳定性—资源闭环及后续路线明确 |

## 四、录制完成检查清单

- [ ] 总时长控制在 7–9 分钟，画面为 1080p，终端和 CSV 字体可读；
- [ ] 环境中明确出现 RTX 4090，且没有把 Intel Arc 等其他 GPU 当作实验设备；
- [ ] 现场 Demo 从写入到 SHA PASS 连续录制；
- [ ] 长实验只展示 `results/final/` 正式结果，不重跑一小时、完整 fio/Vdbench/PCM；
- [ ] 每个百分比能在 CSV 或 `docs/实验结果报告.md` 找到来源；
- [ ] 视频不出现 sudo 密码、令牌、私人窗口和无关个人信息；
- [ ] 最终文件命名为 `GPUC_demo_final.mp4` 并放入 `video/`；
- [ ] 播放最终 MP4，检查画面、声音、字幕同步和文件完整性。
