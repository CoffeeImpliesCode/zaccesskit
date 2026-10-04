# 45 — Milestone status against `docs/40-plan.md`

**What this document is.** A status record for milestones M0 to M11 as the
working copy stands on 2026-10-05. For each milestone it gives the plan's claim,
the measured state, one status word, and the claims this document cannot
verify.

**What this document is not.** It does not correct `docs/40-plan.md`. That file
is not edited here. Section 4 lists the corrections an owner should apply.

**When the counts were taken.** Every number below came from reading the
working copy on this node. Other work was landing while this document was
written, so `src/capi/` and `src/adapters/` grow under it. Each count carries
the time it was read.

## 0. The claims a status word must keep apart

A file that exists is not a file that compiles. A build that passes is not a
build that ran against a platform. This document uses four words and never lets
one stand in for another.

| Word | What it means | What established it here |
|---|---|---|
| **on disk** | the file exists and the count was read from it | a count over the working copy |
| **compiles** | a compiler accepted the file | nothing here. This slice ran no compiler |
| **tests pass** | a runner ran the code and reported a pass | the owner's run, reconciled below |
| **ran on a platform** | a message crossed a bus, or a client read a tree | nothing |

### 0.1 The 706, reconciled

The integration owner reports 706 tests passing. This slice did not run the
runner, because the boundary for this slice forbids it. The count reconciles
exactly against the tree. `src/schema` declares 317, `src/consumer` declares
385, and `src/root.zig` declares 4. 317 + 385 + 4 is 706.

So the 706 is a measured decomposition of a reported result. It is not a second
observation of the result. A reader must not cite this document as proof that
the run is green.

### 0.2 What the 706 does not cover

`src/root.zig` imports two namespaces, `schema/root.zig` at line 33 and
`consumer/root.zig` at line 46. Nothing else is reachable from the test root,
and `build.zig` declares exactly two steps, `test` at line 73 and `cross-test`
at line 106.

At 06:50:25Z the tree held 924 `test "` declarations under `src/`. Of those, 140
sit in `src/capi/` and 78 in `src/adapters/`. Those 218 declarations are not in
the 706 and no build step runs them. This is measured, not inferred, and it is
the single most useful fact in this document for whoever reads the next gate
report.

### 0.3 The layers, measured at 2026-10-05T06:50:25Z

| Layer | Modules | Lines | `test "` | In the 706 |
|---|---:|---:|---:|---|
| `src/schema/` | 23 | 13182 | 317 | yes |
| `src/consumer/` | 27 | 20959 | 385 | yes |
| `src/root.zig` | 1 | 109 | 4 | yes |
| `src/capi/` | 6 | 7318 | 140 | no |
| `src/adapters/` | 13 | 4134 | 78 | no |
| **All of `src/`** | **70** | **46096** | **924** | **706** |

Module counts exclude each layer's `root.zig`. Line counts come from `wc -l`.

### 0.4 The gate steps the plan names

`docs/40-plan.md` section 3.2 gives each milestone a build step the house gate
does not run. Nine of the ten do not exist.

| Step the plan names | Milestone | Present in `build.zig` |
|---|---|---|
| `zig build layout-test` | M1 | no |
| `zig build conformance-test` | M2 | no |
| `zig build action-test` | M3 | no |
| `zig build binding-check` | M4 | no |
| `zig build atspi-bus-test` | M5 | no |
| `zig build atspi-live-test` | M6 | no |

`zig build` on an unknown step exits with an error, so a reviewer who follows
the plan and types these names gets a failure that says nothing about the port.

## 1. The milestones

### M0. The base — not started

**Plan said.** Add the `goose` pin, one probe module under `tools/` that
imports it, three more matrix rows (`riscv64-linux`, `loongarch64-linux`,
`x86-linux`), a self-test that counts its own discovery, and `test`, `include`
and `third_party` in `.paths`. The entry gate is `zig-gate`.

**Measured.** Every addition is absent.

