#!/usr/bin/env bash
set -euo pipefail

# CPU-only line/branch coverage. Uses GCC's bundled gcov so no lcov package is
# required. The raw .gcov files and a machine-readable summary are retained.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/coverage_${RUN_ID}}"
BUILD_DIR="$(mktemp -d /tmp/gpuc-coverage-build-XXXXXX)"
TEST_ROOT="${GPUC_TEST_ROOT:-/tmp}"
TEST_DIR="$(mktemp -d "$TEST_ROOT/gpuc-coverage-data-XXXXXX")"
MIN_LINES="${GPUC_COVERAGE_MIN_LINES:-35}"
trap 'rm -r -- "$BUILD_DIR" "$TEST_DIR"' EXIT
mkdir -p "$RESULT_DIR/gcov" "$TEST_DIR/compressed" "$TEST_DIR/inline"

if [[ -f "$PROJECT_DIR/third_party/lz4/liblz4.so" ]]; then
    LZ4=(-L"$PROJECT_DIR/third_party/lz4" -Wl,-rpath,"$PROJECT_DIR/third_party/lz4" -llz4)
else
    LZ4=(-Wl,-l:liblz4.so.1)
fi
CFLAGS=(--coverage -O0 -g -fno-inline -I"$PROJECT_DIR/include")

gcc "${CFLAGS[@]}" -fPIC -DCPU_ONLY_BUILD -c "$PROJECT_DIR/src/hook.c" \
    -o "$BUILD_DIR/hook.o"
gcc "${CFLAGS[@]}" -fPIC -c "$PROJECT_DIR/src/cpu_compress.c" \
    -o "$BUILD_DIR/cpu_compress.o"
gcc "${CFLAGS[@]}" -fPIC -c "$PROJECT_DIR/src/cpu_lz4.c" \
    -o "$BUILD_DIR/cpu_lz4.o"
gcc --coverage -shared "$BUILD_DIR/hook.o" "$BUILD_DIR/cpu_compress.o" \
    "$BUILD_DIR/cpu_lz4.o" -o "$BUILD_DIR/libcpuhook_coverage.so" \
    -ldl -lpthread "${LZ4[@]}"
gcc "${CFLAGS[@]}" -c "$PROJECT_DIR/src/cpu_daemon.c" \
    -o "$BUILD_DIR/cpu_daemon.o"
gcc --coverage "$BUILD_DIR/cpu_daemon.o" "$BUILD_DIR/cpu_compress.o" \
    "$BUILD_DIR/cpu_lz4.o" -o "$BUILD_DIR/cpu_daemon_coverage" \
    -lpthread "${LZ4[@]}"
gcc -O0 -g "$PROJECT_DIR/tests/test_posix_semantics.c" \
    -o "$BUILD_DIR/test_posix_semantics"
gcc -O0 -g -I"$PROJECT_DIR/include" "$PROJECT_DIR/src/test_hook.c" \
    -o "$BUILD_DIR/test_hook"
gcc "${CFLAGS[@]}" -c "$PROJECT_DIR/tests/test_cpu_lz4_roundtrip.c" \
    -o "$BUILD_DIR/test_cpu_lz4_roundtrip.o"
gcc --coverage "$BUILD_DIR/test_cpu_lz4_roundtrip.o" \
    "$BUILD_DIR/cpu_lz4.o" -o "$BUILD_DIR/test_cpu_lz4_roundtrip" \
    "${LZ4[@]}"

HOOK="$BUILD_DIR/libcpuhook_coverage.so"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_posix_semantics" raw "$TEST_DIR/raw.bin"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_posix_semantics" rename "$TEST_DIR/rename-source"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_hook" writemixed "$TEST_DIR/compressed/data.bin" 262144
"$BUILD_DIR/cpu_daemon_coverage" "$TEST_DIR/compressed" >/dev/null
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_posix_semantics" compressed "$TEST_DIR/compressed/data.bin"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    "$BUILD_DIR/test_hook" readmixed "$TEST_DIR/compressed/data.bin" 262144
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    dd if=/dev/zero of="$TEST_DIR/inline/data.bin" bs=512 count=1 status=none
"$BUILD_DIR/cpu_daemon_coverage" "$TEST_DIR/inline" >/dev/null
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    dd if="$TEST_DIR/inline/data.bin" of=/dev/null bs=512 status=none
"$BUILD_DIR/test_cpu_lz4_roundtrip"

(
    cd "$RESULT_DIR/gcov"
    gcov -b -c "$BUILD_DIR/hook.gcno" "$BUILD_DIR/cpu_daemon.gcno" \
        "$BUILD_DIR/cpu_compress.gcno" "$BUILD_DIR/cpu_lz4.gcno"
) > "$RESULT_DIR/gcov_output.txt"

python3 - "$RESULT_DIR/gcov_output.txt" "$RESULT_DIR/summary.csv" \
    "$MIN_LINES" <<'PY'
import csv,re,sys
text=open(sys.argv[1]).read().splitlines()
rows=[]; current=None
for line in text:
    m=re.match(r"File '(.+)'",line)
    if m: current=m.group(1); continue
    m=re.match(r"Lines executed:([0-9.]+)% of ([0-9]+)",line)
    if m and current:
        rows.append([current,float(m.group(1)),int(m.group(2)),None,None])
        continue
    m=re.match(r"Branches executed:([0-9.]+)% of ([0-9]+)",line)
    if m and rows and rows[-1][0]==current:
        rows[-1][3]=float(m.group(1)); rows[-1][4]=int(m.group(2))
with open(sys.argv[2],"w",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow(["source","line_pct","lines","branch_executed_pct","branches"])
    w.writerows(rows)
hook=next((r for r in rows if r[0].endswith("/src/hook.c")),None)
if not hook: raise SystemExit("hook.c coverage missing")
if hook[1] < float(sys.argv[3]):
    raise SystemExit(f"hook.c line coverage {hook[1]}% below {sys.argv[3]}%")
PY

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)
gcc=$(gcc --version | head -1)
gcov=$(gcov --version | head -1)
minimum_hook_line_coverage_pct=$MIN_LINES
scope=CPU Hook, CPU daemon, SGLZ/LZ4 CPU helpers
EOF

echo "[OK] $RESULT_DIR"
