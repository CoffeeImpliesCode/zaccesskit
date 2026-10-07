# 50-risk-register

**What this document is.** The register of risks for this port. One entry per
risk. Every entry names what can go wrong, how likely it is, what it costs, what
would detect it, and what mitigates it. An entry that cannot be mitigated inside
this repository says so and names the dependency that leaves.

**Why the register is beside the design records and not inside one.** The records
under `docs/` hold measurements. This file holds the entries that survive into
the schedule in `docs/40-plan.md`. It is the only place where a measured defect,
a milestone and a mitigation meet.

**Relationship to the research-phase register.** The first register is
`local://zaccesskit-risk-register.md`. It is a research artifact and it stays
where it is. Its ids are stable, so R1 to R15 mean the same thing here. Every
existing citation of an id still resolves, in `README.md:130`, in
`docs/30-port-design.md`, in `docs/40-plan.md:196-201`, in
`docs/41-atspi-build-map.md:635-638` and in `docs/50-verification.md`. This file
adds R16 to R20, moves R5 to RR3, and owns the register from here.

**Evidence labels.** The three labels in `docs/50-verification.md` section 1.1
apply. SR is a statement read at a pinned revision. EC is a compiler run. RO is
a running program. An entry with no label supports nothing.

**Id names.** `R<n>` names an entry in this file. Other documents keep their own
numbered records, so this file writes "the record it numbers R5" rather than
"record R5" wherever it points into `docs/30-port-design.md`.

**What this run did.** It read the corpus and took two counts on this host: the
line count of `include/zaccesskit.h`, and the number of lines in that header that
carry a `*_free` declaration. It ran no build, no probe, no bus call and no test
suite. Every other number is quoted from the document named beside it.

---

## 0.1 The fields of an entry

| Field | The question it answers |
|---|---|
| Class | Is this a milestone blocker, a fact about someone else's code, an operational hazard, a wrong planning figure, a gap in a house tool, or a choice another document owns? |
| Severity | How much of the schedule it costs. S1 is highest, S4 lowest. |
| Milestone | Which milestone in `docs/40-plan.md` it lands on, or "none" |
| What can go wrong | The failure, stated as an outcome |
| How likely | The probability, with the reason it has that probability |
| What it costs | Lines, gates or a blocked milestone |
| What would detect it | The observation that fires. Never "watch for it". |
| What mitigates it | The action, or the dependency outside this repository that the action needs |
| Mitigable here | Yes or no. When no, the entry names what leaves |

**The classes.**

| Class | Meaning |
|---|---|
| `blocker` | A milestone does not complete until this is closed |
| `fact` | A property of a library or a toolchain outside this repository |
| `hazard` | Damage to the host, not a build failure |
| `estimate` | A planning figure that mis-sizes work |
| `tooling` | A house tool that will not do what the plan expects of it |
| `decision` | A choice that another document owns |

---

## 1. The index

| Id | Subject | Class | Milestone | Severity | Status | Mitigable here |
|---|---|---|---|---|---|---|
| R1 | goose cannot export AT-SPI objects unmodified | blocker | M5, M6 | S2 | open, route fixed | yes |
| R2 | zio 0.18.0 has no virtual clock and no injectable `Io` | fact | all | S3 | open, obligation taken | yes |
| R3 | The house gate has no fuzz stage and no branch coverage | tooling | M0 | S3 | open | yes |
| R4 | The test runner must stay in server mode | tooling | M0 | S4 | open, currently correct | yes |
| R5 | The X11 extension headers are missing | fact | none | none | **removed, see RR3** | not needed |
| R6 | AT-SPI is the only adapter with a live protocol here | decision | M6, M11 | S3 | open, open question | yes |
| R7 | The C ABI lives in a second upstream repository | fact | M4 | S4 | corrected, not a skew | yes |
| R8 | Three more goose gaps for the AT-SPI path | blocker | M5 | S2 | open, two avoided | yes |
| R9 | `-ffuzz` does not compile in Zig 0.16.0 | fact | M0 | S2 | open, substitute required | **no** |
| R10 | `-femit-h` is broken, so the C header is checked in | fact | M4 | S2 | open, route fixed | **no** |
| R11 | `zig translate-c` covers the whole AccessKit C ABI | fact | M4 | S4 | open, forward-looking | yes |
| R12 | goose and zio disagree about `O_NONBLOCK` | blocker | M5 | **S1** | open, **not fixable here** | **no** |
| R13 | The C ABI is flat, with no vtable and no error type | decision | M4 | S2 | open | yes |
| R14 | The C header is not stable | fact | M4 | S3 | open | **no** |
| R15 | Three ownership gaps in the upstream header | fact | M4 | S3 | open, mitigable here | yes |
| R16 | goose never learns its own unique bus name | blocker | M6 | **S1** | open, **not fixable here** | **no** |
| R17 | `Socket.Embed` with a foreign plug name kills `at-spi2-registryd` | hazard | M6 | **S1** | open, damaged a host twice | partly |
| R18 | Eight stale figures in `docs/16`, three of them in a budget | estimate | M8, M9, M10 | S2 | open, correct from the record | yes |
| R19 | `docs/31` section 3 row 16 overcounts the `*_free` functions | estimate | M4 | S3 | corrected, near-miss recorded | yes |
| R20 | How Zig 0.16.0 lowers a 48-byte aggregate return | decision | M4 | S2 | open, undecided | partly |
| RR1 | `zig translate-c` is unverified in this environment | removed | M4 | none | **removed** | no longer a risk |
| RR2 | No usable Zig package for UI Automation | removed | M7 | none | **removed** | no longer a risk |
| RR3 | The missing X11 headers block the port | removed | none | none | **removed** | no longer a risk |

---

## 2. The entries

### R1. goose cannot export AT-SPI objects unmodified

| | |
|---|---|
| Class | blocker |
| Severity | S2 high |
| Milestone | M5, M6 |
| Mitigable here | Yes. Route (b) keeps the connection and the message layer and moves the object layer into this repository. |

**Source.** `docs/13-atspi-protocol.md` findings G1 to G6, and `docs/41` section
3.1.

**What can go wrong.** The adapter publishes `Accessible`, `Action`, `Component`,
`Text` and the rest on the accessibility bus and answers method calls on them.
goose's object export path is the weakest part of the library, and it is the part
this adapter needs. Used unmodified it leaks object paths, asks for a well-known
name the port must not own, matches a member by its Zig declaration name, and
collapses every error into one D-Bus error.

