#!/bin/sh
set -eu

service_name=herdrgo-bridge.service
plugin_id=herdrgo
legacy_plugin_id=kkrainbow.herdrgo
launch_label=dev.herdr.herdrgo.bridge
launch_plist_name=dev.herdr.herdrgo.plist
legacy_launch_label=kkrainbow.herdrgo.bridge
legacy_launch_plist_name=kkrainbow.herdrgo.plist
legacy_migration_complete=false
legacy_migration_pending=false
legacy_state_present=false
legacy_config_present=false
legacy_service_was_running=false
legacy_service_stopped=false
legacy_unit_existed=false
legacy_unit_backup=
legacy_plugin_was_enabled=false
control_lock_acquired=false
runtime_bridge_replaced=false
runtime_bridge_existed=false
runtime_ctl_replaced=false
runtime_ctl_existed=false
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
    if [ "${legacy_migration_pending:-false}" = true ]; then
        cleanup_lock
        if ! rollback_legacy_migration; then
            printf 'HerdrGo: automatic migration rollback was incomplete.\n' >&2
        fi
    fi
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
metadata_herdr_bin_path="$runtime_dir/herdr-bin-path"
lock_owner_name=".control.lock.$$"
lock_state_dir=
lock_dir=
lock_owner_dir=
alternate_lock_dir=
alternate_lock_owner_dir=

cleanup_lock_at() {
    cleanup_lock_dir=$1
    cleanup_owner_dir=$2
    [ -n "$cleanup_lock_dir" ] || return 0
    current_owner=
    if [ -L "$cleanup_lock_dir" ]; then
        current_owner=$(readlink "$cleanup_lock_dir" 2>/dev/null || true)
    fi
    if [ "$current_owner" = "$lock_owner_name" ]; then
        rm -f "$cleanup_lock_dir" 2>/dev/null || true
    fi
    # POSIX ln treats an existing directory as a destination directory. If a
    # contender appeared between our checks, remove only the nested link whose
    # process-unique name and target both belong to this invocation.
    nested_lock="$cleanup_lock_dir/$lock_owner_name"
    nested_owner=
    if [ -L "$nested_lock" ]; then
        nested_owner=$(readlink "$nested_lock" 2>/dev/null || true)
    fi
    if [ "$nested_owner" = "$lock_owner_name" ]; then
        rm -f "$nested_lock" 2>/dev/null || true
    fi
    rm -f "$cleanup_owner_dir/pid" 2>/dev/null || true
    rmdir "$cleanup_owner_dir" 2>/dev/null || true
}

cleanup_lock() {
    cleanup_lock_at "$lock_dir" "$lock_owner_dir"
    if [ -n "$alternate_lock_dir" ] && [ "$alternate_lock_dir" != "$lock_dir" ]; then
        cleanup_lock_at "$alternate_lock_dir" "$alternate_lock_owner_dir"
    fi
}

finish() {
    status=$?
    cleanup_lock
    if [ "$status" -ne 0 ] && [ "$legacy_migration_pending" = true ]; then
        if ! rollback_legacy_migration; then
            printf 'HerdrGo: automatic migration rollback was incomplete.\n' >&2
        fi
    fi
    trap - EXIT
    exit "$status"
}
trap finish EXIT
# A signal trap that only returns would let the interrupted operation continue
# after releasing its lock. Exit explicitly; the EXIT trap performs cleanup.
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

acquire_lock() {
    lock_state_dir=${1:-$state_dir}
    lock_dir="$lock_state_dir/control.lock"
    lock_owner_dir="$lock_state_dir/$lock_owner_name"
    mkdir -p "$lock_state_dir"
    chmod 700 "$lock_state_dir"
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
                    [ ! -f "$lock_state_dir/$old_owner/pid" ] ||
                        old_pid=$(sed -n '1p' "$lock_state_dir/$old_owner/pid")
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
    control_lock_acquired=true
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
    export HERDRGO_BRIDGE_STATE_DIR="$state_dir"
    export HERDRGO_BRIDGE_ENV_FILE="$config_dir/env"
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

legacy_launch_plist_path() {
    printf '%s/Library/LaunchAgents/%s\n' "$HOME" "$legacy_launch_plist_name"
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

stop_legacy_service() {
    case "$platform_name" in
        Linux)
            unit=$(systemd_unit_path)
            if [ -f "$unit" ] || systemctl --user is-active --quiet "$service_name"; then
                systemctl --user stop "$service_name" ||
                    fail "could not stop legacy $service_name"
            fi
            ;;
        Darwin)
            legacy_service="gui/$(id -u)/$legacy_launch_label"
            legacy_plist=$(legacy_launch_plist_path)
            if launchctl print "$legacy_service" >/dev/null 2>&1; then
                launchctl bootout "$legacy_service" ||
                    fail "could not unload legacy $legacy_launch_label"
            fi
            ;;
    esac
}

