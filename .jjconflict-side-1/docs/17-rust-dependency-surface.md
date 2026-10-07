# 17. Rust dependency surface

Consumed by `docs/30-port-design.md`, which turns each replacement into a binding
decision, and by `docs/40-plan.md`, which sequences the work.

Scope: the Rust dependency surface of AccessKit at commit
`466e24e252103f4d82bd6fbab98141b551e46e0c` (core 0.25.1) and of accesskit-c at
commit `8b6ed37c20ed4c59390e253407983333053662ba` (0.23.1). The target is a
Zig port with no Rust toolchain. Every version below comes from a `Cargo.lock`
entry, never from a manifest range.

## How the data was extracted

Three scripts, all read-only, run under
`/tmp/scratch/RustDependencySurface/`.

| Script | What it reads | What it produces |
|---|---|---|
| `parse.py` | `Cargo.lock` of both trees, every member `Cargo.toml` via `tomllib` | exact versions per crate, reverse-dependency map |
| `grepc.py` | member source trees | real `grep -rEc '^\s*(pub\s+)?use\s+<crate>\b'` counts, split into production, test, example |
| `group.py` | `Cargo.lock` package blocks | closure grouped by purpose from explicit name lists |

`Cargo.lock` is parsed by splitting on `[[package]]` and reading the `name` and
`version` keys of each block. Verified counts: 312 `[[package]]` blocks in
`/tmp/scratch/accesskit/Cargo.lock`, 160 in
`/tmp/scratch/accesskit-c/Cargo.lock`. Manifest requirements such
as `version = "1"` are ignored because they are ranges.

The grouping in section 2 is a hand-written name list in `group.py`, not a
heuristic. Every one of the 312 blocks is in exactly one group; the script
prints `UNASSIGNED` for any block it cannot place, and it printed none.

## 1. Direct dependencies per crate

The workspace has 10 members (`Cargo.toml:3-14`). The table lists every direct
dependency of every member, with the exact version from `Cargo.lock`. The
`use` count is the `grep -c` figure from `grepc.py`. "Prod" means the crate is
linked into the shipped library. "Test" means a `#[cfg(test)]` module or a
dev-dependency. "Example" means an `examples/` target.

### accesskit 0.25.1

| Crate | Lock version | Features requested | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `uuid` | 1.18.1 | `default-features = false` | `TreeId` newtype | 1 / 0 / 0 |
| `serde` | 1.0.228 | `alloc`, `derive` (optional) | property serialization | 1 / 0 / 0 |
| `serde_json` | 1.0.145 | optional | JSON Schema output | 1 / 0 / 0 |
| `schemars` | 1.1.0 | optional | JSON Schema derive | 1 / 0 / 0 |
| `enumn` | 0.1.14 | optional | `N_*` ordinal constants | 0 / 0 / 0 |
| `pyo3` | 0.29.0 | optional | Python `pyclass` | 1 / 0 / 0 |

The last five sit behind cargo features that no workspace member enables
(`accesskit/Cargo.toml:25-29`). Only `uuid` is unconditional.

### accesskit_consumer 0.39.1

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `hashbrown` | 0.17.1 | `default-hasher`, no default features | `HashMap`, `HashSet` in the tree | 1 / 0 / 0 |

### adapters/atspi-common 0.21.0

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `atspi-common` | 0.13.0 | `default-features = false` | `Role`, `State`, `CoordType`, `InterfaceSet`, and 5 more | 7 / 0 / 0 |
| `phf` | 0.14.0 | `macros` | one `phf_map!` of 10 getters | 1 / 0 / 0 |
| `serde` | 1.0.228 | default | action/rect wire types | 2 / 0 / 0 |
| `zvariant` | 5.15.0 | `default-features = false` | `Type`, `OwnedValue` impls | 2 / 0 / 0 |

### adapters/unix 0.24.0

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `atspi` | 0.29.0 | `proxies` | `InterfaceSet`, `ObjectRef`, event bodies | 11 / 0 / 0 |
| `zbus` | 5.19.0 | `async-io` | the D-Bus connection and object server | 19 / 0 / 0 |
| `zvariant` | 5.15.0 | transitively, plus direct uses | object paths and signatures | 0 / 0 / 0 |
| `serde` | 1.0.228 | default | event body serialization | 2 / 0 / 0 |
| `futures-lite` | 2.6.0 | default | `block_on` | 0 / 0 / 0 |
| `futures-util` | 0.3.31 | optional, on by default | `select`, `StreamExt` | 1 / 0 / 0 |
| `async-channel` | 2.3.1 | optional, on by default | unbounded message channel | 2 / 0 / 0 |
| `async-executor` | 1.13.1 | optional, on by default | the internal executor | 1 / 0 / 0 |
| `async-task` | 4.7.1 | optional, on by default | cancellable task handle | 1 / 0 / 0 |
| `tokio` | 1.44.2 | `macros`, `net`, `rt`, `sync`, `time` | alternate runtime, feature `tokio` | 3 / 0 / 0 |
| `tokio-stream` | 0.1.17 | optional | `UnboundedReceiverStream` | 1 / 0 / 0 |

