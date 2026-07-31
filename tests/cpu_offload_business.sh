#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/cpu_offload_${RUN_ID}}"
DURATION="${GPUC_RUNTIME:-8}"
REPEATS="${GPUC_REPEATS:-5}"
WORKERS="${GPUC_BUSINESS_WORKERS:-4}"
DECOMP_CPU="${GPUC_DECOMP_CPU:-0}"
TARGET_MIB_S="${GPUC_TARGET_MIB_S:-0}"
WORKSET_MIB="${GPUC_WORKSET_MIB:-16}"
COMPRESSIBLE_PCT="${GPUC_COMPRESSIBLE_PCT:-100}"
BATCH_BLOCKS="${GPUC_BATCH_BLOCKS:-128}"
export GPUC_WORKER_CPU="${GPUC_WORKER_CPU:-$DECOMP_CPU}"
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
target_decomp_mib_s=$TARGET_MIB_S
workset_mib=$WORKSET_MIB
compressible_pct=$COMPRESSIBLE_PCT
batch_blocks=$BATCH_BLOCKS
gpu_worker_cpu=$GPUC_WORKER_CPU
affinity=business workers pinned to cores 0..N-1; submit/decompressor pinned to core $DECOMP_CPU
data=deterministic page pattern; requested compressible pages recorded above; identical CPU-generated LZ4 blocks
EOF
echo "scenario,repeat,elapsed_sec,business_ops_s,decomp_mib_s,user_cpu_sec,sys_cpu_sec,submit_user_sec,submit_sys_sec,maxrss_kib,minflt,majflt,nvcsw,nivcsw,decomp_calls,queue_ms,pack_ms,h2d_ms,kernel_ms,d2h_ms,unpack_ms,total_ms,worker_user_sec,worker_sys_sec,pinned_host,gpu_util_avg_pct,power_avg_w,gpu_board_joules,decomp_gib,gpu_board_j_per_gib" > "$RESULT_DIR/runs.csv"

scenarios=(baseline cpu gpu)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat - 1) % 3 ))
    for idx in 0 1 2; do
        scenario="${scenarios[$(( (idx + shift) % 3 ))]}"
        gpu_log="$RESULT_DIR/${scenario}_r${repeat}_gpu.csv"
        nvidia-smi --query-gpu=utilization.gpu,power.draw \
            --format=csv,noheader,nounits --loop-ms=200 > "$gpu_log" 2>/dev/null &
        smi_pid=$!
        line="$("$PROJECT_DIR/bin/test_cpu_offload" "$scenario" "$DURATION" "$WORKERS" \
            "$DECOMP_CPU" "$TARGET_MIB_S")"
        kill "$smi_pid" 2>/dev/null || true
        wait "$smi_pid" 2>/dev/null || true
        python3 - "$line" "$gpu_log" "$RESULT_DIR/runs.csv" "$repeat" <<'PY'
import csv,sys
line,gpu_log,out,repeat=sys.argv[1:]
names=["scenario","elapsed","workers","business","decomp","user","system",
       "submit_user","submit_system","maxrss","minflt","majflt","nvcsw",
       "nivcsw","calls","queue_ms","pack_ms","h2d_ms","kernel_ms","d2h_ms",
       "unpack_ms","total_ms","worker_user","worker_system","pinned"]
values=line.split(",")
if len(values) != len(names):
    raise SystemExit(f"unexpected test output fields: {len(values)}")
r=dict(zip(names,values)); s=r["scenario"]
samples=[]
for row in csv.reader(open(gpu_log)):
    try: samples.append((float(row[0]),float(row[1])))
    except (ValueError,IndexError): pass
util=sum(x for x,_ in samples)/len(samples) if samples else 0
power=sum(x for _,x in samples)/len(samples) if samples else 0
elapsed=float(r["elapsed"])
decomp_gib=float(r["decomp"])*elapsed/1024.0
board_j=power*elapsed
j_per_gib=board_j/decomp_gib if decomp_gib > 0 else 0
with open(out,"a",newline="") as f:
    csv.writer(f,lineterminator="\n").writerow(
        [s,repeat] + [r[k] for k in names[1:] if k != "workers"] +
        [f"{util:.3f}",f"{power:.3f}",f"{board_j:.6f}",
         f"{decomp_gib:.6f}",f"{j_per_gib:.6f}"])
print(f"{s:8s} repeat={repeat} business={float(r['business']):.0f} ops/s "
      f"decomp={float(r['decomp']):.1f} MiB/s cpu={float(r['user'])+float(r['system']):.2f}s "
      f"worker={float(r['worker_user'])+float(r['worker_system']):.2f}s "
      f"rss={int(r['maxrss'])} KiB gpu={util:.1f}% power={power:.1f}W")
