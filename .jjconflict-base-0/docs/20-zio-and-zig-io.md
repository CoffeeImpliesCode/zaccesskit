# 20. zio and the Zig 0.16 `std.Io` interface

Consumed by `docs/30-port-design.md` and `docs/40-plan.md`, which turn it into the port architecture and the work sequence.

## 0. Scope, versions, and citation format

This document answers one question. Which async layer does the port build on,
and what does each layer give the port.

| Thing | Value | Evidence |
|---|---|---|
| `zio` checkout | `~/zio` | `git remote -v` in that tree lists `https://github.com/CoffeeImpliesCode/zio.git` as `origin` |
| `zio` HEAD in that checkout | `8d03e4b` | `git log --oneline -3` |
| `zio` commit pinned by this project | `2662fdc45997611b962b560c513c16963475a01b` | `build.zig.zon:15` and `build.zig.zon:30` |
| `zio` package version | `0.18.0`, `minimum_zig_version = "0.16.0"` | `zio/build.zig.zon:3-4` |
| Zig standard library | `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std/` | the path recorded in this document |
| `std.Io.zig` size | 3461 lines | `wc -l std/Io.zig` |

Citations use two short prefixes.

- `ZIO/` means `~/zio/`.
- `STD/` means `/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std/`.

### 0.1 The checkout is one commit ahead of the pin

The local checkout is not the pinned commit. The only difference is a stack
growth fix.

```
git diff --stat 2662fdc45997611b962b560c513c16963475a01b HEAD
 docs/changelog.md  |  4 ++
 src/coro/stack.zig | 119 ++++++++++++++++++++++++++++++++++++++---------------
```

Nothing in `src/coro/stack.zig` appears in this document. Every claim below is
about a file that is byte-identical in the pinned commit. The one exception is
noted where it occurs.

### 0.2 What this document does not cover

The D-Bus protocol layer and the X11 client layer belong to
`docs/12-accesskit-adapters.md`. Section 9 states only what the runtime must
supply for those layers and at which rung of the Zig-first dependency ladder
each dependency sits.

---

## 1. The two async layers

### 1.1 The verdict

`zio` **implements** the `std.Io` interface. It does not replace it, and it does
not sit beside it as an alternative.

`std.Io` stays the interface. `zio` becomes one of the implementations behind
it, in the same place `std.Io.Threaded`, `std.Io.Uring`, and `std.Io.Dispatch`
sit. The port calls ordinary `std.Io` functions and the calls land inside zio
tasks.

### 1.2 The evidence

| # | Claim | Evidence |
|---|---|---|
| 1 | zio declares itself an implementation of `std.Io` | `ZIO/src/io.zig:4`: `//! Implementation of the `std.Io` interface backed by zio's runtime.` |
| 2 | zio's own docs say the same | `ZIO/docs/index.md:3`: "it's a full implementation of the standard library's `std.Io` interface, so any Zig 0.16+ code written against `std.Io` runs on zio unmodified." |
| 3 | zio builds one `Io.VTable` literal with all 109 slots | `ZIO/src/io.zig:152-275`, `pub const vtable: Io.VTable = .{ ... }` |
| 4 | `std.Io.VTable` has exactly 109 slots and no defaults | `STD/Io.zig:51-255`, counted with `sed -n '51,256p' STD/Io.zig \| grep -cE '^    [a-zA-Z_]+: \*const fn'` which returns `109`, and no field has a default value |
| 5 | a `std.Io` value can be built from a zio runtime | `ZIO/src/runtime.zig:2067` `pub fn io(self: *Runtime) std.Io` |
| 6 | a `*Runtime` can be recovered from a `std.Io` | `ZIO/src/runtime.zig:2082` `pub fn fromIo(value: std.Io) ?*Runtime` |
| 7 | the vtable pointer identity is the marker | `ZIO/src/runtime.zig:2084`: `if (value.vtable != &io_impl.vtable or value.userdata == null) return null;` |
| 8 | a runtime pointer is smuggled through `Io.userdata` | `ZIO/src/io.zig:124-136`, `encodeUserdata` and `decodeUserdata` tag the low bit of the pointer with a dispatch mode |
| 9 | zio's `Group` is a `std.Io.Group` with the same layout | `ZIO/src/group.zig:25` `inner: std.Io.Group = .init`, and `ZIO/src/group.zig:31` `pub fn fromStd(g: *std.Io.Group) *Group` is a bare `@ptrCast` |
| 10 | std code runs unchanged on zio | `ZIO/examples/http_client.zig:22` `var client: std.http.Client = .{ .allocator = gpa, .io = rt.io() };` then `client.request(...)` at `:30` |

Claim 9 is the strongest single piece. zio does not define a task group and
then adapt it. zio's `Group` **is** `std.Io.Group`, reinterpreting `token` as a
`WaitQueue` head and the low 32 bits of `state` as a combined counter and flag
word (`ZIO/src/group.zig:35-52`).

### 1.3 What each layer owns

| Concern | Owner | Evidence |
|---|---|---|
| The `Io` handle, its vtable, and the 109 slots | `std` | `STD/Io.zig:25-26`, `STD/Io.zig:51-255` |
| Buffering, cursor, and the reader and writer value types | `std` | `STD/Io/Reader.zig:16-21`, `STD/Io/Writer.zig:14-18` |
| Which syscall runs each operation, and on which thread | zio | `ZIO/src/io.zig:297-4780` |
| The event loop and its backends | zio | `ZIO/src/ev/root.zig:14-90` |
| Coroutines and stack management | zio | `ZIO/src/coro/root.zig` |
| Task scheduling across executors | zio | `ZIO/src/runtime.zig:441-1360` |
| Cancellation and timeouts | zio | `ZIO/src/autocancel.zig:27-120`, `ZIO/src/common.zig:608-670` |
| Synchronization primitives | both, in two spellings | `STD/Io.zig:1587` (`Io.Mutex`) against `ZIO/src/sync/Mutex.zig:56` (`zio.Mutex`) |

The last row matters. `std.Io.Mutex`, `std.Io.Condition`, `std.Io.Event`,
`std.Io.RwLock`, `std.Io.Semaphore`, `std.Io.Group`, and `std.Io.Queue` take an
`Io` parameter and go through the vtable. zio also exports its own
`Event`, `Mutex`, `RwLock`, `Semaphore`, `Channel`, and `Group`
(`ZIO/src/zio.zig:41`, `:79-88`), which park tasks without a vtable hop. The
port picks one family per module. Mixing them in one module costs a vtable call
per lock.

### 1.4 What this forces in the port design

Three decisions follow directly from the verdict.

1. **The runtime type that library code receives is `std.Io`, not
   `*zio.Runtime`.** A module that only reads and writes can then be tested
   against `std.Io.Threaded` with no zio in the picture. zio's own README
   states this preference: "prefer the `std.Io` interface, especially if you are
   writing a library" (`ZIO/README.md`, Usage section).
2. **`*zio.Runtime` appears only where a task must be spawned, a group must be
   driven, or a timeout must be armed.** `Runtime.fromIo` (`ZIO/src/runtime.zig:2082`)
   is the bridge when a module already holds an `Io` and needs the runtime, and
   it returns `null` for a `std.Io` from another backend. Every such call site
   must handle `null`.
3. **zio does not wrap `std.Io`.** There is no `zio.Io`, no adapter layer, and
   no translation between a zio type and a `std.Io` type. The vtable literal at
   `ZIO/src/io.zig:152-275` *is* the integration.

### 1.5 A real project confirms the shape

`zomp`, an unrelated application, threads `io: std.Io` through its own modules
and keeps the runtime at the edge.

- `zomp/src/main.zig:84-88` creates the runtime with
  `zio.Runtime.init(init.gpa, .{ .executors = .auto, .enable_main_executor = true })`
  and defers `deinit`.
- `zomp/src/main.zig:90` takes one handle out of it: `const io = runtime.io();`
- `zomp/src/main.zig:107` passes that handle into the command layer:
  `run(io, init, out_stream.w, err_stream.w)`.
- `zomp/src/main.zig:139` shows the parameter the library code then takes:
  `fn run(io: std.Io, init: std.process.Init, out: *std.Io.Writer, err: *std.Io.Writer) cli_print.Error!u8`.
- `zomp/src/core/stream.zig:166`, `:197`, `:233` take `io: std.Io` per method.
- `zomp/build.zig:118-121` and `:142` name the import `zio`:
  `b.dependency("zio", .{ .target = target, .optimize = optimize }).module("zio")`
  then `exe.root_module.addImport("zio", zio)`.
- `zomp/docs/zomp-design.md:32` records the rule as decision D1: `io: std.Io`
  is a parameter in every module that does not need zio-specific features.

One difference from what the port needs. zomp schedules with `rt.spawn` and its
own scheduler rather than `zio.Group`, because `Group.spawn` returns no handle
and only logs task errors (`ZIO/src/group.zig:132-140` swallows the error and
calls `group.setFailed()`). The record is `zomp/docs/zomp-design.md:35`
(decision D4). The port has the same choice to make, and section 4 gives both
spellings.

## 2. The `std.Io` surface

This section lists every type the port meets in `std`. A port does not implement
any of it, because zio does. A port does pass `std.Io` values through its own
signatures, and a port does wrap `std.Io.Reader` and `std.Io.Writer` when it
owns a socket or a file.

### 2.1 The `Io` handle

There is no `pub const Io` in the file. The type is the file's own struct.

```
STD/Io.zig:15   const Io = @This();
STD/Io.zig:25   userdata: ?*anyopaque,
STD/Io.zig:26   vtable: *const VTable,
```

The handle is two machine words. `userdata` is the backend pointer. `vtable` is
the backend's dispatch table. Every `std.Io` free function forwards to
`io.vtable.<slot>(io.userdata, ...)`, for example `STD/process.zig:69`:

```zig
return io.vtable.processCurrentPath(io.userdata, buffer);
```

### 2.2 Re-exports

| Path | Declaration | Evidence |
|---|---|---|
| `std.Io.Threaded` | thread-per-call backend | `STD/Io.zig:28` |
| `std.Io.fiber` | context-switch primitives | `STD/Io.zig:30` |
| `std.Io.Evented` | per-OS backend selector | `STD/Io.zig:31-36` |
| `std.Io.Dispatch` | Darwin dispatcher | `STD/Io.zig:37` |
| `std.Io.Kqueue` | BSD backend | `STD/Io.zig:38` |
| `std.Io.Uring` | Linux backend | `STD/Io.zig:39` |
| `std.Io.Reader` | buffered reader | `STD/Io.zig:41` |
| `std.Io.Writer` | buffered writer | `STD/Io.zig:42` |
| `std.Io.net` | sockets | `STD/Io.zig:43` |
| `std.Io.Dir` | directories | `STD/Io.zig:44` |
| `std.Io.File` | files | `STD/Io.zig:45` |
| `std.Io.Terminal` | terminal colour | `STD/Io.zig:46` |
| `std.Io.RwLock` | reader-writer lock | `STD/Io.zig:48` |
| `std.Io.Semaphore` | counting semaphore | `STD/Io.zig:49` |

`std.Io.Evented` is a compile-time choice, not a runtime one
(`STD/Io.zig:31-36`): `.linux => Uring`, the BSDs `=> Kqueue`, Apple platforms
`=> Dispatch`, everything else `void`. It is `void` when the fiber backend is
unavailable, and it is only referenced when someone asks for it by name.

### 2.3 `Io.VTable`, the 109 slots in field order

This is the layout a backend fills. Field order matters only for readability,
because every field is named in the literal. The line numbers are the field
declarations in `STD/Io.zig`.

| Line | Slot | Signature |
|---|---|---|
| 52 | `crashHandler` | `(?*anyopaque) void` |
| 61 | `async` | `(?*anyopaque, []u8, std.mem.Alignment, []const u8, std.mem.Alignment, *const fn (*const anyopaque, *anyopaque) void) ?*AnyFuture` |
| 75 | `concurrent` | same shape, returns `Io.ConcurrentError!*AnyFuture` |
| 88 | `await` | `(?*anyopaque, *AnyFuture, []u8, bool) void` |
| 103 | `cancel` | `(?*anyopaque, *AnyFuture) void` |
| 119 | `groupAsync` | `(?*anyopaque, *Group, *anyopaque, []u8, std.mem.Alignment, []const u8, std.mem.Alignment, *const fn (...)) void` |
| 130 | `groupConcurrent` | same shape, returns `Io.ConcurrentError!void` |
| 140 | `groupAwait` | `(?*anyopaque, *Group, *anyopaque) Cancelable!void` |
| 141 | `groupCancel` | `(?*anyopaque, *Group, *anyopaque) void` |
| 143 | `recancel` | `(?*anyopaque) void` |
| 144 | `swapCancelProtection` | `(?*anyopaque, CancelProtection) CancelProtection` |
| 145 | `checkCancel` | `(?*anyopaque) Cancelable!void` |
| 147 | `futexWait` | `(?*anyopaque, *const u32, u32, Timeout) Cancelable!void` |
| 148 | `futexWaitUncancelable` | `(?*anyopaque, *const u32, u32) void` |
| 149 | `futexWake` | `(?*anyopaque, *const u32, u32) void` |
| 151 | `operate` | `(?*anyopaque, Operation) Cancelable!Operation.Result` |
| 152 | `batchAwaitAsync` | `(?*anyopaque, *Batch) Cancelable!void` |
| 153 | `batchAwaitConcurrent` | `(?*anyopaque, *Batch, Timeout) Batch.AwaitConcurrentError!void` |
| 154 | `batchCancel` | `(?*anyopaque, *Batch) void` |
| 156-181 | 26 `dir*` slots | directory create, open, stat, access, rename, symlink, readlink, chmod, chown, timestamps, hardlink |
| 183-206 | 23 `file*` slots | stat, length, close, positional read and write, `writeFile` in two modes, seek, sync, tty, ansi, set length, owner, permissions, timestamps, lock, try-lock, unlock, downgrade, realpath, hardlink |
| 208-212 | 5 `fileMemoryMap*` slots | create, destroy, set length, read, write |
| 214-227 | 14 `process*` and `child*` slots | executable open and path, stderr lock trio, current path, set current dir and path, replace in two forms, spawn in two forms, childWait, childKill |
| 229 | `progressParentFile` | `(?*anyopaque) std.Progress.ParentFileError!File` |
| 231 | `now` | `(?*anyopaque, Clock) Timestamp` |
| 232 | `clockResolution` | `(?*anyopaque, Clock) Clock.ResolutionError!Duration` |
| 233 | `sleep` | `(?*anyopaque, Timeout) Cancelable!void` |
| 235 | `random` | `(?*anyopaque, []u8) void` |
| 236 | `randomSecure` | `(?*anyopaque, []u8) RandomSecureError!void` |
| 238-254 | 16 `net*` slots | listen, accept, bind, connect, unix listen and connect, socket pair, send, read, write, writeFile, close, shutdown, interface name resolve and name, lookup |

The exact signature text for the directory, file, process, and network blocks is
in the source. `STD/Io.zig:156-181`, `:183-212`, `:214-236`, and `:238-254`
give each field with its full parameter list, for example `STD/Io.zig:226`:

