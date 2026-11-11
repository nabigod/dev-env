#!/bin/bash

set -u
set -o pipefail

REPO_DIR=$(cd -P "$(dirname "$0")/.." && pwd) || exit 2
EDITOR_ROOT=${EDITOR_ROOT:-"$REPO_DIR/tools/editor"}
VIM_BIN=${VIM_BIN:-vim}
NVIM_BIN=${NVIM_BIN:-nvim}
TEST_ROOT=$(mktemp -d) || exit 2
RUN_MATRIX_ONLY=0
RUN_PATH_ONLY=0
RUN_CURSOR_ONLY=0

if [[ "${1:-}" == "--matrix-only" ]]; then
    RUN_MATRIX_ONLY=1
elif [[ "${1:-}" == "--path-only" ]]; then
    RUN_PATH_ONLY=1
elif [[ "${1:-}" == "--cursor-only" ]]; then
    RUN_CURSOR_ONLY=1
elif [[ -n "${1:-}" ]]; then
    printf 'Usage: %s [--matrix-only|--path-only|--cursor-only]\n' "$0" >&2
    exit 2
fi

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

skip() {
    printf 'SKIP: %s\n' "$*"
}

assert_file_contains() {
    grep -Fq "$2" "$1" || fail "$1 does not contain [$2]"
}

assert_no_editor_error() {
    local output_base="$1"
    if grep -Eq 'Error detected|E[0-9]{3}:|Vim: Error|NVIM.*Error' \
        "$output_base.stdout" "$output_base.stderr" >/dev/null 2>&1; then
        fail "editor reported an error; see $output_base.stdout and $output_base.stderr"
    fi
}

editor_available() {
    local editor="$1"
    case "$editor" in
        vim) command -v "$VIM_BIN" >/dev/null 2>&1 ;;
        nvim) command -v "$NVIM_BIN" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

run_editor_matrix_case() {
    local editor="$1" filetype="$2" file_path="$3" output_base="$4"
    local home="$TEST_ROOT/home-$editor-$filetype"
    local config
    mkdir -p "$home"
    if [[ "$editor" == vim ]]; then
        config="$EDITOR_ROOT/vim/.vimrc"
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" "$file_path" \
            -c 'sleep 10m' -c "set ft=$filetype" -c 'write' \
            -c 'sleep 10m' -c "redir! > $output_base" \
            -c 'silent echomsg "match=" . len(getmatches())' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor $filetype invocation failed"
    else
        config="$EDITOR_ROOT/neovim/init.vim"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" "$file_path" \
            -c 'sleep 10m' -c "set ft=$filetype" -c 'write' \
            -c "redir! > $output_base" \
            -c 'silent echomsg "match=" . len(getmatches())' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor $filetype invocation failed"
    fi
    assert_no_editor_error "$output_base"
}

run_editor_options() {
    local editor="$1" file_path="$2" output_base="$3"
    local home="$TEST_ROOT/options-$editor"
    local config
    mkdir -p "$home"
    if [[ "$editor" == vim ]]; then
        config="$EDITOR_ROOT/vim/.vimrc"
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" "$file_path" \
            -c "redir! > $output_base" \
            -c 'silent echomsg "opts=" . &number . "," . &autoindent . "," . &cindent . "," . &smartindent . "," . &wrap . "," . &ruler . "," . &tabstop . "," . &shiftwidth . "," . &expandtab . "," . &fileencodings . "," . &fileencoding . "," . &hlsearch . "," . &colorcolumn . "," . &tags . "," . get(g:, "colors_name", "NONE")' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor options invocation failed"
    else
        config="$EDITOR_ROOT/neovim/init.vim"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" "$file_path" \
            -c 'sleep 10m' -c "redir! > $output_base" \
            -c 'silent echomsg "opts=" . &number . "," . &autoindent . "," . &cindent . "," . &smartindent . "," . &wrap . "," . &ruler . "," . &tabstop . "," . &shiftwidth . "," . &expandtab . "," . &fileencodings . "," . &fileencoding . "," . &hlsearch . "," . &colorcolumn . "," . &tags . "," . get(g:, "colors_name", "NONE")' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor options invocation failed"
    fi
    assert_no_editor_error "$output_base"
    assert_file_contains "$output_base" \
        'opts=1,1,1,1,0,1,4,4,0,ucs-bom,utf-8,euc-kr,latin1,utf-8,1,100,./tags;,./ctags;,jellybeans'
}

