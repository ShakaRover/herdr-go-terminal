#!/usr/bin/env bash
# 从 EasyTier 仓库构建 easytier-android-jni 并把产物同步进 app 的 Android 源码树：
#   - libeasytier_android_jni.so → app/android/app/src/main/jniLibs/<abi>/
#   - EasyTierJNI.kt → app/android/app/src/main/kotlin/com/easytier/jni/
#
# 幂等：cargo 增量构建 + 覆盖拷贝，重复执行结果一致。
#
# libeasytier_android_jni.so 自包含（DT_NEEDED 只有 liblog/libc/libdl/libm 系统库，
# easytier-ffi 以 rlib 静态链入）；jniLibs 输出目录里的其余 .so 是 workspace 其它
# cdylib 的构建产物，运行时不需要，不拷。
#
# 用法：app/tool/sync_easytier.sh
# 可用 EASYTIER_REPO 环境变量覆盖 EasyTier 仓库位置（默认 /data/project/EasyTier）。
set -euo pipefail

EASYTIER_REPO="${EASYTIER_REPO:-/data/project/EasyTier}"
JNI_DIR="$EASYTIER_REPO/easytier-contrib/easytier-android-jni"
APP_ROOT="$(git rev-parse --show-toplevel)/app"
ANDROID_SDK_ROOT="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-}}"
ANDROID_NDK_VERSION="${ANDROID_NDK_VERSION:-28.2.13676358}"

if [ -z "$ANDROID_SDK_ROOT" ]; then
    echo "错误：请先设置 ANDROID_SDK_ROOT 或 ANDROID_HOME" >&2
    exit 1
fi
export ANDROID_SDK_ROOT

# cargo-ndk and Gradle must use the same pinned NDK.
ndk_dir="$ANDROID_SDK_ROOT/ndk/$ANDROID_NDK_VERSION"
if [ ! -d "$ndk_dir" ]; then
    echo "错误：缺少 Android NDK $ANDROID_NDK_VERSION：$ndk_dir" >&2
    exit 1
fi
export ANDROID_NDK_HOME="$ndk_dir"
export ANDROID_NDK_ROOT="$ndk_dir"
export NDK_HOME="$ndk_dir"

echo "== 构建 easytier-android-jni (arm64-v8a + x86_64, release)"
# EasyTier 是 Cargo workspace；若不显式指定 -o，cargo-ndk 的链接产物会
# 落在 workspace target，而这里可能继续复制 JNI crate 下的历史旧文件。
(cd "$JNI_DIR" && cargo ndk \
    -t arm64-v8a \
    -t x86_64 \
    -o "$JNI_DIR/target/jniLibs" \
    build --locked --release)

for abi in arm64-v8a x86_64; do
    so_src="$JNI_DIR/target/jniLibs/$abi/libeasytier_android_jni.so"
    so_dst="$APP_ROOT/android/app/src/main/jniLibs/$abi"
    mkdir -p "$so_dst"
    cp "$so_src" "$so_dst/"
done

# EasyTierManager.kt / EasyTierVpnService.t.kt 依赖 VpnService 与 moshi，不拷。
KT_SRC="$JNI_DIR/kotlin/com/easytier/jni"
KT_DST="$APP_ROOT/android/app/src/main/kotlin/com/easytier/jni"
mkdir -p "$KT_DST"
cp "$KT_SRC/EasyTierJNI.kt" "$KT_DST/"

echo "== 同步完成"
ls -l "$APP_ROOT/android/app/src/main/jniLibs/arm64-v8a" \
    "$APP_ROOT/android/app/src/main/jniLibs/x86_64" \
    "$KT_DST"