```zig
childWait: *const fn (?*anyopaque, *std.process.Child) std.process.Child.WaitError!std.process.Child.Term,
```

### 2.4 Which slots have a default

**None in `Io.VTable`.** Every one of the 109 fields is mandatory. A struct
literal in Zig must set every field that has no default, so a backend that omits
one does not compile. `Uring.io`, `Dispatch.io`, and zio's `io.zig` vtable each
set all 109. The count is 109 in all three, measured with
`grep -cE '^            \.[a-zA-Z]+ ='` over each literal.

`Io.zig` also exports 15 free functions named `no*` at `STD/Io.zig:2640`,
`2644`, `2695`, `2753`, `2758`, `2763`, `2884`, `2989`, `3037`, `3046`, `3126`,
`3225`, `3297`, `3308`, and `3320`. These are **optional** implementations a
backend may point a slot at. They are not defaults, because a literal that
omits a slot still fails to compile. zio uses two of them at `ZIO/src/io.zig:209-210`:

```zig
.fileWriteFileStreaming = Io.noFileWriteFileStreaming,
.fileWriteFilePositional = Io.noFileWriteFilePositional,
```

### 2.5 `Io.Reader` and `Io.Writer`

These two are vtable interfaces too, and these two do have defaults. A port
writes one of each whenever it owns a socket or a file, because it supplies
exactly three or two slots.

`Io.Reader` value, field order (`STD/Io/Reader.zig:16-21`):

| Line | Field | Type |
|---|---|---|
| 16 | `vtable` | `*const VTable` |
| 17 | `buffer` | `[]u8` |
| 19 | `seek` | `usize`, bytes consumed from `buffer` |
| 21 | `end` | `usize`, `buffer[0..end]` valid, rest undefined |

`Io.Reader.VTable` (`STD/Io/Reader.zig:23-100`):

| Line | Slot | Default |
|---|---|---|
| 46 | `stream` | none. `*const fn (r: *Reader, w: *Writer, limit: Limit) StreamError!usize` |
| 67 | `discard` | `defaultDiscard` at `STD/Io/Reader.zig:196` |
| 87 | `readVec` | `defaultReadVec` at `STD/Io/Reader.zig:440` |
| 99 | `rebase` | `defaultRebase` at `STD/Io/Reader.zig:1411` |

`Io.Writer` value, field order (`STD/Io/Writer.zig:14-18`):

| Line | Field | Type |
|---|---|---|
| 14 | `vtable` | `*const VTable` |
| 16 | `buffer` | `[]u8`, length zero means unbuffered |
| 18 | `end` | `usize` |

`Io.Writer.VTable` (`STD/Io/Writer.zig:20-89`):

| Line | Slot | Default |
|---|---|---|
| 46 | `drain` | none. `*const fn (w: *Writer, data: []const []const u8, splat: usize) Error!usize` |
| 63 | `sendFile` | `unimplementedSendFile` at `STD/Io/Writer.zig` |
| 80 | `flush` | `defaultFlush` |
| 88 | `rebase` | `defaultRebase` |

Two error sets decide what a port must handle. `Io.Reader.Error` is
`error{ ReadFailed, EndOfStream }` (`STD/Io/Reader.zig:112-116`) and
`Io.Writer.Error` is `error{ WriteFailed }` (`STD/Io/Writer.zig:91-94`).
**Neither contains `error.Canceled`.** The cancel error set is
`Io.Cancelable = error{Canceled}` at `STD/Io.zig:704-707`.

The consequence is concrete. When a task is canceled while parked in a
`std.Io.Reader`, the caller sees `error.ReadFailed`, not `error.Canceled`. The
precise cause is stashed on the owning wrapper. `STD/Io/File/Reader.zig:247-264`
catches the vtable error, writes it to `r.err`, and returns the narrow
`error.ReadFailed`. The same happens on the streaming path at
`STD/Io/File/Reader.zig:283-292`. The concrete types that do carry
`error.Canceled` are `Io.File.Reader`, whose error set is
`Io.Operation.FileReadStreaming.UnendingError || Io.Cancelable`
(`STD/Io/File/Reader.zig:29`), `Io.File.Writer`, and zio's own
`fs.FileReader` (`ZIO/src/fs.zig:1205`).

The methods a port calls on these two types, with their exact lines:

| Call | Evidence |
|---|---|
| `reader.takeByte()` | `STD/Io/Reader.zig:1157`, returns `Error!u8` |
| `reader.takeDelimiterInclusive(d)` | `STD/Io/Reader.zig:802`, returns `DelimiterError![]u8` |
| `reader.takeDelimiterExclusive(d)` | `STD/Io/Reader.zig:872` |
| `reader.fill(n)` | `STD/Io/Reader.zig:1105` |
| `reader.toss(n)` | `STD/Io/Reader.zig:544` |
| `reader.streamRemaining(w)` | `STD/Io/Reader.zig:258` |
| `writer.writeAll(bytes)` | `STD/Io/Writer.zig:549`, returns `Error!void` |
| `writer.writeByte(byte)` | `STD/Io/Writer.zig:743` |
| `writer.flush()` | `STD/Io/Writer.zig:312`, forwards to `w.vtable.flush(w)` |
| `writer.print(fmt, args)` | `STD/Io/Writer.zig:612` |

### 2.6 `Io.File`, `Io.File.Reader`, `Io.File.Writer`

`Io.File` is a handle and a flag word, not an interface.

| Line | Field | Type |
|---|---|---|
| `STD/Io/File.zig:12` | `handle` | `Handle` |
| `STD/Io/File.zig:13` | `flags` | `Flags` |
| `STD/Io/File.zig:26` | `Handle` | `std.posix.fd_t` |

The nested reader holds the `Io` and exposes an `interface` field:

| Line | Item |
|---|---|
| `STD/Io/File/Reader.zig:17` | `io: Io` |
| `STD/Io/File/Reader.zig:19` | `file: File` |
| `STD/Io/File/Reader.zig:27` | `interface: Io.Reader` |
| `STD/Io/File/Reader.zig:71` | `pub fn initInterface(buffer: []u8) Io.Reader`, sets `.stream` and `.discard` only |
| `STD/Io/File/Reader.zig:84` | `pub fn init(file: File, io: Io, buffer: []u8) Reader` |
| `STD/Io/File/Reader.zig:92` | `pub fn initSize(file: File, io: Io, buffer: []u8, size: ?u64) Reader` |
| `STD/Io/File/Reader.zig:104` | `pub fn initStreaming(file: File, io: Io, buffer: []u8) Reader` |
| `STD/Io/File/Writer.zig:19` | `interface: Io.Writer` |
| `STD/Io/File/Writer.zig:36` | `pub fn init(file: File, io: Io, buffer: []u8) Writer` |
| `STD/Io/File/Writer.zig:48` | `pub fn initStreaming(file: File, io: Io, buffer: []u8) Writer` |
| `STD/Io/File/Writer.zig:58` | `pub fn initDetect(file: File, io: Io, buffer: []u8) Io.Cancelable!Writer` |
| `STD/Io/File/Writer.zig:67` | `pub fn initInterface(buffer: []u8) Io.Writer`, sets `.drain` and `.sendFile` only |

The `@fieldParentPtr` recovery in the vtable implementations is the pattern the
port copies. `STD/Io/File/Reader.zig:201` does
`const r: *Reader = @alignCast(@fieldParentPtr("interface", io_reader));`.

### 2.7 `Io.Group`

`Io.Group` is **not** an interface. It is a two-field struct, and its behaviour
comes from the four `group*` vtable slots.

| Line | Item |
|---|---|
| `STD/Io.zig:1224` | `token: std.atomic.Value(?*anyopaque)` |
| `STD/Io.zig:1226` | `state: usize` |
| `STD/Io.zig:1228` | `pub const init: Group = .{ .token = .init(null), .state = 0 };` |
| `STD/Io.zig:1240` | `pub fn async(g: *Group, io: Io, function: anytype, args: ...) void` |
| `STD/Io.zig:1261` | `pub fn concurrent(g: *Group, io: Io, function: anytype, args: ...) ConcurrentError!void` |
| `STD/Io.zig:1282` | `pub fn await(g: *Group, io: Io) Cancelable!void` |
| `STD/Io.zig:1298` | `pub fn cancel(g: *Group, io: Io) void` |

### 2.8 The concrete backends

None of these is an interface. Each is a struct with a `pub fn io(...) Io` that
builds a `VTable` literal.

| Type | Constructor | Init | Vtable literal |
|---|---|---|---|
| `Io.Threaded` | `STD/Io/Threaded.zig:1806` `pub fn io(t: *Threaded) Io` | `STD/Io/Threaded.zig:1607` `pub fn init(gpa: Allocator, options: InitOptions) Threaded` | from `:1809` |
| `Io.Uring` | `STD/Io/Uring.zig:664` `pub fn io(ev: *Evented) Io` | `STD/Io/Uring.zig:814` `pub fn init(ev: *Evented, backing_allocator: Allocator, options: InitOptions) !void` | from `:667` |
| `Io.Dispatch` | `STD/Io/Dispatch.zig:344` `pub fn io(ev: *Evented) Io` | `STD/Io/Dispatch.zig:490` `pub fn init(ev: *Evented, backing_allocator: Allocator, options: InitOptions) !void` | `:347-470` |
| `Io.Kqueue` | `STD/Io/Kqueue.zig:610` `pub fn io(k: *Kqueue) Io` | `STD/Io/Kqueue.zig:164` `pub fn init(k: *Kqueue, gpa: Allocator, options: InitOptions) !void` | `:613-661` |

`Io.Threaded` also has the two global single-threaded instances, which the port
must not use at runtime.

| Line | Item |
|---|---|
| `STD/Io/Threaded.zig:1674` | `pub const init_single_threaded: Threaded` |
| `STD/Io/Threaded.zig:1693` | `var global_single_threaded_instance: Threaded = .init_single_threaded;` |
| `STD/Io/Threaded.zig:1704` | `pub const global_single_threaded: *Threaded = &global_single_threaded_instance;` |

`STD/Io/Threaded.zig:1695-1704` says plainly that "library code should accept an
`Io` parameter rather than accessing this declaration" and that most code should
avoid the declaration entirely. zio uses it once, for a narrow fallback at
`ZIO/src/io.zig:284-286`:

```zig
fn globalIo() Io {
    return std.Io.Threaded.global_single_threaded.io();
}
```

The port must not copy that pattern. It is a process-global.

`Io.Threaded.InitOptions` is at `STD/Io/Threaded.zig:1573-1603` with
`stack_size`, `async_limit`, `concurrent_limit`, `argv0`, `environ`, and
`disable_memory_mapping`. `Io.Threaded.setAsyncLimit` is at
`STD/Io/Threaded.zig:1706` and `deinit` at `:1712`.

### 2.9 A defect in `Io.Kqueue` that the port should know about

`Io.Kqueue.io` builds a vtable literal with 43 slots, not 109, and three of the
names it uses no longer exist.

```
STD/Io/Kqueue.zig:637   .fileWriteStreaming = fileWriteStreaming,
STD/Io/Kqueue.zig:639   .fileReadStreaming = fileReadStreaming,
STD/Io/Kqueue.zig:658   .netReceive = netReceive,
```

`Io.VTable` has no `fileWriteStreaming`, no `fileReadStreaming`, and no
`netReceive` (`STD/Io.zig:51-255`). `Io.VTable` has no default for `crashHandler`
(`STD/Io.zig:52`), and the Kqueue literal does not set it. The literal sets 43
fields, measured with `grep -cE '^            \.[a-zA-Z]+ ='` over
`STD/Io/Kqueue.zig:613-661`.

Since `Io.VTable` has no defaults, `Io.Kqueue.io` cannot compile. `[INFERENCE]`
The whole of `STD/Io/Kqueue.zig` is therefore dead in 0.16.0, and `Io.Evented` on
the BSDs (`STD/Io.zig:33`) is a reference to code that cannot build. zio does
not depend on it: zio ships its own kqueue backend at
`ZIO/src/ev/backends/kqueue.zig` and selects it at `ZIO/src/ev/backend.zig:9`.
The port is unaffected, and the finding matters only because a reader comparing
`Io.Kqueue` with `zio.ev` backends will find two different things under one name.

### 2.10 The rest of the surface

| Type | Shape | Evidence |
|---|---|---|
| `Io.Terminal` | `writer: *Io.Writer` at `:12`, `mode: Mode` at `:13`; `Mode` is a `union(enum)` at `:37` | `STD/Io/Terminal.zig` |
| `Io.Semaphore` | `mutex: Io.Mutex = .init` at `:13`, `cond: Io.Condition = .init` at `:14`, `permits: usize = 0` at `:16`; methods `wait` `:18`, `waitUncancelable` `:26`, `post` `:34` | `STD/Io/Semaphore.zig` |
| `Io.RwLock` | `pub const init` at `:15` | `STD/Io/RwLock.zig` |
| `Io.fiber` | `supported` at `:1`, `Context` at `:7`, `Switch` at `:26`, `contextSwitch` at `:29` | `STD/Io/fiber.zig` |
| `Io.net` | module namespace, no vtable | `STD/Io/net.zig:1`, re-exported at `STD/Io.zig:43` |
| `Io.Dir` | module namespace | `STD/Io/Dir.zig:1`, re-exported at `STD/Io.zig:44` |
| `Io.Mutex` | `extern struct` with `state: std.atomic.Value(State)` and `tryLock` | `STD/Io.zig:1587-1599` |
| `Io.Event` | `enum(u32) { unset, waiting, is_set }` with `isSet` and `wait(event: *Event, io: Io) Cancelable!void` | `STD/Io.zig:1766-1790` |

zio carries its own copies of most of these, and section 3 lists them. The port
uses one family, not two.

## 3. The `zio` surface

The whole public surface is one file, `ZIO/src/zio.zig`, 119 lines. Everything
else is reachable through it. The table below is that file, line by line, grouped
by what the port would use.

### 3.1 The root module