The `tokio` and `async-io` paths are mutually exclusive. The adapter refuses to
build with neither and refuses with both
(`adapters/unix/src/lib.rs:13-21`).

### adapters/windows 0.35.1

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `windows` | 0.62.2 | 10 `Win32_*` features | UI Automation calls | 13 total: 8 / 4 / 1 |
| `windows-core` | 0.62.2 | default | `ComObject` | 0 `use` lines; reached as `windows::core` |
| `hashbrown` | 0.17.1 | workspace | event maps | 2 / 0 / 0 |
| `static_assertions` | 1.1.0 | default | one `assert_eq_size!` | 0 `use` lines |
| `parking_lot` | 0.12.4 | dev-dependency | test mutex | 0 / 0 / 0 |
| `scopeguard` | 1.1.0 | dev-dependency | test window guards | 0 / 0 / 0 |
| `raw-window-handle` | 0.6.2 | dev-dependency | example window | 1 / 0 / 1 |
| `winit` | 0.30.9 | dev-dependency | example event loop | 1 / 0 / 1 |
| `example_common` | 0.0.1 | dev-dependency | shared example code | 1 / 0 / 1 |

### adapters/macos 0.27.1

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `objc2` | 0.5.2 | default | `Id`, `WeakId` retain/release | 8 / 0 / 0 |
| `objc2-foundation` | 0.2.2 | `NSArray`, `NSDictionary`, `NSValue`, `NSThread` | `NSObject`, `NSPoint` | 7 / 0 / 0 |
| `objc2-app-kit` | 0.2.2 | 9 `NSAccessibility*` and AppKit features | `NSView`, `NSWindow` | 7 / 0 / 0 |
| `hashbrown` | 0.17.1 | workspace | context maps | 2 / 0 / 0 |

### adapters/ios 0.2.1

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `objc2` | 0.5.2 | default | `Id`, `WeakId` | 6 / 0 / 0 |
| `objc2-foundation` | 0.2.2 | 8 features | `NSString`, `NSThread` | 7 / 0 / 0 |
| `objc2-ui-kit` | 0.2.2 | 11 `UIAccessibility*` and UIKit features | `UIView`, `UIAccessibilityElement` | 6 / 0 / 0 |
| `hashbrown` | 0.17.1 | workspace | context maps | 1 / 0 / 0 |

### adapters/android 0.9.0

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `jni` | 0.21.1 | default | JNI calls into the Android toolkit | 7 / 0 / 0 |
| `log` | 0.4.17 | default | one `log::debug` call | 1 / 0 / 0 |

### adapters/winit 0.34.1

| Crate | Lock version | Features | Used for | `use` prod/test/example |
|---|---|---|---|---|
| `winit` | 0.30.9 | `default-features = false` | window and event loop types | 10 total: 7 / 0 / 3 |
| `raw-window-handle` | 0.6.2 and 0.5.2 | `std` | `RawWindowHandle` | 2 alias lines, no `use` |
| `example_common` | 0.0.1 | dev-dependency | shared example code | 3 / 0 / 3 |

Two versions of `raw-window-handle` are in the lock because the adapter
supports the 0.5 and 0.6 generations through separate features
(`adapters/winit/Cargo.toml:17-19`) and renames one to `raw_window_handle`
(`adapters/winit/src/lib.rs:61,64`).

### example_common 0.0.1

Example support only. Never linked into a shipped library.
`deny.toml:14` excludes it from the licence check.

| Crate | Lock version | Used for |
|---|---|---|
| `raw-window-handle` | 0.6.2 | `HasDisplayHandle`, `HasWindowHandle` |
| `softbuffer` | 0.4.8 | offscreen rendering in examples |

### accesskit-c 0.23.1

| Crate | Lock version | Used for |
|---|---|---|
| `accesskit` | 0.25.1 | shared types |
| `accesskit_windows` | 0.35.1 | Windows adapter, `cfg(target_os = "windows")` |
| `accesskit_macos` | 0.27.1 | macOS adapter, `cfg(target_os = "macos")` |
| `accesskit_unix` | 0.24.0 | Linux and BSD adapters |
| `accesskit_android` | 0.9.0 | Android adapter |
| `accesskit_ios` | 0.2.1 | Apple mobile adapter |

### Totals

33 unique third-party direct dependencies across all members, counted
programmatically. 26 are production, 3 are test-only, 4 are example-only.

## 2. The transitive closure

`accesskit/Cargo.lock` has 312 `[[package]]` blocks, 282 distinct names. The 30
extra blocks are duplicate versions of 20 names, mostly `windows-sys` at four
versions and the nine `windows_*` architecture crates at three versions each.

