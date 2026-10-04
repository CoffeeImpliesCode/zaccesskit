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

## Status

The library does not exist yet. The design record below is large, and it does not
change that. The table says what is in the tree today, and gives the command or
the file that checks each line.

| Part | State | How to check it |
|---|---|---|
| Build wiring | Done. One module, `zaccesskit`, rooted at `src/root.zig`. No executable and no C artifact. | Run `zig build`. It exits 0. Wiring at `build.zig:37-44`. |
| Test wiring | Done. The `test` step runs one Debug shard and one ReleaseSafe shard, each under a 4 GiB address-space ceiling. Neither shard holds a test yet. | Run `zig build test`. It exits 0. Step at `build.zig:52-71`, ceiling at `build.zig:18-22`. |
| Foreign matrix wiring | Done. The `cross-test` step builds the Debug shard for each profile target and runs it through the runner the build system selects. No foreign row holds a test yet. | Run `zig build cross-test`. It exits 0. Step at `build.zig:84-102`, targets at `cross-test.profile.sh:38-42`. |
| Gate profile | Done. Gate stage 9 reads `cross-test.profile.sh`, and the profile names the step it builds. | `cross-test.profile.sh:1-59`. |
| Module root | Documentation only. `src/root.zig` is 19 lines of doc comment and declares nothing. | Read `src/root.zig`. |
| Lint state | One warning, `empty-file`, because the module root declares nothing. It stays until a milestone adds a declaration, and no declaration is added to silence it. | Run `zlint -S src/root.zig`. |
| Environment files | Present. `devenv.nix`, `devenv.lock`, `devenv.yaml`, `.envrc` and `.gitignore` set the shell, the scratch policy and the cache paths. | `ls -1` in this directory. |
| Research record | Written under `docs/`. Every document this README names has a row in the table below. | Run `ls -1 docs/`. |
| Design set | Written. `docs/30-port-design.md`, `docs/31-c-abi-design.md`, `docs/40-plan.md` and `docs/50-verification.md` fix the module layout, the C seam, the milestone order and the evidence record. | Read the four files. |
| The library | Not implemented. No tree, no update protocol, no action channel, no C ABI, no platform adapter, no exported symbol. | Run `ls -1 src/`. It returns one file. |

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
| `zig build` | Builds the default step. |
| `zig build test` | Runs the `test` step: one Debug shard and one ReleaseSafe shard, each under `ulimit -v 4194304`. |
| `zig build cross-test` | Builds and runs the Debug shard for every target in `cross-test.profile.sh`. Each row uses the runner `cross-test` selects. The profile refuses a missing runner, so a broken emulator fails the run instead of reporting build-only coverage. |
| `zig-gate` | The house gate, and the authority on whether a change is acceptable. `devenv shell -- gate` runs the same script. |

`zig-gate` is `~/.local/bin/zig-gate`, 823 lines. It
runs ten stages in order: `fmt`, `build`, `test`, `ast-check`, `ziglint`,
`zlint`, `zbc`, `zwanzig`, `cross-test` and `zig-cov`. The last stage runs only
with `--cov`. The script exits 0 when every stage passes, 1 when a stage finds
an issue, and 2 on a usage or environment error. Stage list at `zig-gate:23-33`,
exit policy at `zig-gate:1-5`.

The `powerpc64-linux` row is the only big-endian execution proof in this project.
The tree serialisation, the action-channel marshalling and the C ABI structs are
byte layouts, so a big-endian row is the only thing that shows they are written
correctly (`cross-test.profile.sh:29-33`). No test runs there yet.

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
There is no C library dependency either, because `src/` holds one file.

goose v4.0.0 declares `minimum_zig_version = "0.17.0"`, so a 0.16.0 build cannot
fetch it. If goose is adopted, the pin is `v3.3.0`.

Where a dependency is not the Zig standard library, the port tries a fixed
order: the Zig standard library, then a Zig package pinned in `build.zig.zon`,
then a `translate-c` binding to a system C library, then a hand-written C shim.
The last rung needs a named reason, such as a macro, an opaque handle or a
callback with a type the binding cannot represent. `docs/12-accesskit-adapters.md`
places each host dependency on that ladder.

## Where the record is

Every document under `docs/` is written. The groups below are the order a reader
usually needs them in, not the order they were produced.

