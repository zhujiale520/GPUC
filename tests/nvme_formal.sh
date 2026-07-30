#!/usr/bin/env bash
set -euo pipefail

# Safe wrapper: it never partitions, formats, or mounts a device. The caller
# must provide an already-mounted, disposable benchmark directory on NVMe.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NVME_DIR="${GPUC_NVME_DIR:-}"
[[ -n "$NVME_DIR" ]] || {
    echo "ERROR: set GPUC_NVME_DIR to an existing disposable directory on a mounted NVMe filesystem." >&2
    exit 2
}
[[ -d "$NVME_DIR" && -w "$NVME_DIR" ]] || {
    echo "ERROR: not an existing writable directory: $NVME_DIR" >&2
    exit 2
}
SOURCE="$(findmnt -no SOURCE -T "$NVME_DIR")"
FSTYPE="$(findmnt -no FSTYPE -T "$NVME_DIR")"
PKNAME="$(lsblk -no PKNAME "$SOURCE" 2>/dev/null | head -1 || true)"
DEVICE="$(basename "$SOURCE")"
if [[ "$DEVICE" != nvme* && "$PKNAME" != nvme* ]]; then
    echo "ERROR: $NVME_DIR is on $SOURCE ($FSTYPE), not a verified NVMe block device." >&2
    exit 2
fi
AVAILABLE_KIB="$(df -Pk "$NVME_DIR" | awk 'NR==2 {print $4}')"
MIN_KIB="${GPUC_NVME_MIN_FREE_KIB:-2097152}"
if (( AVAILABLE_KIB < MIN_KIB )); then
    echo "ERROR: need at least $MIN_KIB KiB free in $NVME_DIR; have $AVAILABLE_KIB KiB." >&2
    exit 2
fi

RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/nvme_$(date -u +%Y%m%dT%H%M%SZ)}"
mkdir -p "$RESULT_DIR"
{
    echo "verified_nvme_dir=$(realpath "$NVME_DIR")"
    echo "source=$SOURCE"
    echo "parent=$PKNAME"
    echo "filesystem=$FSTYPE"
    echo "available_kib=$AVAILABLE_KIB"
    echo "destructive_scope=temporary files below GPUC_NVME_DIR only"
} > "$RESULT_DIR/nvme_preflight.txt"

GPUC_TEST_ROOT="$NVME_DIR" GPUC_RESULT_DIR="$RESULT_DIR/io_matrix" \
    bash "$PROJECT_DIR/tests/io_workload_matrix.sh"
echo "[OK] formal NVMe experiment complete: $RESULT_DIR"
