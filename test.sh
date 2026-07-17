#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AGENTSMD="$ROOT_DIR/agentsmd"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agentsmd-test.XXXXXX")"
TEST_COUNT=0
CURRENT_TEST=""

cleanup() {
    rm -r "$TEST_ROOT"
}

trap cleanup EXIT

fail() {
    printf 'not ok %d - %s: %s\n' "$((TEST_COUNT + 1))" "$CURRENT_TEST" "$1" >&2
    exit 1
}

pass() {
    TEST_COUNT=$((TEST_COUNT + 1))
    printf 'ok %d - %s\n' "$TEST_COUNT" "$CURRENT_TEST"
}

assert_contains() {
    local text="$1"
    local expected="$2"

    case "$text" in
        *"$expected"*) ;;
        *) fail "expected output to contain: $expected" ;;
    esac
}

new_home() {
    local name="$1"
    local home="$TEST_ROOT/$name/home"

    mkdir -p "$home"
    printf 'shared instructions\n' >"$home/AGENTS.shared.md"
    printf 'local instructions\n' >"$home/AGENTS.local.md"
    printf '%s' "$home"
}

run_service() {
    local home="$1"
    shift

    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$AGENTSMD" service "$@"
}

test_unattended_build_and_history() {
    local home
    local output

    CURRENT_TEST="unattended builds update the output and record history"
    home="$(new_home unattended)"
    output="$(run_service "$home" run)"
    assert_contains "$output" "Updated ~/AGENTS.md."
    [[ -f "$home/AGENTS.md" ]] || fail "unattended build did not create AGENTS.md"
    [[ "$(stat -f '%Lp' "$home/AGENTS.md")" == "600" ]] || fail "AGENTS.md mode is not 0600"
    [[ "$(stat -f '%Lp' "$home/state/history.tsv")" == "600" ]] || fail "history mode is not 0600"
    grep -F $'\tok\tbuilt\tUpdated ~/AGENTS.md.' "$home/state/history.tsv" >/dev/null || \
        fail "built result is missing from history"

    run_service "$home" run >/dev/null
    grep -F $'\tok\tunchanged\t~/AGENTS.md was already current.' "$home/state/history.tsv" >/dev/null || \
        fail "unchanged result is missing from history"

    pass
}

test_unattended_build_replaces_output_safely() {
    local home
    local target="$TEST_ROOT/symlink-output/outside.md"
    local backup

    CURRENT_TEST="unattended builds replace output symlinks without following them"
    home="$(new_home symlink-output)"
    mkdir -p "$(dirname "$target")"
    printf 'outside content\n' >"$target"
    ln -s "$target" "$home/AGENTS.md"

    run_service "$home" run >/dev/null
    [[ -f "$home/AGENTS.md" && ! -L "$home/AGENTS.md" ]] || \
        fail "output symlink was not replaced with a regular file"
    [[ "$(<"$target")" == "outside content" ]] || fail "output symlink target was modified"
    backup="$(find "$home/.cache/agentsmd/backups" -type l -name 'AGENTS.md.*.bak' -print -quit)"
    [[ -n "$backup" ]] || fail "output symlink was not backed up"

    pass
}

test_unattended_build_records_failure() {
    local home="$TEST_ROOT/failure/home"
    local output
    local status

    CURRENT_TEST="unattended build failures are recorded"
    mkdir -p "$home"
    printf 'shared instructions\n' >"$home/AGENTS.shared.md"

    set +e
    output="$(run_service "$home" run 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "missing source did not fail"
    assert_contains "$output" "local source is missing or unreadable"
    grep -F $'\terror\tfailed\tsource files are missing or unreadable' "$home/state/history.tsv" >/dev/null || \
        fail "failed result is missing from history"

    pass
}

test_service_install_and_uninstall() {
    local home
    local bin="$TEST_ROOT/install/bin"
    local launchctl_log="$TEST_ROOT/install/launchctl.log"
    local plist
    local shared_target="$TEST_ROOT/install/shared-target.md"

    CURRENT_TEST="service install writes, loads, and uninstalls the LaunchAgent"
    home="$(new_home install)"
    mv "$home/AGENTS.shared.md" "$shared_target"
    ln -s "$shared_target" "$home/AGENTS.shared.md"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$bin/agentsmd"
    chmod 755 "$bin/agentsmd"

    cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
    print)
        if [[ -f "$HOME/.fake-launchctl-loaded" ]]; then
            printf '    last exit code = 0\n'
            exit 0
        fi
        exit 113
        ;;
    bootstrap)
        : >"$HOME/.fake-launchctl-loaded"
        ;;
    bootout)
        if [[ -f "$HOME/.fake-launchctl-loaded" ]]; then
            rm "$HOME/.fake-launchctl-loaded"
        fi
        ;;
