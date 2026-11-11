#!/bin/bash
# shellcheck disable=SC2016

set -u
set -o pipefail

script_dir=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd) || {
    printf 'shell smoke failure: could not resolve test script directory\n' >&2
    exit 2
}
repo_dir=$(cd -P "$script_dir/.." >/dev/null 2>&1 && pwd) || {
    printf 'shell smoke failure: could not resolve repository directory\n' >&2
    exit 2
}
setup_script="$repo_dir/setup_devenv.sh"

smoke_tmp_root=$(mktemp -d) || {
    printf 'shell smoke failure: could not create the temporary test root directory\n' >&2
    exit 2
}
trap 'rm -rf "$smoke_tmp_root"' EXIT

fail() {
    printf 'shell smoke failure: %s\n' "$1" >&2
    exit 1
}

# Prints the failure reason first, then the captured log indented below it.
fail_with_log() {
    printf 'shell smoke failure: %s\n' "$1" >&2
    sed 's/^/    | /' "$2" >&2
    exit 1
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    case "$haystack" in
        *"$needle"*) ;;
        *) fail "expected output to contain: $needle" ;;
    esac
}

# Matches a whole line, so a longer value cannot satisfy a shorter expectation.
assert_line() {
    local text="$1"
    local expected_line="$2"
    local current_line
    while IFS= read -r current_line; do
        [[ "$current_line" == "$expected_line" ]] && return 0
    done <<< "$text"
    fail "expected output line: $expected_line"
}

assert_file_contains() {
    local file_path="$1"
    local needle="$2"
    grep -F -- "$needle" "$file_path" >/dev/null 2>&1 ||
        fail "expected $file_path to contain: $needle"
}

assert_file_line() {
    local file_path="$1"
    local expected_line="$2"
    grep -Fx -- "$expected_line" "$file_path" >/dev/null 2>&1 ||
        fail "expected $file_path to contain the exact line: $expected_line"
}

assert_file_absent() {
    local file_path="$1"
    [[ ! -e "$file_path" && ! -L "$file_path" ]] ||
        fail "file should not exist: $file_path"
}

assert_file_present() {
    local file_path="$1"
    [[ -e "$file_path" || -L "$file_path" ]] ||
        fail "file should exist: $file_path"
}

