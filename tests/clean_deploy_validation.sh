#!/usr/bin/env bash
set -euo pipefail

# Path-independence/deployment validation in a fresh temporary directory.
# Bundled third-party dependencies are copied exactly as a repository checkout
# would contain them; build outputs and prior results are deliberately excluded.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/clean_deploy_${RUN_ID}}"
TEMP_ROOT="$(mktemp -d "$PROJECT_DIR/.clean-deploy-XXXXXX")"
COPY_DIR="$TEMP_ROOT/repository"
VALIDATE_GPU="${GPUC_VALIDATE_GPU:-auto}"
trap 'rm -rf "$TEMP_ROOT"' EXIT
mkdir -p "$RESULT_DIR"

start_epoch="$(date +%s)"
rsync -a --link-dest="$PROJECT_DIR" \
    --exclude=.git --exclude=bin --exclude=results/local --exclude=slides \
    --exclude=node_modules --exclude=third_party/manual --exclude='.clean-deploy-*' \
    "$PROJECT_DIR/" "$COPY_DIR/"
copy_epoch="$(date +%s)"

{
    echo "run_id=$RUN_ID"
    echo "source_git_commit=$(git -C "$PROJECT_DIR" rev-parse HEAD 2>/dev/null || echo unknown)"
    echo "source_git_dirty=$(git -C "$PROJECT_DIR" status --porcelain | wc -l)"
    echo "kernel=$(uname -srvmo)"
    echo "cpu=$(lscpu | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "fresh_path=$COPY_DIR"
    echo "excluded=.git,bin,results/local,slides,node_modules,third_party/manual"
    echo "dependency_model=bundled repository third_party exposed through read-only-equivalent hardlinks; build outputs are fresh"
    echo "copy_seconds=$((copy_epoch-start_epoch))"
} > "$RESULT_DIR/environment.txt"

run_logged() {
    local name=$1
    shift
    local begin end
    begin="$(date +%s)"
    if "$@" > "$RESULT_DIR/${name}.stdout" 2> "$RESULT_DIR/${name}.stderr"; then
        end="$(date +%s)"
        echo "$name,PASS,$((end-begin))" >> "$RESULT_DIR/runs.csv"
    else
        local rc=$?
        end="$(date +%s)"
        echo "$name,FAIL,$((end-begin))" >> "$RESULT_DIR/runs.csv"
        echo "ERROR: clean deployment step failed: $name (rc=$rc)" >&2
        sed -n '1,120p' "$RESULT_DIR/${name}.stderr" >&2
        exit "$rc"
    fi
}

echo "step,status,elapsed_s" > "$RESULT_DIR/runs.csv"
run_logged check_env make -C "$COPY_DIR" check-env
run_logged cpu_smoke make -C "$COPY_DIR" smoke-test
run_logged docs_check make -C "$COPY_DIR" docs-check

if [[ "$VALIDATE_GPU" == auto ]]; then
    if nvidia-smi -L >/dev/null 2>&1; then VALIDATE_GPU=1; else VALIDATE_GPU=0; fi
fi
if [[ "$VALIDATE_GPU" == 1 ]]; then
    run_logged gpu_build make -C "$COPY_DIR" all
    run_logged gpu_test make -C "$COPY_DIR" test
else
    echo "gpu_build,SKIP_NO_VISIBLE_GPU,0" >> "$RESULT_DIR/runs.csv"
    echo "gpu_test,SKIP_NO_VISIBLE_GPU,0" >> "$RESULT_DIR/runs.csv"
fi

end_epoch="$(date +%s)"
{
    echo "total_seconds=$((end_epoch-start_epoch))"
    echo "gpu_validation=$VALIDATE_GPU"
    echo "result=PASS"
} >> "$RESULT_DIR/environment.txt"
echo "[OK] Clean deployment validation complete: $RESULT_DIR"
