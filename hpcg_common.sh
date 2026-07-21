#!/usr/bin/env bash

print_run_root() {
    local prefix="${1:-$PWD}"
    local tag="${2:-}"
    local utc_now
    utc_now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    local run_root="${prefix}/{$tag}hpcg_run_${utc_now}"
    printf "%s\n" "$run_root"
}

print_run_dir() {
    local run_root="$1"
    local ntasks="$2"
    local cpus_per_task="$3"
    local threads_per_task="$4"
    local run_dir="${run_root}/${ntasks}tsk_${cpus_per_task}cpu_"
    run_dir+="${threads_per_task}thd"
    printf "%s\n" "$run_dir"
}

write_hpcg_dat() {
    local target_dir="$1"
    local nx="$2"
    local ny="$3"
    local nz="$4"
    local time="$5"

    if [[ -z "${target_dir}" || \
          -z "${nx}" || -z "${ny}" || -z "${nz}" || -z "${time}" ]]; then
        printf "Usage: write_hpcg_dat <target_dir> <nx> <ny> <nz> <time>\n" >&2
        return 1
    fi

    if ! [[ "${nx}" =~ ^[0-9]+$ && "${ny}" =~ ^[0-9]+$ && \
            "${nz}" =~ ^[0-9]+$ && "${time}" =~ ^[0-9]+$ ]]; then
        printf "Error: nx, ny, nz, and time must be positive integers.\n" >&2
        return 1
    fi

    if ! mkdir -p "${target_dir}"; then
        printf "Error: could not create or access directory '%s'." \
            "${target_dir}" >&2
        return 1
    fi

    local filepath="${target_dir}/hpcg.dat"
    cat > "${filepath}" <<EOF
HPCG benchmark input file
Sandia National Laboratories; University of Tennessee, Knoxville
${nx} ${ny} ${nz}
${time}
EOF

    if [[ $? -ne 0 ]]; then
        printf "Error: failed to write '%s'.\n", "${filepath}" >&2
        return 1
    fi
}