assert_path_entry_count() {
    local path_value="$1"
    local expected="$2"
    local entry="$3"
    local actual
    actual=$(printf '%s\n' "$path_value" | awk -F: -v wanted="$entry" '
        {
            count = 0
            for (field_index = 1; field_index <= NF; field_index++) {
                if ($field_index == wanted) {
                    count++
                }
            }
            print count
        }
    ') || fail "could not count PATH entries of $entry"
    [[ "$actual" == "$expected" ]] ||
        fail "PATH entry $entry appeared $actual times, expected $expected"
}

# Setup prints one summary row per tool; compare the row exactly.
assert_summary_state() {
    local setup_output="$1"
    local tool_name="$2"
    local expected_state="$3"
    local expected_reason="$4"
    local expected_row
    expected_row=$(printf '  %-16s %-8s %s' "$tool_name" "$expected_state" "$expected_reason")
    assert_line "$setup_output" "$expected_row"
}

# Compares a sorted before/after state list against the exact expected additions.
assert_state_delta() {
    local state_kind="$1"
    local before_file="$2"
    local after_file="$3"
    local expected_added="$4"
    local added_entries removed_entries
    added_entries=$(LC_ALL=C comm -13 "$before_file" "$after_file" | tr '\n' ' ') ||
        fail "could not compare added $state_kind"
    removed_entries=$(LC_ALL=C comm -23 "$before_file" "$after_file" | tr '\n' ' ') ||
        fail "could not compare removed $state_kind"
    [[ "$added_entries" == "$expected_added" ]] ||
        fail "$state_kind added by the portable shell files: [$added_entries] expected: [$expected_added]"
    [[ -z "$removed_entries" ]] ||
        fail "$state_kind removed by the portable shell files: [$removed_entries]"
}

# The managed rc block must contain exactly the expected sourcing lines.
assert_rc_block_body() {
    local rc_file="$1"
    local expected_body="$2"
    local actual_body
    actual_body=$(awk '
        $0 == "# <<< portable-devenv <<<" { inside = 0 }
        inside { print }
        $0 == "# >>> portable-devenv >>>" { inside = 1 }
    ' "$rc_file") || fail "could not read the managed rc block of $rc_file"
    [[ "$actual_body" == "$expected_body" ]] ||
        fail "managed rc block of $rc_file is [$actual_body] instead of [$expected_body]"
}

# Sets fixture_dir to a new empty directory below the shared temporary root.
make_fixture_dir() {
    local fixture_name="$1"
    fixture_dir="$smoke_tmp_root/$fixture_name"
    mkdir -p "$fixture_dir" || fail "could not create the $fixture_name fixture directory"
}

make_stub_command() {
    local stub_path="$1"
    local stub_body="$2"
    printf '#!/bin/sh\n%s\n' "$stub_body" > "$stub_path" ||
        fail "could not create stub command $stub_path"
    chmod 755 "$stub_path" || fail "could not make stub command executable: $stub_path"
}

# Usage: write_shell_config <file> <home> <section>... ; a section is "name:key=value,key=value".
write_shell_config() {
    local config_path="$1"
    local config_home="$2"
    local section_spec section_name key_values key_value
    shift 2
    printf '[general]\nbackup_dir = %s/backups\n' "$config_home" > "$config_path" ||
        fail "could not create config file $config_path"
    for section_spec in "$@"; do
        section_name=${section_spec%%:*}
        key_values=${section_spec#*:}
        printf '\n[%s]\n' "$section_name" >> "$config_path" ||
            fail "could not append [$section_name] to $config_path"
        while [[ -n "$key_values" ]]; do
            key_value=${key_values%%,*}
            printf '%s = %s\n' "${key_value%%=*}" "${key_value#*=}" >> "$config_path" ||
                fail "could not append $key_value to $config_path"
            if [[ "$key_values" == *,* ]]; then
                key_values=${key_values#*,}
            else
                key_values=""
            fi
        done
    done
}

# Writes a PATH directory with every system tool except zsh so zsh detection fails.
make_path_without_zsh() {
    local shim_dir="$1"
    local tool_path tool_name
    local -a tool_paths=()
    mkdir -p "$shim_dir" || fail "could not create the zsh-less PATH directory"
    for tool_path in /usr/bin/* /bin/*; do
        tool_name=${tool_path##*/}
        case "$tool_name" in
            *zsh*) continue ;;
        esac
        # /bin is a link to /usr/bin on merged-usr systems; link each name once.
        [[ "$tool_path" == /bin/* && ( -e "/usr/bin/$tool_name" || -L "/usr/bin/$tool_name" ) ]] &&
            continue
        tool_paths[${#tool_paths[@]}]="$tool_path"
    done
    ln -s -t "$shim_dir" "${tool_paths[@]}" ||
        fail "could not link system tools into the zsh-less PATH directory"
}

snapshot_tree() {
    local tree_dir="$1"
    local snapshot_file="$2"
    (
        cd "$tree_dir" || exit 1
        find . -mindepth 1 -printf '%p %y %s %l\n' | sort || exit 1
        find . -type f -exec sha256sum {} + | sort -k2
    ) > "$snapshot_file" || fail "could not snapshot directory tree $tree_dir"
}

# Lists one kind of zsh state (parameter names, options, ...) sorted into a file.
write_zsh_state_list() {
    local state_home="$1"
    local state_path="$2"
    local state_expression="$3"
    local list_file="$4"
    local error_file="$5"
    local exclude_pattern="${6:-a^}"
    env -u GOPATH -u SIFIVE_HOME HOME="$state_home" PATH="$state_path" \
        zsh -o no_append_history -i -c \
        "print -rl -- $state_expression" 2>"$error_file" |
        awk -v exclude="$exclude_pattern" '$0 !~ exclude' |
        LC_ALL=C sort > "$list_file" ||
        fail_with_log "zsh state listing failed: $state_expression" "$error_file"
}

run_bash_tests() {
    local test_root home_dir fake_bin config_file original_hash output path_value
    local backup_dir backup_path backup_id restored_hash unexpected_stderr
    local common_copy mutant_copy mutation_path fallback_bin mutation_count
    local corner_output corner_count vi_corner_output empty_editor_bin stale_vi_output
    local interactive_commands state_dir state_home

    make_fixture_dir bash-main
    test_root=$fixture_dir
    # A space in HOME checks that every product path expansion is quoted.
    home_dir="$test_root/home dir"
    fake_bin="$test_root/bin"
    mkdir -p "$home_dir" "$fake_bin" || fail "could not create bash main home and bin fixtures"
    printf '# user content\n' > "$home_dir/.bashrc" ||
        fail "could not create the bash main user .bashrc fixture"
    original_hash=$(sha256sum "$home_dir/.bashrc" | awk '{print $1}') ||
        fail "could not hash the original bash main .bashrc"
    make_stub_command "$fake_bin/nvim" "exit 0"
    make_stub_command "$fake_bin/vim" "exit 0"
    config_file="$test_root/bash.conf"
    write_shell_config "$config_file" "$home_dir" "bash:enable=true,install=false"

    PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" -c "$config_file" >"$test_root/apply.log" 2>&1 ||
        fail_with_log "setup_devenv.sh failed to apply the bash config" "$test_root/apply.log"

    cat > "$test_root/interactive.sh" <<'EOF'
alias lal; alias ll; alias la; alias l; alias gs; alias tm; alias vi
printf 'HISTSIZE=%s\nHISTFILESIZE=%s\nHISTCONTROL=%s\n' "$HISTSIZE" "$HISTFILESIZE" "$HISTCONTROL"
if shopt -q histappend; then printf 'HISTAPPEND=on\n'; else printf 'HISTAPPEND=off\n'; fi
printf 'LOCAL_BIN_VARIABLE=%s\n' "${portable_devenv_local_bin+set}"
printf 'HISTFILE=%s\n' "$HISTFILE"
bash --noprofile --norc -c 'printf "CHILD_HISTSIZE=%s\nCHILD_HISTFILESIZE=%s\nCHILD_HISTCONTROL=%s\n" "${HISTSIZE-unset}" "${HISTFILESIZE-unset}" "${HISTCONTROL-unset}"'
EOF
    [[ -s "$test_root/interactive.sh" ]] ||
        fail "could not create the bash interactive command script"
    interactive_commands=$(< "$test_root/interactive.sh") ||
        fail "could not read the bash interactive command script"
    output=$(PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        bash -i -c "$interactive_commands" \
        2>"$test_root/bash.stderr") ||
        fail_with_log "bash interactive session printing aliases and history settings exited with an error" "$test_root/bash.stderr"
    unexpected_stderr=$(awk '
        !/cannot set terminal process group/ && !/no job control/
    ' "$test_root/bash.stderr") ||
        fail "could not inspect bash interactive stderr"
    [[ -z "$unexpected_stderr" ]] ||
        fail "bash interactive emitted unexpected stderr: $unexpected_stderr"
    assert_line "$output" "alias lal='ls -lAF'"
    assert_line "$output" "alias ll='ls -lF'"
    assert_line "$output" "alias la='ls -A'"
    assert_line "$output" "alias l='ls -CF'"
    assert_line "$output" "alias gs='git status'"
    assert_line "$output" "alias tm='tmux'"
    assert_line "$output" "alias vi='nvim'"
    assert_line "$output" "HISTSIZE=10000"
    assert_line "$output" "HISTFILESIZE=20000"
    assert_line "$output" "HISTCONTROL=ignoredups:ignorespace"
    assert_line "$output" "HISTAPPEND=on"
    assert_line "$output" "HISTFILE=$home_dir/.bash_history"
    assert_line "$output" "LOCAL_BIN_VARIABLE="
    assert_line "$output" "CHILD_HISTSIZE=10000"
    assert_line "$output" "CHILD_HISTFILESIZE=20000"
    assert_line "$output" "CHILD_HISTCONTROL=ignoredups:ignorespace"

    # Exact state delta: the portable files may add only the known variables,
    # exports, aliases and PATH entry; any machine-specific addition is rejected.
    state_dir="$test_root/state"
    mkdir -p "$state_dir" || fail "could not create the bash shell state directory"
    cat > "$test_root/state.sh" <<'EOF'
: | :
shopt -s | awk '{ print $1 }' | sort > "$1/shopt.before"
set -o | awk '$2 == "on" { print $1 }' | sort > "$1/set-options.before"
trap -p | sort > "$1/traps.before"
pwd -P > "$1/cwd.before"
compgen -v | sort > "$1/variables.before"
compgen -e | sort > "$1/exports.before"
compgen -a | sort > "$1/aliases.before"
compgen -A function | sort > "$1/functions.before"
printf '%s\n' "$PATH" | tr ':' '\n' | sort > "$1/path.before"
. "$HOME/.config/portable-devenv/shell/bash.sh"
shopt -s | awk '{ print $1 }' | sort > "$1/shopt.after"
set -o | awk '$2 == "on" { print $1 }' | sort > "$1/set-options.after"
trap -p | sort > "$1/traps.after"
pwd -P > "$1/cwd.after"
compgen -v | sort > "$1/variables.after"
compgen -e | sort > "$1/exports.after"
compgen -a | sort > "$1/aliases.after"
compgen -A function | sort > "$1/functions.after"
printf '%s\n' "$PATH" | tr ':' '\n' | sort > "$1/path.after"
EOF
    [[ -s "$test_root/state.sh" ]] || fail "could not create the bash shell state script"
    state_home="$home_dir"
    env -i HOME="$state_home" PATH="$fake_bin:/usr/bin:/bin" LC_ALL=C \
        bash --noprofile --norc "$test_root/state.sh" "$state_dir" \
        >"$test_root/state.stdout" 2>"$test_root/state.stderr" ||
        fail_with_log "bash shell state command failed" "$test_root/state.stderr"
    [[ ! -s "$test_root/state.stderr" ]] ||
        fail_with_log "bash shell state command wrote to stderr" "$test_root/state.stderr"
    [[ ! -s "$test_root/state.stdout" ]] ||
        fail_with_log "sourcing bash.sh printed to stdout" "$test_root/state.stdout"
    assert_state_delta "variables" "$state_dir/variables.before" "$state_dir/variables.after" \
        "HISTCONTROL HISTFILESIZE HISTSIZE "
    assert_state_delta "exported variables" "$state_dir/exports.before" "$state_dir/exports.after" \
        "HISTCONTROL HISTFILESIZE HISTSIZE "
    assert_state_delta "aliases" "$state_dir/aliases.before" "$state_dir/aliases.after" \
        "gs l la lal ll tm vi "
    assert_state_delta "functions" "$state_dir/functions.before" "$state_dir/functions.after" ""
    assert_state_delta "PATH entries" "$state_dir/path.before" "$state_dir/path.after" \
        "$home_dir/.local/bin "
    assert_state_delta "shopt options" "$state_dir/shopt.before" "$state_dir/shopt.after" \
        "histappend "
    assert_state_delta "set -o options" "$state_dir/set-options.before" \
        "$state_dir/set-options.after" ""
    assert_state_delta "traps" "$state_dir/traps.before" "$state_dir/traps.after" ""
    cmp -s "$state_dir/cwd.before" "$state_dir/cwd.after" ||
        fail "the portable shell files changed the working directory"

    path_value=$(PATH="/usr/bin:/bin" HOME="$home_dir" \
        bash --noprofile --norc -c '
            . "$HOME/.config/portable-devenv/shell/bash-common.sh"
            . "$HOME/.config/portable-devenv/shell/bash-common.sh"
            printf "%s\n" "$PATH"
        ') || fail "could not source bash-common.sh twice to read PATH"
    assert_path_entry_count "$path_value" 1 "$home_dir/.local/bin"
    [[ "${path_value%%:*}" == "$home_dir/.local/bin" ]] ||
        fail "local bin is not the first PATH entry: ${path_value%%:*}"
    [[ "$(grep -c '^# >>> portable-devenv >>>$' "$home_dir/.bashrc")" == 1 ]] ||
        fail "bash rc start marker count is not one"
    [[ "$(grep -c '^# <<< portable-devenv <<<$' "$home_dir/.bashrc")" == 1 ]] ||
        fail "bash rc end marker count is not one"
    assert_file_contains "$home_dir/.bashrc" "# user content"
    assert_rc_block_body "$home_dir/.bashrc" '. "$HOME/.config/portable-devenv/shell/bash.sh"'

    backup_path=""
    for backup_dir in "$home_dir"/backups/*; do
        [[ -d "$backup_dir" ]] || continue
        backup_path="$backup_dir"
    done
    [[ -n "$backup_path" ]] || fail "setup did not create a backup directory under $home_dir/backups"
    backup_id=${backup_path##*/}
    PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" --restore "$backup_id" -c "$config_file" \
        >"$test_root/restore.log" 2>&1 ||
        fail_with_log "restore of backup $backup_id failed" "$test_root/restore.log"
    restored_hash=$(sha256sum "$home_dir/.bashrc" | awk '{print $1}') ||
        fail "could not hash the restored .bashrc"
    [[ "$restored_hash" == "$original_hash" ]] ||
        fail "restore did not return .bashrc to its original bytes"
    assert_file_absent "$home_dir/.config/portable-devenv/shell/bash.sh"
    assert_file_absent "$home_dir/.config/portable-devenv/shell/bash-common.sh"

    common_copy="$test_root/common.sh"
    mutant_copy="$test_root/common-mutant.sh"
    cp "$repo_dir/tools/shell/common/common.sh" "$common_copy" ||
        fail "could not copy common.sh for the PATH guard mutation check"
    awk '
        index($0, "case \":${PATH-}:\" in") == 1 {
            print "PATH=\"$portable_devenv_local_bin${PATH:+:$PATH}\""
            skip = 1
            next
        }
        /^esac$/ && skip {
            skip = 0
            next
        }
        !skip { print }
    ' "$common_copy" > "$mutant_copy" ||
        fail "could not build the PATH guard mutation copy"
    mutation_path=$(HOME="$home_dir" PATH="/usr/bin:/bin" bash --noprofile --norc -c "
        . '$mutant_copy'
        . '$mutant_copy'
        printf '%s\n' \"\$PATH\"
    ") || fail "could not source the PATH guard mutation copy"
    mutation_count=$(printf '%s\n' "$mutation_path" | awk -F: -v wanted="$home_dir/.local/bin" '
        {
            count = 0
            for (field_index = 1; field_index <= NF; field_index++) {
                if ($field_index == wanted) {
                    count++
                }
            }
            print count
        }
    ') || fail "could not count PATH entries of the PATH guard mutation copy"
    [[ "$mutation_count" != 1 ]] ||
        fail "PATH mutation was not caught by the duplicate-entry assertion"

    mkdir -p "$home_dir/.local/bin/foo" || fail "could not create PATH substring fixture"
    printf '#!/bin/sh\nexit 0\n' > "$home_dir/.local/bin/nvim" || fail "could not create PATH nvim fixture"
    chmod 755 "$home_dir/.local/bin/nvim" || fail "could not chmod PATH nvim fixture"
    corner_output=$(HOME="$home_dir" PATH="$home_dir/.local/bin/foo:/usr/bin:/bin" \
        bash --noprofile --norc -c \
        '. "$1"; printf "%s\n" "$PATH"' bash \
        "$repo_dir/tools/shell/common/common.sh") ||
        fail "sourcing common.sh failed when PATH held an entry that only has the local bin as a prefix"
    corner_count=$(printf '%s\n' "$corner_output" | awk -F: -v wanted="$home_dir/.local/bin" '
        {
            count = 0
            for (field_index = 1; field_index <= NF; field_index++) {
                if ($field_index == wanted) count++
            }
            print count
        }
    ') || fail "could not count PATH substring corner entries"
    [[ "$corner_count" == 1 ]] ||
        fail "PATH whole-entry guard did not add local bin"

    fallback_bin="$test_root/fallback-bin"
    mkdir -p "$fallback_bin" || fail "could not create vi fallback PATH"
    cp "$fake_bin/vim" "$fallback_bin/vim" || fail "could not create vi fallback binary"
    chmod 755 "$fallback_bin/vim" || fail "could not chmod vi fallback binary"
    rm -f "$home_dir/.local/bin/nvim" || fail "could not remove nvim fallback fixture"
    vi_corner_output=$(HOME="$home_dir" PATH="$fake_bin:/usr/bin:/bin" \
        bash --noprofile --norc -c '
            alias vi="nvim"
            . "$1"
            PATH="$2"
            hash -r
            . "$1"
            alias vi
        ' bash "$repo_dir/tools/shell/common/common.sh" "$fallback_bin") ||
        fail "alias vi is not defined after re-sourcing common.sh with only vim on PATH"
    assert_line "$vi_corner_output" "alias vi='vim'"

    empty_editor_bin="$test_root/empty-editor-bin"
    mkdir -p "$empty_editor_bin" || fail "could not create empty editor PATH"
    if stale_vi_output=$(HOME="$home_dir" PATH="$fake_bin:/usr/bin:/bin" \
        bash --noprofile --norc -c '
            alias vi="nvim"
            . "$1"
            PATH="$2"
            hash -r
            . "$1"
            alias vi 2>&1
        ' bash "$repo_dir/tools/shell/common/common.sh" "$empty_editor_bin"); then
        fail "stale vi alias was still defined after the editors left PATH: $stale_vi_output"
    fi
    assert_contains "$stale_vi_output" "alias: vi: not found"
}

# common.sh is a /bin/sh file shared by bash and zsh, so check it under sh too.
run_common_posix_sh_test() {
    local test_root home_dir fake_bin output

    make_fixture_dir common-posix-sh
    test_root=$fixture_dir
    home_dir="$test_root/home"
    fake_bin="$test_root/bin"
    mkdir -p "$home_dir" "$fake_bin" || fail "could not create the POSIX sh fixtures"
    make_stub_command "$fake_bin/nvim" "exit 0"
    output=$(env -i HOME="$home_dir" PATH="$fake_bin:/usr/bin:/bin" /bin/sh -c '
        . "$1"
        alias lal; alias ll; alias la; alias l; alias gs; alias tm; alias vi
        printf "PATH=%s\n" "$PATH"
    ' sh "$repo_dir/tools/shell/common/common.sh" 2>"$test_root/sh.stderr") ||
        fail_with_log "sourcing common.sh under /bin/sh failed" "$test_root/sh.stderr"
    [[ ! -s "$test_root/sh.stderr" ]] ||
        fail_with_log "sourcing common.sh under /bin/sh wrote to stderr" "$test_root/sh.stderr"
    assert_line "$output" "lal='ls -lAF'"
    assert_line "$output" "ll='ls -lF'"
    assert_line "$output" "la='ls -A'"
    assert_line "$output" "l='ls -CF'"
    assert_line "$output" "gs='git status'"
    assert_line "$output" "tm='tmux'"
    assert_line "$output" "vi='nvim'"
    assert_line "$output" "PATH=$home_dir/.local/bin:$fake_bin:/usr/bin:/bin"
    [[ "$(printf '%s\n' "$output" | wc -l)" == 8 ]] ||
        fail "sourcing common.sh under /bin/sh printed extra stdout lines: $output"
    # An empty PATH must not gain a trailing empty entry (current directory).
    output=$(env -i HOME="$home_dir" PATH= /bin/sh -c '
        . "$1"
        printf "PATH=%s\n" "$PATH"
    ' sh "$repo_dir/tools/shell/common/common.sh" 2>"$test_root/sh-empty.stderr") ||
        fail_with_log "sourcing common.sh with an empty PATH failed" "$test_root/sh-empty.stderr"
    assert_line "$output" "PATH=$home_dir/.local/bin"
}

run_bash_vi_variants() {
    local variant key home_dir fake_bin config_file output vi_status editor_name
    local test_root

    make_fixture_dir bash-vi-variants
    test_root=$fixture_dir
    for variant in "nvim vim" "vim" "nvim" "none"; do
        key=$(printf '%s' "$variant" | tr ' ' '_')
        home_dir="$test_root/home-$key"
        fake_bin="$test_root/bin-$key"
        mkdir -p "$home_dir" "$fake_bin" ||
            fail "could not create vi variant fixture directories: $variant"
        printf '# user\n' > "$home_dir/.bashrc" ||
            fail "could not create vi variant .bashrc: $variant"
        if [[ "$variant" != none ]]; then
            for editor_name in $variant; do
                make_stub_command "$fake_bin/$editor_name" "exit 0"
            done
        fi
        config_file="$test_root/$key.conf"
        write_shell_config "$config_file" "$home_dir" "bash:enable=true,install=false"
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
            "$setup_script" -c "$config_file" >"$test_root/$key.apply.log" 2>&1 ||
            fail_with_log "vi variant setup failed: $variant" "$test_root/$key.apply.log"
        if output=$(PATH="$fake_bin" HOME="$home_dir" /usr/bin/bash \
            --noprofile --norc -c \
            '. "$HOME/.config/portable-devenv/shell/bash.sh"; alias vi 2>&1'); then
            vi_status=0
        else
            vi_status=$?
        fi
        case "$variant" in
            "nvim vim"|nvim)
                [[ "$vi_status" == 0 ]] || fail "vi variant shell failed: $variant"
                assert_line "$output" "alias vi='nvim'"
                ;;
            vim)
                [[ "$vi_status" == 0 ]] || fail "vi variant shell failed: $variant"
                assert_line "$output" "alias vi='vim'"
                ;;
            none)
                [[ "$vi_status" != 0 ]] ||
                    fail "vi variant unexpectedly defined: $variant"
                assert_contains "$output" "alias: vi: not found"
                ;;
        esac
    done
}

run_bash_rc_lifecycle_test() {
    local test_root home_dir config_file original_hash backup_id
    local marker_count first_apply_hash

    make_fixture_dir bash-rc-lifecycle
    test_root=$fixture_dir
    home_dir="$test_root/home"
    mkdir -p "$home_dir" || fail "could not create rc lifecycle home"
    printf 'outside-before' > "$home_dir/.bashrc" ||
        fail "could not create rc lifecycle .bashrc"
    original_hash=$(sha256sum "$home_dir/.bashrc" | awk '{print $1}') ||
        fail "could not hash the rc lifecycle original .bashrc"
    config_file="$test_root/config.conf"
    write_shell_config "$config_file" "$home_dir" "bash:enable=true,install=false"
    HOME="$home_dir" "$setup_script" -c "$config_file" >"$test_root/first.log" 2>&1 ||
        fail_with_log "rc lifecycle initial apply failed" "$test_root/first.log"
    first_apply_hash=$(sha256sum "$home_dir/.bashrc" | awk '{print $1}') ||
        fail "could not hash .bashrc after the first apply"
    HOME="$home_dir" "$setup_script" -c "$config_file" >"$test_root/second.log" 2>&1 ||
        fail_with_log "rc lifecycle reapply failed" "$test_root/second.log"
    [[ "$(sha256sum "$home_dir/.bashrc" | awk '{print $1}')" == "$first_apply_hash" ]] ||
        fail "rc lifecycle reapply changed .bashrc bytes (not idempotent)"
    marker_count=$(grep -c '^# >>> portable-devenv >>>$' "$home_dir/.bashrc") ||
        fail "rc lifecycle found no start marker in .bashrc"
    [[ "$marker_count" == 1 ]] ||
        fail "rc lifecycle duplicated start marker: $marker_count"
    marker_count=$(grep -c '^# <<< portable-devenv <<<$' "$home_dir/.bashrc") ||
        fail "rc lifecycle found no end marker in .bashrc"
    [[ "$marker_count" == 1 ]] ||
        fail "rc lifecycle duplicated end marker: $marker_count"
    assert_file_contains "$home_dir/.bashrc" "outside-before"
    backup_id=$(find "$home_dir/backups" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort | head -n 1) ||
        fail "rc lifecycle could not list backups under $home_dir/backups"
    [[ -n "$backup_id" ]] || fail "rc lifecycle found no backup under $home_dir/backups"
    HOME="$home_dir" "$setup_script" --restore "$backup_id" -c "$config_file" \
        >"$test_root/restore.log" 2>&1 ||
        fail_with_log "rc lifecycle restore failed" "$test_root/restore.log"
    [[ "$(sha256sum "$home_dir/.bashrc" | awk '{print $1}')" == "$original_hash" ]] ||
        fail "rc lifecycle restore changed original bytes"
}

run_bash_dry_run_test() {
    local test_root home_dir config_file before_snapshot after_snapshot dry_run_output

    make_fixture_dir bash-dry-run
    test_root=$fixture_dir
    home_dir="$test_root/home"
    mkdir -p "$home_dir" || fail "could not create bash dry-run home"
    printf '# bash dry-run user content\n' > "$home_dir/.bashrc" ||
        fail "could not create bash dry-run rc"
    config_file="$test_root/bash-dry-run.conf"
    write_shell_config "$config_file" "$home_dir" "bash:enable=true,install=false"
    before_snapshot="$test_root/before"
    after_snapshot="$test_root/after"
    snapshot_tree "$home_dir" "$before_snapshot"
    HOME="$home_dir" PATH="/usr/bin:/bin" "$setup_script" --dry-run -c "$config_file" \
        >"$test_root/run.log" 2>&1 ||
        fail_with_log "bash dry-run returned failure" "$test_root/run.log"
    snapshot_tree "$home_dir" "$after_snapshot"
    diff -u "$before_snapshot" "$after_snapshot" >"$test_root/snapshot.diff" 2>&1 ||
        fail_with_log "bash dry-run changed HOME" "$test_root/snapshot.diff"
    dry_run_output=$(< "$test_root/run.log") || fail "could not read the bash dry-run log"
    assert_contains "$dry_run_output" "Would update rc block in $home_dir/.bashrc"
    assert_contains "$dry_run_output" \
        "Would link $home_dir/.config/portable-devenv/shell/bash.sh"
    assert_summary_state "$dry_run_output" bash applied completed
}

# The shipped configs must request what plan 4.1 requires: online.conf installs
# and applies zsh, both configs apply bash.
run_repository_config_dry_run_test() {
    local test_root home_dir dry_run_output no_zsh_bin

    make_fixture_dir repository-config-dry-run
    test_root=$fixture_dir
    home_dir="$test_root/home"
    mkdir -p "$home_dir" || fail "could not create repository config dry-run home"

    HOME="$home_dir" PATH="/usr/bin:/bin" \
        "$setup_script" --dry-run -c "$repo_dir/configs/offline-lite.conf" \
        >"$test_root/offline-lite.log" 2>&1 ||
        fail_with_log "offline-lite.conf dry-run returned failure" "$test_root/offline-lite.log"
    dry_run_output=$(< "$test_root/offline-lite.log") ||
        fail "could not read the offline-lite.conf dry-run log"
    assert_summary_state "$dry_run_output" bash applied completed
    case "$dry_run_output" in
        *"[zsh]"*) fail "offline-lite.conf dry-run mentions zsh although it needs no network" ;;
    esac

    no_zsh_bin="$test_root/no-zsh-bin"
    make_path_without_zsh "$no_zsh_bin"
    HOME="$home_dir" PATH="$no_zsh_bin" \
        "$setup_script" --dry-run -c "$repo_dir/configs/online.conf" \
        >"$test_root/online-no-zsh.log" 2>&1 ||
        fail_with_log "online.conf dry-run without zsh returned failure" "$test_root/online-no-zsh.log"
    dry_run_output=$(< "$test_root/online-no-zsh.log") ||
        fail "could not read the online.conf dry-run log"
    assert_summary_state "$dry_run_output" bash applied completed
    assert_contains "$dry_run_output" "Would install [zsh]"
    assert_summary_state "$dry_run_output" zsh skipped "dry-run: would install"

    # zsh found anywhere on PATH counts as installed, not only under /usr/bin.
    mkdir -p "$test_root/custom-bin" || fail "could not create the custom zsh PATH directory"
    make_stub_command "$test_root/custom-bin/zsh" "exit 0"
    HOME="$home_dir" PATH="$test_root/custom-bin:$no_zsh_bin" \
        "$setup_script" --dry-run -c "$repo_dir/configs/online.conf" \
        >"$test_root/online-custom-zsh.log" 2>&1 ||
        fail_with_log "online.conf dry-run with zsh outside /usr/bin returned failure" \
            "$test_root/online-custom-zsh.log"
    dry_run_output=$(< "$test_root/online-custom-zsh.log") ||
        fail "could not read the online.conf dry-run log with a custom zsh path"
    assert_summary_state "$dry_run_output" zsh applied completed
    case "$dry_run_output" in
        *"Would install [zsh]"*) fail "zsh on a custom PATH directory was not detected as installed" ;;
    esac

    if command -v zsh >/dev/null 2>&1; then
        HOME="$home_dir" PATH="/usr/bin:/bin" \
            "$setup_script" --dry-run -c "$repo_dir/configs/online.conf" \
            >"$test_root/online-zsh.log" 2>&1 ||
            fail_with_log "online.conf dry-run with zsh returned failure" "$test_root/online-zsh.log"
        dry_run_output=$(< "$test_root/online-zsh.log") ||
            fail "could not read the online.conf dry-run log with zsh"
        assert_summary_state "$dry_run_output" bash applied completed
        assert_summary_state "$dry_run_output" zsh applied completed
        case "$dry_run_output" in
            *"Would change default shell"*)
                fail "online.conf dry-run would change the default shell" ;;
        esac
    fi
    [[ -z "$(find "$home_dir" -mindepth 1)" ]] ||
        fail "repository config dry-run created files under $home_dir"
}

run_bash_rc_apply_failure_test() {
    local test_root home_dir config_file output rc before_hash after_hash

    make_fixture_dir bash-rc-apply-failure
    test_root=$fixture_dir
    home_dir="$test_root/home"
    mkdir -p "$home_dir" || fail "could not create bash rc failure home"
    printf '# >>> portable-devenv >>>\n# malformed managed block\n' > "$home_dir/.bashrc" ||
        fail "could not create malformed bash rc fixture"
    before_hash=$(sha256sum "$home_dir/.bashrc" | awk '{print $1}') ||
        fail "could not hash malformed bash rc fixture"
    config_file="$test_root/bash.conf"
    write_shell_config "$config_file" "$home_dir" "bash:enable=true,install=false"
    if output=$(HOME="$home_dir" PATH="/usr/bin:/bin" \
        "$setup_script" -c "$config_file" 2>&1); then
        fail "setup reported success although the bash rc block was malformed: $output"
    else
        rc=$?
    fi
    [[ "$rc" != 0 ]] || fail "malformed bash rc block returned success"
    assert_summary_state "$output" bash failed "module_apply failed (status 1)"
    assert_contains "$output" "[ERROR] Malformed rc block markers in $home_dir/.bashrc"
    after_hash=$(sha256sum "$home_dir/.bashrc" | awk '{print $1}') ||
        fail "could not hash bash rc after failed apply"
    [[ "$after_hash" == "$before_hash" ]] ||
        fail "bash rc changed although rc_block_apply rejected its malformed markers"
}

run_zsh_install_stub_test() {
    local test_root fake_bin marker output rc

    make_fixture_dir zsh-install-stub
    test_root=$fixture_dir
    fake_bin="$test_root/bin"
    marker="$test_root/pkg.marker"
    mkdir -p "$fake_bin" || fail "could not create zsh install bin"
    make_stub_command "$fake_bin/apt-get" "printf '%s\\n' \"\$*\" > \"$marker\""
    # A non-root run reaches apt-get through sudo; keep it inside the stub PATH.
    make_stub_command "$fake_bin/sudo" 'exec "$@"'
    if output=$(PATH="$fake_bin:/usr/bin:/bin" DEVENV_DRY_RUN=false \
        bash --noprofile --norc -c '
            source "$1/lib/log.sh"
            source "$1/lib/package.sh"
            source "$1/tools/shell/zsh/module.sh"
            module_install
        ' bash "$repo_dir" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    [[ "$rc" == 0 ]] || fail "zsh install stub returned $rc: $output"
    [[ -s "$marker" ]] || fail "zsh install stub was not called"
    [[ "$(cat "$marker")" == "install -y zsh" ]] ||
        fail "zsh install requested packages [$(cat "$marker")] instead of exactly [install -y zsh]"
}

run_zsh_missing_chsh_test() {
    local test_root fake_bin expected_zsh_path output rc

    make_fixture_dir zsh-missing-chsh
    test_root=$fixture_dir
    fake_bin="$test_root/bin"
    mkdir -p "$fake_bin" || fail "could not create missing-chsh fixture bin"
    make_stub_command "$fake_bin/zsh" 'exit 0'
    expected_zsh_path="$fake_bin/zsh"
    if output=$(PATH="$fake_bin" /bin/bash --noprofile --norc -c '
        config_has() { return 0; }
        config_bool() { printf -v "$3" true; }
        log_warn() { printf "%s\n" "$*" >&2; }
        source "$1/tools/shell/zsh/module.sh"
        apply_default_shell
    ' bash "$repo_dir" 2>&1); then
        rc=0
    else
        rc=$?
    fi
    [[ "$rc" != 0 ]] || fail "missing chsh was reported as success"
    assert_contains "$output" "chsh is unavailable; run chsh -s $expected_zsh_path manually"
}

# chsh must run only when set_default_shell = true is configured: absent key and
# explicit false never call it, true calls it exactly once.
run_zsh_default_shell_config_test() {
    local test_root fake_bin marker config_file case_name rc output

    make_fixture_dir zsh-default-shell
    test_root=$fixture_dir
    fake_bin="$test_root/bin"
    marker="$test_root/chsh.marker"
    mkdir -p "$fake_bin" || fail "could not create default shell stub bin"
    make_stub_command "$fake_bin/chsh" "printf 'chsh-called %s\\n' \"\$*\" >> \"$marker\""
    for case_name in absent false true invalid; do
        config_file="$test_root/$case_name.conf"
        case "$case_name" in
            absent) write_shell_config "$config_file" "$test_root/home" "zsh:enable=true,install=false" ;;
            invalid) write_shell_config "$config_file" "$test_root/home" \
                "zsh:enable=true,install=false,set_default_shell=invalid" ;;
            *) write_shell_config "$config_file" "$test_root/home" \
                "zsh:enable=true,install=false,set_default_shell=$case_name" ;;
        esac
        rm -f "$marker" || fail "could not reset the chsh marker for $case_name"
        if output=$(PATH="$fake_bin:/usr/bin:/bin" DEVENV_DRY_RUN=false \
            bash --noprofile --norc -c '
                source "$1/lib/log.sh"
                source "$1/lib/ini.sh"
                source "$1/tools/shell/zsh/module.sh"
                config_load "$2" || exit 2
                zsh() { :; }
                apply_default_shell
            ' bash "$repo_dir" "$config_file" 2>&1); then
            rc=0
        else
            rc=$?
        fi
        if [[ "$case_name" == invalid ]]; then
            [[ "$rc" != 0 ]] || fail "invalid set_default_shell boolean returned success"
            assert_contains "$output" "[ERROR] Invalid boolean [zsh] set_default_shell: invalid"
            [[ ! -e "$marker" ]] ||
                fail "chsh was called although set_default_shell was invalid"
            continue
        fi
        [[ "$rc" == 0 ]] ||
            fail "set_default_shell $case_name returned $rc from apply_default_shell: $output"
        case "$case_name" in
            true)
                [[ -f "$marker" ]] ||
                    fail "chsh was not called although set_default_shell = true"
                [[ "$(cat "$marker")" == "chsh-called -s zsh" ]] ||
                    fail "chsh was called as [$(cat "$marker")] instead of exactly once with [-s zsh]"
                ;;
            *)
                [[ ! -e "$marker" ]] ||
                    fail "chsh was called although set_default_shell is $case_name"
                ;;
        esac
    done
}

run_zsh_basic_test() {
    local test_root home_dir fake_bin config_file output apply_rc zdotdir_dir zdotdir_output
    local baseline_dir state_path state_kind state_expression nongit_home

    [[ "${SHELL_SMOKE_ZSH_BASIC:-false}" == true ]] || return 0
    command -v zsh >/dev/null 2>&1 || {
        printf 'zsh smoke skipped: zsh is not installed\n'
        return 0
    }
    make_fixture_dir zsh-basic
    test_root=$fixture_dir
    home_dir="$test_root/home"
    fake_bin="$test_root/bin"
    mkdir -p "$home_dir" "$fake_bin" || fail "could not create zsh basic home and bin"
    make_stub_command "$fake_bin/nvim" "exit 0"
    make_stub_command "$fake_bin/git" 'printf "injected offline clone failure\n" >&2; exit 71'
    config_file="$test_root/zsh.conf"
    write_shell_config "$config_file" "$home_dir" \
        "zsh:enable=true,install=false,set_default_shell=false"
    if PATH="$fake_bin:$PATH" HOME="$home_dir" "$setup_script" -c "$config_file" \
        >"$test_root/apply.log" 2>&1; then
        apply_rc=0
    else
        apply_rc=$?
    fi
    [[ "$apply_rc" != 0 ]] ||
        fail_with_log "offline zsh apply reported success although pinned components are unavailable" \
            "$test_root/apply.log"
    assert_contains "$(cat "$test_root/apply.log")" \
        "applying basic zsh only"
    [[ -f "$home_dir/.zshrc" ]] || fail "offline zsh fallback did not create .zshrc"
    output=$(PATH="$fake_bin:$PATH" HOME="$home_dir" zsh -o no_append_history -i -c \
        'alias lal; alias ll; alias la; alias l; alias gs; alias tm; alias vi; print -r -- "ZSH=${ZSH-unset}"; print -r -- "HISTSIZE=$HISTSIZE"; print -r -- "SAVEHIST=$SAVEHIST"; print -r -- "HISTFILE=$HISTFILE"; [[ -o append_history ]] && print -r -- "APPEND=on" || print -r -- "APPEND=off"; [[ -o inc_append_history ]] && print -r -- "INC_APPEND=on" || print -r -- "INC_APPEND=off"; [[ -o hist_ignore_dups ]] && print -r -- "IGNORE_DUPS=on" || print -r -- "IGNORE_DUPS=off"; print -r -- "BASIC_SESSION_END"' \
        2>"$test_root/zsh.stderr") ||
        fail_with_log "zsh basic interactive session exited with an error" "$test_root/zsh.stderr"
    [[ ! -s "$test_root/zsh.stderr" ]] ||
        fail "zsh basic emitted stderr: $(cat "$test_root/zsh.stderr")"
    assert_line "$output" "lal='ls -lAF'"
    assert_line "$output" "ll='ls -lF'"
    assert_line "$output" "la='ls -A'"
    assert_line "$output" "l='ls -CF'"
    assert_line "$output" "gs='git status'"
    assert_line "$output" "tm=tmux"
    assert_line "$output" "vi=nvim"
    assert_line "$output" "ZSH=unset"
    assert_line "$output" "HISTSIZE=10000"
    assert_line "$output" "SAVEHIST=20000"
    assert_line "$output" "HISTFILE=$home_dir/.zsh_history"
    assert_line "$output" "APPEND=on"
    assert_line "$output" "INC_APPEND=on"
    assert_line "$output" "IGNORE_DUPS=on"
    assert_line "$output" "BASIC_SESSION_END"
    output=$(PATH="$fake_bin:$PATH" HOME="$home_dir" zsh -o no_append_history -i -c ':' \
        2>"$test_root/zsh-startup.stderr") ||
        fail_with_log "zsh basic startup session exited with an error" "$test_root/zsh-startup.stderr"
    [[ -z "$output" ]] || fail "zsh basic startup printed to stdout: $output"
    assert_file_absent "$home_dir/.oh-my-zsh"

    # With ZDOTDIR the history file follows ZDOTDIR instead of HOME.
    zdotdir_dir="$test_root/zdotdir"
    mkdir -p "$zdotdir_dir" || fail "could not create the ZDOTDIR fixture"
    printf '. "$HOME/.config/portable-devenv/shell/zsh.sh"\n' > "$zdotdir_dir/.zshrc" ||
        fail "could not create the ZDOTDIR .zshrc fixture"
    zdotdir_output=$(PATH="$fake_bin:$PATH" HOME="$home_dir" ZDOTDIR="$zdotdir_dir" zsh -i -c \
        'print -r -- "HISTFILE=$HISTFILE"' 2>"$test_root/zdotdir.stderr") ||
        fail_with_log "zsh session with ZDOTDIR exited with an error" "$test_root/zdotdir.stderr"
    assert_line "$zdotdir_output" "HISTFILE=$zdotdir_dir/.zsh_history"

    # Exact state delta against the same zsh with an empty user .zshrc.
    baseline_dir="$test_root/baseline-home"
    mkdir -p "$baseline_dir" || fail "could not create the zsh baseline home"
    : > "$baseline_dir/.zshrc" || fail "could not create the empty zsh baseline .zshrc"
    state_path="$fake_bin:$PATH"
    for state_kind in exports aliases options functions parameters; do
        case "$state_kind" in
            exports) state_expression='${(k)parameters[(R)*export*]}' ;;
            aliases) state_expression='${(k)aliases}' ;;
            options) state_expression='${(k)options[(R)on]}' ;;
            functions) state_expression='${(k)functions}' ;;
            parameters) state_expression='${(k)parameters}' ;;
        esac
        write_zsh_state_list "$baseline_dir" "$state_path" "$state_expression" \
            "$test_root/zsh-$state_kind.before" "$test_root/zsh-$state_kind.before.stderr"
        write_zsh_state_list "$home_dir" "$state_path" "$state_expression" \
            "$test_root/zsh-$state_kind.after" "$test_root/zsh-$state_kind.after.stderr"
    done
    assert_state_delta "zsh exported variables" "$test_root/zsh-exports.before" \
        "$test_root/zsh-exports.after" "HISTFILESIZE HISTSIZE "
    assert_state_delta "zsh aliases" "$test_root/zsh-aliases.before" \
        "$test_root/zsh-aliases.after" "gs l la lal ll tm vi "
    assert_state_delta "zsh options" "$test_root/zsh-options.before" \
        "$test_root/zsh-options.after" "appendhistory histappend histignoredups incappendhistory "
    assert_state_delta "zsh functions" "$test_root/zsh-functions.before" \
        "$test_root/zsh-functions.after" ""
    assert_state_delta "zsh parameters" "$test_root/zsh-parameters.before" \
        "$test_root/zsh-parameters.after" "HISTFILE HISTFILESIZE "
    assert_rc_block_body "$home_dir/.zshrc" '. "$HOME/.config/portable-devenv/shell/zsh.sh"'

    # An existing non-git ~/.oh-my-zsh is user data: setup fails and keeps it.
    nongit_home="$test_root/nongit-home"
    mkdir -p "$nongit_home/.oh-my-zsh" || fail "could not create the non-git oh-my-zsh fixture"
    printf 'user data\n' > "$nongit_home/.oh-my-zsh/user-file" ||
        fail "could not create the non-git oh-my-zsh user file"
    write_shell_config "$test_root/nongit.conf" "$nongit_home" \
        "zsh:enable=true,install=false,set_default_shell=false"
    if PATH="$fake_bin:$PATH" HOME="$nongit_home" "$setup_script" -c "$test_root/nongit.conf" \
        >"$test_root/nongit.log" 2>&1; then
        fail_with_log "setup reported success for a non-git ~/.oh-my-zsh directory" \
            "$test_root/nongit.log"
    fi
    assert_contains "$(cat "$test_root/nongit.log")" \
        "Pinned repository target is not a git repository: $nongit_home/.oh-my-zsh"
    assert_file_line "$nongit_home/.oh-my-zsh/user-file" "user data"
    assert_file_absent "$nongit_home/.oh-my-zsh/.git"
}

