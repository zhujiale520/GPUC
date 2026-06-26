# GPUC 项目演示视频脚本

> 视频时长建议：6–8 分钟
> 录制工具推荐：OBS Studio / SimpleScreenRecorder / 命令行 asciinema
> 分辨率建议：1920×1080，终端字体放大至 18–20px，确保文字清晰

---

## 一、视频整体结构

| 章节 | 时长 | 内容 |
|---|---|---|
| 片头 | 5–10 s | 项目标题、队伍、学校 |
| 环境介绍 | 30 s | 运行环境、GPU、CUDA、文件系统 |
| 项目编译 | 30 s | 克隆/进入目录、环境检查、make all |
| 一键 DEMO | 1.5 min | 写入 → 压缩 → 透明读取 → MD5 校验 |
| 核心实验 | 3–4 min | 顺序读、高并发、mmap、LZ4 后端 |
| 真实场景 | 1–1.5 min | 数据库白名单、容错 fallback |
| 总结 | 30 s | 核心成果与创新点 |

---

## 二、录制前准备

### 2.1 环境检查

确保以下命令可以正常执行：

```bash
cd /home/ubuntu/project3136859-386240

# 检查 GPU
nvidia-smi

# 检查 CUDA
nvcc --version

# 检查依赖
which fio python3 bc xxd
```

### 2.2 清理旧测试文件

```bash
# 清理 /tmp 下旧的 gpuc 测试目录
rm -rf /tmp/gpuc_* /tmp/gpuc_test
```

### 2.3 终端设置

- 终端窗口大小：建议 100×30 行以上
- 字体：Monaco / Consolas / 等宽字体，字号 18+
- 背景：深色背景（与 PPT 风格一致）
- 提前执行 `cd /home/ubuntu/project3136859-386240`

---

## 三、分镜头脚本

### 镜头 1：片头

**时长**：5–10 秒

**画面**：
- 深色背景 + 项目 logo（可选）
- 文字：
  ```
  基于 GPU 的服务资源卸载技术探索
  GPUC - 透明存储压缩卸载系统
  西安交通大学 · 404notfound
  2026 全国大学生计算机系统能力大赛
  ```

**旁白**：
> 大家好，我们是西安交通大学 404notfound 队。本次演示的项目是“基于 GPU 的服务资源卸载技术探索”——GPUC 透明存储压缩卸载系统。

---

### 镜头 2：环境介绍

**时长**：约 30 秒

**画面**：终端执行以下命令

```bash
# 显示项目目录
cd /home/ubuntu/project3136859-386240
pwd
ls

# 显示 GPU 信息
nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv

# 显示 CUDA 版本
nvcc --version

# 显示文件系统
mount | grep "on / "
```

**旁白**：
> 我们的测试环境是一台配备 Tesla V100 GPU 的服务器，CUDA 版本 12.8，文件系统为 ext4。项目不修改操作系统内核，也不改动现有文件系统，完全通过用户态 LD_PRELOAD 实现透明压缩卸载。

---

### 镜头 3：项目编译

**时长**：约 30 秒

**画面**：终端执行

```bash
# 环境检查
bash scripts/check_env.sh

# 编译
make clean && make all -j

# 查看编译产物
ls -lh bin/
```

**旁白**：
> 项目提供一键环境检查脚本和 Makefile。Makefile 会自动检测 GPU 计算能力，无需手动修改编译参数。编译产物包括 LD_PRELOAD 共享库 libgpuhook.so、GPU 离线压缩守护进程 gpu_compress_daemon，以及多个测试程序。

---

### 镜头 4：一键 DEMO

**时长**：约 1.5 分钟

**画面**：终端执行

```bash
# 运行一键 DEMO
bash scripts/demo.sh
```

该脚本会自动完成：
1. 写入 RAW 文件（自动附加 56 B GPUC header）
2. 正常读取 RAW 文件
3. CPU 压缩对比
4. GPU 离线压缩
5. 透明读取已压缩文件（GPU 实时解压）
6. 显示压缩前后大小对比

