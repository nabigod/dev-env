#!/bin/bash

DEVENV_BACKUP_ROOT=""
DEVENV_BACKUP_ID=""
DEVENV_BACKUP_PATH=""
DEVENV_BACKUP_ITEM_COUNT=0

backup_absolute_path() {
    local configured="$1"
    local home_base="${HOME%/}"
    case "$configured" in
        "~") configured="$home_base" ;;
        \~/*) configured="$home_base/${configured:2}" ;;
        /*) ;;
        *) configured="$home_base/$configured" ;;
    esac
    printf '%s\n' "$configured"
}

backup_path_has_forbidden_chars() {
    local path="$1"
    [[ "$path" != *$'\t'* && "$path" != *$'\n'* ]]
}

# A safe path is canonical (no empty, "." or ".." component), absolute, and
# strictly inside HOME. The reason for a rejection is kept for error messages.
DEVENV_PATH_REJECTION_REASON=""

backup_path_check() {
    local path="$1"
    local home_base relative_path
    DEVENV_PATH_REJECTION_REASON=""
    home_base="${HOME:-}"
    home_base="${home_base%/}"
    if [[ -z "$home_base" || "$home_base" == "/" ]]; then
        DEVENV_PATH_REJECTION_REASON="HOME must be a non-root non-empty directory"
        return 1
    fi
    if [[ "$path" != /* ]]; then
        DEVENV_PATH_REJECTION_REASON="path is not absolute"
        return 1
    fi
    if ! backup_path_has_forbidden_chars "$path"; then
        DEVENV_PATH_REJECTION_REASON="path contains a tab or newline"
        return 1
    fi
    if [[ "$path" == */. || "$path" == */./* || "$path" == */.. || "$path" == */../* ]]; then
        DEVENV_PATH_REJECTION_REASON="path contains a '.' or '..' component"
        return 1
    fi
    if [[ "$path" == "$home_base" ]]; then
        DEVENV_PATH_REJECTION_REASON="path is HOME itself"
        return 1
    fi
    if [[ "$path" != "$home_base/"* ]]; then
        DEVENV_PATH_REJECTION_REASON="path is outside HOME"
        return 1
    fi
    relative_path="${path#"$home_base/"}"
    if [[ -z "$relative_path" ]]; then
        DEVENV_PATH_REJECTION_REASON="path is HOME itself"
        return 1
    fi
    if [[ "$relative_path" == /* || "$relative_path" == */ || "$relative_path" == *//* ]]; then
        DEVENV_PATH_REJECTION_REASON="path contains an empty component (repeated or trailing slash)"
        return 1
    fi
    return 0
}

backup_path_is_safe() {
    backup_path_check "$1"
}

backup_set_root() {
    local configured="$1"
    [[ -n "${HOME:-}" && "$HOME" != "/" ]] || {
        log_error "HOME must be a non-root non-empty directory"
        return 1
    }
    DEVENV_BACKUP_ROOT=$(backup_absolute_path "$configured")
    # A trailing slash carries no meaning for a directory, so it is dropped.
    while [[ "$DEVENV_BACKUP_ROOT" == */ && "$DEVENV_BACKUP_ROOT" != "/" ]]; do
        DEVENV_BACKUP_ROOT="${DEVENV_BACKUP_ROOT%/}"
    done
    backup_path_check "$DEVENV_BACKUP_ROOT" || {
        log_error "Backup directory rejected: $DEVENV_PATH_REJECTION_REASON: $DEVENV_BACKUP_ROOT"
        return 1
    }
    return 0
}

backup_begin() {
    local timestamp
    [[ -n "$DEVENV_BACKUP_ROOT" ]] || return 1
    timestamp=$(date +%Y%m%d-%H%M%S) || return 1
    DEVENV_BACKUP_ID="${timestamp}-$$"
    DEVENV_BACKUP_PATH="$DEVENV_BACKUP_ROOT/$DEVENV_BACKUP_ID"
    DEVENV_BACKUP_ITEM_COUNT=0
}

backup_ensure_path() {
    [[ "$DEVENV_DRY_RUN" == true ]] && return 0
    mkdir -p "$DEVENV_BACKUP_PATH" || {
        log_error "Cannot create backup directory: $DEVENV_BACKUP_PATH"
        return 1
    }
    if [[ ! -f "$DEVENV_BACKUP_PATH/manifest" ]]; then
        printf '# portable-devenv backup manifest v1\n' > "$DEVENV_BACKUP_PATH/manifest" || return 1
    fi
}

