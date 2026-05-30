#!/bin/bash
# Build the embeddable headless WebKit runtime from THIS fork.
#
# This builds WebCore / JavaScriptCore / WebGPU (Release, arm64) from the current
# checkout — the `headless-embedding` branch carries the in-process WebGPU patch —
# and prepares the frameworks for embedding in a non-WebKit app (e.g. the
# WebKitRenderer XCFramework). Two things a stock WebKit build does NOT do, both
# required for embedding, are handled here:
#
#   1. WebCore is relinked with WEBCORE_ALLOWABLE_CLIENTS="" so non-WebKit code can
#      link against it (otherwise: `ld: not an allowed client of WebCore`).
#   2. Every install name + cross-reference is repointed to @rpath / @loader_path so
#      the EMBEDDED JavaScriptCore is always used, never the system one. If a system
#      JavaScriptCore is loaded alongside ours (CFNetwork pulls it in to evaluate a
#      proxy PAC script), two libpas/bmalloc heaps corrupt each other and the app
#      panics with `pas_deallocation_did_fail` on the first page load.
#
# Requirements: full Xcode (not just Command Line Tools) + the Metal Toolchain:
#     sudo xcodebuild -runFirstLaunch
#     xcodebuild -downloadComponent MetalToolchain
# ~40 GB free disk. The first build is slow (~1-3 h); subsequent builds are incremental.
#
# Usage:
#   ./build-headless-runtime.sh [--stage <dir>] [--output <build-dir>] [--clean]
#     --stage <dir>    After building, copy the runtime (WebCore/JavaScriptCore/WebGPU
#                      frameworks + libANGLE-shared.dylib + libwebrtc.dylib + the
#                      usr/local/include headers) into <dir>. Point this at your
#                      consumer's vendored runtime, e.g.
#                        --stage /path/to/WebKitRenderer/ThirdParty/WebKit
#     --output <dir>   WebKit build output dir (default: ./WebKitBuild).
#     --clean          Remove the build output dir before building (full rebuild).
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
        -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
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
echo "    fork checkout: $ROOT  (branch: $(git -C "$ROOT" branch --show-current 2>/dev/null || echo '?'))"

[ "$DO_CLEAN" = 1 ] && { echo "==> Cleaning $WK_OUT"; rm -rf "$WK_OUT"; }

echo "==> Building WebKit (Release) — this takes a while…"
export WEBKIT_OUTPUTDIR="$WK_OUT"
Tools/Scripts/build-webkit --release

echo "==> Relinking WebCore without allowable_client (so non-WebKit code can link it)"
xcodebuild -workspace WebKit.xcworkspace -scheme WebCore -configuration Release \
    SYMROOT="$WK_OUT" OBJROOT="$WK_OUT" WEBCORE_ALLOWABLE_CLIENTS="" build

echo "==> Repointing install names to @rpath/@loader_path (embedded-JSC isolation)"
JSC_BIN="$REL/JavaScriptCore.framework/Versions/A/JavaScriptCore"
WC_BIN="$REL/WebCore.framework/Versions/A/WebCore"
GPU_BIN="$REL/WebGPU.framework/Versions/A/WebGPU"
ANGLE_BIN="$REL/libANGLE-shared.dylib"
RTC_BIN="$REL/libwebrtc.dylib"

JSC_RP="@rpath/JavaScriptCore.framework/Versions/A/JavaScriptCore"
WC_RP="@rpath/WebCore.framework/Versions/A/WebCore"
GPU_RP="@rpath/WebGPU.framework/Versions/A/WebGPU"
ANGLE_RP="@loader_path/../../../libANGLE-shared.dylib"   # frameworks sit one dir below the vendor root
RTC_RP="@loader_path/../../../libwebrtc.dylib"

# 1) Set each binary's own install id.
install_name_tool -id "$JSC_RP"   "$JSC_BIN"   2>/dev/null || true
install_name_tool -id "$WC_RP"    "$WC_BIN"    2>/dev/null || true
install_name_tool -id "$GPU_RP"   "$GPU_BIN"   2>/dev/null || true
install_name_tool -id "$ANGLE_RP" "$ANGLE_BIN" 2>/dev/null || true
install_name_tool -id "$RTC_RP"   "$RTC_BIN"   2>/dev/null || true

# 2) Repoint every cross-reference (whatever absolute/system path it currently is)
#    to the canonical @rpath/@loader_path form, by basename.
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

# 3) Re-sign (ad-hoc) after editing load commands.
for b in "$WC_BIN" "$JSC_BIN" "$GPU_BIN" "$ANGLE_BIN" "$RTC_BIN"; do
    [ -f "$b" ] && codesign --force --sign - "$b" || true
done

# 4) Sanity check: no embedded binary may reference a system JavaScriptCore.
echo "==> Verifying no /System JavaScriptCore references remain"
bad=0
for b in "$WC_BIN" "$GPU_BIN" "$JSC_BIN" "$ANGLE_BIN" "$RTC_BIN"; do
    if otool -L "$b" 2>/dev/null | grep -q "/System/Library/.*/JavaScriptCore"; then
        echo "    ERROR: $b still references the system JavaScriptCore"; bad=1
    fi
done
[ "$bad" = 0 ] && echo "    OK — all references are @rpath/@loader_path" || { echo "    install-name repointing failed"; exit 1; }

if [ -n "$STAGE" ]; then
    echo "==> Staging runtime into $STAGE"
    rm -rf "$STAGE"; mkdir -p "$STAGE/include"
    cp -R "$REL/WebCore.framework" "$REL/JavaScriptCore.framework" "$REL/WebGPU.framework" "$STAGE/"
    cp "$REL/libANGLE-shared.dylib" "$REL/libwebrtc.dylib" "$STAGE/"
    cp -R "$REL/usr/local/include/." "$STAGE/include/"
    echo "    staged."
fi

echo ""
echo "Done. Built runtime is in: $REL"
[ -n "$STAGE" ] && echo "Vendored runtime staged at: $STAGE"
echo "Embed alongside each other: WebCore/JavaScriptCore/WebGPU .frameworks + libANGLE-shared.dylib + libwebrtc.dylib"
