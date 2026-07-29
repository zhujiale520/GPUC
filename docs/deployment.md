# GPU Compress - 部署与二次开发指南

## 1. 环境准备

### 1.1 硬件要求

- NVIDIA GPU（计算能力 ≥ 7.0）
  - 测试平台：Tesla V100-SXM2-32GB
  - 兼容：RTX 3060/4060/5060, A100, H100 等
- x86_64 或 aarch64（华为鲲鹏 920）服务器
- NVMe SSD 推荐（发挥压缩后 IO 优势）

### 1.2 软件依赖

```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y build-essential g++ gcc
sudo apt-get install -y nvidia-driver-xxx nvidia-cuda-toolkit
sudo apt-get install -y fio python3 bc xxd linux-headers-$(uname -r)

# 验证 CUDA
nvcc --version
nvidia-smi
```

### 1.3 新主机环境检查

项目提供一键环境检查脚本，自动检测 GPU 架构、CUDA 版本、依赖完整性：

```bash
bash scripts/check_env.sh
```

输出示例：
```
--- GPU / CUDA 检测 ---
[PASS] NVIDIA GPU detected: Tesla V100-SXM2-32GB, 7.0
[INFO] Makefile will use: -arch=sm_70
[PASS] nvcc: 12.8, V12.8.61
...
环境检查全部通过，可以执行 'make all && make test'
```

### 1.4 编译项目

```bash
cd gpu_compress
make clean
make all
```

说明：
- Makefile **自动检测 GPU 计算能力**（通过 `nvidia-smi`），无需手动修改 `-arch=sm_70`
- 若自动检测失败，可手动指定：`make GPU_ARCH=75`
- 若无可用的 GPU，仍可编译纯 CPU 目标：`make bin/libcpuhook.so bin/cpu_compress_daemon`

产物说明：
| 文件 | 说明 |
|------|------|
| `bin/libgpuhook.so` | LD_PRELOAD 共享库 |
| `bin/gpu_compress_daemon` | GPU 离线压缩 daemon |
| `bin/cpu_compress_daemon` | CPU 离线压缩 daemon（对比基准）|
| `bin/test_compress` | 单元测试 |
| `bin/test_cpu_vs_gpu` | CPU vs GPU 性能对比 |

## 2. 快速部署

### 2.1 单文件测试

```bash
# 1. 写入（自动附加 header）
LD_PRELOAD=./bin/libgpuhook.so dd if=/dev/zero of=/tmp/test.bin bs=1M count=100

# 2. 查看文件头
xxd -l 64 /tmp/test.bin

# 3. 后台 GPU 压缩
./bin/gpu_compress_daemon /tmp

# 4. 透明读取（自动解压）
LD_PRELOAD=./bin/libgpuhook.so cat /tmp/test.bin > /dev/null
```

### 2.2 目录监控模式

```bash
# 单次扫描
./bin/gpu_compress_daemon -r /data/to/compress

# 守护模式（每 60 秒扫描一次）
./bin/gpu_compress_daemon -d -r /data/to/compress

# 配合 systemd（可选）
# 创建 /etc/systemd/system/gpu-compress.service
```

### 2.3 对特定应用生效

```bash
# 只对某个应用加载 hook
LD_PRELOAD=/path/to/libgpuhook.so ./my_application

# 全局生效（写入 ~/.bashrc 或 /etc/ld.so.preload，不推荐生产环境）
export LD_PRELOAD=/path/to/libgpuhook.so
```

### 2.4 使用 LZ4 后端（可选）

默认使用本队自定义 SGLZ 算法。如需启用 NVIDIA nvCOMP LZ4，需要：

1. 本地准备 nvCOMP 库（解压到 `third_party/nvcomp`）并创建 liblz4 符号链接（`third_party/lz4/liblz4.so`）。
2. 编译时 Makefile 会自动链接上述库。
3. 启动 Daemon 时设置环境变量：

```bash
LD_PRELOAD=./bin/libgpuhook.so dd if=/usr/include of=/tmp/headers.tar bs=1M
GPUC_ALGO=lz4 ./bin/gpu_compress_daemon /tmp
LD_PRELOAD=./bin/libgpuhook.so cat /tmp/headers.tar | sha256sum
```

说明：
- 文本类数据使用 LZ4 通常比 SGLZ 压缩率更高。
- Hook 读取时根据文件 header 的 `comp_algo` 自动选择 SGLZ 或 LZ4 解压路径，无需用户干预。

