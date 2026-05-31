#!/bin/bash
# Build and stage the WKEC (WebKit(tm) Embedded Core) headless runtime.
#
# Requires full Xcode + Metal toolchain and ~40 GB free disk.
#
# Usage:
#   ./build-headless-runtime.sh [--stage <dir>] [--output <build-dir>] [--clean]
#     --stage <dir>    Copy the runtime into <dir> (replaces it).
#     --output <dir>   Build output dir (default: ./WebKitBuild).
#     --clean          Remove the build output dir before building.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
WK_OUT="$ROOT/WebKitBuild"
STAGE=""
DO_CLEAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --stage)  STAGE="${2:?--stage needs a directory}"; shift 2 ;;
        --output) WK_OUT="${2:?--output needs a directory}"; shift 2 ;;
        --clean)  DO_CLEAN=1; shift ;;
        -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
        *) echo "Unknown option: $1 (see --help)"; exit 1 ;;
    esac
done
REL="$WK_OUT/Release"

echo "==> Checking prerequisites"
xcodebuild -version >/dev/null 2>&1 || { echo "Full Xcode is required (not just Command Line Tools)."; exit 1; }
if ! xcrun --sdk macosx --find metal >/dev/null 2>&1; then
    echo "WARNING: Metal toolchain not found. If the build fails in ANGLE, run:"
    echo "    xcodebuild -downloadComponent MetalToolchain"
fi

[ "$DO_CLEAN" = 1 ] && { echo "==> Cleaning $WK_OUT"; rm -rf "$WK_OUT"; }

# Build only the embedded frameworks, not the WebKit/WebKitLegacy umbrella
# (WebKitLegacy re-exports bridge classes this fork renames and would fail to link).
echo "==> Building WKEC frameworks (Release)"
export WEBKIT_OUTPUTDIR="$WK_OUT"
for scheme in JavaScriptCore WebGPU WebCore; do
    echo "    building scheme: $scheme"
    xcodebuild -workspace WebKit.xcworkspace -scheme "$scheme" -configuration Release \
        SYMROOT="$WK_OUT" OBJROOT="$WK_OUT" build
done

# Relink WebCore without allowable_client so non-WebKit code can link it.
echo "==> Relinking WebCore without allowable_client"
xcodebuild -workspace WebKit.xcworkspace -scheme WebCore -configuration Release \
    SYMROOT="$WK_OUT" OBJROOT="$WK_OUT" WEBCORE_ALLOWABLE_CLIENTS="" build

# Repoint install names to @rpath/@loader_path so the embedded JavaScriptCore is
# always used, never the system one (two libpas/bmalloc heaps would corrupt).
echo "==> Repointing install names to @rpath/@loader_path"
JSC_BIN="$REL/JavaScriptCore.framework/Versions/A/JavaScriptCore"
WC_BIN="$REL/WebCore.framework/Versions/A/WebCore"
GPU_BIN="$REL/WebGPU.framework/Versions/A/WebGPU"
ANGLE_BIN="$REL/libANGLE-shared.dylib"
RTC_BIN="$REL/libwebrtc.dylib"

JSC_RP="@rpath/JavaScriptCore.framework/Versions/A/JavaScriptCore"
WC_RP="@rpath/WebCore.framework/Versions/A/WebCore"
GPU_RP="@rpath/WebGPU.framework/Versions/A/WebGPU"
ANGLE_RP="@loader_path/../../../libANGLE-shared.dylib"
RTC_RP="@loader_path/../../../libwebrtc.dylib"

install_name_tool -id "$JSC_RP"   "$JSC_BIN"   2>/dev/null || true
install_name_tool -id "$WC_RP"    "$WC_BIN"    2>/dev/null || true
install_name_tool -id "$GPU_RP"   "$GPU_BIN"   2>/dev/null || true
install_name_tool -id "$ANGLE_RP" "$ANGLE_BIN" 2>/dev/null || true
install_name_tool -id "$RTC_RP"   "$RTC_BIN"   2>/dev/null || true

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
for b in "$WC_BIN" "$GPU_BIN" "$JSC_BIN" "$ANGLE_BIN" "$RTC_BIN"; do repoint "$b"; done

for b in "$WC_BIN" "$JSC_BIN" "$GPU_BIN" "$ANGLE_BIN" "$RTC_BIN"; do
    [ -f "$b" ] && codesign --force --sign - "$b" || true
done

echo "==> Verifying no /System JavaScriptCore references remain"
bad=0
for b in "$WC_BIN" "$GPU_BIN" "$JSC_BIN" "$ANGLE_BIN" "$RTC_BIN"; do
    if otool -L "$b" 2>/dev/null | grep -q "/System/Library/.*/JavaScriptCore"; then
        echo "    ERROR: $b still references the system JavaScriptCore"; bad=1
    fi
done
[ "$bad" = 0 ] && echo "    OK" || { echo "    install-name repointing failed"; exit 1; }

if [ -n "$STAGE" ]; then
    echo "==> Staging runtime into $STAGE"
    rm -rf "$STAGE"; mkdir -p "$STAGE/include"
    cp -R "$REL/WebCore.framework" "$REL/JavaScriptCore.framework" "$REL/WebGPU.framework" "$STAGE/"
    cp "$REL/libANGLE-shared.dylib" "$REL/libwebrtc.dylib" "$STAGE/"
    cp -R "$REL/usr/local/include/." "$STAGE/include/"
    # Drop .tbd stubs so consumers link the @rpath binaries, not the system copies.
    find "$STAGE" -name '*.tbd' -delete
    echo "    staged."
fi

echo ""
echo "Done. Built runtime is in: $REL"
[ -n "$STAGE" ] && echo "Vendored runtime staged at: $STAGE"
