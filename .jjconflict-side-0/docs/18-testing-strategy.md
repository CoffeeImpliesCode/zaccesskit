# 18 — Testing strategy

Consumed by `docs/40-plan.md`, which turns section 8 into milestone gates, and by
`docs/50-verification.md`, which records the evidence for each one.

Every claim below carries its source. A claim without a `path:line` or a command
and its output is marked `[INFERENCE]`.

---

## 1. The gate

The house gate is one script: `~/.local/bin/zig-gate`,
823 lines. Its help text lists ten sections in order (`zig-gate:23-33`). This
section gives the implementation of each.

The gate keeps one variable, `fail`, declared at `zig-gate:366`. Every section
sets it. The run ends at `zig-gate:817-821`, which prints `GATE FAILED` and exits
1 when `fail` is not 0, and at `zig-gate:823` prints `GATE PASSED`. Exit code 2
means a usage or environment error, per `zig-gate:4`.

### 1.1 Stage table

| # | Stage | Script lines | Exact command | Required? | How it fails |
|---|-------|--------------|---------------|-----------|--------------|
| 1 | fmt | `zig-gate:424-436` | `"$ZIG" fmt --check $fmt_files` (`:429`) | required | `n file(s) need formatting`, then the diff (`:432-434`), `fail=1` (`:435`) |
| 2 | build | `zig-gate:438-446` | `zig_build` with no argument (`:440`) | required | `build: FAILED`, `tail -30` of the log (`:443-444`), `fail=1` (`:445`) |
| 3 | test | `zig-gate:448-458` | `zig_build test` (`:450`) | required | `test: FAILED`, `tail -30` (`:455-456`), `fail=1` (`:457`) |
| 4 | ast-check | `zig-gate:460-475` | `"$ZIG" ast-check "$f"` per file (`:464`) | required | `AST error in <file>` (`:465`), `fail=1` (`:474`) |
| 5 | ziglint | `zig-gate:477-496` | `"$ZIGLINT" $ZIGLINT_ARGS $(files)` (`:483`) | required | `found N issue(s), exit S`, a per-rule histogram, then the sample (`:489-494`) |
| 6 | zlint | `zig-gate:498-527` | `files \| "$ZLINT" -S $ZLINT_ARGS` (`:504`) | required | `found N issue(s), exit S` from zlint's own summary line (`:509-515`) |
| 7 | zbc | `zig-gate:529-555` | `"$ZBC" $(files)` (`:537`) | advisory | prints `(advisory)` (`:544`); still sets `fail=1` when errors are present (`:549-552`) |
| 8 | zwanzig | `zig-gate:557-658` | `"$ZWANZIG" $ZWANZIG_ARGS $zw_files` (`:584`) | required | every finding asserted (`:641-654`) |
| 9 | cross-test | `zig-gate:660-786` | `"$CROSS_TEST" --output "$GATE_CROSS_OUTPUT" $CROSS_TEST_ARGS` (`:709`) | required | `status=fail` or `status=incomplete`, classified against the per-target logs (`:745-766`) |
| 10 | zig-cov | `zig-gate:788-815` | `"$ZIG_COV" test $cov_args` (`:799`) | advisory, opt-in | `coverage: FAILED (advisory)` (`:810`); sets `fail=1` only under `ZIG_COV_FAIL_UNDER` (`:812`) |

### 1.2 What "the exact command" means in stages 2, 3 and 10

`zig_build()` is defined at `zig-gate:358-364`. It expands to
`"$ZIG" build "$@" $BUILD_ARGS`, where `$BUILD_ARGS` carries `--cache-dir` and
`--global-cache-dir` (`zig-gate:352-356`). With `GATE_SYSTEM_PACKAGE_DIR` set it
also passes `--system` (`zig-gate:359-360`). So stage 2 runs
`zig build --cache-dir <d> --global-cache-dir <d>` and stage 3 runs
`zig build test --cache-dir <d> --global-cache-dir <d>`.

Stage 10 expands `$cov_args` at `zig-gate:795` to
`--exclude=zig-pkg --exclude=vk.zig`, plus `--fail-under=<pct>` when
`ZIG_COV_FAIL_UNDER` is set (`zig-gate:796-798`).

### 1.3 The file list every text stage shares

`files()` is at `zig-gate:409-422`. It is `find . -name '*.zig'` minus `vk.zig`
and four build directories, then minus every `GATE_EXCLUDE` BRE pattern
(`zig-gate:406-408` supplies the default). `fmt`, `ast-check`, `ziglint`, `zlint`,
`zbc` and `zwanzig` all read that one list. A new project gets the exclusion
behavior for free and adds nothing.

### 1.4 How the gate decides a stage failed

Three rules, one per class of stage.

**Text stages count findings, not exit codes.** fmt counts lines matching
`^\./` (`zig-gate:432`). ziglint counts lines matching `^Z[0-9]+` and fails if
that count is not 0 **or** the exit code is not 0 (`zig-gate:485-486`). zlint
parses its own summary sentence `Found N errors and M warnings across F files in
Tms` and sums the two numbers (`zig-gate:509-511`).

**zwanzig validates the analyser before it validates the findings.** Five
self-checks run before the class policy, at `zig-gate:621-632`:

- an `Error: ` line in the output (`:622-623`);
- an exit code outside the tool's contract of 0 or 1 (`:624-625`);
- a non-zero exit with zero parsed diagnostics (`:626-627`);
- exit 0 with at least one diagnostic, which zwanzig never does (`:628-629`);
- a mismatch between zwanzig's own `Found N issue(s):` count and the number of
  parsed diagnostic lines (`:630-631`).

Only when all five pass does the finding count decide. Every finding is then
asserted, printed with the word `(asserted)`, and summed (`zig-gate:641-654`).
The gate asserts the whole count rather than a threshold, so a project cannot
ratchet its way past a new class.

**cross-test reads a status line, then reads the logs.** The gate accepts
`status=pass`, `status=partial` and `status=build_only` with `fail=0` as green
(`zig-gate:771-783`). A green run says `partial`, not `pass`, on this host,
because `x86_64-windows` has no runner here (`zig-gate:669-675`). On
`status=fail` or `status=incomplete` the gate greps the per-target build logs for
`timed out` and reports either a budget problem or a real assertion failure
(`zig-gate:745-760`). The exit code alone cannot tell those apart, and the
comment at `zig-gate:678-690` says so.

### 1.5 Skips and advisories

Seven things change what the gate does. They are not all the same.

| Mechanism | Effect | Lines |
|-----------|--------|-------|
| `--no-zbc` | stage 7 not run at all | parsed `:15`, honoured `:531` |
| `--no-zwanzig` | stage 8 not run at all | parsed `:16`, honoured `:572` |
| `--no-cross` | stage 9 not run at all | parsed `:17`, honoured `:698` |
| `--cov` absent | stage 10 not run at all | parsed `:18`, honoured `:790` |
| `ZBC_STRICT=1` | stage 7 warnings become failures | `:549` |
| `ZIG_COV_FAIL_UNDER=<pct>` | stage 10 threshold becomes a failure | `:812` |
| `GATE_EXCLUDE` | shrinks the file list for stages 1 and 4 to 8 | `:181`, `:406-422` |

Stages 1, 2, 3, 4, 5 and 6 have no switch. A project cannot drop them.

