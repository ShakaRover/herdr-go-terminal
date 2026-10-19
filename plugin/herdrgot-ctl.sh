#!/bin/sh
set -eu

service_name=herdrgot-bridge.service
plugin_id=herdrgot
legacy_plugin_id=
# 独立于上游 herdrgo 的 launchd 标识，避免两个 bridge 互相覆盖。
launch_label=kkrainbow.herdrgot.bridge
launch_plist_name=kkrainbow.herdrgot.plist
legacy_alias_active=false
script_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
platform_name=$(uname -s)
case "$platform_name" in
    Linux | Darwin) ;;
    *)
        printf 'HerdrGoT: unsupported platform: %s\n' "$platform_name" >&2
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
    printf 'HerdrGoT: %s\n' "$*" >&2
    pause_for_close
    exit 1
}

state_dir=${HERDR_PLUGIN_STATE_DIR:-}
if [ -z "$state_dir" ] && [ "$(basename -- "$script_dir")" = runtime ]; then
    state_dir=$(CDPATH= cd -- "$script_dir/.." && pwd)
fi
[ -n "$state_dir" ] || fail "HERDR_PLUGIN_STATE_DIR is not available"

runtime_dir="$state_dir/runtime"
runtime_bridge="$runtime_dir/herdrgot-bridge"
runtime_ctl="$runtime_dir/herdrgot-ctl.sh"
metadata_config_dir="$runtime_dir/plugin-config-dir"
metadata_socket_path="$runtime_dir/herdr-socket-path"
metadata_herdr_bin_path="$runtime_dir/herdr-bin-path"
lock_dir="$state_dir/control.lock"
lock_owner_name=".control.lock.$$"
lock_owner_dir="$state_dir/$lock_owner_name"

cleanup_lock() {
    current_owner=
    if [ -L "$lock_dir" ]; then
        current_owner=$(readlink "$lock_dir" 2>/dev/null || true)
    fi
    if [ "$current_owner" = "$lock_owner_name" ]; then
        rm -f "$lock_dir" 2>/dev/null || true
    fi
    # POSIX ln treats an existing directory as a destination directory. If a
    # contender appeared between our checks, remove only the nested link whose
    # process-unique name and target both belong to this invocation.
    nested_lock="$lock_dir/$lock_owner_name"
    nested_owner=
    if [ -L "$nested_lock" ]; then
        nested_owner=$(readlink "$nested_lock" 2>/dev/null || true)
    fi
    if [ "$nested_owner" = "$lock_owner_name" ]; then
        rm -f "$nested_lock" 2>/dev/null || true
    fi
    rm -f "$lock_owner_dir/pid" 2>/dev/null || true
    rmdir "$lock_owner_dir" 2>/dev/null || true
}
trap cleanup_lock EXIT
# A signal trap that only returns would let the interrupted operation continue
# after releasing its lock. Exit explicitly; the EXIT trap performs cleanup.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock() {
    mkdir -p "$state_dir"
    chmod 700 "$state_dir"
    # Prepare a complete, process-unique owner before atomically publishing it
    # as control.lock. cleanup_lock can identify this owner even if a signal is
    # delivered immediately after ln succeeds, so there is no lock_held window.
    mkdir "$lock_owner_dir" 2>/dev/null ||
        fail "stale control lock owner: $lock_owner_dir"
    chmod 700 "$lock_owner_dir"
    printf '%s\n' "$$" > "$lock_owner_dir/pid"
    chmod 600 "$lock_owner_dir/pid"

    lock_acquired=false
    if ln -s "$lock_owner_name" "$lock_dir" 2>/dev/null; then
        published_owner=
        if [ -L "$lock_dir" ]; then
            published_owner=$(readlink "$lock_dir" 2>/dev/null || true)
        fi
        if [ "$published_owner" = "$lock_owner_name" ]; then
            lock_acquired=true
        fi
    fi

    if [ "$lock_acquired" != true ]; then
        old_pid=
        if [ -L "$lock_dir" ]; then
            old_owner=$(readlink "$lock_dir" 2>/dev/null || true)
            old_owner_pid=${old_owner#.control.lock.}
            case "$old_owner_pid" in
                '' | *[!0-9]*) ;;
                *)
                    [ ! -f "$state_dir/$old_owner/pid" ] ||
                        old_pid=$(sed -n '1p' "$state_dir/$old_owner/pid")
                    ;;
            esac
        elif [ -f "$lock_dir/pid" ]; then
            # Recognize the directory lock used by older plugin versions, but
            # never reclaim it automatically.
            old_pid=$(sed -n '1p' "$lock_dir/pid")
        fi
        case "$old_pid" in
            '' | *[!0-9]*) ;;
            *)
                if kill -0 "$old_pid" 2>/dev/null; then
                    fail "another service operation is already running (pid $old_pid)"
                fi
                ;;
        esac
        # Do not reclaim a stale-looking lock automatically. Deleting it after
        # a separate read would let two contenders remove a newly acquired lock.
        fail "stale control lock: $lock_dir (confirm no operation is running, then remove the link and its target)"
    fi
}

