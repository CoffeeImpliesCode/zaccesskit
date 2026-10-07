//! The module root for the harness under `test/fuzz/`.
//!
//! **Why this file sits at the repository root.** A module's package root is
//! the directory that holds its root source file, and a file may only reach a
//! path under that root. `test/fuzz/abi.zig` embeds `include/zaccesskit.h` and
//! the four harness files import `src/` through `../../src/`, so a module
//! rooted at `test/fuzz/property_table.zig` reports `import of file outside
//! module path` for every one of them. The package root has to be the
//! repository root, and the only way to get it is a root source file that is a
//! direct child of the repository root.
//! `[OBSERVED: zig 0.16.0 test test/fuzz/property_table.zig, every @import of
//! ../../src reported as outside the module path]`
//!
//! **What the reference does.** `zig test` collects the `test` blocks of every
//! file the compilation analyses, so importing the harness here is enough for
//! its tests, and the tests of `test/fuzz/random.zig` beside it, to run. The
//! count is larger than the harness alone, because the harness imports
//! `src/schema/` and `src/consumer/` and those files carry tests of their own.
//! `[OBSERVED: zig 0.16.0 test fuzz_root.zig, "All 351 tests passed.",
//! "1 fuzz tests found.", Debug and ReleaseSafe]`
//!
//! **What `build.zig` builds.** Two `addTest` calls rooted here, one Debug and
//! one ReleaseSafe, both on the `test` step and both on the `fuzz` step, so the
//! house gate runs the corpus replay. See `build.zig` for the reason the step
//! is not built from `-ffuzz`.

test {
    _ = @import("test/fuzz/property_table.zig");
}
