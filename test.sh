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

assert_files_equal() {
    local actual="$1"
    local expected="$2"

    if ! cmp -s "$actual" "$expected"; then
        diff -u "$expected" "$actual" >&2 || true
        fail "generated output did not match the expected content"
    fi
}

new_home() {
    local name="$1"
    local home="$TEST_ROOT/$name/home"

    mkdir -p "$home"
    printf 'shared instructions\n' >"$home/AGENTS.shared.md"
    printf 'local instructions\n' >"$home/AGENTS.local.md"
    printf '%s' "$home"
}

new_commit_home() {
    local name="$1"
    local base="$TEST_ROOT/$name"
    local home="$base/home"
    local seed="$base/seed"
    local remote="$base/remote.git"
    local checkout="$base/checkout"

    mkdir -p "$home/agentsmd"
    git init -q --initial-branch=main "$seed"
    git -C "$seed" config user.name "Agentsmd Test"
    git -C "$seed" config user.email "agentsmd-test@example.com"
    printf 'shared instructions\n' >"$seed/AGENTS.shared.md"
    printf 'other instructions\n' >"$seed/other.md"
    git -C "$seed" add AGENTS.shared.md other.md
    git -C "$seed" commit -qm "Initial instructions"

    git init -q --bare "$remote"
    git -C "$seed" remote add origin "$remote"
    git -C "$seed" push -qu origin main
    git --git-dir="$remote" symbolic-ref HEAD refs/heads/main
    git clone -q "$remote" "$checkout"
    git -C "$checkout" config user.name "Agentsmd Test"
    git -C "$checkout" config user.email "agentsmd-test@example.com"

    printf '[shared]\nrepository = "%s"\npath = "AGENTS.shared.md"\ncheckout = "%s"\n' \
        "$remote" "$checkout" >"$home/agentsmd/config.toml"
    printf 'local instructions\n' >"$home/AGENTS.local.md"
    ln -s "$checkout/AGENTS.shared.md" "$home/AGENTS.shared.md"
    printf '%s' "$home"
}

run_commit() {
    local home="$1"
    shift

    HOME="$home" "$AGENTSMD" commit "$@"
}

test_configured_shared_source_is_used_for_builds() {
    local home
    local checkout

    CURRENT_TEST="config selects the repository-backed shared source"
    home="$(new_commit_home configured-source)"
    checkout="$TEST_ROOT/configured-source/checkout"
    rm "$home/AGENTS.shared.md"
    printf 'unmanaged home source\n' >"$home/AGENTS.shared.md"
    printf 'configured repository source\n' >"$checkout/AGENTS.shared.md"

    run_service "$home" run >/dev/null
    grep -F 'configured repository source' "$home/AGENTS.md" >/dev/null || \
        fail "build did not use the configured repository source"
    if grep -F 'unmanaged home source' "$home/AGENTS.md" >/dev/null; then
        fail "build used the unmanaged home source"
    fi

    pass
}

test_config_discovers_checkout_from_shared_symlink() {
    local home
    local checkout
    local expected_checkout
    local output

    CURRENT_TEST="config reuses the checkout behind the shared-source symlink"
    home="$(new_commit_home configured-symlink)"
    checkout="$TEST_ROOT/configured-symlink/checkout"
    expected_checkout="$(cd -P "$checkout" && pwd)"
    git config --file "$home/agentsmd/config.toml" --unset shared.checkout

    output="$(HOME="$home" "$AGENTSMD" status)"
    assert_contains "$output" "Checkout:   $expected_checkout"
    assert_contains "$output" "Managed shared source is ready"

    pass
}

test_install_repairs_the_configured_shared_alias() {
    local home
    local checkout
    local backup

    CURRENT_TEST="install repairs the configured shared-source alias"
    home="$(new_commit_home configured-install)"
    checkout="$TEST_ROOT/configured-install/checkout"
    run_service "$home" run >/dev/null
    rm "$home/AGENTS.shared.md"
    printf 'unmanaged source\n' >"$home/AGENTS.shared.md"

    printf 'yes\n' | HOME="$home" "$AGENTSMD" install >/dev/null
    [[ -L "$home/AGENTS.shared.md" ]] || fail "install did not create the shared-source symlink"
    [[ "$(readlink "$home/AGENTS.shared.md")" == "$checkout/AGENTS.shared.md" ]] || \
        fail "shared-source symlink points to the wrong file"
    backup="$(
        find "$home/.cache/agentsmd/backups" \
            -type f -name 'AGENTS.shared.md.*.bak' -print -quit
    )"
    [[ -n "$backup" ]] || fail "install did not back up the old shared source"
    [[ "$(<"$backup")" == "unmanaged source" ]] || \
        fail "shared-source backup did not preserve the old file"

    pass
}

