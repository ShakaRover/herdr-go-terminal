#!/bin/sh
set -eu

entrypoint=${1:-}
[ -n "$entrypoint" ] || {
    printf 'HerdrGo action: missing pane entrypoint\n' >&2
    exit 2
}
: "${HERDR_BIN_PATH:?Herdr did not provide HERDR_BIN_PATH}"
: "${HERDR_PLUGIN_ID:?Herdr did not provide HERDR_PLUGIN_ID}"

exec "$HERDR_BIN_PATH" plugin pane open \
    --plugin "$HERDR_PLUGIN_ID" \
    --entrypoint "$entrypoint" \
    --focus