read_metadata() {
    config_dir=${HERDR_PLUGIN_CONFIG_DIR:-}
    socket_path=${HERDR_SOCKET_PATH:-}
    herdr_bin_path=${HERDR_BIN_PATH:-}
    if [ -z "$config_dir" ] && [ -f "$metadata_config_dir" ]; then
        config_dir=$(sed -n '1p' "$metadata_config_dir")
    fi
    if [ -z "$socket_path" ] && [ -f "$metadata_socket_path" ]; then
        socket_path=$(sed -n '1p' "$metadata_socket_path")
    fi
    if [ -z "$herdr_bin_path" ] && [ -f "$metadata_herdr_bin_path" ]; then
        herdr_bin_path=$(sed -n '1p' "$metadata_herdr_bin_path")
    fi
    if [ -z "$herdr_bin_path" ]; then
        herdr_bin_path=$(command -v herdr 2>/dev/null || true)
    fi
}

require_runtime() {
    [ -x "$runtime_bridge" ] ||
        fail "bridge is not installed; run: herdr plugin action invoke $plugin_id.setup"
    read_metadata
    [ -n "$config_dir" ] || fail "plugin config directory is unknown; run setup again"
    [ -n "$socket_path" ] || fail "Herdr socket path is unknown; run setup again"
}

