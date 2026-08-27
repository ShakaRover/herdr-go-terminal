#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
release_version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' \
    "$repo_root/herdr-plugin.toml" | sed -n '1p')
test_root=$(mktemp -d "${TMPDIR:-/tmp}/herdrgo-plugin-test.XXXXXX")
socket_pids=

# Exercise the default HOME-relative service path without inheriting a
# developer or CI runner's XDG override.
unset XDG_CONFIG_HOME

cleanup() {
    for pid in $socket_pids; do
        kill "$pid" 2>/dev/null || true
        wait "$pid" 2>/dev/null || true
    done
    rm -rf "$test_root"
}
trap cleanup EXIT HUP INT TERM

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_file() {
    [ -f "$1" ] || fail "expected file: $1"
}

assert_not_file() {
    [ ! -f "$1" ] || fail "unexpected file: $1"
}

assert_not_dir() {
    [ ! -d "$1" ] || fail "unexpected directory: $1"
}

assert_contains() {
    grep -F "$2" "$1" >/dev/null || fail "$1 does not contain: $2"
}

assert_not_contains() {
    if grep -F "$2" "$1" >/dev/null; then
        fail "$1 unexpectedly contains: $2"
    fi
}

fake_bin="$test_root/fake-bin"
mkdir -p "$fake_bin"

cat > "$fake_bin/uname" <<'EOF'
#!/bin/sh
case "${1:-}" in
    -s) printf '%s\n' "${FAKE_OS:-Linux}" ;;
    -m) printf '%s\n' "${FAKE_ARCH:-x86_64}" ;;
    *) printf '%s\n' "${FAKE_OS:-Linux}" ;;
esac
EOF

cat > "$fake_bin/curl" <<'EOF'
#!/bin/sh
output=
url=
while [ "$#" -gt 0 ]; do
    case "$1" in
        --output)
            output=$2
            shift 2
            ;;
        --fail | --location | --silent | --show-error)
            shift
            ;;
        --retry)
            shift 2
            ;;
        *)
            url=$1
            shift
            ;;
    esac
done
cp "$FIXTURE_RELEASE_DIR/$(basename -- "$url")" "$output"
EOF

cat > "$fake_bin/systemctl" <<'EOF'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$FAKE_SERVICE_LOG"
if [ "${FAKE_SERVICE_TERM_ON_RELOAD:-}" = yes ]; then
    case "$*" in
        *"daemon-reload"*) kill -TERM "$PPID" ;;
    esac
fi
if [ "${FAKE_SERVICE_STOP_FAIL:-}" = yes ]; then
    case "$*" in
        *"disable --now herdrgo-bridge.service"*) exit 1 ;;
    esac
fi
if [ "${FAKE_SERVICE_RESTART_FAIL_ONCE:-}" = yes ]; then
    case "$*" in
        *"restart herdrgo-bridge.service"*)
            if [ ! -f "$FAKE_SERVICE_FAILURE_MARKER" ]; then
                : > "$FAKE_SERVICE_FAILURE_MARKER"
                exit 1
            fi
            ;;
    esac
fi
case "$*" in
    *is-active*) exit 0 ;;
    *status*) printf 'active (running)\n' ;;
esac
EOF

cat > "$fake_bin/loginctl" <<'EOF'
#!/bin/sh
printf 'Linger=yes\n'
EOF

cat > "$fake_bin/launchctl" <<'EOF'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FAKE_SERVICE_LOG"
if [ "${FAKE_SERVICE_STOP_FAIL:-}" = yes ] && [ "${1:-}" = bootout ]; then
    exit 1
fi
if [ "${1:-}" = print ]; then
    printf 'state = running\n'
fi
EOF

cat > "$fake_bin/ln" <<'EOF'
#!/bin/sh
/bin/ln "$@"
status=$?
if [ "$status" -eq 0 ] && [ "${FAKE_LOCK_TERM_ON_ACQUIRE:-}" = yes ]; then
    case "$*" in
        *control.lock*) kill -TERM "$PPID" ;;
    esac
fi
exit "$status"
EOF

