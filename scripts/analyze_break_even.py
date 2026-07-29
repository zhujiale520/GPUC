#!/usr/bin/env python3
"""Derive read-time break-even from final measured summaries.

If a compressed read is slower than its paired baseline, no positive number
of reads can amortize a non-negative offline compression cost.
"""

import csv
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
FINAL = ROOT / "results" / "final"


def read_summary(path):
    with path.open(newline="") as f:
        return list(csv.DictReader(f))


rows = []

cold = {
    r["scenario"]: float(r["mean_mib_s"])
    for r in read_summary(FINAL / "cold_cache_v100_20260729" / "summary.csv")
}
rows.append(("cold_cache", "sglz", cold["baseline"], cold["gpu_compressed"]))

backends = {
    r["scenario"]: float(r["mean_mib_s"])
    for r in read_summary(
        FINAL / "backends_worker_batch32_v100_20260729" / "summary.csv"
    )
}
rows.extend(
    [
        ("warm_headers", "sglz", backends["baseline"], backends["sglz"]),
        ("warm_headers", "lz4", backends["baseline"], backends["lz4"]),
    ]
)

gradient = read_summary(
    FINAL / "compressibility_v100_20260729" / "summary.csv"
)
for ratio in (25, 50, 75, 100):
    base = next(
        float(r["mean_mib_s"])
        for r in gradient
        if int(r["compressibility_pct"]) == ratio and r["scenario"] == "baseline"
    )
    gpuc = next(
        float(r["mean_mib_s"])
        for r in gradient
        if int(r["compressibility_pct"]) == ratio and r["scenario"] == "gpuc"
    )
    rows.append((f"warm_gradient_{ratio}pct", "sglz", base, gpuc))

out_path = FINAL / "break_even.csv"
with out_path.open("w", newline="") as f:
    out = csv.writer(f, lineterminator="\n")
    out.writerow(
        [
            "workload",
            "algorithm",
            "baseline_mib_s",
            "gpuc_mib_s",
            "gpuc_vs_baseline",
            "read_count_break_even",
            "reason",
        ]
    )
    for workload, algorithm, baseline, gpuc in rows:
        ratio = gpuc / baseline
        if gpuc <= baseline:
            break_even = "never"
            reason = (
                "compressed read is slower before adding offline compression cost"
            )
        else:
            # Compression cost is workload-specific and must be supplied before
            # calculating an exact positive count.
            break_even = "needs_compression_time"
            reason = "read path is faster; exact count needs matched compression time"
        out.writerow(
            [
                workload,
                algorithm,
                f"{baseline:.3f}",
                f"{gpuc:.3f}",
                f"{ratio:.6f}",
                break_even,
                reason,
            ]
        )

print(out_path)
