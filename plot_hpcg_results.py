#!/usr/bin/env python3
# AI disclosure: ~80% of this file was written by GLM-5.3-Flash
"""Plot HPCG performance vs distributed processes for one node.

Input CSV (header row required) must contain
    distributed_processes, threads_per_processes, hpcg_result   [GFLOP/s]
and may contain nx, ny, nz, gb_total_data_memory, bytes_per_equation,
execution_time (enables extra sanity checks). The sweep keeps
distributed_processes * threads_per_processes == physical core count, so
the core count is inferred from the data and shown in the title.

The vendor-recommended result is drawn as a horizontal reference line. It is
never clamped to the top: if a sweep point overtakes it by a small margin,
that is shown as-is (y limits auto-fit both).

Output: <csv-stem>_hpcg.{png,pdf,svg}
Usage:  python plot_hpcg_results.py RESULTS.csv VENDOR_GFLOPS [--dpi 300]
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

import matplotlib.pyplot as plt
from matplotlib.figure import Figure
import pandas as pd

GB = 1e9
MIN_DIM = 16  # official minimum local grid dimension
OFFICIAL_TIME = 1800  # s of timed run required for official HPCG rankings
REQUIRED = ["distributed_processes", "threads_per_processes", "hpcg_result"]
OPTIONAL = [
    "nx",
    "ny",
    "nz",
    "gb_total_data_memory",
    "bytes_per_equation",
    "execution_time",
]


def warn(msg: str) -> None:
    print(f"WARNING: {msg}", file=sys.stderr)


def save(fig: Figure, stem: str, dpi: int) -> None:
    for ext in ("png", "pdf", "svg"):
        fig.savefig(f"{stem}.{ext}", dpi=dpi)


def load_hpcg(csv_path: Path) -> tuple[pd.DataFrame, int]:
    """Read + sanity-check the CSV; infer physical cores; return (data, cores)."""
    df = pd.read_csv(csv_path)  # first line of the file is the header row
    df.columns = df.columns.str.strip()
    missing = [c for c in REQUIRED if c not in df.columns]
    if missing:
        sys.exit(
            f"error: {csv_path} lacks column(s) {missing} - header row present?"
        )
    if df.empty:
        sys.exit(f"error: {csv_path} has no data rows")
    for col in [c for c in REQUIRED + OPTIONAL if c in df.columns]:
        df[col] = pd.to_numeric(df[col], errors="coerce")

    req = df[REQUIRED]
    bad = req.isna().any(axis=1) | (req <= 0).any(axis=1)
    non_int = (df.distributed_processes % 1 != 0) | (
        df.threads_per_processes % 1 != 0
    )
    for flag, why in (
        (bad, "missing or non-positive processes/threads/result"),
        (non_int, "non-integer processes/threads"),
    ):
        if flag.any():
            warn(f"ignoring {int(flag.sum())} row(s): {why}")
    df = df[~(bad | non_int)]
    dup = df.duplicated(
        subset=["distributed_processes", "threads_per_processes"]
    )
    if dup.any():
        warn(
            f"ignoring {int(dup.sum())} duplicate (processes, threads) row(s)"
        )
    df = df[~dup]
    if df.empty:
        sys.exit("error: no usable rows after sanity checks")

    df["pt"] = df.distributed_processes * df.threads_per_processes
    cores = int(
        df.pt.mode().iloc[0]
    )  # p*t == physical core count by construction
    if df.pt.nunique() > 1:
        warn(f"p*t is not constant; keeping only rows with p*t = {cores}")
        df = df[df.pt == cores]
    # integer p, t with p*t == cores implies cores/p == t, so "p divides cores"
    # holds automatically - no separate divisibility check is needed.

    dims = ["nx", "ny", "nz"]
    if all(c in df for c in dims):
        d = df[dims]
        broken = (
            d.isna().any(axis=1)
            | (d < MIN_DIM).any(axis=1)
            | (d % 2 != 0).any(axis=1)
        )
        if broken.any():
            warn(
                f"{int(broken.sum())} row(s) fail the official grid rules: "
                f"nx,ny,nz >= {MIN_DIM} and even at every multigrid level"
            )
        if {"gb_total_data_memory", "bytes_per_equation"} <= set(df.columns):
            expect = df.gb_total_data_memory * GB / (df.nx * df.ny * df.nz)
            drift = (
                expect - df.bytes_per_equation
            ).abs() > 0.01 * df.bytes_per_equation.abs()
            if drift.any():
                warn(
                    f"bytes_per_equation != gb_total_data_memory/(nx*ny*nz) "
                    f"within 1% for {int(drift.sum())} row(s)"
                )
    if "execution_time" in df:
        if (df.execution_time <= 0).any():
            warn("execution_time has zero/negative value(s)")
        if df.execution_time.min() < OFFICIAL_TIME:
            warn(
                f"timed run(s) {df.execution_time.min():.0f}-"
                f"{df.execution_time.max():.0f} s < {OFFICIAL_TIME} s: not valid "
                "for official HPCG rankings (fine for testing)"
            )

    divs = [d for d in range(1, cores + 1) if cores % d == 0]
    gap = sorted(set(divs) - set(df.distributed_processes.astype(int)))
    print(
        f"Loaded {len(df)} configs on {cores} physical cores; "
        f"divisors not swept: {gap if gap else 'none'}"
    )
    return (
        df.sort_values("distributed_processes").reset_index(drop=True),
        cores,
    )


def plot_hpcg(
    df: pd.DataFrame, cores: int, hostname: str, vendor: float
) -> Figure:
    fig, ax = plt.subplots(figsize=(8.27, 3))
    bars = ax.bar(
        [
            f"{e.distributed_processes}×{e.threads_per_processes}"
            for e in df.itertuples()
        ],
        df.hpcg_result,
        color="tab:blue",
        label="HPCG result @ p×t",
    )
    ax.axhline(
        vendor,
        ls="--",
        color="tab:red",
        label=f"Vendor recommended: {vendor:.1f} GFLOP/s",
    )
    ax.bar_label(bars, padding=-15, color="white")
    ax.set_xlabel("MPI processes × OpenMP threads")
    ax.set_ylabel("Unofficial HPCG result (GFLOP/s)")
    ax.grid(True, alpha=0.3)
    ax.legend(
        loc="lower right",
        ncol=2,
        fontsize=8,
        borderpad=0.3,
        handlelength=1.0,
        labelspacing=0.3,
    )
    ax.set_title(f"HPCG p/t sweep ({hostname}, {cores} physical cores == p×t)")
    fig.tight_layout()
    return fig


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Plot HPCG sweep results vs number of processes."
    )
    ap.add_argument(
        "csv", type=Path, help="results CSV (.csv extension required)"
    )
    ap.add_argument(
        "hostname", type=str, help="Hostname of system HPCG was run on"
    )
    ap.add_argument(
        "vendor",
        type=float,
        metavar="VENDOR_GFLOPS",
        help="vendor-recommended HPCG result, drawn as a horizontal line",
    )
    ap.add_argument(
        "--dpi", type=int, default=300, help="PNG resolution (default 300)"
    )
    args = ap.parse_args()
    if args.csv.suffix.lower() != ".csv":
        sys.exit("error: input file must have a .csv extension")
    if args.vendor <= 0:
        sys.exit("error: vendor-recommended result must be positive")

    df, cores = load_hpcg(args.csv)
    save(
        plot_hpcg(df, cores, args.hostname, args.vendor),
        str(args.csv.with_suffix("")),
        args.dpi,
    )
    print(
        f"Wrote {args.csv.with_suffix('')}_hpcg...".replace("_hpcg...", "")
        + f"{args.csv.stem}_hpcg.{{png,pdf,svg}}"
        if False
        else f"Wrote {args.csv.with_suffix('')}.{{png,pdf,svg}}"
    )


if __name__ == "__main__":
    main()
