#!/usr/bin/env python3
# AI disclosure: ~90% of this code was written by GLM-5.3-Flash
"""Extract key metrics from HPCG benchmark result files (AMD/Intel variants).

Keys are matched whitespace-insensitively, because the implementations pad
them differently (e.g. " Final Summary ::..." vs "Final Summary::...").
"""

import argparse
from dataclasses import asdict, field, fields, dataclass
from pathlib import Path
from typing import Any, get_type_hints


class HpcgParseError(ValueError):
    """A required field is missing or has an unexpected value."""


def _from_line(key: str) -> Any:
    """Tag a dataclass field with the result-file line key it is read from."""
    return field(metadata={"key": key})


@dataclass(frozen=True)
class HpcgResults:
    """One metric per field; the annotation doubles as the value caster."""

    distributed_processes: int = _from_line(
        "Machine Summary::Distributed Processes"
    )
    threads_per_processes: int = _from_line(
        "Machine Summary::Threads per processes"
    )
    nx: int = _from_line("Global Problem Dimensions::Global nx")
    ny: int = _from_line("Global Problem Dimensions::Global ny")
    nz: int = _from_line("Global Problem Dimensions::Global nz")
    gb_total_data_memory: float = _from_line(
        "Memory Use Information::Total memory used for data (Gbytes)"
    )
    bytes_per_equation: float = _from_line(
        "Memory Use Information::Bytes per equation (Total memory / Number of Equations)"
    )
    hpcg_result: float = _from_line(
        "Final Summary::HPCG result is VALID with a GFLOP/s rating of"
    )
    execution_time: float = _from_line(
        "Final Summary::Results are valid but execution time (sec) is"
    )


def _norm(key: str) -> str:
    """Comparison key for a line: all whitespace removed."""
    return "".join(key.split())


def _parse_pairs(text: str) -> dict[str, tuple[int, str]]:
    """Map normalised key -> (line number, raw value) for every 'key=value' line."""
    pairs: dict[str, tuple[int, str]] = {}
    for line_no, line in enumerate(text.splitlines(), start=1):
        line = line.strip()
        if not line or "=" not in line:
            continue
        key, _, value = line.partition("=")
        pairs.setdefault(_norm(key), (line_no, value.strip()))
    return pairs


def parse_hpcg_text(text: str, source: str = "<text>") -> HpcgResults:
    """Extract HpcgResults from the full text of one result file."""
    pairs = _parse_pairs(text)
    casters = get_type_hints(HpcgResults)
    values: dict[str, Any] = {}
    for spec in fields(HpcgResults):
        key = spec.metadata["key"]
        try:
            line_no, raw = pairs[_norm(key)]
        except KeyError:
            raise HpcgParseError(
                f"{source}: missing required line '{key}=<value>'"
            ) from None
        try:
            values[spec.name] = casters[spec.name](raw)
        except ValueError:
            raise HpcgParseError(
                f"{source}: line {line_no}: '{key}' has unexpected value {raw!r}"
            ) from None
    return HpcgResults(**values)


def parse_hpcg_file(path: str | Path) -> HpcgResults:
    """Extract HpcgResults from one result file on disk."""
    return parse_hpcg_text(
        Path(path).read_text(encoding="utf-8"), source=str(path)
    )


def main(argv: list[str] | None = None) -> None:
    parser = argparse.ArgumentParser(
        description="Print key metrics from an HPCG result file."
    )
    parser.add_argument(
        "file", type=Path, help="HPCG result file (AMD or Intel variant)"
    )
    args = parser.parse_args(argv)
    try:
        results = parse_hpcg_file(args.file)
    except (HpcgParseError, OSError) as exc:
        raise SystemExit(f"error: {exc}")
    row = asdict(results)
    width = max(map(len, row))
    for name, value in row.items():
        print(f"{name:<{width}} = {value}")


if __name__ == "__main__":
    main()