cat > "$fake_bin/herdr" <<'EOF'
#!/bin/sh
[ -z "${FAKE_HERDR_LOG:-}" ] || printf 'herdr %s\n' "$*" >> "$FAKE_HERDR_LOG"
case "$*" in
    "plugin list --plugin kkrainbow.herdrgo --json")
        if [ "${FAKE_LEGACY_PLUGIN_INSTALLED:-}" = yes ]; then
            printf '%s\n' '{"result":{"plugins":[{"plugin_id":"kkrainbow.herdrgo","enabled":true}]}}'
        else
            printf '%s\n' '{"result":{"plugins":[]}}'
        fi
        ;;
esac
exit 0
EOF

chmod 755 "$fake_bin/uname" "$fake_bin/curl" "$fake_bin/systemctl" \
    "$fake_bin/loginctl" "$fake_bin/launchctl" "$fake_bin/ln" "$fake_bin/herdr"

make_bridge() {
    path=$1
    version=$2
    cat > "$path" <<EOF
#!/bin/sh
case "\${1:-}" in
    --version) printf 'herdrgo-bridge $version\\n' ;;
    pair) printf 'PAIRING-$version\\n' ;;
    *) printf 'bridge process must be launched by the service manager\\n' ;;
esac
EOF
    chmod 755 "$path"
}

start_socket() {
    socket_path=$1
    if command -v socat >/dev/null 2>&1; then
        socat "UNIX-LISTEN:$socket_path,fork" EXEC:/bin/cat >/dev/null 2>&1 &
    elif command -v ruby >/dev/null 2>&1; then
        ruby -rsocket -e 'server = UNIXServer.new(ARGV[0]); sleep' \
            "$socket_path" >/dev/null 2>&1 &
    else
        fail "socat or ruby is required for the socket test"
    fi
    pid=$!
    socket_pids="$socket_pids $pid"
    remaining=50
    while [ ! -S "$socket_path" ] && [ "$remaining" -gt 0 ]; do
        sleep 0.02
        remaining=$((remaining - 1))
    done
    [ -S "$socket_path" ] || fail "socket did not start: $socket_path"
}

test_install() {
    install_root="$test_root/install"
    release_dir="$test_root/release"
    mkdir -p "$install_root/plugin" "$release_dir"
    cp "$repo_root/herdr-plugin.toml" "$install_root/herdr-plugin.toml"
    cp "$repo_root/plugin/install.sh" "$install_root/plugin/install.sh"
    make_bridge "$release_dir/herdrgo-bridge" "$release_version"
    archive="herdrgo-bridge-$release_version-x86_64-unknown-linux-musl.tar.gz"
    tar -czf "$release_dir/$archive" -C "$release_dir" herdrgo-bridge
    if command -v sha256sum >/dev/null 2>&1; then
        (cd "$release_dir" && sha256sum "$archive" > "$archive.sha256")
    else
        (cd "$release_dir" && shasum -a 256 "$archive" > "$archive.sha256")
    fi

    PATH="$fake_bin:$PATH" FIXTURE_RELEASE_DIR="$release_dir" \
        HERDRGO_RELEASE_BASE_URL=https://invalid.example/releases \
        FAKE_OS=Linux FAKE_ARCH=x86_64 \
        sh "$install_root/plugin/install.sh" >/dev/null
    assert_file "$install_root/bin/herdrgo-bridge"
    output=$($install_root/bin/herdrgo-bridge --version)
    [ "$output" = "herdrgo-bridge $release_version" ] || \
        fail "wrong installed bridge version"

    printf 'bad checksum\n' > "$release_dir/$archive.sha256"
    if PATH="$fake_bin:$PATH" FIXTURE_RELEASE_DIR="$release_dir" \
        HERDRGO_RELEASE_BASE_URL=https://invalid.example/releases \
        FAKE_OS=Linux FAKE_ARCH=x86_64 \
        sh "$install_root/plugin/install.sh" >/dev/null 2>&1; then
        fail "checksum mismatch unexpectedly succeeded"
    fi
    output=$($install_root/bin/herdrgo-bridge --version)
    [ "$output" = "herdrgo-bridge $release_version" ] || \
        fail "failed install replaced candidate"

    if PATH="$fake_bin:$PATH" FIXTURE_RELEASE_DIR="$release_dir" \
        HERDRGO_RELEASE_BASE_URL=https://invalid.example/releases \
        FAKE_OS=FreeBSD FAKE_ARCH=x86_64 \
        sh "$install_root/plugin/install.sh" >/dev/null 2>&1; then
        fail "unsupported platform unexpectedly succeeded"
    fi
}

