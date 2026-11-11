#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 0
}

# Starts a child that starts a grandchild so that termination must reach the whole process tree.
module_apply() {
    : > "$DEVENV_TEST_MARKER_DIR/slow-started"
    bash -c 'echo $$ > "$1/wrapper.pid"; sleep 30 & echo $! > "$1/sleeper.pid"; wait' \
        _ "$DEVENV_TEST_MARKER_DIR"
    : > "$DEVENV_TEST_MARKER_DIR/slow-finished"
}
