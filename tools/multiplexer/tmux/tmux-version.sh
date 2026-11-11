#!/bin/sh

tmux_version_normalize() {
    version_text=$1
    case "$version_text" in
        *master*|*openbsd-*)
            # Development and OpenBSD port strings do not identify tmux reliably.
            printf '%s\n' '999.999.999'
            return 0
            ;;
    esac

    normalized=$(printf '%s\n' "$version_text" |
        sed -n 's/[^0-9]*\([0-9][0-9]*\)\.\([0-9][0-9]*\)\([a-zA-Z]*\).*/\1.\2.0/p')
    if [ -z "$normalized" ]; then
        printf '%s\n' '0.0.0'
    else
        printf '%s\n' "$normalized"
    fi
}

tmux_version_at_least() {
    actual_version=$1
    required_version=$2
    awk -F. -v actual="$actual_version" -v required="$required_version" '
        BEGIN {
            split(actual, actual_parts, ".")
            split(required, required_parts, ".")
            for (i = 1; i <= 3; i++) {
                if ((actual_parts[i] + 0) > (required_parts[i] + 0)) {
                    exit 0
                }
                if ((actual_parts[i] + 0) < (required_parts[i] + 0)) {
                    exit 1
                }
            }
            exit 0
        }'
}

if [ "$1" = "--normalize" ] && [ "$#" -eq 2 ]; then
    tmux_version_normalize "$2"
    exit $?
fi

if [ "$1" = "--at-least" ] && [ "$#" -ge 2 ] && [ "$#" -le 3 ]; then
    if [ "$#" -eq 3 ]; then
        detected_version=$3
    else
        detected_version=$(tmux -V 2>/dev/null) || exit 1
    fi
    normalized_actual=$(tmux_version_normalize "$detected_version")
    normalized_required=$(tmux_version_normalize "$2")
    tmux_version_at_least "$normalized_actual" "$normalized_required"
    exit $?
fi

printf '%s\n' "Usage: $0 --normalize VERSION | --at-least VERSION [TMUX_VERSION]" >&2
exit 2