Stage 3 has one soft skip: if the log contains `no step named 'test'`, the gate
prints `test: skipped (no test step)` and does not fail (`zig-gate:452-453`). A
project with no `test` step therefore has a green gate and no tests. Section 8
item G1 exists to close that.

Stage 10 has three soft skips: the tool is absent (`zig-gate:792-793`), the log
says `invalid option: -Dcoverage` which means `build.zig` is not wired
(`:804-806`), or a plain `zig build test` fails (`:807-808`).

Stage 7 is advisory but not harmless. `zig-gate:544` labels findings
`(advisory)`, yet `zig-gate:549-552` sets `fail=1` whenever the output contains
any `error(`, or the exit status is above 1, or the tool exited non-zero having
printed nothing. Only warnings are advisory. zomp's rules record the same trap
at `zomp/AGENTS.md:201-203`.

### 1.6 What the gate does not run

The gate never runs a fuzzer. Verified:

```
grep -n "fuzz" ~/.local/bin/zig-gate
```

produced no output. `zig build fuzz` is a project step, not a gate stage. The
milestone plan must carry it as a line of its own, and section 4 says what shape
that line takes.

The gate also does not measure branch coverage. Section 7 covers this.

---

## 2. The test layout a new project must have

### 2.1 The two house layouts, and what each teaches

zomp keeps unit tests inside the source files and makes the **shard** the unit of
compilation. `zomp/AGENTS.md:39-45`: tests run from `src/shard_*.zig`, one per
top-level group, not from `src/root.zig`. Each shard holds
`test { std.testing.refAllDecls(@This()); }` over its own group. Adding a module
to `root.zig` does nothing.