| Id | Gap | Evidence | Severity |
|---|---|---|---|
| G1 | No unregister. `registered_interfaces` is append-only and drains only on close | `connection.zig:740`, `:603-606` | blocker |
| G1b | `registered_interfaces` has no mutex while `dispatchUnsolicited` iterates it from a dispatch thread | `connection.zig:934-937` | correctness bug |
| G2 | No path index. Every incoming call scans the whole wrapper list | same | performance |
| G3 | `registerObject` always calls `requestName`. AccessKit must own no well-known name | `connection.zig:701` | blocker |
| G4 | `SocketIterator` parses only `unix:path=` while the launcher emits `unix:abstract=` on some systems | `connection.zig:1458-1473`, `at-spi-bus-launcher.c:541` | portability |
| G5, G6 | The member name is the Zig declaration name, and every error becomes `org.freedesktop.DBus.Error.Failed` | `dispatcher.zig:264`, `:298` | correctness |

**How likely.** Certain if the port exports objects through goose. `docs/41`
section 3.1 marks G1, G2, G3, G5 and G6 as HIT for this adapter.

**What it costs.** `docs/30-port-design.md` section 7.2 item 6 budgets the
dispatcher, the path index, the typed error mapping and the address parser at
630 lines in total. That document says the port does not exist, so the figure is
a budget and not a measurement. Read it as an estimate.

**What would detect it.** A removed node path that still answers a call, or a
member that the bus reaches under a `camelCase` name and never finds.

**What mitigates it.** The route is decided. goose supplies the connection and
the message layer. The port owns the dispatcher, the path index, the typed error
mapping and the bus address lookup (`docs/40-plan.md:198-201`). G4 also needs
port code for `unix:abstract=`, about 40 lines, and this host cannot exercise
it, so it stays unverified until another host serves that form.

**The trigger that reopens this entry.** A second task appears that touches the
object register. `docs/41` records G1b as avoided by construction, and the
avoidance depends on one task owning the register.

### R2. zio 0.18.0 has no virtual clock and no injectable `Io`

| | |
|---|---|
| Class | fact about a third-party library |
| Severity | S3 medium |
| Milestone | every milestone, through the test strategy |
| Mitigable here | Yes, by lifting time into a parameter. No, by patching zio, which this project does not do unilaterally. |

**Source.** `docs/18-testing-strategy.md` section 3.5, and `AGENTS.md` section 3.3.

**What can go wrong.** `Timestamp.now` calls straight into `os.time`, and zio's
own runner builds a real `Io.Threaded` per test. A port test cannot control time
and cannot substitute a deterministic backend through zio as it stands.

**How likely.** Certain for any timed operation, and every adapter deadline is
timed.

**What it costs.** A test that waits on a real clock is not a unit test, and the
alternative is a time seam in each adapter.

**What would detect it.** A grep for `Timestamp.now`, `os.time`,
`nanoTimestamp` and `Instant.now` over `src/` that returns a line outside a
test.

**What mitigates it.** `AGENTS.md` section 3.3 already lifts time into a
parameter or a struct field, and a test supplies it. zio keeps its behaviour and
nothing in this repository patches it.

### R3. The house gate has no fuzz stage and no branch coverage

| | |
|---|---|
| Class | tooling |
| Severity | S3 medium |
| Milestone | M0, and every gate line in `docs/40-plan.md` that wants fuzzing |
| Mitigable here | Yes. Both the step and the gate line are this project's. |

**Source.** `docs/18-testing-strategy.md`, and
`~/.local/bin/zig-gate`, 823 lines.

**What can go wrong.** `zig-gate` runs fmt, build, test, ast-check, ziglint,
zlint, zbc, zwanzig, cross-test and zig-cov. `grep -n fuzz` over the script
returns nothing, and `zig-cov` measures line coverage only, and only when
`--cov` is passed.

**How likely.** Certain. A `fuzz` build step never runs unless a gate line names
it.

**What it costs.** A milestone line in the plan that reads like a gate and never
executes, which is worse than no line, because a reader counts it.

**What would detect it.** A green gate log with nine stage headers where a fuzz
line was expected, or a run in which `zig build fuzz` never appears.

**What mitigates it.** A `fuzz` build step with its own corpus directory, and an
explicit gate line in `docs/40-plan.md`. R9 says the stage cannot compile today,
so the substitute is a deterministic generator that replays a committed corpus.

### R4. The test runner must stay in server mode

| | |
|---|---|
| Class | tooling |
| Severity | S4 low |
| Milestone | M0 |
| Mitigable here | Yes. |

**Source.** `docs/18-testing-strategy.md`, and zio's own `build.zig:114`.

