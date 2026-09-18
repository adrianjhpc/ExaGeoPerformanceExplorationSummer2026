#!/usr/bin/env bash
#SBATCH --job-name=omb
#SBATCH --time=24:00:00
#SBATCH --nvram-options=none
set -euo pipefail

# AI disclosure: ~60% of this file was written by GLM-5.2
# ./run_omb.sh [host1[,host2,...]] # or set HOSTS
# if there are 0/1 hosts: collective, one-sided, pt2pt and startup groups (no
# congestion tests) are run. 0 hosts means run on localhost
# 2+ hosts: all of the above plus the congestion group, i.e. every
# benchmark
# Hosts from a Slurm allocation (srun/sbatch) take priority over HOSTS
# With Slurm, benchmarks are run via srun, otherwise directly through
# Intel MPI/Open MPI via mpi_wrapper.sh
# Environment overrides: RUNNER=auto|slurm|mpi, RANKS_PER_HOST=<n>, OMB=<dir>

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Manually load the MPI you need first!
# module load mpi/2021.15

module unload mpi mpich
module load libfabric/1.13.0
module load openmpi/5.0.10-GNU14.3.0

export FI_PROVIDER=verbs

# Get online physical core count for ranks/host if not specified
NCORES=$(
    for cpu in /sys/devices/system/cpu/cpu[0-9]*; do
        [[ "$(cat "$cpu/online" 2>/dev/null || printf "1\n")" = "1" ]] \
        || continue
        cat "$cpu/topology/thread_siblings_list"
    done | sort -u | wc -l
)
[[ "$NCORES" -gt 0 ]] || NCORES=1

OMB="${OMB:-$HOME/benchmarks/omb_7.5.2_build/libexec/osu-micro-benchmarks/mpi}"
RUNNER="${RUNNER:-auto}" # auto, slurm, or mpi
RANKS_PER_HOST="${RANKS_PER_HOST:-$NCORES}"
HOSTS="${1:-${HOSTS:-}}"

OUTDIR="omb_results_$(date -u +%Y-%m-%dT%H%M%SZ)"
mkdir -p "$OUTDIR"

if [[ ! $RANKS_PER_HOST =~ ^[1-9][0-9]*$ ]]; then
    printf 'RANKS_PER_HOST must be a positive integer\n' >&2
    exit 1
fi

MPI_WRAPPER=''
for _dir in "${SLURM_SUBMIT_DIR:-}" "$SCRIPT_DIR" "$HOME" "$HOME/benchmarks"
do
    if [[ -f $_dir/mpi_wrapper.sh ]]; then
        MPI_WRAPPER="$_dir/mpi_wrapper.sh"
        break
    fi
done
if [[ -z $MPI_WRAPPER ]]; then
    printf 'mpi_wrapper.sh not found\n' >&2
    exit 1
fi
# shellcheck source=./mpi_wrapper.sh
source "$MPI_WRAPPER"

# Hosts from a Slurm allocation take priority over HOSTS
if [[ -n ${SLURM_JOB_NODELIST:-} ]] && command -v scontrol > /dev/null 2>&1
then
    HOSTS_CSV="$(scontrol show hostnames "$SLURM_JOB_NODELIST" | paste -sd,)"
else
    HOSTS_CSV="$(mpi_normalise_hosts "$HOSTS")"
fi

if [[ -n $HOSTS_CSV ]]; then
    IFS=',' read -r -a HOST_LIST <<< "$HOSTS_CSV"
else
    HOST_LIST=(localhost)
fi

