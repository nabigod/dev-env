#!/usr/bin/env bash
set -euo pipefail

TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/rust-tags-smoke.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
VIM_BIN=${VIM_BIN:-vim}
NVIM_BIN=${NVIM_BIN:-nvim}
LOG_DIR=${LOG_DIR:-}

if [[ -z "$LOG_DIR" ]]; then
    LOG_DIR="$TEST_ROOT/logs"
fi
mkdir -p "$LOG_DIR" "$TEST_ROOT/bin" "$TEST_ROOT/home"

for executable in "$VIM_BIN" "$NVIM_BIN"; do
    command -v "$executable" >/dev/null 2>&1 || {
        printf 'required editor is unavailable: %s\n' "$executable" >&2
        exit 77
    }
done

VIM_PATH=$(command -v "$VIM_BIN")
NVIM_PATH=$(command -v "$NVIM_BIN")
ln -s "$VIM_PATH" "$TEST_ROOT/bin/vim"
ln -s "$NVIM_PATH" "$TEST_ROOT/bin/nvim"

for name in cargo rustc rust-analyzer rusty-tags ctags; do
    if PATH="$TEST_ROOT/bin" command -v "$name" >/dev/null 2>&1; then
        printf 'unexpected Rust/tag tool in isolated PATH: %s\n' "$name" >&2
        exit 1
    fi
done
printf 'PASS: isolated PATH excludes cargo, rustc, rust-analyzer, rusty-tags, and ctags\n'

SPACE_ROOT="$TEST_ROOT/work space"
OUTER="$SPACE_ROOT/project"
NESTED="$OUTER/nested"
OTHER="$SPACE_ROOT/other-project"
EXTERNAL="$TEST_ROOT/external cwd"
mkdir -p "$NESTED/src/nested" "$OUTER/src" "$OTHER/src" "$EXTERNAL"

printf 'fn main() {\n    rust_target();\n}\n' >"$NESTED/src/nested/main.rs"
printf 'pub fn one() {}\npub fn two() {}\npub fn rust_target() {}\n' >"$NESTED/src/lib.rs"
printf 'fn old() {}\npub fn legacy_target() {}\n' >"$OUTER/src/legacy.rs"
printf 'fn old() {}\nfn older() {}\npub fn ctags_target() {}\n' >"$OUTER/src/ctags.rs"
printf 'fn main() {\n    rust_target();\n}\n' >"$OTHER/src/main.rs"
printf 'pub fn one() {}\npub fn two() {}\npub fn three() {}\npub fn rust_target() {}\n' >"$OTHER/src/lib.rs"
printf 'rust_target\tsrc/lib.rs\t3\n' >"$NESTED/rusty-tags.vi"
printf 'legacy_target\tsrc/legacy.rs\t2\n' >"$OUTER/tags"
printf 'ctags_target\tsrc/ctags.rs\t3\n' >"$OUTER/ctags"
printf 'rust_target\tsrc/lib.rs\t4\n' >"$OTHER/rusty-tags.vi"

cat >"$TEST_ROOT/tag-check.vim" <<'VIM'
set nomore
function! s:assert_location(expected_file, expected_line, description) abort
  if expand('%:p') !=# a:expected_file || line('.') != a:expected_line
    throw a:description . ': got ' . expand('%:p') . ':' . line('.') . ', expected ' . a:expected_file . ':' . a:expected_line
  endif
endfunction
function! s:check_tag(tag_name, expected_file, expected_line, source_file) abort
  execute 'edit ' . fnameescape(a:source_file)
  call cursor(2, 1)
  let l:source = expand('%:p')
  execute 'tag ' . a:tag_name
  call s:assert_location(a:expected_file, a:expected_line, a:tag_name . ' definition')
  execute "normal! \<C-t>"
  call s:assert_location(l:source, 2, a:tag_name . ' Ctrl-t return')
  call writefile([a:tag_name . '=' . expand('%:p') . ':' . line('.') . ' -> ' . a:expected_file . ':' . a:expected_line . ' -> Ctrl-t=' . l:source . ':2'], $TAG_LOG, 'a')
