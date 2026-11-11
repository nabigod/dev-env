#!/bin/bash

# Descendants are found through /proc because ps is not a permitted dependency.
# Only Linux is supported; elsewhere no descendant is ever reported.
DEVENV_PROCESS_DESCENDANTS=()

# Fills DEVENV_PROCESS_DESCENDANTS with live descendants of the given pid.
# Runs without forking so it can be called from a signal handler.
process_collect_descendants() {
    local root_pid="$1"
    local stat_file stat_line process_id after_name parent_id changed index
    local -a all_pids all_parent_pids
    local -A known_pids
    all_pids=()
    all_parent_pids=()
    known_pids=()
    DEVENV_PROCESS_DESCENDANTS=()

    for stat_file in /proc/[0-9]*/stat; do
        read -r stat_line 2>/dev/null < "$stat_file" || continue
        process_id="${stat_file#/proc/}"
        process_id="${process_id%/stat}"
        # The command name may contain spaces and parentheses; skip past the last ") ".
        after_name="${stat_line##*) }"
        # Zombies are already dead and are only waiting to be reaped.
        [[ "${after_name%% *}" != Z ]] || continue
        parent_id="${after_name#* }"
        parent_id="${parent_id%% *}"
        all_pids[${#all_pids[@]}]="$process_id"
        all_parent_pids[${#all_parent_pids[@]}]="$parent_id"
    done

    known_pids["$root_pid"]=1
    changed=true
    while [[ "$changed" == true ]]; do
        changed=false
        for ((index = 0; index < ${#all_pids[@]}; index++)); do
            [[ -z "${known_pids[${all_pids[index]}]+set}" ]] || continue
            [[ -n "${known_pids[${all_parent_pids[index]}]+set}" ]] || continue
            known_pids["${all_pids[index]}"]=1
            DEVENV_PROCESS_DESCENDANTS[${#DEVENV_PROCESS_DESCENDANTS[@]}]="${all_pids[index]}"
            changed=true
        done
    done
}

process_signal_descendants() {
    local signal_name="$1"
    local index
    for ((index = 0; index < ${#DEVENV_PROCESS_DESCENDANTS[@]}; index++)); do
        kill "-$signal_name" "${DEVENV_PROCESS_DESCENDANTS[index]}" 2>/dev/null || true
    done
}

# Asks every descendant of the given pid to terminate, then kills survivors
# after a grace period (about 5 seconds). Returns 1 if some descendant remains.
process_terminate_descendants() {
    local root_pid="$1"
    local wait_tick
    process_collect_descendants "$root_pid"
    [[ "${#DEVENV_PROCESS_DESCENDANTS[@]}" -gt 0 ]] || return 0
    process_signal_descendants TERM
    for ((wait_tick = 0; wait_tick < 50; wait_tick++)); do
        process_collect_descendants "$root_pid"
        [[ "${#DEVENV_PROCESS_DESCENDANTS[@]}" -gt 0 ]] || return 0
        sleep 0.1
    done
    process_signal_descendants KILL
    sleep 0.1
    process_collect_descendants "$root_pid"
    [[ "${#DEVENV_PROCESS_DESCENDANTS[@]}" -eq 0 ]]
}