NHOSTS=${#HOST_LIST[@]}
if (( NHOSTS > 1 )); then
    TAG=inter
else
    TAG=intra
fi

# pt2pt/one-sided/startup tests need exactly two ranks (one per host)
# collective and congestion scale to all ranks
OMB_GROUPS=(collective one-sided pt2pt startup)
if (( NHOSTS > 1 )); then OMB_GROUPS+=(congestion); fi
FULL_RANK_GROUPS=' collective congestion '
TWO_RANKS=$((NHOSTS > 2 ? 2 : NHOSTS))

MPI_HOSTS="$HOSTS_CSV"

mpi_configure_user() {
    MPI_ARGS=()
    case "$MPI_IMPL" in
        openmpi)
            MPI_ARGS+=(-np "$MPI_NTASKS")
            MPI_ARGS+=(--map-by core)
            MPI_ARGS+=(--bind-to core)
            MPI_ARGS+=(-x FI_PROVIDER)
            if [[ -n $MPI_HOSTS ]]; then 
                MPI_ARGS+=(--host "$MPI_HOSTS")
            fi
            ;;
        intel)
            MPI_ARGS+=(-n "$MPI_NTASKS")
            MPI_ARGS+=(-genv I_MPI_PIN 1)
            MPI_ARGS+=(-genv I_MPI_PIN_DOMAIN core)
            MPI_ARGS+=(-genvlist FI_PROVIDER)
            if [[ -n $MPI_HOSTS ]]; then
                MPI_ARGS+=(-hosts "$MPI_HOSTS")
            fi
            ;;
        *)
            mpi_die "unsupported MPI implementation: $MPI_IMPL"
            ;;
    esac
}

declare -a SLURM_ARGS

set_launch() {
    local ranks=$1
    local per_host=$2
    SLURM_ARGS=(
        --nodes="$NHOSTS"
        --ntasks="$ranks"
        --ntasks-per-node="$per_host")
    if [[ -n $HOSTS_CSV ]]; then
        SLURM_ARGS+=(--nodelist="$HOSTS_CSV")
    fi
    MPI_NTASKS="$ranks"
}

run() {
    case "$RUNNER" in
        slurm)
            command -v srun > /dev/null 2>&1 ||
                { printf 'srun not found\n' >&2; return 1; }
            srun "${SLURM_ARGS[@]}" "$@"
            ;;
        mpi)
            mpi_run "$@"
            ;;
        auto)
            if command -v srun > /dev/null 2>&1; then
                srun "${SLURM_ARGS[@]}" "$@"
            else
                mpi_run "$@"
            fi
            ;;
        *)
            printf 'Invalid RUNNER=%s\n' "$RUNNER" >&2
            return 2
            ;;
    esac
}

{
    printf 'hostname: %s\n' "$(hostname -f)"
    printf 'TAG=%s HOSTS=%s RANKS_PER_HOST=%s OMB_GROUPS=%s\n' \
        "$TAG" "${HOSTS_CSV:-localhost}" "$RANKS_PER_HOST" "${OMB_GROUPS[*]}"
    printf 'SLURM_JOB_ID=%s\n' "${SLURM_JOB_ID:-}"
    if command -v srun > /dev/null 2>&1; then
        srun --version;
    fi
    if command -v mpiexec > /dev/null 2>&1; then
        mpiexec --version;
    fi
    lscpu
} > "$OUTDIR/run_info.txt"

printf 'Running %s benchmarks on %d host(s)\n' "$TAG" "$NHOSTS"
printf 'Groups: %s\n' "${OMB_GROUPS[*]}"
printf 'Results: %s\n' "$OUTDIR"

for group in "${OMB_GROUPS[@]}"; do
    if [[ ! -d $OMB/$group ]]; then
        printf 'Skipping missing group directory: %s/%s\n' "$OMB" "$group" >&2
        continue
    fi

    if [[ $FULL_RANK_GROUPS == *" $group "* ]]; then
        set_launch "$((NHOSTS * RANKS_PER_HOST))" "$RANKS_PER_HOST"
    else
        set_launch "$TWO_RANKS" 1
    fi

    for exe in "$OMB/$group"/osu_*; do
        if [[ ! -f $exe || ! -x $exe ]]; then continue; fi
        benchmark="$(basename "$exe")"
        printf '> %s (%s, %d ranks)\n' "$benchmark" "$TAG" "$MPI_NTASKS"
        if ! run "$exe" 2>&1 | \
            tee "$OUTDIR/${TAG}_${benchmark}_np${MPI_NTASKS}.txt"
        then
            printf 'FAILED: %s\n' "$exe"
        fi
    done
done

printf 'Done. Results are in %s\n' "$OUTDIR"
