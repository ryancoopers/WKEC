# WKEC — WebKit™ Embedded Core

**WKEC** (WebKit™ Embedded Core) is a fork of WebKit that builds WebCore,
JavaScriptCore, and WebGPU into an **embeddable, headless runtime** — a set of
frameworks you can link into a *non-WebKit* application and drive directly,
without the WebKit2 multi-process machinery (no UI process, no Web process, no
GPU process, no IPC).

The goal is to use WebKit's engine internals (DOM, layout, JS, WebGPU/Metal) as
an in-process library — for example, as the rendering core of a custom
embedder such as a `WebKitRenderer` XCFramework — instead of as a full browser
engine.

> WebKit is a trademark of Apple Inc. "WebKit™ Embedded Core" / "WKEC" is an
> unofficial name for this fork and is not affiliated with or endorsed by Apple.

---

## What changed in this fork (and why)

Everything specific to WKEC lives on top of upstream WebKit in two commits: an
engine patch that lets WebGPU run in-process, and the build script that produces
the embeddable runtime. Everything else is stock upstream WebKit.

### 1. In-process WebGPU `DeviceImpl` error objects

*`Source/WebCore/Modules/WebGPU/Implementation/WebGPUDeviceImpl.{cpp,h}`*

The in-process WebGPU implementation (`DeviceImpl`) left these factories as
`RELEASE_ASSERT_NOT_REACHED()` stubs:

- `invalidCommandEncoder()`
- `invalidCommandBuffer()`
- `invalidRenderPassEncoder()`
- `invalidComputePassEncoder()`
- `emptyBindGroupLayout()`

The real implementations live in the **GPU-process** `RemoteDeviceProxy`, which
a headless / in-process embedder does not run. Because
`GPURenderPassEncoder::end()` calls `device->invalidRenderPassEncoder()` on every
render pass, **any** WebGPU render pass crashed without the GPU process.

This patch implements them by mirroring `RemoteDeviceProxy` — building each
object from an invalid command encoder — and removes the now-incorrect
`[[noreturn]]` attributes.

### 2. The embeddable-runtime build script

*`build-headless-runtime.sh`*

A stock `build-webkit` does **not** produce something you can embed in a
non-WebKit app. Two extra steps are required, and the script automates both
after building (see the script's header comment for full detail):

1. **Relink WebCore without `WEBCORE_ALLOWABLE_CLIENTS`.** Upstream WebCore
   restricts who may link it; non-WebKit code otherwise fails with
   `ld: not an allowed client of WebCore`. The script relinks with
   `WEBCORE_ALLOWABLE_CLIENTS=""` to lift that restriction.

2. **Repoint install names to `@rpath`/`@loader_path`.** This guarantees the
   **embedded** JavaScriptCore is always used, never the system one. If a system
   JavaScriptCore is loaded alongside ours (CFNetwork pulls one in to evaluate a
   proxy PAC script), two `libpas`/`bmalloc` heaps corrupt each other and the
   app panics with `pas_deallocation_did_fail` on the first page load. The
   script rewrites every install id and cross-reference to the canonical
   `@rpath`/`@loader_path` form and verifies that **no** embedded binary still
   references a `/System` JavaScriptCore.

---

## Building the runtime

### Prerequisites

- **Full Xcode** (not just the Command Line Tools) plus the **Metal Toolchain**:
  ```sh
  sudo xcodebuild -runFirstLaunch
  xcodebuild -downloadComponent MetalToolchain
  ```
- **~40 GB free disk.** The build writes large intermediate object trees into
  both `WebKitBuild/` and `~/Library/Developer/Xcode/DerivedData/`; if the disk
  fills, the build fails partway through. If you hit failures, check free space
  first (`df -h /`) and clear `~/Library/Developer/Xcode/DerivedData` if needed.
- The first build is slow (~1–3 h). Subsequent builds are incremental.

### Usage

```sh
./build-headless-runtime.sh [--stage <dir>] [--output <build-dir>] [--clean]
```

| Option            | Meaning                                                                                                                                                              |
| ----------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `--stage <dir>`   | After building, copy the runtime into `<dir>` — the three frameworks, `libANGLE-shared.dylib`, `libwebrtc.dylib`, and the `usr/local/include` headers. **Replaces `<dir>`.** |
| `--output <dir>`  | WebKit build output dir (default: `./WebKitBuild`).                                                                                                                  |
| `--clean`         | Remove the build output dir before building (full rebuild).                                                                                                          |

### Examples

Build and stage into a local `bin/`:

```sh
./build-headless-runtime.sh --stage bin/
```

Build and stage straight into a consumer's vendored-runtime directory:

```sh
./build-headless-runtime.sh --stage /path/to/WebKitRenderer/ThirdParty/WebKit
```

Full clean rebuild:

```sh
./build-headless-runtime.sh --clean --stage bin/
```

> **Note:** `--stage` deletes and recreates the target directory. Point it at a
> directory you own, not at a path with other contents you want to keep.

### What you get

A staged runtime directory contains everything needed to embed, all meant to sit
**alongside each other**:

```
JavaScriptCore.framework
WebCore.framework
WebGPU.framework
libANGLE-shared.dylib
libwebrtc.dylib
include/                 # the usr/local/include headers
```

Link these into your embedder and the `@rpath`/`@loader_path` install names will
resolve the frameworks relative to the binary, keeping the embedded
JavaScriptCore isolated from the system one.
