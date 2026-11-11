#!/bin/bash

declare -A DEVENV_CONFIG_VALUES
declare -a DEVENV_CONFIG_SECTION_ORDER
declare -A DEVENV_CONFIG_SEEN_SECTIONS
DEVENV_CONFIG_CURRENT_SECTION=""

ini_trim() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s\n' "$value"
}

config_load() {
    local config_file="$1"
    local raw line section key value line_number=0
    [[ -f "$config_file" ]] || {
        log_error "Config file not found: $config_file"
        return 1
    }
    DEVENV_CONFIG_VALUES=()
    DEVENV_CONFIG_SECTION_ORDER=()
    DEVENV_CONFIG_SEEN_SECTIONS=()
    DEVENV_CONFIG_CURRENT_SECTION=""

    while IFS= read -r raw || [[ -n "$raw" ]]; do
        line_number=$((line_number + 1))
        line=${raw%$'\r'}
        line=$(ini_trim "$line")
        [[ -n "$line" ]] || continue
        [[ "${line:0:1}" == "#" || "${line:0:1}" == ";" ]] && continue
        if [[ "$line" =~ ^\[([^][]+)\]$ ]]; then
            section=$(ini_trim "${BASH_REMATCH[1]}")
            [[ -n "$section" ]] || {
                log_error "$config_file:$line_number: empty section"
                return 1
            }
            DEVENV_CONFIG_CURRENT_SECTION="$section"
            if [[ -z "${DEVENV_CONFIG_SEEN_SECTIONS[$section]+set}" ]]; then
                DEVENV_CONFIG_SECTION_ORDER[${#DEVENV_CONFIG_SECTION_ORDER[@]}]="$section"
                DEVENV_CONFIG_SEEN_SECTIONS["$section"]=1
            fi
            continue
        fi
        [[ "$line" == *=* && -n "$DEVENV_CONFIG_CURRENT_SECTION" ]] || {
            log_error "$config_file:$line_number: invalid line"
            return 1
        }
        key=$(ini_trim "${line%%=*}")
        value=$(ini_trim "${line#*=}")
        [[ "$key" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || {
            log_error "$config_file:$line_number: invalid key"
            return 1
        }
        DEVENV_CONFIG_VALUES["$DEVENV_CONFIG_CURRENT_SECTION.$key"]="$value"
    done < "$config_file"
    return 0
}

config_sections() {
    printf '%s\n' "${DEVENV_CONFIG_SECTION_ORDER[@]}"
}

config_keys_for_section() {
    local section="$1"
    local key composite
    for composite in "${!DEVENV_CONFIG_VALUES[@]}"; do
        [[ "$composite" == "$section."* ]] || continue
        key=${composite#"$section".}
        printf '%s\n' "$key"
    done | sort
}

config_has() {
    [[ -n "${DEVENV_CONFIG_VALUES[$1.$2]+set}" ]]
}

config_get() {
    local section="$1"
    local key="$2"
    local fallback="${3-}"
    if config_has "$section" "$key"; then
        printf '%s\n' "${DEVENV_CONFIG_VALUES[$section.$key]}"
    else
        printf '%s\n' "$fallback"
    fi
}

config_bool() {
    local section="$1"
    local key="$2"
    local output_name="$3"
    local value
    value=$(config_get "$section" "$key" "")
    case "${value,,}" in
        1|true|yes|on) printf -v "$output_name" '%s' true ;;
        0|false|no|off) printf -v "$output_name" '%s' false ;;
        *)
            log_error "Invalid boolean [$section] $key: $value"
            return 1
            ;;
    esac
}
