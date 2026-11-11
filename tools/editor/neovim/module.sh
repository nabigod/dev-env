#!/bin/bash

module_detect() {
    [[ -x "$HOME/.local/bin/nvim" ]] || command -v nvim >/dev/null 2>&1
}

module_install() {
    local plugin_enabled
    module_load_release_lock || return 1
    plugin_enabled=false
    if config_has neovim plugins; then
        config_bool neovim plugins plugin_enabled || return 2
    fi
    if [[ "$plugin_enabled" != true ]]; then
        pkg_install neovim
        return $?
    fi

    if module_try_qualified_package; then
        return 0
    fi
    module_install_official_release
}

module_known_keys() {
    printf '%s\n' plugins
}

module_apply() {
    local init_lua="$HOME/.config/nvim/init.lua"
    module_ensure_plugin_version || return 1
    deploy_displace "$init_lua" || return 1
    deploy_link "$DEVENV_REPO_DIR/tools/editor/neovim/init.vim" \
        "$HOME/.config/nvim/init.vim"
}

module_load_release_lock() {
    local lock_file="$DEVENV_REPO_DIR/tools/editor/neovim/release.lock.sh"
    [[ -r "$lock_file" ]] || {
        log_error "Neovim release lock is missing: $lock_file"
        return 1
    }
    # shellcheck source=/dev/null
    source "$lock_file"
}

module_current_nvim_path() {
    if [[ -x "$HOME/.local/bin/nvim" ]]; then
        printf '%s\n' "$HOME/.local/bin/nvim"
        return 0
    fi
    command -v nvim 2>/dev/null
}

