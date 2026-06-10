#!/bin/bash
set -e

# ============================================================
#  Real Workload Study — 真实数据 workload 测试
#
#  测试三类真实数据：
#    1. 文本类：Linux 内核头文件（高可压缩，有结构）
#    2. 数据库类：SQLite B-tree 页（真实数据库文件）
#    3. 日志类：HTTP 请求日志（中等可压缩）
#
#  测量指标：压缩率、压缩耗时、解压读带宽
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
TESTDIR="/tmp/gpuc_realworkload_$$"
RESULTDIR="/tmp/gpuc_realworkload_results_$$"
mkdir -p "$TESTDIR" "$RESULTDIR"

RUNTIME=10
BS="128k"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/real_workload.csv"
echo "scenario,orig_bytes,comp_bytes,comp_ratio,comp_time_ms,read_bw_mb_s" > "$RESULT_CSV"

# 确保编译产物存在
if [ ! -f "$PROJECT_DIR/bin/libgpuhook.so" ] || [ ! -f "$PROJECT_DIR/bin/gpu_compress_daemon" ]; then
    make -C "$PROJECT_DIR" clean >/dev/null 2>&1
    make -C "$PROJECT_DIR" all >/dev/null 2>&1
fi

# ----------------------------------------------------------
#  辅助函数
# ----------------------------------------------------------
measure() {
    local scenario=$1
    local srcfile=$2
    local testfile="$TESTDIR/${scenario}.bin"

    echo ""
    echo -e "${BLUE}>>> ${scenario}${NC}"

    # 复制到测试目录并附加 RAW header
    cp "$srcfile" "$testfile.raw"
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        dd if="$testfile.raw" of="$testfile" bs=1M status=none

    local orig_bytes=$(stat -c %s "$testfile")
    echo "  Original (with header): $(echo "$orig_bytes" | numfmt --to=iec)"

    # GPU 压缩，计时
    local t0=$(date +%s%N)
    "$PROJECT_DIR/bin/gpu_compress_daemon" "$TESTDIR" >/dev/null 2>&1
    local t1=$(date +%s%N)
    local comp_time_ms=$(( (t1 - t0) / 1000000 ))

    local comp_bytes=$(du -B1 "$testfile" | awk '{print $1}')
    local comp_ratio=$(echo "scale=1; $comp_bytes * 100 / $orig_bytes" | bc)

    echo "  Compressed: $(echo "$comp_bytes" | numfmt --to=iec) (${comp_ratio}%)"
    echo "  Compress time: ${comp_time_ms} ms"

    # fio 读取带宽
    local json_out="$RESULTDIR/${scenario}.json"
    LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
        fio --name="${scenario}" --filename="$testfile" --size="${orig_bytes}B" --bs="$BS" \
            --rw=read --runtime="$RUNTIME" --time_based --direct=0 --ioengine=sync \
            --output-format=json > "$json_out" 2>/dev/null

    local bw=$(python3 -c "
import json
with open('$json_out') as f:
    d = json.load(f)
print(f\"{d['jobs'][0]['read']['bw']/1024:.1f}\")
" 2>/dev/null || echo "0")

    echo -e "  Read BW: ${GREEN}${bw} MB/s${NC}"
    echo "$scenario,$orig_bytes,$comp_bytes,$comp_ratio,$comp_time_ms,$bw" >> "$RESULT_CSV"

    rm -f "$testfile.raw"
}

# ----------------------------------------------------------
#  数据准备
# ----------------------------------------------------------
echo "========================================"
echo "  Real Workload Study — 真实数据测试"
echo "========================================"
echo "Test dir: $TESTDIR"
echo ""

# 1. Linux 内核头文件（文本类）
HEADER_SRC=/usr/src/linux-headers-5.4.0-216
if [ -d "$HEADER_SRC" ]; then
    echo "[DATA] Preparing linux-headers archive..."
    tar -cf "$TESTDIR/linux_headers.tar" -C "$HEADER_SRC" . 2>/dev/null
    measure "linux_headers" "$TESTDIR/linux_headers.tar"
else
    echo -e "${YELLOW}[SKIP] linux-headers not found${NC}"
fi

# 2. SQLite 数据库（数据库类）
SQLITE_FILE="$TESTDIR/test.db"
echo "[DATA] Preparing SQLite database..."
python3 << EOF
import sqlite3, os, random, string

db_path = "$TESTDIR/test.db"
os.makedirs(os.path.dirname(db_path), exist_ok=True)
conn = sqlite3.connect(db_path)
c = conn.cursor()
c.execute('''CREATE TABLE records (
    id INTEGER PRIMARY KEY,
    name TEXT,
    data TEXT,
    score REAL,
    ts INTEGER
)''')
c.execute('CREATE INDEX idx_ts ON records(ts)')

random.seed(42)
batch = []
for i in range(200000):
    name = ''.join(random.choices(string.ascii_letters, k=20))
    data = ''.join(random.choices(string.ascii_letters + string.digits + ' ', k=200))
    score = random.random() * 100
    ts = random.randint(1609459200, 1704067200)
    batch.append((name, data, score, ts))
    if len(batch) >= 5000:
        c.executemany('INSERT INTO records (name, data, score, ts) VALUES (?, ?, ?, ?)', batch)
        batch = []
if batch:
    c.executemany('INSERT INTO records (name, data, score, ts) VALUES (?, ?, ?, ?)', batch)

conn.commit()
conn.close()
print(f"SQLite DB size: {os.path.getsize(db_path)} bytes")
EOF
measure "sqlite_db" "$SQLITE_FILE"

# 3. HTTP 日志（日志类）
LOG_FILE="$TESTDIR/access.log"
echo "[DATA] Preparing HTTP access log..."
python3 << EOF
import random, os

log_path = "$TESTDIR/access.log"
os.makedirs(os.path.dirname(log_path), exist_ok=True)

random.seed(42)
urls = [
    "/index.html", "/api/v1/users", "/api/v1/login", "/static/style.css",
    "/static/app.js", "/api/v1/data", "/api/v1/search", "/health",
    "/products/", "/cart", "/checkout", "/about", "/contact"
]
methods = ["GET", "POST", "PUT", "DELETE"]
status = [200, 200, 200, 200, 200, 201, 301, 302, 400, 401, 403, 404, 500]
agents = [
    "Mozilla/5.0 (X11; Linux x86_64)",
    "curl/7.68.0",
    "python-requests/2.25.1",
    "Mozilla/5.0 (Windows NT 10.0; Win64; x64)"
]

target_size = 512 * 1024 * 1024  # 512 MB
with open(log_path, "w") as f:
    i = 0
    while f.tell() < target_size:
        line = f'192.168.{random.randint(0,255)}.{random.randint(0,255)} - - [{i:08d}] "{random.choice(methods)} {random.choice(urls)} HTTP/1.1" {random.choice(status)} {random.randint(100,50000)} "-" "{random.choice(agents)}"\n'
        f.write(line)
        i += 1

print(f"Log size: {os.path.getsize(log_path)} bytes")
EOF
measure "access_log" "$LOG_FILE"

# ----------------------------------------------------------
#  汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "  Real Workload 汇总"
echo "========================================"
python3 << EOF
import csv
rows = list(csv.DictReader(open('$RESULT_CSV')))
print(f"{'场景':<18} {'原始':>10} {'压缩后':>10} {'压缩率':>8} {'压缩耗时':>10} {'读带宽':>10}")
print("-" * 72)
for r in rows:
    orig = int(r['orig_bytes'])
    comp = int(r['comp_bytes'])
    print(f"{r['scenario']:<18} {orig:>10,} {comp:>10,} {r['comp_ratio']:>8}% {r['comp_time_ms']:>10} ms {r['read_bw_mb_s']:>10} MB/s")
EOF

echo ""
echo -e "${GREEN}原始数据已保存到: $RESULTDIR/real_workload.csv${NC}"
