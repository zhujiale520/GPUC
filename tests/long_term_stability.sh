#!/usr/bin/env bash
set -euo pipefail

# Configurable soak test. Defaults to one hour; CI/smoke runs can lower
# GPUC_RUNTIME. Every run keeps fio JSON, one-second bandwidth samples,
# nvidia-smi samples, pre/post SHA-256 and a statistical summary.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/stability_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-stability-XXXXXX)"
DURATION="${GPUC_RUNTIME:-3600}"
SIZE="${GPUC_SIZE:-256M}"
BS="${GPUC_BS:-128k}"
JOBS="${GPUC_JOBS:-1}"
REPEATS="${GPUC_REPEATS:-1}"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
smi_pid=""
cleanup() {
    if [[ -n "$smi_pid" ]]; then
        kill "$smi_pid" 2>/dev/null || true
        wait "$smi_pid" 2>/dev/null || true
    fi
    rm -r -- "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT
for value in "$DURATION" "$JOBS" "$REPEATS"; do
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || {
        echo "ERROR: runtime, jobs and repeats must be positive integers." >&2
        exit 2
    }
done
mkdir -p "$RESULT_DIR" "$TEST_DIR/data"

make -C "$PROJECT_DIR" bin/libgpuhook.so bin/gpu_compress_daemon >/dev/null
file="$TEST_DIR/data/soak.bin"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    fio --name=prepare --filename="$file" --size="$SIZE" --bs=1M --rw=write \
        --buffer_pattern=0x01 --direct=0 --ioengine=sync >/dev/null
"$DAEMON" "$TEST_DIR/data" > "$RESULT_DIR/daemon.log" 2>&1

logical_sha() {
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
        dd if="$file" bs=1M status=none | sha256sum | awk '{print $1}'
}
before_sha="$(logical_sha)"

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD)
kernel=$(uname -srvmo)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)
duration_s=$DURATION
size=$SIZE
bs=$BS
jobs=$JOBS
repeats=$REPEATS
logical_sha256_before=$before_sha
EOF
echo "repeat,bw_mib_s,iops,mean_us,p95_us,p99_us,p999_us,error,bw_samples,bw_cv_pct,gpu_samples,gpu_util_mean_pct,gpu_power_mean_w,gpu_power_max_w,gpu_memory_mean_mib,logical_sha256" \
    > "$RESULT_DIR/runs.csv"

for repeat in $(seq 1 "$REPEATS"); do
    tag="soak_r${repeat}"
    json="$RESULT_DIR/${tag}.json"
    gpu_log="$RESULT_DIR/${tag}_gpu.csv"
    nvidia-smi --query-gpu=timestamp,utilization.gpu,power.draw,memory.used \
        --format=csv,noheader,nounits --loop-ms=500 > "$gpu_log" 2>/dev/null &
    smi_pid=$!
    set +e
    timeout --kill-after=30 "$((DURATION + 120))" \
        env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
        fio --name="$tag" --filename="$file" --size="$SIZE" --bs="$BS" \
            --rw=read --runtime="$DURATION" --time_based --direct=0 \
            --ioengine=sync --thread=1 --numjobs="$JOBS" --group_reporting \
            --readonly --percentile_list=95:99:99.9 --log_avg_msec=1000 \
            --write_bw_log="$RESULT_DIR/${tag}" --output-format=json > "$json"
    fio_rc=$?
    set -e
    kill "$smi_pid" 2>/dev/null || true
    wait "$smi_pid" 2>/dev/null || true
    smi_pid=""
    [[ "$fio_rc" -eq 0 ]] || {
        echo "fio failed or timed out: rc=$fio_rc" >&2
        exit 1
    }

    after_sha="$(logical_sha)"
    [[ "$after_sha" == "$before_sha" ]]
    bw_log="$(find "$RESULT_DIR" -maxdepth 1 -name "${tag}_bw*.log" -print -quit)"
    python3 - "$json" "$bw_log" "$gpu_log" "$RESULT_DIR/runs.csv" "$repeat" \
        "$after_sha" "$DURATION" <<'PY'
import csv,json,math,statistics,sys
j=json.load(open(sys.argv[1])); job=j["jobs"][0]; r=job["read"]
lat=r.get("clat_ns") or r.get("lat_ns") or {}; pct=lat.get("percentile",{})
samples=[]
if sys.argv[2]:
    for row in csv.reader(open(sys.argv[2])):
        try: samples.append(float(row[1])/1024.0)
        except (ValueError,IndexError): pass
gpu=[]
for row in csv.reader(open(sys.argv[3], errors="replace")):
    try: gpu.append(tuple(float(value.strip()) for value in row[-3:]))
    except (ValueError, IndexError): pass
if not gpu: raise SystemExit("no valid nvidia-smi samples")
cv=(statistics.pstdev(samples)/statistics.mean(samples)*100
    if len(samples)>1 and statistics.mean(samples)>0 else 0)
def us(key): return float(pct.get(key,0))/1000.0
out=[sys.argv[5],r["bw"]/1024.0,r["iops"],
     float(lat.get("mean",0))/1000.0,us("95.000000"),us("99.000000"),
     us("99.900000"),job.get("error",0),len(samples),cv,len(gpu),
     statistics.mean(x[0] for x in gpu), statistics.mean(x[1] for x in gpu),
     max(x[1] for x in gpu), statistics.mean(x[2] for x in gpu), sys.argv[6]]
with open(sys.argv[4],"a",newline="") as f:
    csv.writer(f,lineterminator="\n").writerow(out)
if job.get("error",0): raise SystemExit(1)
if len(samples) < max(1, int(sys.argv[7]) - 2):
    raise SystemExit(f"incomplete one-second bandwidth samples: {len(samples)}")
PY
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1])))
metrics=["bw_mib_s","iops","mean_us","p95_us","p99_us","p999_us","bw_cv_pct",
         "gpu_util_mean_pct","gpu_power_mean_w","gpu_power_max_w","gpu_memory_mean_mib"]
with open(sys.argv[2],"w",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow(["metric","n","mean","ci95"])
    for metric in metrics:
        vals=[float(r[metric]) for r in rows]
        ci=1.96*statistics.stdev(vals)/math.sqrt(len(vals)) if len(vals)>1 else 0
        w.writerow([metric,len(vals),statistics.mean(vals),ci])
PY

echo "logical_sha256_after=$(logical_sha)" >> "$RESULT_DIR/environment.txt"
sha256sum "$PROJECT_DIR/tests/long_term_stability.sh" \
    "$PROJECT_DIR/src/hook.c" "$PROJECT_DIR/src/gpu_lz4.cu" \
    > "$RESULT_DIR/SOURCE_MANIFEST.sha256"
echo "[OK] $RESULT_DIR"
