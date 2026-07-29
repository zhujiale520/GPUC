# Storage baseline preflight

Status: BLOCKED on this host; no filesystem was formatted or mounted.

- requires root/CAP_SYS_ADMIN to mount an isolated filesystem
- no loop device node is visible
- ZFS userspace/kernel tools unavailable
- zpool unavailable

The existing project filesystem is not a substitute for an isolated,
verified btrfs zstd/ZFS volume. Run tests/btrfs_compare.sh only on a
disposable loop device or dedicated test volume with mount privileges.
