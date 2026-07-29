#!/usr/bin/env bash
set -euo pipefail

# Public, independently verifiable real-text dataset benchmark.
# Dataset: Project Gutenberg ebook #2600, War and Peace, UTF-8 plain text.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/public_dataset_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-public-dataset-XXXXXX)"
REPEATS="${GPUC_REPEATS:-5}"
RUNTIME="${GPUC_RUNTIME:-2}"
BS="${GPUC_BS:-128k}"
URL="https://www.gutenberg.org/ebooks/2600.txt.utf-8"
CATALOG_URL="https://www.gutenberg.org/ebooks/2600"
LICENSE_URL="https://www.gutenberg.org/policy/license"
EXPECTED_SHA256="2d5bb2ad5f422765e714617e21fa31bbaf8958aa79682c86fca6660fcc5d1b2b"
HOOK="$PROJECT_DIR/bin/libgpuhook.so"
DAEMON="$PROJECT_DIR/bin/gpu_compress_daemon"
COLD_READER="$PROJECT_DIR/bin/test_cold_read"
trap 'rm -rf -- "$TEST_DIR"' EXIT

mkdir -p "$RESULT_DIR/json" "$TEST_DIR/plain" "$TEST_DIR/raw"
make -C "$PROJECT_DIR" bin/libgpuhook.so bin/gpu_compress_daemon \
    bin/test_cold_read >/dev/null

SOURCE="${GPUC_DATASET_FILE:-$TEST_DIR/pg2600.txt}"
if [[ -z "${GPUC_DATASET_FILE:-}" ]]; then
    curl --http1.1 -L --fail --retry 3 --retry-delay 2 \
        -o "$SOURCE" "$URL"
fi
actual_sha="$(sha256sum "$SOURCE" | awk '{print $1}')"
if [[ "$actual_sha" != "$EXPECTED_SHA256" ]]; then
    echo "Dataset SHA-256 mismatch: $actual_sha" >&2
    exit 1
fi
logical_bytes="$(stat -c %s "$SOURCE")"
cp "$SOURCE" "$TEST_DIR/plain/data.txt"
LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
    cp "$SOURCE" "$TEST_DIR/raw/data.txt"

cat > "$RESULT_DIR/dataset_metadata.txt" <<EOF
dataset=Project Gutenberg ebook #2600, War and Peace
artifact=UTF-8 plain text
download_url=$URL
catalog_url=$CATALOG_URL
license_url=$LICENSE_URL
catalog_last_updated=2022-06-14
catalog_rights=Public domain in the USA
logical_bytes=$logical_bytes
sha256=$EXPECTED_SHA256
verification=exact SHA-256 required before every run
EOF

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)
fio=$(fio --version)
runtime_s=$RUNTIME
repeats=$REPEATS
bs=$BS
cold_definition=POSIX_FADV_DONTNEED on the file before one complete logical read
warm_definition=complete logical pre-read before fio time-based read
EOF

echo "algorithm,repeat,compress_seconds,state,logical_bytes,format_bytes,allocated_bytes,allocated_ratio,logical_sha256" \
    > "$RESULT_DIR/compression_runs.csv"

metadata() {
    python3 - "$1" <<'PY'
import struct,sys
h=open(sys.argv[1],"rb").read(56)
if len(h) != 56 or struct.unpack_from("<I",h,0)[0] != 0x47505543:
    print("INVALID")
else:
    print({0:"RAW",1:"COMPRESSED",2:"BUSY",3:"INLINE"}.get(h[24],"INVALID"))
PY
}

for algorithm in sglz lz4; do
    for repeat in $(seq 1 "$REPEATS"); do
        dir="$TEST_DIR/${algorithm}_r${repeat}"
        mkdir -p "$dir"
        file="$dir/data.txt"
        LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 cp "$SOURCE" "$file"
        begin="$(date +%s.%N)"
        if [[ "$algorithm" == lz4 ]]; then
            GPUC_ALGO=lz4 "$DAEMON" "$dir" >/dev/null
        else
            "$DAEMON" "$dir" >/dev/null
        fi
        end="$(date +%s.%N)"
        state="$(metadata "$file")"
        [[ "$state" == COMPRESSED || "$state" == RAW ]]
        logical_sha="$(LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
            dd if="$file" bs=1M status=none | sha256sum | awk '{print $1}')"
        [[ "$logical_sha" == "$EXPECTED_SHA256" ]]
        format_bytes="$(stat -c %s "$file")"
        allocated_bytes="$(du -B1 "$file" | awk '{print $1}')"
        python3 - "$RESULT_DIR/compression_runs.csv" "$algorithm" "$repeat" \
            "$begin" "$end" "$state" "$logical_bytes" "$format_bytes" \
            "$allocated_bytes" "$logical_sha" <<'PY'