PY
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1]))); groups={}
for r in rows: groups.setdefault(r["scenario"],[]).append(r)
with open(sys.argv[2],"w",newline="") as f:
    fields=["scenario","n","business_mean_ops_s","business_std","business_ci95",
            "business_vs_baseline_pct","decomp_mean_mib_s","process_cpu_mean_sec",
            "process_cpu_cores","submit_cpu_mean_sec","worker_cpu_mean_sec",
            "maxrss_mean_kib","minflt_mean","majflt_mean","nvcsw_mean","nivcsw_mean",
            "queue_mean_ms","pack_mean_ms","h2d_mean_ms","kernel_mean_ms",
            "d2h_mean_ms","unpack_mean_ms","request_total_mean_ms",
            "gpu_util_mean_pct","power_mean_w","gpu_board_energy_mean_j",
            "decomp_mean_gib","gpu_board_j_per_gib",
            "incremental_gpu_power_vs_idle_w",
            "incremental_gpu_j_per_gib"]
    w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n"); w.writeheader()
    base=statistics.mean(float(r["business_ops_s"]) for r in groups["baseline"])
    idle_power=statistics.mean(float(r["power_avg_w"]) for r in groups["baseline"])
    for s,rs in groups.items():
        b=[float(r["business_ops_s"]) for r in rs]; mean=statistics.mean(b)
        std=statistics.stdev(b) if len(b)>1 else 0; ci=1.96*std/math.sqrt(len(b)) if len(b)>1 else 0
        avg=lambda key: statistics.mean(float(r[key]) for r in rs)
        process_cpu=avg("user_cpu_sec")+avg("sys_cpu_sec")
        elapsed=avg("elapsed_sec")
        row=dict(scenario=s,n=len(rs),business_mean_ops_s=f"{mean:.3f}",
                 business_std=f"{std:.3f}",business_ci95=f"{ci:.3f}",
                 business_vs_baseline_pct=f"{mean/base*100:.3f}",
                 decomp_mean_mib_s=f"{avg('decomp_mib_s'):.3f}",
                 process_cpu_mean_sec=f"{process_cpu:.6f}",
                 process_cpu_cores=f"{process_cpu/elapsed:.3f}",
                 submit_cpu_mean_sec=f"{avg('submit_user_sec')+avg('submit_sys_sec'):.6f}",
                 worker_cpu_mean_sec=f"{avg('worker_user_sec')+avg('worker_sys_sec'):.6f}",
                 maxrss_mean_kib=f"{avg('maxrss_kib'):.1f}",
                 minflt_mean=f"{avg('minflt'):.1f}",majflt_mean=f"{avg('majflt'):.1f}",
                 nvcsw_mean=f"{avg('nvcsw'):.1f}",nivcsw_mean=f"{avg('nivcsw'):.1f}",
                 queue_mean_ms=f"{avg('queue_ms'):.6f}",pack_mean_ms=f"{avg('pack_ms'):.6f}",
                 h2d_mean_ms=f"{avg('h2d_ms'):.6f}",kernel_mean_ms=f"{avg('kernel_ms'):.6f}",
                 d2h_mean_ms=f"{avg('d2h_ms'):.6f}",unpack_mean_ms=f"{avg('unpack_ms'):.6f}",
                 request_total_mean_ms=f"{avg('total_ms'):.6f}",
                 gpu_util_mean_pct=f"{avg('gpu_util_avg_pct'):.3f}",
                 power_mean_w=f"{avg('power_avg_w'):.3f}",
                 gpu_board_energy_mean_j=f"{avg('gpu_board_joules'):.6f}",
                 decomp_mean_gib=f"{avg('decomp_gib'):.6f}",
                 gpu_board_j_per_gib=f"{avg('gpu_board_j_per_gib'):.6f}",
                 incremental_gpu_power_vs_idle_w=f"{max(avg('power_avg_w')-idle_power,0):.6f}",
                 incremental_gpu_j_per_gib=(
                     f"{max(avg('power_avg_w')-idle_power,0)*1024/avg('decomp_mib_s'):.6f}"
                     if avg("decomp_mib_s") > 0 else "0.000000"))
        w.writerow(row)
        print(f"{s:8s} business={mean:.0f} ops/s ({mean/base*100:.1f}% baseline) decomp={float(row['decomp_mean_mib_s']):.1f} MiB/s")
PY
echo "[OK] $RESULT_DIR"
