//! The Objective-C runtime surface, the four weakly linked UIKit constants and
//! the one notification centre the iOS adapter reaches.
//!
//! `docs/42-native-adapter-build-map.md` section 1.3.4 counts 17 items under
//! "Runtime, UIKit and Foundation": 4 Objective-C runtime functions, 1
//! association policy, 1 notification centre, 3 UIKit classes and 8 Foundation
//! types. `foundation.zig` holds the last 11; this module holds the first 6 and
//! the 4 weakly linked names of section 1.3.2.
//!
//! **The linkage route.** `AK/ios/src/util.rs:71-75` writes its own `dlsym`
//! declaration and defines `RTLD_DEFAULT` as `-2isize`. Map section 2.3 says a
//! Zig port deletes both and uses `std.DynLib`. That is what
//! `resolveInImage` does, with one difference this module states rather than
//! hides: Zig 0.16.0 `std.DynLib.open` takes a library path and has no
//! null-path form, so the caller hands in the UIKit image instead. The four
//! names are constants of that image, so one handle resolves all four.
//!
//! **What is a fact and what is not.** `docs/29` rows 49 to 51 give the
//! signature of three of the four runtime functions. `class_addMethod` has no
//! signature in any document under `docs/`, so the one below is taken from
//! `objc/runtime.h` and is **unverified**. `OBJC_ASSOCIATION_RETAIN_NONATOMIC`
//! is named by the map and given no value, so the value below is the one
//! `objc/runtime.h` derives as `(1 << OBJC_ASSOCIATION_RETAIN) <<
//! OBJC_ASSOCIATION_ASSIGN`, which is `(1 << 3) << 0`, and is **unverified**.
//! No Apple SDK is installed on this host, so neither header was read.
//!
//! **The loop bound.** `weak_constants` has 4 rows and `runtime_functions` has
//! 4, so every loop over either is bounded by an array length.

const std = @import("std");

const uikit = @import("uikit.zig");

const testing = std.testing;

/// An Objective-C class pointer.
pub const ObjClass = opaque {};

/// Any Objective-C object pointer.
pub const AnyObject = opaque {};

/// An Objective-C selector, which the runtime interns from a name.
pub const Sel = opaque {};

/// An Objective-C method implementation.
///
/// `objc/runtime.h` declares this as `id (*IMP)(id, SEL, ...)`, and a Zig
/// function type cannot spell the variadic tail, so the port carries the fixed
/// part only and passes the pointer through. **Unverified**: no Apple SDK is
/// installed on this host, so `objc/runtime.h` was not read.
pub const Imp = *const fn () callconv(.c) ?*anyopaque;

/// The four `objc2::ffi` entry points the iOS adapter calls.
pub const runtime_function_count = 4;

/// The exact spelling of one Objective-C runtime entry point.
pub const runtime_functions = [runtime_function_count][:0]const u8{
    "class_addMethod",
    "objc_getAssociatedObject",
    "objc_setAssociatedObject",
    "object_setClass",
};

/// The signature `docs/29` rows 49 to 51 record for
/// `objc_getAssociatedObject`.
pub const ObjCGetAssociatedObjectFn = fn (?*AnyObject, ?*const anyopaque) ?*AnyObject;

/// The signature `docs/29` row 50 records for `objc_setAssociatedObject`.
///
/// The fourth parameter is an association policy; the adapter always passes
/// `association_policy_retain_nonatomic`.
pub const ObjCSetAssociatedObjectFn = fn (
    object: ?*AnyObject,
    key: ?*const anyopaque,
    value: ?*AnyObject,
    policy: u64,
) void;

/// The signature `objc/runtime.h` declares for `object_setClass`.
///
/// `docs/29` row 51 records the two parameters and omits the return type; the
/// header returns `id`. **Unverified**: no Apple SDK is installed on this
/// host, so `objc/runtime.h` was not read.
pub const ObjectSetClassFn = fn (?*AnyObject, ?*const ObjClass) ?*AnyObject;

