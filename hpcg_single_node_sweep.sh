#!/usr/bin/env bash
#SBATCH --job-name=hpcgSNS
#SBATCH --exclusive
#SBATCH --nodes=1
# Must request highest CPU count we intend to use upfront for SLURM normal
# partition sweep
#SBATCH --ntasks=48
#SBATCH --hint=nomultithread
#SBATCH --time=48:00:00
#SBATCH --nvram-options=none

set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

module load compiler/2023.0.0
module load mkl/2023.0.0
module load mpi/2021.15

# The implementation decision logic can definitely be improved
IMPLEMENTATION="${1:-intel}"
declare -a R_LIST

detect_system() {
    local ncpu
    ncpu=$(lscpu | awk '/^CPU\(s\):/ {print $NF}')

    # gnr has model name "Genuine Intel(R) 0000" so better to use logical core
    # counts instead. c is physical core count
    case "$ncpu" in
        128)
            IMPLEMENTATION=amd
            R_LIST=(1 2 4 8 16 32 64)
            printf 'amd\n' ;; # 2x EPYC 7502, 64c SMT-2
        112)
            R_LIST=(1 2 4 7 8 14 28 56)
            printf 'icx\n' ;; # 2x Xeon Gold 6330, 56c SMT-2
        480)
            R_LIST=(1 2 3 4 6 8 12 16 24 32 48 64 120 240)
            RUNNING_ON_GNR="${RUNNING_ON_GNR:-1}"
            printf 'gnr\n' ;; # 2x Xeon 6979P eng sample, 240c SMT-2
        96)
            R_LIST=(1 2 4 6 8 12 16 24 32 48)
            printf 'normal\n' ;; # 2x Xeon 8268, 48c SMT-2
        *)
            printf 'ERROR: unrecognised system (CPUs=%s)\n' "$ncpu" >&2
            return 1
            ;;
    esac

    N_HW_CPU=$((ncpu / 2))
}
detect_system

IMPLEMENTATION="${IMPLEMENTATION,,}"

# Set to 1 if you are testing on Granite Rapids
RUNNING_ON_GNR="${RUNNING_ON_GNR:-0}"
RUNNER="${RUNNER:-auto}" # auto, slurm, or mpi
# Set to 1 to clamp the problem size to a max of 424^3 to prevent crashes for
# large problem sizes. This will however mean the problem size may not meet
# the 25% memory capacity requirement for a fair test
# I added this because I had difficulty compiling AMD's HPCG with 64-bit
# global indices. This does not adequately fill gnr's memory capacity
CLAMP_PROB_SIZE="${CLAMP_PROB_SIZE:-1}"

INTEL_HPCG_PATH="$HOME/benchmarks/intel_hpcg/bin/xhpcg_skx"
INTEL_ILP64_HPCG_PATH="$HOME/benchmarks/intel_hpcg_ilp64/bin/xhpcg_skx_ilp64"

# This can be found in the 'Memory Use Summary'section of a HPCG output, run it
# for any problem size which is a multiple of 8 and > 24 and round bytes per
# equation to the nearest integer
BPE_NORMAL=715
BPE_ILP64=839
BYTES_PER_EQUATION="${BYTES_PER_EQUATION:-$BPE_NORMAL}"
HPCG_RUN_TIME="${HPCG_RUN_TIME:-60}"
CLAMPSZ="${CLAMPSZ:-424}"

usage() {
    printf "Usage: %s [intel|intel_ilp64|amd]\n" "$0" >&2
    exit 1
}

if (( $# > 1 )); then
    usage
fi

declare -a SLURM_LAUNCH_ARGS

case "$IMPLEMENTATION" in
    intel)
        [[ -v XHPCG_BIN ]] || XHPCG_BIN="$INTEL_HPCG_PATH"
        ;;
    intel_ilp64)
        [[ -v XHPCG_BIN ]] || XHPCG_BIN="$INTEL_ILP64_HPCG_PATH"
        if (( BYTES_PER_EQUATION == BPE_NORMAL )); then
            BYTES_PER_EQUATION="$BPE_ILP64"
        fi
        ;;
    amd)
        module unload mpi openmpi mpich mkl compiler 
        spack load aocc@5.2.0
        spack load hpcg
        AOCC_LIB_PATH=$(spack location -i aocc@5.2.0)
        AOCC_LIB_PATH+='/lib'
        AMD_HPCG_PATH=$(spack location -i hpcg)
        AMD_HPCG_PATH+='/bin/xhpcg'
        export LD_LIBRARY_PATH="$LD_LIBRARY_PATH:$AOCC_LIB_PATH"
        [[ -v XHPCG_BIN ]] || XHPCG_BIN="$AMD_HPCG_PATH"
        ;;
    *)
        usage
        ;;
