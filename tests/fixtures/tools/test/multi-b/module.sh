#!/bin/bash

module_detect() {
    return 0
}

module_apply() {
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-b-source.txt" "$HOME/.multi-file-b"
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-b-source.txt" "$HOME/.multi-link-b"
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-b-source.txt" "$HOME/.multi-directory-b"
    deploy_link "$DEVENV_REPO_DIR/tests/fixtures/multi-b-source.txt" "$HOME/.multi-none-b"
    rc_block_apply "$HOME/.multi-rc-b" "$DEVENV_REPO_DIR/tests/fixtures/rc-block"
}