import csv,sys
out,algo,repeat,begin,end,state,logical,fmt,alloc,sha=sys.argv[1:]
logical_i=int(logical); alloc_i=int(alloc)
with open(out,"a",newline="") as f:
    csv.writer(f,lineterminator="\n").writerow([
        algo,repeat,f"{float(end)-float(begin):.9f}",state,
        logical,fmt,alloc,f"{alloc_i/logical_i:.9f}",sha])
PY
    done
done

echo "cache,scenario,repeat,bw_mib_s,iops,mean_lat_us,p95_us,p99_us,p999_us,error" \
    > "$RESULT_DIR/read_runs.csv"

declare -A paths=(
    [baseline]="$TEST_DIR/plain/data.txt"
    [hook_raw]="$TEST_DIR/raw/data.txt"
    [sglz]="$TEST_DIR/sglz_r1/data.txt"
    [lz4]="$TEST_DIR/lz4_r1/data.txt"
)

for repeat in $(seq 1 "$REPEATS"); do
    for scenario in baseline hook_raw sglz lz4; do
        path="${paths[$scenario]}"
        cold_out="$RESULT_DIR/cold_${scenario}_r${repeat}.txt"
        if [[ "$scenario" == baseline ]]; then
            "$COLD_READER" "$path" "$logical_bytes" > "$cold_out"
        else
            LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
                "$COLD_READER" "$path" "$logical_bytes" > "$cold_out"
        fi
        python3 - "$cold_out" "$RESULT_DIR/read_runs.csv" "$scenario" "$repeat" <<'PY'
import csv,sys
elapsed,bw,total,checksum=open(sys.argv[1]).read().strip().split(",")
with open(sys.argv[2],"a",newline="") as f:
    csv.writer(f,lineterminator="\n").writerow(
        ["cold",sys.argv[3],sys.argv[4],bw,0,0,0,0,0,0])
PY

        if [[ "$scenario" == baseline ]]; then
            dd if="$path" of=/dev/null bs=1M status=none
        else
            LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1 \
                dd if="$path" of=/dev/null bs=1M status=none
        fi
        json="$RESULT_DIR/json/warm_${scenario}_r${repeat}.json"
        env_args=()
        [[ "$scenario" != baseline ]] &&
            env_args=(env LD_PRELOAD="$HOOK" GPUCOMPRESS_QUIET=1)
        "${env_args[@]}" fio --name="warm_${scenario}" --filename="$path" \
            --size="$logical_bytes" --bs="$BS" --rw=read --runtime="$RUNTIME" \
            --time_based --direct=0 --invalidate=0 --ioengine=sync --numjobs=1 \
            --group_reporting --readonly --percentile_list=95:99:99.9 \
            --output-format=json > "$json"
        python3 - "$json" "$RESULT_DIR/read_runs.csv" "$scenario" "$repeat" <<'PY'
import csv,json,sys
j=json.load(open(sys.argv[1])); job=j["jobs"][0]; r=job["read"]
lat=r.get("clat_ns") or r.get("lat_ns") or {}; pct=lat.get("percentile",{})
def us(name): return float(pct.get(name,0))/1000
with open(sys.argv[2],"a",newline="") as f:
    csv.writer(f,lineterminator="\n").writerow([
        "warm",sys.argv[3],sys.argv[4],r["bw"]/1024,r["iops"],
        float(lat.get("mean",0))/1000,us("95.000000"),us("99.000000"),
        us("99.900000"),job.get("error",0)])
if job.get("error",0): raise SystemExit(1)
PY
    done
done

python3 - "$RESULT_DIR/compression_runs.csv" "$RESULT_DIR/read_runs.csv" \
    "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
comp=list(csv.DictReader(open(sys.argv[1])))
reads=list(csv.DictReader(open(sys.argv[2])))
with open(sys.argv[3],"w",newline="") as f:
    w=csv.writer(f,lineterminator="\n")
    w.writerow(["metric","cache","scenario","n","mean","ci95"])
    for algo in ("sglz","lz4"):
        rows=[r for r in comp if r["algorithm"]==algo]
        for metric in ("compress_seconds","allocated_ratio"):
            vals=[float(r[metric]) for r in rows]
            ci=1.96*statistics.stdev(vals)/math.sqrt(len(vals)) if len(vals)>1 else 0
            w.writerow([metric,"",algo,len(vals),statistics.mean(vals),ci])
    for cache in ("cold","warm"):
        for scenario in ("baseline","hook_raw","sglz","lz4"):
            vals=[float(r["bw_mib_s"]) for r in reads
                  if r["cache"]==cache and r["scenario"]==scenario]
            ci=1.96*statistics.stdev(vals)/math.sqrt(len(vals)) if len(vals)>1 else 0
            w.writerow(["bw_mib_s",cache,scenario,len(vals),statistics.mean(vals),ci])
PY

echo "[OK] $RESULT_DIR"
