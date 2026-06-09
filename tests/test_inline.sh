#!/bin/bash
set -e

TESTDIR=$(mktemp -d /tmp/gpuc_inline_test_XXXXXX)
echo "=== Inline Small File Integration Test ==="
echo "Test directory: $TESTDIR"

# [1/6] Compile test program
cp src/test_hook.c "$TESTDIR/"
gcc -Iinclude "$TESTDIR/test_hook.c" -o "$TESTDIR/test_hook"

# [2/6] Write a small file (512 bytes, <= 1KB inline threshold)
echo "[2/6] Writing small file (512 bytes)..."
LD_PRELOAD="$(pwd)/bin/libgpuhook.so" "$TESTDIR/test_hook" write "$TESTDIR/test_small.bin" 512

# [3/6] Check RAW header
echo "[3/6] Checking RAW header..."
python3 -c "
import struct, sys
with open('$TESTDIR/test_small.bin', 'rb') as f:
    data = f.read(64)
    magic = struct.unpack('<I', data[0:4])[0]
    version = struct.unpack('<I', data[4:8])[0]
    state = data[24]
    assert magic == 0x47505543, 'Bad magic'
    assert version == 1, 'Bad version'
    assert state == 0, 'Expected RAW state'
    print('OK: RAW header valid')
"

# [4/6] Read RAW state file
echo "[4/6] Reading RAW state file..."
LD_PRELOAD="$(pwd)/bin/libgpuhook.so" "$TESTDIR/test_hook" read "$TESTDIR/test_small.bin" 512

# [5/6] Run compression daemon
echo "[5/6] Running compression daemon on small file..."
"$(pwd)/bin/gpu_compress_daemon" "$TESTDIR"

# [6/6] Verify INLINE state and read back
echo "[6/6] Verifying INLINE state and reading back..."
python3 -c "
import struct, sys
with open('$TESTDIR/test_small.bin', 'rb') as f:
    data = f.read(56)
    magic = struct.unpack('<I', data[0:4])[0]
    orig_size = struct.unpack('<Q', data[8:16])[0]
    num_blocks = struct.unpack('<I', data[20:24])[0]
    state = data[24]
    header_size = struct.unpack('<Q', data[32:40])[0]
    assert magic == 0x47505543, 'Bad magic'
    assert state == 3, 'Expected INLINE state (3), got %d' % state
    assert num_blocks == 0, 'Expected 0 blocks for inline'
    assert header_size == 56 + orig_size, 'Bad header_size: %d vs expected %d' % (header_size, 56 + orig_size)
    inline_data = f.read()
    assert len(inline_data) == orig_size, 'Inline data size mismatch: %d vs %d' % (len(inline_data), orig_size)
    # Verify data pattern (test_hook writes i % 256)
    expected = bytes([i % 256 for i in range(orig_size)])
    assert inline_data == expected, 'Inline data mismatch!'
    print('OK: INLINE header valid, orig_size=%d, header_size=%d, data verified' % (orig_size, header_size))
"

# [7/7] Read INLINE state file via hook
echo "[7/7] Reading INLINE state file with LD_PRELOAD..."
LD_PRELOAD="$(pwd)/bin/libgpuhook.so" "$TESTDIR/test_hook" read "$TESTDIR/test_small.bin" 512

# [8/8] Test cp on inline file
echo "[8/8] Testing cp on inline file..."
cp "$TESTDIR/test_small.bin" "$TESTDIR/test_small_cp.bin"
python3 -c "
import struct
with open('$TESTDIR/test_small_cp.bin', 'rb') as f:
    magic = struct.unpack('<I', f.read(4))[0]
    assert magic == 0x47505543, 'cp output should preserve GPUC header'
    print('OK: cp output has valid GPUC header')
"

# Cleanup
rm -rf "$TESTDIR"

echo ""
echo "=== ALL INLINE TESTS PASSED ==="
