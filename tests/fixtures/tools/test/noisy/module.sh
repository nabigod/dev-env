#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    printf 'module detect output\n'
    return 0
}

module_apply() {
    printf 'module apply output\n'
    log_info "module log output"
    return 0
}