backup_allocate_item() {
    local candidate_number item_name candidate_path
    candidate_number=$((DEVENV_BACKUP_ITEM_COUNT + 1))
    while :; do
        item_name=$(printf 'item-%03d' "$candidate_number")
        candidate_path="$DEVENV_BACKUP_PATH/$item_name"
        if [[ ! -e "$candidate_path" && ! -L "$candidate_path" ]]; then
            DEVENV_BACKUP_ITEM_COUNT="$candidate_number"
            printf '%s\n' "$candidate_path"
            return 0
        fi
        candidate_number=$((candidate_number + 1))
    done
}

backup_manifest_has_before() {
    local path="$1"
    [[ -f "$DEVENV_BACKUP_PATH/manifest" ]] || return 1
    awk -F '\t' -v wanted="$path" '$1 == "BEFORE" && $3 == wanted { found=1 } END { exit !found }' \
        "$DEVENV_BACKUP_PATH/manifest"
}

backup_manifest_has_after() {
    local path="$1"
    [[ -f "$DEVENV_BACKUP_PATH/manifest" ]] || return 1
    awk -F '\t' -v wanted="$path" \
        '($1 == "AFTER_LINK" || $1 == "AFTER_RC" || $1 == "AFTER_ABSENT") && $2 == wanted {
            found=1
        }
        END { exit !found }' "$DEVENV_BACKUP_PATH/manifest"
}

backup_manifest_has_after_absent() {
    local path="$1"
    [[ -f "$DEVENV_BACKUP_PATH/manifest" ]] || return 1
    awk -F '\t' -v wanted="$path" \
        '$1 == "AFTER_ABSENT" && $2 == wanted { found=1 }
        END { exit !found }' "$DEVENV_BACKUP_PATH/manifest"
}

backup_target() {
    local target="$1"
    local target_type link_target saved_path
    backup_path_is_safe "$target" || {
        log_error "Refusing to modify path outside HOME: $target"
        return 1
    }
    backup_manifest_has_before "$target" && return 0
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_verbose "Would back up $target"
        return 0
    fi
    backup_ensure_path || return 1
    saved_path=$(backup_allocate_item) || return 1
    if [[ -L "$target" ]]; then
        printf -v target_type '%s' link
        link_target=$(readlink "$target") || return 1
        backup_path_has_forbidden_chars "$link_target" || {
            log_error "Link target contains a tab or newline"
            return 1
        }
        printf 'BEFORE\t%s\t%s\t%s\t%s\n' "$target_type" "$target" "$link_target" "-" \
            >> "$DEVENV_BACKUP_PATH/manifest"
    elif [[ -f "$target" ]]; then
        printf -v target_type '%s' file
        cp -p "$target" "$saved_path" || return 1
        printf 'BEFORE\t%s\t%s\t%s\t%s\n' "$target_type" "$target" "-" "$saved_path" \
            >> "$DEVENV_BACKUP_PATH/manifest"
    elif [[ -d "$target" ]]; then
        target_type=directory
        cp -a "$target" "$saved_path" || return 1
        printf 'BEFORE\t%s\t%s\t%s\t%s\n' "$target_type" "$target" "-" "$saved_path" \
            >> "$DEVENV_BACKUP_PATH/manifest"
    else
        target_type=none
        printf 'BEFORE\t%s\t%s\t%s\t%s\n' "$target_type" "$target" "-" "-" \
            >> "$DEVENV_BACKUP_PATH/manifest"
    fi
}

backup_record_link() {
    local target="$1"
    local source="$2"
    backup_path_is_safe "$target" || return 1
    backup_path_has_forbidden_chars "$source" || {
        log_error "Link source contains a tab or newline"
        return 1
    }
    [[ "$DEVENV_DRY_RUN" == true ]] && return 0
    backup_ensure_path || return 1
    awk -F '\t' -v wanted="$target" '$1 == "AFTER_LINK" && $2 == wanted { found=1 } END { exit !found }' \
        "$DEVENV_BACKUP_PATH/manifest" && return 0
    printf 'AFTER_LINK\t%s\t%s\n' "$target" "$source" >> "$DEVENV_BACKUP_PATH/manifest"
}