run_editor_transition() {
    local editor="$1"
    local output_base="$TEST_ROOT/transition-$editor"
    local home="$TEST_ROOT/transition-home-$editor"
    local config first_file second_file command_file
    first_file="$TEST_ROOT/transition-$editor-python"
    second_file="$TEST_ROOT/transition-$editor-markdown"
    command_file="$TEST_ROOT/transition-$editor.vim"
    printf 'python  \n' >"$first_file"
    printf 'markdown  \n' >"$second_file"
    {
        printf 'redir! > %s\n' "$output_base"
        printf 'edit %s\n' "$first_file"
        if [[ "$editor" == nvim ]]; then
            printf 'sleep 10m\n'
        fi
        printf '%s\n' 'set ft=python'
        printf '%s\n' 'silent echomsg "python=" . len(getmatches())'
        printf 'split %s\n' "$second_file"
        printf '%s\n' 'set ft=markdown'
        printf '%s\n' 'silent echomsg "markdown=" . len(getmatches())'
        printf '%s\n' 'wincmd p'
        printf '%s\n' 'set ft=text'
        printf '%s\n' 'silent echomsg "text=" . len(getmatches())'
        printf 'edit! %s\n' "$second_file"
        if [[ "$editor" == nvim ]]; then
            printf 'sleep 10m\n'
        fi
        printf '%s\n' 'set ft=markdown'
        printf '%s\n' 'silent echomsg "reopen=" . len(getmatches())'
        printf '%s\n' 'silent messages'
        printf '%s\n' 'redir END'
        printf '%s\n' 'qa!'
    } >"$command_file"
    mkdir -p "$home"
    if [[ "$editor" == vim ]]; then
        config="$EDITOR_ROOT/vim/.vimrc"
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" -S "$command_file" \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor buffer transition invocation failed"
    else
        config="$EDITOR_ROOT/neovim/init.vim"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" -S "$command_file" \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor buffer transition invocation failed"
    fi
    assert_no_editor_error "$output_base"
    assert_file_contains "$output_base" 'python=1'
    assert_file_contains "$output_base" 'markdown=0'
    assert_file_contains "$output_base" 'text=0'
    assert_file_contains "$output_base" 'reopen=0'
}

run_editor_cursor_restore() {
    local editor="$1" home="$TEST_ROOT/cursor-home-$1"
    local config file_path write_output read_output info_path
    file_path="$TEST_ROOT/cursor-$editor.txt"
    write_output="$TEST_ROOT/cursor-write-$editor"
    read_output="$TEST_ROOT/cursor-read-$editor"
    info_path="$home/editor-info"
    printf 'first line\nsecond line\nthird line\nfourth line\nfifth line\nsixth line\nseventh line\n' >"$file_path"
    mkdir -p "$home"
    if [[ "$editor" == vim ]]; then
        config="$EDITOR_ROOT/vim/.vimrc"
        HOME="$home" "$VIM_BIN" -N -n -i "$info_path" -u "$config" "$file_path" \
            -c 'set ft=python' -c 'call cursor(2, 4)' -c 'write' \
            -c "redir! > $write_output" -c 'silent echomsg "saved=1"' \
            -c 'redir END' -c 'qa!' \
            >"$write_output.stdout" 2>"$write_output.stderr" \
            || fail "$editor cursor write invocation failed"
        HOME="$home" "$VIM_BIN" -N -n -i "$info_path" -u "$config" "$file_path" \
            -c "redir! > $read_output" \
            -c 'silent echomsg "cursor=" . line(".") . ":" . col(".")' \
            -c 'redir END' -c 'qa!' \
            >"$read_output.stdout" 2>"$read_output.stderr" \
            || fail "$editor cursor read invocation failed"
    else
        config="$EDITOR_ROOT/neovim/init.vim"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -i "$info_path" \
            -u "$config" "$file_path" -c 'sleep 10m' -c 'set ft=python' \
            -c 'call cursor(2, 4)' -c 'write' \
            -c "redir! > $write_output" -c 'silent echomsg "saved=1"' \
            -c 'redir END' -c 'qa!' \
            >"$write_output.stdout" 2>"$write_output.stderr" \
            || fail "$editor cursor write invocation failed"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -i "$info_path" \
            -u "$config" "$file_path" -c 'sleep 10m' -c "redir! > $read_output" \
            -c 'silent echomsg "cursor=" . line(".") . ":" . col(".")' \
            -c 'redir END' -c 'qa!' \
            >"$read_output.stdout" 2>"$read_output.stderr" \
            || fail "$editor cursor read invocation failed"
    fi
    assert_no_editor_error "$write_output"
    assert_no_editor_error "$read_output"
    assert_file_contains "$read_output" 'cursor=2:4'
    if grep -Fq 'cursor=7:4' "$read_output"; then
        fail "$editor cursor restore only preserved the column"
    fi
    printf 'PASS: %s cursor restore line=2 column=4 (not line=7)\n' "$editor"
}

