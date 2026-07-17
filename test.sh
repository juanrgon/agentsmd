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

make_fake_curl() {
    local bin="$1"

    mkdir -p "$bin"
    cat >"$bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -n "${FAKE_CURL_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$FAKE_CURL_LOG"
fi

destination=""
while [[ "$#" -gt 0 ]]; do
    case "$1" in
        -o)
            destination="$2"
            shift 2
            ;;
        *)
            shift
            ;;
    esac
done

[[ -n "$destination" ]]
cp "$FAKE_UPDATE_SOURCE" "$destination"
EOF
    chmod 755 "$bin/curl"
}

make_fake_launchctl() {
    local bin="$1"

    mkdir -p "$bin"
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
}

run_self_update() {
    local home="$1"
    local executable="$2"
    local bin="$3"
    local update_source="$4"

    PATH="$bin:/usr/bin:/bin" \
    HOME="$home" \
    AGENTSMD_UPDATE_URL="https://example.invalid/agentsmd" \
    FAKE_UPDATE_SOURCE="$update_source" \
        "$executable" self-update
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

test_self_update_replaces_executable_and_creates_backup() {
    local base="$TEST_ROOT/self-update-success"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local original="$base/original-agentsmd"
    local update_source="$base/updated-agentsmd"
    local backup
    local output

    CURRENT_TEST="self-update replaces the executable and creates a timestamped backup"
    home="$(new_home self-update-success)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    cp "$executable" "$original"
    cp "$AGENTSMD" "$update_source"
    printf '\n# self-update test version\n' >>"$update_source"
    make_fake_curl "$bin"

    output="$(run_self_update "$home" "$executable" "$bin" "$update_source")"
    assert_contains "$output" "Backup:"
    assert_contains "$output" "Updated:"
    cmp -s "$executable" "$update_source" || fail "executable was not replaced"

    backup="$(find "$bin" -maxdepth 1 -type f -name 'agentsmd.*.bak' -print -quit)"
    [[ -n "$backup" ]] || fail "self-update did not create a backup"
    cmp -s "$backup" "$original" || fail "backup does not match the old executable"
    [[ "$(stat -f '%Lp' "$executable")" == "755" ]] || fail "updated executable mode is not 0755"

    pass
}

test_self_update_is_noop_when_current() {
    local base="$TEST_ROOT/self-update-current"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local output

    CURRENT_TEST="self-update is a no-op when the downloaded command is unchanged"
    home="$(new_home self-update-current)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    make_fake_curl "$bin"

    output="$(run_self_update "$home" "$executable" "$bin" "$AGENTSMD")"
    assert_contains "$output" "already up to date"
    [[ -z "$(find "$bin" -maxdepth 1 -name 'agentsmd.*.bak' -print -quit)" ]] || \
        fail "unchanged self-update created a backup"

    pass
}

test_self_update_rejects_invalid_bash() {
    local base="$TEST_ROOT/self-update-invalid"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local original="$base/original-agentsmd"
    local update_source="$base/invalid-agentsmd"
    local output
    local status

    CURRENT_TEST="self-update rejects invalid Bash without changing the executable"
    home="$(new_home self-update-invalid)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    cp "$executable" "$original"
    printf '#!/usr/bin/env bash\nPROGRAM_NAME="agentsmd"\nif\n' >"$update_source"
    make_fake_curl "$bin"

    set +e
    output="$(run_self_update "$home" "$executable" "$bin" "$update_source" 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "invalid Bash update did not fail"
    assert_contains "$output" "downloaded agentsmd script is not valid Bash"
    cmp -s "$executable" "$original" || fail "invalid update changed the executable"
    [[ -z "$(find "$bin" -maxdepth 1 -name 'agentsmd.*.bak' -print -quit)" ]] || \
        fail "invalid update created a backup"

    pass
}

test_self_update_rejects_unexpected_content() {
    local base="$TEST_ROOT/self-update-unexpected"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local original="$base/original-agentsmd"
    local update_source="$base/not-agentsmd"
    local output
    local status

    CURRENT_TEST="self-update rejects a valid script that is not agentsmd"
    home="$(new_home self-update-unexpected)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    cp "$executable" "$original"
    printf '#!/usr/bin/env bash\nprintf "not agentsmd\\n"\n' >"$update_source"
    make_fake_curl "$bin"

    set +e
    output="$(run_self_update "$home" "$executable" "$bin" "$update_source" 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "unexpected update content did not fail"
    assert_contains "$output" "downloaded file does not look like agentsmd"
    cmp -s "$executable" "$original" || fail "unexpected update changed the executable"

    pass
}

test_self_update_rejects_symlinked_executable() {
    local base="$TEST_ROOT/self-update-symlink"
    local home
    local bin="$base/bin"
    local target_dir="$base/target"
    local target="$target_dir/agentsmd"
    local executable="$bin/agentsmd"
    local original="$base/original-agentsmd"
    local update_source="$base/updated-agentsmd"
    local output
    local status

    CURRENT_TEST="self-update rejects a symlinked executable"
    home="$(new_home self-update-symlink)"
    mkdir -p "$bin" "$target_dir"
    cp "$AGENTSMD" "$target"
    chmod 755 "$target"
    cp "$target" "$original"
    ln -s "$target" "$executable"
    cp "$AGENTSMD" "$update_source"
    printf '\n# self-update symlink test version\n' >>"$update_source"
    make_fake_curl "$bin"

    set +e
    output="$(run_self_update "$home" "$executable" "$bin" "$update_source" 2>&1)"
    status=$?
    set -e

    [[ "$status" -ne 0 ]] || fail "symlinked executable update did not fail"
    assert_contains "$output" "self-update requires agentsmd to be a regular file"
    [[ -L "$executable" ]] || fail "self-update replaced the executable symlink"
    cmp -s "$target" "$original" || fail "self-update changed the symlink target"

    pass
}

test_self_update_refreshes_loaded_service_with_saved_paths() {
    local base="$TEST_ROOT/self-update-service"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local update_source="$base/updated-agentsmd"
    local launchctl_log="$base/launchctl.log"
    local shared="$base/config/shared.md"
    local local_file="$base/config/local.md"
    local generated="$base/config/generated.md"
    local state="$base/config/state"
    local logs="$base/config/logs"
    local cache="$base/config/cache"
    local plist
    local output
    local print_count

    CURRENT_TEST="self-update refreshes a loaded service using its saved paths"
    home="$(new_home self-update-service)"
    mkdir -p "$bin" "$(dirname "$shared")"
    printf 'custom shared instructions\n' >"$shared"
    printf 'custom local instructions\n' >"$local_file"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    cp "$AGENTSMD" "$update_source"
    printf '\n# self-update service test version\n' >>"$update_source"
    make_fake_curl "$bin"
    make_fake_launchctl "$bin"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_SHARED_FILE="$shared" \
    AGENTSMD_LOCAL_FILE="$local_file" \
    AGENTSMD_OUTPUT_FILE="$generated" \
    AGENTSMD_STATE_HOME="$state" \
    AGENTSMD_LOG_HOME="$logs" \
    XDG_CACHE_HOME="$cache" \
        "$executable" service install >/dev/null

    plist="$home/Library/LaunchAgents/com.juanrgon.agentsmd.plist"
    : >"$launchctl_log"
    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
        AGENTSMD_UPDATE_URL="https://example.invalid/agentsmd" \
        FAKE_UPDATE_SOURCE="$update_source" \
            "$executable" self-update
    )"

    assert_contains "$output" "No changes. The agentsmd service is installed and loaded."
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_SHARED_FILE raw -o - "$plist")" == "$shared" ]] || \
        fail "service refresh did not preserve the shared source path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOCAL_FILE raw -o - "$plist")" == "$local_file" ]] || \
        fail "service refresh did not preserve the local source path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_OUTPUT_FILE raw -o - "$plist")" == "$generated" ]] || \
        fail "service refresh did not preserve the output path"
    print_count="$(grep -c '^print ' "$launchctl_log" || true)"
    [[ "$print_count" == "2" ]] || fail "loaded service was not checked and refreshed exactly once"

    pass
}

