#!/bin/bash

DEVENV_RC_BLOCK_START="# >>> portable-devenv >>>"
DEVENV_RC_BLOCK_END="# <<< portable-devenv <<<"

rc_block_validate_path() {
    local rc_file="$1"
    backup_path_is_safe "$rc_file" || {
        log_error "rc file must be inside HOME: $rc_file"
        return 1
    }
}

rc_block_apply() {
    local rc_file="$1"
    local block_file="$2"
    local temp_file rc_mode current_digest new_digest
    rc_block_validate_path "$rc_file" || return 1
    [[ -f "$block_file" ]] || {
        log_error "rc block source not found: $block_file"
        return 1
    }
    if backup_manifest_has_after_absent "$rc_file"; then
        log_error "RC target was already displaced in this backup run: $rc_file"
        return 1
    fi
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_info "Would update rc block in $rc_file"
        return 0
    fi
    mkdir -p "$(dirname "$rc_file")" || return 1
    rc_mode=""
    if [[ -f "$rc_file" ]]; then
        rc_mode=$(stat -c '%a' "$rc_file") || return 1
    fi
    temp_file=$(mktemp "$(dirname "$rc_file")/.portable-devenv-rc.XXXXXX") || return 1
    if [[ -f "$rc_file" ]]; then
        awk -v start="$DEVENV_RC_BLOCK_START" \
            -v end="$DEVENV_RC_BLOCK_END" \
            -v block="$block_file" '
            BEGIN {
                while ((getline line < block) > 0) {
                    body = body line "\n"
                }
                close(block)
            }
            $0 == start {
                if (inside || replaced) exit 2
                inside = 1
                replaced = 1
                print start
                printf "%s", body
                print end
                next
            }
            $0 == end {
                if (!inside) exit 2
                inside = 0
                next
            }
            !inside { print }
            END {
                if (inside) exit 2
                if (!replaced) {
                    print start
                    printf "%s", body
                    print end
                }
            }
        ' "$rc_file" > "$temp_file" || {
            rm -f "$temp_file"
            log_error "Malformed rc block markers in $rc_file"
            return 1
        }
    else
        {
            printf '%s\n' "$DEVENV_RC_BLOCK_START"
            cat "$block_file"
            printf '%s\n' "$DEVENV_RC_BLOCK_END"
        } > "$temp_file" || {
            rm -f "$temp_file"
            return 1
        }
    fi
    current_digest=""
    new_digest=$(sha256sum "$temp_file" | awk '{print $1}') || {
        rm -f "$temp_file"
        return 1
    }
    [[ -f "$rc_file" ]] && current_digest=$(sha256sum "$rc_file" | awk '{print $1}')
    if [[ -f "$rc_file" && "$new_digest" == "$current_digest" ]]; then
        rm -f "$temp_file"
        log_verbose "rc block already correct: $rc_file"
        return 0
    fi
    if [[ -n "$rc_mode" ]]; then
        chmod "$rc_mode" "$temp_file" || {
            rm -f "$temp_file"
            return 1
        }
    fi
    backup_target "$rc_file" || {
        rm -f "$temp_file"
        return 1
    }
    mv "$temp_file" "$rc_file" || return 1
    backup_record_rc "$rc_file"
}

rc_block_remove() {
    local rc_file="$1"
    local temp_file
    rc_block_validate_path "$rc_file" || return 1
    [[ -f "$rc_file" ]] || return 0
    temp_file=$(mktemp "$(dirname "$rc_file")/.portable-devenv-rc.XXXXXX") || return 1
    awk -v start="$DEVENV_RC_BLOCK_START" -v end="$DEVENV_RC_BLOCK_END" '
        $0 == start { inside = 1; next }
        $0 == end { inside = 0; next }
        !inside { print }
    ' "$rc_file" > "$temp_file" || {
        rm -f "$temp_file"
        return 1
    }
    mv "$temp_file" "$rc_file"
}