**What can go wrong.** zio sets `.mode = .simple`, which drops the counted
results, and the compiler's server-mode runner panics with `fuzz test requires
server` under that mode. A project that copies zio's wiring loses both the count
and fuzzing.

**How likely.** Low today. `zaccesskit/build.zig` uses `b.addTest` with no mode
override.

**What it costs.** A `zig build test` that prints no count. `docs/50` section 2.4
item 2 says to read that as a harness failure and not as a clean run.

**What would detect it.** A `zig build test` run that prints no test count and no
`skipped` line.

**What mitigates it.** Keep the default server mode and state it in `AGENTS.md`
so a future editor does not copy zio's shortcut. The integration owner reported
706 tests passing over the whole package on 2026-10-05. This run did not execute
the suite and does not restate that count as its own observation.

### R6. AT-SPI is the only adapter with a live protocol on this host

| | |
|---|---|
| Class | decision |
| Severity | S3 medium |
| Milestone | M6, M11 |
| Mitigable here | Yes. |

**Source.** `docs/05-platform-feasibility.md`, `docs/41` section 7 open question
5, and upstream `adapters/unix/src/adapter.rs:173` and `:222`.

**What can go wrong.** The unix adapter exposes `set_root_window_bounds` and
`update_window_focus_state` as calls the application makes. The adapter has no
source for either value, and this host has no X11 or Wayland client to ask.

**How likely.** Certain. No code path in the port can discover a window geometry
on this host.

**What it costs.** An obligation no other adapter carries, and an open question
that `docs/41` hands to `docs/30`.

**What would detect it.** M11 starts before `docs/30-port-design.md` names how a
Zig application obtains both values on each platform.

**What mitigates it.** The application supplies both values. `docs/30-port-design.md`
owns the answer for each platform, and the answer is a parameter, not a query.

### R7. The C ABI lives in a second upstream repository

| | |
|---|---|
| Class | fact about a third-party repository |
| Severity | S4 low, after the correction below |
| Milestone | M4 |
| Mitigable here | Yes. |

**Source.** Commit `553d9c1`, 2024-07-21, "chore: Move the language bindings to
standalone repositories" (#442), and `docs/15-tree-semantics.md`.

**What can go wrong.** A port that reads the core from one revision and the
header from another produces a library that does not match its own header.

**How likely.** It was likely until the correction below. It is not now.

**The correction.** This is not a skew. `accesskit-c/Cargo.toml:20` pins
`accesskit = "0.25.1"`, so the bindings crate builds against the core this port
targets.

**What it costs.** Two pins instead of one, and one sentence saying which
repository defines the ABI.

**What would detect it.** A change to either pin that is not made in the same
commit as the record of what moved.

**What mitigates it.** Pin both repositories, and say that the header generated
from the core types defines the ABI the port reproduces. `docs/31-c-abi-design.md`
owns that. The port's own header adds two functions to upstream's set, which
R13 records.

### R8. Three more goose gaps for the AT-SPI path

| | |
|---|---|
| Class | blocker |
| Severity | S2 high |
| Milestone | M5 |
| Mitigable here | Yes for G7 and G8. G9 is R1's G1. |

**Source.** `docs/07-zig-ecosystem.md` section 3, reached independently of R1.

| Id | Gap | Evidence | Verdict for this adapter |
|---|---|---|---|
| G7 | `SocketIterator` is private and `initWithBackend` takes a `BusType`, so the port cannot connect to an address it learns at run time | `connection.zig:1451`, `:474` | **worked around, no patch** |
| G8 | No first-class emit-signal call, only `registerSignalHandler` for receiving | `docs/07` section 3 | **avoided, no patch** |
| G9 | G1 restated from the ecosystem side: `registerObject` only appends, while upstream removes exported objects on every tree change | `connection.zig:700` | same as R1's G1 |

**What can go wrong.** Without a patch goose cannot connect to the address the
accessibility bus hands out, and it cannot emit a signal. Both are needed: the
adapter is a D-Bus client that also publishes.

**How likely.** Certain without the workarounds. `docs/41` section 3.1 records
the state of each gap per adapter, and G7 is marked HIT and G8 AVOIDED.

**What it costs.** G7 costs the two-step bus discovery the port owns anyway: open
a session connection, call `org.a11y.Bus.GetAddress` at `/org/a11y/bus`, decode
the string, put it in the `Environ.Map` under `AT_SPI_BUS_ADDRESS`, then open the
`.Accessibility` connection. G8 costs about ten lines, because
`Signal(T)` exposes `name`, `interface` and `path` as ordinary fields at
`dbus_types.zig:10-12`.

**What would detect it.** A connect that fails with `error.FileNotFound` while
`AT_SPI_BUS_ADDRESS` is unset, because the hard-coded fallback at
`connection.zig:498` builds the socket name `bus_0` and the real socket is `bus`.

**What mitigates it.** Both routes are inside this repository and need no goose
patch. That is the reason route (b) is the answer, and it is why three
independent agents finding the same blocker from different angles raises the
confidence that vendoring a patched goose is the wrong route.

### R9. `-ffuzz` does not compile in Zig 0.16.0

| | |
|---|---|
| Class | fact about the toolchain |
| Severity | S2 high |
| Milestone | M0, and any milestone that wants a fuzz gate |
| Mitigable here | **No.** The defect is in the compiler's own test runner. |

**Source.** `docs/22-zig-build-surface.md`, reproduced on a 12 line file.

```
lib/compiler/test_runner.zig:566:55: error: expected type '*const debug.StackTrace',
found '*builtin.StackTrace'
```

**What can go wrong.** Every `-ffuzz` build fails, because
`std.debug.writeStackTrace` takes `*const debug.StackTrace` at
`lib/std/debug.zig:824` and `@errorReturnTrace` returns `*builtin.StackTrace` at
`lib/std/builtin.zig:11`. A plain `zig test` on the same file passes.

**How likely.** Certain on Zig 0.16.0. The path is reachable only under
`builtin.fuzz`, so nothing else in the toolchain touches it.

**What it costs.** The milestone that wants fuzzing is blocked, and the plan must
name a weaker substitute instead of describing `zig build fuzz` as working.

**What would detect it.** `zig build fuzz` failing with the two type names above,
while `zig test` on the same file prints a test count.

**What mitigates it.** A deterministic generator that replays a committed corpus.
That is a different obligation and a weaker one, and the plan must say so.

### R10. `-femit-h` is broken on this host, so the C header is checked in

| | |
|---|---|
| Class | fact about the toolchain |
| Severity | S2 high for the routes it blocks, low for the route the port took |
| Milestone | M4 |
| Mitigable here | **No.** It is ziglang/zig issue 9698. |

**Source.** `docs/22-zig-build-surface.md`, and `docs/40` section 5.4.

**What can go wrong.** Anything that depends on emitting a header is blocked. A
generated header, an `h_dir` passed to an install step, and any build step that
reads `getEmittedH` are all closed routes.

**Three probes, all on this host.**

| Probe | Result |
|---|---|
| `zig build-obj -femit-h -c probe.c` | `error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698` |
| `zig build-lib -femit-h -c probe.c` | the same error |
| `zig cc -femit-h=probe.h -c probe.c` | `error: Unknown Clang option: '-femit-h=probe.h'`, exit 1, no file produced |

**The standard library agrees, in the place it would have to work.**

```
lib/std/Build/Step/InstallArtifact.zig:123    // https://github.com/ziglang/zig/issues/9698
lib/std/Build/Step/InstallArtifact.zig:124    //if (install_artifact.h_dir != null) install_artifact.emitted_h = artifact.getEmittedH();
```

`Step.Compile.getEmittedH` still exists at `Compile.zig:869`, but nothing ever
populates `generated_h`, and `InstallArtifact.zig:168-173` guards its install on
that field. So `h_dir` at `InstallArtifact.zig:24` and `:43` installs nothing
and must stay unset.

**How likely.** Certain on this toolchain version. The defect is upstream and the
call site is commented out, so no local configuration avoids it.

**What it costs.** The generator route is closed. The cost is already paid,
because the port chose the checked-in header before this run. The remaining cost
is a future contributor who spends a day looking for a workaround that is not
there.

**What would detect it.** A build step that sets `h_dir` and installs no header,
or a document that promises a generated header.

**What mitigates it.** Ship `include/zaccesskit.h` as a checked-in file and
install it with `installHeader`, at `Compile.zig:523`. That also fits the zero
Rust rule, because upstream generated its header with cbindgen. `docs/31` owns
who maintains the header and how a change to a Zig type reaches it.

### R11. `zig translate-c` covers the whole AccessKit C ABI today

| | |
|---|---|
| Class | fact about the toolchain and the header |
| Severity | S4 low |
| Milestone | M4 |
| Mitigable here | Yes. |

**Source.** `docs/22-zig-build-surface.md` section 3.7, measured with a probe
header, then measured again against the real header in `docs/40` section 5.5.

**What can go wrong.** `accesskit.h` contains **zero** bitfields, **zero**
function-like macros and **zero** variadic declarations. Those three are the
cases that force a hand-written C shim, so a change that adds one costs the port
a shim it has not written.

**How likely.** Not today. The count of zero for all three is a property of the
current header.

**What it costs.** Nothing today. It is a forward-looking rule.

**What would detect it.** A new bitfield in a public struct, a variadic export,
or a function-like macro in `include/zaccesskit.h`.

**What mitigates it.** Keep the shim rules as forward-looking rules and not as
work. Do not add any of the three constructs without re-reading this entry.

**Two limits that survive the measurement.** `translate-c` is a generating
oracle for the `extern struct` declarations only. It emits
`struct_accesskit_node_ids` style tags rather than the port's names, so it is a
diff that proves no layout moved and not a reflection source. It also says
nothing about how an aggregate is lowered, which R20 records.

**Superseded figure.** This entry originally said the sweep covered the header.
`docs/40` section 5.5 now measures it against the real header: 446 of 446 names,
zero spurious. RR1 records what that measurement removed.

### R12. goose and zio disagree about `O_NONBLOCK`

| | |
|---|---|
| Class | blocker, caused by a fact about a third-party library |
| Severity | **S1, highest** |
| Milestone | M5, and through it M6 |
| Mitigable here | **No, not as the repository stands.** goose is not a dependency. |

**Source.** `docs/26-goose-live-bus-probe.md` sections 7.1 and 7.4, runtime
observation on this host, and `docs/40` section 6.1.

**What can go wrong.** With a zio-backed `std.Io` the first run failed with
`error.ReadFailed`. zio opens sockets non-blocking at `zio/src/net.zig:912` and
never restores blocking mode, so `fcntl F_GETFL` returns `0x802` with
`O_NONBLOCK` set against `0x2` for a default `std.Io`. goose's
`SocketReader.recvWithIovecs` calls raw `recvmsg` at `connection.zig:221` and
folds `EAGAIN` into `error.ReadFailed` at `:188-190`. The caller cannot tell
"would block" from "not ready", and the failure looks like a network fault.

**How likely.** Certain for every AT-SPI read through goose until the fix lands.

**What it costs.** Four `fcntl` lines after connect at `connection.zig:514`, in a
library this repository does not own. The runtime cost of finding it was the
expensive part, and `docs/26` has already paid it.

**What would detect it.** `error.ReadFailed` on the first read after a successful
connect, with `fcntl F_GETFL` returning `0x802` on the same socket.

**Why it is not fixable here as the repository stands.** `build.zig.zon`
declares exactly one dependency, `zio` at `2662fdc4…`. goose is not a
dependency, so there is no goose source in the build graph for a patch to
apply to.

**What a build step would have to do.**

1. Add goose as a dependency in `build.zig.zon`.
2. Take the four-line patch from `docs/26-goose-live-bus-probe.md` section 7.4.
3. Carry it through the mechanism that `docs/30` section 7.3 settles, in the
   record it numbers R5. The shape is `b.addSystemCommand` (`Build.zig:927`)
   plus `Step.Run.addFileArg`, because nothing in `std.Build` patches sources.

**What that would prove.** That a patched goose returns a distinguishable
`EAGAIN`. That is all.

**What it cannot prove.** Anything about `src/capi/`. No C ABI export touches a
socket, and no C ABI export shares a line with the D-Bus layer. A green
`O_NONBLOCK` fix is not movement on `src/capi/`, and a green `src/capi/` gate is
not movement here. The two subjects are independent.

**Dependency to report.** The goose fork or patch at
`/tmp/scratch/goose`, tag `v3.3.0`, the four lines in
`docs/26-goose-live-bus-probe.md` section 7.4, and a `build.zig.zon` entry for
it. R16 needs the same carrier, so one dependency entry serves both entries.

### R13. The C ABI is a flat function API with no vtable and no error type

| | |
|---|---|
| Class | decision |
| Severity | S2 high |
| Milestone | M4 |
| Mitigable here | Yes. The shape is this project's choice. |

**Source.** `docs/11-accesskit-c-abi.md`, 1933 lines.

**What can go wrong.** Two house rules have no target to fire at here. The
explicit-error-set rule has nothing to name, because a grep for `accesskit_error`
and `ACCESSKIT_ERROR` over the header and the whole `accesskit-c` checkout
returns nothing. The allocator rule is fought hardest, because
`accesskit_node_new`, `accesskit_tree_update_with_focus`, every string getter and
`accesskit_custom_actions_free` use the global Rust allocator and no signature
mentions one.

**No vtable exists.** `accesskit_platform_adapter_vtable` and
`accesskit_platform_application_vtable` are absent from the header and from the
whole `accesskit-c` checkout, and the Rust core has no `PlatformAdapter` trait.
A C caller cannot register a platform of its own, so any consumer that assumes a
vtable is wrong.

**How likely.** Certain, because it is the shape upstream publishes. The port
adds two functions to it.

**What it costs.** The decision has to be written down in one place, because the
ABI, the allocator rule and the error-set rule all read from it.

**What would detect it.** A consumer that expects `accesskit_platform_adapter_vtable`,
or a Zig export that takes a global allocator.

**What mitigates it.** State whether the port keeps the flat ABI shape with
Zig-side allocation and typed Zig errors behind it, or changes the ABI. If it
keeps the shape, name the point where a Zig error replaces a null, because a C
caller must still see the null. `docs/31-c-abi-design.md` owns this.

**Superseded figures.** The research-phase text said 496 exports with 444 visible
on Linux. `docs/40` measures the port header at 498 declarations with 446 on
Linux, and the difference is the two functions the port adds,
`accesskit_set_allocator` and `accesskit_last_error`. Both figures describe a
real file.

### R14. The C header is not stable

| | |
|---|---|
| Class | fact about a third-party repository |
| Severity | S3 medium |
| Milestone | M4, and every consumer rebuild after it |
| Mitigable here | **No.** The churn is upstream's release cadence. |

**Source.** `docs/11-accesskit-c-abi.md`, six recorded ABI breaks.

**What can go wrong.** Upstream breaks the header without a deprecation window.
The most recent is 0.18.0, dated 2025-12-10, "Make `accesskit_custom_action` an
opaque type". The others include a `StaticText` to `Label` rename, a dropped
`NodeClassSet`, `hierarchical_level` to `level`, `Checked` to `Toggled` with
`ToggleButton` dropped, and a function rename.

**How likely.** Six breaks in the recorded window, so treat it as a matter of
course rather than an exception.

**What it costs.** A port that promises byte compatibility with upstream makes a
promise upstream has not kept.

**What would detect it.** A release in the `accesskit-c` train, or in one of the
four adapter trains, that renames or retypes a symbol the port already names.

**What mitigates it.** Do not promise byte compatibility as a stable contract.
Say what the port guarantees instead: which of the six breaks it adopts, which it
declines, and what a C consumer must recompile for. Record the two release
trains, because the adapters version independently of the core: macos 0.27.1,
windows 0.35.1, unix 0.24.0, android 0.9.0, ios 0.2.1.

### R15. Three ownership gaps in the upstream header, and one comment not to copy

| | |
|---|---|
| Class | fact about a third-party repository |
| Severity | S3 medium |
| Milestone | M4 |
| Mitigable here | **Yes.** The port's header is hand written. |

**Source.** `docs/11-accesskit-c-abi.md`.

**What can go wrong.** A C consumer reads a value the header does not promise to
keep alive, or frees memory the library still owns.

1. Eight node getters return a `{length, values}` struct **by value** whose
   `values` pointer borrows from the node's internal `Vec`: `accesskit_node_ids`
   at `:688`, the length getters at `:789`, `accesskit_opt_coords` at `:794`. No
   free function exists and none is needed, but the header never says that the
   node must outlive the array.
2. `accesskit_tree_update_set_tree_info` at `:2391` carries no comment, yet the
   shim consumes the box at `common.rs:1032`, so the caller must not free it.
3. `accesskit_action_request_free` at `:2412` also releases the `char *` inside
   `action_data.Value`, the union member at `:1032`, through
   `impl Drop for action_data` at `common.rs:1084-1090`. The header does not say
   so.

**One comment must not be copied.**
`accesskit_macos_add_focus_forwarder_to_window_class_with_length` at `:2988` is
documented at `:2977` as "Caller is responsible for freeing `class_name`", but
the parameter is `const char *` and the shim only reads it at `macos.rs:274`.

**How likely.** Certain for a consumer who reads only the header, because each
of the three cases is silent rather than wrong.

**What it costs.** A use-after-free or a double free in a consumer, from code
that looks correct.

**What would detect it.** A conformance program that frees one of these values,
or a C fixture that drops a node before reading the array it borrowed.

**What mitigates it.** Each case becomes an explicit sentence in the port's own
header. `docs/31-c-abi-design.md` owns the wording, and
`skill://zig-api-design/references/documentation.md` section 3.3 method row 4
owns the obligation: state what survives a failure, because a signature cannot.