test_action() {
    action_log="$test_root/action.log"
    fake_herdr="$test_root/herdr"
    cat > "$fake_herdr" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" > "$FAKE_ACTION_LOG"
EOF
    chmod 755 "$fake_herdr"
    FAKE_ACTION_LOG="$action_log" HERDR_BIN_PATH="$fake_herdr" \
        HERDR_PLUGIN_ID=herdrgo \
        sh "$repo_root/plugin/herdrgo-action.sh" setup-ui
    assert_contains "$action_log" \
        "plugin pane open --plugin herdrgo --entrypoint setup-ui --focus"
}

test_legacy_id_migration() {
    case_root="$test_root/legacy-id"
    plugin_root="$case_root/plugin"
    state_root="$case_root/state/plugins"
    state_dir="$state_root/herdrgo"
    legacy_state_dir="$state_root/kkrainbow.herdrgo"
    config_root="$case_root/config/plugins/config"
    config_dir="$config_root/herdrgo"
    legacy_config_dir="$config_root/kkrainbow.herdrgo"
    home_dir="$case_root/home"
    socket_path="$test_root/legacy-id.sock"
    service_log="$case_root/service.log"
    herdr_log="$case_root/herdr.log"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" \
        "$state_dir" "$legacy_state_dir/runtime" \
        "$config_dir" "$legacy_config_dir" "$home_dir"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" migrated
    printf 'legacy-secret\n' > "$legacy_state_dir/easytier_secret"
    printf 'legacy-network\n' > "$legacy_state_dir/easytier_network_id"
    printf '{"legacy":true}\n' > "$legacy_state_dir/activity.json"
    printf 'HERDRGO_BRIDGE_POLL_MS=750\n' > "$legacy_config_dir/env"
    start_socket "$socket_path"

    PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        FAKE_HERDR_LOG="$herdr_log" FAKE_LEGACY_PLUGIN_INSTALLED=yes \
        HOME="$home_dir" USER=tester \
        HERDR_PLUGIN_ID=herdrgo HERDR_PLUGIN_ROOT="$plugin_root" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDR_PLUGIN_CONFIG_DIR="$config_dir" HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null

    assert_not_dir "$legacy_state_dir"
    assert_not_dir "$legacy_config_dir"
    assert_contains "$state_dir/easytier_secret" legacy-secret
    assert_contains "$state_dir/easytier_network_id" legacy-network
    assert_contains "$state_dir/activity.json" '"legacy":true'
    assert_contains "$config_dir/env" 'HERDRGO_BRIDGE_POLL_MS=750'
    assert_contains "$service_log" "systemctl --user stop herdrgo-bridge.service"
    assert_contains "$herdr_log" "herdr plugin disable kkrainbow.herdrgo"
    assert_contains "$herdr_log" "herdr plugin uninstall kkrainbow.herdrgo"

    unit="$home_dir/.config/systemd/user/herdrgo-bridge.service"
    assert_contains "$unit" "$state_dir/runtime/herdrgo-bridge"
    assert_contains "$unit" "HERDRGO_BRIDGE_ENV_FILE=$config_dir/env"
}

