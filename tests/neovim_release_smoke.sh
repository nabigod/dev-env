#!/bin/bash

set -o pipefail

# Sources are resolved relative to this repository at runtime.
# shellcheck disable=SC1091

script_dir=$(cd -P "$(dirname "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd) || exit 2
repo_dir=$(cd -P "$script_dir/.." >/dev/null 2>&1 && pwd) || exit 2
test_root=$(mktemp -d "${TMPDIR:-/tmp}/portable-devenv-nvim-test.XXXXXX") || exit 2
original_path=$PATH
cleanup() {
    PATH="$original_path" rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

for library in log ini process version backup deploy rcblock package download; do
    # shellcheck disable=SC1090
    source "$repo_dir/lib/$library.sh"
done
# shellcheck disable=SC1091
source "$repo_dir/tools/editor/neovim/module.sh"

fail() {
    printf 'neovim release smoke failure: %s\n' "$*" >&2
    exit 1
}

assert_eq() {
    [[ "$1" == "$2" ]] || fail "$3 (expected '$2', got '$1')"
}

assert_file() {
    [[ -f "$1" ]] || fail "expected file: $1"
}

assert_absent() {
    [[ ! -e "$1" && ! -L "$1" ]] || fail "expected absent: $1"
}

test_bin="$test_root/bin"
mkdir -p "$test_bin"
cat > "$test_bin/nvim" <<'STUB'
#!/bin/bash
printf 'NVIM v%s\n' "${NVIM_TEST_VERSION:-0.7.2}"
STUB
chmod +x "$test_bin/nvim"
PATH="$test_bin:$original_path"
export PATH
export NVIM_TEST_VERSION=0.7.2

fixture_repo="$test_root/repo"
mkdir -p "$fixture_repo/tools/editor/neovim"
cp "$repo_dir/tools/editor/neovim/release.lock.sh" "$fixture_repo/tools/editor/neovim/release.lock.sh"
cp "$repo_dir/tools/editor/neovim/init.vim" "$fixture_repo/tools/editor/neovim/init.vim"
DEVENV_REPO_DIR="$fixture_repo"
export DEVENV_REPO_DIR

fixture_tree="$test_root/archive-tree/nvim-linux-x86_64"
mkdir -p "$fixture_tree/bin"
cat > "$fixture_tree/bin/nvim" <<'STUB'
#!/bin/bash
printf 'NVIM v0.12.6\n'
STUB
chmod +x "$fixture_tree/bin/nvim"
fixture_archive="$test_root/nvim-test.tar.gz"
tar -czf "$fixture_archive" -C "$test_root/archive-tree" nvim-linux-x86_64 || fail "cannot prepare release fixture"
fixture_sha=$(sha256sum "$fixture_archive") || fail "cannot hash release fixture"
fixture_sha=${fixture_sha%% *}
sed -i "s/^NVIM_RELEASE_X86_64_SHA256=.*/NVIM_RELEASE_X86_64_SHA256=\"$fixture_sha\"/" \
    "$fixture_repo/tools/editor/neovim/release.lock.sh"
sed -i "s/^NVIM_RELEASE_ARM64_SHA256=.*/NVIM_RELEASE_ARM64_SHA256=\"$fixture_sha\"/" \
    "$fixture_repo/tools/editor/neovim/release.lock.sh"

curl() {
    local output="" url="" argument
    while [[ $# -gt 0 ]]; do
        argument="$1"
        shift
        if [[ "$argument" == --output ]]; then
            output="$1"
            shift
        else
            url="$argument"
        fi
    done
    [[ -n "$output" ]] || return 2
    printf '%s\n' "$url" >> "$NVIM_TEST_DOWNLOAD_LOG"
    if [[ "${NVIM_TEST_BAD_DOWNLOAD:-false}" == true ]]; then
        printf 'invalid archive\n' > "$output"
    elif [[ -n "${NVIM_TEST_ARCHIVE:-}" ]]; then
        cp "$NVIM_TEST_ARCHIVE" "$output"
    else
        return 1
    fi
}

pkg_manager_detect() {
    printf '%s\n' apt-get
}

apt-cache() {
    if [[ "$#" -eq 2 && "$1" == policy && "$2" == neovim ]]; then
        printf 'neovim:\n  Candidate: %s\n' "${NVIM_TEST_CANDIDATE_VERSION:-(none)}"
        return 0
    fi
    return 1
}

pkg_install() {
    printf '%s\n' "$*" >> "$NVIM_TEST_PACKAGE_LOG"
    [[ -n "${NVIM_TEST_PACKAGE_VERSION:-}" ]] && NVIM_TEST_VERSION="$NVIM_TEST_PACKAGE_VERSION"
    return "${NVIM_TEST_PACKAGE_STATUS:-0}"
}

prepare_case() {
    local name="$1" install_value="$2" plugins_value="$3"
    HOME="$test_root/home-$name"
    mkdir -p "$HOME"
    export HOME
    printf '[general]\nbackup_dir = %s/.dev-env-backup\n[neovim]\ninstall = %s\nplugins = %s\n' \
        "$HOME" "$install_value" "$plugins_value" > "$test_root/$name.conf"
    config_load "$test_root/$name.conf" || fail "cannot load config for $name"
    DEVENV_DRY_RUN=false
    NVIM_TEST_PACKAGE_LOG="$test_root/$name.package.log"
    NVIM_TEST_DOWNLOAD_LOG="$test_root/$name.download.log"
    NVIM_TEST_PACKAGE_VERSION=""
    NVIM_TEST_PACKAGE_STATUS=0
    NVIM_TEST_CANDIDATE_VERSION=""
    NVIM_TEST_BAD_DOWNLOAD=false
    NVIM_TEST_ARCHIVE="$fixture_archive"
    export DEVENV_DRY_RUN NVIM_TEST_PACKAGE_LOG NVIM_TEST_DOWNLOAD_LOG
    export NVIM_TEST_PACKAGE_VERSION NVIM_TEST_PACKAGE_STATUS NVIM_TEST_CANDIDATE_VERSION
    export NVIM_TEST_BAD_DOWNLOAD NVIM_TEST_ARCHIVE
    backup_set_root "$HOME/.dev-env-backup" || fail "cannot set backup root"
    backup_begin || fail "cannot begin backup"
}

prepare_case current-floor true true
NVIM_TEST_VERSION=0.10.0
module_apply >/dev/null || fail "current version at floor should apply without upgrade"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
assert_absent "$HOME/.local/bin/nvim"

pkg_manager_detect() { printf 'dnf\n'; }
dnf() {
    [[ "$1" == --cacheonly ]] || return 2
    printf 'Available Packages\nneovim.x86_64 0.10.1-2.fc42 updates\nneovim.x86_64 0.9.5-1.fc42 updates\n'
}
assert_eq "$(module_package_candidate_version)" "0.10.1" "dnf candidate parser should select the highest cached version"
pkg_manager_detect() { printf 'apt-get\n'; }
unset -f dnf

prepare_case install-disabled false true
NVIM_TEST_VERSION=0.7.2
module_apply >/dev/null || fail "install=false should preserve core config apply"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
assert_absent "$HOME/.local/bin/nvim"

prepare_case plugins-disabled true false
NVIM_TEST_VERSION=0.7.2
module_apply >/dev/null || fail "plugins=false should preserve core config apply"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
assert_absent "$HOME/.local/bin/nvim"

prepare_case plugins-disabled-install true false
NVIM_TEST_PACKAGE_VERSION=0.7.2
module_install >/dev/null || fail "plugins=false should keep ordinary package installation"
assert_eq "$(wc -l < "$NVIM_TEST_PACKAGE_LOG" | tr -d ' ')" 1 "plugins=false should use package manager once"
assert_absent "$NVIM_TEST_DOWNLOAD_LOG"

prepare_case local-file-system-floor true true
NVIM_TEST_VERSION=0.10.0
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/nvim" <<'STUB'
#!/bin/bash
printf 'NVIM v0.7.2\n'
STUB
chmod +x "$HOME/.local/bin/nvim"
module_apply >/dev/null || fail "sufficient system nvim should replace a low local command safely"
assert_absent "$HOME/.local/bin/nvim"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
local_file_backup_id="$DEVENV_BACKUP_ID"
backup_restore "$local_file_backup_id" >/dev/null || fail "local nvim file backup restore failed"
assert_file "$HOME/.local/bin/nvim"
assert_eq "$("$HOME/.local/bin/nvim" --version | sed -n '1p')" "NVIM v0.7.2" "restored user nvim executable"

prepare_case package-floor true true
NVIM_TEST_VERSION=0.7.2
NVIM_TEST_PACKAGE_VERSION=0.10.1
NVIM_TEST_CANDIDATE_VERSION=0.10.1
module_apply >/dev/null || fail "package version at floor should be selected"
assert_file "$NVIM_TEST_PACKAGE_LOG"
assert_eq "$(wc -l < "$NVIM_TEST_PACKAGE_LOG" | tr -d ' ')" 1 "package path should run once"
assert_absent "$HOME/.local/bin/nvim"
assert_absent "$NVIM_TEST_DOWNLOAD_LOG"

prepare_case official-release true true
NVIM_TEST_VERSION=0.7.2
NVIM_TEST_PACKAGE_VERSION=0.8.0
NVIM_TEST_CANDIDATE_VERSION=0.8.0
module_apply >/dev/null || fail "lower package candidate should select official release"
assert_eq "$("$HOME/.local/bin/nvim" --version | sed -n '1p')" "NVIM v0.12.6" "release link version"
assert_file "$HOME/.local/opt/nvim-0.12.6/bin/nvim"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
assert_eq "$(wc -l < "$NVIM_TEST_DOWNLOAD_LOG" | tr -d ' ')" 1 "release should download once"
release_backup_id="$DEVENV_BACKUP_ID"
backup_restore "$release_backup_id" >/dev/null || fail "release symlink restore failed"
assert_absent "$HOME/.local/bin/nvim"

prepare_case cached-release true true
NVIM_TEST_VERSION=0.7.2
module_apply >/dev/null || fail "first pinned install failed"
download_count=$(wc -l < "$NVIM_TEST_DOWNLOAD_LOG" | tr -d ' ')
rm "$HOME/.local/bin/nvim"
backup_begin || fail "cannot begin second cached release run"
NVIM_TEST_PACKAGE_VERSION=0.7.2
module_apply >/dev/null || fail "cached pinned install should be reused"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
assert_eq "$(wc -l < "$NVIM_TEST_DOWNLOAD_LOG" | tr -d ' ')" "$download_count" "existing release must not be downloaded again"
assert_eq "$("$HOME/.local/bin/nvim" --version | sed -n '1p')" "NVIM v0.12.6" "cached release version"

prepare_case checksum-mismatch true true
NVIM_TEST_VERSION=0.7.2
mkdir -p "$HOME/.local/bin"
printf '#!/bin/bash\nprintf old\\n\n' > "$test_root/old-nvim"
chmod +x "$test_root/old-nvim"
ln -s "$test_root/old-nvim" "$HOME/.local/bin/nvim"
old_link=$(readlink "$HOME/.local/bin/nvim")
NVIM_TEST_BAD_DOWNLOAD=true
if module_apply > "$test_root/checksum.log" 2>&1; then
    fail "checksum mismatch unexpectedly succeeded"
fi
assert_eq "$(readlink "$HOME/.local/bin/nvim")" "$old_link" "checksum mismatch must preserve existing link"
assert_absent "$HOME/.local/opt/nvim-0.12.6"
grep -q 'Checksum mismatch' "$test_root/checksum.log" || fail "checksum mismatch reason was not reported"

prepare_case dry-run true true
NVIM_TEST_VERSION=0.7.2
DEVENV_DRY_RUN=true
export DEVENV_DRY_RUN
module_apply >/dev/null || fail "dry-run should succeed"
assert_absent "$NVIM_TEST_PACKAGE_LOG"
assert_absent "$NVIM_TEST_DOWNLOAD_LOG"
assert_absent "$HOME/.local/bin/nvim"

prepare_case low-glibc true true
NVIM_TEST_VERSION=0.7.2
NVIM_TEST_PACKAGE_VERSION=0.7.2
getconf() { printf 'glibc 2.31\n'; }
if module_apply > "$test_root/glibc.log" 2>&1; then
    unset -f getconf
    fail "old glibc unexpectedly accepted"
fi
unset -f getconf
assert_absent "$HOME/.local/bin/nvim"
grep -q 'requires glibc >= 2.34' "$test_root/glibc.log" || fail "glibc failure reason was not reported"

prepare_case unsupported-architecture true true
NVIM_TEST_VERSION=0.7.2
NVIM_TEST_PACKAGE_VERSION=0.7.2
uname() { printf 'riscv64\n'; }
if module_apply > "$test_root/architecture.log" 2>&1; then
    unset -f uname
    fail "unsupported architecture unexpectedly accepted"
fi
unset -f uname
grep -q 'Unsupported architecture' "$test_root/architecture.log" || fail "architecture failure reason was not reported"

prepare_case arm64-release true true
NVIM_TEST_VERSION=0.7.2
NVIM_TEST_PACKAGE_VERSION=0.7.2
uname() { printf 'aarch64\n'; }
module_apply >/dev/null || {
    unset -f uname
    fail "aarch64 release selection failed"
}
unset -f uname
grep -q 'nvim-linux-arm64.tar.gz' "$NVIM_TEST_DOWNLOAD_LOG" || fail "arm64 asset was not selected"

prepare_case module-install-entry true true
NVIM_TEST_VERSION=0.7.2
NVIM_TEST_PACKAGE_VERSION=0.10.2
NVIM_TEST_CANDIDATE_VERSION=0.10.2
module_install >/dev/null || fail "initial package install at floor should succeed"
assert_eq "$(wc -l < "$NVIM_TEST_PACKAGE_LOG" | tr -d ' ')" 1 "initial install should call package manager once"
assert_absent "$NVIM_TEST_DOWNLOAD_LOG"

prepare_case no-detected-nvim true true
no_nvim_path="$test_root/path-without-nvim"
mkdir -p "$no_nvim_path"
for command_name in mkdir chmod sed awk; do
    ln -s "$(command -v "$command_name")" "$no_nvim_path/$command_name"
done
PATH="$no_nvim_path"
export PATH
if module_detect; then
    fail "module detection should report an absent nvim"
fi
NVIM_TEST_CANDIDATE_VERSION=0.10.3
pkg_install() {
    printf '%s\n' "$*" >> "$NVIM_TEST_PACKAGE_LOG"
    mkdir -p "$HOME/.local/bin"
    printf '#!/bin/bash\nprintf "NVIM v0.10.3\\n"\n' > "$HOME/.local/bin/nvim"
    chmod +x "$HOME/.local/bin/nvim"
}
module_install >/dev/null || fail "package install should satisfy the initial install path"
module_detect || fail "module detection should find the newly installed user command"
assert_file "$HOME/.local/bin/nvim"
PATH="$test_bin:$original_path"
export PATH
pkg_install() {
    printf '%s\n' "$*" >> "$NVIM_TEST_PACKAGE_LOG"
    [[ -n "${NVIM_TEST_PACKAGE_VERSION:-}" ]] && NVIM_TEST_VERSION="$NVIM_TEST_PACKAGE_VERSION"
    return "${NVIM_TEST_PACKAGE_STATUS:-0}"
}

prepare_case native-release true true
if [[ -n "${NVIM_OFFICIAL_ARCHIVE:-}" ]]; then
    DEVENV_REPO_DIR="$repo_dir"
    export DEVENV_REPO_DIR
    NVIM_TEST_VERSION=0.7.2
    NVIM_TEST_PACKAGE_VERSION=0.7.2
    NVIM_TEST_ARCHIVE="$NVIM_OFFICIAL_ARCHIVE"
    module_apply > "$test_root/native.log" 2>&1 || {
        cat "$test_root/native.log" >&2
        fail "native install of official archive failed"
    }
    assert_eq "$("$HOME/.local/bin/nvim" --version | sed -n '1p')" "NVIM v0.12.6" "native release version"
    "$HOME/.local/bin/nvim" --headless -u "$HOME/.config/nvim/init.vim" +qa! \
        > "$test_root/native-core.log" 2>&1 || {
        cat "$test_root/native-core.log" >&2
        fail "native Neovim core configuration did not load"
    }
    native_backup_id="$DEVENV_BACKUP_ID"
    backup_restore "$native_backup_id" >/dev/null || fail "native release link restore failed"
    assert_absent "$HOME/.local/bin/nvim"
    printf 'native official archive install and core load: %s\n' "$("$HOME/.local/opt/nvim-0.12.6/bin/nvim" --version | sed -n '1p')"
fi

network_root="$test_root/network"
network_home="$test_root/network-home"
network_modules="$network_root/modules"
network_bin="$network_root/bin"
mkdir -p "$network_modules/editor/neovim" "$network_modules/test/continues" "$network_bin" "$network_home"
ln -s "$repo_dir/tools/editor/neovim/module.sh" "$network_modules/editor/neovim/module.sh"
cat > "$network_modules/test/continues/module.sh" <<'STUB'
#!/bin/bash
module_detect() { return 0; }
module_apply() { : > "$HOME/other-module-ran"; }
STUB
for command_name in curl wget apt-get; do
    cat > "$network_bin/$command_name" <<'STUB'
#!/bin/bash
exit 1
STUB
    chmod +x "$network_bin/$command_name"
done
cat > "$network_bin/sudo" <<'STUB'
#!/bin/bash
shift
"$@"
STUB
chmod +x "$network_bin/sudo"
network_config="$network_root/online.conf"
NVIM_TEST_VERSION=0.7.2
export NVIM_TEST_VERSION
cat > "$network_config" <<EOF
[general]
backup_dir = $network_home/.dev-env-backup
[neovim]
install = true
plugins = true
[continues]
enable = true
EOF
set +e
HOME="$network_home" DEVENV_MODULE_ROOT="$network_modules" PATH="$network_bin:$test_bin:$original_path" \
    "$repo_dir/setup_devenv.sh" -c "$network_config" > "$test_root/network.log" 2>&1
network_status=$?
set -e
[[ "$network_status" -ne 0 ]] || fail "network failure should produce a failed module result"
assert_file "$network_home/other-module-ran"
grep -Eq 'Download failed|Neither curl nor wget' "$test_root/network.log" || fail "network failure reason missing"

printf 'neovim release smoke: all checks passed\n'
