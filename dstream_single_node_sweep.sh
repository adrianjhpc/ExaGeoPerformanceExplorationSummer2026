#!/bin/bash
#SBATCH --job-name=DS-SNS
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --time=04:00:00
#SBATCH --nvram-options=none
# Must request highest CPU count we intend to use upfront
#SBATCH --ntasks=96

set -euo pipefail

module load compiler/2023.0.0
# module load memkind/1.12.0
# module load pmdk/1.11.1

# Uncomment if you need a non-default path, or, leave commented out and set on
# command line
# DSTREAM_BIN="/path/to/distributed_streams

# We use the values below to calculate the number of STREAM_TYPE (double or 
# float) it takes to fill the L3 cache on NextGenIO's compute nodes. See 
# DistributedStream/src/streams_memory_task.c for more info.
# Size of the STREAM_TYPE (usually double, unless you compiled 
# DistributedSteam to use float) being used, in bytes
STREAM_TYPE_SIZE=8
# Size of the last level CPU cache, in bytes
LL_CACHE_SIZE=37486592
# How many times DistributedStream will repeat the benchmark before 
# calculating the min/max/mean
N_RUNS=30
# Change this to point to where you installed Mini-XML
MXML_LIB_PATH="$HOME/mxml/lib"

MAX_TOTAL_CPUS="$SLURM_NTASKS"
# Make this > than MAX_TOTAL_CPUS if you want to test oversubscription e.g.
# MAX_TOTAL_THREADS=$(( 2 * MAX_TOTAL_CPUS ))
MAX_TOTAL_THREADS="$MAX_TOTAL_CPUS"

# DistributedStream multiplies the array size by 4, take this (somewhat) into 
# account so we don't have unneccesarily large arrays
ARRAY_SCALE=2
# DistributedStream divides the test array length by the number of MPI ranks, 
# so we need to make sure that the max task case still exceeds the last level 
# cache size. I just added 1024 here to make sure we still exceed it if
# ARRAY_SCALE=4.
N_ARRAY_ELEMENTS=$(( ( ( ( LL_CACHE_SIZE / STREAM_TYPE_SIZE ) * 
                    MAX_TOTAL_CPUS ) / ( ARRAY_SCALE ) ) + 
                    ( 1024 * MAX_TOTAL_CPUS ) ))


SWEEP_COMMON=""
for _dir in \
    "${SLURM_SUBMIT_DIR:-}" \
    "$(dirname "${BASH_SOURCE[0]}")" \
    "$HOME/benchmarks"; do
    if [[ -f "$_dir/sweep_common.sh" ]]; then
        SWEEP_COMMON="$_dir/sweep_common.sh"
        break
    fi
done

if [[ -z "$SWEEP_COMMON" ]]; then
    printf 'ERROR: sweep_common.sh not found.\n' >&2
    exit 1
fi
# shellcheck source=./sweep_common.sh
source "$SWEEP_COMMON"

DSTREAM_BIN="${DSTREAM_BIN:-$HOME/benchmarks/DistributedStream/\
src/distributed_streams}"
BINARY_PATH=$(resolve_binary DSTREAM_BIN "$DSTREAM_BIN") || exit 1

run_benchmark() {
    local ntasks="$1"
    local cpus_per_task="$2"
    local threads_per_task="$3"

    OMP_NUM_THREADS="$threads_per_task" \
    LD_LIBRARY_PATH="$MXML_LIB_PATH:${LD_LIBRARY_PATH:-}" \
    srun --exclusive \
        --ntasks="$ntasks" \
        --cpus-per-task="$cpus_per_task" \
        "$BINARY_PATH" "$N_ARRAY_ELEMENTS" "$N_RUNS"
}

# from sweep_common.sh
run_sweep