test_legacy_id_conflict() {
    case_root="$test_root/legacy-id-conflict"
    plugin_root="$case_root/plugin"
    state_root="$case_root/state/plugins"
    state_dir="$state_root/herdrgo"
    legacy_state_dir="$state_root/kkrainbow.herdrgo"
    config_root="$case_root/config/plugins/config"
    config_dir="$config_root/herdrgo"
    legacy_config_dir="$config_root/kkrainbow.herdrgo"
    home_dir="$case_root/home"
    socket_path="$test_root/legacy-id-conflict.sock"
    service_log="$case_root/service.log"
    herdr_log="$case_root/herdr.log"
    legacy_plist="$home_dir/Library/LaunchAgents/kkrainbow.herdrgo.plist"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" \
        "$state_dir" "$legacy_state_dir" "$config_dir" \
        "$legacy_config_dir" "$(dirname -- "$legacy_plist")"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" conflict
    printf 'new-secret\n' > "$state_dir/easytier_secret"
    printf 'legacy-secret\n' > "$legacy_state_dir/easytier_secret"
    printf 'HERDRGO_BRIDGE_POLL_MS=500\n' > "$config_dir/env"
    printf 'HERDRGO_BRIDGE_POLL_MS=750\n' > "$legacy_config_dir/env"
    printf 'legacy plist\n' > "$legacy_plist"
    start_socket "$socket_path"

    if PATH="$fake_bin:$PATH" FAKE_OS=Darwin FAKE_SERVICE_LOG="$service_log" \
        FAKE_HERDR_LOG="$herdr_log" HOME="$home_dir" USER=tester \
        HERDR_PLUGIN_ID=herdrgo HERDR_PLUGIN_ROOT="$plugin_root" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDR_PLUGIN_CONFIG_DIR="$config_dir" HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null 2>&1; then
        fail "conflicting plugin ID data unexpectedly migrated"
    fi

    assert_contains "$state_dir/easytier_secret" new-secret
    assert_contains "$legacy_state_dir/easytier_secret" legacy-secret
    assert_contains "$config_dir/env" 'HERDRGO_BRIDGE_POLL_MS=500'
    assert_contains "$legacy_config_dir/env" 'HERDRGO_BRIDGE_POLL_MS=750'
    assert_file "$legacy_plist"
    assert_not_file "$home_dir/Library/LaunchAgents/dev.herdr.herdrgo.plist"
    assert_not_file "$service_log"
    assert_not_file "$herdr_log"
}

test_legacy_id_active_lock() {
    case_root="$test_root/legacy-id-active-lock"
    plugin_root="$case_root/plugin"
    state_root="$case_root/state/plugins"
    state_dir="$state_root/herdrgo"
    legacy_state_dir="$state_root/kkrainbow.herdrgo"
    config_root="$case_root/config/plugins/config"
    config_dir="$config_root/herdrgo"
    legacy_config_dir="$config_root/kkrainbow.herdrgo"
    home_dir="$case_root/home"
    socket_path="$test_root/legacy-id-active-lock.sock"
    service_log="$case_root/service.log"
    herdr_log="$case_root/herdr.log"
    active_owner="$legacy_state_dir/.control.lock.$$"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" "$state_dir" \
        "$active_owner" "$config_dir" "$legacy_config_dir" "$home_dir"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" locked
    printf '%s\n' "$$" > "$active_owner/pid"
    ln -s "$(basename -- "$active_owner")" "$legacy_state_dir/control.lock"
    printf 'legacy-secret\n' > "$legacy_state_dir/easytier_secret"
    : > "$legacy_config_dir/env"
    start_socket "$socket_path"

    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        FAKE_HERDR_LOG="$herdr_log" FAKE_LEGACY_PLUGIN_INSTALLED=yes \
        HOME="$home_dir" USER=tester HERDR_PLUGIN_ID=herdrgo \
        HERDR_PLUGIN_ROOT="$plugin_root" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDR_PLUGIN_CONFIG_DIR="$config_dir" HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null 2>&1; then
        fail "legacy migration ignored an active control lock"
    fi

    assert_contains "$legacy_state_dir/easytier_secret" legacy-secret
    assert_contains "$herdr_log" "herdr plugin disable kkrainbow.herdrgo"
    assert_contains "$herdr_log" "herdr plugin enable kkrainbow.herdrgo"
    assert_not_file "$service_log"
    [ "$(readlink "$legacy_state_dir/control.lock")" = \
        "$(basename -- "$active_owner")" ] ||
        fail "failed migration changed the active legacy lock"
}