backup_record_absent() {
    local target="$1"
    backup_path_is_safe "$target" || return 1
    [[ "$DEVENV_DRY_RUN" == true ]] && return 0
    backup_ensure_path || return 1
    if awk -F '\t' -v wanted="$target" \
        '$1 == "AFTER_ABSENT" && $2 == wanted { found=1 } END { exit !found }' \
        "$DEVENV_BACKUP_PATH/manifest"; then
        return 0
    fi
    printf 'AFTER_ABSENT\t%s\n' "$target" >> "$DEVENV_BACKUP_PATH/manifest"
}

backup_record_rc() {
    local target="$1"
    local digest
    backup_path_is_safe "$target" || return 1
    [[ "$DEVENV_DRY_RUN" == true ]] && return 0
    backup_ensure_path || return 1
    digest=$(sha256sum "$target") || return 1
    digest=${digest%% *}
    if awk -F '\t' -v wanted="$target" '$1 == "AFTER_RC" && $2 == wanted { found=1 } END { exit !found }' \
        "$DEVENV_BACKUP_PATH/manifest"; then
        local manifest_temp
        manifest_temp=$(mktemp "$DEVENV_BACKUP_PATH/.manifest.XXXXXX") || return 1
        awk -F '\t' -v wanted="$target" \
            '$1 == "AFTER_RC" && $2 == wanted { next } { print }' \
            "$DEVENV_BACKUP_PATH/manifest" > "$manifest_temp" || {
            rm -f "$manifest_temp"
            return 1
        }
        mv "$manifest_temp" "$DEVENV_BACKUP_PATH/manifest" || return 1
    fi
    printf 'AFTER_RC\t%s\t%s\n' "$target" "$digest" >> "$DEVENV_BACKUP_PATH/manifest"
}