endfunction
try
  call s:check_tag('rust_target', $TAG_RUST_EXPECT, 3, $TAG_RUST_SOURCE)
  call s:check_tag('legacy_target', $TAG_LEGACY_EXPECT, 2, $TAG_RUST_SOURCE)
  call s:check_tag('ctags_target', $TAG_CTAGS_EXPECT, 3, $TAG_RUST_SOURCE)
  call s:check_tag('rust_target', $TAG_OTHER_EXPECT, 4, $TAG_OTHER_SOURCE)
  execute 'edit ' . fnameescape($TAG_MISSING_SOURCE)
  call setline(1, 'fn edited_without_tags() {}')
  write
  if readfile($TAG_MISSING_SOURCE)[0] !=# 'fn edited_without_tags() {}'
    throw 'tagless Rust buffer did not save edits'
  endif
  call writefile(['tagless rust buffer opened, edited, and saved'], $TAG_LOG, 'a')
  qa!
catch
  call writefile(['FAIL: ' . v:exception, v:throwpoint], $TAG_LOG, 'a')
  cquit
endtry
VIM

printf 'fn main() {\n    let edited = true;\n}\n' >"$OTHER/src/no_tags.rs"

run_editor() {
    local editor=$1 config=$2 log="$LOG_DIR/$1-rust-tags.txt" stderr="$LOG_DIR/$1-rust-tags.stderr"
    : >"$log"
    if [[ "$editor" == vim ]]; then
        (
            cd "$EXTERNAL"
            HOME="$TEST_ROOT/home" PATH="$TEST_ROOT/bin" \
                TAG_RUST_EXPECT="$NESTED/src/lib.rs" TAG_RUST_SOURCE="$NESTED/src/nested/main.rs" \
                TAG_LEGACY_EXPECT="$OUTER/src/legacy.rs" TAG_CTAGS_EXPECT="$OUTER/src/ctags.rs" \
                TAG_OTHER_EXPECT="$OTHER/src/lib.rs" TAG_OTHER_SOURCE="$OTHER/src/main.rs" \
                TAG_MISSING_SOURCE="$OTHER/src/no_tags.rs" TAG_LOG="$log" \
                "$VIM_PATH" -N -n -i NONE -es -u "$config" -S "$TEST_ROOT/tag-check.vim" \
                >"$log.stdout" 2>"$stderr"
        )
    else
        (
            cd "$EXTERNAL"
            HOME="$TEST_ROOT/home" XDG_CONFIG_HOME="$TEST_ROOT/home/config" \
                XDG_DATA_HOME="$TEST_ROOT/home/data" XDG_STATE_HOME="$TEST_ROOT/home/state" \
                PATH="$TEST_ROOT/bin" TAG_RUST_EXPECT="$NESTED/src/lib.rs" \
                TAG_RUST_SOURCE="$NESTED/src/nested/main.rs" TAG_LEGACY_EXPECT="$OUTER/src/legacy.rs" \
                TAG_CTAGS_EXPECT="$OUTER/src/ctags.rs" TAG_OTHER_EXPECT="$OTHER/src/lib.rs" \
                TAG_OTHER_SOURCE="$OTHER/src/main.rs" TAG_MISSING_SOURCE="$OTHER/src/no_tags.rs" \
                TAG_LOG="$log" "$NVIM_PATH" --headless -u "$config" -S "$TEST_ROOT/tag-check.vim" \
                >"$log.stdout" 2>"$stderr"
        )
    fi
    if rg -q '^FAIL:' "$log"; then
        cat "$log" >&2
        return 1
    fi
    [[ $(wc -l <"$log") -eq 5 ]] || {
        cat "$log" >&2
        printf '%s produced incomplete tag results\n' "$editor" >&2
        return 1
    }
    cat "$log"
    printf 'PASS: %s actual tags navigation, source-relative paths, Ctrl-t, buffer switch, and tagless edit\n' "$editor"
}

run_editor vim "$REPO_ROOT/tools/editor/vim/.vimrc"
run_editor nvim "$REPO_ROOT/tools/editor/neovim/init.vim"
