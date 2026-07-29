#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/cpu_offload_${RUN_ID}}"
DURATION="${GPUC_RUNTIME:-8}"
REPEATS="${GPUC_REPEATS:-5}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
mkdir -p "$RESULT_DIR"

make -C "$PROJECT_DIR" bin/test_cpu_offload >/dev/null
cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)
cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
duration=$DURATION
repeats=$REPEATS
business_workers=$WORKERS
affinity=business workers pinned to cores 0..N-1; decompressor pinned to core 0
data=16 MiB deterministic page pattern; identical CPU-generated LZ4 blocks
EOF
echo "scenario,repeat,elapsed_sec,business_ops_s,decomp_mib_s,user_cpu_sec,sys_cpu_sec,gpu_util_avg_pct,power_avg_w" > "$RESULT_DIR/runs.csv"

scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for idx in 0 1 2; do
        scenario="${scenarios[$(( (idx + shift) % 3 ))]}"
        gpu_log="$RESULT_DIR/${scenario}_r${repeat}_gpu.csv"
        nvidia-smi --query-gpu=utilization.gpu,power.draw \
            --format=csv,noheader,nounits --loop-ms=200 > "$gpu_log" 2>/dev/null &
        smi_pid=$!
        line="$("$PROJECT_DIR/bin/test_cpu_offload" "$scenario" "$DURATION" "$WORKERS")"
        kill "$smi_pid" 2>/dev/null || true
        wait "$smi_pid" 2>/dev/null || true
        python3 - "$line" "$gpu_log" "$RESULT_DIR/runs.csv" "$repeat" <<'PY'
import csv,sys
line,gpu_log,out,repeat=sys.argv[1:]
s,elapsed,workers,business,decomp,user,system=line.split(",")
samples=[]
for row in csv.reader(open(gpu_log)):
    try: samples.append((float(row[0]),float(row[1])))
    except (ValueError,IndexError): pass
util=sum(x for x,_ in samples)/len(samples) if samples else 0
power=sum(x for _,x in samples)/len(samples) if samples else 0
with open(out,"a",newline="") as f:
    csv.writer(f).writerow([s,repeat,elapsed,business,decomp,user,system,f"{util:.3f}",f"{power:.3f}"])
print(f"{s:8s} repeat={repeat} business={float(business):.0f} ops/s decomp={float(decomp):.1f} MiB/s user={float(user):.2f}s gpu={util:.1f}% power={power:.1f}W")
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1]))); groups={}
for r in rows: groups.setdefault(r["scenario"],[]).append(r)
with open(sys.argv[2],"w",newline="") as f:
    fields=["scenario","n","business_mean_ops_s","business_std","business_ci95","business_vs_baseline_pct","decomp_mean_mib_s","user_cpu_mean_sec","sys_cpu_mean_sec","gpu_util_mean_pct","power_mean_w"]
    w=csv.DictWriter(f,fieldnames=fields); w.writeheader()
    base=statistics.mean(float(r["business_ops_s"]) for r in groups["baseline"])
    for s,rs in groups.items():
        b=[float(r["business_ops_s"]) for r in rs]; mean=statistics.mean(b)
        std=statistics.stdev(b) if len(b)>1 else 0; ci=1.96*std/math.sqrt(len(b)) if len(b)>1 else 0
        row=dict(scenario=s,n=len(rs),business_mean_ops_s=f"{mean:.3f}",business_std=f"{std:.3f}",business_ci95=f"{ci:.3f}",business_vs_baseline_pct=f"{mean/base*100:.3f}",
                 decomp_mean_mib_s=f"{statistics.mean(float(r['decomp_mib_s']) for r in rs):.3f}",
                 user_cpu_mean_sec=f"{statistics.mean(float(r['user_cpu_sec']) for r in rs):.6f}",
                 sys_cpu_mean_sec=f"{statistics.mean(float(r['sys_cpu_sec']) for r in rs):.6f}",
                 gpu_util_mean_pct=f"{statistics.mean(float(r['gpu_util_avg_pct']) for r in rs):.3f}",
                 power_mean_w=f"{statistics.mean(float(r['power_avg_w']) for r in rs):.3f}")
        w.writerow(row)
        print(f"{s:8s} business={mean:.0f} ops/s ({mean/base*100:.1f}% baseline) decomp={float(row['decomp_mean_mib_s']):.1f} MiB/s")
PY
echo "[OK] $RESULT_DIR"
