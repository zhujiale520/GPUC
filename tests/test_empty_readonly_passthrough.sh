#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"

[[ -f "$HOOK" ]] || {
    echo "ERROR: build bin/libgpuhook.so first." >&2
    exit 1
}

actual="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 head -n 1 /proc/stat)"

[[ "$actual" =~ ^cpu[[:space:]]+[0-9]+([[:space:]]+[0-9]+){3,} ]] || {
    echo "ERROR: Hook changed or hid /proc/stat." >&2
    exit 1
}

echo "PASS: empty read-only procfs file is passed through"
