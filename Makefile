# GPU Compress Makefile
# 基于 CUDA 的存储压缩卸载 - 操作系统设计赛项目
# 适配新主机：自动检测 GPU 架构，一键编译/测试

NVCC       ?= nvcc
GCC        ?= gcc

# ----------------------------------------------------------
# 自动检测 GPU 计算能力（优先 nvidia-smi）
# 仅接受形如 7.0 / 8.6 的有效输出，避免驱动异常文本进入 -arch。
# 可通过 make GPU_ARCH=70 显式覆盖。
# ----------------------------------------------------------
GPU_ARCH_DETECTED := $(shell nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null \
	| awk -F. '/^[0-9]+\.[0-9]+/ { gsub(/[^0-9]/, "", $$2); print $$1 $$2; exit }')
GPU_ARCH ?= $(GPU_ARCH_DETECTED)
ifeq ($(strip $(GPU_ARCH)),)
    GPU_ARCH := 70
    $(warning GPU auto-detect failed, defaulting to sm_70. Override with: make GPU_ARCH=75)
endif
# Ablation study flags: pass via make ABLATION_FLAGS="-DGPUC_NO_BATCH"
ABLATION_FLAGS ?=

# ----------------------------------------------------------
# nvCOMP LZ4 backend（下载到 third_party/nvcomp，无需系统安装）
# ----------------------------------------------------------
PROJECT_ROOT := $(CURDIR)
NVCOMP_ROOT ?= $(PROJECT_ROOT)/third_party/nvcomp
NVCOMP_INC  := $(NVCOMP_ROOT)/usr/include/nvcomp_12
NVCOMP_LIB  := $(NVCOMP_ROOT)/usr/lib/x86_64-linux-gnu/nvcomp/12
NVCOMP_FLAGS = -I$(NVCOMP_INC)
NVCOMP_LINK  = -L$(NVCOMP_LIB) -lnvcomp -Xlinker -rpath -Xlinker $(NVCOMP_LIB)

# liblz4 runtime 已存在，本地创建符号链接用于链接期
LZ4_LIB     := $(PROJECT_ROOT)/third_party/lz4
ifneq ($(wildcard $(LZ4_LIB)/liblz4.so),)
LZ4_LINK    = -L$(LZ4_LIB) -llz4 -Xlinker -rpath -Xlinker $(LZ4_LIB)
else
LZ4_LINK    = -Xlinker -l:liblz4.so.1
endif

NVCCFLAGS  = -arch=sm_$(GPU_ARCH) -O3 -I./include $(NVCOMP_FLAGS) -Xcompiler -Wno-maybe-uninitialized -Wno-deprecated-gpu-targets $(ABLATION_FLAGS)
LDFLAGS    = -lpthread $(LZ4_LINK)

SRCDIR     = src
INCDIR     = include
BINDIR     = bin

# 所有编译产物
TARGETS    = $(BINDIR)/libgpuhook.so $(BINDIR)/libcpuhook.so \
             $(BINDIR)/gpu_compress_daemon $(BINDIR)/cpu_compress_daemon \
             $(BINDIR)/test_cpu_vs_gpu $(BINDIR)/test_lz4_cpu_gpu $(BINDIR)/test_cpu_offload \
             $(BINDIR)/test_compress $(BINDIR)/test_hook $(BINDIR)/test_cold_read \
             $(BINDIR)/test_odirect_compressed

.PHONY: all clean test dirs unit-test integration-test check-env check-gpu-deps cpu-only smoke-test sanitizer-test coverage-test docs-check

# ----------------------------------------------------------
# 默认目标
# ----------------------------------------------------------
all: check-gpu-deps dirs $(TARGETS)
	@echo "========================================"
	@echo "  Build complete! GPU arch: sm_$(GPU_ARCH)"
	@echo "  Run 'make test' to verify."
	@echo "========================================"

dirs:
	@mkdir -p $(BINDIR)

check-gpu-deps:
	@test -f "$(NVCOMP_INC)/nvcomp/lz4.h" || { \
		echo "[MISSING] nvCOMP headers: $(NVCOMP_INC)/nvcomp/lz4.h"; \
		echo "Run: bash scripts/setup_dependencies.sh"; \
		exit 1; \
	}
	@test -f "$(NVCOMP_LIB)/libnvcomp.so" || { \
		echo "[MISSING] nvCOMP library: $(NVCOMP_LIB)/libnvcomp.so"; \
		echo "Run: bash scripts/setup_dependencies.sh"; \
		exit 1; \
	}

cpu-only: dirs $(BINDIR)/libcpuhook.so $(BINDIR)/cpu_compress_daemon $(BINDIR)/test_hook
	@echo "CPU-only build complete."

smoke-test: cpu-only
	bash tests/test_posix_semantics.sh
	bash tests/test_corrupt_headers.sh
	bash tests/test_header_fuzz.sh

sanitizer-test:
	bash tests/sanitizer_cpu.sh

coverage-test:
	bash tests/coverage_cpu.sh

