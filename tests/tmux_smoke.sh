#!/bin/bash

set -o pipefail

SCRIPT_DIR=$(cd -P "$(dirname "$0")" >/dev/null 2>&1 && pwd) || exit 1
REPO_DIR=$(cd "$SCRIPT_DIR/.." >/dev/null 2>&1 && pwd) || exit 1
TMUX_BIN=$(command -v tmux)
if [ -z "$TMUX_BIN" ]; then
    printf '%s\n' 'tmux_smoke.sh: tmux is required but was not found in PATH' >&2
    exit 1
fi
TEST_HOME=$(mktemp -d) || exit 1
TEST_CONFIG=$(mktemp) || exit 1
LOG_FILE=$(mktemp) || exit 1
FAILURES=0
SOCKETS=""

cleanup() {
    local socket
    for socket in $SOCKETS; do
        HOME="$TEST_HOME" "$TMUX_BIN" -L "$socket" kill-server >/dev/null 2>&1 || true
        rm -f "${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)/$socket"
    done
    rm -f "$TEST_CONFIG" "$LOG_FILE"
    rm -rf "$TEST_HOME"
}
trap cleanup EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    FAILURES=$((FAILURES + 1))
}

assert_equal() {
    local expected="$1"
    local actual="$2"
    local description="$3"
    if [[ "$expected" != "$actual" ]]; then
        fail "$description (expected '$expected', got '$actual')"
    fi
}

assert_file_absent() {
    local path="$1"
    [[ ! -e "$path" && ! -L "$path" ]] || fail "Expected absent path: $path"
}

load_tmux_config() {
    local socket="$1"
    local path_value="$2"
    local terminfo_root="${3:-}"
    local terminfo_dirs="${4:-}"
    SOCKETS="$SOCKETS $socket"
    TERMINFO="$terminfo_root" TERMINFO_DIRS="$terminfo_dirs" \
        PATH="$path_value" HOME="$TEST_HOME" "$TMUX_BIN" -L "$socket" \
        -f "$TEST_HOME/.tmux.conf" \
        start-server \; set-option -g exit-empty off \; \
        source-file "$TEST_HOME/.tmux.conf"
}

show_option() {
    local socket="$1"
    local option="$2"
    HOME="$TEST_HOME" "$TMUX_BIN" -L "$socket" show-option -gqv "$option"
}

show_window_option() {
    local socket="$1"
    local option="$2"
    HOME="$TEST_HOME" "$TMUX_BIN" -L "$socket" show-window-option -gv "$option"
}

assert_contains() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null ||
        fail "$description"
}

assert_absent() {
    local haystack="$1"
    local needle="$2"
    local description="$3"
    if printf '%s\n' "$haystack" | grep -F "$needle" >/dev/null; then
        fail "$description"
    fi
}

terminfo_file_exists_in() {
    local root="$1"
    local name="$2"
    local layout
    for layout in t 74 .; do
        if [[ -r "$root/$layout/$name" ]]; then
            return 0
        fi
    done
    return 1
}

printf '[general]\nbackup_dir = %s/.dev-env-backup\n\n[tmux]\nenable = true\ninstall = false\n' \
    "$TEST_HOME" > "$TEST_CONFIG" || exit 1
printf 'original tmux configuration\n' > "$TEST_HOME/.tmux.conf" || exit 1

HOME="$TEST_HOME" bash "$REPO_DIR/setup_devenv.sh" -c "$TEST_CONFIG" > "$LOG_FILE" 2>&1
setup_status=$?
assert_equal "0" "$setup_status" "tmux module setup"
[[ -L "$TEST_HOME/.tmux.conf" ]] || fail "tmux.conf was not deployed as a link"
assert_equal \
    "$REPO_DIR/tools/multiplexer/tmux/tmux.conf" \
    "$(readlink "$TEST_HOME/.tmux.conf")" \
    "tmux.conf link target"

for support_file in \
    tmux-version.sh \
    tmux-terminfo.sh \
    tmux-style-legacy.conf \
    tmux-style-modern.conf \
    tmux-path-legacy.conf \
    tmux-path-modern.conf \
    tmux-mouse-legacy.conf \
    tmux-mouse-modern.conf; do
    [[ -L "$TEST_HOME/.tmux/portable-devenv/$support_file" ]] ||
        fail "Missing support link: $support_file"
done

