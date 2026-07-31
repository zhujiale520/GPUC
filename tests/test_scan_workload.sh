#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCANNER="$PROJECT_DIR/bin/scan_workload"
TEST_DIR="$(mktemp -d /tmp/gpuc-scan-smoke-XXXXXX)"
trap 'rm -r -- "$TEST_DIR"' EXIT

[[ -x "$SCANNER" ]] || {
    echo "ERROR: missing scan workload binary: $SCANNER" >&2
    exit 2
}

INPUT="$TEST_DIR/input.bin"
OUTPUT="$TEST_DIR/output.csv"
printf 'real log error marker\nELF\177binary error marker\n' > "$INPUT"
"$SCANNER" "$INPUT" 0.01 > "$OUTPUT"

python3 - "$OUTPUT" "$(stat -c %s "$INPUT")" <<'PY'
import csv
import math
import sys

path, expected_size = sys.argv[1], int(sys.argv[2])
rows = list(csv.reader(open(path, newline="")))
if len(rows) != 1 or len(rows[0]) != 11:
    raise SystemExit(f"unexpected scanner output shape: {rows!r}")

elapsed, total_bytes, scans, mib_s, scans_s, p99_ms, cpu_cores, \
    content_hash, marker_hits, logical_bytes, maxrss_kib = rows[0]
numeric = (elapsed, mib_s, scans_s, p99_ms, cpu_cores, content_hash, maxrss_kib)
if not all(math.isfinite(float(value)) for value in numeric):
    raise SystemExit("scanner output contains a non-finite metric")
if int(scans) < 1 or int(total_bytes) != int(scans) * expected_size:
    raise SystemExit("scanner byte or scan count is inconsistent")
if int(logical_bytes) != expected_size or int(marker_hits) != 2:
    raise SystemExit("scanner content metrics are incorrect")
PY

echo "PASS: real scan workload builds and reports valid content metrics"
