#!/bin/bash

set -u
set -o pipefail

REPO_DIR=$(cd -P "$(dirname "$0")/.." && pwd) || exit 2
TEST_ROOT=$(mktemp -d) || exit 2
trap 'rm -rf "$TEST_ROOT"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file_contains() {
    grep -Fq "$2" "$1" || fail "$1 does not contain $2"
}

assert_equal() {
    [[ "$1" == "$2" ]] || fail "expected [$2], got [$1]"
}

home_snapshot() {
    (
        cd "$1" || exit 1
        find . -mindepth 1 -print | sort
        find . -type f -exec sha256sum {} + | sort
    )
}

cat > "$TEST_ROOT/test.conf" <<'CONFIG'
; parser comment
[general]
backup_dir = ~/.dev-env-backup
[success]
enable = yes
install = no
unknown = warning
[failure]
enable = true
install = false
[skip]
enable = true
install = false
[disabled]
enable = false
install = false
[detect3]
enable = true
install = false
[apply3]
enable = true
install = false
[noisy]
enable = true
install = false
CONFIG

cat > "$TEST_ROOT/dry-run.conf" <<'CONFIG'
[general]
backup_dir = ~/.dev-env-backup
[success]
enable = true
CONFIG

cat > "$TEST_ROOT/missing-dry-run.conf" <<'CONFIG'
[general]
backup_dir = ~/.dev-env-backup
[missing]
enable = true
install = true
CONFIG

cat > "$TEST_ROOT/skip-only.conf" <<'CONFIG'
[general]
backup_dir = ~/.dev-env-backup
[skip]
enable = true
install = false
CONFIG

source "$REPO_DIR/lib/log.sh"
source "$REPO_DIR/lib/ini.sh"
source "$REPO_DIR/lib/version.sh"
parsed_bool=false
config_load "$TEST_ROOT/test.conf" || fail "valid INI was rejected"
config_bool success enable parsed_bool || fail "boolean parsing failed"
assert_equal "$parsed_bool" true
expected_backup='~'"/.dev-env-backup"
assert_equal "$(config_get general backup_dir)" "$expected_backup"
assert_equal "$(version_normalize 3.2a)" "3.2.0"
assert_equal "$(version_normalize next-3.4)" "3.4.0"
assert_equal "$(version_normalize 0.7.2)" "0.7.2"
version_at_least 8.2 7.4 || fail "version comparison failed"
version_at_least 3.2a 3.2 || fail "suffix version comparison failed"
[[ "$(version_compare 7.4 8.2)" == -1 ]] || fail "version ordering failed"
assert_equal "$(version_normalize 8.2.0099)" "8.2.99"
assert_equal "$(version_normalize 1.08)" "1.8.0"
assert_equal "$(version_normalize 2.09)" "2.9.0"
cat > "$TEST_ROOT/invalid.conf" <<'CONFIG'
[general]
not a key
CONFIG
if config_load "$TEST_ROOT/invalid.conf" 2>/dev/null; then
    fail "invalid INI was accepted"
fi
cat > "$TEST_ROOT/unknown-section.conf" <<'CONFIG'
[general]
backup_dir = ~/.dev-env-backup
[missing]
enable = true
CONFIG
unknown_home="$TEST_ROOT/unknown-home"
mkdir -p "$unknown_home"
result_tmp="$TEST_ROOT/result-tmp"
mkdir -p "$result_tmp"
set +e
HOME="$unknown_home" TMPDIR="$result_tmp" "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/unknown-section.conf" \
    > "$TEST_ROOT/unknown-section.log" 2>&1
unknown_status=$?
set -e
[[ "$unknown_status" -ne 0 ]] || fail "unknown section was accepted"
assert_file_contains "$TEST_ROOT/unknown-section.log" "No module found"
assert_file_contains "$TEST_ROOT/unknown-section.log" "Tool summary"
assert_equal "$(ls -A "$result_tmp")" ""

list_home="$TEST_ROOT/list-home"
mkdir -p "$list_home/custom-backups/example-backup"
printf '# manifest\n' > "$list_home/custom-backups/example-backup/manifest"
cat > "$TEST_ROOT/custom-backup.conf" <<'CONFIG'
[general]
backup_dir = ~/custom-backups
CONFIG
assert_file_contains <(HOME="$list_home" "$REPO_DIR/setup_devenv.sh" --list-backups \
    -c "$TEST_ROOT/custom-backup.conf") "example-backup"
assert_file_contains <(HOME="$list_home" "$REPO_DIR/setup_devenv.sh" --help) \
    "$REPO_DIR/configs/online.conf"

home="$TEST_ROOT/home"
mkdir -p "$home/.config"
printf 'original link target\n' > "$home/.fixture-link"
printf 'outside rc\n' > "$home/.bashrc"
set +e
HOME="$home" TMPDIR="$result_tmp" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/test.conf" > "$TEST_ROOT/first.log" 2>&1
first_status=$?
set -e
assert_equal "$(ls -A "$result_tmp")" ""
[[ "$first_status" -ne 0 ]] || fail "fixture failure did not affect exit status"
assert_file_contains "$TEST_ROOT/first.log" "success"
assert_file_contains "$TEST_ROOT/first.log" "failure"
assert_file_contains "$TEST_ROOT/first.log" "Unknown [success] key: unknown"
if grep -Fq "Unknown [success] key: enable" "$TEST_ROOT/first.log"; then
    fail "common enable key was incorrectly warned"
fi
assert_file_contains "$TEST_ROOT/first.log" "skip"
assert_file_contains "$TEST_ROOT/first.log" "skipped"
assert_file_contains "$TEST_ROOT/first.log" "disabled"
assert_file_contains "$TEST_ROOT/first.log" "detect3"
assert_file_contains "$TEST_ROOT/first.log" "apply3"
assert_file_contains "$TEST_ROOT/first.log" "detection failed (status 3)"
assert_file_contains "$TEST_ROOT/first.log" "module_apply returned status 3 without module_skip"
detect_line=$(grep -n "module detect output" "$TEST_ROOT/first.log" | cut -d: -f1)
apply_line=$(grep -n "module apply output" "$TEST_ROOT/first.log" | cut -d: -f1)
log_line=$(grep -n "module log output" "$TEST_ROOT/first.log" | cut -d: -f1)
[[ "$detect_line" -lt "$apply_line" && "$apply_line" -lt "$log_line" ]] \
    || fail "module output order was not preserved"
[[ -L "$home/.fixture-link" ]] || fail "link was not deployed"
assert_equal "$(readlink "$home/.fixture-link")" "$REPO_DIR/tests/fixtures/source.txt"
assert_file_contains "$home/.bashrc" "PORTABLE_DEVENV_FIXTURE=1"