test_commit_check_reports_source_changes() {
    local home
    local checkout
    local unconfigured_home
    local output
    local status

    CURRENT_TEST="commit check distinguishes clean and dirty shared sources"
    home="$(new_commit_home commit-check)"
    checkout="$TEST_ROOT/commit-check/checkout"

    set +e
    output="$(run_commit "$home" --check 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 1 ]] || fail "clean source check did not exit 1"
    [[ -z "$output" ]] || fail "clean source check wrote output"

    printf 'updated shared instructions\n' >"$checkout/AGENTS.shared.md"
    output="$(run_commit "$home" --check 2>&1)" || fail "dirty source check did not exit 0"
    [[ -z "$output" ]] || fail "dirty source check wrote output"

    unconfigured_home="$(new_home commit-check-unconfigured)"
    set +e
    output="$(run_commit "$unconfigured_home" --check 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]] || fail "unconfigured source check did not exit 2"
    [[ -z "$output" ]] || fail "unconfigured source check wrote output"

    git config --file "$home/agentsmd/config.toml" \
        shared.repository "$TEST_ROOT/commit-check/wrong-remote.git"
    set +e
    output="$(run_commit "$home" --check 2>&1)"
    status=$?
    set -e
    [[ "$status" -eq 2 ]] || fail "unavailable source check did not exit 2"
    [[ -z "$output" ]] || fail "unavailable source check wrote output"

    pass
}

test_commit_cancellation_preserves_changes() {
    local home
    local checkout
    local before
    local output

    CURRENT_TEST="commit cancellation leaves the repository unchanged"
    home="$(new_commit_home commit-cancel)"
    checkout="$TEST_ROOT/commit-cancel/checkout"
    printf 'updated shared instructions\n' >"$checkout/AGENTS.shared.md"
    before="$(git -C "$checkout" rev-parse HEAD)"

    output="$(printf 'no\n' | run_commit "$home")"
    assert_contains "$output" "-shared instructions"
    assert_contains "$output" "+updated shared instructions"
    assert_contains "$output" "Commit cancelled. No files were changed."
    [[ "$(git -C "$checkout" rev-parse HEAD)" == "$before" ]] || \
        fail "cancellation created a commit"
    [[ -n "$(git -C "$checkout" status --short -- AGENTS.shared.md)" ]] || \
        fail "cancellation discarded the shared-source change"

    pass
}

test_commit_pushes_only_the_shared_source() {
    local home
    local checkout
    local remote
    local output
    local committed_files

    CURRENT_TEST="commit pushes only the configured shared source"
    home="$(new_commit_home commit-push)"
    checkout="$TEST_ROOT/commit-push/checkout"
    remote="$TEST_ROOT/commit-push/remote.git"
    printf 'updated shared instructions\n' >"$checkout/AGENTS.shared.md"
    printf 'updated other instructions\n' >"$checkout/other.md"
    git -C "$checkout" add other.md

    output="$(printf 'yes\n' | run_commit "$home" 2>&1)"
    assert_contains "$output" "Committed and pushed"
    [[ "$(git --git-dir="$remote" show main:AGENTS.shared.md)" == \
       "updated shared instructions" ]] || fail "remote shared source was not updated"
    [[ "$(git --git-dir="$remote" show main:other.md)" == \
       "other instructions" ]] || fail "unrelated file was pushed"
    [[ "$(git -C "$checkout" status --short -- other.md)" == "M  other.md" ]] || \
        fail "unrelated staged change was not preserved"
    committed_files="$(
        git -C "$checkout" show --pretty='' --name-only HEAD
    )"
    [[ "$committed_files" == "AGENTS.shared.md" ]] || \
        fail "commit included files besides the configured shared source"
    [[ "$(git -C "$checkout" log -1 --format=%B)" == \
       "Update AGENTS.shared.md" ]] || fail "commit message was unexpected"

    pass
}

