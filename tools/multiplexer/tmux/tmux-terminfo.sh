#!/bin/sh

terminfo_name=${1:-tmux-256color}

terminfo_exists_in() {
    terminfo_root=$1
    [ -n "$terminfo_root" ] || return 1
    for terminfo_path in \
        "$terminfo_root/$terminfo_name" \
        "$terminfo_root/t/$terminfo_name" \
        "$terminfo_root/74/$terminfo_name"; do
        [ -r "$terminfo_path" ] && return 0
    done
    return 1
}

terminfo_exists_in_compiled_paths() {
    for terminfo_root in \
        /etc/terminfo \
        /lib/terminfo \
        /usr/share/terminfo \
        /usr/lib/terminfo; do
        terminfo_exists_in "$terminfo_root" && return 0
    done
    return 1
}

# ncurses keeps searching after a TERMINFO miss; it is the first location, not exclusive.
# Source: ncurses tinfo/db_iterator.c (versions 5.9, 6.3 and 6.4).
if [ -n "${TERMINFO:-}" ] && terminfo_exists_in "$TERMINFO"; then
    exit 0
fi

if [ -n "${HOME:-}" ]; then
    terminfo_exists_in "$HOME/.terminfo" && exit 0
fi

if [ "${TERMINFO_DIRS+x}" = x ]; then
    terminfo_dirs_value=$TERMINFO_DIRS
    while :; do
        case "$terminfo_dirs_value" in
            *:*)
                terminfo_root=${terminfo_dirs_value%%:*}
                terminfo_dirs_value=${terminfo_dirs_value#*:}
                has_more=1
                ;;
            *)
                terminfo_root=$terminfo_dirs_value
                has_more=0
                ;;
        esac
        if [ -n "$terminfo_root" ]; then
            terminfo_exists_in "$terminfo_root" && exit 0
        else
            terminfo_exists_in_compiled_paths && exit 0
        fi
        [ "$has_more" -eq 1 ] || break
    done
fi

terminfo_exists_in_compiled_paths && exit 0

exit 1