backup_id=$(HOME="$home" "$REPO_DIR/setup_devenv.sh" --list-backups | tail -n 1)
[[ -n "$backup_id" ]] || fail "backup was not listed"
backup_count_before=$(find "$home/.dev-env-backup" -mindepth 1 -maxdepth 1 -type d | wc -l)
HOME="$home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/dry-run.conf" >/dev/null
backup_count_after_idempotent=$(find "$home/.dev-env-backup" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_equal "$backup_count_after_idempotent" "$backup_count_before"
dry_run_snapshot_before=$(home_snapshot "$home")
HOME="$home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/dry-run.conf" --dry-run >/dev/null
dry_run_snapshot_after=$(home_snapshot "$home")
assert_equal "$dry_run_snapshot_after" "$dry_run_snapshot_before"
[[ -L "$home/.fixture-link" ]] || fail "dry-run changed a link unexpectedly"
assert_equal "$(readlink "$home/.fixture-link")" "$REPO_DIR/tests/fixtures/source.txt"
backup_count_after=$(find "$home/.dev-env-backup" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_equal "$backup_count_after" "$backup_count_before"

restore_dry_snapshot_before=$(home_snapshot "$home")
HOME="$home" "$REPO_DIR/setup_devenv.sh" --restore "$backup_id" --dry-run >/dev/null
restore_dry_snapshot_after=$(home_snapshot "$home")
assert_equal "$restore_dry_snapshot_after" "$restore_dry_snapshot_before"

HOME="$home" "$REPO_DIR/setup_devenv.sh" --restore "$backup_id" >/dev/null
[[ -f "$home/.fixture-link" ]] || fail "file backup was not restored"
assert_equal "$(cat "$home/.fixture-link")" "original link target"
assert_equal "$(cat "$home/.bashrc")" "outside rc"

multi_home="$TEST_ROOT/multi-home"
mkdir -p "$multi_home/.multi-directory-a" "$multi_home/.multi-directory-b"
printf 'original multi A\n' > "$multi_home/.multi-file-a"
printf 'original multi B\n' > "$multi_home/.multi-file-b"
printf 'original directory A\n' > "$multi_home/.multi-directory-a/file"
printf 'original directory B\n' > "$multi_home/.multi-directory-b/file"
ln -s /original/multi-a "$multi_home/.multi-link-a"
ln -s /original/multi-b "$multi_home/.multi-link-b"
printf 'original rc A\n' > "$multi_home/.multi-rc-a"
printf 'original rc B\n' > "$multi_home/.multi-rc-b"
cat > "$TEST_ROOT/multi.conf" <<'CONFIG'
[general]
backup_dir = ~/.multi-backups
[multi-a]
enable = true
[multi-b]
enable = true
CONFIG
HOME="$multi_home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/multi.conf" >/dev/null \
    || fail "multi-module backup setup failed"
multi_backup_id=$(HOME="$multi_home" "$REPO_DIR/setup_devenv.sh" --list-backups \
    -c "$TEST_ROOT/multi.conf" | tail -n 1)
multi_manifest="$multi_home/.multi-backups/$multi_backup_id/manifest"
multi_duplicate_saved=$(awk -F '\t' \
    '$1 == "BEFORE" && ($2 == "file" || $2 == "directory") { print $5 }' \
    "$multi_manifest" | sort | uniq -d)
[[ -z "$multi_duplicate_saved" ]] || fail "multi-module backup items collided"
multi_snapshot_before=$(home_snapshot "$multi_home")
HOME="$multi_home" "$REPO_DIR/setup_devenv.sh" --restore "$multi_backup_id" \
    -c "$TEST_ROOT/multi.conf" --dry-run >/dev/null \
    || fail "multi-module restore dry-run failed"
multi_snapshot_after=$(home_snapshot "$multi_home")
assert_equal "$multi_snapshot_after" "$multi_snapshot_before"
HOME="$multi_home" "$REPO_DIR/setup_devenv.sh" --restore "$multi_backup_id" \
    -c "$TEST_ROOT/multi.conf" >/dev/null \
    || fail "multi-module restore failed"
assert_equal "$(cat "$multi_home/.multi-file-a")" "original multi A"
assert_equal "$(cat "$multi_home/.multi-file-b")" "original multi B"
assert_equal "$(cat "$multi_home/.multi-directory-a/file")" "original directory A"
assert_equal "$(cat "$multi_home/.multi-directory-b/file")" "original directory B"
assert_equal "$(readlink "$multi_home/.multi-link-a")" "/original/multi-a"
assert_equal "$(readlink "$multi_home/.multi-link-b")" "/original/multi-b"
assert_file_contains "$multi_home/.multi-rc-a" "original rc A"
assert_file_contains "$multi_home/.multi-rc-b" "original rc B"
[[ ! -e "$multi_home/.multi-none-a" && ! -L "$multi_home/.multi-none-a" ]] \
    || fail "multi-module absent target A was not restored"
[[ ! -e "$multi_home/.multi-none-b" && ! -L "$multi_home/.multi-none-b" ]] \
    || fail "multi-module absent target B was not restored"

displace_home="$TEST_ROOT/displace-home"
mkdir -p "$displace_home/.config/nvim" "$displace_home/.displace-directory"
printf 'displace original file\n' > "$displace_home/.displace-file"
chmod 0640 "$displace_home/.displace-file"
ln -s /original/displace-target "$displace_home/.displace-link"
printf 'displace original directory\n' > "$displace_home/.displace-directory/file"
chmod 0750 "$displace_home/.displace-directory"
cat > "$TEST_ROOT/displace.conf" <<'CONFIG'
[general]
backup_dir = ~/.displace-backups
[displace]
enable = true
install = false
CONFIG
HOME="$displace_home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/displace.conf" >/dev/null \
    || fail "displace module failed"
[[ ! -e "$displace_home/.displace-file" && ! -L "$displace_home/.displace-file" ]] \
    || fail "displace file was not removed"
[[ ! -e "$displace_home/.displace-link" && ! -L "$displace_home/.displace-link" ]] \
    || fail "displace link was not removed"
[[ ! -e "$displace_home/.displace-directory" && ! -L "$displace_home/.displace-directory" ]] \
    || fail "displace directory was not removed"
displace_backup_id=$(HOME="$displace_home" "$REPO_DIR/setup_devenv.sh" \
    --list-backups -c "$TEST_ROOT/displace.conf" | tail -n 1)
displace_manifest="$displace_home/.displace-backups/$displace_backup_id/manifest"
[[ "$(awk -F '\t' '$1 == "AFTER_ABSENT" { count++ } END { print count + 0 }' \
    "$displace_manifest")" -eq 3 ]] || fail "displace records were incomplete"
displace_snapshot_before=$(home_snapshot "$displace_home")
HOME="$displace_home" "$REPO_DIR/setup_devenv.sh" --restore "$displace_backup_id" \
    --dry-run -c "$TEST_ROOT/displace.conf" \
    > "$TEST_ROOT/displace-restore-dry.log" 2>&1 \
    || fail "displace restore dry-run failed"
assert_equal "$(home_snapshot "$displace_home")" "$displace_snapshot_before"
assert_file_contains "$TEST_ROOT/displace-restore-dry.log" \
    "[DRY-RUN] Would restore $displace_home/.displace-file"
assert_file_contains "$TEST_ROOT/displace-restore-dry.log" \
    "[DRY-RUN] Would restore $displace_home/.displace-link"
assert_file_contains "$TEST_ROOT/displace-restore-dry.log" \
    "[DRY-RUN] Would restore $displace_home/.displace-directory"
HOME="$displace_home" "$REPO_DIR/setup_devenv.sh" --restore "$displace_backup_id" \
    -c "$TEST_ROOT/displace.conf" >/dev/null \
    || fail "displace restore failed"
assert_equal "$(cat "$displace_home/.displace-file")" "displace original file"
assert_equal "$(stat -c '%a' "$displace_home/.displace-file")" "640"
[[ -L "$displace_home/.displace-link" ]] || fail "displace link was not restored"
assert_equal "$(readlink "$displace_home/.displace-link")" "/original/displace-target"
[[ -d "$displace_home/.displace-directory" ]] \
    || fail "displace directory was not restored"
assert_equal "$(cat "$displace_home/.displace-directory/file")" \
    "displace original directory"
assert_equal "$(stat -c '%a' "$displace_home/.displace-directory")" "750"
[[ ! -e "$displace_home/.displace-none" && ! -L "$displace_home/.displace-none" ]] \
    || fail "absent displace target changed"
printf 'user recreated init.lua\n' > "$displace_home/.displace-file"
set +e
HOME="$displace_home" "$REPO_DIR/setup_devenv.sh" --restore "$displace_backup_id" \
    -c "$TEST_ROOT/displace.conf" >/dev/null 2>&1
displace_conflict_status=$?
set -e
[[ "$displace_conflict_status" -ne 0 ]] \
    || fail "restore overwrote a recreated displaced target"
assert_equal "$(cat "$displace_home/.displace-file")" "user recreated init.lua"

mkdir -p "$home/.fixture-directory"
printf 'directory content\n' > "$home/.fixture-directory/file"
source "$REPO_DIR/lib/backup.sh"
source "$REPO_DIR/lib/deploy.sh"
export HOME="$home" DEVENV_DRY_RUN=false
mixed_home="$TEST_ROOT/mixed-home"
mkdir -p "$mixed_home/original-directory"
printf 'mixed file\n' > "$mixed_home/original-file"
printf 'mixed directory\n' > "$mixed_home/original-directory/file"
ln -s /elsewhere/original-target "$mixed_home/original-link"
cat > "$TEST_ROOT/mixed-backup.conf" <<CONFIG
[general]
backup_dir = $mixed_home/.mixed-backups
CONFIG
export HOME="$mixed_home"
backup_set_root "$mixed_home/.mixed-backups" || fail "mixed backup root rejected"
backup_begin || fail "mixed backup did not start"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$mixed_home/original-file" || fail "mixed file deploy failed"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$mixed_home/original-link" || fail "mixed link deploy failed"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$mixed_home/original-directory" || fail "mixed directory deploy failed"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$mixed_home/original-none" || fail "mixed absent deploy failed"
mixed_backup_id="$DEVENV_BACKUP_ID"
mixed_snapshot_before=$(home_snapshot "$mixed_home")
HOME="$mixed_home" "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/mixed-backup.conf" \
    --restore "$mixed_backup_id" --dry-run >/dev/null
mixed_snapshot_after=$(home_snapshot "$mixed_home")
assert_equal "$mixed_snapshot_after" "$mixed_snapshot_before"
HOME="$mixed_home" "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/mixed-backup.conf" \
    --restore "$mixed_backup_id" >/dev/null
assert_equal "$(cat "$mixed_home/original-file")" "mixed file"
[[ -L "$mixed_home/original-link" ]] || fail "mixed link was not restored"
assert_equal "$(readlink "$mixed_home/original-link")" "/elsewhere/original-target"
assert_file_contains "$mixed_home/original-directory/file" "mixed directory"
[[ ! -e "$mixed_home/original-none" && ! -L "$mixed_home/original-none" ]] \
    || fail "mixed absent target was not restored"

duplicate_displace_home="$TEST_ROOT/duplicate-displace-home"
mkdir -p "$duplicate_displace_home"
printf 'duplicate displace\n' > "$duplicate_displace_home/.target"
export HOME="$duplicate_displace_home" DEVENV_DRY_RUN=false
backup_set_root "$duplicate_displace_home/.duplicate-displace-backups" \
    || fail "duplicate displace backup root rejected"
backup_begin || fail "duplicate displace backup did not start"
deploy_displace "$duplicate_displace_home/.target" \
    || fail "first displace did not succeed"
if deploy_displace "$duplicate_displace_home/.target"; then
    fail "repeated displace was accepted in one backup run"
fi

evil_home="$TEST_ROOT/evil-home"
mkdir -p "$evil_home/.dev-env-backup/evil1" "$evil_home/.dev-env-backup/evil2"
ln -s "$REPO_DIR/tests/fixtures/source.txt" "$evil_home/victim"
{
    printf 'BEFORE\tfile\t%s\t-\t/etc/hostname\n' "$evil_home/victim"
    printf 'AFTER_LINK\t%s\t%s\n' "$evil_home/victim" "$REPO_DIR/tests/fixtures/source.txt"
} > "$evil_home/.dev-env-backup/evil1/manifest"
set +e
HOME="$evil_home" "$REPO_DIR/setup_devenv.sh" --restore evil1 >/dev/null 2>&1
evil_status=$?
set -e
[[ "$evil_status" -ne 0 ]] || fail "manifest outside backup was accepted"
[[ -L "$evil_home/victim" ]] || fail "unsafe manifest changed victim"
{
    printf 'AFTER_LINK\t%s\t%s\n' "$evil_home/../outside" "$REPO_DIR/tests/fixtures/source.txt"
} > "$evil_home/.dev-env-backup/evil2/manifest"
set +e
HOME="$evil_home" "$REPO_DIR/setup_devenv.sh" --restore evil2 >/dev/null 2>&1
unsafe_target_status=$?
set -e
[[ "$unsafe_target_status" -ne 0 ]] || fail "unsafe manifest target was accepted"

export HOME="$home"
backup_set_root "$home/.directory-backups" || fail "custom backup root rejected"
backup_begin || fail "backup run did not start"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$home/.fixture-directory" || fail "directory replacement failed"
[[ -L "$home/.fixture-directory" ]] || fail "directory was not replaced by a link"
directory_backup_id="$DEVENV_BACKUP_ID"
backup_restore "$directory_backup_id" || fail "directory restore failed"
[[ -d "$home/.fixture-directory" ]] || fail "directory was not restored"
assert_file_contains "$home/.fixture-directory/file" "directory content"

printf 'wrong target\n' > "$home/.fixture-link"
if HOME="$home" "$REPO_DIR/setup_devenv.sh" --restore "$backup_id" >/dev/null 2>&1; then
    fail "restore overwrote a changed target"
fi
assert_equal "$(cat "$home/.fixture-link")" "wrong target"

new_dry_home="$TEST_ROOT/new-dry-home"
mkdir -p "$new_dry_home"
new_dry_before=$(home_snapshot "$new_dry_home")
HOME="$new_dry_home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/dry-run.conf" --dry-run >/dev/null
new_dry_after=$(home_snapshot "$new_dry_home")
assert_equal "$new_dry_after" "$new_dry_before"
[[ ! -e "$new_dry_home/.fixture-link" ]] || fail "new dry-run changed HOME"

set +e
HOME="$TEST_ROOT/missing-dry-home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/missing-dry-run.conf" --dry-run \
    > "$TEST_ROOT/missing-dry-run.log" 2>&1
missing_dry_status=$?
set -e
[[ "$missing_dry_status" -eq 0 ]] || fail "dry-run install was treated as failure"
assert_file_contains "$TEST_ROOT/missing-dry-run.log" "skipped"
assert_file_contains "$TEST_ROOT/missing-dry-run.log" "dry-run: would install"

set +e
HOME="$TEST_ROOT/skip-only-home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/skip-only.conf" \
    > "$TEST_ROOT/skip-only.log" 2>&1
skip_only_status=$?
set -e
[[ "$skip_only_status" -eq 0 ]] || fail "skip-only config returned failure"
assert_file_contains "$TEST_ROOT/skip-only.log" "skipped"

source "$REPO_DIR/lib/package.sh"
pkg_manager_detect() {
    return 1
}
set +e
pkg_install imaginary-package >/dev/null 2>&1
pkg_status=$?
set -e
if [[ "$pkg_status" -eq 0 ]]; then
    fail "missing package manager was not reported as skipped"
fi
assert_equal "$pkg_status" "3"

download_home="$TEST_ROOT/download-home"
mkdir -p "$download_home"
printf 'source payload\n' > "$TEST_ROOT/download-source"
printf 'original destination\n' > "$download_home/download-target"
source "$REPO_DIR/lib/download.sh"
source "$REPO_DIR/lib/backup.sh"
source "$REPO_DIR/lib/rcblock.sh"
wrong_digest=0000000000000000000000000000000000000000000000000000000000000000
if command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1; then
    if HOME="$download_home" download_file "file://$TEST_ROOT/download-source" \
        "$download_home/download-target" "$wrong_digest"; then
        fail "checksum mismatch was accepted"
    fi
    assert_equal "$(cat "$download_home/download-target")" "original destination"
    [[ -z "$(find "$download_home" -name '.portable-devenv-download.*' -print)" ]] \
        || fail "download temporary file remained"
fi

rc_home="$TEST_ROOT/rc-home"
mkdir -p "$rc_home"
printf 'outside rc\n' > "$rc_home/.bashrc"
chmod 0644 "$rc_home/.bashrc"
printf 'export RC_FIXTURE=one\n' > "$TEST_ROOT/rc-one"
printf 'export RC_FIXTURE=two\n' > "$TEST_ROOT/rc-two"
export HOME="$rc_home" DEVENV_DRY_RUN=false
backup_set_root "$rc_home/.rc-backups" || fail "rc backup root rejected"
backup_begin || fail "rc backup did not start"
rc_block_apply "$rc_home/.bashrc" "$TEST_ROOT/rc-one" || fail "rc initial apply failed"
assert_equal "$(stat -c '%a' "$rc_home/.bashrc")" "644"
rc_block_apply "$rc_home/.bashrc" "$TEST_ROOT/rc-two" || fail "rc replacement failed"
assert_file_contains "$rc_home/.bashrc" "RC_FIXTURE=two"
if grep -Fq "RC_FIXTURE=one" "$rc_home/.bashrc"; then
    fail "rc block was duplicated instead of replaced"
fi
rc_backup_id="$DEVENV_BACKUP_ID"
backup_restore "$rc_backup_id" || fail "changed rc restore failed"
assert_equal "$(cat "$rc_home/.bashrc")" "outside rc"
assert_equal "$(stat -c '%a' "$rc_home/.bashrc")" "644"

new_rc_home="$TEST_ROOT/new-rc-home"
mkdir -p "$new_rc_home"
export HOME="$new_rc_home"
backup_set_root "$new_rc_home/.rc-backups" || fail "new rc backup root rejected"
backup_begin || fail "new rc backup did not start"
rc_block_apply "$new_rc_home/.bashrc" "$TEST_ROOT/rc-one" || fail "new rc apply failed"
new_rc_backup_id="$DEVENV_BACKUP_ID"
[[ -f "$new_rc_home/.bashrc" ]] || fail "new rc file was not created"
backup_restore "$new_rc_backup_id" || fail "new rc restore failed"
[[ ! -e "$new_rc_home/.bashrc" ]] || fail "new rc file was not removed on restore"

malformed_rc="$new_rc_home/malformed-rc"
printf '%s\n' "$DEVENV_RC_BLOCK_START" "$DEVENV_RC_BLOCK_START" "$DEVENV_RC_BLOCK_END" \
    > "$malformed_rc"
if rc_block_apply "$malformed_rc" "$TEST_ROOT/rc-one"; then
    fail "duplicate rc markers were accepted"
fi

export HOME="$home"
source "$REPO_DIR/lib/backup.sh"
if backup_path_is_safe "$HOME/../escaped"; then
    fail "parent traversal path was accepted"
fi
if deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$HOME/../escaped-link"; then
    fail "deploy accepted parent traversal path"
fi
tab_name=$(printf 'a\tb')
if backup_path_is_safe "$HOME/$tab_name"; then
    fail "tab path was accepted"
fi
newline_name=$(printf 'a\nb')
if backup_path_is_safe "$HOME/$newline_name"; then
    fail "newline path was accepted"
fi
if backup_path_is_safe "$HOME"; then
    fail "HOME itself was accepted"
fi
for normal_path in "$HOME/.vimrc" "$HOME/a/b" "$HOME/..hidden" "$HOME/a..b"; do
    backup_path_is_safe "$normal_path" || fail "normal path was rejected: $normal_path"
done
for noncanonical_path in "$HOME/a//b" "$HOME/a///b" "$HOME/a/" "$HOME/a/./b" "$HOME/a/../b"; do
    if backup_path_is_safe "$noncanonical_path"; then
        fail "non-canonical path was accepted: $noncanonical_path"
    fi
done
for home_variant in "$HOME/" "$HOME/." "$HOME//" "$HOME/./"; do
    if backup_path_is_safe "$home_variant"; then
        fail "HOME variant was accepted: $home_variant"
    fi
done
cat > "$TEST_ROOT/unsafe-backup.conf" <<'CONFIG'
[general]
backup_dir = ~/../escaped-backup
CONFIG
if HOME="$home" "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/unsafe-backup.conf" --dry-run \
    >/dev/null 2>&1; then
    fail "unsafe backup_dir was accepted"
fi
if env -u HOME "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/dry-run.conf" --dry-run \
    >/dev/null 2>&1; then
    fail "empty HOME was accepted"
fi
if HOME=/ "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/dry-run.conf" --dry-run \
    >/dev/null 2>&1; then
    fail "root HOME was accepted"
fi

# Restore must reject every manifest whose saved path or target is not exactly
# what a backup run writes, in dry-run and real mode, without touching anything.
tamper_outside="$TEST_ROOT/tamper-outside"
mkdir -p "$tamper_outside/secret-dir"
printf 'OUTSIDE SECRET\n' > "$tamper_outside/secret.txt"
printf 'OUTSIDE DIRECTORY SECRET\n' > "$tamper_outside/secret-dir/file"
tamper_case_number=0

assert_tampered_restore_rejected() {
    local description="$1" backup_type="$2" saved_template="$3" target_template="${4:-@HOME@/.victim}"
    local tamper_home restore_path saved_path target mode status before_snapshot outside_before
    tamper_case_number=$((tamper_case_number + 1))
    tamper_home="$TEST_ROOT/tamper-$tamper_case_number-home"
    restore_path="$tamper_home/.dev-env-backup/tamper"
    mkdir -p "$restore_path/sub"
    printf 'saved content\n' > "$restore_path/item-001"
    printf 'saved content\n' > "$restore_path/sub/item-001"
    printf 'saved content\n' > "$restore_path/other-file"
    ln -s "$REPO_DIR/tests/fixtures/source.txt" "$tamper_home/.victim"
    saved_path="${saved_template//@BACKUP@/$restore_path}"
    saved_path="${saved_path//@OUTSIDE@/$tamper_outside}"
    target="${target_template//@HOME@/$tamper_home}"
    {
        printf 'BEFORE\t%s\t%s\t-\t%s\n' "$backup_type" "$target" "$saved_path"
        printf 'AFTER_LINK\t%s\t%s\n' "$target" "$REPO_DIR/tests/fixtures/source.txt"
    } > "$restore_path/manifest"
    before_snapshot=$(home_snapshot "$tamper_home")
    outside_before=$(home_snapshot "$tamper_outside")
    for mode in real dry-run; do
        status=0
        if [[ "$mode" == real ]]; then
            HOME="$tamper_home" "$REPO_DIR/setup_devenv.sh" --restore tamper \
                > "$TEST_ROOT/tamper.log" 2>&1 || status=$?
        else
            HOME="$tamper_home" "$REPO_DIR/setup_devenv.sh" --restore tamper --dry-run \
                > "$TEST_ROOT/tamper.log" 2>&1 || status=$?
        fi
        [[ "$status" -ne 0 ]] || fail "tampered manifest accepted ($description, $mode)"
        assert_file_contains "$TEST_ROOT/tamper.log" "[ERROR]"
        assert_equal "$(home_snapshot "$tamper_home")" "$before_snapshot"
        assert_equal "$(home_snapshot "$tamper_outside")" "$outside_before"
        [[ -L "$tamper_home/.victim" ]] || fail "tampered manifest changed the target ($description, $mode)"
    done
}

assert_tampered_restore_rejected "dotdot below backup prefix" file \
    '@BACKUP@/../../../tamper-outside/secret.txt'
assert_tampered_restore_rejected "dotdot directory" directory \
    '@BACKUP@/../../../tamper-outside/secret-dir'
assert_tampered_restore_rejected "absolute path outside backup" file '@OUTSIDE@/secret.txt'
assert_tampered_restore_rejected "nested item" file '@BACKUP@/sub/item-001'
assert_tampered_restore_rejected "dot component" file '@BACKUP@/./item-001'
assert_tampered_restore_rejected "repeated slash" file '@BACKUP@//item-001'
assert_tampered_restore_rejected "item dotdot" file '@BACKUP@/item-001/../other-file'
assert_tampered_restore_rejected "non item name" file '@BACKUP@/other-file'
assert_tampered_restore_rejected "missing item" file '@BACKUP@/item-999'
assert_tampered_restore_rejected "unknown type" socket '@BACKUP@/item-001'
assert_tampered_restore_rejected "unsafe target" file '@BACKUP@/item-001' \
    '@HOME@/../tamper-outside/target.txt'
assert_tampered_restore_rejected "target outside HOME" file '@BACKUP@/item-001' '/tmp/portable-devenv-outside'
[[ ! -e /tmp/portable-devenv-outside ]] || fail "target outside HOME was created"

duplicate_home="$TEST_ROOT/duplicate-manifest-home"
duplicate_restore_path="$duplicate_home/.dev-env-backup/duplicate"
mkdir -p "$duplicate_restore_path"
printf 'duplicate saved content\n' > "$duplicate_restore_path/item-001"
ln -s /duplicate-a "$duplicate_home/.duplicate-a"
ln -s /duplicate-b "$duplicate_home/.duplicate-b"
{
    printf 'BEFORE\tfile\t%s\t-\t%s\n' "$duplicate_home/.duplicate-a" \
        "$duplicate_restore_path/item-001"
    printf 'BEFORE\tfile\t%s\t-\t%s\n' "$duplicate_home/.duplicate-b" \
        "$duplicate_restore_path/item-001"
    printf 'AFTER_LINK\t%s\t%s\n' "$duplicate_home/.duplicate-a" \
        "$REPO_DIR/tests/fixtures/source.txt"
    printf 'AFTER_LINK\t%s\t%s\n' "$duplicate_home/.duplicate-b" \
        "$REPO_DIR/tests/fixtures/source.txt"
} > "$duplicate_restore_path/manifest"
duplicate_snapshot=$(home_snapshot "$duplicate_home")
for mode in real dry-run; do
    duplicate_status=0
    if [[ "$mode" == real ]]; then
        HOME="$duplicate_home" "$REPO_DIR/setup_devenv.sh" --restore duplicate \
            > "$TEST_ROOT/duplicate-manifest.log" 2>&1 || duplicate_status=$?
    else
        HOME="$duplicate_home" "$REPO_DIR/setup_devenv.sh" --restore duplicate --dry-run \
            > "$TEST_ROOT/duplicate-manifest.log" 2>&1 || duplicate_status=$?
    fi
    [[ "$duplicate_status" -ne 0 ]] \
        || fail "duplicate manifest saved path was accepted ($mode)"
    assert_file_contains "$TEST_ROOT/duplicate-manifest.log" "Duplicate manifest backup path"
    assert_equal "$(home_snapshot "$duplicate_home")" "$duplicate_snapshot"
done

assert_invalid_absent_manifest() {
    local label="$1" manifest_body="$2"
    local invalid_home="$TEST_ROOT/invalid-absent-$label-home"
    local invalid_path="$invalid_home/.dev-env-backup/$label"
    local target="$invalid_home/.victim" mode invalid_status snapshot
    mkdir -p "$invalid_path"
    printf 'saved content\n' > "$invalid_path/item-001"
    ln -s "$REPO_DIR/tests/fixtures/source.txt" "$target"
    printf '%s\n' "${manifest_body//@TARGET@/$target}" > "$invalid_path/manifest"
    snapshot=$(home_snapshot "$invalid_home")
    for mode in real dry-run; do
        invalid_status=0
        if [[ "$mode" == real ]]; then
            HOME="$invalid_home" "$REPO_DIR/setup_devenv.sh" --restore "$label" \
                > "$TEST_ROOT/invalid-absent.log" 2>&1 || invalid_status=$?
        else
            HOME="$invalid_home" "$REPO_DIR/setup_devenv.sh" --restore "$label" \
                --dry-run > "$TEST_ROOT/invalid-absent.log" 2>&1 || invalid_status=$?
        fi
        [[ "$invalid_status" -ne 0 ]] \
            || fail "invalid AFTER_ABSENT manifest was accepted ($label, $mode)"
        assert_equal "$(home_snapshot "$invalid_home")" "$snapshot"
        [[ -L "$target" ]] || fail "invalid manifest changed target ($label, $mode)"
    done
}

assert_invalid_absent_manifest missing-before 'AFTER_ABSENT	@TARGET@'
assert_invalid_absent_manifest before-none $'BEFORE\tnone\t@TARGET@\t-\t-\nAFTER_ABSENT\t@TARGET@'
assert_invalid_absent_manifest extra-field 'AFTER_ABSENT	@TARGET@	extra'

# Termination signals must stop the script, its running module and everything
# the module started, run no later module, and leave no result file behind.
cat > "$TEST_ROOT/signal.conf" <<'CONFIG'
[general]
backup_dir = ~/.dev-env-backup
[signal-slow]
enable = true
[signal-after]
enable = true
CONFIG

wait_for_file() {
    local wanted="$1" tick
    for ((tick = 0; tick < 100; tick++)); do
        [[ -e "$wanted" ]] && return 0
        sleep 0.1
    done
    return 1
}

assert_process_gone() {
    local process_id="$1" tick
    for ((tick = 0; tick < 50; tick++)); do
        kill -0 "$process_id" 2>/dev/null || return 0
        sleep 0.1
    done
    kill -KILL "$process_id" 2>/dev/null || true
    fail "process $process_id survived termination"
}

assert_signal_stops_script() {
    local signal_name="$1" expected_status="$2" label="signal-$1"
    local marker_dir="$TEST_ROOT/$label-marker" signal_tmp="$TEST_ROOT/$label-tmp"
    local signal_home="$TEST_ROOT/$label-home" signal_log="$TEST_ROOT/$label.log"
    local script_pid tick exit_status=0
    mkdir -p "$marker_dir" "$signal_tmp" "$signal_home"
    # Job control keeps SIGINT enabled for the background job; plain background jobs ignore it.
    set -m
    DEVENV_TEST_MARKER_DIR="$marker_dir" HOME="$signal_home" TMPDIR="$signal_tmp" \
        DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
        "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/signal.conf" > "$signal_log" 2>&1 < /dev/null &
    script_pid=$!
    set +m
    wait_for_file "$marker_dir/sleeper.pid" || {
        kill -KILL "$script_pid" 2>/dev/null || true
        fail "slow module did not start ($signal_name)"
    }
    [[ -n "$(ls "$signal_tmp")" ]] || fail "no result file existed while the module ran"
    kill "-$signal_name" "$script_pid"
    for ((tick = 0; tick < 100; tick++)); do
        kill -0 "$script_pid" 2>/dev/null || break
        sleep 0.1
    done
    if kill -0 "$script_pid" 2>/dev/null; then
        kill -KILL "$script_pid" 2>/dev/null || true
        fail "script ignored SIG$signal_name"
    fi
    wait "$script_pid" || exit_status=$?
    assert_equal "$exit_status" "$expected_status"
    assert_process_gone "$(cat "$marker_dir/wrapper.pid")"
    assert_process_gone "$(cat "$marker_dir/sleeper.pid")"
    [[ ! -e "$marker_dir/slow-finished" ]] || fail "module kept running after SIG$signal_name"
    [[ ! -e "$marker_dir/after-ran" ]] || fail "later module ran after SIG$signal_name"
    assert_equal "$(ls -A "$signal_tmp")" ""
    assert_file_contains "$signal_log" "Interrupted by SIG$signal_name"
    if grep -Fq "failed" "$signal_log"; then
        fail "interruption was reported as a module failure ($signal_name)"
    fi
}

assert_signal_stops_script TERM 143
assert_signal_stops_script HUP 129
assert_signal_stops_script INT 130

# A trailing slash on backup_dir is dropped; other non-canonical spellings are
# rejected with the actual reason.
slash_home="$TEST_ROOT/slash-home"
mkdir -p "$slash_home"
cat > "$TEST_ROOT/slash-backup.conf" <<'CONFIG'
[general]
backup_dir = ~/slash-backup/
[success]
enable = true
install = false
CONFIG
HOME="$slash_home" DEVENV_MODULE_ROOT="$REPO_DIR/tests/fixtures/tools" \
    "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/slash-backup.conf" > "$TEST_ROOT/slash-backup.log" 2>&1 \
    || fail "backup_dir with a trailing slash was rejected"
slash_backup_id=$(HOME="$slash_home" "$REPO_DIR/setup_devenv.sh" --list-backups -c "$TEST_ROOT/slash-backup.conf")
[[ -n "$slash_backup_id" && -f "$slash_home/slash-backup/$slash_backup_id/manifest" ]] \
    || fail "backup was not stored under the normalized backup_dir"

assert_backup_dir_rejected() {
    local spelling="$1" expected_reason="$2" status=0
    printf '[general]\nbackup_dir = %s\n' "$spelling" > "$TEST_ROOT/backup-dir-spelling.conf"
    HOME="$slash_home" "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/backup-dir-spelling.conf" --dry-run \
        > "$TEST_ROOT/backup-dir-spelling.log" 2>&1 || status=$?
    assert_equal "$status" "2"
    assert_file_contains "$TEST_ROOT/backup-dir-spelling.log" "$expected_reason"
}
config_tilde='~'
assert_backup_dir_rejected "$config_tilde/" "HOME itself"
assert_backup_dir_rejected "$config_tilde//" "HOME itself"
assert_backup_dir_rejected "./bk" "'.' or '..' component"
assert_backup_dir_rejected "$config_tilde/bk/." "'.' or '..' component"
assert_backup_dir_rejected "$config_tilde/a//b" "empty component"
assert_backup_dir_rejected "$config_tilde/a///b" "empty component"
assert_backup_dir_rejected "/outside-home/bk" "outside HOME"

special_home="$TEST_ROOT/special-home"
mkdir -p "$special_home"
export HOME="$special_home" DEVENV_DRY_RUN=false
printf 'original other target\n' > "$HOME/.other-target"
backup_set_root "$HOME/.special-backups" || fail "special backup root rejected"
backup_begin || fail "special backup run did not start"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$HOME/.other-target" \
    || fail "normal target setup failed"
mkfifo "$HOME/.fifo-target"
if deploy_displace "$HOME/.fifo-target"; then
    fail "FIFO displacement was accepted"
fi
[[ -p "$HOME/.fifo-target" ]] || fail "FIFO target changed"
! grep -F "$HOME/.fifo-target" "$DEVENV_BACKUP_PATH/manifest" \
    || fail "FIFO displacement wrote a manifest record"

socket_path="$HOME/.socket-target"
if command -v python3 >/dev/null 2>&1; then
python3 - "$socket_path" <<'PY' &
import socket
import sys
listener = socket.socket(socket.AF_UNIX)
listener.bind(sys.argv[1])
listener.listen(1)
listener.accept()
PY
socket_pid=$!
    for ((tick = 0; tick < 50; tick++)); do
        [[ -S "$socket_path" ]] && break
        sleep 0.1
    done
    [[ -S "$socket_path" ]] || fail "Unix socket target was not created"
    if deploy_displace "$socket_path"; then
        fail "Unix socket displacement was accepted"
    fi
    [[ -S "$socket_path" ]] || fail "Unix socket target changed"
    ! grep -F "$socket_path" "$DEVENV_BACKUP_PATH/manifest" \
        || fail "Unix socket displacement wrote a manifest record"
    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true
else
    printf 'Unix socket fixture unavailable; dedicated host test required\n' >&2
fi

if mknod "$HOME/.char-target" c 1 3 2>/dev/null; then
    if deploy_displace "$HOME/.char-target"; then
        fail "character device displacement was accepted"
    fi
    [[ -c "$HOME/.char-target" ]] || fail "character device target changed"
    ! grep -F "$HOME/.char-target" "$DEVENV_BACKUP_PATH/manifest" \
        || fail "character device displacement wrote a manifest record"
else
    printf 'character device fixture unavailable; dedicated privileged test required\n' >&2
fi

special_backup_id="$DEVENV_BACKUP_ID"
backup_restore "$special_backup_id" \
    || fail "normal change was not restorable after special-file rejection"
assert_equal "$(cat "$HOME/.other-target")" "original other target"

if command -v nvim >/dev/null 2>&1; then
    n6_mixed_home="$TEST_ROOT/n6-mixed-home"
    n6_mixed_modules="$TEST_ROOT/n6-mixed-modules"
    mkdir -p "$n6_mixed_home/.config/nvim" "$n6_mixed_modules"
    ln -s "$REPO_DIR/tools/editor" "$n6_mixed_modules/editor"
    ln -s "$REPO_DIR/tests/fixtures/tools/test" "$n6_mixed_modules/test"
    printf 'n6 original link\n' > "$n6_mixed_home/.fixture-link"
    printf 'n6 original rc\n' > "$n6_mixed_home/.bashrc"
    mkfifo "$n6_mixed_home/.config/nvim/init.lua"
    cat > "$TEST_ROOT/n6-mixed.conf" <<'CONFIG'
[general]
backup_dir = ~/.n6-mixed-backups
[neovim]
enable = true
install = false
[success]
enable = true
install = false
CONFIG
    n6_mixed_before=$(home_snapshot "$n6_mixed_home")
    set +e
    HOME="$n6_mixed_home" DEVENV_MODULE_ROOT="$n6_mixed_modules" \
        "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/n6-mixed.conf" \
        --dry-run > "$TEST_ROOT/n6-mixed-dry.log" 2>&1
    n6_mixed_dry_status=$?
    set -e
    [[ "$n6_mixed_dry_status" -ne 0 ]] \
        || fail "neovim FIFO dry-run was accepted"
    assert_equal "$(home_snapshot "$n6_mixed_home")" "$n6_mixed_before"
    set +e
    HOME="$n6_mixed_home" DEVENV_MODULE_ROOT="$n6_mixed_modules" \
        "$REPO_DIR/setup_devenv.sh" -c "$TEST_ROOT/n6-mixed.conf" \
        > "$TEST_ROOT/n6-mixed-apply.log" 2>&1
    n6_mixed_apply_status=$?
    set -e
    [[ "$n6_mixed_apply_status" -ne 0 ]] \
        || fail "neovim FIFO apply was accepted"
    [[ -p "$n6_mixed_home/.config/nvim/init.lua" ]] \
        || fail "neovim FIFO target changed"
    [[ ! -e "$n6_mixed_home/.config/nvim/init.vim" && \
        ! -L "$n6_mixed_home/.config/nvim/init.vim" ]] \
        || fail "neovim init.vim was deployed after FIFO rejection"
    [[ -L "$n6_mixed_home/.fixture-link" ]] \
        || fail "other module did not apply in FIFO mixed run"
    n6_mixed_id=$(HOME="$n6_mixed_home" "$REPO_DIR/setup_devenv.sh" \
        --list-backups -c "$TEST_ROOT/n6-mixed.conf" | tail -n 1)
    n6_mixed_restore_before=$(home_snapshot "$n6_mixed_home")
    HOME="$n6_mixed_home" "$REPO_DIR/setup_devenv.sh" \
        --restore "$n6_mixed_id" --dry-run \
        -c "$TEST_ROOT/n6-mixed.conf" > "$TEST_ROOT/n6-mixed-restore-dry.log" 2>&1
    assert_equal "$(home_snapshot "$n6_mixed_home")" "$n6_mixed_restore_before"
    assert_file_contains "$TEST_ROOT/n6-mixed-restore-dry.log" \
        "[DRY-RUN] Would restore $n6_mixed_home/.fixture-link"
    assert_file_contains "$TEST_ROOT/n6-mixed-restore-dry.log" \
        "[DRY-RUN] Would restore $n6_mixed_home/.bashrc"
    HOME="$n6_mixed_home" "$REPO_DIR/setup_devenv.sh" \
        --restore "$n6_mixed_id" -c "$TEST_ROOT/n6-mixed.conf" >/dev/null
    assert_equal "$(cat "$n6_mixed_home/.fixture-link")" "n6 original link"
    assert_equal "$(cat "$n6_mixed_home/.bashrc")" "n6 original rc"
    [[ -p "$n6_mixed_home/.config/nvim/init.lua" ]] \
        || fail "FIFO target was not preserved by mixed restore"
else
    printf 'neovim mixed FIFO fixture unavailable; nvim is not installed\n' >&2
fi

remove_shim_dir="$TEST_ROOT/remove-shim"
mkdir -p "$remove_shim_dir"
cat > "$remove_shim_dir/rm" <<'SHIM'
#!/bin/bash
for argument in "$@"; do
    case "$argument" in
        */remove-failure-home/.target|*/link-failure-home/.target)
            exit 1
            ;;
        */.lie-target)
            exit 0
            ;;
    esac
