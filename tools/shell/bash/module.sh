#!/bin/bash

module_detect() {
    return 0
}

module_known_keys() {
    printf '%s\n' ""
}

module_apply() {
    local module_dir="$DEVENV_REPO_DIR/tools/shell/bash"
    local common_source="$DEVENV_REPO_DIR/tools/shell/common/common.sh"
    local common_target="$HOME/.config/portable-devenv/shell/bash-common.sh"
    local shell_source="$module_dir/bash.sh"
    local shell_target="$HOME/.config/portable-devenv/shell/bash.sh"

    deploy_link "$common_source" "$common_target" || return 1
    deploy_link "$shell_source" "$shell_target" || return 1
    rc_block_apply "$HOME/.bashrc" "$module_dir/rc.block" || return 1
}
