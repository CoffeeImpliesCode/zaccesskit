# 40 — The milestone plan for `zaccesskit`

**What this plan consumes.** The research documents under `docs/`, which numbered
29 when this plan was written and number 41 now, the two pinned upstream
checkouts, the `zio` pin in `build.zig.zon`, the eight fixed decisions in
`local://zaccesskit-risk-register.md`, and the module layout in
`docs/30-port-design.md`.

**What consumes this plan.** `docs/50-verification.md`, which turns the gates
below into a verification record. And the next agent to translate a module, who
needs to know what must already be true before a file opens.

**Branch: advice. This document is a proposal, not a finding.** No claim below
is evidence, and no entry gate in this document is a result. Every build and test
command in this plan is written as a command an agent *would* run, and every size
figure is a size somebody expects. Where a fact comes from a document that
measured it, the label says so. Where this plan is guessing, the label says that
too. A reader must not treat an entry gate here as a result.

**What changed under this plan.** The plan was written against an empty tree on
2026-10-05, and section 1.1 corrects the sentences that describe that tree. The
milestone tables are not corrected, because a milestone states what a slice must
produce and what gate it must pass, and a milestone that has been reached is still
described by its target.

## 1. What this plan is and is not

This plan sequences the port. It names twelve milestones, M0 to M11, and it
fixes the order. Each milestone covers a named set of upstream Rust files, says
which Zig modules it creates, names the earlier milestones it depends on,
estimates its size, and states an entry gate. An entry gate is a command plus a
stated proof. A gate can fail, and when it fails the failure names the defect
rather than a stage number.

This plan does not implement the port, and it does not describe the port as it
stands. It was written against an empty tree and read: "Today the repository
holds five things and no more: `build.zig` and `build.zig.zon` for the `zio` pin
and the module wiring, `cross-test.profile.sh` for the foreign matrix,
`src/root.zig` as a module doc comment with no declaration in it, `AGENTS.md` and
`README.md` for the house rules, and this `docs/` corpus. There is no library
code, no test, no C header and no adapter. Every line of Zig the port will
contain does not exist yet." Every one of those sentences is now false, and
section 1.1 carries the measurement that says so.

### 1.1 The tree as it stands, measured 2026-10-05T20:02+02:00

A comment-aware walk of the `@import` graph from `src/root.zig`, skipping `std`,
`builtin`, `zio` and `build_options`. Line counts come from `wc -l`. The test
column counts declarations whose line begins with `test "`. Other agents were
editing the tree while the walk ran, so a reader who repeats it may see a
different total.

| Layer | Modules | Lines | `test "` declarations | In the import graph |
|---|---:|---:|---:|---:|
| `src/schema/` | 24 | 13992 | 318 | 24 of 24 |
| `src/consumer/` | 28 | 21282 | 385 | 28 of 28 |
| `src/capi/` | 14 | 22316 | 220 | 14 of 14 |
| `src/adapters/` | 47 | 36528 | 519 | 43 of 47 |
| `src/root.zig` | 1 | 127 | 5 | in the graph |
| **All** | **114** | **94245** | **1447** | **110 of 114** |

Four modules and 1554 lines are outside the graph, and 22 of the 1447 test
declarations sit in those files, so a build step that roots at `src/root.zig`
analyses none of them. All four are Windows modules and all four need the
`zigwin32` pin that `build.zig.zon` does not declare. **Declaring the pin does
not reach them.** Compiled against the pinned commit with Zig 0.16.0,
`bindings.zig` compiles and its six tests pass on `x86_64-linux`, the other
three fail to compile, and `bindings.zig` itself cannot be analysed for
`aarch64-linux` or `powerpc64-linux`.
`docs/42-native-adapter-build-map.md` section 2.1.5 records every diagnostic,
and `src/adapters/windows/root.zig:19-31` records the measurement.

`src/root.zig` is 127 lines and declares five names: `schema` at `:36`,
`consumer` at `:49`, `capi` at `:57`, `version` at `:68` and
`minimum_zig_version` at `:74`. Three of the five carry a `refAllDecls` test at
`:106`, `:115` and `:122`, which is why a green `zig build test` reaches all 24
schema modules.

This census counts files and declarations. It runs no compiler.
`docs/50-verification.md` owns the run evidence, and this plan cites none of it.

A milestone here is a named set of upstream files translated, with an entry gate
that can fail. It is not a sprint and it is not a date. The unit is the upstream
file boundary, because that is where a reviewer can check the translation line
by line. A milestone that cannot state which upstream lines it covers is not a
milestone. M1 covers `lib.rs` role and property tables. M2 covers `tree.rs` and
`update_coordinator.rs`. Neither is "the data layer".

The gates below are commands, not results. Nothing was run to write this plan and
nothing in it reports an outcome. The tree has moved since, and the run evidence
for the tree belongs to `docs/50-verification.md`.

The upstream figures this plan quotes, the 182 roles, the 496 exported C
functions, the goose gaps G1 to G9, the measured struct layouts, all of those
come from documents that measured them, and each is attributed. The proof labels
in `docs/31-c-abi-design.md` section 1 apply here too, with one addition: every
statement about the port's own future behaviour is **advice**, and nothing in
this document rises above that.

### 1.2 Current build routes

These commands select declared build steps.
`docs/50-verification.md` records observed results.
This table does not repeat the house gate command list.

| Command | Contract |
|---|---|
| `zig build -Doptimize=ReleaseSafe` | Install the static C library and `zig-out/include/zaccesskit.h`. The native module uses the selected target and mode |
| `zig build -Doptimize=ReleaseSafe -Dlinkage=dynamic` | Install the dynamic C library and header |
| `zig build test-c -Doptimize=ReleaseSafe` | Link and run the offline C11 consumer against the selected library |
| `zig build integration` | Run the pure application-model command-to-Tree update tests in Debug and ReleaseSafe |
| `zig build integration-run -Doptimize=ReleaseSafe` | Run the exact eight-node offline application scenario |
| `zig build reference` | Load the pinned, hand-recorded JSON fixtures in Debug and ReleaseSafe |
| `zig build reference-run -Doptimize=ReleaseSafe` | Check fixture length, SHA-256, provenance, and exact output for all twelve cases |
| `zig build bench-test` | Run the benchmark harness tests in Debug and ReleaseSafe |
| `zig build bench-build -Doptimize=ReleaseSafe` | Compile `consumer-bench` without a run. The build reports its cache artifact |
| `zig build bench -Doptimize=ReleaseSafe -- --workload snapshot --shape balanced --nodes 65536 --work-units 8` | Run the deterministic snapshot workload without internal timing |
| `zig build test-c -Dtarget=aarch64-linux -Doptimize=ReleaseSafe -fqemu` | Link and run the Linux C consumer through QEMU user mode |

