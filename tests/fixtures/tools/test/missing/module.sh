#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 1
}

module_install() {
    log_error "dry-run must not install"
    return 7
}

module_apply() {
    log_error "missing fixture should not apply"
    return 7
}
