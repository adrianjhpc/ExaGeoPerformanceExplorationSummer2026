#!/usr/bin/env python3
# AI disclosure: ~80% of this file was written by GLM-5.3-Flash
"""Plot max sustained TRIAD bandwidth from a memory benchmark results CSV.

Expected input: a CSV whose first line is the header row, containing at least
    experiment, processes_per_node, threads_per_process, triad_size,
    node_name, node_triad_minimum

For every sweep point:
    max_sustained_triad_bandwidth = processes_per_node * triad_size
                                    / node_triad_minimum / 1e9   [GB/s]
(node_triad_minimum = fastest of N repetitions; triad_size = per-process bytes
moved, so processes * triad_size is the whole node's traffic per iteration.)

Outputs (next to the CSV, using its file stem):
    <stem>_heatmap.(png|pdf|svg)  p x t heatmap; grey = unswept,
                                  red cross-hatch = zero triad_size / bad time
    <stem>_scaling.(png|pdf|svg)  bandwidth vs. processes*threads

Usage:
    python plot_ds_results.py RESULTS.csv [--cores 112] [--cmap viridis]
                             [--dpi 300] [--font-scale 1.0]
"""

import argparse
import sys
from pathlib import Path

import matplotlib as mpl
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd
from matplotlib.patches import Patch, Rectangle
from matplotlib.figure import Figure

GB = 1e9  # bytes per GB
REQUIRED = [
    "experiment",
    "processes_per_node",
    "threads_per_process",
    "triad_size",
    "node_name",
    "node_triad_minimum",
]
NUMERIC = [
    "processes_per_node",
    "threads_per_process",
    "triad_size",
    "node_triad_minimum",
]
UNSWEPT, INVALID = "0.97", "tab:red"  # cell styles: grey / red cross-hatch
PEAK = "#D55E00"


def warn(msg: str) -> None:
    print(f"WARNING: {msg}", file=sys.stderr)


def save(fig: Figure, stem: str, tag: str, dpi: int) -> None:
    """Write PNG (raster) plus PDF/SVG (vector), so any tool can place it."""
    for ext in ("png", "pdf", "svg"):
        fig.savefig(f"{stem}_{tag}.{ext}", dpi=dpi)


def load_results(
    csv_path: Path, cores: int | None
) -> tuple[pd.DataFrame, int, str]:
    """Read the CSV, sanity-check it, and add derived columns pt / bw / invalid."""
    df = pd.read_csv(csv_path)  # first line of the file is the header row
    df.columns = df.columns.str.strip()
    missing = [c for c in REQUIRED if c not in df.columns]
    if missing:
        sys.exit(
            f"error: {csv_path} lacks column(s) {missing} - is the header row present?"
        )
    if df.empty:
        sys.exit(f"error: {csv_path} has no data rows")
    for col in NUMERIC:  # unparseable values become NaN and are flagged below
        df[col] = pd.to_numeric(df[col], errors="coerce")

    nodes = sorted(df["node_name"].astype(str).unique())
    if len(nodes) > 1:
        warn(f"multiple node_name values {nodes}; plotting only '{nodes[0]}'")
        df = df[df["node_name"].astype(str) == nodes[0]]

    bad_pos = (
        (df.processes_per_node <= 0)
        | (df.threads_per_process <= 0)
        | df.processes_per_node.isna()
        | df.threads_per_process.isna()
    )
    if bad_pos.any():
        warn(
            f"ignoring {int(bad_pos.sum())} row(s) with missing or non-positive p/t"
        )
    df = df[~bad_pos]
    non_int = (df.processes_per_node % 1 != 0) | (
        df.threads_per_process % 1 != 0
    )
    if non_int.any():
        warn(f"ignoring {int(non_int.sum())} row(s) with non-integer p/t")
    df = df[~non_int]
    if df.empty:
        sys.exit("error: no usable rows after sanity checks")
    dup = df.duplicated(subset=["processes_per_node", "threads_per_process"])
    if dup.any():
        warn(f"ignoring {int(dup.sum())} duplicate (processes, threads) rows")
    df = df[~dup]

    df["pt"] = df.processes_per_node * df.threads_per_process
    df["bw"] = (
        df.processes_per_node * df.triad_size / df.node_triad_minimum / GB
    )
    # zero/negative size or time cannot yield a sensible bandwidth
    df["invalid"] = ~(
        np.isfinite(df.bw)
        & (df.bw > 0)
        & (df.triad_size > 0)
        & (df.node_triad_minimum > 0)
    )
    if df.invalid.any():
        bad = ", ".join(
            f"{int(r.processes_per_node)}x{int(r.threads_per_process)}"
            for r in df[df.invalid].itertuples()
        )
        warn(
            f"zero/negative triad_size or invalid time in run(s) {bad}; "
            "cells will be marked as invalid"
        )

    core_count = int(cores or df.pt.max())
    if cores is None:
        warn(
            f"--cores not given: inferred {core_count} from the largest p*t "
            "(assumes the sweep reached the full core count)"
        )
    over = df.pt > core_count
    if over.any():
        warn(
            f"{int(over.sum())} row(s) exceed the {core_count}-core sweep limit; ignored"
        )
        df = df[~over]
    nondiv = core_count % df.processes_per_node.astype(int) != 0
    if nondiv.any():
        bad = sorted(df.processes_per_node[nondiv].astype(int).unique())
        warn(
            f"processes_per_node value(s) {bad} do not divide {core_count}; "
            "excluded from the heatmap"
        )
        df = df[~nondiv]

    # per-process footprint x processes should equal the node total in every run
    traffic = (df.processes_per_node * df.triad_size).dropna()
    if (
        len(traffic) > 1
        and traffic.max() - traffic.min() > 1e-6 * traffic.max()
    ):
        warn(
            "processes_per_node * triad_size is not constant across runs - "
            "check that triad_size is per-process before trusting the bandwidth"
        )

    print(
        f"Loaded {len(df)} sweep points from {csv_path} (node '{nodes[0]}', "
        f"{core_count} logical cores, {int((~df.invalid).sum())} valid)."
    )
    return df.reset_index(drop=True), core_count, nodes[0]


