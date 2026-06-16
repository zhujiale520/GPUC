#!/bin/bash
set -e

# ============================================================
#  Real Workload Comprehensive Benchmark
# ============================================================
# 覆盖场景：
#   1. SQLite: 批量导入 + 随机查询（模拟事务/日志）
#   2. LevelDB: fillseq + readrandom + readseq（db_bench）
#   3. ccache: 大量小文件编译缓存
#   4. ML 数据加载: 大文件顺序/随机读（模拟 ImageNet 风格）
#
# 依赖自动下载到 deps/，无需 sudo。
# ============================================================

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
HOOK_SO="$PROJECT_DIR/bin/libgpuhook.so"
GPU_DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
DEPS_DIR="$PROJECT_DIR/deps"
TESTDIR="/tmp/gpuc_real_workload_$$"
RESULTDIR="/tmp/gpuc_real_workload_results_$$"

mkdir -p "$DEPS_DIR" "$TESTDIR" "$RESULTDIR"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

RESULT_CSV="$RESULTDIR/results.csv"
echo "workload,scenario,metric,value,unit" > "$RESULT_CSV"

# ----------------------------------------------------------
#  依赖准备
# ----------------------------------------------------------
ensure_leveldb() {
    if [ -f "$DEPS_DIR/leveldb/build/libleveldb.a" ] && [ -x "$PROJECT_DIR/tests/workload_tools/leveldb_simple_bench" ] && [ -x "$PROJECT_DIR/tests/workload_tools/leveldb_verify" ]; then
        return 0
    fi
    echo -e "${BLUE}[DEP] 下载并编译 LevelDB...${NC}"
    cd "$DEPS_DIR"
    if [ ! -d leveldb ]; then
        git clone --depth=1 --branch=1.23 https://github.com/google/leveldb.git >/dev/null 2>&1
    fi
    cd leveldb
    rm -rf build && mkdir -p build && cd build
    cmake -DCMAKE_BUILD_TYPE=Release -DLEVELDB_BUILD_TESTS=OFF -DLEVELDB_BUILD_BENCHMARKS=OFF .. >/dev/null 2>&1
    make -j$(nproc) leveldb >/dev/null 2>&1
    echo -e "${GREEN}[DEP] LevelDB 库就绪${NC}"

    echo -e "${BLUE}[DEP] 编译 LevelDB simple bench...${NC}"
    g++ -O3 -I "$DEPS_DIR/leveldb/include" \
        "$PROJECT_DIR/tests/workload_tools/leveldb_simple_bench.cc" \
        "$DEPS_DIR/leveldb/build/libleveldb.a" \
        -lpthread -o "$PROJECT_DIR/tests/workload_tools/leveldb_simple_bench"
    g++ -O3 -I "$DEPS_DIR/leveldb/include" \
        "$PROJECT_DIR/tests/workload_tools/leveldb_verify.cc" \
        "$DEPS_DIR/leveldb/build/libleveldb.a" \
        -lpthread -o "$PROJECT_DIR/tests/workload_tools/leveldb_verify"
    echo -e "${GREEN}[DEP] LevelDB simple bench / verify 就绪${NC}"
}

ensure_ccache() {
    if [ -x "$DEPS_DIR/ccache/bin/ccache" ]; then
        return 0
    fi
    echo -e "${BLUE}[DEP] 下载 ccache 预编译二进制...${NC}"
    cd "$DEPS_DIR"
    rm -rf ccache ccache.tar.xz
    curl -L -o ccache.tar.xz https://github.com/ccache/ccache/releases/download/v4.8.3/ccache-4.8.3-linux-x86_64.tar.xz >/dev/null 2>&1
    mkdir -p ccache
    tar -xf ccache.tar.xz --strip-components=1 -C ccache >/dev/null 2>&1
    echo -e "${GREEN}[DEP] ccache 就绪${NC}"
}