export_bridge_env() {
    export HERDRGOT_BRIDGE_STATE_DIR="$state_dir"
    export HERDRGOT_BRIDGE_ENV_FILE="$config_dir/env"
    export HERDR_SOCKET_PATH="$socket_path"
    export HERDR_BIN_PATH="$herdr_bin_path"
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

directory_is_empty() {
    directory=$1
    [ -d "$directory" ] || return 0
    for entry in "$directory"/.[!.]* "$directory"/..?* "$directory"/*; do
        if [ -e "$entry" ] || [ -L "$entry" ]; then
            return 1
        fi
    done
    return 0
}

alias_destination_is_available() {
    source=$1
    destination=$2
    label=$3
    [ -d "$source" ] || return 0
    if [ -L "$destination" ]; then
        [ "$(readlink "$destination")" = "$source" ] ||
            fail "$label path points somewhere unexpected: $destination"
        return 0
    fi
    if [ -e "$destination" ] && ! directory_is_empty "$destination"; then
        fail "$label already contains data: $destination"
    fi
}

create_legacy_alias() {
    source=$1
    destination=$2
    [ -d "$source" ] || return 0
    if [ ! -L "$destination" ]; then
        mkdir -p "$(dirname -- "$destination")"
        [ ! -d "$destination" ] || rmdir "$destination"
        ln -s "$source" "$destination" ||
            fail "could not create compatibility alias: $destination"
    fi
    legacy_alias_active=true
}

ensure_legacy_aliases() {
    [ -n "$legacy_plugin_id" ] || return 0
    [ "${HERDR_PLUGIN_ID:-}" = "$plugin_id" ] || return 0
    legacy_state_dir="$(dirname -- "$state_dir")/$legacy_plugin_id"
    legacy_config_dir="$(dirname -- "$HERDR_PLUGIN_CONFIG_DIR")/$legacy_plugin_id"
    if [ ! -d "$legacy_state_dir" ] && [ ! -d "$legacy_config_dir" ]; then
        return 0
    fi

    alias_destination_is_available "$legacy_state_dir" "$state_dir" "state"
    alias_destination_is_available \
        "$legacy_config_dir" "$HERDR_PLUGIN_CONFIG_DIR" "config"
    create_legacy_alias "$legacy_state_dir" "$state_dir"
    create_legacy_alias "$legacy_config_dir" "$HERDR_PLUGIN_CONFIG_DIR"
    printf 'HerdrGoT: using existing pairing data through the new plugin ID.\n'
}

unregister_legacy_plugin() {
    [ "$legacy_alias_active" = true ] || return 0
    if ! "$herdr_bin_path" plugin uninstall "$legacy_plugin_id" >/dev/null 2>&1; then
        printf 'HerdrGoT: the previous plugin registration could not be removed.\n' >&2
    fi
}

write_systemd_unit() {
    unit=$(systemd_unit_path)
    mkdir -p "$(dirname -- "$unit")"
    temporary="$unit.tmp.$$"
    bridge_value=$(systemd_escape "$runtime_bridge")
    socket_value=$(systemd_escape "$socket_path")
    herdr_bin_value=$(systemd_escape "$herdr_bin_path")
    state_value=$(systemd_escape "$state_dir")
    env_value=$(systemd_escape "$config_dir/env")
    cat > "$temporary" <<EOF
[Unit]
Description=HerdrGoT mobile bridge for Herdr
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
Environment="HERDR_BIN_PATH=$herdr_bin_value"
Environment="HERDRGOT_BRIDGE_STATE_DIR=$state_value"
Environment="HERDRGOT_BRIDGE_ENV_FILE=$env_value"

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
    herdr_bin_value=$(xml_escape "$herdr_bin_path")
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
    <key>HERDR_BIN_PATH</key>
    <string>$herdr_bin_value</string>
    <key>HERDRGOT_BRIDGE_STATE_DIR</key>
    <string>$state_value</string>
    <key>HERDRGOT_BRIDGE_ENV_FILE</key>
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
    printf 'HerdrGoT service failed to reach running state.\n' >&2
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
    candidate="$HERDR_PLUGIN_ROOT/bin/herdrgot-bridge"
    control_script="$HERDR_PLUGIN_ROOT/plugin/herdrgot-ctl.sh"
    [ -x "$candidate" ] || fail "candidate bridge is missing; reinstall the plugin"
    [ -f "$control_script" ] || fail "plugin control script is missing"
    [ -S "$HERDR_SOCKET_PATH" ] || fail "Herdr socket is unavailable: $HERDR_SOCKET_PATH"
    read_metadata
    [ -x "$herdr_bin_path" ] || fail "Herdr executable is unavailable"

    ensure_legacy_aliases
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
    printf '%s\n' "$herdr_bin_path" > "$metadata_herdr_bin_path"
    chmod 600 "$metadata_config_dir" "$metadata_socket_path" "$metadata_herdr_bin_path"
    read_metadata
    export_bridge_env
    "$runtime_bridge" --version
    service_install_and_restart
    wait_for_service
    unregister_legacy_plugin

    if [ "$platform_name" = Linux ] && command -v loginctl >/dev/null 2>&1; then
        if ! loginctl show-user "${USER:-$(id -un)}" -p Linger 2>/dev/null |
            grep -q '^Linger=yes$'; then
            printf '\nNote: this user service stops after logout unless an administrator enables linger.\n'
        fi
    fi

    printf '\nHerdrGoT bridge is running. Scan this code from the mobile app:\n\n'
    "$runtime_bridge" pair || fail "could not generate pairing information"
    pause_for_close
}

pair_bridge() {
    require_runtime
    export_bridge_env
    case "${2:-}" in
        --string) "$runtime_bridge" pair --string ;;
        *) "$runtime_bridge" pair ;;
    esac
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
    answer=${HERDRGOT_UNINSTALL_CONFIRM:-}
    if [ "$answer" != yes ]; then
        printf 'Remove the HerdrGoT user service? Pairing state will be kept. [y/N] '
        IFS= read -r answer || answer=
    fi
    case "$answer" in
        y | Y | yes | YES) ;;
        *) printf 'Cancelled.\n'; pause_for_close; return 0 ;;
    esac

    acquire_lock
    case "$platform_name" in
        Linux)
            unit=$(systemd_unit_path)
            if [ -f "$unit" ] || systemctl --user is-active --quiet "$service_name"; then
                systemctl --user disable --now "$service_name" ||
                    fail "could not stop and disable $service_name"
            fi
            rm -f "$unit"
            systemctl --user daemon-reload || fail "could not reload the systemd user manager"
            ;;
        Darwin)
            domain="gui/$(id -u)"
            service="$domain/$launch_label"
            plist=$(launch_plist_path)
            if launchctl print "$service" >/dev/null 2>&1; then
                launchctl bootout "$domain" "$plist" ||
                    fail "could not unload $launch_label"
            fi
            rm -f "$plist"
            ;;
    esac
    rm -f \
        "$runtime_bridge" "$runtime_bridge.previous" \
        "$runtime_ctl" "$runtime_ctl.previous" \
        "$metadata_config_dir" "$metadata_socket_path" "$metadata_herdr_bin_path"
    rmdir "$runtime_dir" 2>/dev/null || true
    printf 'HerdrGoT service removed. Pairing state remains in %s\n' "$state_dir"
    pause_for_close
}

command=${1:-}
case "$command" in
    setup) setup_service ;;
    pair) pair_bridge "$@" ;;
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
