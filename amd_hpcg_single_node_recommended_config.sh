#!/usr/bin/env bash
set -euo pipefail

# Make sure we don't use Intel MPI, spack will load OpenMPI for us
module unload mpi openmpi mpich

# Bytes per equation is ~715 on amd01
# Problem size is hardcoded for nextgenio-amd01 which free reports as having
# 270269554688 bytes of memory capacity
NX="${NX:-144}"
NY="${NY:-144}"
NZ="${NZ:-144}"
HPCG_RUN_TIME="${HPCG_RUN_TIME:-60}"

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

AOCC_LOC=$(spack location -i aocc)
HPCG_LOC=$(spack location -i hpcg)

# This is the correct value for the EPYC 7502, despite AMD's HPCG docs
# suggesting otherwise
# https://www.nas.nasa.gov/hecc/support/kb/amd-rome-processors_658.html
CORES_PER_CCX=4
NUM_CORES=$(nproc)

export OMP_PROC_BIND=true
export OMP_PLACES=cores
export OMP_NUM_THREADS=2

DIV_SMT=1
# I don't have permission to disable SMT on amd01, so divide number of 
# available cores by 2 if SMT is on
if [[ $(cat /sys/devices/system/cpu/smt/active) == "1" ]]; then
    DIV_SMT=2
fi

NUM_MPI_RANKS=$(( NUM_CORES / OMP_NUM_THREADS / DIV_SMT ))
RANKS_PER_CCX=$(( CORES_PER_CCX / OMP_NUM_THREADS ))

RUN_ROOT=$(print_run_root "$PWD" "amd_nosweep_")
mkdir -p "$RUN_ROOT"

write_hpcg_dat "$RUN_ROOT" "$NX" "$NY" "$NZ" "$HPCG_RUN_TIME"

spack load hpcg %aocc

cd "$RUN_ROOT" || exit 1
export LD_LIBRARY_PATH="$AOCC_LOC/lib:$LD_LIBRARY_PATH"
mpirun -np $NUM_MPI_RANKS --bind-to core \
    --map-by "ppr:$RANKS_PER_CCX:l3cache:pe=$OMP_NUM_THREADS" \
    "${HPCG_LOC}/bin/xhpcg"