# ----------------------------------------------------------
#  SQLite Workload
# ----------------------------------------------------------
run_sqlite() {
    echo ""
    echo -e "${YELLOW}### SQLite Workload ###${NC}"
    local db="$TESTDIR/test.db"

    for scenario in baseline hook; do
        rm -f "$db" "$db-journal" "$db-wal" "$db-shm"
        if [ "$scenario" = "hook" ]; then
            export LD_PRELOAD="$HOOK_SO"
            export GPUCOMPRESS_QUIET=1
        else
            unset LD_PRELOAD GPUCOMPRESS_QUIET
        fi

        echo -e "${GREEN}>>> $scenario: 导入 10 万行${NC}"
        local t0=$(date +%s.%N)
        if python3 - << PYEOF
import sqlite3, os, time, sys
try:
    start = time.time()
    db = "$db"
    conn = sqlite3.connect(db)
    c = conn.cursor()
    c.execute('CREATE TABLE IF NOT EXISTS kv (id INTEGER PRIMARY KEY, k TEXT, v TEXT)')
    c.execute('CREATE INDEX IF NOT EXISTS idx_k ON kv(k)')
    conn.commit()
    batch = 10000
    total = 100000
    for i in range(0, total, batch):
        rows = [(f"key-{j:08d}", f"value-{j:012d}-{os.urandom(32).hex()}") for j in range(i, i+batch)]
        c.executemany('INSERT INTO kv (k, v) VALUES (?, ?)', rows)
        conn.commit()
    conn.close()
    print(f"  import_time={time.time()-start:.2f}s")
except Exception as e:
    print(f"  FAILED: {e}")
    sys.exit(1)
PYEOF
        then
            local t1=$(date +%s.%N)
            local import_sec=$(python3 -c "print(f'{$t1 - $t0:.2f}')")

            echo -e "${GREEN}>>> $scenario: 1 万随机查询${NC}"
            local t2=$(date +%s.%N)
            if python3 - << PYEOF
import sqlite3, random, time, sys
try:
    db = "$db"
    conn = sqlite3.connect(db)
    c = conn.cursor()
    start = time.time()
    for _ in range(10000):
        k = f"key-{random.randint(0, 99999):08d}"
        c.execute('SELECT v FROM kv WHERE k=?', (k,))
        c.fetchone()
    conn.close()
    print(f"  query_time={time.time()-start:.2f}s")
except Exception as e:
    print(f"  FAILED: {e}")
    sys.exit(1)
PYEOF
            then
                local t3=$(date +%s.%N)
                local query_sec=$(python3 -c "print(f'{$t3 - $t2:.2f}')")
                echo "$scenario,sqlite,import_time,$import_sec,s" >> "$RESULT_CSV"
                echo "$scenario,sqlite,query_time,$query_sec,s" >> "$RESULT_CSV"
            else
                echo "$scenario,sqlite,import_time,$import_sec,s" >> "$RESULT_CSV"
                echo "$scenario,sqlite,query_time,FAILED,s" >> "$RESULT_CSV"
            fi
        else
            echo "$scenario,sqlite,import_time,FAILED,s" >> "$RESULT_CSV"
            echo "$scenario,sqlite,query_time,FAILED,s" >> "$RESULT_CSV"
        fi
    done

    unset LD_PRELOAD GPUCOMPRESS_QUIET
}

# ----------------------------------------------------------
#  LevelDB Workload
# ----------------------------------------------------------
run_leveldb() {
    echo ""
    echo -e "${YELLOW}### LevelDB Workload ###${NC}"
    local db="$TESTDIR/leveldb_test"
    local bench="$PROJECT_DIR/tests/workload_tools/leveldb_simple_bench"

    for scenario in baseline hook; do
        rm -rf "$db"
        if [ "$scenario" = "hook" ]; then
            export LD_PRELOAD="$HOOK_SO"
            export GPUCOMPRESS_QUIET=1
        else
            unset LD_PRELOAD GPUCOMPRESS_QUIET
        fi

        echo -e "${GREEN}>>> $scenario: fillseq/readseq/readrandom 100K${NC}"
        local out="$RESULTDIR/leveldb_${scenario}.log"
        if "$bench" "$db" 100000 100 > "$out" 2>&1; then
            cat "$out"
            python3 - << PYEOF
import re
with open('$out') as f:
    for line in f:
        m = re.match(r'(\S+)\s+:\s+(\d+\.\d+) micros/op', line)
        if m:
            print(f"  {m.group(1)}: {m.group(2)} us/op")
            with open('$RESULT_CSV', 'a') as cf:
                cf.write("$scenario,leveldb,{},{},us/op\n".format(m.group(1), m.group(2)))
PYEOF
            # 数据一致性校验
            local verify_out="$RESULTDIR/leveldb_${scenario}_verify.log"
            if "$PROJECT_DIR/tests/workload_tools/leveldb_verify" "$db" > "$verify_out" 2>&1; then
                cat "$verify_out"
                local verr=$(grep -oP 'errors=\d+' "$verify_out" | cut -d= -f2)
                echo "$scenario,leveldb,verify_errors,$verr,count" >> "$RESULT_CSV"
            else
                echo "  VERIFY FAILED"
                cat "$verify_out" | head -3
                echo "$scenario,leveldb,verify_errors,FAILED,count" >> "$RESULT_CSV"
            fi
        else
            echo "  FAILED"
            cat "$out" | head -3
            echo "$scenario,leveldb,fillseq,FAILED,us/op" >> "$RESULT_CSV"
            echo "$scenario,leveldb,readseq,FAILED,us/op" >> "$RESULT_CSV"
            echo "$scenario,leveldb,readrandom,FAILED,us/op" >> "$RESULT_CSV"
            echo "$scenario,leveldb,verify_errors,FAILED,count" >> "$RESULT_CSV"
        fi
    done

    unset LD_PRELOAD GPUCOMPRESS_QUIET
}