esac

# The code to set the problem size sometimes undershoots, so use 17/64 (~26.5%) 
# instead of 1/4. I use 272 since (17/64)*1024=272 is an integer
MEM_TARGET_BYTES=$(grep MemTotal /proc/meminfo | awk '{print $2 * 272}')

export OMP_PROC_BIND=close
export OMP_PLACES=cores

SWEEP_COMMON=''
HPCG_COMMON=''
MPI_WRAPPER=''
for _dir in \
    "${SLURM_SUBMIT_DIR:-}" \
    "$SCRIPT_DIR" \
    "$HOME/benchmarks"; do
    if [[ -f "$_dir/sweep_common.sh" ]]; then
        SWEEP_COMMON="$_dir/sweep_common.sh"
    fi
    if [[ -f "$_dir/hpcg_common.sh" ]]; then
        HPCG_COMMON="$_dir/hpcg_common.sh"
    fi
    if [[ -f "$_dir/mpi_wrapper.sh" ]]; then
        MPI_WRAPPER="$_dir/mpi_wrapper.sh"
    fi
done

if [[ -z "$SWEEP_COMMON" ]]; then
    printf 'ERROR: sweep_common.sh not found.\n' >&2
    exit 1
fi

if [[ -z "$HPCG_COMMON" ]]; then
    printf 'ERROR: hpcg_common.sh not found.\n' >&2
    exit 1
fi

if [[ -z "$MPI_WRAPPER" ]]; then
    printf 'ERROR: mpi_wrapper.sh not found.\n' >&2
    exit 1
fi

# shellcheck source=./sweep_common.sh
source "$SWEEP_COMMON"
# shellcheck source=./hpcg_common.sh
source "$HPCG_COMMON"
# shellcheck source=./mpi_wrapper.sh
source "$MPI_WRAPPER"

# From mpi_wrapper.sh
mpi_detect_implementation || exit 1

BINARY_PATH=$(resolve_binary XHPCG_BIN "$XHPCG_BIN") || exit 1

round_mult8() {
    awk -v s="$1" -v clamp="${2:-0}" -v clampsz="$CLAMPSZ" 'BEGIN {
        n = int((s + 4) / 8) * 8
        if (n < 24) n = 24
        if ((clamp == "1" || clamp == "true") && n > clampsz) n = clampsz
        print n
    }'
}

# Override mpi_configure_default and do nothing (we build MPI_ARGS ourselves)
mpi_configure_user() {
    true
}

run() {
    case "$RUNNER" in
        slurm)
            command -v srun >/dev/null 2>&1 ||
                { printf "srun not found\n" >&2; return 1; }
            srun "${SLURM_LAUNCH_ARGS[@]}" "$@"
            ;;
        mpi)
            mpi_run "$@"
            ;;
        auto)
            if [[ -n "${SLURM_JOB_ID:-}" ]] &&
                command -v srun >/dev/null 2>&1; then
                srun "${SLURM_LAUNCH_ARGS[@]}" "$@"
            else
                mpi_run "$@"
            fi
            ;;
        *)
            printf "Invalid RUNNER=%s" "$RUNNER" >&2
            return 2
            ;;
    esac
}

HST=$(hostname -s)
# From hpcg_common.sh
RUN_ROOT=$(print_run_root "${SLURM_SUBMIT_DIR:-$PWD}" "${HST}_s_")

FAILED_LOG="${RUN_ROOT:-.}/failed_runs.log"

if [[ "$CLAMP_PROB_SIZE" -gt 0 || "$CLAMP_PROB_SIZE" == 'true'  ]]; then
    printf '\nCLAMP_PROB_SIZE is ON. Problem size limited to 424^3\n'
