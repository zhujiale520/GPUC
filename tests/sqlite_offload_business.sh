#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/sqlite_offload_${RUN_ID}}"
DURATION="${GPUC_RUNTIME:-8}"
REPEATS="${GPUC_REPEATS:-5}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
ROWS="${GPUC_SQLITE_ROWS:-100000}"
SPAN="${GPUC_SQLITE_SPAN:-256}"
DECOMP_CPU="${GPUC_DECOMP_CPU:-0}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-4096}"
PHYSICAL_GPU="${GPUC_PHYSICAL_GPU:-0}"
export GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-$DECOMP_CPU}"
DB_PATH="$RESULT_DIR/workload.sqlite"
FREQ_GUARD_CPU="${GPUC_FREQ_GUARD_CPU:-23}"
[[ "$PHYSICAL_GPU" =~ ^[0-9]+$ ]] || {
    echo "ERROR: GPUC_PHYSICAL_GPU must be a non-negative integer." >&2
    exit 2
}
mkdir -p "$RESULT_DIR"

make -C "$PROJECT_DIR" bin/test_cpu_offload >/dev/null
python3 "$PROJECT_DIR/tests/sqlite_business.py" \
    --db "$DB_PATH" --rows "$ROWS" --span "$SPAN" --workers 1 --duration 0.1 --prepare >/dev/null

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
gpu=$(nvidia-smi -i "$PHYSICAL_GPU" \
  --query-gpu=index,name,uuid,driver_version,compute_cap,memory.total \
  --format=csv,noheader | head -1)
cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
duration=$DURATION
repeats=$REPEATS
sqlite_rows=$ROWS
sqlite_range_span=$SPAN
business_workers=$WORKERS
decomp_cpu=$DECOMP_CPU
target_decomp_mib_s=$TARGET_MIB_S
gpu_worker_cpu=$GPUC_WORKER_CPU
workset_mib=${GPUC_WORKSET_MIB:-16}
pin_workset=${GPUC_PIN_WORKSET:-auto}
frequency_guard_cpu=$FREQ_GUARD_CPU
workload=SQLite read-only indexed range aggregates (span=$SPAN); 512-byte payload
EOF

echo "scenario,repeat,qps,latency_mean_us,latency_p50_us,latency_p95_us,latency_p99_us,decomp_mib_s,decomp_process_cpu_sec,maxrss_kib" > "$RESULT_DIR/runs.csv"
scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for idx in 0 1 2; do
        scenario="${scenarios[$(( (idx + shift) % 3 ))]}"
        decomp_log="$RESULT_DIR/${scenario}_r${repeat}_decomp.csv"
        taskset -c "$FREQ_GUARD_CPU" sh -c 'while :; do :; done' &
        guard_pid=$!
        sleep 0.2
        python3 "$PROJECT_DIR/tests/sqlite_business.py" \
            --db "$DB_PATH" --rows "$ROWS" --span "$SPAN" --workers "$WORKERS" --duration 0.2 >/dev/null
        "$PROJECT_DIR/bin/test_cpu_offload" "$scenario" "$((DURATION + 1))" 0 \
            "$DECOMP_CPU" "$TARGET_MIB_S" > "$decomp_log" &
        decomp_pid=$!
        sleep 0.3
        db_json="$(python3 "$PROJECT_DIR/tests/sqlite_business.py" \
            --db "$DB_PATH" --rows "$ROWS" --span "$SPAN" --workers "$WORKERS" --duration "$DURATION")"
        wait "$decomp_pid"
        kill "$guard_pid" 2>/dev/null || true
        wait "$guard_pid" 2>/dev/null || true
        python3 - "$scenario" "$repeat" "$db_json" "$decomp_log" "$RESULT_DIR/runs.csv" <<'PY'
import csv,json,sys
scenario,repeat,db_json,decomp_log,out=sys.argv[1:]
d=json.loads(db_json)
line=open(decomp_log).read().strip().splitlines()[-1].split(",")
decomp=float(line[4]) if len(line)>4 else 0.0
cpu=(float(line[5])+float(line[6])) if len(line)>6 else 0.0
rss=int(line[9]) if len(line)>9 else 0
row=[scenario,repeat,d["qps"],d["latency_mean_us"],d["latency_p50_us"],
     d["latency_p95_us"],d["latency_p99_us"],decomp,cpu,rss]
with open(out,"a",newline="") as f: csv.writer(f).writerow(row)
print(f"{scenario:8s} repeat={repeat} qps={d['qps']:.0f} "
      f"p99={d['latency_p99_us']:.1f}us decomp={decomp:.1f}MiB/s cpu={cpu:.2f}s")
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1]))); groups={}
for row in rows: groups.setdefault(row["scenario"],[]).append(row)
fields=["scenario","n","qps_mean","qps_std","qps_ci95","qps_vs_baseline_pct",
        "latency_p99_mean_us","decomp_mean_mib_s","decomp_process_cpu_mean_sec",
        "maxrss_mean_kib"]
base=statistics.mean(float(r["qps"]) for r in groups["baseline"])
with open(sys.argv[2],"w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields); w.writeheader()
    for scenario,rs in groups.items():
        q=[float(r["qps"]) for r in rs]; mean=statistics.mean(q)
        std=statistics.stdev(q) if len(q)>1 else 0.0
        ci=1.96*std/math.sqrt(len(q)) if len(q)>1 else 0.0
        row=dict(scenario=scenario,n=len(rs),qps_mean=f"{mean:.3f}",
                 qps_std=f"{std:.3f}",qps_ci95=f"{ci:.3f}",
                 qps_vs_baseline_pct=f"{mean/base*100:.3f}",
                 latency_p99_mean_us=f"{statistics.mean(float(r['latency_p99_us']) for r in rs):.3f}",
                 decomp_mean_mib_s=f"{statistics.mean(float(r['decomp_mib_s']) for r in rs):.3f}",
                 decomp_process_cpu_mean_sec=f"{statistics.mean(float(r['decomp_process_cpu_sec']) for r in rs):.6f}",
                 maxrss_mean_kib=f"{statistics.mean(float(r['maxrss_kib']) for r in rs):.1f}")
        w.writerow(row)
        print(f"{scenario:8s} qps={mean:.0f} ({mean/base*100:.1f}% baseline) "
              f"p99={float(row['latency_p99_mean_us']):.1f}us")
PY
echo "[OK] $RESULT_DIR"
