//! The 43 `UIAccessibility` identifiers the iOS adapter names, from the eight
//! files under `AK/ios/src/`.
//!
//! `docs/42-native-adapter-build-map.md` section 1.3.1 measured the figure by
//! scanning those eight files for the `UIAccessibility` prefix. A prefix scan
//! finds *names*, so this module declares names: `identifiers` holds one
//! `Identifier` per name, with the exact spelling and the kind the map's group
//! table gives it.
//!
//! No record here carries a UIKit value. No document under `docs/` records one,
//! and the map states the constants are read from the headers rather than from
//! the Rust source. A caller that needs a value resolves the symbol by `name`
//! through `runtime.resolveInImage`, or links it directly when the build
//! targets iOS.
//!
//! **The one identifier in two groups.** Four of the 43 are read at run time
//! rather than linked, at `AK/ios/src/util.rs:71-110`.
//! `UIAccessibilityTraitToggleButton` is both a named trait constant, at
//! `AK/ios/src/util.rs:80`, and the first of the four `dlsym` names. This
//! module counts it once, as `.trait`, so its seven groups hold 10, 13, 9, 4,
//! 3, 1 and 3 identifiers. `runtime.zig` counts it a second time, among the
//! four weakly linked names. The map's summary rows say "39 named plus 4
//! string literals", which counts this one member twice; the map's group
//! table gives 40 named plus 3 that exist only as strings, and that is the
//! decomposition this module follows because it sums to the 43.
//!
//! **What this module does not do.** It does not link UIKit. There is no Zig
//! UIKit package, at map section 2.3, and a Zig compiler cannot check a
//! notification name or a trait bit, because both are strings and integers
//! rather than declarations.
//!
//! **The loop bound.** Every loop over `identifiers` walks the array, whose
//! length is `identifier_count` and is a type-level fact rather than a value
//! read at run time. The `comptime` block below checks the seven group counts
//! and that no spelling appears twice.

const std = @import("std");
const foundation = @import("foundation.zig");

const testing = std.testing;

/// What kind of UIKit entry one identifier names.
///
/// The seven tags are the seven rows of the map's group table, section 1.3.1.
pub const Kind = enum {
    /// A class, a protocol or a type the UIKit headers declare.
    type_identifier,
    /// One bit of the `accessibilityTraits` mask.
    trait,
    /// A notification the adapter registers as an observer, at
    /// `AK/ios/src/adapter.rs:105-119`.
    observed_notification,
    /// A notification the adapter posts.
    posted_notification,
    /// One of the three functions that report a running assistive technology.
    /// They short-circuit at `AK/ios/src/adapter.rs:97-103`.
    predicate,
    /// `UIAccessibilityPostNotification`, the one function the adapter calls.
    posting_function,
    /// A name that exists only as a `dlsym` string and is never linked.
    weak_link_only,
};

/// One `UIAccessibility` identifier, as the spelling the adapter writes.
///
/// `name` is null-terminated so a caller passes it straight to
/// `runtime.resolveInImage` and to `NSSelectorFromString`. `kind` is the
/// group the map's table gives the identifier; `UIAccessibilityTraitToggleButton`
/// belongs to two groups upstream and this record holds `.trait`.
pub const Identifier = struct {
    kind: Kind,
    name: [:0]const u8,
};

/// How many identifiers `identifiers` holds.
///
/// The map's section 1.3.1 total. The value is a comptime constant because it
/// is the length of `identifiers`, so a table that loses or gains a member is
/// a compile error rather than a wrong count at run time.
pub const identifier_count = 43;

