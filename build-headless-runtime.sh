#!/bin/bash
# Build and stage the WKEC (WebKit(tm) Embedded Core) headless runtime.
#
# Requires full Xcode + Metal toolchain and ~40 GB free disk per configuration.
#
# Usage:
#   ./build-headless-runtime.sh [--debug] [--release] [--stage <dir>] [--output <dir>] [--clean]
#     --debug          Build the Debug configuration.
#     --release        Build the Release configuration.
#                      If neither is given, both are built.
#     --stage <dir>    Copy the runtime into <dir> (replaces it). When both
#                      configurations are built, stages into <dir>/Debug and <dir>/Release.
#     --output <dir>   Build output dir (default: ./WebKitBuild).
#     --clean          Remove the build output dir before building.
#
# A Debug consumer must link the Debug runtime and a Release consumer the Release
# runtime: assertions change the size of types embedded in shared structs (e.g.
# CompletionHandler), so mixing them corrupts ABI layout.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WK_OUT="$ROOT/WebKitBuild"
STAGE=""
DO_CLEAN=0
BUILD_DEBUG=0
BUILD_RELEASE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --debug)   BUILD_DEBUG=1; shift ;;
        --release) BUILD_RELEASE=1; shift ;;
        --stage)   STAGE="${2:?--stage needs a directory}"; shift 2 ;;
        --output)  WK_OUT="${2:?--output needs a directory}"; shift 2 ;;
        --clean)   DO_CLEAN=1; shift ;;
        -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done
if [ "$BUILD_DEBUG" = 0 ] && [ "$BUILD_RELEASE" = 0 ]; then
    BUILD_DEBUG=1
    BUILD_RELEASE=1
fi
CONFIGS=()
[ "$BUILD_DEBUG" = 1 ]   && CONFIGS+=("Debug")
[ "$BUILD_RELEASE" = 1 ] && CONFIGS+=("Release")

echo "==> Checking prerequisites"
xcodebuild -version >/dev/null 2>&1 || { echo "Full Xcode is required (not just Command Line Tools)."; exit 1; }
if ! xcrun --sdk macosx --find metal >/dev/null 2>&1; then
    echo "WARNING: Metal toolchain not found. If the build fails in ANGLE, run:"
    echo "    xcodebuild -downloadComponent MetalToolchain"
fi

[ "$DO_CLEAN" = 1 ] && { echo "==> Cleaning $WK_OUT"; rm -rf "$WK_OUT"; }

export WEBKIT_OUTPUTDIR="$WK_OUT"

JSC_RP="@rpath/JavaScriptCore.framework/Versions/A/JavaScriptCore"
WC_RP="@rpath/WebCore.framework/Versions/A/WebCore"
GPU_RP="@rpath/WebGPU.framework/Versions/A/WebGPU"
ANGLE_RP="@loader_path/../../../libANGLE-shared.dylib"
RTC_RP="@loader_path/../../../libwebrtc.dylib"

