#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 0
}

module_apply() {
    log_error "intentional fixture failure"
    return 7
}