/// Every `UIAccessibility` identifier the iOS adapter names, in the map's
/// group order.
pub const identifiers = [identifier_count]Identifier{
    // 10 class, protocol and type names.
    .{ .kind = .type_identifier, .name = "UIAccessibilityContainer" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityContainerType" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityConvertFrameToScreenCoordinates" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityElement" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityExpandedStatus" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityHitTest" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityNotifications" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityPriority" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityScrollDirection" },
    .{ .kind = .type_identifier, .name = "UIAccessibilityTraits" },
    // 13 trait constants.
    .{ .kind = .trait, .name = "UIAccessibilityTraitAdjustable" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitAllowsDirectInteraction" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitButton" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitHeader" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitImage" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitLink" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitNone" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitNotEnabled" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitSearchField" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitSelected" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitStaticText" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitToggleButton" },
    .{ .kind = .trait, .name = "UIAccessibilityTraitUpdatesFrequently" },
    // 9 observed notifications.
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityBoldTextStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityDarkerSystemColorsStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityInvertColorsStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityOnOffSwitchLabelsDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityReduceMotionStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilitySpeakScreenStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilitySwitchControlStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityVideoAutoplayStatusDidChangeNotification",
    },
    .{
        .kind = .observed_notification,
        .name = "UIAccessibilityVoiceOverStatusDidChangeNotification",
    },
    // 4 posted notifications.
    .{ .kind = .posted_notification, .name = "UIAccessibilityAnnouncementNotification" },
    .{ .kind = .posted_notification, .name = "UIAccessibilityLayoutChangedNotification" },
    .{ .kind = .posted_notification, .name = "UIAccessibilityScreenChangedNotification" },
    .{ .kind = .posted_notification, .name = "UIAccessibilitySpeechAttributeQueueAnnouncement" },
    // 3 assistive-technology predicates.
    .{ .kind = .predicate, .name = "UIAccessibilityIsVoiceOverRunning" },
    .{ .kind = .predicate, .name = "UIAccessibilityIsSwitchControlRunning" },
    .{ .kind = .predicate, .name = "UIAccessibilityIsSpeakScreenEnabled" },
    // 1 posting function.
    .{ .kind = .posting_function, .name = "UIAccessibilityPostNotification" },
    // 3 names that exist only as `dlsym` strings.
    .{ .kind = .weak_link_only, .name = "UIAccessibilityPriorityHigh" },
    .{ .kind = .weak_link_only, .name = "UIAccessibilityPriorityLow" },
    .{ .kind = .weak_link_only, .name = "UIAccessibilitySpeechAttributeAnnouncementPriority" },
};

comptime {
    @setEvalBranchQuota(200_000);
    const expected = [_]struct { Kind, usize }{
        .{ .type_identifier, 10 },
        .{ .trait, 13 },
        .{ .observed_notification, 9 },
        .{ .posted_notification, 4 },
        .{ .predicate, 3 },
        .{ .posting_function, 1 },
        .{ .weak_link_only, 3 },
    };
    for (expected) |group| {
        if (countOfKind(group[0]) != group[1]) {
            @compileError(std.fmt.comptimePrint(
                "group .{s} holds {d} identifiers, the map gives {d}",
                .{ @tagName(group[0]), countOfKind(group[0]), group[1] },
            ));
        }
    }
    for (identifiers, 0..) |a, i| {
        for (identifiers[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate spelling at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.name },
                ));
            }
        }
    }
}

