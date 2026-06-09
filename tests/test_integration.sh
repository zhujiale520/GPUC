#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
BINDIR="$PROJECT_DIR/bin"
TESTDIR="/tmp/gpuc_test_$$"

export LD_LIBRARY_PATH="${LD_LIBRARY_PATH}:$BINDIR"

echo "=== GPU Compress Integration Test ==="
echo "Test directory: $TESTDIR"

mkdir -p "$TESTDIR"

# 编译测试程序
echo "[1/7] Compiling test program..."
gcc -I"$PROJECT_DIR/include" "$PROJECT_DIR/src/test_hook.c" -o "$BINDIR/test_hook"

# 使用 LD_PRELOAD 写入文件
echo "[2/7] Writing test file with LD_PRELOAD..."
LD_PRELOAD="$BINDIR/libgpuhook.so" "$BINDIR/test_hook" write "$TESTDIR/test.bin" 262144

# 检查物理文件是否有 header
echo "[3/7] Checking physical file header..."
python3 << EOF
import struct, sys
path = "$TESTDIR/test.bin"
with open(path, 'rb') as f:
    data = f.read(64)
    magic = struct.unpack('<I', data[0:4])[0]
    expected = 0x47505543
    if magic != expected:
        print(f"FAIL: Magic mismatch: {hex(magic)} != {hex(expected)}")
        sys.exit(1)
    version = struct.unpack('<I', data[4:8])[0]
    state = data[24]
    print(f"OK: Magic=GPUC, Version={version}, State={'RAW' if state==0 else 'COMPRESSED'}")
EOF

# 使用 LD_PRELOAD 读取文件（RAW 状态）
echo "[4/7] Reading test file with LD_PRELOAD (RAW state)..."
LD_PRELOAD="$BINDIR/libgpuhook.so" "$BINDIR/test_hook" read "$TESTDIR/test.bin" 262144

# 运行 Daemon 压缩
echo "[5/7] Running compression daemon..."
"$BINDIR/gpu_compress_daemon" "$TESTDIR"

# 检查压缩后 header
echo "[6/7] Checking compressed file header..."
python3 << EOF
import struct, sys
path = "$TESTDIR/test.bin"
with open(path, 'rb') as f:
    data = f.read(64)
    state = data[24]
    orig_size = struct.unpack('<Q', data[8:16])[0]
    num_blocks = struct.unpack('<I', data[20:24])[0]
    if state != 1:
        print(f"FAIL: Expected COMPRESSED state, got {state}")
        sys.exit(1)
    print(f"OK: State=COMPRESSED, orig_size={orig_size}, num_blocks={num_blocks}")
EOF

# 使用 LD_PRELOAD 读取文件（COMPRESSED 状态，GPU 解压）
echo "[7/7] Reading test file with LD_PRELOAD (COMPRESSED state)..."
LD_PRELOAD="$BINDIR/libgpuhook.so" "$BINDIR/test_hook" read "$TESTDIR/test.bin" 262144

# 测试 cp 复制压缩文件
echo "[8/9] Testing cp on compressed file..."
LD_PRELOAD="$BINDIR/libgpuhook.so" cp "$TESTDIR/test.bin" "$TESTDIR/test_cp.bin"
python3 << EOF
import struct, sys
path = "$TESTDIR/test_cp.bin"
with open(path, 'rb') as f:
    data = f.read(64)
    magic = struct.unpack('<I', data[0:4])[0]
    if magic != 0x47505543:
        print(f"FAIL: cp output missing GPUC header")
        sys.exit(1)
    print("OK: cp output has valid GPUC header")
EOF

# 测试 dd 复制压缩文件
echo "[9/9] Testing dd on compressed file..."
LD_PRELOAD="$BINDIR/libgpuhook.so" dd if="$TESTDIR/test.bin" of="$TESTDIR/test_dd.bin" bs=4096 2>/dev/null
python3 << EOF
import struct, sys
path = "$TESTDIR/test_dd.bin"
with open(path, 'rb') as f:
    data = f.read(64)
    magic = struct.unpack('<I', data[0:4])[0]
    if magic != 0x47505543:
        print(f"FAIL: dd output missing GPUC header")
        sys.exit(1)
    print("OK: dd output has valid GPUC header")
EOF

echo ""
echo "=== ALL INTEGRATION TESTS PASSED ==="

# 清理
rm -rf "$TESTDIR"
