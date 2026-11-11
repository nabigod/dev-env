#!/bin/bash

set -o pipefail

script_path="$0"
while [[ -L "$script_path" ]]; do
    link_target=$(readlink "$script_path") || exit 2
    if [[ "$link_target" == /* ]]; then
        script_path="$link_target"
    else
        script_path="$(dirname "$script_path")/$link_target"
    fi
done

SCRIPT_DIR=$(cd -P "$(dirname "$script_path")" >/dev/null 2>&1 && pwd) || exit 2
export DEVENV_REPO_DIR="$SCRIPT_DIR"
export DEVENV_MODULE_ROOT="${DEVENV_MODULE_ROOT:-$SCRIPT_DIR/tools}"

source "$SCRIPT_DIR/lib/log.sh"
source "$SCRIPT_DIR/lib/ini.sh"
source "$SCRIPT_DIR/lib/process.sh"
source "$SCRIPT_DIR/lib/version.sh"
source "$SCRIPT_DIR/lib/backup.sh"
source "$SCRIPT_DIR/lib/deploy.sh"
source "$SCRIPT_DIR/lib/rcblock.sh"
source "$SCRIPT_DIR/lib/package.sh"
source "$SCRIPT_DIR/lib/download.sh"

DEVENV_CONFIG_FILE=""
DEVENV_RESTORE_ID=""
DEVENV_LIST_BACKUPS=false
DEVENV_HELP=false
DEVENV_DRY_RUN=false
DEVENV_VERBOSE=false
DEVENV_RESULT_FILE=""
DEVENV_ACTIVE_MODULE_NAME=""

show_help() {
    cat <<HELP
Usage: $0 -c <config> [options]

Options:
  -c, --config FILE       INI configuration file
      --dry-run           Show changes without modifying HOME
  -v, --verbose           Enable verbose output
      --restore ID        Restore a backup manifest
      --list-backups      List available backup IDs
  -h, --help              Show this help

Available repository configs:
$(list_config_files)
HELP
}

list_config_files() {
    local config_file
    if [[ -d "$SCRIPT_DIR/configs" ]]; then
        for config_file in "$SCRIPT_DIR"/configs/*.conf; do
            [[ -f "$config_file" ]] || continue
            printf '  %s\n' "$config_file"
        done
    fi
}

die_usage() {
    log_error "$1"
    show_help >&2
    exit 2
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -c|--config)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "Missing value for $1"
                DEVENV_CONFIG_FILE="$2"
                shift 2
                ;;
            --dry-run)
                DEVENV_DRY_RUN=true
                shift
                ;;
            -v|--verbose)
                DEVENV_VERBOSE=true
                shift
                ;;
            --restore)
                [[ $# -ge 2 && -n "$2" ]] || die_usage "Missing backup ID for --restore"
                DEVENV_RESTORE_ID="$2"
                shift 2
                ;;
            --list-backups)
                DEVENV_LIST_BACKUPS=true
                shift
                ;;
            -h|--help)
                DEVENV_HELP=true
                shift
                ;;
            *)
                die_usage "Unknown option: $1"
                ;;
        esac
    done
}

module_path_for_section() {
    local section="$1"
    local module_path module_name found=""
    [[ -d "$DEVENV_MODULE_ROOT" ]] || return 1
    for module_path in "$DEVENV_MODULE_ROOT"/*/"$section"/module.sh; do
        [[ -f "$module_path" ]] || continue
        module_name=${module_path#"$DEVENV_MODULE_ROOT"/}
        if [[ -n "$found" ]]; then
            log_error "Multiple modules found for [$section]: $found and $module_name"
            return 2
        fi
        found="$module_path"
    done
    [[ -n "$found" ]] || return 1
    printf '%s\n' "$found"
}

validate_general_keys() {
    local key
    while IFS= read -r key; do
        case "$key" in
            backup_dir|"") ;;
            *) log_warn "Unknown [general] key: $key" ;;
        esac
    done < <(config_keys_for_section general)
}

validate_module_keys() {
    local section="$1"
    local allowed key allowed_key known
    allowed="enable install $(module_known_keys 2>/dev/null || true)"
    while IFS= read -r key; do
        [[ -n "$key" ]] || continue
        known=false
        for allowed_key in $allowed; do
            [[ "$key" == "$allowed_key" ]] && known=true
        done
        [[ "$known" == true ]] || log_warn "Unknown [$section] key: $key"
    done < <(config_keys_for_section "$section")
}

module_skip() {
    DEVENV_MODULE_SKIP_REQUESTED=true
    DEVENV_MODULE_SKIP_REASON="$*"
    return 3
}

