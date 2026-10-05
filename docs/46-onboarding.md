# 46 — Onboarding

This document is for someone who arrives at this repository today and knows nothing
about it. It answers six questions in the order the reader has them. Where a fact has
an owner elsewhere, it names the owner instead of repeating it.

## 1. What this is

`zaccesskit` is a pure Zig 0.16 port of the Rust `accesskit` accessibility toolkit.
It rewrites every upstream Rust module and every public function in Zig, and it links
no Rust code and calls no Rust toolchain. It runs on the `zio` async runtime and it
ships one C header, `include/zaccesskit.h`, so a platform adapter can be written in
any language that speaks C.

Three constraints bind every decision in the tree. `AGENTS.md` section 1 is the
authority.

| Constraint | What it forbids |
|---|---|
| Not a wrapper | No `libaccesskit`, and no Rust behind an `extern`. |
| Zero Rust toolchain | No `Cargo.toml`, no `cargo`, and no Rust-built oracle. |
| Zig before C | Standard library, then a pinned package, then `translate-c`, then a shim. |

## 2. Build and test

### 2.1 Read this before the first build

`$HOME` is on NFS. Zig writes files atomically with `renameat2(RENAME_EXCHANGE)`, and
NFS does not implement that call. NFS rejects it with `EINVAL`, so a build whose cache
sits on NFS dies before it compiles anything.

The failure looks like a compiler defect. It is not.

```text
thread N panic: programmer bug caused syscall error: INVAL
... in dirRenamePreserveLinux
```

`docs/00-house-and-environment.md` section 4.2 records this failure and the second
NFS failure, which is the package unpacker reporting `illegal file type 'unknown'`.

The checkout is on NFS, so both cache paths are symlinks to local disk. They must stay
symlinks.

```text
.zig-cache -> /tmp/cache/zaccesskit/build
zig-pkg     -> /tmp/cache/zaccesskit/pkg
```

If either path is a real directory, do not delete its contents by hand and do not run
`mkdir`. Run `devenv shell`. It recreates both symlinks.

Check the paths before you build.

```sh
ls -ld .zig-cache zig-pkg
stat -f -c '%T' .
```

The first command must print two symlinks. The second must print `nfs` for the
checkout. Then check the cache root on its own.

```sh
stat -f -c '%T' /tmp/cache/zaccesskit
```

That one must print `ext2/ext3`.

### 2.2 `zig` is a shim, not the compiler

`zig` on `PATH` is an `anyzig` shim. It reads `.minimum_zig_version` from
`build.zig.zon` and selects the toolchain from it. Do not install a second compiler
beside it and do not write the version anywhere else. The manifest is the single
version authority for the project and for every tool the gate runs.

### 2.3 The commands

Enter the environment first. `.envrc` loads the host scratch policy and then runs
devenv. Either of these two commands does that job.

```sh
devenv shell
```

```sh
direnv allow .
```

Then run the build steps from the repository root.

```sh
zig version
zig build
zig build test
zig build cross-test
```

| Command | What it does |
|---|---|
| `zig version` | Prints the version the shim selected. |
| `zig build` | Builds the default step, which is the published module. |
| `zig build test` | Runs four shards: `test-Debug`, `test-ReleaseSafe`, `fuzz-Debug` and `fuzz-ReleaseSafe`. |
| `zig build cross-test` | Runs the Debug shard for every foreign target. |
| `zig build fuzz` | Replays the committed corpus. `zig build test` already depends on both fuzz shards. |
| `zig build capi-parity` | Compares `include/zaccesskit.h` against the exports for every measured target. |
| `zig build docs-tables` | Checks the generated symbol tables in `docs/36` against the source. |

Each native test shard runs under a four gibibyte address-space ceiling, so a runaway
test fails quickly. `build.zig` names the ceiling and applies it.

The gate is the authority on whether a change is acceptable. Run it once, after the
work lands, not while you edit.

```sh
zig-gate
```

Inside devenv the same script is a task.

```sh
devenv shell -- gate:zaccesskit
```

`zig-gate` runs ten stages: `fmt`, `build`, `test`, `ast-check`, `ziglint`, `zlint`,
`zbc`, `zwanzig`, `cross-test` and `zig-cov`. The last one runs only with `--cov`.
`AGENTS.md` section 4 owns the stage list.

### 2.4 Read the count, not the verdict

`zig build test` prints a test count. Read it. A run with no count and no `skipped`
line is a harness failure, not a clean run. `AGENTS.md` section 10 item 2 says this.

