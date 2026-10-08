# zaccesskit

## What this is

`zaccesskit` is a pure Zig 0.16 port of the AccessKit accessibility toolkit. It
translates each upstream Rust module and each public function into Zig, module
by module and function by function. It does not wrap, link or call the Rust
implementation, and it needs no Rust toolchain at any point.

**PowerPC64 C ABI:** At tested source snapshot `d854c8b0d77385cf8c0c5983832369923fdef2d5`, the private repair passed the Debug C consumer on native x86_64, PPC64 Linux MUSL through QEMU, and AArch64 Linux MUSL through QEMU.
Each target reported 37,240 checks, 0 failures, and 7/7 steps. The native run is in `artifact://2946`; Main also reported the paired QEMU `test-c` results for PPC64 Linux MUSL and AArch64 Linux MUSL.
The repair is limited to the known broken PPC64 Linux MUSL families. It is not a general ABI or platform-SDK claim. The canonical Zig 0.16 compiler-control case still fails.
At earlier source `c45632aa2fe6bcdf344ac7745b9a4350080309ee`, the full C consumer failed the `f32` font and color cases.
It also failed the Boolean case and twelve real enum controls with two-byte values. That earlier failure set was not limited to 16-byte returns.
Independent compiler-only reproductions fail without zaccesskit and still demonstrate the canonical compiler-control failure.
Earlier pure Zig PowerPC64 tests, twelve recorded reference cases, and the offline integration scenario passed through QEMU.
The earlier accepted publication retained the unsupported boundary. It included no compiler change or speculative wrapper.
Tested source snapshot `d854c8b0d77385cf8c0c5983832369923fdef2d5` carries 49 private return cases, eight input exports, and the bare TreeId getter return-lowering helper. These private ABI paths are gated to PPC64 Linux MUSL.
That source also retains 17 WHY comments across nine paths and bounded Mac-provider typed-notification error/no-close changes. The root namespace, seven root declarations, public API, header, and marshalling records remain unchanged.
The d854 root result is not a full project gate. Main's later pre-guard gate run failed; its stage results are below. Both foreign Debug C-consumer rows passed.
The required `refAllDecls` guards in `src/root.zig` and `src/adapters/root.zig` prove declaration reachability, not behavior. On foreign targets they do not typecheck or analyze the Windows COM graph. Main narrowed COM-graph analysis to `cpu.arch == .x86_64`; the supported x86_64 analyzer remains required. No post-fix source pin or gate result is available; lint cleanup and a full-gate rerun are pending.
[Issue #5](https://github.com/CoffeeImpliesCode/zaccesskit/issues/5) is OPEN and tracks the future Zig 0.17 ABI check.
It does not establish that Zig 0.17 fixes the defect.
The C artifact requires the LLVM backend on Zig 0.16.0.
`build.zig` selects it explicitly. Native Zig consumers retain their existing backend selection.
The self-hosted x86 Debug backend failed five linked-C geometry result checks. The LLVM Debug C artifact passed all 1676.

The async design runs the other way round from what the name suggests.
`std.Io` is the interface. `zio` is one implementation behind it, in the place
`std.Io.Threaded` and `std.Io.Uring` sit.
Blocking entry points take explicit I/O capabilities.
Native transport owners also receive the runtime needed for owned tasks.
The pure schema and consumer layers need neither capability.
`docs/30-port-design.md` sections 2.1 and 12.2 record the boundary.

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

The library exists. The table below preserves a historical source census.
It does not describe the current source or import graph.
`docs/30-port-design.md` sections 1.3 and 12 describe the current public contracts.
`docs/52-translation-ledger.md` records current item dispositions.
`docs/50-verification.md` records actual test and platform receipts.

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

The earlier header census counted 6596 lines and 498 functions, with 446 Linux exports.
Those figures are historical, not the current exact-error API inventory.
`docs/52-translation-ledger.md` maps the added C diagnostics.
`tools/capi_parity/main.zig` measures header/export parity per target.

### Historical analysis graph: four files were unreachable

The earlier `src/root.zig` import walk reached 110 of 114 modules.
At that measurement, four Windows files were unreachable.
Those findings below are historical, not current missing-provider claims.
The current source publishes real Windows provider namespaces.

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

The earlier corrected-source gate passed its native test stage.
Its strict x86_64 cross row passed all 1653 library tests and all 1676 linked-C checks.
That earlier full gate exited 1 because external checker failures and the PowerPC64 C boundary remained.
`docs/50-verification.md` section 10.7 records that historical gate result and cross counts.

The census above is historical. Declaration counts and executed pass counts are different measurements.
Neither certifies behavior on a real platform accessibility object.
The current fixture inventory contains fifteen finite, hand-recorded, source-derived cases.
Earlier twelve-case receipts remain twelve-case evidence.
No fixture check executes a Rust oracle or establishes wire parity.
Use `docs/52-translation-ledger.md` for reconciled source counts, not the earlier 57-open-row summary.

The root publishes seven names: `schema`, `consumer`, `capi`, `adapters`, `Runtime`,
`version`, and `minimum_zig_version` (`src/root.zig:36-81`).
`adapters` publishes AT-SPI, Windows, Mac, iOS, and Android namespaces.
`Runtime` is the same pinned zio runtime type used by native adapters.
Mandatory declaration-reachability guards remain in the test graph.
They do not replace observable behavior and ownership tests.

Current portable native-contract tests passed 18 cases and skipped one case in each safety mode.
The Windows native client cross-build exited 0. No Windows client executed.
Mac context tests passed ten cases and skipped two native Objective-C cases.
Saved native-peer receipts match 216 independent read-only GDBus/busctl calls and 54 action/error-reply commands.
Other bounded receipts match 32 full ACTION JSON callback cases, 101 lifecycle checks, 106 status-epoch checks, and eight positioned FIFO RPCs with observed signals.
The positioned-boundary receipt matched 114/114 cases and three fresh-provider closes.
Main-provider close exited 0 with zero late callbacks and an empty registry.
Native OOM baseline/retry, geometry-boundary, reorder-repair, callback, event, and close cases were observed. The edit-head OOM path was not exercised through the CLI.
The pinned source oracle confirms that removal after unregister returns UnknownObject.
Android's complete namespace filter passed 209/209 tests in Debug and 209/209 in ReleaseSafe.
The receipts are `execute-1-4-green/android-complete-namespace-debug.json` and `execute-1-4-green/android-complete-namespace-releasesafe.json`.
The `src.adapters.android` filter covers all 13 modules, including scroll, tagged scalar cases, JNI gates and errors, allocation, public C queues, and producer ownership.
These tests cover the portable JNI seam, not an Android VM, SDK client, device, or emulator.
The controlled Linux provider matrix is complete through the CLI. It does not prove GUI or screen-reader behavior, Windows or macOS SDK behavior, or iOS or Android device execution.
An earlier Debug run of the canonical 2051-test graph reported 1996 passes, 43 skips, and 12 failures.
The ReleaseSafe run reported 1994 passes, 43 skips, and 14 failures.
`execute-1-4-green/canonical-full-graph-failure-inventory.json` lists those 26 failure contexts.
The source-corrected 2051-test graph at `3b4e07e5d05a960d57095405c339e7787436014a` exited 0 in both modes.
Each corrected-source receipt reports 2,008 passed, 43 skipped, and 0 failed.
The receipts are `execute-1-4-green/canonical-graph-source-corrected-debug.json` and `execute-1-4-green/canonical-graph-source-corrected-releasesafe.json`.

At prior source snapshot `9741daec59b72c4c0d25843bb3e5c9af2d3abd4a`, the test run exited 0 with 31/31 build steps.
Each root mode reported 2,021 passes, 43 skips, and 0 failures out of 2,064 tests. These are historical results, not results for the later guard-patch source.

Historical BG250 output (`artifact://2827`) for tested source snapshot `320cb011918e099317136c226d43a2abf3d665d0` reported 31/31 build steps.
Each Debug and ReleaseSafe root run reported 2,028 passes, 43 SDK skips, and 0 failures out of 2,071 tests. Each root run found two fuzz tests.
Dedicated fuzz shards passed 440/440 in both modes and found three fuzz tests.
Benchmarks passed 9/9 in both modes. Native-contract tests passed 18 and skipped one in each mode.
Integration passed 918/918 in both modes and found one fuzz test per mode. Reference tests passed 785/785 in both modes.
The native Debug C-consumer run at that snapshot passed 34,594 checks with no failures and recorded 2,093 allocations, 2,093 frees, and zero active allocations.
These historical test shards overlap. Do not sum them.

Main's completed `zig build test --summary all` output at tested source snapshot `d854c8b0d77385cf8c0c5983832369923fdef2d5` exited 0 with 31/31 steps (`artifact://2946`).
Each Debug and ReleaseSafe root run had 2,070 tests: 2,027 passed, 43 SDK skips, and 0 failures. Each root run found two fuzz tests.
Integration passed 918/918 in both modes and found one fuzz test per mode. Reference passed 785/785 in both modes.
Dedicated fuzz shards passed 440/440 in both modes and found three fuzz tests. Benchmarks passed 9/9 in both modes.
Native-contract tests passed 18 and skipped one in each mode. These snapshot shards overlap and must not be summed.
The native Debug C consumer passed 37,240 checks with no failures and 7/7 steps. It recorded 2,095 allocations, 2,095 frees, and zero active allocations.
Its output also records 1,669 strings, four custom actions, seven action lists, 55 nodes, two tree infos, and three tree updates (`artifact://2946`).
Main's Debug QEMU `test-c` runs for PPC64 Linux MUSL and AArch64 Linux MUSL each passed 37,240 checks with no failures and 7/7 steps.
These C-consumer results are Debug-only. No ReleaseSafe C-consumer result is recorded. The d854 test-stage result is not a full project gate.

The approved bounded Linux AT-SPI smoke passed at source `c45632aa2fe6bcdf344ac7745b9a4350080309ee`.
Its receipt is `execute-1-4-green/approved-bounded-native-bus-smoke.json`.
It used approved private storage and an explicit approved daemon address.
It queued and applied 11 edits, made 14 commits, and sent two click callbacks.
Both stock clients observed 14 cache entries before removal and 13 after.
They returned `UnknownObject` for the removed object and saw empty registries after close.
The smoke matched `AéΩ😀😀`, four 256-byte replacements, a 1,024-byte value, and an empty end cursor.
Both provider tasks joined, all five owned processes stopped with pidfds and exited 0, and no unrelated process was killed.
It restored `IsEnabled` and `ScreenReaderEnabled` to false and recorded zero late callbacks.
It exposed the native `click` action only. It makes no `custom42`, native OOM, desktop UI, or `nogui` claim.
Its transport binary matched tested source snapshot `320cb011918e099317136c226d43a2abf3d665d0`; no binary identity with the d854 or later guard-patch source is established.

BG249 remains red for the private 49-return candidate at tested source snapshot `320cb011918e099317136c226d43a2abf3d665d0`. No full C49 pass is recorded for that snapshot.
Main's latest reported pre-guard full-gate run passed `fmt`, `build`, `test`, and `ast-check`, then reported 877 `ziglint` findings; `zbc` and `zwanzig` each terminated with exit status 134 (tool failures, not finding counts). A foreign COM cross-compilation failure occurred at `src/adapters/root.zig` (`refAllDecls(windows)` reached `unsupported.winapi`). The foreign Debug C-consumer rows passed.
Main narrowed COM analysis to `cpu.arch == .x86_64` while preserving required root reachability guards. The x86_64 analyzer remains required. No post-fix source pin or gate result is available; lint cleanup continues and the gate rerun is pending. `docs/50-verification.md` section 11 records the exact receipts and limits.
Nogui remains source-only and was not executed.

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
| `devenv shell` | Loads `devenv.nix`. It sets `ZIG_GLOBAL_CACHE_DIR`, `GATE_CACHE_DIR` and `GATE_CROSS_OUTPUT` to local disk. It links the two cache paths and `zig-out` to the selected `cacheRoot`. `direnv allow` loads the same configuration. |
| `zig build -Doptimize=ReleaseSafe` | Install the static C library and `zig-out/include/zaccesskit.h`. Use `-Dlinkage=dynamic` for the dynamic library. |
| `zig build test` | Run native Debug and ReleaseSafe library, integration, and reference shards. Run the linked offline C consumer on native targets. |
| `zig build cross-test -Dtarget=aarch64-linux -fqemu` | Run the Debug library shard and linked Linux C consumer through QEMU. `cross-test.profile.sh` supplies the full matrix. |
| `zig build capi-parity` | Runs the parity tool's own tests, then the sweep that compares `include/zaccesskit.h` against what `src/capi/` exports, per target, with both the header guards and the Zig `comptime` guards evaluated. Exit 0 is parity, 1 a mismatch, 2 something unreadable, 3 a bad command line. |
| `zig build test-c -Doptimize=ReleaseSafe` | Link and run the offline C11 consumer against the real library. |
| `zig-gate` | The house gate, and the authority on whether a change is acceptable. `devenv shell -- gate` runs the same script. |

`docs/40-plan.md` section 1.2 lists the integration, reference, and benchmark steps.
They do not require a live accessibility bus.

For a native Zig consumer, add the published module to the consumer module:

```zig
const accesskit = b.dependency("zaccesskit", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zaccesskit", accesskit.module("zaccesskit"));
```

Import it in Zig with `@import("zaccesskit")`.
For a C consumer, select linkage and link the published artifact:

```zig
const accesskit = b.dependency("zaccesskit", .{
    .target = target,
    .optimize = optimize,
    .linkage = .static,
});
exe.root_module.linkLibrary(accesskit.artifact("zaccesskit"));
```

Use `#include <zaccesskit.h>` in C.
The library carries the installed header.
The module and library honor the selected target and optimization mode.

A separate external package exercised both routes in Debug and ReleaseSafe.
Static and dynamic linkage each passed all nine build steps in both modes.
All four configurations executed the Zig and C consumers.
Its Unix callback probe used actual owning C payloads without a native bus.
`docs/50-verification.md` section 10.5 records the outputs and limits.
Nogui remains source-only and was not executed.

`zig-gate` is `~/.local/bin/zig-gate`, 823 lines. It
runs ten stages in order: `fmt`, `build`, `test`, `ast-check`, `ziglint`,
`zlint`, `zbc`, `zwanzig`, `cross-test` and `zig-cov`. The last stage runs only
with `--cov`. The script exits 0 when every stage passes, 1 when a stage finds
an issue, and 2 on a usage or environment error. Stage list at `zig-gate:23-33`,
exit policy at `zig-gate:1-5`.

`build.zig` wires the committed decoder corpus through `fuzz_root.zig`.
The native tests replay that corpus in Debug and ReleaseSafe.
The linked C consumer also runs in the native test route.
Corpus replay is not mutation fuzzing or native platform execution.

The `powerpc64-linux` row provides big-endian execution evidence for the pure Zig tests.
It does not prove the linked C boundary, which crashes with the known compiler ABI defect.
The corrected-source strict cross run passed x86_64 and AArch64, but failed PowerPC64.
No row proves communication with a real platform accessibility object.

### `zig ast-check` reaches further than `zig build test`

`zig ast-check` scans every file under `src/`, so it checks the four modules
the test root cannot reach. A green `zig build test` therefore says nothing
about them. A parse error or a half-finished rename in one of those four files
surfaces at the `ast-check` stage and nowhere else, and no build step will have
warned you first.

`src/adapters/windows/com.zig` is the file to watch. It is the COM node layer,
it is the largest of the four at 532 lines, and no stage above `ast-check`
looks at it.

### Cache and install paths must stay symlinks

This checkout is on a network filesystem.
Keep the two cache paths, `.zig-cache` and `zig-pkg`, as symlinks to local disk.
Keep the install-output path, `zig-out`, as a symlink to local disk too.
`devenv shell` links them to `${cacheRoot}/build`, `${cacheRoot}/pkg`, and `${cacheRoot}/install`.
`ZACCESKIT_CACHE_ROOT` selects `cacheRoot` when set.
Otherwise, the configuration uses `${XDG_CACHE_HOME}/zaccesskit`, then `${HOME}/.cache/zaccesskit-zig`.
Select a local-disk root. The root is not fixed to `/home/tmp2`.
If a link is absent, run `devenv shell`, not `mkdir`.
The shell reports real directories and leaves them unchanged. It does not automatically delete or move their contents.

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

Check all three paths:

```sh
ls -ld .zig-cache zig-pkg zig-out
stat -f -c '%T' .
```

The first line must show three symlinks. The second reports the checkout filesystem, not the link targets.
Check the selected root separately. It must use local disk.
An actual local-scratch shell smoke test confirmed all three links under UID 33156.
A populated-directory refusal test preserved its sentinel text. Neither test moved or deleted user files.

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

### Packaged build inputs

`build.zig.zon:67-81` includes `src`, `include`, `test`, and `tools`.
It also includes the library and harness roots.
A packaged consumer can reach the module, C library, installed header, and declared test steps.

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

This listing preserves the earlier directory census.
Module, dependency, build-step, and document counts below are historical.
The current root publishes seven names, including `adapters` and the shared `Runtime` type.

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
│   ├── root.zig            the module root; current public names are listed above
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

The earlier geometry research left five probe object files, as recorded in `docs/19`.
That historical inventory is not a current filesystem observation.
The standing scratch-cleanup requirements in `AGENTS.md` remain unchanged.

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