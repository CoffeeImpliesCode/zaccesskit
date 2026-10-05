//! Build wiring for zaccesskit.
//!
//! **What this build publishes.** One module, `zaccesskit`, rooted at
//! `src/root.zig`. A dependent package reaches it as
//! `dep.module("zaccesskit")`; no executable and no C artifact exist yet, so
//! `dep.artifact("zaccesskit")` is unsupported and `zig-out/bin` stays empty.
//! The `test` tree is built and is named in `.paths`, so a packaged copy runs
//! its own gate. `docs/40-plan.md` names the milestone that adds the C ABI
//! artifact, and that artifact is not declared before it exists.
//!
//! **Compiler.** `build.zig.zon` declares `.minimum_zig_version = "0.16.0"`.
//! That is a lower bound, not the supported compiler. Zig 0.16.0 is the line
//! this project intends. On this host `zig` is an anyzig shim that reads the
//! same field to select the toolchain, so the manifest is the single version
//! authority for the project and for every tool the gate runs.

const std = @import("std");

/// Package version. Mirrors `.version` in `build.zig.zon`.
///
/// Zig's build API exposes no manifest reader, so this is a second copy. A
/// release bumps both, and `src/root.zig` checks the shape of this value
/// because the C header embeds it at M4.
const version = "0.0.0";

/// Compiler floor. Mirrors `.minimum_zig_version` in `build.zig.zon`, which is
/// the authority and also selects the toolchain through the anyzig shim.
/// `src/root.zig` checks it against the running compiler.
const minimum_zig_version = "0.16.0";

