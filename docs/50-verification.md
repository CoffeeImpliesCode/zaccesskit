# 50 — Verification record

It consumes the research corpus below and the house gate script, and it is
consumed by `docs/40-plan.md`, which turns sections 3, 4 and 7 into milestone
gates, and by any reviewer who must decide whether a claim about this port is
evidence.

The corpus it reads: `docs/10`, `docs/11`, `docs/13`, `docs/15`, `docs/18`,
`docs/19`, `docs/20`, `docs/22`, `docs/23`, `docs/25`, `docs/26`,
`local://zaccesskit-risk-register.md`, `local://zaccesskit-deps.md`, this
repository's `build.zig`, `src/root.zig` and `cross-test.profile.sh`, and
`~/.local/bin/zig-gate`.

Sections 3–7 retain the original verification design and research-era observations.
Their host-absence and empty-registry statements describe those earlier receipts, not the latest host state.
Their acceptance requirements remain in force.
Section 11 records the current source, portable, and real-peer limits.

---

## 1. The proof vocabulary

### 1.1 The three labels

Every claim in this repository carries one of three labels. A claim with no label
is a claim about nothing.

| Label | Short form | What it is | What produced one |
|-------|------------|------------|-------------------|
| **Source reading at a pinned revision** | SR | A statement read out of a file at a named commit, quoted with `path:line`. | Reading `/tmp/scratch/accesskit` at `466e24e252103f4d82bd6fbab98141b551e46e0c`, `/tmp/scratch/accesskit-c` at `8b6ed37c20ed4c59390e253407983333053662ba`, `zio` at `2662fdc45997611b962b560c513c16963475a01b`, `goose` at tag `v3.3.0` commit `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1`, and the Zig 0.16.0 standard library under the pinned toolchain cache. |
| **Exercised compilation** | EC | A statement about what the compiler accepted or rejected, with the command and its output. | Running `zig build`, `zig build test`, `zig build-obj`, `zig build-exe`, `zig fetch` or `zig-gate` under Zig 0.16.0 and recording the output. |
| **Runtime observation** | RO | A statement about what a running program did, with the transcript. | Running the program and capturing stdout, stderr and the exit status. |

The labels are not interchangeable. An SR claim about `zig` never becomes an EC
claim because the toolchain is installed. An EC claim that a file compiles never
becomes an RO claim because a test binary exists.

### 1.2 What each label does not establish

| Label | Does not establish |
|-------|--------------------|
| SR | That the code runs. That the reading is complete. That the surrounding code does not change the meaning of the quoted lines. That the pinned revision is the one a consumer will use. |
| EC | That the program does the right thing. That the assertion inside a passing test is meaningful. That a file no build step names was checked at all. That a green gate says anything about behaviour. Section 2.2 lists the eight cases. |
| RO | That the result generalises. That the transcript was not cherry-picked. That the same code on another host, another endianness, or another bus behaves the same way. |

### 1.3 How to read the repository state

Sections 2 through 5 preserve the original verification design.
Their unproven labels describe that design record, not the current source.
Sections 6 through 9 record earlier port checks and corrections.
Section 10 records earlier API integration work and its observed checks.
Section 11 records steps 1–4. Later evidence supersedes earlier counts only for the same named check.

The research probes remain separate from port checks.
The goose live-bus probe ran in a separate scratch package.
The geometry probes and platform compile matrix also used separate programs.
A probe result does not prove this package's native platform behavior.

---

## 2. What the house gate does and does not prove

The gate is one script: `~/.local/bin/zig-gate`, 823
lines. It keeps one variable, `fail`, declared at `zig-gate:366`. Exit 0 is a
pass, exit 1 is findings, exit 2 is a usage or environment error
(`zig-gate:4`). The run ends at `zig-gate:817-823`.

### 2.1 The ten stages, in order

| # | Stage | Script lines | Exact command | Required | What a failure looks like |
|---|-------|--------------|---------------|----------|--------------------------|
| 1 | fmt | `zig-gate:424-436` | `"$ZIG" fmt --check $fmt_files` (`:429`) | required | `fmt: N file(s) need formatting`, then the diff, `fail=1` (`:432-435`) |
| 2 | build | `zig-gate:438-446` | `zig_build` (`:440`), which expands to `"$ZIG" build --cache-dir <d> --global-cache-dir <d>` (`:358-364`, `:352-356`) | required | `build: FAILED` then `tail -30` of the log (`:443-445`) |
| 3 | test | `zig-gate:448-458` | `zig_build test` (`:450`), which expands to `zig build test --cache-dir <d> --global-cache-dir <d>` | required | `test: FAILED` then `tail -30` (`:455-457`) |
| 4 | ast-check | `zig-gate:460-475` | `"$ZIG" ast-check "$f"`, once per file (`:464`) | required | `AST error in <file>`, then the compiler message (`:465-467`), `fail=1` (`:474`) |
| 5 | ziglint | `zig-gate:477-496` | `"$ZIGLINT" $ZIGLINT_ARGS $(files)` (`:483`) | required | `found N issue(s), exit S`, a per-rule histogram, then the sample (`:489-494`) |
| 6 | zlint | `zig-gate:498-527` | `files \| "$ZLINT" -S $ZLINT_ARGS` (`:504`) | required | `found N issue(s), exit S`, counted from zlint's own summary sentence (`:509-515`) |
| 7 | zbc | `zig-gate:529-555` | `"$ZBC" $(files)` (`:537`) | advisory | `zbc: N error(s), M warning(s) (advisory), exit S` (`:544`); `fail=1` only when errors are present, or `ZBC_STRICT=1`, or the exit status is above 1 (`:549-552`) |
| 8 | zwanzig | `zig-gate:557-658` | `"$ZWANZIG" $ZWANZIG_ARGS $zw_files` (`:584`) | required | every finding asserted and printed with `(asserted)` (`:641-654`); five analyser self-checks fail the stage before the class policy runs (`:621-632`) |
| 9 | cross-test | `zig-gate:660-786` | `"$CROSS_TEST" --output "$GATE_CROSS_OUTPUT" $CROSS_TEST_ARGS` (`:709-710`) | required | `status=fail` or `status=incomplete` classified against the per-target build logs as a budget problem or a real assertion (`:745-766`) |
| 10 | zig-cov | `zig-gate:788-815` | `"$ZIG_COV" test --exclude=zig-pkg --exclude=vk.zig` (`:795-799`) | advisory, opt-in | `coverage: FAILED (advisory)` (`:810`); `fail=1` only under `ZIG_COV_FAIL_UNDER` (`:812`) |

Six stages have no switch: 1, 2, 3, 4, 5 and 6. Four do: `--no-zbc` (`:531`),
`--no-zwanzig` (`:572`), `--no-cross` (`:698`) and `--cov` (`:790`).

### 2.2 The eight things a green gate does not prove

**1. It ran no coverage at all.** `use_cov=false` is set at `zig-gate:12`.
`--cov` sets it at `:18` and the block is guarded at `:790`, so a bare `zig-gate`
never reaches it. Even when it runs, the metric is line coverage and `fail=1`
needs `ZIG_COV_FAIL_UNDER` (`:812`). A green gate is compatible with a project
that has never measured anything.

**2. There is no fuzz stage.** The help text lists ten sections at
`zig-gate:23-33` and none of them is one. `zig build fuzz` is a project step
that the gate never calls. On this toolchain it could not work anyway:
`-ffuzz` fails to compile `lib/compiler/test_runner.zig:565-567`
(`docs/22` §9.7).

**3. The analysers are bounded by the file list the gate finds.** `files()` is
`find . -name '*.zig'` minus `vk.zig`, minus five path patterns, minus every
`GATE_EXCLUDE` pattern (`zig-gate:409-422`, default at `:406-408`). fmt,
ast-check, ziglint, zlint, zbc and zwanzig all read that one list, zwanzig at
`:584`. A Zig file outside those paths is not formatted, not parsed and not
analysed. The comment at `zig-gate:560-568` records why the list is passed
explicitly: a directory argument makes the finding count a function of build
state, because zwanzig then reads Zig's own `builtin.zig` copies out of the
cache.

**4. A stage removed by a flag prints nothing at all.** `--no-zwanzig` takes the
branch `if ! $use_zwanzig; then` followed by a bare `:` at `zig-gate:572-573`,
so no line, no count and no `skipped` marker reaches the log. `--no-zbc`
(`:531`), `--no-cross` (`:698`) and an absent `--cov` (`:790`) have no `else`
either. A reader of a green log cannot tell an absent stage from a passing one.

**5. `zig build` type-checks only what the build graph reaches.** Stage 2 runs
`zig build` (`zig-gate:440`). A `.zig` file that no step names is never
compiled. Stage 4 parses it (`zig ast-check`, `zig-gate:464`) but parses and
type-checks are different operations, so a file with a type error that nothing
imports passes both stages. The analysers in stages 5 to 8 read the file, but a
linter is not a type checker.

**6. Zero tests is a green stage.** Stage 3 skips silently when the log contains
`no step named 'test'` (`zig-gate:452-453`), and a `test` step that exists and
executes nothing exits 0. `docs/18` §8 G1 exists to close this, and
`ozai/build.zig:56-65` records the same trap in another project.

**7. A foreign target with no runner reads green.** `zig-gate:771-783` accepts
`status=pass`, `status=partial` and `status=build_only` with `fail=0`. The
comment at `:669-674` records that `x86_64-windows` has no runner on this host,
so cross-test records it `build_only` and deliberately never counts it as a
pass, and that `--require-runners` is not passed. `cross-test.profile.sh:46`
sets `CROSS_REQUIRE_RUNNERS=1`, so the three rows the profile names are
execution-covered. A row added to the profile later without a runner degrades
to compile-only and still reads green.

**8. It knows nothing about this port.** The ten stages are formatting,
compilation, the project's own tests, three static analysers, a coverage number
and a foreign matrix. Not one of them knows what a `TreeUpdate` is. None
measures the update protocol, the property table, the C ABI against a C
compiler, or the AT-SPI wire. A package of empty modules produces the correct
output for that input.

### 2.3 What a green gate does prove

State the positive side, so the negative list is not read as a refusal of the
gate. A green gate proves all of the following, and only the following.

| It proves | It does not prove |
|----------|------------------|
| Every file in `files()` is formatted | That any file exists |
| `zig build` exits 0 for the declared graph | That a file no step names was compiled |
| The declared `test` step exits 0 | That any test ran inside it |
| Every file in `files()` parses | That any file type-checks |
| ziglint reports zero findings | Anything about behaviour |
| zlint reports zero errors and zero warnings | Anything about behaviour |
| zwanzig reports zero findings and passed its own five self-checks | That zwanzig was run at all, if `--no-zwanzig` was passed |
| Every target in `./cross-test.profile.sh` built | That every target ran |

That is a real result and it is worth having. It is not a result about
AccessKit.

### 2.4 How a reviewer reads a gate log

Four checks, in this order, before reading a green `GATE PASSED` as evidence
about this port.

1. **Count the stage headers.** The log prints one `== <stage> ==` line per
   stage, from `step()` at `zig-gate:367`. A run with `--no-zwanzig` prints nine
   headers instead of ten and says nothing about the tenth.
2. **Read the `test:` line, not the exit status.** `test: OK` at
   `zig-gate:451` means the step exited 0. It does not mean a test ran. The
   number of tests is in the `--summary all` output, which the gate does not
   pass. `docs/18` §8 G1 is the milestone item that closes this.
3. **Read the cross-test status word.** `cross-test: OK (status=partial, fail=0
   ...)` at `zig-gate:778-780` is the normal clean result on this host, and the
   parenthetical says why. `status=pass` means every row had a runner.
4. **Check the file list is the one you expect.** Stages 1 and 4 to 8 all read
   `files()` (`zig-gate:409-422`), and `GATE_EXCLUDE` shrinks it silently. A
   project that sets `GATE_EXCLUDE` to something wide has fewer files analysed
   than it has files.

---

## 3. The verification layers

Five layers, in increasing cost and decreasing reach. Each has a route, a claim
it supports, and a claim it cannot support. `docs/40-plan.md` schedules them in
this order for that reason.

### 3.1 Layer 1 — pure unit tests over the tree, the protocol and the tables

**Route.** A `test` block inside each source file, reached through a shard. The
shard convention is at `docs/18` §2.2: one `addTest` module per shard, every
shard file is `src/shard_<area>.zig`, and each shard reaches its own group with
`refAllDecls`. `build.zig:52-71` already runs `src/root.zig` as the Debug shard
and as a private ReleaseSafe equivalent. `zig-gate` stage 3 runs them
(`zig-gate:450`).

**Proves.** Value-level behaviour of the platform-neutral half with no I/O, no
clock and no global state. That is the shape upstream's core crate already has:
`accesskit/src/` names no platform and imports no runtime
(`docs/23` §2.1, §2.2). Every assertion compares a result against a value read
from a source line or a recorded byte vector.

**Does not prove.** That the bytes upstream produces decode into those values.
That is layer 2. It does not prove that any platform produces the events that
enter the tree either. That is layers 3 and 4.

**The assertions this layer must carry**, each with its source:

| Assertion | Source |
|-----------|--------|
| Each of the 13 `UpdateError` variants is returned by a named call site | `docs/10` §4.6, the panic-to-error table |
| `validate_global` returns `error.RootMissing` then `error.FocusMissing`, in that order | `docs/10` §4.12, `accesskit_consumer/src/tree.rs:85-96` |
| The invariant after each block of the update algorithm | `docs/10` §4.5, 18 rows |
| `Rect{-10,-20,30,40}.contains(30, 40) == false`; the far edge is exclusive | `docs/19` §7.1 |
| `Rect{5,7,5,7}.contains(5, 7) == false`; a zero-area rectangle contains no point | `docs/19` §7.2 |
| `Rect{80,60,20,10}.width() == -60` and `area() == 3000` | `docs/19` §7.3 |
| `Affine.scale(2) * Affine.translate(1,1)` applied to `(1,1)` is `(4,4)`; the reverse product is `(3,3)` | `docs/19` §7.6 |
| `Role` has 182 variants in upstream order; `Action` has 22 numbered 0 to 21 and `actionFromInt(22)` returns null; `PropertyId` has 87 and `Unset == 87`; `Flag` has 18 | `docs/10` §9.4, `accesskit/src/lib.rs:274-350`, test at `:3482-3509` |
| Two nodes with the same properties compare equal whatever order they were set in | `accesskit/src/lib.rs:3392-3405` |
| A cleared property equals one never set | `accesskit/src/lib.rs:3407-3414` |

The last two are upstream's own tests. Transcribed rather than invented, which is
what makes them evidence.