### R16. goose never learns its own unique bus name, so the adapter cannot register

| | |
|---|---|
| Class | blocker caused by a fact about a third-party library |
| Severity | **S1, highest.** It is not a workaround, it is a hard dependency. |
| Milestone | M6 |
| Mitigable here | **No.** The fix is in goose, which this repository does not own. |

**Source.** `docs/41-atspi-build-map.md` sections 3.1 and 6.4. This defect was
**not** in the research-phase register. `docs/41` names it the tenth gap.

**What can go wrong.** `sayHello` at `GO/connection.zig:549` sends `Hello`, takes
the reply at `:572` and drops it at `:573`. There is no `uniqueName` accessor and
no field. A grep for `unique` over `GO/` returns two doc comments and no
declaration. Upstream needs that name: `bus.rs:88` passes
`self.unique_name().as_str()` as the first half of the `Embed` plug, and the
AT-SPI reference XML states that the plug is "a string for the unique bus name of
the application".

**How likely.** Certain. Without the fix the adapter has no value to pass, and
`docs/41` section 6.4 records that without it the adapter cannot register at all.

**What it costs.** About five lines at one known location in goose: keep the
`Hello` reply, store the `s` body, expose a getter. The cost is not the lines, it
is that M6 waits on a patch to a library outside this repository, and R17's hazard
stays open until the same patch lands.

