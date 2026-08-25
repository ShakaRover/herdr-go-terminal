#!/bin/sh
set -eu

service_name=herdrgo-bridge.service
launch_label=kkrainbow.herdrgo.bridge
launch_plist_name=kkrainbow.herdrgo.plist
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
platform_name=$(uname -s)
case "$platform_name" in
    Linux | Darwin) ;;
    *)
        printf 'HerdrGo: unsupported platform: %s\n' "$platform_name" >&2
        exit 1
        ;;
esac

pause_for_close() {
    if [ -t 0 ]; then
        printf '\nPress Enter to close this pane...'
        IFS= read -r _ || true
    fi
}

fail() {
    printf 'HerdrGo: %s\n' "$*" >&2
    pause_for_close
    exit 1
}

state_dir=${HERDR_PLUGIN_STATE_DIR:-}
if [ -z "$state_dir" ] && [ "$(basename -- "$script_dir")" = runtime ]; then
    state_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi
[ -n "$state_dir" ] || fail "HERDR_PLUGIN_STATE_DIR is not available"

runtime_dir="$state_dir/runtime"
runtime_bridge="$runtime_dir/herdrgo-bridge"
runtime_ctl="$runtime_dir/herdrgo-ctl.sh"
metadata_config_dir="$runtime_dir/plugin-config-dir"
metadata_socket_path="$runtime_dir/herdr-socket-path"
lock_dir="$state_dir/control.lock"
lock_held=false

cleanup_lock() {
    if [ "$lock_held" = true ]; then
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null || true
        lock_held=false
    fi
}
trap cleanup_lock EXIT HUP INT TERM

acquire_lock() {
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    if ! mkdir "$lock_dir" 2>/dev/null; then
        old_pid=
        [ ! -f "$lock_dir/pid" ] || old_pid=$(sed -n '1p' "$lock_dir/pid")
        case "$old_pid" in
            '' | *[!0-9]*) ;;
            *)
                if kill -0 "$old_pid" 2>/dev/null; then
                    fail "another service operation is already running (pid $old_pid)"
                fi
                ;;
        esac
        rm -f "$lock_dir/pid"
        rmdir "$lock_dir" 2>/dev/null ||
            fail "cannot recover stale control lock: $lock_dir"
        mkdir "$lock_dir" 2>/dev/null ||
            fail "another service operation started concurrently"
    fi
    printf '%s\n' "$$" > "$lock_dir/pid"
    lock_held=true
}

read_metadata() {
    config_dir=${HERDR_PLUGIN_CONFIG_DIR:-}
    socket_path=${HERDR_SOCKET_PATH:-}
    if [ -z "$config_dir" ] && [ -f "$metadata_config_dir" ]; then
        config_dir=$(sed -n '1p' "$metadata_config_dir")
    fi
    if [ -z "$socket_path" ] && [ -f "$metadata_socket_path" ]; then
        socket_path=$(sed -n '1p' "$metadata_socket_path")
    fi
}

require_runtime() {
    [ -x "$runtime_bridge" ] ||
        fail "bridge is not installed; run: herdr plugin action invoke kkrainbow.herdrgo.setup"
    read_metadata
    [ -n "$config_dir" ] || fail "plugin config directory is unknown; run setup again"
    [ -n "$socket_path" ] || fail "Herdr socket path is unknown; run setup again"
}

export_bridge_env() {
    export HERDRGO_BRIDGE_STATE_DIR="$state_dir"
    export HERDRGO_BRIDGE_ENV_FILE="$config_dir/env"
    export HERDR_SOCKET_PATH="$socket_path"
}

install_runtime_file() {
    source_file=$1
    destination=$2
    mode=$3
    temporary="$destination.tmp.$$"
    previous="$destination.previous"
    previous_temporary="$previous.tmp.$$"

    cp "$source_file" "$temporary"
    chmod "$mode" "$temporary"
    if [ -f "$destination" ]; then
        cp "$destination" "$previous_temporary"
        chmod "$mode" "$previous_temporary"
        mv -f "$previous_temporary" "$previous"
    fi
    mv -f "$temporary" "$destination"
}

systemd_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g' -e 's/%/%%/g'
}

xml_escape() {
    printf '%s' "$1" | sed \
        -e 's/&/\&amp;/g' \
        -e 's/</\&lt;/g' \
        -e 's/>/\&gt;/g' \
        -e 's/"/\&quot;/g' \
        -e "s/'/\&apos;/g"
}

systemd_unit_path() {
    printf '%s/systemd/user/%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}" "$service_name"
}

launch_plist_path() {
    printf '%s/Library/LaunchAgents/%s\n' "$HOME" "$launch_plist_name"
}