module_current_nvim_version() {
    local executable version_line
    executable=$(module_current_nvim_path) || return 1
    version_line=$("$executable" --version 2>/dev/null | sed -n '1p') || return 1
    [[ "$version_line" =~ NVIM[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}

module_system_nvim_version() {
    local directory executable version_line
    local -a path_directories
    IFS=: read -r -a path_directories <<< "${PATH:-}"
    for directory in "${path_directories[@]}"; do
        [[ -n "$directory" ]] || directory=.
        [[ "$directory" == "$HOME/.local/bin" ]] && continue
        executable="$directory/nvim"
        [[ -x "$executable" ]] || continue
        version_line=$("$executable" --version 2>/dev/null | sed -n '1p') || continue
        if [[ "$version_line" =~ NVIM[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]]; then
            printf '%s\n' "${BASH_REMATCH[1]}"
            return 0
        fi
    done
    return 1
}

module_plugin_install_requested() {
    local install_requested=false plugin_enabled=false
    if config_has neovim install; then
        config_bool neovim install install_requested || return 2
    fi
    if config_has neovim plugins; then
        config_bool neovim plugins plugin_enabled || return 2
    fi
    [[ "$install_requested" == true && "$plugin_enabled" == true ]]
}

module_ensure_plugin_version() {
    local current_version system_version
    module_load_release_lock || return 1
    module_plugin_install_requested
    case $? in
        0) ;;
        1) return 0 ;;
        *) return 1 ;;
    esac

    if [[ "${DEVENV_DRY_RUN:-false}" == true ]]; then
        log_info "Would ensure Neovim >= $NVIM_PLUGIN_MIN_VERSION for plugins"
        return 0
    fi

    current_version=$(module_current_nvim_version 2>/dev/null) || current_version=""
    if [[ -n "$current_version" ]] && version_at_least "$current_version" "$NVIM_PLUGIN_MIN_VERSION"; then
        return 0
    fi

    system_version=$(module_system_nvim_version 2>/dev/null) || system_version=""
    if [[ -n "$system_version" ]] && version_at_least "$system_version" "$NVIM_PLUGIN_MIN_VERSION"; then
        module_displace_local_nvim || return 1
        return 0
    fi

    if module_try_qualified_package; then
        return 0
    fi
    module_install_official_release
}

module_package_candidate_version() {
    local manager package_output candidate highest_version="" comparison
    manager=$(pkg_manager_detect) || return 1
    case "$manager" in
        apt-get)
            command -v apt-cache >/dev/null 2>&1 || return 1
            package_output=$(apt-cache policy neovim 2>/dev/null) || return 1
            candidate=$(printf '%s\n' "$package_output" | awk '$1 == "Candidate:" { print $2; exit }')
            [[ -n "$candidate" && "$candidate" != "(none)" ]] || return 1
            candidate=${candidate#*:}
            candidate=${candidate%%-*}
            [[ "$candidate" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || return 1
            version_normalize "$candidate"
            ;;
        dnf|yum)
            package_output=$("$manager" --cacheonly --showduplicates list --available neovim 2>/dev/null) || return 1
            while IFS= read -r candidate; do
                [[ -n "$candidate" ]] || continue
                if [[ -z "$highest_version" ]]; then
                    highest_version="$candidate"
                else
                    comparison=$(version_compare "$candidate" "$highest_version") || return 1
                    [[ "$comparison" -gt 0 ]] && highest_version="$candidate"
                fi
            done < <(printf '%s\n' "$package_output" | awk '
                $1 ~ /^neovim([.].*)?$/ && $2 ~ /^[0-9]/ {
                    version = $2
                    sub(/^[0-9]+:/, "", version)
                    sub(/-.*/, "", version)
                    if (version ~ /^[0-9]+([.][0-9]+){1,2}$/) print version
                }
            ')
            [[ -n "$highest_version" ]] || return 1
            version_normalize "$highest_version"
            ;;
        *) return 1 ;;
    esac
}

module_try_qualified_package() {
    local candidate current_version system_version package_status
    candidate=$(module_package_candidate_version) || {
        log_info "No cached Neovim package candidate is available; using the pinned release"
        return 1
    }
    if ! version_at_least "$candidate" "$NVIM_PLUGIN_MIN_VERSION"; then
        log_info "Cached Neovim package candidate $candidate is below $NVIM_PLUGIN_MIN_VERSION; using the pinned release"
        return 1
    fi

    log_info "Installing Neovim package candidate $candidate"
    pkg_install neovim
    package_status=$?
    current_version=$(module_current_nvim_version 2>/dev/null) || current_version=""
    if [[ -n "$current_version" ]] && version_at_least "$current_version" "$NVIM_PLUGIN_MIN_VERSION"; then
        return 0
    fi
    system_version=$(module_system_nvim_version 2>/dev/null) || system_version=""
    if [[ -n "$system_version" ]] && version_at_least "$system_version" "$NVIM_PLUGIN_MIN_VERSION"; then
        module_displace_local_nvim || return 1
        return 0
    fi
    if [[ "$package_status" -ne 0 ]]; then
        log_warn "Neovim package installation failed (status $package_status); using the pinned release"
    else
        log_warn "Neovim package installation did not provide a usable version; using the pinned release"
    fi
    return 1
}

module_displace_local_nvim() {
    local local_nvim="$HOME/.local/bin/nvim"
    if [[ -e "$local_nvim" || -L "$local_nvim" ]]; then
        deploy_displace "$local_nvim"
    fi
}

module_install_official_release() {
    local architecture asset checksum executable glibc_info glibc_version
    local opt_directory archive stage release_directory release_nvim release_version
    module_load_release_lock || return 1

    case "$(uname -m 2>/dev/null)" in
        x86_64|amd64)
            architecture=x86_64
            asset="$NVIM_RELEASE_X86_64_ASSET"
            checksum="$NVIM_RELEASE_X86_64_SHA256"
            ;;
        aarch64|arm64)
            architecture=arm64
            asset="$NVIM_RELEASE_ARM64_ASSET"
            checksum="$NVIM_RELEASE_ARM64_SHA256"
            ;;
        *)
            log_error "Unsupported architecture for pinned Neovim release: $(uname -m 2>/dev/null || printf unknown)"
            return 1
            ;;
    esac

    glibc_info=$(getconf GNU_LIBC_VERSION 2>/dev/null) || {
        log_error "Cannot determine glibc version; refusing to install the pinned Neovim release"
        return 1
    }
    case "$glibc_info" in
        glibc\ *) glibc_version=${glibc_info#glibc } ;;
        *)
            log_error "Pinned Neovim release requires glibc >= $NVIM_RELEASE_MIN_GLIBC; detected: $glibc_info"
            return 1
            ;;
    esac
    if ! version_at_least "$glibc_version" "$NVIM_RELEASE_MIN_GLIBC"; then
        log_error "Pinned Neovim release requires glibc >= $NVIM_RELEASE_MIN_GLIBC; detected $glibc_version"
        return 1
    fi

    for executable in tar gzip sha256sum; do
        if ! command -v "$executable" >/dev/null 2>&1; then
            log_error "Cannot install Neovim release: required command is missing: $executable"
            return 1
        fi
    done

    opt_directory="$HOME/.local/opt"
    release_directory="$opt_directory/nvim-$NVIM_RELEASE_VERSION"
    if [[ -e "$release_directory" || -L "$release_directory" ]]; then
        [[ -d "$release_directory" && -x "$release_directory/bin/nvim" ]] || {
            log_error "Pinned Neovim release directory exists but is incomplete: $release_directory"
            return 1
        }
        release_version=$(module_read_nvim_version "$release_directory/bin/nvim") || {
            log_error "Cannot verify the existing pinned Neovim release: $release_directory"
            return 1
        }
        [[ "$release_version" == "$NVIM_RELEASE_VERSION" ]] || {
            log_error "Existing Neovim release version mismatch at $release_directory: $release_version"
            return 1
        }
        log_info "Using existing Neovim release $NVIM_RELEASE_VERSION"
        deploy_link "$release_directory/bin/nvim" "$HOME/.local/bin/nvim"
        return $?
    fi

    mkdir -p "$opt_directory" || {
        log_error "Cannot create Neovim installation directory: $opt_directory"
        return 1
    }
    archive=$(mktemp "$opt_directory/.nvim-release.XXXXXX") || return 1
    stage=$(mktemp -d "$opt_directory/.nvim-stage.XXXXXX") || {
        rm -f "$archive"
        return 1
    }
    if ! download_file "https://github.com/neovim/neovim/releases/download/$NVIM_RELEASE_TAG/$asset" \
        "$archive" "$checksum"; then
        rm -f "$archive"
        rmdir "$stage" 2>/dev/null || true
        return 1
    fi
    if ! tar -xzf "$archive" -C "$stage" --strip-components=1 --no-same-owner; then
        log_error "Cannot extract the pinned Neovim release archive"
        rm -f "$archive"
        rm -rf "$stage"
        return 1
    fi
    release_nvim="$stage/bin/nvim"
    [[ -x "$release_nvim" ]] || {
        log_error "Pinned Neovim archive does not contain executable bin/nvim"
        rm -f "$archive"
        rm -rf "$stage"
        return 1
    }
    release_version=$(module_read_nvim_version "$release_nvim") || {
        log_error "Cannot execute Neovim from the pinned release archive"
        rm -f "$archive"
        rm -rf "$stage"
        return 1
    }
    [[ "$release_version" == "$NVIM_RELEASE_VERSION" ]] || {
        log_error "Pinned archive version mismatch: expected $NVIM_RELEASE_VERSION, got $release_version"
        rm -f "$archive"
        rm -rf "$stage"
        return 1
    }
    if ! mv "$stage" "$release_directory"; then
        log_error "Cannot install Neovim release into $release_directory"
        rm -f "$archive"
        rm -rf "$stage"
        return 1
    fi
    rm -f "$archive" || return 1
    log_info "Installed pinned Neovim $NVIM_RELEASE_VERSION ($architecture)"
    deploy_link "$release_directory/bin/nvim" "$HOME/.local/bin/nvim"
}

module_read_nvim_version() {
    local executable="$1" version_line
    version_line=$("$executable" --version 2>/dev/null | sed -n '1p') || return 1
    [[ "$version_line" =~ NVIM[[:space:]]+v?([0-9]+\.[0-9]+\.[0-9]+) ]] || return 1
    printf '%s\n' "${BASH_REMATCH[1]}"
}
