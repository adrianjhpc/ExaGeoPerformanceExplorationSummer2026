#!/usr/bin/env bash
#SBATCH --job-name=ihpcgSN
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --hint=nomultithread
#SBATCH --cpus-per-task=24
#SBATCH --time=01:00:00
#SBATCH --nvram-options=none
set -euo pipefail

module load compiler/2023.0.0
module load mkl/2023.0.0
module load mpi/2021.15

# Bytes per equation is ~715 on normal partition nextgenio compute nodes
# free reports these as having 201326981120 bytes of memory capacity
NX="${NX:-328}"
NY="${NY:-328}"
NZ="${NZ:-328}"
HPCG_RUN_TIME="${HPCG_RUN_TIME:-60}"

# XHPCG_SKX_PATH=/path/to/xhpcg_skx, or leave this commented out and set on 
# command line
XHPCG_SKX_PATH="${XHPCG_SKX_PATH:-$HOME/benchmarks/intel_hpcg/bin/xhpcg_skx}"

if [[ ! -x "$XHPCG_SKX_PATH" ]]; then
    printf "xhpcg_skx not executable at '%s'\n" "$XHPCG_SKX_PATH"
    exit 1
fi

export OMP_NUM_THREADS=24
# export MKL_NUM_THREADS=24
# export OMP_PROC_BIND=close
# export OMP_PLACES=cores
export KMP_AFFINITY=granularity=fine,compact

HPCG_COMMON=""
for _dir in \
    "${SLURM_SUBMIT_DIR:-}" \
    "$(dirname "${BASH_SOURCE[0]}")" \
    "$HOME/benchmarks"; do
    if [[ -f "$_dir/hpcg_common.sh" ]]; then
        HPCG_COMMON="$_dir/hpcg_common.sh"
        break
    fi
done

if [[ -z "$HPCG_COMMON" ]]; then
    printf 'ERROR: hpcg_common.sh not found.\n' >&2
    exit 1
fi

# shellcheck source=./hpcg_common.sh
source "$HPCG_COMMON"

RUN_ROOT=$(print_run_root "$PWD" "intel_nosweep_")
mkdir -p "$RUN_ROOT"

write_hpcg_dat "$RUN_ROOT" "$NX" "$NY" "$NZ" "$HPCG_RUN_TIME"

cd "$RUN_ROOT" || exit 1

srun --cpu-bind=verbose --mem-bind=local "$XHPCG_SKX_PATH"