/// Address-space ceiling for one test shard, in kibibytes. Four gigabytes is
/// far above an honest test and far below what an unbounded allocation loop
/// reaches in a minute, so a runaway test fails quickly and visibly instead of
/// taking the machine with it.
const test_address_space_kb: u32 = 4 * 1024 * 1024;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // zio is the async runtime the port is built around. It is a module-level
    // import rather than a whole-package import: only the library needs a
    // runtime, and the test harness wants to construct one explicitly.
    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });

    // The two published values reach source through an options module, so a
    // consumer reads them from `@import("zaccesskit")` rather than parsing the
    // manifest. `docs/31-c-abi-design.md` section 4 needs the version for the
    // shared library's version symbol and the C header's version macro.
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption([]const u8, "minimum_zig_version", minimum_zig_version);

    // The published module. Consumers import `@import("zaccesskit")`.
    const mod = b.addModule("zaccesskit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zio", .module = zio.module("zio") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });

    // Library tests, once per safety mode. Both modes belong to the gate
    // because the house gate runs a plain `zig build test` with no
    // `-Doptimize`, so an optimized-only failure cannot slip past a Debug-only
    // run. The Debug shard is the published module itself, so a change that
    // breaks `dep.module("zaccesskit")` breaks the gate. A module's mode is
    // fixed at creation, so ReleaseSafe needs a private equivalent.
    const test_step = b.step("test", "Run the library tests in Debug and ReleaseSafe");

    const debug_tests = b.addTest(.{
        .name = "test-Debug",
        .root_module = mod,
    });
    test_step.dependOn(&addCeilingedRun(b, "test-Debug", debug_tests).step);

    const release_tests = b.addTest(.{
        .name = "test-ReleaseSafe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    test_step.dependOn(&addCeilingedRun(b, "test-ReleaseSafe", release_tests).step);

    // The foreign matrix. This step runs the Debug shard through the build
    // system's own runner selection, which is native for the host and
    // qemu_user for a foreign target, so `./cross-test.profile.sh` needs no
    // launcher of its own. Deliberately one mode: the native `test` step above
    // already covers both safety modes, and a foreign run is about execution,
    // not about optimisation.
    //
    // No address-space ceiling here. The ceiling is applied by a shell
    // launcher, and a shell launcher does not report counted results to
    // cross-test; worse, under qemu_user the limit would bound the emulator
    // rather than the guest.
    const cross_test_step = b.step(
        "cross-test",
        "Run the Debug shard in foreign targets through the build system's runner",
    );
    const cross_tests = b.addTest(.{
        .name = "cross-test-Debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    const cross_run = b.addRunArtifact(cross_tests);
    // A cached run executes no tests and cannot prove execution coverage.
    cross_run.has_side_effects = true;
    cross_test_step.dependOn(&cross_run.step);

    // The fuzz and adversarial harness. Its module root is `fuzz_root.zig` at
    // the repository root and not a file under `test/`, because a module's
    // package root is the directory that holds its root source file, and this
    // harness reaches `src/` through `../../src/` and embeds
    // `include/zaccesskit.h`. A module rooted at
    // `test/fuzz/property_table.zig` reports `import of file outside module
    // path` for all 21 of those imports.
    // `[OBSERVED: zig 0.16.0 test test/fuzz/property_table.zig, 21 diagnostics]`
    //
    // No `-ffuzz`, and `Module.CreateOptions.fuzz` is not set: it becomes
    // `-ffuzz`, which does not compile the compiler's own test runner on
    // 0.16.0 (`docs/22-zig-build-surface.md:1913-1957`). What runs here is the
    // committed corpus replayed through `std.testing.fuzz`, which a plain test
    // build compiles and runs. That is replay and not mutation, and the step
    // says so instead of being called a fuzz gate.
    //
    // Both safety modes, for the reason the two library shards above give. The
    // address-space ceiling comes with them, because a runaway sweep is the
    // failure the ceiling is for.
    //
    // `zio` and `build_options` are declared although nothing under the
    // harness reaches them today, so that a `src/` module that grows a runtime
    // dependency does not turn this step red.
    //
    // The count this shard prints is larger than the harness: `zig test`
    // collects the `test` blocks of every file it analyses, and this module
    // analyses `src/schema/` and `src/consumer/`, so it re-runs the library
    // tests it pulls in.
    const fuzz_step = b.step("fuzz", "Replay the committed corpus of the property table harness");

    const fuzz_debug = b.addTest(.{
        .name = "fuzz-Debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz_root.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    const fuzz_debug_run = addCeilingedRun(b, "fuzz-Debug", fuzz_debug);
    test_step.dependOn(&fuzz_debug_run.step);
    fuzz_step.dependOn(&fuzz_debug_run.step);

    const fuzz_release = b.addTest(.{
        .name = "fuzz-ReleaseSafe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz_root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zio", .module = zio.module("zio") },
                .{ .name = "build_options", .module = options.createModule() },
            },
        }),
    });
    const fuzz_release_run = addCeilingedRun(b, "fuzz-ReleaseSafe", fuzz_release);
    test_step.dependOn(&fuzz_release_run.step);
    fuzz_step.dependOn(&fuzz_release_run.step);

    // The C ABI parity sweep. The tool compares `include/zaccesskit.h` against
    // what `src/capi/*.zig` exports, per target, with the header's preprocessor
    // guards and the Zig `comptime` guards both evaluated. It imports the
    // published module so `src/capi/platform.zig` owns the guard logic rather
    // than a second copy of it living in the tool.
    //
    // Debug, and the same module the Debug test shard uses: the sweep reads
    // the same declarations the tests compile, and a mode that analysed a
    // different set would be measuring something nobody builds.
    //
    // `has_side_effects` because a cached run executes nothing. A parity check
    // that can report success without having compared anything is the failure
    // this step exists to prevent.
    const parity_step = b.step(
        "capi-parity",
        "Compare the C header against the exports for every measured target",
    );

    // One module, two artifacts: the tool's own tests and the sweep itself read
    // the same files, and a second module would be a second thing to keep in
    // step with the first.
    const parity_module = b.createModule(.{
        .root_source_file = b.path("tools/capi_parity/main.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zaccesskit", .module = mod },
        },
    });

    // The tool's own tests run first and gate the sweep. The scanner's tests
    // are what prove it reads a declaration-shaped comment as a comment, so a
    // sweep that ran without them would be reporting on code nothing checked.
    const parity_tests = b.addTest(.{
        .name = "capi-parity-test",
        .root_module = parity_module,
    });
    const parity_test_run = b.addRunArtifact(parity_tests);
    parity_test_run.has_side_effects = true;
    parity_step.dependOn(&parity_test_run.step);

    const parity = b.addExecutable(.{
        .name = "capi-parity",
        .root_module = parity_module,
    });
    const parity_run = b.addRunArtifact(parity);
    parity_run.has_side_effects = true;
    if (b.args) |args| parity_run.addArgs(args);
    parity_run.step.dependOn(&parity_test_run.step);
    parity_step.dependOn(&parity_run.step);

    // The per-module symbol tables in `docs/36-consumer-call-graph.md`. The
    // tool reads every module under `src/`, resolves each qualified name to the
    // file that declares it, and compares what it found against the tables the
    // document marks as generated. It imports nothing from the library: it
    // reads the same files a compiler would, and parsing the source a second
    // time is what lets it report a name it could not resolve.
    //
    // The default action is a check. `--write` is the only path that touches
    // the document, because a generator that rewrites a hand-maintained file on
    // a plain run is a generator that will one day destroy a human's edit
    // without asking.
    //
    // `has_side_effects` because a cached run executes nothing, and a check
    // that can report success without having compared anything is the failure
    // this step exists to prevent.
    const tables_step = b.step(
        "docs-tables",
        "Check the generated symbol tables in docs/36 against the source",
    );

    const tables_module = b.createModule(.{
        .root_source_file = b.path("tools/docs_tables/main.zig"),
        .target = target,
        .optimize = .Debug,
    });

    // The tool's own tests run first and gate the check. The scanner's tests
    // are what prove it reads a declaration-shaped comment as a comment, so a
    // sweep that ran without them would be reporting on code nothing checked.
    const tables_tests = b.addTest(.{
        .name = "docs-tables-test",
        .root_module = tables_module,
    });
    const tables_test_run = b.addRunArtifact(tables_tests);
    tables_test_run.has_side_effects = true;
    tables_step.dependOn(&tables_test_run.step);

    const tables = b.addExecutable(.{
        .name = "docs-tables",
        .root_module = tables_module,
    });
    const tables_run = b.addRunArtifact(tables);
    tables_run.has_side_effects = true;
    if (b.args) |args| tables_run.addArgs(args);
    tables_run.step.dependOn(&tables_test_run.step);
    tables_step.dependOn(&tables_run.step);
}

/// Native runs retain the address-space ceiling that bounds a runaway test.
/// argv is `[bash, -c, script, bin]`, so the binary is `$0` to the script and
/// the ceiling applies before it ever starts.
fn addCeilingedRun(
    b: *std.Build,
    name: []const u8,
    compile: *std.Build.Step.Compile,
) *std.Build.Step.Run {
    const run = b.addSystemCommand(&.{ "bash", "-c" });
    run.addArg(b.fmt("ulimit -v {d}; exec \"$0\"", .{test_address_space_kb}));
    run.addFileArg(compile.getEmittedBin());
    run.setName(name);
    return run;
}
