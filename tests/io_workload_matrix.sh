#!/usr/bin/env bash
set -euo pipefail

# P1 storage workload matrix.
# COMPRESSED files are immutable, so read workloads compare all four paths;
# write/randwrite/randrw compare Baseline and Hook RAW only.
# The intercepted path uses synchronous libc I/O: iodepth is 1 and numjobs is
# reported as application concurrency. A separate Baseline libaio sweep records
# true queue-depth behavior without pretending that GPUC intercepts app AIO.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/io_matrix_${RUN_ID}}"
TEST_ROOT="${GPUC_TEST_ROOT:-/tmp}"
[[ -d "$TEST_ROOT" && -w "$TEST_ROOT" ]] || {
    echo "ERROR: GPUC_TEST_ROOT must be an existing writable directory: $TEST_ROOT" >&2
    exit 2
}
TEST_DIR="$(mktemp -d "$TEST_ROOT/gpuc-io-matrix-XXXXXX")"
SIZE="${GPUC_SIZE:-64M}"
RUNTIME="${GPUC_RUNTIME:-2}"
REPEATS="${GPUC_REPEATS:-5}"
BS_LIST="${GPUC_BS_LIST:-4k 16k 128k}"
CONCURRENCY_LIST="${GPUC_CONCURRENCY_LIST:-1 4}"
QD_LIST="${GPUC_QD_LIST:-1 8 32}"
PHYSICAL_GPU="${GPUC_PHYSICAL_GPU:-0}"
SAMPLE_TIMEOUT="${GPUC_SAMPLE_TIMEOUT:-$((RUNTIME + 30))}"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
trap 'rm -rf -- "$TEST_DIR"' EXIT

[[ "$PHYSICAL_GPU" =~ ^[0-9]+$ ]] || {
    echo "ERROR: GPUC_PHYSICAL_GPU must be a non-negative integer." >&2
    exit 2
}

mkdir -p "$RESULT_DIR/json" "$TEST_DIR/raw" "$TEST_DIR/sglz" "$TEST_DIR/lz4"
make -C "$PROJECT_DIR" bin/libgpuhook.so bin/gpu_compress_daemon >/dev/null

BASE="$TEST_DIR/baseline.bin"
RAW="$TEST_DIR/raw/data.bin"
SGLZ="$TEST_DIR/sglz/data.bin"
LZ4="$TEST_DIR/lz4/data.bin"

fio --name=prepare_base --filename="$BASE" --size="$SIZE" --bs=1M \
    --rw=write --buffer_pattern=0x01 --direct=0 --ioengine=sync >/dev/null
for path in "$RAW" "$SGLZ" "$LZ4"; do
    LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
        fio --name=prepare_gpuc --filename="$path" --size="$SIZE" --bs=1M \
            --rw=write --buffer_pattern=0x01 --direct=0 --ioengine=sync >/dev/null
done
"$DAEMON" "$TEST_DIR/sglz" >/dev/null
GPUC_ALGO=lz4 "$DAEMON" "$TEST_DIR/lz4" >/dev/null

BASE_SHA="$(sha256sum "$BASE" | awk '{print $1}')"
RAW_SHA="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    dd if="$RAW" bs=1M status=none | sha256sum | awk '{print $1}')"
SGLZ_SHA="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    dd if="$SGLZ" bs=1M status=none | sha256sum | awk '{print $1}')"
LZ4_SHA="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    dd if="$LZ4" bs=1M status=none | sha256sum | awk '{print $1}')"
[ "$BASE_SHA" = "$RAW_SHA" ] && [ "$BASE_SHA" = "$SGLZ_SHA" ] &&
    [ "$BASE_SHA" = "$LZ4_SHA" ]
{
    echo "baseline,$BASE_SHA"
    echo "hook_raw,$RAW_SHA"
    echo "sglz,$SGLZ_SHA"
    echo "lz4,$LZ4_SHA"
} > "$RESULT_DIR/logical_sha256.csv"

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
fio=$(fio --version)
gpu=$(nvidia-smi -i "$PHYSICAL_GPU" \
  --query-gpu=index,name,uuid,driver_version,compute_cap,memory.total \
  --format=csv,noheader | head -1)