for version_case in \
    "tmux 3.2a|3.2.0" \
    "tmux next-3.4|3.4.0" \
    "tmux master|999.999.999" \
    "tmux openbsd-7.4|999.999.999" \
    "unrecognised|0.0.0"; do
    version_input=${version_case%%|*}
    version_expected=${version_case#*|}
    version_actual=$("$REPO_DIR/tools/multiplexer/tmux/tmux-version.sh" \
        --normalize "$version_input")
    assert_equal "$version_expected" "$version_actual" \
        "version normalization: $version_input"
done

for version_case in \
    "tmux 1.8|2.9|1" \
    "tmux 2.8|2.9|1" \
    "tmux 2.9|2.9|0" \
    "tmux next-3.4|2.9|0" \
    "tmux master|2.9|0" \
    "tmux openbsd-7.4|2.9|0"; do
    version_input=${version_case%%|*}
    remainder=${version_case#*|}
    required_version=${remainder%%|*}
    expected_status=${remainder#*|}
    "$REPO_DIR/tools/multiplexer/tmux/tmux-version.sh" \
        --at-least "$required_version" "$version_input"
    actual_status=$?
    assert_equal "$expected_status" "$actual_status" \
        "version comparison: $version_input >= $required_version"
done

local_path="$PATH"
socket="t03-local-$RANDOM"
load_tmux_config "$socket" "$local_path" > "$LOG_FILE" 2>&1
load_status=$?
assert_equal "0" "$load_status" "local tmux configuration load"
[[ ! -s "$LOG_FILE" ]] || fail "local tmux configuration emitted errors"
assert_equal "C-a" "$(show_option "$socket" prefix)" "prefix"
assert_equal "top" "$(show_option "$socket" status-position)" "status position"
assert_equal "#[fg=green,bold]#S : " "$(show_option "$socket" status-left)" \
    "status left"
assert_equal " " "$(show_option "$socket" status-right)" "status right"
assert_equal "10000" "$(show_option "$socket" history-limit)" "history limit"
assert_equal "0" "$(show_option "$socket" escape-time)" "escape time"
assert_equal "off" "$(show_option "$socket" mouse)" "mouse"
assert_equal "fg=white,bg=black" "$(show_option "$socket" status-style)" "status style"
assert_equal "fg=white,bg=red" \
    "$(show_option "$socket" window-status-current-style)" \
    "current window style"
assert_equal "#W" "$(show_window_option "$socket" window-status-current-format)" \
    "current window format"
assert_equal "#W" "$(show_window_option "$socket" window-status-format)" \
    "window format"
terminfo_expected="screen-256color"
if terminfo_file_exists_in "$TEST_HOME/.terminfo" tmux-256color; then
    terminfo_expected="tmux-256color"
else
    for compiled_root in /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo; do
        if terminfo_file_exists_in "$compiled_root" tmux-256color; then
            terminfo_expected="tmux-256color"
            break
        fi
    done
fi
assert_equal "$terminfo_expected" \
    "$(show_option "$socket" default-terminal)" \
    "default terminal"
prefix_keys=$(HOME="$TEST_HOME" "$TMUX_BIN" -L "$socket" list-keys -T prefix)
assert_contains "$prefix_keys" \
    'bind-key -r -T prefix [       previous-window' \
    "repeatable previous-window binding"
assert_contains "$prefix_keys" \
    'bind-key -r -T prefix ]       next-window' \
    "repeatable next-window binding"
assert_contains "$prefix_keys" \
    'bind-key    -T prefix r       command-prompt -I "#W" "rename-window' \
    "rename-window binding"
assert_contains "$prefix_keys" \
    'bind-key    -T prefix R       command-prompt -I "#S" "rename-session' \
    "rename-session binding"
assert_contains "$prefix_keys" 'bind-key    -T prefix C-a     send-prefix' \
    "send-prefix binding"
for direction in Left Right Up Down; do
    assert_contains "$prefix_keys" "bind-key    -T prefix $direction" \
        "$direction pane binding"
done
for direction_case in "Left|-L" "Right|-R" "Up|-U" "Down|-D"; do
    direction=${direction_case%%|*}
    direction_flag=${direction_case#*|}
    direction_line=$(printf '%s\n' "$prefix_keys" |
        awk -v key="$direction" '$1 == "bind-key" && $4 == key')
    assert_contains "$direction_line" "select-pane $direction_flag" \
        "$direction pane direction"
done
assert_contains "$prefix_keys" \
    'bind-key    -T prefix c       new-window -c "#{pane_current_path}"' \
    "current-path new-window binding"
assert_contains "$prefix_keys" \
    'bind-key    -T prefix |       split-window -h -c "#{pane_current_path}"' \
    "current-path horizontal split binding"
assert_contains "$prefix_keys" \
    'bind-key    -T prefix _       split-window -v -c "#{pane_current_path}"' \
    "current-path vertical split binding"
for key in C-b ',' '"' l; do
    if printf '%s\n' "$prefix_keys" | awk -v key="$key" \
        '$4 == key {found=1} END {exit found ? 0 : 1}'; then
        fail "default prefix binding remains: $key"
    fi
done
for unbind_line in \
    'unbind C-b' \
    'unbind ,' \
    'unbind l' \
    'unbind Left' \
    'unbind Right' \
    'unbind Up' \
    'unbind Down'; do
    grep -Fx "$unbind_line" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux.conf" >/dev/null ||
        fail "default binding unbind missing: $unbind_line"
done
grep -Fx "unbind '\"'" "$REPO_DIR/tools/multiplexer/tmux/tmux.conf" >/dev/null ||
    fail 'default binding unbind missing: quote'

terminfo_root="$TEST_HOME/terminfo"
mkdir -p "$terminfo_root/t" || exit 1
: > "$terminfo_root/t/tmux-256color" || exit 1
socket="t03-custom-terminfo-$RANDOM"
load_tmux_config "$socket" "$local_path" "$terminfo_root" > "$LOG_FILE" 2>&1
load_status=$?
assert_equal "0" "$load_status" "tmux configuration load with tmux-256color"
[[ ! -s "$LOG_FILE" ]] || fail "custom terminfo configuration emitted errors"
assert_equal "tmux-256color" "$(show_option "$socket" default-terminal)" \
    "custom tmux-256color selection"
rm -f "$terminfo_root/t/tmux-256color" || exit 1
socket="t03-no-terminfo-$RANDOM"
load_tmux_config "$socket" "$local_path" "$terminfo_root" > "$LOG_FILE" 2>&1
load_status=$?
assert_equal "0" "$load_status" "tmux configuration load without tmux-256color"
[[ ! -s "$LOG_FILE" ]] || fail "fallback tmux configuration emitted errors"
fallback_expected="screen-256color"
for compiled_root in /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo; do
    if terminfo_file_exists_in "$compiled_root" tmux-256color; then
        fallback_expected="tmux-256color"
        break
    fi
done
assert_equal "$fallback_expected" "$(show_option "$socket" default-terminal)" \
    "screen fallback terminal"

printf '%s\n' '--- terminfo search-order cases'
terminfo_case() {
    local name="$1"
    local expected="$2"
    local terminfo_root="$3"
    local terminfo_dirs="$4"
    local socket_name="t03-terminfo-$RANDOM"
    load_tmux_config "$socket_name" "$local_path" "$terminfo_root" "$terminfo_dirs" \
        > "$LOG_FILE" 2>&1
    assert_equal "0" "$?" "$name load"
    assert_equal "$expected" "$(show_option "$socket_name" default-terminal)" "$name"
}

terminfo_name="t03-fake-256color-$$-$RANDOM"
terminfo_no_home="$TEST_HOME/no-home"
terminfo_no_such="$TEST_HOME/no-such"

# Every layout case uses a fresh root holding exactly one layout file, so removing one layout
# from the helper cannot be masked by another layout.
make_layout_root() {
    local layout="$1"
    LAYOUT_ROOT=$(mktemp -d "$TEST_HOME/layout-root-XXXXXX") || exit 1
    if [[ "$layout" == "flat" ]]; then
        : > "$LAYOUT_ROOT/$terminfo_name" || exit 1
    else
        mkdir -p "$LAYOUT_ROOT/$layout" || exit 1
        : > "$LAYOUT_ROOT/$layout/$terminfo_name" || exit 1
    fi
}

terminfo_helper_case() {
    local name="$1"
    local expected="$2"
    local terminfo_value="$3"
    local home_value="$4"
    local dirs_value="$5"
    local actual
    TERMINFO="$terminfo_value" HOME="$home_value" TERMINFO_DIRS="$dirs_value" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux-terminfo.sh" "$terminfo_name"
    actual=$?
    assert_equal "$expected" "$actual" "$name"
}

for layout_case in "t|t/" "74|74/" "flat|flat"; do
    layout=${layout_case%%|*}
    layout_label=${layout_case#*|}
    make_layout_root "$layout"
    terminfo_helper_case "single-layout TERMINFO $layout_label hit" 0 \
        "$LAYOUT_ROOT" "$terminfo_no_home" ""
done
make_layout_root "zz"
terminfo_helper_case "unrecognised layout directory miss" 1 \
    "$LAYOUT_ROOT" "$terminfo_no_home" ""

make_layout_root "t"
terminfo_layout_hit_root="$LAYOUT_ROOT"
terminfo_empty_root=$(mktemp -d "$TEST_HOME/layout-root-XXXXXX") || exit 1
terminfo_home_root=$(mktemp -d "$TEST_HOME/home-root-XXXXXX") || exit 1
mkdir -p "$terminfo_home_root/.terminfo/t" || exit 1
: > "$terminfo_home_root/.terminfo/t/$terminfo_name" || exit 1
terminfo_helper_case "TERMINFO miss then HOME hit" 0 "$terminfo_empty_root" \
    "$terminfo_home_root" ""
terminfo_helper_case "TERMINFO_DIRS single entry hit" 0 "" \
    "$terminfo_no_home" "$terminfo_layout_hit_root"
terminfo_helper_case "TERMINFO_DIRS second entry hit" 0 "" \
    "$terminfo_no_home" "$terminfo_no_such:$terminfo_layout_hit_root"
terminfo_helper_case "TERMINFO_DIRS empty entry then miss" 1 "" \
    "$terminfo_no_home" ":$terminfo_no_such"
terminfo_helper_case "all locations miss" 1 "$terminfo_no_such" \
    "$terminfo_no_home" "$terminfo_no_such"

# The helper exit status alone must pick default-terminal, independent of the host terminfo database.
terminfo_helper_link="$TEST_HOME/.tmux/portable-devenv/tmux-terminfo.sh"
terminfo_stub_case() {
    local stub_exit="$1"
    local expected="$2"
    local description="$3"
    local stub_socket="t03-stub-$stub_exit-$RANDOM"
    rm -f "$terminfo_helper_link" || exit 1
    printf '#!/bin/sh\nexit %s\n' "$stub_exit" > "$terminfo_helper_link" || exit 1
    chmod 755 "$terminfo_helper_link" || exit 1
    load_tmux_config "$stub_socket" "$local_path" > "$LOG_FILE" 2>&1
    assert_equal "0" "$?" "$description load"
    [[ ! -s "$LOG_FILE" ]] || fail "$description emitted errors"
    assert_equal "$expected" "$(show_option "$stub_socket" default-terminal)" \
        "$description"
}
terminfo_stub_case 1 "screen-256color" "helper exit 1 selects screen-256color"
terminfo_stub_case 0 "tmux-256color" "helper exit 0 selects tmux-256color"
rm -f "$terminfo_helper_link" || exit 1
ln -s "$REPO_DIR/tools/multiplexer/tmux/tmux-terminfo.sh" \
    "$terminfo_helper_link" || exit 1

# Helper versus infocmp on a unique entry compiled by tic. Only the t/ layout is asserted;
# 74/ and flat layouts are informational because Linux ncurses 6.3/6.4 do not read them.
infocmp_layout_report() {
    local label="$1"
    local terminfo_value="$2"
    local home_value="$3"
    local dirs_value="$4"
    local helper_status infocmp_status verdict
    TERMINFO="$terminfo_value" HOME="$home_value" TERMINFO_DIRS="$dirs_value" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux-terminfo.sh" "$terminfo_name"
    helper_status=$?
    TERMINFO="$terminfo_value" HOME="$home_value" TERMINFO_DIRS="$dirs_value" \
        infocmp -x "$terminfo_name" >/dev/null 2>&1
    infocmp_status=$?
    verdict="MATCH"
    [[ "$helper_status" == "$infocmp_status" ]] || verdict="DIFF"
    printf 'INFO infocmp layout %-22s helper=%s infocmp=%s %s\n' \
        "$label" "$helper_status" "$infocmp_status" "$verdict"
    INFOCMP_HELPER_STATUS="$helper_status"
    INFOCMP_STATUS="$infocmp_status"
}

system_entry=""
for compiled_root in /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo; do
    if [[ -r "$compiled_root/t/tmux-256color" ]]; then
        system_entry="$compiled_root/t/tmux-256color"
        break
    fi
done
if ! command -v infocmp >/dev/null 2>&1 || ! command -v tic >/dev/null 2>&1; then
    printf '%s\n' 'SKIP: infocmp or tic is unavailable for layout comparison'
elif [[ -z "$system_entry" ]]; then
    printf '%s\n' 'SKIP: no compiled tmux-256color entry for layout comparison'
else
    tic_source="$TEST_HOME/layout-source.ti"
    tic_output="$TEST_HOME/layout-compiled"
    mkdir -p "$tic_output" || exit 1
    env -u TERMINFO -u TERMINFO_DIRS infocmp -x tmux-256color |
        sed "s/^tmux-256color|/$terminfo_name|/" > "$tic_source"
    tic -x -o "$tic_output" "$tic_source"
    tic_status=$?
    compiled_entry="$tic_output/t/$terminfo_name"
    if [[ "$tic_status" -ne 0 || ! -r "$compiled_entry" ]]; then
        printf 'SKIP: tic did not produce a t/ entry (exit %s)\n' "$tic_status"
    else
        make_layout_root "74"
        cp "$compiled_entry" "$LAYOUT_ROOT/74/$terminfo_name" || exit 1
        infocmp_74_root="$LAYOUT_ROOT"
        make_layout_root "flat"
        cp "$compiled_entry" "$LAYOUT_ROOT/$terminfo_name" || exit 1
        infocmp_flat_root="$LAYOUT_ROOT"
        make_layout_root "t"
        cp "$compiled_entry" "$LAYOUT_ROOT/t/$terminfo_name" || exit 1
        infocmp_t_root="$LAYOUT_ROOT"
        mkdir -p "$TEST_HOME/infocmp-home/.terminfo/t" || exit 1
        cp "$compiled_entry" "$TEST_HOME/infocmp-home/.terminfo/t/$terminfo_name" || exit 1

        infocmp_layout_report "TERMINFO t/" "$infocmp_t_root" "$terminfo_no_home" ""
        assert_equal "$INFOCMP_STATUS" "$INFOCMP_HELPER_STATUS" "infocmp match: TERMINFO t/"
        infocmp_layout_report "HOME t/" "" "$TEST_HOME/infocmp-home" ""
        assert_equal "$INFOCMP_STATUS" "$INFOCMP_HELPER_STATUS" "infocmp match: HOME t/"
        infocmp_layout_report "TERMINFO_DIRS t/" "" "$terminfo_no_home" "$infocmp_t_root"
        assert_equal "$INFOCMP_STATUS" "$INFOCMP_HELPER_STATUS" "infocmp match: TERMINFO_DIRS t/"
        infocmp_layout_report "TERMINFO miss" "$terminfo_no_such" "$terminfo_no_home" ""
        assert_equal "$INFOCMP_STATUS" "$INFOCMP_HELPER_STATUS" "infocmp match: all miss"
        infocmp_layout_report "TERMINFO 74/ (info)" "$infocmp_74_root" "$terminfo_no_home" ""
        infocmp_layout_report "TERMINFO flat (info)" "$infocmp_flat_root" "$terminfo_no_home" ""
    fi
fi

if ! grep -F 'set -g default-path ""' \
    "$REPO_DIR/tools/multiplexer/tmux/tmux-path-legacy.conf" >/dev/null; then
    fail "legacy path does not use empty default-path"
fi
if grep -F '#{' "$REPO_DIR/tools/multiplexer/tmux/tmux-path-legacy.conf" >/dev/null; then
    fail "legacy path contains a format expression"
fi
for required_line in \
    'set -g mode-mouse off' \
    'set -g mouse-select-pane off' \
    'set -g mouse-select-window off' \
    'set -g status-bg black' \
    'set -g status-fg white' \
    'set -g window-status-current-bg red' \
    'set -g window-status-current-fg white'; do
    if ! grep -F "$required_line" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux-mouse-legacy.conf" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux-style-legacy.conf" >/dev/null; then
        fail "legacy fragment line missing: $required_line"
    fi
done
for required_line in \
    'bind c new-window' \
    'bind | split-window -h' \
    'bind _ split-window -v'; do
    grep -Fx "$required_line" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux-path-legacy.conf" >/dev/null ||
        fail "legacy path binding missing: $required_line"
done
# Behaviour cannot tell /lib from /usr/lib on merged-usr hosts, so each path is matched as a whole source line.
compiled_path_is_listed() {
    awk -v wanted="$1" '
        {
            entry = $0
            sub(/^[ \t]+/, "", entry)
            sub(/ \\$/, "", entry)
            sub(/; do$/, "", entry)
            if (entry == wanted) { found = 1 }
        }
        END { exit found ? 0 : 1 }' "$2"
}
for required_path in /etc/terminfo /lib/terminfo /usr/share/terminfo /usr/lib/terminfo; do
    compiled_path_is_listed "$required_path" \
        "$REPO_DIR/tools/multiplexer/tmux/tmux-terminfo.sh" ||
        fail "compiled terminfo path missing: $required_path"
done
terminfo_compiled_fallbacks=$(grep -c \
    'terminfo_exists_in_compiled_paths && exit 0' \
    "$REPO_DIR/tools/multiplexer/tmux/tmux-terminfo.sh")
assert_equal "2" "$terminfo_compiled_fallbacks" \
    "TERMINFO_DIRS empty entry compiled fallback"
terminfo_default_assignment="terminfo_name=\${1:-tmux-256color}"
grep -F "$terminfo_default_assignment" \
    "$REPO_DIR/tools/multiplexer/tmux/tmux-terminfo.sh" >/dev/null ||
    fail "terminfo helper optional name argument missing"

printf '%s\n' '--- simulated version fragment selection'
DISPATCH_HOME="$TEST_HOME/.tmux/portable-devenv"
for fragment in \
    tmux-path-legacy.conf tmux-path-modern.conf \
    tmux-mouse-legacy.conf tmux-mouse-modern.conf \
    tmux-style-legacy.conf tmux-style-modern.conf; do
    rm -f "$DISPATCH_HOME/$fragment"
done
printf '%s\n' 'set -g @tmux_smoke_path legacy' > \
    "$DISPATCH_HOME/tmux-path-legacy.conf"
printf '%s\n' 'set -g @tmux_smoke_path modern' > \
    "$DISPATCH_HOME/tmux-path-modern.conf"
printf '%s\n' 'set -g @tmux_smoke_mouse legacy' > \
    "$DISPATCH_HOME/tmux-mouse-legacy.conf"
printf '%s\n' 'set -g @tmux_smoke_mouse modern' > \
    "$DISPATCH_HOME/tmux-mouse-modern.conf"
printf '%s\n' 'set -g @tmux_smoke_style legacy' > \
    "$DISPATCH_HOME/tmux-style-legacy.conf"
printf '%s\n' 'set -g @tmux_smoke_style modern' > \
    "$DISPATCH_HOME/tmux-style-modern.conf"
shim_dir="$TEST_HOME/tmux-shim"
mkdir -p "$shim_dir"
cat > "$shim_dir/tmux" <<EOF
#!/bin/sh
if [ "\$1" = "-V" ]; then
    printf 'tmux %s\n' "\$FAKE_TMUX_VERSION"
else
    exec "$TMUX_BIN" "\$@"
fi
EOF
chmod 755 "$shim_dir/tmux"
dispatch_case() {
    local version="$1"
    local expected_path="$2"
    local expected_mouse="$3"
    local expected_style="$4"
    local socket_name="t03-dispatch-$RANDOM"
    FAKE_TMUX_VERSION="$version" \
        load_tmux_config "$socket_name" "$shim_dir:$local_path" "" ""
    assert_equal "0" "$?" "dispatch $version load"
    assert_equal "$expected_path" \
        "$(show_option "$socket_name" @tmux_smoke_path)" \
        "dispatch $version path"
    assert_equal "$expected_mouse" \
        "$(show_option "$socket_name" @tmux_smoke_mouse)" \
        "dispatch $version mouse"
    assert_equal "$expected_style" \
        "$(show_option "$socket_name" @tmux_smoke_style)" \
        "dispatch $version style"
}
dispatch_case "tmux 1.8" legacy legacy legacy
dispatch_case "tmux 1.9" modern legacy legacy
dispatch_case "tmux 2.0" modern legacy legacy
dispatch_case "tmux 2.1" modern modern legacy
dispatch_case "tmux 2.8" modern modern legacy
dispatch_case "tmux 2.9" modern modern modern
dispatch_case "tmux 3.2a" modern modern modern
for threshold_case in \
    "tmux 1.8|1.9|1" \
    "tmux 1.9|1.9|0" \
    "tmux 2.0|2.1|1" \
    "tmux 2.1|2.1|0" \
    "tmux 2.8|2.9|1" \
    "tmux 2.9|2.9|0"; do
    threshold_version=${threshold_case%%|*}
    threshold_rest=${threshold_case#*|}
    threshold_required=${threshold_rest%%|*}
    threshold_expected=${threshold_rest#*|}
    "$REPO_DIR/tools/multiplexer/tmux/tmux-version.sh" \
        --at-least "$threshold_required" "$threshold_version"
    assert_equal "$threshold_expected" "$?" \
        "dispatch threshold $threshold_version >= $threshold_required"
done
for fragment in \
    tmux-path-legacy.conf tmux-path-modern.conf \
    tmux-mouse-legacy.conf tmux-mouse-modern.conf \
    tmux-style-legacy.conf tmux-style-modern.conf; do
    rm -f "$DISPATCH_HOME/$fragment" || exit 1
    ln -s "$REPO_DIR/tools/multiplexer/tmux/$fragment" \
        "$DISPATCH_HOME/$fragment" || exit 1
done

product_hash_before=$(sha256sum \
    "$REPO_DIR/tools/multiplexer/tmux/tmux-style-modern.conf" |
    awk '{print $1}')
rm -f "$TEST_HOME/.tmux/portable-devenv/tmux-style-modern.conf" || exit 1
cp "$REPO_DIR/tools/multiplexer/tmux/tmux-style-modern.conf" \
    "$TEST_HOME/.tmux/portable-devenv/tmux-style-modern.conf" || exit 1
sed -i 's/status-style/status-invalid-option/' \
    "$TEST_HOME/.tmux/portable-devenv/tmux-style-modern.conf" || exit 1
socket="t03-mutated-$RANDOM"
load_tmux_config "$socket" "$local_path" > "$LOG_FILE" 2>&1
grep -E 'invalid option|unknown option|error' "$LOG_FILE" >/dev/null ||
    fail "mutation did not make the configuration test fail"
rm -f "$TEST_HOME/.tmux/portable-devenv/tmux-style-modern.conf" || exit 1
ln -s "$REPO_DIR/tools/multiplexer/tmux/tmux-style-modern.conf" \
    "$TEST_HOME/.tmux/portable-devenv/tmux-style-modern.conf" || exit 1
product_hash_after=$(sha256sum \
    "$REPO_DIR/tools/multiplexer/tmux/tmux-style-modern.conf" |
    awk '{print $1}')
assert_equal "$product_hash_before" "$product_hash_after" \
    "product fragment hash after mutation test"

HOME="$TEST_HOME" bash "$REPO_DIR/setup_devenv.sh" -c "$TEST_CONFIG" > "$LOG_FILE" 2>&1
assert_equal "0" "$?" "idempotent tmux setup"
backup_count=$(find "$TEST_HOME/.dev-env-backup" -mindepth 1 -maxdepth 1 \
    -type d | wc -l)
assert_equal "1" "$backup_count" "idempotent backup count"
backup_id=$(HOME="$TEST_HOME" bash "$REPO_DIR/setup_devenv.sh" \
    --list-backups -c "$TEST_CONFIG")
[[ -n "$backup_id" ]] || fail "backup ID was not listed"

HOME="$TEST_HOME" bash "$REPO_DIR/setup_devenv.sh" \
    --restore "$backup_id" -c "$TEST_CONFIG" > "$LOG_FILE" 2>&1
restore_status=$?
assert_equal "0" "$restore_status" "tmux backup restore"
[[ -f "$TEST_HOME/.tmux.conf" && ! -L "$TEST_HOME/.tmux.conf" ]] ||
    fail "original tmux.conf was not restored as a regular file"
grep -F 'original tmux configuration' "$TEST_HOME/.tmux.conf" >/dev/null ||
    fail "original tmux.conf content was not restored"
for support_file in \
    tmux-version.sh \
    tmux-terminfo.sh \
    tmux-style-legacy.conf \
    tmux-style-modern.conf \
    tmux-path-legacy.conf \
    tmux-path-modern.conf \
    tmux-mouse-legacy.conf \
    tmux-mouse-modern.conf; do
    assert_file_absent "$TEST_HOME/.tmux/portable-devenv/$support_file"
done

if [[ "$FAILURES" -ne 0 ]]; then
    printf '%s tmux smoke checks failed\n' "$FAILURES" >&2
    exit 1
fi
printf '%s\n' 'tmux smoke tests passed'
