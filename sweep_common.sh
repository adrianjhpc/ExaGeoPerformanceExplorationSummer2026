#!/usr/bin/env bash
# AI disclosure: original human written code in this file has been heavily
# refactored by GLM-5.2
# Generic single-node task/CPU sweep
# The sourcing script MUST define:
#   MAX_TOTAL_CPUS:    logical CPU capacity of the node
#   MAX_TOTAL_THREADS: max OpenMP threads (often == MAX_TOTAL_CPUS)
#   run_benchmark():   function called as:
#       run_benchmark <ntasks> <cpus-per-task> <threads-per-task>
#
# Optional:
#   ENABLE_OVERSUBSCRIPTION=1: also sweep threads > cpus (phase 2)

# Generate divisors of max CPU count so that max total CPUs is always divisible
# by ntasks * nthreads
# e.g. gen_task_list 96 96 -> 1 2 3 4 6 8 12 16 24 32 48 96
gen_task_list() {
    local max_total_cpus="$1"
    local max_total_threads="$2"
    local v

    for (( v = 1; v <= max_total_cpus; v++ )); do
        if (( max_total_cpus % v == 0 && max_total_threads % v == 0 )); then
            printf '%s ' "$v"
        fi
    done
}

# Validate a single combination and print what we're about to run.
# Returns 1 on any validation failure
validate_and_print() {
    local ntasks="$1"
    local cpus_per_task="$2"
    local threads_per_task="$3"

    local total_cpus=$(( ntasks * cpus_per_task ))
    local total_threads=$(( ntasks * threads_per_task ))

    if (( ntasks < 1 )); then
        printf "ERROR: ntasks must be >= 1\n" >&2
        return 1
    fi
    if (( cpus_per_task < 1 )); then
        printf "ERROR: cpus-per-task must be >= 1\n" >&2
        return 1
    fi
    if (( threads_per_task < 1 )); then
        printf "ERROR: threads-per-task must be >= 1\n" >&2
        return 1
    fi
    # MAX_TOTAL_CPUS defined by sourcing script
    # shellcheck disable=SC2153
    if (( total_cpus > MAX_TOTAL_CPUS )); then
        printf "ERROR: requested CPUs exceed limit: %u > %u\n" \
            "$total_cpus" "$MAX_TOTAL_CPUS" >&2
        return 1
    fi
    # MAX_TOTAL_THREADS defined by sourcing script
    # shellcheck disable=SC2153
    if (( total_threads > MAX_TOTAL_THREADS )); then
        printf "ERROR: total OpenMP threads exceed limit: %u > %u\n" \
            "$total_threads" "$MAX_TOTAL_THREADS" >&2
        return 1
    fi
    if (( threads_per_task < cpus_per_task )); then
        printf "ERROR: threads-per-task must be >= cpus-per-task: %u < %u\n" \
            "$threads_per_task" "$cpus_per_task" >&2
        return 1
    fi

    local m='\nRunning: %u rank(s), %u CPU(s)/rank, %u thread(s)/rank, '
         m+='%u total CPU(s), %u total thread(s)\n'
    # m is a format string
    # shellcheck disable=SC2059
    printf "$m" "$ntasks" "$cpus_per_task" "$threads_per_task" "$total_cpus" \
        "$total_threads"
}

# Iterate all the same task/cpus-per-task combinations for any
# benchmark script that has a run_benchmark() function
run_sweep() {
    if ! declare -f run_benchmark >/dev/null 2>&1; then
        printf "ERROR: run_benchmark() is not defined. "
        printf "Define it before calling run_sweep.\n" >&2
        return 1
    fi

    local n_tasks_list
    n_tasks_list=$(gen_task_list "$MAX_TOTAL_CPUS" "$MAX_TOTAL_THREADS")

    for ntasks in $n_tasks_list; do
        local max_cpus_per_task=$(( MAX_TOTAL_CPUS / ntasks ))
        local max_threads_per_task=$(( MAX_TOTAL_THREADS / ntasks ))

        printf "\n"
        printf "============================================================\n"
        printf "ntasks=%u, max_cpus_per_task=%u, max_threads_per_task=%u\n" \
               "$ntasks" "$max_cpus_per_task" "$max_threads_per_task"
        printf "============================================================\n"

        # Phase 1: cpus_per_task == threads_per_task (no oversubscription)
        local cpt
        for (( cpt = 1; cpt <= max_cpus_per_task; cpt++ )); do
            validate_and_print "$ntasks" "$cpt" "$cpt" || continue
            if ! run_benchmark "$ntasks" "$cpt" "$cpt"; then
                local msg='WARNING: run FAILED: ntasks=%u cpus_per_task=%u'
                msg+='threads_per_task=%u (see %s)\n'
                # msg is a format string
                # shellcheck disable=SC2059
                printf "$msg" \
                "$ntasks" "$cpt" "$cpt" "${FAILED_LOG:-failed_runs.log}" >&2
                printf '%s ntasks=%u cpus_per_task=%u threads_per_task=%u\n' \
                "$(date -u +%Y-%m-%dT%H%M%SZ)" "$ntasks" "$cpt" "$cpt" \
                >> "${FAILED_LOG:-failed_runs.log}"
            fi
        done

        # Phase 2 (optional): keep CPUs at max, oversubscribe threads
        if [[ "${ENABLE_OVERSUBSCRIPTION:-0}" == "1" ]]; then
            local tpt
            for (( tpt = max_cpus_per_task + 1; \
                   tpt <= max_threads_per_task; \
                   tpt++ )); do
                validate_and_print "$ntasks" "$max_cpus_per_task" "$tpt" \
                    || continue
                run_benchmark "$ntasks" "$max_cpus_per_task" "$tpt"
            done
        fi
    done
}

# Resolve a benchmark binary path.
#
# Usage: resolve_binary <env_var_name> <default_path>
#
# If the environment variable is set and non-empty, use that.
# Otherwise fall back to <default_path>.
# In either case, warn if the resolved path does not exist
# or is not executable.
#
# Prints the resolved path to stdout (capture with $(...) or use
# the global RESOLVED_BINARY)
resolve_binary() {
    local env_var="$1"
    local default_path="$2"
    local resolved

    resolved="${!env_var:-$default_path}"

    if [[ -z "$resolved" ]]; then
        printf 'WARNING: %s is not set and no default was provided.\n' \
            "$env_var" >&2
        printf 'Set it with: export %s=/path/to/binary\n' "$env_var" >&2
        return 1
    fi

    if [[ ! -x "$resolved" ]]; then
        printf 'WARNING: benchmark binary not found or not executable: %s\n' \
            "$resolved" >&2
        printf 'Set %s to the correct path.\n' "$env_var" >&2
        printf 'Example: \n'
        # shellcheck disable=SC2016
        printf 'sbatch --export=ALL,%s="~/distributed_streams" ...\n' \
            "$env_var" >&2
        return 1
    fi

    # RESOLVED_BINARY used by sourcing script
    # shellcheck disable=SC2034
    RESOLVED_BINARY="$resolved"
    printf '%s\n' "$resolved"
}