def plot_heatmap(
    df: pd.DataFrame, core_count: int, node: str, cmap_name: str
) -> Figure:
    """x = threads/process (1..cores), y = processes/node (divisors of cores)."""
    procs = [d for d in range(1, core_count + 1) if core_count % d == 0]
    grid = np.full((len(procs), core_count), np.nan)  # NaN = unswept
    for r in df.itertuples():
        grid[
            procs.index(int(r.processes_per_node)),
            int(r.threads_per_process) - 1,
        ] = r.bw
    for i, p in enumerate(procs):
        if np.isnan(grid[i]).all():
            warn(f"no data anywhere in the processes_per_node={p} row")

    fig, ax = plt.subplots(figsize=(8.27, 3))
    cmap = mpl.colormaps[cmap_name].copy()
    cmap.set_bad(UNSWEPT)

    im = ax.imshow(
        np.ma.masked_invalid(grid),
        origin="lower",
        aspect="auto",
        interpolation="nearest",
        cmap=cmap,
    )
    fig.colorbar(im, ax=ax, label="Max. triad bandwidth (GB/s)")

    for i, j in zip(
        *np.where(np.isnan(grid))
    ):  # unswept cell have white & grey crosshatch
        ax.add_patch(
            Rectangle(
                (j - 0.5, i - 0.5),
                1,
                1,
                facecolor="white",
                edgecolor=UNSWEPT,
                hatch="xx",
                lw=0,
            )
        )
    for r in df[df.invalid].itertuples():  # swept, but zero size / bad time
        i, j = (
            procs.index(int(r.processes_per_node)),
            int(r.threads_per_process) - 1,
        )
        ax.add_patch(
            Rectangle(
                (j - 0.5, i - 0.5),
                1,
                1,
                facecolor="white",
                edgecolor=INVALID,
                hatch="xx",
                lw=1.5,
            )
        )
        ax.text(
            j,
            i,
            "x",
            ha="center",
            va="center",
            color=INVALID,
            fontsize=8,
            fontweight="bold",
        )
    ax.legend(
        handles=[
            Patch(
                facecolor="white",
                edgecolor=UNSWEPT,
                hatch="xx",
                label="unswept (p×t > thread count)",
            ),
            Patch(facecolor="white", edgecolor=PEAK, label="peak bandwidth"),
            # White looks better for print:
            # Patch(facecolor=UNSWEPT, label=f"unswept (p×t > {core_count})"),
            # Patch(
            #     facecolor="white",
            #     edgecolor=INVALID,
            #     hatch="xx",
            #     label="invalid (zero size/time)",
            # ),
        ],
        loc="upper right",
        framealpha=0.9,
    )

    step = max(1, core_count // 14)  # thin out the x tick labels
    ticks = sorted(set(range(0, core_count, step)) | {core_count - 1})
    ax.set_xticks(ticks, [str(t + 1) for t in ticks])
    ax.xaxis.get_major_ticks()[-2].set_visible(False)
    ax.set_yticks(range(len(procs)), [str(p) for p in procs])
    ax.set_xlabel("OpenMP threads per process")
    ax.set_ylabel("MPI processes")

    title = f"DS max. triad BW ({node}, {core_count}t)"
    if np.isfinite(grid).any():
        i, j = np.unravel_index(np.nanargmax(grid), grid.shape)
        title += f": peak {np.nanmax(grid):.1f} GB/s @ {procs[i]}p{j + 1}t"
        ax.add_patch(
            Rectangle(
                (j - 0.5, i - 0.5), 1, 1, fill=False, edgecolor=PEAK, lw=1.5
            )
        )
    ax.set_title(title)
    fig.tight_layout()
    return fig


def plot_scaling(df: pd.DataFrame, core_count: int, node: str) -> Figure:
    """Companion line plot: bandwidth vs. p*t, one line per process count."""
    fig, ax = plt.subplots(figsize=(8.27, 3))
    for p, grp in df[~df.invalid].groupby("processes_per_node"):
        grp = grp.sort_values("pt")
        ax.plot(grp.pt, grp.bw, lw=1.2, label=f"{int(p)}")
    top = df.loc[df[~df.invalid].bw.idxmax()]
    ax.plot(
        top.pt,
        top.bw,
        marker="d",
        ls="none",
        ms=6,
        color="k",
        label=f"peak {top.bw:.1f} GB/s",
    )
    ax.set_title(
        f"DS scaling ({node}, {core_count}t): total threads vs. max. triad bandwidth"
    )
    ax.set_xlabel("MPI processes × OpenMP threads")
    ax.set_ylabel("Max. triad bandwidth (GB/s)")
    ax.grid(True, alpha=0.3)
    ax.legend(
        title="MPI processes",
        loc="lower right",
        ncol=4,
        fontsize=6,
        borderpad=0.3,
        handlelength=1.0,
        labelspacing=0.3,
    )
    fig.tight_layout()
    return fig


def main() -> None:
    ap = argparse.ArgumentParser(
        description="Plot triad bandwidth sweep from a benchmark CSV."
    )
    ap.add_argument("csv", type=Path, help="results CSV (header row required)")
    ap.add_argument(
        "--cores",
        type=int,
        help="logical core count (default: inferred from data)",
    )
    ap.add_argument(
        "--cmap", default="viridis", help="perceptually uniform colormap"
    )
    ap.add_argument(
        "--dpi", type=int, default=300, help="PNG resolution (default 300)"
    )
    ap.add_argument(
        "--font-scale",
        type=float,
        default=1.0,
        help="font size multiplier (e.g. 1.5 for a poster banner)",
    )
    args = ap.parse_args()

    mpl.rcParams.update(
        {
            "font.size": 10 * args.font_scale,
            "axes.labelsize": 10 * args.font_scale,
            "axes.titlesize": 11 * args.font_scale,
            "legend.fontsize": 9 * args.font_scale,
            "xtick.labelsize": 9 * args.font_scale,
            "ytick.labelsize": 9 * args.font_scale,
        }
    )

    df, core_count, node = load_results(args.csv, args.cores)
    if not (~df.invalid).any():
        sys.exit("error: no run produced a valid bandwidth")

    stem = str(args.csv.with_suffix(""))
    save(
        plot_heatmap(df, core_count, node, args.cmap),
        stem,
        "heatmap",
        args.dpi,
    )
    save(plot_scaling(df, core_count, node), stem, "scaling", args.dpi)
    print(
        f"Wrote {stem}_heatmap.{{png,pdf,svg}} and {stem}_scaling.{{png,pdf,svg}}"
    )


if __name__ == "__main__":
    main()
