#!/usr/bin/env bash
# AI disclosure: ~90% of this file was written by GPT 5.6 Luna
# mpi_wrapper.sh
# Examples:
#   ./mpi_wrapper.sh --np 8 --hosts node01,node02 -- ./program arg1
#
#   ./mpi_wrapper.sh \
#       --mpi openmpi \
#       --openmpi-hostfile hosts.openmpi \
#       --diagnose
#
#   MPI_IMPL=intel MPI_NTASKS=16 \
#       ./mpi_wrapper.sh --intel-hostfile hosts.intel -- ./program
#
# As a sourced library:
#   source ./mpi_wrapper.sh
#   mpi_run --np 8 --hosts node01,node02 -- ./program

###############################################################################
# Configuration
###############################################################################
# Declare these in sourcing script before sourcing if you want to use a
# different value
FI_PROVIDER="${FI_PROVIDER:-verbs}"
export FI_PROVIDER

MPI_IMPL="${MPI_IMPL:-auto}"
MPI_LAUNCHER="${MPI_LAUNCHER:-}"

MPI_NTASKS="${MPI_NTASKS:-${SLURM_NTASKS:-1}}"

MPI_HOSTS=''
MPI_HOSTFILE=''
MPI_OPENMPI_HOSTFILE=''
MPI_INTEL_HOSTFILE=''

MPI_VERBOSE="${MPI_VERBOSE:-0}"

# This is populated in mpi_configure()
declare -a MPI_ARGS

###############################################################################
# Utility functions
###############################################################################

mpi_die() {
    printf 'mpi_wrapper: error: %s\n' "${*}" >&2
    exit 2
}

mpi_log() {
    (( MPI_VERBOSE )) && printf 'mpi_wrapper: %s\n' "${*}" >&2
    return 0
}

mpi_require_command() {
    command -v "$1" >/dev/null 2>&1 ||
        mpi_die "required command not found: $1"
}

mpi_count_hosts() {
    local hosts="$1"
    local count=0
    local host
    local -a host_array

    IFS=',' read -ra host_array <<< "$hosts"

    for host in "${host_array[@]}"; do
        [[ -n "$host" ]] && ((++count))
    done

    printf '%s\n' "$count"
}

mpi_normalise_hosts() {
    # Convert whitespace or comma-separated hosts to comma-separated
    local input="$1"

    input="${input//,/ }"

    awk '
        NF {
            for (i = 1; i <= NF; i++) {
                if (out != "") out = out ","
                out = out $i
            }
        }
        END { print out }
    ' <<< "$input"
}

###############################################################################
# MPI implementation detection
###############################################################################

mpi_find_launcher() {
    if [[ -n "$MPI_LAUNCHER" ]]; then
        command -v "$MPI_LAUNCHER" >/dev/null 2>&1 ||
            mpi_die "MPI launcher not found: $MPI_LAUNCHER"
        return
    fi

    if command -v mpiexec >/dev/null 2>&1; then
        MPI_LAUNCHER="$(command -v mpiexec)"
    elif command -v mpirun >/dev/null 2>&1; then
        MPI_LAUNCHER="$(command -v mpirun)"
    else
        mpi_die 'neither mpiexec nor mpirun was found'
    fi
}

mpi_detect_implementation() {
    mpi_find_launcher

    if [[ "$MPI_IMPL" != auto ]]; then
        case "$MPI_IMPL" in
            openmpi|intel) return 0 ;;
            *) mpi_die "unsupported MPI implementation: $MPI_IMPL" ;;
        esac
    fi

    local version
    version=$("$MPI_LAUNCHER" --version 2>&1 || true)

    if grep -Eiq 'Open MPI|OpenMPI' <<< "$version"; then
        MPI_IMPL='openmpi'
    elif grep -Eiq 'Intel.*MPI|Intel\(R\).*MPI|Intel MPI' <<< "$version"; then
        MPI_IMPL='intel'
    else
        printf '%s\n' "$version" >&2
        local msg='could not detect MPI implementation; use --mpi openmpi or '
        msg+='--mpi intel'
        mpi_die "$msg"
    fi

    mpi_log "detected MPI implementation: $MPI_IMPL"
    mpi_log "launcher: $MPI_LAUNCHER"
}

###############################################################################
# Hostfile handling
###############################################################################