| Addition | Measured state | Evidence |
|---|---|---|
| `goose` pin | one dependency only, `zio` | `build.zig.zon:29` |
| probe module under `tools/` | one file, `tools/capi_parity/header.zig` | `find tools`, 06:51:21Z |
| three more matrix rows | three rows, unchanged | `cross-test.profile.sh:38-42` |
| counting self-test | four tests in `src/root.zig`, none counts discovery | `src/root.zig:66-104` |
| `.paths` widened | six entries, `include` and `test` absent | `build.zig.zon:36-43` |

**Status.** Not started.

**One consequence is already live.** `include/zaccesskit.h` exists and holds
6581 lines, and `.paths` does not list `include`. A packaged build of this
project drops the only C header the project has. `docs/40-plan.md` hazard H8
predicted this and named the fix. The fix has not landed.

### M1. Geometry and schema types — on disk, gate absent, one count in the plan is wrong

**Plan said.** 21 schema modules, about 3700 lines of Zig, from 4051 upstream
non-test lines. The gate must prove the five `extern struct` layouts, the 182
role discriminants against `ACCESSKIT_ROLE_`, and 105 properties in eight
families.

**Measured.** All 21 modules exist. 11793 lines across 21 modules, which is the
`src/schema` figure of 13182 less `update.zig` at 1022 and `handlers.zig` at
367.

| Gate condition | Measured | Evidence |
|---|---|---|
| five layouts | `Point` 16/8, `Size` 16/8, `Vec2` 16/8 | `point.zig:132`, `size.zig:119`, `vec2.zig:107` |
| five layouts | `Rect` 32/8, `Affine` 48/8, every offset asserted | `rect.zig:61-64`, `affine.zig:88-92` |
| 182 roles | 182 in Zig, 182 in the header, 182 upstream | `role.zig`, `lib.rs:63-270` |
| 105 properties | **87** in Zig and **87** upstream | `table.zig:202-315`, `lib.rs:894-1008` |

The five layouts carry both a `std.debug.assert` and a `std.testing.expectEqual`
for size, alignment and every offset. That is what the plan asked for.

**Status.** Done on disk. The gate step `zig build layout-test` does not exist,
so the layouts are proven by `zig build test` rather than by the step the plan
named.

**Not verified.** No compiler was run by this slice. The 182 and 87 counts are
lexical and were compared against the pinned upstream at commit
`466e24e252103f4d82bd6fbab98141b551e46e0c`, so the comparison is against the
authority. What is unverified is that a C caller sees the same numbers.

### M2. The tree store and the update protocol — on disk, the fixture set is absent

**Plan said.** 27 consumer modules, about 4400 lines of Zig, from 9871 upstream
lines. The gate must prove each of the 12 invariants in
`docs/15-tree-semantics.md:1451-1464`, over a fixture set of 10 files, through
a step the gate does not run.

**Measured.** All 27 modules exist. 20959 lines across 27 modules.

| Gate condition | Measured | Evidence |
|---|---|---|
| upstream size | 9871 lines, exact | `accesskit_consumer/src/*.rs` |
| 27 modules | 27 | `find src/consumer -name '*.zig' ! -name root.zig` |
| invariants as assertions | run-time errors and `comptime` checks, not comments | `tree_validate.zig:1-40` |
| fixture set of 10 files | **absent**. `test/` holds 4 files, none a fixture | `find test`, 06:51:21Z |

**Status.** Done on disk. Hazard H3 has not been answered. The fixtures do not
exist, so a tree that is self-consistent and wrong would still pass here.

**Not verified.** The 706 tests are in-process tests over fixtures the test
code builds in memory. No byte a real implementation produced has entered this
repository. The recorded-fixture route in `docs/40-plan.md` section 4 is unused.

### M3. The action channel and the platform interface — partly done

**Plan said.** Three modules, about 280 lines of Zig: `schema/update.zig`,
`schema/handlers.zig`, and a platform interface module the plan names
`src/consumer/adapter.zig` and marks a proposal.

**Measured.** Two of the three exist and total 1389 lines. The third does not
exist. The consumer layer holds 27 modules and none of them is an adapter.

| Module | Lines | Evidence |
|---|---:|---|
| `src/schema/update.zig` | 1022 | `wc -l` |
| `src/schema/handlers.zig` | 367 | `wc -l` |
| `src/consumer/adapter.zig` | absent | `find src/consumer` |

