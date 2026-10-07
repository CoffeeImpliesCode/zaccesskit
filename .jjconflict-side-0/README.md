# zaccesskit

## What this is

`zaccesskit` is a pure Zig 0.16 port of the AccessKit accessibility toolkit. It
translates each upstream Rust module and each public function into Zig, module
by module and function by function. It does not wrap, link or call the Rust
implementation, and it needs no Rust toolchain at any point.

The async design runs the other way round from what the name suggests.
`std.Io` is the interface. `zio` is one implementation behind it, in the place
`std.Io.Threaded` and `std.Io.Uring` sit. Every library signature takes
`io: std.Io`, and a `*zio.Runtime` appears only where a task is spawned, a group
is driven or a timeout is armed. `docs/30-port-design.md` section 7 and
`docs/20-zio-and-zig-io.md` section 1 carry the reasoning.

It tracks two upstream repositories, which version independently:

| Upstream | Repository | Commit | Version |
|---|---|---|---|
| AccessKit core | `https://github.com/AccessKit/accesskit` | `466e24e252103f4d82bd6fbab98141b551e46e0c` | 0.25.1 |
| AccessKit C bindings | `https://github.com/AccessKit/accesskit-c` | `8b6ed37c20ed4c59390e253407983333053662ba` | 0.23.1 |