| Group | Document | What it answers | State |
|---|---|---|---|
| The house and the host | `docs/00-house-and-environment.md` | What this machine builds with: house rules, toolchain selection, the network filesystem constraint, the ten gate stages, the scratch policy. | Written |
| | `docs/05-platform-feasibility.md` | What this host can compile, link, run and test, with the command behind each row. | Written |
| | `docs/21-licensing.md` | Which licences the upstream trees carry, which notice every translated file must retain, and which legal decisions are still open. | Written |
| The upstream surface | `docs/10-accesskit-core.md` | The upstream crate map and the type surface, module by module. | Written |
| | `docs/11-accesskit-c-abi.md` | Every declaration in the AccessKit C header, with the doc comment and the ownership rule each one carries. | Written |
| | `docs/12-accesskit-adapters.md` | What each upstream adapter does, which one to port first, and which rung of the ladder each host dependency belongs on. | Written |
| | `docs/15-tree-semantics.md` | What roles, properties, relations and the node model are, so they become Zig types, and which enum order is wire-visible. | Written |
| | `docs/19-geometry-and-text.md` | What the geometry types and the text interfaces are, with the byte layouts the C ABI must match. | Written |
| | `docs/23-core-boundary.md` | Where the platform-neutral part of AccessKit ends, and where the port puts its own line. | Written |
| The platforms | `docs/13-atspi-protocol.md` | What the AT-SPI over D-Bus contract is, and where goose falls short of it. | Written |
| | `docs/14-x11-wayland-surface.md` | What the display server surface does and does not need, given that upstream ships no X11 path. | Written |
| | `docs/16-native-platform-apis.md` | Every Win32, UI Automation, Objective-C, AppKit, UIKit and JNI symbol the four adapters touch, and what this host can verify. | Written |
| | `docs/16a-windows-translate-c.md` | The Windows fallback route: where the MinGW headers live and which header holds which symbol. | Written |
| | `docs/29-apple-android-apis.md` | The iOS and Android symbols and the licensing on the derived Flutter files. | Written |
| The runtime and the toolchain | `docs/07-zig-ecosystem.md` | Which Zig packages exist for each host dependency, measured at a pinned commit. | Written |
| | `docs/20-zio-and-zig-io.md` | Which async layer the port builds on, and what `std.Io` and `zio` each give it. | Written |
| | `docs/22-zig-build-surface.md` | Which Zig 0.16.0 build calls a pure-Zig port needs, with `path:line` into the standard library. | Written |
| The prior art | `docs/06-rust-to-zig-lessons.md` | What this house already learned translating Rust to Zig elsewhere, and which lessons bind this port. | Written |
| | `docs/24-rust-idiom-mapping.md` | The input contract for a Rust-to-Zig port, and the construct-by-construct mapping table. | Written |
| | `docs/24b-translation-checklist.md` | The per-function checklist, the rejections already recorded, and the rules inherited from the house translator. | Written |
| | `docs/25-r2z-oracle-and-promotion.md` | Where an oracle may and may not come from, and which mechanisms are worth copying. | Written |
| Feasibility, testing and experiments | `docs/17-rust-dependency-surface.md` | Every Rust crate AccessKit depends on, at the version `Cargo.lock` gives, and what replaces each one. | Written |
| | `docs/18-testing-strategy.md` | What each gate stage really checks, what a green gate does not prove, and the item list a milestone must satisfy. | Written |
| | `docs/26-goose-live-bus-probe.md` | Whether goose v3.3.0 can carry the AT-SPI adapter against the live bus on this host. | Written |
| | `docs/27-x11-headers-resolution.md` | Whether the four missing X11 headers can be obtained on this host, and what each attempt cost. | Written |
| The design set | `docs/30-port-design.md` | The module layout, where the runtime is allowed, and every design decision the research forces. | Written |
| | `docs/31-c-abi-design.md` | The C declarations the port reproduces, the checked-in header, and the rule that keeps header and Zig types in step. | Written |
| | `docs/40-plan.md` | The milestone order, the gate each milestone must pass, and the open risks beside it. | Written |
| | `docs/50-verification.md` | The evidence each milestone records, and the claims this project refuses to make. | Written |

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
`docs/30-port-design.md:134` record it.

## Layout

What exists today:

```text
zaccesskit/
├── .envrc                  direnv hook, loads the host scratch policy first
├── .gitignore              the caches, `.jj/` and the generated directories
├── AGENTS.md               the house rules this repository is written under
├── README.md               this file
├── build.zig               one module and two named build steps
├── build.zig.zon           package manifest, one dependency
├── cross-test.profile.sh   the target matrix gate stage 9 runs
├── devenv.lock
├── devenv.nix              the development environment and the gate task
├── devenv.yaml
├── docs/                   the research and design record
└── src/
    └── root.zig            the module root, documentation only
```

Two symlinks sit beside that tree and point at local disk, because Zig 0.16.0
cannot keep a cache on this network filesystem:

```text
.zig-cache -> /tmp/cache/zaccesskit/build
zig-pkg -> /tmp/cache/zaccesskit/pkg
```

`.jj/` and `.git/` hold the colocated version control. `.devenv/` and `.direnv/`
are generated. `src/root.zig` is the only source file and it declares nothing.
`docs/30-port-design.md` fixes the module layout the port will use.

The adapter order is fixed too: `atspi`, `windows`, `macos`, `ios`, `android`.
AT-SPI comes first because it is the only adapter whose protocol runs on this
host, against the live accessibility bus at
`unix:path=/run/user/33156/at-spi/bus`. There is no X11 adapter to port, because
upstream ships none. `adapters/unix/src/` holds no X11, XCB or Wayland code, and
the only match for those names is a doc comment at
`adapters/unix/src/adapter.rs:172` (`docs/12-accesskit-adapters.md:68-80`).

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