| Line | Export | Kind |
|---|---|---|
| 10 | `Options` | root module configuration |
| 11 | `Scheduling` | `single_executor`, `pinned`, `work_stealing` |
| 14 | `Runtime` | the runtime |
| 15 | `RuntimeOptions` | constructor options |
| 16 | `JoinHandle` | `JoinHandle(T)` |
| 17 | `Placement` | where `spawnInto` puts a task |
| 18 | `ExecutorId` | `u5` on 32-bit, `u6` on 64-bit |
| 21 | `spawn` | free function, task context only |
| 22 | `spawnInto` | free function, task context only |
| 23 | `spawnBlocking` | free function, task context only |
| 24-25 | `yield`, `maybeYield` | `Cancelable!void` |
| 26 | `sleep` | `fn (Duration) Cancelable!void` |
| 27 | `now` | `fn () Timestamp` |
| 29-31 | `random`, `randomSecure`, `RandomSecureError` | entropy |
| 32-35 | `beginShield`, `endShield`, `checkCancel`, `recancel` | cancellation control |
| 37-39 | `AutoCancel`, `withTimeout`, `WithTimeoutResult` | scoped timeouts |
| 41 | `Group` | structured concurrency |
| 42 | `CompletionQueue` | many operations, one driver |
| 44 | `TaskLocal` | task-local storage |
| 47-49 | `Cancelable`, `Timeoutable`, `Closeable` | the three error sets |
| 50-51 | `blockInPlace`, `blockInPlaceReserved` | run a function on the blocking pool |
| 54-58 | `Duration`, `Timestamp`, `Timeout`, `Clock`, `Stopwatch` | time |
| 61-71 | `File`, `Dir`, `AtomicFile`, `TempFile`, `TempDir`, `PipePair`, `openSystemTempDir`, `createTempFile`, `createTempDir`, `max_temp_prefix_len`, `max_temp_name_len` | files |
| 73-75 | `stdin`, `stdout`, `stderr` | standard handles, as `fn () File` |
| 77 | `net` | the network module |
| 79-88 | `Mutex`, `Condition`, `Event`, `RwLock`, `Semaphore`, `Barrier`, `Futex`, `Channel`, `BroadcastChannel`, `Future` | synchronization |
| 93-94 | `Signal`, `SignalKind` | POSIX signals |
| 96-99 | `select`, `wait`, `SelectResult`, `WaitResult` | the future protocol |
| 101 | `debug_io` | the `std.Io` used by `std.log` and `std.debug.print` |
| 104 | `coro` | low-level coroutines |
| 107 | `ev` | low-level event loop |
| 110 | `os` | low-level OS wrappers |

One entry is a deprecated alias that a clean cutover must delete rather than
carry: `ZIO/src/zio.zig:91` `pub const ResetEvent = Event;` with the comment
"Deprecated, will be removed in a future release." The port does not use it.

### 3.2 `Runtime`

| Line | Declaration |
|---|---|
| `ZIO/src/runtime.zig:1569` | `pub const Runtime = struct {` |
| `ZIO/src/runtime.zig:1620` | `pub fn init(allocator: Allocator, options: RuntimeOptions) !*Runtime` |
| `ZIO/src/runtime.zig:1629` | `pub fn initStatic(self: *Runtime, allocator: Allocator, options: RuntimeOptions) !void` |
| `ZIO/src/runtime.zig:1759` | `pub fn deinit(self: *Runtime) void` |
| `ZIO/src/runtime.zig:1816` | `pub fn spawn(self: *Runtime, func: anytype, args: std.meta.ArgsTuple(@TypeOf(func))) !JoinHandle(meta.ReturnType(func))` |
| `ZIO/src/runtime.zig:1821` | `pub fn spawnInto(self: *Runtime, placement: Placement, func: anytype, args: ...) !JoinHandle(meta.ReturnType(func))` |
| `ZIO/src/runtime.zig:1850` | `pub fn spawnBlocking(self: *Runtime, func: anytype, args: ...) !JoinHandle(meta.ReturnType(func))` |
| `ZIO/src/runtime.zig:1920` | `pub fn schedulerMetrics(self: *Runtime) SchedulerMetrics` |
| `ZIO/src/runtime.zig:2067` | `pub fn io(self: *Runtime) std.Io` |
| `ZIO/src/runtime.zig:2075` | `pub fn blockingIo(self: *Runtime) std.Io` |
| `ZIO/src/runtime.zig:2082` | `pub fn fromIo(value: std.Io) ?*Runtime` |

`init` allocates the runtime on the heap and sets `own_self = true`
(`ZIO/src/runtime.zig:1621-1626`), so `deinit` frees it at
`ZIO/src/runtime.zig:1810-1812`. `initStatic` fills a caller-owned struct, which
suits a static or arena-allocated runtime. `RuntimeOptions` is at
`ZIO/src/runtime.zig:134-159` with `thread_pool`, `stack_pool`,
`metrics_log_interval`, `executors`, `enable_main_executor`, and `dns`.

`Runtime` also carries six methods that forward to module functions and are
marked "Deprecated" in their own doc comments: `yield` at `:2028`, `sleep` at
`:2035`, `beginShield` at `:2041`, `endShield` at `:2047`, `checkCancel` at
`:2055`, and `now` at `:2062`. A clean cutover calls the `zio.` free functions
and not these.

The module-level `spawn`, `spawnInto`, and `spawnBlocking`
(`ZIO/src/runtime.zig:1492`, `:1499`, `:1506`) each start with
`const rt = getCurrentExecutor().runtime;` and carry the doc line "Panics if
called outside of a task context." `getCurrentExecutor` is
`ZIO/src/runtime.zig:1363`. **From `main`, and from any foreign thread, the port
must call `rt.spawn`, not `zio.spawn`.** zomp makes exactly this split:
`zomp/src/main.zig:970` calls `zio.spawn` from inside a task, and the runtime
handle is the one from `zomp/src/main.zig:84`.

`Placement` is at `ZIO/src/runtime.zig:361-369`:

```zig
pub const Placement = union(enum) {
    auto,
    local,
    executor: ExecutorId,
};
```

### 3.3 `JoinHandle`

`JoinHandle(T)` is at `ZIO/src/runtime.zig:169-298`. It is a by-pointer handle
holding `awaitable: ?*Awaitable` and `result: T`.

| Line | Method | Behaviour |
|---|---|---|
| 193 | `join(self: *Self) T` | waits, returns the result. If the current task is canceled while waiting, the spawned task is canceled too (doc at `:186`) |
| 206 | `hasResult(self: *const Self) bool` | non-blocking poll |
| 216 | `getResult(self: *Self) T` | asserts the task already completed |
| 226 | `asyncWait(self: Self, waiter: *Waiter) common.AsyncWaitState` | future protocol for `select` |
| 241 | `asyncCancelWait(self: Self, waiter: *Waiter) bool` | future protocol |
| 260 | `cancel(self: *Self) void` | request cancellation and wait for completion. No-op after `join` (`:265-268`) |
| 289 | `detach(self: *Self) void` | run the task in the background, discard the result |

`cancel` and `join` are mutually forgiving. `cancel` returns immediately when
`awaitable` is null (`:262`), and it only cleans up when the task already has a
result (`:265-268`). The recommended idiom is in the doc comment at
`ZIO/src/runtime.zig:252-259`: `defer handle.cancel()` immediately after the
spawn, then `join()` later.

### 3.4 `Group`

`Group` is at `ZIO/src/group.zig:24-320`. Its single field is
`inner: std.Io.Group = .init` (`ZIO/src/group.zig:25`).

| Line | Method |
|---|---|
| 27 | `pub const init: Group = .{};` |
| 31 | `pub fn fromStd(g: *std.Io.Group) *Group` |
| 66 | `pub fn setFailed(self: *Group) void` |
| 78 | `pub fn hasFailed(self: *Group) bool` |
| 85 | `pub fn setCanceled(self: *Group) void` |
| 97 | `pub fn isCanceled(self: *Group) bool` |
| 105 | `pub fn setFailFast(self: *Group) void` |
| 110 | `pub fn isFailFast(self: *Group) bool` |
| 118 | `pub fn spawn(self: *Group, func: anytype, args: ...) !void` |
| 123 | `pub fn spawnInto(self: *Group, placement: Placement, func: anytype, args: ...) !void` |
| 151 | `pub fn spawnBlocking(self: *Group, func: anytype, args: ...) !void` |
| 190 | `pub fn wait(group: *Group) Cancelable!void` |
| 207 | `pub fn cancel(group: *Group) void` |
| 263 | `pub fn asyncWait(self: *Group, waiter: *Waiter, ctx: *WaitContext) common.AsyncWaitState` |
| 313 | `pub fn asyncCancelWait(self: *Group, waiter: *Waiter, ctx: *WaitContext) bool` |

Three behaviours a port must design around.

1. **`Group.spawn` returns no handle and swallows the task error.** The wrapper
   at `ZIO/src/group.zig:129-145` catches the error and either calls
   `group.setCanceled()` for `error.Canceled` or logs and calls
   `group.setFailed()` for anything else. The return value is `void`, so the
   task's error never reaches the caller. `group.wait()` at
   `ZIO/src/group.zig:190` returns `Cancelable!void` and does not report the
   failure either, only `hasFailed()` at `:78` does.
2. **`Group.wait` is `Cancelable!void`, not `error{GroupFailed}!void`.** A
   failed group is invisible unless the caller polls `hasFailed()`.
3. **`Group` is reusable after `wait` and after `cancel`.** The doc comment at
   `ZIO/src/group.zig:187-189` says "Neither this nor `cancel` closes a group
   permanently: `cancel` clears the flag again on its way out". Only a failure
   or cancelation with `fail_fast` set leaves it closed (`:189`).

This is why `zomp` chose `Runtime.spawn` over `Group`
(`zomp/docs/zomp-design.md:35`).

### 3.5 The `io` module

`ZIO/src/io.zig` is 4780 lines and is the `std.Io` backend. Its public
declarations are four items.

| Line | Declaration |
|---|---|
| `ZIO/src/io.zig:61` | `pub const debug_io: Io = .{ .userdata = null, .vtable = &vtable };` |
| `ZIO/src/io.zig:93` | `pub fn zioFileToStd(file: zio_fs.File) Io.File` |
| `ZIO/src/io.zig:118` | `pub const Mode = enum { regular, blocking };` |
| `ZIO/src/io.zig:138` | `pub fn fromRuntime(rt: *Runtime, mode: Mode) Io` |
| `ZIO/src/io.zig:146` | `pub fn toRuntime(io: Io) *Runtime` |
| `ZIO/src/io.zig:152` | `pub const vtable: Io.VTable = .{ ... };`, 109 slots, `:153-275` |

`debug_io` exists so that `std.log` and `std.debug.print` do not block the event
loop. The root module installs it with
`pub const std_options_debug_io = zio.debug_io;`, as in
`ZIO/examples/sleep.zig:7`. Because its `userdata` is null,
`Runtime.fromIo(debug_io)` returns null (`ZIO/src/runtime.zig:2084`), so it must
never be used as the `io` a library module receives.

`Runtime.blockingIo()` (`ZIO/src/runtime.zig:2075`) returns a handle whose
`concurrent` and `async` dispatch to `spawnBlocking` instead of coroutine tasks
(`ZIO/src/io.zig:325`). The doc at `ZIO/src/runtime.zig:2071-2074` says the two
handles "share the same vtable and runtime; only the scheduling path for new
work differs".

### 3.6 The `net` module

`ZIO/src/net.zig` is 3296 lines. The port uses it only if it keeps zio's socket
types. The D-Bus and X11 adapters bring their own transports, so the port more
likely reads a Unix socket address through this module and does its own framing.

| Line | Declaration |
|---|---|
| `ZIO/src/net.zig:45` | `pub fn readBuf(handle: Handle, buf: ev.ReadBuf, timeout: Timeout) (ev.NetRecv.Error \|\| Timeoutable)!usize` |
| `ZIO/src/net.zig:51` | `pub fn writeBuf(handle: Handle, buf: ev.WriteBuf, timeout: Timeout) (ev.NetSend.Error \|\| Timeoutable)!usize` |
| `ZIO/src/net.zig:73` | `pub const HostName = struct` with `validate` `:98`, `init` `:148`, `eql` `:154`, `lookup` `:174`, `connect` `:188` |
| `ZIO/src/net.zig:253` | `pub const IpAddress = extern union` with `parseIp4` `:316`, `parseIp6` `:328`, `parseIp` `:387`, `bind` `:643`, `listen` `:659`, `connect` `:676` |
| `ZIO/src/net.zig:685` | `pub const UnixAddress = extern union` with `init` `:696`, `bind` `:737`, `listen` `:752`, `connect` `:764` |
| `ZIO/src/net.zig:775` | `pub const Address = extern union` with `fromStd` `:811`, `fromPosix` `:831`, `connect` `:867` |
| `ZIO/src/net.zig:907` | `pub const Socket = struct` with `open` `:911`, `close` `:918`, `receive` `:1061`, `send` `:1068`, `receiveMsg` `:1098`, `sendMsg` `:1120`, `shutdown` `:1160` |
| `ZIO/src/net.zig:1167` | `pub const Server = struct` with `accept` `:1181`, `close` `:1201` |
| `ZIO/src/net.zig:1206` | `pub const Stream = struct` with `read` `:1212`, `write` `:1227`, `shutdown` `:1250`, `close` `:1255`, `reader` `:1431`, `writer` `:1436` |
| `ZIO/src/net.zig:1441` | `pub fn tcpConnectToHost(...)` |
| `ZIO/src/net.zig:1450` | `pub fn tcpConnectToAddress(addr: IpAddress, options: IpAddress.ConnectOptions) !Stream` |

`Stream.Reader` at `ZIO/src/net.zig:1259` and `Stream.Writer` at `:1322` both
hold a `std.Io.Reader` or `std.Io.Writer` as `interface`
(`ZIO/src/net.zig:1261` and `:1324`), and both have a `fromStd` that refuses a
foreign backend. `ZIO/src/net.zig:1281` asserts
`Runtime.fromIo(io) != null; // adopting the handle needs a zio-backed std.Io`.
A port that opens a socket through zio and then hands it to `std` code hits this
assert.

### 3.7 The `fs` module

`ZIO/src/fs.zig` is 2917 lines. Every operation returns an error set that
includes `zio.Cancelable`, for example `ZIO/src/fs.zig:1205-1206`:

```zig
pub const ReadError = os.fs.FileReadError || Cancelable;
pub const WriteError = os.fs.FileWriteError || Cancelable;
```

The port-relevant entry points:

| Line | Declaration |
|---|---|
| `ZIO/src/fs.zig:36-93` | module-level `openDir`, `openFile`, `deleteDir`, `deleteFile`, `deleteTree`, `rename`, `createDir`, `createFile`, `createAtomicFile`, `openSystemTempDir`, `createTempFile`, `createTempDir` |
| `ZIO/src/fs.zig:116` | `pub const PipePair = struct` with `close` at `:120` |
| `ZIO/src/fs.zig:126` | `pub fn createPipe() (os.fs.PipeError \|\| Cancelable)!PipePair` |
| `ZIO/src/fs.zig:136`, `:140`, `:144` | `pub fn stdin() File`, `stdout()`, `stderr()` |
| `ZIO/src/fs.zig:167` | `pub fn stat(path: []const u8) Dir.StatError!os.fs.FileStatInfo` |
| `ZIO/src/fs.zig:177` | `pub const Dir = struct` with `cwd` `:180`, `close` `:184`, and the path operations `:192-547` |
| `ZIO/src/fs.zig:1193` | `pub const File = struct` |
| `ZIO/src/fs.zig:1409` | `pub fn reader(self: File, buffer: []u8) Reader` |
| `ZIO/src/fs.zig:1413` | `pub fn writer(self: File, buffer: []u8) Writer` |
| `ZIO/src/fs.zig:1423` | `pub fn stdReader(self: File, buffer: []u8) std.Io.File.Reader` |
| `ZIO/src/fs.zig:1428` | `pub fn stdWriter(self: File, buffer: []u8) std.Io.File.Writer` |
| `ZIO/src/fs.zig:1447` | `pub const FileReader = struct`, `interface: std.Io.Reader` at `:1455` |
| `ZIO/src/fs.zig:1631` | `pub const FileWriter = struct`, `interface: std.Io.Writer` at `:1639` |