run_zsh_online_test() {
    local test_root home_dir config_file output fake_bin
    local omz_commit autosuggestions_commit syntax_commit path_line expected_zsh_path
    local original_zshrc_hash backup_id shallow_home baseline_home baseline_path
    local state_kind state_expression state_exclude_pattern

    [[ "${SHELL_SMOKE_ZSH_ONLINE:-false}" == true ]] || return 0
    command -v zsh >/dev/null 2>&1 ||
        fail "SHELL_SMOKE_ZSH_ONLINE=true requires zsh, which is not installed"
    make_fixture_dir zsh-online
    test_root=$fixture_dir
    home_dir="$test_root/home"
    fake_bin="$test_root/bin"
    mkdir -p "$home_dir" "$fake_bin" || fail "could not create zsh online home and bin"
    printf '# user zshrc\n' > "$home_dir/.zshrc" || fail "could not create the zsh online user .zshrc"
    original_zshrc_hash=$(sha256sum "$home_dir/.zshrc" | awk '{print $1}') ||
        fail "could not hash the zsh online user .zshrc"
    make_stub_command "$fake_bin/chsh" "printf 'chsh-called %s\\n' \"\$*\" > \"\$SHELL_SMOKE_CHSH_MARKER\"; exit 99"
    make_stub_command "$fake_bin/nvim" "exit 0"
    config_file="$test_root/zsh-online.conf"
    write_shell_config "$config_file" "$home_dir" \
        "zsh:enable=true,install=false,set_default_shell=false"
    SHELL_SMOKE_CHSH_MARKER="$test_root/chsh.marker" \
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" -c "$config_file" \
        >"$test_root/apply.log" 2>&1 ||
        fail_with_log "online zsh apply with pinned oh-my-zsh and plugin clones failed" \
            "$test_root/apply.log"
    assert_rc_block_body "$home_dir/.zshrc" '. "$HOME/.config/portable-devenv/shell/zsh-online.sh"'
    assert_file_contains "$home_dir/.zshrc" "# user zshrc"
    [[ ! -e "$test_root/chsh.marker" ]] ||
        fail "chsh was called although set_default_shell = false"
    if grep -F "Unknown [zsh] key: set_default_shell" "$test_root/apply.log" \
        >/dev/null 2>&1; then
        fail "zsh known-key validation rejected set_default_shell"
    fi
    if grep -F "ZSH_DISABLE_COMPFIX" \
        "$repo_dir/tools/shell/zsh/zsh-online.sh" >/dev/null 2>&1; then
        fail "zsh online configuration disables compfix without evidence"
    fi
    git_c_pattern="git -C \"\$repository_target\""
    if grep -F "$git_c_pattern" \
        "$repo_dir/tools/shell/zsh/module.sh" \
        >/dev/null 2>&1; then
        fail "zsh module still uses git -C"
    fi
    assert_file_line "$repo_dir/configs/online.conf" "[bash]"
    assert_file_line "$repo_dir/configs/online.conf" "[zsh]"
    assert_file_line "$repo_dir/configs/online.conf" "set_default_shell = false"
    assert_file_line "$repo_dir/configs/offline-lite.conf" "[bash]"
    omz_commit=$(git -C "$home_dir/.oh-my-zsh" rev-parse HEAD) ||
        fail "could not read the installed oh-my-zsh commit"
    autosuggestions_commit=$(git -C \
        "$home_dir/.oh-my-zsh/custom/plugins/zsh-autosuggestions" rev-parse HEAD) ||
        fail "could not read the installed zsh-autosuggestions commit"
    syntax_commit=$(git -C \
        "$home_dir/.oh-my-zsh/custom/plugins/zsh-syntax-highlighting" rev-parse HEAD) ||
        fail "could not read the installed zsh-syntax-highlighting commit"
    [[ "$omz_commit" == 17a2b4c3a5855524ad4772a17ada0dc474e2fdf3 ]] ||
        fail "oh-my-zsh was not at the pinned commit"
    [[ "$autosuggestions_commit" == 85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5 ]] ||
        fail "zsh-autosuggestions was not at the pinned commit"
    [[ "$syntax_commit" == e6683f20e5c38d3e5447f45845d04ddda75d0f23 ]] ||
        fail "zsh-syntax-highlighting was not at the pinned commit"
    git -C "$home_dir/.oh-my-zsh" checkout --quiet --detach HEAD~1 ||
        fail "could not prepare an older oh-my-zsh checkout"
    HOME="$home_dir" "$setup_script" -c "$config_file" \
        >"$test_root/repin.log" 2>&1 ||
        fail_with_log "different commit was not repinned" "$test_root/repin.log"
    omz_commit=$(git -C "$home_dir/.oh-my-zsh" rev-parse HEAD) ||
        fail "could not read repinned oh-my-zsh commit"
    [[ "$omz_commit" == 17a2b4c3a5855524ad4772a17ada0dc474e2fdf3 ]] ||
        fail "existing oh-my-zsh clone did not reach the pinned commit"
    output=$(env -u DOCKER_SCRIPT SHELL_SMOKE_CHSH_MARKER="$test_root/chsh.marker" \
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        zsh -o no_append_history -i -c '
            alias lal
            alias ll
            alias la
            alias l
            alias gs
            alias tm
            alias vi
            print -r -- "HISTSIZE=$HISTSIZE"
            print -r -- "SAVEHIST=$SAVEHIST"
            print -r -- "HISTFILE=$HISTFILE"
            print -r -- "PATH=$PATH"
            [[ -n "${DOCKER_SCRIPT-}" ]] && print -r -- "MACHINE_DOCKER_SCRIPT_ACTIVE"
            [[ -o append_history ]] && print -r -- "APPEND=on" || print -r -- "APPEND=off"
            [[ -o inc_append_history ]] && print -r -- "INC_APPEND=on" || print -r -- "INC_APPEND=off"
            [[ -o hist_ignore_dups ]] && print -r -- "IGNORE_DUPS=on" || print -r -- "IGNORE_DUPS=off"
            print -r -- "AUTO_UPDATE=$ZSH_DISABLE_AUTO_UPDATE"
            print -r -- "THEME=$ZSH_THEME"
            print -r -- "PLUGINS=${plugins[*]}"
            alias g
            whence _zsh_autosuggest_start
            whence _zsh_highlight
            whence git_prompt_info
            print -r -- "ONLINE_SESSION_END"
        ' 2>"$test_root/zsh.stderr") ||
        fail_with_log "zsh online interactive session exited with an error" "$test_root/zsh.stderr"
    [[ ! -s "$test_root/zsh.stderr" ]] ||
        fail "zsh online emitted stderr: $(cat "$test_root/zsh.stderr")"
    assert_line "$output" "lal='ls -lAF'"
    assert_line "$output" "ll='ls -lF'"
    assert_line "$output" "la='ls -A'"
    assert_line "$output" "l='ls -CF'"
    assert_line "$output" "gs='git status'"
    assert_line "$output" "tm=tmux"
    assert_line "$output" "vi=nvim"
    assert_line "$output" "HISTSIZE=10000"
    assert_line "$output" "SAVEHIST=20000"
    assert_line "$output" "HISTFILE=$home_dir/.zsh_history"
    assert_line "$output" "APPEND=on"
    assert_line "$output" "INC_APPEND=on"
    assert_line "$output" "IGNORE_DUPS=on"
    path_line=$(printf '%s\n' "$output" | grep '^PATH=') ||
        fail "zsh online output has no PATH line"
    assert_path_entry_count "${path_line#PATH=}" 1 "$home_dir/.local/bin"
    case "$output" in
        *pwr*|*dbg*|*MACHINE_DOCKER_SCRIPT_ACTIVE*|*sifive*|*SiFive*|*s2c*|*/go/bin*|*cargo/bin*)
            fail "machine-specific shell content was active in zsh"
            ;;
    esac
    assert_line "$output" "AUTO_UPDATE=true"
    assert_line "$output" "THEME=robbyrussell"
    assert_line "$output" "PLUGINS=git zsh-autosuggestions zsh-syntax-highlighting"
    assert_line "$output" "g=git"
    assert_line "$output" "_zsh_autosuggest_start"
    assert_line "$output" "_zsh_highlight"
    assert_line "$output" "git_prompt_info"
    assert_line "$output" "ONLINE_SESSION_END"
    output=$(PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" zsh -o no_append_history -i -c ':' \
        2>"$test_root/zsh-startup.stderr") ||
        fail_with_log "zsh online startup session exited with an error" "$test_root/zsh-startup.stderr"
    [[ -z "$output" ]] || fail "zsh online startup printed to stdout: $output"

    write_shell_config "$config_file" "$home_dir" \
        "zsh:enable=true,install=false,set_default_shell=true"
    if SHELL_SMOKE_CHSH_MARKER="$test_root/chsh.marker" \
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" -c "$config_file" \
        >"$test_root/chsh-failure.log" 2>&1; then
        fail_with_log "setup reported success although chsh failed" "$test_root/chsh-failure.log"
    fi
    [[ -f "$test_root/chsh.marker" ]] ||
        fail "chsh was not called although set_default_shell = true"
    expected_zsh_path=$(PATH="$fake_bin:/usr/bin:/bin" command -v zsh) ||
        fail "could not locate zsh for the chsh argument check"
    [[ "$(cat "$test_root/chsh.marker")" == "chsh-called -s $expected_zsh_path" ]] ||
        fail "chsh was called as [$(cat "$test_root/chsh.marker")] instead of [-s $expected_zsh_path]"
    assert_contains "$(cat "$test_root/chsh-failure.log")" "chsh failed"
    assert_contains "$(cat "$test_root/chsh-failure.log")" \
        "chsh failed; run chsh -s $expected_zsh_path manually"

    # Without a set_default_shell key chsh must not run (default is false).
    write_shell_config "$config_file" "$home_dir" "zsh:enable=true,install=false"
    rm -f "$test_root/chsh.marker" || fail "could not reset the chsh marker"
    SHELL_SMOKE_CHSH_MARKER="$test_root/chsh.marker" \
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" -c "$config_file" \
        >"$test_root/chsh-default.log" 2>&1 ||
        fail_with_log "apply without set_default_shell failed" "$test_root/chsh-default.log"
    [[ ! -e "$test_root/chsh.marker" ]] ||
        fail "chsh was called although the set_default_shell key is absent"

    # Compare against the same pinned Oh My Zsh and plugins without the target startup file.
    baseline_home="$test_root/online-baseline/home"
    mkdir -p "$baseline_home/.local/bin" || fail "could not create the zsh online baseline home"
    ln -s "$home_dir/.oh-my-zsh" "$baseline_home/.oh-my-zsh" ||
        fail "could not link the pinned Oh My Zsh baseline fixture"
    cat > "$baseline_home/.zshrc" <<'EOF'
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME=robbyrussell
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
ZSH_DISABLE_AUTO_UPDATE=true
. "$ZSH/oh-my-zsh.sh"
EOF
    baseline_path="$baseline_home/.local/bin:$fake_bin:/usr/bin:/bin"
    for state_kind in exports aliases options functions parameters; do
        case "$state_kind" in
            exports) state_expression='${(k)parameters[(R)*export*]}' ;;
            aliases) state_expression='${(k)aliases}' ;;
            options) state_expression='${(k)options[(R)on]}' ;;
            functions) state_expression='${(k)functions}' ;;
            parameters) state_expression='${(k)parameters}' ;;
        esac
        state_exclude_pattern='^$'
        # The pinned highlighter names widget wrappers with session-scoped SECONDS and RANDOM.
        [[ "$state_kind" == functions ]] &&
            state_exclude_pattern='^_zsh_highlight_widget_orig-s[0-9.]+-r[0-9]+-'
        write_zsh_state_list "$baseline_home" "$baseline_path" "$state_expression" \
            "$test_root/zsh-online-$state_kind.before" \
            "$test_root/zsh-online-$state_kind.before.stderr" \
            "$state_exclude_pattern"
        write_zsh_state_list "$home_dir" "$fake_bin:/usr/bin:/bin" "$state_expression" \
            "$test_root/zsh-online-$state_kind.after" \
            "$test_root/zsh-online-$state_kind.after.stderr" \
            "$state_exclude_pattern"
    done
    assert_state_delta "zsh online exported variables" "$test_root/zsh-online-exports.before" \
        "$test_root/zsh-online-exports.after" "HISTFILESIZE HISTSIZE "
    assert_state_delta "zsh online aliases" "$test_root/zsh-online-aliases.before" \
        "$test_root/zsh-online-aliases.after" "gs lal tm vi "
    assert_state_delta "zsh online options" "$test_root/zsh-online-options.before" \
        "$test_root/zsh-online-options.after" "appendhistory histappend incappendhistory "
    assert_state_delta "zsh online functions" "$test_root/zsh-online-functions.before" \
        "$test_root/zsh-online-functions.after" ""
    assert_state_delta "zsh online parameters" "$test_root/zsh-online-parameters.before" \
        "$test_root/zsh-online-parameters.after" "HISTFILESIZE "

    # Restore returns the user .zshrc and removes every deployed zsh link.
    backup_id=$(find "$home_dir/backups" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %f\n' |
        sort -n | head -n 1 | cut -d' ' -f2) ||
        fail "could not list the zsh online backups"
    [[ -n "$backup_id" ]] || fail "zsh online setup created no backup under $home_dir/backups"
    HOME="$home_dir" "$setup_script" --restore "$backup_id" -c "$config_file" \
        >"$test_root/restore.log" 2>&1 ||
        fail_with_log "zsh online restore of backup $backup_id failed" "$test_root/restore.log"
    [[ "$(sha256sum "$home_dir/.zshrc" | awk '{print $1}')" == "$original_zshrc_hash" ]] ||
        fail "zsh online restore did not return .zshrc to its original bytes"
    assert_file_absent "$home_dir/.config/portable-devenv/shell/zsh.sh"
    assert_file_absent "$home_dir/.config/portable-devenv/shell/zsh-common.sh"
    assert_file_absent "$home_dir/.config/portable-devenv/shell/zsh-online.sh"

    # Existing shallow clones lack the pinned commits; setup must fetch them.
    shallow_home="$test_root/shallow-home"
    mkdir -p "$shallow_home" || fail "could not create the shallow clone fixture home"
    git clone --quiet --depth 1 https://github.com/ohmyzsh/ohmyzsh.git \
        "$shallow_home/.oh-my-zsh" || fail "could not create the shallow oh-my-zsh clone"
    git clone --quiet --depth 1 https://github.com/zsh-users/zsh-autosuggestions.git \
        "$shallow_home/.oh-my-zsh/custom/plugins/zsh-autosuggestions" ||
        fail "could not create the shallow zsh-autosuggestions clone"
    write_shell_config "$test_root/shallow.conf" "$shallow_home" \
        "zsh:enable=true,install=false,set_default_shell=false"
    PATH="$fake_bin:/usr/bin:/bin" HOME="$shallow_home" \
        "$setup_script" -c "$test_root/shallow.conf" >"$test_root/shallow.log" 2>&1 ||
        fail_with_log "setup did not repin the existing shallow clones" "$test_root/shallow.log"
    omz_commit=$(git -C "$shallow_home/.oh-my-zsh" rev-parse HEAD) ||
        fail "could not read the shallow oh-my-zsh commit after setup"
    [[ "$omz_commit" == 17a2b4c3a5855524ad4772a17ada0dc474e2fdf3 ]] ||
        fail "shallow oh-my-zsh clone was not fetched to the pinned commit"
    autosuggestions_commit=$(git -C \
        "$shallow_home/.oh-my-zsh/custom/plugins/zsh-autosuggestions" rev-parse HEAD) ||
        fail "could not read the shallow zsh-autosuggestions commit after setup"
    [[ "$autosuggestions_commit" == 85919cd1ffa7d2d5412f6d3fe437ebdbeeec4fc5 ]] ||
        fail "shallow zsh-autosuggestions clone was not fetched to the pinned commit"
}