cpu=$(lscpu | awk -F: '/Model name/{gsub(/^[ \t]+/,"",$2); print $2; exit}')
test_root=$TEST_ROOT
filesystem=$(findmnt -no FSTYPE -T "$TEST_DIR")
source=$(findmnt -no SOURCE -T "$TEST_DIR")
size=$SIZE
runtime_s=$RUNTIME
repeats=$REPEATS
block_sizes=$BS_LIST
application_concurrency=$CONCURRENCY_LIST
compressed_read_concurrency=$CONCURRENCY_LIST
sample_timeout_s=$SAMPLE_TIMEOUT
baseline_libaio_queue_depths=$QD_LIST
read_cache_mode=warm buffered I/O (direct=0), pre-read before each timed run
intercepted_ioengine=sync, iodepth=1; numjobs is application concurrency
write_scope=Baseline and Hook RAW; COMPRESSED is intentionally read-only
data=constant nonzero byte 0x01
EOF

printf '%s\n' \
    "phase,scenario,rw,op,bs,concurrency,ioengine,iodepth,repeat,bw_mib_s,iops,clat_mean_us,p50_us,p95_us,p99_us,p999_us,errors" \
    > "$RESULT_DIR/runs.csv"

record_json() {
    local json=$1 phase=$2 scenario=$3 rw=$4 bs=$5 concurrency=$6
    local ioengine=$7 iodepth=$8 repeat=$9
    python3 - "$json" "$RESULT_DIR/runs.csv" "$phase" "$scenario" "$rw" \
        "$bs" "$concurrency" "$ioengine" "$iodepth" "$repeat" <<'PY'
import csv,json,sys
path,out,phase,scenario,rw,bs,conc,engine,depth,repeat=sys.argv[1:]
d=json.load(open(path))
job=d["jobs"][0]
with open(out,"a",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    for op in ("read","write"):
        x=job.get(op,{})
        if float(x.get("io_bytes",0)) <= 0:
            continue
        lat=x.get("clat_ns") or x.get("lat_ns") or {}
        pct=lat.get("percentile",{})
        def p(name):
            value=pct.get(name)
            return float(value)/1000.0 if value is not None else 0.0
        w.writerow([
            phase,scenario,rw,op,bs,conc,engine,depth,repeat,
            f"{float(x.get('bw',0))/1024.0:.6f}",
            f"{float(x.get('iops',0)):.6f}",
            f"{float(lat.get('mean',0))/1000.0:.6f}",
            f"{p('50.000000'):.6f}",f"{p('95.000000'):.6f}",
            f"{p('99.000000'):.6f}",f"{p('99.900000'):.6f}",
            int(job.get("error",0)),
        ])
PY
}

run_read() {
    local scenario=$1 path=$2 preload=$3 rw=$4 bs=$5 conc=$6 repeat=$7
    local tag="read_${scenario}_${rw}_${bs}_c${conc}_r${repeat}"
    local json="$RESULT_DIR/json/$tag.json"
    if [ -n "$preload" ]; then
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            dd if="$path" of=/dev/null bs=1M status=none
        timeout --signal=TERM --kill-after=10 "$SAMPLE_TIMEOUT" \
            env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            fio --name="$tag" --filename="$path" --size="$SIZE" --bs="$bs" \
                --rw="$rw" --direct=0 --ioengine=sync --iodepth=1 \
                --thread=1 --numjobs="$conc" --runtime="$RUNTIME" --time_based \
                --group_reporting --randrepeat=1 --norandommap=1 \
                --percentile_list=50:95:99:99.9 --output-format=json > "$json"
    else
        dd if="$path" of=/dev/null bs=1M status=none
        timeout --signal=TERM --kill-after=10 "$SAMPLE_TIMEOUT" \
            fio --name="$tag" --filename="$path" --size="$SIZE" --bs="$bs" \
                --rw="$rw" --direct=0 --ioengine=sync --iodepth=1 \
                --thread=1 --numjobs="$conc" --runtime="$RUNTIME" --time_based \
                --group_reporting --randrepeat=1 --norandommap=1 \
                --percentile_list=50:95:99:99.9 --output-format=json > "$json"
    fi
    record_json "$json" read "$scenario" "$rw" "$bs" "$conc" sync 1 "$repeat"
}

run_write() {
    local scenario=$1 preload=$2 rw=$3 bs=$4 conc=$5 repeat=$6
    local tag="write_${scenario}_${rw}_${bs}_c${conc}_r${repeat}"
    local path="$TEST_DIR/${tag}.bin"
    local json="$RESULT_DIR/json/$tag.json"
    local mix=()
    [ "$rw" = randrw ] && mix=(--rwmixread=70)
    if [ -n "$preload" ]; then
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            fio --name="$tag" --filename="$path" --size="$SIZE" --bs="$bs" \
                --rw="$rw" "${mix[@]}" --direct=0 --ioengine=sync --iodepth=1 \
                --thread=1 --numjobs="$conc" --runtime="$RUNTIME" --time_based \
                --group_reporting --randrepeat=1 --norandommap=1 --unlink=1 \
                --percentile_list=50:95:99:99.9 --output-format=json > "$json"
    else
        fio --name="$tag" --filename="$path" --size="$SIZE" --bs="$bs" \
            --rw="$rw" "${mix[@]}" --direct=0 --ioengine=sync --iodepth=1 \
            --thread=1 --numjobs="$conc" --runtime="$RUNTIME" --time_based \
            --group_reporting --randrepeat=1 --norandommap=1 --unlink=1 \
            --percentile_list=50:95:99:99.9 --output-format=json > "$json"
    fi
    record_json "$json" write "$scenario" "$rw" "$bs" "$conc" sync 1 "$repeat"
}

run_qd_baseline() {
    local rw=$1 bs=$2 qd=$3 repeat=$4
    local tag="qd_baseline_${rw}_${bs}_q${qd}_r${repeat}"
    local json="$RESULT_DIR/json/$tag.json"
    fio --name="$tag" --filename="$BASE" --size="$SIZE" --bs="$bs" \
        --rw="$rw" --direct=1 --ioengine=libaio --iodepth="$qd" --numjobs=1 \
        --runtime="$RUNTIME" --time_based --group_reporting --randrepeat=1 \
        --norandommap=1 --percentile_list=50:95:99:99.9 \
        --output-format=json > "$json"
    record_json "$json" baseline_qd baseline "$rw" "$bs" 1 libaio "$qd" "$repeat"
}

for repeat in $(seq 1 "$REPEATS"); do
    for bs in $BS_LIST; do
        for rw in read randread; do
            for conc in $CONCURRENCY_LIST; do
                run_read baseline "$BASE" "" "$rw" "$bs" "$conc" "$repeat"
                run_read hook_raw "$RAW" yes "$rw" "$bs" "$conc" "$repeat"
                run_read sglz "$SGLZ" yes "$rw" "$bs" "$conc" "$repeat"
                run_read lz4 "$LZ4" yes "$rw" "$bs" "$conc" "$repeat"
            done
        done
        for rw in write randwrite randrw; do
            for conc in 1 4; do
                run_write baseline "" "$rw" "$bs" "$conc" "$repeat"
                run_write hook_raw yes "$rw" "$bs" "$conc" "$repeat"
            done
        done
        for qd in $QD_LIST; do
            run_qd_baseline randread "$bs" "$qd" "$repeat"
        done
    done
done

python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1])))
keys=["phase","scenario","rw","op","bs","concurrency","ioengine","iodepth"]
metrics=["bw_mib_s","iops","clat_mean_us","p95_us","p99_us","p999_us"]
groups={}
for row in rows:
    groups.setdefault(tuple(row[k] for k in keys),[]).append(row)
fields=keys+["n"]
for metric in metrics:
    fields += [metric+"_mean",metric+"_ci95"]
with open(sys.argv[2],"w",newline="") as f:
    w=csv.DictWriter(f,fieldnames=fields,lineterminator="\n"); w.writeheader()
    for key,items in sorted(groups.items()):
        out=dict(zip(keys,key)); out["n"]=len(items)
        for metric in metrics:
            vals=[float(x[metric]) for x in items]
            mean=statistics.mean(vals)
            ci=1.96*statistics.stdev(vals)/math.sqrt(len(vals)) if len(vals)>1 else 0
            out[metric+"_mean"]=f"{mean:.6f}"
            out[metric+"_ci95"]=f"{ci:.6f}"
        w.writerow(out)
PY

echo "[OK] $RESULT_DIR"
