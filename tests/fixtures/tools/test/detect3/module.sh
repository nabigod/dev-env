#!/bin/bash

module_known_keys() {
    printf '%s\n' "enable install"
}

module_detect() {
    return 3
}

module_apply() {
    return 0
}