`stdReader` and `stdWriter` are the documented bridge for std APIs that demand
the exact type `std.Io.File.Reader` or `std.Io.File.Writer`
(`ZIO/src/fs.zig:1417-1422`). The doc at `ZIO/src/fs.zig:1420-1422` is explicit
that "I/O through it still goes through zio's runtime". The port uses these
whenever it hands a file to code that takes `std.Io.File.Reader`, for example
`std.Io.Writer.sendFileAll` (`STD/Io/Writer.zig:970`).

### 3.8 The `process` module

`ZIO/src/process.zig` is 123 lines. Two public functions.

| Line | Declaration |
|---|---|
| `ZIO/src/process.zig:15` | `pub fn childWait(child: *std.process.Child) std.process.Child.WaitError!std.process.Child.Term` |
| `ZIO/src/process.zig:31` | `pub fn childKill(child: *Child) void` |

Both drive `ev.ProcessWait` (`ZIO/src/process.zig:16` and `:33`) rather than
`posix.waitpid`. The spawn side needs no zio call: `std.process.spawn` already
takes an `Io` (`STD/process.zig:442`
`pub fn spawn(io: Io, options: SpawnOptions) SpawnError!Child`) and dispatches
into zio through the `processSpawn` vtable slot (`STD/Io.zig:224`). zio's own
tests show the pattern at `ZIO/src/process.zig:94`:
`var child = try std.process.spawn(rt.io(), .{ .argv = argv_exit0 });`.

### 3.9 The `time` module

`ZIO/src/time.zig` is 925 lines.

| Line | Declaration |
|---|---|
| `ZIO/src/time.zig:46` | `pub const Clock = enum(u8)` |
| `ZIO/src/time.zig:64` | `pub fn fromStd(clock: std.Io.Clock) Clock` |
| `ZIO/src/time.zig:75` | `pub fn fromStdTimeout(t: std.Io.Timeout) Clock` |
| `ZIO/src/time.zig:86` | `pub fn resolution(clock: Clock) ?Duration` |
| `ZIO/src/time.zig:92` | `pub const Duration = struct { value: TimeInt }` |
| `ZIO/src/time.zig:98-122` | `fromNanoseconds`, `fromMicroseconds`, `fromMilliseconds`, `fromSeconds`, `fromMinutes` |
| `ZIO/src/time.zig:176` | `pub fn format(self: Duration, w: *std.Io.Writer) std.Io.Writer.Error!void` |
| `ZIO/src/time.zig:285` | `pub fn parse(s: []const u8) ParseError!Duration` |
| `ZIO/src/time.zig:365` | `pub const Timestamp = struct { value: TimeInt }` |
| `ZIO/src/time.zig:370` | `pub fn now(clock: Clock) Timestamp` |
| `ZIO/src/time.zig:411` | `pub fn durationTo(from: Timestamp, to: Timestamp) Duration` |
| `ZIO/src/time.zig:415` | `pub fn untilNow(self: Timestamp, comptime clock: Clock) Duration` |
| `ZIO/src/time.zig:459` | `pub const Timeout = union(enum)` with `fromStd` `:469` |
| `ZIO/src/time.zig:548-611` | the future protocol on `Timeout`: `asyncWait` `:556`, `asyncCancelWait` `:600`, `getResult` `:611` |
| `ZIO/src/time.zig:622` | `pub const Stopwatch = struct` with `start` `:627`, `read` `:633`, `reset` `:639`, `lap` `:645` |

`Timeout` is a future, so it goes straight into `zio.select`. The example at
`ZIO/examples/ntp_client.zig:142-145` passes a `*zio.Timeout` and a `*zio.Signal`
as the two arms of one select.

`zio.now()` (`ZIO/src/runtime.zig:1551`) returns the event loop's **cached**
timestamp, not a fresh clock read (`ZIO/src/runtime.zig:2059-2060`). The port
must not treat it as a wall clock. `Timestamp.now(clock)` at
`ZIO/src/time.zig:370` is the real read.

### 3.10 The `sync` modules

`ZIO/src/sync/` holds ten modules. All of them have the same shape: a struct with
a `pub const init` constant, a parking method that returns `Cancelable!void`, an
uncancellable variant, and, where it applies, the future protocol.

| Type | File | `init` | Cancellable wait | Uncancelable | Timed | Signal |
|---|---|---|---|---|---|---|
| `Event` | `sync/Event.zig` | `:66` | `wait` `:110` | none | `waitTimeout` `:150` | `set` `:81`, `reset` `:99` |
| `Mutex` | `sync/Mutex.zig` | `:56` | `lock` `:72` | `lockUncancelable` `:87` | none | `unlock` `:101` |
| `Condition` | `sync/Condition.zig` | `:71` | `wait` `:92` | `waitUncancelable` `:141` | `waitTimeout` `:159` | `signal` `:230`, `broadcast` `:251` |
| `RwLock` | `sync/RwLock.zig` | `:59` | `lock` `:82`, `lockShared` `:160` | `:111`, `:183` | none | `unlock` `:124`, `unlockShared` `:204` |
| `Semaphore` | `sync/Semaphore.zig` | none | `wait` `:73` | `waitUncancelable` `:106` | `waitTimeout` `:122` | `post` `:160` |
| `Barrier` | `sync/Barrier.zig` | `init(count)` `:66` | `wait` `:91` returns `(Cancelable \|\| error{BrokenBarrier})!bool` | none | none | none |
| `Futex` | `sync/Futex.zig` | none | `wait` `:71` | `waitUncancelable` `:115` | `waitTimeout` `:140` | `wake` `:218` |
| `Channel` | `sync/channel.zig` | `Channel(T).init` | `send`, `receive` | `Closeable!` | none | `close` |
| `BroadcastChannel` | `sync/broadcast_channel.zig` | `:308` | `send`, `receive` | `Closeable \|\| error{Lagged}` | none | `close` |
| `Future` | `sync/future.zig` | `:73` | `await` | none | none | resolve |

The port needs `Event` and `Mutex` in almost every module, `Channel` in the
dispatcher, and `Semaphore` nowhere. `Mutex` works from a foreign thread as well
as from a task (`ZIO/src/sync/Mutex.zig:8` and `:69`), which matters for the
handshake between a C callback thread and the executor.

### 3.11 The `signal` module

| Line | Declaration |
|---|---|
| `ZIO/src/signal.zig:19` | `pub const SignalKind` |
| `ZIO/src/signal.zig:258` | `pub fn init(kind: SignalKind) !Signal` |
| `ZIO/src/signal.zig:267` | `pub fn deinit(self: *Signal) void` |
| `ZIO/src/signal.zig:280` | `pub fn wait(self: *Signal) Cancelable!void` |
| `ZIO/src/signal.zig:319` | `pub fn waitTimeout(self: *Signal, timeout: Timeout) (Timeoutable \|\| Cancelable)!void` |
| `ZIO/src/signal.zig:360` | `pub fn asyncWait(self: *Signal, waiter: *Waiter) common.AsyncWaitState` |
| `ZIO/src/signal.zig:400` | `pub fn getResult(self: *Signal) void` |

This is the cleanest example of "an external event becomes a task wakeup". The
signal arrives on an arbitrary thread and the waiting task resumes as if the
loop had woken it. Section 5 uses it as the model for the D-Bus callback.

### 3.12 The three error sets

| Line | Set | Members |
|---|---|---|
| `ZIO/src/common.zig:27-29` | `Cancelable` | `Canceled` |
| `ZIO/src/common.zig:32-34` | `Timeoutable` | `Timeout` |
| `ZIO/src/common.zig:37-39` | `Closeable` | `Closed` |

Every zio public operation that can be interrupted returns `Cancelable` or a
union containing it. That is the house rule on explicit error sets, applied
consistently. The port inherits it.

## 4. Construction and lifetime

### 4.1 The lifecycle in order

1. Create the runtime. `Runtime.init(allocator, options) !*Runtime` at
   `ZIO/src/runtime.zig:1620`. `Runtime.initStatic` at `:1629` fills a
   caller-owned struct instead. The allocator is a parameter, never a global.
2. Get one `std.Io` handle out of it. `Runtime.io()` at `:2067`.
3. Hand `std.Io` values to library code. Do not hand out `*Runtime` unless the
   code must spawn, group, or arm a timeout.
4. Spawn tasks. `rt.spawn(func, args)` at `:1816`, or `rt.spawnInto` at `:1821`,
   or `rt.spawnBlocking` at `:1850`.
5. Own every spawn with a `defer handle.cancel()` on the line after it. The
   idiom is in the doc comment at `ZIO/src/runtime.zig:252-259`.
6. Wait with `handle.join()` at `:193`, which returns the task result.
7. Destroy the runtime. `Runtime.deinit()` at `:1759` sets `shutting_down`
   (`:1763`), stops and joins the thread pool (`:1780`), joins the workers
   (`:1783`), and then asserts `task_count == 0` at `ZIO/src/runtime.zig:1786`.

That last assertion is the whole shutdown contract. **No task may outlive
`deinit`.** `zomp/src/main.zig:80-83` says so in its own comment: "`deinit`
asserts every task has settled, which is why nothing here may detach."

### 4.2 Group lifecycle

`Group.wait()` at `ZIO/src/group.zig:190` parks on a futex until the task counter
reaches zero (`ZIO/src/group.zig:195-200`). `Group.cancel()` at `:207` shields
the caller (`ZIO/src/group.zig:208-209`), sets the canceled flag (`:211`), pops
every task and cancels it (`:216-221`), waits for the counter to drain
(`:224-230`), then clears the flag for reuse (`:233`).

`Group.wait` has an `errdefer group.cancel()` at `ZIO/src/group.zig:191`, so a
canceled wait cancels the group on the way out.

### 4.3 A complete program

The program below starts a runtime, spawns two tasks, one of which awaits an
`std.Io.Reader` and the other of which writes to an `std.Io.Writer`, and
cancels cleanly. Every line is attributed.

```zig
// 1  const std = @import("std");
//      ZIO/examples/sleep.zig:4
// 2  const zio = @import("zio");
//      ZIO/examples/sleep.zig:5
// 3  pub const std_options_debug_io = zio.debug_io;
//      ZIO/examples/sleep.zig:7, and ZIO/src/zio.zig:101

// 4  /// A task can fail from its own I/O, from a timeout, or from
// 5  /// cancellation. `Timeout` is here because `zio.FileReader` and
// 6  /// `zio.FileWriter` carry it (ZIO/src/fs.zig:1448 and :1632).
// 7  const TaskError = zio.Cancelable || error{
// 8      ReadFailed,
// 9      WriteFailed,
// 10     EndOfStream,
// 11     StreamTooLong,
// 12     Timeout,
// 13 };

// 14 /// One line of input, and the handoff between the two tasks.
// 15 const Line = struct {
// 16     ready: zio.Event = .init,      // ZIO/src/sync/Event.zig:66
// 17     bytes: [256]u8 = undefined,
// 18     len: usize = 0,
// 19 };

// 20 /// `std.Io.Reader.Error` is `error{ReadFailed, EndOfStream}` and
// 21 /// `std.Io.Writer.Error` is `error{WriteFailed}`. Neither carries
// 22 /// `error.Canceled` (STD/Io/Reader.zig:112-116, STD/Io/Writer.zig:91-94),
// 23 /// so the cause is recovered from the zio wrapper's `err` field, which
// 24 /// zio fills at ZIO/src/fs.zig:1490-1493 and ZIO/src/fs.zig:1679-1682.
// 25 /// `wrapper` is `anytype` because zio keeps the `fs` module private
// 26 /// (ZIO/src/zio.zig:60), so the wrapper types have no name outside zio.
// 27 fn causeOf(wrapper: anytype, fallback: TaskError) TaskError {
// 28     if (wrapper.err) |e| switch (e) {
// 29         error.Canceled => return error.Canceled,
// 30         error.Timeout => return error.Timeout,
// 31         else => {},
// 32     };
// 33     return fallback;
// 34 }

// 35 /// Task 1. Parks inside `Io.Reader.takeDelimiterInclusive` until a line
// 36 /// arrives on standard input.
// 37 fn read_line(line: *Line) TaskError!void {
// 38     var buffer: [256]u8 = undefined;
// 39     var reader = zio.stdin().reader(&buffer);   // ZIO/src/fs.zig:136, :1409
// 40     const got = reader.interface                 // ZIO/src/fs.zig:1455
// 41         .takeDelimiterInclusive('\n')           // STD/Io/Reader.zig:802
// 42         catch |err| switch (err) {
// 43         error.ReadFailed => return causeOf(reader, error.ReadFailed),
// 44         else => |e| return e,
// 45     };
// 46     @memcpy(line.bytes[0..got.len], got);
// 47     line.len = got.len;
// 48     line.ready.set();                            // ZIO/src/sync/Event.zig:81
// 49 }

// 50 /// Task 2. Parks on `Event.wait`, then writes through `Io.Writer`.
// 51 fn write_line(line: *Line) TaskError!void {
// 52     try line.ready.wait();                       // ZIO/src/sync/Event.zig:110
// 53     var buffer: [256]u8 = undefined;
// 54     var writer = zio.stdout().writer(&buffer);   // ZIO/src/fs.zig:140, :1413
// 55     writer.interface                              // ZIO/src/fs.zig:1639
// 56         .writeAll(line.bytes[0..line.len])        // STD/Io/Writer.zig:549
// 57         catch |err| switch (err) {
// 58         error.WriteFailed => return causeOf(writer, error.WriteFailed),
// 59         };
// 60     writer.interface
// 61         .flush()                                  // STD/Io/Writer.zig:312
// 62         catch |err| switch (err) {
// 63         error.WriteFailed => return causeOf(writer, error.WriteFailed),
// 64         };
// 65 }

// 66 pub fn main(init: std.process.Init) !void {
// 67     const rt = try zio.Runtime.init(init.gpa, .{});  // ZIO/src/runtime.zig:1620
// 68     defer rt.deinit();                              // ZIO/src/runtime.zig:1759
// 69
// 70     var line: Line = .{};
// 71
// 72     var reader_handle = try rt.spawn(read_line, .{&line});  // :1816
// 73     defer reader_handle.cancel();                        // :260
// 74     var writer_handle = try rt.spawn(write_line, .{&line}); // :1816
// 75     defer writer_handle.cancel();                        // :260
// 76
// 77     // The writer task ends when the reader task hands over the line.
// 78     try writer_handle.join();                           // :193
// 79
// 80     // Cancel the reader. With no input ever arriving the reader is still
// 81     // parked in `takeDelimiterInclusive` and this is a real cancellation.
// 82     // With a line already read the task has a result and `cancel` only
// 83     // releases the awaitable (ZIO/src/runtime.zig:265-268).
// 84     reader_handle.cancel();
// 85 }
```

Notes on the shape, all of them checked against the sources.

