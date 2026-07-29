#!/usr/bin/env bash
set -euo pipefail

# Compressibility gradient with deterministic independent files, repeated
# compression/read measurements, checksums, state and storage accounting.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/compressibility_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-gradient-XXXXXX)"
SIZE="${GPUC_SIZE:-256M}"
RUNTIME="${GPUC_RUNTIME:-10}"
REPEATS="${GPUC_REPEATS:-5}"
BS="${GPUC_BS:-128k}"
DIRECT="${GPUC_DIRECT:-0}"
RATIO_LIST="${GPUC_RATIO_LIST:-0 25 50 75 100}"

mkdir -p "$RESULT_DIR"
[[ "$DIRECT" == 0 ]] || { echo "[ERROR] GPUC compact format does not support true O_DIRECT; use GPUC_DIRECT=0" >&2; exit 2; }
trap 'rm -rf -- "$TEST_DIR"' EXIT

state_of() {
    python3 - "$1" <<'PY'
import sys
with open(sys.argv[1],"rb") as f: h=f.read(25)
if len(h)<25 or h[:4]!=b"CUPG": print("PLAIN")
elif h[24]==0: print("RAW")
elif h[24]==1: print("COMPRESSED")
elif h[24]==3: print("INLINE")
else: print(f"STATE_{h[24]}")
PY
}

logical_sha() {
    local preload="$1" file="$2"
    if [[ -n "$preload" ]]; then
        LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 \
            dd if="$file" bs=1M status=none | sha256sum | awk '{print $1}'
    else
        sha256sum "$file" | awk '{print $1}'
    fi
}

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
fio=$(fio --version)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)
size=$SIZE
runtime=$RUNTIME
repeats=$REPEATS
bs=$BS
direct=$DIRECT
ratio_list=$RATIO_LIST
generator=percentage of deterministic 4KiB pages that contain a repeated nonzero byte; remaining pages use seeded pseudorandom bytes
EOF
echo "compressibility_pct,repeat,compress_sec,state,format_bytes,allocated_bytes,logical_sha256" > "$RESULT_DIR/compression_runs.csv"
echo "compressibility_pct,scenario,repeat,bw_mib_s,iops,mean_lat_us,error,state,logical_sha256,format_bytes,allocated_bytes" > "$RESULT_DIR/read_runs.csv"

for ratio in $RATIO_LIST; do
    ratio_dir="$TEST_DIR/r${ratio}"
    mkdir -p "$ratio_dir"
    input="$ratio_dir/input.bin"
    baseline="$ratio_dir/baseline.bin"
    gpuc="$ratio_dir/gpuc.bin"

    echo "[SETUP] ratio=$ratio generating $SIZE..."
    python3 - "$input" "$SIZE" "$ratio" <<'PY'
