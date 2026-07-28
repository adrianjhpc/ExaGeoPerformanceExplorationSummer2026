#!/usr/bin/env bash
#SBATCH --job-name=omb
#SBATCH --time=01:00:00
#SBATCH --nvram-options=none
set -euo pipefail

# Usage:
#   sbatch --nodes=1 --ntasks-per-node=4 run_omb.sh intra
#   sbatch --nodes=2 --ntasks-per-node=24 \
#       --nodelist=node01,node02 run_omb.sbatch inter node01,node02
# COLLECTIVE_NP can be specified using --export, e.g.
#   sbatch --export=ALL,COLLECTIVE_NP=48...

module load mpi/2021.15
# I'm not entirely sure why, but psm2 doesn't work when sceduling more than 1
# task per node. verbs doesn't have this problem
export FI_PROVIDER=verbs

MODE="${1:-intra}"
HOSTS="${2:-}"
COLLECTIVE_NP="${COLLECTIVE_NP:-4}"

OMB="${HOME}/benchmarks/omb_7.5.2_build/libexec/osu-micro-benchmarks/mpi"
UTC_NOW="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
OUTDIR="omb_results_${SLURM_JOB_ID}_${UTC_NOW}"
mkdir -p "$OUTDIR"

if [[ "$MODE" != intra && "$MODE" != inter ]]; then
    printf 'Usage: %s {intra|inter} [host1,host2]\n' "$0" >&2
    exit 1
fi

if [[ ! -d "$OMB" ]]; then
    printf 'OMB directory does not exist: %s\n' "$OMB" >&2
    exit 1
fi

if ! [[ "$COLLECTIVE_NP" =~ ^[1-9][0-9]*$ ]]; then
    printf 'COLLECTIVE_NP must be a positive integer\n' >&2
    exit 1
fi

if [[ "$MODE" == inter ]]; then
    if [[ -z "$HOSTS" ]]; then
        printf 'Inter-node mode requires two hosts, e.g. node01,node02\n' >&2
        exit 1
    fi

    IFS=',' read -r -a HOST_ARRAY <<< "$HOSTS"

    if (( ${#HOST_ARRAY[@]} != 2 )); then
        printf 'Inter-node mode requires exactly two comma-separated hosts\n' \
            >&2
        exit 1
    fi

    # Two ranks per point-to-point/RMA/startup test: one rank per host
    SRUN_BASE=(srun --nodelist="$HOSTS" --nodes=2 --ntasks=2 \
        --ntasks-per-node=1)

    TAG=inter
else
    # Both ranks are placed on the first allocated node.
    SRUN_BASE=(srun --nodes=1 --ntasks=2 --ntasks-per-node=2)

    TAG=intra
fi

if [[ "$MODE" == inter ]]; then
    if (( COLLECTIVE_NP % 2 != 0 )); then
        printf 'COLLECTIVE_NP must be even in inter mode\n' >&2
        exit 1
    fi

    COLLECTIVE_SRUN=(srun --nodelist="$HOSTS" --nodes=2
        --ntasks="$COLLECTIVE_NP"
        --ntasks-per-node="$((COLLECTIVE_NP / 2))")
else
    COLLECTIVE_SRUN=(srun --nodes=1 --ntasks="$COLLECTIVE_NP")
fi

{
    printf 'hostname -f\n'
    hostname -f
    printf 'MODE=%s\n' "$MODE"
    printf 'HOSTS=%s\n' "${HOSTS:-allocated node}"
    printf 'COLLECTIVE_NP=%s\n' "$COLLECTIVE_NP"
    printf 'SLURM_JOB_ID=%s\n' "$SLURM_JOB_ID"
    printf '\nAllocated nodes:\n'
    scontrol show hostnames "$SLURM_JOB_NODELIST"

    printf '\nMPI-related environment:\n'
    command -v srun
    srun --version

    printf '\nCPU information:\n'
    lscpu
} > "$OUTDIR/run_info.txt"

run_two_rank_benchmark()
{
    local category="$1"
    local benchmark="$2"
    local output="$OUTDIR/${TAG}_${benchmark}.txt"
    local executable="$OMB/$category/$benchmark"

    if [[ ! -x "$executable" ]]; then
        printf 'Missing executable: %s\n' "$executable" >&2
        return 1
    fi

    printf '> %s (%s)\n' "$benchmark" "$TAG"
    "${SRUN_BASE[@]}" "$executable" 2>&1 | tee "$output"
}

run_collective()
{
    local benchmark="$1"
    local output="$OUTDIR/${TAG}_${benchmark}_np${COLLECTIVE_NP}.txt"
    local executable="$OMB/collective/$benchmark"

    if [[ ! -x "$executable" ]]; then
        printf 'Missing executable: %s\n' "$executable" >&2
        return 1
    fi

    printf '> %s (%s, %s ranks)\n' \
        "$benchmark" "$TAG" "$COLLECTIVE_NP"

    "${COLLECTIVE_SRUN[@]}" "$executable" 2>&1 | tee "$output"
}

printf 'Running %s benchmarks\n' "$MODE"
printf 'Results: %s\n' "$OUTDIR"

# Point-to-point
for benchmark in osu_latency osu_bw osu_bibw osu_mbw_mr; do
    run_two_rank_benchmark pt2pt "$benchmark"
done

# MPI one-sided
for benchmark in osu_put_latency osu_get_latency osu_put_bw osu_get_bw; do
    run_two_rank_benchmark one-sided "$benchmark"
done

# MPI startup
for benchmark in osu_init osu_hello; do
    run_two_rank_benchmark startup "$benchmark"
done

# Collectives
for benchmark in \
    osu_allreduce \
    osu_bcast \
    osu_barrier \
    osu_allgather \
    osu_alltoall \
    osu_reduce
do
    run_collective "$benchmark"
done

printf 'Done. Results are in %s\n' "$OUTDIR"
