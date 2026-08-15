#!/usr/bin/env bash

# 鲲鹏 + 天数智芯 CoreX 部署前只读检查。任何单项失败都继续执行，便于一次收集完整信息。
COREX_HOME="${COREX_HOME:-/usr/local/corex-4.4.0}"
export PATH="$COREX_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$COREX_HOME/lib64${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"

section() {
    printf '\n========== %s ==========\n' "$1"
}

section "系统信息"
uname -a
if [ -r /etc/os-release ]; then
    sed -n '1,8p' /etc/os-release
fi

section "CPU 信息"
lscpu | grep -E 'Architecture|架构|Vendor ID|厂商 ID|Model name|型号名称|CPU\(s\)|Socket|座|Core|核心|NUMA|L1|L2|L3' || true

section "CPU 详细标识"
grep -m1 -E 'model name|CPU implementer|Hardware|Processor' /proc/cpuinfo || \
    echo "[WARN] /proc/cpuinfo 未提供型号字段（AArch64 平台较常见）"

section "GPU PCIe 识别"
lspci -nnk | grep -A3 -E 'VGA|3D|Display|Processing accelerators' || true

section "CoreX 驱动与设备节点"
lsmod | grep -E 'iluvatar|corex' || echo "[FAIL] 未发现 iluvatar/corex 内核模块"
if compgen -G '/dev/iluvatar*' >/dev/null || compgen -G '/dev/ix*' >/dev/null || \
   [ -e /dev/itrctl ]; then
    ls -l /dev/iluvatar* /dev/ix* /dev/itrctl 2>/dev/null
else
    if tr '\0' ' ' </proc/1/cmdline 2>/dev/null | grep -q 'bwrap.*--dev /dev'; then
        echo "[WARN] Codex/bwrap 使用隔离 /dev；请在宿主机 Shell 复查，不代表 GPU 未安装"
    else
        echo "[FAIL] 未发现 CoreX GPU 设备节点；容器部署时需要映射宿主机 GPU 设备"
    fi
fi

section "GPU 状态 (ixsmi)"
if command -v ixsmi >/dev/null 2>&1; then
    ixsmi || echo "[FAIL] ixsmi 无法访问 GPU"
else
    echo "[FAIL] 未找到 ixsmi"
fi

section "CoreX 编译工具链"
if [ -x "$COREX_HOME/bin/clang++" ]; then
    "$COREX_HOME/bin/clang++" --version 2>&1 | sed -n '1,4p'
    probe_dir="$(mktemp -d)"
    printf '%s\n' '__global__ void k(void) {}' 'int main(void) { k<<<1,1>>>(); return 0; }' > "$probe_dir/probe.cu"
    if "$COREX_HOME/bin/clang++" -x ivcore --cuda-path="$COREX_HOME" \
       --offload-arch=ivcore11 -c "$probe_dir/probe.cu" \
       -o "$probe_dir/probe.o" >/dev/null 2>&1 && \
       [ -s "$probe_dir/probe.o" ]; then
        echo "[PASS] CoreX Clang/ivcore11 可生成目标文件"
    else
        echo "[FAIL] CoreX Clang 无法编译 ivcore11 CUDA 源码"
    fi
    rm -rf "$probe_dir"
else
    echo "[FAIL] 未找到 $COREX_HOME/bin/clang++"
fi

section "GPU 温度与功耗"
if command -v ixsmi >/dev/null 2>&1; then
    ixsmi -q 2>/dev/null | grep -E 'Temperature|Power' || echo "[WARN] 当前无法读取温度/功耗"
fi

section "内存使用"
free -h

section "磁盘使用"
df -h /