test_commit_treats_configured_paths_literally() {
    local literal_names=(
        'shared*.md'
        'shared?.md'
        'shared[ab].md'
        ':(glob)shared*.md'
    )
    local decoy_names=(
        'shared-other.md'
        'shared1.md'
        'shareda.md'
        'shared-glob.md'
    )
    local index
    local home
    local checkout
    local remote
    local config
    local literal
    local decoy
    local output
    local status
    local committed_files

    CURRENT_TEST="commit treats configured source paths as literal filenames"

    for ((index = 0; index < ${#literal_names[@]}; index++)); do
        home="$(new_commit_home "commit-literal-$index")"
        checkout="$TEST_ROOT/commit-literal-$index/checkout"
        remote="$TEST_ROOT/commit-literal-$index/remote.git"
        config="$home/agentsmd/config.toml"
        literal="${literal_names[$index]}"
        decoy="${decoy_names[$index]}"

        printf 'literal baseline\n' >"$checkout/$literal"
        printf 'decoy baseline\n' >"$checkout/$decoy"
        git -C "$checkout" add -A
        git -C "$checkout" commit -qm "Add literal path fixture"
        git -C "$checkout" push -q origin main
        git config --file "$config" shared.path "$literal"

        printf 'decoy update\n' >"$checkout/$decoy"
        set +e
        output="$(run_commit "$home" --check 2>&1)"
        status=$?
        set -e
        [[ "$status" -eq 1 ]] || \
            fail "decoy change matched configured literal path: $literal"
        [[ -z "$output" ]] || fail "clean literal path check wrote output: $literal"

        printf 'literal update\n' >"$checkout/$literal"
        output="$(printf 'yes\n' | run_commit "$home" 2>&1)"
        assert_contains "$output" "literal update"
        case "$output" in
            *"decoy update"*) fail "configured path diff included decoy: $literal" ;;
        esac
        [[ "$(git --git-dir="$remote" show "main:$literal")" == "literal update" ]] || \
            fail "configured literal file was not pushed: $literal"
        [[ "$(git --git-dir="$remote" show "main:$decoy")" == "decoy baseline" ]] || \
            fail "decoy file was pushed: $literal"
        committed_files="$(
            git -C "$checkout" show --pretty='' --name-only HEAD
        )"
        [[ "$committed_files" == "$literal" ]] || \
            fail "commit selected a pathspec instead of the literal file: $literal"
        [[ -n "$(
            git -C "$checkout" --literal-pathspecs status --short -- "$decoy"
        )" ]] || fail "decoy change was not preserved: $literal"
    done

    pass
}

test_commit_refuses_to_push_existing_commits() {
    local home
    local checkout
    local remote
    local remote_before
    local output
    local status

    CURRENT_TEST="commit refuses to push pre-existing local commits"
    home="$(new_commit_home commit-ahead)"
    checkout="$TEST_ROOT/commit-ahead/checkout"
    remote="$TEST_ROOT/commit-ahead/remote.git"
    printf 'local committed change\n' >"$checkout/other.md"
    git -C "$checkout" add other.md
    git -C "$checkout" commit -qm "Unrelated local commit"
    printf 'updated shared instructions\n' >"$checkout/AGENTS.shared.md"
    remote_before="$(git --git-dir="$remote" rev-parse main)"

    set +e
    output="$(printf 'yes\n' | run_commit "$home" 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "commit accepted a checkout with unpushed commits"
    assert_contains "$output" "has unpushed commits; refusing to push them"
    [[ "$(git --git-dir="$remote" rev-parse main)" == "$remote_before" ]] || \
        fail "remote changed despite the existing local commit"

    pass
}

test_commit_refuses_a_behind_checkout() {
    local home
    local checkout
    local remote
    local updater
    local output
    local status

    CURRENT_TEST="commit refuses a checkout behind the remote branch"
    home="$(new_commit_home commit-behind)"
    checkout="$TEST_ROOT/commit-behind/checkout"
    remote="$TEST_ROOT/commit-behind/remote.git"
    updater="$TEST_ROOT/commit-behind/updater"
    git clone -q "$remote" "$updater"
    git -C "$updater" config user.name "Agentsmd Test"
    git -C "$updater" config user.email "agentsmd-test@example.com"
    printf 'remote update\n' >"$updater/other.md"
    git -C "$updater" add other.md
    git -C "$updater" commit -qm "Remote update"
    git -C "$updater" push -q origin main
    printf 'updated shared instructions\n' >"$checkout/AGENTS.shared.md"

    set +e
    output="$(printf 'yes\n' | run_commit "$home" 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "commit accepted a checkout behind its remote"
    assert_contains "$output" "is behind origin/main; update it first"
    [[ -n "$(git -C "$checkout" status --short -- AGENTS.shared.md)" ]] || \
        fail "behind-checkout failure discarded the source change"

    pass
}

test_commit_keeps_a_commit_when_push_fails() {
    local home
    local checkout
    local remote
    local before
    local output
    local status

    CURRENT_TEST="commit reports a failed push and keeps the local commit"
    home="$(new_commit_home commit-push-failure)"
    checkout="$TEST_ROOT/commit-push-failure/checkout"
    remote="$TEST_ROOT/commit-push-failure/remote.git"
    before="$(git -C "$checkout" rev-parse HEAD)"
    printf '#!/usr/bin/env bash\nexit 1\n' >"$remote/hooks/pre-receive"
    chmod 755 "$remote/hooks/pre-receive"
    printf 'updated shared instructions\n' >"$checkout/AGENTS.shared.md"

    set +e
    output="$(printf 'yes\n' | run_commit "$home" 2>&1)"
    status=$?
    set -e
    [[ "$status" -ne 0 ]] || fail "rejected push was reported as successful"
    assert_contains "$output" "locally, but the push to origin/main failed"
    [[ "$(git -C "$checkout" rev-parse HEAD)" != "$before" ]] || \
        fail "local commit was not kept after push failure"
    [[ "$(git --git-dir="$remote" rev-parse main)" == "$before" ]] || \
        fail "rejected remote unexpectedly changed"

    pass
}

test_generated_output_is_self_describing() {
    local home
    local expected

    CURRENT_TEST="generated output identifies its sources and rebuild workflow"
    home="$(new_home generated-format)"
    expected="$home/expected.md"
    printf '# Shared heading\n\nshared body\n' >"$home/AGENTS.shared.md"
    printf '# Local heading\n\nlocal body\n' >"$home/AGENTS.local.md"

    run_service "$home" run >/dev/null
    cat >"$expected" <<'EOF'
<!-- Generated by agentsmd. Do not edit this file directly.
Edit ~/AGENTS.shared.md for shared instructions.
Edit ~/AGENTS.local.md for machine-specific or private instructions.
Then run `agentsmd build`.
Version the source files, not this file. -->

<!-- BEGIN AGENTSMD SHARED SOURCE: ~/AGENTS.shared.md -->
# Shared heading

shared body

<!-- END AGENTSMD SHARED SOURCE: ~/AGENTS.shared.md -->

<!-- BEGIN AGENTSMD LOCAL SOURCE: ~/AGENTS.local.md -->
# Local heading

local body

<!-- END AGENTSMD LOCAL SOURCE: ~/AGENTS.local.md -->
EOF
    assert_files_equal "$home/AGENTS.md" "$expected"

    pass
}

test_generated_output_handles_missing_final_newlines() {
    local home
    local expected

    CURRENT_TEST="generated boundaries handle sources without final newlines"
    home="$(new_home generated-newlines)"
    expected="$home/expected.md"
    printf 'shared without final newline' >"$home/AGENTS.shared.md"
    printf 'local without final newline' >"$home/AGENTS.local.md"

    run_service "$home" run >/dev/null
    cat >"$expected" <<'EOF'
<!-- Generated by agentsmd. Do not edit this file directly.
Edit ~/AGENTS.shared.md for shared instructions.
Edit ~/AGENTS.local.md for machine-specific or private instructions.
Then run `agentsmd build`.
Version the source files, not this file. -->

<!-- BEGIN AGENTSMD SHARED SOURCE: ~/AGENTS.shared.md -->
shared without final newline
<!-- END AGENTSMD SHARED SOURCE: ~/AGENTS.shared.md -->

<!-- BEGIN AGENTSMD LOCAL SOURCE: ~/AGENTS.local.md -->
local without final newline
<!-- END AGENTSMD LOCAL SOURCE: ~/AGENTS.local.md -->
EOF
    assert_files_equal "$home/AGENTS.md" "$expected"

    pass
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
        if [[ "${FAKE_LAUNCHCTL_FAIL_BOOTSTRAP:-0}" -eq 1 ]]; then
            exit 1
        fi
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
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_CONFIG_FILE raw -o - "$plist")" == "$home/agentsmd/config.toml" ]] || \
        fail "plist did not capture the config path"
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

test_service_uses_custom_config_path() {
    local base="$TEST_ROOT/service-custom-config"
    local home
    local bin="$base/bin"
    local launchctl_log="$base/launchctl.log"
    local custom_config="$base/config/config.toml"
    local default_config
    local checkout="$base/checkout"
    local plist
    local saved_config
    local saved_shared
    local saved_local
    local saved_output
    local saved_state
    local saved_logs
    local saved_cache

    CURRENT_TEST="service builds keep using the selected custom config"
    home="$(new_commit_home service-custom-config)"
    default_config="$home/agentsmd/config.toml"
    mkdir -p "$bin" "$(dirname "$custom_config")"
    mv "$default_config" "$custom_config"
    printf '[invalid\n' >"$default_config"
    cp "$AGENTSMD" "$bin/agentsmd"
    chmod 755 "$bin/agentsmd"
    make_fake_launchctl "$bin"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_CONFIG_FILE="$custom_config" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
        "$bin/agentsmd" service install >/dev/null

    plist="$(
        find "$home/Library/LaunchAgents" -maxdepth 1 -type f -name '*.plist' -print -quit
    )"
    [[ -n "$plist" ]] || fail "service did not install a LaunchAgent plist"
    saved_config="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_CONFIG_FILE raw -o - "$plist")"
    saved_shared="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_SHARED_FILE raw -o - "$plist")"
    saved_local="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOCAL_FILE raw -o - "$plist")"
    saved_output="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_OUTPUT_FILE raw -o - "$plist")"
    saved_state="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_STATE_HOME raw -o - "$plist")"
    saved_logs="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOG_HOME raw -o - "$plist")"
    saved_cache="$(/usr/bin/plutil -extract EnvironmentVariables.XDG_CACHE_HOME raw -o - "$plist")"
    [[ "$saved_config" == "$custom_config" ]] || fail "service did not save the custom config path"

    printf 'service config instructions\n' >"$checkout/AGENTS.shared.md"
    PATH="$bin:/usr/bin:/bin" \
    HOME="$home" \
    AGENTSMD_CONFIG_FILE="$saved_config" \
    AGENTSMD_SHARED_FILE="$saved_shared" \
    AGENTSMD_LOCAL_FILE="$saved_local" \
    AGENTSMD_OUTPUT_FILE="$saved_output" \
    AGENTSMD_STATE_HOME="$saved_state" \
    AGENTSMD_LOG_HOME="$saved_logs" \
    XDG_CACHE_HOME="$saved_cache" \
        "$bin/agentsmd" service run >/dev/null
    grep -F 'service config instructions' "$saved_output" >/dev/null || \
        fail "service build did not use the custom config source"

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
    local custom_config="$base/config/agentsmd.toml"
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
    home="$(new_commit_home self-update-service)"
    mkdir -p "$bin" "$(dirname "$shared")"
    mv "$home/agentsmd/config.toml" "$custom_config"
    printf '[invalid\n' >"$home/agentsmd/config.toml"
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
    AGENTSMD_CONFIG_FILE="$custom_config" \
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
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_CONFIG_FILE raw -o - "$plist")" == "$custom_config" ]] || \
        fail "service refresh did not preserve the custom config path"
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

test_self_update_migrates_legacy_service_config_path() {
    local base="$TEST_ROOT/self-update-legacy-service"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local update_source="$base/updated-agentsmd"
    local launchctl_log="$base/launchctl.log"
    local plist
    local output
    local print_count

    CURRENT_TEST="self-update migrates a legacy service to the default config path"
    home="$(new_commit_home self-update-legacy-service)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    cp "$AGENTSMD" "$update_source"
    printf '\n# self-update legacy service test version\n' >>"$update_source"
    make_fake_curl "$bin"
    make_fake_launchctl "$bin"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
    XDG_CACHE_HOME="$home/cache" \
        "$executable" service install >/dev/null

    plist="$home/Library/LaunchAgents/com.juanrgon.agentsmd.plist"
    /usr/bin/plutil -remove EnvironmentVariables.AGENTSMD_CONFIG_FILE "$plist"
    if /usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_CONFIG_FILE raw \
        -o - "$plist" >/dev/null 2>&1; then
        fail "legacy plist still contains AGENTSMD_CONFIG_FILE"
    fi

    : >"$launchctl_log"
    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
        AGENTSMD_UPDATE_URL="https://example.invalid/agentsmd" \
        FAKE_UPDATE_SOURCE="$update_source" \
            "$executable" self-update
    )"

    assert_contains "$output" "Installed and started the agentsmd service."
    [[ "$(
        /usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_CONFIG_FILE raw \
            -o - "$plist"
    )" == "$home/agentsmd/config.toml" ]] || \
        fail "legacy service did not derive the default config path from HOME"
    print_count="$(grep -c '^print ' "$launchctl_log" || true)"
    [[ "$print_count" == "2" ]] || fail "legacy service was not checked and refreshed exactly once"

    pass
}

test_current_self_update_repairs_legacy_service() {
    local base="$TEST_ROOT/self-update-current-legacy-service"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local launchctl_log="$base/launchctl.log"
    local plist
    local saved_shared
    local saved_local
    local saved_output
    local saved_state
    local saved_logs
    local saved_cache
    local output
    local print_count

    CURRENT_TEST="current self-update repairs a loaded legacy service"
    home="$(new_commit_home self-update-current-legacy-service)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    make_fake_curl "$bin"
    make_fake_launchctl "$bin"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
    AGENTSMD_STATE_HOME="$home/state" \
    AGENTSMD_LOG_HOME="$home/logs" \
    XDG_CACHE_HOME="$home/cache" \
        "$executable" service install >/dev/null

    plist="$(
        find "$home/Library/LaunchAgents" -maxdepth 1 -type f \
            -name '*.plist' -print -quit
    )"
    [[ -n "$plist" ]] || fail "service install did not create a LaunchAgent plist"
    saved_shared="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_SHARED_FILE raw -o - "$plist")"
    saved_local="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOCAL_FILE raw -o - "$plist")"
    saved_output="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_OUTPUT_FILE raw -o - "$plist")"
    saved_state="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_STATE_HOME raw -o - "$plist")"
    saved_logs="$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOG_HOME raw -o - "$plist")"
    saved_cache="$(/usr/bin/plutil -extract EnvironmentVariables.XDG_CACHE_HOME raw -o - "$plist")"
    /usr/bin/plutil -remove EnvironmentVariables.AGENTSMD_CONFIG_FILE "$plist"

    : >"$launchctl_log"
    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
        AGENTSMD_UPDATE_URL="https://example.invalid/agentsmd" \
        FAKE_UPDATE_SOURCE="$AGENTSMD" \
            "$executable" self-update
    )"

    assert_contains "$output" "already up to date"
    assert_contains "$output" "Installed and started the agentsmd service."
    [[ "$(
        /usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_CONFIG_FILE raw \
            -o - "$plist"
    )" == "$home/agentsmd/config.toml" ]] || \
        fail "current self-update did not derive the default config path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_SHARED_FILE raw -o - "$plist")" == "$saved_shared" ]] || \
        fail "current self-update changed the shared source path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOCAL_FILE raw -o - "$plist")" == "$saved_local" ]] || \
        fail "current self-update changed the local source path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_OUTPUT_FILE raw -o - "$plist")" == "$saved_output" ]] || \
        fail "current self-update changed the output path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_STATE_HOME raw -o - "$plist")" == "$saved_state" ]] || \
        fail "current self-update changed the state path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.AGENTSMD_LOG_HOME raw -o - "$plist")" == "$saved_logs" ]] || \
        fail "current self-update changed the log path"
    [[ "$(/usr/bin/plutil -extract EnvironmentVariables.XDG_CACHE_HOME raw -o - "$plist")" == "$saved_cache" ]] || \
        fail "current self-update changed the cache path"
    [[ -z "$(find "$bin" -maxdepth 1 -name 'agentsmd.*.bak' -print -quit)" ]] || \
        fail "current self-update created an executable backup"
    cmp -s "$executable" "$AGENTSMD" || \
        fail "current self-update changed the executable"
    print_count="$(grep -c '^print ' "$launchctl_log" || true)"
    [[ "$print_count" == "2" ]] || \
        fail "current self-update did not check and repair the loaded service exactly once"

    pass
}