/// The signature `objc/runtime.h` declares for `class_addMethod`.
///
/// No document under `docs/` records this signature.
/// **Unverified**: no Apple SDK is installed on this host, so
/// `objc/runtime.h` was not read.
pub const ClassAddMethodFn = fn (
    class: ?*ObjClass,
    name: ?*Sel,
    implementation: ?*Imp,
    types: ?[*:0]const u8,
) bool;

/// `OBJC_ASSOCIATION_RETAIN_NONATOMIC`, the only association policy the
/// adapter uses.
///
/// The map names it and records no value. `objc/runtime.h` defines it as
/// `(1 << OBJC_ASSOCIATION_RETAIN) << OBJC_ASSOCIATION_ASSIGN`, which is
/// `(1 << 3) << 0`. **Unverified**: no Apple SDK is installed on this host, so
/// `objc/runtime.h` was not read.
pub const association_policy_retain_nonatomic: u64 = (1 << 3) << 0;

/// `NSNotificationCenter`, the one class of the 17 the adapter names by class.
///
/// The observer registered at `AK/ios/src/adapter.rs:373` is the only
/// notification observer in the whole upstream tree, and it is removed in the
/// adapter's drop at `:511`.
pub const notification_centre_name: [:0]const u8 = "NSNotificationCenter";

/// What the adapter does when a weakly linked constant is absent.
pub const Fallback = enum {
    /// The trait bit is zero, so the node reports no toggle trait. This is the
    /// fallback for `UIAccessibilityTraitToggleButton` at
    /// `AK/ios/src/util.rs:77-87`.
    no_trait,
    /// The announcement carries no priority, which downgrades it. This is the
    /// fallback for both priority constants at `AK/ios/src/util.rs:100-106`.
    downgrade_announcement,
    /// The announcement is a plain string with no attributed key. This is the
    /// fallback at `AK/ios/src/util.rs:108-110`.
    plain_string_announcement,
};

/// One constant the adapter reads at run time rather than links.
///
/// `UIAccessibilityTraitToggleButton` is also a linked trait constant in
/// `uikit.identifiers`, which counts it once under `.trait`; the `comptime`
/// block below checks that it is in both places.
pub const WeakConstant = struct {
    /// The exact spelling passed to the symbol lookup.
    name: [:0]const u8,
    /// What the adapter does when the image does not export `name`.
    fallback: Fallback,
    /// The upstream line the fallback comes from, kept as text so a reader can
    /// find it without a second document.
    upstream_range: [:0]const u8,
};

/// How many rows `weak_constants` holds.
pub const weak_constant_count = 4;

/// The four constants `AK/ios/src/util.rs:71-110` reads with `dlsym`.
pub const weak_constants = [weak_constant_count]WeakConstant{
    .{
        .name = "UIAccessibilityTraitToggleButton",
        .fallback = .no_trait,
        .upstream_range = "AK/ios/src/util.rs:77-87",
    },
    .{
        .name = "UIAccessibilityPriorityHigh",
        .fallback = .downgrade_announcement,
        .upstream_range = "AK/ios/src/util.rs:100-102",
    },
    .{
        .name = "UIAccessibilityPriorityLow",
        .fallback = .downgrade_announcement,
        .upstream_range = "AK/ios/src/util.rs:104-106",
    },
    .{
        .name = "UIAccessibilitySpeechAttributeAnnouncementPriority",
        .fallback = .plain_string_announcement,
        .upstream_range = "AK/ios/src/util.rs:108-110",
    },
};

/// Why a weakly linked constant could not be read.
pub const ResolveError = error{
    /// The image could not be opened. The caller falls back for every one of
    /// the four constants, so the adapter stays in its pre-iOS-17 shape.
    ImageUnavailable,
};

