//! The JNI entry points, handle types and scalars the Android adapter reaches.
//!
//! `docs/42-native-adapter-build-map.md` section 1.4.4 counts 13 `JNIEnv`
//! methods, 6 handle types and 4 scalar types, and
//! `docs/29-apple-android-apis.md` section 3.2 rows 9 to 23 lists 15 rows
//! across `JNIEnv` and `JavaVM`. The two agree: rows 9 to 20 plus row 22 are
//! the 13 `JNIEnv` methods, and rows 21 and 23 are the 2 `JavaVM` methods the
//! map places outside the 13.
//!
//! **This module names the surface; it does not bind it.** Map section 2.4
//! records that `jni.h` is plain C and that `translate-c` parses it, but the
//! run was against a desktop JDK 7 header, not the Android NDK, and no NDK is
//! installed on this host. The declarations themselves are therefore rung 3
//! and belong to `build.zig` at milestone M10. What this module fixes now is
//! the part a compiler can never check: the spelling of an entry point, the
//! spelling of a handle type and the width of a scalar.
//!
//! **The two JavaVM methods are here and are not part of the 13.**
//! `AK/android/src/inject.rs:422` is the only place in the four adapters where
//! a thread attaches to a runtime and posts work to another thread.
//!
//! **The loop bound.** Every loop over `jni_env_methods` or
//! `java_vm_methods` walks an array whose length is a comptime constant.

const std = @import("std");

const testing = std.testing;

/// How many `JNIEnv` methods the map counts.
pub const jni_env_method_count = 13;

/// The 13 `JNIEnv` methods the Android adapter reaches, in `docs/29` row order.
///
/// These are the names the Rust `jni` crate exposes, so a Zig port either
/// binds the same 13 C functions or calls the equivalent one. The spelling
/// here is the crate's, not `jni.h`'s, and `entry_points` gives the C spelling
/// of the ones that have a distinct C name.
pub const jni_env_methods = [jni_env_method_count][:0]const u8{
    "call_method",
    "call_static_method",
    "find_class",
    "new_string",
    "new_global_ref",
    "new_weak_ref",
    "new_object",
    "new_int_array",
    "new_direct_byte_buffer",
    "get_int_array_region",
    "is_instance_of",
    "with_local_frame",
    "register_native_methods",
};

/// How many `JavaVM` methods the adapter reaches, outside the 13.
pub const java_vm_method_count = 2;

/// The 2 `JavaVM` methods, at `AK/android/src/inject.rs:422`.
pub const java_vm_methods = [java_vm_method_count][:0]const u8{
    "get_java_vm",
    "attach_current_thread",
};

/// How many handle types the map counts.
pub const handle_type_count = 6;

/// The 6 handle types, as the Rust `jni` crate spells them.
///
/// `JNIEnv` is the per-thread environment and the other five are the handles
/// that cross it.
pub const handle_types = [handle_type_count][:0]const u8{
    "JNIEnv",
    "JObject",
    "JClass",
    "GlobalRef",
    "WeakRef",
    "JavaVM",
};

/// How many scalar types the map counts.
pub const scalar_type_count = 4;

/// The 4 scalar types, with the number of uses the map records for each.
///
/// `docs/42` section 1.4.4 counts `jint` 145 times, `jfloat` 15, `jlong` 10
/// and `jboolean` 3. The counts are the map's, not this module's; they are here
/// because a port that gets one width wrong mis-marshals every argument.
pub const scalar_types = [scalar_type_count]struct {
    name: [:0]const u8,
    zig: type,
    upstream_uses: usize,
}{
    .{ .name = "jint", .zig = i32, .upstream_uses = 145 },
    .{ .name = "jfloat", .zig = f32, .upstream_uses = 15 },
    .{ .name = "jlong", .zig = i64, .upstream_uses = 10 },
    .{ .name = "jboolean", .zig = u8, .upstream_uses = 3 },
};

/// `JNI_TRUE`, the value a `jboolean` result carries on success.
///
/// **`jni.h` defines this and no document under `docs/` records its value.**
/// **Unverified**: no JDK or NDK header was read on this host.
pub const jni_true: u8 = 1;

/// `JNI_FALSE`, the value a `jboolean` result carries on failure.
///
/// **`jni.h` defines this and no document under `docs/` records its value.**
/// **Unverified**: no JDK or NDK header was read on this host.
pub const jni_false: u8 = 0;