**Status.** Partly done. Two modules at 5.0 times the planned total, and the
module whose name the plan could not fix is the one still missing.

**Every upstream anchor in this milestone row is exact.** `TreeInfo` at
`accesskit/src/lib.rs:3169`, the deprecated alias at `:3178-3179`, `TreeUpdate`
at `:3208`, `ScrollUnit` at `:3271`, `ScrollHint` at `:3291`, `ActionData` at
`:3305`, `ActionRequest` at `:3328`, and the three handler traits at `:3336`,
`:3362` and `:3376` all name what the plan says they name.

**Not verified.** `zig build action-test` does not exist. The plan's requirement
that `ActionData` match its `#[repr(C)]` layout byte for byte has no test that a
big-endian target has run.

### M4. The C ABI — partly done, and the header is twice the planned size

**Plan said.** `src/capi/`, one module per header region, about 5500 lines of
Zig plus about 3200 lines of header. The gate is `zig build binding-check`,
`zig-gate`, and one C conformance program.

**Measured.** The header exists and is more than twice the planned size. The Zig
layer exists and is 6 modules, not one per header region. No library is built.

| Item | Planned | Measured | Evidence |
|---|---:|---:|---|
| header lines | about 3200 | **6581** | `wc -l include/zaccesskit.h` |
| function declarations | 496 upstream | **498**, zero duplicates | lexical scan, 06:44Z |
| role constants | 182 | 182 | a count over `ACCESSKIT_ROLE_` |
| exports on `x86_64-linux` | not stated | **446** | `docs/40-capi-build-map.md:79-82`, `:1179` |
| Zig modules | one per header region | 6 named files | `find src/capi` |
| Zig lines | about 5500 | 7318 | `find src/capi \| xargs wc -l` |
| `addLibrary`, `installHeader`, `installArtifact` | required | absent | `grep` over `build.zig` |

The header states its own count at line 1766: 496 functions plus two this port
adds. This slice confirmed the arithmetic independently by stripping comments
and counting unique `accesskit_*(` occurrences, which returned 498.

**Status.** Partly done. The header and the conversion layer are on disk. The
shared library, the install steps and every gate step are absent.

**The module split in the plan is wrong.** `docs/30-port-design.md:218-219`
fixes `src/capi/` at three modules: `capi/root.zig`, `capi/header_check.zig`
and `capi/marshal.zig`. The work on disk uses a different split of six. Two
documents now name two different layouts for the same directory.

**The upstream anchor in this row cannot be checked.** The plan cites
`accesskit-c/include/accesskit.h` at commit `8b6ed37c20ed4c59390e253407983333053662ba`.
That directory does not exist at the pinned commit, and that commit is not in
this checkout. `git cat-file` answers `not our ref`. The plan's figures of 3154
lines, 496 symbols, 18 enums, 18 opaque handles and 4 function-pointer
typedefs are therefore **unverified**. Missing: the `accesskit-c` tree at that
commit.

**Not verified.** `zig translate-c` produced 3408 lines and 446 declarations per
`docs/40-capi-build-map.md:1173-1189`. This slice did not re-run it. The
aggregate-passing convention is recorded as undecided at
`docs/40-capi-build-map.md:1260`, and 105 declarations return an aggregate by
value while 77 parameters across 57 declarations pass one. Until that decision
lands, no line count for `marshal.zig` has a floor.

### M5. The D-Bus layer on goose — the milestone has not opened, and its plan is superseded

**Plan said.** `src/adapters/atspi/dbus/`, about 630 lines of Zig, of which
about 250 are the object register and remove path. Entry gate
`zig build atspi-bus-test`.

**Measured.** There is no `dbus/` directory. The AT-SPI tree exists and is 6
files and 1920 lines, and `goose` is not a dependency.

| Item | Measured | Evidence |
|---|---|---|
| `src/adapters/atspi/dbus/` | absent | `find src/adapters` |
| `src/adapters/atspi/` | 6 files, 1920 lines | `find` and `wc -l`, 06:50:33Z |
| `goose` dependency | absent | `build.zig.zon:12-33` |
| `third_party/` | absent | 06:51:18Z |
| `zig build atspi-bus-test` | absent | `build.zig` has two steps |

