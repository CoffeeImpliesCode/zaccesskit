# 22 — The Zig 0.16.0 build surface a pure-Zig AccessKit port needs

**Consumed by `docs/30-port-design.md`**, which binds the module layout, and by
`docs/40-plan.md`, which orders the milestones. Every build call named here
appears in the section 8 skeleton.

## How to read this document

Every claim about the build system carries a `path:line` into the Zig 0.16.0
standard library tree at

```
/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/
```

Paths below are written relative to that `lib/` directory, so `std/Build.zig:1414`
means `<lib>/std/Build.zig` line 1414.

Claims that came from running a compiler are marked `[OBSERVED]` and give the
command. Claims that are inferences are marked `[INFERENCE]`. Everything else
was read from the source.

A few citations carry the `lib/` prefix as well (`lib/std/zig.zig:156`,
`lib/std/Build/Step.zig:305`). Those name the same files, relative to the cache
directory rather than to its `lib/` child. Either form resolves; this document
mixes them because the source files themselves mix them.

The compiler used for the observations is the same tree: `zig` on this host is an
anyzig shim, and `zig 0.16.0 version` prints `0.16.0` and points at
`N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ`, the directory above
`[OBSERVED: zig 0.16.0 version]`.

Every call in the section 8 skeleton was compiled and run before it was written
down. The skeleton was extracted verbatim from this document into a temporary
scratch package, which has since been deleted; the commands and their outputs
are recorded below.
`[OBSERVED: zig 0.16.0 build --list-steps]`:

```
  install (default)            Copy build artifacts to prefix path
  uninstall                    Remove build artifacts from prefix path
  test                         Run the library tests in Debug and ReleaseSafe, sharded
  c-test                       Run the C ABI conformance suite
  binding-check                Check the C header against the Zig exports
  fuzz                         Run the decoder fuzz targets
  cross-test                   Run the Debug shards in foreign targets through the build system's runner
```

and every step that does not hit the fuzz blocker is green
`[OBSERVED: zig 0.16.0 build <step> --summary all]`:

```
install (static)  Build Summary: 5/5 steps succeeded
install (dynamic) Build Summary: 5/5 steps succeeded
test              Build Summary: 11/11 steps succeeded
c-test            Build Summary: 7/7 steps succeeded
binding-check     Build Summary: 6/6 steps succeeded; 1/1 tests passed
cross-test        Build Summary: 7/7 steps succeeded; 2/2 tests passed
```

The dynamic install puts `zig-out/include/accesskit.h`,
`zig-out/lib/libzaccesskit.so`, `libzaccesskit.so.0` and
`libzaccesskit.so.0.0.0` in the prefix, and `readelf -d` on the last of those
reports `SONAME [libzaccesskit.so.0]`. The `fuzz` step fails, on the blocker
in section 9.7 and nothing else.

## 0. The short version

| Question | Answer on Zig 0.16.0 |
|---|---|
| Target expression | `b.standardTargetOptions(.{})` returns `Build.ResolvedTarget`, a query plus a resolved `std.Target`. |
| Foreign ABI selection | The ABI is the third field of the triple `-Dtarget=x86_64-linux-musl`. There is no separate ABI flag. |
| Module publication | `b.addModule(name, …)` registers; `b.createModule(…)` does not. |
| C sources | `Module.addCSourceFiles` / `Module.addCSourceFile`. |
| C headers to Zig | `b.addTranslateC(…).createModule()`, then `Module.addImport`. `@cImport` also works inside a source file. |
| System libraries | `Module.linkSystemLibrary`. There is **no** `b.linkLibC` or `b.linkLibCpp` function in 0.16.0. |
| Build-time values in Zig source | `b.addOptions()` then `Module.addOptions("build_options", options)`. |
| `std_options` | Not produced by `addOptions`. It is a `pub const` in the **root source file** of the compilation. See section 4.4. |
| Sharded tests | One `b.addTest` per shard and mode; a `bash -c` launcher applies `ulimit -v`. |
| Cross matrix | `cross-test` runs `zig build <step> -Dtarget=<triple>` and greps the build summary for `compile (test\|exe)` and `run exe` lines. |
| Shared library soname | `LibraryOptions.version`; Zig derives `libNAME.so.MAJOR` and writes `DT_SONAME`. |
| Generated C header | **Broken.** `-femit-h` returns an error. Ship a checked-in header. |
| Fuzzing | **Blocked.** `-ffuzz` fails to compile in this 0.16.0 tree. See section 9.7. |

---

## 1. Target and ABI model

### 1.1 The two types

`std.Build.ResolvedTarget` is a pair (`std/Build.zig:2697`):

```zig
pub const ResolvedTarget = struct {
    query: Target.Query,
    result: Target,
};
```

`std.Target.Query` is the same data as `std.Target` plus the idea of "native".
Every field is optional and `null` means native (`std/Target/Query.zig:16-54`):

| Field | Line | `null` means |
|---|---|---|
| `cpu_arch: ?Target.Cpu.Arch` | `std/Target/Query.zig:16` | native |
| `cpu_model: CpuModel` | `:18` | `.determined_by_arch_os` |
| `cpu_features_add` / `cpu_features_sub` | `:21`, `:24` | no change |
| `os_tag: ?Target.Os.Tag` | `:27` | native |
| `os_version_min` / `os_version_max` | `:31`, `:35` | default range |
| `glibc_version: ?SemanticVersion` | `:39` | default, or native |
| `android_api_level: ?u32` | `:43` | default, or native |
| `abi: ?Target.Abi` | `:46` | native C ABI, or the default for the OS |
| `dynamic_linker: ?Target.DynamicLinker` | `:51` | the standard path for the OS |
| `ofmt: ?Target.ObjectFormat` | `:54` | default for cpu and OS |

The query is kept next to the target on purpose (`std/Build.zig:2693-2696`): the
Zig toolchain needs to know which parts of the target are native, because a
field that stays native is not passed on the command line at all.

`std.Target.Query.isNative` is `std/Target/Query.zig:396`. It is the test the
build system uses to decide whether to emit `-target`.

### 1.2 The standard options

```zig
const target = b.standardTargetOptions(.{});
```

`std/Build.zig:1414`, taking `StandardTargetOptionsArgs` (`std/Build.zig:1407`):

```zig
pub const StandardTargetOptionsArgs = struct {
    whitelist: ?[]const Target.Query = null,
    default_target: Target.Query = .{},
};
```

The four options it registers are declared in
`standardTargetOptionsQueryOnly` (`std/Build.zig:1473-1493`). Confirmed in the
build script's own help text `[OBSERVED: zig build --help]`:

```
  -Dtarget=[string]            The CPU architecture, OS, and ABI to build for
  -Dcpu=[string]               Target CPU features to add or subtract
  -Dofmt=[string]              Target object format
  -Ddynamic-linker=[string]    Path to interpreter on the target system
```

There is no `-Dabi`. **A foreign ABI is selected by the third field of the
triple.** `-Dtarget=x86_64-linux-musl`, `-Dtarget=x86_64-windows-gnu` and
`-Dtarget=aarch64-macos` differ only in that field. The parse is
`std.Target.Query.parse` (`std/Target/Query.zig:212`); `Build.parseTargetQuery`
(`std/Build.zig:1423`) is the same parse with a readable error instead of a
silent one.

`whitelist` is the whitelist. A target outside it does not build;
`standardTargetOptionsQueryOnly` logs each allowed triple and calls
`b.markInvalidUserInput()` (`std/Build.zig:1512-1531`). The gate fails before
any step runs.

`resolveTargetQuery` (`std/Build.zig:2704`) has a fast path: a native query
returns `b.graph.host` and does not re-query the host. `b.graph.host` is a
`ResolvedTarget` and is computed before `build()` is called
(`std/Build.zig:125-126`).

### 1.3 How the target reaches the compiler

`Module.appendZigProcessFlags` is the one place a module becomes command-line
arguments (`std/Build/Module.zig:538`). For the target it does
(`std/Build/Module.zig:592-608`):

```zig
if (m.resolved_target) |*target| {
    if (!target.query.isNative()) {
        try zig_args.appendSlice(&.{
            "-target", try target.query.zigTriple(b.allocator),
            "-mcpu",   try target.query.serializeCpuAlloc(b.allocator),
        });
        // … and --dynamic-linker or --no-dynamic-linker
    }
}
```

Three consequences the port depends on:

1. A native build passes **no** `-target`. `-Dtarget=native` is therefore not
   the same command line as an absent `-Dtarget` in the cache key, but it is the
   same target.
2. The query is sent, not the resolved target. A CPU model the query marked
   native is left to the host.
3. `--no-dynamic-linker` is sent when `query.dynamic_linker` is a non-`null`
   empty string. This is how a target that must not start a loader is built.

`Query.zig:421 zigTriple` and `Query.zig:488 serializeCpu` are the two writers.
`Query.zig:400 canDetectLibC` says whether the target's libc can be found at
all.

### 1.4 libc and libc++

`Module.CreateOptions` carries both as plain optional bools
(`std/Build/Module.zig:231-238`):

```zig
/// `true` requires a compilation that includes this Module to link libc.
/// `false` causes a build failure if a compilation that includes this Module would link libc.
/// `null` neither requires nor prevents libc from being linked.
link_libc: ?bool = null,
link_libcpp: ?bool = null,
```

There is **no** `std.Build.linkLibC` and **no** `std.Build.linkLibCpp`. A search
of the whole `lib/std` tree returns no definition `[OBSERVED: grep -rn "fn linkLibC|fn linkLibCpp" lib/std → no matches]`.
The three ways to state it are:

| Spelling | Where | Notes |
|---|---|---|
| `.link_libc = true` in `CreateOptions` | `std/Build/Module.zig:234` | At creation. This is what the house uses. |
| `module.link_libc = true` after creation | `std/Build/Module.zig:34` | The field is public. `zautomerge/build.zig:141` uses it. |
| `linkSystemLibrary("c", .{})` | `std/Build/Module.zig:371-374` | Special-cased into `m.link_libc = true`. |

The same special case exists for libc++ at `std/Build/Module.zig:375-378`,
using `std.zig.target.isLibCxxLibName` (`lib/std/zig/target.zig:481`). The libc
name test is `lib/std/zig/target.zig:291`.

### 1.5 Optimisation is a separate option

`b.standardOptimizeOption(.{})` (`std/Build.zig:1378`) is independent of the
target. `StandardOptimizeOptionOptions` has one field,
`preferred_optimize_mode` (`std/Build.zig:1374-1376`). With no preference and
`--release` given, the build prints and exits (`std/Build.zig:1395-1400`):

```
the project does not declare a preferred optimization mode. choose: --release=fast, --release=safe, or --release=small
```

**The port does not set it.** Every other house project
(`zomp`, `zautomerge`, `ozai`, `mpfr`) calls `b.standardOptimizeOption(.{})`,
so the house gate and every developer invocation can say `-Doptimize`. Setting
`preferred_optimize_mode` removes `-Doptimize` from `--help` and replaces it
with `-Drelease`; `[OBSERVED: zig build --help]` on a probe with the field set
shows `-Drelease=[bool] optimize for end users` and no `-Doptimize` at all.
Section 9.11 has both spellings and the test.

### 1.6 What a foreign ABI costs

`zig build -Dtarget=x86_64-windows` on a Linux host compiles and then fails at
run time, because nothing on the host can execute the guest
(`std/Build/Step/Run.zig:1355-1357`):

```
error: unable to spawn foreign binary '.../probe-cross.exe' (x86_64-windows.win10...win11_dt-gnu) on host system (x86_64-linux.6.12...6.12-gnu.2.39)
         consider using -fwine or enabling skip_foreign_checks in the Run step
```

`[OBSERVED: zig build cross-test -Dtarget=x86_64-windows]` produced exactly that
line, and the build summary showed the compile step green and the run step red:

```
Build Summary: 3/5 steps succeeded (1 failed)
cross-test transitive failure
+- run test probe-cross failure
   +- compile test probe-cross Debug x86_64-windows success 22s MaxRSS:434M
```

The same message is produced from `std/Build/Step/Run.zig:2768-2771`. Two flags
change the outcome, and both are set on the field, not by a build option:

| Field | Line | Default |
|---|---|---|
| `skip_foreign_checks: bool` | `std/Build/Step/Run.zig:71` | `false` (`:225`) |
| `failing_to_execute_foreign_is_an_error: bool` | `std/Build/Step/Run.zig:78` | `true` (`:226`) |

`allow_skip` is read from `skip_foreign_checks` only for `.check` and
`.zig_test` stdio (`std/Build/Step/Run.zig:1233-1236`). The port sets neither
field. It wants a missing runner to be a failure, because a silent skip turns
execution coverage into compile coverage.

---

## 2. Module and dependency wiring