**What would detect it.** M6's live-bus gate cannot register a node path, and the
registry never returns the desktop root from `Embed`.

**What mitigates it.** The patch rides in the same carrier as R12's `fcntl` fix,
through the mechanism that `docs/30` section 7.3 settles, in the record it
numbers R5. It must be asserted on its own value: the adapter's unique name is
the one it passed to `Embed`. That is the assertion `docs/41` section 6.4 names.

**What leaves this repository.** The patch itself, which is in goose v3.3.0 at
`/tmp/scratch/goose`, tag `v3.3.0`, commit `8c6ee3a`. The
dependency entry is R12's. One entry serves both.

### R17. `Socket.Embed` with a foreign plug name kills `at-spi2-registryd`

| | |
|---|---|
| Class | operational hazard |
| Severity | **S1.** It has already damaged a host, and any live-bus probe can repeat it. |
| Milestone | M6, and every future probe against the live bus |
| Mitigable here | Partly. The call can be avoided. The abort is not this project's. |

**Source.** `docs/41-atspi-build-map.md` section 6.4, runtime observation on this
host, transcript included there.

**What can go wrong.** The registry aborts when `Embed` carries a plug name that
is not the caller's own unique name. The accessibility stack of the machine that
runs the probe goes down until the launcher restarts the daemon.