run_editor_path_load() {
    local editor="$1" path_name="$2" path_number="$3"
    local path_root="$TEST_ROOT/path-$editor-$path_number-$path_name"
    local output_base="$TEST_ROOT/path-output-$editor-$path_number"
    local home="$TEST_ROOT/path-home-$editor-$path_number"
    local config load_file="$path_root/load.txt"
    mkdir -p "$path_root" "$home"
    cp -a "$EDITOR_ROOT" "$path_root/editor"
    printf 'path load\n' >"$load_file"
    if [[ "$editor" == vim ]]; then
        config="$path_root/editor/vim/.vimrc"
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" "$load_file" \
            -c 'sleep 10m' -c 'colorscheme default' -c 'colorscheme jellybeans' \
            -c "redir! > $output_base" \
            -c 'scriptnames' \
            -c 'silent echomsg "colors=" . get(g:, "colors_name", "NONE")' \
            -c 'silent echomsg "localdir=" . haslocaldir()' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor special path invocation failed for [$path_name]"
    else
        config="$path_root/editor/neovim/init.vim"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" "$load_file" \
            -c 'colorscheme default' -c 'colorscheme jellybeans' \
            -c "redir! > $output_base" \
            -c 'scriptnames' \
            -c 'silent echomsg "colors=" . get(g:, "colors_name", "NONE")' \
            -c 'silent echomsg "localdir=" . haslocaldir()' \
            -c 'silent echomsg "guicursor=" . &guicursor' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor special path invocation failed for [$path_name]"
    fi
    assert_no_editor_error "$output_base"
    assert_file_contains "$output_base" 'colors=jellybeans'
    assert_file_contains "$output_base" 'localdir=0'
    grep -Fq "$config" "$output_base" \
        || fail "$editor special path output omitted the loaded config path [$config]"
    if [[ "$editor" == nvim ]]; then
        assert_file_contains "$output_base" \
            'guicursor=n:blinkon0,i:block,c:Cursor/lCursor'
    fi
    [[ "$config" == *"$path_name"* ]] \
        || fail "$editor special path fixture did not contain [$path_name]"
    printf 'PASS: %s special path [%s] colors=jellybeans localdir=0\n' \
        "$editor" "$path_name"
}

run_editor_matrix() {
    local editor="$1" filetype file_path output_base expected_match trim_state
    for filetype in make python c cpp rust markdown text java javascript php sh lua; do
        file_path="$TEST_ROOT/matrix-$editor-$filetype"
        output_base="$TEST_ROOT/matrix-output-$editor-$filetype"
        printf 'first line  \nsecond line  \n' >"$file_path"
        run_editor_matrix_case "$editor" "$filetype" "$file_path" "$output_base"
        expected_match=0
        case "$filetype" in
            make|python|c|cpp|rust) expected_match=1 ;;
        esac
        if [[ "$expected_match" -eq 1 ]]; then
            grep -Eq 'first line[[:space:]]*$' "$file_path" \
                || fail "$editor $filetype did not trim trailing whitespace"
        else
            grep -Eq 'first line[[:space:]]{2}$' "$file_path" \
                || fail "$editor $filetype unexpectedly trimmed whitespace"
        fi
        grep -Fq "match=$expected_match" "$output_base" \
            || fail "$editor $filetype expected match=$expected_match"
        if [[ "$expected_match" -eq 1 ]]; then
            trim_state=trimmed
        else
            trim_state=kept
        fi
        printf 'PASS: %s %s trim=%s match=%s\n' \
            "$editor" "$filetype" "$trim_state" "$expected_match"
    done
}