write_systemd_unit() {
    unit=$(systemd_unit_path)
    mkdir -p "$(dirname -- "$unit")"
    temporary="$unit.tmp.$$"
    bridge_value=$(systemd_escape "$runtime_bridge")
    socket_value=$(systemd_escape "$socket_path")
    state_value=$(systemd_escape "$state_dir")
    env_value=$(systemd_escape "$config_dir/env")
    cat > "$temporary" <<EOF
[Unit]
Description=HerdrGo mobile bridge for Herdr
After=default.target
StartLimitIntervalSec=0

[Service]
Type=simple
ExecStart="$bridge_value"
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes
PrivateTmp=yes
Environment="HERDR_SOCKET_PATH=$socket_value"
Environment="HERDRGO_BRIDGE_STATE_DIR=$state_value"
Environment="HERDRGO_BRIDGE_ENV_FILE=$env_value"

[Install]
WantedBy=default.target
EOF
    chmod 600 "$temporary"
    mv -f "$temporary" "$unit"
}

write_launch_plist() {
    plist=$(launch_plist_path)
    mkdir -p "$(dirname -- "$plist")" "$state_dir/logs"
    temporary="$plist.tmp.$$"
    bridge_value=$(xml_escape "$runtime_bridge")
    socket_value=$(xml_escape "$socket_path")
    state_value=$(xml_escape "$state_dir")
    env_value=$(xml_escape "$config_dir/env")
    stdout_value=$(xml_escape "$state_dir/logs/bridge.stdout.log")
    stderr_value=$(xml_escape "$state_dir/logs/bridge.stderr.log")
    cat > "$temporary" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$launch_label</string>
  <key>ProgramArguments</key>
  <array>
    <string>$bridge_value</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>HERDR_SOCKET_PATH</key>
    <string>$socket_value</string>
    <key>HERDRGO_BRIDGE_STATE_DIR</key>
    <string>$state_value</string>
    <key>HERDRGO_BRIDGE_ENV_FILE</key>
    <string>$env_value</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key>
    <false/>
  </dict>
  <key>ThrottleInterval</key>
  <integer>5</integer>
  <key>StandardOutPath</key>
  <string>$stdout_value</string>
  <key>StandardErrorPath</key>
  <string>$stderr_value</string>
</dict>
</plist>
EOF
    chmod 600 "$temporary"
    mv -f "$temporary" "$plist"
}

service_is_running() {
    case "$platform_name" in
        Linux) systemctl --user is-active --quiet "$service_name" ;;
        Darwin)
            launchctl print "gui/$(id -u)/$launch_label" 2>/dev/null |
                grep -q 'state = running'
            ;;
    esac
}

service_status() {
    case "$platform_name" in
        Linux) systemctl --user --no-pager status "$service_name" ;;
        Darwin) launchctl print "gui/$(id -u)/$launch_label" ;;
    esac
}

service_start() {
    case "$platform_name" in
        Linux) systemctl --user enable --now "$service_name" ;;
        Darwin)
            domain="gui/$(id -u)"
            service="$domain/$launch_label"
            if launchctl print "$service" >/dev/null 2>&1; then
                launchctl kickstart -k "$service"
            else
                launchctl bootstrap "$domain" "$(launch_plist_path)"
            fi
            ;;
    esac
}

service_stop() {
    case "$platform_name" in
        Linux) systemctl --user stop "$service_name" ;;
        Darwin) launchctl bootout "gui/$(id -u)" "$(launch_plist_path)" ;;
    esac
}

service_restart() {
    case "$platform_name" in
        Linux) systemctl --user restart "$service_name" ;;
        Darwin)
            domain="gui/$(id -u)"
            service="$domain/$launch_label"
            if launchctl print "$service" >/dev/null 2>&1; then
                launchctl kickstart -k "$service"
            else
                launchctl bootstrap "$domain" "$(launch_plist_path)"
            fi
            ;;
    esac
}

service_install_and_restart() {
    case "$platform_name" in
        Linux)
            write_systemd_unit
            systemctl --user daemon-reload
            systemctl --user enable "$service_name"
            systemctl --user restart "$service_name"
            ;;
        Darwin)
            write_launch_plist
            domain="gui/$(id -u)"
            launchctl bootout "$domain" "$(launch_plist_path)" >/dev/null 2>&1 || true
            launchctl bootstrap "$domain" "$(launch_plist_path)"
            ;;
    esac
}

wait_for_service() {
    remaining=10
    while [ "$remaining" -gt 0 ]; do
        if service_is_running; then
            return 0
        fi
        sleep 1
        remaining=$((remaining - 1))
    done
    printf 'HerdrGo service failed to reach running state.\n' >&2
    service_status >&2 || true
    case "$platform_name" in
        Linux) printf 'Logs: journalctl --user -u %s -n 100\n' "$service_name" >&2 ;;
        Darwin) printf 'Logs: %s/logs/bridge.stderr.log\n' "$state_dir" >&2 ;;
    esac
    [ ! -x "$runtime_bridge.previous" ] ||
        printf 'Previous bridge: %s\n' "$runtime_bridge.previous" >&2
    return 1
}

