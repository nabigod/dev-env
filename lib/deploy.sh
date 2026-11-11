#!/bin/bash

deploy_validate_source() {
    local source="$1"
    [[ -e "$source" || -L "$source" ]] || {
        log_error "Deployment source not found: $source"
        return 1
    }
}

deploy_link() {
    local source="$1"
    local target="$2"
    deploy_validate_source "$source" || return 1
    backup_path_is_safe "$target" || {
        log_error "Deployment target must be inside HOME: $target"
        return 1
    }
    if backup_manifest_has_after_absent "$target"; then
        log_error "Target was already displaced in this backup run: $target"
        return 1
    fi
    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
        log_verbose "Link already correct: $target"
        return 0
    fi
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_info "Would link $target -> $source"
        return 0
    fi
    backup_target "$target" || return 1
    mkdir -p "$(dirname "$target")" || return 1
    backup_remove_current "$target" || return 1
    ln -s "$source" "$target" || {
        log_error "Cannot create link: $target"
        return 1
    }
    backup_record_link "$target" "$source" || return 1
    log_verbose "Linked $target -> $source"
}

deploy_displace() {
    local target="$1"
    backup_path_is_safe "$target" || {
        log_error "Displacement target must be inside HOME: $target"
        return 1
    }
    if backup_manifest_has_after "$target"; then
        log_error "Target was already handled in this backup run: $target"
        return 1
    fi
    if [[ ! -e "$target" && ! -L "$target" ]]; then
        return 0
    fi
    if [[ ! -L "$target" && ! -f "$target" && ! -d "$target" ]]; then
        log_error "Unsupported displacement target type: $target"
        return 1
    fi
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_info "Would move existing target to backup and remove $target"
        return 0
    fi
    backup_target "$target" || return 1
    backup_record_absent "$target" || return 1
    backup_remove_current "$target" || return 1
    [[ ! -e "$target" && ! -L "$target" ]] || {
        log_error "Displacement target still exists: $target"
        return 1
    }
}