mpi_select_hostfile() {
    case "$MPI_IMPL" in
        openmpi)
            MPI_HOSTFILE="${MPI_OPENMPI_HOSTFILE:-}"
            ;;
        intel)
            MPI_HOSTFILE="${MPI_INTEL_HOSTFILE:-}"
            ;;
    esac

    [[ -z "$MPI_HOSTS" && -z "$MPI_HOSTFILE" ]] && return 0

    if [[ -n "$MPI_HOSTS" && -n "$MPI_HOSTFILE" ]]; then
        mpi_die "use either --hosts or a hostfile, not both"
    fi
}

mpi_validate_hostfile() {
    local file="$1"
    local line
    local host
    local slots
    local line_number=0
    local found=0

    [[ -f "$file" ]] || mpi_die "hostfile does not exist: $file"
    [[ -r "$file" ]] || mpi_die "hostfile is not readable: $file"

    while IFS= read -r line || [[ -n "$line" ]]; do
        ((++line_number))

        # Remove comments and surrounding whitespace
        line="${line%%#*}"
        line="$(sed 's/^[[:space:]]*//;s/[[:space:]]*$//' <<< "$line")"

        [[ -z "$line" ]] && continue

        # Accepted syntax:
        # node01
        # node01 slots=8
        read -r host slots extra <<< "$line"

        [[ -n "$host" && -z "$extra" ]] ||
            mpi_die "unsupported syntax in $file at line $line_number: $line"

        [[ "$host" =~ ^[A-Za-z0-9_.-]+$ ]] ||
            mpi_die "invalid hostname in $file at line $line_number: $host"

        if [[ -n "$slots" && ! "$slots" =~ ^slots=[1-9][0-9]*$ ]]; then
            local msg="invalid slot specification in $file at line "
            msg+="$line_number: $slots"
            mpi_die "$msg"
        fi

        found=1
    done < "$file"

    (( found )) || mpi_die "hostfile is empty: $file"

    mpi_log "validated hostfile for $MPI_IMPL: $file"
}

mpi_validate_hosts() {
    local hosts="$1"
    local host
    local -a host_array

    [[ -n "$hosts" ]] || mpi_die "empty host list"

    IFS=',' read -ra host_array <<< "$hosts"

    for host in "${host_array[@]}"; do
        [[ "$host" =~ ^[A-Za-z0-9_.-]+$ ]] ||
            mpi_die "invalid hostname: $host"
    done

    mpi_log "validated host list: $hosts"
}

###############################################################################
# MPI-specific configuration
###############################################################################

mpi_configure_default() {
    case "$MPI_IMPL" in
        openmpi)
            if [[ -n "$MPI_HOSTS" ]]; then
                MPI_ARGS+=(--host "$MPI_HOSTS")
            elif [[ -n "$MPI_HOSTFILE" ]]; then
                MPI_ARGS+=(--hostfile "$MPI_HOSTFILE")
            fi

            MPI_ARGS+=(--map-by numa)
            MPI_ARGS+=(--bind-to numa)
            MPI_ARGS+=(--report-bindings)
            ;;
        intel)
            if [[ -n "$MPI_HOSTS" ]]; then
                MPI_ARGS+=(-hosts "$MPI_HOSTS")
            elif [[ -n "$MPI_HOSTFILE" ]]; then
                MPI_ARGS+=(-f "$MPI_HOSTFILE")
            fi

            MPI_ARGS+=(-genv I_MPI_PIN 1)
            MPI_ARGS+=(-genv I_MPI_PIN_DOMAIN numa)
            MPI_ARGS+=(-genv I_MPI_DEBUG 5)
            ;;
        *)
            mpi_die "unsupported MPI implementation: $MPI_IMPL"
            ;;
    esac
}

mpi_configure() {
    # Common preparation remains the wrapper's responsibility
    mpi_detect_implementation
    mpi_select_hostfile

    if [[ -n "$MPI_HOSTFILE" ]]; then
        mpi_validate_hostfile "$MPI_HOSTFILE"
    elif [[ -n "$MPI_HOSTS" ]]; then
        mpi_validate_hosts "$MPI_HOSTS"
    fi

    if declare -F mpi_configure_user >/dev/null 2>&1; then
        mpi_configure_user
    else
        mpi_configure_default
    fi
}

###############################################################################
# Diagnostics
###############################################################################

mpi_diagnostic_command() {
    cat <<'EOF'
printf 'host=%s pid=%s\n' "$(hostname)" "$$"
if command -v taskset >/dev/null 2>&1; then
    taskset -pc "$$" 2>&1
fi
awk '/Cpus_allowed_list/ {print}' /proc/self/status 2>/dev/null || true
if command -v numactl >/dev/null 2>&1; then
    numactl --show 2>&1 || true
fi
EOF
}

