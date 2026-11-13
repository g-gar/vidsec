# ARCH-031: Android Native Port (Shared Library & JNI Bridge)

**Status**: Proposed  
**Date**: 2026-11-13  
**Related**: [ARCH-009](009-unified-sqlite-storage-and-schema.md), [ARCH-015](015-declarative-task-services-and-comptime-di.md), [ARCH-019](019-collectors-architecture-and-inbound-agents.md)

---

## 1. Context & Goal

Enable embedding the Flowdata engine (`flowdata`, `flowdata_extensions`, and app-specific tasks) inside a native Android application (Kotlin/Java) as a compiled shared library (`libflowdata_android.so`) for `aarch64-linux-android` (and optionally `x86_64-linux-android` for emulators).

Running the engine natively via JNI avoids rewriting core pipeline, routing, dataflow, or binary inspection logic while staying compliant with Android's process sandbox and lifecycle constraints.

---

## 2. Architecture Overview

```text
  Android App (Kotlin / ForegroundService / WorkManager)
        │  JNI (filesDir, cacheDir, jobJson, progress callback)
        ▼
  libflowdata_android.so (Zig shared library, aarch64-linux-android)
        ├── C-ABI / JNI Bridge (android_jni.zig)
        ├── Static In-Process Plugins (LoadedModule without dlopen)
        ├── Flowdata Core + Dataflow + Extensions
        ├── std.http.Client (with injected/embedded CA bundle)
        └── Static SQLite3 (compiled from sqlite3.c amalgamation)
```

---

## 3. Implementation Plan

### Phase 1: Build System & Static SQLite3 (`build.zig`)
- **Problem**: `build.zig` and app build scripts currently use `linkSystemLibrary("sqlite3", .{})`. The Android NDK does not expose a public linkable `libsqlite3.so` in its sysroot.
- **Change**:
  - Add a build option (e.g. `-Dandroid=true` or automatic detection via `target.result.abi == .android`).
  - When targeting Android, compile the official `sqlite3.c` amalgamation via `addCSourceFile` and link it statically into `flowdata_datasource_sqlite` and `flowdata_extensions`.
  - Provide an NDK `libc.txt` mapping template/script so Zig can cross-compile `.link_libc = true` modules against Android Bionic (`std.c.clock_gettime`, pthreads, etc.).

### Phase 2: TLS CA Certificates (`http_transport.zig`)
- **Problem**: `std.http.Client` expects desktop Linux CA bundle paths (e.g. `/etc/ssl/certs`), whereas Android stores system certs as individual hashed files under `/system/etc/security/cacerts` (and `/apex/com.android.conscrypt/cacerts` on Android 14+).
- **Change**:
  - Extend `src/transport/outbound/protocols/http_transport.zig` to accept an explicit CA bundle path or in-memory PEM buffer (e.g. via `@embedFile` fallback or runtime config passed during engine initialization).

### Phase 3: Static Plugin Registration
- **Problem**: Loading secondary `.so` plugins at runtime via `std.DynLib.open` (`dlopen`) introduces path, SELinux, and Google Play policy friction.
- **Change**:
  - Leverage the existing static/in-process support in `src/plugin/loader/loaded_module.zig` to register app tasks (e.g. `apps/mangadex/plugin/tasks/`) directly at compile time inside `libflowdata_android.so`.

### Phase 4: Minimal JNI Bridge & Android Lifecycle Wrapper
- Create a shared library target (`android_jni.zig`) exporting C/JNI entrypoints:
  - `initEngine(dataDir, cacheDir, caBundlePath)` — configures sandboxed paths (`context.filesDir` / `context.cacheDir`) instead of relative CWD paths.
  - `runJob(jobEnvelopeJson)` — dispatches a job into the engine.
  - `registerProgressCallback(...)` — forwards `TelemetryBus` events back to Kotlin.
  - `shutdownEngine()` — triggers graceful teardown.
- On the Android side:
  - Place compiled `.so` artifacts in `app/src/main/jniLibs/arm64-v8a/`.
  - Execute long-running pipelines inside an Android `ForegroundService` or `WorkManager` worker so the OS does not kill background execution.
  - Exclude desktop-only collectors (`collectors/file_watcher` / `inotify`) and `ssh_store` from the Android build target.

---

## 4. Verification Criteria

- `zig build -Dtarget=aarch64-linux-android -Doptimize=ReleaseFast` produces `libflowdata_android.so` with zero system `libsqlite3.so` dynamic dependencies (`readelf -d`).
- A minimal Kotlin test app on an ARM64 emulator/device initializes the engine with `filesDir`, executes an outbound HTTPS request + SQLite write, and receives progress callbacks on the Kotlin side without crashes.

