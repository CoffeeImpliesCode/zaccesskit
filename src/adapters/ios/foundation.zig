//! The 8 Foundation types and the 3 UIKit class names the iOS adapter names.
//!
//! `docs/42-native-adapter-build-map.md` section 1.3.4 counts 17 items under
//! "Runtime, UIKit and Foundation": 4 Objective-C runtime functions, 1
//! association policy, 1 notification centre, 3 UIKit classes and 8 Foundation
//! types. This module holds the last 11, and `runtime.zig` holds the first 6.
//!
//! The 11 are declared twice over. `platform_names` pins the exact spelling of
//! each, which is what a test can check, and the Zig declarations below give
//! the adapter something to name in a signature.
//!
//! **What is a fact and what is not.** The map names the 11 types and records
//! no layout for any of them. `CGFloat`, `CGPoint`, `CGSize` and `CGRect` are
//! declared here from `CGGeometry.h`, which CoreGraphics defines with a
//! double-precision scalar on every 64-bit target, and `NSInteger` is declared
//! as the pointer-sized integer Foundation defines it to be. No document under
//! `docs/` records either layout and no Apple SDK is installed on this host, so
//! **all of them are unverified**. The remaining seven types are Objective-C
//! objects with an opaque handle, which is exactly what the map says they are
//! and what the adapter needs to name them.
//!
//! **The loop bound.** Every loop over `platform_names` walks the array, whose
//! length is `platform_name_count` and is a type-level fact.

const std = @import("std");

const testing = std.testing;

/// What kind of platform name one entry of `platform_names` carries.
pub const PlatformKind = enum {
    /// A class the adapter looks up with the Objective-C runtime.
    uikit_class,
    /// A Foundation type the adapter names in a signature.
    foundation_type,
};

/// One platform name, as the exact spelling the adapter writes.
pub const PlatformName = struct {
    kind: PlatformKind,
    name: [:0]const u8,
};

/// How many names `platform_names` holds.
///
/// Three UIKit classes and eight Foundation types, which is 11 of the 17 items
/// in the map's section 1.3.4.
pub const platform_name_count = 11;

/// The 3 UIKit classes and the 8 Foundation types the iOS adapter names.
pub const platform_names = [platform_name_count]PlatformName{
    // 3 UIKit classes.
    .{ .kind = .uikit_class, .name = "UIView" },
    .{ .kind = .uikit_class, .name = "UIWindow" },
    .{ .kind = .uikit_class, .name = "UICoordinateSpace" },
    // 8 Foundation types.
    .{ .kind = .foundation_type, .name = "CGPoint" },
    .{ .kind = .foundation_type, .name = "CGRect" },
    .{ .kind = .foundation_type, .name = "CGSize" },
    .{ .kind = .foundation_type, .name = "NSArray" },
    .{ .kind = .foundation_type, .name = "NSAttributedStringKey" },
    .{ .kind = .foundation_type, .name = "NSInteger" },
    .{ .kind = .foundation_type, .name = "NSObject" },
    .{ .kind = .foundation_type, .name = "NSString" },
};

comptime {
    for (platform_names, 0..) |a, i| {
        for (platform_names[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate spelling at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.name },
                ));
            }
        }
    }
    if (countOfKind(.uikit_class) != 3) @compileError("the map gives 3 UIKit classes");
    if (countOfKind(.foundation_type) != 8) @compileError("the map gives 8 Foundation types");
}

