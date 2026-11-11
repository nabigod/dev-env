#!/bin/sh

portable_devenv_local_bin="$HOME/.local/bin"
case ":${PATH-}:" in
    *":$portable_devenv_local_bin:"*) ;;
    *) PATH="$portable_devenv_local_bin${PATH:+:$PATH}" ;;
esac
export PATH

alias lal='ls -lAF'
alias ll='ls -lF'
alias la='ls -A'
alias l='ls -CF'
alias gs='git status'
alias tm='tmux'

# Clear a previous alias before selecting the available editor.
unalias vi 2>/dev/null || :
if command -v nvim >/dev/null 2>&1; then
    alias vi='nvim'
elif command -v vim >/dev/null 2>&1; then
    alias vi='vim'
fi

HISTSIZE=10000
HISTFILESIZE=20000
export HISTSIZE HISTFILESIZE

unset portable_devenv_local_bin