**旁白**：
> 这是项目的一键 DEMO。首先，我们在 LD_PRELOAD 环境下写入一个 100 MB 的测试文件，系统会自动在文件头部附加 56 字节的 GPUC header。然后后台 Daemon 对文件进行 GPU 压缩。最后，我们再次通过 LD_PRELOAD 读取文件，此时 Hook 会自动调用 GPU 解压，对上层应用完全透明。

**关键画面**：
- 显示压缩前/后文件大小
- 显示 MD5 校验通过

---

### 镜头 5：核心实验 — 顺序读性能

**时长**：约 1 分钟

**画面**：终端执行

```bash
# 运行 fio 基准测试
bash tests/benchmark_fio.sh
```

**旁白**：
> 我们使用 fio 测试顺序读性能。可以看到，在 128 KB 块大小、page cache 命中的条件下，GPU Compressed 的读带宽与 Baseline 基本持平，这说明 GPU 解压开销已被 batch、内存池、io_uring 等优化完全摊销。

**关键数据**（可在脚本输出后暂停展示）：
- Baseline：450.9 MB/s
- Hook RAW：451.7 MB/s
- GPU Compressed：458.3 MB/s

---

### 镜头 6：核心实验 — jobs=32 高并发

**时长**：约 1 分钟

**画面**：终端执行

```bash
# 高并发综合测试
bash tests/benchmark_high_concurrency.sh
```

**旁白**：
> 这是项目早期遇到的最大性能挑战。在 32 线程高并发下，早期实现因单 Stream 竞争和 batch 无法合并，带宽骤降至 Baseline 的 7%。通过引入 16 个 CUDA Stream、io_uring 批量 I/O 和激进 read-ahead，jobs=32 时 GPU Compressed 已恢复至 Baseline 的 99.8%。

**关键数据**：
- zero 128k：Baseline 4900.2 MB/s，GPUC 4889.1 MB/s，99.8%
- rand 128k：Baseline 396.6 MB/s，GPUC 395.8 MB/s，99.8%

---

### 镜头 7：核心实验 — mmap 按需解压

**时长**：约 1 分钟

**画面**：终端执行

```bash
# 编译 mmap 测试程序
gcc -O3 tests/test_mmap_ondemand.c -o bin/test_mmap_ondemand

# 运行 mmap 大小扫描
bash tests/mmap_size_sweep.sh
```

**旁白**：
> 对于数据库和编译器等使用 mmap 的应用，早期实现需要在 mmap() 时一次性预解压整个文件。我们对 512 MB 文件进行了优化：改为同步预加载前 16 MB，后台线程异步解压剩余部分。结果显示，mmap 返回时间从 2414 毫秒降至 231 毫秒，提升了 10.4 倍。

**关键数据**：
- 512 MB 优化前：2414.5 ms
- 512 MB 优化后：231.4 ms

---

### 镜头 8：核心实验 — nvCOMP LZ4 后端

**时长**：约 1 分钟

**画面**：终端执行

```bash
# 运行 LZ4 后端集成测试
bash tests/nvcomp_lz4.sh
```

**旁白**：
> 除了自研 SGLZ 算法，我们还集成了 NVIDIA nvCOMP LZ4 后端。在 Linux headers 文本类数据上，LZ4 后端将压缩率从 SGLZ 的 82.5% 降至 38.6%，同时由于物理 I/O 量减少，128 KB 顺序读带宽从 279 MB/s 提升至 581 MB/s，实现了压缩率更高、读带宽更高的双赢。

**关键数据**：
- SGLZ：压缩率 82.5%，读带宽 279 MB/s
- LZ4：压缩率 38.6%，读带宽 581 MB/s

---

### 镜头 9：真实场景 — 数据库白名单

**时长**：约 30 秒

**画面**：终端执行

```bash
# 数据库白名单测试
bash tests/db_whitelist.sh
```

**旁白**：
> 真实 workload 中，SQLite 和 LevelDB 等数据库文件在 offset 0 处具有严格的 magic 格式。GPUC 的 56 字节 RAW header 会破坏这些格式。我们实现了数据库文件白名单机制，对 .db、.wal、.log、.ldb、.sst、CURRENT、MANIFEST-* 等文件直接透传，不附加 header。测试显示 SQLite 和 LevelDB 均可正常工作。