test_self_update_does_not_refresh_service_for_other_executable() {
    local base="$TEST_ROOT/self-update-other-service"
    local home
    local tools_bin="$base/tools"
    local update_bin="$base/update-bin"
    local service_bin="$base/service-bin"
    local executable="$update_bin/agentsmd"
    local service_executable="$service_bin/agentsmd"
    local update_source="$base/updated-agentsmd"
    local launchctl_log="$base/launchctl.log"
    local output
    local print_count

    CURRENT_TEST="self-update leaves a service for another executable unchanged"
    home="$(new_home self-update-other-service)"
    mkdir -p "$update_bin" "$service_bin"
    cp "$AGENTSMD" "$executable"
    cp "$AGENTSMD" "$service_executable"
    chmod 755 "$executable" "$service_executable"
    cp "$AGENTSMD" "$update_source"
    printf '\n# self-update other service test version\n' >>"$update_source"
    make_fake_curl "$tools_bin"
    make_fake_launchctl "$tools_bin"

    PATH="$tools_bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$service_executable" service install >/dev/null

    : >"$launchctl_log"
    output="$(
        PATH="$tools_bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
        AGENTSMD_UPDATE_URL="https://example.invalid/agentsmd" \
        FAKE_UPDATE_SOURCE="$update_source" \
            "$executable" self-update
    )"

    assert_contains "$output" "Updated:"
    case "$output" in
        *"The agentsmd service is installed and loaded"*)
            fail "self-update refreshed a service that uses another executable"
            ;;
    esac
    print_count="$(grep -c '^print ' "$launchctl_log" || true)"
    [[ "$print_count" == "1" ]] || fail "service for another executable was refreshed"

    pass
}

