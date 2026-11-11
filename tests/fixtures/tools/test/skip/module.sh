#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 1
}

module_apply() {
    log_error "skip fixture should not apply"
    return 7
}
