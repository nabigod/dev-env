#!/usr/bin/env zsh
# zsh-only file; sourced from the zsh startup block.
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2034

. "$HOME/.config/portable-devenv/shell/zsh-common.sh"

HISTFILE="${ZDOTDIR:-$HOME}/.zsh_history"
HISTSIZE=10000
SAVEHIST=20000
setopt append_history
setopt inc_append_history
setopt hist_ignore_dups
