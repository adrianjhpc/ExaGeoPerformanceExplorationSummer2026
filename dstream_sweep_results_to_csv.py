#!/usr/bin/env python3
# AI disclosure: ~99% of this file was written by GPT 5.5

import argparse
import csv
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

COLUMNS = [
    "experiment",
    "processes_per_node",
    "threads_per_process",
    "number_of_nodes",
    "copy_size",
    "scale_size",
    "add_size",
    "triad_size",
    "node_name",
    "node_copy_average",
    "node_copy_minimum",
    "node_copy_maximum",
    "node_scale_average",
    "node_scale_minimum",
    "node_scale_maximum",
    "node_add_average",
    "node_add_minimum",
    "node_add_maximum",
    "node_triad_average",
    "node_triad_minimum",
    "node_triad_maximum",
]


FILENAME_RE = re.compile(
    r"^memory_results-(?P<processes>\d+)x(?P<threads>\d+)-(?P<date>\d+)-(?P<time>\d+)\.dat$"
)


def clean_text(value):
    """
    XML text in the sample may contain embedded newlines.
    This normalises it, e.g.

        memory_results-
        4x17-20260622-
        161412.dat

    becomes

        memory_results-4x17-20260622-161412.dat
    """
    if value is None:
        return ""
    return "".join(value.split())


def get_text(parent, path, default=""):
    """
    Safely fetch text from an XML element using an ElementTree path.
    """
    element = parent.find(path)
    if element is None:
        return default
    return clean_text(element.text)


def parse_process_thread_from_filename(path):
    """
    Extract M and N from memory_results-MxN-DATE-TIME.dat.

    Used as a fallback if the XML fields are missing.
    """
    match = FILENAME_RE.match(path.name)
    if not match:
        return "", ""

    return match.group("processes"), match.group("threads")


def parse_result_file(path):
    """
    Parse one XML benchmark result file and return a dictionary matching COLUMNS.
    """
    try:
        tree = ET.parse(path)
    except ET.ParseError as exc:
        raise RuntimeError(f"Could not parse XML file {path}: {exc}") from exc

    root = tree.getroot()

    filename_processes, filename_threads = parse_process_thread_from_filename(
        path
    )

    experiment = get_text(root, "experiment")
    if not experiment:
        experiment = path.name

    configuration = root.find("configuration")
    if configuration is None:
        raise RuntimeError(f"Missing <configuration> section in {path}")

    results = root.find("results")
    if results is None:
        raise RuntimeError(f"Missing <results> section in {path}")

    node = results.find("node")
    if node is None:
        raise RuntimeError(f"Missing <results><node> section in {path}")

    row = {
        "experiment": experiment,
        "processes_per_node": get_text(configuration, "processes_per_node")
        or filename_processes,
        "threads_per_process": get_text(configuration, "threads_per_process")
        or filename_threads,
        "number_of_nodes": get_text(configuration, "number_of_nodes"),
        "copy_size": get_text(configuration, "copy_size"),
        "scale_size": get_text(configuration, "scale_size"),
        "add_size": get_text(configuration, "add_size"),
        "triad_size": get_text(configuration, "triad_size"),
        "node_name": get_text(node, "name"),
        "node_copy_average": get_text(node, "Copy/Average"),
        "node_copy_minimum": get_text(node, "Copy/Minimum"),
        "node_copy_maximum": get_text(node, "Copy/Maximum"),
        "node_scale_average": get_text(node, "Scale/Average"),
        "node_scale_minimum": get_text(node, "Scale/Minimum"),
        "node_scale_maximum": get_text(node, "Scale/Maximum"),
        "node_add_average": get_text(node, "Add/Average"),
        "node_add_minimum": get_text(node, "Add/Minimum"),
        "node_add_maximum": get_text(node, "Add/Maximum"),
        "node_triad_average": get_text(node, "Triad/Average"),
        "node_triad_minimum": get_text(node, "Triad/Minimum"),
        "node_triad_maximum": get_text(node, "Triad/Maximum"),
    }

    return row


def sort_key(path):
    """
    Sort files numerically by processes, threads, date, and time where possible.
    """
    match = FILENAME_RE.match(path.name)
    if not match:
        return (sys.maxsize, sys.maxsize, path.name)

    return (
        int(match.group("processes")),
        int(match.group("threads")),
        match.group("date"),
        match.group("time"),
    )


def main():
    parser = argparse.ArgumentParser(
        description="Convert STREAM-like XML benchmark .dat files into DS_results.csv"
    )

    parser.add_argument(
        "directory",
        nargs="?",
        default=".",
        help="Directory containing memory_results-*.dat files. Default: current directory.",
    )

    parser.add_argument(
        "-o",
        "--output",
        default="DS_results.csv",
        help="Output CSV filename. Default: DS_results.csv",
    )

    args = parser.parse_args()

    input_dir = Path(args.directory).expanduser().resolve()
    output_csv = Path(args.output).expanduser().resolve()

    if not input_dir.is_dir():
        raise SystemExit(f"Error: {input_dir} is not a directory")

    files = sorted(input_dir.glob("memory_results-*.dat"), key=sort_key)

    if not files:
        raise SystemExit(f"No memory_results-*.dat files found in {input_dir}")

    rows = []

    for path in files:
        try:
            rows.append(parse_result_file(path))
        except Exception as exc:
            print(f"Warning: skipping {path.name}: {exc}", file=sys.stderr)

    if not rows:
        raise SystemExit("No valid result files were parsed")

    with output_csv.open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=COLUMNS)
        writer.writeheader()
        writer.writerows(rows)

    print(f"Wrote {len(rows)} rows to {output_csv}")


if __name__ == "__main__":
    main()