/// The platform name spelled `name`, or `null` when the table holds no such
/// spelling.
pub fn find(name: []const u8) ?PlatformName {
    for (platform_names) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

/// How many names the table holds for `kind`.
pub fn countOfKind(kind: PlatformKind) usize {
    var total: usize = 0;
    for (platform_names) |candidate| {
        if (candidate.kind == kind) total += 1;
    }
    return total;
}

/// `CGFloat`, the scalar CoreGraphics measures with.
///
/// `CGGeometry.h` defines this as `double` on every 64-bit target, and this
/// port builds 64-bit targets only. **Unverified**: no Apple SDK is installed
/// on this host, so `CGGeometry.h` was not read.
pub const CGFloat = f64;

/// `CGPoint`, a location in a coordinate space.
///
/// Declared from `CGGeometry.h`. **Unverified**: no Apple SDK is installed on
/// this host, so `CGGeometry.h` was not read.
pub const CGPoint = extern struct {
    x: CGFloat,
    y: CGFloat,
};

/// `CGSize`, a width and a height.
///
/// Declared from `CGGeometry.h`. **Unverified**: no Apple SDK is installed on
/// this host, so `CGGeometry.h` was not read.
pub const CGSize = extern struct {
    width: CGFloat,
    height: CGFloat,
};

/// `CGRect`, a rectangle given as an origin and a size.
///
/// `AK/ios/src/util.rs:46-48` passes one to
/// `UIAccessibilityConvertFrameToScreenCoordinates`. Declared from
/// `CGGeometry.h`. **Unverified**: no Apple SDK is installed on this host, so
/// `CGGeometry.h` was not read.
pub const CGRect = extern struct {
    origin: CGPoint,
    size: CGSize,
};

/// `NSInteger`, the integer Foundation declares as pointer-sized.
///
/// `AK/ios/src/util.rs` hands one to `UIAccessibilityPostNotification` for the
/// indexed arguments. **Unverified**: no Apple SDK is installed on this host,
/// so `NSObjCRuntime.h` was not read.
pub const NSInteger = isize;

/// `NSObject`, the root Objective-C class.
///
/// Every Foundation object is one. **Unverified**: no Apple SDK is installed
/// on this host, so `NSObject.h` was not read.
pub const NSObject = opaque {};

/// `NSString`, the Foundation string.
///
/// `AK/ios/src/node.rs:238-294` returns one for the label, the hint, the value
/// and the language. **Unverified**: no Apple SDK is installed on this host, so
/// `NSString.h` was not read.
pub const NSString = opaque {};

/// `NSArray`, the Foundation array.
///
/// `AK/ios/src/node.rs:393-394` returns one for `accessibilityElements`.
/// **Unverified**: no Apple SDK is installed on this host, so `NSArray.h` was
/// not read.
pub const NSArray = opaque {};

/// `NSAttributedStringKey`, the key type of an attributed string.
///
/// `UIAccessibilitySpeechAttributeQueueAnnouncement` is one. **Unverified**: no
/// Apple SDK is installed on this host, so `NSAttributedString.h` was not read.
pub const NSAttributedStringKey = opaque {};

/// `UIView`, the host view the adapter subclasses.
///
/// `AK/ios/src/subclass.rs:280-282` reaches it through the root view
/// controller of a window. **Unverified**: no iOS SDK is installed on this
/// host, so `UIView.h` was not read.
pub const UIView = opaque {};

/// `UIWindow`, the window a view belongs to.
///
/// `AK/ios/src/util.rs:38` converts a point through it. **Unverified**: no iOS
/// SDK is installed on this host, so `UIWindow.h` was not read.
pub const UIWindow = opaque {};

/// `UICoordinateSpace`, the screen space hit tests are expressed in.
///
/// `AK/ios/src/util.rs:39` reaches it from the screen. **Unverified**: no iOS
/// SDK is installed on this host, so `UICoordinateSpace.h` was not read.
pub const UICoordinateSpace = opaque {};

test "the table holds the 3 UIKit classes and the 8 Foundation types" {
    try testing.expectEqual(@as(usize, 11), platform_names.len);
    try testing.expectEqual(@as(usize, 3), countOfKind(.uikit_class));
    try testing.expectEqual(@as(usize, 8), countOfKind(.foundation_type));
}

test "every UIKit class is spelled as the map spells it" {
    try expectSpelling(.uikit_class, &.{ "UIView", "UIWindow", "UICoordinateSpace" });
}

test "every Foundation type is spelled as the map spells it" {
    try expectSpelling(.foundation_type, &.{
        "CGPoint",
        "CGRect",
        "CGSize",
        "NSArray",
        "NSAttributedStringKey",
        "NSInteger",
        "NSObject",
        "NSString",
    });
}

test "find returns the record that carries the spelling, or null" {
    try testing.expectEqual(PlatformKind.foundation_type, find("CGRect").?.kind);
    try testing.expectEqual(@as(?PlatformName, null), find("NSMutableString"));
}

test "the geometry types carry the layout CoreGraphics declares" {
    // `docs/42` names the three types and records no layout, so the assertions
    // below are this module's own claim rather than a measured one.
    try testing.expectEqual(@sizeOf(CGFloat), @sizeOf(f64));
    try testing.expectEqual(@as(usize, 16), @sizeOf(CGPoint));
    try testing.expectEqual(@as(usize, 32), @sizeOf(CGRect));
    const rect: CGRect = .{
        .origin = .{ .x = 1, .y = 2 },
        .size = .{ .width = 3, .height = 4 },
    };
    try testing.expectEqual(@as(CGFloat, 1), rect.origin.x);
    try testing.expectEqual(@as(CGFloat, 4), rect.size.height);
}

/// Checks that the names of `kind` are exactly `expected`, in order.
fn expectSpelling(kind: PlatformKind, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, countOfKind(kind));
    var seen: usize = 0;
    for (platform_names) |candidate| {
        if (candidate.kind != kind) continue;
        try testing.expectEqualStrings(expected[seen], candidate.name);
        seen += 1;
    }
    try testing.expectEqual(expected.len, seen);
}