backup_list() {
    local path
    [[ -d "$DEVENV_BACKUP_ROOT" ]] || return 0
    for path in "$DEVENV_BACKUP_ROOT"/*; do
        [[ -d "$path" && -f "$path/manifest" ]] || continue
        basename "$path"
    done
}

backup_remove_current() {
    local target="$1"
    backup_path_is_safe "$target" || return 1
    [[ ! -e "$target" && ! -L "$target" ]] && return 0
    if [[ -L "$target" || -f "$target" ]]; then
        rm -f "$target" || {
            log_error "Cannot remove target: $target"
            return 1
        }
    elif [[ -d "$target" ]]; then
        rm -rf "$target" || {
            log_error "Cannot remove target: $target"
            return 1
        }
    else
        log_error "Unsupported target type cannot be removed: $target"
        return 1
    fi
    [[ ! -e "$target" && ! -L "$target" ]] || {
        log_error "Target still exists after removal: $target"
        return 1
    }
}

# Saved items are written as item-<number> directly inside the backup that is
# being restored, so any other spelling cannot come from backup_target.
backup_saved_path_is_valid() {
    local restore_path="$1"
    local saved_path="$2"
    local item_name
    backup_path_has_forbidden_chars "$saved_path" || return 1
    [[ "$saved_path" == "$restore_path"/* ]] || return 1
    item_name="${saved_path#"$restore_path"/}"
    [[ "$item_name" =~ ^item-[0-9]+$ ]]
}

# Validates one BEFORE record. Used for dry-run, for the pre-restore pass and
# as a guard right before a target is removed.
backup_before_record_is_valid() {
    local restore_path="$1"
    local backup_type="$2"
    local target="$3"
    local link_target="$4"
    local saved_path="$5"
    backup_path_check "$target" || {
        log_error "Unsafe manifest target ($DEVENV_PATH_REJECTION_REASON): $target"
        return 1
    }
    case "$backup_type" in
        none)
            [[ "$link_target" == "-" && "$saved_path" == "-" ]] || {
                log_error "Malformed manifest entry for: $target"
                return 1
            }
            ;;
        link)
            if [[ -z "$link_target" || "$saved_path" != "-" ]] \
                || ! backup_path_has_forbidden_chars "$link_target"; then
                log_error "Malformed manifest link entry for: $target"
                return 1
            fi
            ;;
        file|directory)
            [[ "$link_target" == "-" ]] || {
                log_error "Malformed manifest entry for: $target"
                return 1
            }
            backup_saved_path_is_valid "$restore_path" "$saved_path" || {
                log_error "Unsafe manifest backup path for $target: $saved_path"
                return 1
            }
            if [[ "$backup_type" == file ]]; then
                [[ -f "$saved_path" && ! -L "$saved_path" ]] || {
                    log_error "Backup item is missing or not a regular file: $saved_path"
                    return 1
                }
            else
                [[ -d "$saved_path" && ! -L "$saved_path" ]] || {
                    log_error "Backup item is missing or not a directory: $saved_path"
                    return 1
                }
            fi
            ;;
        *)
            log_error "Unknown manifest entry type: $backup_type"
            return 1
            ;;
    esac
}

# Validates one AFTER_LINK or AFTER_RC record: a target and one value field.
backup_after_record_is_valid() {
    local record_kind="$1"
    local target="$2"
    local value="$3"
    backup_path_check "$target" || {
        log_error "Unsafe manifest target ($DEVENV_PATH_REJECTION_REASON): $target"
        return 1
    }
    case "$record_kind" in
        AFTER_LINK)
            if [[ -z "$value" ]] || ! backup_path_has_forbidden_chars "$value"; then
                log_error "Malformed manifest link entry for: $target"
                return 1
            fi
            ;;
        AFTER_RC)
            [[ "$value" =~ ^[0-9a-f]{64}$ ]] || {
                log_error "Malformed manifest checksum entry for: $target"
                return 1
            }
            ;;
    esac
}

backup_after_absent_record_is_valid() {
    local target="$1"
    backup_path_check "$target" || {
        log_error "Unsafe manifest target ($DEVENV_PATH_REJECTION_REASON): $target"
        return 1
    }
}

# Checks every record of a manifest without modifying anything. Dry-run and
# real restore both call this, so they accept and reject the same manifests.
backup_validate_manifest() {
    local restore_path="$1"
    local record_kind field_1 field_2 field_3 field_4 extra_fields
    local line_number=0 status=0 index
    local -A before_targets before_types before_saved_paths after_seen
    local -a after_targets after_kinds
    before_targets=()
    before_types=()
    before_saved_paths=()
    after_seen=()
    after_targets=()
    after_kinds=()
    while IFS=$'\t' read -r record_kind field_1 field_2 field_3 field_4 extra_fields \
        || [[ -n "$record_kind" ]]; do
        line_number=$((line_number + 1))
        case "$record_kind" in
            BEFORE)
                if [[ -n "$extra_fields" ]]; then
                    log_error "Malformed manifest line $line_number: too many fields"
                    status=1
                    continue
                fi
                # Recorded even when invalid so that AFTER records do not add a second error.
                [[ -z "$field_2" ]] || {
                    before_targets["$field_2"]=1
                    before_types["$field_2"]="$field_1"
                }
                backup_before_record_is_valid "$restore_path" "$field_1" "$field_2" "$field_3" "$field_4" \
                    || { status=1; continue; }
                if [[ "$field_1" == file || "$field_1" == directory ]]; then
                    if [[ -n "${before_saved_paths[$field_4]+set}" ]]; then
                        log_error "Duplicate manifest backup path: $field_4"
                        status=1
                    else
                        before_saved_paths["$field_4"]="$field_2"
                    fi
                fi
                ;;
            AFTER_LINK|AFTER_RC)
                if [[ -n "$field_3$field_4$extra_fields" ]]; then
                    log_error "Malformed manifest line $line_number: too many fields"
                    status=1
                    continue
                fi
                backup_after_record_is_valid "$record_kind" "$field_1" "$field_2" || { status=1; continue; }
                if [[ -n "${after_seen[$field_1]+set}" ]]; then
                    log_error "Duplicate AFTER record for: $field_1"
                    status=1
                else
                    after_seen["$field_1"]="$record_kind"
                fi
                after_targets[${#after_targets[@]}]="$field_1"
                after_kinds[${#after_kinds[@]}]="$record_kind"
                ;;
            AFTER_ABSENT)
                if [[ -n "$field_2$field_3$field_4$extra_fields" ]]; then
                    log_error "Malformed manifest line $line_number: too many fields"
                    status=1
                    continue
                fi
                backup_after_absent_record_is_valid "$field_1" || { status=1; continue; }
                if [[ -n "${after_seen[$field_1]+set}" ]]; then
                    log_error "Duplicate AFTER record for: $field_1"
                    status=1
                else
                    after_seen["$field_1"]="$record_kind"
                fi
                after_targets[${#after_targets[@]}]="$field_1"
                after_kinds[${#after_kinds[@]}]="$record_kind"
                ;;
            ""|\#*)
                ;;
            *)
                log_error "Unknown manifest record type on line $line_number: $record_kind"
                status=1
                ;;
        esac
    done < "$restore_path/manifest"
    for ((index = 0; index < ${#after_targets[@]}; index++)); do
        if [[ -z "${before_targets[${after_targets[index]}]+set}" ]]; then
            log_error "Missing BEFORE entry for ${after_targets[index]}"
            status=1
        elif [[ "${after_kinds[index]}" == AFTER_ABSENT \
            && "${before_types[${after_targets[index]}]}" == none ]]; then
            log_error "AFTER_ABSENT requires an existing BEFORE entry: ${after_targets[index]}"
            status=1
        fi
    done
    return "$status"
}

backup_restore_before() {
    local restore_path="$1"
    local backup_type="$2"
    local target="$3"
    local link_target="$4"
    local saved_path="$5"
    backup_before_record_is_valid "$restore_path" "$backup_type" "$target" "$link_target" "$saved_path" \
        || return 1
    backup_remove_current "$target" || return 1
    case "$backup_type" in
        none) ;;
        link) ln -s "$link_target" "$target" || return 1 ;;
        file) cp -p "$saved_path" "$target" || return 1 ;;
        directory) cp -a "$saved_path" "$target" || return 1 ;;
        *) return 1 ;;
    esac
}

backup_restore_recorded_target() {
    local restore_path="$1"
    local target="$2"
    local before_line backup_type before_target link_target saved_path
    before_line=$(awk -F '\t' -v wanted="$target" '$1 == "BEFORE" && $3 == wanted { print; exit }' \
        "$restore_path/manifest")
    if [[ -z "$before_line" ]]; then
        log_error "Missing BEFORE entry for $target"
        return 1
    fi
    IFS=$'\t' read -r _ backup_type before_target link_target saved_path <<< "$before_line"
    backup_restore_before "$restore_path" "$backup_type" "$before_target" "$link_target" "$saved_path"
}

backup_print_restore_plan() {
    local restore_path="$1"
    local record_kind target
    while IFS=$'\t' read -r record_kind target _ || [[ -n "$record_kind" ]]; do
        case "$record_kind" in
            AFTER_LINK|AFTER_RC|AFTER_ABSENT)
                printf '[DRY-RUN] Would restore %s\n' "$target"
                ;;
        esac
    done < "$restore_path/manifest"
}

backup_restore() {
    local requested_id="$1"
    local restore_path record_kind target value current_digest
    local status=0
    restore_path="$DEVENV_BACKUP_ROOT/$requested_id"
    [[ "$requested_id" != */* && "$requested_id" != .* ]] || {
        log_error "Invalid backup ID: $requested_id"
        return 2
    }
    [[ -f "$restore_path/manifest" ]] || {
        log_error "Backup manifest not found: $requested_id"
        return 1
    }
    backup_validate_manifest "$restore_path" || {
        log_error "Backup manifest is invalid; nothing was restored: $requested_id"
        return 1
    }
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        backup_print_restore_plan "$restore_path"
        printf '[DRY-RUN] Would restore backup %s\n' "$requested_id"
        return 0
    fi
    while IFS=$'\t' read -r record_kind target value _ || [[ -n "$record_kind" ]]; do
        case "$record_kind" in
            AFTER_LINK)
                if [[ -L "$target" && "$(readlink "$target")" == "$value" ]]; then
                    :
                else
                    log_warn "Restore skipped; current link differs: $target"
                    status=1
                    continue
                fi
                backup_restore_recorded_target "$restore_path" "$target" || status=1
                ;;
            AFTER_RC)
                current_digest=""
                [[ -f "$target" ]] && current_digest=$(sha256sum "$target" | awk '{print $1}')
                if [[ "$current_digest" != "$value" ]]; then
                    log_warn "Restore skipped; current rc differs: $target"
                    status=1
                    continue
                fi
                backup_restore_recorded_target "$restore_path" "$target" || status=1
                ;;
            AFTER_ABSENT)
                if [[ -e "$target" || -L "$target" ]]; then
                    log_warn "Restore skipped; current target exists: $target"
                    status=1
                    continue
                fi
                backup_restore_recorded_target "$restore_path" "$target" || status=1
                ;;
        esac
    done < "$restore_path/manifest"
    return "$status"
}