test_legacy_id_rollback() {
    case_root="$test_root/legacy-id-rollback"
    plugin_root="$case_root/plugin"
    state_root="$case_root/state/plugins"
    state_dir="$state_root/herdrgo"
    legacy_state_dir="$state_root/kkrainbow.herdrgo"
    config_root="$case_root/config/plugins/config"
    config_dir="$config_root/herdrgo"
    legacy_config_dir="$config_root/kkrainbow.herdrgo"
    home_dir="$case_root/home"
    socket_path="$test_root/legacy-id-rollback.sock"
    service_log="$case_root/service.log"
    herdr_log="$case_root/herdr.log"
    failure_marker="$case_root/restart-failed"
    unit="$home_dir/.config/systemd/user/herdrgo-bridge.service"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" "$state_dir" \
        "$legacy_state_dir/runtime" "$config_dir" "$legacy_config_dir" \
        "$(dirname -- "$unit")"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" candidate
    make_bridge "$legacy_state_dir/runtime/herdrgo-bridge" legacy
    cp "$repo_root/plugin/herdrgo-ctl.sh" \
        "$legacy_state_dir/runtime/herdrgo-ctl.sh"
    chmod 755 "$legacy_state_dir/runtime/herdrgo-ctl.sh"
    printf 'legacy-secret\n' > "$legacy_state_dir/easytier_secret"
    printf 'HERDRGO_BRIDGE_POLL_MS=750\n' > "$legacy_config_dir/env"
    printf 'legacy unit\n' > "$unit"
    start_socket "$socket_path"

    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        FAKE_SERVICE_RESTART_FAIL_ONCE=yes \
        FAKE_SERVICE_FAILURE_MARKER="$failure_marker" \
        FAKE_HERDR_LOG="$herdr_log" FAKE_LEGACY_PLUGIN_INSTALLED=yes \
        HOME="$home_dir" USER=tester HERDR_PLUGIN_ID=herdrgo \
        HERDR_PLUGIN_ROOT="$plugin_root" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDR_PLUGIN_CONFIG_DIR="$config_dir" HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null 2>&1; then
        fail "failed replacement service did not roll back migration"
    fi

    assert_not_dir "$state_dir"
    assert_not_dir "$config_dir"
    assert_contains "$legacy_state_dir/easytier_secret" legacy-secret
    assert_contains "$legacy_config_dir/env" 'HERDRGO_BRIDGE_POLL_MS=750'
    output=$("$legacy_state_dir/runtime/herdrgo-bridge" --version)
    [ "$output" = "herdrgo-bridge legacy" ] ||
        fail "rollback did not restore the legacy bridge"
    assert_contains "$legacy_state_dir/runtime/plugin-config-dir" \
        "$legacy_config_dir"
    assert_contains "$unit" "legacy unit"
    assert_contains "$herdr_log" "herdr plugin enable kkrainbow.herdrgo"
    restart_count=$(grep -c 'restart herdrgo-bridge.service' "$service_log")
    [ "$restart_count" -eq 2 ] || fail "rollback did not restart the legacy service"
}

test_signal_stops_control() {
    case_root="$test_root/signal"
    plugin_root="$case_root/plugin"
    state_dir="$case_root/state"
    config_dir="$case_root/config"
    home_dir="$case_root/home"
    socket_path="$test_root/signal.sock"
    service_log="$case_root/service.log"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" "$config_dir" "$home_dir"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" signal
    start_socket "$socket_path"

    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        FAKE_SERVICE_TERM_ON_RELOAD=yes HOME="$home_dir" USER=tester \
        HERDR_PLUGIN_ROOT="$plugin_root" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDR_PLUGIN_CONFIG_DIR="$config_dir" HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null 2>&1; then
        fail "setup survived TERM and continued without its control lock"
    fi
    assert_contains "$service_log" "systemctl --user daemon-reload"
    assert_not_contains "$service_log" "systemctl --user enable"
    assert_not_contains "$service_log" "systemctl --user restart"
    [ ! -d "$state_dir/control.lock" ] || fail "signal did not clean the control lock"
}

test_signal_cleans_atomic_lock_claim() {
    case_root="$test_root/lock-signal"
    plugin_root="$case_root/plugin"
    state_dir="$case_root/state"
    config_dir="$case_root/config"
    home_dir="$case_root/home"
    socket_path="$test_root/lock-signal.sock"
    service_log="$case_root/service.log"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" "$config_dir" "$home_dir"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" lock-signal
    start_socket "$socket_path"

    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        FAKE_LOCK_TERM_ON_ACQUIRE=yes HOME="$home_dir" USER=tester \
        HERDR_PLUGIN_ROOT="$plugin_root" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDR_PLUGIN_CONFIG_DIR="$config_dir" HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null 2>&1; then
        fail "setup survived TERM at the atomic lock claim"
    fi
    [ ! -e "$state_dir/control.lock" ] && [ ! -L "$state_dir/control.lock" ] ||
        fail "TERM at lock claim left control.lock behind"
    for owner in "$state_dir"/.control.lock.*; do
        [ ! -e "$owner" ] || fail "TERM at lock claim left its owner behind"
    done
}