zomp keeps golden vectors in `test/` as a **separate binary**, because a fixture
is a file and `@embedFile` turns a missing one into a build failure rather than
a silent skip (`zomp/AGENTS.md:49-50`, and the same reasoning in the build
script's module comment at `zomp/build.zig:16-18`).

ozai keeps integration artifacts and fuzz targets in `test/`, one file per
concern, and gives each its own module. Names carry the kind:
`test/integration_test.zig`, `test/loopback_test.zig`, `test/postcard_fuzz.zig`.
Corpus lives in `test/corpus/<decoder>/`.

ozai records why a test root must exist at all. `ozai/build.zig:56-65` says a
root that only re-exports discovers zero tests and still exits 0, which is a
green step proving nothing.

### 2.2 The shard convention

| Rule | Source |
|------|--------|
| One `addTest` module per shard | `zomp/build.zig:58-77` |
| Shard list is a single `const` shared by native and foreign runs | `zomp/build.zig:41-55` |
| Every shard file is `src/shard_<area>.zig` | `zomp/build.zig:45-54` |
| Unit tests are `test` blocks in the same file, never a `src/tests/` directory | `zomp/AGENTS.md:45` |
| Each shard reaches its own group with `refAllDecls` | `zomp/AGENTS.md:41-42` |
| Vector, integration and fuzz files live in `test/` and get their own module | `ozai/build.zig:196-204`, `ozai/build.zig:450-459` |

### 2.3 The address space ceiling

zomp bounds every native shard run at 4 GiB of address space.
`zomp/build.zig:39`:

```zig
const test_address_space_kb: u32 = 4 * 1024 * 1024;
```

The launcher is a `bash -c` wrapper so the limit applies before the test binary
starts (`zomp/build.zig:86-90`):

```zig
const run = b.addSystemCommand(&.{ "bash", "-c" });
run.addArg(b.fmt("ulimit -v {d}; exec \"$0\"", .{test_address_space_kb}));
run.addFileArg(compile.getEmittedBin());
```

The comment at `zomp/build.zig:35-38` gives the reason: four gigabytes is far
above an honest test and far below what a runaway loop reaches in a minute.

ozai has no ceiling. Verified by reading all of `ozai/build.zig`. A port that
decodes untrusted D-Bus bytes wants the ceiling, because a decoder bug is
exactly the kind of defect that allocates without bound.

The ceiling applies only to the native run. zomp omits it from `cross-test`
because a native `ulimit -v` would bound QEMU itself rather than the guest
(`zomp/build.zig:167-169`).

### 2.4 The fragment to copy

Copy this into `~/zaccesskit/build.zig`. Change the
shard names, the shard paths and the fuzz target list. Keep the ceiling, the two
optimize modes and the shared shard list.

```zig
const std = @import("std");

/// Mirror of `.version` in `build.zig.zon`. The zon is the release authority.
const version = "0.0.0";

/// Both safety-enabled modes belong to the house gate, so an optimized-only
/// failure cannot pass a Debug-only run.
const test_modes_full = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };

/// Address-space ceiling for one test shard, in kibibytes. Four gigabytes is
/// far above any honest test here and far below what a runaway decoder reaches
/// in a minute.
const test_address_space_kb: u32 = 4 * 1024 * 1024;

/// The shard list is shared so native and foreign coverage cannot drift.
const Shard = struct { name: []const u8, path: []const u8 };

const shards = [_]Shard{
    .{ .name = "core", .path = "src/shard_core.zig" },
    .{ .name = "tree", .path = "src/shard_tree.zig" },
    .{ .name = "protocol", .path = "src/shard_protocol.zig" },
    .{ .name = "abi", .path = "src/shard_abi.zig" },
    .{ .name = "platform", .path = "src/shard_platform.zig" },
};

/// One fuzz target file and one corpus directory per decoder. Nothing else.
const fuzz_targets = [_]struct { name: []const u8, file: []const u8 }{
    .{ .name = "tree-update", .file = "test/fuzz/tree_update_fuzz.zig" },
    .{ .name = "property", .file = "test/fuzz/property_fuzz.zig" },
    .{ .name = "abi-marshalling", .file = "test/fuzz/abi_marshalling_fuzz.zig" },
    .{ .name = "dbus-message", .file = "test/fuzz/dbus_message_fuzz.zig" },
};

fn compileShard(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    zio: *std.Build.Module,
    options: *std.Build.Step.Options,
    shard: Shard,
    mode: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .root_source_file = b.path(shard.path),
        .target = target,
        .optimize = mode,
    });
    module.addImport("zio", zio);
    module.addOptions("build_options", options);
    const compile = b.addTest(.{ .root_module = module });
    // A foreign musl loader need not exist on the host, even for x86 on x64.
    if (target.result.os.tag == .linux and target.result.abi == .musl) {
        compile.linkage = .static;
    }
    return compile;
}

/// Native shards retain the address-space ceiling that bounds runaway tests.
fn addCeilingedRun(
    b: *std.Build,
    shard: Shard,
    mode: std.builtin.OptimizeMode,
    compile: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "bash", "-c" });
    // argv is [bash, -c, script, bin], so the binary is `$0` to the script
    // and the ceiling applies before it ever starts.
    run.addArg(b.fmt("ulimit -v {d}; exec \"$0\"", .{test_address_space_kb}));
    run.addFileArg(compile.getEmittedBin());
    run.setName(b.fmt("test-{s}-{s}", .{ shard.name, @tagName(mode) }));
    return run;
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    }).module("zio");

    // The library surface a dependent package imports.
    const zak = b.addModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    zak.addImport("zio", zio);
    zak.addOptions("build_options", options);

    const lib = b.addLibrary(.{
        .name = "zaccesskit",
        .linkage = .static,
        .root_module = zak,
    });
    b.installArtifact(lib);

    // The suite is sharded, one binary per top-level module, in both
    // safety-enabled modes.
    const test_step = b.step(
        "test",
        "Run library unit tests in Debug and ReleaseSafe, sharded by module",
    );
    for (test_modes_full) |mode| {
        for (shards) |shard| {
            const compile = compileShard(b, target, zio, options, shard, mode);
            const run = addCeilingedRun(b, shard, mode, compile);
            test_step.dependOn(&run.step);
        }
    }

    // Counted test-server runs preserve Zig's result protocol, so the foreign
    // matrix can report a test count. No ceiling here: a native `ulimit -v`
    // would bound the emulator rather than the guest.
    const cross_test_step = b.step(
        "cross-test",
        "Run every library shard in Debug through the build system's foreign runner",
    );
    for (shards) |shard| {
        const compile = compileShard(b, target, zio, options, shard, .Debug);
        const run = b.addRunArtifact(compile);
        // A cached run executes no tests and cannot prove execution coverage.
        run.has_side_effects = true;
        cross_test_step.dependOn(&run.step);
    }

    // Zig 0.16 exposes no build-script entry point for the fuzzer. The build
    // runner reads `--fuzz[=N]` from its own command line and drives these run
    // steps, so this step is what puts a run step on that path. A bare
    // `zig build fuzz` replays the seed corpus and stops, which is the form a
    // commit gate can afford. ReleaseSafe is the fastest mode that builds and
    // keeps the checks a decoder bug trips.
    const fuzz_optimize: std.builtin.OptimizeMode =
        if (optimize == .Debug) .ReleaseSafe else optimize;
    const fuzz_step = b.step("fuzz", "Run the decoder fuzz targets, `--fuzz=N` to mutate");
    for (fuzz_targets) |fuzz_target| {
        const fuzz_mod = b.createModule(.{
            .root_source_file = b.path(fuzz_target.file),
            .target = target,
            .optimize = fuzz_optimize,
        });
        fuzz_mod.addImport("zio", zio);
        fuzz_mod.addImport("zaccesskit", zak);
        fuzz_step.dependOn(&b.addRunArtifact(b.addTest(.{
            .name = b.fmt("zaccesskit-fuzz-{s}", .{fuzz_target.name}),
            .root_module = fuzz_mod,
        })).step);
    }

    // Golden-vector harness. A fixture is a file, so it is a separate binary
    // and `@embedFile` turns a missing vector into a build failure.
    const vectors = b.addExecutable(.{
        .name = "zaccesskit-vectors",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/vectors/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    vectors.root_module.addImport("zio", zio);
    vectors.root_module.addImport("zaccesskit", zak);
    b.step("vectors", "Run the recorded-fixture harness").dependOn(
        &b.addRunArtifact(vectors).step,
    );
}
```

Four things in the fragment have no line to copy from, and each is `[INFERENCE]`:

- `src/shard_*.zig`. The five names follow zomp's area split. `docs/40-plan.md`
  may rename them.
- `test/vectors/main.zig`. zomp calls this `test/main.zig`
  (`zomp/build.zig:205`). A subdirectory is clearer once a second harness joins
  it, and `test/vectors/` is where zomp puts the fixture files
  (`zomp/AGENTS.md:49`, `zomp/AGENTS.md:161-163`).
- `b.addLibrary` with `.linkage = .static`. ozai's shape at `ozai/build.zig:26-31`.
- The `zaccesskit` module name. `[INFERENCE]` that the package publishes a module
  and not only an executable. `docs/30-port-design.md` owns that choice; the
  fragment is written so swapping it for `b.createModule` is a five-line edit.

The last shard path, `src/shard_platform.zig`, carries the scripted-platform and
transcript-replay tests from section 6.

### 2.5 The embed path rule that bites fixtures

A module created with `root_source_file = b.path("src/root.zig")` has `src/` as
its package root, so `@embedFile("../../test/vectors/…")` from `src/` fails with
`embed of file outside package path`, and listing `test` in `build.zig.zon`'s
`.paths` does not widen it (`zomp/AGENTS.md:157-163`).

Two consequences. First, the fixture harness is its own module rooted at
`test/vectors/main.zig`, which is why the fragment builds it as a separate
executable rather than an `addTest`. Second, any fixture read at runtime from a
`src/` module must have its length checked, so a missing or truncated capture is
a failed test rather than a silent pass (`zomp/AGENTS.md:162-163`).

---

## 3. Determinism

### 3.1 The rule

`ozai/AGENTS.md:59-63` states the rule and the reason:

> `io: std.Io` threaded explicitly (never global) → deterministic simulation
> (VOPR pattern; marionette on 0.16): deterministic Io swap, seed+commit
> reproducibility, time as data. Logic never reads clock/env/cwd — lifted inputs.
> A `localtime()` failure hid a 4-yearly bug behind 100% line coverage in
> another project.

`ozai/AGENTS.md:65-68` adds the rule that decides this port's test seams: network
logic is pure over bytes, every state machine takes a decoded message and a
state value and returns a new state plus an action list, with no socket handle,
no clock read and no allocator.

`ozai/AGENTS.md:93-94` makes non-determinism a review finding, not a documented
limitation.

### 3.2 What zio actually offers

zio 0.18.0 has no virtual clock and no injectable Io implementation.

| Fact | Source |
|------|--------|
| `zio.Clock` is an enum of five real OS clocks: `awake`, `boot`, `real`, `cpu_process`, `cpu_thread` | `zio/src/time.zig:46-56` |
| `Timestamp.now(clock)` calls `os.time.now(clock)` | `zio/src/time.zig:370-372` |
| `Runtime.now()` forwards to the module-level `now()`, documented as the event loop's cached time | `zio/src/runtime.zig:2059-2064` |
| Backends are `poll`, `linux`, `epoll`, `kqueue`, `io_uring`, `iocp` | `zio/src/options.zig:46`, `zio/build.zig:129` |
| Scheduling is `single_executor`, `pinned`, `work_stealing` | `zio/src/options.zig:22-44` |
| The default scheduling is `work_stealing` | `zio/src/options.zig:23-33`, `zio/build.zig:20` |
| A `-fsingle-threaded` build is forced to one executor | `zio/src/options.zig:69-76`, the assignment at `:73` |
| `-Dbackend=` and `-Dscheduling=` select both at configure time | `zio/build.zig:12-13` |
| zio's own test runner builds a real `Io.Threaded` per test | `zio/test_runner.zig:189-190` |

So the clock is a **choice of clock**, never a **value of the clock**. The only
way a zio test controls time is by not reading it.

### 3.3 What std.testing offers

| Type or function | Line | Use |
|------------------|------|-----|
| `std.testing.io` | `lib/std/testing.zig:35` | a real `Io.Threaded` (`:34`) |
| `std.testing.allocator` | `lib/std/testing.zig:21` | `DebugAllocator` with a leak-detecting canary (`:22-32`) |
| `std.testing.Reader` | `lib/std/testing.zig:1236-1275` | an `Io.Reader` that writes a predetermined list of buffers, one per `stream` call (`:1262-1274`) |
| `std.testing.ReaderIndirect` | `lib/std/testing.zig:1279` | the same, behind another reader, always returning 0 |
| `std.testing.tmpDir` | `lib/std/testing.zig:634` | a scratch directory for socket paths |
| `std.testing.random_seed` | `lib/std/testing.zig:11` | set by the runner from `--seed=` (`lib/compiler/test_runner.zig:55-57`) |
| `std.testing.FailingAllocator` | `lib/std/testing/FailingAllocator.zig:30` | fails the Nth allocation (`:24`) and the Nth resize (`:27`) |
| `std.testing.failing_allocator` | `lib/std/testing.zig:14` | a global instance fixed at index 0 |
| `std.testing.checkAllAllocationFailures` | `lib/std/testing.zig:1115` | sweeps the fail index from 0 to the successful count |

`std.testing.Reader` is the deterministic stream the fake D-Bus peer in section 6
uses. Its `Call` list (`:1244-1246`) fixes both the byte content and the number
of `stream` calls, so a test that depends on how a message was split across reads
fails when that split changes.

`checkAllAllocationFailures` returns three named errors, and each names a defect
(`lib/std/testing.zig:1135-1156`):

- `error.SwallowedOutOfMemoryError` — the code ignored an allocation failure;
- `error.NondeterministicMemoryUsage` — the allocation count changed between the
  baseline run and a failing run;
- `error.MemoryLeakDetected` — allocated bytes differ from freed bytes at the
  failing index.

### 3.4 The three seams this port must have

1. **Clock as data.** Every function that needs "now" takes a `Timestamp` value.
   Nothing under `src/` calls `zio.now`, `Timestamp.now` or `Clock.now`. A
   source-level gate enforces this: section 8 item G14.
2. **Bytes as data.** The update protocol, the property codec and the ABI
   marshaller take a byte slice and return a value. No socket, no handle.
   `ozai/AGENTS.md:65-68`.
3. **State as a parameter.** `process(event, &state)` rather than a closure over
   a cache. `ozai/AGENTS.md:69-70`, which names the visible failure: a sequence
   bug where `(5,4)` after `(5,0)` stays invisible.

### 3.5 What a zio test can and cannot control

**Can.**

| Control | How |
|---------|-----|
| Allocator identity and every allocation index | `std.testing.allocator`; `checkAllAllocationFailures` |
| Number of executors | `Runtime.init(allocator, .{ .executors = .exact(n) })`; `zio/src/runtime.zig:1620`, a use at `:2475` |
| Presence of the blocking thread pool | `Runtime.init(allocator, .{ .thread_pool = .{} })`, `zio/src/runtime.zig:2154` |
| Scheduling discipline | `-Dscheduling=single_executor` |
| Event loop backend | `-Dbackend=poll` |
| Number of threads in the process | `-fsingle-threaded`, which zio forces to one executor (`zio/src/options.zig:73`) |
| The bytes a reader yields and how it splits them | `std.testing.Reader` |
| Which OS clock a `Clock` value names | `zio/src/time.zig:64-72` |
| Seed for a fuzzed value | `--seed=` on the test binary, `lib/compiler/test_runner.zig:55-57` |
| Process boundaries | one artifact per concern, as ozai does at `ozai/build.zig:293-323` |

**Cannot.**

| Gap | Evidence | Consequence for the plan |
|-----|----------|---------------------------|
| Make `now` return a chosen value | zio has no clock interface to swap; `Timestamp.now` calls straight into `os.time` (`zio/src/time.zig:370-372`) | Every timestamp enters as a parameter. A test that needs elapsed time asserts on the difference between two lifted values. |
| Replace the `Io` inside a zio test | zio's runner constructs `Io.Threaded` per test (`zio/test_runner.zig:190`) | No VOPR marionette. Determinism comes from parameter injection, not from an Io swap. This is a real gap against `ozai/AGENTS.md:60`. |
| Fix the interleaving of N tasks | `work_stealing` is the default (`zio/src/options.zig:23-33`) and moves tasks between executors (`:40-42`) | Assert on the set of events, not on their order, unless the test runs `-Dscheduling=single_executor`. |
| Count tests through zio's own runner | zio's `build.zig:114` sets `.mode = .simple`, so the build runner does not speak the test-server protocol | zaccesskit must use the default server-mode runner for any artifact that must report a count to `zig build`. ozai sets `.mode = .server` explicitly (`ozai/build.zig:227`). |
| Reach a fuzzer through a `.simple` runner | `lib/compiler/test_runner.zig:259` panics with `fuzz test requires server` when `builtin.fuzz` is set outside the server mode | Same conclusion. Fuzz targets use the default runner. |

The last two rows matter enough to state plainly: **a project that copies zio's
test-runner wiring loses test counts and loses fuzzing.** zaccesskit does not
copy it.

---

## 4. Fuzzing

### 4.1 The API, exactly

```zig
pub const FuzzInputOptions = struct {
    corpus: []const []const u8 = &.{},
};

pub inline fn fuzz(
    context: anytype,
    comptime testOne: fn (context: @TypeOf(context), smith: *Smith) anyerror!void,
    options: FuzzInputOptions,
) anyerror!void
```

`lib/std/testing.zig:1222-1233`. The body forwards to the root module's `fuzz`
at `lib/std/testing.zig:1232`, which is the compiler's test runner function at
`lib/compiler/test_runner.zig:526-607`.

The runner does four things that decide how a target is written.

| Behaviour | Line |
|-----------|------|
| `is_fuzz_test = true` is set on entry; a test that returns without calling `std.testing.fuzz` panics with `missed call to std.testing.fuzz` | `:542`, checked at `:448` |
| An error log before fuzzing starts panics with `error logs detected` | `:545`, `:449` |
| Without `-ffuzz`, the runner walks `options.corpus` and then runs one empty string as a smoke test | `:596-606` |
| With `-ffuzz`, each corpus entry is handed to the fuzzer as a seed and `fuzzer_start_test` runs | `:582-594` |

Each invocation resets `testing.allocator_instance` and calls
`testing.allocator_instance.deinit()`, exiting 1 on a leak
(`lib/compiler/test_runner.zig:557-558`). An `error.SkipZigTest` from `testOne`
counts as a pass (`:561`).

### 4.2 The Smith interface

`Smith` is `lib/std/testing/Smith.zig`, 930 lines. One field:

```zig
in: ?[]const u8,   // lib/std/testing/Smith.zig:12
```

It is the corpus entry verbatim while the corpus replays, and `null` when the
fuzzer drives (`:620`, `:649`). Every method then takes one of two paths:
consume from `in` when it is set, or call into the fuzzer ABI when it is `null`
(`:649-657`).

| Method | Line | Returns |
|--------|------|---------|
| `value(T)` | `:185` | a `T` of any type the fuzzer can construct |
| `valueWeighted(T, weights)` | `:191` | a `T` biased by a weight list |
| `valueRangeAtMost(T, least, most)` | `:197` | a `T` in a closed range |
| `valueRangeLessThan(T, least, less_than)` | `:203` | a `T` in a half-open range |
| `index(len)` | `:212` | a `usize` below `len` |
| `boolWeighted(false_w, true_w)` | `:221` | a `bool` |
| `eos()` | `:230` | `true` when the input is spent, which lets a target build a length-delimited structure from a flat buffer |
| `eosWeighted(weights)`, `eosWeightedSimple(f, t)` | `:241`, `:253` | the same with bias |
| `bytes(out)`, `bytesWeighted(out, weights)` | `:259`, `:265` | fill a buffer exactly |
| `slice(buf)` | `:274` | fill a buffer with a fuzzer-chosen length |
| `sliceWeightedBytes(buf, weights)` | `:284` | biased bytes with a chosen length |
| `sliceWeighted(buf, len_weights, weights)` | `:294` | biased length and biased bytes |
| `baselineWeights(T)` | `:45` | the default weight list for `T` |

Every one of these has a `…WithHash` twin that takes an explicit `hash: u32`
(`:364` onward). Use the plain form. It derives the hash from the return address
of a `noinline` wrapper (`lib/std/testing/Smith.zig:179-188`), which is what
gives each call site its own stable slot in the fuzzer's corpus.

`slice` is the one to reach for at a decoder boundary, and `eos` is the one to
reach for at a nesting boundary. `lib/std/testing/Smith.zig:620-630` shows how a
replay consumes `slice` inputs: a 4-byte little-endian length header, then that
many bytes, with a short input degrading to length 0 rather than a fault.

### 4.3 Registration and driving

There is no build-script API for the fuzzer. ozai records this at
`ozai/build.zig:410-434`: the build runner reads `--fuzz[=N]` from its own
command line, records which tests a run step owns called `std.testing.fuzz`, then
rebuilds those run steps with `-ffuzz` and drives them.

The evidence in the standard library:

| Step | Source |
|------|--------|
| `Run.fuzz_tests` collects the names of tests that reported the fuzz flag | `lib/std/Build/Step/Run.zig:91-94`, populated at `:1964` |
| the run step sends `.start_fuzzing` with the test names and a limit kind | `lib/std/Build/Step/Run.zig:2587-2625` |
| `LimitKind` is `enum(u8) { forever, iterations }` | `lib/std/Build/abi.zig:323` |
| the instance count is CPU-bound under `forever` and 1 under `iterations` | `lib/std/Build/Step/Run.zig:2057-2060` |
| a failing input is written into the build cache and named | `lib/std/Build/Step/Run.zig:2422-2426` |

Registration in `build.zig` is therefore the pattern in `ozai/build.zig:439-460`:
a `const` list of `{ name, file }`, one `b.createModule` per entry, one
`b.addRunArtifact(b.addTest(...))`, and one `fuzz_step.dependOn`. No `fuzz = true`
goes on the artifact. ozai explains why at `ozai/build.zig:420-423`: a binary
that already carries `-ffuzz` crashes when a fuzz test runs outside the fuzzer's
own driver, which is exactly what a bare `zig build fuzz` is.

Two constraints the fragment must respect. The optimize mode is pinned off Debug,
because that rebuild is what meets the fuzzer's error path, and only `-ffuzz`
analyses it (`ozai/build.zig:424-428`). And the artifact must be absent from any
coverage list, because coverage turns `fuzz` on as its own switch and a coverage
build would hand the binary `-ffuzz` outside the driver (`ozai/build.zig:430-434`).

### 4.4 What the gate does with fuzz targets

Nothing. `zig-gate` has no fuzz stage. See section 1.6. `zig build fuzz` replays
the committed corpus and stops, which is the bounded form a commit gate can
afford (`ozai/build.zig:417-418`). The mutation form is `zig build fuzz
--fuzz=<bounded>`, which `ozai/AGENTS.md:128` names as gate 10: every decoder, no
crashes, inputs replayed.

So the milestone plan carries two fuzz lines: a required corpus replay, and a
nightly bounded mutation run.

### 4.5 Which parts of an AccessKit port are worth fuzzing

Four areas, four files. Each pairs one target file with one corpus directory, as
`ozai/build.zig:437-438` requires.

**1. The update protocol.** Target file `test/fuzz/tree_update_fuzz.zig`, corpus
`test/corpus/tree_update/`. The oracle is that no input produces a tree the port
cannot represent: a node that is neither the root nor a child of the root tree
or of another node in the same update. That rule is upstream's own, at
`accesskit/accesskit/src/lib.rs:3216-3228`. The target drives the port's
equivalent of `TreeState::update_and_process_changes`
(`accesskit/accesskit_consumer/src/tree.rs:620-628`), which is where upstream
enforces it.

**2. Property serialisation.** Target file `test/fuzz/property_fuzz.zig`, corpus
`test/corpus/property/`. Two oracles. Encode, decode, encode is a fixed point.
And a cleared property equals a property that was never set, which upstream
asserts itself at `accesskit/accesskit/src/lib.rs:3408-3414`, alongside the
order-independence rule at `:3393-3406`. Fuzz the value domain with
`smith.value(PropertyValue)`, then the byte domain with `smith.slice`.

**3. ABI marshalling.** Target file `test/fuzz/abi_marshalling_fuzz.zig`, corpus
`test/corpus/abi/`. Build a tree update through the C ABI, serialize it, decode
it, and compare against the value the API was given. The surface is wide and
mechanical: `accesskit-c/include/accesskit.h:2378` builds an update, `:2381` frees
one, and many setters have a `_with_length` twin that takes a caller-supplied
length, such as `accesskit_tree_info_set_toolkit_name_with_length` at `:2343`.
A wrong length is an out-of-bounds read with no other symptom, which makes this
the highest-value target in the set.

**4. The D-Bus message decoder.** Target file `test/fuzz/dbus_message_fuzz.zig`,
corpus `test/corpus/dbus_message/`. The oracle is that a decoded message either
is a well-formed goose value or returns a declared error, never a panic and never
a read past a truncated buffer. This is the only target that runs untrusted bytes
end to end, so it is the one that uses `smith.slice` for the whole buffer and
`smith.eos` for each nested value length prefix.

Two more are worth naming, at lower priority. `test/fuzz/atspi_node_fuzz.zig`
covers the AT-SPI string and reference decoding that sits between areas 3 and 4.
`test/fuzz/text_range_fuzz.zig` covers the text interface, where upstream
keeps `character_lengths` and the text buffer in step across a clone
(`accesskit/accesskit/src/lib.rs:3450-3461`).

---

## 5. Recorded fixtures

### 5.1 The rule

`ozai/AGENTS.md:89-91` makes interoperability a test:

> Wire compatibility is a test, not a comment. Any claim of iroh
> interoperability is a golden-vector test carrying bytes captured from the
> Rust implementation, or it is an unverified claim.

The port constraint adds the hard part. No `cargo`, no `rustc`, no `build.rs`, no
`cbindgen`, at any point. The recorder therefore runs **offline, by hand, on a
machine that has a Rust toolchain**, and its output is committed. The build never
regenerates a fixture and never shells out.

The version skew is recorded in `local://zaccesskit-deps.md:74-76`: core is
0.25.1 and the C bindings are 0.23.1, and the C ABI left the main repository on
2024-07-21 in commit `553d9c1`. Each fixture records which of the two it came
from.

### 5.2 The file format

One case is two files. The `.bin` is the recorded bytes and nothing else. The
`.meta.json` is the case's identity.

```
test/fixtures/
  README.md
  manifest.json
  tree_update/
    0001_root_with_two_children.bin
    0001_root_with_two_children.meta.json
    0002_focus_moves.bin
    0002_focus_moves.meta.json
  abi/
    ...
```

`manifest.json`:

```json
{
  "schema": 1,
  "generator": {
    "note": "Recorded by hand from the upstream tree. See test/fixtures/README.md.",
    "rust_toolchain_used_offline": "1.79.0"
  },
  "sources": {
    "core": {
      "repository": "https://github.com/AccessKit/accesskit",
      "commit": "466e24e252103f4d82bd6fbab98141b551e46e0c",
      "version": "0.25.1"
    },
    "c": {
      "repository": "https://github.com/AccessKit/accesskit-c",
      "commit": "8b6ed37c20ed4c59390e253407983333053662ba",
      "version": "0.23.1"
    }
  },
  "cases": [
    {
      "name": "tree_update/0001_root_with_two_children",
      "body_sha256": "<64 lowercase hex digits>",
      "body_len": 0,
      "recorded_from": "accesskit::TreeUpdate with the serde feature, serialized to Vec<u8>",
      "intent": "The smallest update that is not trivial: a root with two children and focus on the first."
    }
  ]
}
```

Fields the format requires, and why each one exists.

| Field | Why it is required |
|-------|--------------------|
| `schema` | A change to the container or the metadata is a version bump, and a reader rejects a `schema` it does not know. Without it, an old harness reads new metadata as valid. |
| `sources.core.commit` | The exact tree the bytes came from. Without it, "0.25.1" names a moving tag and the fixture is unreproducible. |
| `sources.c.commit` | The C bindings version independently. A fixture recorded through the C ABI carries the second commit, not the first. |
| `cases[].body_sha256` | The checksum. A truncated or hand-edited capture becomes a **test failure**, not a silently shorter input. This is the field that catches a bad merge. |
| `cases[].body_len` | The length the recorder observed. A `.bin` shorter than this fails before the hash, with a message naming the file. |
| `cases[].intent` | The one sentence a reviewer reads. A fixture nobody understands does not get regenerated. |

The digest is `std.crypto.hash.sha2.Sha256`, declared at
`lib/std/crypto/sha2.zig:23`, with `digest_length` at `:94` and the one-shot
`hash(b, out, .{})` at `:108`.

### 5.3 The case metadata, worked example

`test/fixtures/tree_update/0001_root_with_two_children.meta.json`:

```json
{
  "name": "tree_update/0001_root_with_two_children",
  "schema": 1,
  "body_sha256": "<64 lowercase hex digits>",
  "body_len": 214,
  "recorded_from": {
    "crate": "accesskit",
    "commit": "466e24e252103f4d82bd6fbab98141b551e46e0c",
    "version": "0.25.1",
    "path": "accesskit/src/lib.rs",
    "symbol": "TreeUpdate"
  },
  "upstream_field_names": {
    "TreeUpdate": ["nodes", "tree", "treeId", "focus"],
    "TreeInfo": ["root", "toolkitName", "toolkitVersion"]
  },
  "input_semantics": {
    "node_count": 3,
    "root_id": 1,
    "child_ids": [2, 3],
    "focus_id": 2,
    "tree_id": 0
  },
  "oracles": [
    "decode succeeds",
    "the node set is exactly {1,2,3}",
    "focus resolves to node 2",
    "tree.toolkitName equals the recorded value",
    "re-encode equals the body byte for byte"
  ]
}
```

Two things in this example are verified and one is not.

- `TreeUpdate`'s field names and its `camelCase` serde rename are verified at
  `accesskit/accesskit/src/lib.rs:3203-3258`: `nodes` at `:3229`, `tree` at
  `:3235`, `tree_id` at `:3246`, `focus` at `:3257`, and the
  `rename_all = "camelCase"` attribute at `:3207`.
- `TreeInfo`'s fields are verified at `accesskit/accesskit/src/lib.rs:3169-3177`:
  `root`, `toolkit_name`, `toolkit_version`.
- `Node`'s serialized field set is **not** asserted here. The public struct at
  `accesskit/accesskit/src/lib.rs:1107` has five private fields, `role`,
  `actions`, `child_actions`, `flags` and `properties`, and its accessors are
  generated below it. The exact serde shape of a node is a question the recorder
  answers, not one this document guesses. The fixture records the bytes and the
  port decodes them. That is the whole point of the format.

`input_semantics` is what makes a fixture reviewable without a decoder. It states
what the bytes mean in plain numbers, and the harness cross-checks each field
against the decoded value. A fixture whose semantics no longer match its bytes
fails, which is the disagreement a reviewer needs to see.

### 5.4 Regeneration without upstream

Upstream may be unavailable: a tag may be force-pushed, or the network may be
gone. The procedure does not need upstream.

1. **The fixtures are the source of truth.** They are committed files. A test
   runs from them alone. Nothing in the build, and nothing in the harness, ever
   consults a Git remote.
2. **Regeneration is a re-recording from another recorded fixture.** When the
   port must add a case for a shape it has not seen, the recorder extends an
   existing `.bin` through the port's own serializer and stores the result as a
   **new** case with `recorded_from` naming the case it derives from and the port
   commit. Such a case is a regression test, not a conformance test, and the
   manifest marks it with `"derived_from": "tree_update/0001_root_with_two_children"`
   so nobody reads it as upstream authority.
3. **Only a real upstream recording produces a conformance claim.**
   `docs/50-verification.md` records which cases carry an upstream commit and
   which do not. A milestone that claims interoperability points at cases with
   the commit field set.
4. **Bumping upstream is a new fixture set, not a rewrite.** Add a new `sources`
   entry, raise `schema`, and leave the old cases in place. The old cases keep
   proving what they proved. This applies the house rule of no backwards
   compatibility to evidence rather than to code (`ozai/AGENTS.md:52`).

### 5.5 The harness rules

The harness is `test/vectors/main.zig`, its own module root, so `@embedFile`
resolves (section 2.5). It satisfies these rules, and each one has a fixture that
proves it.

| Rule | Failure mode it prevents |
|------|---------------------------|
| Load every case named in `manifest.json` with `@embedFile` | A missing fixture is a build failure, not a skip (`zomp/AGENTS.md:49-50`) |
| Assert `sha256(body) == body_sha256` before decoding | A truncated merge passes silently |
| Assert `body.len == body_len` and report both numbers | Same defect, with a shorter message |
| Refuse any `schema` the harness does not know | New metadata read as valid |
| Refuse a `.bin` with no sibling `.meta.json`, and a `.meta.json` with no `.bin` | A half-committed pair looks like coverage |
| Report a malformed fixture as a named error carrying the case index, never a panic | A panic destroys every remaining case. The shape is `[INFERENCE]`: it follows zomp's harness at `zomp/test/main.zig:17-29` and its `reportFixture` at `:56-67`. |

---

## 6. Platform testing without a platform

### 6.1 What upstream gives the port as a seam

| Item | Source |
|------|--------|
| The shared AT-SPI adapter is a plain struct with no platform calls in its own signature | `accesskit/adapters/atspi-common/src/adapter.rs:360` |
| Its only output channel is a three-method trait: `register_interfaces`, `unregister_interfaces`, `emit_event` | `accesskit/adapters/atspi-common/src/callback.rs:11-16` |
| The event it emits is one struct | `accesskit/adapters/atspi-common/src/simplified.rs:675` |
| The consumer's update entry is `update_and_process_changes(update, handler)` | `accesskit/accesskit_consumer/src/tree.rs:620-628` |
| Its change callback is a four-method trait | `accesskit/accesskit_consumer/src/tree.rs:578-583` |

That is the whole port boundary for the tree: decoded platform events go in, a
`TreeUpdate` comes out, and the consumer applies it. Both ends are interfaces, so
both ends are substitutable in a test.

### 6.2 The three techniques

#### A. Scripted platform

A test-local struct implementing the adapter's output trait, plus a table of
decoded platform records the adapter must turn into events.

| Element | Contract |
|---------|----------|
| The fake platform | Implements `register_interfaces`, `unregister_interfaces` and `emit_event`. Records every call into an append-only log. |
| The script | An ordered list of platform records, each decoded by the port's own decoder before the adapter sees it. |
| The driver | Feeds records one at a time, then reads the log. |
| The oracle | The log equals the recorded log for that script, element for element. |

**Proves.** The tree model, the interface registry lifetime, the event
translation, and the adapter's memory discipline. Every allocation goes through
`std.testing.allocator`, so a leaked interface registration fails.

**Does not prove.** That the real native API returns what the script claims. A
wrong assumption in the script produces a green run over a wrong tree.

#### B. Recorded event transcript replayed through the adapter

The script from A, plus the resulting `TreeUpdate` bytes as ground truth.

| Element | Contract |
|---------|----------|
| The transcript | Section 5's fixture pair, with `recorded_from` naming the upstream commit and the native API it was captured from. |
| The replay | Decode each record, drive the adapter, serialize the resulting update. |
| The oracle | Three checks: the update bytes equal the recorded update; the resulting update has exactly the recorded node id set; every `emit_event` call matches the recorded one. |

**Proves.** The event-to-update pipeline, byte for byte, and it does so without a
windowing system. This is the closest a headless host gets to the platform.

**Does not prove.** That the native API emits these records in this order, that
the native API emits them at all, and that the platform sends the platform event
at all. The transcript is a claim about the platform, and only a run on the
platform confirms it.

#### C. Fake D-Bus peer over a socket pair

The AT-SPI bus transport, replaced.

| Element | Contract |
|---------|----------|
| The listener | `std.Io.net.UnixAddress.listen(io, .{})` then `Server.accept(io)`; `lib/std/Io/net.zig:880` and `:1442`. The path comes from `std.testing.tmpDir` (`lib/std/testing.zig:634`). |
| The client | `UnixAddress.connect(io)`, `lib/std/Io/net.zig:908`. |
| The scripted peer | Serves bytes from a fixture through `std.testing.Reader` (`lib/std/testing.zig:1236`), or from a socket peer, and reads what the adapter writes. |
| The oracle | The bytes the adapter writes equal the recorded bytes, and the reply the script serves produces the recorded decoded result. |

On a platform without UNIX sockets, `std.Io.net.has_unix_sockets`
(`lib/std/Io/net.zig:49`) is false and the test returns `error.SkipZigTest`. The
skip is honest, because section 8's gate treats a skip as a skip and not as a
pass.

**Proves.** The D-Bus marshalling, the match-rule handling, the method dispatch,
the signal demultiplexing and the auth handshake, against bytes captured from a
real bus. This is the only technique that exercises the true wire.

**Does not prove.** That a real `at-spi2-registryd` emits the same messages, that
a real bus routes them the same way, and that the adapter behaves under the real
bus's concurrency.

### 6.3 Per adapter

| Adapter | Scripted platform | Transcript replay | Fake D-Bus peer | Notes |
|---------|-------------------|-------------------|-----------------|-------|
| `atspi-common` | primary | primary | primary | The only adapter all three techniques fit without a shim. The seam is `callback.rs:11-16`. |
| `unix` | primary | primary | not applicable | The platform input is the D-Bus accessibility bus. A synthetic bus message replaces the bus event, and the AT-SPI conversion is the unit under test. There is no X11 or Wayland event to replace: `docs/12-accesskit-adapters.md:68` proves it, and `docs/14-x11-wayland-surface.md:7-9` and `:94-95` restate it. |
| `winit` | primary | primary | not applicable | Same shape as `unix`, with one difference: winit really is an event source, so a synthetic `Event` table replaces the platform event. |
| `macos` | limited | primary | not applicable | The AX API is an Objective-C object graph. The testable seam is the state machine below it, plus a fake `AXUIElement` shim behind a narrow interface. `[INFERENCE]` that the shim is worth building; `docs/12-accesskit-adapters.md` owns that decision. |
| `windows` | limited | primary | not applicable | Same shape as `macos`, against `IRawElementProviderSimple`. The provider table is a natural fixture. |
| `ios` | not applicable | primary | not applicable | The state machine is reachable; the Objective-C side is not. Fuzz the record that crosses the FFI boundary rather than the boundary call itself. |
| `android` | not applicable | primary | not applicable | Same as `ios`, over JNI. The JNI signature is the unfuzzable part; the decoded record on the far side is fuzzable. |

The last two rows are the honest ones. A JNI or Objective-C boundary cannot be
driven on a Linux host, so the plan states what it gives up rather than claiming
a green run covers it. What the port can prove for `ios` and `android` is the
state machine that receives an already-decoded record, and the byte layout of that
record. What it cannot prove is that the foreign side produces it.

### 6.4 What the techniques do not reach

State this in the plan so no milestone claims it:

- That any real platform produces the transcribed events.
- That a real D-Bus daemon performs the match and the routing.
- Anything about window creation, focus rings or compositor behaviour.
- Anything about the iOS and Android runtimes.

Each of those needs a host with the platform present. The plan records them as
out of scope with the reason. `ozai/AGENTS.md:205-206` requires it: `When in
doubt: SKIP, don't guess. Silent skips forbidden; report N/A explicitly.`

---

## 7. The coverage obligation

### 7.1 What the gate does

Stage 10, `zig-gate:788-815`. It is opt-in and advisory.

| Property | Value | Source |
|----------|-------|--------|
| Activation | `--cov` on the gate's command line | parsed `zig-gate:18`, honoured `:790` |
| Command | `zig-cov test --exclude=zig-pkg --exclude=vk.zig [--fail-under=<pct>]` | `:795-799` |
| Fails the run | only when `ZIG_COV_FAIL_UNDER` is set | `:812` |
| Skips | tool absent `:792-793`; `build.zig` not wired `:804-806`; plain `zig build test` fails `:807-808` | |
| Metric | line coverage | `zig-cov --help`: `--fail-under=<pct>  Exit 1 if line coverage below threshold` |

### 7.2 Line versus branch

**There is no branch metric.** Verified by reading `zig-cov --help`. The only
threshold flag is `--fail-under=<pct>`, and it is defined against line coverage.
`zig-cov report --format=` offers `summary`, `lcov`, `html`, `json`, `cobertura`
and `github`. Every one of those is a line-coverage format.

The house rule agrees. `ozai/AGENTS.md:125` names gate 7 as "measure changed
paths (kcov 0.16 / zcov 0.17-dev); every uncovered path: test, refactor, or
accept with a written reason". Note the unit: **changed paths**, not the whole
tree. And the disposition is one of three, with the third written down.

`ozai/AGENTS.md:130-131` sets the density rule that keeps this honest:

> Density rule: 12/357 paths is noise; 352/357 makes each missing path a
> judgment call. Coverage guides, never gates alone.

`ozai/AGENTS.md:126` adds the static-analysis gate, and `ozai/AGENTS.md:127-128`
adds sanitizers as optional and fuzz as "every decoder, no crashes, inputs
replayed".

So the coverage obligation is **not** a percentage. It is: for every uncovered
path in the changed set, one of three dispositions, and the third one written
down.

### 7.3 The wiring conflict the plan must resolve

`zig-cov --help` gives this setup:

```zig
unit_tests.sanitize_coverage_trace_pc_guard = true;
unit_tests.root_module.addObjectFile(.{ .cwd_relative = rt_path });
```

ozai wires it differently (`ozai/build.zig:385-391`): `artifact.use_llvm = true`,
`artifact.root_module.fuzz = true`, `link_libc = true`, plus the object file. Its
comment at `ozai/build.zig:385-387` gives the reason: the self-hosted backends
emit no counters, `fuzz` is the only switch that makes LLVM emit them, and the
runtime flushes from a libc `atexit` handler, so all three settings are
load-bearing.

Two wirings are documented and they are not the same. `[INFERENCE]` the `zig-cov`
help text predates what ozai needed, and the `-Dcoverage` path also panics when
`-Dcoverage-rt` is missing (`ozai/build.zig:359-363`).

The plan picks one, proves it on a shard, and records the proof. Until it does,
coverage is unavailable and the obligation is unmet. That is the honest state,
and it is why section 8's checklist has no coverage item.

### 7.4 What a percentage would hide

The house rule's own example: a `localtime()` failure hid a 4-yearly bug behind
100% line coverage (`ozai/AGENTS.md:62-63`). A line is covered when it runs. It
runs on the happy path. Coverage cannot see the branch a decoder takes on byte
`0xff`, which is exactly the branch a fuzz target exists to reach.

That is the argument for section 4 and for section 8 items G7, G9 and G10: they
measure what coverage cannot.

---

## 8. The verification plan input

Each item is observable. Each fails with a message that names the defect. No
item here passes on a stub: every one executes a body and compares a result.

Format: `[G<n>] <gate line> — <what it proves> — <what the failure says>`.

**G1** `zig build test --summary all` reports a non-zero executed test count for
every shard, in both modes. Proves the shard root reaches its tests. A zero count
names the shard file. This closes `zig-gate:452-453`, where a project with no
tests still gets a green gate. `ozai/build.zig:56-65` records the same trap.

**G2** A source-level check walks `src/`, finds every file containing a `test`
block, and asserts each one is reachable from a registered shard root. Proves no
test file is orphaned. The failure names the orphan file and the shard list.
`zomp/AGENTS.md:41-42` states the rule: adding a module to `root.zig` does
nothing.

**G3** Every shard runs with `std.testing.allocator` and reports zero leaks in
Debug and ReleaseSafe. Proves lifetime discipline. The failure names the shard
and the allocation stack.

**G4** `checkAllAllocationFailures` runs over every public function that
allocates. Proves every OOM path unwinds. The three errors it can return each name
a defect (`lib/std/testing.zig:1135-1156`). `ozai/AGENTS.md:73-75` makes this
mandatory.

**G5** For every declared error set, an `inline for` over `@typeInfo(ErrorSet)`
proves each error is returned by a named call site. Proves no error is
unreachable and none is missing. `ozai/AGENTS.md:77-79`. The failure names the
error.

**G6** For every wire enum, an `inline for` over `@typeInfo(Enum).fields` decodes
one input per variant. Proves the decoder handles every variant. `ozai/AGENTS.md:80-81`
calls this the strongest coverage substitute Zig has. The failure names the
variant.

**G7** encode, decode, encode is a fixed point, byte for byte, for the tree
update, the property list, the ABI record and the D-Bus message. Proves the
codec loses nothing. `ozai/AGENTS.md:87` names the metamorphic oracle. The
failure reports the first differing offset and both byte values.

**G8** Every fixture in `manifest.json` loads, its `sha256` matches, its length
matches, and its `input_semantics` agrees with the decoded value. Proves the
recorded evidence is intact and describes what it says it describes. The failure
names the fixture file and the mismatched field.

**G9** `zig build fuzz` runs every registered fuzz target over its committed
corpus with exit 0. Proves every decoder survives its recorded inputs. The
failure names the target and writes the offending input
(`lib/std/Build/Step/Run.zig:2422-2426`).

**G10** `zig build fuzz --fuzz=<bounded>` runs every decoder for the recorded
budget with zero crashes and zero new inputs. Proves the mutation search ran. The
failure names the target, the budget and the saved input path. This is
`ozai/AGENTS.md:128`.

**G11** Every entry in the port's function inventory has a Zig counterpart and at
least one test that calls it. Proves the port is complete against its own
inventory. The failure names the upstream symbol and its `path:line`.

**G12** Every error in the C ABI surface is produced by a call that passes a null
or empty argument where the signature allows one. Proves the ABI defends its
boundary. The failure names the entry point from
`accesskit-c/include/accesskit.h`.

**G13** Every C ABI setter with a `_with_length` twin rejects a length that does
not match the buffer. Proves no caller-supplied length reaches a read unchecked.
The failure names the entry point and the length.

**G14** No file under `src/` calls `zio.now`, `Timestamp.now`, `Clock.now`,
`Runtime.now` or `std.time.nanoTimestamp`. Proves the clock is data.
`ozai/AGENTS.md:61-62`. The failure names `path:line` and the call.

**G15** No file under `src/` stores an `std.Io` in a container-scope or
module-scope variable. Proves `io` is threaded. `ozai/AGENTS.md:59`,
`zomp/AGENTS.md:66-67`. The failure names `path:line` and the declaration.

**G16** The scripted platform's call log equals the recorded log for each
script, element for element. Proves the adapter's event translation and its
interface lifetime. The failure prints the two logs side by side with the first
divergent element marked.

**G17** Each recorded transcript yields the recorded `TreeUpdate` bytes, the
recorded node id set and the recorded focus. Proves the event-to-update pipeline
byte for byte. The failure reports the first differing offset.

**G18** The fake D-Bus peer receives the exact recorded request bytes, and its
recorded reply yields the recorded decoded result. Proves the wire format. The
failure reports the first differing offset and both directions.

**G19** Every action in the port's action table produces the recorded platform
action and the recorded reply code against the fake peer. Proves the action
channel end to end. The failure names the action.

**G20** A test that allocates without bound fails inside the 4 GiB ceiling
instead of exhausting the machine. Proves the ceiling is live and not decorative.
The failure names the shard and the elapsed time. This is `zomp/build.zig:35-39`.
A stub that returns constants passes G1 to G19 and fails here.

**G21** `zig build cross-test` reports `tests_complete` equal to the native count
on every target in `./cross-test.profile.sh`, with `fail=0`. Proves foreign-ABI
and big-endian execution coverage. The gate reads this same line at
`zig-gate:715-784`.

**G22** `zig-gate` exits 0 with no flag. Proves the whole gate, with every
analyser on, rather than a subset. The failure names the stage.

### 8.1 Items that are deliberately absent

| Not included | Why |
|--------------|-----|
| `zig fmt --check` passes | Gate stage 1, already covered by G22 |
| `zig ast-check` passes | Gate stage 4, already covered by G22 |
| A line-coverage percentage | Advisory, and the wiring is unresolved. Section 7.3. |
| `refAllDecls` type-checks | Proves compilation only, which a stub passes |
| The library artifact installs | Proves compilation only |
| `zig build` exits 0 | Proves compilation only |