run_cscope_case() {
    local editor="$1"
    local cscope_root="$TEST_ROOT/cscope-$editor"
    local output_base="$TEST_ROOT/cscope-output-$editor"
    local home="$TEST_ROOT/cscope-home-$editor"
    local config file_path database
    mkdir -p "$cscope_root" "$home"
    file_path="$cscope_root/main.c"
    database="$cscope_root/cscope.out"
    printf 'int main(void) { return 0; }\n' >"$file_path"
    if ! command -v cscope >/dev/null 2>&1; then
        skip "$editor cscope scenarios: cscope command is unavailable"
        return 0
    fi
    (cd "$cscope_root" && cscope -b -q -f cscope.out main.c) \
        || fail "could not create a valid cscope database"
    if [[ "$editor" == vim ]]; then
        config="$EDITOR_ROOT/vim/.vimrc"
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" "$file_path" \
            -c "cd $cscope_root" -c 'doautocmd BufEnter' -c 'sleep 10m' \
            -c "redir! > $output_base" \
            -c 'silent echomsg "has_cscope=" . has("cscope")' \
            -c 'silent echomsg "connection=" . cscope_connection(2, expand("%:p:h") . "/cscope.out")' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor valid cscope invocation failed"
    else
        config="$EDITOR_ROOT/neovim/init.vim"
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" "$file_path" \
            -c "cd $cscope_root" -c 'doautocmd BufEnter' -c 'sleep 10m' \
            -c "redir! > $output_base" \
            -c 'silent echomsg "has_cscope=" . has("cscope")' \
            -c 'silent echomsg "connection=" . cscope_connection(2, expand("%:p:h") . "/cscope.out")' \
            -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" \
            || fail "$editor valid cscope invocation failed"
    fi
    if grep -Eq 'has_cscope=0' "$output_base"; then
        skip "$editor cscope scenarios: editor was built without +cscope"
        return 0
    fi
    assert_no_editor_error "$output_base"
    assert_file_contains "$output_base" 'connection=1'

    printf 'not a cscope database\n' >"$database"
    if [[ "$editor" == vim ]]; then
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" "$file_path" \
            -c "redir! > $output_base" -c "cd $cscope_root" -c 'doautocmd BufEnter' \
            -c 'silent messages' -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" || true
    else
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" "$file_path" \
            -c "redir! > $output_base" -c "cd $cscope_root" -c 'doautocmd BufEnter' \
            -c 'silent messages' -c 'redir END' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" || true
    fi
    if ! grep -Eq 'Error detected|E[0-9]{3}:' \
        "$output_base" "$output_base.stdout" "$output_base.stderr"; then
        fail "$editor corrupt cscope database error was hidden"
    fi
    rm -f "$database"
    mkdir -p "$cscope_root/empty"
    if [[ "$editor" == vim ]]; then
        HOME="$home" "$VIM_BIN" -N -n -i NONE -es -u "$config" \
            -c "cd $cscope_root/empty" -c 'doautocmd BufEnter' -c 'sleep 10m' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" || true
    else
        HOME="$home" XDG_CONFIG_HOME="$home/config" XDG_DATA_HOME="$home/data" \
            XDG_STATE_HOME="$home/state" "$NVIM_BIN" --headless -u "$config" \
            -c "cd $cscope_root/empty" -c 'doautocmd BufEnter' -c 'sleep 10m' -c 'qa!' \
            >"$output_base.stdout" 2>"$output_base.stderr" || true
    fi
    if grep -Eq 'Error detected|E[0-9]{3}:' "$output_base.stdout" "$output_base.stderr"; then
        fail "$editor missing cscope database was not silent"
    fi
    printf 'PASS: %s cscope normal, duplicate, corrupt-error, and missing-db cases\n' "$editor"
}

run_editor_smoke() {
    local editor="$1"
    local file_path="$TEST_ROOT/options-$editor.txt"
    printf 'option test\n' >"$file_path"
    run_editor_options "$editor" "$file_path" "$TEST_ROOT/options-output-$editor"
    run_editor_transition "$editor"
    run_editor_cursor_restore "$editor"
    run_editor_matrix "$editor"
    run_cscope_case "$editor"
    printf 'PASS: %s editor smoke scenarios\n' "$editor"
}

run_path_cases() {
    local special_path editor_name path_number=0
    while IFS= read -r special_path; do
        path_number=$((path_number + 1))
        for editor_name in vim nvim; do
            editor_available "$editor_name" || continue
            run_editor_path_load "$editor_name" "$special_path" "$path_number"
        done
    done <<'PATHS'
space dir
com,ma
qu'ote
back\slash
per%cent
ha#sh
PATHS
}

