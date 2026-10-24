# zaccesskit

A Zig port of [AccessKit](https://github.com/AccessKit/accesskit), with an
accessibility tree, consumer queries, platform adapters, and a C interface.
Experimental; native platform coverage and licensing are incomplete.

## Requirements

- Zig 0.17.0.
- The package manager fetches pinned zio and zigwin32 dependencies.
- libc. Linux AT-SPI uses this project's D-Bus codec and needs a session
  accessibility bus at runtime, not libdbus development headers.
- macOS builds require an Apple SDK through `-Dmacos-sdk=/path/to/MacOSX.sdk`.
- Windows builds link UI Automation, User32, OleAut32, and Kernel32.
- Tests use Bash. Cross-target Linux execution needs QEMU user-mode runners.

The optional `devenv shell` supplies Git and pkg-config. Install Zig separately.
Use local-disk cache directories when the checkout is on a network filesystem.

## Build and test

```sh
zig build
zig build -Doptimize=ReleaseSafe -Dlinkage=dynamic
zig build test
zig build capi-parity
```

The default build installs `libzaccesskit` and `include/zaccesskit.h` under
`zig-out/`. Static linkage is the default. `test` runs Debug and ReleaseSafe
library, corpus replay, native-contract, benchmark, integration, and reference
tests, plus the linked C11 consumer on a native target.

Additional steps:

| Command | Purpose |
|---|---|
| `zig build test-c` | Run the linked C11 consumer. |
| `zig build integration-run` | Run the offline application scenario. |
| `zig build reference-run` | Check source-derived reference fixtures. |
| `zig build bench-build` | Compile the consumer benchmark. |
| `zig build bench -- --nodes 128 --work-units 2` | Run a small consumer benchmark. |
| `zig build native-atspi-probe` | Build the Linux AT-SPI probe. |
| `zig build native-atspi-probe-run` | Run the probe against the current Linux accessibility bus. |
| `zig build windows-native-client -Dtarget=x86_64-windows` | Build the Windows UI Automation client. |
| `zig build macos-native-client -Dtarget=aarch64-macos -Dmacos-sdk=/path/to/MacOSX.sdk` | Build the macOS selector client. |
| `zig build cross-test -Dtarget=aarch64-linux-musl -fqemu` | Run the library and C consumer through QEMU. |

The Windows and macOS client `-run` steps require their native OS. iOS and
Android adapters need host application integration; there is no device runner
in the build. Offline tests do not establish native accessibility runtime parity.
The `aarch64-ios` build is blocked by Zig 0.17's `std.Io.Threaded` referencing
the absent `NullFile.fd` field.
The PowerPC64 C consumer is unsupported: aggregate-return checks fail and the
linked consumer crashes. See [issue #5](https://github.com/CoffeeImpliesCode/zaccesskit/issues/5).

## Use from Zig or C

Add the package to your project with Zig's package manager:

```sh
zig fetch --save=zaccesskit git+https://github.com/CoffeeImpliesCode/zaccesskit
```

Import the module in your `build.zig`:

```zig
const accesskit = b.dependency("zaccesskit", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("zaccesskit", accesskit.module("zaccesskit"));
```

Use `@import("zaccesskit")` in Zig. For a C consumer, link the artifact instead:

```zig
exe.root_module.linkLibrary(accesskit.artifact("zaccesskit"));
```

Include `<zaccesskit.h>`. The artifact supplies the installed header. Pass
`.linkage = .dynamic` to the dependency options to select shared linkage.

## Layout

- `src/schema/`: roles, properties, geometry, actions, and tree updates.
- `src/consumer/`: materialized trees, queries, text navigation, and updates.
- `src/capi/` and `include/`: C implementation and public header.
- `src/adapters/`: AT-SPI, Windows, macOS, iOS, and Android integration.
- `test/`: C consumer, application scenarios, fixtures, and fuzz corpora.
- `tools/`: benchmarks, C declaration checks, and native platform clients.

## Licence and provenance

No licence has been chosen for port-authored code. The distribution licence
bundle is incomplete. See [licensing and provenance](docs/21-licensing.md).
AccessKit-authored material is MIT OR Apache-2.0; Chromium- and Flutter-derived
material carries additional BSD-style notices. This project is independent of
AccessKit and does not claim endorsement by its authors or platform vendors.
