#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/cold_cache_${RUN_ID}}"
TEST_DIR="$(mktemp -d /tmp/gpuc-cold-XXXXXX)"
SIZE="${GPUC_SIZE:-512M}"
REPEATS="${GPUC_REPEATS:-5}"
mkdir -p "$RESULT_DIR" "$TEST_DIR/plain" "$TEST_DIR/raw" "$TEST_DIR/compressed"
trap 'rm -rf -- "$TEST_DIR"' EXIT

make -C "$PROJECT_DIR" bin/test_cold_read >/dev/null
bytes="$(numfmt --from=iec "$SIZE")"
plain="$TEST_DIR/plain/data.bin"; raw="$TEST_DIR/raw/data.bin"; comp="$TEST_DIR/compressed/data.bin"
python3 - "$plain" "$bytes" <<'PY'
import sys
path,n=sys.argv[1],int(sys.argv[2])
with open(path,"wb",buffering=1<<20) as f:
    for p in range(n//4096): f.write(bytes([1+(p*37)%251])*4096)
PY
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 cp "$plain" "$raw"
LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 cp "$plain" "$comp"
"$PROJECT_DIR/bin/gpu_compress_daemon" "$TEST_DIR/compressed" >/dev/null
sha="$(sha256sum "$plain" | awk '{print $1}')"
[[ "$(LD_PRELOAD="$PROJECT_DIR/bin/libgpuhook.so" GPUCOMPRESS_QUIET=1 dd if="$comp" bs=1M status=none | sha256sum | awk '{print $1}')" == "$sha" ]]

cat > "$RESULT_DIR/environment.txt" <<EOF
run_id=$RUN_ID
git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)
kernel=$(uname -srvmo)
gpu=$(nvidia-smi --query-gpu=name,driver_version,compute_cap --format=csv,noheader | head -1)
size=$SIZE
repeats=$REPEATS
cache_mode=single logical pass after POSIX_FADV_DONTNEED on the underlying inode
direct=0
sha256=$sha
EOF
echo "scenario,repeat,elapsed_sec,mib_s,logical_bytes,checksum,state,sha256" > "$RESULT_DIR/runs.csv"

scenarios=(baseline hook_raw gpu_compressed)
for repeat in $(seq 1 "$REPEATS"); do
    shift=$(( (repeat-1)%3 ))
    for idx in 0 1 2; do
        scenario="${scenarios[$(((idx+shift)%3))]}"
        case "$scenario" in
            baseline) file="$plain"; preload=""; state=PLAIN ;;
            hook_raw) file="$raw"; preload="$PROJECT_DIR/bin/libgpuhook.so"; state=RAW ;;
            gpu_compressed) file="$comp"; preload="$PROJECT_DIR/bin/libgpuhook.so"; state=COMPRESSED ;;
        esac
        if [[ -n "$preload" ]]; then
            line="$(LD_PRELOAD="$preload" GPUCOMPRESS_QUIET=1 "$PROJECT_DIR/bin/test_cold_read" "$file" "$bytes")"
        else
            line="$("$PROJECT_DIR/bin/test_cold_read" "$file" "$bytes")"
        fi
        echo "$scenario,$repeat,$line,$state,$sha" >> "$RESULT_DIR/runs.csv"
        echo "$scenario repeat=$repeat $line"
    done
done
python3 - "$RESULT_DIR/runs.csv" "$RESULT_DIR/summary.csv" <<'PY'
import csv,math,statistics,sys
rows=list(csv.DictReader(open(sys.argv[1]))); groups={}
for r in rows: groups.setdefault(r["scenario"],[]).append(float(r["mib_s"]))
with open(sys.argv[2],"w",newline="") as f:
    w=csv.writer(f); w.writerow(["scenario","n","mean_mib_s","stddev_mib_s","ci95_mib_s"])
    for s,v in groups.items():
        mean=statistics.mean(v); std=statistics.stdev(v) if len(v)>1 else 0
        ci=1.96*std/math.sqrt(len(v)) if len(v)>1 else 0
        w.writerow([s,len(v),f"{mean:.3f}",f"{std:.3f}",f"{ci:.3f}"])
        print(f"{s:15s} mean={mean:9.1f} MiB/s 95%CI=±{ci:6.1f}")
PY
echo "[OK] $RESULT_DIR"
