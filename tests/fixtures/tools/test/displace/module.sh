#!/bin/bash

module_detect() {
    return 0
}

module_apply() {
    deploy_displace "$HOME/.displace-file" || return 1
    deploy_displace "$HOME/.displace-link" || return 1
    deploy_displace "$HOME/.displace-directory" || return 1
    deploy_displace "$HOME/.displace-none" || return 1
}
