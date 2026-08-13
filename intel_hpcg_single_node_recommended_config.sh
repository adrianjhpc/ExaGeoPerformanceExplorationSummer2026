#!/usr/bin/env bash
#SBATCH --job-name=ihpcgSN
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --hint=nomultithread
#SBATCH --cpus-per-task=24
#SBATCH --time=01:00:00
#SBATCH --nvram-options=none
set -euo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

module load compiler/2023.0.0
module load mkl/2023.0.0
module load mpi/2021.15

# Bytes per equation is ~715 on all the systems except Granite Rapids.
# It has ~839 BPE because I had to compile HPCG in ILP64 mode
# NTASKS is only used for mpirun, slurm uses ntasks. It should equal board
# socket count
# normal: 2
# icx: 2
# gnr: 2
NTASKS=2
# Use calc_hpcg_problem_size.py to get problem size
# normal: 328,328,328
# icx: 360,360,368
# gnr: 624,624,624
NX="${NX:-328}"
NY="${NY:-328}"
NZ="${NZ:-328}"
HPCG_RUN_TIME="${HPCG_RUN_TIME:-60}"

# XHPCG_SKX_PATH=/path/to/xhpcg_skx, or leave this commented out and set on 
# command line
XHPCG_SKX_PATH="${XHPCG_SKX_PATH:-$HOME/benchmarks/intel_hpcg/bin/xhpcg_skx}"
RUNNER="${RUNNER:-auto}" # auto, slurm, or mpi
# Set to 1 if you are testing on Granite Rapids
RUNNING_ON_GNR="${RUNNING_ON_GNR:-0}"

if [[ ! -x "$XHPCG_SKX_PATH" ]]; then
    printf "xhpcg_skx not executable at '%s'\n" "$XHPCG_SKX_PATH"
    exit 1
fi

# normal: 24
# icx: 28
# gnr: 120
export OMP_NUM_THREADS=24
export MKL_NUM_THREADS=24
export KMP_AFFINITY=granularity=fine,compact

MPI_WRAPPER=''
HPCG_COMMON=''
for _dir in \
    "${SLURM_SUBMIT_DIR:-}" \
    "$SCRIPT_DIR" \
    "$HOME/benchmarks"; do
    if [[ -f "$_dir/mpi_wrapper.sh" ]]; then
        MPI_WRAPPER="$_dir/mpi_wrapper.sh"
    fi
    if [[ -f "$_dir/hpcg_common.sh" ]]; then
        HPCG_COMMON="$_dir/hpcg_common.sh"
    fi
done

# shellcheck source=./mpi_wrapper.sh
source "$MPI_WRAPPER"
# shellcheck source=./hpcg_common.sh
source "$HPCG_COMMON"

mpi_configure_user() {
    MPI_ARGS=()
    case "$MPI_IMPL" in
        openmpi)
            MPI_ARGS+=(--host localhost)
            MPI_ARGS+=(-np "$NTASKS")
            MPI_ARGS+=(--map-by numa)
            MPI_ARGS+=(--bind-to numa)
            MPI_ARGS+=(--report-bindings)
            if (( RUNNING_ON_GNR )); then
                MPI_ARGS+=(--mca btl 'self,sm')
            fi
            ;;
        intel)
            MPI_ARGS+=(-hosts localhost)
            MPI_ARGS+=(-n "$NTASKS")
            MPI_ARGS+=(-genv I_MPI_PIN 1)
            MPI_ARGS+=(-genv I_MPI_PIN_DOMAIN numa)
            if (( RUNNING_ON_GNR )); then
                MPI_ARGS+=(-genv I_MPI_FABRICS shm)
            fi
            ;;
        *)
            mpi_die "unsupported MPI implementation: $MPI_IMPL"
            ;;
    esac
}

declare -a SLURM_LAUNCH_ARGS=(
    --mem-bind=local
    --cpu-bind='verbose,ldoms'
    --hint=nomultithread
)

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

RUN_ROOT=$(print_run_root "$PWD" "intel_nosweep_")
mkdir -p "$RUN_ROOT"

write_hpcg_dat "$RUN_ROOT" "$NX" "$NY" "$NZ" "$HPCG_RUN_TIME"

cd "$RUN_ROOT" || exit 1

run "$XHPCG_SKX_PATH"