### 3.2 Layer 2 — recorded fixtures

**Route.** `zig build reference` runs `reference_root.zig` in Debug and ReleaseSafe.
`zig build reference-run -Doptimize=ReleaseSafe` runs the standalone fixture loader.
It reads `test/fixtures/manifest.json`, `geometry.json`, and `text.json`.

**Provenance.** The manifest pins core revision `466e24e252103f4d82bd6fbab98141b551e46e0c`.
The cases record upstream paths and source test locations.
These are finite, hand-recorded source oracles.
Hand-computed expected values are `[INFERENCE]`, not Rust runtime output.

**Integrity.** The loader checks raw byte length and SHA-256 before it parses each body.
It then checks case identity, provenance, and exact production output.
The current geometry body contains seven cases. The text body contains eight cases.
Sections 10 and 11 distinguish the earlier twelve-case receipts from the current fifteen-case source inventory.

**Proves when exercised.** The checked Zig operations match the stored expected results for that receipt.
The integrity checks detect changed fixture bytes.

**Does not prove.** The loader does not execute Rust.
It does not prove wire-byte parity, serde compatibility, or equivalence for unrecorded inputs.
An upstream pin states provenance. It does not turn a hand-recorded value into runtime evidence.

### 3.3 Layer 3 — the live AT-SPI bus on this host

**Route.** Two steps, in this order. Open a session connection, call
`org.a11y.Bus.GetAddress` at `/org/a11y/bus`, decode the returned `s`. Put it in
the `Environ.Map` under `AT_SPI_BUS_ADDRESS`, then open the `.Accessibility`
connection. goose reads that variable at `connection.zig:493-501`. The address
on this host is `unix:path=/run/user/33156/at-spi/bus` (`docs/26` §0, §3).

**What a round trip proves.** The SASL handshake, the framing, the serialisation,
the method dispatch and the error-reply path against a real daemon and a real
registry. Concretely, `docs/26` §5 observed: `GetChildren` at
`/org/a11y/atspi/null` returned `message_type=Error` with `ERROR_NAME =
org.freedesktop.DBus.Error.UnknownMethod`, byte for byte as `busctl` did;
`GetRegisteredEvents` at `/org/a11y/atspi/registry` returned signature `a(ss)`;
and `Introspect` returned the registry XML with three methods and two signals.
It also proves the defect that matters most for the port: `methodCall` returns
a D-Bus error as a **value**, not as a Zig error, so the port must check
`message_type` itself (`docs/26` §5).

**What an empty-tree reply does not prove.** `GetRegisteredEvents` returned
eight zero bytes, which is an empty `a(ss)`: the four-byte length plus four
bytes of alignment padding (`docs/26` §5). `busctl tree` on the same bus shows
three paths and nothing else: `/org/a11y/atspi/accessible/root`,
`/org/a11y/atspi/cache` and `/org/a11y/atspi/registry` (`docs/26` §5). So the
empty reply proves the registry is reachable and that **no AT-SPI application is
on this bus**. It proves nothing about decoding a populated `Accessible`,
`Action`, `Component` or `Text` reply, because no populated reply exists here to
decode. An empty tree is the success case for the call and no evidence for the
adapter.

**Also unproven by this layer.** That a real accessibility client can drive the
port's exported objects. No such client exists on this host.

### 3.4 Layer 4 — a synthetic D-Bus peer

**Why it is necessary, not convenient.** Six seconds of idle on the live bus
produced `signal_hits = 0`, although both `AddMatch` calls returned without
error (`docs/26` §4). `AddMatch` is `connection.zig:1064-1077` and it ignores the
reply body, so a rejected match rule is silent. The zero is not a defect in the
subscription; there is simply nothing on the bus that emits an
`org.a11y.atspi.Event.Object` signal.

Delivery was proven twice on the live bus, and both proofs are narrow. The
registry emits `EventListenerDeregistered` whenever a client leaves, so a
second probe process connecting and exiting produced one hit with body
`:1.53` and an empty string (`docs/26` §4). A synthetic peer owning a name and
sending a hand-built `Signal` message produced one hit
(`docs/26` §4). **Neither carried a real event body.** Every
`org.a11y.atspi.Event.Object` signal has the five-argument signature
`siiva{sv}`; the probe sent an empty body (`docs/26` §4). It also named a
member that the interface does not declare, so the hit proved delivery
only.

**Route.** Two of them, and `docs/13` §8.1 and §8.2 recommend both.

| Route | What it is | What it needs |
|-------|------------|---------------|
| Private daemon | `dbus-daemon --nofork --print-address=3 --address="unix:path=$sock" 3>address.txt &` with `AT_SPI_BUS_ADDRESS="unix:path=$sock"`, per `docs/13` §8.1. `dbus-daemon` and `dbus-broker` are both present at `/bin` (`docs/13` §8.1). | A real daemon, so `Hello`, the handshake and framing are exercised against one. `Embed` needs a stub responder, because the daemon has no registry. |
| Zig test peer | Bind an `AF_UNIX` listener, point `AT_SPI_BUS_ADDRESS` at it, and speak the protocol from the test process, per `docs/13` §8.2. It must answer the auth handshake, `Hello`, and `Embed`, and nothing else. | No external binary, so it runs in a container and in CI, and it is deterministic because the peer controls both directions. |

The environment variable is the seam, because goose has no already-connected
socket entry: `Connection.init` and `initWithBackend` both resolve an address
and connect themselves (`goose/src/connection.zig:469-518`). Both routes need
the same missing piece, a full D-Bus address parser that also handles
`unix:abstract=` (`docs/13` §8.5, and risk R1 gap G4).

**Proves.** Match rules, handler registration, signal demultiplexing, the
`sendSignal` construction, and marshalling, against a peer whose expected byte
strings are golden vectors. It also proves the interface registration and
removal path, which is the one goose does not have: upstream registers ten
interfaces per node and removes them when a subtree dies
(`adapters/unix/src/atspi/bus.rs:83,94,106,188,250`), and the port's own object
register and remove path is about 250 lines (`docs/17` §5).

**Does not prove.** That a real registry emits these messages. That a real
daemon routes them the same way. That the real `Embed` reply has the shape the
port expects, which `docs/13` §8.2 says to fix with one recorded reply
captured by `busctl` and committed as bytes.

### 3.5 Layer 5 — the cross-test matrix

**Route.** `zig-gate` stage 9 (`zig-gate:660-786`) runs `cross-test`, narrowed
by `./cross-test.profile.sh`. The profile sets `CROSS_BUILD_STEP=cross-test`
(`cross-test.profile.sh:20`), three rows (`:38-42`) and
`CROSS_REQUIRE_RUNNERS=1` (`:46`).

| Row | What it is |
|-----|------------|
| `x86_64-linux` | The host target, so a matrix gap can never hide a native break (`cross-test.profile.sh:26`) |
| `aarch64-linux` | Foreign 64-bit little-endian, the common embedded and phone ABI, with the best qemu_user support (`:27-28`) |
| `powerpc64-linux` | Foreign 64-bit **big-endian** (`:29-33`) |

**What it proves.** The same test binary, compiled for a foreign target and
executed under qemu_user, reaches the same assertions. For the three byte
layouts — tree serialisation, action-channel marshalling and the C ABI structs —
the big-endian row is the **only** execution proof that they are correct,
because a little-endian host cannot distinguish a correct byte order from a
consistently wrong one. `docs/25` §1.4 item 8 makes the same point from the
other side: a `size_t` in a public struct means a snapshot that follows the
host pointer width is not a snapshot.

**Does not prove.** Any calling convention the row does not exercise. macOS,
iOS, Android and Windows rows do not exist: `zig build-exe -target
aarch64-macos` fails at `-lobjc`, `-target aarch64-ios` fails on `libSystem`, and
`-target aarch64-linux-android` fails at `-llog` (`docs/16:1771-1788`). The C
half will need one row per system library it links
(`cross-test.profile.sh:56-59`).

### 3.6 The five layers in one table

Use this table to pick a layer for a claim. It is the same content as sections
3.1 to 3.5, compressed, so a reviewer can check the choice without reading
five subsections.

| Layer | Proves | Cannot prove | Route |
|-------|--------|--------------|-------|
| 1. Pure unit tests | Value-level behaviour of the tree, the update protocol and the property tables, with no I/O, no clock and no global state | That the bytes upstream produces decode into those values; that any platform produces the events | A `test` block per file, reached through a shard (`docs/18` §2.2); `zig-gate` stage 3 |
| 2. Recorded fixtures | That the port decodes bytes captured from upstream at a named commit, and re-encodes to them | That upstream still produces them; that unrecorded inputs work; that a re-recording is upstream truth | `test/fixtures/manifest.json` plus `.bin` and `.meta.json` pairs, hashed with SHA-256 (`docs/18` §5.2) |
| 3. The live AT-SPI bus | The handshake, framing, dispatch and the error-reply path against a real daemon and a real registry | Anything about a populated tree reply, because no AT-SPI application is on this bus | `GetAddress` on the session bus, then `AT_SPI_BUS_ADDRESS` in the `Environ.Map`, then the `.Accessibility` connection (`docs/26` §3) |
| 4. A synthetic D-Bus peer | Match rules, handler registration, demultiplexing, signal construction and the register/remove path, against golden byte strings | That a real registry emits these messages; that the real daemon routes them the same way | A private `dbus-daemon` on a filesystem socket (`docs/13` §8.1) or a Zig peer over one (`:8.2`) |
| 5. The cross-test matrix | The same assertions on a foreign ABI, and, on `powerpc64-linux`, that the three byte layouts are written correctly | Any convention the row does not exercise; any non-Linux platform | `zig-gate` stage 9, narrowed by `./cross-test.profile.sh` (`zig-gate:660-786`) |


---

## 4. Per area: what proves it

Eight areas. Each row names the test, the exact assertion, what a failure means,
and the proof label the claim carries **today**.

Read the last column literally. A row marked SR means the expectation was read
from a source line and the port code that would satisfy it does not exist yet.
No row in this table is EC or RO inside `src/`, for the reason in section 1.3.

| Area | The test | The exact assertion | What a failure would mean | Proof label today |
|------|----------|---------------------|---------------------------|--------------------|
| **The geometry layouts** | A `comptime` layout test in the geometry types module, plus the five recorded vector cases from `docs/19` §7 as ordinary unit tests. | `@sizeOf(Affine) == 48`, `@sizeOf(Rect) == 32`, `@sizeOf(Point) == @sizeOf(Size) == @sizeOf(Vec2) == 16`, `@sizeOf(OptRect) == 40`, `@alignOf(Affine) == 8`. Plus `Rect{-10,-20,30,40}.contains(30,40) == false`; `Rect{5,7,5,7}.contains(5,7) == false`; `Rect{80,60,20,10}.width() == -60` and `area() == 3000`; `Affine.scale(2)*translate(1,1)` on `(1,1)` is `(4,4)` while the reverse product is `(3,3)`; `Affine.new([0,0,0,0,0,0]).inverse().isNan() == true`. | The far-edge rule became inclusive, or a composition order reversed. The second places every window at the wrong position while passing every other vector, which `docs/19:1169-1172` names as the most likely mistake in this area. | **SR** for the expected values at `466e24e2…` plus **RO** from a Zig vector probe (`docs/19:1009-1013`). The `comptime` assertion is **unproven**: no geometry module exists. |
| **The role and property tables** | A table-driven test with one case per variant, driven by `@typeInfo(Enum).fields` rather than a hand-written list, so a missing variant cannot compile. | `Role` has 182 variants in upstream order; `Action` has 22 numbered 0 to 21 and `actionFromInt(22)` returns null; `PropertyId` has 87 and `Unset == 87`; `Flag` has 18 positions. Two nodes holding the same properties compare equal whatever order they were set in; a cleared property equals one never set. | A shifted discriminant. Every role and property id is a wire value, so a shift silently reinterprets a remote node's role and no test anywhere reports an error. `Unset == 87` failing means the id space and the unset sentinel disagree. | **SR** at `466e24e2…` (`docs/10` §9.4, `accesskit/src/lib.rs:47-62`, `:274-350`, `:888-1009`, `:796-826`, tests at `:3392-3414` and `:3482-3509`). **Unproven**: no table exists. |
| **The update protocol** | Unit tests over `TreeState.update`, one per `UpdateError` variant and one per row of the invariant table, plus a fixture-driven case for a full first update. | A full first update produces the recorded node set. `validate_global` returns `error.RootMissing` then `error.FocusMissing`. A duplicate child id inside one update returns `error.DuplicateChild`. A node that is neither the root, a child of the root tree, nor a child of another node in the same update returns `error.OrphanNodesWithoutParent`. A child id naming no known node returns `error.UnknownChildIds`. Removing a child by updating the parent alone removes its descendants. A graft node must precede its subtree. The emitted change set equals the recorded one element for element. | The port accepts an update upstream rejects, so a torn application is not detected, or it rejects an update upstream accepts, so a live tree silently stops updating. The last assertion is the one that catches a bug that no error path would. | **SR** at `466e24e2…` (`docs/10` §4.4 pseudocode, §4.5 invariants, §4.6 errors, §4.12 validation, `accesskit_consumer/src/tree.rs:124-486`). **Unproven**: no tree module exists. |
| **The action channel** | A scripted platform that feeds `Action.DoAction(0)` and asserts the handler receives an exactly equal `ActionRequest`; plus a lifetime test over the free path. | The request is 72 bytes in the port layout. `data.value` is an owned `[]u8`, not `[]const u8`, because the request crosses a thread boundary and upstream holds an owned `Box<str>` there. An unsupported action is silently dropped, because `do_action` returns void upstream. After the free function, the `char *` inside the `action_data` union is released too, because upstream's `impl Drop for action_data` does it and the header does not say so. | An action arrives holding a borrowed buffer the callee outlives, or every request leaks its string. Both are silent in a release build. | **SR** at `466e24e2…` (`docs/10` §5.2, §5.3) and at `8b6ed37c…` (`accesskit-c/include/accesskit.h:1065-1070`, `src/common.rs:1084-1090`, `docs/11` §4.6). **Unproven**: no action module exists. |
| **The C ABI layout** | A `binding-check` build step that compiles a C probe against the checked-in `include/accesskit.h`, and a Zig test asserting the same offsets and sizes from `@sizeOf`, `@alignOf` and `@offsetOf`. | `@sizeOf(Affine) == 48`, `@sizeOf(Rect) == 32`, `@sizeOf(OptRect) == 40`, `@offsetOf(Rect, .y0) == 8`, `@offsetOf(Rect, .x1) == 16`, `@offsetOf(Rect, .y1) == 24`, `@offsetOf(OptRect, .value) == 8`, `@offsetOf(OptRect, .has_value) == 0`. `accesskit_tree_id` is `bytes[16]` at offset 0. `accesskit_node_ids` is a `size_t` then a pointer. | The Zig struct and the C header disagree. This produces a silent wrong read in a C caller with no other symptom, and it is the highest-value target in the port because many setters have a `_with_length` twin that takes a caller-supplied length. | **RO** for the C side: a compiled probe printed every size, alignment and offset (`docs/19:338-366`). **Unproven** for the Zig side: no `extern struct` exists and `build.zig` declares no `binding-check` step. |
| **The C ABI aggregate passing convention** | A C probe that calls the geometry functions by value and prints what it received, linked against the port's library, run on `x86_64-linux` and on the `powerpc64-linux` row, with the two outputs compared. | A 16-byte struct of two doubles returns in `XMM0`; `accesskit_rect` returns in `XMM0` and `XMM1`; `accesskit_affine` returns in memory. The port's declaration must be `extern fn` returning `extern struct`, never `callconv(.C)` returning a plain `struct`. | The values land in the wrong registers or the wrong stack slots. A C caller reads garbage with no diagnostic and no crash. | **SR**, and `docs/19:406-409` marks the register assignment itself `[INFERENCE]` because no C compiler call site was exercised. The big-endian half is **unproven in full**: the PowerPC 64 ELFv2 classification for a 48-byte struct is not recorded anywhere in this repository. |
| **The D-Bus message decoder** | The synthetic peer of layer 4, plus a decode table driven from `@typeInfo` over every wire variant, plus a truncation test per length prefix. | `GetRegisteredEvents` at `/org/a11y/atspi/registry` returns signature `a(ss)` with body `0000000000000000`, eight zero bytes being a four-byte length plus four bytes of alignment padding, and decoding it yields an empty list. `GetChildren` at `/org/a11y/atspi/null` returns `message_type=Error` with `ERROR_NAME = org.freedesktop.DBus.Error.UnknownMethod`, and the port checks `message_type` itself because `methodCall` returns errors as values. A body truncated at every offset returns a declared error and never reads past the end. | The port treats a D-Bus error reply as a success body, and every upstream error name collapses into one class; or the decoder reads past a truncated buffer. The second is the only defect in this table that a fuzzer would find cheaply, and no fuzzer exists. | **RO** for the two reply shapes, from the live bus (`docs/26` §5). The truncation behaviour is **unproven**, and there is no way to reach it: `-ffuzz` does not compile (`docs/22` §9.7). |
| **The platform interface defaults** | Boundary rule D1 as a build step, rules B1 to B4 and C1 to C8 as source-level checks, and the scripted platform whose call log must equal the recorded log element for element. | One artifact builds from `src/schema/` and `src/consumer/` with no adapter package in the dependency graph, on a host that has none of the five platform SDKs. No file under either directory imports `std.os`, `std.posix`, `std.c`, `std.Io` or `zio`. No file under either directory reads the clock, the environment or the working directory. The scripted platform's call log equals the recorded log, first divergent element marked. | The platform-neutral half has taken a compile-time dependency on a platform. Upstream enforces that by review, which is why `docs/23` §2.4 calls it "enforced by review, not by tooling" and why §8.4 needs a test for it. | **SR** for the rules (`docs/23` §8.1 to §8.4). The Linux half is **unproven**: no core-half module exists. The four non-Linux adapters are **unproven and not attemptable on this host**, which section 7 spells out. |