The count covers the modules the `test` step reaches from `src/root.zig`. That root
re-exports `schema`, `consumer` and `capi`. A `pub const` that no other declaration
references is a re-export that analyzes nothing, so the count says nothing about a
module that no re-export reaches.

A walk of the `@import` graph from `src/root.zig` on 2026-10-05 puts that number in
writing. The tree holds 114 modules under `src/`. 106 of them are in the graph. The
eight that are not hold 2430 lines and 46 of the 1438 `test "` declarations under
`src/`, so no shard reaches them. Seven are AT-SPI or Windows modules, and three of
those, `src/adapters/windows/bindings.zig`, `src/adapters/windows/com.zig` and
`src/adapters/windows/error_codes.zig`, are outside the graph because
`build.zig.zon` does not name `zigwin32`. `src/adapters/windows/root.zig:19-21` says
so. Do not quote a test count as coverage of those eight files.

### 2.5 Scratch

Put scratch under `/tmp/scratch/<your-slice>/`. Never use `/tmp`, never
use `/var/tmp`, and never write scratch under the NFS home. The pinned upstream trees
are read-only and live at `/tmp/scratch/accesskit`,
`/tmp/scratch/accesskit-c` and `/tmp/scratch/goose`.

## 3. The map of the source

Read the layers in this order. Each one depends on the layers above it in the list.

1. `src/schema/` is the platform-neutral value types. It holds roles, actions,
   identifiers, geometry, the property model and the tree update. It holds no runtime,
   no clock and no socket. A consumer reaches it as `@import("zaccesskit").schema`.
2. `src/consumer/` is the materialized tree, the queries over it, and the update
   protocol that keeps it current. A consumer reaches it as
   `@import("zaccesskit").consumer`.
3. `src/capi/` is the C ABI. It implements the 498 declarations in the header so a
   platform adapter can link against them. A consumer reaches it as
   `@import("zaccesskit").capi`.
4. `src/adapters/` holds five platform adapters: `atspi`, `windows`, `macos`, `ios`
   and `android`. Each one feeds the C ABI, and `src/capi/platform.zig` imports them
   all.
5. `include/zaccesskit.h` is the C contract, checked in. It is the only thing a C
   consumer compiles against.
6. `test/` holds the C consumer, the fuzz corpus and the fuzz generator.
7. `tools/` holds Zig helper programs, such as the header parity checker.

`src/root.zig` is the module root. It declares five names: `schema` at
`src/root.zig:36`, `consumer` at `:49`, `capi` at `:57`, `version` at `:68` and
`minimum_zig_version` at `:74`. It also holds five tests. The first three
declarations carry a `refAllDecls` test, which is what makes a green run reach the
modules underneath them. Everything a consumer reaches is re-exported there.

### 3.1 Which document answers which question

| Your question | Read this |
|---|---|
| What does this machine build with? | `docs/00-house-and-environment.md` |
| What can this host compile and run? | `docs/05-platform-feasibility.md` |
| What upstream surface am I porting? | `docs/10-accesskit-core.md` |
| What does each upstream C declaration do? | `docs/11-accesskit-c-abi.md` |
| What does each upstream adapter do? | `docs/12-accesskit-adapters.md` |
| What are roles, properties and the node model? | `docs/15-tree-semantics.md` |
| What are the geometry and text byte layouts? | `docs/19-geometry-and-text.md` |
| Which async layer does the port build on? | `docs/20-zio-and-zig-io.md` |
| Which licences apply to a translated file? | `docs/21-licensing.md` |
| Which Zig 0.16.0 build calls do I need? | `docs/22-zig-build-surface.md` |
| Where does the platform-neutral part end? | `docs/23-core-boundary.md` |
| How does a Rust construct map to Zig? | `docs/24-rust-idiom-mapping.md` |
| What does a translation ledger row hold? | `docs/24b-translation-checklist.md` |
| What is the module layout? | `docs/30-port-design.md` |
| What is the C seam? | `docs/31-c-abi-design.md` |
| Which consumer module owns a shared type? | `docs/33-consumer-interface-contract.md` |
| Which consumer module calls which? | `docs/36-consumer-call-graph.md` |
| What is the milestone order? | `docs/40-plan.md` |
| Which C ABI declaration lives where? | `docs/40-capi-build-map.md` |
| Which AT-SPI piece lives where? | `docs/41-atspi-build-map.md` |
| Which native platform piece lives where? | `docs/42-native-adapter-build-map.md` |
| How far along are the milestones? | `docs/45-plan-status.md` |
| What evidence does a milestone record? | `docs/50-verification.md` |
| What is still a risk? | `docs/50-risk-register.md` |

## 4. Rules that are settled