```
$ pgrep -f 'at-spi2-registryd'
... 46843
$ busctl --address=unix:path=/run/user/33156/at-spi/bus introspect \
      org.a11y.atspi.Registry /org/a11y/atspi/accessible/root
Failed to parse bus message: No such device or address
$ pgrep -f 'at-spi2-registryd'
... 46843
$ busctl --address=unix:path=/run/user/33156/at-spi/bus call \
      org.a11y.atspi.Registry /org/a11y/atspi/accessible/root \
      org.a11y.atspi.Socket Embed ss ":1.12345" "/org/a11y/atspi/accessible/root"
Call failed: Remote peer disconnected
$ pgrep -f 'at-spi2-registryd'
        (46843 is gone)
```

`Introspect` on the same path, with the same registry process, leaves it alive.
The launcher restarts it, which is why the name then shows as `(activatable)`.

**How likely.** High for anyone who probes the live bus by hand. Those two calls
are the two a probe reaches for first, and only one of them is safe.

**What it costs.** The node's accessibility stack, for as long as it takes the
launcher to bring the daemon back. It costs more on a machine with a screen
reader than the transcript suggests.

**What would detect it.** The kill is immediate and visible: the process id is
gone and `busctl` reports "Remote peer disconnected". The dangerous case is the
one that never runs, because a harness substituted a literal unique name and the
test then runs against a restarted daemon.

**What mitigates it.** Pass the connection's own unique name, which is R16's fix,
and assert that the name passed equals the name returned by the connection. A
test that substitutes a literal unique name must be refused rather than fixed.
`busctl` cannot supply its own unique name, so the `Embed` integration test has
to be written in Zig. Anything that only needs a bus should use a private
`dbus-daemon` instead of the live one.

**What leaves this repository.** The abort is in `at-spi2-registryd`, which is
upstream. This repository can stop calling it wrongly. It cannot stop another
process from calling it wrongly.

### R18. Eight stale figures in `docs/16`, three of them in a milestone budget

| | |
|---|---|
| Class | estimate |
| Severity | S2 high, because three of the eight size a milestone |
| Milestone | M8, M9, M10 |
| Mitigable here | Yes. The corrections are measurements. |

**Source.** `docs/42-native-adapter-build-map.md` section 1.5, each row with the
measurement that settles it.

**What can go wrong.** An implementer sizes a milestone from `docs/16` and writes
less code than the adapter needs. Three figures do that today.

| # | `docs/16` says | The source says | Effect |
|---|---|---|---|
| C2 | macOS has **6** literal attribute and action names | **43** distinct `AX…` literals | M8, off by 37 |
| C6 | Android has **about 40** JNI call sites | **78** call sites naming **68** distinct Java methods | M10, off by a factor of two |
| C4 | the iOS adapter is **2603** lines across eight files | **2560** | M9, off by 43 |
| C5 | iOS has **26** named UIKit symbols plus 4 by `dlsym` | **39** named, **43** distinct identifiers | M9's "26 typed by hand" row, short by 13 |
| C1 | macOS has **33** role constants | **31** | `docs/16`'s own M6 table lists 31 rows, so its heading contradicts its own table |
| C3 | macOS reaches `+[NSArray arrayWithObjects:count:]` | the source calls `NSArray::from_vec` and `Id::autorelease_return` at `AK/macos/src/adapter.rs:250-251` | a declaration for a symbol the port never calls |
| N1 | the Windows crate enables ten feature groups and names nine | `AK/windows/Cargo.toml:33` enables a tenth that no source file imports, and three of the ten enable nothing | a dependency line with no user |
| N2 | W12 calls the enum type `NavigationDirection` | the source type is `NavigateDirection` at `AK/windows/src/node.rs:1077` | the port invents a type |

**How likely.** Certain for anyone who budgets from `docs/16`. `docs/42` measured
each row with a lexical scan over the pinned tree rather than from a summary
line.

**What the plan carries today.** Four rows of `docs/40-plan.md` repeat a
`docs/16` figure, and three of them are wrong.

| Plan row | What it says | What the source carries |
|---|---|---|
| M8 body | 58 selectors typed by hand, from `docs/16:1826` | 54 node selectors and **43** distinct `AX…` literals, of which `docs/16` counts 6 |
| M9 body | 26 UIKit symbols typed by hand, 4 of them through `dlsym` | **39** named plus 4 literals, 43 distinct identifiers |
| M9 field "Upstream covered" | 2560 lines | 2560 lines. The plan is already right here and only `docs/16` is wrong |
| M10 body | about 40 JNI call sites, from `docs/16:1826` | **78** call sites naming 68 methods |

**What it costs.** M8's literal surface is about seven times the figure the plan
carries, and M10's JNI surface is about double. Those two are what change how
many days the milestones take. M9's source size is already correct in the plan, so
C4 costs a reader of `docs/16` and not the schedule.

**What would detect it.** A milestone gate that passes while `docs/42`'s census
count is unmet. A string literal compiles whatever it says, so the compiler
never raises this. The detection is a count sweep in the milestone's own entry
gate.

**What mitigates it.** Budget from `docs/42`'s census, not from `docs/16`, and
recompute the "expected size" rows in `docs/40-plan.md` M8, M9 and M10 from it.
Where a record and an older document disagree, the record wins, because it was
measured against the pinned upstream rather than transcribed.

**What this entry does not claim.** `docs/16` is also confirmed on one point, the
Windows constant total of 181. A first pass here produced 178 because the
measuring regex required the `UIA_` prefix and missed `E_FAIL`, `E_INVALIDARG`
and `E_NOTIMPL`. A scan that starts from a regex has to be read twice.

### R19. `docs/31` section 3 row 16 overcounts the `*_free` functions

| | |
|---|---|
| Class | estimate |
| Severity | S3 medium |
| Milestone | M4 |
| Mitigable here | Yes. The row is corrected. |

**Source.** `docs/40-capi-build-map.md` sections 4 and 4.1, and the correction in
`docs/31-c-abi-design.md` section 9.1.

