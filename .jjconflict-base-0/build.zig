//! Build wiring for zaccesskit.
//!
//! **What this build publishes.** `dep.module("zaccesskit")` imports the Zig
//! surface. `dep.artifact("zaccesskit")` links the C library and supplies
//! `zaccesskit.h`. `-Dlinkage=static` is the default. `-Dlinkage=dynamic` selects
//! the same C surface as a shared library.
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
    const runs_on_host = target.result.os.tag == b.graph.host.result.os.tag and
        target.result.cpu.arch == b.graph.host.result.cpu.arch;
    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "C library linkage: static (default) or dynamic",
    ) orelse .static;
    const macobjc = createMacObjcBindings(b, target, optimize);

    // zio is the async runtime the port is built around. It is a module-level
    // import rather than a whole-package import: only the library needs a
    // runtime, and the test harness wants to construct one explicitly.
    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    });
    const zio_module = zio.module("zio");

    // zigwin32 is the Windows type boundary: UI Automation, Win32, COM and
    // `oleaut32`. It is a module-level import like `zio`, and it is only
    // reached by the four files under `src/adapters/windows/` that name a
    // COM interface, a vtable or a status code. The declaration is
    // unconditional, so a `src/` file may reach for the boundary on any
    // host, and every shard below sees the same module.
    //
    // No options. `zigwin32/build.zig` is seven lines that call
    // `b.addModule` with a root source file and nothing else, so it never
    // calls `standardTargetOptions` and rejects `-Dtarget`, `-Dcpu` and
    // `-Doptimize`. Passing them is a build failure, and the module it hands
    // back is target-agnostic: the target and the mode come from the module
    // that imports it, which is what every `win32` import below is.
    const win32 = b.dependency("win32", .{});

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
        .optimize = optimize,
        .imports = &.{
            .{ .name = "zio", .module = zio_module },
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "win32", .module = win32.module("win32") },
        },
    });
    linkNativeSdk(mod, target, macobjc);

    const library = b.addLibrary(.{
        .name = "zaccesskit",
        .linkage = linkage,
        // LLVM passes C geometry aggregates correctly in Debug. The x86 backend does not.
        .use_llvm = true,
        .root_module = b.createModule(.{
            .root_source_file = b.path("capi_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(library.root_module, target, macobjc);
    library.installHeader(b.path("include/zaccesskit.h"), "zaccesskit.h");
    b.installArtifact(library);

    // The gate modes stay fixed even when a consumer selects another mode.
    const debug_module = if (optimize == .Debug) mod else b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "zio", .module = zio_module },
            .{ .name = "build_options", .module = options.createModule() },
            .{ .name = "win32", .module = win32.module("win32") },
        },
    });
    if (debug_module != mod) linkNativeSdk(debug_module, target, macobjc);
    const test_step = b.step("test", "Run the library tests in Debug and ReleaseSafe");

    const test_c_step = b.step("test-c", "Link and run the offline C11 consumer");
    const supports_c_run = target.query.isNative() or target.result.os.tag == .linux;
    const c_consumer_run: ?*std.Build.Step.Run = if (supports_c_run) run: {
        const c_consumer = b.addExecutable(.{
            .name = "c-consumer",
            .root_module = b.createModule(.{
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        c_consumer.root_module.addCSourceFiles(.{
            .files = &.{"test/c_consumer/consumer.c"},
            .flags = &.{ "-std=c11", "-Wall", "-Wextra", "-Werror" },
        });
        c_consumer.root_module.linkLibrary(library);
        const c_run = b.addRunArtifact(c_consumer);
        c_run.has_side_effects = true;
        test_c_step.dependOn(&c_run.step);
        if (target.query.isNative()) test_step.dependOn(&c_run.step);
        break :run c_run;
    } else unavailable: {
        const unsupported = b.addFail("test-c requires a native target or a Linux foreign target");
        test_c_step.dependOn(&unsupported.step);
        break :unavailable null;
    };

    // Compile separately so external profilers can run the emitted binary.
    // Use -Doptimize=ReleaseSafe for a benchmark with safety checks enabled.
    const benchmark = b.addExecutable(.{
        .name = "consumer-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("consumer_bench_root.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "zaccesskit", .module = mod },
            },
        }),
    });
    const bench_build_step = b.step("bench-build", "Compile the consumer benchmark without running it");
    bench_build_step.dependOn(&benchmark.step);
    const bench_step = b.step("bench", "Run the consumer benchmark without internal timing");
    const benchmark_run = b.addRunArtifact(benchmark);
    benchmark_run.has_side_effects = true;
    if (b.args) |args| benchmark_run.addArgs(args);
    bench_step.dependOn(&benchmark_run.step);

    const probe_build_step = b.step("native-atspi-probe", "Build and install the Linux AT-SPI probe");
    const probe_run_step = b.step("native-atspi-probe-run", "Run the Linux AT-SPI probe CLI");
    if (target.result.os.tag == .linux) {
        const probe = b.addExecutable(.{
            .name = "atspi-native-probe",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/atspi_native_probe.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zaccesskit", .module = mod },
                },
            }),
        });
        const probe_install = b.addInstallArtifact(probe, .{});
        probe_build_step.dependOn(&probe_install.step);
        const probe_run = b.addRunArtifact(probe);
        probe_run.has_side_effects = true;
        if (b.args) |args| probe_run.addArgs(args);
        probe_run_step.dependOn(&probe_run.step);
    } else {
        const unavailable = b.addFail("native-atspi-probe requires a Linux target");
        probe_build_step.dependOn(&unavailable.step);
        probe_run_step.dependOn(&unavailable.step);
    }

    const windows_client_build = b.step(
        "windows-native-client",
        "Build and install the real Windows UI Automation client",
    );
    const windows_client_run = b.step(
        "windows-native-client-run",
        "Run the real UI Automation client on a native Windows host",
    );
    if (target.result.os.tag == .windows) {
        const client = b.addExecutable(.{
            .name = "zaccesskit-windows-native-client",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/windows_native_client.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zaccesskit", .module = mod },
                    .{ .name = "win32", .module = win32.module("win32") },
                },
            }),
        });
        client.root_module.linkSystemLibrary("ole32", .{});
        const install = b.addInstallArtifact(client, .{});
        windows_client_build.dependOn(&install.step);
        if (runs_on_host) {
            const run = b.addRunArtifact(client);
            run.has_side_effects = true;
            if (b.args) |args| run.addArgs(args);
            windows_client_run.dependOn(&run.step);
        } else {
            const unavailable = b.addFail("windows-native-client-run requires a native Windows host");
            windows_client_run.dependOn(&unavailable.step);
        }
    } else {
        const unavailable = b.addFail("windows-native-client requires a Windows target");
        windows_client_build.dependOn(&unavailable.step);
        windows_client_run.dependOn(&unavailable.step);
    }

    const macos_client_build = b.step(
        "macos-native-client",
        "Build and install the real macOS accessibility selector client",
    );
    const macos_client_run = b.step(
        "macos-native-client-run",
        "Run the real accessibility selector client on a native macOS host",
    );
    if (target.result.os.tag == .macos) {
        const client = b.addExecutable(.{
            .name = "zaccesskit-macos-native-client",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/macos_native_client.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "zaccesskit", .module = mod },
                    .{ .name = "macobjc", .module = macobjc.? },
                },
            }),
        });
        const install = b.addInstallArtifact(client, .{});
        macos_client_build.dependOn(&install.step);
        if (runs_on_host) {
            const run = b.addRunArtifact(client);
            run.has_side_effects = true;
            if (b.args) |args| run.addArgs(args);
            macos_client_run.dependOn(&run.step);
        } else {
            const unavailable = b.addFail("macos-native-client-run requires a native macOS host");
            macos_client_run.dependOn(&unavailable.step);
        }
    } else {
        const unavailable = b.addFail("macos-native-client requires a macOS target");
        macos_client_build.dependOn(&unavailable.step);
        macos_client_run.dependOn(&unavailable.step);
    }

    const debug_tests = b.addTest(.{
        .name = "test-Debug",
        .root_module = debug_module,
    });
    linkTestApartment(debug_tests.root_module, target);
    test_step.dependOn(&addCeilingedRun(b, "test-Debug", debug_tests).step);

    const release_tests = b.addTest(.{
        .name = "test-ReleaseSafe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/root.zig"),
            .target = target,
            .optimize = .ReleaseSafe,
            .imports = &.{
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(release_tests.root_module, target, macobjc);
    linkTestApartment(release_tests.root_module, target);
    test_step.dependOn(&addCeilingedRun(b, "test-ReleaseSafe", release_tests).step);

    const contract_step = b.step("native-contract", "Run the published native consumer contract tests");
    for ([_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe }) |mode| {
        const name = b.fmt("native-contract-{s}", .{@tagName(mode)});
        const contract_tests = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("test/native_contract_cases.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{
                    .{
                        .name = "zaccesskit",
                        .module = if (mode == .Debug) debug_module else release_tests.root_module,
                    },
                },
            }),
        });
        const contract_run = addCeilingedRun(b, name, contract_tests);
        contract_step.dependOn(&contract_run.step);
        test_step.dependOn(&contract_run.step);
    }

    const bench_test_step = b.step("bench-test", "Test the benchmark in Debug and ReleaseSafe");
    const benchmark_test_modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };
    for (benchmark_test_modes) |mode| {
        const name = b.fmt("bench-test-{s}", .{@tagName(mode)});
        const benchmark_tests = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("consumer_bench_root.zig"),
                .target = target,
                .optimize = mode,
                .imports = &.{
                    .{
                        .name = "zaccesskit",
                        .module = if (mode == .Debug) debug_module else release_tests.root_module,
                    },
                },
            }),
        });
        const benchmark_test_run = addCeilingedRun(b, name, benchmark_tests);
        bench_test_step.dependOn(&benchmark_test_run.step);
        test_step.dependOn(&benchmark_test_run.step);
    }

    const integration_step = b.step(
        "integration",
        "Run the offline application roundtrip in Debug and ReleaseSafe",
    );
    const integration_modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };
    for (integration_modes) |mode| {
        const name = b.fmt("integration-{s}", .{@tagName(mode)});
        const integration_tests = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("integration_root.zig"),
                .target = target,
                .optimize = mode,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zio", .module = zio_module },
                    .{ .name = "build_options", .module = options.createModule() },
                    .{ .name = "win32", .module = win32.module("win32") },
                },
            }),
        });
        linkNativeSdk(integration_tests.root_module, target, macobjc);
        linkTestApartment(integration_tests.root_module, target);
        const integration_run = addCeilingedRun(b, name, integration_tests);
        integration_step.dependOn(&integration_run.step);
        test_step.dependOn(&integration_run.step);
    }

    const reference_step = b.step(
        "reference",
        "Run the pinned reference fixtures in Debug and ReleaseSafe",
    );
    const reference_modes = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };
    for (reference_modes) |mode| {
        const name = b.fmt("reference-{s}", .{@tagName(mode)});
        const reference_tests = b.addTest(.{
            .name = name,
            .root_module = b.createModule(.{
                .root_source_file = b.path("reference_root.zig"),
                .target = target,
                .optimize = mode,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zio", .module = zio_module },
                    .{ .name = "build_options", .module = options.createModule() },
                    .{ .name = "win32", .module = win32.module("win32") },
                },
            }),
        });
        linkNativeSdk(reference_tests.root_module, target, macobjc);
        linkTestApartment(reference_tests.root_module, target);
        const reference_run = addCeilingedRun(b, name, reference_tests);
        reference_step.dependOn(&reference_run.step);
        test_step.dependOn(&reference_run.step);
    }

    const integration_program = b.addExecutable(.{
        .name = "integration-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("integration_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(integration_program.root_module, target, macobjc);
    const integration_program_run = b.addRunArtifact(integration_program);
    integration_program_run.has_side_effects = true;
    const integration_run_step = b.step("integration-run", "Run the offline application scenario");
    integration_run_step.dependOn(&integration_program_run.step);

    const reference_program = b.addExecutable(.{
        .name = "reference-run",
        .root_module = b.createModule(.{
            .root_source_file = b.path("reference_root.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(reference_program.root_module, target, macobjc);
    const reference_program_run = b.addRunArtifact(reference_program);
    reference_program_run.has_side_effects = true;
    const reference_run_step = b.step("reference-run", "Run the pinned reference fixture checks");
    reference_run_step.dependOn(&reference_program_run.step);

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
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(cross_tests.root_module, target, macobjc);
    linkTestApartment(cross_tests.root_module, target);
    const cross_run = b.addRunArtifact(cross_tests);
    // A cached run executes no tests and cannot prove execution coverage.
    cross_run.has_side_effects = true;
    cross_test_step.dependOn(&cross_run.step);
    if (target.result.os.tag == .linux) {
        if (c_consumer_run) |c_run| cross_test_step.dependOn(&c_run.step);
    }

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
    // The transport and the public Runtime alias share the exact pinned zio
    // module instance with every fuzz shard; dependency types must not fork.
    //
    // The count this shard prints is larger than the harness: `zig test`
    // collects the `test` blocks of every file it analyses, and this module
    // analyses `src/schema/` and `src/consumer/`, so it re-runs the library
    // tests it pulls in.
    const fuzz_step = b.step("fuzz", "Replay committed schema and D-Bus decoder corpora");

    const fuzz_debug = b.addTest(.{
        .name = "fuzz-Debug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("fuzz_root.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(fuzz_debug.root_module, target, macobjc);
    linkTestApartment(fuzz_debug.root_module, target);
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
                .{ .name = "zio", .module = zio_module },
                .{ .name = "build_options", .module = options.createModule() },
                .{ .name = "win32", .module = win32.module("win32") },
            },
        }),
    });
    linkNativeSdk(fuzz_release.root_module, target, macobjc);
    linkTestApartment(fuzz_release.root_module, target);
    const fuzz_release_run = addCeilingedRun(b, "fuzz-ReleaseSafe", fuzz_release);
    test_step.dependOn(&fuzz_release_run.step);
    fuzz_step.dependOn(&fuzz_release_run.step);

    // The C ABI parity sweep. The tool compares `include/zaccesskit.h` against
    // what `src/capi/*.zig` exports, per target, with the header's preprocessor
    // guards and the Zig `comptime` guards both evaluated. It imports the
    // published module so `src/capi/platform.zig` owns the guard logic rather
    // than a second copy of it living in the tool.
    //
    // Debug matches the fixed Debug gate, independent of consumer options.
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
            .{ .name = "zaccesskit", .module = debug_module },
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

/// SDK declarations are generated only for the real macOS target.
fn createMacObjcBindings(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Module {
    if (target.result.os.tag != .macos) return null;
    const sdk = b.option(
        []const u8,
        "macos-sdk",
        "Actual macOS SDK path for Objective-C declarations and native linking",
    ) orelse b.sysroot orelse
        std.debug.panic(
            "macOS native adapters require -Dmacos-sdk=<SDK> or --sysroot <SDK>",
            .{},
        );
    b.sysroot = sdk;
    const translated = b.addTranslateC(.{
        .root_source_file = b.path("src/adapters/macos/runtime.h"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    translated.defineCMacro("OBJC_OLD_DISPATCH_PROTOTYPES", "0");
    translated.addSystemIncludePath(.{
        .cwd_relative = b.pathJoin(&.{ sdk, "usr/include" }),
    });
    translated.addSystemFrameworkPath(.{
        .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }),
    });
    return translated.createModule();
}

/// Link only the SDK used by the selected target's real native implementation.
fn linkNativeSdk(
    module: *std.Build.Module,
    target: std.Build.ResolvedTarget,
    macobjc: ?*std.Build.Module,
) void {
    if (macobjc) |binding| module.addImport("macobjc", binding);
    module.linkSystemLibrary("c", .{});
    switch (target.result.os.tag) {
        .windows => {
            module.linkSystemLibrary("uiautomationcore", .{});
            module.linkSystemLibrary("user32", .{});
            module.linkSystemLibrary("oleaut32", .{});
            module.linkSystemLibrary("kernel32", .{});
        },
        .macos => {
            const b = module.owner;
            const sdk = b.sysroot.?;
            module.addSystemFrameworkPath(.{
                .cwd_relative = b.pathJoin(&.{ sdk, "System/Library/Frameworks" }),
            });
            module.addCSourceFile(.{
                .file = b.path("src/adapters/macos/foundation.m"),
                .flags = &.{ "-fno-objc-arc", "-fvisibility=hidden" },
            });
            module.linkFramework("AppKit", .{});
            module.linkFramework("Foundation", .{});
            module.linkSystemLibrary("objc", .{});
        },
        else => {},
    }
}

/// Native reserved-value regressions initialize their own COM apartment.
fn linkTestApartment(module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    if (target.result.os.tag == .windows) module.linkSystemLibrary("ole32", .{});
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