test_install_downloads_from_uncached_main_url() {
    local base="$TEST_ROOT/install-latest"
    local home
    local bin="$base/bin"
    local install_dir
    local update_source="$base/updated-agentsmd"
    local curl_log="$base/curl.log"
    local output

    CURRENT_TEST="install downloads the latest main branch instead of a cached copy"
    home="$(new_home install-latest)"
    install_dir="$home/.local/bin"
    cp "$AGENTSMD" "$update_source"
    printf '\n# install latest test version\n' >>"$update_source"
    make_fake_curl "$bin"

    output="$(
        PATH="$bin:/usr/bin:/bin" \
        HOME="$home" \
        AGENTSMD_INSTALL_DIR="$install_dir" \
        FAKE_UPDATE_SOURCE="$update_source" \
        FAKE_CURL_LOG="$curl_log" \
            /bin/bash "$ROOT_DIR/install.sh"
    )"

    assert_contains "$output" "Installed:"
    cmp -s "$install_dir/agentsmd" "$update_source" || fail "installer did not use the downloaded command"
    grep -F 'Accept: application/vnd.github.raw' "$curl_log" >/dev/null || \
        fail "installer did not request raw contents from GitHub's API"
    grep -F 'https://api.github.com/repos/juanrgon/agentsmd/contents/agentsmd?ref=main&cache=' "$curl_log" >/dev/null || \
        fail "installer did not download the current main branch through GitHub's API"

    pass
}

test_self_update_downloads_from_uncached_main_url() {
    local base="$TEST_ROOT/self-update-latest"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local update_source="$base/updated-agentsmd"
    local curl_log="$base/curl.log"
    local output

    CURRENT_TEST="self-update downloads the latest main branch instead of a cached copy"
    home="$(new_home self-update-latest)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    cp "$AGENTSMD" "$update_source"
    printf '\n# self-update latest test version\n' >>"$update_source"
    make_fake_curl "$bin"

    output="$(
        PATH="$bin:/usr/bin:/bin" \
        HOME="$home" \
        FAKE_UPDATE_SOURCE="$update_source" \
        FAKE_CURL_LOG="$curl_log" \
            "$executable" self-update
    )"

    assert_contains "$output" "Updated:"
    grep -F 'Accept: application/vnd.github.raw' "$curl_log" >/dev/null || \
        fail "self-update did not request raw contents from GitHub's API"
    grep -F 'https://api.github.com/repos/juanrgon/agentsmd/contents/agentsmd?ref=main&cache=' "$curl_log" >/dev/null || \
        fail "self-update did not download the current main branch through GitHub's API"

    pass
}

test_status_summarizes_service_state() {
    local base="$TEST_ROOT/status-service-summary"
    local home
    local bin="$base/bin"
    local launchctl_log="$base/launchctl.log"
    local plist
    local output

    CURRENT_TEST="status summarizes whether the service is installed and running"
    home="$(new_home status-service-summary)"
    make_fake_launchctl "$bin"
    plist="$home/Library/LaunchAgents/com.juanrgon.agentsmd.plist"

    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
            "$AGENTSMD" status
    )"
    assert_contains "$output" "Service: not installed"

    mkdir -p "$(dirname "$plist")"
    : >"$plist"
    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
            "$AGENTSMD" status
    )"
    assert_contains "$output" "Service: installed but stopped"

    : >"$home/.fake-launchctl-loaded"
    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
            "$AGENTSMD" status
    )"
    assert_contains "$output" "Service: installed and running"

    pass
}

printf '1..17\n'
test_unattended_build_and_history
test_unattended_build_replaces_output_safely
test_unattended_build_records_failure
test_service_install_and_uninstall
test_service_status_and_doctor
test_stale_lock_is_recovered
test_non_macos_is_rejected
test_self_update_replaces_executable_and_creates_backup
test_self_update_is_noop_when_current
test_self_update_rejects_invalid_bash
test_self_update_rejects_unexpected_content
test_self_update_rejects_symlinked_executable
test_self_update_refreshes_loaded_service_with_saved_paths
test_self_update_does_not_refresh_service_for_other_executable
test_install_downloads_from_uncached_main_url
test_self_update_downloads_from_uncached_main_url
test_status_summarizes_service_state