done
exec /bin/rm "$@"
SHIM
chmod +x "$remove_shim_dir/rm"

remove_semantics_home="$TEST_ROOT/remove-semantics-home"
mkdir -p "$remove_semantics_home"
export HOME="$remove_semantics_home" DEVENV_DRY_RUN=false
backup_set_root "$HOME/.remove-semantics-backups" || fail "remove semantics root rejected"
backup_begin || fail "remove semantics run did not start"
printf 'remove file\n' > "$HOME/.remove-file"
ln -s /nonexistent "$HOME/.remove-link"
mkdir -p "$HOME/.remove-directory/sub"
printf 'directory content\n' > "$HOME/.remove-directory/sub/file"
mkdir -p "$HOME/.remove-real-directory"
ln -s "$HOME/.remove-real-directory" "$HOME/.remove-link-directory"
for removal_target in "$HOME/.remove-file" "$HOME/.remove-link" \
    "$HOME/.remove-directory" "$HOME/.remove-link-directory"; do
    backup_remove_current "$removal_target" \
        || fail "supported removal failed: $removal_target"
    [[ ! -e "$removal_target" && ! -L "$removal_target" ]] \
        || fail "supported removal left target: $removal_target"
done
[[ -d "$HOME/.remove-real-directory" ]] \
    || fail "removing a directory link removed its target"