Do not re-open these four. Each was contested or paid for, and the answer is recorded.

### 4.1 `gpa` is the first parameter of an allocating free function

`AGENTS.md:99` is the authority. An allocating free function takes
`std.mem.Allocator` first. An allocating method takes the receiver first, because Zig
builds the call syntax only in that order. The difference is a language fact, not a
preference.

This was contested twice. It is settled. Do not put the allocator second on a free
function and do not add a comment that argues for it.

### 4.2 Every loop over a domain carries a `comptime` bound

A loop over a domain is bounded, the bound is named, and the bound function is derived
in its module doc. `treeWalkStepBound` and `graftChainStepBound` in
`src/consumer/tree_state.zig` are the two examples. A walk reports exhaustion as its
own error. An unbounded loop is a review finding, not a style question.

### 4.3 `FullNodeId` compares with `std.meta.eql`

`FullNodeId` is a 16-byte struct with four padding bytes, so `==` compares padding that
carries no value. Compare it with `std.meta.eql` and with nothing else. The same rule
holds for any padded struct in this tree.

### 4.4 The shared C ABI boundary types live in `src/capi/boundary.zig`

They live there and nowhere else. `src/capi/platform.zig` imports every adapter, and an
adapter needs the four callback types to hold a handler it was given. An adapter that
reached into `platform.zig` for them would make the two files import each other, and
that is a cycle at the seam where `@export` runs at `comptime`.

So `boundary.zig` is a leaf that imports only `schema`. `platform.zig` imports it and
re-exports every name. Every adapter imports it directly. Neither side imports the
other.

Only a type both sides must name belongs there. A type one platform uses alone belongs
in that platform's adapter.

## 5. Five traps

Each of these has cost time in this repository. Each one names what to do instead.

### 5.1 `expectEqual` on a slice compares the pointer

`expectEqual` compares slices as values, and a slice value includes its pointer. Two
equal strings in two different buffers fail.

Use `expectEqualStrings`. Use `expectEqualSlices` only when the element order matters
and the bytes come from the same buffer.

### 5.2 A narrow scratch root reports green for what it never analyzed

A scratch test file that imports two modules is a run over two modules. Every module it
does not import is analyzed by nothing, and the run still reports green. This has
already hidden a use-after-free, because no run had ever compiled the file the defect
was in.

The same holds for `pub const X = @import("X/root.zig")` when nothing references `X`.
A re-export nothing references is a re-export that analyzes nothing.

Use `zig build test`. Its root is `src/root.zig`. A narrow closure over a few files is
worse than no run at all, because it reads as evidence.

### 5.3 `TreeState.nodes.get(id)` returns a copy

`TreeState.nodes` is a hash map of `NodeState`, so `get` returns a `NodeState` by value.
That copy is detached from the map. A property setter on it frees the payload the map
still points at, and the next `deinit` walks freed memory.

Use `getPtr`. Take the pointer, do the write, and drop it.

### 5.4 An `errdefer` that outlives the call that takes ownership is a double free

An `errdefer` runs when the enclosing block exits with an error, and it also runs when
an assertion below it fails. If ownership has already moved past the call, the
`errdefer` frees what the new owner will free again.

Move the `errdefer` into the block that owns the value, or cancel it as soon as the
transfer happens.

### 5.5 A C string stops at the first NUL

`accesskit_string_free` releases with `std.mem.span`, and `std.mem.span` finds the end at
the first NUL. An allocation that holds one byte past a NUL is freed at the wrong
length. A C reader using `printf("%s")` truncates at the same place.

`marshal.dup_c_string` truncates on purpose. Every function that takes or returns text
says so in its own doc comment. Follow that convention when you add one.

## 6. Where the work is going next

Two parts of the tree are in progress. Assume neither is finished, and do not quote a
coverage number that counts a file no build step reaches.

`src/capi/` is in progress. The C ABI does not compile end to end yet. Its design
record is `docs/40-capi-build-map.md`, and `docs/31-c-abi-design.md` holds the seam
itself. That build map measures the C ABI at 446 of the 498 declarations exported on a
Linux target. The header declares more than one target exports, so those two numbers
are not a gap to close. They answer two different questions.

`src/adapters/` is in progress. Five adapter directories exist, and four of them are
being written now. The records are `docs/41-atspi-build-map.md` for AT-SPI and
`docs/42-native-adapter-build-map.md` for Windows, macOS, iOS and Android.

`docs/45-plan-status.md` holds the measured status against `docs/40-plan.md`. It keeps
four status words apart, because a file that exists is not a file that compiles, and a
build that passes is not a build that ran against a platform.