#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_DIR="$(mktemp -d /tmp/gpuc-header-fuzz-XXXXXX)"
trap 'rm -rf -- "$TEST_DIR"' EXIT

gcc -O1 -g -Wall -Wextra "$PROJECT_DIR/tests/test_header_fuzz.c" \
    -o "$TEST_DIR/test_header_fuzz"

python3 - "$TEST_DIR" <<'PY'
import os
import random
import struct
import sys

root = sys.argv[1]
rng = random.Random(0x47505543)
for i in range(2000):
    size = rng.randrange(0, 513)
    data = bytearray(rng.getrandbits(8) for _ in range(size))
    # Half the corpus is recognized as GPUC and exercises defensive parsing;
    # the rest covers short/ordinary files.
    if i % 2 == 0 and size >= 4:
        struct.pack_into("<I", data, 0, 0x47505543)
    if i % 3 == 0 and size >= 56:
        struct.pack_into("<I", data, 4, rng.choice([0, 1, 2, 0xFFFFFFFF]))
        struct.pack_into("<Q", data, 8, rng.getrandbits(64))
        struct.pack_into("<I", data, 16, rng.choice([0, 1, 4096, 131072, 0xFFFFFFFF]))
        struct.pack_into("<I", data, 20, rng.getrandbits(32))
        data[24] = rng.randrange(0, 256)
        data[25] = rng.randrange(0, 256)
        struct.pack_into("<Q", data, 28, rng.getrandbits(64))
    with open(os.path.join(root, f"case-{i:04d}"), "wb") as f:
        f.write(data)
PY

LD_PRELOAD="$PROJECT_DIR/bin/libcpuhook.so" GPUCOMPRESS_QUIET=1 \
    "$TEST_DIR/test_header_fuzz" "$TEST_DIR"
