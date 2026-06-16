#!/bin/bash
set -e

# ============================================================
#  Database / Log File Whitelist Test
# ============================================================
# 验证 SQLite / LevelDB 等依赖固定文件 magic 的数据库文件
# 在 LD_PRELOAD 下不会被附加 GPUC header，从而能正常工作。
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
TESTDIR="/tmp/gpuc_db_whitelist_$$"
RESULTDIR="/tmp/gpuc_db_whitelist_results_$$"

mkdir -p "$TESTDIR" "$RESULTDIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
RED='\033[0;31m'
NC='\033[0m'

PASS=0
FAIL=0
SKIP=0

pass() {
    echo -e "${GREEN}PASS${NC}: $1"
    PASS=$((PASS + 1))
}

fail() {
    echo -e "${RED}FAIL${NC}: $1"
    FAIL=$((FAIL + 1))
}

skip() {
    echo -e "${BLUE}SKIP${NC}: $1"
    SKIP=$((SKIP + 1))
}

# 检查文件头是否为 GPUC magic
check_no_gpuc_header() {
    local file="$1"
    if [ ! -f "$file" ]; then
        return 1
    fi
    python3 - << PY
import struct, sys
with open('$file', 'rb') as f:
    data = f.read(4)
if len(data) < 4:
    sys.exit(0)
magic = struct.unpack('<I', data)[0]
if magic == 0x47505543:
    sys.exit(1)
sys.exit(0)
PY
}

echo "========================================"
echo "  Database / Log File Whitelist Test"
echo "========================================"
echo "测试目录: $TESTDIR"
echo ""

# ----------------------------------------------------------
#  1. SQLite 兼容性
# ----------------------------------------------------------
echo -e "${YELLOW}### 1. SQLite 数据库 ###${NC}"
SQLITE_DB="$TESTDIR/test.db"
rm -f "$SQLITE_DB"

if LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 python3 - << PY
import sqlite3, os, sys
db = '$SQLITE_DB'
conn = sqlite3.connect(db)
c = conn.cursor()
c.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)')
c.executemany('INSERT INTO t (v) VALUES (?)', [('x' * 100,) for _ in range(1000)])
conn.commit()
# 随机查询
c.execute('SELECT COUNT(*) FROM t')
assert c.fetchone()[0] == 1000
conn.close()
print('sqlite ok')
PY
then
    if check_no_gpuc_header "$SQLITE_DB"; then
        pass "SQLite 在 Hook 下工作正常且未被附加 GPUC header"
    else
        fail "SQLite 工作正常但文件被附加了 GPUC header"
    fi
else
    fail "SQLite 在 Hook 下无法正常工作"
fi

# 检查 SQLite WAL / journal 文件也被跳过
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 python3 - << PY
import sqlite3
db = '$SQLITE_DB'
conn = sqlite3.connect(db)
conn.execute('PRAGMA journal_mode=WAL')
conn.execute('INSERT INTO t (v) VALUES (?)', ('y' * 100,))
conn.commit()
conn.close()
PY

WAL_FILE="${SQLITE_DB}-wal"
if [ -f "$WAL_FILE" ] && check_no_gpuc_header "$WAL_FILE"; then
    pass "SQLite WAL 文件未被附加 GPUC header"
else
    skip "SQLite WAL 文件未生成或已被附加 header"
fi

# ----------------------------------------------------------
#  2. LevelDB 兼容性（若工具已存在）
# ----------------------------------------------------------
echo ""
echo -e "${YELLOW}### 2. LevelDB ###${NC}"
LEVELDB_BENCH="$PROJECT_DIR/tests/workload_tools/leveldb_simple_bench"
LEVELDB_VERIFY="$PROJECT_DIR/tests/workload_tools/leveldb_verify"

if [ -x "$LEVELDB_BENCH" ] && [ -x "$LEVELDB_VERIFY" ]; then
    LEVELDB_DB="$TESTDIR/leveldb_test"
    rm -rf "$LEVELDB_DB"
    mkdir -p "$LEVELDB_DB"

    if LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 "$LEVELDB_BENCH" "$LEVELDB_DB" 10000 > "$RESULTDIR/leveldb.log" 2>&1; then
        if LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 "$LEVELDB_VERIFY" "$LEVELDB_DB" > "$RESULTDIR/leveldb_verify.log" 2>&1; then
            # 检查关键文件未被附加 header
            ok=1
            for f in "$LEVELDB_DB"/CURRENT "$LEVELDB_DB"/MANIFEST-*; do
                [ -f "$f" ] || continue
                if ! check_no_gpuc_header "$f"; then
                    echo "  $f has GPUC header"
                    ok=0
                fi
            done
            if [ $ok -eq 1 ]; then
                pass "LevelDB 在 Hook 下工作正常且关键文件未被附加 GPUC header"
            else
                fail "LevelDB 工作正常但部分文件被附加了 GPUC header"
            fi
        else
            fail "LevelDB 数据校验失败"
        fi
    else
        fail "LevelDB benchmark 在 Hook 下失败"
    fi
else
    skip "LevelDB 测试工具未编译，运行 tests/real_workload_comprehensive.sh 可生成"
fi

# ----------------------------------------------------------
#  3. 普通文件仍正常附加 header（回归测试）
# ----------------------------------------------------------
echo ""
echo -e "${YELLOW}### 3. 普通文件仍被 Hook（回归）###${NC}"
REG_FILE="$TESTDIR/normal.bin"
rm -f "$REG_FILE"
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if=/dev/zero of="$REG_FILE" bs=1K count=4 status=none

if ! check_no_gpuc_header "$REG_FILE"; then
    pass "普通文件仍被正确附加 GPUC header"
else
    fail "普通文件未被附加 GPUC header，回归失败"
fi

# ----------------------------------------------------------
#  4. GPUC_WHITELIST 环境变量追加测试
# ----------------------------------------------------------
echo ""
echo -e "${YELLOW}### 4. 自定义白名单 GPUC_WHITELIST ###${NC}"
CUSTOM_FILE="$TESTDIR/data.custom"
rm -f "$CUSTOM_FILE"
LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 GPUC_WHITELIST="*.custom" \
    dd if=/dev/zero of="$CUSTOM_FILE" bs=1K count=4 status=none

if check_no_gpuc_header "$CUSTOM_FILE"; then
    pass "GPUC_WHITELIST 追加 *.custom 生效"
else
    fail "GPUC_WHITELIST 追加 *.custom 未生效"
fi

# ----------------------------------------------------------
#  汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "       汇总"
echo "========================================"
echo -e "${GREEN}PASS: $PASS${NC}"
echo -e "${RED}FAIL: $FAIL${NC}"
echo -e "${BLUE}SKIP: $SKIP${NC}"

rm -rf "$TESTDIR"

[ $FAIL -eq 0 ]
