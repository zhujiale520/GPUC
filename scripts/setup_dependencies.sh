#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
NVCOMP_ROOT="$PROJECT_DIR/third_party/nvcomp"
NVCOMP_INC="$NVCOMP_ROOT/usr/include/nvcomp_12/nvcomp/lz4.h"
NVCOMP_SO="$NVCOMP_ROOT/usr/lib/x86_64-linux-gnu/nvcomp/12/libnvcomp.so"
LZ4_DIR="$PROJECT_DIR/third_party/lz4"

mkdir -p "$NVCOMP_ROOT" "$LZ4_DIR"

find_nvcomp_deb() {
    local name=$1
    local candidate
    for candidate in \
        "$NVCOMP_ROOT"/"$name"_*.deb \
        "$PROJECT_DIR/deps"/"$name"_*.deb; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

if [ ! -f "$NVCOMP_INC" ] || [ ! -f "$NVCOMP_SO" ]; then
    runtime_deb="$(find_nvcomp_deb libnvcomp4-cuda-12 || true)"
    dev_deb="$(find_nvcomp_deb libnvcomp4-dev-cuda-12 || true)"
    if [ -n "$runtime_deb" ] && [ -n "$dev_deb" ]; then
        echo "[SETUP] Extracting nvCOMP packages locally..."
        dpkg-deb -x "$runtime_deb" "$NVCOMP_ROOT"
        dpkg-deb -x "$dev_deb" "$NVCOMP_ROOT"
    fi
fi

if [ ! -f "$NVCOMP_INC" ] || [ ! -f "$NVCOMP_SO" ]; then
    echo "[ERROR] nvCOMP 4.x for CUDA 12 was not found."
    echo "Place these NVIDIA packages in deps/ or third_party/nvcomp/:"
    echo "  libnvcomp4-cuda-12_<version>_amd64.deb"
    echo "  libnvcomp4-dev-cuda-12_<version>_amd64.deb"
    echo "The validated project version is 4.2.0.11."
    exit 1
fi

if [ ! -e "$LZ4_DIR/liblz4.so" ]; then
    system_lz4="$(ldconfig -p 2>/dev/null | awk '/liblz4\.so\.1 \(/{print $NF; exit}')"
    if [ -z "$system_lz4" ] || [ ! -f "$system_lz4" ]; then
        echo "[ERROR] liblz4.so.1 was not found. Install the liblz4 runtime package."
        exit 1
    fi
    ln -s "$system_lz4" "$LZ4_DIR/liblz4.so"
fi

echo "[OK] nvCOMP header: $NVCOMP_INC"
echo "[OK] nvCOMP library: $NVCOMP_SO"
echo "[OK] liblz4: $(readlink -f "$LZ4_DIR/liblz4.so")"
echo "Dependencies are ready. Run: make all"
