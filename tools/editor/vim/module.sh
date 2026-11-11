#!/bin/bash

module_detect() {
    command -v vim >/dev/null 2>&1
}

module_install() {
    pkg_install vim
}

module_apply() {
    deploy_link "$DEVENV_REPO_DIR/tools/editor/vim/.vimrc" "$HOME/.vimrc"
}