### 4.1 What "unproven" costs

Eight rows, eight unproven. The reason is one fact, not eight defects:
`src/root.zig` carries no declarations. Nothing in this table is a failed
assertion. It is an assertion that has not been written.

The order the rows become provable in is the order of the milestones in
`docs/40-plan.md`: geometry and the tables first because they are pure and
cheap, the update protocol next because it is the core algorithm, then the
action channel, then the C ABI layout, then the passing convention, then the
wire, then the boundary rules.

---

## 5. The tests this project refuses to write

Each entry names the test, the reason, and the replacement. A later contributor
who proposes one of these has proposed a test that passes today, on a stub, and
that fails for a reason no reader of the suite could act on.

| Refused test | Why it is refused | The replacement |
|--------------|-------------------|-----------------|
| **A test that passes on a stub** | It proves only that a body ran. A module whose every function returns a constant satisfies every assertion that does not compare against a recorded value. `docs/18` §8 states the rule: "No item here passes on a stub: every one executes a body and compares a result." | Every assertion compares a result against a value read from a source line or against a recorded byte vector. Where no such value exists yet, the honest state is an open hole in section 7, not a green test. |
| **Wiring and forwarding tests** | A test that asserts one function calls another asserts something the compiler already proves, and it still passes when the callee does the wrong thing. | Assert the observable value at the boundary. Where a forwarding test is the only way to reach a lifetime, assert the counter or the allocator instead: `docs/25` §1.4 item 5 says that after a refusal the port holds no handle, no arena block and no registered interface, and the check is that the counter is unchanged. |
| **Duplicate same-path rows** | Two tests that reach the same code through the same entry point add a second place to update and a second place to break, and the second failure is always the more confusing one. | One test per behaviour. Where the cases differ only in input, one table-driven case list. The rule of thumb from `docs/18` §8 G6: an `inline for` over `@typeInfo(Enum).fields` covers every variant in one body, so a 22-variant table is one test and not 22. |
| **`expectNonEmpty`, `expect(len >= n)`, and every length-grew assertion** | They pass on any output at all. A decoder that returns one byte instead of the whole body satisfies both, and the failure that eventually appears points at the caller rather than at the decoder. | Assert the exact set, the exact length and the exact byte value. `docs/18` §8 G7 requires the first differing offset and both byte values, which is what makes the failure readable. |
| **A bare `try` with no assertion after it** | It passes on an implementation that never returns an error, and on one that returns the wrong error. Both are defects. | Pin the refusal by name. `translate-rust/build.zig:517-526` states why: a non-zero exit "stays green when a fixture starts failing with a *different* error", so the fixture asserts the typed error by name. `docs/25` §8.1 item 6 carries the same defence: a port that refuses an upstream construct must name the refusal in a test, or the boundary moves the first time someone widens a `switch`. |
| **Any test whose oracle is `cargo`** | The build constraint forbids it, and `docs/25` §3.5 closes the route for four independent reasons, of which the decisive one is that the expected values cannot be re-derived without the toolchain. | A committed `.bin` carrying an upstream commit, a source file and a line, and a SHA-256. For a pure value, a value transcribed by hand from a named source line, which is stronger provenance than a captured byte stream because a reviewer can check it without running anything (`docs/10:3986-3988`). |
| **A coverage-percentage gate** | The stage is opt-in and advisory (`zig-gate:12`, `:790`, `:812`), the metric is line coverage with no branch form, and the `zig-cov` wiring is documented two ways that are not the same (`docs/18` §7.3). | The obligation `docs/18` §7.2 sets instead: for every uncovered path in the changed set, one of three dispositions, and the third one written down. |
| **A fuzz gate** | `-ffuzz` does not compile in Zig 0.16.0. `lib/compiler/test_runner.zig:565-567` passes a `*builtin.StackTrace` where `std.debug.writeStackTrace` wants `*const debug.StackTrace` (`docs/22` §9.7). A `zig build fuzz` that never builds is a red milestone, not a gate. | Corpus replay inside plain `zig build test`, which does compile and does replay (`docs/22` §9.7). It is a weaker obligation and must be named as one. A bounded mutation harness written by this project is the only stronger route available, and it is listed as an open hole in section 7. |

Two more refusals that are not tests but that a contributor will propose as
verification, recorded here so they are refused in advance:

- **A real screen reader as the oracle.** It is non-deterministic and it needs a
  session. `docs/13` §8.4 lists it as not viable and says keep it as a manual
  smoke test, never as a gate.
- **`goose`'s own `src/tests/` as the model.** They are run apps, not
  `zig build test` targets, and they need a live bus (`goose/build.zig:21-35`,
  `docs/13` §8.4). Write new tests.

---

## 6. The reproduction rule

### 6.1 The four rules

**1. Reproduce before.** No fix lands without a test or a command that fails on
the unfixed tree and passes on the fixed one. A fix with no reproduction is a
story, and a story does not close a milestone.

**2. Confirm after.** Run the same command on the fixed tree and keep the
output. A reproduction that was never re-run has not been shown to work.

**3. Keep a regression test only for a plausible consumer-visible defect.** A
defect no consumer can observe is fixed and described in the milestone entry.
Pinning it forever costs a maintenance edge and teaches nothing. "Consumer"
means a C caller, an AT-SPI client, or an application using the tree.

**4. Delete any test that merely pins an existing implementation or its
wording.** A test that pins wording fails on a harmless rewrite. A test that
pins an implementation detail fails on every correct refactor. Both outlive the
problem they were written for. The subject-specific version of this rule is
`docs/25` §2.2: golden files are regenerated from validated source and read as
the diff, never edited by hand.

### 6.2 What a milestone entry must carry

`docs/40-plan.md` closes a milestone only when its entry carries all seven:

| # | Field | Why |
|---|-------|-----|
| 1 | The exact command, copy-pasteable | A milestone closed on "the tests pass" is closed on assertion. |
| 2 | The proof label it earns, EC or RO | Section 1.1. SR is not a milestone gate. |
| 3 | The failing output before the fix, quoted | Without it there is no reproduction. |
| 4 | The passing output after the fix, quoted | Without it there is no confirmation. |
| 5 | The name of the test, and the section 4 area it belongs to | Otherwise the entry cannot be checked against the table that says what proves what. |
| 6 | The row of section 7 the defect came from, or `none` | A hole that was closed is evidence the hole list is maintained. |
| 7 | For anything not reproducible on this host: the reason, and the host that would reproduce it | `ozai/AGENTS.md:205-206` requires it: silent skips are forbidden, report N/A explicitly. |

---

## 7. The open verification holes

Every entry names the hole and what closes it. An empty list here would be a
failure: the holes are known now, and each one is a claim this repository
cannot yet support.

| # | Hole | What closes it |
|---|------|----------------|
| H1 | **The data-carrying `repr(C)` enum layout.** `accesskit_action_data_Tag` is the only enum the header writes as `typedef enum NAME` with a trailing `_Tag` and no `uint8_t` alias (`accesskit-c/include/accesskit.h:1009-1022`). It has eight variants, each with a payload in one anonymous union (`:1025-1052`), and its values are wire values. Zig picks the backing integer for a C enum differently from Rust's `#[repr(u8)]`, so size and discriminants are a target decision. | The `binding-check` step: a Zig test asserting `@sizeOf(ActionData_Tag)` and every discriminant against the header's, plus a C probe that prints the size and every value. Run it on `powerpc64-linux` too, because a C enum's size is a target property. |
| H2 | **The aggregate passing convention on big-endian.** `docs/19:406-409` gives the SysV x86-64 classification and marks the register assignment `[INFERENCE]`, because no C compiler call site was exercised. The PowerPC 64 ELFv2 classification for a 48-byte `double[6]` struct returned by value is not recorded anywhere here. It matters because `accesskit_affine` returns by value from fourteen geometry functions and `accesskit_rect` from several more. | The `powerpc64-linux` row with a C probe linked against the port's library that round-trips `accesskit_affine`, `accesskit_rect` and `accesskit_opt_rect` by value and prints what it received, compared against the `x86_64-linux` run of the same probe. If the two disagree, the port's declaration is target-dependent, which is the defect. |
| H3 | **The opaque handle layout across a callback.** Eighteen opaque struct typedefs exist, four unconditional (`docs/11` §2.2). A C caller receives `struct accesskit_tree_update *` from the activation handler (`accesskit.h:1113`) and `struct accesskit_action_request *` from the action handler (`:1120`), and both must be released by the caller. Eight node getters return a `{length, values}` struct whose `values` pointer borrows from the node's internal `Vec`, no free function exists, and the header never states that the node must outlive the array (`docs/11` §4.5). | A C example that receives an update from the activation callback, calls a getter, uses the returned array after the owning node is dropped, and frees the update, linked against the port's library under Debug and ReleaseSafe, with a leak check on the free path. The header must state the lifetime in words, because a signature cannot. |
| H4 | **The Windows adapter.** `zig build-obj -target x86_64-windows` works and `zig build-exe -target x86_64-windows -luiautomationcore` and `-luser32` both link here, so a wrong import name fails the build rather than waiting for a runtime crash (`docs/16:1771-1788`). Nothing built here can execute: `which wine` returns nothing. | A Windows host, or a CI runner with UI Automation, running the scripted platform plus a live UIA client against the exported `IRawElementProviderSimple` objects. Compile coverage is not execution coverage and must not be recorded as such. |
| H5 | **The macOS adapter.** `build-obj` works; `build-exe -target aarch64-macos` fails at `-lobjc` with `unable to find dynamic system library 'objc'` (`docs/16:1780`). The `AXUIElement` surface is an Objective-C object graph, and `translate-c` on an Objective-C header fails (`:1784`). | A macOS host. Failing that, a recorded transcript of `AXUIElement` attribute calls replayed through the adapter state machine, plus a fake `AXUIElement` behind a narrow interface. The first is evidence, the second is a unit test over a claim about the platform. |
| H6 | **The iOS adapter.** `zig build-exe -target aarch64-ios` fails with `unable to find libSystem system library` and a zero-byte output (`docs/16:1782`). Until someone runs the iOS milestone on a Mac its status is "compiles", not "works" (`docs/16:1878-1881`). Text reaches VoiceOver as one flat `accessibilityValue` string, so no text interface exists to test. | A Mac for the link and a device or simulator for the run. The only thing testable on Linux is the state machine that receives an already-decoded record, and that is a narrower claim. |
| H7 | **The Android adapter.** `zig build-exe -target aarch64-linux-android -llog -lc` fails with `unable to find dynamic system library 'log'` (`docs/16:1783`). `translate-c` on `jni.h` works (`:1786`), so the binding is available, but the JNI signature cannot be exercised on a Linux host. | An NDK build plus a device or emulator run. Failing that, the decoded `AccessibilityNodeInfo` record on the far side of the JNI boundary, which is testable. The JNI call itself is not. |
| H8 | **Fuzz-reachable decoder paths.** `-ffuzz` does not compile in Zig 0.16.0 (`docs/22` §9.7), so the four decoder targets `docs/18` §4.5 names cannot run under the compiler's fuzzer, and `zig build test --fuzz=N` reports `error: no fuzz tests found`. | A toolchain where `lib/compiler/test_runner.zig:565-567` type-checks, or a deterministic mutation harness written by this project that drives the tree update decoder, the property codec, the ABI marshaller and the D-Bus decoder without the compiler's fuzzer. The second is a different obligation and a weaker one, and `docs/22:2181-2184` says so. |
| H9 | **The recorded `Embed` reply from a real registry.** No AT-SPI application is on this host (`docs/26` §0), so the `(so)` reply shape the port must decode has never been captured. The fake peer returns a fixed value, and a fixed value is a guess. | One `Embed` reply captured from a real bus with `busctl`, committed as bytes, replayed by the peer. No Rust is needed to produce it. This is the single capture that would move layer 4 from a claim about the protocol to a claim about this daemon. |
| H10 | **The four-line `O_NONBLOCK` patch to goose.** With a zio-backed `std.Io` the first run failed with `error.ReadFailed`. zio opens sockets non-blocking and never restores blocking mode, so `fcntl F_GETFL` returns `0x802`, and goose folds `EAGAIN` into `error.ReadFailed` (`docs/26` §7.3-7.4). The fix is four `fcntl` lines after connect, and it exists today only as an edit in a working copy. | A decision from `docs/30-port-design.md` on how the patch is carried, plus a test that fails with `error.ReadFailed` on the unpatched path and passes on the patched one. Until it is carried, every live-bus result in this repository depends on an unpublished local edit, and any milestone that cites it must say so. |
| H11 | **The a11y bus address parser for `unix:abstract=`.** goose's `SocketIterator` parses `unix:path=` only (`goose/src/connection.zig:1458-1473`) and the launcher emits `unix:abstract=` on some systems (`at-spi-bus-launcher.c:541`). This host uses `unix:path=`, so a green test here does not clear it. | A unit test over the address parser with both forms, available now, plus one end-to-end run on a system where the launcher chose the abstract form, which needs a different host. The first is not a substitute for the second. |
| H12 | **`accesskit_opt_lresult`.** A `LRESULT` in a public struct that exists only under `_WIN32` (`accesskit.h:1125-1135`). It cannot be declared, laid out or tested here, because the type does not exist on this host. | The Windows build of H4. Until then the port either keeps it out of its own header under the same `#ifdef`, leaving a C consumer on Windows with a different surface than the port, or carries a declared stand-in. `docs/31-c-abi-design.md` owns the choice, and this row records that the choice cannot be verified here. |
| H13 | **The address-space ceiling is decorative until a test proves it.** `build.zig:22` sets four gibibytes and `build.zig:108-118` applies it through a `bash -c` launcher. No test asserts the ceiling bites. | The test `docs/18` §8 G20 describes: it allocates without bound and must fail inside the ceiling rather than take the machine with it. It is the one item in that list that a stub passes and a runaway decoder does not. |
| H14 | **Line coverage for the whole tree.** No coverage number exists and none is promised. The `zig-cov` wiring is documented two ways that disagree (`docs/18` §7.3), and the stage is advisory anyway. | Not a number. The obligation `docs/18` §7.2 sets instead: every uncovered path in the changed set carries one of three dispositions, and the third is written down. A number is not a disposition. |