/// The identifier spelled `name`, or `null` when the table holds no such
/// spelling.
///
/// `name` may carry a null terminator; the comparison ignores it. The walk is
/// bounded by `identifiers.len`, which is `identifier_count`.
pub fn find(name: []const u8) ?Identifier {
    for (identifiers) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

/// How many identifiers the table holds for `kind`.
pub fn countOfKind(kind: Kind) usize {
    var total: usize = 0;
    for (identifiers) |candidate| {
        if (candidate.kind == kind) total += 1;
    }
    return total;
}

/// `UIAccessibilityNotifications`, the tag `UIAccessibilityPostNotification`
/// takes.
///
/// UIKit declares this as an enumeration. `docs/42` section 1.3.1 lists the
/// type and lists no case, and the four posted notification names are the only
/// values the adapter needs, so this declaration is a distinct non-exhaustive
/// enumeration over the platform `int` and a caller builds a value with
/// `@enumFromInt`. **Unverified**: no iOS SDK is installed on this host, so
/// `UIAccessibilityConstants.h` was not read.
pub const Notifications = enum(c_int) { _ };

/// `UIAccessibilityTraits`, the bitmask `accessibilityTraits` returns.
///
/// The mask is 64 bits wide on the 64-bit targets this port builds. The
/// adapter sets the 13 trait constants `identifiers` lists as `.trait`; UIKit
/// defines further bits that the adapter never sets. **Unverified**: no iOS SDK
/// is installed on this host, so `UIAccessibilityConstants.h` was not read.
pub const Traits = enum(u64) { _ };

/// `UIAccessibilityContainerType`, the value `accessibilityContainerType`
/// returns.
///
/// The adapter maps a `Role` onto it at `AK/ios/src/node.rs:167-188`. The map
/// names the type and no case. **Unverified**: no iOS SDK is installed on this
/// host, so `UIAccessibilityConstants.h` was not read.
pub const ContainerType = enum(c_int) { _ };

/// `UIAccessibilityExpandedStatus`, the value `accessibilityExpandedStatus`
/// returns.
///
/// `docs/29-apple-android-apis.md` row 34 counts three expanded-status values
/// in the adapter and gives no number for any of them.
/// **Unverified**: no iOS SDK is installed on this host, so
/// `UIAccessibilityConstants.h` was not read.
pub const ExpandedStatus = enum(c_int) { _ };

/// `UIAccessibilityScrollDirection`, the argument `accessibilityScroll:` takes.
///
/// `AK/ios/src/node.rs:359-391` inverts the vertical directions. The map names
/// the type and no case. **Unverified**: no iOS SDK is installed on this host,
/// so `UIAccessibilityConstants.h` was not read.
pub const ScrollDirection = enum(c_int) { _ };

/// `UIAccessibilityContainer`, the protocol a node implements so that UIKit
/// pulls its children instead of pushing them.
///
/// `docs/42` section 5.2.1 names it and records no layout.
/// **Unverified**: no iOS SDK is installed on this host, so
/// `UIAccessibilityConstants.h` was not read.
pub const Container = opaque {};

/// `UIAccessibilityElement`, the class every `PlatformNode` subclasses.
///
/// `docs/29-apple-android-apis.md` section 2.1 row 25 states the relationship.
/// **Unverified**: no iOS SDK is installed on this host, so
/// `UIAccessibilityElement.h` was not read.
pub const Element = opaque {};

/// `UIAccessibilityPriority`, the type of the two announcement priorities.
///
/// `docs/29-apple-android-apis.md` rows 22 and 23 read
/// `UIAccessibilityPriorityHigh` and `UIAccessibilityPriorityLow` as
/// `*const NSString`, so this is the Foundation string under another name.
/// **Unverified**: no iOS SDK is installed on this host, so
/// `UIAccessibilityConstants.h` was not read.
pub const Priority = foundation.NSString;

/// The signature `docs/29-apple-android-apis.md` row 1 records for
/// `UIAccessibilityPostNotification`.
///
/// The Rust binding takes `(notification, argument)`, and the C entry point
/// takes the tag and a nullable object.
pub const PostNotificationFn = fn (Notifications, ?*anyopaque) void;

/// The signature `docs/29-apple-android-apis.md` rows 12 to 14 record for the
/// three assistive-technology predicates.
///
/// Each takes nothing and returns whether the technology is running.
pub const IsRunningFn = fn () bool;

/// The signature `docs/29-apple-android-apis.md` row 2 records for
/// `UIAccessibilityConvertFrameToScreenCoordinates`.
///
/// The Rust binding takes a `CGRect` and a `UIView` and returns a `CGRect`.
/// `foundation.CGRect` and `foundation.UIView` carry the two types.
pub const ConvertFrameToScreenCoordinatesFn = fn (
    frame: foundation.CGRect,
    view: *foundation.UIView,
) foundation.CGRect;

/// The signature `docs/29-apple-android-apis.md` does not record, for
/// `UIAccessibilityHitTest`.
///
/// The map lists `UIAccessibilityHitTest` among the 10 type names and no
/// document under `docs/` gives its parameter list, so this module declares the
/// name and no signature. **Unverified**.
pub const hit_test_signature_recorded = false;

test "the table holds exactly the 43 identifiers of map section 1.3.1" {
    try testing.expectEqual(@as(usize, 43), identifiers.len);
    try testing.expectEqual(@as(usize, 40), countOfKind(.type_identifier) +
        countOfKind(.trait) + countOfKind(.observed_notification) +
        countOfKind(.posted_notification) + countOfKind(.predicate) +
        countOfKind(.posting_function));
    try testing.expectEqual(@as(usize, 3), countOfKind(.weak_link_only));
}

test "every type, protocol and enum name is spelled as the map spells it" {
    const expected = [_][:0]const u8{
        "UIAccessibilityContainer",
        "UIAccessibilityContainerType",
        "UIAccessibilityConvertFrameToScreenCoordinates",
        "UIAccessibilityElement",
        "UIAccessibilityExpandedStatus",
        "UIAccessibilityHitTest",
        "UIAccessibilityNotifications",
        "UIAccessibilityPriority",
        "UIAccessibilityScrollDirection",
        "UIAccessibilityTraits",
    };
    try expectKind(.type_identifier, &expected);
}

test "every trait constant is spelled as the map spells it" {
    const expected = [_][:0]const u8{
        "UIAccessibilityTraitAdjustable",
        "UIAccessibilityTraitAllowsDirectInteraction",
        "UIAccessibilityTraitButton",
        "UIAccessibilityTraitHeader",
        "UIAccessibilityTraitImage",
        "UIAccessibilityTraitLink",
        "UIAccessibilityTraitNone",
        "UIAccessibilityTraitNotEnabled",
        "UIAccessibilityTraitSearchField",
        "UIAccessibilityTraitSelected",
        "UIAccessibilityTraitStaticText",
        "UIAccessibilityTraitToggleButton",
        "UIAccessibilityTraitUpdatesFrequently",
    };
    try expectKind(.trait, &expected);
}

test "every observed notification is spelled as the map spells it" {
    // `UIAccessibilityOnOffSwitchLabelsDidChangeNotification` is the upstream
    // spelling, and `docs/29` row 10 flags it as such.
    const expected = [_][:0]const u8{
        "UIAccessibilityBoldTextStatusDidChangeNotification",
        "UIAccessibilityDarkerSystemColorsStatusDidChangeNotification",
        "UIAccessibilityInvertColorsStatusDidChangeNotification",
        "UIAccessibilityOnOffSwitchLabelsDidChangeNotification",
        "UIAccessibilityReduceMotionStatusDidChangeNotification",
        "UIAccessibilitySpeakScreenStatusDidChangeNotification",
        "UIAccessibilitySwitchControlStatusDidChangeNotification",
        "UIAccessibilityVideoAutoplayStatusDidChangeNotification",
        "UIAccessibilityVoiceOverStatusDidChangeNotification",
    };
    try expectKind(.observed_notification, &expected);
}

test "every posted notification is spelled as the map spells it" {
    const expected = [_][:0]const u8{
        "UIAccessibilityAnnouncementNotification",
        "UIAccessibilityLayoutChangedNotification",
        "UIAccessibilityScreenChangedNotification",
        "UIAccessibilitySpeechAttributeQueueAnnouncement",
    };
    try expectKind(.posted_notification, &expected);
}

test "every predicate and the posting function are spelled as the map spells them" {
    try expectKind(.predicate, &.{
        "UIAccessibilityIsVoiceOverRunning",
        "UIAccessibilityIsSwitchControlRunning",
        "UIAccessibilityIsSpeakScreenEnabled",
    });
    try expectKind(.posting_function, &.{"UIAccessibilityPostNotification"});
}

test "every run-time-only name is spelled as the map spells it" {
    try expectKind(.weak_link_only, &.{
        "UIAccessibilityPriorityHigh",
        "UIAccessibilityPriorityLow",
        "UIAccessibilitySpeechAttributeAnnouncementPriority",
    });
}

test "find returns the record that carries the spelling, or null" {
    const toggle = find("UIAccessibilityTraitToggleButton");
    try testing.expect(toggle != null);
    try testing.expectEqual(Kind.trait, toggle.?.kind);
    try testing.expectEqual(@as(?Identifier, null), find("UIAccessibilityTraitNoSuchName"));
}

/// Checks that the identifiers of `kind` are exactly `expected`, in order.
fn expectKind(kind: Kind, expected: []const [:0]const u8) !void {
    try testing.expectEqual(expected.len, countOfKind(kind));
    var seen: usize = 0;
    for (identifiers) |candidate| {
        if (candidate.kind != kind) continue;
        try testing.expectEqualStrings(expected[seen], candidate.name);
        seen += 1;
    }
    try testing.expectEqual(expected.len, seen);
}
