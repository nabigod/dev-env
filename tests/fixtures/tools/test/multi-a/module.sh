#!/bin/bash

module_detect() {
    return 0
}

module_apply() {
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-a-source.txt" "$HOME/.multi-file-a"
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-a-source.txt" "$HOME/.multi-link-a"
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-a-source.txt" "$HOME/.multi-directory-a"
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-a-source.txt" "$HOME/.multi-none-a"
    rc_block_apply "$HOME/.multi-rc-a" "$DEVENV_REPO_DIR/tests/fixtures/rc-block"
}
