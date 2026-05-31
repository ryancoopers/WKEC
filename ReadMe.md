# WKEC — WebKit™ Embedded Core

A fork of WebKit that builds WebCore, JavaScriptCore, and WebGPU into an
embeddable, headless runtime you can link into a non-WebKit app and drive
in-process.

> WebKit is a trademark of Apple Inc. "WKEC" is an unofficial name for this fork,
> not affiliated with or endorsed by Apple.

## Build and stage

Requires full Xcode + the Metal toolchain and ~40 GB free disk.

```sh
./build-headless-runtime.sh --stage bin/
```

Stages the runtime into `bin/` (frameworks + dylibs + headers). Use
`--stage <dir>` to stage elsewhere (it replaces `<dir>`), `--clean` for a full
rebuild. The first build takes ~1–3 h; later builds are incremental.

Embed all of these together in the consumer app, alongside each other:

```
WebCore.framework  JavaScriptCore.framework  WebGPU.framework
libANGLE-shared.dylib  libwebrtc.dylib
```

## What changed, and why

- **In-process WebGPU error objects** (`Source/WebCore/Modules/WebGPU/Implementation/WebGPUDeviceImpl.{cpp,h}`):
  implemented the `invalid*`/`emptyBindGroupLayout` factories that were
  GPU-process stubs, so WebGPU works without the GPU process.

- **Obj-C class renaming** (`objc_runtime_name("WKEC_…")` across WebCore,
  JavaScriptCore, WebGPU, and libwebrtc): the embedded engine and Apple's system
  WebKit can load in the same process, so fork-defined classes are given unique
  runtime names to avoid duplicate-class collisions.
  `Tools/Scripts/check-for-inappropriate-objc-class-names` allows the `WKEC_`
  prefix.

- **`build-headless-runtime.sh`**: builds the three frameworks, relinks WebCore
  without `WEBCORE_ALLOWABLE_CLIENTS` (so non-WebKit code can link it), repoints
  install names to `@rpath`/`@loader_path` (so the embedded JavaScriptCore is
  used, never the system one), and drops `.tbd` stubs.
