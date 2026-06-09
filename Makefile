# GPU Compress Makefile
# 基于 CUDA 的存储压缩卸载 - 操作系统设计赛项目

NVCC       = nvcc
NVCCFLAGS  = -arch=sm_70 -O3 -I./include -Xcompiler -Wno-maybe-uninitialized
LDFLAGS    = -lpthread

SRCDIR     = src
INCDIR     = include
BINDIR     = bin

TARGETS    = $(BINDIR)/libgpuhook.so $(BINDIR)/libcpuhook.so $(BINDIR)/gpu_compress_daemon $(BINDIR)/cpu_compress_daemon $(BINDIR)/test_cpu_vs_gpu

.PHONY: all clean test dirs unit-test integration-test

all: dirs $(TARGETS)

dirs:
	@mkdir -p $(BINDIR)

# LD_PRELOAD 共享库（GPU 默认，支持 GPUCOMPRESS_BACKEND=cpu 切换）
$(BINDIR)/libgpuhook.so: $(SRCDIR)/hook.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/cpu_compress.c
	$(NVCC) -shared -Xcompiler -fPIC $(NVCCFLAGS) $^ -o $@ -ldl $(LDFLAGS)

# 离线压缩后台程序 (GPU)
$(BINDIR)/gpu_compress_daemon: $(SRCDIR)/daemon.c $(SRCDIR)/gpu_compress.cu
	$(NVCC) $(NVCCFLAGS) $^ -o $@ $(LDFLAGS)

# LD_PRELOAD 共享库（纯 CPU 版本，无 CUDA 依赖）
$(BINDIR)/libcpuhook.so: $(SRCDIR)/hook.c $(SRCDIR)/cpu_compress.c
	gcc -shared -fPIC -O3 -DCPU_ONLY_BUILD -I./include $^ -o $@ -ldl -lpthread

# 离线压缩后台程序 (CPU 对比)
$(BINDIR)/cpu_compress_daemon: $(SRCDIR)/cpu_daemon.c $(SRCDIR)/cpu_compress.c
	gcc -O3 -I./include $^ -o $@ -lpthread

# 单元测试：压缩/解压一致性
$(BINDIR)/test_compress: $(SRCDIR)/test_compress.c $(SRCDIR)/gpu_compress.cu
	$(NVCC) $(NVCCFLAGS) $^ -o $@ $(LDFLAGS)

# CPU vs GPU 性能对比测试
$(BINDIR)/test_cpu_vs_gpu: $(SRCDIR)/test_cpu_vs_gpu.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/cpu_compress.c
	$(NVCC) $(NVCCFLAGS) $^ -o $@ $(LDFLAGS)

# Hook 集成测试程序
$(BINDIR)/test_hook: $(SRCDIR)/test_hook.c
	gcc -I$(INCDIR) $^ -o $@

unit-test: all $(BINDIR)/test_compress
	@echo "=== Running unit tests ==="
	$(BINDIR)/test_compress

integration-test: all $(BINDIR)/test_hook
	@echo "=== Running integration tests ==="
	bash tests/test_integration.sh
	bash tests/test_mixed_compressibility.sh
	bash tests/test_inline.sh

test: unit-test integration-test

clean:
	rm -rf $(BINDIR)