prepare_legacy_service_rollback() {
    case "$platform_name" in
        Linux)
            unit=$(systemd_unit_path)
            if systemctl --user is-active --quiet "$service_name"; then
                legacy_service_was_running=true
            fi
            if [ -f "$unit" ]; then
                legacy_unit_backup="$unit.herdrgo-migration.$$"
                cp "$unit" "$legacy_unit_backup" ||
                    fail "could not back up legacy $service_name"
                chmod 600 "$legacy_unit_backup" ||
                    fail "could not protect the legacy service backup"
                legacy_unit_existed=true
            fi
            ;;
        Darwin)
            legacy_service="gui/$(id -u)/$legacy_launch_label"
            if launchctl print "$legacy_service" >/dev/null 2>&1; then
                legacy_service_was_running=true
            fi
            ;;
    esac
}

legacy_destination_is_available() {
    source=$1
    destination=$2
    label=$3
    [ -d "$source" ] || return 0
    [ ! -L "$destination" ] || fail "$label directory is a symbolic link: $destination"
    if [ -e "$destination" ] && [ ! -d "$destination" ]; then
        fail "$label path is not a directory: $destination"
    fi
    if ! directory_is_empty "$destination"; then
        printf 'HerdrGo: keeping existing %s; legacy data remains in %s\n' \
            "$destination" "$source" >&2
        return 1
    fi
}

move_legacy_directory() {
    source=$1
    destination=$2
    label=$3
    [ -d "$source" ] || return 0
    mkdir -p "$(dirname -- "$destination")"
    [ ! -d "$destination" ] || rmdir "$destination"
    mv "$source" "$destination" || fail "could not migrate legacy $label"
}

migrate_legacy_plugin_data() {
    [ "${HERDR_PLUGIN_ID:-}" = "$plugin_id" ] || return 0
    legacy_state_dir="$(dirname -- "$state_dir")/$legacy_plugin_id"
    legacy_config_dir="$(dirname -- "$HERDR_PLUGIN_CONFIG_DIR")/$legacy_plugin_id"
    if [ ! -d "$legacy_state_dir" ] && [ ! -d "$legacy_config_dir" ]; then
        return 0
    fi
    if ! legacy_destination_is_available \
        "$legacy_state_dir" "$state_dir" "state" || \
        ! legacy_destination_is_available \
        "$legacy_config_dir" "$HERDR_PLUGIN_CONFIG_DIR" "config"; then
        fail "new plugin data already exists; legacy migration was not started"
    fi

    [ ! -d "$legacy_state_dir" ] || legacy_state_present=true
    [ ! -d "$legacy_config_dir" ] || legacy_config_present=true
    legacy_migration_pending=true

    legacy_plugin_json=$("$herdr_bin_path" plugin list \
        --plugin "$legacy_plugin_id" --json) ||
        fail "could not inspect the legacy plugin registration"
    if printf '%s\n' "$legacy_plugin_json" | grep -Eq \
        '"plugin_id"[[:space:]]*:[[:space:]]*"kkrainbow\.herdrgo"' && \
        printf '%s\n' "$legacy_plugin_json" | grep -Eq \
        '"enabled"[[:space:]]*:[[:space:]]*true'; then
        "$herdr_bin_path" plugin disable "$legacy_plugin_id" >/dev/null ||
            fail "could not disable the legacy plugin during migration"
        legacy_plugin_was_enabled=true
    fi

    if [ "$legacy_state_present" = true ]; then
        acquire_lock "$legacy_state_dir"
        alternate_lock_dir="$state_dir/control.lock"
        alternate_lock_owner_dir="$state_dir/$lock_owner_name"
    else
        acquire_lock "$state_dir"
    fi
    prepare_legacy_service_rollback
    stop_legacy_service
    legacy_service_stopped=true
    if [ "$legacy_state_present" = true ]; then
        move_legacy_directory "$legacy_state_dir" "$state_dir" "state"
        lock_state_dir="$state_dir"
        lock_dir="$state_dir/control.lock"
        lock_owner_dir="$state_dir/$lock_owner_name"
    fi
    if [ "$legacy_config_present" = true ]; then
        move_legacy_directory \
            "$legacy_config_dir" "$HERDR_PLUGIN_CONFIG_DIR" "config"
    fi
    if [ ! -d "$legacy_state_dir" ] && [ ! -d "$legacy_config_dir" ]; then
        printf 'HerdrGo: migrated data from the previous plugin ID.\n'
    fi
}

restore_runtime_file() {
    destination=$1
    existed=$2
    if [ "$existed" = true ]; then
        [ -f "$destination.previous" ] || return 1
        mv -f "$destination.previous" "$destination"
    else
        rm -f "$destination"
    fi
}