run_zsh_auto_update_order_test() {
    local test_root home_dir marker output

    command -v zsh >/dev/null 2>&1 || {
        printf 'zsh auto-update order smoke skipped: zsh is not installed\n'
        return 0
    }
    make_fixture_dir zsh-auto-update-order
    test_root=$fixture_dir
    home_dir="$test_root/home"
    marker="$test_root/auto-update.marker"
    mkdir -p "$home_dir/.oh-my-zsh" "$home_dir/.config/portable-devenv/shell" ||
        fail "could not create zsh auto-update fixture directories"
    printf 'print -r -- "$ZSH_DISABLE_AUTO_UPDATE" > "$AUTO_UPDATE_MARKER"\n' \
        > "$home_dir/.oh-my-zsh/oh-my-zsh.sh" ||
        fail "could not create oh-my-zsh observation stub"
    printf ':\n' > "$home_dir/.config/portable-devenv/shell/zsh.sh" ||
        fail "could not create zsh common observation stub"
    if output=$(HOME="$home_dir" AUTO_UPDATE_MARKER="$marker" PATH="/usr/bin:/bin" \
        zsh -f -c '. "$1"' zsh "$repo_dir/tools/shell/zsh/zsh-online.sh" 2>&1); then
        :
    else
        fail "zsh auto-update observation command failed: $output"
    fi
    [[ -s "$marker" ]] || fail "oh-my-zsh observation marker was not written"
    [[ "$(cat "$marker")" == true ]] ||
        fail "auto-update disable was not set before oh-my-zsh loaded"
}