/// `LOCAL_FRAME_CAPACITY`, the local reference budget for one UI-thread hop.
///
/// `AK/android/src/inject.rs:99` gives the value and
/// `docs/29-apple-android-apis.md` row 51 confirms it. Map section 5.3.2 calls
/// this the one constant a port copies verbatim: the frame has to hold the
/// upgraded host view and the runnable, and JNI caps local references per
/// frame.
pub const local_frame_capacity: i32 = 2;

comptime {
    assertDistinct(jni_env_methods);
    assertDistinct(java_vm_methods);
    assertDistinct(handle_types);
    if (jni_env_methods.len != jni_env_method_count) @compileError("the 13 must be 13");
    if (java_vm_methods.len != java_vm_method_count) @compileError("the 2 must be 2");
    if (handle_types.len != handle_type_count) @compileError("the 6 must be 6");
    if (scalar_types.len != scalar_type_count) @compileError("the 4 must be 4");
    // The 13 `JNIEnv` methods and the 2 `JavaVM` methods share one name space
    // in the table, so `get_java_vm` must not also appear among the 13.
    for (jni_env_methods) |a| {
        for (java_vm_methods) |b| {
            if (std.mem.eql(u8, a, b)) @compileError("a JavaVM method is in the 13");
        }
    }
    var uses: usize = 0;
    for (scalar_types) |scalar| uses += scalar.upstream_uses;
    if (uses != 173) @compileError("the map counts 173 scalar uses across the 4 types");
}

/// Fails the build when `table` holds one spelling twice. The walk compares
/// each row with the rows after it, so the bound is the array length squared.
fn assertDistinct(comptime table: anytype) void {
    for (table, 0..) |a, i| {
        for (table[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate name at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
}

/// Whether `name` is one of the 13 `JNIEnv` methods.
pub fn isJniEnvMethod(name: []const u8) bool {
    for (jni_env_methods) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

/// Whether `name` is one of the 6 handle types.
pub fn isHandleType(name: []const u8) bool {
    for (handle_types) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

test "the table holds the 13 JNIEnv methods the map counts" {
    try testing.expectEqual(@as(usize, 13), jni_env_methods.len);
    for ([_][]const u8{
        "call_method",
        "call_static_method",
        "find_class",
        "new_string",
        "new_global_ref",
        "new_weak_ref",
        "new_object",
        "new_int_array",
        "new_direct_byte_buffer",
        "get_int_array_region",
        "is_instance_of",
        "with_local_frame",
        "register_native_methods",
    }) |name| {
        try testing.expect(isJniEnvMethod(name));
    }
    try testing.expect(!isJniEnvMethod("attach_current_thread"));
}

test "the two JavaVM methods sit outside the 13" {
    try testing.expectEqual(@as(usize, 2), java_vm_methods.len);
    try testing.expect(std.mem.eql(u8, java_vm_methods[0], "get_java_vm"));
    try testing.expect(std.mem.eql(u8, java_vm_methods[1], "attach_current_thread"));
    try testing.expect(!isJniEnvMethod("get_java_vm"));
}

test "the table holds the 6 handle types the map counts" {
    try testing.expectEqual(@as(usize, 6), handle_types.len);
    for ([_][]const u8{
        "JNIEnv",
        "JObject",
        "JClass",
        "GlobalRef",
        "WeakRef",
        "JavaVM",
    }) |name| {
        try testing.expect(isHandleType(name));
    }
    try testing.expect(!isHandleType("JString"));
}

test "the four scalar types carry the widths the map counts" {
    try testing.expectEqual(@as(usize, 4), scalar_types.len);
    try testing.expectEqualStrings("jint", scalar_types[0].name);
    try testing.expectEqual(i32, scalar_types[0].zig);
    try testing.expectEqual(@as(usize, 145), scalar_types[0].upstream_uses);
    try testing.expectEqualStrings("jfloat", scalar_types[1].name);
    try testing.expectEqual(f32, scalar_types[1].zig);
    try testing.expectEqualStrings("jlong", scalar_types[2].name);
    try testing.expectEqual(i64, scalar_types[2].zig);
    try testing.expectEqualStrings("jboolean", scalar_types[3].name);
    try testing.expectEqual(u8, scalar_types[3].zig);
    try testing.expectEqual(@as(i32, 2), local_frame_capacity);
    try testing.expect(jni_true != jni_false);
}