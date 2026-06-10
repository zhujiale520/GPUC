#!/bin/bash
# ============================================================
#  GPU Compress - 新主机环境检查脚本
#  用法: bash scripts/check_env.sh
# ============================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

PASS=0
FAIL=0
WARN=0

check_cmd() {
    local name=$1
    local cmd=$2
    if which "$cmd" >/dev/null 2>&1; then
        local ver
        ver=$($cmd --version 2>/dev/null | head -1 || echo 'installed')
        echo -e "${GREEN}[PASS]${NC} $name: $ver"
        ((PASS++))
        return 0
    else
        echo -e "${RED}[FAIL]${NC} $name: not found"
        ((FAIL++))
        return 1
    fi
}

check_gpu() {
    echo ""
    echo -e "${BLUE}--- GPU / CUDA 检测 ---${NC}"
    if which nvidia-smi >/dev/null 2>&1; then
        local gpu_info=$(nvidia-smi --query-gpu=name,compute_cap --format=csv,noheader 2>/dev/null | head -1)
        if [ -n "$gpu_info" ]; then
            echo -e "${GREEN}[PASS]${NC} NVIDIA GPU detected: $gpu_info"
            local cap=$(echo "$gpu_info" | awk -F', ' '{print $2}' | tr -d '.')
            echo -e "${GREEN}[INFO]${NC} Makefile will use: -arch=sm_$cap"
            ((PASS++))
        else
            echo -e "${YELLOW}[WARN]${NC} nvidia-smi exists but no GPU found"
            ((WARN++))
        fi
    else
        echo -e "${YELLOW}[WARN]${NC} nvidia-smi not found (GPU driver may not be installed)"
        echo -e "${YELLOW}[WARN]${NC} You can still build CPU-only targets: make bin/libcpuhook.so bin/cpu_compress_daemon"
        ((WARN++))
    fi

    if which nvcc >/dev/null 2>&1; then
        echo -e "${GREEN}[PASS]${NC} nvcc: $(nvcc --version | grep release | sed 's/.*release //')"
        ((PASS++))
    else
        echo -e "${RED}[FAIL]${NC} nvcc not found. Install CUDA Toolkit first."
        ((FAIL++))
    fi
}

check_headers() {
    echo ""
    echo -e "${BLUE}--- 系统头文件 / 特性 ---${NC}"
    local kernel=$(uname -r)
    echo -e "${GREEN}[INFO]${NC} Kernel version: $kernel"

    if [ -f /usr/include/linux/io_uring.h ] || [ -f /usr/src/linux-headers-${kernel}/include/linux/io_uring.h ]; then
        echo -e "${GREEN}[PASS]${NC} io_uring headers found"
        ((PASS++))
    else
        echo -e "${YELLOW}[WARN]${NC} io_uring headers not found. Hook will fallback to pread64."
        echo -e "${YELLOW}[WARN]${NC}   Fix: sudo apt-get install linux-headers-$(uname -r)"
        ((WARN++))
    fi
}

check_build_env() {
    echo ""
    echo -e "${BLUE}--- 编译工具链 ---${NC}"
    check_cmd "gcc" "gcc"
    check_cmd "g++" "g++"
    check_cmd "make" "make"
    check_cmd "ldd" "ldd"
}

check_runtime_deps() {
    echo ""
    echo -e "${BLUE}--- 运行时 / 测试依赖 ---${NC}"
    check_cmd "fio" "fio"
    check_cmd "python3" "python3"
    check_cmd "bc" "bc"
    check_cmd "xxd" "xxd"
}

main() {
    echo "========================================"
    echo "  GPU Compress - 新主机环境检查"
    echo "========================================"

    check_build_env
    check_gpu
    check_headers
    check_runtime_deps

    echo ""
    echo "========================================"
    echo -e "  检查结果: ${GREEN}PASS=$PASS${NC} ${YELLOW}WARN=$WARN${NC} ${RED}FAIL=$FAIL${NC}"
    echo "========================================"

    if [ $FAIL -gt 0 ]; then
        echo -e "${RED}有必需依赖缺失，请先安装后再编译。${NC}"
        echo "快速安装（Ubuntu/Debian）:"
        echo "  sudo apt-get update"
        echo "  sudo apt-get install -y build-essential fio python3 bc xxd linux-headers-\$(uname -r)"
        exit 1
    elif [ $WARN -gt 0 ]; then
        echo -e "${YELLOW}环境基本可用，但有警告项（详见上方）。${NC}"
        echo "建议修复警告后获得最佳性能。"
        exit 0
    else
        echo -e "${GREEN}环境检查全部通过，可以执行 'make all && make test'${NC}"
        exit 0
    fi
}

main "$@"