run_module_isolated() {
    local section="$1"
    local module_file="$2"
    local module_status module_state module_reason

    (
        export DEVENV_TOOL_NAME="$section"
        DEVENV_MODULE_SKIP_REQUESTED=false
        DEVENV_MODULE_SKIP_REASON=""
        # Modules share generic function names and run in an isolated subshell.
        # shellcheck source=/dev/null
        source "$module_file" || return 2

        devenv_module_execute() {
            local enabled install_requested detect_status install_status apply_status
            declare -F module_detect >/dev/null 2>&1 || {
                DEVENV_MODULE_SKIP_REASON="module_detect is missing"
                return 2
            }
            declare -F module_apply >/dev/null 2>&1 || {
                DEVENV_MODULE_SKIP_REASON="module_apply is missing"
                return 2
            }
            if declare -F module_known_keys >/dev/null 2>&1; then
                validate_module_keys "$section"
            fi

            enabled=true
            if config_has "$section" enable; then
                config_bool "$section" enable enabled || return 2
            fi
            if [[ "$enabled" != true ]]; then
                module_skip "disabled"
                return $?
            fi

            if module_detect; then
                :
            else
                detect_status=$?
                if [[ "$detect_status" -ne 1 ]]; then
                    DEVENV_MODULE_SKIP_REQUESTED=false
                    DEVENV_MODULE_SKIP_REASON="detection failed (status $detect_status)"
                    return "$detect_status"
                fi
                install_requested=false
                if config_has "$section" install; then
                    config_bool "$section" install install_requested || return 2
                fi
                if [[ "$install_requested" != true ]]; then
                    module_skip "not installed"
                    return $?
                fi
                declare -F module_install >/dev/null 2>&1 || {
                    DEVENV_MODULE_SKIP_REASON="install=true but module_install is missing"
                    return 2
                }
                if [[ "$DEVENV_DRY_RUN" == true ]]; then
                    log_info "Would install [$section]"
                    module_skip "dry-run: would install"
                    return $?
                fi
                module_install
                install_status=$?
                if [[ "$install_status" -eq 3 ]]; then
                    if [[ -n "${DEVENV_INSTALL_SKIP_REASON:-}" ]]; then
                        module_skip "install skipped: $DEVENV_INSTALL_SKIP_REASON"
                        return $?
                    fi
                    DEVENV_MODULE_SKIP_REASON="module_install returned status 3 without install skip reason"
                    return 3
                fi
                if [[ "$install_status" -ne 0 ]]; then
                    DEVENV_MODULE_SKIP_REASON="module_install failed (status $install_status)"
                    return "$install_status"
                fi
                module_detect
                detect_status=$?
                if [[ "$detect_status" -ne 0 ]]; then
                    DEVENV_MODULE_SKIP_REASON="unavailable after installation (status $detect_status)"
                    return "$detect_status"
                fi
            fi
            module_apply
            apply_status=$?
            if [[ "$apply_status" -eq 0 ]]; then
                return 0
            fi
            if [[ "$apply_status" -eq 3 && "$DEVENV_MODULE_SKIP_REQUESTED" != true ]]; then
                DEVENV_MODULE_SKIP_REASON="module_apply returned status 3 without module_skip"
            elif [[ "$apply_status" -ne 3 ]]; then
                DEVENV_MODULE_SKIP_REASON="module_apply failed (status $apply_status)"
            fi
            return "$apply_status"
        }

        devenv_module_execute
        module_status=$?
        if [[ "$module_status" -eq 0 ]]; then
            module_state=applied
            module_reason=completed
        elif [[ "$module_status" -eq 3 && "$DEVENV_MODULE_SKIP_REQUESTED" == true ]]; then
            module_state=skipped
            module_reason="${DEVENV_MODULE_SKIP_REASON:-module requested skip}"
        else
            module_state=failed
            module_reason="${DEVENV_MODULE_SKIP_REASON:-module failed (status $module_status)}"
        fi
        printf '%s\t%s\n' "$module_state" "$module_reason" > "$DEVENV_RESULT_FILE"
        return "$module_status"
    )
}

remove_result_file() {
    [[ -z "${DEVENV_RESULT_FILE:-}" ]] || rm -f "$DEVENV_RESULT_FILE"
    DEVENV_RESULT_FILE=""
    return 0
}

# Runs from the INT/TERM/HUP traps: stop the running module and everything it
# started, then exit with the conventional 128+signal status. The EXIT trap
# removes the result file.
handle_termination_signal() {
    local signal_name="$1"
    local signal_number="$2"
    # Cleanup is bounded, so repeated signals are ignored until it is done.
    trap '' INT TERM HUP
    if [[ -n "$DEVENV_ACTIVE_MODULE_NAME" ]]; then
        log_error "Interrupted by SIG$signal_name; stopping module [$DEVENV_ACTIVE_MODULE_NAME]"
    else
        log_error "Interrupted by SIG$signal_name"
    fi
    process_terminate_descendants "$$" \
        || log_warn "Some child processes could not be stopped"
    log_error "Remaining modules were not run"
    exit $((128 + signal_number))
}

