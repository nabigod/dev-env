#!/bin/bash

module_detect() {
    command -v tmux >/dev/null 2>&1
}

module_install() {
    pkg_install tmux
}

module_apply() {
    local module_dir="$DEVENV_REPO_DIR/tools/multiplexer/tmux"
    local config_target="$HOME/.tmux.conf"
    local support_dir="$HOME/.tmux/portable-devenv"
    local support_file

    deploy_link "$module_dir/tmux.conf" "$config_target" || return 1
    for support_file in \
        tmux-version.sh \
        tmux-terminfo.sh \
        tmux-style-legacy.conf \
        tmux-style-modern.conf \
        tmux-path-legacy.conf \
        tmux-path-modern.conf \
        tmux-mouse-legacy.conf \
        tmux-mouse-modern.conf; do
        deploy_link "$module_dir/$support_file" \
            "$support_dir/$support_file" || return 1
    done
}