`accesskit-c/Cargo.lock` has 160 blocks and 158 distinct names. 157 of those
names also appear in the core lock. The only name unique to the C tree is
`accesskit-c` itself. The core lock has 125 names the C tree does not, and every
one of them arrives through `adapters/winit`, `example_common`, or their
dependencies. The C tree drops all windowing.

### Closure grouped by purpose

| Group | Blocks |
|---|---|
| Platform binding, Windows | 45 |
| Async runtime, executor, reactor, timer, channel, lock | 42 |
| Platform binding, Linux, X11, Wayland, windowing | 40 |
| Platform binding, macOS and iOS | 35 |
| Rust-specific plumbing, macros, proc macros | 26 |
| Build, parsing and codegen tooling | 23 |
| Collections, hashing, byte scanning | 16 |
| D-Bus and AT-SPI | 14 |
| Serialization | 14 |
| Web and WASM | 13 |
| Filesystem, randomness, misc runtime | 11 |
| Text, unicode, font encoding | 10 |
| AccessKit workspace members | 10 |
| Android and JNI | 7 |
| Logging | 4 |
| Error handling | 2 |
| **Total** | **312** |

The two largest groups are Windows platform binding at 45 blocks and the async
stack at 42 blocks. Their names:

**Windows, 45 blocks.** `windows`, `windows-collections`, `windows-core`,
`windows-future`, `windows-implement`, `windows-interface`, `windows-link`,
`windows-numerics`, `windows-result`, `windows-strings`, `windows-threading`,
`windows-sys` at 0.45.0, 0.52.0, 0.59.0 and 0.61.2, `windows-targets` at 0.42.2,
0.48.1 and 0.52.6, and nine `windows_<arch>_<abi>` crates at up to three
versions each, plus `winapi`, `winapi-i686-pc-windows-gnu`,
`winapi-x86_64-pc-windows-gnu`, `winapi-util`, `uds_windows`.

**Async, 42 blocks.** `async-broadcast`, `async-channel`, `async-executor`,
`async-io`, `async-lock`, `async-process`, `async-recursion`, `async-signal`,
`async-task`, `atomic-waker`, `blocking`, `calloop`,
`calloop-wayland-source`, `concurrent-queue`, `crossbeam-utils`,
`event-listener`, `event-listener-strategy`, `fastrand`, `futures-core`,
`futures-io`, `futures-lite`, `futures-macro`, `futures-task`, `futures-util`,
`lock_api`, `mio`, `ordered-stream`, `parking`, `parking_lot`,
`parking_lot_core`, `pin-project`, `pin-project-internal`,
`pin-project-lite`, `pin-utils`, `piper`, `polling`, `signal-hook-registry`,
`slab`, `socket2`, `tokio`, `tokio-macros`, `tokio-stream`.

The group boundaries show the shape of the problem. 160 of 312 blocks, more
than half, exist only to name a platform API. 42 exist only to run futures. 26
exist only because Rust needs a macro to name a Rust type.

## 3. What each direct dependency is for

Every row names the AccessKit file that uses it and what the port must replace
it with. Size estimates come from the Zig standard library line counts and from
the size of the Rust code being replaced.

### Serialization and data types

| Crate | Use site | Purpose | Replacement | Estimate |
|---|---|---|---|---|
| `uuid` 1.18.1 | `accesskit/src/lib.rs:32` | 128-bit `TreeId`. Only `Uuid::nil()` and `Uuid::from_u128` are called, 15 call sites total | written from scratch: a 16-byte extern struct plus `nil` and `fromBytes` | 40 lines |
| `serde` 1.0.228 | `accesskit/src/geometry.rs:20`, 36 derive sites | property wire format. `Properties` has a hand-written `Serialize` at `lib.rs:2821` and `Deserialize` at `lib.rs:3009` spanning 316 lines | `std.json.Stringify` for the C ABI writer, plus a hand-written compact writer for the tree update. No derive: comptime property tables | 900 lines |
| `serde_json` 1.0.145 | `accesskit/src/lib.rs:30` | JSON Schema construction | `std.json` (`std/json/Stringify.zig`, 999 lines, already in std) | 150 lines |
| `schemars` 1.1.0 | `accesskit/src/geometry.rs:19`, 46 mentions | JSON Schema generation | written from scratch, or drop. Nothing in the C ABI needs it. `docs/30-port-design.md` decides | 500 lines if kept |
| `enumn` 0.1.14 | `accesskit/src/lib.rs:48`, 15 derive sites | `N_*` ordinal constants for enums such as the 182-variant `Role` | `std.enums.directEnumArray` (`std/enums.zig:126`) and `std.enums.fromInt` (`std/enums.zig:11`). The crate already hand-writes a fallback at `lib.rs:357` | 120 lines |
| `phf` 0.14.0 | `adapters/atspi-common/src/text_attributes.rs:8,68` | one 10-entry perfect hash from attribute name to getter | a `comptime` array of `{name, fn}` pairs with linear search. Ten entries do not need a hash | 40 lines |
| `zvariant` 5.15.0 | `adapters/atspi-common/src/rect.rs:7`, `action.rs:7` | D-Bus `Type` and `OwnedValue` impls | goose `Value` and `Signature` (`goose/src/value.zig:104`) | 100 lines |