mpi_diagnose() {
    local diagnostic_np="${MPI_NTASKS:-1}"
    local -a args=()

    args=(-n "$diagnostic_np")

    case "$MPI_IMPL" in
        openmpi)
            [[ -n "$MPI_HOSTS" ]] &&
                args+=(--host "$MPI_HOSTS")
            [[ -n "$MPI_HOSTFILE" ]] &&
                args+=(--hostfile "$MPI_HOSTFILE")

            args+=(--map-by numa --bind-to numa --report-bindings)
            ;;
        intel)
            [[ -n "$MPI_HOSTS" ]] &&
                args+=(-hosts "$MPI_HOSTS")
            [[ -n "$MPI_HOSTFILE" ]] &&
                args+=(-f "$MPI_HOSTFILE")

            args+=(-genv I_MPI_DEBUG 5)
            ;;
    esac

    printf "+ %s %s bash -c '<diagnostic command>'\n" "$MPI_LAUNCHER" \
        "${args[*]}" >&2

    "$MPI_LAUNCHER" "${args[@]}" bash -c "$(mpi_diagnostic_command)"
}

###############################################################################
# Generic execution
###############################################################################

mpi_run() {
    [[ "$#" -gt 0 ]] || mpi_die "mpi_run requires a program"

    mpi_configure

    printf "+ %s %s %s\n" "$MPI_LAUNCHER" "${MPI_ARGS[*]}" "${*}" >&2

    "$MPI_LAUNCHER" "${MPI_ARGS[@]}" "$@"
}

###############################################################################
# Command-line interface
###############################################################################

mpi_usage() {
    cat <<'EOF'
Usage:
  mpi_wrapper.sh [options] -- PROGRAM [ARGS...]

Options:
  --mpi IMPL                  auto, openmpi, or intel
  --np N                      number of MPI ranks
  --hosts HOST1,HOST2         hosts supplied on command line
  --openmpi-hostfile FILE     Open MPI hostfile
  --intel-hostfile FILE       Intel MPI hostfile
  --diagnose                  run hostname/affinity diagnostics
  --verbose                   print additional information
  --help                      show this help

Examples:
  ./mpi_wrapper.sh --np 8 --hosts node01,node02 -- ./program input.dat

  ./mpi_wrapper.sh --mpi openmpi \
      --openmpi-hostfile hosts.openmpi \
      --diagnose

  MPI_IMPL=intel ./mpi_wrapper.sh \
      --intel-hostfile hosts.intel \
      --np 16 -- ./program
EOF
}

mpi_main() {
    local diagnose=0
    local -a program=()

    while [[ "$#" -gt 0 ]]; do
        case "$1" in
            --mpi)
                [[ "$#" -ge 2 ]] || mpi_die "--mpi requires an argument"
                MPI_IMPL="$2"
                shift 2
                ;;
            --np)
                [[ "$#" -ge 2 ]] || mpi_die "--np requires an argument"
                MPI_NTASKS="$2"
                shift 2
                ;;
            --hosts)
                [[ "$#" -ge 2 ]] || mpi_die "--hosts requires an argument"
                MPI_HOSTS="$(mpi_normalise_hosts "$2")"
                shift 2
                ;;
            --openmpi-hostfile)
                local msg="--openmpi-hostfile requires a file"
                [[ "$#" -ge 2 ]] || mpi_die "$msg"
                MPI_OPENMPI_HOSTFILE="$2"
                shift 2
                ;;
            --intel-hostfile)
                [[ "$#" -ge 2 ]] || mpi_die "--intel-hostfile requires a file"
                MPI_INTEL_HOSTFILE="$2"
                shift 2
                ;;
            --diagnose)
                diagnose=1
                shift
                ;;
            --verbose)
                MPI_VERBOSE=1
                shift
                ;;
            --help|-h)
                mpi_usage
                return 0
                ;;
            --)
                shift
                program=("$@")
                break
                ;;
            *)
                mpi_die "unknown option: $1"
                ;;
        esac
    done

    mpi_configure

    if (( diagnose )); then
        mpi_diagnose
    fi

    if [[ "${#program[@]}" -gt 0 ]]; then
        mpi_run "${program[@]}"
    elif (( ! diagnose )); then
        mpi_usage >&2
        return 2
    fi
}

# Do not execute the CLI when this file is sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    mpi_main "$@"
fi