### 2.1 `addModule` against `createModule`

```zig
pub fn addModule(b: *Build, name: []const u8, options: Module.CreateOptions) *Module {
    const module = Module.create(b, options);
    b.modules.put(b.graph.arena, b.dupe(name), module) catch @panic("OOM");
    return module;
}
```

`std/Build.zig:909`. `createModule` (`std/Build.zig:918`) is the same call
without the map insert. `b.modules` is `std.array_hash_map.String(*Module)`
(`std/Build.zig:89`), and a consumer looks a name up with
`Dependency.module` (`std/Build.zig:1961`).

| Call | Visible to `dep.module("name")` | Use for |
|---|---|---|
| `b.addModule` | yes | the published surface |
| `b.createModule` | no | a test root, an executable root, a C ABI root |

The house states this in prose. `zomp/build.zig:5-8`:

> Every module below comes from `b.createModule`, which builds a module this
> file owns, so `dep.module("zomp")` does not exist.

And `mpfr/build.zig:690-692` records the other failure mode: `b.addModule` is
keyed by name, so two registrations of one name mean the last one wins for
every dependent.

### 2.2 `CreateOptions`

`std/Build/Module.zig:216-259`. Every field that is left unset is inherited
from the parent module when the module is inserted into an import table
(`std/Build/Module.zig:214-215`, `std/Build/Module.zig:280-306`).

The fields the port uses:

| Field | Line | Why |
|---|---|---|
| `root_source_file: ?LazyPath` | `:221` | `null` means the module has only link objects. A compile step will refuse it (`std/Build/Step/Compile.zig:386-387`). |
| `imports: []const Import` | `:226` | `Import` is `{ name, module }` (`:261`). |
| `target: ?Build.ResolvedTarget` | `:228` | Required by `linkSystemLibrary`. |
| `optimize: ?OptimizeMode` | `:229` | Fixed at creation; a second mode needs a second module. |
| `link_libc` / `link_libcpp` | `:234`, `:238` | The port links libc for every C-facing root. |
| `fuzz: ?bool` | `:248` | Becomes `-ffuzz`. See section 9.7. |
| `pic: ?bool` | `:252` | `null` means "the driver decides". A shared library states `true`. `mpfr/build.zig:909-912` explains why `false` is the wrong static answer. |
| `sanitize_c: ?std.zig.SanitizeC` | `:246` | `.off`, `.trap`, `.full` (`lib/std/zig.zig:243`). |
| `single_threaded: ?bool` | `:239` | The port is multi-threaded, so this stays `null`. |

The full flag list each field becomes is in
`std/Build/Module.zig:545-556`. Every `?bool` field becomes an explicit
`-f...` or `-fno-...`; `null` emits nothing.

### 2.3 Naming an import

```zig
pub fn addImport(m: *Module, name: []const u8, module: *Module) void
```

`std/Build/Module.zig:326`. The comment on the `import_table` field
(`std/Build/Module.zig:4-6`) says to use `addImport` rather than writing the
table, because `addImport` is what records the dependency edge.

The graph is flattened at make time by `Module.getGraph`
(`std/Build/Module.zig:678`), which returns the root first and then every
reachable module, in breadth-first order. The result is cached on the module
(`std/Build/Module.zig:43`).

`Module.addAnonymousImport(name, options)` (`std/Build/Module.zig:332`) creates a
module and adds it in one call. **It needs a `root_source_file`.** Without one
the module has no root, no `-M` argument is emitted, and the compilation fails:

```
error: error: module 'probe' depends on non-existent module 'probe_c'
```

`[OBSERVED: zig build, after calling mod.addAnonymousImport("probe_c", .{ .target = …, .optimize = … })]`
with no `root_source_file`. The `--dep probe_c` was on the command line and no
`-Mprobe_c=` was. The correct route for a C header is `b.addTranslateC(…)`, not
`addAnonymousImport`.

### 2.4 Options as an import

```zig
pub fn addOptions(m: *Module, module_name: []const u8, options: *Step.Options) void
```

`std/Build/Module.zig:340`. It calls `options.createModule()` and then
`addImport`. `Step.Options.createModule` is `lib/std/Build/Step/Options.zig:428`
and produces a module whose only file is the generated Zig source. Section 4
covers the rest.

### 2.5 Dependencies

```zig
pub fn dependency(b: *Build, name: []const u8, args: anytype) *Dependency
```

`std/Build.zig:2055`. The returned `Dependency` (`std/Build.zig:1940`) has:

| Method | Line | Returns |
|---|---|---|
| `artifact(name)` | `:1943` | `*Step.Compile` |
| `module(name)` | `:1961` | `*Module` |
| `namedWriteFiles(name)` | `:1967` | `*Step.WriteFile` |
| `namedLazyPath(name)` | `:1973` | `LazyPath` |
| `path(sub_path)` | `:1979` | `LazyPath` into the dependency's tree |

Every one of them panics with `unable to find module '{s}'` or
`unable to find artifact '{s}'` when the name is absent. `artifact` prints the
available names first (`:1953-1956`).

`args` is a struct of `-D` options passed to the dependency's own `build()`
through `std.Build.option`. `lazyDependency` (`std/Build.zig:2035`) is the lazy
variant and returns `null` while the dependency is unfetched;
`dependencyFromBuildZig` (`std/Build.zig:2108`) takes an `@import`ed build
struct instead of a name; `b.lazyImport` (`std/Build.zig:2078`) is the
build-script-side spelling.

Mixing the two panics with a clear message (`std/Build.zig:2064`):

```
dependency '{s}{s}' is marked as lazy in build.zig.zon which means it must use the lazyDependency function instead
```

### 2.6 The shape a port needs: a library that re-exports zio

`zio` is the one dependency. It is taken as a module, not as a whole package:

```zig
const zio = b.dependency("zio", .{
    .target = target,
    .optimize = optimize,
}).module("zio");
```

That is `zomp/build.zig:118-121` verbatim. The published module then re-exports
it so a consumer writes `@import("zio")` without declaring the dependency:

```zig
const mod = b.addModule("zaccesskit", .{
    .root_source_file = b.path("src/root.zig"),
    .target = target,
    .optimize = optimize,
    .link_libc = true,
    .imports = &.{
        .{ .name = "zio", .module = zio },
    },
});
mod.addOptions("build_options", options);
mod.addIncludePath(b.path("include"));
mod.linkSystemLibrary("m", .{});
```

`build.zig.zon` then names `zio` once. A consumer of `zaccesskit` gets
`zio` through the module graph, not through its own `.dependencies`.
`zomp/build.zig:117` makes the same statement about zio's own options:

> zio carries its own `zio_options`, and a consumer cannot override them.

### 2.7 Compile steps

| Call | Line | Notes |
|---|---|---|
| `b.addExecutable(ExecutableOptions)` | `std/Build.zig:787` | `ExecutableOptions` at `:770-785`. |
| `b.addObject(ObjectOptions)` | `std/Build.zig:811` | `ObjectOptions` at `:802-809`. |
| `b.addLibrary(LibraryOptions)` | `std/Build.zig:842` | `LibraryOptions` at `:823-840`. |
| `b.addTest(TestOptions)` | `std/Build.zig:881` | `TestOptions` at `:858-871`. |

Every one takes a `root_module`, and **every one reads its target and
optimisation from that module**, not from its own options. That is why a
release-mode test needs a second module: `zaccesskit/build.zig:60-70` builds a
`createModule` copy for `ReleaseSafe`.

`Step.Compile.create` (`std/Build/Step/Compile.zig:380`) panics when the root
module has no target (`std/Build/Step/Compile.zig:386-387`):

```
the root Module of a Compile step must be created with a known 'target' field
```

A name that looks like a path also panics (`std/Build/Step/Compile.zig:382-383`):

```
invalid name: '{s}'. It looks like a file path, but it is supposed to be the library or application name.
```

---

## 3. C integration

### 3.1 The complete set, with signatures

| Call | Signature | Line |
|---|---|---|
| `linkSystemLibrary` | `pub fn linkSystemLibrary(m: *Module, name: []const u8, options: LinkSystemLibraryOptions) void` | `std/Build/Module.zig:363` |
| `addCSourceFiles` | `pub fn addCSourceFiles(m: *Module, options: AddCSourceFilesOptions) void` | `std/Build/Module.zig:408` |
| `addCSourceFile` | `pub fn addCSourceFile(m: *Module, source: CSourceFile) void` | `std/Build/Module.zig:431` |
| `addIncludePath` | `pub fn addIncludePath(m: *Module, lazy_path: LazyPath) void` | `std/Build/Module.zig:485` |
| `addSystemIncludePath` | `pub fn addSystemIncludePath(m: *Module, lazy_path: LazyPath) void` | `std/Build/Module.zig:480` |
| `addAfterIncludePath` | `pub fn addAfterIncludePath(m: *Module, lazy_path: LazyPath) void` | `std/Build/Module.zig:475` |
| `addLibraryPath` | `pub fn addLibraryPath(m: *Module, directory_path: LazyPath) void` | `std/Build/Module.zig:512` |
| `addObjectFile` | `pub fn addObjectFile(m: *Module, object: LazyPath) void` | `std/Build/Module.zig:460` |
| `linkLibrary` | `pub fn linkLibrary(m: *Module, library: *Step.Compile) void` | `std/Build/Module.zig:470` |
| `addObject` | `pub fn addObject(m: *Module, object: *Step.Compile) void` | `std/Build/Module.zig:465` |
| `addRPath` | `pub fn addRPath(m: *Module, directory_path: LazyPath) void` | `std/Build/Module.zig:517` |
| `addRPathSpecial` | `pub fn addRPathSpecial(m: *Module, bytes: []const u8) void` | `std/Build/Module.zig:522` |
| `addCMacro` | `pub fn addCMacro(m: *Module, name: []const u8, value: []const u8) void` | `std/Build/Module.zig:533` |
| `addFrameworkPath` | `pub fn addFrameworkPath(m: *Module, directory_path: LazyPath) void` | `std/Build/Module.zig:501` |
| `addConfigHeader` | `pub fn addConfigHeader(m: *Module, config_header: *Step.ConfigHeader) void` | `std/Build/Module.zig:490` |
| `addEmbedPath` | `pub fn addEmbedPath(m: *Module, lazy_path: LazyPath) void` | `std/Build/Module.zig:507` |
| `b.addTranslateC` | `pub fn addTranslateC(b: *Build, options: Step.TranslateC.Options) *Step.TranslateC` | `std/Build.zig:1115` |
| `b.addWin32ResourceFile` | `pub fn addWin32ResourceFile(m: *Module, source: RcSourceFile) void` | `std/Build/Module.zig:442` |
| `b.addAssemblyFile` | `pub fn addAssemblyFile(m: *Module, source: LazyPath) void` | `std/Build/Module.zig:455` |
| `b.addConfigHeader` | `pub fn addConfigHeader(b: *Build, options: Step.ConfigHeader.Options, values: anytype) *Step.ConfigHeader` | `std/Build.zig:1005` |

**`linkLibC` and `linkLibCpp` do not exist in 0.16.0.** Section 1.4 gives the
three substitutions. A search of the whole tree finds no definition
`[OBSERVED: grep -rn "fn linkLibC\|fn linkLibCpp" lib/std]`.

### 3.2 When the port uses each one

| Call | The port's use |
|---|---|
| `linkSystemLibrary("m", …)` | glibc and musl both need libm for the geometry maths in `docs/19-geometry-and-text.md`. |
| `linkSystemLibrary("pthread", …)` | Only if `link_libc` turns out not to bring the threads in. On this host `[OBSERVED: pkg-config --modversion]` reports glibc 2.39, where libpthread is inside libc. State it only when a target needs it. |
| `linkSystemLibrary("xcb", …)` | **Not used.** `docs/14-x11-wayland-surface.md` §1 proves the upstream adapter has no X11 path, and §4 states that reintroducing one is a cost statement, not a proposal. No line of the port links `libxcb`. |
| `linkSystemLibrary("dbus-1", …)` | **Rung 3 only.** `local://zaccesskit-deps.md` pins goose for D-Bus, so there is no `-ldbus-1`. Listed so the design wave knows the alternative's cost. |
| `addCSourceFiles` | The C shim only. Every file named there is a file the port wrote, listed one name at a time. |
| `addCSourceFile` | A generated C file, for example a unit emitted by `b.addWriteFiles()`. `mpfr/build.zig:926-931` is the model. |
| `addIncludePath` | The port's own `include/` directory, so a consumer that links the C artifact finds `accesskit.h` without reaching into this tree. |
| `addSystemIncludePath` | Nothing. A system path would hide a missing header. |
| `addAfterIncludePath` | Nothing. |
| `addLibraryPath` | Only for a `-Dprefix=` style option that points at a cross sysroot. `zautomerge/build.zig:588-589` shows the pattern. |
| `addObjectFile` | An installed shared object linked into another artifact without recording the build cache directory as an rpath. See section 7.5. |
| `linkLibrary` | The ordinary in-tree consumer route. |
| `addObject` | A `b.addObject` step, for C compiled once and linked into several artifacts. `pcre2/build.zig:1593-1595` is the model. |
| `addTranslateC` | A **consumer** of the port's header. The port itself does not need it unless the port calls a C library. |