docs-check:
	python3 scripts/check_docs_links.py

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
$(BINDIR)/libgpuhook.so: check-gpu-deps dirs $(SRCDIR)/hook.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/cpu_compress.c $(SRCDIR)/cpu_lz4.c $(SRCDIR)/gpu_lz4.cu
	$(NVCC) -shared -Xcompiler -fPIC $(NVCCFLAGS) $(filter-out dirs check-gpu-deps,$^) -o $@ -ldl $(NVCOMP_LINK) $(LDFLAGS)

# ----------------------------------------------------------
# 离线压缩后台程序 (GPU)
# ----------------------------------------------------------
$(BINDIR)/gpu_compress_daemon: check-gpu-deps dirs $(SRCDIR)/daemon.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/gpu_lz4.cu
	$(NVCC) $(NVCCFLAGS) $(filter-out dirs check-gpu-deps,$^) -o $@ $(NVCOMP_LINK) $(LDFLAGS)

# ----------------------------------------------------------
# LD_PRELOAD 共享库（纯 CPU 版本，无 CUDA 依赖）
# ----------------------------------------------------------
$(BINDIR)/libcpuhook.so: dirs $(SRCDIR)/hook.c $(SRCDIR)/cpu_compress.c $(SRCDIR)/cpu_lz4.c
	$(GCC) -shared -fPIC -O3 -DCPU_ONLY_BUILD -I./include $(filter-out dirs,$^) -o $@ -ldl -lpthread $(LZ4_LINK)

# ----------------------------------------------------------
# 离线压缩后台程序 (CPU 对比)
# ----------------------------------------------------------
$(BINDIR)/cpu_compress_daemon: dirs $(SRCDIR)/cpu_daemon.c $(SRCDIR)/cpu_compress.c $(SRCDIR)/cpu_lz4.c
	$(GCC) -O3 -I./include $(filter-out dirs,$^) -o $@ -lpthread $(LZ4_LINK)

# ----------------------------------------------------------
# 单元测试：压缩/解压一致性
# ----------------------------------------------------------
$(BINDIR)/test_compress: check-gpu-deps dirs $(SRCDIR)/test_compress.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/gpu_lz4.cu
	$(NVCC) $(NVCCFLAGS) $(filter-out dirs check-gpu-deps,$^) -o $@ $(NVCOMP_LINK) $(LDFLAGS)

# ----------------------------------------------------------
# CPU vs GPU 性能对比测试
# ----------------------------------------------------------
$(BINDIR)/test_cpu_vs_gpu: check-gpu-deps dirs $(SRCDIR)/test_cpu_vs_gpu.c $(SRCDIR)/gpu_compress.cu $(SRCDIR)/cpu_compress.c $(SRCDIR)/cpu_lz4.c $(SRCDIR)/gpu_lz4.cu
	$(NVCC) $(NVCCFLAGS) $(filter-out dirs check-gpu-deps,$^) -o $@ $(NVCOMP_LINK) $(LDFLAGS)

$(BINDIR)/test_lz4_cpu_gpu: check-gpu-deps dirs tests/test_lz4_cpu_gpu.c $(SRCDIR)/cpu_lz4.c $(SRCDIR)/gpu_lz4.cu
	$(NVCC) $(NVCCFLAGS) $(filter-out dirs check-gpu-deps,$^) -o $@ $(NVCOMP_LINK) $(LDFLAGS)

$(BINDIR)/test_cpu_offload: check-gpu-deps dirs tests/test_cpu_offload.cpp $(SRCDIR)/cpu_lz4.c $(SRCDIR)/gpu_lz4.cu
	$(NVCC) $(NVCCFLAGS) $(filter-out dirs check-gpu-deps,$^) -o $@ $(NVCOMP_LINK) $(LDFLAGS)

# ----------------------------------------------------------
# Hook 集成测试程序
# ----------------------------------------------------------
$(BINDIR)/test_hook: dirs $(SRCDIR)/test_hook.c
	$(GCC) -I$(INCDIR) $(filter-out dirs,$^) -o $@

$(BINDIR)/test_cold_read: dirs tests/test_cold_read.c
	$(GCC) -O3 $(filter-out dirs,$^) -o $@

$(BINDIR)/test_odirect_compressed: dirs tests/test_odirect_compressed.c
	$(GCC) -O3 $(filter-out dirs,$^) -o $@

$(BINDIR)/test_shared_pread: dirs tests/test_shared_pread.c
	$(GCC) -O2 -Wall -Wextra -pthread $(filter-out dirs,$^) -o $@

# ----------------------------------------------------------
# 测试目标
# ----------------------------------------------------------
unit-test: all $(BINDIR)/test_compress
	@echo "=== Running unit tests ==="
	$(BINDIR)/test_compress

integration-test: all $(BINDIR)/test_hook $(BINDIR)/test_shared_pread
	@echo "=== Running integration tests ==="
	bash tests/test_integration.sh
	bash tests/test_mixed_compressibility.sh
	bash tests/test_inline.sh
	bash tests/test_shared_pread.sh
	bash tests/test_empty_readonly_passthrough.sh

test: unit-test integration-test

# ----------------------------------------------------------
# 清理
# ----------------------------------------------------------
clean:
	rm -rf $(BINDIR)
