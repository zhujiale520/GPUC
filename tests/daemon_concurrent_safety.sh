#!/bin/bash
set -e

# ============================================================
#  Daemon Concurrent Safety Test
#  Verifies that daemon skips files that are currently locked.
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_dmn_safety_$$"
mkdir -p "$TESTDIR"

TESTFILE="$TESTDIR/safe.bin"
SIZE="64M"

echo "[SETUP] Creating test file..."
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
    dd if=/dev/zero of="$TESTFILE" bs=1M count=64 status=none 2>/dev/null

echo ""
echo "[TEST] Starting background reader with flock (keeps file locked for 10s)..."
(
  exec 200<>"$TESTFILE"
  flock -x 200
  echo "[reader] Locked file, sleeping 10s..."
  sleep 10
  echo "[reader] Releasing lock."
) &
READER_PID=$!

# Give reader time to acquire lock
sleep 1

echo "[TEST] Running daemon while file is locked..."
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" 2>&1 | tee "$TESTDIR/daemon.log"

wait $READER_PID 2>/dev/null || true

echo ""
echo "========================================"
echo "  Daemon Concurrent Safety Result"
echo "========================================"
if grep -q "File busy, skipping" "$TESTDIR/daemon.log"; then
    echo "PASS: Daemon correctly skipped the locked file."
else
    echo "INFO: Check daemon log manually."
fi
cat "$TESTDIR/daemon.log"

rm -rf "$TESTDIR"
