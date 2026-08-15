#!/usr/bin/env bash
#SBATCH --job-name=DS-SNS
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --time=05:00:00
#SBATCH --nvram-options=none
# Must request highest CPU count we intend to use upfront
#SBATCH --ntasks=96
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

module load mpi/2021.15 libfabric/1.13.0
# module load memkind/1.12.0
# module load pmdk/1.11.1

# Uncomment if you need a non-default path, or, leave commented out and set on
# command line
# DSTREAM_BIN="/path/to/distributed_streams"

# We use the values below to calculate the number of STREAM_TYPE (double or 
# float) it takes to fill the L3 cache on NextGenIO's compute nodes. See 
# DistributedStream/src/streams_memory_task.c for more info.
# Size of the STREAM_TYPE (usually double, unless you compiled 
# DistributedSteam to use float) being used, in bytes
STREAM_TYPE_SIZE=8
# Size of the last level CPU cache, in bytes
LL_CACHE_SIZE=44040192
# How many times DistributedStream will repeat the benchmark before 
# calculating the min/max/mean
N_RUNS=30
# Change this to point to where you installed Mini-XML
MXML_LIB_PATH="$HOME/mxml/lib"
N_PROC=$(nproc)
MAX_TOTAL_CPUS="${MAX_TOTAL_CPUS:-${SLURM_NTASKS:-$N_PROC}}"
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

RUNNER="${RUNNER:-auto}" # auto, slurm, or mpi
declare -a SLURM_LAUNCH_ARGS

export FI_PROVIDER="${FI_PROVIDER:-verbs}"
# Set to 1 if you are testing on Granite Rapids
RUNNING_ON_GNR="${RUNNING_ON_GNR:-0}"

SWEEP_COMMON=''
MPI_WRAPPER=''
for _dir in \
    "${SLURM_SUBMIT_DIR:-}" \
    "$SCRIPT_DIR" \
    "$HOME" \
    "$HOME/benchmarks"; do
    if [[ -f "$_dir/sweep_common.sh" ]]; then
        SWEEP_COMMON="$_dir/sweep_common.sh"
    fi
    if [[ -f "$_dir/mpi_wrapper.sh" ]]; then
        MPI_WRAPPER="$_dir/mpi_wrapper.sh"
    fi
done

# shellcheck source=./sweep_common.sh
source "$SWEEP_COMMON"
# shellcheck source=./mpi_wrapper.sh
source "$MPI_WRAPPER"

# From mpi_wrapper.sh
mpi_detect_implementation || exit 1

# Override mpi_configure_default and do nothing
mpi_configure_user() {
    true
}

run() {
    case "$RUNNER" in
        slurm)
            command -v srun > /dev/null 2>&1 ||
                { printf "srun not found\n" >&2; return 1; }
            srun "${SLURM_LAUNCH_ARGS[@]}" "$@"
            ;;
        mpi)
            mpi_run "$@"
            ;;
        auto)
            if [[ -n "${SLURM_JOB_ID:-}" ]] &&
                command -v srun > /dev/null 2>&1; then
                srun "${SLURM_LAUNCH_ARGS[@]}" "$@"
            else
                mpi_run "$@"
            fi
            ;;
        *)
            printf "Invalid RUNNER=%s\n" "$RUNNER" >&2
            return 2
            ;;
    esac
}

DSTREAM_BIN="${DSTREAM_BIN:-$HOME/benchmarks/DistributedStream/\
src/distributed_streams}"
BINARY_PATH=$(resolve_binary DSTREAM_BIN "$DSTREAM_BIN") || exit 1

UTC_NOW=$(date -u +%Y-%m-%dT%H%M%SZ)
RUN_DIR="ds_single_node_sweep_${UTC_NOW}"
mkdir -p "$RUN_DIR" && cd "$RUN_DIR" || exit 1

run_benchmark() {
    local ntasks="$1"
    local cpus_per_task="$2"
    local threads_per_task="$3"

    export OMP_NUM_THREADS="$threads_per_task"
    export LD_LIBRARY_PATH="$MXML_LIB_PATH:${LD_LIBRARY_PATH:-}"
    SLURM_LAUNCH_ARGS=(
        --ntasks="$ntasks"
        --cpus-per-task="$cpus_per_task"
    )

    MPI_ARGS=()
    case "$MPI_IMPL" in
        openmpi)
            MPI_ARGS+=(--host localhost)
            MPI_ARGS+=(-np "$ntasks")
            MPI_ARGS+=(--map-by slot:PE="$cpus_per_task")
            MPI_ARGS+=(--bind-to core)
            MPI_ARGS+=(-x FI_PROVIDER)
            if (( RUNNING_ON_GNR )); then
                MPI_ARGS+=(--mca btl 'self,sm')
            fi
            ;;
        intel)
            MPI_ARGS+=(-hosts localhost)
            MPI_ARGS+=(-n "$ntasks")
            MPI_ARGS+=(-genv I_MPI_PIN_DOMAIN "$cpus_per_task")
            if (( RUNNING_ON_GNR )); then
                MPI_ARGS+=(-genv I_MPI_FABRICS shm)
            fi
            MPI_ARGS+=(-genvlist FI_PROVIDER)
            ;;
        *)
            printf "Not setting args for unsupported MPI implementation\n"
            ;;
    esac
    run "$BINARY_PATH" "$N_ARRAY_ELEMENTS" "$N_RUNS"
}

# from sweep_common.sh
run_sweep