- **`rt.spawn`, not `zio.spawn`.** `zio.spawn` is `ZIO/src/runtime.zig:1492` and
  starts with `const rt = getCurrentExecutor().runtime;`. It panics outside a
  task. `main` is not a task. `rt.spawn` reaches the executor through
  `getNextExecutor` (`ZIO/src/runtime.zig:344`), which is pure atomics and no
  thread-local.
- **`init.gpa` is the allocator.** `std.process.Init.gpa` is
  `std.mem.Allocator` at `STD/process.zig:39`.
- **`const rt` is correct.** `init` returns `*Runtime`, and `deinit` takes
  `*Runtime` (`ZIO/src/runtime.zig:1759`), so the pointee is mutable through a
  const binding. `zomp/src/main.zig:84` does the same.
- **`reader.interface` is a real `std.Io.Reader`.** `ZIO/src/fs.zig:1455`
  declares `interface: std.Io.Reader,` and `ZIO/src/fs.zig:1463-1467` gives it a
  three-slot vtable with `.stream`, `.discard`, `.readVec`.
- **`causeOf` exists because the narrow errors lose the cause.** Section 2.5
  gives the full argument. Without it, a canceled read would be reported as
  `error.ReadFailed` and a shutdown would look like a hardware failure.
- **Both defers plus the explicit cancel are not redundant.** The defers are the
  early-return path. The explicit `reader_handle.cancel()` at the end is the
  normal path and is what makes the program drain rather than leave the reader
  parked until `deinit`.

### 4.4 The same program with a `Group`

When the port does not need a task result, `Group` is shorter.

```zig
var group: zio.Group = .init;              // ZIO/src/group.zig:27
defer group.cancel();                      // ZIO/src/group.zig:207
try group.spawn(read_line, .{&line});      // ZIO/src/group.zig:118
try group.spawn(write_line, .{&line});     // ZIO/src/group.zig:118
try group.wait();                          // ZIO/src/group.zig:190
```

This form loses two things and gains one. It loses the task results, because
`Group.spawn` returns `void` (`ZIO/src/group.zig:118`) and swallows the error at
`ZIO/src/group.zig:132-140`. It loses per-task cancellation, because only
`Group.cancel` at `:207` exists. It gains that `wait` and `cancel` are usable
again afterwards (`ZIO/src/group.zig:187-189`).

`zomp` made the same choice and recorded why at `zomp/docs/zomp-design.md:35`.

### 4.5 `spawnBlocking` and `blockInPlace`

A blocking task runs on the thread pool, not on an executor.

| Line | Declaration |
|---|---|
| `ZIO/src/runtime.zig:1850` | `pub fn spawnBlocking(self: *Runtime, func, args) !JoinHandle(meta.ReturnType(func))` |
| `ZIO/src/group.zig:151` | `pub fn spawnBlocking(self: *Group, func, args) !void` |
| `ZIO/src/zio.zig:50` | `pub const blockInPlace = common.blockInPlace;` |
| `ZIO/src/zio.zig:51` | `pub const blockInPlaceReserved = common.blockInPlaceReserved;` |
| `ZIO/src/common.zig:846` | `pub fn blockInPlace(func, args) meta.ReturnType(func)` |
| `ZIO/src/common.zig:863` | `pub fn blockInPlaceReserved(func, args) meta.ReturnType(func)` |

`ZIO/examples/stderr_smoke.zig:109-110` shows the shape:
`var pw = try rt.spawnBlocking(poolWorker, .{}); pw.join();`.

## 5. The bridge that matters

This section answers the question the D-Bus and X11 adapters depend on. How does
a C callback, entered on a thread zio does not own, hand work to a zio task.

### 5.1 The exact type

**`ev.Async`** at `ZIO/src/ev/completion.zig:620-652`.

```zig
pub const Async = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    pending: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    pub const Error = Cancelable;

    pub fn init() Async {
        return .{
            .c = .init(.async),
        };
    }

    /// Notify the loop to wake up and complete this async handle (thread-safe)
    pub fn notify(self: *Async) void {
```

`notify` at `ZIO/src/ev/completion.zig:634-647` is the whole bridge. It does two
things.

```zig
const was_pending = self.pending.swap(1, .acq_rel);
if (was_pending == 0) {
    if (self.c.getLoop()) |loop| {
        loop.wakeAsync();
    }
}
```

The `acq_rel` swap on `pending` pairs with the same swap in `Loop.addInternal`,
which the doc comment at `ZIO/src/ev/completion.zig:635-640` explains. Either
the loop sees the notification and wakes, or the loop sees the handle armed and
completes it itself. There is no lost wakeup and no double completion.

`notify` is reachable from any thread. A D-Bus dispatch function or an XCB event
handler calls it and returns. It allocates nothing and takes no lock.

The waiting side is `common.waitForIo` at `ZIO/src/common.zig:608`. The port
reaches `Async` as `zio.ev.Async`: `ZIO/src/zio.zig:107` re-exports
`ZIO/src/ev/root.zig`, and `ZIO/src/ev/root.zig:32` re-exports
`completion.Async`.

### 5.2 Which thread runs a callback

Three cases, and the port must not confuse them.

| Callback kind | Thread | Evidence |
|---|---|---|
| completion callback for a loop operation | the executor thread that owns that `Loop` | `Loop.add` calls `assertOwnThread()` at `ZIO/src/ev/loop.zig:852`, and `processCompletions` at `ZIO/src/ev/loop.zig:1148` runs on the loop thread |
| completion callback for thread-pool work | the pool worker | `ZIO/src/blocking_task.zig:152`: "All operations here must be thread-safe as this runs on a foreign thread." |
| a callback the embedder drives itself | whatever thread calls `Loop.nextDispatched` | `ZIO/src/ev/loop.zig:586-588` |

The third row is the escape hatch. `Loop.Options.do_not_call_callbacks` at
`ZIO/src/ev/loop.zig:520` and the field at `:511` exist so that an embedder can
poll with a lock released and then run the callbacks itself. The doc at
`ZIO/src/ev/loop.zig:505-510` names the use case: "This lets an embedder (e.g. a
CPython asyncio event loop) run the blocking poll with the GIL released and then
invoke callbacks with the GIL held." zio's own `docs/index.md:9` cites
blazio, a CPython `asyncio` event loop built on `zio.ev`, as a working example.

`Completion.CallbackFn` is the callback type
(`ZIO/src/ev/completion.zig:339-342`):

```zig
pub const CallbackFn = fn (
    loop: *Loop,
    completion: *Completion,
) void;
```

### 5.3 Which `Loop` operations are thread-safe

This is the table the port's bridge code is written against.

| Operation | Thread-safe | Evidence |
|---|---|---|
| `Loop.wake` | yes | `ZIO/src/ev/loop.zig:623`, doc at `:621-622` |
| `Loop.wakeAsync` | yes | `ZIO/src/ev/loop.zig:628`, doc at `:627` |
| `Loop.clearTimer` | yes | `ZIO/src/ev/loop.zig:669`, doc at `:660-662` |
| `Loop.add` | no | `ZIO/src/ev/loop.zig:852` calls `assertOwnThread` |
| `Loop.cancel` | no | `ZIO/src/ev/loop.zig:694` calls `assertOwnThread` |
| `Loop.setTimer` | own thread | `ZIO/src/ev/loop.zig:640` asserts the timer belongs to this loop |
| `Loop.nextDispatched` | own thread | pops the loop's own dispatched queue |
| `Loop.run`, `Loop.poll` | own thread | `ZIO/src/ev/loop.zig:844` and `:1404` |

`assertOwnThread` is debug-only. `ZIO/src/ev/loop.zig:573-575` guards it with
`if (in_debug_mode)`. A release build does not catch a violation, so the port
must not rely on the assert.

### 5.4 What a callback may do

**May spawn a task.** `rt.spawn` from a foreign thread is supported and tested.
`getNextExecutor` at `ZIO/src/runtime.zig:344-353` reads `shutting_down` and then
does one `fetchAdd` on `next_executor_index`. `registerTask` at
`ZIO/src/task.zig:697` increments `task_count` and calls
`Executor.scheduleTask`. `scheduleTask` at `ZIO/src/runtime.zig:1215-1276` ends
in `scheduleTaskRemote` at `:1204-1210` when the caller has no executor, which
pushes onto the overflow queue and calls `loop.wake()`, a thread-safe call.

The one placement that fails from a foreign thread is `.local`.
`getPlacementExecutor` at `ZIO/src/runtime.zig:383-387` returns
`error.InvalidPlacement` when `getCurrentExecutorOrNull()` is null, and the test
at `ZIO/src/runtime.zig:2649-2671` asserts exactly that. `.auto` and
`.executor` both work.

**Must not call `zio.spawn`.** `ZIO/src/runtime.zig:1492-1494` calls
`getCurrentExecutor()`, which is `ZIO/src/runtime.zig:1363` and panics with no
executor. A C callback always uses `rt.spawn`, never `zio.spawn`.

**Must not park the calling thread.** `[INFERENCE]` A callback dispatched by
`processCompletions` runs on the loop thread. If it calls `JoinHandle.join()`
(`ZIO/src/runtime.zig:193`), that reaches `select.waitUntilComplete` at
`ZIO/src/runtime.zig:198`, which parks through `Waiter.wait`
(`ZIO/src/common.zig:375`). The loop thread is then parked, so `poll` never runs
again and the awaited completion is never dispatched. The port spawns a task and
returns. It never joins inside a callback.

**Must not free the completion or its userdata.** `Completion.Flags.defer_callback`
at `ZIO/src/ev/completion.zig:268` defaults to true, which means the callback may
chain further operations. `Flags.rearm` at `:273` re-adds the completion after
the callback returns, and its doc says "The callback must not free the
completion."

### 5.5 Calling back into Zig from a C thread pool

The rules, in order.

1. **The Zig entry point takes one opaque pointer and returns void or an int.**
   `ev.Completion.CallbackFn` at `ZIO/src/ev/completion.zig:339-342` is the
   shape. A C `callconv(.c)` function pointer matches it when the signature is
   `fn (*Loop, *Completion) void` plus the calling convention. zio uses
   `callconv(.c)` where it must, for example the SIGPIPE handler at
   `ZIO/src/runtime.zig:71`:
   `fn doNothingSignalHandler(_: os.posix.SIG) callconv(.c) void {}`.
2. **Do not allocate, do not free, and do not panic inside the callback.**
   zio registers its own `crashHandler` slot at `ZIO/src/io.zig:153`, and the
   implementation at `ZIO/src/io.zig:288-295` calls `coro.crashHandler()`,
   `runtime_mod.markCrashed()`, and `stderr.markCrashed()`. A crash on a foreign
   thread with no task is not recoverable by zio.
3. **Copy the payload out before you return.** A C callback hands zio a pointer
   into C-owned memory. If the message is parsed later, on another thread, the
   memory must survive that long. The port copies into a zio-owned allocation on
   the spot.
4. **Wake, do not block.** `Async.notify()` at
   `ZIO/src/ev/completion.zig:634`, or `Event.set()` at
   `ZIO/src/sync/Event.zig:81`, which the test at `ZIO/src/sync/Event.zig:414`
   exercises from a foreign thread.
5. **The reverse direction runs through `ev.Work`.** When a task must call into
   blocking C code, it submits a `Work` (`ZIO/src/ev/completion.zig:654`) to
   `ThreadPool.submit` at `ZIO/src/ev/thread_pool.zig:181`. The worker's `func`
   field is `*const fn (work: *Work) void` (`ZIO/src/ev/completion.zig:658`) and
   the completion callback is `completion_fn` at `:661`. The runtime does this
   for the port already: `rt.spawnBlocking` reaches
   `spawnBlockingTask` at `ZIO/src/blocking_task.zig:189`, which calls
   `rt.thread_pool.submit(&task.work)` at `ZIO/src/blocking_task.zig:179`.
6. **A cancellation that arrives with no loop thread to drive it degrades.**
   `AnyBlockingTask.cancel` at `ZIO/src/blocking_task.zig:61-76` takes the
   `getCurrentExecutorOrNull()` branch at `:68`. With no executor it falls
   through to `thread_pool.cancel` at `:73` and drops the keep-alive reference,
   with the comment "Not on a loop thread, so there is no ticking loop here to
   drive the SIGURG resend: best-effort single signal".

### 5.6 Watching a foreign file descriptor

The D-Bus connection and the XCB connection are each one file descriptor that zio
does not own. `ev.PipePoll` is the watch, at
`ZIO/src/ev/completion.zig:2228-2253`:

```zig
pub const PipePoll = struct {
    c: Completion,
    result_private_do_not_touch: void = {},
    handle: fs.fd_t,
    event: Event,

    pub const Error = fs.FileReadError || fs.FileWriteError || Cancelable;

    pub const Event = enum { read, write };

    pub fn init(handle: fs.fd_t, event: Event) PipePoll {
```

Despite the name, it watches any descriptor. Every backend treats it as a plain
file descriptor.

| Backend | Registration | Dispatch |
|---|---|---|
| epoll | `ZIO/src/ev/backends/linux/epoll.zig:348-355` maps `.read` to `EPOLL.IN` and `.write` to `EPOLL.OUT`, and `:511` returns `completion.cast(PipePoll).handle` | `:1070-1085` |
| io_uring | `ZIO/src/ev/backends/linux/io_uring.zig:156` lists `.pipe_poll` | `:1719-1723` |
| kqueue | `ZIO/src/ev/backends/kqueue.zig:407-408` and `:432` return the handle | `:1129-1132` |
| poll | `ZIO/src/ev/backends/poll.zig:258-259` and `:396` return the handle | `:890-905` |
| iocp | `ZIO/src/ev/backends/iocp.zig:244` lists `.pipe_poll` | `:740` |

`PipePoll` is reachable as `zio.ev.PipePoll` (`ZIO/src/ev/root.zig:85`). It is
not used anywhere in zio's own higher-level code, so it carries no production
history inside the runtime. The port is its first user.

### 5.7 No task context at all

A zio operation called with no runtime in scope does not fail. It runs
synchronously on the calling thread. `common.waitForIo` at
`ZIO/src/common.zig:622-626`:

```zig
const task = waiter.mode.direct.task orelse {
    // TODO: Don't use std.heap.c_allocator - it should be passed as a parameter
    ev.executeBlocking(c, std.heap.c_allocator);
    return;
};
```

The same fallback is at `ZIO/src/common.zig:688-692`. `ev.executeBlocking` is
`ZIO/src/ev/blocking.zig:47`. This path is how the D-Bus and X11 layers work
before a runtime exists, and it uses a hidden global allocator, which section 8
treats as a house-rule problem.

### 5.8 The `std.Io` thread-safety contract

The port must know which vtable slots a C library may call from any thread. From
the doc comments in `STD/Io.zig`, the slots marked "Thread-safe" are `async`
(`:60`), `concurrent` (`:74`), `await` (`:87`), `cancel` (`:102`), `groupAsync`
(`:118`), and `groupConcurrent` (`:129`).

`concurrent` is the one a C thread pool wants. It is exactly what
`Runtime.blockingIo()` switches to (`ZIO/src/runtime.zig:2075`, implemented at
`ZIO/src/io.zig:325` with `.reserve_thread = true`). If the port needs a foreign
thread to start work that a task will await, it calls `io.vtable.concurrent` and
hands the result to `io.vtable.await`.