rollback_legacy_migration() {
    rollback_failed=false
    printf 'HerdrGo: rolling back the plugin ID migration.\n' >&2

    if [ "$legacy_service_stopped" = true ]; then
        case "$platform_name" in
            Linux)
                systemctl --user stop "$service_name" >/dev/null 2>&1 || true
                ;;
            Darwin)
                service="gui/$(id -u)/$launch_label"
                if launchctl print "$service" >/dev/null 2>&1; then
                    launchctl bootout "$service" >/dev/null 2>&1 ||
                        rollback_failed=true
                fi
                rm -f "$(launch_plist_path)"
                ;;
        esac
    fi

    if [ "$legacy_state_present" = true ] && \
        [ ! -d "$legacy_state_dir" ] && [ -d "$state_dir" ]; then
        if [ "$runtime_bridge_replaced" = true ]; then
            restore_runtime_file "$runtime_bridge" "$runtime_bridge_existed" ||
                rollback_failed=true
        fi
        if [ "$runtime_ctl_replaced" = true ]; then
            restore_runtime_file "$runtime_ctl" "$runtime_ctl_existed" ||
                rollback_failed=true
        fi
        if [ "$legacy_config_present" = true ] && [ -d "$runtime_dir" ]; then
            printf '%s\n' "$legacy_config_dir" > "$metadata_config_dir" ||
                rollback_failed=true
        fi
        mv "$state_dir" "$legacy_state_dir" || rollback_failed=true
    fi
    if [ "$legacy_config_present" = true ] && \
        [ ! -d "$legacy_config_dir" ] && [ -d "$HERDR_PLUGIN_CONFIG_DIR" ]; then
        mv "$HERDR_PLUGIN_CONFIG_DIR" "$legacy_config_dir" || rollback_failed=true
    fi

    if [ "$legacy_service_stopped" = true ]; then
        case "$platform_name" in
            Linux)
                unit=$(systemd_unit_path)
                if [ "$legacy_unit_existed" = true ] && \
                    [ -f "$legacy_unit_backup" ]; then
                    mv -f "$legacy_unit_backup" "$unit" || rollback_failed=true
                else
                    rm -f "$unit"
                fi
                systemctl --user daemon-reload >/dev/null 2>&1 ||
                    rollback_failed=true
                if [ "$legacy_service_was_running" = true ]; then
                    systemctl --user restart "$service_name" >/dev/null 2>&1 ||
                        rollback_failed=true
                fi
                ;;
            Darwin)
                legacy_plist=$(legacy_launch_plist_path)
                if [ "$legacy_service_was_running" = true ] && \
                    [ -f "$legacy_plist" ]; then
                    launchctl bootstrap "gui/$(id -u)" "$legacy_plist" \
                        >/dev/null 2>&1 || rollback_failed=true
                fi
                ;;
        esac
    fi
    if [ "$legacy_plugin_was_enabled" = true ]; then
        "$herdr_bin_path" plugin enable "$legacy_plugin_id" >/dev/null 2>&1 ||
            rollback_failed=true
    fi
    [ -z "$legacy_unit_backup" ] || rm -f "$legacy_unit_backup"
    legacy_migration_pending=false
    [ "$rollback_failed" = false ]
}

commit_legacy_migration() {
    [ "$legacy_migration_pending" = true ] || return 0
    [ -z "$legacy_unit_backup" ] || rm -f "$legacy_unit_backup"
    if [ "$platform_name" = Darwin ]; then
        rm -f "$(legacy_launch_plist_path)"
    fi
    legacy_migration_pending=false
    legacy_migration_complete=true
}

unregister_legacy_plugin() {
    [ "$legacy_migration_complete" = true ] || return 0
    if ! "$herdr_bin_path" plugin uninstall "$legacy_plugin_id" >/dev/null 2>&1; then
        printf 'HerdrGo: legacy data is migrated, but its old plugin registration remains.\n' >&2
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
Environment="HERDR_BIN_PATH=$herdr_bin_value"
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
    read_metadata
    [ -x "$herdr_bin_path" ] || fail "Herdr executable is unavailable"

    migrate_legacy_plugin_data
    [ "$control_lock_acquired" = true ] || acquire_lock "$state_dir"
    umask 077
    mkdir -p "$runtime_dir" "$HERDR_PLUGIN_CONFIG_DIR" "$state_dir/logs"
    chmod 700 "$runtime_dir" "$HERDR_PLUGIN_CONFIG_DIR" "$state_dir/logs"
    if [ ! -f "$HERDR_PLUGIN_CONFIG_DIR/env" ]; then
        : > "$HERDR_PLUGIN_CONFIG_DIR/env"
    fi
    chmod 600 "$HERDR_PLUGIN_CONFIG_DIR/env"

    [ ! -f "$runtime_bridge" ] || runtime_bridge_existed=true
    install_runtime_file "$candidate" "$runtime_bridge" 755
    runtime_bridge_replaced=true
    [ ! -f "$runtime_ctl" ] || runtime_ctl_existed=true
    install_runtime_file "$control_script" "$runtime_ctl" 755
    runtime_ctl_replaced=true
    printf '%s\n' "$HERDR_PLUGIN_CONFIG_DIR" > "$metadata_config_dir"
    printf '%s\n' "$HERDR_SOCKET_PATH" > "$metadata_socket_path"
    printf '%s\n' "$herdr_bin_path" > "$metadata_herdr_bin_path"
    chmod 600 "$metadata_config_dir" "$metadata_socket_path" "$metadata_herdr_bin_path"
    read_metadata
    export_bridge_env
    "$runtime_bridge" --version
    service_install_and_restart
    wait_for_service
    commit_legacy_migration
    unregister_legacy_plugin

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