test_linux_control() {
    case_root="$test_root/linux case"
    plugin_root="$case_root/plugin"
    state_dir="$case_root/state dir"
    config_dir="$case_root/config dir"
    home_dir="$case_root/home"
    socket_path="$test_root/linux.sock"
    service_log="$case_root/service.log"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" "$config_dir" "$home_dir"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" v1
    printf 'HERDRGO_BRIDGE_SECRET=do-not-copy\n' > "$config_dir/env"
    start_socket "$socket_path"

    output="$case_root/setup.out"
    PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        HOME="$home_dir" USER=tester HERDR_PLUGIN_ROOT="$plugin_root" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
        HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup > "$output"

    unit="$home_dir/.config/systemd/user/herdrgo-bridge.service"
    assert_file "$unit"
    assert_file "$state_dir/runtime/herdrgo-bridge"
    assert_contains "$unit" "$state_dir/runtime/herdrgo-bridge"
    assert_contains "$unit" "HERDRGO_BRIDGE_ENV_FILE=$config_dir/env"
    assert_contains "$unit" "HERDR_BIN_PATH=$fake_bin/herdr"
    assert_not_contains "$unit" do-not-copy
    assert_contains "$output" PAIRING-v1
    assert_contains "$service_log" "systemctl --user daemon-reload"
    assert_contains "$service_log" "systemctl --user restart herdrgo-bridge.service"

    printf 'stable-secret\n' > "$state_dir/easytier_secret"
    make_bridge "$plugin_root/bin/herdrgo-bridge" v2
    PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        HOME="$home_dir" USER=tester HERDR_PLUGIN_ROOT="$plugin_root" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
        HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null
    assert_contains "$state_dir/runtime/herdrgo-bridge.previous" "herdrgo-bridge v1"
    [ "$(sed -n '1p' "$state_dir/easytier_secret")" = stable-secret ] ||
        fail "setup changed the EasyTier secret"

    mkdir "$state_dir/control.lock"
    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        HOME="$home_dir" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" restart >/dev/null 2>&1; then
        fail "a control lock without a pid was reclaimed"
    fi
    [ -d "$state_dir/control.lock" ] || fail "a contender removed the active control lock"
    rmdir "$state_dir/control.lock"

    active_owner="$state_dir/.control.lock.$$"
    mkdir "$active_owner"
    printf '%s\n' "$$" > "$active_owner/pid"
    ln -s "$(basename -- "$active_owner")" "$state_dir/control.lock"
    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        HOME="$home_dir" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" restart >/dev/null 2>&1; then
        fail "a live atomic control lock did not exclude a contender"
    fi
    [ "$(readlink "$state_dir/control.lock")" = "$(basename -- "$active_owner")" ] ||
        fail "a contender replaced the live atomic control lock"
    rm -f "$state_dir/control.lock" "$active_owner/pid"
    rmdir "$active_owner"

    if PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        FAKE_SERVICE_STOP_FAIL=yes HOME="$home_dir" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" HERDRGO_UNINSTALL_CONFIRM=yes \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" uninstall-service >/dev/null 2>&1; then
        fail "Linux uninstall ignored a service stop failure"
    fi
    assert_file "$unit"
    assert_file "$state_dir/runtime/herdrgo-bridge"

    PATH="$fake_bin:$PATH" FAKE_OS=Linux FAKE_SERVICE_LOG="$service_log" \
        HOME="$home_dir" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDRGO_UNINSTALL_CONFIRM=yes \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" uninstall-service >/dev/null
    assert_not_file "$unit"
    assert_not_file "$state_dir/runtime/herdrgo-bridge"
    assert_file "$state_dir/easytier_secret"
}