### 5.9 A main-loop integration exists already

The port does not have to build one. `zio.ev` is documented as embeddable at
`ZIO/docs/index.md:9` and at `ZIO/src/ev/root.zig:7-10`, which lists "Embedding
in a game loop or other custom run loops" as a supported use. `Loop.poll` at
`ZIO/src/ev/loop.zig:1404` takes a `Duration` cap with a documented meaning at
`ZIO/src/ev/loop.zig:1397-1403`: `.zero` never blocks, `.max` waits for the next
event, anything between caps the wait.

`Loop.done` at `ZIO/src/ev/loop.zig:605-614` answers whether the loop has
nothing left to do, which is what a frame-driven host needs to know when to stop
polling. The zio example says the same at
`ZIO/examples/ev_demo.zig:13`: "Embedding in a game loop (call
`loop.poll(.zero)` each frame)".

## 6. Cancellation and timeouts

### 6.1 Cancellation is per task and is a counter

Every task carries one 32-bit status word. `CanceledStatus` is at
`ZIO/src/task.zig:147` and `CancelKind` at `:156`. The word holds a user flag, an
auto-cancel count, a pending-error count, and a shield count.

| Operation | Line | What it does |
|---|---|---|
| `AnyTask.cancel(self)` | `ZIO/src/task.zig:461` | `setCanceled(.user)` then `wake()` |
| `AnyTask.setCanceled(self, kind)` | `ZIO/src/task.zig:351` | CAS loop, returns false when shadowed by an earlier user cancel |
| `AnyTask.checkCancel(self)` | `ZIO/src/task.zig:437` | returns `error.Canceled` once per pending error, unless shielded |
| `AnyTask.recancel(self)` | `ZIO/src/task.zig:389` | puts a delivered cancellation back, so the next cancellation point reports it |
| `AnyTask.checkAutoCancel(self)` | `ZIO/src/task.zig:411` | consumes one auto-cancel, and refuses when a user cancel is pending |
| `AnyTask.beginShield`, `endShield` | `ZIO/src/task.zig:319`, `:334` | raise and lower `shield_count` |

The module functions are `zio.beginShield` (`ZIO/src/zio.zig:32`),
`zio.endShield` (`:33`), `zio.checkCancel` (`:34`), and `zio.recancel` (`:35`).
The matching `Runtime` methods are deprecated in their own doc comments at
`ZIO/src/runtime.zig:2041`, `:2047`, `:2055`, and `:1534`.

`recancel` exists for one reason, and `ZIO/DEVELOPMENT.md` states the rule in
full under "Cancellation":

> If an operation completes and gets canceled at the same time, return
> `error.Canceled` when the result can be cheaply discarded, so cancellation
> propagates as quickly as possible. If the result owns resources that need to be
> handled (file descriptors, allocations, etc.), call `recancel()` and return the
> result, so the next cancellation point reports the cancellation.

The port follows this rule in every adapter that hands a descriptor back to the
caller.

### 6.2 What a timeout does to a task blocked in I/O

Two mechanisms exist and they compose.

**Per-operation timeout.** Every zio socket and file call takes a `Timeout`
(`ZIO/src/time.zig:459`). `timedWaitForIo` at `ZIO/src/common.zig:706` and
`timedWaitForIoClock` at `:711` implement it. The implementation races the
operation against a timer inside an `ev.Group` in `.race` mode
(`ZIO/src/common.zig:716-722`), then inspects which side won at `:726-732`:

```zig
if (timer.c.err == null) {
    if (c.err) |io_err| {
        if (io_err == error.Canceled) {
            return error.Timeout;
        }
    }
}
```

So a per-operation timeout returns `error.Timeout`, not `error.Canceled`, and the
underlying operation has been canceled. The test at
`ZIO/src/common.zig:743-750` pins this: a one-second timer with a ten-millisecond
timeout gives `error.Timeout`.

**Task-scoped timeout.** `AutoCancel` at `ZIO/src/autocancel.zig:27` arms a
timer that cancels the *task* when it fires. The callback is
`autoCancelCallback` at `ZIO/src/autocancel.zig:179`, and the cancellation is
claimed before it is handed over at `:202-203`:

```zig
autocancel.triggered.store(true, .release);
if (!t.setCanceled(.auto)) autocancel.triggered.store(false, .monotonic);
```

`AutoCancel.check` at `ZIO/src/autocancel.zig:112-119` then tells the caller
whether the auto-cancel won or a user cancel shadowed it.

`withTimeout` at `ZIO/src/autocancel.zig:145-166` is the scoped form. It arms,
runs, disarms, and rewrites `error.Canceled` into `error.Timeout` at `:162`
only when the auto-cancel actually won. A user cancel still surfaces as
`error.Canceled`. The doc at `ZIO/src/autocancel.zig:143-144` says so: "An
explicit cancel of the task wins over the timeout and is reported as
`error.Canceled`, exactly as `AutoCancel.check` decides."

The port uses `withTimeout` for every wait that has a deadline: the D-Bus method
reply timeout, the AT-SPI cache refresh interval, and the XCB request timeout.

### 6.3 What cancellation does to a task parked in I/O

`common.waitForIo` at `ZIO/src/common.zig:608` is the one place every blocking
zio operation funnels through. Its cancellation path is
`ZIO/src/common.zig:650-666`:

```zig
waiter.wait(1, .allow_cancel) catch |err| switch (err) {
    error.Canceled => {
        // On cancellation, cancel the I/O and wait for completion
        task.getExecutor().loopCancel(c);
        waiter.wait(1, .no_cancel);

        // Check if I/O was actually canceled
        if (c.err) |io_err| {
            if (io_err == error.Canceled) {
                return error.Canceled;
            }
        }
        // IO completed successfully despite cancel request - restore the pending cancel
        task.recancel();
        return;
    },
};
```

Four steps, and the port must understand all of them.

1. `loopCancel` asks the loop to cancel the operation. `Loop.cancel` at
   `ZIO/src/ev/loop.zig:693` is fire-and-forget and idempotent, with the doc at
   `ZIO/src/ev/loop.zig:689-690`: "the completion's callback will still be
   invoked when the operation completes (either with error.Canceled or its
   natural result)". It must run on the loop's own thread (`:694`), and a
   cross-loop cancel is routed through the completion's cancel queue
   (`ZIO/src/ev/loop.zig:700-703`).
2. `waiter.wait(1, .no_cancel)` reaps the completion. Without this reap the
   completion's memory would be freed while the loop still holds it.
3. The check on `c.err` distinguishes a real cancellation from a race in which
   the operation already had a result.
4. `task.recancel()` re-arms the cancellation so the next cancellation point
   reports it. This is the `DEVELOPMENT.md` rule in code.

The cancellation is delivered to a blocked task because `waitForIo` parks on a
`Waiter` (`ZIO/src/common.zig:609`) and `Waiter.wait` at `ZIO/src/common.zig:375`
takes the cancel mode as a comptime parameter.

### 6.4 Cancelling from outside

| From | Call | Evidence |
|---|---|---|
| anywhere | `JoinHandle.cancel()` | `ZIO/src/runtime.zig:260`, dispatches to `Awaitable.cancel` at `:271` then reaps at `:274` |
| anywhere | `Group.cancel()` | `ZIO/src/group.zig:207` |
| a foreign thread | `Awaitable.cancel()` | `ZIO/src/awaitable.zig:46`, dispatches to `AnyTask.cancel` or `AnyBlockingTask.cancel` |
| the owning loop only | `Loop.cancel(completion)` | `ZIO/src/ev/loop.zig:693`, own-thread assert at `:694` |

`Awaitable.markComplete` at `ZIO/src/awaitable.zig:70-78` pops every waiter and
signals it, and its doc at `:67-69` says "Can be called from any context."
`Group.cancel` is not marked thread-safe. `[INFERENCE]` The port calls it from a
task, not from a C callback.

### 6.5 The future protocol and `select`

`select` at `ZIO/src/select.zig:270` waits on any number of futures at once. The
protocol a type implements is written out at `ZIO/src/select.zig:18-108`, and
the three methods are `asyncWait` (`:29-30`), `asyncCancelWait` (`:76-77`), and
`getResult` (`:96-97`), plus a `Result` type and an optional `WaitContext`
(`:20-27`).

The protocol guarantees, quoted from the source at `ZIO/src/select.zig:92-94` and
`:108`:

> Thread-safe: can be called from any thread

for `asyncCancelWait`, and

> Thread-safe: can be called from any thread after completion

for `getResult`.

| Call | Line | Returns |
|---|---|---|
| `select(.{ .a = &a, .b = b })` | `ZIO/src/select.zig:270` | a tagged union named after the fields |
| `wait(future)` | `ZIO/src/select.zig:632` | `Cancelable!WaitResult(T)`, works "from both coroutines and threads" (`:623`) |
| `waitUntilComplete(future)` | `ZIO/src/select.zig:647` | `T`, never `error.Canceled` |
| `selectAwaitables([]const *Awaitable)` | `ZIO/src/select.zig:479` | `Cancelable!usize`, the index that won |

`SelectResult` is generated by `@Union` at `ZIO/src/select.zig:229`, and
`WaitResult` is a one-field wrapper at `ZIO/src/select.zig:196-200`.

Types in this repository that are already futures, so the port gets `select` for
free:

| Type | `asyncWait` | `asyncCancelWait` | `getResult` |
|---|---|---|---|
| `JoinHandle(T)` | `ZIO/src/runtime.zig:226` | `:241` | `:216` |
| `Awaitable` | `ZIO/src/awaitable.zig:56` | `:63` | `:82` |
| `Group` | `ZIO/src/group.zig:263` | `:313` | `:258` |
| `Timeout` | `ZIO/src/time.zig:556` | `:600` | `:611` |
| `Signal` | `ZIO/src/signal.zig:360` | `:393` | `:400` |
| `Event` | `ZIO/src/sync/Event.zig:213` | `:220` | `:205` |
| `Channel(T)` receive | `ZIO/src/sync/channel.zig:484` | `:548` | `:561` |
| `BroadcastChannel(T)` receive | `ZIO/src/sync/broadcast_channel.zig:171` | `:216` | `:224` |
| `CompletionQueue` | drives the queue | | |

The working example is `ZIO/examples/ntp_client.zig:142-145`, which waits on an
interval timer and a SIGINT handler in one select.

`self-wait` is detected and rejected. `checkSelfWait` at
`ZIO/src/select.zig:131-140` panics with "cannot wait on self (would deadlock)"
in Debug and ReleaseSafe.

### 6.6 How a shutdown drains

The order is fixed, and the port must not reorder it.

1. **Stop the sources.** The port cancels every outstanding D-Bus method reply
   and closes the connections. `Group.cancel` at `ZIO/src/group.zig:207` is the
   tool for the task trees.
2. **Drain the task trees.** `Group.cancel` sets the flag
   (`ZIO/src/group.zig:211`), pops and cancels every task (`:216-221`), waits for
   the counter to reach zero on a futex (`:224-230`), and clears the flag
   (`:233`). `JoinHandle.cancel` at `ZIO/src/runtime.zig:260` does the same for
   one task.
3. **Stop the thread pool first, while the executor loops are still alive.**
   `Runtime.deinit` calls `self.thread_pool.stop()` at
   `ZIO/src/runtime.zig:1780`. The doc at `ZIO/src/runtime.zig:1774-1779` gives
   the reason: "Thread-pool completion callbacks wake the owning loop (writing its
   eventfd), so the pool's worker threads must be fully joined before any loop is
   torn down." `ThreadPool.stop` at `ZIO/src/ev/thread_pool.zig:151` drops queued
   work (`:160`), sets `shutdown` (`:156`), and joins every worker (`:168-178`).
4. **Stop and join the workers.** `shutdownWorkers` at
   `ZIO/src/runtime.zig:1737` waits for each worker's `ready`
   (`:1742`), calls `worker.executor.shutdown.notify()` (`:1744`), sets `teardown`
   (`:1750`), then joins the threads (`:1753-1755`). The `teardown` barrier
   exists because a worker must not close its waker file descriptors while a
   cross-thread notifier is still writing to them; the comment at
   `ZIO/src/runtime.zig:1887-1895` gives the full race.
5. **Assert nothing is left.** `ZIO/src/runtime.zig:1786`:
   `std.debug.assert(self.task_count.load(.acquire) == 0);`

Step 5 is a hard gate. Any task that was detached (`ZIO/src/runtime.zig:289`) or
left parked past its cancel point trips it. `zomp/src/main.zig:82-83` records the
same constraint in prose: "deinit asserts every task has settled, which is why
nothing here may detach."

## 7. Testing

### 7.1 What zio's own harness is

zio has a custom test runner, wired at `ZIO/build.zig:112-116`:

```zig
const lib_unit_tests = b.addTest(.{
    .root_module = zio,
    .test_runner = .{ .path = b.path("test_runner.zig"), .mode = .simple },
    .filters = if (test_filter) |f| &.{f} else &.{},
});
```

`ZIO/test_runner.zig` is 480 lines. It adds log capture, a progress node, and a
slow-test tracker on top of the `builtin.test_functions` loop at
`ZIO/test_runner.zig:148`.

Four facts from the runner shape the port's tests.

1. `ZIO/test_runner.zig:190` sets `std.testing.io_instance = .init(gpa, .{});`
   for every test, and `ZIO/test_runner.zig:214` tears it down after. In Zig
   0.16 `std.testing.io_instance` is declared `pub var io_instance: Io.Threaded`
   at `STD/testing.zig:34` and exposed as `std.testing.io` at `STD/testing.zig:35`.
   The test process's `std.Io` is `std.Io.Threaded`, not zio.
2. Each zio test that needs a runtime builds its own. `ZIO/src/process.zig:91`
   `const rt = try Runtime.init(std.testing.allocator, .{});`,
   `ZIO/src/common.zig:736` the same, `ZIO/src/runtime.zig:2092` the same with
   `.executors = .exact(2)`.
3. `ZIO/test_runner.zig:215` turns a `std.testing.allocator` leak into a test
   failure. That is the memory-leak gate.
4. `ZIO/src/zio.zig:112-119` adds a `refAllDecls` test on the root module, so
   every public declaration type-checks.

`ZIO/DEVELOPMENT.md`, Testing section, lists the driver: `./check.sh`,
`./check.sh --filter "test name"`, `./check.sh --target x86_64-windows --wine`,
`./check.sh --target riscv64-linux --qemu`, and `./check.sh --full`. The script
is `ZIO/check.sh`, 6515 bytes.

### 7.2 Is time simulated

**No.** A search of the whole source tree for `simulat`, `Mock`, `mock`,
`FakeClock`, `fake`, `TestBackend`, `test_backend`, `TestLoop`, and
`deterministic` returns three hits, and all three are prose in comments
(`grep -rn 'simulat\|Mock\|mock\|FakeClock\|fake\|TestBackend\|test_backend\|TestLoop\|deterministic' src/`).
There is no simulated clock and no fake event backend.