**What can go wrong.** Row 16 said "2 node, 2 tree-info, 1 tree-update, 2
custom-action, 1 action-request, 1 string, 10 platform", which is 19 functions.
The header declares 17. An implementer who follows the row literally writes a
second `accesskit_node_free` and a second `accesskit_tree_info_free`, and the
second pair is a duplicate symbol at link time.

**The count, category by category.**

| Category | Row 16 said | The header has | Line in the current header |
|---|---:|---:|---:|
| string | 1 | 1 | 2824 |
| custom-action | 2 | 2 | 5006, 5068 |
| node | 2 | **1** | 5128 |
| tree-info | 2 | **1** | 5157 |
| tree-update | 1 | 1 | 5294 |
| action-request | 1 | 1 | 5372 |
| platform | 10 | 10 | 5720 to 6436 |
| **Total** | **19** | **17** | 17 declarations |

Upstream declares the same 17 under the same names at commit `8b6ed37`. The two
extra rows are therefore a counting error in `docs/31`, not a divergence the port
introduced and not a name the port renamed. This run counted the header itself: a
grep for `_free(` returns 17 lines, and all 17 are declarations. That count is
this run's own. Every other number in this entry is quoted from `docs/40`.

**How likely.** Certain for an implementer who reads the row before the header.
It was not caught because a count is not a compile error on its own.

**What it costs.** A link failure naming two symbols, and a reader who then
suspects the header. The same count matters after the link, because a second
release of any of the 17 is a double free, and a second release of any
`*_queued_events` handle is a use after free.

**What would detect it.** A duplicate `accesskit_node_free` or
`accesskit_tree_info_free` symbol at link time, or a sweep that counts 19 free
functions in the header.

**What mitigates it.** The row is corrected to 17 in `docs/31`, counted at
`8b6ed37`, with the seven named declarations listed at section 9.1 there. The
rule for the next reader is short: correct the row, not the header. A row with no
declaration behind it is a defect in the row.

**A caveat on line numbers in the two records.** `docs/40` section 4.1 cites the
free functions nine lines below where the current `include/zaccesskit.h` puts
them, and it does so for all seven. The same nine-line offset moves the two port
functions, from 6463 to 6472 for `accesskit_set_allocator` and from 6475 to 6484
for `accesskit_last_error`, and `docs/40` section 1 gives the header as 6572 lines
against 6581 now. The header grew after that run, so the record was right when it
was written. This entry cites the header's current lines, and a reader comparing
the two records should expect the offset rather than treat one record as wrong
about the other. This run counted those lines. Everything else here is quoted.

### R20. How Zig 0.16.0 lowers a 48-byte aggregate return is undecided

| | |
|---|---|
| Class | decision |
| Severity | S2 high |
| Milestone | M4 |
| Mitigable here | Yes on `x86_64-linux`. No on the other five targets without a runner or an SDK. |

**Source.** `docs/40-capi-build-map.md` section 6.2, and `docs/31` section 2.5.

**What can go wrong.** An `extern struct` has the right in-memory layout, but a
caller compiled with a different aggregate classification corrupts its own stack
rather than receiving a wrong number. `accesskit_affine` is 48 bytes, past the
x86-64 System V return budget, so it travels through a hidden pointer and every
named argument shifts with it. Nine of the 105 declarations return it by value.

**How likely.** Unknown, and that is the problem. Nothing in the installed
toolchain settles it: the toolchain ships `lib/` and the `zig` binary but not the
compiler's `src/`, so the ABI classifier and the per-architecture generators
cannot be cited. No ABI classifier was found in `lib/std`, and `translate-c`
emits declarations only.

**What it costs.** The header's 40 layouts are already measured and correct, so
the cost is the calling convention and not the layout. A wrong answer here is a
stack corruption in a consumer, and it reproduces as a wrong number at the call
site rather than as a diagnostic.

**What would detect it.** A C fixture that calls one function of each shape and
links against the built artefact. It must cover at minimum
`accesskit_affine_inverse`, `accesskit_affine_mul`, `accesskit_rect_area`,
`accesskit_rect_translate`, `accesskit_point_add_vec2`, an
`accesskit_opt_double` return and a `char *` return.

**What mitigates it.** The fixture belongs in `b.addSystemCommand`
(`Build.zig:927`) with the artefact as an `addFileArg`, because
`b.addRunArtifact` (`Build.zig:936`) runs an artefact and does not link a foreign
object. That proves the classifier agrees for `x86_64-linux` in the mode built.
It proves nothing about `aarch64-linux`, `powerpc64-linux`, Windows, macOS or
Android, and nothing about another optimize mode.

**The fallback is named and not yet needed.** `docs/31` section 2.5 names a
hand-written C shim owning the nine affine entry points. Nothing in scope builds
it until check 5 in `docs/31` section 6 has run. The decision is recorded in
`docs/31`, and `docs/40` does not own it.

---

## 3. Removed risks

A risk moves here when a measurement closes it. The entry stays, because a
register that deletes its own history cannot be audited. Each removed entry names
the evidence that removed it, and each names the residual that survives, so a
reader does not over-read the removal.

### RR1. `zig translate-c` is unverified in this environment, so the parity sweep has no criterion

**The risk as it stood.** The sweep had no pass criterion, because nobody had run
`translate-c` against the port header on this host. The register held R11's
conclusion from a probe header and no measurement of the real one.

**What removed it.** `docs/40` section 5.5 ran it here:

```
zig 0.16.0 translate-c -Iinclude include/zaccesskit.h -lc > zaccesskit.zig
```

Exit 0. 3408 lines of Zig and zero diagnostics. The two lines on stderr are the
`anyzig` shim's own progress output, not the translator.

| Check | Result |
|---|---:|
| `pub extern fn` declarations emitted | 446 |
| Of the 498 header declarations, those the translator carries | **446** |
| Names in the translator that the header does not declare | **0** |
| Names in the header the translator omits | **52, exactly the platform-gated set** |

**The criterion it leaves behind.** The sweep runs, and its pass criterion is
**446 of 446 on Linux**. That is the same gate the header applies, where 440
declarations are portable and 6 sit behind the unix guard.

**Residuals that survive the removal.** It cannot cover the other 52 here,
because `_WIN32`, `__ANDROID__`, `ACCESSKIT_MACOS` and the Apple-mobile macros
are not defined when translating on Linux. It is a generating oracle for the
`extern struct` declarations and not a reflection source, because it emits
`struct_accesskit_node_ids` style tags rather than the port's names. It gives no
opinion on aggregate lowering, which R20 records.