backup_remove_current "$HOME/.missing" \
    || fail "missing target removal was not successful"
mkfifo "$HOME/.remove-fifo"
if backup_remove_current "$HOME/.remove-fifo"; then
    fail "unsupported FIFO removal was accepted"
fi
[[ -p "$HOME/.remove-fifo" ]] || fail "unsupported FIFO was changed"
printf 'lying removal target\n' > "$HOME/.lie-target"
if PATH="$remove_shim_dir:$PATH" backup_remove_current "$HOME/.lie-target"; then
    fail "lying rm success was accepted"
fi
[[ -f "$HOME/.lie-target" ]] || fail "lying rm success removed target"

remove_failure_home="$TEST_ROOT/remove-failure-home"
mkdir -p "$remove_failure_home"
printf 'remove failure target\n' > "$remove_failure_home/.target"
export HOME="$remove_failure_home"
backup_set_root "$HOME/.remove-failure-backups" || fail "remove failure root rejected"
backup_begin || fail "remove failure run did not start"
if PATH="$remove_shim_dir:$PATH" deploy_displace "$HOME/.target"; then
    fail "PATH rm failure was accepted by deploy_displace"
fi
[[ -f "$HOME/.target" ]] || fail "deploy_displace rm failure removed target"

link_failure_home="$TEST_ROOT/link-failure-home"
mkdir -p "$link_failure_home"
printf 'link failure target\n' > "$link_failure_home/.target"
export HOME="$link_failure_home"
backup_set_root "$HOME/.link-failure-backups" || fail "link failure root rejected"
backup_begin || fail "link failure run did not start"
link_failure_id="$DEVENV_BACKUP_ID"
if PATH="$remove_shim_dir:$PATH" \
    deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$HOME/.target"; then
    fail "PATH rm failure was accepted by deploy_link"