**Status.** Not started as a milestone. Six of the modules this milestone owns
are on disk and already exceed the planned line count by 3.0 times.

**The module layout in the plan is superseded.** `docs/41-atspi-build-map.md`
section 2.2 names 35 modules for the whole AT-SPI adapter and has no `dbus/`
subtree. The port-only modules that replace the goose gaps are `wire.zig`,
`objects.zig`, `dispatch.zig`, `pump.zig` and `runtime.zig`, all under
`src/adapters/atspi/`.

**Two upstream blockers are untouched.** The `O_NONBLOCK` defect and the missing
`fromRuntime` re-export both sit in libraries this project has not pinned.
Blocker 2 of the plan's table is therefore not merely unfixed, it is
unreachable.

**Not verified.** Nothing in this tree has opened a socket. The five-step
discovery, the object register and the signal emit have no code.

### M6. The AT-SPI adapter — not started

**Plan said.** `src/adapters/atspi/`, about 29 modules, about 7500 lines of
Zig, from 5226 upstream lines.

**Measured.** The 5226 upstream lines are exact. 4417 lines in
`adapters/atspi-common/src/`, and 809 in `adapters/unix/src/` outside `atspi/`.

| Item | Planned | Measured |
|---|---:|---:|
| upstream lines | 5226 | 5226, exact |
| Zig modules | about 29 | 35 named by `docs/41` section 2.2, 6 on disk |
| Zig lines | about 7500 | 1920, shared with M5 |

**Status.** Not started. The 6 files on disk are M5 modules by the naming in
`docs/41`.

**The module budget is wrong.** `docs/41` section 2.2 names 35 modules for M5
and M6 together, not 29 for M6 alone. `node.zig` at 2065 upstream lines is
named there as a split into five modules, and no split has been written.

**Not verified.** No screen reader is installed on this node, and
`local://zaccesskit-verified.md` records that `at-spi2-registryd` was running
when it was written. The plan's own blocker 8 says the bus is live and the
reader is not. Nothing here has run against either.

### M7. The Windows adapter — one file on disk, the dependency is not pinned

**Plan said.** `src/adapters/windows/`, about 16 modules, about 4000 lines of
Zig, against `marlersoft/zigwin32` at
`9f15c276b4e9d05afd34a10d8662a7dfc34647ea`.

**Measured.** One file, 774 lines. The dependency is not in `build.zig.zon`.

| Item | Measured | Evidence |
|---|---|---|
| upstream library lines | 3764, exact | `adapters/windows/src/*.rs` |
| upstream test lines | 712, exact | `adapters/windows/src/tests/*.rs` |
| upstream example lines | 317, not in the plan | `adapters/windows/examples/hello_world.rs` |
| `zigwin32` dependency | absent | `build.zig.zon:12-33` |
| Zig on disk | 1 file, 774 lines | 06:50:33Z |

**Status.** Not started as a milestone. One binding file is on disk.

**The dependency is not pinned, so the compile route does not exist yet.** The
plan's gate is `zig build-obj -target x86_64-windows` against zigwin32. Without
the pin that command cannot resolve the import.

**Not verified.** `bindings.zig` names symbols. Nothing was compiled here, and
the 712 upstream test lines have no route on this host. The plan already says
this, and it is still true.

### M8. The macOS adapter — not started

**Plan said.** `src/adapters/macos/`, about 11 modules, about 2800 lines of
Zig, from 2605 upstream lines. 58 selectors are typed by hand.

**Measured.** Nothing on disk. The upstream figure is exact. The selector count
is not reproduced by any measurement in this repository.

| Item | Planned | Measured | Source of the measurement |
|---|---:|---:|---|
| upstream lines | 2605 | 2605, exact | `adapters/macos/src/*.rs` |
| Zig modules | about 11 | 0 | `find src/adapters/macos` |
| selectors typed by hand | 58 | **43** selector literals | `docs/42` section 1.2.5 |
| node selectors | not stated | 54, plus 4 on the host view | `docs/42` section 1.2.2 |

**Status.** Not started.

