#!/usr/bin/env zsh
# zsh-only file; sourced from the zsh startup block.
# shellcheck shell=bash
# shellcheck disable=SC1091,SC2034

export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=robbyrussell
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
ZSH_DISABLE_AUTO_UPDATE=true
# Leave compaudit enabled; clean completion directories load without suppression.
. "$ZSH/oh-my-zsh.sh"
# Re-source shared settings after oh-my-zsh to preserve portable aliases.
. "$HOME/.config/portable-devenv/shell/zsh.sh"