comptime {
    @setEvalBranchQuota(200_000);
    for (runtime_functions, 0..) |a, i| {
        for (runtime_functions[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a, b)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate runtime entry point at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a },
                ));
            }
        }
    }
    for (weak_constants, 0..) |a, i| {
        for (weak_constants[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate weak constant at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.name },
                ));
            }
        }
    }
    // The map puts `UIAccessibilityTraitToggleButton` in two groups: a named
    // trait constant and the fourth `dlsym` name. Check both halves.
    const toggle = uikit.find("UIAccessibilityTraitToggleButton");
    if (toggle == null or toggle.?.kind != .trait) {
        @compileError("uikit.identifiers must hold the toggle trait under .trait");
    }
    var weak_toggle: usize = 0;
    for (weak_constants) |weak| {
        if (std.mem.eql(u8, weak.name, "UIAccessibilityTraitToggleButton")) weak_toggle += 1;
    }
    if (weak_toggle != 1) @compileError("the toggle trait must be one weak constant");
    // The other three weak names are the three `uikit` records whose kind is
    // `.weak_link_only`, so the two tables must agree on all four.
    var shared: usize = 0;
    for (weak_constants) |weak| {
        for (uikit.identifiers) |identifier| {
            if (std.mem.eql(u8, identifier.name, weak.name)) shared += 1;
        }
    }
    if (shared != weak_constant_count) @compileError("the two tables must share all four names");
}

/// Resolves one weakly linked UIKit constant in `image_path`.
///
/// Returns `null` when the image opens but does not export `name`, which is the
/// case on an operating system older than the one that introduced it. The
/// caller applies the `Fallback` of the matching `weak_constants` row.
///
/// The returned pointer is owned by the image and is never released. The
/// handle is closed before this function returns, so a caller that needs a
/// value must copy it before then.
pub fn resolveInImage(
    comptime T: type,
    image_path: []const u8,
    name: [:0]const u8,
) ResolveError!?T {
    var image = std.DynLib.open(image_path) catch return error.ImageUnavailable;
    defer image.close();
    return image.lookup(T, name);
}

/// The weakly linked constant spelled `name`, or `null` when the table holds no
/// such spelling.
pub fn weakConstant(name: []const u8) ?WeakConstant {
    for (weak_constants) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

test "the table holds the four Objective-C runtime entry points" {
    try testing.expectEqual(@as(usize, 4), runtime_functions.len);
    for ([_][]const u8{
        "class_addMethod",
        "objc_getAssociatedObject",
        "objc_setAssociatedObject",
        "object_setClass",
    }) |name| {
        var found = false;
        for (runtime_functions) |candidate| {
            if (std.mem.eql(u8, candidate, name)) found = true;
        }
        try testing.expect(found);
    }
}

test "every weakly linked name is spelled as the map spells it" {
    try testing.expectEqual(@as(usize, 4), weak_constants.len);
    try testing.expectEqualStrings(
        "UIAccessibilityTraitToggleButton",
        weak_constants[0].name,
    );
    try testing.expectEqual(Fallback.no_trait, weak_constants[0].fallback);
    try testing.expectEqualStrings("UIAccessibilityPriorityHigh", weak_constants[1].name);
    try testing.expectEqual(Fallback.downgrade_announcement, weak_constants[1].fallback);
    try testing.expectEqualStrings("UIAccessibilityPriorityLow", weak_constants[2].name);
    try testing.expectEqual(Fallback.downgrade_announcement, weak_constants[2].fallback);
    try testing.expectEqualStrings(
        "UIAccessibilitySpeechAttributeAnnouncementPriority",
        weak_constants[3].name,
    );
    try testing.expectEqual(Fallback.plain_string_announcement, weak_constants[3].fallback);
}

test "the toggle trait is both a named trait constant and a weak constant" {
    const identifier = uikit.find("UIAccessibilityTraitToggleButton");
    try testing.expect(identifier != null);
    try testing.expectEqual(uikit.Kind.trait, identifier.?.kind);
    try testing.expect(weakConstant("UIAccessibilityTraitToggleButton") != null);
}

test "the three weak-only names are the three uikit records of that kind" {
    var checked: usize = 0;
    for (uikit.identifiers) |identifier| {
        if (identifier.kind != .weak_link_only) continue;
        try testing.expect(weakConstant(identifier.name) != null);
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 3), checked);
}

test "the association policy is the value the header derives" {
    try testing.expectEqual(@as(u64, 8), association_policy_retain_nonatomic);
}

test "the notification centre is the one the adapter registers with" {
    try testing.expectEqualStrings("NSNotificationCenter", notification_centre_name);
    try testing.expectEqual(@as(?WeakConstant, null), weakConstant("NoSuchConstant"));
}