fi

run_benchmark() {
    local ntasks="$1"
    local cpus_per_task="$2"
    local threads_per_task="$cpus_per_task"

    local local_volume initial_side nx ny nz_initial nz run_root run_dir
    # We need to scale the local problem size so that it uses ~25% total
    # memory when multiplied by the number of ranks
    local_volume=$(awk -v m="$MEM_TARGET_BYTES" \
        -v b="$BYTES_PER_EQUATION" \
        -v n="$ntasks" \
        'BEGIN { printf "%d", m / (b * n) }')
    
    # Start with cube close to target size
    initial_side=$(awk -v v="$local_volume" \
        'BEGIN { printf "%.4f", v ^ (1 / 3) }')
    
    # Intel HPCG problem size must be a multiple of 8
    nx=$(round_mult8 "$initial_side" "$CLAMP_PROB_SIZE")
    ny="$nx"
    # Find z s.t. xyz approx.= target problem size and xyz multiple of 8
    nz_initial=$(awk -v v="$local_volume" -v x="$nx" -v y="$ny" \
        'BEGIN { printf "%.4f", v / (x * y) }')
    nz=$(round_mult8 "$nz_initial" "$CLAMP_PROB_SIZE")

    run_dir=$(print_run_dir "$RUN_ROOT" "$ntasks" "$cpus_per_task" \
        "$threads_per_task")
    mkdir -p "$run_dir"
    write_hpcg_dat "$run_dir" "$nx" "$ny" "$nz" "$HPCG_RUN_TIME"
    
    SLURM_LAUNCH_ARGS=(
        --mem-bind=local
        --cpu-bind='verbose,cores'
        --ntasks="$ntasks"
        --cpus-per-task="$cpus_per_task"
    )

    export OMP_NUM_THREADS="$threads_per_task"
    export MKL_NUM_THREADS="$threads_per_task"

    MPI_ARGS=()
    case "$MPI_IMPL" in
        openmpi)
            MPI_ARGS+=(--host localhost:"$ntasks")
            MPI_ARGS+=(-np "$ntasks")
            MPI_ARGS+=(--map-by slot:PE="$cpus_per_task":HWTCPUS)
            MPI_ARGS+=(--bind-to hwthread)
            MPI_ARGS+=(-x FI_PROVIDER)
            MPI_ARGS+=(-x OMP_NUM_THREADS)
            MPI_ARGS+=(-x MKL_NUM_THREADS)
            if (( RUNNING_ON_GNR )); then
                MPI_ARGS+=(--mca btl 'self,sm')
            fi
            ;;
        intel)
            MPI_ARGS+=(-hosts localhost)
            MPI_ARGS+=(-n "$ntasks")
            MPI_ARGS+=(-genv I_MPI_PIN 1)
            MPI_ARGS+=(-genv I_MPI_PIN_CELL core)
            MPI_ARGS+=(-genv I_MPI_PIN_DOMAIN "$cpus_per_task")
            MPI_ARGS+=(-genv I_MPI_PIN_ORDER compact)
            MPI_ARGS+=(-genv I_MPI_DEBUG 5)
            MPI_ARGS+=(-genv KMP_AFFINITY granularity='fine,scatter')
            MPI_ARGS+=(-genvlist 'FI_PROVIDER,OMP_NUM_THREADS,MKL_NUM_THREADS')
            if (( RUNNING_ON_GNR )); then
                MPI_ARGS+=(-genv I_MPI_FABRICS shm)
            fi
            ;;
        *)
            printf "Not setting args for unsupported MPI implementation\n"
            ;;
    esac
    
    (
        cd "$run_dir" || exit 1
        run "$BINARY_PATH"
    )
}

for R in "${R_LIST[@]}"; do
    CPR=$((N_HW_CPU / R))
    if ! run_benchmark "$R" "$CPR"; then
        printf 'WARNING: run FAILED: ntasks=%u cpus_per_task=%u (see %s)' \
            "$R" "$CPR" "$FAILED_LOG"
        printf '%s ntasks=%u cpus_per_task=%u\n' \
                "$(date -u +%Y-%m-%dT%H%M%SZ)" "$R" "$CPR" \
                >> "$FAILED_LOG"
    fi
done