fi
[[ -f "$HOME/.target" ]] || fail "deploy_link rm failure removed target"
backup_restore "$link_failure_id" \
    || fail "failed deploy_link backup was not restorable"
assert_equal "$(cat "$HOME/.target")" "link failure target"

n3_home="$TEST_ROOT/n3-home"
mkdir -p "$n3_home"
printf 'n3 original\n' > "$n3_home/.same"
export HOME="$n3_home"
backup_set_root "$HOME/.n3-backups" || fail "N-3 backup root rejected"
backup_begin || fail "N-3 run did not start"
deploy_displace "$HOME/.same" || fail "N-3 first displacement failed"
if deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$HOME/.same"; then
    fail "displace then link was accepted"
fi
n3_id="$DEVENV_BACKUP_ID"
backup_restore "$n3_id" \
    >/dev/null || fail "displace then link manifest was not restorable"
assert_equal "$(cat "$n3_home/.same")" "n3 original"

printf 'n3 reverse original\n' > "$n3_home/.same"
export HOME="$n3_home"
backup_set_root "$HOME/.n3-reverse-backups" || fail "N-3 reverse root rejected"
backup_begin || fail "N-3 reverse run did not start"
deploy_link "$REPO_DIR/tests/fixtures/source.txt" "$HOME/.same" \
    || fail "N-3 link setup failed"
