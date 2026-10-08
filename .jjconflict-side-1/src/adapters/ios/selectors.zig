//! The 36 Objective-C selector names the iOS adapter writes, in three groups.
//!
//! `docs/42-native-adapter-build-map.md` section 1.3.3 counts 19 selectors
//! implemented on `PlatformNode` and 5 installed on the host view subclass.
//! `docs/29-apple-android-apis.md` section 2.1 rows 52 to 63 count 12 more that
//! the adapter calls on a Foundation or a UIKit object. This module holds all
//! 36, each with the exact spelling, and the group each belongs to.
//!
//! **Two spellings appear in two groups.** `isAccessibilityElement` and
//! `accessibilityElements` are both implemented on a node and installed on the
//! host view, and `didMoveToWindow` is both installed on the host view and
//! called on the superclass implementation it chains to. The table keeps 36
//! rows rather than 33 distinct spellings, because the map counts the two
//! implementations separately and a caller that installs a selector needs to
//! know which of them it is installing. The duplicate check is therefore per
//! group, and `distinct_name_count` is 33.
//!
//! **The loop bound.** Every loop over `selectors` walks the array, whose
//! length is `selector_count` and is a type-level fact. The one loop that
//! walks the groups walks `groups`, whose length is 3.

const std = @import("std");

const testing = std.testing;

/// What the adapter does with one selector.
pub const Target = enum {
    /// One of the 19 selectors `PlatformNode` implements for UIKit to call,
    /// declared at `AK/ios/src/node.rs:219-438`.
    node,
    /// One of the 5 selectors `SubclassingAdapter` installs on a copy of the
    /// host view's class, at `AK/ios/src/subclass.rs:214` to `:230`.
    host_view,
    /// One of the 12 methods the adapter calls on a Foundation or a UIKit
    /// object, listed at `docs/29` section 2.1 rows 52 to 63.
    called,
};

/// One selector, as the exact spelling the adapter passes to
/// `class_addMethod` or to `NSSelectorFromString`.
pub const Selector = struct {
    target: Target,
    name: [:0]const u8,
};

/// How many rows `selectors` holds.
///
/// 19 implemented on the node, 5 installed on the host view and 12 called.
pub const selector_count = 36;

/// How many distinct spellings `selectors` holds.
///
/// Three spellings appear in two groups, so the row count exceeds this one.
pub const distinct_name_count = 33;

/// The three groups, with the row count the map gives each.
pub const groups = [_]struct { target: Target, rows: usize }{
    .{ .target = .node, .rows = 19 },
    .{ .target = .host_view, .rows = 5 },
    .{ .target = .called, .rows = 12 },
};

/// Every selector name the iOS adapter writes, in the map's group order.
pub const selectors = [selector_count]Selector{
    // 19 selectors implemented on `PlatformNode`.
    .{ .target = .node, .name = "accessibilityContainer" },
    .{ .target = .node, .name = "setAccessibilityContainer:" },
    .{ .target = .node, .name = "isAccessibilityElement" },
    .{ .target = .node, .name = "accessibilityLabel" },
    .{ .target = .node, .name = "accessibilityHint" },
    .{ .target = .node, .name = "accessibilityValue" },
    .{ .target = .node, .name = "accessibilityTraits" },
    .{ .target = .node, .name = "accessibilityFrame" },
    .{ .target = .node, .name = "accessibilityLanguage" },
    .{ .target = .node, .name = "accessibilityExpandedStatus" },
    .{ .target = .node, .name = "accessibilityActivate" },
    .{ .target = .node, .name = "accessibilityIncrement" },
    .{ .target = .node, .name = "accessibilityDecrement" },
    .{ .target = .node, .name = "accessibilityScroll:" },
    .{ .target = .node, .name = "accessibilityElements" },
    .{ .target = .node, .name = "accessibilityContainerType" },
    .{ .target = .node, .name = "accessibilityElementDidBecomeFocused" },
    .{ .target = .node, .name = "accessibilityElementDidLoseFocus" },
    .{ .target = .node, .name = "accessibilityIdentifier" },
    // 5 selectors installed on the host view subclass.
    .{ .target = .host_view, .name = "superclass" },
    .{ .target = .host_view, .name = "isAccessibilityElement" },
    .{ .target = .host_view, .name = "accessibilityElements" },
    .{ .target = .host_view, .name = "accessibilityHitTest:" },
    .{ .target = .host_view, .name = "didMoveToWindow" },
    // 12 methods called on a Foundation or a UIKit object.
    .{ .target = .called, .name = "defaultCenter" },
    .{ .target = .called, .name = "addObserver:selector:name:object:" },
    .{ .target = .called, .name = "removeObserver:" },
    .{ .target = .called, .name = "window" },
    .{ .target = .called, .name = "coordinateSpace" },
    .{ .target = .called, .name = "convertPoint:fromCoordinateSpace:" },
    .{ .target = .called, .name = "contentScaleFactor" },
    .{ .target = .called, .name = "bounds" },
    .{ .target = .called, .name = "rootViewController" },
    .{ .target = .called, .name = "view" },
    .{ .target = .called, .name = "initWithAccessibilityContainer:" },
    .{ .target = .called, .name = "didMoveToWindow" },
};

