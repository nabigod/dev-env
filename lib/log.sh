#!/bin/bash

DEVENV_LOG_WARN_COUNT=0
DEVENV_LOG_ERROR_COUNT=0
DEVENV_SUMMARY_COUNT=0
declare -a DEVENV_SUMMARY_NAMES
declare -a DEVENV_SUMMARY_STATES
declare -a DEVENV_SUMMARY_REASONS

log_info() {
    printf '[INFO] %s\n' "$*"
}

log_verbose() {
    [[ "${DEVENV_VERBOSE:-false}" == true ]] || return 0
    printf '[VERBOSE] %s\n' "$*"
}

log_warn() {
    DEVENV_LOG_WARN_COUNT=$((DEVENV_LOG_WARN_COUNT + 1))
    printf '[WARN] %s\n' "$*" >&2
}

log_error() {
    DEVENV_LOG_ERROR_COUNT=$((DEVENV_LOG_ERROR_COUNT + 1))
    printf '[ERROR] %s\n' "$*" >&2
}

summary_add() {
    DEVENV_SUMMARY_NAMES[DEVENV_SUMMARY_COUNT]="$1"
    DEVENV_SUMMARY_STATES[DEVENV_SUMMARY_COUNT]="$2"
    DEVENV_SUMMARY_REASONS[DEVENV_SUMMARY_COUNT]="$3"
    DEVENV_SUMMARY_COUNT=$((DEVENV_SUMMARY_COUNT + 1))
}

summary_print() {
    local index
    printf '\nTool summary:\n'
    if [[ "$DEVENV_SUMMARY_COUNT" -eq 0 ]]; then
        printf '  (no tool sections)\n'
        return 0
    fi
    for ((index = 0; index < DEVENV_SUMMARY_COUNT; index++)); do
        printf '  %-16s %-8s %s\n' \
            "${DEVENV_SUMMARY_NAMES[index]}" \
            "${DEVENV_SUMMARY_STATES[index]}" \
            "${DEVENV_SUMMARY_REASONS[index]}"
    done
}

summary_has_failures() {
    local index
    for ((index = 0; index < DEVENV_SUMMARY_COUNT; index++)); do
        [[ "${DEVENV_SUMMARY_STATES[index]}" == failed ]] && return 0
    done
    return 1
}