if deploy_displace "$HOME/.same"; then
    fail "link then displace was accepted"
fi
n3_reverse_id="$DEVENV_BACKUP_ID"
backup_restore "$n3_reverse_id" \
    >/dev/null || fail "reverse N-3 manifest was not restorable"
assert_equal "$(cat "$n3_home/.same")" "n3 reverse original"

printf 'n3 rc original\n' > "$n3_home/.rc"
export HOME="$n3_home"
backup_set_root "$HOME/.n3-rc-backups" || fail "N-3 rc root rejected"
backup_begin || fail "N-3 rc run did not start"
rc_block_apply "$HOME/.rc" "$REPO_DIR/tests/fixtures/rc-block" \
    || fail "N-3 rc setup failed"
if deploy_displace "$HOME/.rc"; then
    fail "rc block then displace was accepted"
fi
n3_rc_id="$DEVENV_BACKUP_ID"
backup_restore "$n3_rc_id" \
    >/dev/null || fail "N-3 rc manifest was not restorable"
assert_file_contains "$n3_home/.rc" "n3 rc original"

printf 'n3 displace rc original\n' > "$n3_home/.displace-rc"
export HOME="$n3_home"
backup_set_root "$HOME/.n3-displace-rc-backups" \
    || fail "N-3 displace rc root rejected"