test_macos_control() {
    case_root="$test_root/mac & case"
    plugin_root="$case_root/plugin"
    state_root="$case_root/state & root/plugins"
    state_dir="$state_root/herdrgo"
    legacy_state_dir="$state_root/kkrainbow.herdrgo"
    config_root="$case_root/config & root/plugins/config"
    config_dir="$config_root/herdrgo"
    legacy_config_dir="$config_root/kkrainbow.herdrgo"
    home_dir="$case_root/home"
    socket_path="$test_root/macos.sock"
    service_log="$case_root/service.log"
    herdr_log="$case_root/herdr.log"
    legacy_plist="$home_dir/Library/LaunchAgents/kkrainbow.herdrgo.plist"
    mkdir -p "$plugin_root/bin" "$plugin_root/plugin" \
        "$state_dir" "$legacy_state_dir" "$config_dir" "$legacy_config_dir" \
        "$(dirname -- "$legacy_plist")"
    cp "$repo_root/plugin/herdrgo-ctl.sh" "$plugin_root/plugin/herdrgo-ctl.sh"
    make_bridge "$plugin_root/bin/herdrgo-bridge" mac
    printf 'mac-secret\n' > "$legacy_state_dir/easytier_secret"
    printf 'HERDRGO_BRIDGE_SECRET=do-not-copy\n' > "$legacy_config_dir/env"
    printf 'legacy plist\n' > "$legacy_plist"
    start_socket "$socket_path"

    PATH="$fake_bin:$PATH" FAKE_OS=Darwin FAKE_SERVICE_LOG="$service_log" \
        FAKE_HERDR_LOG="$herdr_log" FAKE_LEGACY_PLUGIN_INSTALLED=yes \
        HOME="$home_dir" \
        HERDR_PLUGIN_ID=herdrgo HERDR_PLUGIN_ROOT="$plugin_root" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" HERDR_PLUGIN_CONFIG_DIR="$config_dir" \
        HERDR_SOCKET_PATH="$socket_path" \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" setup >/dev/null

    plist="$home_dir/Library/LaunchAgents/dev.herdr.herdrgo.plist"
    assert_file "$plist"
    assert_not_file "$legacy_plist"
    assert_contains "$plist" "dev.herdr.herdrgo.bridge"
    assert_contains "$plist" "state &amp; root/plugins/herdrgo/runtime/herdrgo-bridge"
    assert_contains "$plist" "config &amp; root/plugins/config/herdrgo/env"
    assert_contains "$plist" "$fake_bin/herdr"
    assert_not_contains "$plist" do-not-copy
    assert_contains "$state_dir/easytier_secret" mac-secret
    assert_contains "$config_dir/env" 'HERDRGO_BRIDGE_SECRET=do-not-copy'
    assert_contains "$service_log" \
        "launchctl bootout gui/$(id -u)/kkrainbow.herdrgo.bridge"
    assert_contains "$service_log" "launchctl bootstrap"
    assert_contains "$herdr_log" "herdr plugin uninstall kkrainbow.herdrgo"
    if command -v plutil >/dev/null 2>&1; then
        plutil -lint "$plist" >/dev/null
    fi

    if PATH="$fake_bin:$PATH" FAKE_OS=Darwin FAKE_SERVICE_LOG="$service_log" \
        FAKE_SERVICE_STOP_FAIL=yes HOME="$home_dir" \
        HERDR_PLUGIN_STATE_DIR="$state_dir" HERDRGO_UNINSTALL_CONFIRM=yes \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" uninstall-service >/dev/null 2>&1; then
        fail "macOS uninstall ignored a service stop failure"
    fi
    assert_file "$plist"
    assert_file "$state_dir/runtime/herdrgo-bridge"

    PATH="$fake_bin:$PATH" FAKE_OS=Darwin FAKE_SERVICE_LOG="$service_log" \
        HOME="$home_dir" HERDR_PLUGIN_STATE_DIR="$state_dir" \
        HERDRGO_UNINSTALL_CONFIRM=yes \
        sh "$plugin_root/plugin/herdrgo-ctl.sh" uninstall-service >/dev/null
    assert_not_file "$plist"
}

test_static_systemd_unit() {
    unit="$repo_root/bridge/systemd/herdrgo-bridge.service"
    assert_contains "$unit" 'Environment=HERDR_BIN_PATH=%h/.local/bin/herdr'
}

test_install
test_action
test_legacy_id_migration
test_legacy_id_conflict
test_legacy_id_active_lock
test_legacy_id_rollback
test_signal_cleans_atomic_lock_claim
test_signal_stops_control
test_linux_control
test_macos_control
test_static_systemd_unit
printf 'plugin tests passed\n'