setup_service() {
    : "${HERDR_PLUGIN_ROOT:?Herdr did not provide HERDR_PLUGIN_ROOT}"
    : "${HERDR_PLUGIN_CONFIG_DIR:?Herdr did not provide HERDR_PLUGIN_CONFIG_DIR}"
    : "${HERDR_SOCKET_PATH:?Herdr did not provide HERDR_SOCKET_PATH}"
    candidate="$HERDR_PLUGIN_ROOT/bin/herdrgo-bridge"
    control_script="$HERDR_PLUGIN_ROOT/plugin/herdrgo-ctl.sh"
    [ -x "$candidate" ] || fail "candidate bridge is missing; reinstall the plugin"
    [ -f "$control_script" ] || fail "plugin control script is missing"
    [ -S "$HERDR_SOCKET_PATH" ] || fail "Herdr socket is unavailable: $HERDR_SOCKET_PATH"

    acquire_lock
    umask 077
    mkdir -p "$runtime_dir" "$HERDR_PLUGIN_CONFIG_DIR" "$state_dir/logs"
    chmod 700 "$runtime_dir" "$HERDR_PLUGIN_CONFIG_DIR" "$state_dir/logs"
    if [ ! -f "$HERDR_PLUGIN_CONFIG_DIR/env" ]; then
        : > "$HERDR_PLUGIN_CONFIG_DIR/env"
    fi
    chmod 600 "$HERDR_PLUGIN_CONFIG_DIR/env"

    install_runtime_file "$candidate" "$runtime_bridge" 755
    install_runtime_file "$control_script" "$runtime_ctl" 755
    printf '%s\n' "$HERDR_PLUGIN_CONFIG_DIR" > "$metadata_config_dir"
    printf '%s\n' "$HERDR_SOCKET_PATH" > "$metadata_socket_path"
    chmod 600 "$metadata_config_dir" "$metadata_socket_path"
    read_metadata
    export_bridge_env
    "$runtime_bridge" --version
    service_install_and_restart
    wait_for_service

    if [ "$platform_name" = Linux ] && command -v loginctl >/dev/null 2>&1; then
        if ! loginctl show-user "${USER:-$(id -un)}" -p Linger 2>/dev/null |
            grep -q '^Linger=yes$'; then
            printf '\nNote: this user service stops after logout unless an administrator enables linger.\n'
        fi
    fi

    printf '\nHerdrGo bridge is running. Scan this code from the mobile app:\n\n'
    "$runtime_bridge" pair || fail "could not generate pairing information"
    pause_for_close
}

pair_bridge() {
    require_runtime
    export_bridge_env
    "$runtime_bridge" pair || fail "could not generate pairing information"
    pause_for_close
}

status_bridge() {
    require_runtime
    printf 'Version: '
    "$runtime_bridge" --version
    printf 'Runtime: %s\n' "$runtime_bridge"
    printf 'State:   %s\n' "$state_dir"
    printf 'Config:  %s\n\n' "$config_dir/env"
    service_status || true
    pause_for_close
}

uninstall_service() {
    answer=${HERDRGO_UNINSTALL_CONFIRM:-}
    if [ "$answer" != yes ]; then
        printf 'Remove the HerdrGo user service? Pairing state will be kept. [y/N] '
        IFS= read -r answer || answer=
    fi
    case "$answer" in
        y | Y | yes | YES) ;;
        *) printf 'Cancelled.\n'; pause_for_close; return 0 ;;
    esac

    acquire_lock
    case "$platform_name" in
        Linux)
            systemctl --user disable --now "$service_name" 2>/dev/null || true
            unit=$(systemd_unit_path)
            rm -f "$unit"
            systemctl --user daemon-reload
            ;;
        Darwin)
            launchctl bootout "gui/$(id -u)" "$(launch_plist_path)" 2>/dev/null || true
            rm -f "$(launch_plist_path)"
            ;;
    esac
    rm -f \
        "$runtime_bridge" "$runtime_bridge.previous" \
        "$runtime_ctl" "$runtime_ctl.previous" \
        "$metadata_config_dir" "$metadata_socket_path"
    rmdir "$runtime_dir" 2>/dev/null || true
    printf 'HerdrGo service removed. Pairing state remains in %s\n' "$state_dir"
    pause_for_close
}

command=${1:-}
case "$command" in
    setup) setup_service ;;
    pair) pair_bridge ;;
    status) status_bridge ;;
    start)
        require_runtime
        acquire_lock
        service_start
        ;;
    stop)
        require_runtime
        acquire_lock
        service_stop
        ;;
    restart)
        require_runtime
        acquire_lock
        service_restart
        ;;
    uninstall-service) uninstall_service ;;
    *) fail "usage: $0 {setup|pair|status|start|stop|restart|uninstall-service}" ;;
esac
