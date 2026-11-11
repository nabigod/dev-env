#!/bin/bash

pkg_manager_detect() {
    if command -v apt-get >/dev/null 2>&1; then
        printf '%s\n' apt-get
    elif command -v dnf >/dev/null 2>&1; then
        printf '%s\n' dnf
    elif command -v yum >/dev/null 2>&1; then
        printf '%s\n' yum
    else
        return 1
    fi
}

pkg_install() {
    local manager command_prefix=()
    DEVENV_INSTALL_SKIP_REASON=""
    [[ $# -gt 0 ]] || {
        log_error "pkg_install requires at least one package"
        return 2
    }
    manager=$(pkg_manager_detect) || {
        DEVENV_INSTALL_SKIP_REASON="no supported package manager; run manually: $*"
        log_warn "$DEVENV_INSTALL_SKIP_REASON"
        return 3
    }
    if [[ "${EUID:-1}" -ne 0 ]]; then
        command -v sudo >/dev/null 2>&1 || {
            DEVENV_INSTALL_SKIP_REASON="sudo is unavailable; run manually: $manager install $*"
            log_warn "$DEVENV_INSTALL_SKIP_REASON"
            return 3
        }
        command_prefix=(sudo)
    fi
    case "$manager" in
        apt-get) command_prefix+=(apt-get install -y) ;;
        dnf|yum) command_prefix+=("$manager" install -y) ;;
        *) log_error "Unsupported package manager: $manager"; return 2 ;;
    esac
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        printf '[DRY-RUN] '
        printf '%q ' "${command_prefix[@]}" "$@"
        printf '\n'
        return 0
    fi
    log_info "Installing packages: $*"
    "${command_prefix[@]}" "$@"
}
