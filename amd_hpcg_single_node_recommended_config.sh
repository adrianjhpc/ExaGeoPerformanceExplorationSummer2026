#!/usr/bin/env bash
set -euo pipefail

module unload mpi

printf "Please remember to set the correct problem size in hpcg.dat!\n"
printf "It can be found by running 'spack cd -i hpcg %%aocc'\n"

spack load hpcg %aocc
loc=$(spack location -i aocc)
spack cd -i hpcg

CORES_PER_CCX=4
NUM_CORES=$(nproc)

export OMP_PROC_BIND=true
export OMP_PLACES=cores
export OMP_NUM_THREADS=2

DIV_SMT=1
if [[ $(cat /sys/devices/system/cpu/smt/active) == "1" ]]; then
    DIV_SMT=2
fi

NUM_MPI_RANKS=$(( NUM_CORES / OMP_NUM_THREADS / DIV_SMT ))
RANKS_PER_CCX=$(( CORES_PER_CCX / OMP_NUM_THREADS ))

export LD_LIBRARY_PATH="$loc/lib:$LD_LIBRARY_PATH"
mpirun -np $NUM_MPI_RANKS --bind-to core \
    --map-by "ppr:$RANKS_PER_CCX:l3cache:pe=$OMP_NUM_THREADS" ./bin/xhpcg