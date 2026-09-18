#!/usr/bin/env python3
# AI disclosure: ~90% of this code was written by GLM-5.3-Flash
"""Write a CSV of HPCG sweep results from a directory of per-run subdirectories.

Each subdirectory of the sweep directory holds the result file(s) of one run
(AMD or Intel naming). Runs whose result file is missing or unparsable are
skipped with a loud warning on stderr; the rest become one CSV row each.
"""

import argparse
import csv
import re
import sys
from dataclasses import astuple, fields
from pathlib import Path

from hpcg_extract import HpcgParseError, HpcgResults, parse_hpcg_file

# AMD example: HPCG-Benchmark_3.1_2026-09-03_19-41-15.txt
AMD_NAME = re.compile(
    r"HPCG-Benchmark_[\d.]+_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.txt"
)
# Intel example: n368-2p-28t_V3.1_2026-09-04_15-34-43.txt
INTEL_NAME = re.compile(
    r"n\d{1,3}-\d{1,3}p-\d{1,3}t_V[\d.]+_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.txt"
)


def _warn(message: str) -> None:
    print(f"WARNING: {message}", file=sys.stderr)


def _result_files(run_dir: Path) -> list[Path]:
    """HPCG result files in one run directory, oldest to newest (the embedded
    timestamp in each name sorts chronologically)."""
    return sorted(
        path
        for path in run_dir.iterdir()
        if path.is_file()
        and (AMD_NAME.fullmatch(path.name) or INTEL_NAME.fullmatch(path.name))
    )


def collect_runs(sweep_dir: Path) -> list[HpcgResults]:
    """Parse one result file per run directory, skipping bad runs with a warning."""
    rows: list[HpcgResults] = []
    for run_dir in sorted(sweep_dir.iterdir()):
        if not run_dir.is_dir():
            continue  # e.g. failed_runs.log, sweep logs
        files = _result_files(run_dir)
        if not files:
            _warn(f"{run_dir}: no HPCG results file found")
            continue
        if len(files) > 1:
            _warn(
                f"{run_dir}: multiple HPCG result files, using newest ({files[-1].name})"
            )
        try:
            rows.append(parse_hpcg_file(files[-1]))
        except (HpcgParseError, OSError, UnicodeDecodeError) as exc:
            _warn(f"{run_dir}: {exc}")
    return rows


def write_csv(rows: list[HpcgResults], path: Path) -> None:
    """Write a header row of HpcgResults field names, then one row per run."""
    columns = [info.name for info in fields(HpcgResults)]
    with path.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.writer(fh)
        writer.writerow(columns)
        writer.writerows(astuple(row) for row in rows)


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Write a CSV of HPCG sweep results."
    )
    parser.add_argument(
        "sweep_results_dir",
        type=Path,
        help="directory holding one subdirectory per HPCG run",
    )
    args = parser.parse_args(argv)

    sweep_dir = args.sweep_results_dir
    if not sweep_dir.is_dir():
        raise SystemExit(f"error: not a directory: {sweep_dir}")
    if not sweep_dir.name:
        raise SystemExit(f"error: cannot derive a CSV name from '{sweep_dir}'")

    rows = collect_runs(sweep_dir)
    # Numeric sort on the int fields (stable: ties fall back to directory order).
    rows.sort(
        key=lambda run: (run.distributed_processes, run.threads_per_processes)
    )

    out_path = Path(f"{sweep_dir.name}.csv")
    write_csv(rows, out_path)
    print(f"wrote {len(rows)} runs to {out_path}")


if __name__ == "__main__":
    main()
