#!/usr/bin/env python3
"""Deterministic SQLite point-read workload for GPU offload experiments."""

from __future__ import annotations

import argparse
import hashlib
import json
import multiprocessing as mp
import os
import sqlite3
import statistics
import time
from pathlib import Path


def prepare_database(path: Path, rows: int, payload_mode: str = "constant") -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        path.unlink()
    con = sqlite3.connect(path)
    con.execute("PRAGMA journal_mode=OFF")
    con.execute("PRAGMA synchronous=OFF")
    con.execute("CREATE TABLE kv (id INTEGER PRIMARY KEY, payload BLOB NOT NULL)")
    constant_payload = bytes((i * 37 + 11) & 0xFF for i in range(512))
    def records():
        for row_id in range(rows):
            if payload_mode == "constant":
                payload = constant_payload
            else:
                digest = hashlib.sha256(f"gpuc-sqlite-{row_id}".encode()).digest()
                prefix = (f"event id={row_id} category={row_id % 32} status=ok ".encode() * 8)
                payload = (prefix + digest * 8)[:512].ljust(512, b" ")
            yield row_id, payload
    con.executemany(
        "INSERT INTO kv(id, payload) VALUES (?, ?)",
        records(),
    )
    con.commit()
    con.execute("ANALYZE")
    con.close()


def worker(path: str, rows: int, span: int, cpu: int, duration: float,
           prewarm: bool, sample_every: int, start, queue: mp.Queue) -> None:
    try:
        os.sched_setaffinity(0, {cpu})
    except (AttributeError, OSError):
        pass
    con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
    con.execute("PRAGMA query_only=ON")
    con.execute("PRAGMA mmap_size=0")
    cur = con.cursor()
    if prewarm:
        row = cur.execute(
            "SELECT sum(length(payload)) FROM kv WHERE id BETWEEN ? AND ?",
            (0, span - 1),
        ).fetchone()
        if row is None or row[0] != 512 * span:
            raise RuntimeError("SQLite warmup result mismatch")
    state = 0x9E3779B97F4A7C15 ^ cpu
    operations = 0
    samples_us: list[float] = []
    start.wait()
    deadline = time.monotonic() + duration
    while time.monotonic() < deadline:
        state ^= state >> 12
        state ^= (state << 25) & ((1 << 64) - 1)
        state ^= state >> 27
        key = (state * 0x2545F4914F6CDD1D) % (rows - span)
        t0 = time.perf_counter_ns()
        row = cur.execute(
            "SELECT sum(length(payload)) FROM kv WHERE id BETWEEN ? AND ?",
            (key, key + span - 1),
        ).fetchone()
        t1 = time.perf_counter_ns()
        if row is None or row[0] != 512 * span:
            raise RuntimeError("SQLite result mismatch")
        operations += 1
        if operations % sample_every == 0:
            samples_us.append((t1 - t0) / 1000.0)
    con.close()
    queue.put((operations, samples_us))


def percentile(values: list[float], percentile_value: float) -> float:
    if not values:
        return 0.0
    ordered = sorted(values)
    index = min(len(ordered) - 1,
                max(0, int(round((len(ordered) - 1) * percentile_value))))
    return ordered[index]


def run_workload(path: Path, rows: int, span: int,
                 workers: int, duration: float, prewarm: bool = False,
                 sample_every: int = 128) -> dict:
    ctx = mp.get_context("fork")
    start = ctx.Event()
    queue = ctx.Queue()
    processes = [
        ctx.Process(target=worker,
                    args=(str(path), rows, span, cpu, duration, prewarm,
                          sample_every, start, queue))
        for cpu in range(workers)
    ]
    for process in processes:
        process.start()
    begin = time.monotonic()
    start.set()
    results = [queue.get() for _ in processes]
    for process in processes:
        process.join()
        if process.exitcode != 0:
            raise RuntimeError(f"SQLite worker exited with {process.exitcode}")
    elapsed = time.monotonic() - begin
    operations = sum(result[0] for result in results)
    latencies = [sample for result in results for sample in result[1]]
    return {
        "elapsed_sec": elapsed,
        "workers": workers,
        "operations": operations,
        "qps": operations / elapsed,
        "latency_samples": len(latencies),
        "latency_mean_us": statistics.mean(latencies) if latencies else 0.0,
        "latency_p50_us": percentile(latencies, 0.50),
        "latency_p95_us": percentile(latencies, 0.95),
        "latency_p99_us": percentile(latencies, 0.99),
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--db", type=Path, required=True)
    parser.add_argument("--rows", type=int, default=100_000)
    parser.add_argument("--workers", type=int, default=4)
    parser.add_argument("--span", type=int, default=256)
    parser.add_argument("--duration", type=float, default=8.0)
    parser.add_argument("--payload-mode", choices=("constant", "mixed"), default="constant")
    parser.add_argument("--prewarm", action="store_true")
    parser.add_argument("--sample-every", type=int, default=128)
    parser.add_argument("--prepare", action="store_true")
    args = parser.parse_args()
    if args.sample_every < 1:
        parser.error("--sample-every must be positive")
    if args.prepare or not args.db.exists():
        prepare_database(args.db, args.rows, args.payload_mode)
    result = run_workload(args.db, args.rows, args.span,
                          args.workers, args.duration, args.prewarm,
                          args.sample_every)
    result["payload_mode"] = args.payload_mode
    result["database"] = str(args.db)
    result["rows"] = args.rows
    result["range_span"] = args.span
    result["database_bytes"] = args.db.stat().st_size
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