**The selector figure is wrong and the plan repeats a wrong figure.** `docs/16`
counts 6. `docs/42` section 1.5 row C2 measures 43. The plan's 58 is a third
number, and neither measurement produces it.

**Not verified.** A selector is an interned string, so a wrong one type-checks.
Nothing here has been compiled for `aarch64-macos` by this slice.

### M9. The iOS adapter — not started, and the work on disk outruns the plan

**Plan said.** `src/adapters/ios/`, about 11 modules, about 2700 lines of Zig,
from 2560 upstream lines. 26 UIKit symbols are typed by hand, 4 through
`dlsym`.

**Measured.** 5 files and 1256 lines are on disk. The upstream figure is exact.
The UIKit figure is contradicted.

| Item | Planned | Measured | Source of the measurement |
|---|---:|---:|---|
| upstream lines | 2560 | 2560, exact | `adapters/ios/src/*.rs` |
| Zig modules | about 11 | 5 on disk | 06:50:33Z |
| Zig lines | about 2700 | 1256 | 06:50:33Z |
| UIKit symbols by hand | 26 plus 4 | **39 named plus 4 literals** | `docs/42` section 1.3.1 |

**Status.** Not started as a milestone. Five modules are on disk.

**Where the plan is right and where it is wrong.** The 2560 figure in the plan
is correct. `docs/16` says 2603 and `docs/42` section 1.5 row C4 corrects that
to 2560, so the plan already carries the corrected number. The UIKit count of 26
is the uncorrected one, and `docs/42` row C5 measures 43 distinct identifiers.

**Not verified.** `zig build-exe -target aarch64-ios` fails on this host, so
nothing here links. The four `dlsym` strings are unchecked by the compiler.

### M10. The Android adapter — not started

**Plan said.** `src/adapters/android/`, about 11 modules, about 2800 lines of
Zig, plus about 70 lines of Java. No JNI surface figure.

**Measured.** One file and 184 lines on disk. The Java figure is exact. The JNI
surface is twice what the research recorded.

| Item | Planned | Measured | Source of the measurement |
|---|---:|---:|---|
| upstream library lines | 2604 | 2604, exact | `adapters/android/src/*.rs` |
| Java lines | about 70 | 70, exact | `adapters/android/java/.../Delegate.java` |
| Zig modules | about 11 | 1 on disk | 06:50:33Z |
| JNI call sites | not stated | **78**, naming 68 Java methods | `docs/42` section 1.5 row C6 |

This slice counted the call sites itself. A scan for `call_method` and
`call_static_method` over `adapters/android/src/*.rs` returned 78, which
reproduces the recorded figure.

**Status.** Not started as a milestone. One module is on disk.

**Where the plan is silent and the research was wrong.** `docs/16` records about
40 JNI call sites. 78 is 1.95 times that. The plan does not carry the figure, so
the plan is not wrong here. It is incomplete, and the research document it
relies on is wrong.

**Not verified.** No NDK, no `adb`, no device, and no separate build
configuration for an Android `.so` exists in `build.zig`.

### M11. The application side — not started, and it has no owner document

**Plan said.** One application-facing module per platform under `src/app/`,
and one facade, about 600 lines of Zig.

**Measured.** `src/app/` does not exist.

| Item | Measured | Evidence |
|---|---|---|
| `src/app/` | absent | 06:51:18Z |
| an owner for the module layout | none found | `grep -r 'src/app' docs/` returns nothing |
| `set_root_window_bounds` | at `adapter.rs:173`, not `:172` | `adapters/unix/src/adapter.rs:173` |
| `AdapterState` variants | `Inactive` `:81`, `Pending` `:86`, `Active` `:91` | exact |
| `update_if_active` | `:196` | exact |

**Status.** Not started.

**Two problems the plan does not name.** First, `src/app/` has no owner.
`docs/30-port-design.md` section 3.3 names `src/capi/` and `src/adapters/` and
says nothing about an application layer. Second, the plan cites line 172 for
`set_root_window_bounds`, which is that method's doc comment. The method is at
line 173. `docs/12`, `docs/14` and this plan carry the same one-line error.

**Not verified.** Nothing here links, because nothing exists.

## 2. Estimates now known to be wrong

