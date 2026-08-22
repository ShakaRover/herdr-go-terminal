#!/usr/bin/env bash
# 从 EasyTier 仓库构建 easytier-android-jni 并把产物同步进 app 的 Android 源码树：
#   - libeasytier_android_jni.so → app/android/app/src/main/jniLibs/arm64-v8a/
#   - EasyTierJNI.kt / EasyTierForwarder.kt → app/android/app/src/main/kotlin/com/easytier/jni/
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

source "$(git rev-parse --show-toplevel)/.toolchain/env.sh"

EASYTIER_REPO="${EASYTIER_REPO:-/data/project/EasyTier}"
JNI_DIR="$EASYTIER_REPO/easytier-contrib/easytier-android-jni"
APP_ROOT="$(git rev-parse --show-toplevel)/app"

# cargo-ndk 需要 NDK 路径；复用 .toolchain/android-sdk/ndk/ 下的符号链接。
if [ -z "${ANDROID_NDK_HOME:-}" ] && [ -z "${ANDROID_NDK_ROOT:-}" ]; then
    ndk_dir="$(find "$ANDROID_SDK_ROOT/ndk" -mindepth 1 -maxdepth 1 | head -n 1)"
    if [ -z "$ndk_dir" ]; then
        echo "错误：$ANDROID_SDK_ROOT/ndk 下没有 NDK" >&2
        exit 1
    fi
    export ANDROID_NDK_HOME="$ndk_dir"
fi

echo "== 构建 easytier-android-jni (arm64-v8a, release)"
(cd "$JNI_DIR" && cargo ndk -t arm64-v8a build --release)

SO_SRC="$JNI_DIR/target/jniLibs/arm64-v8a"
SO_DST="$APP_ROOT/android/app/src/main/jniLibs/arm64-v8a"
mkdir -p "$SO_DST"
cp "$SO_SRC/libeasytier_android_jni.so" "$SO_DST/"

# EasyTierManager.kt / EasyTierVpnService.t.kt 依赖 VpnService 与 moshi，不拷。
KT_SRC="$JNI_DIR/kotlin/com/easytier/jni"
KT_DST="$APP_ROOT/android/app/src/main/kotlin/com/easytier/jni"
mkdir -p "$KT_DST"
cp "$KT_SRC/EasyTierJNI.kt" "$KT_SRC/EasyTierForwarder.kt" "$KT_DST/"

echo "== 同步完成"
ls -l "$SO_DST" "$KT_DST"
