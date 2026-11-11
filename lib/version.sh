#!/bin/bash

version_normalize() {
    local input="$1"
    local numeric major minor patch
    if [[ "$input" =~ ([0-9]+([.][0-9]+){0,2}) ]]; then
        numeric="${BASH_REMATCH[1]}"
    else
        printf '0.0.0\n'
        return 0
    fi
    IFS=. read -r major minor patch <<< "$numeric"
    major=${major:-0}
    minor=${minor:-0}
    patch=${patch:-0}
    major=$((10#$major))
    minor=$((10#$minor))
    patch=$((10#$patch))
    printf '%d.%d.%d\n' "$major" "$minor" "$patch"
}

version_compare() {
    local left right left_part right_part index
    local -a left_parts right_parts
    left=$(version_normalize "$1")
    right=$(version_normalize "$2")
    IFS=. read -r -a left_parts <<< "$left"
    IFS=. read -r -a right_parts <<< "$right"
    for index in 0 1 2; do
        left_part=${left_parts[index]:-0}
        right_part=${right_parts[index]:-0}
        if ((left_part < right_part)); then
            printf '%s\n' -1
            return 0
        fi
        if ((left_part > right_part)); then
            printf '%s\n' 1
            return 0
        fi
    done
    printf '%s\n' 0
}

version_at_least() {
    [[ "$(version_compare "$1" "$2")" -ge 0 ]]
}