repoint() {
    local bin="$1"; [ -f "$bin" ] || return 0
    otool -L "$bin" | awk 'NR>1{print $1}' | while read -r dep; do
        case "$dep" in
            @rpath/*|@loader_path/*) ;;
            *JavaScriptCore.framework/Versions/A/JavaScriptCore) install_name_tool -change "$dep" "$JSC_RP"   "$bin" 2>/dev/null || true ;;
            *WebCore.framework/Versions/A/WebCore)               install_name_tool -change "$dep" "$WC_RP"    "$bin" 2>/dev/null || true ;;
            *WebGPU.framework/Versions/A/WebGPU)                 install_name_tool -change "$dep" "$GPU_RP"   "$bin" 2>/dev/null || true ;;
            *libANGLE-shared.dylib)                              install_name_tool -change "$dep" "$ANGLE_RP" "$bin" 2>/dev/null || true ;;
            *libwebrtc.dylib)                                    install_name_tool -change "$dep" "$RTC_RP"   "$bin" 2>/dev/null || true ;;
        esac
    done
}

build_config() {
    local config="$1"
    local out="$WK_OUT/$config"

    # Build only the embedded frameworks, not the WebKit/WebKitLegacy umbrella
    # (WebKitLegacy re-exports bridge classes this fork renames and would fail to link).
    # libwebrtc and ANGLE (dynamic) must precede WebCore: each installs the
    # headers WebCore compiles against (webrtc/* SPI such as CMBaseObjectSPI.h
    # used by PAL's CoreMedia soft-link; ANGLE/* for the GLES backend) into the
    # build's usr/local/include, and each produces a dylib the runtime stages
    # (libwebrtc.dylib, libANGLE-shared.dylib).
    echo "==> Building WKEC frameworks ($config)"
    for scheme in JavaScriptCore WebGPU libwebrtc "ANGLE (dynamic)" WebCore; do
        echo "    building scheme: $scheme"
        xcodebuild -workspace WebKit.xcworkspace -scheme "$scheme" -configuration "$config" \
            SYMROOT="$WK_OUT" OBJROOT="$WK_OUT" build
    done

    # Relink WebCore without allowable_client so non-WebKit code can link it.
    echo "==> Relinking WebCore without allowable_client ($config)"
    xcodebuild -workspace WebKit.xcworkspace -scheme WebCore -configuration "$config" \
        SYMROOT="$WK_OUT" OBJROOT="$WK_OUT" WEBCORE_ALLOWABLE_CLIENTS="" build

    local JSC_BIN="$out/JavaScriptCore.framework/Versions/A/JavaScriptCore"
    local WC_BIN="$out/WebCore.framework/Versions/A/WebCore"
    local GPU_BIN="$out/WebGPU.framework/Versions/A/WebGPU"
    local ANGLE_BIN="$out/libANGLE-shared.dylib"
    local RTC_BIN="$out/libwebrtc.dylib"

    # Repoint install names to @rpath/@loader_path so the embedded JavaScriptCore is
    # always used, never the system one (two libpas/bmalloc heaps would corrupt).
    echo "==> Repointing install names ($config)"
    install_name_tool -id "$JSC_RP"   "$JSC_BIN"   2>/dev/null || true
    install_name_tool -id "$WC_RP"    "$WC_BIN"    2>/dev/null || true
    install_name_tool -id "$GPU_RP"   "$GPU_BIN"   2>/dev/null || true
    install_name_tool -id "$ANGLE_RP" "$ANGLE_BIN" 2>/dev/null || true
    install_name_tool -id "$RTC_RP"   "$RTC_BIN"   2>/dev/null || true

    for b in "$WC_BIN" "$GPU_BIN" "$JSC_BIN" "$ANGLE_BIN" "$RTC_BIN"; do repoint "$b"; done
    for b in "$WC_BIN" "$JSC_BIN" "$GPU_BIN" "$ANGLE_BIN" "$RTC_BIN"; do
        [ -f "$b" ] && codesign --force --sign - "$b" || true
    done

    echo "==> Verifying no /System JavaScriptCore references remain ($config)"
    local bad=0
    for b in "$WC_BIN" "$GPU_BIN" "$JSC_BIN" "$ANGLE_BIN" "$RTC_BIN"; do
        if otool -L "$b" 2>/dev/null | grep -q "/System/Library/.*/JavaScriptCore"; then
            echo "    ERROR: $b still references the system JavaScriptCore"; bad=1
        fi
    done
    [ "$bad" = 0 ] && echo "    OK" || { echo "    install-name repointing failed"; exit 1; }
}

stage_config() {
    local config="$1"
    local dest="$2"
    local out="$WK_OUT/$config"
    echo "==> Staging $config runtime into $dest"
    rm -rf "$dest"; mkdir -p "$dest/include"
    cp -R "$out/WebCore.framework" "$out/JavaScriptCore.framework" "$out/WebGPU.framework" "$dest/"
    cp "$out/libANGLE-shared.dylib" "$out/libwebrtc.dylib" "$dest/"
    cp -R "$out/usr/local/include/." "$dest/include/"
    # Drop .tbd stubs so consumers link the @rpath binaries, not the system copies.
    find "$dest" -name '*.tbd' -delete
    echo "    staged."
}

for config in "${CONFIGS[@]}"; do
    build_config "$config"
done

if [ -n "$STAGE" ]; then
    if [ "${#CONFIGS[@]}" -gt 1 ]; then
        for config in "${CONFIGS[@]}"; do stage_config "$config" "$STAGE/$config"; done
    else
        stage_config "${CONFIGS[0]}" "$STAGE"
    fi
fi

echo ""
echo "Done."
for config in "${CONFIGS[@]}"; do echo "  $config runtime: $WK_OUT/$config"; done
if [ -n "$STAGE" ]; then
    if [ "${#CONFIGS[@]}" -gt 1 ]; then
        for config in "${CONFIGS[@]}"; do echo "  staged ($config): $STAGE/$config"; done
    else
        echo "  staged: $STAGE"
    fi
fi
