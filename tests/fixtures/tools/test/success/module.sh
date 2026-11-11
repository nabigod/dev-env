#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 0
}

module_apply() {
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/source.txt" "$HOME/.fixture-link" || return 1
    rc_block_apply "$HOME/.bashrc" "$DEVENV_REPO_DIR/tests/fixtures/rc-block"
}