zio's own timing tests read the real clock and assert tolerance bands.

| Test | Evidence |
|---|---|
| `ev` timer basic | `ZIO/src/ev/tests.zig:64-81`, a 50 ms timer asserted as at least 45 and at most 150 ms at `:78-79` |
| `setTimer` and `clearTimer` basic | `ZIO/src/ev/test/timer.zig:12-31`, a 100 ms timer asserted as at least 90 and at most 250 ms at `:28-29` |
| `clearTimer` before expiration | `ZIO/src/ev/test/timer.zig:33-56`, asserts under 200 ms at `:54` |
| cross-thread wake | `ZIO/src/ev/test/wake.zig:35-91`, 20 000 iterations with a real `Timestamp.now(.monotonic)` deadline at `:85-89` |

`Clock` is an enum at `ZIO/src/time.zig:46` and `Timestamp.now` at
`ZIO/src/time.zig:370` is a real syscall. `Loop.now` at `ZIO/src/ev/loop.zig:617`
returns the loop's cached tick, which is still a real clock, only sampled at
poll boundaries.

### 7.3 What a port test can control

| Lever | Evidence |
|---|---|
| Swap the whole runtime. A module that takes `io: std.Io` runs on `std.Io.Threaded` with no zio at all. | `STD/Io/Threaded.zig:1704` `pub const global_single_threaded: *Threaded` |
| Feed a fixed byte stream. | `STD/Io/Reader.zig:152` `pub fn fixed(buffer: []const u8) Reader` |
| Feed a bounded byte stream. | `STD/Io/Reader.zig:144-145` `pub const ending_instance` and `pub const ending` |
| Collect output into a buffer. | `STD/Io/Writer.zig:125` `pub fn fixed(buffer: []u8) Writer`, which fails with `WriteFailed` when full |
| Count bytes and discard them. | `STD/Io/Writer.zig:2205` `pub const Discarding` |
| Step the loop by hand, never blocking. | `ZIO/src/ev/loop.zig:1404` `pub fn poll(self: *Loop, wait_cap: Duration) !void`, where `.zero` "never blocks (and skips the poll syscall entirely when nothing is in flight)" per the doc at `:1398-1400` |
| Ask whether the loop is finished. | `ZIO/src/ev/loop.zig:605-614` `fn done(self: *const Loop) bool` |
| Make a deadline win immediately. A `zio.Timeout` is a future, so a test arms `.zero` and it wins the `select` on the first poll. | `ZIO/src/time.zig:548-611` |
| Reproduce a cross-thread window on one thread. `do_not_call_callbacks` holds a finished completion in the dispatch queue, which the zio tests use deliberately. | `ZIO/src/ev/loop.zig:511`, `ZIO/src/ev/loop.zig:520`, used at `ZIO/src/ev/test/timer.zig:58-63` |
| Break `select` ties deterministically. | `ZIO/src/select.zig:257-258`: "fields are checked in declaration order and the first ready handle is returned" |
| Check for leaks. | `ZIO/test_runner.zig:215` |

### 7.4 What a port test cannot control

| Gap | Why |
|---|---|
| The wall clock inside a `Runtime` | `zio.now()` returns the loop's cached timestamp (`ZIO/src/runtime.zig:1551`). `Timestamp.now` at `ZIO/src/time.zig:370` is a syscall. No injection point exists. |
| The event backend | `ev.Backend` is selected by a `switch` on a comptime value at `ZIO/src/ev/backend.zig:14-21`. There is no runtime-selectable or injectable backend. |
| Which executor runs a task | `.work_stealing` is the default (`ZIO/src/options.zig:58`). `Placement.executor` (`ZIO/src/runtime.zig:368`) picks one, but `getPlacementExecutor` at `:373-375` returns `error.InvalidPlacement` for any non-`.auto` placement under work stealing. A test that wants one executor must compile the root module with `pub const zio_options: zio.Options = .{ .scheduling = .pinned };`, which `ZIO/src/options.zig:72` reads from the root. |
| Task interleaving | `Executor.max_tick_budget` is 8192 (`ZIO/src/runtime.zig:692`) and there is no scheduler-step hook. Two tasks racing on shared state produce a real race. |
| Allocation failure injection inside zio's pools | `TaskPool` (`ZIO/src/task.zig:785`) and `StackPool` take the allocator at construction, and tests pass `std.testing.allocator`, which checks for leaks but does not fail-N. |
| The D-Bus and XCB transports | Both are outside zio. Section 9 assigns them. |

### 7.5 The consequence for the port test plan

The house rules in `ozai/AGENTS.md` section 2 demand that network logic be pure
over decoded bytes, that state be a parameter, and that time be data. zio gives
the port the last of these only for deadlines, not for reads. A port test can
therefore do four things.

1. Test every protocol decoder, state machine, and dispatcher as a pure function
   over bytes, with no runtime at all. This is the large majority of lines.
2. Test the boundary with a `Loop` driven by `poll(.zero)` and a `Timeout` of
   `.zero`, so no test waits on a clock.
3. Test the `std.Io`-facing signatures on `std.Io.Threaded`, which is what
   `zomp` relies on (`zomp/docs/zomp-design.md:32`, decision D1).
4. Keep the number of tests that need real elapsed time small and give each one
   a wide tolerance band, the way `ZIO/src/ev/test/timer.zig:28-29` does.

One place needs explicit honesty in the plan. `zio.Timeout` is a future that
wins a `select`, so a timeout is testable as a decision, but the arming of the
timer is a real clock operation. A test that must prove "this fires after 100 ms"
cannot do it without waiting. The port asserts the decision and records the
duration as a measurement, not an assertion.

## 8. House-rule fit

The rules come from `ozai/AGENTS.md` section 1 ("Golden rules") and section 2
("Architecture: extreme-testable by default"), plus the two rules the
integration owner added for this project. Each row states whether zio satisfies
the rule today and what the port must add.

### 8.1 `io: std.Io` threaded explicitly, never global

**Partly satisfied. The port must fix the gaps.**

Where zio is right:

* `Runtime.io(self) std.Io` at `ZIO/src/runtime.zig:2067` is a method, not a
  global. The caller obtains the handle and passes it.
* `Runtime.fromIo(value: std.Io) ?*Runtime` at `ZIO/src/runtime.zig:2082` takes
  the handle back. Library code that already holds a `std.Io` can recover the
  runtime, and gets `null` rather than a wrong answer.
* Every `std` API that does I/O takes an `Io` parameter. `STD/process.zig:442`
  `pub fn spawn(io: Io, options: SpawnOptions) SpawnError!Child` is the model.

Where zio fights the rule:

| Violation | Evidence |
|---|---|
| A hidden global allocator on the no-task path | `ZIO/src/common.zig:624` `ev.executeBlocking(c, std.heap.c_allocator);` with the in-source TODO "Don't use std.heap.c_allocator - it should be passed as a parameter" at `:623`. The same at `ZIO/src/common.zig:689-690`. |
| A second hidden global allocator | `ZIO/src/io.zig:1724` `const rt: *Runtime = @ptrCast(@alignCast(userdata orelse return std.heap.c_allocator));` |
| A process-global `Io` used as a fallback | `ZIO/src/io.zig:284-286` `fn globalIo() Io { return std.Io.Threaded.global_single_threaded.io(); }`, used at `ZIO/src/io.zig:1738` |
| A thread-local as an implicit parameter | `ZIO/src/runtime.zig:556` `pub threadlocal var current_DO_NOT_ACCESS_DIRECTLY: ?*Executor = null;` and `ZIO/src/ev/loop.zig:35` `threadlocal var current_loop` |
| The module functions read that thread-local | `zio.now()` at `ZIO/src/runtime.zig:1551`, `zio.spawn()` at `:1492`, `zio.sleep()` at `:1556`, and `common.waitForIo` through `waiter.mode.direct.task` at `ZIO/src/common.zig:622` |
| A global allocator for coroutine stacks | `ZIO/src/coro/stack.zig:472-473` and `:530` use `std.heap.page_allocator` |

What the port must add:

1. **Library modules take `io: std.Io` and never touch `zio.` module functions.**
   The port's own modules use `rt.` methods where a runtime is genuinely needed,
   and `io.` parameters everywhere else. `zomp/docs/zomp-design.md:32` records
   the same split as decision D1.
2. **The bridge layer passes the allocator explicitly.** The port owns its own
   `waitForIo`-equivalent for anything that may run without a task, and it takes
   the allocator as a parameter rather than reaching for `std.heap.c_allocator`.
3. **`main` is the only place that reads the thread-local.** Every runtime handle
   is created once in `main` and passed down.
4. **`Runtime.fromIo` returning `null` is a handled case, never an `unreachable`.**
   The port asserts a positive case at a boundary and handles the negative one.

### 8.2 Network and event logic is pure over decoded input

**Not zio's job, and zio does not obstruct it.** zio supplies the transport and
the scheduling. The decoding and the state machines belong to the port.

What zio gives the port for this:

* Byte-limited reads and writes. `net.readBuf` at `ZIO/src/net.zig:45` and
  `net.writeBuf` at `:51` return `ev.NetRecv.Error || Timeoutable`.
* `Loop.poll(.zero)` at `ZIO/src/ev/loop.zig:1404`, which never blocks. A pure
  decoder test feeds bytes from a `std.Io.Reader.fixed`
  (`STD/Io/Reader.zig:152`) and never enters an event loop.

What the port must add: the pure functions themselves. Every D-Bus message
decoder, the AT-SPI cache, and the XCB event reducer take `(bytes, state)` and
return `(new_state, actions)`. No `io`, no clock, no allocator.

### 8.3 State is a parameter, not a capture

**Satisfied by zio's own design, and it transfers.**

* `Awaitable` holds `waiting_list` and `group_node` as fields
  (`ZIO/src/awaitable.zig:36` and `:39`) and every method takes `self` explicitly.
* `Group` has exactly two fields at `ZIO/src/group.zig:25` and every flag
  accessor takes `self`.
* `Executor.scheduleTask` at `ZIO/src/runtime.zig:1215` is `pub fn
  scheduleTask(task: *AnyTask) void`, a static function. The task is the
  parameter and the queue is reached through the task's executor.
* The D-Bus and X11 signal handlers get the connection as an explicit
  `userdata` parameter: `Completion.userdata` at `ZIO/src/ev/completion.zig:286`
  and `Async.pending` at `:623` carry the state across the thread boundary.

What the port must add: nothing structural. A port adapter that holds a
connection struct by pointer and takes it as a parameter satisfies the rule by
construction.

### 8.4 Allocations are parameters

**Satisfied at the runtime boundary, violated on three internal paths.**

| Where | Verdict | Evidence |
|---|---|---|
| Runtime construction | parameter | `Runtime.init(allocator: Allocator, options)` at `ZIO/src/runtime.zig:1620` |
| Thread pool | parameter | `ThreadPool.init(self, allocator, options)` at `ZIO/src/ev/thread_pool.zig:61` |
| Event loop | parameter with a global default | `Loop.Options.allocator` at `ZIO/src/ev/loop.zig:516` defaults to `std.heap.page_allocator` |
| Task pool | parameter | `TaskPool.init(allocator)` at `ZIO/src/task.zig:791` |
| No-task I/O fallback | **global** | `ZIO/src/common.zig:624`, `:690` |
| `debug_io` scratch buffer | **global** | `ZIO/src/io.zig:1724` |

What the port must add: the bridge module takes `gpa: std.mem.Allocator` and
passes it down. Section 9 assigns that to the bridge, not to zio.

### 8.5 Error sets are explicit

**Mostly satisfied. Two leaks.**

zio's own three error sets are minimal and named: `Cancelable` with one member
(`ZIO/src/common.zig:27-29`), `Timeoutable` with one (`:32-34`), and `Closeable`
with one (`:37-39`). Every interruptible operation returns `Cancelable` or a union
containing it.

The two leaks are inferred error sets written as bare `!`:

| Declaration | Line |
|---|---|
| `pub fn parseIp4(buf: []const u8, port: u16) !IpAddress` | `ZIO/src/net.zig:316` |
| `pub fn parseIp6(buf: []const u8, port: u16) !IpAddress` | `ZIO/src/net.zig:328` |
| `pub fn parseIp(name: []const u8, port: u16) !IpAddress` | `ZIO/src/net.zig:387` |
| `pub fn lookup(...) !void` on `HostName` | `ZIO/src/net.zig:174` |

A bare `!` is `anyerror`. The port never writes a bare `!` in a public
signature. Where it needs one of these functions, it wraps the call in a `catch`
into a declared set.

One internal field is `anyerror`: `Completion.err: ?anyerror` at
`ZIO/src/ev/completion.zig:312`, with the doc comment "Stored here instead of in
each operation type to simplify error handling." It is internal to zio and the
port does not see it.

### 8.6 Loops have fixed upper bounds

**Satisfied.**

* The scheduler's event loops assert non-termination by design.
  `Executor.run(self, mode: RunMode)` at `ZIO/src/runtime.zig:760` takes
  `RunMode` from `ZIO/src/runtime.zig:750-757`, which is `until_ready` or
  `until_stopped`. There is no counting loop over tasks.
* Bounded budgets exist where a loop could otherwise spin.
  `Executor.max_tick_budget = 8192` at `ZIO/src/runtime.zig:692`.
  `spawn_yield_threshold = 13` at `ZIO/src/task.zig:691`.
  `Loop.wall_clock_cap` defaults to ten seconds at `ZIO/src/ev/loop.zig:498`, and
  `Loop.max_wait` to sixty seconds at `:492`.
* The resend sweep is bounded. `poll` clamps its timeout to `wait_cap` at
  `ZIO/src/ev/loop.zig:1433-1435`.

What the port must add: a fixed iteration cap on every loop over a D-Bus message
queue or an XCB event batch, and an assert when the cap is hit.

### 8.7 All errors handled, never discarded

**Satisfied inside zio, and the port copies the practice.**

* `Group.cancel` uses `Futex.wait(state_ptr, state) catch unreachable;` at
  `ZIO/src/group.zig:229`, inside a cancellation shield that was raised at
  `:208`. The unreachable is a claim, not a discard.
* `AnyBlockingTask.cancel` takes a reference before it can be lost, at
  `ZIO/src/blocking_task.zig:65-66`, and releases it in
  `onResendRelease` at `:80-83`.
* The one bare discard is `ZIO/src/blocking_task.zig:155` `_ = work;`, where the
  parameter is genuinely unused because the completion context carries
  everything.

### 8.8 No backwards compatibility, no shims, no aliases

**zio has one deprecated alias. The port carries none.**

`ZIO/src/zio.zig:91` declares `pub const ResetEvent = Event;` with the comment
"Deprecated, will be removed in a future release." `ZIO/src/runtime.zig:2028`
through `:2064` are six `Runtime` methods marked "Deprecated: use `zio.yield()`
instead" and its equivalents.

The port does not use `ResetEvent` and does not call the six `Runtime`
deprecated methods. A clean cutover means the port has one spelling per
operation.

### 8.9 Zero dependencies unless justified

**Satisfied by zio, and it is the reason zio is the right base.**