## 3. 性能测试

### 3.1 CPU vs GPU 压缩吞吐对比

```bash
./bin/test_cpu_vs_gpu
```

输出示例：
```
GPU compress(batch):  0.035 s  =>    1843.7 MB/s
CPU compress:         0.054 s  =>    1181.2 MB/s
Speedup (batch vs CPU): 1.56x
```

### 3.2 端到端 fio 测试

```bash
bash tests/benchmark_fio.sh
```

测试项：
- Baseline 纯 CPU 读写
- Hook RAW 读写（带 header，未压缩）
- CPU Compressed 读（CPU 压缩后）
- GPU Compressed 读（GPU 压缩后实时解压）

### 3.3 资源监控

```bash
# 在运行测试时后台采样
bash scripts/monitor_resources.sh 1 120 ./logs &

# 然后运行 fio
bash tests/benchmark_fio.sh

# 分析日志
cat ./logs/cpu_usage.log
cat ./logs/gpu_usage.log
```

## 4. 二次开发

### 4.1 添加新的压缩算法

项目已采用可插拔后端设计，参考 `src/gpu_lz4.cu` / `src/cpu_lz4.c` 的实现方式：

1. 在 `include/file_header.h` 中添加算法标识：
```c
#define GPUC_ALGO_MYALGO 4
```

2. 新增 GPU 后端实现（如 `src/gpu_myalgo.cu`），提供：
```c
int gpu_myalgo_compress_batch(...);
int gpu_myalgo_decompress_batch(...);
int gpu_myalgo_compress_128k(...);
int gpu_myalgo_decompress_128k(...);
```

3. 新增 CPU fallback 实现（如 `src/cpu_myalgo.c`），提供相同接口的 CPU 版本。

4. 在 `src/daemon.c` 中根据 `GPUC_ALGO` 选择压缩后端；在 `src/hook.c` 中根据 `hdr.comp_algo` 选择解压后端。

5. 更新 `include/gpu_compress_api.h` 中的函数声明。

### 4.2 调整块大小

修改 `include/gpu_compress_api.h`：
```c
#define GC_BLOCK_SIZE   (256 * 1024)  // 改为 256KB
#define GC_NCHUNKS      64            // 相应调整
```

> 注意：块大小改变后需同步调整 CUDA kernel 的 grid/block 配置。

### 4.3 Hook 层扩展

当前 hook 拦截的调用：
- `open/open64/creat/openat/openat64`
- `read/write/pread64/pwrite64/readv/writev`
- `lseek/lseek64`
- `close`
- `__fxstat/__fxstat64`

如需支持 `mmap`：
- 实现 `mmap/munmap/msync` 拦截
- 在 mmap 时预解压整个文件到匿名映射区
- 复杂度较高，建议作为内核态方案实现

### 4.4 集成到 Ganymede

将压缩下沉到 Ganymede 内核路径：
1. 在 `libgeminiFs_src/geminifs.cu` 的 `CachePage::__read_in` 中添加解压逻辑
2. 在 `CachePage::__write_back` 中添加压缩逻辑
3. 复用 `gpu_compress.cu` 中的 batch API

## 5. 故障排查

### 5.1 fio 段错误

```bash
# 如果 fio 崩溃，尝试禁用 hook 确认问题
GPUC_NO_HOOK=1 LD_PRELOAD=./bin/libgpuhook.so fio ...
```

### 5.2 压缩率异常

- 检查数据本身是否可压缩（随机数据无法压缩）
- 使用 `./bin/test_compress` 验证算法正确性

### 5.3 GPU 初始化失败

```bash
# 检查 CUDA 环境
nvidia-smi
nvcc --version
cudaSetDevice 返回值检查
```

### 5.4 Hook 不生效

- 确认 `LD_PRELOAD` 路径正确
- 确认应用是动态链接的（`ldd ./app` 查看）
- 静态编译的程序无法被 LD_PRELOAD 拦截

## 6. 安全注意事项

1. **Daemon 并发安全**：文件被打开时进行压缩可能导致状态不一致，建议在低峰期运行
2. **磁盘空间**：压缩过程中需要同目录临时文件（`.gpuc_tmp`），确保磁盘有足够空间
3. **备份**：生产环境使用前请先备份重要数据
