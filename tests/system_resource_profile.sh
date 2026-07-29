#!/usr/bin/env bash
set -euo pipefail

# Collect reproducible process and system resource evidence around the
# baseline/CPU/GPU offload business workload. Raw pidstat/sar/nvidia-smi logs
# are retained so reported values can be independently audited.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/system_resource_${RUN_ID}}"
DURATION="${GPUC_RUNTIME:-5}"
REPEATS="${GPUC_REPEATS:-5}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
DECOMP_CPU="${GPUC_DECOMP_CPU:-0}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-4096}"
export GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-$DECOMP_CPU}"
mkdir -p "$RESULT_DIR"

for command in pidstat sar nvidia-smi; do
    command -v "$command" >/dev/null || {
        echo "Missing required sampler: $command" >&2
        exit 1
    }
done
make -C "$PROJECT_DIR" bin/test_cpu_offload >/dev/null

{
    echo "run_id=$RUN_ID"
    echo "git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')"
    echo "gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader | head -1)"
    echo "duration_s=$DURATION"
    echo "repeats=$REPEATS"
    echo "business_workers=$WORKERS"
    echo "target_decomp_mib_s=$TARGET_MIB_S"
    echo "samplers=pidstat -u -r -w (process); sar -u -r -B -W (system); nvidia-smi 200ms"
} > "$RESULT_DIR/environment.txt"

{
    echo "perf_binary=$(command -v perf || echo unavailable)"
    echo "perf_event_paranoid=$(cat /proc/sys/kernel/perf_event_paranoid 2>/dev/null || echo unavailable)"
    echo "intel_pcm=$(command -v pcm-memory || command -v pcm || echo unavailable)"
    echo "powercap_entries=$(find /sys/class/powercap -mindepth 1 -maxdepth 2 -type f -name energy_uj 2>/dev/null | wc -l)"
    echo
    echo "[perf probe]"
    perf stat -e task-clock,cycles,instructions,cache-misses true
} > "$RESULT_DIR/capability_probe.txt" 2>&1 || true

echo "scenario,repeat,elapsed_sec,business_ops_s,decomp_mib_s,user_cpu_sec,sys_cpu_sec,process_cpu_cores,submit_cpu_sec,worker_cpu_sec,maxrss_kib,minflt,majflt,nvcsw,nivcsw,gpu_util_avg_pct,gpu_power_avg_w,gpu_board_joules" \
    > "$RESULT_DIR/runs.csv"

scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for idx in 0 1 2; do
        scenario="${scenarios[$(( (idx + shift) % 3 ))]}"
        tag="${scenario}_r${repeat}"
        out="$RESULT_DIR/${tag}_workload.csv"
        LC_ALL=C "$PROJECT_DIR/bin/test_cpu_offload" "$scenario" "$DURATION" \
            "$WORKERS" "$DECOMP_CPU" "$TARGET_MIB_S" > "$out" &
        workload_pid=$!

        LC_ALL=C pidstat -u -r -w -p "$workload_pid" 1 \
            > "$RESULT_DIR/${tag}_pidstat.txt" 2>&1 &
        pidstat_pid=$!
        LC_ALL=C sar -u -r -B -W 1 \
            > "$RESULT_DIR/${tag}_sar.txt" 2>&1 &
        sar_pid=$!
        nvidia-smi --query-gpu=timestamp,utilization.gpu,power.draw,memory.used \
            --format=csv,noheader,nounits --loop-ms=200 \
            > "$RESULT_DIR/${tag}_gpu.csv" 2>/dev/null &
        smi_pid=$!

        wait "$workload_pid"
        for sampler_pid in "$pidstat_pid" "$sar_pid" "$smi_pid"; do
            kill "$sampler_pid" 2>/dev/null || true
            wait "$sampler_pid" 2>/dev/null || true
        done

        python3 - "$out" "$RESULT_DIR/${tag}_gpu.csv" \
            "$RESULT_DIR/runs.csv" "$repeat" <<'PY'
import csv,sys
line=open(sys.argv[1]).read().strip().splitlines()[-1]
gpu_log,out,repeat=sys.argv[2:]
names=["scenario","elapsed","workers","business","decomp","user","system",
       "submit_user","submit_system","maxrss","minflt","majflt","nvcsw",
       "nivcsw","calls","queue_ms","pack_ms","h2d_ms","kernel_ms","d2h_ms",
       "unpack_ms","total_ms","worker_user","worker_system","pinned"]
v=line.split(",")
if len(v)!=len(names): raise SystemExit(f"unexpected workload fields: {len(v)}")
r=dict(zip(names,v))
samples=[]
for row in csv.reader(open(gpu_log)):
    try: samples.append((float(row[1]),float(row[2])))
    except (ValueError,IndexError): pass
util=sum(x for x,_ in samples)/len(samples) if samples else 0
power=sum(x for _,x in samples)/len(samples) if samples else 0
elapsed=float(r["elapsed"]); process=float(r["user"])+float(r["system"])
row=[r["scenario"],repeat,r["elapsed"],r["business"],r["decomp"],
     r["user"],r["system"],process/elapsed,
     float(r["submit_user"])+float(r["submit_system"]),
     float(r["worker_user"])+float(r["worker_system"]),
     r["maxrss"],r["minflt"],r["majflt"],r["nvcsw"],r["nivcsw"],
     util,power,power*elapsed]
with open(out,"a",newline="") as f:
    csv.writer(f,lineterminator="\n").writerow(row)
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1])))
metrics=["business_ops_s","decomp_mib_s","process_cpu_cores",
         "submit_cpu_sec","worker_cpu_sec","maxrss_kib","minflt","majflt",
         "nvcsw","nivcsw","gpu_util_avg_pct","gpu_power_avg_w",
         "gpu_board_joules"]
fields=["scenario","n"]
for m in metrics: fields += [m+"_mean",m+"_ci95"]
with open(sys.argv[2],"w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n"); w.writeheader()
    for scenario in ("baseline","cpu","gpu"):
        rs=[r for r in rows if r["scenario"]==scenario]
        out={"scenario":scenario,"n":len(rs)}
        for m in metrics:
            vals=[float(r[m]) for r in rs]
            mean=statistics.mean(vals)
            ci=1.96*statistics.stdev(vals)/math.sqrt(len(vals)) if len(vals)>1 else 0
            out[m+"_mean"]=f"{mean:.6f}"; out[m+"_ci95"]=f"{ci:.6f}"
        w.writerow(out)
PY

echo "[OK] $RESULT_DIR"