`ZIO/build.zig.zon` ends with `.dependencies = .{},`. zio depends on nothing but
the Zig standard library. `zio.coro` reimplements context switching at
`ZIO/src/coro/coroutines.zig`, and `zio.os` reimplements the POSIX and Win32
surface at `ZIO/src/os/root.zig`, because `ZIO/DEVELOPMENT.md` records that
`std.posix`, `std.Thread`, `std.fs`, and `std.net` "no longer exist or are
mostly empty" in Zig 0.16.

### 8.10 No Rust toolchain anywhere

**Satisfied by construction.** zio is Zig. `ZIO/build.zig.zon` has no
`Cargo.toml`, no `build.rs`, and no `.dependencies`. Nothing in `ZIO/src/` or
`ZIO/build.zig` shells out to `cargo` or `rustc`. The port inherits this.

### 8.11 Determinism is a feature

**Partly satisfied. This is the biggest gap the port must work around.**

What zio gives:

* Time is an explicit parameter at the API surface. `AutoCancel.setClock` at
  `ZIO/src/autocancel.zig:72` takes a `Clock`, and `common.timedWaitForIoClock`
  at `ZIO/src/common.zig:711` takes one too.
* A deadline is a value, not a read. `zio.Timeout` at `ZIO/src/time.zig:459` and
  `zio.Duration` at `:92` are plain structs.
* `Loop.poll(.zero)` never blocks (`ZIO/src/ev/loop.zig:1398-1400`).

What zio lacks: any simulated clock or injectable backend. Section 7.4 lists
the gap. The port closes it by keeping all clock reads out of logic and by
testing against `Loop.poll(.zero)`.

### 8.12 Summary table

| Rule | zio | What the port adds |
|---|---|---|
| `io: std.Io` explicit, never global | partly | `io` parameter in every module, `rt` only at the edge, own allocator on the no-task path |
| Network logic pure over bytes | not zio's job | pure decoders and state machines |
| State is a parameter | yes | nothing |
| Allocations are parameters | partly | allocator threaded through the bridge |
| Explicit error sets | mostly | no bare `!` in any public signature |
| Loops have fixed upper bounds | yes | caps on message and event loops |
| All errors handled | yes | nothing |
| No back-compat, no shims | one alias | use none of the aliases |
| Zero dependencies | yes | justify each of the four in section 9 |
| No Rust toolchain | yes | nothing |
| Determinism | partly | no clock reads in logic, `poll(.zero)` tests |

## 9. What the port must supply that zio does not

The dependency order the integration owner set is the following.

1. Zig in the standard library.
2. A Zig package pinned in `build.zig.zon`, such as an existing pure-Zig
   implementation of the same protocol.
3. A Zig `translate-c` binding to a system C library, when no Zig implementation
   exists and the C API binds cleanly.
4. A hand-written C shim, only when the C API cannot be bound directly, and the
   reason is concrete: a macro, an opaque handle, a callback with a
   non-representable type, or varargs.

Four capabilities are missing or partial. Each row gives the rung and why it
cannot sit higher.

### 9.1 A D-Bus client

**Rung 2. A Zig package pinned in `build.zig.zon`.**

The package is `goose`, registry name `luxluth/goose`, a pure-Zig D-Bus
implementation. The completeness verdict against the operations AccessKit's
Linux adapter needs is recorded in `docs/12-accesskit-adapters.md`; this
document does not repeat it. The version that applies is `v3.3.0`, which
declares `minimum_zig_version = "0.16.0"`. `v4.0.0` declares
`minimum_zig_version = "0.17.0"` and does not apply to this project, which pins
Zig 0.16.0 at `build.zig.zon:11`.

Where the search was done, for the record:

| Query | Where | Result |
|---|---|---|
| `dbus` | `https://zigpkg.dev/search?q=dbus` | 6 results: `luxluth/goose` at `v4.0.0`, tagged "A pure Zig D-Bus implementation"; `0xCatPKG/dbuz`, "D-Bus client library written in pure zig"; `akunaakwei/zig-dbus`, "dbus for zig"; and three unrelated results |
| `zig package dbus pure Zig implementation zig.pm` | web search | also surfaced `erffy/plume` on Codeberg, "A pure Zig D-Bus implementation", and `Southporter/dbus` on GitHub |

goose cannot sit at rung 1 because `std` has no D-Bus. It does not need rung 4,
because the protocol layer is Zig.

The other candidates are weaker. `dbuz` and `plume` have no version entry on
zigpkg.dev, so `build.zig.zon` cannot pin them by version. `docs/12` records
the detail.

What zio supplies around the package:

* The connection descriptor watch is `ev.PipePoll`, section 5.6.
* The Unix socket connect is `zio.net.UnixAddress.connect` at
  `ZIO/src/net.zig:764`.
* The cross-thread wake is `ev.Async.notify` at
  `ZIO/src/ev/completion.zig:634`.

What the port must supply: the dispatch loop that turns an `Async` notification
into a select on `goose`'s message source, and the `org.a11y` method table.

**Verdict: not a zio extension, and not a C shim. A pinned Zig package plus a
small project module for the dispatch loop.**

### 9.2 An XCB client

**Rung 3. A Zig `translate-c` binding to `libxcb`.** There is no Zig
implementation of the X11 protocol, and none is plausible: X11 is a wire
protocol with a C-shaped API surface and a server-side half that only the
reference server provides.

Where the search was done:

| Query | Where | Result |
|---|---|---|
| `xcb` | `https://zigpkg.dev/search?q=xcb` | exactly 1 result, `akunaakwei/zig-libxcb`, "libxcb for zig", current version 1.17.0, Zig 0.16.0, Zlib, 0 stars, last commit 14 days before the search |
| `zig.pm packages dbus xcb x11 event loop` | web search | surfaced "Phoenix: A modern X server written from scratch in Zig", which is a server, not a client binding |

`zig-libxcb` is **not** a Zig implementation. Its `build.zig` compiles libxcb
from C:

```zig
const xcb_dep = b.dependency("xcb", .{});
mod.addCSourceFiles(.{ .root = xcb_dep.path("src"), .files = &sources });
```

with `sources` listing `xcb_conn.c`, `xcb_out.c`, `xcb_in.c`, `xcb_ext.c`,
`xcb_xid.c`, `xcb_list.c`, `xcb_util.c`, and `xcb_auth.c`, and it also builds
`xau` and `xorgproto` from C. So it sits at rung 2 for **packaging** and rung 3
for the **binding**, and it does not remove the libxcb dependency. The port may
use it to obtain libxcb without a system `pkg-config`, or it may link the system
library.

The binding itself is clean. The installed headers are macro-free where it
matters:

| Check | Command and result |
|---|---|
| one function-like macro across all installed headers | `grep -hcE '^#define +[A-Za-z_]+\(' /usr/include/xcb/*.h \| paste -sd+ \| bc` returns `1` |
| that macro | `#define XCB_TYPE_PAD(T,I) (-(I) & (sizeof(T) > 4 ? 3 : sizeof(T) - 1))` at `/usr/include/xcb/xcb.h:99` |
| whether it is used | `grep -rn 'XCB_TYPE_PAD' /usr/include/xcb/` returns only the definition, no use |
| the connection type is opaque | `/usr/include/xcb/xcb.h:108` `typedef struct xcb_connection_t xcb_connection_t;` |
| the poll entry point | `/usr/include/xcb/xcb.h:313` `xcb_generic_event_t *xcb_poll_for_event(xcb_connection_t *c);` |
| the blocking entry point | `/usr/include/xcb/xcb.h:300` `xcb_generic_event_t *xcb_wait_for_event(xcb_connection_t *c);` |
| the descriptor accessor | `/usr/include/xcb/xcb.h:482` `int xcb_get_file_descriptor(xcb_connection_t *c);` |
| the reply checker | `/usr/include/xcb/xcb.h:379` `xcb_generic_error_t *xcb_request_check(xcb_connection_t *c, xcb_void_cookie_t cookie);` |
| the event header is a plain struct | `/usr/include/xcb/xcb.h:130` `uint8_t response_type;` in `xcb_generic_reply_t` |

`xcb_poll_for_event` returning a nullable pointer is exactly the shape the port
wants: it drains whatever XCB has already read, and returns null when the queue
is empty. The loop is then: wait on `ev.PipePoll` for the XCB descriptor, drain
with `xcb_poll_for_event` until null, decode each event.

**Verdict: not a zio extension. A project module that `translate-c` binds
`xcb.h` and wraps `xcb_poll_for_event` over `ev.PipePoll`. No C shim is needed,
because no header uses a macro that `translate-c` cannot evaluate.**

### 9.3 A main-loop integration

**zio supplies it. The port supplies nothing.**

The primitives are `zio.ev.Loop` (`ZIO/src/ev/loop.zig:482`),
`Loop.poll(wait_cap)` (`:1404`), `Loop.done` (`:605`), `Loop.nextDispatched`
(`:586`), and the `do_not_call_callbacks` option (`:511`, `:520`). Section 5.9
cites the upstream evidence that this is a supported use, including blazio, a
CPython `asyncio` loop built on `zio.ev` (`ZIO/docs/index.md:9`).

The one thing the port must add is a decision, not code. AccessKit on Linux
also needs a **main** loop for the X11 event queue and a **bus** loop for the
AT-SPI connection. `LoopGroup` at `ZIO/src/ev/loop.zig:136` is the type for
grouping loops that service each other's operations, and `Loop.Options.loop_group`
at `ZIO/src/ev/loop.zig:518` is the parameter.

### 9.4 A thread-pool bridge

**zio supplies the mechanism. The port supplies one adapter function.**

The mechanism is `ev.Work` at `ZIO/src/ev/completion.zig:654-718` and
`ThreadPool.submit` at `ZIO/src/ev/thread_pool.zig:181`. Fields the port sets:

| Field | Line | Purpose |
|---|---|---|
| `func: *const fn (work: *Work) void` | `ZIO/src/ev/completion.zig:658` | the blocking call |
| `userdata: ?*anyopaque` | `ZIO/src/ev/completion.zig:659` | the C handle |
| `completion_fn` and `completion_context` | `ZIO/src/ev/completion.zig:661-662` | the wake |
| `cancel_token: ?*os.syscall_cancel.Token` | `ZIO/src/ev/completion.zig:668` | makes a blocking syscall interruptible |
| `reserve_thread: bool` | `ZIO/src/ev/completion.zig:679` | guarantees a worker for a job that may block on something queued behind it |

`ThreadPool.cancel` at `ZIO/src/ev/thread_pool.zig:255-294` documents the
distinction the port must respect: with a `cancel_token` the work always runs and
the cancellation arrives in-band as `error.Canceled` (`:256-265`). Without one,
the job is dropped if it has not started (`:267-272`). Any call into libxcb or
into a blocking D-Bus read therefore needs a token.

The higher-level entry point already exists: `rt.spawnBlocking` at
`ZIO/src/runtime.zig:1850`, and `blockInPlace` at `ZIO/src/common.zig:846` for a
call that must not return until it finishes. `blockInPlaceReserved` at
`ZIO/src/common.zig:863` is the deadlock-safe variant.

**Verdict: not a zio extension. One small project module that turns a
`callconv(.c)` function plus an opaque pointer into an `ev.Work`.**

### 9.5 Items zio has that need nothing from the port

For completeness, these came up and are already covered.

| Capability | Evidence |
|---|---|
| POSIX signal delivery as a task wakeup | `zio.Signal` at `ZIO/src/signal.zig:244`, `asyncWait` at `:360` |
| Process spawn and reap | `std.process.spawn(io, ...)` at `STD/process.zig:442`, zio's `childWait` at `ZIO/src/process.zig:15` |
| DNS resolution | `zio.net.HostName.lookup` at `ZIO/src/net.zig:174` |
| Thread-safe primitives usable from a C thread | `zio.Mutex` at `ZIO/src/sync/Mutex.zig:56`, documented usable "from a foreign thread" at `:69` |
| Standard handles | `zio.stdin`, `zio.stdout`, `zio.stderr` at `ZIO/src/zio.zig:73-75` |
| Structured logging that does not block the loop | `zio.debug_io` at `ZIO/src/zio.zig:101` |

### 9.6 The one runtime gap the port must patch around

`ZIO/src/common.zig:623-624` and `ZIO/src/common.zig:689-690` reach for
`std.heap.c_allocator` when no task is in scope, and the in-source TODO names
the fix. `ZIO/src/io.zig:1724` does the same for the `debug_io` scratch
allocator.

The port does not patch zio. It does the following instead.

1. **Every path that may run without a task lives in a port module** that takes
   `gpa: std.mem.Allocator` and a `*zio.Runtime` explicitly. No port code calls
   `common.waitForIo` without a task.
2. **The allocators are checked at the boundary.** The port's own allocator
   wrapper fails Nth allocation for the fail-N tests required by
   `ozai/AGENTS.md` section 2.
3. **The two zio sites are recorded as known debt** in `docs/40-plan.md` rather
   than worked around by reaching into zio internals. Reaching into
   `common.waitForIo` from the port would create a dependency on a private
   module, which is worse than the global allocator.

### 9.7 Host libraries present on this machine

Recorded because section 9 needs the ladder position, not because the port
links them. The command is `pkg-config --modversion <name>`.

| Library | Version | Rung for this port |
|---|---|---|
| `xcb` | 1.17.0 | rung 3, `translate-c` binding, section 9.2 |
| `xcb-icccm` | absent | none |
| `xcb-keysyms` | absent | none |
| `dbus-1` | 1.14.10 | rung 4 candidate only if goose fails, see section 9.1 |
| `gio-2.0` | 2.84.4 | rung 3 at best, and never chosen: goose is rung 2 |
| `glib-2.0` | 2.84.4 | rung 3 at best, and never chosen |
| `gobject-2.0` | 2.84.4 | rung 3 at best, and never chosen |
| `atspi-2` | absent | the Linux adapter needs its own AT-SPI layer |
| `libudev` | 257 | not used by any AccessKit adapter |

`cargo` and `rustc` are both present at
`~/.local/share/cargo/bin/`, confirmed with
`command -v cargo rustc`. Neither is a build input for this project. The port
does not invoke them, does not vendor a `Cargo.toml`, and does not use them as a
test oracle. Where a cross-check against upstream behaviour matters, the port
uses a recorded fixture checked into the repository.

### 9.8 What this document leaves to `docs/30-port-design.md`

Four decisions are open, and each needs evidence this document supplies but
does not make.

1. **Which D-Bus package, pinned at which version.** Section 9.1 names goose
   `v3.3.0` and the four alternatives that were searched. The design document
   picks one and records why.
2. **Whether the port links the system `libxcb` or the `zig-libxcb` build.**
   Section 9.2 gives both rungs. The choice depends on whether the target hosts
   have libxcb development headers, which `docs/05-platform-feasibility.md`
   answers.
3. **One loop or two for Linux.** Section 9.3 lists the primitives. The design
   document decides between a single `LoopGroup` and two independent loops.
4. **Where the runtime handle is allowed to appear.** Section 8.1 lists the six
   zio sites that read a thread-local. The design document fixes the boundary
   and the rule that keeps library code off it.