### 3.3 The option structs

`LinkSystemLibraryOptions` (`std/Build/Module.zig:344-361`):

| Field | Default | Note |
|---|---|---|
| `needed: bool` | `false` | Keep the dynamic library even with no referenced symbol. |
| `weak: bool` | `false` | Mark every referenced symbol weak. |
| `use_pkg_config: SystemLib.UsePkgConfig` | `.yes` | `.no`, `.yes`, `.force` (`:68-77`). `.force` panics with `pkg-config failed for library {s}` (`lib/std/Build/Step/TranslateC.zig:263`). |
| `preferred_link_mode: std.builtin.LinkMode` | `.dynamic` | `pcre2/build.zig:732-736` states that naming the default changes what a default build links, so the port states it. |
| `search_strategy: SystemLib.SearchStrategy` | `.paths_first` | `paths_first`, `mode_first`, `no_fallback` (`:79`). |

`SystemLib.UsePkgConfig` defaults to `.yes`, so **`pkg-config` must be on
`PATH`** for any `linkSystemLibrary` call that does not pass `use_pkg_config`.
This host has it; a foreign row of the cross matrix does not, which is one more
reason the cross profile builds static musl.

`AddCSourceFilesOptions` (`std/Build/Module.zig:397-405`): `root`,
`files`, `flags`, `language`. `root` defaults to `b.path("")`, the build root.
`language` is `null` by default, meaning the language comes from each file's
extension (`std/Build/Module.zig:112-113`).

`CSourceFile` (`std/Build/Module.zig:116-129`) is the single-file struct:
`file`, `flags`, `language`.

`CSourceLanguage` (`std/Build/Module.zig:82-104`) is `c`, `cpp`,
`objective_c`, `objective_cpp`, `assembly`, `assembly_with_preprocessor`. The
last two matter for the Windows adapter; the first four for the macOS adapter.

### 3.4 Absolute paths are refused in two places

`addCSourceFiles` panics (`std/Build/Module.zig:412-419`):

```
file paths added with 'addCSourceFiles' must be relative, found absolute path '/tmp/absolute.c'
```

`[OBSERVED: zig build, m.addCSourceFiles(.{ .files = &.{"/tmp/absolute.c"} })]`

`b.path` panics (`std/Build.zig:1755-1760`):

```
sub_path is expected to be relative to the build root, but was this absolute path: '{s}'. It is best avoid absolute paths, but if you must, it is supported by LazyPath.cwd_relative
```

`LazyPath.cwd_relative` is the supported escape. `b.pathFromRoot`
(`std/Build.zig:1770`) accepts an absolute path and returns a `[]const u8`, but
the doc comment calls it low-level and "a code smell"
(`std/Build.zig:1767-1769`). `zautomerge/build.zig:575-589` works through the
whole choice and is the model for any `-Dprefix=` option the port adds.

### 3.5 `linkSystemLibrary` needs a known target

`std/Build/Module.zig:370` calls `m.requireKnownTarget()`, which is
`std/Build/Module.zig:661-665`. A module created with only a root source file
panics:

```
thread 16809 panic: this API requires the Module to be created with a known 'target' field
.../lib/std/Build/Module.zig:663:9: 0x1509d02 in requireKnownTarget (std.zig)
.../lib/std/Build/Module.zig:370:40: 0x150606a in linkSystemLibrary (std.zig)
```

`[OBSERVED: zig build, m = b.createModule(.{ .root_source_file = … }); m.linkSystemLibrary("m", .{})]`

`pcre2/build.zig:1334-1337` records the same rule from the other side: a module
built with only a root source file panics at configure time the moment a system
library is linked through it.

### 3.6 `translate-c`: what it carries and what it drops

Two routes reach the same translator.

**In a source file.** `@cImport` becomes a `c_import` block
(`lib/std/zig/AstGen.zig:10027`, dispatched at `:9178`). It cannot nest:
`cannot nest @cImport` (`lib/std/zig/AstGen.zig:10036`). `@cInclude`,
`@cDefine` and `@cUndef` are only valid inside it
(`lib/std/zig/AstGen.zig:9513`, `:9963`).

**In the build script.** `b.addTranslateC` creates a step
(`std/Build.zig:1115`) whose `Options` are
`{ root_source_file, target, optimize, link_libc = true }`
(`lib/std/Build/Step/TranslateC.zig:22-27`). `make` runs
`zig translate-c … --listen=-` (`lib/std/Build/Step/TranslateC.zig:171-278`),
so the translation is a cached build step, not a compile-time surprise. The
step has its own `addIncludePath` (`:116`), `defineCMacro` (`:153`),
`defineCMacroRaw` (`:159`), `linkSystemLibrary` (`:285`), `addFrameworkPath`
(`:136`), `addConfigHeader` (`:123`) and `addCheckFile` (`:143`). It then hands
over a module with `addModule(name)` (`:68`) or `createModule()` (`:80`).

The decision between the two routes is one of reach, not of capability. A
`translate_c` step can be attached to a module the port publishes; `@cImport`
cannot, because it lives inside a source file the port owns.

**What the translator produces.** A probe header was translated with
`zig 0.16.0 translate-c`. The input declared an opaque handle, a callback
typedef, a plain struct, a struct with a bitfield, a `const char *` return, a
variadic function, two object-like macros and one function-like macro.
`[OBSERVED: zig 0.16.0 translate-c probe6/h.h]` gave, verbatim:

```zig
// h.h:15:18: warning: struct demoted to opaque type - has bitfield
pub const struct_ak_node = opaque {};
pub const ak_node = struct_ak_node;
pub const ak_event_callback = ?*const fn (node: ?*ak_node, event: u32, ctx: ?*anyopaque) callconv(.c) void;
pub const ak_rect = extern struct {
    x: i32 = 0,
    y: i32 = 0,
    width: i32 = 0,
    height: i32 = 0,
};
pub extern fn ak_sum(n: c_int, ...) c_int;
pub extern fn ak_emit(cb: ak_event_callback, ctx: ?*anyopaque) void;
pub extern fn ak_make_rect(x: c_int, y: c_int, w: c_int, h: c_int) ak_rect;
pub extern fn ak_kind_name(kind: u32) [*c]const u8;
pub extern fn ak_kind_count() u32;
…
pub const AK_MAX = @as(c_int, 16);
pub const AK_NAME_LEN = @as(c_int, 64);
pub inline fn AK_KIND(a: anytype, b: anytype) @TypeOf(a + b) {
```

| C construct | Result | Usable by a Zig consumer |
|---|---|---|
| opaque handle `typedef struct X X;` | `pub const X = struct_X;` with `struct_X = opaque {}` | yes |
| callback typedef | `?*const fn (…) callconv(.c) void` | yes |
| plain struct | `extern struct` with defaulted fields | yes |
| object-like `#define` | `pub const NAME = @as(c_int, value);` | yes, as a comptime constant |
| function-like `#define` | `pub inline fn NAME(a: anytype, b: anytype) …` | yes, as a Zig inline function |
| `const char *` return | `[*c]const u8` | yes, but **the sentinel is gone**: no `[:0]` |
| struct with a bitfield | `opaque {}` plus a warning comment | **no** — every field is lost |
| variadic declaration | `pub extern fn f(n: c_int, ...) c_int;` | declaration only; see below |
| a macro it cannot render | `pub const __x = @compileError("unable to translate macro: undefined identifier …")` | **no** — hard failure |

The last row appeared in the same probe output for a libc-internal macro:

```zig
pub const __seg_gs = @compileError("unable to translate macro: undefined identifier `address_space`"); // <builtin>:33:9
```

### 3.7 The four cases that force a hand-written C shim

These are the concrete rungs-4 cases. Everything else in the C surface the port
needs is rung 2 or rung 3.

**1. A variadic export.** `translate-c` declares the function. Zig cannot
define it. `export fn probe_vsum(n: c_int, args: ...) c_int` is a parse error:

```
export fn probe_vsum(n: c_int, args: ...) c_int {
                                     ^~~
error: expected type expression, found '...'
```

`[OBSERVED: zig 0.16.0 build-obj probe5/src/varargs.zig]`

`zautomerge/build.zig:520-531` hit this exact wall and resolved it the way this
section recommends: the variadic function is C, it lives in the library and not
in the test binary, and it forwards to a private non-variadic export in Zig.
The AccessKit C ABI has no variadic declaration today
`[OBSERVED: grep -n "\.\.\." accesskit-c/include/accesskit.h → one hit, a comment
at line 227]`, so this is a forward-looking case, not a present one. The
`accesskit-c` tree is at `/tmp/scratch/accesskit-c`.

**2. A bitfield in a public struct.** The struct becomes opaque, so a consumer
cannot read or write a field. The current `accesskit.h` has none
`[OBSERVED: grep -nE ":\s*[0-9]+\s*;" accesskit-c/include/accesskit.h → no
matches]`, and `docs/31-c-abi-design.md` should keep it that way. If a bitfield
ever appears, the C shim owns the struct and the Zig side owns a plain struct
plus conversions.

**3. A macro the C consumer needs at compile time.** A function-like macro
becomes a Zig `inline fn`, which a C caller cannot use and which is not a symbol
in the shared object. A C `#define` with arguments is therefore a shim
decision, not a header decision. The current `accesskit.h` has none
`[OBSERVED: grep -cE "^#define [A-Za-z_]+\(" accesskit-c/include/accesskit.h → 0]`.

**4. A macro the translator cannot render.** `@compileError` in the generated
module is a build failure with no workaround from the build script. The port
avoids it by not including such a header. If one is unavoidable, the shim
re-declares the two or three values the port actually needs.

**A fifth case the port will hit anyway: an opaque handle across a callback.**
`translate-c` carries `opaque {}` perfectly. What it does not carry is a
**layout rule**: nothing tells a Zig consumer which fields the C side promises
to keep. That is an ABI-document rule, and `docs/31-c-abi-design.md` owns it.

### 3.8 The generated C header is broken on 0.16.0

`Step.Compile.getEmittedH` exists (`std/Build/Step/Compile.zig:869`) and asserts
`kind != .exe and kind != .@"test"` (`:870`). Calling it adds `-femit-h`
(`std/Build/Step/Compile.zig:1411`), and the compiler answers:

```
error: error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698
```

`[OBSERVED: zig build, after `const h = lib.getEmittedH();`]`

The standard library agrees. `lib/std/Build/Step/InstallArtifact.zig:123-124`
carries the issue number and a commented-out call:

```zig
// https://github.com/ziglang/zig/issues/9698
//if (install_artifact.h_dir != null) install_artifact.emitted_h = artifact.getEmittedH();
```

`InstallArtifact.Options` still has an `h_dir` field
(`lib/std/Build/Step/InstallArtifact.zig:43`), but nothing ever sets
`emitted_h`. **The port ships a checked-in header and installs it with
`installHeader`.** There is no generated-header path to fall back to.

---

## 4. Options modules

### 4.1 The calls

| Call | Line | Note |
|---|---|---|
| `b.addOptions()` | `std/Build.zig:766` | Creates a `*Step.Options`. No arguments. |
| `options.addOption(T, name, value)` | `lib/std/Build/Step/Options.zig:39` | Panics on OOM; `addOptionFallible` is the other spelling. |
| `options.addOptionPath(name, path)` | `lib/std/Build/Step/Options.zig:415` | Adds a dependency and writes the path. |
| `options.createModule()` | `lib/std/Build/Step/Options.zig:428` | A private module over the generated file. |
| `options.getOutput()` | `lib/std/Build/Step/Options.zig:436` | A `LazyPath`, for wiring a path directly. |
| `Module.addOptions(module_name, options)` | `std/Build/Module.zig:340` | `createModule` plus `addImport`. |

`b.addOptions` is documented at `std/Build.zig:761-765`:

> Create a set of key-value pairs that can be converted into a Zig source file
> and then inserted into a Zig compilation's module table for importing.

### 4.2 How a value reaches Zig source

The fragment the house uses:

```zig
const options = b.addOptions();
options.addOption([]const u8, "version", version);
options.addOption(bool, "have_atspi", have_atspi);

mod.addOptions("build_options", options);
```

`zomp/build.zig:114-115` and `:132` are the first two lines and the wiring;
`zautomerge/build.zig:49-51` is the whole fragment including `createModule`:

```zig
const build_options = b.addOptions();
build_options.addOption(bool, "check_slow_paths", slow_path);
mod.addImport("build_options", build_options.createModule());
```

The generated file is a real Zig source file. From a probe build with the two
options above, its whole content was
`[OBSERVED: cat <local-cache>/c/<hash>/options.zig]`:

```zig
pub const version: []const u8 = "0.0.1";
pub const have_atspi: bool = true;
```

In Zig source the value is a comptime constant:

```zig
const build_options = @import("build_options");
comptime std.debug.assert(build_options.version.len > 0);
```

### 4.3 Why the house prefers this over a generated file

`zautomerge/build.zig:26-38` gives the reasoning in full:

> A Zig comptime gate has to be a `const`, and the only thing that can set one
> from a command line is a generated module, so the option arrives as
> `build_options.check_slow_paths`. **Both files that read it read that module,
> not a copy of its value**, because a `const check_slow_paths: bool = false`
> sitting next to it would be a constant with a new name and no new behaviour.

Three reasons, in the order the port needs them:

1. **One declaration, one source of truth.** A checked-in `config.zig` has to
   be kept in step with the build script by hand. An options module cannot
   drift: the value the build used is the value the compiler saw.
2. **It changes the cache key.** `Step.MakeOptions` hashing includes the
   options step, so toggling `-Dcheck-slow-paths` rebuilds. A committed file
   that nobody edits is a stale constant the gate never notices.
3. **It reaches Zig source, not only C.** `addConfigHeader`
   (`std/Build.zig:1005`) serves a C `config.h`; `addOptions` serves the Zig
   tree, which is where the port's comptime gates live.

There is one more house habit worth copying. `zautomerge/build.zig:72-86`
builds a **second** options module with the flag forced on, so the `slow-path`
step cannot be run in a state where the checker it exists to run is compiled
out:

```zig
const slow_options = b.addOptions();
slow_options.addOption(bool, "check_slow_paths", true);
const slow_lib_tests = b.addTest(.{
    .root_module = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "build_options", .module = slow_options.createModule() }},
    }),
});
```

The port needs the same shape for any check that is linear in the size of the
thing it checks.

### 4.4 `std_options` is a different thing

`std_options` is **not** produced by `addOptions`. It is a declaration in the
**root source file** of a compilation (`lib/std/std.zig:112`):

```zig
pub const options: Options = if (@hasDecl(root, "std_options")) root.std_options else .{};
```

`std.Options` is at `lib/std/std.zig:114-228`. It is the compiler's own knob set:
segfault handler, log level, page size, thread name, and four overrides of the
ambient environment — `std_options_debug_threaded_io` (`:207`),
`std_options_debug_io` (`:221`), `std_options_FilePermissions` (`:224`) and
`std_options_cwd` (`:227`).

**The last two are a house-rule problem, not a convenience.**
`AGENTS.md` §2 requires that `io` is threaded explicitly and never global.
Setting `std_options_debug_io` makes the debug `Io` a process-wide global.
The port therefore does not set `std_options` at all, and `docs/20-zio-and-zig-io.md`
owns the decision on how a `std.Io` reaches goose.

---

## 5. Build steps

### 5.1 Declaring and naming a step

```zig
pub fn step(b: *Build, name: []const u8, description: []const u8) *Step
```

`std/Build.zig:1355`. The name is the key in `b.top_level_steps`; a duplicate
panics (`std/Build.zig:1366`):

```
A top-level step with name "{s}" already exists
```

`install` and `uninstall` always exist: `install` is created in
`b.create` (`std/Build.zig:296-301`) and `b.getInstallStep` (`std/Build.zig:1119`)
returns it. A project's own steps are created by `b.step`.

Renaming a `Run` step is `Step.Run.setName` (`lib/std/Build/Step/Run.zig:239`),
which also clears `rename_step_with_output_arg`.

### 5.2 Depending one step on another

```zig
pub fn dependOn(step: *Step, other: *Step) void
```

`lib/std/Build/Step.zig:305`. That is the whole ordering mechanism. A build
graph orders a step after another only by an edge; two steps that are both
children of one parent have no order between them. `zautomerge/build.zig:686-689`
states this and mutates a `Run` step to add several edges.

The edges a lazy path creates for you are worth knowing:
`Module.addImport` records one; `addCSourceFiles` records the root directory;
`linkLibraryOrObject` records the other compile step and its include tree
(`std/Build/Module.zig:649-659`).

### 5.3 A test shard: build and run

```zig
pub const TestOptions = struct {
    name: []const u8 = "test",
    root_module: *Module,
    max_rss: usize = 0,
    filters: []const []const u8 = &.{},
    test_runner: ?Step.Compile.TestRunner = null,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    /// Emits an object file instead of a test binary.
    emit_object: bool = false,
};
```

`std/Build.zig:858-871`. `addTest` is `std/Build.zig:881` and **does not run
anything**; the doc comment says so at `:873-880`. `kind` is `.@"test"` or
`.test_obj` (`:884`).

`b.addRunArtifact(compile)` (`std/Build.zig:936`) is the ordinary runner. It
reads `test_runner` to choose between the `std.zig.Server` protocol and an exit
code (`std/Build.zig:962-992`), and it skips the server protocol on a small set
of architectures when `use_llvm == false` (`std/Build.zig:964-983`). A custom
runner is `Step.Compile.TestRunner = .{ path, mode }`
(`std/Build/Step/Compile.zig:372-378`) with `mode` either `.simple` or
`.server`.

**Attach the runner before `addRunArtifact`.** `zautomerge/build.zig:866-871`
gives the reason: `addRunArtifact` reads `test_runner` at configure time, so a
runner attached afterwards leaves a `Run` step waiting for a protocol the
process never speaks.

### 5.4 The house shard fragment, with an address-space ceiling

This is the fragment the gate runs. Sources: `zomp/build.zig:39`, `:42-55`,
:58-77`, `:79-96`, `:157-165`. The target project's `build.zig:22`, `:52-71`
and `:108-118` already carry the same three pieces.

```zig
/// Address-space ceiling for one test shard, in kibibytes. Four gigabytes is
/// far above any honest test here and far below what a runaway loop reaches in
/// a minute, so a test that allocates without bound fails quickly and visibly
/// instead of taking the machine with it.
const test_address_space_kb: u32 = 4 * 1024 * 1024;

/// The shard list is shared so native and foreign coverage cannot drift.
const Shard = struct { name: []const u8, path: []const u8 };

const shards = [_]Shard{
    .{ .name = "core", .path = "src/shard_core.zig" },
    // …
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
    if (target.result.os.tag == .linux and target.result.abi == .musl) compile.linkage = .static;
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
    // argv is [bash, -c, script, bin], so the binary is `$0` to the
    // script and the ceiling applies before it ever starts.
    run.addArg(b.fmt("ulimit -v {d}; exec \"$0\"", .{test_address_space_kb}));
    run.addFileArg(compile.getEmittedBin());
    run.setName(b.fmt("test-{s}-{s}", .{ shard.name, @tagName(mode) }));
    return run;
}

const test_step = b.step("test", "Run library unit tests in Debug and ReleaseSafe, sharded by module");

for (test_modes_full) |mode| {
    for (shards) |shard| {
        const compile = compileShard(b, target, zio, options, shard, mode);
        const run = addCeilingedRun(b, shard, mode, compile);
        test_step.dependOn(&run.step);
    }
}
```

`zomp/build.zig:147-156` gives the reason for sharding, and it is a reason the
port needs too: `std.testing.allocator` is a debug allocator, so the peak of one
process running everything is the worst moment across the whole run. Sharding
makes the peak the worst **module**.

`b.addSystemCommand` is `std/Build.zig:927`. `Step.Run.addArg` is
`lib/std/Build/Step/Run.zig:518`, `addFileArg` is `:330`, and `b.fmt` is
`std/Build.zig:1786`.

### 5.5 Run steps are cached unless they say otherwise

`Step.Run.has_side_effects: bool` is a public field
(`lib/std/Build/Step/Run.zig:89`). `hasSideEffects`
(`lib/std/Build/Step/Run.zig:707`) returns `true` when the field is set or when
the stdio mode already implies it. With no side effects and a cache hit, the
command is **not run** (`lib/std/Build/Step/Run.zig:926`).

So a test that reports nothing to the build system can pass from cache without
executing a single case. The house says this at `zomp/build.zig:190` and
`zaccesskit/build.zig:100`:

> Cached runs execute no tests and cannot prove execution coverage.

Every test run step in the port sets `has_side_effects = true`. That costs the
run its caching and buys it its evidence.

### 5.6 Other step helpers the port will reach for

| Call | Line | Use |
|---|---|---|
| `b.addCheckFile(source, .{ .expected_matches = … })` | `std/Build.zig:1730` | Assert that a generated file contains a string. `CheckFile.Options` at `lib/std/Build/Step/CheckFile.zig:21-24`. |
| `compile.checkObject()` | `std/Build/Step/Compile.zig:614` | Runs `Step.CheckObject` over the emitted object. |
| `b.addFmt(.{ .paths = …, .check = true })` | `std/Build.zig:1111` | The in-graph `zig fmt`. `Fmt.Options` at `lib/std/Build/Step/Fmt.zig:15-20`. |
| `b.addWriteFiles()` | `std/Build.zig:1099` | A directory of generated files. |
| `b.addNamedWriteFiles(name)` | `std/Build.zig:1057` | The same, reachable from a dependent. |
| `b.addObjCopy(source, options)` | `std/Build.zig:1693` | Rename or strip a produced binary. |
| `Step.Run.expectExitCode(code)` | `lib/std/Build/Step/Run.zig:628` | For a non-test program. |
| `Step.Run.setCwd(path)` | `lib/std/Build/Step/Run.zig:535` | The process working directory. `zautomerge/build.zig:662`. |
| `b.option(T, name, description)` | `std/Build.zig:1141` | A `-D` option. |
| `b.validateUserInputDidItFail()` | `std/Build.zig:1644` | Ends a `build()` that refused a combination. `mpfr/build.zig:588-593` uses a typed error instead. |
| `b.markInvalidUserInput()` | called from `standardTargetOptionsQueryOnly` (`std/Build.zig:1507`) | Same, for a whitelist miss. |

`b.runBuild(build_zig)` (`std/Build.zig:2262`) accepts a `build()` returning
`void` or `!void` and propagates the error set, so `pub fn build(b: *std.Build)
error{UnsupportedTarget}!void` is legal. `mpfr/build.zig:576-593` refuses an
unsupported target that way and gets a typed refusal rather than a panic.

---

## 6. Cross compilation

### 6.1 Building for a foreign target

There is no separate cross-build API. `-Dtarget=<triple>` feeds
`b.standardTargetOptions`, `Module.appendZigProcessFlags` emits `-target` and
`-mcpu`, and the build proceeds. The one extra decision is whether the guest
can run.

Runner selection is a build-runner flag, not a build-script option:

| Flag | Field | Line |
|---|---|---|
| `-fqemu` / `-fno-qemu` | `b.enable_qemu: bool` | `std/Build.zig:72-73` |
| `-frosetta` / `-fno-rosetta` | `b.enable_rosetta` | `std/Build.zig:74-75` |
| `-fwasmtime` / `-fno-wasmtime` | `b.enable_wasmtime` | `std/Build.zig:76-77` |
| `-fwine` / `-fno-wine` | `b.enable_wine` | `std/Build.zig:78-79` |
| `--libc-runtimes <path>` | `b.libc_runtimes_dir` | `std/Build.zig:80-85` |
| `--system <pkgdir>` | `b.graph.system_package_mode` | `std/Build.zig:117` |
| `-fsys=<name>` / `-fno-sys=<name>` | `b.graph.system_library_options` | `std/Build.zig:116` |

The flags are parsed in `lib/compiler/build_runner.zig:392-395` (`-fqemu`),
`:318-322` (`--system`) and `:170-174` (`-fsys` / `-fno-sys`).

`zomp/build.zig:176-189` is the one place the house branches on the runner,
and the comment says why:

```zig
// Zig 0.16's fallback compares dynamic linkers even for static x86.
// Honor -fqemu explicitly without skipping tests or their protocol.
if (b.enable_qemu and target.result.cpu.arch == .x86 and
    target.result.os.tag == .linux and target.result.abi == .musl and
    b.graph.host.result.cpu.arch != .x86)
{
    const emulated = b.addSystemCommand(&.{"qemu-i386"});
    emulated.addArtifactArg(compile);
    emulated.enableTestRunnerMode();
    break :run emulated;
}
break :run b.addRunArtifact(compile);
```

### 6.2 What a test cannot do when the target is foreign

Five concrete limits, each with the field or function that owns it.

1. **It cannot spawn the guest unless a runner exists.** Otherwise the step
   fails with the `unable to spawn foreign binary` message quoted in section
   1.6. `skip_foreign_checks = true` turns that into `error.MakeSkipped`
   (`lib/std/Build/Step/Run.zig:2760-2762`); the port leaves it `false`.
2. **It cannot exit-code a skipped run into a pass.** `expectExitCode`
   (`lib/std/Build/Step/Run.zig:628`) never runs if the process never starts.
   `cross-test` handles this by reading the build summary, not the exit code.
3. **It cannot be wrapped in a host-side resource limit that means the same
   thing.** `ulimit -v` on the launcher bounds the emulator, not the guest.
   `zomp/build.zig:167-168` and `zaccesskit/build.zig:80-83` both say this.
4. **It cannot report through a shell launcher.** A `bash -c` wrapper does not
   speak the test protocol, so the build summary shows no counted results.
   `zomp/cross-test.profile.sh:1-3` and `zaccesskit/cross-test.profile.sh:18-19`
   are the same statement. This is a hard requirement, not a preference; see
   6.3.
5. **A dynamic foreign binary needs a foreign loader.** `--libc-runtimes`
   supplies it. Without it the row is compile coverage only. Both house
   profiles avoid the problem by building static musl
   (`zomp/cross-test.profile.sh:30`, `zaccesskit/cross-test.profile.sh:56-57`).

### 6.3 How the house gate runs the foreign matrix

`cross-test` is at `~/.local/bin/cross-test`, 792
lines. `zig-gate` section 9 runs it and is on by default
(`~/.local/bin/zig-gate:660-664`).

The exact command is `cross-test:388-392`:

```bash
CROSS_COMMAND=("${ZIG_COMMAND[@]}" build "$CROSS_BUILD_STEP" "-Dtarget=$target" "-j$CROSS_BUILD_JOBS"
  --prefix "$CROSS_PREFIX" --cache-dir "$CROSS_CACHE_DIR" --build-runner "$CROSS_BUILD_RUNNER"
  --summary all --color off)