Every row gives a planned figure, a measured figure, and how the measurement was
made. Three were known before this slice started. The rest were measured here.

| Milestone | Planned | Measured | Ratio | How it was measured |
|---|---:|---:|---:|---|
| M1 property count | 105 | **87** | 0.83 | `table.zig:202-315`; upstream 88, one is `Unset` |
| M1 lines | 3700 | **11793** | 3.19 | `find src/schema` less `update.zig` and `handlers.zig` |
| M2 lines | 4400 | **20959** | 4.76 | `find src/consumer` less `root.zig` |
| M3 lines | 280 | **1389** | 4.96 | `wc -l src/schema/update.zig src/schema/handlers.zig` |
| M4 header lines | 3200 | **6581** | 2.06 | `wc -l include/zaccesskit.h` |
| M4 export count | 496 on the host | **446** on Linux | 0.90 | `docs/40-capi-build-map.md:79-82` |
| M4 modules | one per header region | **3** | not comparable | `docs/30:218` fixes three |
| M5 lines | 630 | **1920** with 6 of the modules | 3.05 | `find src/adapters/atspi` |
| M5 layout | `src/adapters/atspi/dbus/` | none | not comparable | `docs/41` section 2.2 |
| M6 modules | about 29 | **35** for M5 and M6 together | 1.21 | `docs/41` section 2.2 |
| M7 upstream | 3764 plus 712 | plus **317** of example | 1.08 | `windows/examples/` |
| M8 selectors | 58 | **43** | 0.74 | `docs/42` section 1.2.5. `docs/16` counts 6 |
| M9 UIKit symbols | 26 plus 4 | **39 plus 4, 43 distinct** | 1.50 | `docs/42` section 1.3.1 |
| M10 JNI call sites | `docs/16` says about 40 | **78** | 1.95 | a `call_method` scan, repeated here |
| M10 upstream | 2604 | plus **374** of example | 1.14 | `android/examples/hello_world.rs` |
| M11 line anchor | `adapter.rs:172` | **`:173`** | not comparable | `:172` is the doc comment |

**Three notes on the three figures that were known before this slice.**

The macOS selector figure is off by 37 between `docs/16` and `docs/42`, and the
plan carries a third number. The plan's 58 selectors is neither the 6 that
`docs/16` counts nor the 43 that `docs/42` measures.

The Android figure is off by a factor of two between `docs/16` and `docs/42`.
The plan states no JNI figure at all, so the plan is silent rather than wrong.

The iOS figure is off by 43 between `docs/16` and `docs/42`, and the plan
already carries the corrected 2560.

**One upstream figure in the plan could not be checked at all.** The M4 anchor
`8b6ed37c20ed4c59390e253407983333053662ba` is not in this checkout and
`accesskit-c/` does not exist at the pinned commit. That row is unverified, not
merely wrong.

## 3. What the plan still cannot say

Each remaining milestone has one fact that would move its estimate. A hope is
not a risk. These are facts, and each is checkable.

**M3, the platform interface module.** No document owns its name.
`docs/30-port-design.md` section 3.3 names `src/capi/` and `src/adapters/` and
stops. The plan proposed `src/consumer/adapter.zig`, and `AGENTS.md` line 90
states that neither the core nor the consumer half may hold `io`. A platform
interface holds `io`. Writing it where the plan proposed places a platform seam
in a layer whose rule forbids one, so the module moves or the rule changes, and
both cost more than the 280 lines the plan budgets.

**M4, the shared library and the gate.** 105 declarations return an aggregate by
value and 77 parameters across 57 declarations pass one, and
`docs/40-capi-build-map.md:1260` records the lowering convention as undecided.
The 48-byte `Affine` return is the case that decides it. Until the convention
lands, the conversion layer has no floor and the 7318 lines on disk cannot be
read as two thirds of the work.

**M5, the goose pin.** M5's estimate assumes four lines are added to a library
this project has not pinned. `build.zig.zon` holds one dependency. The first
`zig build` that fetches goose is therefore an unproven event, and if the author
declines the patch, the carrier is a 6412-line fork, not four lines. That is the
difference between a build-script edit and a second project.

