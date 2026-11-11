#!/bin/bash
# shellcheck disable=SC1091

module_detect() {
    command -v zsh >/dev/null 2>&1
}

module_install() {
    pkg_install zsh
}

module_known_keys() {
    printf '%s\n' set_default_shell
}

pin_git_repository() {
    local repository_url="$1"
    local repository_commit="$2"
    local repository_target="$3"
    local actual_commit

    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_info "Would pin $repository_target to $repository_commit"
        return 0
    fi
    if [[ -d "$repository_target/.git" ]]; then
        actual_commit=$(git_repository_command "$repository_target" rev-parse HEAD) ||
            return 1
        if [[ "$actual_commit" != "$repository_commit" ]]; then
            # Fetch the exact commit so an existing clone is deterministic.
            git_repository_command "$repository_target" fetch --quiet origin \
                "$repository_commit" || return 1
        fi
    else
        [[ ! -e "$repository_target" ]] || {
            log_error "Pinned repository target is not a git repository: $repository_target"
            return 1
        }
        mkdir -p "$(dirname "$repository_target")" || return 1
        git clone --quiet "$repository_url" "$repository_target" || return 1
    fi
    git_repository_command "$repository_target" checkout --quiet --detach \
        "$repository_commit" || return 1
    actual_commit=$(git_repository_command "$repository_target" rev-parse HEAD) ||
        return 1
    [[ "$actual_commit" == "$repository_commit" ]]
}

git_repository_command() {
    local repository_target="$1"
    shift
    # Use the older Git interface supported before git -C was introduced.
    git --git-dir="$repository_target/.git" \
        --work-tree="$repository_target" "$@"
}

apply_default_shell() {
    local shell_path
    local set_default_shell=false

    if config_has zsh set_default_shell; then
        config_bool zsh set_default_shell set_default_shell || return 1
    fi
    [[ "$set_default_shell" == true ]] || return 0
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_info "Would change default shell to zsh"
        return 0
    fi
    shell_path=$(command -v zsh) || {
        log_warn "Cannot change default shell: zsh is not available"
        return 1
    }
    if ! command -v chsh >/dev/null 2>&1; then
        log_warn "Cannot change default shell: chsh is unavailable; run chsh -s $shell_path manually"
        return 1
    fi
    if ! chsh -s "$shell_path"; then
        log_warn "chsh failed; run chsh -s $shell_path manually"
        return 1
    fi
    return 0
}

module_apply() {
    local module_dir="$DEVENV_REPO_DIR/tools/shell/zsh"
    local common_source="$DEVENV_REPO_DIR/tools/shell/common/common.sh"
    local common_target="$HOME/.config/portable-devenv/shell/zsh-common.sh"
    local shell_source="$module_dir/zsh.sh"
    local shell_target="$HOME/.config/portable-devenv/shell/zsh.sh"
    local online_source="$module_dir/zsh-online.sh"
    local online_target="$HOME/.config/portable-devenv/shell/zsh-online.sh"
    local repository_status=0

    . "$module_dir/versions.sh" || return 1
    pin_git_repository "$PORTABLE_DEVENV_OMZ_URL" \
        "$PORTABLE_DEVENV_OMZ_COMMIT" "$HOME/.oh-my-zsh" || repository_status=1
    if [[ "$repository_status" -eq 0 ]]; then
        pin_git_repository "$PORTABLE_DEVENV_AUTOSUGGESTIONS_URL" \
            "$PORTABLE_DEVENV_AUTOSUGGESTIONS_COMMIT" \
            "$HOME/.oh-my-zsh/custom/plugins/zsh-autosuggestions" \
            || repository_status=1
    fi
    if [[ "$repository_status" -eq 0 ]]; then
        pin_git_repository "$PORTABLE_DEVENV_SYNTAX_HIGHLIGHTING_URL" \
            "$PORTABLE_DEVENV_SYNTAX_HIGHLIGHTING_COMMIT" \
            "$HOME/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" \
            || repository_status=1
    fi

    deploy_link "$common_source" "$common_target" || return 1
    deploy_link "$shell_source" "$shell_target" || return 1
    if [[ "$repository_status" -eq 0 ]]; then
        deploy_link "$online_source" "$online_target" || return 1
        rc_block_apply "$HOME/.zshrc" "$module_dir/rc.block" || return 1
    else
        # Use the basic block when pinned online components are unavailable.
        log_error "oh-my-zsh or its plugins could not be pinned; applying basic zsh only"
        rc_block_apply "$HOME/.zshrc" "$module_dir/rc.basic.block" || return 1
    fi
    apply_default_shell || return 1
    [[ "$repository_status" -eq 0 ]]
}