---

## 8. Portable AT-SPI node fixes

This change addresses [issue #2](https://github.com/CoffeeImpliesCode/zaccesskit/issues/2).
The source reference is AccessKit commit
`466e24e252103f4d82bd6fbab98141b551e46e0c`.
The 43 original open rows now name their portable Zig counterparts.
The methods return values or emit application actions. They do not register D-Bus objects.
The ledger also corrects the three mappings for `adapter_id`, `id`, and `role`.

### 8.1 Defects and regression tests

| Defect | Observed failure before the fix | Regression |
|---|---|---|
| Unsupported bulk selection resolved the node | The missing-node case returned `error.Defunct` instead of `false`. Upstream `node.rs:1381-1389` returns `false` without resolution. | `unsupported bulk selection returns false without resolving a node` |
| Cache strings lost their allocation length | `CacheNode.deinit` triggered `Invalid free`. The stored text length was smaller than the list capacity. | `cache text ownership transfer releases grown name and description under fail N` and the real cache query |
| Child lookup ran before the selection capability check | `expected error.UnsupportedInterface, found error.Defunct` for an image with no children. | `selection and text methods emit actions for the real consumer tree` |
| Lazy method analysis hid invalid calls | The first build reported two errors. The broader value/action tests exposed seven more. Caret and point queries exposed two more. | The real value, action, caret, and point tests call those methods. |

The cache fix transfers each list through `toOwnedSlice`.
An error releases the list and each earlier buffer.
Fail-N tests exercise the existing `error.OutOfMemory` paths.
This change adds no production error tag.
Selection methods use the resolved node once.
The filtered child cursor owns the walk bound and reports `error.TreeCycle` on exhaustion.
The fixture loops use finite named arrays.

The initial command was:

```sh
zig build test --summary all -j4
```

Its step summary was:

```text
Build Summary: 6/11 steps succeeded (2 failed)
test transitive failure
```

The focused run includes six behavior tests and six existing reachability sweeps.
The final run reported:

```text
All 12 tests passed.
```

The mutation check changed only `selectAll` from `false` to `true`.
The regression detected the change:

```text
adapters.atspi.node.test.unsupported bulk selection returns false without resolving a node...FAIL (TestUnexpectedResult)
6 passed; 0 skipped; 1 failed.
```

The implementation was restored before the passing run.

### 8.2 Real consumer smoke

A standalone program built a seven-node `TreeUpdate` and passed it to `Tree.init`.
It called the real node methods and inspected their emitted `ActionRequest` values.
It did not replace the node implementation.
The program reported:

```text
PASS real Tree.init: image=(115,230,40,40) value=4.5 step=0.25 text=bc family=Fixture Sans selected=1 click_target=5 selection=(0,2) removed=(3,3) scroll=(45,50) substring_scroll=(60,80)
```

The substring-scroll oracle follows `node.rs:1728-1758` and `util.rs:44-56`.
Window coordinates use a zero origin.
The text range starts at `(10,0)`, so the request `(70,80)` emits `(60,80)`.
The smoke proves portable queries and action emission only.
It does not prove live D-Bus registration or communication with an accessibility client.

### 8.3 Android decisions

[Issue #4](https://github.com/CoffeeImpliesCode/zaccesskit/issues/4) permits written decisions.
The ledger records scroll payload ownership and the accessibility-manager lookup contract.
Root scroll events use the host-view representation.
The proposed slot error set preserves filter errors.
The manager descriptor follows the linked Android API and JNI specification.
Both rows remain open because this change does not implement either contract.

### 8.4 Retained root-mapper obligation

Review identified a separate path in `PlatformRoot.mapDescendantCacheNodes`.
A standalone identity-mapper probe used a real tree and the application registry.
Compilation failed before the mapper could run:

```text
src/adapters/atspi/node.zig:2375:9: error: expected type 'i32', found 'error{TooManyChildren}!i32'
        child_count,
        ^~~~~~~~~~~
```

The child-count cast at `node.zig:2369` lacks an error return.
The ledger reopens upstream `node.rs:1973` instead of retaining a completion claim.
`[INFERENCE]` The mapper can also retain cache strings that the collector then releases.
The compile failure prevented a runtime check of that ownership concern.
This path needs its own cast, ownership, and allocation-failure checks.

The actual ledger has 1356 rows.
The original 43 completions and the reopened root row change the open count from 108 to 66.
The prior header count of 104 did not match the inventory.

### 8.5 Final native tests and gate

The final `zig build test --summary all -j4` run reported these count and summary lines:

```text
All 353 tests passed.
All 353 tests passed.
All 1599 tests passed.
All 1599 tests passed.
Build Summary: 11/11 steps succeeded
```

The two library shards run in Debug and ReleaseSafe.
The two 353-test shards replay the committed decoder corpus in those modes.
This change adds no decoder boundary or fixture.

The final `zig-gate` run executed all nine default stages.
These are its verdict lines:

```text
== zig fmt --check ==
  fmt: OK
== zig build ==
  build: OK
== zig build test ==
  test: OK
== zig ast-check ==
  ast-check: OK
== ziglint ==
  ziglint: found 119 issue(s), exit 1
== zlint ==
  zlint: found 10 issue(s), exit 0
== zbc ==
  zbc: 0 error(s), 0 warning(s) (advisory), exit 134
== zwanzig ==
  zwanzig: found 103 finding(s) in 4 rule class(es), exit 1
  zwanzig: FAILED (zwanzig reported 104 issue(s) but 103 diagnostic line(s) parsed; the output format moved)
== cross-test ==
  cross-test: status=pass pass=3 fail=0 build_only=0 partial=0 summary=/tmp/cache/zaccesskit/cross-test/cross-test-summary.json
  cross-test: OK
GATE FAILED — fix the issues above
```

The gate exited 1. This is not a green-gate claim.
The `zbc` process panicked with `integer overflow` in its AST parameter scan.
The `zwanzig` finding count did not match the parsed diagnostic count.
The native tests do not resolve the remaining lint findings or either tool failure.
No rule was disabled and no stage was skipped.
The four optional-unwrap findings introduced by the first test draft were removed.

The final cross-test summary records execution, not build-only results:

| Target | Status | Tests | Reason |
|---|---|---|---|
| `x86_64-linux` | pass | 1599 | `tests_complete` |
| `aarch64-linux` | pass | 1589 | `tests_complete` |
| `powerpc64-linux` | pass | 1589 | `tests_complete` |

The foreign rows do not execute the Windows COM surface.
No row proves communication with a live platform accessibility object.

The final source format check reported no file.
The added source lines contain no unbounded loop, empty catch, discarded error,
unexplained `unreachable`, or file-scope variable.
Repository scans found no Rust manifest or build input and no Rust tool invocation.

## 9. Final correction evidence

This section supersedes section 8.4's reopened cache claim and section 8's final counters.
Section 8 remains the historical record of that earlier run.
The evidence comes from `correction-proof.json` and raw artifacts `252`, `292`, and `303`.

### 9.1 Root cache contract and tests

The historical `correction-proof.json` source places `PlatformRoot.mapDescendantCacheNodes` at `src/adapters/atspi/node.zig:2251`.
It uses an owned-input mapper contract.
The mapper consumes each `CacheNode` on success and error, including both text buffers.
The collector reserves output capacity before handoff.
The release callback frees partial mapped output on failure and must not retain its item pointer.
Both callbacks run on the calling thread and must not change the registry or trees.
On success, the caller owns all mapped items and the list buffer through the supplied allocator.
On error, no result survives. The collector does not undo mapper side effects.
The return error set joins `NodeError` with the mapper's closed error set and rejects `anyerror`.
Checked child counts and indices replace the failed cast recorded in section 8.4.

The focused result records 17 passing tests, including these five root-cache tests:

| Test | Evidence covered |
|---|---|
| `root cache identity retains owned name and description` | Identity mapping retains text after collector temporaries end. |
| `root cache preserves multi window preorder filtering indices and focus` | Two windows preserve preorder, promoted children, hidden-subtree filtering, indices, and per-window focus. |
| `root cache releases owned inputs and mapped outputs under fail N` | Fail-N covers the successful walk's allocations and partial ownership. |
| `root cache query failure releases partial mapped outputs under fail N` | Fail-N covers allocations before query failure and releases earlier results. |
| `root cache mapper rejection consumes input and releases outputs under fail N` | Fail-N covers mapper rejection, consumed input, and partial output release. |

### 9.2 Windows formatter cases and errors

`src/adapters/windows/util.zig` has nine formatter tests:

| Test | Cases covered |
|---|---|
| `toolkit description preserves Unicode code units and version presence` | Default name, empty name, absent/empty version, empty-name version, BMP/non-BMP Unicode, and interior NUL. |
| `ARIA empty and exact multiple properties have no invented escaping` | Empty builder, empty fields, exact semicolons, Unicode, equals signs, and literal backslashes. |
| `ARIA booleans and usize use lowercase and exact decimal digits` | Both booleans, zero, and maximum `usize`. |
| `toolkit description fail-N releases all intermediate buffers` | Description allocation failures release temporary storage. |
| `ARIA fail-N preserves completed properties separators and transfer ownership` | Property allocation failures and owned output. |
| `ARIA allocation failure does not leave a separator before a later retry` | Failed writes preserve completed properties and permit a correct retry. |
| `ARIA failed ownership transfer keeps completed bytes until a successful transfer` | Failed transfer preserves the builder and permits a later transfer. |
| `ARIA typed writers fail-N leave an empty builder usable and leak nothing` | Boolean and integer writer allocation failures. |
| `toolkit description rejects invalid UTF-8 in name and version` | Both inputs return `error.InvalidUtf8`. |

`DescriptionError` is the closed set `error{ OutOfMemory, InvalidUtf8 }`.
`PropertyError` is the closed set `error{OutOfMemory}`.
Fail-N tests reach the new APIs' `OutOfMemory` paths. The named invalid-UTF-8 test reaches `InvalidUtf8`.
Neither formatter imposes an arbitrary size cap. Checked size arithmetic reports unrepresentable allocation sizes as `OutOfMemory`.
The integer buffer uses `@bitSizeOf(usize)`, which bounds every decimal representation, including zero.
The description returns native UTF-16 code units, not a little-endian byte sequence.
The big-endian branch converts decoder output and the space separator with `littleToNative`.
The executed `powerpc64-linux` suite checks the same exact Unicode code-unit oracle on a big-endian target.
This is portable formatter evidence, not Windows COM execution.

### 9.3 Smoke, mutation, and native results

The real-consumer smoke reported this exact line:

```text
PASS cache preorder=[7:0,7:2,7:5,11:0,11:2,11:5] indices=[0,0,1,1,0,1] children=[2,0,0,2,0,0] focused=[0,1,0,0,0,0] name="Retained image" description="Retained description" toolkit_utf16=[233,55357,56832,32,946,46,49] aria="disabled=false;level=7"
```

Artifact `292` records the wrong-cache-index and comma-for-semicolon mutations in one native run:

```text
1400/1624 adapters.atspi.node.test.root cache preserves multi window preorder filtering indices and focus...expected 1, found 0
FAIL (TestExpectedEqual)
1619 passed; 0 skipped; 5 failed.
```

The comma mutation failed four formatter checks: exact properties, booleans/integers, fail-N property output, and allocation-failure retry.
The index mutation failed the root-cache preorder test. The proof records that both mutations were restored.
Artifact `252` records these native count and summary lines:

```text
All 353 tests passed.
All 1624 tests passed.
All 353 tests passed.
All 1624 tests passed.
Build Summary: 11/11 steps succeeded
```

Debug and ReleaseSafe each ran 1624 library tests and 353 committed-corpus tests.
This correction adds no protocol-decoder boundary or corpus fixture.
These results do not claim new fuzz coverage or live-platform proof.

### 9.4 Full gate result and retained policy

Artifact `303` ran all nine stages. Its stage heads and verdict were:

```text
== zig fmt --check ==
  fmt: OK
== zig build ==
  build: OK
== zig build test ==
  test: OK
== zig ast-check ==
  ast-check: OK
== ziglint ==
  ziglint: found 96 issue(s), exit 1
== zlint ==
  zlint: found 3 issue(s), exit 0
== zbc ==
  zbc: 0 error(s), 0 warning(s) (advisory), exit 134
== zwanzig ==
  zwanzig: found 66 finding(s) in 4 rule class(es), exit 1
  zwanzig: FAILED (zwanzig reported 67 issue(s) but 66 diagnostic line(s) parsed; the output format moved)
== cross-test ==
  cross-test: status=pass pass=3 fail=0 build_only=0 partial=0 summary=/tmp/tmp/zig-gate-cross/cross-test-summary.json
  cross-test: OK
GATE FAILED — fix the issues above
```

The gate exited 1. It did not pass.
`zbc` still panicked with integer overflow. The `zwanzig` count still disagreed with the parsed diagnostic count.
The final executed cross-test counts supersede section 8.5:

| Target | Status | Tests |
|---|---|---|
| `x86_64-linux` | pass | 1624 |
| `aarch64-linux` | pass | 1614 |
| `powerpc64-linux` | pass | 1614 |

Tools, lint rules, production invariant-backed unwraps, and the external checker's 200-state cap remain unchanged.
Allocator-first parameters, foreign SDK/C names, and valid deinitialization resets remain unchanged.
The Z017 direct-return experiment failed compilation because the error-union payload could not coerce to the optional payload.
The recorded Debug `zig test` CLI experiment exited 1 with eleven errors in the optional string getters.
The compiler reported: `error union payload '[]u8' cannot cast into error union payload '?[]u8'`.
That experiment does not show that a hoisted temporary fails.
The current source retains `return try`. It does not apply lint-policy hoisting solely to hide the warning.

### 9.5 Tool reports, host fit, and ledger

The approved tool reports are:

- [zbc #105](https://github.com/CoffeeImpliesCode/zbc/issues/105): integer overflow in the AST parameter scan.
- [zwanzig #87](https://github.com/CoffeeImpliesCode/zwanzig/issues/87): separate owned getter results reported as a double free.
- [zwanzig #86](https://github.com/CoffeeImpliesCode/zwanzig/issues/86): a live generic callback reported as unused.

`CoffeeImpliesCode/ziglint` has issues disabled.
The five Ziglint drafts cover Z030 valid resets/idempotent deinitialization, Z006 PascalCase SDK type aliases,
Z006 exported C ABI constants, Z032 foreign SDK/JNI acronym names, and Z017 syntactically truncated code suggestions.
The Z017 draft does not report the `return try` warning itself as a checker defect.
Z023 allocator-first order remains a policy conflict, not a tool-defect draft.
All five remain drafts, not posted issues.
Authenticated queries for `CoffeeImpliesCode/zlint` and `CoffeeImpliesCode/zig-gate` returned HTTP 404.
Reports for those destinations remain unfileable. No report was redirected to an unrelated repository.

The nogui fit review inspected source at
[`a7761b4245974d62adf6f65fba41812f23bc5b9c`](https://github.com/CoffeeImpliesCode/nogui/tree/a7761b4245974d62adf6f65fba41812f23bc5b9c).
It did not execute nogui.
`src/v7/semantics.zig` owns the model semantics. `App.present` commits the semantic snapshot.
The replacement seam is the host accessibility adapter and its bridge, not the semantic producer.
Current zaccesskit is not a drop-in replacement.
Custom-action, positioned editable-text, callback-close, and native bus/attachment gaps still need equivalent implementations.
The tool reports contain no nogui review data.

At that historical checkpoint, the ledger recorded 1356 rows: 457 ported, 647 adapted, 194 not applicable, and 58 open.
The open rows split into Unix 39, Windows 13, atspi-common 4, and Android 2.
The signature wrap added five lines below `node.zig:2256`.
The then-current LSP coordinate named `notifyChanges` at `node.zig:2453`.
Original upstream coordinates remain unchanged. Section 10.5 records the later document-event closure.

## 10. API integration evidence

This section records the integrated API work.
The artifact counts below describe their recorded runs, not a current source census.
Sections 10.5 through 10.7 record later execution evidence.
These sections do not replace earlier platform refusal limits or claim a green house gate.
`docs/40-plan.md` section 1.2 owns the build-step command list.

### 10.1 Offline application and linked C consumer

Artifact `388` records 857 integration tests per mode in Debug and ReleaseSafe.
Artifact `414` records the ReleaseSafe standalone application scenario, with a two-millisecond run.
The scenario converts pure application-model commands to tree updates.
It checks the exact eight-node result and returns `InvalidState` on a wrong result.
It does not execute nogui or a native accessibility bus.

Artifact `426` records the ReleaseSafe linked C11 consumer:

| Counter | Observed value |
|---|---:|
| Checks | 1676 |
| Failed checks | 0 |
| Allocations | 598 |
| Frees | 598 |
| Active allocations | 0 |
| String releases | 184 |
| Custom-action releases | 4 |
| Action-list releases | 7 |
| Node releases | 53 |
| Tree-info releases | 2 |
| Tree-update releases | 2 |

This run links and executes the real library.
The empty-array regressions cover eligible `NULL, 0` setters.
The run does not prove native platform object attachment.

### 10.2 Hand-recorded reference fixtures

Artifact `426` records 766 passing reference-shard tests per mode in Debug and ReleaseSafe.
The ReleaseSafe standalone run took four milliseconds.
It printed two raw-fixture passes and twelve exact-output case passes.
It also printed `reference-runtime=not-executed` and `wire-parity=not-claimed`.

| Fixture | Cases | Raw bytes | SHA-256 |
|---|---:|---:|---|
| `test/fixtures/geometry.json` | 4 | 1686 | `055257448677d44741d3d80c29c61ed0fdcc46654484d8c8d5e710137ac271f2` |
| `test/fixtures/text.json` | 8 | 4447 | `ec41b6fcaa01d2816f751f2c1598559a471f9334ee1096e192ba0e2e588357a8` |

`test/fixtures/manifest.json` records these bytes and core revision `466e24e252103f4d82bd6fbab98141b551e46e0c`.
These results support the finite source-oracle scope in section 3.2.
They do not support Rust execution or wire-byte parity.

### 10.3 Measured registry reuse

The benchmark tests passed nine tests per mode in Debug and ReleaseSafe.
The benchmark emits deterministic digests and work counts. It has no internal timing.
`TreeIndexMap.cloneInto` compares the next index, both counts, and every mapping in both directions.
Equal registries skip two map clones and destination replacement.
Changed registries keep the existing transactional copy path.

Run `bg_24` measured all eighteen cases in the table below.
Both binaries used ReleaseSafe and CPU 0.
GNU time recorded five interleaved runs per version, with compilation idle.
Allocation instrumentation ran separately.
Times cover the whole process, including fixture construction, canonical checksum verification, and teardown.
They do not measure native accessibility-bus latency.

The receipts are `/tmp/cache/zaccesskit/evidence/api-integration-perf/benchmark-results.json`.
The baseline binary SHA-256 is `64662b278d7a918a8d810f073b1f2ca9e460c5b3843e0e5512fb06330d9c0d58`.
The candidate binary SHA-256 is `f6fe1a2c5c6a07eada4a75e03e5c4b87c830098e9647c05accfea20db1d89ee6`.
The baseline cache artifact starts with `148b62d6`. The candidate starts with `efa3ccc5`.
Earlier calibration artifact `f669` used different host load. It is not a comparative result.

| Shape | Nodes | Workload | Work units | Baseline median seconds | Candidate median seconds | Baseline allocations | Candidate allocations |
|---|---:|---|---:|---:|---:|---:|---:|
| balanced | 65 | snapshot | 8192 | 1.67 | 1.67 | 5267457 | 5267457 |
| balanced | 65 | update 1 | 65536 | 0.23 | 0.21 | 656004 | 524932 |
| balanced | 65 | update 64 | 4096 | 0.33 | 0.33 | 889476 | 881284 |
| balanced | 4096 | snapshot | 128 | 1.88 | 1.89 | 4925697 | 4925697 |
| balanced | 4096 | update 1 | 65536 | 0.27 | 0.25 | 693843 | 562771 |
| balanced | 4096 | update 64 | 4096 | 0.89 | 0.86 | 1193555 | 1185363 |
| balanced | 65536 | snapshot | 8 | 3.09 | 3.10 | 4916113 | 4916113 |
| balanced | 65536 | update 1 | 65536 | 0.76 | 0.73 | 1269875 | 1138803 |
| balanced | 65536 | update 64 | 4096 | 1.39 | 1.36 | 1769587 | 1761395 |
| wide | 65 | snapshot | 8192 | 2.00 | 1.99 | 5095425 | 5095425 |
| wide | 65 | update 1 | 65536 | 0.19 | 0.16 | 524911 | 393839 |
| wide | 65 | update 64 | 4096 | 0.34 | 0.34 | 832111 | 823919 |
| wide | 4096 | snapshot | 128 | 1.89 | 1.90 | 4729473 | 4729473 |
| wide | 4096 | update 1 | 65536 | 0.17 | 0.15 | 561238 | 430166 |
| wide | 4096 | update 64 | 4096 | 0.29 | 0.29 | 868438 | 860246 |
| wide | 65536 | snapshot | 8 | 2.43 | 2.40 | 4719537 | 4719537 |
| wide | 65536 | update 1 | 65536 | 0.51 | 0.49 | 1114231 | 983159 |
| wide | 65536 | update 64 | 4096 | 0.63 | 0.63 | 1421431 | 1413239 |

All eighteen cases preserve input and output digests, work counts, and callback counts.
Both versions report zero live bytes after teardown.
Each update work unit removes exactly two allocations.
Update-1 cases remove 131072 allocations. Update-64 cases remove 8192.
Snapshot allocation counts do not change.
Update-1 medians improve in each case.
Update-64 medians show small or no gains. Snapshot medians vary within measurement noise.
These results support registry-copy allocation removal, not a general platform latency claim.

Seven separate `perf stat` repeats measured balanced 65-node update-1 with 65536 work units.
The input digest was `cc7a5aced880e530`. The output digest was `5b762f34cb278bab`.

| Counter | Baseline | Candidate |
|---|---:|---:|
| Cycles | 966558257 | 862744010 |
| Instructions | 1558597028 | 1440632208 |
| Branches | 252474013 | 237007506 |
| Branch misses | 1580553 | 1390446 |
| Mean elapsed seconds | 0.26532 | 0.23658 |
| Reported elapsed standard error, seconds | 0.00381 | 0.00445 |

The cycle count decreases by 10.74 percent. The instruction count decreases by 7.57 percent.
An earlier sparse-update profile collected 136 samples at 199 Hz, with none lost.
`memset` accounted for 25.88 percent of those samples.
The profile does not identify its causal caller or prove that registry cloning caused those samples.

### 10.4 Callback and registry regression evidence

The public-C Unix callback regression failed before the ownership change.
Run `bg_11` records a segmentation fault at address `0x18` and an abort.
The stack crossed `Properties.deinit`, `Node.deinit`, `TreeUpdate.deinit`, `Tree.init`, `PlatformAdapter.apply`, and `unixAdapterUpdateIfActive`.
The callback had returned an actual C factory handle.
This failure exposed the opaque-handle/native-update mismatch.

The equal-registry regression also failed before the source change.
Run `bg_14` records `OutOfMemory` at the original `cloneInto` map clone.
The test used an equal destination registry and a fail-first allocator.
The failure showed that the old equal-copy path still allocated.

**Source reading.** All five adapters now consume owning opaque C callback handles through the shared conversion.
It releases the outer handle through the captured allocator on success and error.
Zero-copy requires proof of the same allocator domain, not an unconditional context-pointer comparison.
Known stateless standard allocators and C ABI registered pairs permit that proof.
Unknown custom vtables require array migration without a context-pointer read.
Different initialized stateful contexts also require array migration.
Nodes retain their property allocators.
Three fixed owner slots protect committed, working, and incoming metadata.
Pruning uses storage identity after every update attempt.
The native tree dies before the retained metadata owners.
macOS queued events keep the reference-counted context and its metadata alive.

**Source reading.** `platform_adapter.onNodeUpdated` calls `node.notifyChanges`.
The notifier orders state, property, bounds, children, and document events.
It keeps focus in a separate change slot.
`notifyDocumentChanges` adds `LoadComplete` only when a document changes from busy to not busy.
The event queue owns announcement text.
The notifier error set excludes unreachable action failures.
These are generated queue notifications, not signals sent on a real Unix bus.

### 10.5 Publication execution evidence

Run `bg_29` passed all 70 focused native callback, allocator, and notification tests.
Run `bg_31` passed these shards in both Debug and ReleaseSafe:

| Shard | Passing tests per mode |
|---|---:|
| Reference | 767 |
| Integration | 860 |
| Benchmark | 9 |
| Committed decoder corpus | 356 |

The native shard in that run had one focus-fixture failure.
The fixture required two total events, but legitimate role and state notifications made four.
The corrected fixture checks both exact Focus identities and addresses.
It excludes `StateChanged(focused)` and permits unrelated property notifications.
That correction is not a passing native-shard receipt.

The linked C consumer recorded 1676 checks, zero failed checks, 598 allocations, and 598 frees.
It reported zero active allocations.
The actual `integration-run` and `reference-run` executions passed.
The reference run checked all twelve source-derived cases for exact output.
Both raw fixtures matched their recorded byte lengths and SHA-256 values in section 10.2.
These checks do not execute a Rust reference or establish wire parity.
The 356-test corpus shard replays committed decoder inputs. It is not mutation fuzzing.

The C ABI parity sweep reported `IN PARITY` for all five targets.
It covered 498 functions and one exported data symbol.
The target-set comparisons matched at 447, 457, 454, 454, and 451 symbols.
The guard census printed portable `440` versus `441` as `MISMATCH`.
The second count includes the exported data symbol. This census discrepancy is not a target ABI mismatch.

A separate external package used `dependency.module("zaccesskit")` and `dependency.artifact("zaccesskit")`.
All four external smoke configurations passed:

| Optimization | Linkage | Build steps |
|---|---|---|
| Debug | static | 9/9 passed |
| Debug | dynamic | 9/9 passed |
| ReleaseSafe | static | 9/9 passed |
| ReleaseSafe | dynamic | 9/9 passed |

Each configuration executed both consumers and reported:

```text
external-zig root=1 role=window label=ExternalZig focus=1 toolkit=AccessKit toolkit_version=null
external-C label=ExternalC-é affine=(-3,11) reverse=(-18,-3)
```

The external Unix callback probe exercised actual C factory, activation, update, debug, and free routes.
Its callback returned actual owning C payloads. The probe passed through the no-bus Unix path.
It did not attach to a real platform accessibility object.
It did not run nogui.
The source-only nogui review in section 9.5 remains integration guidance, not an executed consumer claim.

Three deliberate mutations produced red results:

| Mutation | Observed failure |
|---|---|
| Parse before fixture length/SHA validation | Expected `HashMismatch`, found `InvalidFixture` |
| Retain a removed text run through the actual update | `OutputMismatch` at the absent-node check |
| Compare registry counts without mappings | Expected mapping index `0`, found `7`. A stale ID remained present |

The corrected reference source passed before these mutations.
These results test fixture validation order, removed-node behavior, and registry mapping comparison.
They do not add platform execution evidence.

The verified document-event path closes only `atspi-common/adapter.rs:513` as adapted.
The ledger now has 457 ported, 648 adapted, 194 not applicable, and 57 open rows, totaling 1356.
The open rows comprise 39 Unix, 13 Windows, three AT-SPI common, and two Android rows.
Historical Main-source LSP reports `allocation.release` at `src/capi/allocation.zig:386`.
It reports `notifyChanges` at `src/adapters/atspi/node.zig:2459` and `notifyDocumentChanges` at `:2703`.

The actual AArch64 run passed all 15 steps through QEMU.
Its native shard reported 1643 passes and 10 skips out of 1653 tests.
Its linked C consumer passed 1676 checks with zero failures.
It recorded 598 allocations, 598 frees, and zero active allocations.
All twelve reference cases and the standalone integration scenario passed.

The actual big-endian powerpc64 run passed all twelve reference cases and the standalone integration scenario.
Its native shard reported 1643 passes and 10 skips out of 1653 tests.
The linked real C consumer crashed with `SIGSEGV`. The build completed 13 of 15 steps.
This result is not a passing powerpc64 matrix receipt.
At that historical publication, the user accepted an unsupported PowerPC64 C boundary, not a fixed C-consumer claim.
All checks remain enabled. No speculative wrapper or compiler change is included.

An independent reproduction used no zaccesskit code.
The manifest-selected Zig 0.16.0 shim compiled it with static `zig cc -target powerpc64-linux`.
Actual executions returned these results:

| Aggregate-return case | Observed result |
|---|---|
| Dense `usize` and pointer control | PASS, exit 0 |
| Flattened bool and `u64` | FAIL, exit 1 |
| Bool and `f64` | FAIL, exit 1 |
| Direct nested NodeID | `SIGSEGV`, exit 139 |
| Indirect nested case | FAIL, exit 1 |

GDB showed a 16-byte bool/`u64` C caller expecting results in `r3` and `r4`.
The Zig callee expected a hidden result pointer in `r3` and the node pointer in `r4`.
That historical capture identifies the sixteen-byte example only; it does not restrict the defect to sixteen-byte aggregates.
The parent later observed affected two-byte optional shapes, including twelve actual enum types.
Its private semantic ABI candidate is not a full-library, compiler-fix, or wire-parity proof; the strict linked-C gate remains unresolved until a real corrected-source receipt.
The node pointer therefore became a function address.
The ELF flags identified ABI v2. This evidence isolates the compiler boundary from the project.
The `CoffeeImpliesCode/zig` repository lookup returned HTTP 404. No issue was created in that repository.
[zaccesskit issue #5](https://github.com/CoffeeImpliesCode/zaccesskit/issues/5) records the Zig 0.17 aggregate-return ABI migration check.
The user-approved issue is OPEN and has no labels.
It tracks a future Zig 0.17 check, not a claim that Zig 0.17 fixes the compiler defect.

### 10.6 Native Debug C repair and first final gate

The first final house gate ran all nine default stages. It did not pass.
Formatting, build, and AST checks passed.
Both native library shards passed all 1653 tests, in Debug and ReleaseSafe.
The reference shards passed 767 tests per mode. Integration passed 860 and benchmark passed nine per mode.
The linked Debug C consumer failed five geometry result checks.
It still reported 598 allocations, 598 frees, and zero active allocations.

The source correction sets `.use_llvm = true` for the C artifact only.
The self-hosted x86 Debug backend produced incorrect C geometry aggregate results.
The LLVM backend produced the correct results.
After this source correction, actual `zig build test-c -Doptimize=Debug` passed all seven steps.
The consumer passed 1676 checks with zero failures, 598 allocations, 598 frees, and zero active allocations.
This is a native Debug C receipt, not a new passing full-gate receipt.
No compiler, checker, or test-shape change forms part of this repair.
In that historical receipt, the PowerPC64 C boundary remained unsupported. Current linked-C results are recorded separately in section 11.
Issue #5 requires another aggregate-return ABI check during Zig 0.17 migration before the limit can change.

The first gate reported these remaining checker and cross results:

| Stage | Observed result |
|---|---|
| ziglint | 110 findings, exit 1 |
| zlint | Warnings, exit 0 |
| zbc | Integer overflow, exit 134. Existing issue #105 applies |
| zwanzig | 88 reported findings, 87 parsed findings, exit 1 |
| Strict cross x86 | Failed at the five C geometry checks |
| Strict cross AArch64 | Passed, 1643 tests plus 10 skips |
| Strict cross PowerPC64 | Failed at the known C ABI boundary |

The zwanzig report retains the known format and false-positive limits.
The user accepted publication with the PowerPC64 C limit and disclosed checker failures.
All checks remain enabled. Section 10.7 records the corrected-source gate receipt.

### 10.7 Corrected-source final gate

Artifact `614` records the corrected-source `zig-gate` output and exit 1.
This is not a green full-gate result.
No source or coordinate change followed the previous documentation integration.
The manifest-selected compiler and external tools remain unchanged.

| Stage | Actual result |
|---|---|
| fmt | PASS |
| build | PASS |
| test | PASS |
| ast-check | PASS |
| ziglint | 109 issues, exit 1 |
| zlint | 9 issues, exit 0 |
| zbc | Integer-overflow panic in the AST parameter scan, exit 134. Existing [zbc issue #105](https://github.com/CoffeeImpliesCode/zbc/issues/105) applies |
| zwanzig | 87 reported issues versus 86 parsed findings, exit 1. Parser count mismatch |
| strict cross | `status=fail pass=2 fail=1 build_only=0 partial=0` |

The zlint warnings comprise six `unsafe-undefined`, one `unused-decls`, one `suppressed-errors`, and one `no-print`.
The zwanzig parser counted three `analysis-limit-exceeded`, 24 `optional-unwrap`, one `store-violations-engine`, and 58 `unused-decl` findings.
The output reports a moved format because the reported total does not match the parsed diagnostics.
Neither zlint's exit 0 nor zbc's zero-diagnostic prefix establishes a warning-free or completed analysis.

The strict cross summary is `/tmp/cache/zaccesskit/cross-test/cross-test-summary.json`.
Its run ID is `20261008-021910-25483-19862`.
The per-target logs are under `/tmp/cache/zaccesskit/cross-test/runs/20261008-021910-25483-19862`.

| Target | Library tests | Linked C checks | Strict row |
|---|---|---|---|
| `x86_64-linux` | 1653/1653 PASS | 1676 checks, 0 failed | PASS |
| `aarch64-linux` | 1643/1653 PASS, 10 skipped | 1676 checks, 0 failed | PASS |
| `powerpc64-linux` | 1643/1653 pure Zig PASS, 10 skipped | Segmentation fault at the known compiler ABI defect | FAIL |

The cross failure is a real linked-C failure, not a timeout or build-only result.
The foreign library rows do not execute the Windows COM surface.
The pure Zig PowerPC64 result does not support its C consumer boundary.
[Issue #5](https://github.com/CoffeeImpliesCode/zaccesskit/issues/5) remains OPEN for the future Zig 0.17 ABI check.
No observed result establishes that Zig 0.17 fixes it.

The native Debug C repair retains the RED-to-GREEN evidence in section 10.6.
The self-hosted x86 Debug artifact failed five geometry checks.
The C artifact now requires LLVM without changing the compiler.
The focused `zig build test-c -Doptimize=Debug` run passed 7/7 steps and 1676 checks with 0 failed.
It recorded 598 allocations, 598 frees, and 0 active allocations.
This backend selection applies only to the C library, not the native Zig consumer module.

Run `bg_51`, recorded in artifact `616`, passed the counted native suite.
Its summary reported `Build Summary: 27/27 steps succeeded`.

| Shard | Debug passes | ReleaseSafe passes |
|---|---:|---:|
| Library | 1653 | 1653 |
| Integration | 860 | 860 |
| Reference | 767 | 767 |
| Benchmark | 9 | 9 |
| Committed decoder corpus replay | 356 | 356 |
| Total shard test executions | 3645 | 3645 |

All 7290 shard test executions passed across the two modes.
These totals count executions across overlapping shard imports, not unique test declarations.
The corpus results replay committed inputs. They do not establish mutation-fuzzing coverage.

The suite also executed the linked Debug C consumer.
It reported 1676 checks, 0 failed, 598 allocations, 598 frees, and 0 active allocations.
Its release counters were 184 strings, four custom actions, seven action lists, and 53 nodes.
It also released two tree infos and two tree updates.
This counted native-suite PASS does not change the failed full-gate or PowerPC64 linked-C receipts above.

At that historical publication, the user accepted the disclosed external-checker failures and unsupported PowerPC64 C boundary. Section 11 records later source-specific linked-C results.
All checks remain enabled.
The earlier ledger had 57 open rows. The reconciled source inventory is in `docs/52-translation-ledger.md`.
Hand-recorded reference cases remain finite source-reference evidence, not an executed Rust oracle or wire-parity proof.
These earlier receipts do not claim real-platform accessibility attachment.
Nogui remains source-only and was not executed.


## 11. Steps 1–4: source integration and observed limits

### 11.1 Evidence authority

The source baseline for this documentation workspace is `101f912320e225626ca833626dc2895eb0343418`.
Historical owner revisions are explicit in `docs/52-translation-ledger.md`.
Current counterpart coordinates use formatted source `d854c8b0d77385cf8c0c5983832369923fdef2d5`.
Earlier actual complete-graph receipts belong to pre-format source `3b4e07e5d05a960d57095405c339e7787436014a`.
Formatting adds no execution proof. Historical receipt, stack, and profiling coordinates remain unchanged.
Source integration is not a native SDK or bus result.
This documentation task ran no build, test, formatter, linter, native client, or nogui program.

The parent retained actual receipts under `/tmp/cache/zaccesskit/evidence/execute-1-4-red/` and `execute-1-4-green/`.
Each JSON receipt records the command, status, stdout, and stderr.
The directory name does not establish a PASS. The recorded status and executed test count do.
For example, `atomic-core-all.json` records a compile failure.
The later `atomic-core-final-fixture.json` records nine executed passing tests.
The zero-test `main-macos-context-portable.json` establishes no Mac context behavior.
Only the forced-import receipt below supports that claim.

### 11.2 Portable and compilation receipts

All focused JSON paths below are relative to `execute-1-4-green/`.

| Receipt | Observed result | Scope |
|---|---|---|
| `atomic-core-final-fixture.json` | Exit 0, 9/9 tests passed | Fail-N transaction rejection, focus, custom action ownership, recovery, subtree registration, metadata-only graft, relocation, and retry |
| `c-allocator-all.json` | Exit 0, 6/6 tests passed | Installed C allocator alignment and matching original-pointer release |
| `positioned-unicode.json` | Exit 0, 1/1 test passed | Decoded optional positioned edits changed a real Unicode consumer tree |
| `positioned-fifo.json` | Exit 0, 1/1 test passed | Ordered edits used the live host model before consumer publication |
| `positioned-readonly.json` | Exit 0, 1/1 test passed | Disabled and read-only consumer nodes refused positioned edits |
| `positioned-failn.json` | Exit 0, 1/1 test passed | Fail-N edits released each allocation |
| `positioned-reply-preflight.json` | Exit 0, 1/1 test passed | Reply limits refused the edit before host mutation |
| `mobile-owned-producers.json` | Exit 0, 3/3 tests passed | Android and iOS callbacks owned independent configured-domain values, plus the import harness |
| `mobile-interior-nul.json` | Exit 0, 3/3 tests passed | Both producers preserved borrowed bytes and released C allocations on `InteriorNul`, plus the import harness |
| `ios-public-diagnostic.json` | Exit 0, 2/2 tests passed | Actual public `OrphanChild` diagnostic, plus the import harness |
| `android-null-factory.json` | Exit 0, 2/2 tests passed | Actual null-factory diagnostic, plus the import harness |
| `ios-public-debug-raw-origin-green.json` | Exit 0, 1/1 test passed | Public string destructor released the configured raw CString after adapter free |
| `windows-root-c-error-green.json` | Exit 0, 1/1 test passed | Rejected public C update retained exact diagnostics and committed tree |
| `windows-root-debug-domain-green.json` | Exit 0, 1/1 test passed | Configured public string destructor owned the returned CString |
| `subclass-refusal-threaded-runtime-green.json` | Exit 0, 1/1 test passed | Constructor refusal left the caller runtime reusable |
| `subclass-oom-threaded-runtime-green.json` | Exit 0, 1/1 test passed | Each constructor allocation failure preserved caller runtime authority |
| `subclass-transfer-threaded-runtime-green.json` | Exit 0, 1/1 test passed | Successful transfer retained authority through the final weak handle |
| `macos-context-forced-import.json` | Exit 0, 10 passed, 2 skipped, 0 failed | Actual context admission, join, weak retention, payload release, pin limits, failure atomicity, scoped placeholder epoch, and Threaded runtime authority |
| `android-all-final-fixtures-debug.json` | Exit 1, 1676 passed, 0 skipped, 2 failed | Zero scroll maximum read as null. Queue-OOM fixture rejected before the intended post-commit queue allocation |
| `schema-sorted-merge-green.json` | Exit 0, 2/2 tests passed | Zero scroll maximum and interleaved owning strings survived sorted merge and fail-N |
| `schema-table-all-green.json` | Exit 0, 169/169 tests passed | Unconditional full property-table test import, including dependencies |
| `android-all-canonical-debug.json` | Exit 1, compilation failed before tests | Full declaration reachability exposed stale integration fixtures and error-domain assertions; no executed pass count |
| `android-all-canonical-releasesafe.json` | Exit 1, compilation failed before tests | Same analysis failures in ReleaseSafe; no executed pass count |
| `actual-daemon-sender-green.json` | Exit 0, 1/1 tests passed | Actual captured daemon Hello reply accepts the reserved driver sender and preserves the assigned unique name |
| `dbus-codec-all-green.json` | Exit 0, 32/32 tests passed | Entire codec and signature suite, including ordinary well-known sender spoof rejection |
| `android-public-update-error-reset.json` | Exit 0, 1/1 test passed | Actual public C update and public empty-queue cleanup reset diagnostics |
| `android-public-action-error-reset.json` | Exit 0, 1/1 test passed | Actual public C action and public empty-queue cleanup reset diagnostics |
| `android-complete-namespace-debug.json` | Exit 0, 209/209 tests passed | Qualified Android namespace, all thirteen modules, portable JNI seams |
| `android-complete-namespace-releasesafe.json` | Exit 0, 209/209 tests passed | Same complete namespace in ReleaseSafe; not real VM, SDK, or device proof |
| `queue-refused-cleanup-forced.json` | Exit 0, 1/1 test passed | Retains failed cleanup without duplicate delivery; earlier same-name red receipt crashed at address 0x11 |
| `queue-cancel-cleanup-forced.json` | Exit 0, 1/1 test passed | Cancellation/raise preserves value and provider lifetime; earlier same-name red receipt crashed at address 0x10 |
| `canonical-graph-source-corrected-debug.json` | Exit 0, 2008 passed, 43 skipped, 0 failed; total 2051 | Complete unfiltered public graph; two fuzz tests found |
| `canonical-graph-source-corrected-releasesafe.json` | Exit 0, 2008 passed, 43 skipped, 0 failed; total 2051 | Same complete graph in ReleaseSafe; skips are not PASS or SDK execution |

The three Windows runtime tests used actual `Io.concurrent` filesystem work and `Future.await`.
They did not infer runtime validity from copied function pointers.
The Mac skips require native Objective-C activation and hit-test window reentry.
The scoped Mac epoch covers placeholder-to-current-full publication only.
It does not establish generic per-node generations or permanent defunct state after an ID reappears.

The earlier Android full-module receipt was not green.
The zero-maximum failure exposed a sorted-property merge defect.
`execute-1-4-red/schema-sorted-merge-red.json` executed both regression tests and failed both.
The later focused and full-table receipts above passed after the insertion-order fix.
The queue-OOM fixture also required correction to reach the intended post-commit failure.
The earlier `android-all-canonical` receipts failed during compilation in both safety modes.
The earlier 2053-test graph exposed two Android diagnostic expectations and a Windows forwarding-only fixture COM-release crash.
The Android tests bypassed existing public C diagnostic reset; this did not establish a production Android defect.
The later complete graph executed 2051 tests in both modes but first failed:
Debug 1996 passed/43 skipped/12 failed; ReleaseSafe 1994 passed/43 skipped/14 failed.
`android-canonical-complete-debug.json`, `android-canonical-complete-releasesafe.json`, and
`canonical-full-graph-failure-inventory.json` retain the actual 26 failure contexts.
Seven test-fixture files were corrected without a production-semantic change or a new SDK skip.
Pre-format source `3b4e07e5d05a960d57095405c339e7787436014a` then passed the complete unfiltered graph in both modes:
**2008 passed, 43 skipped, 0 failed; total 2051, two fuzz tests found**, exit 0 for each receipt above.
The complete Android namespace independently passed 209/209 in each mode.
The required declaration guards remain enabled; they force analysis and are not behavior proof.
This closes named portable Android acceptance. Real JNI VM, SDK, device, and UIKit prerequisites remain unavailable.
The final project gate remains pending. Complete graph success is not a gate-success claim.

Main later observed `capi-parity` exit 0 in BG239: **7/7 build steps succeeded**.
It counted 499 function declarations, 273 enum variants, 500 source sites, and 58 matched guarded export records.
All five declared/exported symbol sets matched: Linux 448, macOS 458, iOS 455, Android 455, Windows 452.
The result had no mismatch, unreadable site, count disagreement, or guard disagreement.
Authority: Main's actual BG239 tool message. This is source/header parity, not project-gate or native SDK proof.

The earlier combined BG235 command exited 1 overall after 15/18 build steps succeeded.
Its `capi-parity` branch failed to compile. Other branches independently succeeded.
The linked C consumer passed 1690 checks with zero failures. Allocation counts were 598 allocations, 598 frees, zero active.
The public integration CLI exited 0. The reference CLI checked fifteen exact cases: seven geometry and eight text.
Those observations use Main's actual BG235 tool message, not fabricated JSON receipts.
They do not establish Rust runtime output, wire parity, SDK execution, or a green project gate.

Main later observed `zig build test --summary all` exit 0 in BG242 at source `9741daec59b72c4c0d25843bb3e5c9af2d3abd4a`: **31/31 build steps succeeded** (actual output `artifact://2721`).
Each root graph ran 2064 tests: **2021 passed, 43 SDK-related skips, zero failures**, in Debug and ReleaseSafe.
The separate fuzz shard passed 436/436 in each mode, with three fuzz tests found; benchmark tests passed 9/9.
Native contracts passed eighteen with one skip in each mode. Integration passed 918/918 and reference tests 785/785 in each mode.
These graph/shard counts overlap. Do not add them as unique tests or report a coverage percentage.
The linked C consumer passed 1690 checks with zero failures, 598 allocations, 598 frees, and zero active allocations.
The project gate is still not green. At that source9741 receipt, the PowerPC strict linked-C failure still required a source correction. Later source-specific C results follow below; the complete project gate still needs its own observed receipt.

The parent observed eight focused transport receipts: `execute-1-4-green/transport-bounds-{1,2,3,4}-{debug,releasesafe}.json`.
Each ran one test and exited 0 in its named mode. Their frozen owner source is `619d46f2d4970734cd1b962534cbc1c7650a8d56`.
The address-alternative case preserves the last candidate failure under a byte-derived bound.
The PumpLimit cases cover owner-loop exhaustion, accepted work settlement, and terminal-cause propagation.
These are portable focused tests, not injected native-loop exhaustion or a new complete project gate.
`PumpLimit` uses the existing static `@errorName` diagnostic path; no C error category, header enum tag, or registry API is added.

Main observed root build BG250 at source `320cb011918e099317136c226d43a2abf3d665d0` exit 0, **31/31 build steps succeeded** (`artifact://2827`). This receipt predates current source `d854c8b0d77385cf8c0c5983832369923fdef2d5` and is not build or test evidence for current source.
Each source320 root graph ran **2071 tests: 2028 passed, 43 SDK skips, zero failures**, in Debug and ReleaseSafe; two root fuzz tests were found.
The separate fuzz shard passed 440/440 in each mode with three fuzz tests found. Benchmarks passed 9/9, integration 918/918, and reference 785/785 in each mode; native contracts passed eighteen with one skip in each mode.
Those graph/shard counts overlap and are not summed as unique tests. The native Debug C consumer passed 34594 checks with zero failures, 2093 allocations, 2093 frees, and zero active allocations. No second C-consumer mode is claimed without its own receipt.
The historical strict linked PowerPC C run BG249 was red (`artifact://2826`): the source320 getter return families improved, but color/decoration and TreeId setter-input mismatches remained and the Rect case faulted.
That source320 receipt established neither a passing PowerPC linked-C boundary nor a green project gate. Later results belong to their own source identity.

Main observed current source `d854c8b0d77385cf8c0c5983832369923fdef2d5` root build BG262 exit 0: **31/31 build steps succeeded** (`artifact://2946`). Each Debug and ReleaseSafe root graph ran **2070 tests: 2027 passed, 43 SDK skips, zero failures**; two root fuzz tests were discovered.
The separate integration shard passed 918/918 per mode, with one fuzz test discovered; reference passed 785/785, fuzz 440/440 with three fuzz tests discovered, and benchmarks 9/9 per mode. Native contracts passed eighteen with one real SDK skip in each mode. These graph/shard counts overlap and are not added as unique tests or coverage percentages.
The native Debug C consumer passed **37240 checks with zero failures**, 2095 allocations, 2095 frees, zero active allocations; strings 1669, custom-action lists 4, action lists 7, nodes 55, tree infos 2, tree updates 3. The parent's actual QEMU powerpc64-linux-musl and aarch64-linux-musl Debug C commands also each passed 37240 checks with zero failures and the same allocation/cleanup totals; 7/7 build steps succeeded per target. Authority for the cross-target results is the parent's observed tool output; no unavailable JSON receipt is invented and no second C optimize mode is inferred.
The prior mixed receipt `artifact://2918` passed its unit shards but failed one new C-consumer debug-string oracle, not a library ABI regression. The incidental oracle was removed; the current passing results above supersede that fixture failure. Exact observable TreeId byte, input-copy, allocation/error, and copied-getter-independence tests remain.
The private musl lowering establishes the exercised current library boundaries; it is not a compiler fix. Independent original canonical Zig 0.16.0 controls remain failed, and issue #5 remains open. A future removal requires original canonical tests in both modes, direct/function-pointer calls, and unchanged inputs.
**The full project `zig-gate` has not run for this source.** Root and three Debug C-consumer successes do not imply all-stage gate success, Windows/Mac SDK execution, Android VM or UIKit/device execution, GUI execution, or a private nogui run.

Native SDK scope: the public repository workflow `.github/workflows/native-sdk.yml:33-34,40-49,249-265` at immutable source `d854c8b0d77385cf8c0c5983832369923fdef2d5` arranges Windows (`windows-2022`) and macOS (`macos-15`) clients only. The parent observed SHA-256 `10861b0dca99ae6642680df53afae68b15d0043ce4e747713edab927d340a54e` for that exact immutable workflow file; this is provenance, not a hosted SDK run. Their hosted runs are pending; neither has an observed SDK runtime result. It does not arrange Android or iOS acceptance lanes.
Android is blocked by missing source and build inputs, not only the absence of a local VM. `src/adapters/android/root.zig:61-66` requires the unshipped Delegate Java/Dex input; `src/adapters/android/classes.zig:23-32` names `dev.accesskit.android.Delegate`. No checked-in Activity/APK, manifest/Gradle app, NDK shared-library route, or emulator-accessibility client is available in the inspected scope. Portable JNI-contract tests do not close the packaged-build, JVM, or device requirements.
iOS has three current native-object gaps (`src/adapters/ios/root.zig:197-219`): accessibility elements returns an empty array, hit testing returns no UIKit node object, and queued node notifications carry a null node (`:460-479,699-745`). The node's Objective-C object stays null because instance initialization is missing (`:61-81,920-970`). There is also no checked-in UIKit application, Xcode/XCTest target, or simulator lane. A runner alone cannot satisfy real native-tree acceptance before these source and build prerequisites exist.
These are explicit missing prerequisites for the required platform steps, not substitutes or completed acceptance. No Windows/Mac SDK, Android VM/device, iOS UIKit/device, GUI, or private nogui result is inferred. The feasibility investigation ran no app, SDK job, emulator, or simulator.

`execute-1-4-red/android-public-c-reset-mutant.json` records an actual isolated implementation mutation:
only the two public-wrapper `clearError` calls at historical mutation coordinates `src/capi/platform.zig:891,971` were removed.
The real public C update/action regressions both failed (`expected .none, found .operation_failed`);
the run exited 1 with one pass and two failures.
`execute-1-4-green/android-public-c-reset-restored.json` records restoration of the exact canonical file,
exit 0 and all three tests passing, including actual C update/metadata conversion.
Main production was not mutated, and no mutant remains.
The table-only source snapshot is `e8cd20cbd2b07ab3b96bf0ce97c0c3db3aa1e14a`.
The parent integrated it at `269a754c91f8b5efcf8d7e977777fcd827accb59`.
The source map is `accesskit/src/lib.rs:1164-1167` to `src/schema/props/table.zig:1512-1563`.

The parent observation record is `local://native-contract-and-sdk-observed.json`.

| Exact parent command | Observed result | Limit |
|---|---|---|
| `zig build native-contract --prefix /tmp/cache/zaccesskit/execute-1-4-out` | Exit 0. Debug: 18 passed, 1 skipped. ReleaseSafe: 18 passed, 1 skipped | The custom NSWindow focus case requires a real macOS SDK and runtime |
| `zig build windows-native-client -Dtarget=x86_64-windows-gnu --prefix /tmp/cache/zaccesskit/execute-1-4-windows-out` | Exit 0 | Cross-compilation only. No Windows client executed |

Portable receipts do not prove UI Automation, AppKit, VoiceOver, or JNI behavior.
No Mac SDK client result exists in this record. Current source-only cleanup is `tools/macos_native_client.zig:18-38,873-879,881-939`; no SDK client execution is claimed.
`execute-1-4-green/native-sdk-workflow-host-guard.json` records actual embedded Node execution on Linux.
The Windows-selected lane exited 1 with `Wrong Windows host` before any compiler/client command.
This proves the wrong-host guard fails closed only. It is not PowerShell parsing, SDK compilation, or native Windows/macOS execution.
There is no iOS or Android SDK-client executable, app, or device run step.
The library constructors are not native client entrypoints (`build.zig:200-275,678-707`).
The iOS accessibility-element, hit-test, and node-notification gaps remain
at `src/adapters/ios/root.zig:199-228,894-944`.
Android still needs the real VM, view, delegate class, SDK/NDK, and device or emulator lane
(`src/adapters/android/injecting.zig:80-107,154-177`, `jni.zig:10-16`, `jni_table.zig:23-36`).
Portable mobile tests and minimal compiler probes establish none of these native prerequisites.

### 11.3 Real Linux observation

The earlier parent run started an actual GNOME accessibility registry.
An independent `GetChildren` call returned `(@a(so) [],)`.
The provider start then returned `START_REJECTED InvalidHeader remote=none`.
That red observation is preserved in `local://native-contract-and-sdk-observed.json`.

The later sender correction is `c6ac4e75eb6c3596a430e9f0f9088aee8576c56a`.
Main compiled the CLI with exit 0 and started an owned D-Bus daemon and actual GNOME accessibility service.
The provider reported `OUTCOME committed attachment 1 usedfull true notif none`.
Independent `busctl` identified provider `:1.2`; independent stock `gdbus` then returned
`[(':1.2', objectpath '/org/a11y/atspi/accessible/root')]` from registry `GetChildren`.
This is observed registration, not inferred registration from a synthetic peer.
The independent read-only interface matrix is now observed.
Bounded callbacks, positioned edits, metadata updates, status epochs, events, and provider close now have real receipts.
Later receipts cover bounds, native tree OOM/retry, committed notification failure, reorder, and main-provider close.
`native-removal-source-confirmed.json` confirms that removed-path `UnknownObject` is correct after unregistering all interfaces.

`execute-1-4-green/native-peer-actions.json` records 54 actual stock `gdbus` and `busctl` commands.
All 54 matched their expected replies or D-Bus errors.
Two are no-reply submissions; exit 0 does not prove the host callback ran.
The receipt excludes positioned `InsertText` and `DeleteText`.
It contains no publication, reorder, removal, edit commit, or close operation.
`execute-1-4-green/native-peer-action-callbacks.json` supplies the later provider-stdout correlation.
All 32 complete action requests matched the independent command inventory, including both no-reply cases.
Tree IDs, targets, action data, text-run coordinates, and scroll coordinates were compared.
This does not imply that the host committed every requested mutation.

`execute-1-4-green/native-peer-queries.json` records 108 logical read-only rows,
each checked by both stock `gdbus` and `busctl`: 216 independent client invocations.
All rows and all client assertions matched.
`GetAll` covered all twelve interfaces on thirteen paths.
Both clients decoded fourteen cache items.
Twenty-seven direct property rows returned twenty-four supported values and three exact `NotSupported` results.
The receipt includes eleven introspection rows, three standard-method rows, and fifty-four AT-SPI read-only method rows.
It issued no mutators and used no socket mock.
The source-backed oracle corrections are Application 75, ControllerFor 3, and Widget layer 3.
They correct stale driver expectations, not production values.

| Actual native receipt | Observed result | Scope and limit |
|---|---|---|
| `native-metadata-lifecycle.json` | 101/101 checks passed | Null hook: five exact `NotSupported` replies, no callbacks or text change. Owned C metadata survives free; invalid `RootNotInTree` publication preserves baseline, then corrected metadata and ordinary delta publish. Real property/name/value/text signals and two provider close/join cases passed |
| `native-status-epochs.json` | 106/106 checks passed; 153 independent RPC receipts | Session-bus discovery, deferred empty cache, rejected `OrphanChild` baseline, full retry, disable/enable, new unique names, reattachment full followed by delta. Two provider closes returned 0 with no late callbacks; initial status was restored |
| `native-positioned-fifo.json` | Eight actual RPCs | Two edits were accepted against a stale published frame. Text stayed `Aé😀B` until host drain and publication, then became `AéΩ😀😀`, scalar count 5 and caret 5. Independent delete/insert signals were captured |
| `native-positioned-boundaries.json` | 114/114 checks passed | Byte-prefix/scalar validation, no-hook invalid arguments, clipped delete bound, eight-item queue, QueueFull/PayloadLimit refusal, exact 1024-byte live-text boundary, and fresh-drain TextLimit rejection. Three providers closed 0 with zero late callbacks |
| `native-tree-oom-baseline.json` and `native-tree-oom-retry.json` | Actual `OutOfMemory` rejection, then accepted cached publication | Native Save/value 0 and previously committed edits survive rejection; retry publishes Saved/value 1 and preserves edits |
| `native-committed-notification-error.json` and `native-full-rejection-baseline.json` | Commit with `GeometryOutOfRange` notification failure, then exact `MissingFullNode` rejection | Host accepted baseline advanced on commit; later rejection preserved that error-bearing accepted baseline. Native geometry query returned exact Failed/GeometryOutOfRange |
| `native-reorder-and-notification-repair.json` | Independent native geometry/order/index/selection readback | Repaired extents `(20,80,200,30)`, children 6 then 5, indexes 0 then 1, selected child 6 |
| `native-properties-signals-and-no-reply.json` | Native Id 19 property signal/readback and two exact numeric-value callbacks | Reply and no-reply requests carry 2.5. Native value and signals stay at source value 0.0: callback delivery is not an automatic host edit |
| `native-main-provider-close.json` | Provider exited 0; process absent; registry empty; old service unavailable | Closed stats: seven commits, two rejections, 34 actions, one deactivation, zero late callbacks. Task join and userdata-lifetime markers were observed |
| `native-removal-source-confirmed.json` | Node 2 absent from native children/cache; old path returns UnknownObject | Pinned source confirms defunct/cache removal before unregistering. Old focus clears, root focus sets, defunct/cache-removal/children-removal signals are observed. Original wrong driver expectation remains in `native-removal-initial-oracle.json`; production was not changed |
| `native-owned-services-stop.json` | Five task-owned services exited after SIGTERM; kernel exit verified with PIDFD identity | Actual UID/cmdline/environment scope excludes the parent chain. No KILL was needed. This is scoped owned-service shutdown, not proof of unrestricted process visibility or full scratch cleanup |

The fresh `execute-1-4-green/final-native-bus-smoke.json` uses source `9741daec59b72c4c0d25843bb3e5c9af2d3abd4a`.
Its provider binary has SHA-256 `a441974a18b5dfccf381390879dc5b996372b74520251690af6e60a08c1cd4ce`.
Both stock clients observed one registered provider root, nine window children, and fourteen cache entries.
Removal left eight children and thirteen cache entries. Both clients received UnknownObject for the removed path and ServiceUnknown after close.
Name/value signals, focus off/on, reordered children, positioned Unicode edits, four actions, and two applied edits were observed.
The exposed action count was one: click. This receipt does not exercise custom action 42.
The provider closed with zero late callbacks, joined tasks, live userdata, and an empty registry for both clients.
All owned services stopped through PIDFD-identified SIGTERM; none remained, and private status settings were restored.
The three initial busctl negative-1 option-parser failures remain in the receipt; `--` corrected those commands.
This smoke does not inject post-commit Register.sync OutOfMemory. The new registration/reconciliation failure cases have separate portable focused receipts.
Native consumer/tree OOM is a different proof. No GUI, private nogui, Windows/Mac SDK, VM/UIKit, or device run is claimed.

`execute-1-4-green/approved-bounded-native-bus-smoke.json` is the accepted bounded native rerun at source `c45632aa2fe6bcdf344ac7745b9a4350080309ee`.
Its provider binary SHA-256 is `f8b7a1c6213a2805def7d3612f21079821f1a86336152f4d0a9433a160f8df5b`.
The receipt records fourteen commits, two click actions, eleven queued/applied edits, zero rejected/refused edits, and zero late callbacks.
It checks the 256-byte replacement and 1024-byte text/end boundaries, real signals, registry removal, close/join, and live userdata.
Five owned services exited after UID/PIDFD-identified SIGTERM, with no KILL or unrelated-process shutdown. Both private status getters returned their initial false values after restoration.
The earlier raw `bounded-native-bus-smoke.json` is not accepted approved-storage proof: the launcher discarded a socket name of at least 100 bytes and fell back to `/tmp`. That attempt remains preserved.
The accepted rerun used a shorter approved path and verified both GetAddress and the daemon's explicit approved address before provider start.
This proves bounded native transport in that binary, not native injected OOM, custom action 42, GUI/nogui, or Windows/Mac SDK/device execution. The later source320 node-properties delta does not re-identify this c456 execution receipt.

These are stock-client and actual-provider observations, not socket mocks.
Each receipt preserves its command-parser or expectation-harness corrections and original failed attempts.
Removal maps AccessKit `466e24e252103f4d82bd6fbab98141b551e46e0c`
`adapters/atspi-common/src/adapter.rs:324-347` and `adapters/unix/src/atspi/bus.rs:194-254`
to `src/adapters/atspi/objects.zig:124-141,144-211` and `src/adapters/atspi/dispatch.zig:172-227,384-390,489-518`.
`zbus` 5.19.0 `src/object_server/mod.rs:408-421` returns `UnknownObject` after interface removal.
An internal retained node can report defunct; that does not make an unregistered bus path callable.

The earlier focused fuzz red expected four corpus descriptors and observed five
(`execute-1-4-red/fuzz-corpus-stale-shape.json`).
`execute-1-4-green/fuzz-corpus-current-shapes.json` records three passing focused tests, exit 0.
The correction removes incidental count/frame-shape/byte-identity assumptions.
Descriptor hashes, strict decoding, canonical fixed points, truncation, and inversion mutations remain required.
The real daemon Hello reply can use valid noncanonical header order. No new fixed corpus count is pinned.

The C metadata receipt distinguishes the first required full publication from the final actual delta.
The main-provider close receipt now supplies the separate final close/join observation.
The positioned boundary receipt explicitly does not exercise native edit-head `OutOfMemory` retry.
The existing focused unit fail-N receipt covers that ownership case; native tree OOM is not a substitute.
This is a controlled real GNOME registry/bus and provider-CLI scope, not GUI-application or screen-reader proof.

The accepted captured frame is the actual 89-byte daemon Hello return, not a hand-derived packet.
`src/adapters/atspi/dbus_corpus/daemon-hello-return.bin` has SHA-256
`59de2c6f17737b660704386754a904f823fd2e5543c254277190fb12c59e39d7`.
The capture is `execute-1-4-green/native-startup-bounded-wire-red.json`.
`src/adapters/atspi/dbus.zig:855` records it as the fifth corpus descriptor.
`actual-daemon-sender-green.json` and `dbus-codec-all-green.json` prove captured-frame decoding and the sender grammar tests.
They do not replace the independent live matrix.

### 11.4 Recorded geometry and profiling

The fixture inventory now contains seven geometry cases and eight text cases.
`test/fixtures/geometry.json:7-9` adds independent far-edge exclusion, empty-origin containment, and all-zero affine inverse classification.
The pinned source is `accesskit/src/geometry.rs:519-521,99-113`.
`reference_root.zig:194-209,260-280` checks the same production operations through schema and C routes.
`test/c_consumer/consumer.c:1791-1810,1867-1876` adds independent public C assertions.
The geometry body has 3097 bytes.
Its SHA-256 is `6d56a673b21d02425e35adab4d23f0cfb54fd7a5afd191eb1124c21f86848e04`.

These values are finite, source-derived, hand-recorded fixtures.
They are not Rust runtime output or wire-parity proof.
The six-NaN inverse result applies to the all-zero affine fixture, not every singular matrix.
Earlier twelve-case receipts remain twelve-case evidence.
Main also observed `zig build reference-run` exit 0 with all 15 recorded cases executed:
seven geometry cases and eight text cases.
That CLI observation exercises the stored source-derived expectations.
It does not convert them into Rust runtime output or wire-parity proof.
The later parent command `zig build reference --prefix /tmp/cache/zaccesskit/execute-1-4-out`
exited 0. Debug and ReleaseSafe each reported `All 785 tests passed.`
Full raw stdout is `artifact://2343` (1580 lines).
The deliberate wrong-expected-value cases printed mismatch diagnostics and then returned OK.
Those diagnostics prove rejection of an incorrect fixture oracle; they are not suite failures.
This observed reference-suite result still does not prove SDK execution or a Rust runtime oracle.
`execute-1-4-red/geometry-inclusive-x-mutant-cli.json` records a distinct implementation mutation.
The mutant admitted the far x edge; the real CLI exited 1 with `OutputMismatch`
at point `(30, 0)`, expected false and actual true.
This is an observed implementation-mutant rejection, not the passing wrong-oracle test diagnostics above.
`execute-1-4-green/geometry-restored-cli.json` records the post-restoration green run.
`zig build reference-run -j1 -Doptimize=Debug --prefix /tmp/cache/zaccesskit/execute-1-4-mutation-out`
exited 0 and checked both fixture lengths and hashes, then all fifteen exact schema/C outputs.
This completes the observed implementation-mutant red/restored-green pair without a Rust runtime oracle.

The earlier `local://current-lbr-attribution.json` records source-attributed synthetic whole-process profiles.
Its profiled binary predates the transaction changes.
The attribution does not justify a production optimization.
No speedup or native accessibility latency claim follows from these profiles.

The canonical later capture is `/tmp/cache/zaccesskit/evidence/sparse-attribution-canonical65536-20261008/`.
`execution-receipts.json` records six sequential CLI runs, all exit 0: plain, counted, and LBR for each case.
`attribution-summary.json` records matching semantic digests across all three modes.
Binary SHA-256: `df6f1b6d6c6b0cb5ff85b7d9b2a2dcb6b69e522d76c889a22565ee9903e58c50`.
The binary is Zig 0.16.0 ReleaseSafe with the observed host glibc 2.40 CRT.

| Case | Nodes / updates / changed nodes | Output digest | Allocations / frees | Live / peak bytes |
|---|---|---|---|---|
| Sparse | 65536 / 128 / 1 | `0fd54e4524fbac76` | 616179 / 616179 | 0 / 119256760 |
| Dense | 4096 / 128 / 64 | `62a1c1ace055b526` | 107347 / 107347 | 0 / 7339832 |

Sparse sampled-cycle period shares were 55.37% initial consumer setup, 19.62% oracles,
16.40% final teardown, and 1.23% update pipeline. Only 19 of 1830 samples reached that pipeline.
Dense update-pipeline share was 59.95%, with 164 of 309 samples.
No samples were lost. Unresolved-leaf period shares were 1.32% sparse and 0.85% dense.
These weighted period shares are not wall-clock phase timings or native notification latency.
Each case/mode ran once; 32-entry LBR history does not establish complete call chains.
Historical binary-DWARF attribution retains `tools/consumer_bench/main.zig:392-417` and `src/consumer/tree.zig:290-342,438-453,481-696`.
These are capture coordinates, not formatted-420 coordinates. `attribution-summary.json` records the source hashes:
`tools/consumer_bench/main.zig`: `94684fdced37dd8ae57ff5e5ff30bce5d60873a7fd421ef72d4b31634fc11f48`.
`src/consumer/tree.zig`: `888ca65558b5374a532c8e0b11304f8b1a7554bb8d184ad4371a7f060ab61314`.
The initial two-state copy runs once. Dirty-recovery cloning is skipped on all 128 successful updates.
Decision: **NO_OPTIMIZATION**. No safe, measurable production hotspot follows from these captures.
Do not suppress safety poisoning or atomic preparation. Historical Nix glibc 2.42 profiles are not a coherent speedup baseline.

### 11.5 Public consumer usage limit

The public usage contract requires explicit allocator, I/O, runtime authority, callbacks, current-full publication, and close barriers.
The host keeps its accepted baseline unchanged after a rejected update.
After a committed update, the host advances that baseline even when notification delivery reports an error.
The host retains runtime authority through providers and queued notifications, not only through adapter close.
`docs/30-port-design.md` section 12 and `docs/52-translation-ledger.md` map these contracts.

The nogui migration is source-only.
No nogui build, test, launch, headless execution, native attachment, or runtime equivalence result is claimed.
This record publishes no private paths, source snippets, or private fixtures.