### Hash maps

| Crate | Use site | Purpose | Replacement | Estimate |
|---|---|---|---|---|
| `hashbrown` 0.17.1 | `accesskit_consumer/src/tree.rs:9`, `adapters/{windows,macos,ios}/src/context.rs` | `HashMap`, `HashSet` | `std.ArrayHashMapUnmanaged` and `std.AutoArrayHashMapUnmanaged` (`std/std.zig:37-41`, backed by `std/array_hash_map.zig`, 2256 lines) | 0 lines, only import changes |

### D-Bus and AT-SPI

| Crate | Use site | Purpose | Replacement | Estimate |
|---|---|---|---|---|
| `zbus` 5.19.0 | `adapters/unix/src/atspi/bus.rs:24` | D-Bus connection, object server, signal emission | goose 3.3.0, pinned. See section 5 | see section 5 |
| `atspi` 0.29.0 | `adapters/unix/src/adapter.rs:13` | `InterfaceSet`, `Role`, `StateSet`, `ObjectRef`, `proxy::bus::BusProxy`, `proxy::socket::SocketProxy` | written from scratch for the enums and object references. The two proxies become two small goose `Proxy` structs. Evidence for which types are used: `CoordType`, `InterfaceSet`, `ObjectId`, `ObjectRef`, `OwnedObjectAddress`, `TextSelection`, `proxy::bus::StatusProxy` | 800 lines |
| `atspi-common` 0.13.0 | `adapters/atspi-common/src/lib.rs:21`, 7 `use` sites | `Role`, `State`, `CoordType`, `Granularity`, `ScrollType`, `Layer`, `RelationType`, `InterfaceSet`, `StateSet`, `Politeness`, `CacheItem`, `ObjectRef` | written from scratch as Zig enums. Each is a fixed name-to-integer table. `std.enums.EnumArray` covers the storage | 700 lines |

### Async

| Crate | Use site | Purpose | Replacement | Estimate |
|---|---|---|---|---|
| `tokio` 1.44.2 | `adapters/unix/src/adapter.rs:17`, `context.rs:18` | optional runtime for the blocking public API | zio. See section 4 | 0 lines |
| `tokio-stream` 0.1.17 | `adapters/unix/src/context.rs:23` | adapts a channel to a stream | zio `Channel` plus `select` | 60 lines |
| `async-executor` 1.13.1 | `adapters/unix/src/executor.rs:11` | the internal single-threaded executor | zio `Runtime` (`zio/src/zio.zig:14`) | 80 lines |
| `async-task` 4.7.1 | `adapters/unix/src/executor.rs:13` | cancellable task handle | zio `JoinHandle` (`zio/src/runtime.zig:169`) | 60 lines |
| `async-channel` 2.3.1 | `adapters/unix/src/adapter.rs:12` | unbounded message channel | zio `Channel` (`zio/src/sync/channel.zig:624`) | 40 lines |
| `futures-util` 0.3.31 | `adapters/unix/src/context.rs:12` | `select`, `StreamExt`, `pin_mut` | zio `select` (`zio/src/select.zig:270`) | 60 lines |
| `futures-lite` 2.6.0 | `adapters/unix/src/util.rs:13` | `block_on` for the blocking adapter entry point | zio has no `block_on`. The port exposes an async entry point and the C ABI drives it. See `docs/30-port-design.md` | 0 lines |

### Platform bindings

| Crate | Use site | Purpose | Replacement | Estimate |
|---|---|---|---|---|
| `windows` 0.62.2 | `adapters/windows/src/adapter.rs:13` and 9 more files | UI Automation, COM activation, window subclassing | hand-written `extern` declarations. Zig std has no `oleacc` or `IAccessible` symbols; `grep -rl oleacc` over the 0.16.0 std tree returns nothing. Ten `Win32_*` feature groups map to about 120 symbols | 1400 lines |
| `windows-core` 0.62.2 | `adapters/windows/src/context.rs:11`, as `windows::core::ComObject` | `ComObject` trait | same extern layer as `windows` | included above |
| `objc2` 0.5.2 | `adapters/macos/src/adapter.rs:18` | `Id`, `WeakId` smart pointers over `objc_msgSend` | hand-written `extern` declarations for `objc_msgSend`, `objc_retain`, `objc_release`, `objc_autoreleasePoolPush`. Zig std has no Objective-C binding; `grep -rl objc_msgSend` returns nothing | 500 lines |
| `objc2-foundation` 0.2.2 | `adapters/macos/src/adapter.rs:20` | `NSObject`, `NSArray`, `NSPoint`, `NSThread` | hand-written extern declarations plus `msgSend` selector wrappers for about 12 classes | 600 lines |
| `objc2-app-kit` 0.2.2 | `adapters/macos/src/adapter.rs:19` | `NSView`, `NSWindow`, `NSAccessibility` protocol | hand-written extern declarations plus selector wrappers for about 20 selectors on 6 classes | 900 lines |
| `objc2-ui-kit` 0.2.2 | `adapters/ios/src/adapter.rs:27` | `UIView`, `UIAccessibilityElement` | same approach, UIKit instead of AppKit | 900 lines |
| `jni` 0.21.1 | `adapters/android/src/adapter.rs:16` | JNI calls into the Android toolkit classes | hand-written `extern` declarations against `libart.so` exports. Zig std has no JNI; `grep -rl JNIEnv` returns nothing | 700 lines |
| `log` 0.4.17 | `adapters/android/src/inject.rs:19` | one `debug!` call | drop it, or route through a logger struct passed as a parameter. The house rules forbid globals | 0 lines |

