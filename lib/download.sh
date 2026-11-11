#!/bin/bash

download_file() {
    local url="$1"
    local destination="$2"
    local expected_sha256="${3-}"
    local digest temporary_destination
    backup_path_is_safe "$destination" || {
        log_error "Download destination must be inside HOME: $destination"
        return 1
    }
    if [[ "$DEVENV_DRY_RUN" == true ]]; then
        log_info "Would download $url -> $destination"
        return 0
    fi
    mkdir -p "$(dirname "$destination")" || return 1
    temporary_destination=$(mktemp "$(dirname "$destination")/.portable-devenv-download.XXXXXX") || return 1
    if command -v curl >/dev/null 2>&1; then
        if curl --fail --location --silent --show-error --output "$temporary_destination" "$url"; then
            :
        elif command -v wget >/dev/null 2>&1; then
            rm -f "$temporary_destination"
            temporary_destination=$(mktemp "$(dirname "$destination")/.portable-devenv-download.XXXXXX") || return 1
            wget --no-verbose --output-document="$temporary_destination" "$url" || {
                rm -f "$temporary_destination"
                log_error "Download failed: $url"
                return 1
            }
        else
            rm -f "$temporary_destination"
            log_error "Download failed: $url"
            return 1
        fi
    elif command -v wget >/dev/null 2>&1; then
        wget --no-verbose --output-document="$temporary_destination" "$url" || {
            rm -f "$temporary_destination"
            log_error "Download failed: $url"
            return 1
        }
    else
        rm -f "$temporary_destination"
        log_error "Neither curl nor wget is available for: $url"
        return 1
    fi
    if [[ -n "$expected_sha256" ]]; then
        digest=$(sha256sum "$temporary_destination") || {
            rm -f "$temporary_destination"
            return 1
        }
        digest=${digest%% *}
        if [[ "$digest" != "$expected_sha256" ]]; then
            log_error "Checksum mismatch for $destination"
            rm -f "$temporary_destination"
            return 1
        fi
    fi
    mv "$temporary_destination" "$destination" || {
        rm -f "$temporary_destination"
        return 1
    }
}