run_zsh_partial_pin_failure_test() {
    local test_root git_path fake_bin failure home_dir config_file git_marker output rc
    local omz_commit autosuggestions_commit

    [[ "${SHELL_SMOKE_ZSH_ONLINE:-false}" == true ]] || return 0
    test_root="$smoke_tmp_root/zsh-partial-pin-failure"
    mkdir -p "$test_root" || fail "could not create partial pin failure root"
    git_path=$(command -v git) || fail "could not locate git for partial pin failure fixtures"
    fake_bin="$test_root/bin"
    mkdir -p "$fake_bin" || fail "could not create partial pin failure bin"
    cat > "$fake_bin/git" <<'EOF'
#!/bin/sh
if [ "$1" = clone ]; then
    printf '%s\n' "$3" >> "$SHELL_SMOKE_GIT_MARKER"
    case "$SHELL_SMOKE_FAIL_PLUGIN:$3" in
        autosuggestions:https://github.com/zsh-users/zsh-autosuggestions.git)
            printf 'injected autosuggestions clone failure\n' >&2
            exit 73
            ;;
        syntax-highlighting:https://github.com/zsh-users/zsh-syntax-highlighting.git)
            printf 'injected syntax-highlighting clone failure\n' >&2
            exit 74
            ;;
    esac
fi
exec "$SHELL_SMOKE_REAL_GIT" "$@"
EOF
    chmod 755 "$fake_bin/git" || fail "could not make partial pin failure git stub executable"
    # shellcheck disable=SC1091
    . "$repo_dir/tools/shell/zsh/versions.sh" ||
        fail "could not load pinned zsh repository versions"
    for failure in autosuggestions syntax-highlighting; do
        home_dir="$test_root/$failure/home"
        config_file="$test_root/$failure.conf"
        git_marker="$test_root/$failure.git-clones"
        mkdir -p "$home_dir" || fail "could not create $failure fallback home"
        : > "$git_marker" || fail "could not create $failure git clone marker"
        write_shell_config "$config_file" "$home_dir" \
            "zsh:enable=true,install=false,set_default_shell=false"
        if output=$(SHELL_SMOKE_REAL_GIT="$git_path" SHELL_SMOKE_GIT_MARKER="$git_marker" \
            SHELL_SMOKE_FAIL_PLUGIN="$failure" PATH="$fake_bin:/usr/bin:/bin" \
            HOME="$home_dir" "$setup_script" -c "$config_file" 2>&1); then
            fail "setup reported success after the $failure pin failed: $output"
        else
            rc=$?
        fi
        [[ "$rc" != 0 ]] || fail "$failure pin failure returned success"
        assert_contains "$output" \
            "[ERROR] oh-my-zsh or its plugins could not be pinned; applying basic zsh only"
        assert_summary_state "$output" zsh failed "module_apply failed (status 1)"
        assert_file_present "$home_dir/.config/portable-devenv/shell/zsh.sh"
        assert_file_absent "$home_dir/.config/portable-devenv/shell/zsh-online.sh"
        assert_rc_block_body "$home_dir/.zshrc" \
            '. "$HOME/.config/portable-devenv/shell/zsh.sh"'
        assert_file_line "$git_marker" "$PORTABLE_DEVENV_OMZ_URL"
        omz_commit=$("$git_path" --git-dir="$home_dir/.oh-my-zsh/.git" rev-parse HEAD) ||
            fail "could not read the successful oh-my-zsh pin after $failure failure"
        [[ "$omz_commit" == "$PORTABLE_DEVENV_OMZ_COMMIT" ]] ||
            fail "oh-my-zsh reached $omz_commit instead of its pin after $failure failure"
        if [[ "$failure" == syntax-highlighting ]]; then
            assert_file_line "$git_marker" "$PORTABLE_DEVENV_AUTOSUGGESTIONS_URL"
            autosuggestions_commit=$("$git_path" \
                --git-dir="$home_dir/.oh-my-zsh/custom/plugins/zsh-autosuggestions/.git" \
                rev-parse HEAD) ||
                fail "could not read the successful autosuggestions pin before syntax failure"
            [[ "$autosuggestions_commit" == "$PORTABLE_DEVENV_AUTOSUGGESTIONS_COMMIT" ]] ||
                fail "autosuggestions did not reach its pin before syntax failure"
        else
            assert_file_line "$git_marker" "$PORTABLE_DEVENV_AUTOSUGGESTIONS_URL"
            ! grep -Fx "$PORTABLE_DEVENV_SYNTAX_HIGHLIGHTING_URL" "$git_marker" >/dev/null 2>&1 ||
                fail "syntax-highlighting clone ran after autosuggestions had already failed"
        fi
        output=$(HOME="$home_dir" PATH="$fake_bin:/usr/bin:/bin" \
            zsh -o no_append_history -i -c 'print -r -- "HISTSIZE=$HISTSIZE"; alias lal' \
            2>"$test_root/$failure.zsh.stderr") ||
            fail_with_log "basic zsh fallback failed after $failure pin failure" \
                "$test_root/$failure.zsh.stderr"
        [[ ! -s "$test_root/$failure.zsh.stderr" ]] ||
            fail "basic zsh fallback emitted stderr after $failure pin failure"
        assert_line "$output" "HISTSIZE=10000"
        assert_line "$output" "lal='ls -lAF'"
    done
}

