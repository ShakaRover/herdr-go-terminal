#!/usr/bin/env bash
# 在 macOS 上构建 easytier-ios 静态库并同步进 app 的 ios/Frameworks/。
#
# 用法：
#   app/tool/build_ios_easytier.sh
# 环境变量：
#   EASYTIER_REPO  EasyTier 仓库路径（默认 ~/et-rs）
#
# 产物（被 ios/.gitignore 排除，不入库）：
#   app/ios/Frameworks/iphoneos/libeasytier_ios.a        (真机)
#   app/ios/Frameworks/iphonesimulator/libeasytier_ios.a (模拟器, lipo 合并 arm64+x86_64)
set -euo pipefail

if [[ "$(uname)" != "Darwin" ]]; then
    echo "error: 只能在 macOS 上运行（需要 Apple SDK）" >&2
    exit 1
fi

EASYTIER_REPO="${EASYTIER_REPO:-$HOME/et-rs}"
APP_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FRAMEWORKS="$APP_ROOT/ios/Frameworks"

echo "==> 构建 easytier_ios.xcframework（含 device + simulator slices）"
"$EASYTIER_REPO/easytier-contrib/easytier-ios/build-xcframework.sh"

TARGET_DIR="$EASYTIER_REPO/target"
XCF="$EASYTIER_REPO/easytier-contrib/easytier-ios/xcframework/easytier_ios.xcframework"

echo "==> 同步库到 $FRAMEWORKS"
mkdir -p "$FRAMEWORKS/iphoneos" "$FRAMEWORKS/iphonesimulator"
cp "$TARGET_DIR/aarch64-apple-ios/release/libeasytier_ios.a" "$FRAMEWORKS/iphoneos/"
# simulator slice 是 lipo 合并 arm64+x86_64 后的版本，从 xcframework 里取
SIM_SLICE="$(find "$XCF" -path '*simulator*' -name 'libeasytier_ios.a' | head -1)"
cp "$SIM_SLICE" "$FRAMEWORKS/iphonesimulator/"

echo "==> 完成"
ls -la "$FRAMEWORKS/iphoneos/" "$FRAMEWORKS/iphonesimulator/"