### RR2. No usable Zig package covers UI Automation, and the candidate may need the Windows SDK

**The risk as it stood.** Windows is rung 2, which means a pinned Zig package
rather than a hand-written boundary. If no package covers UI Automation, then
either the port hand-writes a large boundary or it needs an SDK this host does
not have.

**What removed it.** `docs/42` section 2.1 checked all three claims in
`docs/07` section 5.1 and `docs/16` section 9.2 against a fresh clone of
`marlersoft/zigwin32` at `9f15c276b4e9d05afd34a10d8662a7dfc34647ea`, which
matches `docs/16`.

| Claim | Result |
|---|---|
| it covers the entire Windows boundary | every symbol in the census is present, with `path:line` for the 7 `uiautomationcore` functions, the 8 `user32` functions, the 2 `oleaut32` functions, `LocaleNameToLCID`, the UIA interfaces and the vtables |
| Zig 0.16.0 may fetch it | its `.zon` reads `.name = .win32`, `.version = "42.0.39-preview"` and `.minimum_zig_version = "0.14.0"` |
| it does not need the SDK | `build.zig` is seven lines, declares one module, and a grep for `sdk`, `windows_sdk`, `MSVC` and `MinGW` returns nothing. The declarations in `dll/*.zig` are `pub extern "<dllname>" fn` with hand-written parameter types, so no header is read and no import library is opened |
| the recorded compile probe reproduces | `zig 0.16.0 build-obj -target x86_64-windows --dep zigwin32 -Mroot=wtest.zig -Mzigwin32=zigwin32/win32.zig` produces an object with no error and no warning |

**A caveat on the recorded byte count.** `docs/16` records a 32432 byte object.
The reproduction in `docs/42` section 2.1.3 measured 32396 bytes with the module
path `../zigwin32/win32.zig` and 32416 bytes with `zigwin32/win32.zig`. The
recorded figure is 16 bytes above the second. The difference is the module path
length in the COFF debug directory, not generated code. Treat the byte count as a
fingerprint of one directory layout and not as a fact about the package.

**Residuals that survive the removal.** Three differences from `windows-rs` have
to be written down: the namespace is one level shallower, many types are
file-private aliases so `uia.HWND` fails while `win32.foundation.HWND` works,
and `VARENUM` is an `enum(u16)` so `VT_I4` is an alias of `VARENUM.I4`. And
zigwin32 gives no COM object factory, so about 120 lines of the port have no
upstream counterpart. `docs/40-plan.md` M7 carries all four.

### RR3. The missing X11 extension headers block the port

**The risk as it stood.** `XTest.h`, `Xfixes.h`, `XInput2.h` and `xkbcommon.h`
are absent on this host while the runtime libraries are present, so an X11
boundary could not be written at all.

**What removed it.** Upstream ships no X11 adapter to port, so no milestone needs
the headers. A grep for `xcb|wayland|X11|xlib|xkb|wl_` over
`adapters/unix/src/` and its manifest returns exactly one hit, and it is a doc
comment at `adapters/unix/src/adapter.rs:172`. The adapter is pure AT-SPI over
D-Bus, and geometry and focus reach it only through `set_root_window_bounds` at
`:173` and `update_window_focus_state` at `:222`, both pushed in by the
application. That last fact is the live obligation, and it is R6.

**Residuals that survive the removal.** An X11 path written from scratch rather
than translated would not compile here until the headers are obtained.
`docs/27-x11-headers-resolution.md` records that the Nix sandbox store on this
host supplies all four and that no root is needed, so the residual is a command
and not a blocker. It costs nothing today.

---

## 4. The three highest-severity entries

| Rank | Id | Why it is S1 |
|---:|---|---|
| 1 | R16 | The adapter cannot register at all without a patch to a library outside this repository. It is a hard dependency, not a workaround, and no route around it exists inside the port. |
| 2 | R12 | The same dependency, and the same patch carrier, for the read path. Until it lands, every AT-SPI read fails with a runtime error that looks like a network fault. |
| 3 | R17 | It has already taken the accessibility stack down twice on this host, and any agent probing the live bus can repeat it. No test result reports the damage, because the damage is to the machine and not to the build. |

**Why these three and not R10 or R9.** R10 and R9 are S2 because the port
already routed around both. The header is checked in, so the cost of `-femit-h`
is a future contributor's afternoon. The fuzz stage is replaced by a corpus
replay, so the cost of `-ffuzz` is a weaker gate that is named as weaker. R16 and
R12 have no route around them inside this repository.

**What the three share.** One dependency entry in `build.zig.zon` and one patch
carrier close R16 and R12 together. That is why the report to the integration
owner lists them as one item with two assertions, and not as two patches.

---

## 5. Open questions the register does not own

A register that carries a question it cannot answer stops being a register. Each
of these is already written down in the document named, and this file only points
at it.

| Question | Owner | Recorded at |
|---|---|---|
| How the goose patch is carried: a vendored copy, a build step, or an upstream pull request | `docs/30-port-design.md` | section 7.3, the record it numbers R5, and the three carriers in `docs/40-plan.md:231-236` |
| Whether the adapter may depend on a two-patch goose | `docs/30-port-design.md` | `docs/41` section 7 row 2 |
| Whether the pump task also drains the message channel, which is what keeps G1b avoided | `docs/30-port-design.md` | sections 5.3 and 2.3 |
| A fixed-capacity worklist or a maximum depth with `error.TreeTooDeep` | `docs/30-port-design.md` | `docs/41` section 7 row 4, and `docs/12:1395-1399` |
| Where a Zig application gets window bounds and focus state on this host | `docs/30-port-design.md` | `docs/41` section 7 row 5, and R6 |
| Whether the `SocketIterator` widening covers `guid=` and `tcp:` as well as `unix:abstract=` | `docs/40-plan.md` | section 3.1 gap G4, and `docs/26` section 8.1 item 5 |
| Whether the aggregate-lowering decision is written down, and which check closes it | `docs/31-c-abi-design.md` | section 2.5, section 6 check 5, and R20 |

**A rule for this file.** No entry is closed by a monitoring instruction. Every
"What would detect it" field names an observation, and an entry whose trigger is
unknown says so rather than asking a reader to watch for something.