### Test and example only

| Crate | Use site | Replacement |
|---|---|---|
| `winit` 0.30.9 | `adapters/winit/src/lib.rs:53` | the port has no windowing library. The winit adapter becomes an adapter over a window handle type the host supplies |
| `raw-window-handle` 0.6.2 and 0.5.2 | `adapters/winit/src/lib.rs:61` | one `RawWindowHandle` extern struct, about 30 lines. Two versions collapse to one |
| `softbuffer` 0.4.8 | `example_common/src/render.rs:8` | drop. Examples are out of port scope |
| `parking_lot` 0.12.4 | `adapters/windows/src/tests/mod.rs:185` | `zio.Mutex` (`zio/src/sync/Mutex.zig:39`) |
| `scopeguard` 1.1.0 | `adapters/windows/src/tests/mod.rs:233` | `defer` |
| `static_assertions` 1.1.0 | `adapters/windows/src/node.rs:41` | `comptime assert` |

### Not ported at all

`pyo3` 0.29.0 provides Python bindings for 20 types. There is no Python consumer
in the target, so it goes away with its feature flag. `serde` and `schemars`
stay only if `docs/30-port-design.md` keeps a JSON tree-update path; the C ABI
in `accesskit-c/src/common.rs` passes tree updates through a C struct
(`tree_update` at line 972) and never calls serde, so the C ABI needs no
serialization crate at all.

## 4. The async dependencies

Eleven crates supply an executor, a reactor, a timer, a channel, or a lock.
`accesskit_unix` uses five of them directly and pulls the rest through `zbus`.

| Crate | Lock version | What AccessKit uses it for | zio replacement |
|---|---|---|---|
| `tokio` | 1.44.2 | optional runtime behind the `tokio` feature. It supplies `mpsc`, `select`, and a current-thread runtime for `block_on` (`adapters/unix/src/util.rs:18`) | `zio.Runtime`, `zio/src/zio.zig:14`, declared at `zio/src/runtime.zig:1569` |
| `tokio-stream` | 0.1.17 | wraps `UnboundedReceiver` as a `Stream` so `select` can race it (`adapters/unix/src/context.rs:23`) | `zio.select`, `zio/src/select.zig:270` |
| `async-executor` | 1.13.1 | the single-threaded executor the adapter runs its internal tasks on (`adapters/unix/src/executor.rs:11`) | `zio.Runtime.spawn`, `zio/src/runtime.zig:1492` |
| `async-task` | 4.7.1 | the task handle, which cancels on drop (`adapters/unix/src/executor.rs:13`) | `zio.JoinHandle`, `zio/src/runtime.zig:169` |
| `async-channel` | 2.3.1 | the unbounded channel from the host thread into the bus task (`adapters/unix/src/adapter.rs:12`) | `zio.Channel`, `zio/src/sync/channel.zig:624` |
| `futures-util` | 0.3.31 | `select` over the channel and the bus stream (`adapters/unix/src/context.rs:12`) | `zio.select`, `zio/src/select.zig:270` |
| `futures-lite` | 2.6.0 | `block_on` (`adapters/unix/src/util.rs:13`) | none. zio has no blocking wait. This is the one gap, and it changes the public shape |
| `async-io` | 2.3.4 | the reactor zbus runs on, selected by the `async-io` feature | `zio.io.fromRuntime`, `zio/src/io.zig:138`, exposed as `Runtime.io()` at `zio/src/runtime.zig:2067` |
| `async-lock` | 3.4.0 | async mutex and rwlock inside zbus | `zio.Mutex` at `zio/src/sync/Mutex.zig:39`, `zio.RwLock` at `zio/src/sync/RwLock.zig:44` |
| `polling` | 3.7.4 | readiness notification under `async-io` | zio `ev` backend, `zio/src/ev/root.zig` |
| `parking_lot` | 0.12.4 | a synchronous mutex, dev-dependency only | `zio.Mutex` |

Timers come from `tokio`'s `time` feature. The only use is the executor tick
loop (`adapters/unix/src/atspi/bus.rs:56`), which has no timeout. zio needs
nothing here.

### The shape of the port