run_zsh_dry_run_test() {
    local test_root home_dir fake_bin config_file dry_run_output
    local before_snapshot after_snapshot

    [[ "${SHELL_SMOKE_ZSH_DRY_RUN:-true}" == true ]] || return 0
    command -v zsh >/dev/null 2>&1 || {
        printf 'zsh dry-run skipped: zsh is not installed\n'
        return 0
    }
    make_fixture_dir zsh-dry-run
    test_root=$fixture_dir
    home_dir="$test_root/home"
    fake_bin="$test_root/bin"
    mkdir -p "$home_dir/.oh-my-zsh" "$fake_bin" ||
        fail "could not create zsh dry-run home and bin"
    printf 'existing omz marker\n' > "$home_dir/.oh-my-zsh/marker" ||
        fail "could not create the existing oh-my-zsh marker"
    printf '# user zshrc\n' > "$home_dir/.zshrc" ||
        fail "could not create the zsh dry-run user .zshrc"
    make_stub_command "$fake_bin/chsh" "printf 'chsh-called\\n' > \"\$SHELL_SMOKE_CHSH_MARKER\"; exit 99"
    config_file="$test_root/dry-run.conf"
    write_shell_config "$config_file" "$home_dir" \
        "zsh:enable=true,install=false,set_default_shell=true"
    before_snapshot="$test_root/before"
    after_snapshot="$test_root/after"
    snapshot_tree "$home_dir" "$before_snapshot"
    SHELL_SMOKE_CHSH_MARKER="$test_root/chsh.marker" \
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" --dry-run -c "$config_file" \
        >"$test_root/run.log" 2>&1 ||
        fail_with_log "zsh dry-run returned failure" "$test_root/run.log"
    snapshot_tree "$home_dir" "$after_snapshot"
    diff -u "$before_snapshot" "$after_snapshot" >"$test_root/snapshot.diff" 2>&1 ||
        fail_with_log "zsh dry-run changed HOME" "$test_root/snapshot.diff"
    [[ ! -e "$test_root/chsh.marker" ]] ||
        fail "zsh dry-run called chsh"
    dry_run_output=$(< "$test_root/run.log") || fail "could not read the zsh dry-run log"
    assert_contains "$dry_run_output" \
        "Would pin $home_dir/.oh-my-zsh to 17a2b4c3a5855524ad4772a17ada0dc474e2fdf3"
    assert_contains "$dry_run_output" "Would change default shell to zsh"
    assert_summary_state "$dry_run_output" zsh applied completed

    rm -rf "$home_dir/.oh-my-zsh" "$home_dir/.zshrc" ||
        fail "could not reset the zsh dry-run home for the fresh run"
    before_snapshot="$test_root/fresh-before"
    after_snapshot="$test_root/fresh-after"
    snapshot_tree "$home_dir" "$before_snapshot"
    rm -f "$test_root/chsh.marker" || fail "could not reset the fresh dry-run chsh marker"
    SHELL_SMOKE_CHSH_MARKER="$test_root/chsh.marker" \
        PATH="$fake_bin:/usr/bin:/bin" HOME="$home_dir" \
        "$setup_script" --dry-run -c "$config_file" \
        >"$test_root/fresh-run.log" 2>&1 ||
        fail_with_log "fresh zsh dry-run returned failure" "$test_root/fresh-run.log"
    snapshot_tree "$home_dir" "$after_snapshot"
    diff -u "$before_snapshot" "$after_snapshot" >"$test_root/fresh-snapshot.diff" 2>&1 ||
        fail_with_log "fresh zsh dry-run changed HOME" "$test_root/fresh-snapshot.diff"
    [[ ! -d "$home_dir/.oh-my-zsh" ]] || fail "fresh zsh dry-run created oh-my-zsh"
    [[ ! -e "$test_root/chsh.marker" ]] ||
        fail "fresh zsh dry-run called chsh"
}

run_bash_tests || exit $?
run_bash_rc_apply_failure_test || exit $?
run_common_posix_sh_test || exit $?
run_bash_vi_variants || exit $?
run_bash_rc_lifecycle_test || exit $?
run_bash_dry_run_test || exit $?
run_repository_config_dry_run_test || exit $?
run_zsh_install_stub_test || exit $?
run_zsh_missing_chsh_test || exit $?
run_zsh_default_shell_config_test || exit $?
run_zsh_dry_run_test || exit $?
run_zsh_basic_test || exit $?
run_zsh_online_test || exit $?
run_zsh_partial_pin_failure_test || exit $?
run_zsh_auto_update_order_test || exit $?
printf 'shell smoke tests passed\n'