[[ $CROSS_ZIG_VERSION != 0.16.0 ]] || CROSS_COMMAND+=(--test-timeout "${CROSS_TIMEOUT}s")
```

Note `--test-timeout` is only passed on a Zig version other than 0.16.0.
On 0.16.0 the budget is whatever `CROSS_TIMEOUT` controls inside the runner.

**The result is read out of the build summary text.** `cross-test:370-377` is
the parser:

```bash
/(compile (test|exe)|zig (test|build-exe)).*(success|cached)/ { compiled++ }
/run exe .* success([[:space:]]|$)/ { executed++ }
…
/^error: (the host system .*unable to execute binaries from the target|unable to spawn foreign binary)/ { foreign++ }
```

The contract is narrower than it looks. `parse_build_summary`
(`cross-test:359-369`) sets `have` from the `Build Summary:` line and `total`
from its `N/M tests passed` part; the pass condition at `cross-test:397` is
`rc == 0 && have && (tests > 0 || executed > 0)`. So a row needs **counted test
results**. `b.addRunArtifact` produces both the counts and a
`run exe … success` line. A `bash -c` launcher produces a `run test <name>`
line and no counts, so the row silently degrades to compile coverage.

**That is the whole cross-test contract:** the `cross-test` step in `build.zig`
must depend on `b.addRunArtifact(compile)` steps and on nothing else.
`zomp/build.zig:174-193` and `zaccesskit/build.zig:84-102` both satisfy it.

The project's own profile is `./cross-test.profile.sh` or
`./test/cross-test.profile.sh` (`cross-test:633-634`). The keys the port's
profile already sets (`zaccesskit/cross-test.profile.sh:20-54`):

| Key | Line | Meaning |
|---|---|---|
| `CROSS_BUILD_STEP` | `:20` | Which named step to run. `cross-test`. |
| `CROSS_MATRIX` | `:38-42` | An indexed Bash array of `'target\|auto'`. `auto` only; `skip` and `runner` are also accepted (`cross-test:50`). |
| `CROSS_REQUIRE_RUNNERS` | `:46` | A missing runner is a failure. |
| `CROSS_JOBS`, `CROSS_BUILD_JOBS` | `:51-52` | Concurrency. |
| `CROSS_BUILD_TIMEOUT`, `CROSS_TIMEOUT` | `:53-54` | Build and run budgets. |
| `CROSS_LIBC_RUNTIMES` | not set | Passed as `--libc-runtimes` at `cross-test:387`. |

Two properties the profile must not break, from `zig-gate:669-673` and
`zomp/cross-test.profile.sh:1-3`:

1. A green run reports `status=partial`, not `status=pass`, whenever a row has
   no runner. `partial` and `build_only` are judged by `fail=0`. Passing
   `--require-runners` would turn a normal result into a failure, and the gate
   does not pass it.
2. `status=fail` cannot tell a timeout from a wrong answer. A `timed out` in a
   per-target log is a budget problem. `zaccesskit/cross-test.profile.sh:14-16`
   records this, and `zig-gate:749-760` is the code that reads it.

The port's own profile already pins three rows: `x86_64-linux`, `aarch64-linux`
and `powerpc64-linux`. `zaccesskit/cross-test.profile.sh:56-59` notes the row
set must grow by one per system library the C half links, because a
`translate-c` binding that only works against the host glibc is not portable
coverage. Section 3.2 is the list.

---

## 7. Shared and static libraries

This is how the port exposes its C interface.

### 7.1 The three emission calls

```zig
pub const LibraryOptions = struct {
    linkage: std.builtin.LinkMode = .static,
    name: []const u8,
    root_module: *Module,
    version: ?std.SemanticVersion = null,
    max_rss: usize = 0,
    use_llvm: ?bool = null,
    use_lld: ?bool = null,
    zig_lib_dir: ?LazyPath = null,
    win32_manifest: ?LazyPath = null,
    win32_module_definition: ?LazyPath = null,
};
```

`std/Build.zig:823-840`, `b.addLibrary` at `:842`. `b.addObject` is `:811`
(`ObjectOptions` at `:802-809`) and `b.addExecutable` is `:787`
(`ExecutableOptions` at `:770-785`).

**`linkage` defaults to `.static`.** `mpfr/build.zig:556-559` makes the point
that a missing `-Dlinkage` must keep producing what the package produced
before the option existed. The port therefore states `.linkage` explicitly on
both routes rather than relying on the default.

### 7.2 The output file name

`std.zig.binNameAlloc` (`std/zig.zig:156`) is the single naming authority.
`Step.Compile.create` calls it at `std/Build/Step/Compile.zig:400-410`.

| Format | Static | Dynamic, no version | Dynamic, with version |
|---|---|---|---|
| ELF | `libNAME.a` (`zig.zig:175-177`) | `libNAME.so` (`:184-186`) | `libNAME.so.MAJOR.MINOR.PATCH` (`:180-182`) |
| Mach-O | `libNAME.a` (`:197-199`) | `libNAME.dylib` (`:206-208`) | `libNAME.MAJOR.MINOR.PATCH.dylib` (`:202-204`) |
| COFF | `NAME.lib` (`:164`) | `NAME.dll` (`:166`) | `NAME.lib` (`Compile.zig:500`) |
| wasm | `libNAME.a` (`:219-221`) | `NAME.wasm` (`:222`) | `NAME.wasm` |

Observed, with `.name = "probe"`, `.linkage = .dynamic`,
`.version = .{ .major = 0, .minor = 0, .patch = 1 }`
`[OBSERVED: find zig-out -type f -o -type l]`:

```
zig-out/include/probe.h
zig-out/lib/libprobe.so
zig-out/lib/libprobe.so.0
zig-out/lib/libprobe.so.0.0.1
```

### 7.3 Soname and symlinks

There is no separate soname field. **`LibraryOptions.version` is the soname
source.** `Step.Compile.create` derives the symlink names from it
(`std/Build/Step/Compile.zig:488-515`):

```zig
} else if (compile.version) |version| {
    if (target.os.tag.isDarwin()) {
        compile.major_only_filename = owner.fmt("lib{s}.{d}.dylib", .{ compile.name, version.major });
        compile.name_only_filename = owner.fmt("lib{s}.dylib", .{compile.name});
        compile.out_lib_filename = compile.out_filename;
    } else if (target.os.tag == .windows) {
        compile.out_lib_filename = owner.fmt("{s}.lib", .{compile.name});
    } else {
        compile.major_only_filename = owner.fmt("lib{s}.so.{d}", .{ compile.name, version.major });
        compile.name_only_filename = owner.fmt("lib{s}.so", .{compile.name});
        compile.out_lib_filename = compile.out_filename;
    }
}
```

`std/Build/Step/Compile.zig:502-503`. The symlinks themselves are made by
`doAtomicSymLinks` (`std/Build/Step/Compile.zig:1869`), called at
`std/Build/Step/Compile.zig:1830-1832`, and only when
`b.wantSharedLibSymLinks(target)` is true. That function is
`std/Build.zig:2717`:

```zig
pub fn wantSharedLibSymLinks(target: Target) bool {
    return target.os.tag != .windows;
}
```

So there is no soname on COFF at all. `pcre2/build.zig:1672-1685` states the
rule and passes `version` only where it means something:

```zig
fn hasSoname(target: std.Build.ResolvedTarget) bool {
    … => switch (target.result.ofmt) {
        .elf, .macho => true,
        // COFF (Windows and UEFI) has no soname at all, wasm has no dynamic
        // loader, and the rest of `std.Target.ObjectFormat` are not object
        // formats a C library is produced for.
        else => false,
    };
}
```

and `pcre2/build.zig:1219-1221` applies it.

The observable result, from the probe
`[OBSERVED: readelf -d zig-out/lib/libprobe.so.0.0.1]`:

```
 0x0000000000000001 (NEEDED)             Shared library: [libm.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [libc.so.6]
 0x0000000000000001 (NEEDED)             Shared library: [ld-linux-x86-64.so.2]
 0x000000000000000e (SONAME)             Library soname: [libprobe.so.0]
 0x000000000000001d (RUNPATH)            Library runpath: [$ORIGIN]
```

The `RUNPATH` came from `Module.addRPathSpecial("$ORIGIN")`
(`std/Build/Module.zig:522`), which the module turns into `-rpath $ORIGIN`
(`std/Build/Module.zig:632-635`). The `NEEDED` on `libm.so.6` came from
`linkSystemLibrary("m", .{})`.

**Version derivation for the port.** `mpfr/build.zig:343-355` derives its soname
from upstream's own libtool `-version-info` rather than carrying a literal, so a
rebase that changes the versioning fails the build instead of shipping a stale
soname. The port has no upstream libtool file. `build.zig.zon:3` carries
`.version = "0.0.0"` and `build.zig` mirrors it as a `version` constant
(`zomp/build.zig:27-29`). The skeleton below does the same: one literal in
`build.zig`, read from the manifest by a human, and asserted equal by
`docs/50-verification.md`.

### 7.4 How a consumer links

| Case | Call | Line |
|---|---|---|
| static archive or an in-cache shared object | `module.linkLibrary(lib)` | `std/Build/Module.zig:470` |
| a compiled object step | `module.addObject(obj)` | `std/Build/Module.zig:465` |
| an installed shared object, no cache path | `module.addObjectFile(lib.getEmittedBin())` | `std/Build/Module.zig:460` |

`linkLibraryOrObject` (`std/Build/Module.zig:649-659`) also appends the other
compile step's installed header tree to this module's include path, and on
Windows asks for the import library. That is why a consumer of the port's C
artifact finds `accesskit.h` without being told where it is.

### 7.5 The rpath trap, and the `addObjectFile` answer

`Module.linkLibrary` on a **dynamic** artifact makes the linker record the
directory the shared object was emitted into, which is the build cache. The
block is at `std/Build/Step/Compile.zig:1195-1198`:

```zig
if (fs.path.dirname(full_path_lib)) |dirname| {
    try zig_args.append("-rpath");
    try zig_args.append(dirname);
}
```

`mpfr/build.zig:984-995` explains why that is a packaging bug rather than a
detail:

> That directory is the build cache. It does not exist once the file is
> installed, and Nix refuses an installed file that names its own build
> directory at all, so an installed artifact that carried it could never be
> packaged — and on ELF the loader would search a directory that is gone
> rather than the one that is there. `Module.addObjectFile` puts the very same
> file on the link line and records no search path at all.

The answer, `mpfr/build.zig:996-1009`:

```zig
fn linkInstalledSibling(
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
    target: std.Build.ResolvedTarget,
) void {
    // Windows links through the import library and has no rpath, so the
    // ordinary call is the right one there and is kept.
    if (library.linkage != .dynamic or target.result.os.tag == .windows) {
        module.linkLibrary(library);
        return;
    }
    module.addObjectFile(library.getEmittedBin());
    if (installedLibraryRPath(target)) |rpath| module.addRPathSpecial(rpath);
}
```

with `installedLibraryRPath` at `mpfr/build.zig:970-975`:

```zig
return switch (target.result.os.tag) {
    .windows, .wasi, .uefi => null,
    else => if (target.result.os.tag.isDarwin()) "@loader_path" else "$ORIGIN",
};
```

The port adopts this for every installed artifact.

`Step.Compile.each_lib_rpath: ?bool = null` (`std/Build/Step/Compile.zig:93`)
becomes `--each-lib-rpath` at `std/Build/Step/Compile.zig:1647`. It exists on
`Step.Compile` only, **not** in `ExecutableOptions` or `LibraryOptions`
(`std/Build.zig:770-785`, `:823-840`). Setting it on `b.addExecutable(.{ … })`
is a compile error in the build script; `zautomerge/build.zig:630-657` records
the incident and the fix, which is to set `bin.each_lib_rpath = true` after the
call. On this toolchain the flag had no measured effect
(`zautomerge/build.zig:644-651`), so the port treats it as a stated requirement
rather than a fix.

### 7.6 Headers

| Call | Line | Note |
|---|---|---|
| `compile.installHeader(source, dest_rel_path)` | `std/Build/Step/Compile.zig:523` | Also puts the header on the include path of every compilation that links the artifact. |
| `compile.installHeadersDirectory(source, dest_rel_path, options)` | `std/Build/Step/Compile.zig:537` | `include_extensions` defaults to `.h` (`:339`). |
| `compile.installLibraryHeaders(other_lib)` | `std/Build/Step/Compile.zig:564` | Copies another artifact's headers. |
| `compile.installConfigHeader(config_header)` | `std/Build/Step/Compile.zig:557` | A `Step.ConfigHeader` as a header. |
| `b.addInstallHeaderFile(source, dest_rel_path)` | `std/Build.zig:1713` | A plain file into `include/`, no artifact involved. |

Because `getEmittedH` is broken (section 3.8), the port writes
`include/accesskit.h` as a checked-in file and installs it with
`installHeader`. The probe did exactly that and `zig-out/include/probe.h`
appeared `[OBSERVED: find zig-out -type f]`.

### 7.7 The Darwin install name

`Step.Compile.install_name: ?[]const u8` (`std/Build/Step/Compile.zig:148`)
becomes `-install_name` on Darwin (`std/Build/Step/Compile.zig:1497-1504`),
defaulting to `@rpath/libNAME.dylib`. The port states it explicitly so the
macOS adapter's dylib has a predictable name.

---

## 8. What the port build will need

**This is a skeleton for the design wave to refine, not a finished file.**
Every call in it was compiled against Zig 0.16.0, and every step that does not
hit the fuzz blocker in section 9.7 was run. The shape follows
the existing `zaccesskit/build.zig`, which publishes one module and two test
shards, and adds what `docs/40-plan.md` will schedule: the C half, the shared
library with its header, the cross matrix, and the fuzz registration.

The `std.Build` calls it uses, with their definitions:

| Call | Definition |
|---|---|
| `b.standardTargetOptions` | `std/Build.zig:1414` |
| `b.standardOptimizeOption` | `std/Build.zig:1378` |
| `b.option` | `std/Build.zig:1141` |
| `b.addOptions` | `std/Build.zig:766` |
| `b.addModule` | `std/Build.zig:909` |
| `b.createModule` | `std/Build.zig:918` |
| `b.dependency` | `std/Build.zig:2055` |
| `Dependency.module` | `std/Build.zig:1961` |
| `b.addLibrary` | `std/Build.zig:842` |
| `b.addExecutable` | `std/Build.zig:787` |
| `b.addTest` | `std/Build.zig:881` |
| `b.addRunArtifact` | `std/Build.zig:936` |
| `b.addSystemCommand` | `std/Build.zig:927` |
| `b.step` | `std/Build.zig:1355` |
| `Step.dependOn` | `std/Build/Step.zig:305` |
| `b.addTranslateC` | `std/Build.zig:1115` |
| `b.addFmt` | `std/Build.zig:1111` |
| `b.addCheckFile` | `std/Build.zig:1730` |
| `b.installArtifact` | `std/Build.zig:1660` |
| `b.addInstallHeaderFile` | `std/Build.zig:1713` |
| `b.installFile` | `std/Build.zig:1675` |
| `b.fmt` | `std/Build.zig:1786` |
| `b.path` | `std/Build.zig:1755` |
| `Module.addImport` | `std/Build/Module.zig:326` |
| `Module.addOptions` | `std/Build/Module.zig:340` |
| `Module.addCSourceFiles` | `std/Build/Module.zig:408` |
| `Module.addCSourceFile` | `std/Build/Module.zig:431` |
| `Module.addIncludePath` | `std/Build/Module.zig:485` |
| `Module.addLibraryPath` | `std/Build/Module.zig:512` |
| `Module.addObjectFile` | `std/Build/Module.zig:460` |
| `Module.linkLibrary` | `std/Build/Module.zig:470` |
| `Module.linkSystemLibrary` | `std/Build/Module.zig:363` |
| `Module.addRPathSpecial` | `std/Build/Module.zig:522` |
| `options.addOption` | `std/Build/Step/Options.zig:39` |
| `options.createModule` | `std/Build/Step/Options.zig:428` |
| `Compile.getEmittedBin` | `std/Build/Step/Compile.zig:856` |
| `Compile.installHeader` | `std/Build/Step/Compile.zig:523` |
| `Step.Run.setName` | `std/Build/Step/Run.zig:239` |
| `Step.Run.addArg` | `std/Build/Step/Run.zig:518` |
| `Step.Run.addFileArg` | `std/Build/Step/Run.zig:330` |
| `Step.Run.addArtifactArg` | `std/Build/Step/Run.zig:254` |
| `Step.Run.enableTestRunnerMode` | `std/Build/Step/Run.zig:244` |
| `Step.Run.setCwd` | `std/Build/Step/Run.zig:535` |
| `Step.Run.expectExitCode` | `std/Build/Step/Run.zig:628` |
| `Step.TranslateC.defineCMacro` | `std/Build/Step/TranslateC.zig:153` |
| `Step.TranslateC.addIncludePath` | `std/Build/Step/TranslateC.zig:116` |
| `Step.TranslateC.createModule` | `std/Build/Step/TranslateC.zig:80` |

```zig
//! Build wiring for zaccesskit.
//!
//! SKELETON. docs/30-port-design.md refines the module layout and
//! docs/40-plan.md schedules the milestones. Every std.Build call below has a
//! definition verified against the Zig 0.16.0 standard library.

const std = @import("std");

/// Mirror of `.version` in `build.zig.zon`. The manifest is the release
/// authority; a release bumps both and docs/50-verification.md checks them
/// against each other.
const version = "0.0.0";

/// Both safety-enabled modes belong to the house gate, so an optimized-only
/// failure cannot pass a Debug-only run.
const test_modes_full = [_]std.builtin.OptimizeMode{ .Debug, .ReleaseSafe };

/// Address-space ceiling for one native test shard, in kibibytes.
const test_address_space_kb: u32 = 4 * 1024 * 1024;

/// The shard list is shared so native and foreign coverage cannot drift.
const Shard = struct { name: []const u8, path: []const u8 };

const shards = [_]Shard{
    .{ .name = "core", .path = "src/shard_core.zig" },
    .{ .name = "platform", .path = "src/platform/root.zig" },
    // docs/40-plan.md names the milestone that adds each shard.
};

pub fn build(b: *std.Build) void {
    // `-Doptimize` is what the house gate and every developer invocation use,
    // so the port keeps the default option set. `preferred_optimize_mode` is
    // deliberately NOT set: it removes `-Doptimize` from `--help` and replaces
    // it with `-Drelease`. See section 9.11.
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // No `-fsys=` integration is declared. The facility exists in 0.16.0
    // (section 9.23), but the port has no X11 build to select. A milestone
    // that adds one declares its own option then, and section 10, item 3,
    // records the decision that reopens it.

    const have_atspi = b.option(
        bool,
        "atspi",
        "Build the Linux AT-SPI adapter",
    ) orelse true;

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);
    options.addOption(bool, "have_atspi", have_atspi);

    // zio is the async runtime. It is a module-level import, not a
    // whole-package import: only the library needs a runtime, and the test
    // harness constructs one explicitly so the io is a parameter.
    const zio = b.dependency("zio", .{
        .target = target,
        .optimize = optimize,
    }).module("zio");

    // The published Zig module. Consumers write @import("zaccesskit").
    const mod = b.addModule("zaccesskit", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zio", .module = zio },
        },
    });
    mod.addOptions("build_options", options);
    mod.addIncludePath(b.path("include"));
    // The only system library the Zig half links. Every other C dependency the
    // adapters take is rung 2, a Zig package, per local://zaccesskit-deps.md.
    mod.linkSystemLibrary("m", .{});

    // ---- The C half ------------------------------------------------------
    //
    // A private module: it is the root of a library artefact, not a surface a
    // consumer imports by name. It re-exports `zaccesskit` so the C ABI is one
    // export declaration per entry point rather than a re-implementation.
    const cabi_module = b.createModule(.{
        .root_source_file = b.path("src/c_abi/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "zaccesskit", .module = mod },
            .{ .name = "zio", .module = zio },
        },
    });
    cabi_module.addOptions("build_options", options);
    cabi_module.addIncludePath(b.path("include"));

    // The shim is C. It exists for the four reasons in section 3.7 and for no
    // other one. Every file is named here; none is globbed.
    cabi_module.addCSourceFiles(.{
        .root = b.path("src/c_abi"),
        .files = &.{
            "variadic.c",
        },
        .flags = &.{ "-std=c11" },
    });

    const linkage = b.option(
        std.builtin.LinkMode,
        "linkage",
        "Linkage of the installed libzaccesskit: static (default) or dynamic",
    ) orelse .static;

    const shared = linkage == .dynamic;

    const lib = b.addLibrary(.{
        .name = "zaccesskit",
        .linkage = linkage,
        // `version` is the soname source. A static archive has no name to carry
        // it, which is why the value is null there rather than passed and
        // ignored. `hasSoname` mirrors pcre2/build.zig:1679-1685.
        .version = if (shared and hasSoname(target)) .{
            .major = 0,
            .minor = 0,
            .patch = 0,
        } else null,
        .root_module = cabi_module,
    });
    if (shared) {
        // Position-independent is stated, not inferred: null means the driver
        // decides. See mpfr/build.zig:909-912.
        lib.root_module.pic = true;
    }
    lib.root_module.addRPathSpecial(installedLibraryRPath(target) orelse "$ORIGIN");
    // The header is checked in, because -femit-h is broken on 0.16.0.
    lib.installHeader(b.path("include/accesskit.h"), "accesskit.h");
    b.installArtifact(lib);

    // The C conformance suite below links the artefact the ordinary way. It
    // runs out of the build cache and is never installed, so the cache rpath
    // that linkLibrary records is correct for it.
    //
    // A consumer of the *installed* shared object must NOT use linkLibrary: it
    // records the build cache directory as an rpath, which does not exist after
    // installation. That consumer writes
    //     module.addObjectFile(lib.getEmittedBin());
    //     module.addRPathSpecial(installedLibraryRPath(target) orelse "$ORIGIN");
    // instead. See section 7.5 and mpfr/build.zig:996-1009.
    //
    // This module must NOT link the library it is the root of. Doing so is a
    // dependency loop; section 9.9 has the exact message.

    // ---- Tests -----------------------------------------------------------

    const test_step = b.step("test", "Run the library tests in Debug and ReleaseSafe, sharded");

    for (test_modes_full) |mode| {
        for (shards) |shard| {
            const m = b.createModule(.{
                .root_source_file = b.path(shard.path),
                .target = target,
                .optimize = mode,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "zaccesskit", .module = mod },
                    .{ .name = "zio", .module = zio },
                },
            });
            m.addOptions("build_options", options);
            const compile = b.addTest(.{
                .name = b.fmt("test-{s}-{s}", .{ shard.name, @tagName(mode) }),
                .root_module = m,
            });
            // A foreign musl loader need not exist on the host.
            if (target.result.os.tag == .linux and target.result.abi == .musl) {
                compile.linkage = .static;
            }

            const run = b.addSystemCommand(&.{ "bash", "-c" });
            // argv is [bash, -c, script, bin], so the binary is $0 to the
            // script and the ceiling applies before it ever starts.
            run.addArg(b.fmt("ulimit -v {d}; exec \"$0\"", .{test_address_space_kb}));
            run.addFileArg(compile.getEmittedBin());
            run.setName(b.fmt("test-{s}-{s}", .{ shard.name, @tagName(mode) }));
            test_step.dependOn(&run.step);
        }
    }

    // The C ABI's own conformance suite: a C program linked against the
    // installed-shaped artefact, exactly as a C consumer links it.
    const c_suite = b.addExecutable(.{
        .name = "accesskit-c-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/c/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    c_suite.root_module.addIncludePath(b.path("include"));
    c_suite.root_module.addCSourceFiles(.{
        .root = b.path("test/c"),
        .files = &.{
            "main.c",
            "abi_layout.c",
            "tree_updates.c",
        },
    });
    c_suite.root_module.linkLibrary(lib);
    const run_c_suite = b.addRunArtifact(c_suite);
    run_c_suite.setCwd(b.path("test/c"));
    run_c_suite.expectExitCode(0);
    const c_test_step = b.step("c-test", "Run the C ABI conformance suite");
    c_test_step.dependOn(&run_c_suite.step);

    // A binding check: the port's own header, read back through translate-c.
    // This is what proves the header and the Zig exports agree.
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("include/accesskit.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("include"));
    translate.defineCMacro("ACCESSKIT_NO_AUTOMATIC_INIT", null);
    const binding_check = b.addTest(.{
        .name = "binding-check",
        .root_module = b.createModule(.{
            .root_source_file = b.path("test/binding_check.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{
                .{ .name = "c", .module = translate.createModule() },
                .{ .name = "zaccesskit", .module = mod },
            },
        }),
    });
    const binding_step = b.step("binding-check", "Check the C header against the Zig exports");
    binding_step.dependOn(&b.addRunArtifact(binding_check).step);

    // ---- Fuzz ------------------------------------------------------------
    //
    // `.fuzz = true` becomes `-ffuzz`, which does not compile on Zig 0.16.0.
    // See section 9.7. The step is declared so the graph is complete, and
    // docs/40-plan.md carries the blocker; until it clears, the corpus replay
    // in `zig build test` is the fuzz evidence.
    const fuzz_module = b.createModule(.{
        .root_source_file = b.path("test/fuzz_root.zig"),
        .target = target,
        .optimize = .Debug,
        .fuzz = true,
        .imports = &.{
            .{ .name = "zaccesskit", .module = mod },
            .{ .name = "zio", .module = zio },
        },
    });
    fuzz_module.addOptions("build_options", options);
    const fuzz = b.addTest(.{
        .name = "fuzz",
        .root_module = fuzz_module,
    });
    const fuzz_run = b.addRunArtifact(fuzz);
    fuzz_run.has_side_effects = true;
    // The fuzz run is deliberately NOT hung off `test`. `.fuzz = true` becomes
    // `-ffuzz`, which does not compile on 0.16.0 (section 9.7), and a red
    // `zig build test` is a failed house gate. Until the blocker clears,
    // `zig build test --fuzz=N` reports `no fuzz tests found`, and the corpus
    // replay inside plain `zig build test` is the fuzz evidence.
    b.step("fuzz", "Run the decoder fuzz targets").dependOn(&fuzz_run.step);

    // ---- Cross -----------------------------------------------------------
    //
    // This step must depend on addRunArtifact steps and nothing else. The
    // cross-test tool reads counted test results out of the build summary, and
    // a `bash -c` launcher reports none, so the row would silently degrade to
    // compile coverage.
    const cross_test_step = b.step(
        "cross-test",
        "Run the Debug shards in foreign targets through the build system's runner",
    );
    for (shards) |shard| {
        const m = b.createModule(.{
            .root_source_file = b.path(shard.path),
            .target = target,
            .optimize = .Debug,
            .link_libc = true,
            .imports = &.{
                .{ .name = "zaccesskit", .module = mod },
                .{ .name = "zio", .module = zio },
            },
        });
        m.addOptions("build_options", options);
        const compile = b.addTest(.{
            .name = b.fmt("cross-test-{s}", .{shard.name}),
            .root_module = m,
        });
        const run = b.addRunArtifact(compile);
        // A cached run executes no tests and cannot prove execution coverage.
        run.has_side_effects = true;
        cross_test_step.dependOn(&run.step);
    }

    // ---- House gates -----------------------------------------------------

    // `addFmt` returns a step, and Zig rejects an unused value.
    _ = b.addFmt(.{
        .paths = &.{ "build.zig", "src", "test" },
        .check = true,
    });
}

/// Whether this target's shared-library naming has a soname at all. Mirrors
/// pcre2/build.zig:1679-1685.
fn hasSoname(target: std.Build.ResolvedTarget) bool {
    return switch (target.result.ofmt) {
        .elf, .macho => true,
        else => false,
    };
}

/// The search path an installed library needs. A library installed beside its
/// own dependencies needs only its own directory. Mirrors mpfr/build.zig:970-975.
fn installedLibraryRPath(target: std.Build.ResolvedTarget) ?[]const u8 {
    return switch (target.result.os.tag) {
        .windows, .wasi, .uefi => null,
        else => if (target.result.os.tag.isDarwin()) "@loader_path" else "$ORIGIN",
    };
}
```

### 8.1 What is deliberately absent from the skeleton

| Missing | Why |
|---|---|
| `cargo`, `rustc`, any Rust step | The project has no Rust toolchain. There is no step that shells out to one. |
| A generated and installed pkg-config file | `docs/31-c-abi-design.md` owns the C consumer story. `mpfr/build.zig:1097-1126` is the model if one is needed. |
| `addConfigHeader` | Nothing here needs a C `config.h`. A port that does gets one from `std/Build.zig:1005`. |
| `addCheckFile` in the graph | Listed in the table above because `docs/18-testing-strategy.md` will want it. A header-drift check is its first use. |
| `b.addObjCopy` | Nothing strips or renames a produced artefact yet. |

### 8.2 House rules, one line each

| `AGENTS.md` rule | How the skeleton satisfies it |
|---|---|
| `io` threaded explicitly, never global | The build passes no `--main-mod-path` and sets no `std_options`. Every Zig module takes `io` as a parameter; no build facility can change that. Section 4.4. |
| State is a parameter, not a capture | No build facility captures state. `Module` is a value the graph owns; the port's own state is in Zig, not in the build. |
| Event and platform logic is pure over decoded input | The build cannot affect this, and the skeleton states no generated source that would smuggle behaviour in. `addOptions` carries two values, all of them facts about the build. |
| Allocators are parameters | Same: `b.addOptions` carries no allocator and the generated module is two constants. |
| Error sets are explicit | The skeleton returns `void` from `build` and refuses a target through `hasSoname`, a `bool` switch, not a panic. `mpfr/build.zig:576-593` shows the typed-refusal route if the port needs one. |
| Loops have fixed upper bounds | Every loop is over a fixed array: `shards`, `test_modes_full`. No loop over a directory, no recursion. |
| No backwards compatibility | No alias, no deprecated step, no fallback route. `-Dlinkage` has one spelling. |

---

## 9. Traps

Every entry below is a place where a build script written for an earlier Zig,
or written from memory, loses time. The error text is the one the compiler
produced, not a paraphrase.

### 9.1 `ExecutableOptions` has no `each_lib_rpath`

The field exists on `Step.Compile` (`std/Build/Step/Compile.zig:93`) and on
nothing else. Writing it in the options struct is a **compile error in the
build script**, and a build script that does not compile fails every step:

```
build.zig:8:10: error: no field named 'each_lib_rpath' in struct 'Build.ExecutableOptions'
        .each_lib_rpath = true,
         ^~~~~~~~~~~~~~~~
note: struct declared here
pub const ExecutableOptions = struct {
```

`[OBSERVED: zig build, probe2]`. Fix: assign it after the call.
`zautomerge/build.zig:630-657` records the same incident.

### 9.2 `addAnonymousImport` without a root source file

`Module.addAnonymousImport` (`std/Build/Module.zig:332`) forwards its options
straight to `create`. With no `root_source_file` the module has no `-M`
argument, and the compilation fails:

```
error: error: module 'probe' depends on non-existent module 'probe_c'
```

`[OBSERVED: zig build, probe1]`. The `--dep probe_c` was on the command line
and no `-Mprobe_c=` was. For a C header use `b.addTranslateC(…).createModule()`
(`std/Build/Step/TranslateC.zig:80`); for a Zig source use `addImport`.

### 9.3 `linkSystemLibrary` needs a known target

`std/Build/Module.zig:370` calls `requireKnownTarget`
(`std/Build/Module.zig:661-665`):

```
thread 16809 panic: this API requires the Module to be created with a known 'target' field
.../lib/std/Build/Module.zig:663:9: in requireKnownTarget (std.zig)
.../lib/std/Build/Module.zig:370:40: in linkSystemLibrary (std.zig)
```

`[OBSERVED: zig build, probe3]`. The same applies to `addWin32ResourceFile`
(`std/Build/Module.zig:445`). Every module the port builds that links
something carries `.target = target`.

### 9.4 Absolute paths are refused in two different places

```
thread 18748 panic: file paths added with 'addCSourceFiles' must be relative, found absolute path '/tmp/absolute.c'
```

`std/Build/Module.zig:414-418` `[OBSERVED: zig build, probe4]`, and

```
sub_path is expected to be relative to the build root, but was this absolute path: '{s}'. It is best avoid absolute paths, but if you must, it is supported by LazyPath.cwd_relative
```

`std/Build.zig:1756-1759`. `b.pathFromRoot` (`std/Build.zig:1770`) is the
escape hatch, and `zautomerge/build.zig:575-589` works through every step of it.

### 9.5 `-femit-h` is broken and the standard library knows it

```
error: error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698
```

`[OBSERVED: zig build, after calling lib.getEmittedH()]`.
`lib/std/Build/Step/InstallArtifact.zig:123-124` carries the issue number and a
commented-out call. There is no header generator to fall back to. Ship a
checked-in header.

### 9.6 `std.Build.Step.Check` does not exist

There is no `Check` step in 0.16.0. `lib/std/Build/Step.zig:188-202` lists what
does: `CheckFile`, `CheckObject`, `ConfigHeader`, `Fail`, `Fmt`,
`InstallArtifact`, `InstallDir`, `InstallFile`, `ObjCopy`, `Compile`,
`Options`, `Run`, `TranslateC`, `WriteFile`, `UpdateSourceFiles`. The two
checks are `Step.CheckFile` (`b.addCheckFile`, `std/Build.zig:1730`) and
`Step.CheckObject` (`compile.checkObject()`, `std/Build/Step/Compile.zig:614`).

### 9.7 Fuzzing does not work on this Zig 0.16.0

`zig test -ffuzz` fails to compile the standard library's own test runner:

```
.../lib/compiler/test_runner.zig:566:55: error: expected type '*const debug.StackTrace', found '*builtin.StackTrace'
                            std.debug.writeStackTrace(trace, stderr) catch break :p;
                                                      ^~~~~
note: pointer type child 'builtin.StackTrace' cannot cast into pointer type child 'debug.StackTrace'
note: struct declared here
pub const StackTrace = struct {          # lib/std/builtin.zig:11
pub const StackTrace = struct {          # lib/std/debug.zig:604
pub fn writeStackTrace(st: *const StackTrace, t: Io.Terminal) Writer.Error!void {   # lib/std/debug.zig:824
```

`[OBSERVED: zig 0.16.0 test -ffuzz probe6/f.zig]`. The same tree without
`-ffuzz` passes and prints `1 fuzz tests found.`
`[OBSERVED: zig 0.16.0 test probe6/f.zig]`.

`std.debug.writeStackTrace` takes `*const debug.StackTrace`
(`lib/std/debug.zig:824`), `@errorReturnTrace()` returns `?*builtin.StackTrace`
(`lib/std/builtin.zig:11`), and `lib/compiler/test_runner.zig:565-567` passes
one to the other with no cast. That code is only reachable under `builtin.fuzz`,
so every `-ffuzz` build fails.

Two consequences for the port:

1. `Module.CreateOptions.fuzz` (`std/Build/Module.zig:248`) becomes `-ffuzz`
   (`std/Build/Module.zig:552`) and turns every containing compile red. Do not
   hang a fuzz run off the `test` step while the blocker stands.
2. A fuzz `Run` step that is not reachable from `test` is never made, so
   `run.fuzz_tests` stays empty (`lib/std/Build/Step/Run.zig:1832-1833`) and
   `zig build test --fuzz=N` reports:

   ```
   error: no fuzz tests found
   ```

   `[OBSERVED: zig build test --fuzz=20, fuzz run only under the `fuzz` step]`.
   `zig build fuzz` fails the same way.

What still works today: a plain `zig build test` compiles `std.testing.fuzz`
targets, runs the recorded corpus, and reports `N fuzz tests found`. That is
replay, not mutation. `docs/18-testing-strategy.md` and `docs/40-plan.md`
carry the blocker and the replay-only interim.

### 9.8 `std.testing.Smith.bytes` returns `void` in 0.16.0

```zig
pub noinline fn bytes(s: *Smith, out: []u8) void {
    return s.bytesWithHash(out, firstHash());
}
```

`lib/std/testing/Smith.zig:259`. Calling `smith.bytes()` with no argument is an
arity error, and using the result is a type error:

```
src/fuzz_root.zig:8:41: error: type 'void' does not support field access
src/fuzz_root.zig:6:23: error: member function expected 1 argument(s), found 0
```

`[OBSERVED: zig build test --fuzz=20]`. `Smith.slice(buf) u32`
(`lib/std/testing/Smith.zig:274`) is the one that returns the length.

### 9.9 A module must not link the artifact it is the root of

```zig
// A module that is the root of `lib` must not carry lib's own output.
cabi_module.addObjectFile(lib.getEmittedBin());
```

is a dependency loop, and the build runner says so at configure time:

```
dependency loop detected:
  compile lib zaccesskit Debug native
  compile lib zaccesskit Debug native
  install zaccesskit
  install
```

`[OBSERVED: zig build, probe7]`. The `addObjectFile` route belongs on a
**different** module — the installed consumer, not the producer.

### 9.10 `b.addFmt` returns a step and Zig rejects an unused value

```
build.zig:293:13: error: value of type '*Build.Step.Fmt' ignored
    b.addFmt(.{
    ~~~~~~~~^
note: all non-void values must be used
```

`[OBSERVED: zig build, probe7]`. `_ = b.addFmt(.{ … });`. The same rule applies
to every `b.add*` that returns a step: `addOptions`, `addTranslateC`,
`addCheckFile`, `addWriteFiles`, `addObjCopy`.

### 9.11 `preferred_optimize_mode` changes the option set

`b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe })` is not
"the same call with a default filled in". It registers `-Drelease=[bool]` and
**removes `-Doptimize`** (`std/Build.zig:1378-1393`). Observed
`[OBSERVED: zig build --help]`:

```
  -Drelease=[bool]             optimize for end users
```

with no `-Doptimize` anywhere. The same field does not exist on
`StandardTargetOptionsArgs` (`std/Build.zig:1407-1410`), and passing it there is

```
build.zig:32:10: error: no field named 'preferred_optimize_mode' in struct 'Build.StandardTargetOptionsArgs'
```

`[OBSERVED: zig build, probe7]`. Four house projects use `.{ }`. The port does
too, and accepts that `zig build --release` prints
`the project does not declare a preferred optimization mode` and exits
(`std/Build.zig:1395-1400`). `docs/40-plan.md` may revisit that.

### 9.12 A test run step may never execute at all

`Step.Run.has_side_effects: bool` (`lib/std/Build/Step/Run.zig:89`) decides
whether a cache hit skips the process (`lib/std/Build/Step/Run.zig:926`). A
test that reports nothing to the build system passes from cache with zero cases
run. Every test run step in the port sets the field to `true`, and pays for it
in build time. `zomp/build.zig:190` and `zaccesskit/build.zig:100` both say
why.

### 9.13 `linkSystemLibrary` shells out to `pkg-config` by default

`LinkSystemLibraryOptions.use_pkg_config` defaults to `.yes`
(`std/Build/Module.zig:358`). Any `linkSystemLibrary` call that does not say
otherwise runs `pkg-config` first. A foreign cross row without `pkg-config`
installed falls back to plain `-lNAME` and may link the wrong one. For a
deliberate choice, say so:

```zig
mod.linkSystemLibrary("freetype", .{ .use_pkg_config = .no });
```

as `pcre2/build.zig:1416-1419` does, and `pcre2/build.zig:732-736` explains why
`preferred_link_mode` must be stated too.

### 9.14 `b.dependency` against a lazy dependency panics

```
dependency '{s}{s}' is marked as lazy in build.zig.zon which means it must use the lazyDependency function instead
```

`std/Build.zig:2064`. The pin in `build.zig.zon` is a tarball, not a lazy
entry, so `b.dependency` is correct today. A future lazy pin changes the call.

### 9.15 `b.addTest` is named `test` by default

`TestOptions.name` defaults to `"test"` (`std/Build.zig:859`), and
`addRunArtifact` shortens the run step name only for that exact name
(`std/Build.zig:942-945`). Two shards with the default name produce two
identical step names. Every shard in the skeleton passes an explicit
`.name`.

### 9.16 `zig` on this host is an anyzig shim

```
$ zig version
no build.zig to pull a zig version from, you can:
  1. run 'zig VERSION' to specify a version
  2. run from a directory where a build.zig can be found
```

`[OBSERVED: ~/.local/bin/zig version, run from a
directory with no build.zig]`. The working spelling is
`zig 0.16.0 <command>` `[OBSERVED: zig 0.16.0 version → 0.16.0]`. This is why
`build.zig.zon:8-11` calls `.minimum_zig_version` the single version authority
for the project and for every tool in the gate.

### 9.17 `.fingerprint` must match the package name

```
build.zig.zon:1:2: error: invalid fingerprint: 0x58b0780e6fe20fa5; if this is a new or forked package, use this value: 0xc1b929b4e184bcc4
```

`[OBSERVED: four probe packages]`. The value is derived from `.name`. It is
already correct in `build.zig.zon:7`; do not regenerate it.

### 9.18 The local cache is outside the build tree by default

With no `--cache-dir`, `zig build` writes to the global cache root's sibling
`zig-local`, not to the project's `.zig-cache`
`[OBSERVED: the failed build command showed --cache-dir /tmp/cache/zig-local]`.
The house sets it explicitly: `zaccesskit/.zig-cache` is a symlink into
`/tmp/cache/zaccesskit/build`. `cross-test` passes
`--cache-dir` of its own (`cross-test:389`) and refuses `-Dtarget`, `-j` and
`--test-timeout` (`zig-gate:696-697`).

### 9.19 `Module.pic = false` is not "let the driver decide"

`CreateOptions.pic` is `?bool` (`std/Build/Module.zig:252`). `null` emits no
flag; `false` emits `-fno-PIC`. `mpfr/build.zig:909-912` states the rule: pass
`true` on the shared route, leave it `null` on the static one, never `false`.

### 9.20 `linkLibrary` on a dynamic artifact poisons the RUNPATH

Covered in section 7.5. The symptom is `readelf -d` showing a `RUNPATH` that
names a build-cache directory, which no installed file may contain. The fix is
`addObjectFile` plus an explicit `addRPathSpecial`.

### 9.21 A relative `-L` becomes a relative RUNPATH

`-L` directories are copied into the linked binary's RUNPATH
(`std/Build/Step/Compile.zig:1195-1198`). A relative prefix therefore resolves
against the **child's** working directory, not against the build root.
`zautomerge/build.zig:562-573` records the exact failure: the link succeeds and
the process dies before `main` with
`libcmocka.so.0: cannot open shared object file`, exit 127. Resolve the prefix
with `b.pathFromRoot` before it reaches the module.

### 9.22 A custom test runner must be attached before `addRunArtifact`

`b.addRunArtifact` reads `test_runner` at configure time to choose the server
protocol or an exit code (`std/Build.zig:962-992`). A runner attached after
that call leaves a `Run` step waiting for a protocol the process never speaks.
`zautomerge/build.zig:866-871` explains it and attaches the runner in one
helper for every root.

### 9.23 `-fsys=<name>` must match the declared name exactly

`b.systemIntegrationOption(name, config)` (`std/Build.zig:2726`) records the
name in `b.graph.system_library_options`. The build runner parses `-fsys=` into
the same map (`lib/compiler/build_runner.zig:170-174`) and errors on a name it
never saw declared (`lib/compiler/build_runner.zig:1747-1750`). Verified:

```
$ zig build --help | grep -A1 "Available System Integrations"
  Available System Integrations:                Enabled:
    probe-x11                                   no
$ zig build --help -fsys=probe-x11 | grep -A1 "Available System Integrations"
  Available System Integrations:                Enabled:
    probe-x11                                   yes
```

`[OBSERVED: both, probe1]`. The port declares no system integration of its own, so no
profile or CI line carries a `-fsys=` name. A name, once declared, must match exactly.

### 9.24 Facilities that do not exist in 0.16.0

Stated plainly, because a plan that assumes one of them is wrong:

| Assumed facility | Reality |
|---|---|
| `b.linkLibC` / `b.linkLibCpp` | No definition anywhere in `lib/std`. Use `CreateOptions.link_libc`, the `Module.link_libc` field, or `linkSystemLibrary("c")`. |
| `std.Build.Step.Check` | Does not exist. `CheckFile` and `CheckObject`. |
| `ExecutableOptions.each_lib_rpath` | Compile error. `Step.Compile.each_lib_rpath` only. |
| A working `-femit-h` | Returns an error. `getEmittedH` is commented out upstream. |
| A working `-ffuzz` | Fails to compile `lib/compiler/test_runner.zig`. |
| `b.addOptions` producing `std_options` | It does not. `std_options` is a root-source-file declaration (`lib/std/std.zig:112`). |
| `-Dabi` | No such option. The ABI is the third triple field. |

### 9.25 `for (a, start..)` shifts the index capture only

`for (a, start..) |v, i|` moves `i` to `start` and leaves `v` at the front of
`a`, so `for (x, 1..) |b, i|` binds `b = x[0]` and never `x[1]`. A walk that
means to start at the tail slices it first: `for (x[1..], 1..) |b, i|`.

The failure is a wrong value and no trace. A check that compares each row with
the row before it compares each row with itself under the offset form, so it
passes until the one row where the two differ. `for (x, 0..)` is unaffected, so
the defect arrives only with the offset.

It bit `src/adapters/android/methods.zig`, where the sortedness check over the
68 Java method names compared each name with itself and stopped the package at
compile time. `MultiIndexForLoop` is absent from the 0.16.0 `lib/std` tree, so
the desugar is in the compiler and carries no `path:line` citation here. The
probe is the evidence. `zig 0.16.0 test probe.zig` against

```zig
const std = @import("std");

const names = [3][:0]const u8{ "add", "addAction", "addChild" };

test "probe" {
    for (names, 1..) |b, i| std.debug.print("i={d} b='{s}'\n", .{ i, b });
}
```

prints `i=1 b='add'`, `i=2 b='addAction'` and `i=3 b='addChild'`
`[OBSERVED: 0.16.0, three-element probe]`.

---

## 10. What the design wave still has to decide

This document fixes the build surface. Four decisions belong to
`docs/30-port-design.md` and `docs/40-plan.md`, not here.

1. **The fuzz blocker.** `-ffuzz` does not compile on 0.16.0 (9.7). Either the
   plan carries the blocker until the toolchain moves, or it schedules a
   vendored patch, or it accepts corpus replay only. It must not put a fuzz run
   under `test` in the meantime, because `zig build test` is a house gate.
2. **The C header's origin.** Checked in and installed with `installHeader`, or
   kept in step with the Zig exports by a `binding-check` step (section 8) plus
   `addCheckFile`. The skeleton does both; the plan decides which is a gate.
3. **The rung for X11/Wayland: closed, and it is no rung.** `docs/14-x11-wayland-surface.md`
   §1 proves the upstream adapter has no X11 or Wayland code, and §4 and §6.2 state that
   their cost statements are not proposals. So the port carries no `-lxcb`, and the
   `-fsys=zaccesskit-x11` scaffold once reserved here is deleted rather than kept as dead
   weight. A milestone that adds an X11 path reopens this item and declares the option
   again.
4. **The `std.Io` to goose question.** `local://zaccesskit-deps.md` leaves it
   open. It is a source question, but it decides whether `build.zig` needs a
   `std_options_debug_io` at all — and section 4.4 says the house answer is no.

## 11. Facilities that do not exist, restated for the reader in a hurry

Shortest possible version of section 9.24, with the substitution to use.

| You want | You write |
|---|---|
| link libc | `.link_libc = true` in `Module.CreateOptions` |
| link libc++ | `.link_libcpp = true` in `Module.CreateOptions` |
| compile C | `Module.addCSourceFiles` / `Module.addCSourceFile` |
| read a C header from Zig | `b.addTranslateC(…).createModule()`, then `Module.addImport` |
| build a value into Zig source | `b.addOptions()` + `Module.addOptions("build_options", …)` |
| name a dependency's module | `b.dependency(name, args).module(name)` |
| publish a module | `b.addModule(name, …)` |
| order two steps | `step.dependOn(other)` |
| set a soname | `LibraryOptions.version` |
| install a C header | `compile.installHeader(src, "name.h")` |
| mark a system integration | `b.systemIntegrationOption(name, .{ .default = … })` and pass `-fsys=name` |

