#!/usr/bin/env bash
#SBATCH --job-name=ihpcgSNS
#SBATCH --exclusive
#SBATCH --nodes=1
#SBATCH --ntasks=2
#SBATCH --ntasks-per-socket=1
#SBATCH --cpus-per-task=24
#SBATCH --time=01:00:00
#SBATCH --nvram-options=none
set -euo pipefail

module load compiler/2023.0.0
module load mkl/2023.0.0
module load mpi/2021.15

export OMP_NUM_THREADS=24
export MKL_NUM_THREADS=24
export OMP_PROC_BIND=close
export OMP_PLACES=cores

# XHPCG_SKX_PATH=/path/to/xhpcg_skx, or leave this commented out and set on 
# command line
XHPCG_SKX_PATH="${XHPCG_SKX_PATH:-./xhpcg_skx}"

printf "Please remember to set the correct problem size in hpcg.dat!\n"

srun --cpu-bind=verbose,ldoms "$XHPCG_SKX_PATH"