`test` also runs the integration and reference shards.
On a native target, it runs the linked C consumer.
`cross-test` also runs that consumer on Linux targets.
Foreign Linux execution requires the target runner.
Without a runner, the run fails rather than counts as compile-only evidence.
`integration-run`, `reference-run`, and `bench` use Zig runner selection with `-fqemu` for foreign targets.
The native module route is `dep.module("zaccesskit")`.
The C library route is `dep.artifact("zaccesskit")`, which carries its installed header.
The C artifact explicitly selects LLVM on Zig 0.16.0.
The native Zig module keeps its existing backend selection.
This requirement does not lift the accepted PowerPC64 C boundary limit.
Neither fixture checks nor offline scenarios execute Rust or a native platform accessibility bus.
Reference checks cover twelve finite, hand-recorded source-derived cases, not an executed Rust oracle or wire-parity proof.
The separate external-package probe exercised both dependency routes in Debug and ReleaseSafe.
Static and dynamic linkage each passed nine steps in both modes, for four executed configurations.
`docs/50-verification.md` section 10.5 records the outputs and no-bus limits.
Nogui remains source-only and was not executed.
The corrected-source gate exited 1 with disclosed checker failures and the unsupported PowerPC64 linked-C boundary.
Section 10.7 records its actual stage results and strict cross summary.
[Issue #5](https://github.com/CoffeeImpliesCode/zaccesskit/issues/5) is OPEN and tracks the future Zig 0.17 ABI check.
It does not establish a Zig 0.17 fix.


---

## 2. The milestones

Twelve milestones. Each table gives the upstream lines a milestone translates,
the Zig modules it creates, what it needs from earlier milestones, an expected
size, and the entry gate it must pass. Every size is advice. Every command is
one an agent would run.

Upstream paths in these tables are relative to the checkout at
`466e24e252103f4d82bd6fbab98141b551e46e0c`. The module paths follow
`docs/23-core-boundary.md` section 7. The module count is 50, not 47, because
the three splits it names are counted here as separate modules.

### M0. The base

This table is the baseline M0 started from, read on 2026-10-05. It is not the tree
today, and section 1.1 measures that. Three of the five rows have moved, and the
corrections are beside each row.

| Thing | Where, then | State then |
|---|---|---|
| `zio` pin, codeload tarball at commit `2662fdc45997611b962b560c513c16963475a01b` | `build.zig.zon:29-33` | source reading at a pinned revision. The pin has not moved. |
| One published module `zaccesskit`, rooted at `src/root.zig`, importing `zio` | `build.zig:37-48`, now `build.zig:58-66` | source reading |
| Two test shards, Debug and ReleaseSafe, each under `ulimit -v 4194304` | `build.zig:52-71`, now `build.zig:74-94` | source reading |
| One foreign matrix with three rows | `cross-test.profile.sh:38-42` | source reading |
| A module root with no declaration in it | `src/root.zig:1-19` | source reading. Wrong now. `src/root.zig` is 127 lines and declares five names, at `:36`, `:49`, `:57`, `:68` and `:74`, and the `test` step depends on two more shards it did not have, `fuzz-Debug` at `build.zig:170` and `fuzz-ReleaseSafe` at `build.zig:186`. |

What M0 adds:

| Addition | Detail | Why here |
|---|---|---|
| The `goose` pin | `.url = https://github.com/luxluth/goose/archive/refs/tags/v3.3.0.tar.gz`, `.hash = goose-3.3.0-e9MzMIEpBACANYPKd-lGDjoxFHcbYTKmfMWA4c0XK_wZ`, recorded in `local://zaccesskit-deps.md` and measured at `docs/26-goose-live-bus-probe.md:114-131` | It is the second of the two dependencies the decision fixes. Pinning it before any code exists means the first `zig build` that fetches it is the gate. |
| A probe module that imports `goose` | One file, no logic | A dependency in `.dependencies` that nothing imports is never fetched, so a bad hash would not fail until M5. |
| Three more matrix rows | `riscv64-linux`, `loongarch64-linux`, `x86-linux`, named in advance at `cross-test.profile.sh:35-37` | Wider architecture coverage and 32-bit pointer and alignment bugs. `x86-linux` is the row that catches a `usize` assumed to be 8 bytes. |
| A self-test | One `test` that counts its own discovery, so stage 3 prints a count | `AGENTS.md` item 2 makes the printed count a gate condition, and stage 3 only soft-skips when there is no `test` step at all (`zig-gate:452-453`). |
| `.paths` widened | Add `third_party` | **Done for two of the three.** `build.zig.zon:53-64` lists `test`, `tools`, `include` and `docs`. It does not list `third_party`, and no `third_party` directory exists. |
| **No `fuzz` step** | The decision was to add none, because a fuzz step cannot compile | **The decision stands and the reason no longer holds alone.** `-ffuzz` does not compile on Zig 0.16.0 (`docs/22-zig-build-surface.md:1915-1959`), and no build step sets it. `build.zig:156` declares a `fuzz` step anyway, and it replays the committed corpus in `test/fuzz/corpus/` through `std.testing.fuzz` rather than mutating. `build.zig:140-142` says so in the step's own comment. |

| Field | M0 |
|---|---|
| Upstream covered | none. M0 translates nothing. |
| Zig modules created | one probe under `tools/`, not published |
| Depends on | nothing |
| Expected size | about 120 lines of build wiring, plus 3 matrix rows |
| Entry gate | `zig-gate` |
| What the gate must prove | `zig build` resolves both pins, so the `zio` hash and the `goose` hash are both correct for Zig 0.16.0 on this host. Stage 3 prints a test count, so the test tree is discoverable. Stage 9 runs five rows and reports `fail=0`. |

### M1. Geometry and schema types

| Field | M1 |
|---|---|
| Upstream covered | `accesskit/src/geometry.rs:22-866`, all five `#[repr(C)]` types: `Affine` at `:22`, `Point` at `:212`, `Rect` at `:337`, `Size` at `:571`, `Vec2` at `:717`. Then `accesskit/src/lib.rs:61-1170` and `:1909-2546` and `:2679-2790`: `Role` at `:62`, `Action` at `:289`, the 13 node enums at `:417-700`, `NodeId` at `:715`, `TreeId` at `:745`, `CustomAction` at `:761`, `TextSelection` at `:784`, `Color` at `:834`, `PropertyValue` at `:856`, `PropertyId` at `:893`, `Node` at `:1107` |
| Zig modules created | the 21 schema modules of `docs/23-core-boundary.md:710-732`, minus `schema/update.zig` and `schema/handlers.zig`, which belong to M3. That is `geometry/affine.zig`, `geometry/point.zig`, `geometry/rect.zig`, `geometry/size.zig`, `geometry/vec2.zig`, `role.zig`, `node_enums.zig`, `scroll_enums.zig`, `action.zig`, `ids.zig`, `values.zig`, `props/table.zig`, `props/flags.zig`, `props/ids.zig`, `props/strings.zig`, `props/numbers.zig`, `props/colors.zig`, `props/vectors.zig`, `props/enums.zig`, `props/option.zig`, `node.zig` |
| Depends on | M0 |
| Expected size | about 3700 lines of Zig across 21 modules, from 4051 upstream non-test lines (`docs/23-core-boundary.md:689-692`) |
| Entry gate | `zig build test` plus a layout conformance test |
| What the gate must prove | Three things, each with a test that fails on a named field. The five `extern struct` layouts match what the C header says, so `@sizeOf` and each field offset agree with `include/accesskit.h`. The 182 role discriminants match `lib.rs:62-271` and with `ACCESSKIT_ROLE_` in the header, which is 182 occurrences (`docs/15-tree-semantics.md:1477`, and a count taken again for this plan). The 105 properties exist, in the eight families of `docs/23-core-boundary.md:722-729`: 18 flags, 15 id, 21 string, 22 number, 6 color and decoration, 5 list, 14 boolean and unique-enum, 4 option. |

`Role` is `#[repr(u8)]` at `lib.rs:61` with 182 variants, discriminants 0 to 181
(`docs/15-tree-semantics.md:58-59`). `PropertyValue` at `lib.rs:856` has 29
variants, one per storage kind. `PropertyId` at `lib.rs:893` is `#[repr(u8)]`
and private upstream. The port publishes it, because the fixtures in
`docs/15-tree-semantics.md:1436` address roles and properties by discriminant.

**The five measured layouts.** `docs/19-geometry-and-text.md:505-534` records a
Zig 0.16.0 probe with `@sizeOf`, `@alignOf` and `@offsetOf`, exercised
compilation on this host. M1 asserts these numbers in a `comptime` block rather
than trusting the compiler, because a wrong `extern struct` compiles silently.

| Type | Size | Align | Field offsets |
|---|---|---|---|
| `Point` | 16 | 8 | `x` 0, `y` 8 |
| `Size` | 16 | 8 | `width` 0, `height` 8 |
| `Vec2` | 16 | 8 | `x` 0, `y` 8 |
| `Rect` | 32 | 8 | `x0` 0, `y0` 8, `x1` 16, `y1` 24 |
| `Affine` | 48 | 8 | `coeffs` 0, so `coeffs[3]` 24 |

The optional `Rect` is 40 with the flag at 0 and the payload at 8, because the
payload needs an alignment of 8. A `packed` `Point` or `Rect` measures align 16,
which is why neither is used. These five numbers are the only byte layouts M1
owns, and each one is compared against the C header a second time in M4.

### M2. The tree store and the update protocol

| Field | M2 |
|---|---|
| Upstream covered | the whole `accesskit_consumer` crate: `src/filters.rs` 421 lines, `src/iterators.rs` 1060, `src/lib.rs` 210, `src/node.rs` 2120, `src/text.rs` 2836, `src/tree.rs` 3224. Total 9871 lines, 4202 of them non-test (`docs/23-core-boundary.md:692`) |
| Zig modules created | the 24 consumer modules of `docs/23-core-boundary.md:742-765`, plus the 3 splits that section names: `tree_apply` cut in two, `text/hit_test` cut in two, `text/position_motion` cut in two. That is 27 modules |
| Depends on | M1 |
| Expected size | about 4400 lines of Zig across 27 modules |
| Entry gate | `zig build test` over the conformance fixture set, plus `zig-gate` |
| What the gate must prove | Each of the 12 invariants in `docs/15-tree-semantics.md:1451-1464` has a test, and the fixture set of `docs/15-tree-semantics.md:1433-1444` runs against them. Eight of the twelve are cheap: decode is stable, encode after decode is byte-identical, `clear` then `push` leaves one item, the sum of `character_lengths` equals the byte length of `value`, `word_starts` strictly increases, a `tree_id` node has no `children`, the root has no parent, and no `NodeId` appears twice across `children` in one update. |

The invariants become `assert` statements in the port, not comments. They trace
to upstream lines: `lib.rs:1164-1167` for clone equality, `lib.rs:1084-1094` for
order independence, `lib.rs:1131-1133` for clear then push,
`lib.rs:2336-2337` for the character length sum, `lib.rs:2356` for word starts,
`lib.rs:2392-2393` for position and length agreement,
`accesskit_consumer/src/tree.rs:272-278` for the graft rule,
`tree.rs:262-264` for the root parent rule, and `tree.rs:235-237` for the
duplicate child rule.

### M3. The action channel and the platform interface

| Field | M3 |
|---|---|
| Upstream covered | `accesskit/src/lib.rs:3162-3385`: `TreeInfo` at `:3169`, the deprecated `pub type Tree = TreeInfo` at `:3178-3179`, `TreeUpdate` at `:3208`, `ScrollUnit` at `:3271`, `ScrollHint` at `:3291`, `ActionData` at `:3305`, `ActionRequest` at `:3328`, and the three handler traits `ActivationHandler` at `:3336`, `ActionHandler` at `:3362`, `DeactivationHandler` at `:3376`. Then the tree-update rule at `lib.rs:3216-3228` |
| Zig modules created | `schema/update.zig` and `schema/handlers.zig`, the two modules `docs/23-core-boundary.md:731-732` names. Plus the adapter interface module. `docs/30-port-design.md` owns its name. This plan calls it `src/consumer/adapter.zig` and marks that a proposal |
| Depends on | M1 for the value types, M2 for the tree store it updates |
| Expected size | about 280 lines of Zig in 3 modules, from 224 upstream lines |
| Entry gate | `zig build test` over the action-channel tests, plus `zig-gate` |
| What the gate must prove | An `ActionRequest` survives a round trip through the channel with its `Action`, `TreeId`, `NodeId` and `ActionData` intact, and `ActionData` is `#[repr(C)]` upstream at `lib.rs:3304`, so the port must match its layout byte for byte. A node with no parent in an update fails with a named error rather than a panic. |

`pub type Tree = TreeInfo` at `lib.rs:3178-3179` is deleted rather than
translated, on the house rule against backwards compatibility, as
`docs/23-core-boundary.md:787` records. `TreeUpdate` keeps its four fields: new
nodes, updated nodes, removed nodes, and the tree info.

### M4. The C ABI

| Field | M4 |
|---|---|
| Upstream covered | `accesskit-c/include/accesskit.h` at `8b6ed37c20ed4c59390e253407983333053662ba`, 3154 lines, 496 unique `accesskit_*(` symbols, 182 `ACCESSKIT_ROLE_` constants, 18 enums, 18 opaque handle typedefs and 4 function-pointer typedefs. Then `accesskit-c/src/`, 2755 lines across `common.rs` 1234, `geometry.rs` 247, `macos.rs` 276, `ios.rs` 252, `lib.rs` 224, `android.rs` 230, `windows.rs` 174, `unix.rs` 96 |
| Zig modules created | `src/capi/`, one module per header region, plus `include/accesskit.h` checked in and installed with `Step.Compile.installHeader`. `docs/31-c-abi-design.md` owns the module split and the header wording |
| Depends on | M1 for the value types, M3 for `ActionRequest` and `TreeUpdate` |
| Expected size | about 5500 lines of Zig plus about 3200 lines of header |
| Entry gate | `zig build capi-parity` plus `zig-gate` plus `zig build test-c` |
| What the gate must prove | Header parity checks names and guarded exports. The linked C11 consumer checks calls and ownership. `zig build` installs the selected static or dynamic C library and header. |

The header is checked in because `-femit-h` returns
`error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698`
(`docs/22-zig-build-surface.md:715`, runtime observation on Zig 0.16.0), and
Zig has no Zig-to-C emitter. No hand-written C shim is needed for the ABI as it
stands, because the header carries zero bitfields, zero function-like macros and
zero variadic declarations (`docs/22-zig-build-surface.md`, section 3.7).

The conformance program is what closes the big-endian gap that section 5 names.
It writes one `accesskit_tree_update_with_focus` and reads it back, and it does
so inside the `powerpc64-linux` row of `cross-test`, so the `#[repr(C)]` layout
of `ActionData` is executed on a big-endian target rather than assumed.

### M5. The D-Bus layer on goose

This is the milestone the risk register spends the most words on. Eleven gaps
between goose and what an AT-SPI adapter needs are recorded in
`docs/13-atspi-protocol.md:803-815` as G1 to G11, and the risk register
consolidates nine of them into R1 and R8. Decision 5 fixes the route: goose
supplies the connection and the message layer, and the port owns the
dispatcher, the path index, the typed error mapping and the bus address
discovery. Of the eleven, G7 and G8 need nothing written, because AccessKit's
handlers are synchronous and short and AccessKit does not use `ObjectManager`.

| Field | M5 |
|---|---|
| Upstream covered | `accesskit/accesskit_consumer` has no D-Bus code. The reference is `accesskit/adapters/unix/src/atspi/`, 1951 lines: `bus.rs` 525, `interfaces/` 1289 across 13 files, `object_id.rs` 79, `object_address.rs` 45, `mod.rs` 13 |
| Zig modules created | `src/adapters/atspi/dbus/`: a dynamic object register and remove path, a path index, a member-name table, a typed error set and its mapping to `org.freedesktop.DBus.Error` names, a runtime signal emit, the bus address parser, the five-step discovery, and the zio pump loop over `getFd` and `dispatch` |
| Depends on | M0 for the pin, M2 for the tree it publishes, M3 for the tree update it sends |
| Expected size | about 630 lines of Zig, of which about 250 are the object register and remove path (`docs/17-rust-dependency-surface.md:392-394`) |
| Entry gate | `zig build atspi-bus-test`, then `zig-gate` |
| What the gate must prove | Four things. The bus address discovery reaches the live a11y bus at `unix:path=/run/user/33156/at-spi/bus` with no session bus in the environment, because `org.a11y.Bus.GetAddress` is called at `/org/a11y/bus` and the result is put in the environment map under `AT_SPI_BUS_ADDRESS`. An object registered at a path and then removed answers a call on the first and returns `UnknownObject` on the second. A method call on an unregistered path returns `org.freedesktop.DBus.Error.UnknownObject` byte for byte, and a call with a bad index returns `InvalidArgs`, which is a name goose cannot produce on its own. A signal the port emits arrives at a subscriber that called `addMatch`. |

**The `O_NONBLOCK` fix.** goose opens the socket through the caller's `std.Io`,
and zio opens sockets non-blocking at `zio/src/net.zig:912` and never restores
blocking mode. goose's `SocketReader.recvWithIovecs` calls raw `recvmsg` at
`connection.zig:221` and folds `EAGAIN` into `error.ReadFailed` at `:188-190`.
Measured: `fcntl F_GETFL` returns `0x802` against `0x2` for a default `std.Io`,
and the first run fails with `error.ReadFailed` (`docs/26-goose-live-bus-probe.md:657-668`,
runtime observation). The fix is four lines after `const socket = try
unix_addr.connect(io);` at `connection.zig:514`, clearing bit 11
(`docs/26-goose-live-bus-probe.md:670-682`).

**Advice on how the patch is carried.** The port cannot fix this from outside.
`Connection.initWithBackend` runs the `auth()` handshake at
`connection.zig:419-463` before it returns, so the failure happens before
`getFd()` is usable, and goose exposes no `initFromFileDescriptor`. Three
carriers are available:

| Carrier | Cost | When it wins |
|---|---|---|
| A checked-in patch file and a build step that applies it, failing when it does not apply | one extra directory, `third_party/goose-patches/`, and about 20 lines of build script | The pin stays the exact tarball hash, and a goose update that moves the line fails the build with the patch named |
| A vendored copy of the goose tree | the whole 6412-line library under version control | A maintainer will not accept the upstream change |
| An upstream pull request | nothing local | The author takes it. `docs/26-goose-live-bus-probe.md:879-883` names this as the open risk |

This plan recommends the first, and says so as advice. A four-line change is not
a fork, but it is a change, and a build step that applies a patch is a thing that
can silently stop applying.

**The five-step discovery.** goose does not model it. A search of the goose tree
for `org.a11y.Bus` and `GetAddress` returns nothing
(`docs/26-goose-live-bus-probe.md:550-556`). The port opens a `.Session`
connection, calls `GetAddress` at `/org/a11y/bus`, decodes a `GStr`, puts the
result in the environment map under `AT_SPI_BUS_ADDRESS`, then opens the
`.Accessibility` connection (`docs/26-goose-live-bus-probe.md:570-574`).
The variable is not optional: the fallback at `connection.zig:497-500` builds
the socket name `bus_0` while the real socket is `bus`, so with the variable
removed the connect fails with `error.FileNotFound`.

**The dispatcher.** goose's `registerObject` takes a `comptime` type, calls
`requestName` at `connection.zig:701`, and appends to an append-only list at
`:740`. There is no `remove` anywhere in the file, and the list has no mutex
while `dispatchUnsolicited` iterates it from a dispatch thread at `:934-937`.
Upstream registers ten interfaces per node and removes them when a subtree dies,
so the port needs a path-keyed table with register, remove and vtable dispatch.
It needs an explicit member name per method, because goose takes the wire name
from the Zig declaration name at `dispatcher.zig:264` and every error collapses
to `org.freedesktop.DBus.Error.Failed` at `:298`.

### M6. The AT-SPI adapter

First adapter, because it is the only one that runs on this host.

| Field | M6 |
|---|---|
| Upstream covered | `accesskit/adapters/atspi-common/`, 4417 lines: `node.rs` 2065, `simplified.rs` 977, `adapter.rs` 824, `util.rs` 134, `context.rs` 122, `text_attributes.rs` 79, `events.rs` 78, `rect.rs` 37, `error.rs` 33, `lib.rs` 33, `action.rs` 14, `callback.rs` 15, `filters.rs` 6. Then `accesskit/adapters/unix/`, 809 lines: `context.rs` 306, `adapter.rs` 276, `executor.rs` 158, `util.rs` 42, `lib.rs` 27 |
| Zig modules created | `src/adapters/atspi/`, about 29 modules at the 250-line limit |
| Depends on | M5 for the bus, M2 for the tree, M3 for the update |
| Expected size | about 7500 lines of Zig across about 29 modules, from 5226 upstream lines |
| Entry gate | `zig build atspi-live-test`, then `zig-gate` |
| What the gate must prove | A real accessibility client sees the tree. `busctl` or `python3` with `dbus-next` calls `GetChildren` on a registered node path and gets the child references the port published, then calls `GetRole` and `GetState` and gets the values the tree update carried. The port emits `Cache.AddAccessible` on registration and `Cache.RemoveAccessible` on removal, one each. |

This is the largest single milestone and the plan says so rather than
discovering the cost halfway through. `node.rs` at 2065 lines and `simplified.rs`
at 977 are wide mapping tables from AccessKit types onto AT-SPI types. They port
well and test well, and they buy no platform coverage
(`docs/12-accesskit-adapters.md:1474-1483`). They run here, which is why.

### M7. The Windows adapter

| Field | M7 |
|---|---|
| Upstream covered | `accesskit/adapters/windows/`, 3764 lines of library and 712 of tests: `node.rs` 1539, `adapter.rs` 673, `text.rs` 652, `util.rs` 536, `subclass.rs` 204, `context.rs` 98, `window_handle.rs` 32, `lib.rs` 22, `filters.rs` 8. Tests: `tests/mod.rs` 337, `tests/simple.rs` 198, `tests/subclassed.rs` 177 |
| Zig modules created | `src/adapters/windows/`, about 16 modules |
| Depends on | M2 for the tree, M3 for the update, M4 for the C entry points `accesskit_windows_adapter_new` and its siblings |
| Expected size | about 4000 lines of Zig across about 16 modules |
| Entry gate | `zig build-obj -target x86_64-windows` over the adapter, then `zig-gate` |
| What the gate must prove | The adapter compiles for `x86_64-windows` against `marlersoft/zigwin32` at `9f15c276b4e9d05afd34a10d8662a7dfc34647ea`, and every one of the 18 functions and 14 COM interfaces it names exists with the signature the header gives. `zig build-exe -target x86_64-windows -luiautomationcore` links, and `-luser32` links (`docs/16-native-platform-apis.md:1776-1778`, exercised compilation). Nothing more. |

There is no Windows host. `which wine` returns nothing
(`docs/16-native-platform-apis.md:1788`), so no Windows claim in M7 can be an
observation. The Linux gate proves the adapter names real symbols. It does not
prove the adapter works.

Zig 0.16.0 ships no `std.com`, so the COM object base is about 120 lines the
port must write (`docs/16-native-platform-apis.md:1436`, `:1825`). `zigwin32`
gives types and extern declarations, not an object factory
(`docs/16-native-platform-apis.md:1530-1537`).

### M8. The macOS adapter

| Field | M8 |
|---|---|
| Upstream covered | `accesskit/adapters/macos/`, 2605 lines: `node.rs` 1367, `event.rs` 335, `subclass.rs` 273, `adapter.rs` 295, `util.rs` 108, `context.rs` 103, `patch.rs` 93, `lib.rs` 25, `filters.rs` 6 |
| Zig modules created | `src/adapters/macos/`, about 11 modules |
| Depends on | M2, M3, M4 |
| Expected size | about 2800 lines of Zig across about 11 modules |
| Entry gate | `zig build-obj -target aarch64-macos` over the adapter, then `zig-gate` |
| What the gate must prove | The adapter compiles for `aarch64-macos`. It does not link: `zig build-exe -target aarch64-macos -lobjc` fails with `unable to find dynamic system library 'objc' using strategy 'paths_first'. searched paths: none`, and `-framework Foundation` fails with `unable to find framework 'Foundation'` (`docs/16-native-platform-apis.md:1780-1781`, exercised compilation). |

Three externs for associated objects and `object_setClass` are typed by hand
because `zig-objc` does not expose them (`docs/16-native-platform-apis.md:1438`).
58 selectors are typed by hand (`:1826`). AppKit itself is rung 4, a
hand-written shim, because AppKit headers are Objective-C and `translate-c`
cannot parse them (`docs/16-native-platform-apis.md:1439`).

### M9. The iOS adapter

| Field | M9 |
|---|---|
| Upstream covered | `accesskit/adapters/ios/`, 2560 lines: `node.rs` 1076, `adapter.rs` 514, `subclass.rs` 324, `event.rs` 270, `filters.rs` 130, `util.rs` 110, `context.rs` 95, `lib.rs` 41 |
| Zig modules created | `src/adapters/ios/`, about 11 modules |
| Depends on | M2, M3, M4 |
| Expected size | about 2700 lines of Zig across about 11 modules |
| Entry gate | `zig build-obj -target aarch64-ios` over the adapter, then `zig-gate` |
| What the gate must prove | The adapter compiles for `aarch64-ios`. It does not link: `zig build-exe -target aarch64-ios` fails with `unable to find libSystem system library` and the output file is 0 bytes (`docs/16-native-platform-apis.md:1782`, exercised compilation). |

UIKit is rung 4 throughout. 26 UIKit symbols are typed by hand, 4 of them
through `dlsym`, which is why the crate links `libSystem`
(`docs/16-native-platform-apis.md:1454`, `:1826`). Until someone runs M9 on a
Mac its status is "compiles", not "works"
(`docs/16-native-platform-apis.md:1878-1881`).

### M10. The Android adapter

| Field | M10 |
|---|---|
| Upstream covered | `accesskit/adapters/android/`, 2604 lines: `adapter.rs` 906, `inject.rs` 471, `node.rs` 447, `event.rs` 419, `util.rs` 251, `action.rs` 85, `lib.rs` 19, `filters.rs` 6. Plus the Java side, about 70 lines |
| Zig modules created | `src/adapters/android/`, about 11 modules |
| Depends on | M2, M3, M4 |
| Expected size | about 2800 lines of Zig across about 11 modules, plus the Java layer |
| Entry gate | `zig build-obj -target aarch64-linux-android` over the adapter, then `zig-gate` |
| What the gate must prove | The adapter compiles for `aarch64-linux-android` and `zig translate-c` parses `jni.h` (`docs/16-native-platform-apis.md:1775`, `:1786`, both exercised compilation). It does not link: `zig build-exe -target aarch64-linux-android -llog -lc` fails with `unable to find dynamic system library 'log'` (`:1783`). |

The Zig code is portable and the build is not. The adapter must be compiled
into an Android `.so` under a separate build configuration that this repository
does not declare, so M10 needs an NDK and an APK and belongs to an Android host
(`docs/12-accesskit-adapters.md:1314`). The Android `embedded-dex` feature at
`adapters/android/Cargo.toml:16` exists to work around the absence of a Java
class on the classpath. `docs/12-accesskit-adapters.md:1403-1408` recommends
keeping that behaviour, and M10 carries it.

### M11. The application side

| Field | M11 |
|---|---|
| Upstream covered | `accesskit/adapters/unix/src/adapter.rs:172` `set_root_window_bounds` and `:222` `update_window_focus_state`, plus the `Adapter` facade at `:80-230` that holds the three-state `AdapterState` (`Inactive` at `:81`, `Pending` at `:86`, `Active` at `:91`) and `update_if_active` at `:196` |
| Zig modules created | one application-facing module per platform under `src/app/`, and one facade that the application calls |
| Depends on | every adapter milestone, because the facade is what calls them |
| Expected size | about 600 lines of Zig, plus an example application per platform |
| Entry gate | `zig-gate` on the native target, plus one example application that links and runs |
| What the gate must prove | On the AT-SPI path, the example pushes `set_root_window_bounds` with an outer and an inner rect, then `update_window_focus_state`, and both reach the bus. `at-spi2-registryd` and `at-spi2d` are not installed on this host, only `at-spi-bus-launcher` (`docs/12-accesskit-adapters.md:1460`), so a real assistive client is not part of the proof. |

**What M11 exists for.** Upstream's unix adapter never reads a display server.
It has no `extern "C"` block, no `#[link]` attribute and no `build.rs`, and the
only match for `xcb|wayland|X11|xlib|xkb|wl_` over `adapters/unix/src/` is a
doc comment at `adapter.rs:172` (`docs/12-accesskit-adapters.md:74-80`). Geometry
and focus reach the adapter through two methods the application calls. A Zig
application must supply both itself, on each platform, from the platform's own
window API. That is a real cost the port carries, and R6 downgrades it from a
risk to a named obligation.

---

## 3. The gates

### 3.1 The house gate, and what it does not run

The house gate is one script, `~/.local/bin/zig-gate`,
823 lines, ten stages in this order: `fmt`, `build`, `test`, `ast-check`,
`ziglint`, `zlint`, `zbc`, `zwanzig`, `cross-test`, `zig-cov`
(`docs/18-testing-strategy.md:13-14`, `:24-35`). The first nine are on by
default. The tenth is advisory and off.

Three facts about the gate shape every milestone's own checks.

**The gate has no fuzz stage.** A search for `fuzz` over the 823 lines returns
nothing (`docs/18-testing-strategy.md:125-133`). No milestone therefore claims a
fuzz gate. A fuzz step that the gate never runs is not a gate.

**The gate measures line coverage, and the measurement is advisory.** Stage 10
is off unless `--cov` is passed, and it fails the run only when
`ZIG_COV_FAIL_UNDER` is set (`docs/18-testing-strategy.md:983-991`). There is no
branch metric: `zig-cov report --format=` offers only summary, lcov, html, json,
cobertura and github, and all six are line-coverage formats
(`docs/18-testing-strategy.md:993-1006`). No milestone writes a coverage number
into its gate. `build.zig` has no coverage wiring, so stage 10 currently reports
that it is skipped.

**`cross-test` is the only stage that leaves the host.** It runs
`zig build cross-test` through `cross-test.profile.sh`, and on this host that
builds static musl and runs it under `qemu_user`. `zig-gate --no-cross` drops
it, and nothing else does. Every foreign-endian claim in this plan rests on
that one stage.

### 3.2 The gate per milestone

This table retains planned milestone checks.
Section 1.2 names current declared routes. `docs/50-verification.md` records runs, not this table.

| Milestone | What `zig-gate` proves | What the milestone must add, and what it proves |
|---|---|---|
| M0 | both dependency hashes resolve, stage 3 prints a count, and stage 9 builds and runs five rows | none |
| M1 | every schema module compiles, lints and passes its own tests | `zig build layout-test`. It compares `@sizeOf` and every field offset of the five `extern struct` types against the C header, and it compares the 182 role discriminants against `ACCESSKIT_ROLE_`. The gate has no way to know a struct is the wrong size. |
| M2 | the reached consumer tests run | The reference and integration routes in section 1.2 check finite hand-recorded oracles and the application-model update scenario. They do not execute Rust or prove all possible trees. |
| M3 | the update and handler modules compile and pass | `zig build action-test`. It drives one `ActionRequest` through the channel and back. |
| M4 | the default build installs the selected C library and header. Native tests run the linked consumer | The C and parity routes in section 1.2 separate declarations from linked calls and ownership checks. Foreign Linux runs require a runner. |
| M5 | the D-Bus modules compile under the static analysers | `zig build atspi-bus-test`. It runs the five-step discovery against a private `dbus-daemon` and against the live a11y bus, and the fake-peer suite from `docs/13-atspi-protocol.md:1005-1047`. Neither needs a display server. |
| M6 | the AT-SPI modules compile | `zig build atspi-live-test`. It needs the a11y bus, and it skips when `AT_SPI_BUS_ADDRESS` is unset. It is not a gate line, so a skip is not a failure. |
| M7 | nothing about the adapter, because the gate builds for the host target | `zig build-obj -target x86_64-windows`. It proves the adapter names real symbols. |
| M8 | nothing about the adapter | `zig build-obj -target aarch64-macos`. Same. |
| M9 | nothing about the adapter | `zig build-obj -target aarch64-ios`. Same. |
| M10 | nothing about the adapter | `zig build-obj -target aarch64-linux-android`. Same. |
| M11 | the facade modules compile | one example application that links and runs on the host target |

### 3.3 Which milestones can be verified here, and which cannot

| Milestone | On this host | Host it needs for the rest |
|---|---|---|
| M0 | build, test, cross-test | none |
| M1 | build, test, cross-test, layout conformance | none |
| M2 | build, test, cross-test, fixture conformance | none |
| M3 | build, test, cross-test, action round trip | none |
| M4 | build, test, cross-test, `binding-check`, C link. The shared library links on Linux. | a Windows or macOS host for the C ABI as a real consumer uses it |
| M5 | build, test, cross-test, private bus, live a11y bus, fake peer | none |
| M6 | build, test, cross-test, live bus. Not a real screen reader: `at-spi2-registryd` and `at-spi2d` are not installed, only `at-spi-bus-launcher` (`docs/12-accesskit-adapters.md:1460`) | a desktop session with a screen reader for the end-to-end claim |
| M7 | cross-compile only | a Windows host, with UI Automation available |
| M8 | cross-compile only | a macOS host |
| M9 | cross-compile only | a Mac with the iOS SDK |
| M10 | cross-compile only | an Android host with the NDK, and a device or emulator for the APK |
| M11 | the AT-SPI path only | one host per platform for the other four |

Five milestones, M0 to M5, are fully verifiable here. M6 is verifiable here
except for the screen reader. M7 to M10 are compile-only here and nothing more.
M11 is per-platform.

---

## 4. The verification route per milestone

Six routes. A cell names what the route proves for that milestone, or it says
nothing, or it says the row is honest that nothing proves it here.

| Route | What it can prove |
|---|---|
| Pure unit test | a function computes the right answer from arguments it was given. It cannot prove a wire layout, a byte order or a foreign symbol. |
| Recorded fixture | the port decodes bytes a real implementation produced, or the port emits bytes a real implementation consumed. The fixture is committed and the build never regenerates it (`docs/18-testing-strategy.md:686-700`). |
| Live AT-SPI bus | the handshake, framing, match rules and method dispatch work against a real daemon and the real a11y bus address. |
| Synthetic D-Bus peer | the same wire facts with no daemon, driven from both directions, deterministic, and running in a container. |
| Cross build | a symbol exists with a name and a signature, on a foreign target. It proves nothing about behaviour. |
| Nothing on this machine | the claim has no route here. It is written down as open, not as passing. |

| Milestone | Pure unit test | Recorded fixture | Live AT-SPI bus | Synthetic D-Bus peer | Cross build | Nothing on this machine |
|---|---|---|---|---|---|---|
| M0 | the probe imports goose and reports the compiler version | none | none | none | all five rows build and run, `fail=0` | nothing. M0 is fully verifiable here. |
| M1 | every geometry method: `Rect.abs`, `union`, `intersect`, `contains`, `Affine.inverse`, and the numeric edges `-0.0`, `0.0`, `nan`, `inf`, `-inf` | `test/fixtures/wire/*.nodejson.hex` decode and re-encode byte-identically | none | none | the 182 role tags and the five struct layouts hold on `powerpc64-linux`, which is the only row that catches an endianness bug in a byte layout | a real consumer linking `libzaccesskit` from another language |
| M2 | every property getter and setter, the 12 invariants as assertions, the iterators | the fixture set of `docs/15-tree-semantics.md:1433-1444`: 10 files, including `roles_all`, `property_all`, `flags_all`, `graft`, `clear_then_push`, `clone_equivalence`, `numeric_edges` | none | none | the tree serialisation holds on `powerpc64-linux` | nothing about the tree store. It is pure logic and M2 is fully verifiable here. |
| M3 | the action channel delivers and does not deliver, `ActionData` variant round trips, an update with an orphan node fails with a named error | one `test/fixtures/abi/` case built through the C ABI and decoded in Zig | none | none | `ActionData` is `#[repr(C)]`, so the big-endian row is the only execution proof of its layout | the ordering guarantee against a real assistive technology, which M6 owns |
| M4 | the C conformance program calls across all 18 enums, every opaque handle is non-null, every `has_value` predicate is exercised | `test/fixtures/abi/`: a tree update built through the C ABI, serialised, decoded, and compared against the value the API was given | none | none | the big-endian row executes the same conformance program, which is what closes the data-carrying enum gap | the ABI as a Windows or macOS C consumer uses it |
| M5 | the path index registers, resolves and removes, the typed error set maps to the right `org.freedesktop.DBus.Error` names, and the address parser handles `unix:path=` and `unix:abstract=` | one captured `Embed` reply from a real bus, committed as bytes and replayed by the peer, because a fake peer cannot prove the real registry's reply shape (`docs/13-atspi-protocol.md:1055-1059`) | `GetAddress` returns `unix:path=/run/user/33156/at-spi/bus`, the `.Accessibility` connection opens, `GetId` round-trips, `Introspect` returns XML, an error reply comes back byte for byte | the peer answers the auth handshake, `Hello`, and `Embed` with a fixed `(so)`, then drives `GetState`, `GetItems`, `DoAction`, a bad index, an unregistered path and `Introspect`, and captures `Cache.AddAccessible`, `Cache.RemoveAccessible`, `Event.Object.StateChanged`, `PropertyChange`, `ChildrenChanged`, `Event.Window.Activate` and `Event.Document.LoadComplete` | none | the `O_NONBLOCK` defect under a `std.Io` other than the two the probe used, and any goose version after v3.3.0 |
| M6 | the mapping tables: every AccessKit role and property onto its AT-SPI counterpart, both directions where both exist | `test/fixtures/tree_update/` bytes recorded through the Rust implementation, committed | `busctl` or `python3` with `dbus-next` reads `GetChildren`, `GetRole` and `GetState` off a registered node path | the fake peer drives `DoAction` and reaches the toolkit handler, and a call on a removed path returns `UnknownObject` | none | a screen reader. `at-spi2-registryd` and `at-spi2d` are absent, so a real client never reads this tree here |
| M7 | the COM base, `QueryInterface` on an IID, the HRESULT to error mapping, the provider table as data | `tests/simple.rs` 198 lines and `tests/subclassed.rs` 177 lines upstream become transcript replays, because they are scripts over a live provider | none | none | `zig build-obj -target x86_64-windows` against zigwin32 proves 18 functions and 14 interfaces exist, and `build-exe` links with `-luiautomationcore` and `-luser32` | everything. The adapter has never been executed. No Windows host and no Wine, so "works" is not a claim this machine can make |
| M8 | the AX value conversions, the focus ring, the subclass state machine | upstream has no recorded transcripts, so a transcript is captured on a Mac and committed | none | none | `zig build-obj -target aarch64-macos` compiles | linking. `-lobjc` and `-framework Foundation` both fail here. Nothing runs |
| M9 | the state machine above the Objective-C boundary | the record that crosses the FFI boundary is fuzzable. The boundary call is not (`docs/18-testing-strategy.md:955`) | none | none | `zig build-obj -target aarch64-ios` compiles | linking. `-libSystem` fails and the output is 0 bytes. Nothing runs |
| M10 | the same shape as M9, over JNI | the same | none | none | `zig build-obj -target aarch64-linux-android` compiles and `zig translate-c` parses `jni.h` | linking. `-llog` fails. No NDK and no APK here, so not even the `.so` |
| M11 | the facade's three-state machine: `Inactive`, `Pending`, `Active` | none | `set_root_window_bounds` and `update_window_focus_state` both reach the bus | none | none | the four non-AT-SPI paths, which need the same hosts as M7 to M10 |

### 4.1 The row that proves nothing here

The honest last column is not one row, it is four. **M7, M8, M9 and M10 each
prove exactly one thing on this machine: that the adapter names symbols that
exist.** M7 links its real system libraries, so it goes one step further and
proves the link line resolves. Nothing else about any of the four is
established, and a plan that says otherwise is describing a machine that is not
this one.

M6's last cell is narrower than it looks. The bus is live and the handshake and
the dispatch are real, but a screen reader is not installed, so the claim "a
screen reader can use this application" has no route here. It belongs in
`docs/50-verification.md` as open.

One more silence. **Nothing in M0 to M11 has been compiled.** No `zig build`, no
`zig build test`, no `zig build cross-test` and no `zig-gate` has run against
this repository for this plan. Every command above is one an agent would run.

---

## 5. Sequencing hazards

Eight things can go wrong in this order. Each names what to do about it before
the next milestone opens, not after.

### H1. The property table is generated by 27 macros, and a hand expansion is a review burden

`docs/23-core-boundary.md:789` records 27 `macro_rules!` definitions at
`accesskit/src/lib.rs:1170-1778`, plus 2 in `accesskit_consumer/src/text.rs:980`
and `:1215`, and that is the figure this plan uses. A count taken again for this
plan returns 23 over `lib.rs:1170-1778` and confirms the two in `text.rs`, so
the recorded 27 was not reproduced and the difference is left open. It does not
change what has to happen. The invocations run `lib.rs:1909-2546`. Under the
macros the property set is defined once. Under a hand expansion it is defined
in nine places, and a reviewer has to diff nine lists against one.

**What to do.** M1 expands the table once, by hand, into
`schema/props/*.zig`, and M1 is not done until a `comptime` sweep over
`@typeInfo` proves that every `PropertyId` tag has an accessor, that every
accessor appears in the table, and that the count is 105. That sweep is the
review. A `grep` count is not: it cannot tell an accessor that is unreachable
from one that is reachable twice.

**The trap.** If M1 lands the table without the sweep, M2 inherits a table
nobody reviewed, and the defect surfaces as a silently dropped property in an
adapter, three milestones later, where no test points at it.

### H2. The C ABI's data-carrying enums are unproven until a big-endian row runs

`ActionData` is `#[repr(C)]` at `lib.rs:3304-3305` and carries a payload:
`CustomAction(i32)`, `Value(Box<str>)`, `NumericValue(f64)`. A `#[repr(C)]`
Rust enum with data is a tag plus a union whose largest arm decides the size.
The Zig equivalent must match byte for byte, and no little-endian test can tell
a correct layout from a wrong one that happens to agree on x86_64.

**What to do.** M4 does not close until the C conformance program runs inside
the `powerpc64-linux` row of `cross-test`, not only on the host. `zig-gate
--no-cross` is not an acceptable substitute for that milestone, and a milestone
that reports "the ABI test passes" without saying which architecture it passed
on has not reported anything.

### H3. A tree that lands before a fixture can be self-consistent and wrong

A tree store, its iterators and its text queries are 9661 upstream lines. A
port of them will pass its own tests and be wrong in the same way its author
was wrong.

**What to do.** The conformance fixture set of
`docs/15-tree-semantics.md:1433-1444` lands in M2, and it lands **before** the
consumer modules it constrains, not after. The fixtures are hand-authored from
`docs/15-tree-semantics.md` sections 1 and 2, which carry a `path:line` for
every role name, every property name and every property type, so a reviewer can
check a fixture by reading rather than by running
(`docs/15-tree-semantics.md:1466-1471`). A fixture recorded from the port's own
output proves only that the port agrees with itself.

### H4. A goose patch that silently stops applying

M5 needs four lines inside goose. If the carrier is a build step that edits the
fetched tree, a goose update that moves the line can leave the patch unapplied
and the tree compiling.

**What to do.** The build step must fail loudly when the patch does not apply,
naming the goose line it looked for. It must not warn. And M6 must not open
until M5 has run twice: once on a warm cache, where the patch is already
applied, and once on a cold cache, where it is not. A warm-cache pass proves
nothing about the carrier.

### H5. The adapter lands before the application can drive it

`set_root_window_bounds` at `adapters/unix/src/adapter.rs:172` and
`update_window_focus_state` at `:222` are application calls. M11 supplies them.
Between M6 and M11 no application exists.

**What to do.** M6's live-bus harness supplies both values itself, from a test
fixture. That is correct for M6 and wrong for M11: the harness must be the only
thing that supplies them, and M11's gate must prove the facade supplies them
when the harness is gone. Otherwise M11 lands with a green gate and nothing
exercises it.

### H6. Two adapters disagree about what a role means

The three platform mappings disagree. Upstream has no reverse role tables, so a
port that reads a native tree would need 182 entries per platform
(`docs/15-tree-semantics.md:1495`).

**What to do.** Every adapter maps AccessKit onto its native API, in one
direction only, exactly as upstream does. A reverse table is not scheduled and
is not wanted. A milestone that adds one is adding a feature nobody asked for.

### H7. The matrix rows are added before there is anything to catch

M0 adds `riscv64-linux`, `loongarch64-linux` and `x86-linux`. At M0 there is
one probe module, so the new rows prove only that the rows run.

**What to do.** The rows stay, and every milestone after M0 re-runs them. M1 is
the first milestone that gives the big-endian row something to catch, and M1's
gate is not satisfied until the layout test runs there.

### H8. The package drops the fixtures

`build.zig.zon:36-43` lists `build.zig`, `build.zig.zon`, `src`, `docs`,
`README.md` and `AGENTS.md`. It does not list `test/`. A
dependency that fetches this package therefore gets no fixtures, and every
conformance test skips silently rather than failing.

**What to do.** M0 adds `test`, `include` and `third_party` to `.paths`, and M2
adds a check that a packaged build still contains
`test/fixtures/manifest.json`. A missing fixture must be a build failure, which
is what `@embedFile` gives for free
(`docs/18-testing-strategy.md:858`).

---

## 6. What is blocked, and on what

Ten items. Four of them block a milestone. Six bound a claim.

| # | Blocker | Evidence | What unblocks it | Who acts |
|---|---|---|---|---|
| 1 | `-ffuzz` does not compile on Zig 0.16.0 | `lib/compiler/test_runner.zig:566:55: error: expected type '*const debug.StackTrace', found '*builtin.StackTrace'`, then `note: pointer type child 'builtin.StackTrace' cannot cast into pointer type child 'debug.StackTrace'`. `std.debug.writeStackTrace` takes `*const debug.StackTrace` at `lib/std/debug.zig:824` and `@errorReturnTrace()` returns `*builtin.StackTrace` at `lib/std/builtin.zig:11`, and the runner passes one to the other with no cast at `lib/compiler/test_runner.zig:565-567`. The path is reachable only under `builtin.fuzz`. Runtime observation, `docs/22-zig-build-surface.md:1919-1932` | A Zig release in which the two `StackTrace` types agree. No issue link is recorded for this defect in any document under `docs/`, so this plan names none rather than guess one. Until then the substitute is corpus replay inside a plain `zig build test`, which reports `N fuzz tests found` and is replay, not mutation (`docs/22-zig-build-surface.md:1956-1959`) | the Zig project |
| 2 | goose leaves a socket non-blocking and folds `EAGAIN` into `error.ReadFailed` | zio opens sockets non-blocking at `zio/src/net.zig:912`, `fcntl F_GETFL` returns `0x802` against `0x2` for a default `std.Io`, and goose's `recvWithIovecs` calls raw `recvmsg` at `connection.zig:221` and maps `EAGAIN` at `:188-190`. Runtime observation, `docs/26-goose-live-bus-probe.md:657-668` | An upstream goose change that clears `O_NONBLOCK` after `connect` at `connection.zig:514`. The four lines are at `docs/26-goose-live-bus-probe.md:675-681`. Failing that, the checked-in patch carrier this plan recommends for M5. `docs/26-goose-live-bus-probe.md:879-883` names the risk that the author declines | the goose author, or this project at M5 |
| 3 | zio does not re-export `fromRuntime` | `zio.zig:101` re-exports only `debug_io`, and adding `src/io.zig` as a second module fails with `error: file exists in modules 'zio_io' and 'zio'`, notes at `lib`-relative `zio.zig:1:1` and `zio.zig:101:30`. The functions exist at `zio/src/io.zig:138` and `:146`. Runtime observation, `docs/26-goose-live-bus-probe.md:616-632` | Three lines in `zio.zig` re-exporting `fromRuntime`, `toRuntime` and `Mode` (`docs/26-goose-live-bus-probe.md:638-641`, `:851-852`). Failing that, a bridge module inside this project that reaches `io.zig` by path | the zio author, or this project at M5 |
| 4 | `-femit-h` is broken on Zig 0.16.0 | `error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698`, with the call commented out at `lib/std/Build/Step/InstallArtifact.zig:123-124`. Runtime observation, `docs/22-zig-build-surface.md:715`, `:720-727` | Not needed. The header is checked in and installed with `Step.Compile.installHeader`. Recorded so nobody re-derives the workaround | nobody |
| 5 | The X11 extension headers are absent | `XTest.h`, `Xfixes.h`, `XInput2.h` and `xkbcommon.h` are absent while the runtime libraries are present. `docs/27-x11-headers-resolution.md:144-146` records that the Nix sandbox store on this host supplies all four and no root was needed, so the headers are obtainable | It does not matter to this plan. Upstream ships no X11 adapter to port, so no milestone needs them. This item bounds any future X11 work only | nobody, unless an X11 path is asked for |
| 6 | No macOS SDK, no iOS SDK, no Android NDK | `zig build-exe -target aarch64-macos -lobjc` fails, `-framework Foundation` fails, `zig build-exe -target aarch64-ios` fails with `unable to find libSystem system library` and a 0-byte output, and `zig build-exe -target aarch64-linux-android -llog -lc` fails. Exercised compilation, `docs/16-native-platform-apis.md:1780-1783` | A macOS host for M8, a Mac with the iOS SDK for M9, an Android host with the NDK for M10. `zig build-obj` works for all three here, so M8, M9 and M10 are not blocked, they are limited | whoever owns the CI or the hardware |
| 7 | No Windows host and no Wine | `which wine` returns nothing. `docs/16-native-platform-apis.md:1788`. `zig build-exe -target x86_64-windows` does link, with `-luiautomationcore` and with `-luser32` (`docs/16-native-platform-apis.md:1776-1778`, exercised compilation) | A Windows host, or a Windows runner in CI. M7 is not blocked, it is limited to compile-only | whoever owns the CI |
| 8 | No assistive technology on this bus | `at-spi2-registryd` and `at-spi2d` are not installed, and only `at-spi-bus-launcher` is (`docs/12-accesskit-adapters.md:1460`). Six seconds of idle on the live bus gave zero emissions, though both `AddMatch` calls succeeded (`docs/26-goose-live-bus-probe.md:354-359`) | A desktop session with a screen reader. Until then M6 proves the bus, not the reader, and the reader claim stays open in `docs/50-verification.md` | whoever tests on a desktop |
| 9 | Zig 0.16.0 ships no `std.com` | A listing of `lib/std` has no `com.zig` (`docs/16-native-platform-apis.md:1530-1535`). zigwin32 gives types and extern declarations, not an object factory | Nothing unblocks it. The Windows COM object base, about 120 lines, is port-owned work inside M7 | nobody |
| 10 | Declaring the `zigwin32` pin turns two `cross-test` rows red | `std.builtin.CallingConvention.winapi` is defined by CPU architecture alone at `lib/std/builtin.zig:132-138`: `x86_64`, `x86`, `aarch64` and `thumb` have values and every other architecture reaches `else => unreachable`. `bindings.zig` carries `callconv(.winapi)` in its vtable fields, so `aarch64-linux` fails with `error: calling convention 'aarch64_aapcs_win' not supported by compiler backend 'stage2_llvm'` and `powerpc64-linux` fails with `error: reached unreachable code`. Both rows are in `cross-test.profile.sh:38-42` and `CROSS_REQUIRE_RUNNERS=1` is set. Exercised compilation against the pinned commit, `docs/42-native-adapter-build-map.md` section 2.1.5 | Adoptable, not adopted, and the blocker is not the absence of the package. Scope the tests that read a `VTable` to an architecture where `.winapi` resolves, fix the three files that do not compile, then take the pin. The `.hash` `build.zig.zon` needs comes from one `zig build` run | this project at M7 |

---

## 7. What this plan deliberately does not schedule

Each omission has a reason and a re-entry condition. A re-entry condition says
what would have to change for the item to become worth scheduling.

| Not scheduled | Why | Re-entry condition |
|---|---|---|
| An X11 adapter | Upstream ships none. `adapters/unix/src/` contains zero X11, XCB and Wayland code: the only match for `xcb\|wayland\|X11\|xlib\|xkb\|wl_` over the adapter and its manifest is a doc comment at `adapters/unix/src/adapter.rs:172` (`docs/12-accesskit-adapters.md:74-80`) | Someone asks for window bounds and focus that the application cannot supply. That is new work with no upstream to translate, and `docs/27-x11-headers-resolution.md` says the headers are obtainable from the Nix sandbox store |
| A Wayland adapter | The same finding, same line. Under Wayland an application cannot get its window position, which is why the doc comment at `adapter.rs:172` says `set_root_window_bounds` only makes sense under X11 | The same condition. A compositor protocol would have to be named first |
| Fuzzing | Mutation is not scheduled, and that part still holds: `-ffuzz` does not compile on Zig 0.16.0, so a mutating step cannot be built (`docs/22-zig-build-surface.md:1940-1944`). A replay step was built anyway. `build.zig:156` declares `fuzz` and replays the committed corpus in `test/fuzz/corpus/` through `std.testing.fuzz`, and `build.zig:140-142` says in its own comment that this is replay and not mutation | A Zig release where `zig test -ffuzz` compiles. The corpus and the targets in `docs/18-testing-strategy.md:637-680` are then scheduled unchanged, and the milestone plan gains two gate lines: the required replay already in the graph, and a bounded nightly mutation |
| An `accesskit_winit` equivalent | `docs/12-accesskit-adapters.md:861-863` argues it is a toolkit bridge, not a platform adapter, and that reproducing it means writing a winit clone. This port targets platform adapters | A Zig windowing library appears that the port can bind to. Until then a bridge would be a second project |
| A coverage gate | `zig-cov` is off unless `--cov` is passed, and `build.zig` has no coverage wiring, so stage 10 skips itself (`docs/18-testing-strategy.md:983-991`). There is no branch metric at all (`:993-1006`) | Someone wires `zig-cov` into `build.zig` and sets `ZIG_COV_FAIL_UNDER`. Until then no milestone writes a percentage |
| `ReleaseFast` and `ReleaseSmall` builds | `build.zig:74-94` runs Debug and ReleaseSafe because the gate runs a plain `zig build test` with no `-Doptimize`. `AGENTS.md:296-297` names a green gate as no proof of the other two modes | The gate gains a stage that runs them, or a milestone needs a performance claim |
| A multi-threaded executor for D-Bus calls | goose's `Connection` methods are synchronous (`connection.zig:1080` for `methodCall`), and every D-Bus call blocks its executor (`docs/26-goose-live-bus-probe.md:702-704`, runtime observation). Upstream's handlers are synchronous and short | A call is measured blocking long enough to matter. Then a bounded worker pool is scheduled, not a general executor |
| Byte compatibility with upstream's C header | The upstream header has six recorded ABI breaks, the most recent 0.18.0 on 2025-12-10 (`docs/11-accesskit-c-abi.md`, R14). The two crates also version independently: macos 0.27.1, windows 0.35.1, unix 0.24.0, android 0.9.0, ios 0.2.1 | Never, for the header upstream ships. `docs/31-c-abi-design.md` states which breaks the port adopts and which it declines |
| Bindings for languages other than C | The port targets a C ABI because that is what upstream's adapters consume, and a C caller cannot register a platform of its own because no vtable exists (`docs/11-accesskit-c-abi.md`, R13). Adding a second binding is a second surface to keep in step | A consumer appears that cannot link C. A `translate-c` binding over the port's own header is then a rung-3 addition, not a redesign |
| Reverse role tables, 182 per platform | Upstream has none (`docs/15-tree-semantics.md:1495`). The adapters map AccessKit onto the native API in one direction | A port that reads a native tree instead of publishing one. Nothing in this plan does that |