test_current_self_update_reports_service_refresh_failure() {
    local base="$TEST_ROOT/self-update-current-service-failure"
    local home
    local bin="$base/bin"
    local executable="$bin/agentsmd"
    local launchctl_log="$base/launchctl.log"
    local plist
    local output
    local status

    CURRENT_TEST="current self-update reports a service refresh failure accurately"
    home="$(new_commit_home self-update-current-service-failure)"
    mkdir -p "$bin"
    cp "$AGENTSMD" "$executable"
    chmod 755 "$executable"
    make_fake_curl "$bin"
    make_fake_launchctl "$bin"

    PATH="$bin:/usr/bin:/bin" \
    FAKE_LAUNCHCTL_LOG="$launchctl_log" \
    HOME="$home" \
        "$executable" service install >/dev/null

    plist="$(
        find "$home/Library/LaunchAgents" -maxdepth 1 -type f \
            -name '*.plist' -print -quit
    )"
    [[ -n "$plist" ]] || fail "service install did not create a LaunchAgent plist"
    /usr/bin/plutil -remove EnvironmentVariables.AGENTSMD_CONFIG_FILE "$plist"

    set +e
    output="$(
        PATH="$bin:/usr/bin:/bin" \
        FAKE_LAUNCHCTL_FAIL_BOOTSTRAP=1 \
        FAKE_LAUNCHCTL_LOG="$launchctl_log" \
        HOME="$home" \
        AGENTSMD_UPDATE_URL="https://example.invalid/agentsmd" \
        FAKE_UPDATE_SOURCE="$AGENTSMD" \
            "$executable" self-update 2>&1
    )"
    status=$?
    set -e

    [[ "$status" -eq 1 ]] || \
        fail "current self-update succeeded after service refresh failed"
    assert_contains "$output" "already up to date"
    assert_contains "$output" "agentsmd is current, but the service could not be refreshed"
    if [[ "$output" == *"agentsmd updated, but"* ]]; then
        fail "current self-update claimed the executable was updated"
    fi
    [[ -z "$(find "$bin" -maxdepth 1 -name 'agentsmd.*.bak' -print -quit)" ]] || \
        fail "failed current self-update created an executable backup"
    cmp -s "$executable" "$AGENTSMD" || \
        fail "failed current self-update changed the executable"

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