**M6, the node split.** `node.rs` is 2065 upstream lines and
`docs/41-atspi-build-map.md` section 2.2 names five cuts inside it. No cut has
been written. The 35-module figure is a list, not a measurement, and the 29 in
the plan is neither that list nor a measurement.

**M7, the compile route.** `marlersoft/zigwin32` is not in `build.zig.zon`. The
plan's whole gate for M7 is one `zig build-obj` against that dependency, so
until the pin lands the milestone has no gate and no estimate can be checked
against one.

**M8, the selector strings.** 54 node selectors and 43 selector literals are
strings to a Zig compiler, so a wrong selector compiles and
`docs/42-native-adapter-build-map.md:1004` says so. The M8 estimate can only be
checked on a Mac, and there is no route here.

**M9, the same, plus the link.** 39 UIKit identifiers are unchecked the same
way, and `zig build-exe -target aarch64-ios` fails on this host, so nothing
links. Five modules and 1256 lines are on disk and none of them has been
compiled by this slice.

**M10, the build configuration.** An Android `.so` needs an NDK, an APK and a
separate build configuration. `build.zig` declares one module and two steps.
The ceiling for M10 on this host is a compile, and even that needs a target and
a dependency this project has not declared.

**M11, the owner.** No document names `src/app/`, and the four non-AT-SPI paths
need four hosts. The 600-line figure covers a facade whose location no document
fixes.

**Every milestone at once.** The plan's section 4.1 closes with the sentence
that nothing in M0 to M11 has been compiled. That sentence is still true for
`src/capi/` and `src/adapters/`, and this slice ran no compiler to change it.

## 4. Corrections to apply to `docs/40-plan.md`

This file was not edited. These are the changes an owner should make.

1. **Section 2, M1 gate.** Replace 105 properties in eight families with 87
   properties in thirteen upstream families. Name the thirteen counts.
2. **Section 2, M1 size.** Replace about 3700 lines with 11793 lines measured
   across 21 modules.
3. **Section 2, M2 size.** Replace about 4400 lines with 20959 measured across
   27 modules.
4. **Section 2, M3 size.** Replace about 280 lines in 3 modules with 1389
   measured in 2, and record that the third module has no owner document.
5. **Section 2, M4 size.** Replace about 3200 header lines with 6581 measured.
6. **Section 2, M4 modules.** Replace one module per header region with the
   three modules `docs/30-port-design.md:218` names, or record the disagreement
   between the plan and the work on disk.
7. **Section 2, M4 upstream anchor.** Mark the `accesskit-c` row unverified and
   name what is missing, which is that tree at that commit.
8. **Section 2, M4 exports.** State 446 for `x86_64-linux` beside the 496
   all-platform total, so a reader does not sweep for 496 and report 50 misses.
9. **Section 2, M5 layout.** Replace `src/adapters/atspi/dbus/` with the 35
   modules `docs/41-atspi-build-map.md` section 2.2 names.
10. **Section 2, M6 modules.** Replace about 29 with 35 for M5 and M6 together.
11. **Section 2, M8.** Replace 58 selectors with the 43 selector literals and the
    54 node selectors `docs/42` measures, and say that `docs/16` counts 6.
12. **Section 2, M9.** Replace 26 UIKit symbols with 39 named plus 4 literals.
    Keep the 2560 line count, which is correct.
13. **Section 2, M11.** Correct `adapter.rs:172` to `:173` in this plan, in
    `docs/12` and in `docs/14`.
14. **Section 3.2.** Every milestone-specific build step in that table does not
    exist. Mark the column, or add the steps, so a reviewer does not type a name
    that fails for a reason unrelated to the port.
15. **Section 4.1, last paragraph.** Add that 218 test declarations under
    `src/capi/` and `src/adapters/` are not reachable from the test root, so the
    706 does not cover them.
16. **Section 5, hazard H8.** Record that `include/zaccesskit.h` now exists and
    `.paths` still omits `include`, so a packaged build drops the header.

**One correction this slice cannot make.** The M4 row cites an upstream commit
that this checkout does not hold. Either the row is marked unverified or the
checkout gains that tree. Do not leave it as a figure a reader will trust.