esac
EOF
    chmod 755 "$bin/launchctl"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service install >/dev/null

    plist="$home/Library/LaunchAgents/com.juanrgon.agentsmd.plist"
    [[ -f "$plist" ]] || fail "service install did not create the plist"
    [[ "$(stat -f '%Lp' "$plist")" == "600" ]] || fail "plist mode is not 0600"
    [[ "$(stat -f '%Lp' "$home/logs/service.log")" == "600" ]] || \
        fail "service output log mode is not 0600"
    [[ "$(stat -f '%Lp' "$home/logs/service.error.log")" == "600" ]] || \
        fail "service error log mode is not 0600"
    /usr/bin/plutil -lint "$plist" >/dev/null || fail "installed plist is invalid"
    [[ "$(/usr/bin/plutil -extract ProgramArguments.1 raw -o - "$plist")" == \
       "$(cd -P "$bin" && pwd)/agentsmd" ]] || \
        fail "plist did not capture the installed executable path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_SHARED_FILE raw -o - "$plist")" == "$home/AGENTS.shared.md" ]] || \
        fail "plist did not capture the shared source path"
    [[ "$(/usr/bin/plutil -extract WatchPaths.2 raw -o - "$plist")" == \
       "$(cd -P "$(dirname "$shared_target")" && pwd)/$(basename "$shared_target")" ]] || \
        fail "plist did not watch the resolved shared source path"
    grep -F "bootstrap gui/$(id -u) $plist" "$launchctl_log" >/dev/null || \
        fail "service install did not bootstrap the LaunchAgent"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service stop >/dev/null
    grep -F "disable gui/$(id -u)/com.juanrgon.agentsmd" "$launchctl_log" >/dev/null || \
        fail "service stop did not disable the LaunchAgent"
    [[ ! -e "$home/.fake-launchctl-loaded" ]] || fail "service stop did not unload the LaunchAgent"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service start >/dev/null
    grep -F "enable gui/$(id -u)/com.juanrgon.agentsmd" "$launchctl_log" >/dev/null || \
        fail "service start did not enable the LaunchAgent"
    [[ -f "$home/.fake-launchctl-loaded" ]] || fail "service start did not load the LaunchAgent"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service uninstall >/dev/null
    [[ ! -e "$plist" ]] || fail "service uninstall did not remove the plist"

    pass
}

test_service_status_and_doctor() {
    local home
    local bin="$TEST_ROOT/status/bin"
    local launchctl_log="$TEST_ROOT/status/launchctl.log"
    local output

    CURRENT_TEST="service status and doctor report a healthy installation"
    home="$(new_home status)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$bin/agentsmd"
    chmod 755 "$bin/agentsmd"
    cat >"$bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_LAUNCHCTL_LOG"
case "${1:-}" in
    print)
        if [[ -f "$HOME/.fake-launchctl-loaded" ]]; then
            printf '    last exit code = 0\n'
            exit 0
        fi
        exit 113
        ;;
    bootstrap)
        : >"$HOME/.fake-launchctl-loaded"
        ;;
    bootout)
        if [[ -f "$HOME/.fake-launchctl-loaded" ]]; then
            rm "$HOME/.fake-launchctl-loaded"
        fi
        ;;
esac
EOF
    chmod 755 "$bin/launchctl"

    PATH="$bin:/usr/bin:/bin" FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" AGENTSMD_STATE_HOME="$home/state" AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service install >/dev/null
    PATH="$bin:/usr/bin:/bin" FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" AGENTSMD_STATE_HOME="$home/state" AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service run >/dev/null

    output="$(PATH="$bin:/usr/bin:/bin" FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" AGENTSMD_STATE_HOME="$home/state" AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service status)"
    assert_contains "$output" "(current)"
    assert_contains "$output" "Loaded:       yes"
    assert_contains "$output" "Last build:"

    output="$(PATH="$bin:/usr/bin:/bin" FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" AGENTSMD_STATE_HOME="$home/state" AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service doctor)"
    assert_contains "$output" "No problems found."

    pass
}

test_stale_lock_is_recovered() {
    local home
    local output

    CURRENT_TEST="unattended builds recover from a stale lock"
    home="$(new_home stale-lock)"
    mkdir -p "$home/state/run.lock"
    printf '99999999\n' >"$home/state/run.lock/pid"

    output="$(run_service "$home" run)"
    assert_contains "$output" "Updated ~/AGENTS.md."
    [[ ! -e "$home/state/run.lock" ]] || fail "stale lock was not cleaned up"

    pass
}

test_non_macos_is_rejected() {
    local home
    local bin="$TEST_ROOT/non-macos/bin"
    local output
    local status

    CURRENT_TEST="service commands reject non-macOS systems"
    home="$(new_home non-macos)"
    mkdir -p "$bin"
    cat >"$bin/uname" <<'EOF'
#!/usr/bin/env bash
printf 'Linux\n'
EOF
    chmod 755 "$bin/uname"

    set +e
    output="$(PATH="$bin:/usr/bin:/bin" HOME="$home" "$AGENTSMD" service status 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "non-macOS service command did not fail"
    assert_contains "$output" "only supported on macOS (detected: Linux)"

    pass
}

printf '1..7\n'
test_unattended_build_and_history
test_unattended_build_replaces_output_safely
test_unattended_build_records_failure
test_service_install_and_uninstall
test_service_status_and_doctor
test_stale_lock_is_recovered
test_non_macos_is_rejected
