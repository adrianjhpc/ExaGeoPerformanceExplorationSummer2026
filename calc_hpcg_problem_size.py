#!/usr/bin/env python3
import argparse
import math

# AI disclosure: ~90% of this was file written by GPT 5.6 Luna

def round_multiple_of_8(value: float) -> int:
    """Round to the nearest multiple of 8, with a minimum of 24."""
    return max(24, int(math.floor(value / 8 + 0.5)) * 8)


def hpcg_problem_size(
    memory_bytes: int,
    bytes_per_equation: int,
    ranks: int,
    memory_proportion: float = 0.25,
) -> tuple[int, int, int]:
    """Return HPCG problem dimensions x, y, and z."""
    if memory_bytes <= 0 or bytes_per_equation <= 0 or ranks <= 0:
        raise ValueError(
            "memory_bytes, bytes_per_equation, and ranks must be positive"
        )
    if not math.isfinite(memory_proportion) or not 0 < memory_proportion <= 1:
        raise ValueError("memory_proportion must be > 0 and <= 1")

    target_memory = memory_proportion * memory_bytes
    target_volume = math.ceil(target_memory / (ranks * bytes_per_equation))

    x = round_multiple_of_8(math.cbrt(target_volume))
    y = x

    # Smallest multiple of 8 such that x * y * z > target_volume
    z = max(
        24,
        8 * (target_volume // (x * y * 8) + 1),
    )

    return x, y, z


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Calculate HPCG problem dimensions."
    )
    parser.add_argument(
        "memory_bytes",
        type=int,
        help="Total memory capacity of the system you wish to test, in bytes",
    )
    parser.add_argument(
        "bytes_per_equation",
        type=int,
        help=(
            "This can be found in the 'Memory Use Summary' section of a "
            "HPCG output, run it for any problem size which is a multiple "
            "of 8 and > 24 and round bytes per equation to the nearest "
            "integer."
        ),
    )
    parser.add_argument("ranks", type=int)
    parser.add_argument(
        "--proportion",
        type=float,
        default=0.25,
        help=(
            "Target memory proportion, must be > 0 and <= 1. The default of "
            "0.25 means 25%% of total memory capacity (memory_bytes)"
        ),
    )

    args = parser.parse_args()

    print(
        *hpcg_problem_size(
            args.memory_bytes,
            args.bytes_per_equation,
            args.ranks,
            args.proportion,
        )
    )


if __name__ == "__main__":
    main()