---

### 镜头 10：真实场景 — CPU fallback

**时长**：约 30 秒

**画面**：终端执行

```bash
# 模拟无 GPU 环境，验证 CPU fallback
CUDA_VISIBLE_DEVICES="" LD_PRELOAD=./bin/libgpuhook.so ./bin/test_hook read /tmp/test.bin 262144
```

**旁白**：
> 为了保证系统的高可用性，当 GPU 不可用时，Hook 会自动 fallback 到 CPU 后端。这里我们通过 CUDA_VISIBLE_DEVICES 模拟无 GPU 环境，可以看到 Hook 检测到 GPU 初始化失败后自动切换到 CPU 后端，数据读取仍然正确。

---

### 镜头 11：总结

**时长**：约 30 秒

**画面**：
- 显示 PPT 总结页或终端显示项目主页
- 展示关键数据表格

**旁白**：
> 总结来说，GPUC 通过 LD_PRELOAD 实现了非侵入式 GPU 存储压缩卸载。在 32 线程高并发下读性能达到 Baseline 的 99.8%，mmap 返回时间提升 10.4 倍，nvCOMP LZ4 后端将文本类数据压缩率降至 38.6%。系统具备 CPU fallback、CRC32 校验、原子替换等生产级基础，所有实验均可一键复现。

---

## 四、操作步骤清单

### 步骤 1：打开终端并进入项目目录

```bash
cd /home/ubuntu/project3136859-386240
```

### 步骤 2：环境介绍（可选显示）

```bash
nvidia-smi --query-gpu=name,memory.total,compute_cap --format=csv
nvcc --version
mount | grep "on / "
```

### 步骤 3：环境检查与编译

```bash
bash scripts/check_env.sh
make clean && make all -j
ls -lh bin/
```

### 步骤 4：一键 DEMO

```bash
bash scripts/demo.sh
```

### 步骤 5：顺序读性能测试

```bash
bash tests/benchmark_fio.sh
```

### 步骤 6：高并发测试

```bash
bash tests/benchmark_high_concurrency.sh
```

### 步骤 7：mmap 测试

```bash
bash tests/mmap_size_sweep.sh
```

### 步骤 8：LZ4 后端测试

```bash
bash tests/nvcomp_lz4.sh
```

### 步骤 9：数据库白名单测试

```bash
bash tests/db_whitelist.sh
```

### 步骤 10：CPU fallback 验证

```bash
# 先准备一个测试文件
LD_PRELOAD=./bin/libgpuhook.so GPUCOMPRESS_QUIET=1 \
    dd if=/dev/zero of=/tmp/test.bin bs=1M count=10 status=none

# 压缩
./bin/gpu_compress_daemon /tmp/

# 模拟无 GPU 读取
CUDA_VISIBLE_DEVICES="" LD_PRELOAD=./bin/libgpuhook.so ./bin/test_hook read /tmp/test.bin 1048576
```

---

## 五、录制技巧

1. **提前预演**：所有命令先执行一遍，确保不会因等待或报错而冷场。
2. **控制节奏**：每个镜头之间可暂停 1–2 秒，便于后期剪辑。
3. **突出关键数据**：实验输出中关键数字可用鼠标高亮或后期加字幕。
4. **保持终端清晰**：避免过多历史命令，必要时用 `clear` 清屏。
5. **背景音乐**：片头和总结可添加轻音乐，讲解时静音。
6. **字幕**：关键旁白可配中文字幕，特别是技术术语和数据。

---

## 六、后期剪辑建议

| 时间点 | 建议 |
|---|---|
| 0:00–0:10 | 片头淡入，配标题音乐 |
| 0:10–1:00 | 环境介绍 + 编译，可适当加速（1.5x） |
| 1:00–2:30 | 一键 DEMO，正常速度，突出压缩效果 |
| 2:30–5:30 | 核心实验，每个实验后暂停展示数据表格 |
| 5:30–6:30 | 真实场景 + 总结 |
| 6:30–7:00 | 片尾：项目信息、GitLab 地址、致谢 |