comptime {
    @setEvalBranchQuota(200_000);
    for (groups) |group| {
        if (countOf(group.target) != group.rows) {
            @compileError(std.fmt.comptimePrint(
                "group .{s} holds {d} selectors, the map gives {d}",
                .{ @tagName(group.target), countOf(group.target), group.rows },
            ));
        }
        for (selectors, 0..) |a, i| {
            if (a.target != group.target) continue;
            for (selectors[i + 1 ..], 0..) |b, j| {
                if (b.target != group.target) continue;
                if (std.mem.eql(u8, a.name, b.name)) {
                    @compileError(std.fmt.comptimePrint(
                        "group .{s} repeats {s} at {d} and {d}",
                        .{ @tagName(group.target), a.name, i, i + 1 + j },
                    ));
                }
            }
        }
    }
    if (selectors.len != selector_count) @compileError("the array length is the count");
}

/// How many rows of `selectors` belong to `target`.
pub fn countOf(target: Target) usize {
    var total: usize = 0;
    for (selectors) |selector| {
        if (selector.target == target) total += 1;
    }
    return total;
}

/// The first row spelled `name` for `target`, or `null` when the table holds no
/// such spelling.
///
/// `target` is part of the key because three spellings belong to two groups
/// and the caller needs to know which one it is asking about.
pub fn find(target: Target, name: []const u8) ?Selector {
    for (selectors) |selector| {
        if (selector.target != target) continue;
        if (std.mem.eql(u8, selector.name, name)) return selector;
    }
    return null;
}

test "the table holds 19 node selectors, 5 view selectors and 12 called ones" {
    try testing.expectEqual(@as(usize, 36), selectors.len);
    try testing.expectEqual(@as(usize, 19), countOf(.node));
    try testing.expectEqual(@as(usize, 5), countOf(.host_view));
    try testing.expectEqual(@as(usize, 12), countOf(.called));
    try testing.expectEqual(@as(usize, 33), distinctNameCount());
}

test "every selector on the node is spelled as the map spells it" {
    try expectTarget(.node, &.{
        "accessibilityContainer",
        "setAccessibilityContainer:",
        "isAccessibilityElement",
        "accessibilityLabel",
        "accessibilityHint",
        "accessibilityValue",
        "accessibilityTraits",
        "accessibilityFrame",
        "accessibilityLanguage",
        "accessibilityExpandedStatus",
        "accessibilityActivate",
        "accessibilityIncrement",
        "accessibilityDecrement",
        "accessibilityScroll:",
        "accessibilityElements",
        "accessibilityContainerType",
        "accessibilityElementDidBecomeFocused",
        "accessibilityElementDidLoseFocus",
        "accessibilityIdentifier",
    });
}

test "every selector installed on the host view is spelled as the map spells it" {
    try expectTarget(.host_view, &.{
        "superclass",
        "isAccessibilityElement",
        "accessibilityElements",
        "accessibilityHitTest:",
        "didMoveToWindow",
    });
}

test "every called selector is spelled as docs 29 spells it" {
    try expectTarget(.called, &.{
        "defaultCenter",
        "addObserver:selector:name:object:",
        "removeObserver:",
        "window",
        "coordinateSpace",
        "convertPoint:fromCoordinateSpace:",
        "contentScaleFactor",
        "bounds",
        "rootViewController",
        "view",
        "initWithAccessibilityContainer:",
        "didMoveToWindow",
    });
}

test "the three shared spellings are present in both of their groups" {
    // `isAccessibilityElement` and `accessibilityElements` are installed on the
    // host view as well as implemented on the node, and `didMoveToWindow` is
    // called on the superclass implementation as well as installed.
    for ([_][]const u8{ "isAccessibilityElement", "accessibilityElements" }) |name| {
        try testing.expect(find(.node, name) != null);
        try testing.expect(find(.host_view, name) != null);
    }
    try testing.expect(find(.host_view, "didMoveToWindow") != null);
    try testing.expect(find(.called, "didMoveToWindow") != null);
}

test "find answers for the group it is asked about and null otherwise" {
    try testing.expectEqual(Target.node, find(.node, "accessibilityLabel").?.target);
    try testing.expectEqual(@as(?Selector, null), find(.called, "accessibilityLabel"));
    try testing.expectEqual(@as(?Selector, null), find(.node, "noSuchSelector"));
}

/// How many distinct spellings the table holds, compared one row at a time.
///
/// The walk is over 36 rows and compares each with the 35 that follow it, so
/// the bound is `selector_count * selector_count`.
fn distinctNameCount() usize {
    var total: usize = 0;
    for (selectors, 0..) |a, i| {
        var already_counted = false;
        for (selectors[0..i]) |b| {
            if (std.mem.eql(u8, a.name, b.name)) already_counted = true;
        }
        if (!already_counted) total += 1;
    }
    return total;
}

/// Checks that the selectors for `target` are exactly `expected`, in order.
fn expectTarget(target: Target, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, countOf(target));
    var seen: usize = 0;
    for (selectors) |selector| {
        if (selector.target != target) continue;
        try testing.expectEqualStrings(expected[seen], selector.name);
        seen += 1;
    }
    try testing.expectEqual(expected.len, seen);
}
