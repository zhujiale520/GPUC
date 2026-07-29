#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/gpuc-corrupt-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

gcc -O2 -Wall -Wextra "$PROJECT_DIR/tests/test_corrupt_headers.c" \
    -o "$PROJECT_DIR/bin/test_corrupt_headers"

python3 - "$TEST_DIR" <<'PY'
import os, struct, sys
d=sys.argv[1]
def hdr(orig=0, block=131072, nblocks=0, state=0, hsize=56):
    return struct.pack("<IIQIIBBH4xQQQ",
        0x47505543, 1, orig, block, nblocks, state, 1, 0, hsize, 0, 0)
cases = {
    "bad_block": hdr(block=0),
    "huge_blocks": hdr(orig=131072, nblocks=0xffffffff, state=1, hsize=80),
    "huge_header": hdr(hsize=1<<63),
    "bad_state": hdr(state=99),
    "bad_entry": hdr(orig=131072, nblocks=1, state=1, hsize=80)
                 + struct.pack("<IIQII",131072,128,999999,0,0),
    "truncated_entry": hdr(orig=131072, nblocks=1, state=1, hsize=80) + b"\0"*8,
}
for name,data in cases.items():
    with open(os.path.join(d,name+".bin"),"wb") as f: f.write(data)
PY

LD_PRELOAD="$PROJECT_DIR/bin/libcpuhook.so" GPUCOMPRESS_QUIET=1 \
    "$PROJECT_DIR/bin/test_corrupt_headers" "$TEST_DIR"/*.bin