Upstream `accesskit_unix` hides its async runtime behind a blocking API. It
spawns a thread (`adapters/unix/src/context.rs:55`), builds a runtime inside it
(`:56`), and blocks on it (`adapters/unix/src/util.rs:13`). The zio port should
delete that layer rather than reproduce it. Two process globals,
`APP_CONTEXT` and `MESSAGES` at `adapters/unix/src/context.rs:33-34`, become
explicit fields on an adapter struct. This matches the house rule that `io` is
threaded and never global.

## 5. The D-Bus dependencies

### What is in the tree today

| Crate | Lock version | Role |
|---|---|---|
| `zbus` | 5.19.0 | the D-Bus library. Async, selected by the `async-io` feature |
| `zvariant` | 5.15.0 | the D-Bus value and signature system |
| `zbus_macros` | 5.19.0 | proc macros for `#[interface]` and `#[proxy]` |
| `zvariant_derive` | 5.15.0 | proc macros for `Type` and `Value` |
| `zbus_names` | 4.3.4 | `BusName`, `InterfaceName`, `MemberName`, `UniqueName` |
| `zbus_xml` | 5.2.1 | introspection XML |
| `zbus-lockstep` and `zbus-lockstep-macros` | 0.5.1 | checked-in XML from the spec, compiled at build time |
| `zcheapstr` | 1.1.0 | cheap string type |
| `zvariant_utils` | 4.2.0 | `ObjectPath` helpers |
| `atspi` | 0.29.0 | the AT-SPI client types, with `proxies` on |
| `atspi-common` | 0.13.0 | the shared AT-SPI enums |
| `atspi-proxies` | 0.13.0 | generated client proxies, pulled in by `atspi` |
| `serde_repr` | 0.1.19 | integer discriminants, pulled in by `zbus` |

The reverse-dependency map confirms the shape: `zbus` is depended on by
`accesskit_unix`, `atspi-common` and `atspi-proxies`. `atspi-common` is
depended on by `accesskit_atspi_common`, `atspi` and `atspi-proxies`. Nothing
outside `adapters/unix` and `adapters/atspi-common` touches any of them.

### What changes with goose 3.3.0

goose v3.3.0 at commit `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1` is 6412 lines
of Zig across 13 modules, with no external dependencies
(`goose/build.zig.zon`: `.dependencies = .{}`) and
`minimum_zig_version = "0.16.0"`.

Thirteen of the fourteen D-Bus crates above disappear. `atspi`,
`atspi-common`, and `atspi-proxies` do not, but they are plain data types, not
protocol code. They become Zig enums, estimated at 1500 lines for the two
`use` sites plus the enum tables.

goose is not async. Its `Connection` methods are synchronous
(`goose/src/connection.zig:1080` for `methodCall`). It runs its own worker
threads when the backend is `threaded`
(`goose/src/connection.zig:863-880`) and `serve()` blocks
(`goose/src/connection.zig:891`). This is a good fit, because the upstream
adapter already blocks.

Five things the Rust crate did that goose does not. Each is work for the port.

**Dynamic object registration and removal.** `zbus` lets the adapter register an
interface at a path at runtime and remove it later.
`self.conn.object_server().at(path, interface)` appears at
`adapters/unix/src/atspi/bus.rs:83,94,106,188` and
`.remove::<T, _>(path)` at `:250`. The adapter registers ten interfaces per
node and removes them when a subtree dies, so this is the hot path, not an edge
case. goose's `registerObject` takes a `comptime` type and a fixed path and
appends to a list (`goose/src/connection.zig:700,740`). There is no `remove`
anywhere in the file. The port needs a dynamic object table, about 250 lines,
keyed by path and interface name with a vtable dispatch. This is the single
largest gap between the two libraries.

**A runtime-computed signal member name.** The adapter picks the signal name
from a match on the event kind (`adapters/unix/src/atspi/bus.rs:270-281`) and
calls `emit_signal` with it (`:491`). goose signals are declared as struct
fields and bound at registration (`goose/src/dbus_types.zig:8-49`), so the name
is a comptime constant. The port needs an `emit_signal` that takes the name as
a parameter, about 60 lines, modelled on `dbus_types.zig:24-48`.

**Typed D-Bus errors.** Every method returns `fdo::Result`, 92 sites across 12
interface files. `fdo::Error` carries names such as `UnknownObject` and
`NotSupported` that the adapter maps from its own error type
(`adapters/unix/src/util.rs:28-42`). goose has `sendError(msg, name, text)` at
`goose/src/connection.zig:821` but no error taxonomy. The port writes an
explicit Zig error set and a mapping function, about 150 lines.