# ----------------------------------------------------------
#  ccache Workload
# ----------------------------------------------------------
run_ccache() {
    echo ""
    echo -e "${YELLOW}### ccache Workload ###${NC}"
    local ccache="$DEPS_DIR/ccache/ccache"
    local srcdir="$TESTDIR/ccache_src"
    mkdir -p "$srcdir"

    # 生成 500 个小 C 文件
    echo -e "${BLUE}生成 500 个源文件...${NC}"
    for i in $(seq 1 500); do
        cat > "$srcdir/f$i.c" << EOF
#include <stdio.h>
int f$i(int x) { return x + $i; }
EOF
    done

    for scenario in baseline hook; do
        rm -rf "$TESTDIR/ccache_cache_$scenario"
        mkdir -p "$TESTDIR/ccache_cache_$scenario"
        export CCACHE_DIR="$TESTDIR/ccache_cache_$scenario"
        export CCACHE_NODIRECT=1
        export CCACHE_NOHASHDIR=1
        "$ccache" -C >/dev/null 2>&1

        if [ "$scenario" = "hook" ]; then
            export LD_PRELOAD="$HOOK_SO"
            export GPUCOMPRESS_QUIET=1
        else
            unset LD_PRELOAD GPUCOMPRESS_QUIET
        fi

        echo -e "${GREEN}>>> $scenario: 编译 500 个文件${NC}"
        local t0=$(date +%s.%N)
        for i in $(seq 1 500); do
            "$ccache" gcc -c "$srcdir/f$i.c" -o "$srcdir/f$i.o" >/dev/null 2>&1
        done
        local t1=$(date +%s.%N)
        local cold=$(python3 -c "print(f'{$t1 - $t0:.2f}')")

        # 清理 .o 重新编译（应命中 cache）
        rm -f "$srcdir"/*.o
        local t2=$(date +%s.%N)
        for i in $(seq 1 500); do
            "$ccache" gcc -c "$srcdir/f$i.c" -o "$srcdir/f$i.o" >/dev/null 2>&1
        done
        local t3=$(date +%s.%N)
        local hot=$(python3 -c "print(f'{$t3 - $t2:.2f}')")

        echo -e "  cold compile: ${cold}s, hot compile: ${hot}s"
        echo "$scenario,ccache,cold_compile,$cold,s" >> "$RESULT_CSV"
        echo "$scenario,ccache,hot_compile,$hot,s" >> "$RESULT_CSV"
    done

    unset LD_PRELOAD GPUCOMPRESS_QUIET CCACHE_DIR CCACHE_NODIRECT CCACHE_NOHASHDIR
}

# ----------------------------------------------------------
#  ML 数据加载 Workload
# ----------------------------------------------------------
run_ml_loading() {
    echo ""
    echo -e "${YELLOW}### ML Data Loading Workload ###${NC}"
    local imgdir="$TESTDIR/imagenet_like"
    mkdir -p "$imgdir"

    # 生成 1000 个 1MB 图片文件（共 1GB）
    echo -e "${BLUE}生成 1000 个 1MB 模拟图片...${NC}"
    for i in $(seq 1 1000); do
        dd if=/dev/urandom of="$imgdir/img_$i.bin" bs=1M count=1 status=none
    done

    # 用 hook 创建 RAW 并压缩
    echo -e "${BLUE}用 hook 重写文件以生成 header...${NC}"
    for i in $(seq 1 1000); do
        LD_PRELOAD="$HOOK_SO" GPUCOMPRESS_QUIET=1 dd if="$imgdir/img_$i.bin" of="$imgdir/img_${i}_hook.bin" bs=1M count=1 status=none
    done
    "$GPU_DAEMON" "$imgdir" >/dev/null 2>&1 || true

    for scenario in baseline hook; do
        local pattern_dir="$imgdir"
        if [ "$scenario" = "hook" ]; then
            pattern_dir="$imgdir/*_hook.bin"
            export LD_PRELOAD="$HOOK_SO"
            export GPUCOMPRESS_QUIET=1
        else
            pattern_dir="$imgdir/img_*.bin"
            unset LD_PRELOAD GPUCOMPRESS_QUIET
        fi

        echo -e "${GREEN}>>> $scenario: 顺序读取 1000 张图片${NC}"
        local t0=$(date +%s.%N)
        python3 - << PYEOF
import glob, time
files = sorted(glob.glob('$pattern_dir'))
start = time.time()
for f in files:
    with open(f, 'rb') as fp:
        fp.read()
print(f"  sequential_time={time.time()-start:.2f}s, throughput={len(files)*1/(time.time()-start):.1f} MB/s")
PYEOF
        local t1=$(date +%s.%N)
        local seq_sec=$(python3 -c "print(f'{$t1 - $t0:.2f}')")

        echo -e "${GREEN}>>> $scenario: 随机读取 1000 张图片${NC}"
        local t2=$(date +%s.%N)
        python3 - << PYEOF
import glob, random, time
files = glob.glob('$pattern_dir')
random.shuffle(files)
start = time.time()
for f in files[:200]:
    with open(f, 'rb') as fp:
        fp.read()
print(f"  random_time={time.time()-start:.2f}s, throughput={200*1/(time.time()-start):.1f} MB/s")
PYEOF
        local t3=$(date +%s.%N)
        local rand_sec=$(python3 -c "print(f'{$t3 - $t2:.2f}')")

        echo "$scenario,ml_load,seq_time,$seq_sec,s" >> "$RESULT_CSV"
        echo "$scenario,ml_load,random_time,$rand_sec,s" >> "$RESULT_CSV"
    done

    unset LD_PRELOAD GPUCOMPRESS_QUIET
}

# ----------------------------------------------------------
#  主流程
# ----------------------------------------------------------
echo "========================================"
echo "  Real Workload Comprehensive"
echo "========================================"
echo "依赖目录: $DEPS_DIR"
echo "测试目录: $TESTDIR"
echo "========================================"

ensure_leveldb
ensure_ccache

run_sqlite
run_leveldb
run_ccache
run_ml_loading

# ----------------------------------------------------------
#  汇总
# ----------------------------------------------------------
echo ""
echo "========================================"
echo "       真实 Workload 汇总"
echo "========================================"
python3 - << PYEOF
import csv
rows = []
with open('$RESULT_CSV') as f:
    reader = csv.DictReader(f)
    for r in reader:
        rows.append(r)

print(f"{'Scenario':<12} {'Workload':<12} {'Metric':<18} {'Value':<10} {'Unit':<8}")
print("-" * 70)
for r in rows:
    print(f"{r['scenario']:<12} {r['workload']:<12} {r['metric']:<18} {r['value']:<10} {r['unit']:<8}")

print("\n--- Hook vs Baseline 比例 ---")
base = {}
hook = {}
for r in rows:
    key = (r['workload'], r['metric'])
    if r['value'] == 'FAILED':
        continue
    val = float(r['value'])
    if r['scenario'] == 'baseline':
        base[key] = val
    elif r['scenario'] == 'hook':
        hook[key] = val
for key in sorted(base.keys()):
    if key in hook:
        ratio = hook[key] / base[key] * 100
        # 时间是越低越好，所以比例要反一下
        if 'time' in key[1] or 'compile' in key[1]:
            ratio = base[key] / hook[key] * 100
        print(f"  {key}: {ratio:.1f}%")
PYEOF

rm -rf "$TESTDIR"
echo ""
echo -e "${GREEN}完成。CSV: $RESULT_CSV${NC}"