The C bindings left the core repository on 2024-07-21 in commit `553d9c1`,
"chore: Move the language bindings to standalone repositories" (#442). The two
version numbers are not a skew. `accesskit-c/Cargo.toml:20` pins
`accesskit = "0.25.1"`, so the bindings already build against the core this port
targets and the generated header already matches it.
`docs/11-accesskit-c-abi.md:30-64` and `docs/30-port-design.md:43-45` record it.

## What is in the tree

The library exists. The table below is a census of the working copy, measured by
reading the files: module and line counts from `find` and `wc`, and test counts
from a comment-aware scan for `test "` declarations. The last column counts the
modules `zig build test` reaches from `src/root.zig`. A milestone moves every
figure in the table, so treat each one as the reading of a moment and
re-measure it before you quote it.

| Layer | Modules | Lines | `test "` | In the analysis graph |
|---|---:|---:|---:|---|
| `src/schema/` | 24 | 13992 | 318 | yes |
| `src/consumer/` | 28 | 21282 | 385 | yes |
| `src/capi/` | 14 | 22316 | 220 | yes |
| `src/adapters/` | 47 | 36528 | 519 | 43 of 47 |
| `src/root.zig` | 1 | 127 | 5 | yes |
| **All of `src/`** | **114** | **94245** | **1447** | **110 of 114** |

`src/schema/` holds the platform-neutral vocabulary: roles, actions, identifiers,
geometry, the property model and the tree update. It holds no I/O, no clock and
no global state. `src/consumer/` holds the materialized tree, the queries over it
and the update protocol that keeps it current. `src/capi/` implements the 498
declarations `include/zaccesskit.h` carries, and `src/adapters/` holds the five
platform adapters. The layering is a constraint rather than a preference:
`docs/30-port-design.md` section 3.3 fixes it.

`include/zaccesskit.h` is 6596 lines and declares 498 functions. A Linux build
exports 446 of them, because 52 sit behind a preprocessor guard that is off
there. `docs/40-capi-build-map.md` section 1.1 measured both figures, and
`tools/capi_parity/main.zig` re-measures them per target on demand.

### The analysis graph does not cover four files

`zig build test` compiles the test root `src/root.zig` and follows every
`@import` from it. That reaches 110 of the 114 modules under `src/`. The other
four are on disk, are compiled by nobody, and hold 1554 lines and 22 `test "`
declarations.

| File | Lines | `test "` | Why nothing imports it |
|---|---:|---:|---|
| `src/adapters/windows/bindings.zig` | 746 | 6 | Needs the `zigwin32` pin, which `build.zig.zon` does not declare. |
| `src/adapters/windows/com.zig` | 532 | 8 | The same pin. This is the COM node layer. |
| `src/adapters/windows/error_codes.zig` | 176 | 5 | The same pin. |
| `src/adapters/windows/window_handle.zig` | 100 | 3 | The same pin. Nothing else named it. |

All four are Windows modules, and declaring the pin does not reach them.
Compiled against the pinned `zigwin32` commit with Zig 0.16.0, `bindings.zig`
compiles and its six tests pass on `x86_64-linux`, the other three fail to
compile, and `bindings.zig` itself cannot be analysed for `aarch64-linux` or
`powerpc64-linux`. `docs/42-native-adapter-build-map.md` section 2.1.5 gives
every diagnostic and the fix it needs.

The same question on the AT-SPI side has a different answer, and the difference
is the finding. `goose` covered four type definitions there, so those modules
now write their own D-Bus body bytes and are reached. No Zig package covers the
UI Automation boundary, so the Windows four cannot be written the same way.

Reproduce the reachability with a walk of the `@import` graph from
`src/root.zig`, skipping `std`, `builtin`, `zio` and `build_options`.

### What the run reports, and what it does not

The integration owner reports `zig build test` exiting 0 with 1371 tests passing
in Debug and in ReleaseSafe, no leaks. That is the owner's observation. This
README does not repeat a run it did not perform.

The census above is a different measurement and the two do not agree exactly:
1425 `test "` declarations sit in the analysis graph against 1371 reported
passes. A declaration count and a pass count are not the same measurement, and
the two disagree. Do not treat either figure as a certificate for the other.

## Why a direct translation

Upstream AccessKit is Rust that is assumed to compile. Anything the port
borrowed from it would already be type checked, so borrowing saves nothing a
port needs. What a port must earn instead is a faithful translation of every
module and every public function. The failure that matters is not a compile
error. It is output that compiles and computes the wrong value, which no gate on
this host can catch. The mapping from each upstream module and function to its
Zig counterpart is the record under `docs/` listed below, and
`docs/30-port-design.md` fixes the module layout it targets.

## Build and verify

Run every command inside the devenv shell.

| Command | What it does |
|---|---|
| `devenv shell` | Loads `devenv.nix`. It sets `ZIG_GLOBAL_CACHE_DIR`, `GATE_CACHE_DIR` and `GATE_CROSS_OUTPUT` to local disk, and it links `.zig-cache` and `zig-pkg`. `direnv allow` in this directory does the same. |
| `zig build` | Builds the default step. The default step publishes the module, and `zig-out/` stays empty because the build declares no artifact. |
| `zig build test` | Runs the `test` step: one Debug shard and one ReleaseSafe shard, each under `ulimit -v 4194304`. |
| `zig build cross-test` | Builds and runs the Debug shard for every target in `cross-test.profile.sh`. Each row uses the runner `cross-test` selects. The profile refuses a missing runner, so a broken emulator fails the run instead of reporting build-only coverage. |
| `zig build capi-parity` | Runs the parity tool's own tests, then the sweep that compares `include/zaccesskit.h` against what `src/capi/` exports, per target, with both the header guards and the Zig `comptime` guards evaluated. Exit 0 is parity, 1 a mismatch, 2 something unreadable, 3 a bad command line. |
| `test/c_consumer/check.sh` | Compiles the C consumer against the header under C11 with `-Wall -Wextra -Wpedantic`, and checks the declaration census. It stops at `-c` and does not link. |
| `zig-gate` | The house gate, and the authority on whether a change is acceptable. `devenv shell -- gate` runs the same script. |

`zig-gate` is `~/.local/bin/zig-gate`, 823 lines. It
runs ten stages in order: `fmt`, `build`, `test`, `ast-check`, `ziglint`,
`zlint`, `zbc`, `zwanzig`, `cross-test` and `zig-cov`. The last stage runs only
with `--cov`. The script exits 0 when every stage passes, 1 when a stage finds
an issue, and 2 on a usage or environment error. Stage list at `zig-gate:23-33`,
exit policy at `zig-gate:1-5`.

Two commands in that table are not wired into `build.zig`. `test/fuzz/` and
`test/c_consumer/check.sh` have no step, so neither runs when the gate runs.
`test/fuzz/` is four modules and 19 `test "` declarations that import
`../../src/schema/` by relative path; `grep` finds no reference to either path
in `build.zig`. Add a step before treating them as coverage.

The `powerpc64-linux` row is the only big-endian execution proof in this project.
The tree serialisation, the action-channel marshalling and the C ABI structs are
byte layouts, so a big-endian row is the only thing that shows they are written
correctly (`cross-test.profile.sh:29-33`).

### `zig ast-check` reaches further than `zig build test`

`zig ast-check` scans every file under `src/`, so it checks the four modules
the test root cannot reach. A green `zig build test` therefore says nothing
about them. A parse error or a half-finished rename in one of those four files
surfaces at the `ast-check` stage and nowhere else, and no build step will have
warned you first.

`src/adapters/windows/com.zig` is the file to watch. It is the COM node layer,
it is the largest of the four at 532 lines, and no stage above `ast-check`
looks at it.

### The two cache paths must stay symlinks

This checkout is on a network filesystem. Zig 0.16.0 cannot keep a cache there,
so `.zig-cache` and `zig-pkg` are symlinks to `/tmp/cache/zaccesskit/`,
which is on local disk. Keep them symlinks. `devenv shell` recreates them, so if
you delete one, run `devenv shell` and not `mkdir`.

A real directory for `zig-pkg` produces this error. It was observed in this
checkout while the path was still a directory on the network filesystem:

```text
error: package contains 'zio-2662fdc.../src/sync' which has illegal file type 'unknown'
```

A real directory for the build cache produces this instead, recorded at
`~/.dev-env.sh:21-22`:

```text
thread N panic: programmer bug caused syscall error: INVAL
... in dirRenamePreserveLinux
```

Check both paths:

```sh
ls -ld .zig-cache zig-pkg
stat -f -c '%T' .
```

The first line must show two symlinks. The second must print `nfs` for the
checkout and `ext2/ext3` for the cache root.

## Dependencies

| Name | What it is | Pin |
|---|---|---|
| Zig | The compiler. On this host `zig` is an anyzig shim that reads `.minimum_zig_version` to select the toolchain. | `0.16.0`, at `build.zig.zon:11`. That field is a lower bound. 0.16.0 is the line this project targets. |
| `zio` | The async runtime behind `std.Io`. It replaces the tokio runtime the Rust crates depend on. | Commit `2662fdc45997611b962b560c513c16963475a01b`, package version 0.18.0. It is the only declared dependency, at `build.zig.zon:29-33`. |
| `goose` | A Zig D-Bus library and the candidate for the AT-SPI adapter. Under evaluation, not adopted. | Tag `v3.3.0`, commit `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1`. It is not in `build.zig.zon`. |
| `zigwin32` | The candidate binding route for the Windows COM layer. Not adopted. | `marlersoft/zigwin32` at `9f15c276b4e9d05afd34a10d8662a7dfc34647ea`, per `docs/42-native-adapter-build-map.md:38`. It is not in `build.zig.zon`. |

`goose` is unadopted because the port writes its own D-Bus body bytes, so no
module waits on it.

**`zigwin32` is adoptable and is not adopted.** The blocker is not the absence
of a package. The package fetches, declares no dependencies and opens no
header. The blocker is one compile error in each of the three files that do not
compile against it, one test in `error_codes.zig` whose expected value is
wrong, one design question about `HWND`, and one architecture mismatch that
keeps `bindings.zig` out of two rows of the cross-test matrix. A later reader
must be able to tell that from "the package is unavailable", because one is a
decision this project has not taken and the other is not a fact about this
host. `docs/42-native-adapter-build-map.md` section 2.1.5 records every defect
and the fix each one answers.

`goose` v3.3.0 builds and runs under Zig 0.16.0, and
`docs/26-goose-live-bus-probe.md` drove it against the live accessibility bus on
this host. It is not pinned in `build.zig.zon` because the port still owns part
of the server side. `docs/13-atspi-protocol.md` section 6.3 lists eleven gaps
between goose and what an AT-SPI adapter needs, and `docs/40-plan.md:196-201`
records that nine of them are consolidated into risk register entries R1 and R8.
`docs/30-port-design.md` section 7.2 then budgets the parts the port writes
instead at about 630 lines.
That number is a budget, not a measurement.

There is no Rust dependency. No `Cargo.toml`, no `Cargo.lock`, no `build.rs`,
no `rust-toolchain`, no `cbindgen`, and nothing that shells out to Cargo at any
point. `rustc` and `cargo` are installed on this host and are not build inputs.
There is no C library dependency either, because nothing under `src/` links one
yet.

goose v4.0.0 declares `minimum_zig_version = "0.17.0"`, so a 0.16.0 build cannot
fetch it. If goose is adopted, the pin is `v3.3.0`.

Where a dependency is not the Zig standard library, the port tries a fixed
order: the Zig standard library, then a Zig package pinned in `build.zig.zon`,
then a `translate-c` binding to a system C library, then a hand-written C shim.
The last rung needs a named reason, such as a macro, an opaque handle or a
callback with a type the binding cannot represent. `docs/12-accesskit-adapters.md`
places each host dependency on that ladder.

### `.paths` omits three directories the build reads

`build.zig.zon:36-43` packages `build.zig`, `build.zig.zon`, `src`, `docs`,
`README.md` and `AGENTS.md`. It does not name `include`, `test` or `tools`.

`tools` is the sharper problem, because `build.zig:149` names
`tools/capi_parity/main.zig` as a module root. A dependent package that fetches
this one gets a manifest whose build refers to a file the manifest did not ship.
`include` is the header the whole C ABI implements, and `test` holds the fuzz
harness and the C consumer. Add all three, or drop the capi-parity step.

## Where the record is

Forty-one documents live under `docs/`. The groups below are the order a
reader usually needs them in, not the order they were produced.

| Group | Document | What it answers |
|---|---|---|
| The house and the host | `docs/00-house-and-environment.md` | What this machine builds with: house rules, toolchain selection, the network filesystem constraint, the gate stages, the scratch policy. |
| | `docs/05-platform-feasibility.md` | What this host can compile, link, run and test, with the command behind each row. |
| | `docs/21-licensing.md` | Which licences the upstream trees carry, which notice every translated file must retain, and which legal decisions are still open. |
| | `docs/46-onboarding.md` | The six questions a newcomer has, in order. The shortest way in. |
| The upstream surface | `docs/10-accesskit-core.md` | The upstream crate map and the type surface, module by module. |
| | `docs/11-accesskit-c-abi.md` | Every declaration in the AccessKit C header, with the doc comment and the ownership rule each one carries. |
| | `docs/12-accesskit-adapters.md` | What each upstream adapter does, which one to port first, and which rung of the ladder each host dependency belongs on. |
| | `docs/15-tree-semantics.md` | What roles, properties, relations and the node model are, and which enum order is wire-visible. |
| | `docs/19-geometry-and-text.md` | What the geometry types and the text interfaces are, with the byte layouts the C ABI must match. |
| | `docs/23-core-boundary.md` | Where the platform-neutral part of AccessKit ends, and where the port puts its own line. |
| The platforms | `docs/13-atspi-protocol.md` | What the AT-SPI over D-Bus contract is, and where goose falls short of it. |
| | `docs/14-x11-wayland-surface.md` | What the display server surface does and does not need, given that upstream ships no X11 path. |
| | `docs/16-native-platform-apis.md` | Every Win32, UI Automation, Objective-C, AppKit, UIKit and JNI symbol the four adapters touch, and what this host can verify. |
| | `docs/16a-windows-translate-c.md` | The Windows fallback route: where the MinGW headers live and which header holds which symbol. |
| | `docs/29-apple-android-apis.md` | The iOS and Android symbols and the licensing on the derived Flutter files. |
| The runtime and the toolchain | `docs/07-zig-ecosystem.md` | Which Zig packages exist for each host dependency, measured at a pinned commit. |
| | `docs/20-zio-and-zig-io.md` | Which async layer the port builds on, and what `std.Io` and `zio` each give it. |
| | `docs/22-zig-build-surface.md` | Which Zig 0.16.0 build calls a pure-Zig port needs, with `path:line` into the standard library. |
| The prior art | `docs/06-rust-to-zig-lessons.md` | What this house already learned translating Rust to Zig elsewhere, and which lessons bind this port. |
| | `docs/24-rust-idiom-mapping.md` | The input contract for a Rust-to-Zig port, and the construct-by-construct mapping table. |
| | `docs/24b-translation-checklist.md` | The per-function checklist, the rejections already recorded, and the rules inherited from the house translator. |
| | `docs/25-r2z-oracle-and-promotion.md` | Where an oracle may and may not come from, and which mechanisms are worth copying. |
| Feasibility and experiments | `docs/17-rust-dependency-surface.md` | Every Rust crate AccessKit depends on, and what replaces each one. |
| | `docs/18-testing-strategy.md` | What each gate stage really checks, what a green gate does not prove, and the item list a milestone must satisfy. |
| | `docs/26-goose-live-bus-probe.md` | Whether goose v3.3.0 can carry the AT-SPI adapter against the live bus on this host. |
| | `docs/27-x11-headers-resolution.md` | Whether the four missing X11 headers can be obtained on this host, and what each attempt cost. |
| The design set | `docs/30-port-design.md` | The module layout, where the runtime is allowed, and every design decision the research forces. |
| | `docs/31-c-abi-design.md` | The C declarations the port reproduces, the checked-in header, and the rule that keeps header and Zig types in step. |
| | `docs/32-layout-and-naming-corrections.md` | Layout and naming corrections, measured. |
| | `docs/33-consumer-interface-contract.md` | The interface the consumer layer was written against. |
| | `docs/34-design-record-corrections.md` | Where the design record was wrong, and the measurement that settles it. |
| | `docs/35-translation-ledger-schema.md` | The translation ledger for the settled schema modules. |
| | `docs/36-consumer-call-graph.md` | The consumer layer import table and the owner of every symbol. |
| The build maps | `docs/40-capi-build-map.md` | The `src/capi/` census: what to write, in what order, and the per-target function counts. |
| | `docs/41-atspi-build-map.md` | The `src/adapters/atspi/` census, and the goose gaps that block the transport. |
| | `docs/42-native-adapter-build-map.md` | The four native adapters: symbol census, binding route, and the verification each can reach here. |
| | `docs/51c-macos-test-plan.md` | What a macOS adapter test needs, and what a Linux host cannot provide. |
| Plan and status | `docs/40-plan.md` | The milestone order, the gate each milestone must pass, and the open risks beside it. |
| | `docs/45-plan-status.md` | Milestone status measured against the plan, with the claims it cannot verify. |
| | `docs/50-risk-register.md` | The open risks, each with its trigger and its mitigation. |
| | `docs/50-verification.md` | The evidence vocabulary, what each label does not establish, and the claims this project refuses to make. |

`docs/50-verification.md` section 1 defines three labels — source reading at a
pinned revision, exercised compilation, and runtime observation — and section 1.2
says what each one does not establish. Its section 1.3 describes the repository
as it stood before the schema, consumer, C ABI and adapter layers landed, so
treat that paragraph as history rather than as current state.

Two Zig 0.16.0 compiler defects shape the plan, and both are in the record
above rather than in a workaround in this file.

`-femit-h` is broken, so the C header is checked in instead of generated:

```text
error: error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698
```

`docs/22-zig-build-surface.md` section 9.5 and `docs/40-plan.md:620` record it.
`-ffuzz` does not compile either, so no fuzz gate is promised:

```text
lib/compiler/test_runner.zig:566:55: error: expected type '*const debug.StackTrace', found '*builtin.StackTrace'
```

`docs/22-zig-build-surface.md` section 9.7, `docs/40-plan.md:88` and
`docs/30-port-design.md:134` record it. This is why `test/fuzz/` runs as an
ordinary test rather than as a fuzz target.

## Layout

```text
zaccesskit/
├── .envrc                  direnv hook, loads the host scratch policy first
├── .gitignore              the caches, `.jj/` and the generated directories
├── AGENTS.md               the house rules this repository is written under
├── README.md               this file
├── build.zig               one module and three named build steps
├── build.zig.zon           package manifest, one dependency
├── cross-test.profile.sh   the target matrix gate stage 9 runs
├── devenv.lock
├── devenv.nix              the development environment and the gate task
├── devenv.yaml
├── docs/                   41 research, design and status documents
├── include/
│   └── zaccesskit.h        the C ABI, checked in rather than generated
├── src/
│   ├── root.zig            the module root; re-exports the three namespaces
│   ├── schema/             24 modules: the platform-neutral vocabulary
│   ├── consumer/           28 modules: the tree, its queries, the update protocol
│   ├── capi/               14 modules: the 498 header declarations in Zig
│   └── adapters/
│       ├── atspi/          10 modules: the Linux and BSD adapter
│       ├── windows/        12 modules: UI Automation and the COM node layer
│       ├── macos/          5 modules: AppKit and the Objective-C selectors
│       ├── ios/            6 modules: UIKit and the UIKit identifiers
│       └── android/        14 modules: the JNI boundary and its adapters
├── test/
│   ├── c_consumer/         a C program that spells the whole header, and its check
│   └── fuzz/               the seeded property generator and its corpus
└── tools/
    └── capi_parity/        the header-against-exports sweep, with its own tests
```

Two symlinks sit beside that tree and point at local disk, because Zig 0.16.0
cannot keep a cache on this network filesystem:

```text
.zig-cache -> /tmp/cache/zaccesskit/build
zig-pkg -> /tmp/cache/zaccesskit/pkg
```

`.jj/` and `.git/` hold the colocated version control. `.devenv/` and `.direnv/`
are generated. `codedb.snapshot` is an index artifact and is ignored.

Five object files sit in the repository root: `probe2.o`, `probe6.o`, `probe7.o`,
`probe8.o` and `probe9.o`, together about 30 MB. They are scratch output from
the geometry probes `docs/19` records, nothing imports them, and `.gitignore`
does not name them. Delete them.

The adapter order is fixed: `atspi`, `windows`, `macos`, `ios`, `android`.
AT-SPI comes first because it is the only adapter whose protocol runs on this
host, against the live accessibility bus. There is no X11 adapter to port,
because upstream ships none; `adapters/unix/src/` holds no X11, XCB or Wayland
code (`docs/12-accesskit-adapters.md:68-80`).

## Licence

This project has no licence of its own yet. None has been chosen, and nothing in
the tree asserts one.

AccessKit is `MIT OR Apache-2.0` at your option for AccessKit-authored material.
Twelve files derived from Chromium and from the Flutter engine carry the Chromium
BSD-style licence on top, so the notices stack per file rather than forming one
three-way choice. `accesskit-c` adds an LGPL-2.1 notice for its Meson build
system alone, which this port does not copy. `docs/21-licensing.md` records each
licence, the notice every translated file must retain, and the decisions still
open. That document is an inventory, not legal advice. A qualified reviewer must
confirm its conclusions, including the derivative-work judgement for
translation, before the port is released.