run_runtimepath_mutations() {
    local editor_name mutation_root mutation_log original_hash restored_hash
    for editor_name in vim nvim; do
        editor_available "$editor_name" || continue
        mutation_root="$TEST_ROOT/mutated-runtime-$editor_name"
        mutation_log="$TEST_ROOT/mutated-runtime-$editor_name.log"
        original_hash=$(sha256sum \
            "$EDITOR_ROOT/common/core.vim" "$EDITOR_ROOT/vim/.vimrc" \
            "$EDITOR_ROOT/neovim/init.vim" "$EDITOR_ROOT/neovim/lua/core.lua" \
            | sha256sum | awk '{print $1}')
        cp -a "$EDITOR_ROOT" "$mutation_root"
        if [[ "$editor_name" == vim ]]; then
            sed -i '/^let &runtimepath = escape(s:common_dir/ s/^/" mutation: /' \
                "$mutation_root/vim/.vimrc"
            if VIM_BIN="$VIM_BIN" NVIM_BIN="$TEST_ROOT/no-nvim" \
                EDITOR_ROOT="$mutation_root" "$0" --path-only >"$mutation_log" 2>&1; then
                fail "$editor_name runtimepath restoration mutation unexpectedly passed"
            fi
        else
            sed -i '/let &runtimepath = g:portable_devenv_nvim_common_runtime/d' \
                "$mutation_root/neovim/init.vim"
            if VIM_BIN="$TEST_ROOT/no-vim" NVIM_BIN="$NVIM_BIN" \
                EDITOR_ROOT="$mutation_root" "$0" --path-only >"$mutation_log" 2>&1; then
                fail "$editor_name runtimepath restoration mutation unexpectedly passed"
            fi
        fi
        grep -Eq 'special path invocation failed|editor reported an error|colorscheme' \
            "$mutation_log" \
            || fail "$editor_name runtimepath mutation did not expose a load failure"
        restored_hash=$(sha256sum \
            "$EDITOR_ROOT/common/core.vim" "$EDITOR_ROOT/vim/.vimrc" \
            "$EDITOR_ROOT/neovim/init.vim" "$EDITOR_ROOT/neovim/lua/core.lua" \
            | sha256sum | awk '{print $1}')
        [[ "$original_hash" == "$restored_hash" ]] \
            || fail "$editor_name runtimepath mutation changed product files"
        printf 'PASS: mutation rejected %s runtimepath restoration; product hash restored\n' \
            "$editor_name"
    done
}

run_cursor_mutation() {
    local mutation_script="$TEST_ROOT/mutated-cursor-test.sh"
    local mutation_log="$TEST_ROOT/mutated-cursor-test.log"
    local original_hash restored_hash
    original_hash=$(sha256sum "$0" | awk '{print $1}')
    cp "$0" "$mutation_script"
    sed -i '0,/-i "[^"]*info_path"/s//-i NONE/' "$mutation_script"
    if VIM_BIN="$VIM_BIN" NVIM_BIN="$NVIM_BIN" "$mutation_script" --cursor-only \
        >"$mutation_log" 2>&1; then
        fail "cursor restoration mutation unexpectedly passed"
    fi
    grep -Eq 'cursor|cursor restore' "$mutation_log" \
        || fail "cursor restoration mutation did not identify the regression"
    restored_hash=$(sha256sum "$0" | awk '{print $1}')
    [[ "$original_hash" == "$restored_hash" ]] \
        || fail "cursor mutation changed the product test"
    printf 'PASS: mutation rejected cursor restoration removal; test hash restored\n'
}

run_cursor_core_mutation() {
    local label="$1" mutation_root="$TEST_ROOT/mutated-cursor-$1"
    local mutation_log="$TEST_ROOT/mutated-cursor-$1.log"
    local original_hash restored_hash
    original_hash=$(sha256sum \
        "$EDITOR_ROOT/common/core.vim" "$EDITOR_ROOT/vim/.vimrc" \
        "$EDITOR_ROOT/neovim/init.vim" "$EDITOR_ROOT/neovim/lua/core.lua" \
        | sha256sum | awk '{print $1}')
    cp -a "$EDITOR_ROOT" "$mutation_root"
    if [[ "$label" == m6 ]]; then
        sed -i '/autocmd BufReadPost \* call s:restore_cursor()/d' \
            "$mutation_root/common/core.vim"
    else
        sed -i 's/normal! g`"/normal! 7G3l/' \
            "$mutation_root/common/core.vim"
    fi
    if EDITOR_ROOT="$mutation_root" "$0" --cursor-only >"$mutation_log" 2>&1; then
        fail "$label cursor mutation unexpectedly passed"
    fi
    grep -Eq 'cursor=2:4|cursor restore' "$mutation_log" \
        || fail "$label cursor mutation did not identify the regression"
    restored_hash=$(sha256sum \
        "$EDITOR_ROOT/common/core.vim" "$EDITOR_ROOT/vim/.vimrc" \
        "$EDITOR_ROOT/neovim/init.vim" "$EDITOR_ROOT/neovim/lua/core.lua" \
        | sha256sum | awk '{print $1}')
    [[ "$original_hash" == "$restored_hash" ]] \
        || fail "$label cursor mutation changed product files"
    printf 'PASS: mutation rejected %s cursor restoration; product hash restored\n' "$label"
}

