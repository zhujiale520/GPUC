#!/bin/bash
set -e

# ============================================================
#  Mixed Compressibility Integration Test
# ============================================================
# 生成"前半可压缩 + 后半不可压缩"的混合数据文件，
# 验证 Daemon 压缩后同一文件中同时存在压缩块与未压缩块。
# 与 compressibility_gradient.sh 区别：
#   - 本脚本验证单文件混合场景的正确性
#   - compressibility_gradient.sh 测试不同可压缩率梯度下的性能
# ============================================================

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINDIR="$PROJECT_DIR/bin"
TESTDIR="/tmp/gpuc_mixed_test_$$"

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:$BINDIR"

echo "=== Mixed Compressibility Integration Test ==="
echo "Test directory: $TESTDIR"

mkdir -p "$TESTDIR"

# 编译测试程序
echo "[1/6] Compiling test program..."
gcc -I"$PROJECT_DIR/include" "$PROJECT_DIR/src/test_hook.c" -o "$BINDIR/test_hook"

# 使用 LD_PRELOAD 写入混合数据文件（前半可压缩，后半不可压缩）
echo "[2/6] Writing mixed compressibility file..."
LD_PRELOAD="$BINDIR/libgpuhook.so" "$BINDIR/test_hook" writemixed "$TESTDIR/test.bin" 262144

# 检查物理文件是否有 header
echo "[3/6] Checking RAW header..."
python3 << EOF
import struct, sys
path = "$TESTDIR/test.bin"
with open(path, 'rb') as f:
    data = f.read(64)
    magic = struct.unpack('<I', data[0:4])[0]
    if magic != 0x47505543:
        print(f"FAIL: Magic mismatch: {hex(magic)}")
        sys.exit(1)
    state = data[24]
    if state != 0:
        print(f"FAIL: Expected RAW state, got {state}")
        sys.exit(1)
    print("OK: RAW header valid")
EOF

# 使用 LD_PRELOAD 读取 RAW 状态文件
echo "[4/6] Reading RAW state file..."
LD_PRELOAD="$BINDIR/libgpuhook.so" "$BINDIR/test_hook" readmixed "$TESTDIR/test.bin" 262144

# 运行 Daemon 压缩
echo "[5/6] Running compression daemon..."
"$BINDIR/gpu_compress_daemon" "$TESTDIR"

# 检查压缩后 header 和 block 表，验证存在 comp_len == orig_len 的 block
echo "[6/6] Verifying mixed compression result..."
python3 << EOF
import struct, sys

path = "$TESTDIR/test.bin"
with open(path, 'rb') as f:
    # 读取 header
    hdr = f.read(56)
    state = hdr[24]
    orig_size = struct.unpack('<Q', hdr[8:16])[0]
    num_blocks = struct.unpack('<I', hdr[20:24])[0]
    header_size = struct.unpack('<Q', hdr[32:40])[0]
    
    if state != 1:
        print(f"FAIL: Expected COMPRESSED state, got {state}")
        sys.exit(1)
    
    # 对齐格式的 header_size 包含 4 KiB padding，entry 仍固定为 24 字节。
    flags = struct.unpack('<H', hdr[26:28])[0]
    entry_size = 24 if flags & 1 else (header_size - 56) // num_blocks
    if entry_size not in (16, 24):
        print(f"FAIL: Invalid block entry size: {entry_size}")
        sys.exit(1)
    blocks = []
    for i in range(num_blocks):
        entry = f.read(entry_size)
        orig_len, comp_len, offset = struct.unpack('<IIQ', entry[0:16])
        crc32 = struct.unpack('<I', entry[16:20])[0] if entry_size >= 24 else 0
        blocks.append((orig_len, comp_len, offset, crc32))
    
    print(f"OK: State=COMPRESSED, num_blocks={num_blocks}, header_size={header_size}")
    
    # 检查是否有不可压缩 block（comp_len == orig_len）
    uncompressed_found = False
    for i, (ol, cl, off, crc) in enumerate(blocks):
        status = "RAW" if cl == ol else "COMPRESSED"
        crc_str = f", crc32={crc:08x}" if entry_size >= 24 else ""
        print(f"  Block {i}: orig_len={ol}, comp_len={cl}, offset={off}{crc_str} [{status}]")
        if ol == 0 or cl == 0 or off < header_size:
            print(f"FAIL: Invalid block {i}")
            sys.exit(1)
        if cl == ol:
            uncompressed_found = True
    
    if not uncompressed_found:
        print("FAIL: No uncompressed block found (all blocks compressed)")
        sys.exit(1)
    
    print("OK: Found at least one uncompressed block (comp_len == orig_len)")
EOF

# 使用 LD_PRELOAD 读取 COMPRESSED 状态文件（关键测试：包含不可压缩 block）
echo "[7/7] Reading COMPRESSED state file with mixed blocks..."
LD_PRELOAD="$BINDIR/libgpuhook.so" "$BINDIR/test_hook" readmixed "$TESTDIR/test.bin" 262144

echo ""
echo "=== ALL MIXED COMPRESSIBILITY TESTS PASSED ==="

# 清理
rm -rf "$TESTDIR"
