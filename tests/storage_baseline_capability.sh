#!/usr/bin/env bash
set -euo pipefail

# Read-only preflight for filesystem/block-layer baselines. It never formats or
# mounts a device; the result explains exactly which external prerequisite is
# missing before btrfs_compare.sh or a ZFS/DM experiment is attempted.

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)"
RESULT_DIR="${GPUC_RESULT_DIR:-$PROJECT_DIR/results/local/storage_capability_${RUN_ID}}"
mkdir -p "$RESULT_DIR"

available() { command -v "$1" 2>/dev/null || echo unavailable; }
{
    echo "run_id=$RUN_ID"
    echo "uid=$(id -u)"
    echo "filesystem=$(findmnt -no FSTYPE -T "$PROJECT_DIR")"
    echo "source=$(findmnt -no SOURCE -T "$PROJECT_DIR")"
    echo "mount=$(available mount)"
    echo "losetup=$(available losetup)"
    echo "mkfs_btrfs=$(available mkfs.btrfs)"
    echo "btrfs=$(available btrfs)"
    echo "compsize=$(available compsize)"
    echo "zfs=$(available zfs)"
    echo "zpool=$(available zpool)"
    echo "dmsetup=$(available dmsetup)"
    echo "loop_nodes=$(find /dev -maxdepth 1 -name 'loop*' -printf '%f ' 2>/dev/null || true)"
    echo "visible_nvme_nodes=$(find /dev -maxdepth 1 -name 'nvme*n*' -printf '%f ' 2>/dev/null || true)"
    echo "block_inventory_begin"
    lsblk -o NAME,TYPE,SIZE,FSTYPE,MOUNTPOINT 2>&1 || true
    echo "block_inventory_end"
} > "$RESULT_DIR/capability.txt"

reasons=()
[[ "$(id -u)" -eq 0 ]] || reasons+=("requires root/CAP_SYS_ADMIN to mount an isolated filesystem")
command -v mkfs.btrfs >/dev/null || reasons+=("btrfs-progs mkfs.btrfs unavailable")
find /dev -maxdepth 1 -name 'loop*' -print -quit 2>/dev/null | grep -q . ||
    reasons+=("no loop device node is visible")
command -v zfs >/dev/null || reasons+=("ZFS userspace/kernel tools unavailable")
command -v zpool >/dev/null || reasons+=("zpool unavailable")

{
    echo "# Storage baseline preflight"
    echo
    echo "Status: BLOCKED on this host; no filesystem was formatted or mounted."
    echo
    for reason in "${reasons[@]}"; do echo "- $reason"; done
    echo
    echo "The existing project filesystem is not a substitute for an isolated,"
    echo "verified btrfs zstd/ZFS volume. Run tests/btrfs_compare.sh only on a"
    echo "disposable loop device or dedicated test volume with mount privileges."
} > "$RESULT_DIR/README.md"

echo "[OK] $RESULT_DIR"