run_module() {
    local section="$1"
    local module_file="$2"
    local result_state result_reason module_status
    DEVENV_MODULE_RESULT_STATE=failed
    DEVENV_MODULE_RESULT_REASON="module failed without a result"
    DEVENV_RESULT_FILE=$(mktemp "${TMPDIR:-/tmp}/portable-devenv-result.XXXXXX") || {
        DEVENV_RESULT_FILE=""
        log_error "[$section] cannot create result file"
        return 2
    }
    export DEVENV_RESULT_FILE
    DEVENV_ACTIVE_MODULE_NAME="$section"
    # bash defers a trap until the foreground command ends, so the module runs
    # in the background and the signal interrupts wait immediately. Stdin is
    # passed through because background commands otherwise read /dev/null.
    run_module_isolated "$section" "$module_file" <&0 &
    wait "$!"
    module_status=$?
    DEVENV_ACTIVE_MODULE_NAME=""
    if [[ -s "$DEVENV_RESULT_FILE" ]]; then
        IFS=$'\t' read -r result_state result_reason < "$DEVENV_RESULT_FILE"
        DEVENV_MODULE_RESULT_STATE="$result_state"
        DEVENV_MODULE_RESULT_REASON="$result_reason"
    else
        DEVENV_MODULE_RESULT_STATE=failed
        DEVENV_MODULE_RESULT_REASON="module failed without a result (status $module_status)"
    fi
    remove_result_file
    if [[ "$DEVENV_MODULE_RESULT_STATE" == failed ]]; then
        log_error "[$section] $DEVENV_MODULE_RESULT_REASON"
    elif [[ "$DEVENV_MODULE_RESULT_STATE" == skipped ]]; then
        log_warn "[$section] skipped: $DEVENV_MODULE_RESULT_REASON"
    fi
    return "$module_status"
}

run_config() {
    local section module_file module_status lookup_status
    local -a section_names
    config_load "$DEVENV_CONFIG_FILE" || return 2
    validate_general_keys
    backup_set_root "$(config_get general backup_dir "$HOME/.dev-env-backup")" || return 2
    backup_begin

    # Sections are read up front so that modules keep the script's own stdin.
    mapfile -t section_names < <(config_sections)
    for section in "${section_names[@]}"; do
        [[ -n "$section" && "$section" != general ]] || continue
        module_file=$(module_path_for_section "$section")
        lookup_status=$?
        case "$lookup_status" in
            0) ;;
            1)
                log_error "No module found for config section [$section]"
                summary_add "$section" "failed" "module missing"
                continue
                ;;
            *)
                summary_add "$section" "failed" "ambiguous module"
                continue
                ;;
        esac
        log_info "Applying [$section]"
        run_module "$section" "$module_file"
        module_status=$?
        summary_add "$section" "$DEVENV_MODULE_RESULT_STATE" "$DEVENV_MODULE_RESULT_REASON"
    done
    summary_print
    summary_has_failures && return 1
    return 0
}

main() {
    local restore_status
    trap remove_result_file EXIT
    trap 'handle_termination_signal INT 2' INT
    trap 'handle_termination_signal TERM 15' TERM
    trap 'handle_termination_signal HUP 1' HUP
    parse_args "$@"
    if [[ "$DEVENV_HELP" == true ]]; then
        show_help
        return 0
    fi
    if [[ "$DEVENV_LIST_BACKUPS" == true && -n "$DEVENV_RESTORE_ID" ]]; then
        die_usage "--list-backups and --restore cannot be combined"
    fi
    export DEVENV_CONFIG_FILE DEVENV_DRY_RUN DEVENV_VERBOSE
    if [[ "$DEVENV_LIST_BACKUPS" == true ]]; then
        if [[ -n "$DEVENV_CONFIG_FILE" ]]; then
            [[ -f "$DEVENV_CONFIG_FILE" ]] || die_usage "Config file not found: $DEVENV_CONFIG_FILE"
            config_load "$DEVENV_CONFIG_FILE" || return 2
            backup_set_root "$(config_get general backup_dir "$HOME/.dev-env-backup")" || return 2
        else
            backup_set_root "$HOME/.dev-env-backup" || return 2
        fi
        backup_list
        return 0
    fi
    if [[ -n "$DEVENV_RESTORE_ID" ]]; then
        if [[ -n "$DEVENV_CONFIG_FILE" ]]; then
            config_load "$DEVENV_CONFIG_FILE" || return 2
            backup_set_root "$(config_get general backup_dir "$HOME/.dev-env-backup")" || return 2
        else
            backup_set_root "$HOME/.dev-env-backup" || return 2
        fi
        backup_restore "$DEVENV_RESTORE_ID"
        restore_status=$?
        return "$restore_status"
    fi
    if [[ -z "$DEVENV_CONFIG_FILE" ]]; then
        show_help
        return 0
    fi
    [[ -f "$DEVENV_CONFIG_FILE" ]] || die_usage "Config file not found: $DEVENV_CONFIG_FILE"
    run_config
}

main "$@"