run_no_editor_mutation() {
    local mutation_log="$TEST_ROOT/no-editor.log"
    if VIM_BIN="$TEST_ROOT/no-vim" NVIM_BIN="$TEST_ROOT/no-nvim" "$0" --matrix-only \
        >"$mutation_log" 2>&1; then
        fail "zero-editor mutation unexpectedly passed"
    fi
    grep -Fq 'NO EDITOR TESTS EXECUTED' "$mutation_log" \
        || fail "zero-editor mutation did not report that no tests ran"
    if grep -Fq 'editor smoke tests passed' "$mutation_log"; then
        fail "zero-editor mutation printed a passing summary"
    fi
    printf 'PASS: mutation rejects zero-editor execution\n'
}

available_editor_count=0
for editor_name in vim nvim; do
    if editor_available "$editor_name"; then
        available_editor_count=$((available_editor_count + 1))
    else
        skip "$editor_name is unavailable (set ${editor_name^^}_BIN to an installed binary)"
    fi
done

if [[ "$RUN_MATRIX_ONLY" -eq 1 ]]; then
    if [[ "$available_editor_count" -eq 0 ]]; then
        printf 'NO EDITOR TESTS EXECUTED; vim and nvim are unavailable\n' >&2
        exit 77
    fi
    for editor_name in vim nvim; do
        editor_available "$editor_name" || continue
        run_editor_matrix "$editor_name"
    done
    exit 0
fi

if [[ "$RUN_PATH_ONLY" -eq 1 ]]; then
    if [[ "$available_editor_count" -eq 0 ]]; then
        printf 'NO EDITOR TESTS EXECUTED; vim and nvim are unavailable\n' >&2
        exit 77
    fi
    run_path_cases
    exit 0
fi

if [[ "$RUN_CURSOR_ONLY" -eq 1 ]]; then
    if [[ "$available_editor_count" -eq 0 ]]; then
        printf 'NO EDITOR TESTS EXECUTED; vim and nvim are unavailable\n' >&2
        exit 77
    fi
    for editor_name in vim nvim; do
        editor_available "$editor_name" || continue
        run_editor_cursor_restore "$editor_name"
    done
    exit 0
fi

if [[ "$available_editor_count" -eq 0 ]]; then
    printf 'NO EDITOR TESTS EXECUTED; vim and nvim are unavailable\n' >&2
    exit 77
fi

if [[ "$available_editor_count" -gt 0 ]]; then
    mutation_root="$TEST_ROOT/mutated-editor"
    mutation_log="$TEST_ROOT/mutation.log"
    original_core_hash=$(sha256sum "$EDITOR_ROOT/common/core.vim" | awk '{print $1}')
    cp -a "$EDITOR_ROOT" "$mutation_root"
    sed -i 's/return index(s:whitespace_filetypes, a:filetype) >= 0/return 1/' \
        "$mutation_root/common/core.vim"
    if EDITOR_ROOT="$mutation_root" "$0" --matrix-only >"$mutation_log" 2>&1; then
        fail "the broad-whitespace mutation unexpectedly passed"
    fi
    grep -Eq 'expected match=0|unexpectedly trimmed whitespace' "$mutation_log" \
        || fail "mutation failure did not identify the D-12 regression"
    restored_core_hash=$(sha256sum "$EDITOR_ROOT/common/core.vim" | awk '{print $1}')
    [[ "$original_core_hash" == "$restored_core_hash" ]] \
        || fail "product core hash changed during mutation test"
    printf 'PASS: mutation rejected broad whitespace matching; product hash restored\n'
    run_runtimepath_mutations
    run_cursor_mutation
    run_cursor_core_mutation m6
    run_cursor_core_mutation column-only
    run_no_editor_mutation
fi

for editor_name in vim nvim; do
    editor_available "$editor_name" || continue
    run_editor_smoke "$editor_name"
done

run_path_cases

printf 'editor smoke tests passed; executed editors=%s; unavailable editors were reported as SKIP\n' \
    "$available_editor_count"