backup_begin || fail "N-3 displace rc run did not start"
deploy_displace "$HOME/.displace-rc" \
    || fail "N-3 displace rc first displacement failed"
if rc_block_apply "$HOME/.displace-rc" "$REPO_DIR/tests/fixtures/rc-block"; then
    fail "displace then rc block was accepted"
fi
n3_displace_rc_id="$DEVENV_BACKUP_ID"
backup_restore "$n3_displace_rc_id" \
    >/dev/null || fail "displace then rc manifest was not restorable"
assert_equal "$(cat "$n3_home/.displace-rc")" "n3 displace rc original"

assert_manifest_validation_case() {
    local label="$1"
    local expected_status="$2"
    local manifest_body="$3"
    local validation_home="$TEST_ROOT/manifest-$label-home"
    local backup_path="$validation_home/.dev-env-backup/$label"
    local target="$validation_home/.target"
    local source="$REPO_DIR/tests/fixtures/source.txt"
    local item="$backup_path/item-001"
    local before mode status
    mkdir -p "$backup_path"
    printf 'saved validation content\n' > "$item"
    manifest_body="${manifest_body//@TARGET@/$target}"
    manifest_body="${manifest_body//@SOURCE@/$source}"
    manifest_body="${manifest_body//@ITEM@/$item}"
    printf '%s\n' "$manifest_body" > "$backup_path/manifest"
    before=$(home_snapshot "$validation_home")
    for mode in real dry-run; do
        status=0
        if [[ "$mode" == real ]]; then
            HOME="$validation_home" "$REPO_DIR/setup_devenv.sh" --restore "$label" \
                > "$TEST_ROOT/manifest-$label.log" 2>&1 || status=$?
        else
            HOME="$validation_home" "$REPO_DIR/setup_devenv.sh" --restore "$label" \
                --dry-run > "$TEST_ROOT/manifest-$label.log" 2>&1 || status=$?
        fi
        assert_equal "$status" "$expected_status"
        assert_equal "$(home_snapshot "$validation_home")" "$before"
    done
}

assert_manifest_validation_case unknown-record 1 \
    $'# portable test manifest\n\nUNKNOWN_RECORD\tvalue'
assert_manifest_validation_case duplicate-absent 1 \
    $'BEFORE\tfile\t@TARGET@\t-\t@ITEM@\nAFTER_ABSENT\t@TARGET@\nAFTER_ABSENT\t@TARGET@'
assert_manifest_validation_case mixed-after 1 \
    $'BEFORE\tfile\t@TARGET@\t-\t@ITEM@\nAFTER_ABSENT\t@TARGET@\nAFTER_LINK\t@TARGET@\t@SOURCE@'
assert_manifest_validation_case duplicate-link 1 \
    $'BEFORE\tfile\t@TARGET@\t-\t@ITEM@\nAFTER_LINK\t@TARGET@\t@SOURCE@\nAFTER_LINK\t@TARGET@\t@SOURCE@'
assert_manifest_validation_case comments-and-blank-lines 0 \
    $'# comment\n\nBEFORE\tnone\t@TARGET@\t-\t-'

printf 'smoke tests passed\n'