**Bus address parsing.** Upstream parses `AT_SPI_BUS_ADDRESS` itself
(`adapters/unix/src/atspi/bus.rs:43-47`) and falls back to asking the session
bus through `BusProxy::get_address()`. goose has a `.Accessibility` bus type
that reads `AT_SPI_BUS_ADDRESS` and falls back to
`unix:path=/run/user/{uid}/at-spi/bus_0`
(`goose/src/connection.zig:493-501`). Its `SocketIterator`
(`goose/src/connection.zig:1451-1475`) handles only the `unix:` prefix and the
`path=` parameter. It does not handle `abstract=`, which AT-SPI bus addresses
use in some configurations. The port must extend the iterator, about 40 lines,
and keep the `BusProxy` fallback, about 30 lines.

**A typed client proxy for the socket interface.** `atspi-proxies` generates
`SocketProxy` and `BusProxy`. goose has a generic `Proxy` with `rawCall`,
`getProperty`, `connectSignal` (`goose/src/proxy.zig:45-149`). The port writes
two thin wrappers, about 100 lines.

### What goose already covers

Introspection XML generation is built in (`goose/src/xml_generator.zig`, 139
lines). `Properties.Get`, `GetAll` and `Set` are dispatched, and
`PropertiesChanged` is emitted on a property write
(`goose/src/dispatcher.zig:72-231`). Signal subscription through `AddMatch` is
at `goose/src/proxy.zig:121-149`. Method dispatch reads argument types from the
Zig function signature at comptime (`goose/src/dispatcher.zig:256-310`), which
is how an interface becomes a struct of methods.

## 6. Dependencies that exist only for Rust

Twenty-six blocks in the closure serve Rust itself. Removing them is free.

| Group | Names | What they do |
|---|---|---|
| Proc macro runtime | `proc-macro2` 1.0.106, `quote` 1.0.37, `syn` 2.0.87 and 3.0.6, `unicode-ident` 1.0.8 | token streams and parsing inside `rustc` |
| Derive helpers | `heck` 0.5.0, `num_enum` 0.7.3, `num_enum_derive` 0.7.3, `enumn` 0.1.14, `phf_macros` 0.14.0, `schemars_derive` 1.1.0, `serde_derive` 1.0.228, `serde_derive_internals` 0.29.1, `zvariant_derive` 5.15.0, `zbus_macros` 5.19.0, `zbus-lockstep-macros` 0.5.1, `zvariant_utils` 4.2.0, `ref-cast` 1.0.25, `ref-cast-impl` 1.0.25, `dyn-clone` 1.0.20 | generate the code that names Rust types |
| Python bridge | `pyo3` 0.29.0, `pyo3-build-config` 0.29.0, `pyo3-ffi` 0.29.0, `pyo3-macros` 0.29.0, `pyo3-macros-backend` 0.29.0 | CPython bindings, 6 blocks |
| Async trait erasure | `async-trait` 0.1.83 | turns `async fn` in traits into boxed futures |
| Thread-local and atomics shims | `scoped-tls` 1.0.1, `portable-atomic` 1.9.0, `zerocopy` 0.7.32, `zerocopy-derive` 0.7.32, `memoffset` 0.9.0, `autocfg` 1.1.0 | make Rust primitives work on targets that lack them |
| Build-time crate resolution | `proc-macro-crate` 3.5.0 | finds the version of the crate under `#[derive]` |

Zig has no derive. Everything these crates generate becomes a `comptime`
function or a `inline for` over `@typeInfo`. The house rule on comptime
exhaustiveness in section 2 of `AGENTS.md` applies directly: a wire enum such
as the 182-variant `Role` is an enumerable domain, and the port decodes every
variant in a comptime sweep.

Removing the Rust-only set saves all 26 blocks plus the compile time behind
them. It also removes the need for a proc-macro toolchain entirely, which is
one of the stated goals of the port.

## 7. Licence and supply chain posture

`deny.toml` at the root of each tree configures `cargo-deny`. The CI runs it
per target through `EmbarkStudios/cargo-deny-action@v2`
(`.github/workflows/ci.yml:54`).

### Graph

The check runs with `all-features = true` over seven target triples, listed at
`deny.toml:4-12`: `aarch64-apple-darwin`, `aarch64-linux-android`,
`i686-pc-windows-gnu`, `i686-pc-windows-msvc`, `x86_64-pc-windows-gnu`,
`x86_64-pc-windows-msvc`, `x86_64-unknown-linux-gnu`. The C tree checks nine
triples (`accesskit-c/deny.toml:4-14`), adding `x86_64-apple-darwin`,
`x86_64-unknown-linux-gnu` and `x86_64-unknown-linux-musl`. The multi-target
sweep exists because a crate that only appears on one target still has to pass.

The core tree excludes `example_common` (`deny.toml:14`), which is why the
example-only dependencies in section 1 are not licence-checked.

### Advisories

The RustSec advisory database is fetched from
`https://github.com/rustsec/advisory-db`. One advisory is ignored:
`RUSTSEC-2026-0192`, for `ttf-parser`, with a written reason. It is unmaintained
and reaches the tree only through `sctk-adwaita` via `ab_glyph` in the example
windowing stack (`deny.toml:19-21`). The C tree ignores nothing.

### Licences

