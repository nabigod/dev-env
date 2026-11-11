#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 0
}

module_apply() {
    : > "$DEVENV_TEST_MARKER_DIR/after-ran"
}
