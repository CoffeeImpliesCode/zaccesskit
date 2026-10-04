//! The JNI boundary surface of the Android adapter, for milestone M10.
//!
//! Upstream is `accesskit_android` 0.9.0, 2604 lines across the eight files
//! under `AK/android/src/`, plus 70 lines of Java at
//! `AK/android/java/dev/accesskit/android/Delegate.java`. This directory holds
//! the four modules that carry the strings and numbers the adapter sends across
//! the boundary, and nothing else: the handle maps, the thread handoff, the
//! node fill loop and the adapter body land in later milestones.
//!
//! | Module | Upstream | Holds |
//! |---|---|---|
//! | `constants.zig` | `AK/android/src/util.rs:14-68` | the 43 Android SDK constant names and `HOST_VIEW_ID` |
//! | `classes.zig` | throughout | the 20 class descriptors of map section 1.4.3, plus the delegate class |
//! | `methods.zig` | the eight files | the 68 Java method names and the 27 method lookups |
//! | `jni.zig` | `AK/android/src/inject.rs:14-23`, `:99` | 13 `JNIEnv` methods, 2 `JavaVM` methods, 6 handle types, 4 scalar types, the local frame capacity |
//!
//! **The verification split, as map sections 3.1 to 3.4 state it.** Level 1 is
//! that the source type-checks and generates code for its target. Level 2 is
//! that the object links against the real system libraries. Level 3 is that the
//! adapter works against a live assistive technology. This host reaches level 1
//! for Android and no further: `zig build-exe -target aarch64-linux-android`
//! fails at `-llog` because no NDK sysroot is installed here. Every name and
//! every descriptor in this directory is a string to the Zig compiler, so a
//! misspelt one passes level 1 and fails at `GetMethodID` on a device. That is
//! why each is pinned by a test that asserts its exact spelling.
//!
//! **What this directory does not do.** It does not bind `jni.h`. Map section
//! 2.4 records that `translate-c` parses a JNI header, but the run was against
//! a desktop JDK 7 header rather than the NDK header the port needs, so the
//! declarations are rung 3 work for `build.zig`. It also does not ship the Java
//! class: map section 5.3.1 records that the 70 lines of `Delegate.java` are a
//! build input the port must carry, and that both the Java file and, for the
//! `embedded-dex` mode, a prebuilt `classes.dex` need a licence and placement
//! decision that `docs/40-plan.md` M10 owns.
//!
//! **What it deliberately does not carry.** `AK/android/src/inject.rs:88-105`
//! declares four file-scope statics. Map section 5.3.2 is explicit that a Zig
//! port threads that state instead, so no handle map and no counter appear
//! here. The counter, the map and the closure become fields of the adapter
//! struct, and the two `BTreeMap` declarations become insertion-ordered
//! collections so iteration stays deterministic.
//!
//! Nothing here allocates, takes an allocator, reaches a clock or holds state.
//!
//! **The adapter body.** `node_id_map.zig` holds the two-way map, `node.zig`
//! the node fill, `platform_action.zig` the action object, `queued_events.zig`
//! the event queue, `adapter.zig` the plain adapter and `injecting.zig` the one
//! that installs itself on a host view. `root.zig` owns the four handle types
//! and the thirteen entry points `src/capi/platform.zig` calls.

const std = @import("std");

const testing = std.testing;

pub const classes = @import("classes.zig");
pub const constants = @import("constants.zig");
pub const jni = @import("jni.zig");
pub const methods = @import("methods.zig");
pub const jni_table = @import("jni_table.zig");
pub const node_id_map = @import("node_id_map.zig");
pub const node = @import("node.zig");
pub const values = @import("values.zig");
pub const platform_action = @import("platform_action.zig");
pub const queued_events = @import("queued_events.zig");
pub const adapter = @import("adapter.zig");
pub const injecting = @import("injecting.zig");

comptime {
    // Map section 1.4.5 totals.
    if (constants.constant_count != 43) @compileError("the map gives 43 integer constants");
    if (methods.method_name_count != 68) @compileError("the map gives 68 method names");
    if (classes.descriptor_count != 20) @compileError("the map's table lists 20 descriptors");
    if (jni.jni_env_method_count != 13) @compileError("the map gives 13 JNIEnv entry points");
    if (jni.handle_type_count + jni.scalar_type_count != 10) {
        @compileError("the map gives 10 handle and scalar types");
    }
    if (methods.method_name_count - methods.pinned_signature_count !=
        methods.unpinned_name_count)
    {
        @compileError("the unpinned count must be 68 minus 22");
    }
}

test "the four modules of the JNI boundary are reachable" {
    testing.refAllDecls(constants);
    testing.refAllDecls(classes);
    testing.refAllDecls(methods);
    testing.refAllDecls(jni);
}

test "the Android census holds the figures the map measured" {
    try testing.expectEqual(@as(usize, 43), constants.constant_count);
    try testing.expectEqual(@as(usize, 68), methods.method_name_count);
    try testing.expectEqual(@as(usize, 20), classes.descriptor_count);
    try testing.expectEqual(@as(usize, 19), classes.map_descriptor_count);
    try testing.expectEqual(@as(usize, 13), jni.jni_env_method_count);
    try testing.expectEqual(@as(usize, 5), registeredNativeCount());
}

test "22 of the 68 method names have a lookup row and 46 do not" {
    // The walk is over the 68 rows of `methods.method_names`, so the bound is
    // `methods.method_name_count`.
    var covered: usize = 0;
    for (methods.method_names) |name| {
        if (methods.findByName(name) != null) covered += 1;
    }
    try testing.expectEqual(methods.pinned_name_count, covered);
    try testing.expectEqual(@as(usize, 22), covered);
    try testing.expectEqual(methods.unpinned_name_count, methods.method_name_count - covered);
}

/// How many of the 27 lookup rows are registered native methods. The walk is
/// over the 27 rows, so the bound is `methods.method_id_count`.
fn registeredNativeCount() usize {
    var total: usize = 0;
    for (methods.method_ids) |row| {
        if (row.kind == .registered_native) total += 1;
    }
    return total;
}