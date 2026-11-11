#!/bin/bash
# shellcheck disable=SC1091

. "$HOME/.config/portable-devenv/shell/bash-common.sh"

HISTCONTROL=ignoredups:ignorespace
export HISTCONTROL
shopt -s histappend