Seven licences are allowed: `Apache-2.0`, `Apache-2.0 WITH LLVM-exception`,
`BSD-2-Clause`, `BSD-3-Clause`, `ISC`, `MIT`, `Zlib`
(`deny.toml:24-32`). Confidence threshold 0.8. One exception:
`unicode-ident` is allowed under `Unicode-DFS-2016`.

Everything else is denied by omission. Copyleft and source-available licences
are not on the list. Both trees ship `LICENSE-APACHE`, `LICENSE-MIT` and
`LICENSE.chromium`, and the C tree adds `COPYING.LIB`.

### Bans

`multiple-versions = "deny"` and `wildcards = "deny"` (`deny.toml:41-42`). No
version requirement may use a wildcard. Duplicate versions are denied except for
a skip list at `deny.toml:46-58`: `bitflags:<2`, `linux-raw-sys:<0.12`,
`raw-window-handle:<0.6`, `rustix:<1`, `syn:<3`, `windows-sys:<0.61`,
`windows-targets:<0.52`, and the four `windows_<arch>` entries. The skip list
is the same evidence as section 2: 30 duplicate-version blocks exist because
older windowing and binding crates pin their own generation.

### Sources

`unknown-registry = "deny"` and `unknown-git = "deny"` (`deny.toml:62-63`).
Every crate comes from crates.io or from a declared git source. No build script
may fetch an undeclared dependency.

### What this means for the port

The licence allow-list is the constraint the port inherits. Both new
dependencies are MIT: goose's `LICENSE` opens with the MIT permission notice,
and so does zio's. Both fit the list without an exception.

`cargo deny` has no Zig equivalent. The supply chain check becomes a check that
`build.zig.zon` pins a hash for every dependency and that `docs/21-licensing.md`
records the licence of each. The target count of two packages in section 8 is
what makes that check small enough to do by hand.

## 8. The port dependency budget

### Target: two Zig packages

`.dependencies` in `build.zig.zon` should hold exactly `zio` and `goose`, both
already pinned. `zio` is in place at commit
`2662fdc45997611b962b560c513c16963475a01b`; goose joins at
`8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1`.

The reasoning is the decision order from the port philosophy, applied to all 33
direct dependencies.

| Rung | Count | Reason |
|---|---|---|
| 1. Zig standard library | 24 | hash maps, JSON, arrays, enums, unicode, threads, process environment |
| 2. Zig package in `build.zig.zon` | 2 | `zio` for the runtime, `goose` for D-Bus |
| 3. `translate-c` binding to a system C library | 0 by default | `pkg-config` finds `dbus-1` 1.14.10, `xcb` 1.17.0 and `wayland-client` 1.24.0 on this host, but rung 2 already covers D-Bus and the port does not need windowing |
| 4. Hand-written C shim | 0 | no macro, opaque handle, non-representable callback or varargs forces it |

### Why not more

**`zig-uuid`.** The index search returns two candidates, `dmgk/zig-uuid` and
`jdknezek/uuid6-zig`. Neither is needed. `accesskit` calls exactly two UUID
functions in 15 places: `nil()` and `from_u128`. A 40-line extern struct beats
a dependency.

**A Wayland binding.** `Isaac Freund/zig-wayland` exists on the index. The port
does not need it. The windowing stack in the Rust tree exists to feed
`softbuffer` in examples and to give `winit` something to own. The AT-SPI adapter
talks D-Bus only.

**An Objective-C binding.** A search of the index for `objc` returns zero
results. The Objective-C runtime calls go through `objc_msgSend`, which is a C
function with a variadic signature. Hand-written extern declarations in Zig
are about 500 lines and cover `Id` and `WeakId` exactly.

**A Windows binding.** A search for `windows` returns two console and process
packages, neither of which touches UI Automation. Zig std has no `oleacc`
symbols. The 45 Windows blocks in the closure collapse to about 120 extern
declarations, because only ten `Win32_*` feature groups are enabled.

**A JSON library.** `nektro/zig-json` and `ziglibs/tres` exist. `std.json` is
already in the compiler at 999 lines for writing and 1766 for scanning.

### Why not fewer

`zio` and `goose` cannot be merged. goose is built on `std.Io`, not on zio. The
two runtimes overlap in what they provide: both have a scheduler, both have
channels, both have sockets. Running both in one process means two thread pools
and two cancellation models, which is exactly what the house rules forbid.

The three options in `local://zaccesskit-deps.md` stay open. `zio` implements
`std.Io` at `zio/src/io.zig:138`, and `Runtime.io()` at
`zio/src/runtime.zig:2067` produces one. That makes option (a) work: hand
goose a `std.Io` backed by the zio runtime, so there is one I/O implementation
and one cancellation model. `docs/30-port-design.md` must pick this and defend
it. This document does not decide it.

### What the count buys

Two packages means two hashes to audit, two licences to record, and two
repositories to track. `cargo deny` checked 312 blocks across seven targets.
The manual equivalent of that check, for two pinned packages, is a page. That
is the whole argument for the number.
