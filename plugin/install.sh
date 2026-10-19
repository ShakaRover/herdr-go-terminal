#!/bin/sh
set -eu

plugin_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
manifest="$plugin_root/herdr-plugin.toml"

fail() {
    printf 'HerdrGoT install: %s\n' "$*" >&2
    exit 1
}

version=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$manifest" | sed -n '1p')
[ -n "$version" ] || fail "cannot read plugin version"
case "$version" in
    *[!0-9A-Za-z._-]*) fail "invalid plugin version: $version" ;;
esac

case "$(uname -s):$(uname -m)" in
    Linux:x86_64) target=x86_64-unknown-linux-musl ;;
    Linux:aarch64 | Linux:arm64) target=aarch64-unknown-linux-musl ;;
    Darwin:x86_64) target=x86_64-apple-darwin ;;
    Darwin:arm64 | Darwin:aarch64) target=aarch64-apple-darwin ;;
    *) fail "unsupported platform: $(uname -s) $(uname -m)" ;;
esac

archive="herdrgot-bridge-${version}-${target}.tar.gz"
checksum="$archive.sha256"
base_url=${HERDRGOT_RELEASE_BASE_URL:-"https://github.com/ShakaRover/herdr-go-terminal/releases/download/v$version"}
tmp_dir=$(mktemp -d "$plugin_root/.herdrgot-install.XXXXXX")
candidate="$plugin_root/bin/.herdrgot-bridge.$$"

cleanup() {
    rm -f "$candidate"
    rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

download() {
    url=$1
    output=$2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --show-error --retry 3 \
            --output "$output" "$url"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$output" "$url"
    else
        fail "curl or wget is required"
    fi
}

printf 'Downloading HerdrGoT bridge %s for %s...\n' "$version" "$target"
download "$base_url/$archive" "$tmp_dir/$archive"
download "$base_url/$checksum" "$tmp_dir/$checksum"

checksum_line=$(sed -n '1p' "$tmp_dir/$checksum")
expected_hash=$(printf '%s\n' "$checksum_line" |
    sed -n 's/^\([0-9A-Fa-f]\{64\}\)[[:space:]][ *].*$/\1/p')
expected_name=$(printf '%s\n' "$checksum_line" |
    sed -n 's/^[0-9A-Fa-f]\{64\}[[:space:]][ *]//p')
[ -n "$expected_hash" ] || fail "invalid checksum file"
[ "$expected_name" = "$archive" ] || fail "checksum names an unexpected asset"

if command -v sha256sum >/dev/null 2>&1; then
    actual_hash=$(sha256sum "$tmp_dir/$archive" | sed 's/[[:space:]].*$//')
elif command -v shasum >/dev/null 2>&1; then
    actual_hash=$(shasum -a 256 "$tmp_dir/$archive" | sed 's/[[:space:]].*$//')
else
    fail "sha256sum or shasum is required"
fi
[ "$actual_hash" = "$expected_hash" ] || fail "archive checksum mismatch"

tar -xzf "$tmp_dir/$archive" -C "$tmp_dir"
[ -f "$tmp_dir/herdrgot-bridge" ] || fail "archive does not contain herdrgot-bridge"
mkdir -p "$plugin_root/bin"
cp "$tmp_dir/herdrgot-bridge" "$candidate"
chmod 755 "$candidate"
mv -f "$candidate" "$plugin_root/bin/herdrgot-bridge"
printf 'HerdrGoT bridge candidate installed at %s\n' "$plugin_root/bin/herdrgot-bridge"
