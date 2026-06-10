# GPU Compress Makefile
# 基于 CUDA 的存储压缩卸载 - 操作系统设计赛项目
# 适配新主机：自动检测 GPU 架构，一键编译/测试

NVCC       ?= nvcc
GCC        ?= gcc

# ----------------------------------------------------------
# 自动检测 GPU 计算能力（优先 nvidia-smi）
# ----------------------------------------------------------
GPU_ARCH   := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -1 | tr -d '.')
ifeq ($(GPU_ARCH),)
    GPU_ARCH := 70
    $(warning GPU auto-detect failed, defaulting to sm_70. Override with: make GPU_ARCH=75)
endif
NVCCFLAGS  = -arch=sm_$(GPU_ARCH) -O3 -I./include -Xcompiler -Wno-maybe-uninitialized -Wno-deprecated-gpu-targets
LDFLAGS    = -lpthread

SRCDIR     = src
INCDIR     = include
BINDIR     = bin

# 所有编译产物
TARGETS    = $(BINDIR)/libgpuhook.so $(BINDIR)/libcpuhook.so \
             $(BINDIR)/gpu_compress_daemon $(BINDIR)/cpu_compress_daemon \
             $(BINDIR)/test_cpu_vs_gpu $(BINDIR)/test_compress $(BINDIR)/test_hook

.PHONY: all clean test dirs unit-test integration-test check-env

# ----------------------------------------------------------
# 默认目标
# ----------------------------------------------------------
all: dirs $(TARGETS)
	@echo "========================================"
	@echo "  Build complete! GPU arch: sm_$(GPU_ARCH)"
	@echo "  Run 'make test' to verify."
	@echo "========================================"

dirs:
	@mkdir -p $(BINDIR)

# ----------------------------------------------------------
# 环境检查
# ----------------------------------------------------------
check-env:
	@echo "=== GPU Compress Environment Check ==="
	@echo "--- Compiler ---"
	@which $(NVCC) >/dev/null 2>&1 && $(NVCC) --version | head -1 || echo "[MISSING] nvcc not found"
	@which $(GCC) >/dev/null 2>&1 && $(GCC) --version | head -1 || echo "[MISSING] gcc not found"
	@echo "--- GPU ---"
	@which nvidia-smi >/dev/null 2>&1 && nvidia-smi --query-gpu=name,compute_cap --format=csv || echo "[MISSING] nvidia-smi not found (GPU driver may not be installed)"
	@echo "--- Dependencies ---"
	@which fio >/dev/null 2>&1 && echo "[OK] fio" || echo "[MISSING] fio (apt-get install fio)"
	@which python3 >/dev/null 2>&1 && echo "[OK] python3" || echo "[MISSING] python3"
	@which bc >/dev/null 2>&1 && echo "[OK] bc" || echo "[MISSING] bc (apt-get install bc)"
	@echo "--- Kernel Headers (for io_uring) ---"
	@echo "Kernel: $$(uname -r)"
	@echo "========================================"

# ----------------------------------------------------------
# LD_PRELOAD 共享库（GPU 默认，支持 GPUCOMPRESS_BACKEND=cpu 切换）
# ----------------------------------------------------------
$(BINDIR)/libgpuhook.so: $(SRCDIR)/hook.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/cpu_compress.c
	$(NVCC) -shared -Xcompiler -fPIC $(NVCCFLAGS) $^ -o $@ -ldl $(LDFLAGS)

# ----------------------------------------------------------
# 离线压缩后台程序 (GPU)
# ----------------------------------------------------------
$(BINDIR)/gpu_compress_daemon: $(SRCDIR)/daemon.c $(SRCDIR)/gpu_compress.cu
	$(NVCC) $(NVCCFLAGS) $^ -o $@ $(LDFLAGS)

# ----------------------------------------------------------
# LD_PRELOAD 共享库（纯 CPU 版本，无 CUDA 依赖）
# ----------------------------------------------------------
$(BINDIR)/libcpuhook.so: $(SRCDIR)/hook.c $(SRCDIR)/cpu_compress.c
	$(GCC) -shared -fPIC -O3 -DCPU_ONLY_BUILD -I./include $^ -o $@ -ldl -lpthread

# ----------------------------------------------------------
# 离线压缩后台程序 (CPU 对比)
# ----------------------------------------------------------
$(BINDIR)/cpu_compress_daemon: $(SRCDIR)/cpu_daemon.c $(SRCDIR)/cpu_compress.c
	$(GCC) -O3 -I./include $^ -o $@ -lpthread

# ----------------------------------------------------------
# 单元测试：压缩/解压一致性
# ----------------------------------------------------------
$(BINDIR)/test_compress: $(SRCDIR)/test_compress.c $(SRCDIR)/gpu_compress.cu
	$(NVCC) $(NVCCFLAGS) $^ -o $@ $(LDFLAGS)

# ----------------------------------------------------------
# CPU vs GPU 性能对比测试
# ----------------------------------------------------------
$(BINDIR)/test_cpu_vs_gpu: $(SRCDIR)/test_cpu_vs_gpu.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/cpu_compress.c
	$(NVCC) $(NVCCFLAGS) $^ -o $@ $(LDFLAGS)

# ----------------------------------------------------------
# Hook 集成测试程序
# ----------------------------------------------------------
$(BINDIR)/test_hook: $(SRCDIR)/test_hook.c
	$(GCC) -I$(INCDIR) $^ -o $@

# ----------------------------------------------------------
# 测试目标
# ----------------------------------------------------------
unit-test: all $(BINDIR)/test_compress
	@echo "=== Running unit tests ==="
	$(BINDIR)/test_compress

integration-test: all $(BINDIR)/test_hook
	@echo "=== Running integration tests ==="
	bash tests/test_integration.sh
	bash tests/test_mixed_compressibility.sh
	bash tests/test_inline.sh

test: unit-test integration-test

# ----------------------------------------------------------
# 清理
# ----------------------------------------------------------
clean:
	rm -rf $(BINDIR)