import random,sys
path,size,ratio=sys.argv[1],sys.argv[2].upper(),int(sys.argv[3])
mul={"K":1<<10,"M":1<<20,"G":1<<30}; n=int(size[:-1])*mul[size[-1]]
rng=random.Random(0x47505543 + ratio)
with open(path,"wb",buffering=1<<20) as f:
    for p in range(n//4096):
        if p%100 < ratio:
            f.write(bytes([1+(p*37)%251])*4096)
        else:
            # Python 3.8 compatibility: Random.randbytes() was added in 3.9.
            f.write(rng.getrandbits(4096 * 8).to_bytes(4096, "little"))
PY
    cp "$input" "$baseline"
    sha="$(sha256sum "$input" | awk '{print $1}')"

    for repeat in $(seq 1 "$REPEATS"); do
        rm -f "$gpuc"
        LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 \
            dd if="$input" of="$gpuc" bs=1M status=none
        t0="$(date +%s%N)"
        "$PROJECT_DIR/bin/gpu_compress_daemon" "$ratio_dir" >/dev/null
        t1="$(date +%s%N)"
        sec="$(python3 -c "print(($t1-$t0)/1e9)")"
        state="$(state_of "$gpuc")"
        got_sha="$(logical_sha "$PROJECT_DIR/bin/libgpuhook.so" "$gpuc")"
        [[ "$got_sha" == "$sha" ]]
        format_bytes="$(stat -c %s "$gpuc")"
        allocated_bytes="$(du -B1 "$gpuc" | awk '{print $1}')"
        printf '%s,%s,%.6f,%s,%s,%s,%s\n' \
            "$ratio" "$repeat" "$sec" "$state" "$format_bytes" "$allocated_bytes" "$sha" \
            >> "$RESULT_DIR/compression_runs.csv"
        echo "  compress ratio=$ratio repeat=$repeat time=${sec}s state=$state bytes=$format_bytes"
    done

    # The last compressed artifact is used for all read repetitions.
    [[ "$(logical_sha "$PROJECT_DIR/bin/libgpuhook.so" "$gpuc")" == "$sha" ]]
    for repeat in $(seq 1 "$REPEATS"); do
        if (( repeat % 2 == 1 )); then order="baseline gpuc"; else order="gpuc baseline"; fi
        for scenario in $order; do
            if [[ "$scenario" == baseline ]]; then
                file="$baseline"; preload=""; state="PLAIN"
            else
                file="$gpuc"; preload="$PROJECT_DIR/bin/libgpuhook.so"; state="$(state_of "$gpuc")"
            fi
            json="$RESULT_DIR/r${ratio}_${scenario}_r${repeat}.json"
            if [[ -n "$preload" ]]; then
                LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 \
                    fio --name="${scenario}_r${ratio}" --filename="$file" --size="$SIZE" \
                        --bs="$BS" --rw=read --runtime="$RUNTIME" --time_based \
                        --direct="$DIRECT" --invalidate=0 --ioengine=sync --numjobs=1 \
                        --group_reporting --output-format=json > "$json" 2>/dev/null
            else
                fio --name="${scenario}_r${ratio}" --filename="$file" --size="$SIZE" \
                    --bs="$BS" --rw=read --runtime="$RUNTIME" --time_based \
                    --direct="$DIRECT" --invalidate=0 --ioengine=sync --numjobs=1 \
                    --group_reporting --output-format=json > "$json" 2>/dev/null
            fi
            format_bytes="$(stat -c %s "$file")"
            allocated_bytes="$(du -B1 "$file" | awk '{print $1}')"
            python3 - "$json" "$RESULT_DIR/read_runs.csv" "$ratio" "$scenario" "$repeat" "$state" "$sha" "$format_bytes" "$allocated_bytes" <<'PY'
import csv,json,sys
jpath,csvpath,ratio,scenario,repeat,state,sha,fmt,alloc=sys.argv[1:]
d=json.load(open(jpath)); r=d["jobs"][0]["read"]; lat=r.get("lat_ns",{}).get("mean",0)/1000
with open(csvpath,"a",newline="") as f:
    csv.writer(f).writerow([ratio,scenario,repeat,r["bw"]/1024,r["iops"],lat,d["jobs"][0]["error"],state,sha,fmt,alloc])
print(f"  read ratio={ratio:>3s} {scenario:8s} repeat={repeat} bw={r['bw']/1024:9.1f} MiB/s state={state}")
PY
        done
    done
done

python3 - "$RESULT_DIR/read_runs.csv" "$RESULT_DIR/compression_runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
reads=list(csv.DictReader(open(sys.argv[1]))); comps=list(csv.DictReader(open(sys.argv[2])))
groups={}
for r in reads: groups.setdefault((int(r["compressibility_pct"]),r["scenario"],r["state"]),[]).append(float(r["bw_mib_s"]))
comp_groups={}
for r in comps: comp_groups.setdefault(int(r["compressibility_pct"]),[]).append(float(r["compress_sec"]))
with open(sys.argv[3],"w",newline="") as f:
    w=csv.writer(f); w.writerow(["compressibility_pct","scenario","state","n","mean_mib_s","stddev_mib_s","ci95_mib_s","mean_compress_sec"])
    for key,vals in sorted(groups.items()):
        mean=statistics.mean(vals); std=statistics.stdev(vals) if len(vals)>1 else 0
        ci=1.96*std/math.sqrt(len(vals)) if len(vals)>1 else 0
        cmean=statistics.mean(comp_groups[key[0]]) if key[1]=="gpuc" else ""
        w.writerow([*key,len(vals),f"{mean:.3f}",f"{std:.3f}",f"{ci:.3f}",f"{cmean:.6f}" if cmean!="" else ""])
        print(f"ratio={key[0]:3d}% {key[1]:8s} state={key[2]:10s} mean={mean:9.1f} 95%CI=±{ci:6.1f}")
PY
echo "[OK] $RESULT_DIR"
