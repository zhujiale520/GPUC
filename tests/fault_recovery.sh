#!/usr/bin/env bash
set -euo pipefail

# Deterministic, non-root fault recovery suite. It validates atomic daemon
# replacement, stale temporary-file recovery, injected ENOSPC cleanup, GPU
# unavailable CPU fallback, and kernel ENOSPC propagation via /dev/full.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/fault_recovery_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-fault-recovery-XXXXXX)"
CPU_HOOK="$PROJECT_DIR/bin/libcpuhook.so"
GPU_HOOK="$PROJECT_DIR/bin/libgpuhook.so"
CPU_DAEMON="$PROJECT_DIR/bin/cpu_compress_daemon"
trap 'rm -r -- "$TEST_DIR"' EXIT
mkdir -p "$RESULT_DIR" "$TEST_DIR/enospc" "$TEST_DIR/crash" "$TEST_DIR/gpu"

make -C "$PROJECT_DIR" cpu-only >/dev/null
echo "test,status,detail" > "$RESULT_DIR/summary.csv"

state_of() {
    python3 - "$1" <<'PY'
import struct,sys
h=open(sys.argv[1],"rb").read(56)
if len(h)!=56 or struct.unpack_from("<I",h,0)[0]!=0x47505543: print("INVALID")
else: print({0:"RAW",1:"COMPRESSED",2:"BUSY",3:"INLINE"}.get(h[24],"INVALID"))
PY
}

logical_sha() {
    LD_PRELOAD="$CPU_HOOK" GPUCOMPRESS_QUIET=1 \
        dd if="$1" bs=1M status=none | sha256sum | awk '{print $1}'
}

record() {
    printf '%s,%s,%s\n' "$1" "$2" "$3" >> "$RESULT_DIR/summary.csv"
    [[ "$2" == PASS ]]
}

plain="$TEST_DIR/plain.bin"
dd if=/dev/zero of="$plain" bs=1M count=64 status=none
plain_sha="$(sha256sum "$plain" | awk '{print $1}')"

# 1. Inject ENOSPC after two blocks. Original RAW must remain intact and the
# temporary file must be removed by the normal failure path.
enospc_file="$TEST_DIR/enospc/data.bin"
LD_PRELOAD="$CPU_HOOK" GPUCOMPRESS_QUIET=1 cp "$plain" "$enospc_file"
GPUC_FAULT_ENOSPC_AFTER_BLOCKS=2 "$CPU_DAEMON" "$TEST_DIR/enospc" \
    > "$RESULT_DIR/enospc_daemon.log" 2>&1 || true
if [[ "$(state_of "$enospc_file")" == RAW &&
      "$(logical_sha "$enospc_file")" == "$plain_sha" &&
      ! -e "${enospc_file}.gpuc_tmp" ]]; then
    record injected_enospc PASS "original RAW and SHA preserved; temp removed"
else
    record injected_enospc FAIL "atomic cleanup invariant failed"
fi

# 2. Kill the daemon while it is paused after writing the first block. The
# stale temp is allowed after SIGKILL, but the original must remain readable.
crash_file="$TEST_DIR/crash/data.bin"
LD_PRELOAD="$CPU_HOOK" GPUCOMPRESS_QUIET=1 cp "$plain" "$crash_file"
GPUC_FAULT_PAUSE_AFTER_BLOCKS=1 GPUC_FAULT_PAUSE_SECONDS=60 \
    "$CPU_DAEMON" "$TEST_DIR/crash" > "$RESULT_DIR/crash_daemon.log" 2>&1 &
daemon_pid=$!
for _ in $(seq 1 100); do
    [[ -e "${crash_file}.gpuc_tmp" ]] && break
    sleep 0.05
done
kill -9 "$daemon_pid" 2>/dev/null || true
wait "$daemon_pid" 2>/dev/null || true
if [[ "$(state_of "$crash_file")" == RAW &&
      "$(logical_sha "$crash_file")" == "$plain_sha" ]]; then
    record daemon_sigkill PASS "original RAW and SHA preserved"
else
    record daemon_sigkill FAIL "original changed before atomic rename"
fi

# A normal restart truncates/overwrites the stale temp and completes.
"$CPU_DAEMON" "$TEST_DIR/crash" > "$RESULT_DIR/recovery_daemon.log" 2>&1
if [[ "$(state_of "$crash_file")" == COMPRESSED &&
      "$(logical_sha "$crash_file")" == "$plain_sha" &&
      ! -e "${crash_file}.gpuc_tmp" ]]; then
    record stale_temp_restart PASS "restart produced valid COMPRESSED file"
else
    record stale_temp_restart FAIL "restart did not recover stale temp"
fi

# 3. A GPU build with no visible device must fall back to the CPU decoder and
# preserve content. Skip only when the GPU build has not been prepared.
if [[ -f "$GPU_HOOK" ]]; then
    if CUDA_VISIBLE_DEVICES="" GPUCOMPRESS_BACKEND=gpu \
       LD_PRELOAD="$GPU_HOOK" GPUCOMPRESS_QUIET=1 \
       dd if="$crash_file" bs=1M status=none |
       sha256sum | awk '{print $1}' | grep -qx "$plain_sha"; then
        record gpu_unavailable_fallback PASS "CPU fallback SHA verified"
    else
        record gpu_unavailable_fallback FAIL "read failed without visible GPU"
    fi
else
    printf '%s,%s,%s\n' gpu_unavailable_fallback SKIP "GPU Hook not built" \
        >> "$RESULT_DIR/summary.csv"
fi

# 4. /dev/full provides a deterministic kernel ENOSPC without mount privilege.
if LD_PRELOAD="$CPU_HOOK" GPUCOMPRESS_QUIET=1 \
   dd if=/dev/zero of=/dev/full bs=4096 count=1 status=none \
   > "$RESULT_DIR/dev_full.log" 2>&1; then
    record dev_full_enospc FAIL "write unexpectedly succeeded"
else
    record dev_full_enospc PASS "kernel write failure propagated"
fi

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)
kernel=$(uname -srvmo)
faults=injected daemon ENOSPC; SIGKILL before rename; stale temp restart; GPU unavailable; /dev/full
plain_sha256=$plain_sha
EOF

echo "[OK] $RESULT_DIR"