printf '1..33\n'
test_configured_shared_source_is_used_for_builds
test_config_discovers_checkout_from_shared_symlink
test_install_repairs_the_configured_shared_alias
test_commit_check_reports_source_changes
test_commit_cancellation_preserves_changes
test_commit_pushes_only_the_shared_source
test_commit_treats_configured_paths_literally
test_commit_refuses_to_push_existing_commits
test_commit_refuses_a_behind_checkout
test_commit_keeps_a_commit_when_push_fails
test_generated_output_is_self_describing
test_generated_output_handles_missing_final_newlines
test_unattended_build_and_history
test_unattended_build_replaces_output_safely
test_unattended_build_records_failure
test_service_install_and_uninstall
test_service_uses_custom_config_path
test_service_status_and_doctor
test_stale_lock_is_recovered
test_non_macos_is_rejected
test_self_update_replaces_executable_and_creates_backup
test_self_update_is_noop_when_current
test_self_update_rejects_invalid_bash
test_self_update_rejects_unexpected_content
test_self_update_rejects_symlinked_executable
test_self_update_refreshes_loaded_service_with_saved_paths
test_self_update_migrates_legacy_service_config_path
test_current_self_update_repairs_legacy_service
test_current_self_update_reports_service_refresh_failure
test_self_update_does_not_refresh_service_for_other_executable
test_install_downloads_from_uncached_main_url
test_self_update_downloads_from_uncached_main_url
test_status_summarizes_service_state
