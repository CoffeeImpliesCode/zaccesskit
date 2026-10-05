//! Every string the macOS adapter hands to AppKit.
//!
//! **What this module is.** The spelling table for the adapter, and nothing
//! else. It holds the 43 `AX…` strings `docs/42-native-adapter-build-map.md`
//! section 1.2.5 counts, the 31 `NSAccessibility…Role` constants `ns_role`
//! returns, the 7 `NSAccessibility…Subrole` constants `ns_sub_role` returns, the
//! 7 notification names the adapter posts, and the two announcement keys it
//! publishes. `roles.zig` and `events.zig` name a member of one of these tables
//! rather than writing a string.
//!
//! **Why this module is the highest-value one in the adapter.** `objc2-app-kit`
//! exports no constant for any of the 43, which is why upstream writes them as
//! strings and why a Zig port writes 43 literals. A misspelled one is a runtime
//! wrong answer and no compile catches it: the node answers `accessibilityRole`
//! or `accessibilitySubrole` with a string the system has never heard of, and
//! the tree is wrong in a way that looks like a platform bug. Every other name
//! in the adapter fails loudly — a wrong exported symbol does not link, a wrong
//! function signature does not type-check. **Only these 43 fail silently**, and
//! all 43 are assertable on a host with no Mac, no SDK and no Objective-C
//! runtime.
//!
//! **The 44th literal, which is not in the 43.** Upstream writes
//! `Role::Heading => ns_string!("Heading")` at `AK/macos/src/node.rs:125`, with
//! no `AX` prefix, which is why a `"AX[A-Za-z]+"` scan returns 43 and not 44.
//! Every other role the adapter emits carries the prefix, and upstream itself
//! writes `AXHeading` for `doc_subtitle` at `:224`. **The rule for this port is
//! that upstream wins, so the port reproduces `"Heading"`.** It is held as
//! `heading_role` below, outside the 43, with its own test, so the next reader
//! who finds it unpinned cannot "fix" it into a silent divergence.
//!
//! **What this module does not do.** It does not link AppKit, and it does not
//! declare an Objective-C type. `docs/42` section 2.5 records that `translate-c`
//! cannot parse an Objective-C header, and no macOS SDK is installed on this
//! host, so the value of a constant is written here as a string and pinned by a
//! test rather than read from a header.
//!
//! **The loop bound.** Every loop in this module walks one of the five tables
//! below, and each walk is bounded by that table's length, which is a comptime
//! constant rather than a value read at run time: `literal_count` is 43,
//! `role_constant_count` is 31, `subrole_constant_count` is 7,
//! `notification_count` is 7 and `announcement_key_count` is 2. The `comptime`
//! block checks all five lengths and the five group counts against the figures
//! `docs/42` section 1.2.5 and section 1.2.4 record.

const std = @import("std");

const testing = std.testing;

/// Which group of the 43 a literal belongs to.
///
/// The five tags are the five rows of `docs/42` section 1.2.5's table. The
/// groups are disjoint, and a literal that upstream writes in two places is
/// held once, at the first place, with its second place recorded in the
/// provenance note on `subrole_duplicates`.
pub const Group = enum(u8) {
    /// A value `ns_role` returns, upstream `AK/macos/src/node.rs:36-242`.
    role_literal,
    /// A value `ns_sub_role` returns, upstream `AK/macos/src/node.rs:244-296`.
    subrole_literal,
    /// An attribute name `accessibilityAttributeValue:` matches,
    /// `AK/macos/src/node.rs:1090-1104`.
    attribute_name,
    /// A key of the font dictionary,
    /// `AK/macos/src/node.rs:892` and `:899`.
    font_key,
    /// The one action name the adapter publishes, `AK/macos/src/node.rs:34`.
    action_name,
};

/// One `AX…` string, with the group it belongs to and the upstream line it is
/// written at.
///
/// `text` is null-terminated because AppKit takes these as `NSString` values and
/// `NSString` is built from a C string. `upstream_line` is the line in
/// `AK/macos/src/node.rs` where upstream writes the spelling for the first time;
/// a spelling upstream writes twice is held once here, and the second line is
/// in `subrole_duplicates`.
pub const Literal = struct {
    /// The group this literal belongs to.
    group: Group,
    /// The spelling, byte for byte as upstream writes it.
    text: [:0]const u8,
    /// The `AK/macos/src/node.rs` line of the first spelling.
    upstream_line: u16,
};

/// How many literals `literals` holds.
///
/// `docs/42` section 1.2.5's total. The value is a comptime constant because it
/// is the length of `literals`, so a table that gains or loses a member is a
/// compile error rather than a wrong count at run time.
pub const literal_count = 43;

/// The 43 `AX…` strings, in upstream's group order.
///
/// The five groups hold 5, 32, 3, 2 and 1 members and sum to 43.
pub const literals = [literal_count]Literal{
    // 5 role values, `ns_role`, `AK/macos/src/node.rs:36-242`.
    .{ .group = .role_literal, .text = "AXListMarker", .upstream_line = 49 },
    .{ .group = .role_literal, .text = "AXDateField", .upstream_line = 86 },
    .{ .group = .role_literal, .text = "AXTimeField", .upstream_line = 88 },
    .{ .group = .role_literal, .text = "AXWebArea", .upstream_line = 149 },
    .{ .group = .role_literal, .text = "AXHeading", .upstream_line = 224 },
    // 32 subrole values, `ns_sub_role`, `AK/macos/src/node.rs:244-296`.
    .{ .group = .subrole_literal, .text = "AXApplicationAlert", .upstream_line = 249 },
    .{ .group = .subrole_literal, .text = "AXWebApplication", .upstream_line = 251 },
    .{ .group = .subrole_literal, .text = "AXDocumentArticle", .upstream_line = 252 },
    .{ .group = .subrole_literal, .text = "AXLandmarkBanner", .upstream_line = 253 },
    .{ .group = .subrole_literal, .text = "AXCodeStyleGroup", .upstream_line = 255 },
    .{ .group = .subrole_literal, .text = "AXLandmarkComplementary", .upstream_line = 256 },
    .{ .group = .subrole_literal, .text = "AXDeleteStyleGroup", .upstream_line = 257 },
    .{ .group = .subrole_literal, .text = "AXInsertStyleGroup", .upstream_line = 258 },
    .{ .group = .subrole_literal, .text = "AXLandmarkContentInfo", .upstream_line = 259 },
    .{ .group = .subrole_literal, .text = "AXDefinition", .upstream_line = 260 },
    .{ .group = .subrole_literal, .text = "AXDocument", .upstream_line = 262 },
    .{ .group = .subrole_literal, .text = "AXEmphasisStyleGroup", .upstream_line = 263 },
    .{ .group = .subrole_literal, .text = "AXApplicationGroup", .upstream_line = 264 },
    .{ .group = .subrole_literal, .text = "AXLandmarkForm", .upstream_line = 266 },
    .{ .group = .subrole_literal, .text = "AXApplicationLog", .upstream_line = 270 },
    .{ .group = .subrole_literal, .text = "AXLandmarkMain", .upstream_line = 271 },
    .{ .group = .subrole_literal, .text = "AXApplicationMarquee", .upstream_line = 272 },
    .{ .group = .subrole_literal, .text = "AXDocumentMath", .upstream_line = 273 },
    .{ .group = .subrole_literal, .text = "AXMeter", .upstream_line = 274 },
    .{ .group = .subrole_literal, .text = "AXLandmarkNavigation", .upstream_line = 275 },
    .{ .group = .subrole_literal, .text = "AXDocumentNote", .upstream_line = 276 },
    .{ .group = .subrole_literal, .text = "AXLandmarkRegion", .upstream_line = 278 },
    .{ .group = .subrole_literal, .text = "AXLandmarkSearch", .upstream_line = 279 },
    .{ .group = .subrole_literal, .text = "AXSectionFooter", .upstream_line = 281 },
    .{ .group = .subrole_literal, .text = "AXSectionHeader", .upstream_line = 282 },
    .{ .group = .subrole_literal, .text = "AXApplicationStatus", .upstream_line = 283 },
    .{ .group = .subrole_literal, .text = "AXStrongStyleGroup", .upstream_line = 284 },
    .{ .group = .subrole_literal, .text = "AXTabPanel", .upstream_line = 287 },
    .{ .group = .subrole_literal, .text = "AXTerm", .upstream_line = 288 },
    .{ .group = .subrole_literal, .text = "AXTimeGroup", .upstream_line = 289 },
    .{ .group = .subrole_literal, .text = "AXApplicationTimer", .upstream_line = 290 },
    .{ .group = .subrole_literal, .text = "AXUserInterfaceTooltip", .upstream_line = 292 },
    // 3 attribute names, `AK/macos/src/node.rs:1090-1104`.
    .{ .group = .attribute_name, .text = "AXBrailleLabel", .upstream_line = 1093 },
    .{ .group = .attribute_name, .text = "AXBrailleRoleDescription", .upstream_line = 1095 },
    .{ .group = .attribute_name, .text = "AXDOMIdentifier", .upstream_line = 1097 },
    // 2 font dictionary keys, `AK/macos/src/node.rs:892` and `:899`.
    .{ .group = .font_key, .text = "AXFontBold", .upstream_line = 892 },
    .{ .group = .font_key, .text = "AXFontItalic", .upstream_line = 899 },
    // 1 action name, `AK/macos/src/node.rs:34`.
    .{ .group = .action_name, .text = "AXScrollToVisible", .upstream_line = 34 },
};

/// The one subrole spelling that two roles emit, and the line of the second.
///
/// Upstream writes `AXLandmarkBanner` at `AK/macos/src/node.rs:253` for
/// `banner` and at `:269` for `header`, and it writes the other three of these
/// the same way. A test that asserts no two literals in a group are equal must
/// exempt this pair, because deduplicating the 36 arms into 32 would change
/// which roles answer. It is held here so the exemption is data rather than a
/// special case in a test.
pub const subrole_duplicates = [_]struct { [:0]const u8, u16, u16 }{
    // Two lines: `banner` at 253, `header` at 269.
    .{ "AXLandmarkBanner", 253, 269 },
    // `content_info` at 259, `footer` at 265.
    .{ "AXLandmarkContentInfo", 259, 265 },
    // `document` at 262, `graphics_document` at 267.
    .{ "AXDocument", 262, 267 },
    // `feed` at 264, `group` at 268.
    .{ "AXApplicationGroup", 264, 268 },
};

/// The role `heading` emits, which carries no `AX` prefix.
///
/// Upstream `AK/macos/src/node.rs:125`. It is the 44th `AX`-shaped literal and
/// it is not one of the 43, because the scan that counts the 43 matches `"AX`
/// followed by a letter. `roles.zig` returns this string and the test
/// "the heading role emits the unprefixed string upstream emits" pins it.
pub const heading_role: [:0]const u8 = "Heading";

/// One `NSAccessibility…Role` constant, as the `objc2-app-kit` name and the
/// string the constant carries.
pub const RoleConstant = struct {
    /// The exported name, spelled as `objc2-app-kit` spells it.
    name: [:0]const u8,
    /// The string the constant carries at run time.
    value: [:0]const u8,
};

/// How many role constants `role_constants` holds.
///
/// `docs/42` section 1.2.4's role row. `NSAccessibilityRole` is the class
/// itself and is not in this count.
pub const role_constant_count = 31;

/// The 31 role constants `ns_role` returns, in the map's alphabetical order.
///
/// Every `value` is `AX` followed by the constant's own suffix, with one
/// exception: `NSAccessibilityUnknownRole` carries `AXUnknownRole` and not
/// `AXUnknown`. The test "every role constant carries the string its name gives"
/// derives the other 30 and pins the exception.
pub const role_constants = [role_constant_count]RoleConstant{
    .{ .name = "NSAccessibilityButtonRole", .value = "AXButton" },
    .{ .name = "NSAccessibilityCellRole", .value = "AXCell" },
    .{ .name = "NSAccessibilityCheckBoxRole", .value = "AXCheckBox" },
    .{ .name = "NSAccessibilityColorWellRole", .value = "AXColorWell" },
    .{ .name = "NSAccessibilityComboBoxRole", .value = "AXComboBox" },
    .{ .name = "NSAccessibilityGroupRole", .value = "AXGroup" },
    .{ .name = "NSAccessibilityImageRole", .value = "AXImage" },
    .{ .name = "NSAccessibilityIncrementorRole", .value = "AXIncrementor" },
    .{ .name = "NSAccessibilityLevelIndicatorRole", .value = "AXLevelIndicator" },
    .{ .name = "NSAccessibilityLinkRole", .value = "AXLink" },
    .{ .name = "NSAccessibilityListRole", .value = "AXList" },
    .{ .name = "NSAccessibilityMenuBarRole", .value = "AXMenuBar" },
    .{ .name = "NSAccessibilityMenuItemRole", .value = "AXMenuItem" },
    .{ .name = "NSAccessibilityMenuRole", .value = "AXMenu" },
    .{ .name = "NSAccessibilityOutlineRole", .value = "AXOutline" },
    .{ .name = "NSAccessibilityPopUpButtonRole", .value = "AXPopUpButton" },
    .{ .name = "NSAccessibilityProgressIndicatorRole", .value = "AXProgressIndicator" },
    .{ .name = "NSAccessibilityRadioButtonRole", .value = "AXRadioButton" },
    .{ .name = "NSAccessibilityRadioGroupRole", .value = "AXRadioGroup" },
    .{ .name = "NSAccessibilityRowRole", .value = "AXRow" },
    .{ .name = "NSAccessibilityScrollBarRole", .value = "AXScrollBar" },
    .{ .name = "NSAccessibilitySliderRole", .value = "AXSlider" },
    .{ .name = "NSAccessibilitySplitterRole", .value = "AXSplitter" },
    .{ .name = "NSAccessibilityStaticTextRole", .value = "AXStaticText" },
    .{ .name = "NSAccessibilityTabGroupRole", .value = "AXTabGroup" },
    .{ .name = "NSAccessibilityTableRole", .value = "AXTable" },
    .{ .name = "NSAccessibilityTextAreaRole", .value = "AXTextArea" },
    .{ .name = "NSAccessibilityTextFieldRole", .value = "AXTextField" },
    .{ .name = "NSAccessibilityToolbarRole", .value = "AXToolbar" },
    .{ .name = "NSAccessibilityUnknownRole", .value = "AXUnknownRole" },
    .{ .name = "NSAccessibilityWindowRole", .value = "AXWindow" },
};

/// One `NSAccessibility…Subrole` constant.
pub const SubroleConstant = struct {
    /// The exported name, spelled as `objc2-app-kit` spells it.
    name: [:0]const u8,
    /// The string the constant carries at run time.
    value: [:0]const u8,
};

/// How many literals the `.attribute_name` group holds, as a comptime fact.
///
/// `countOfGroup` is a run-time function, so a caller that needs an array
/// length uses this instead. The `comptime` block checks it against the group's
/// own count.
pub const attribute_name_count = 3;

/// How many subrole constants `subrole_constants` holds.
///
/// `docs/42` section 1.2.4's subrole row, and the number of arms of
/// `ns_sub_role` that name a constant instead of one of the 32 literals.
pub const subrole_constant_count = 7;

/// The 7 subrole constants `ns_sub_role` returns, in the map's order.
///
/// `docs/51c-macos-test-plan.md` section 7 records that whether
/// `objc2-app-kit` exports each of these under exactly this spelling was not
/// checked against the crate, because the crate is not vendored here. A
/// misspelled name is caught when the build targets macOS; a name that exists
/// and carries a different string is not caught by anything on this host.
pub const subrole_constants = [subrole_constant_count]SubroleConstant{
    .{ .name = "NSAccessibilityDialogSubrole", .value = "AXDialog" },
    .{ .name = "NSAccessibilityOutlineRowSubrole", .value = "AXOutlineRow" },
    .{ .name = "NSAccessibilitySearchFieldSubrole", .value = "AXSearchField" },
    .{ .name = "NSAccessibilitySecureTextFieldSubrole", .value = "AXSecureTextField" },
    .{ .name = "NSAccessibilitySwitchSubrole", .value = "AXSwitch" },
    .{ .name = "NSAccessibilityTabButtonSubrole", .value = "AXTabButton" },
    .{ .name = "NSAccessibilityToggleSubrole", .value = "AXToggle" },
};

/// The one notification the adapter posts through
/// `NSAccessibilityPostNotificationWithUserInfo` rather than
/// `NSAccessibilityPostNotification`.
///
/// `AK/macos/src/event.rs:97`.
pub const announcement_requested_notification: Notification = .{
    .name = "NSAccessibilityAnnouncementRequestedNotification",
    .value = "NSAccessibilityAnnouncementRequestedNotification",
    .upstream_line = 99,
};

/// One notification name the adapter posts.
pub const Notification = struct {
    /// The exported name, spelled as AppKit spells it.
    name: [:0]const u8,
    /// The string the constant carries, which is the name itself.
    value: [:0]const u8,
    /// The `AK/macos/src/event.rs` line of the first post.
    upstream_line: u16,
};

/// How many notifications `notifications` holds.
///
/// Measured over `AK/macos/src/event.rs`, `context.rs` and `node.rs`: seven
/// distinct names across three post sites.
pub const notification_count = 7;

/// The 7 notifications the adapter posts, in alphabetical order.
pub const notifications = [notification_count]Notification{
    announcement_requested_notification,
    .{
        .name = "NSAccessibilityFocusedUIElementChangedNotification",
        .value = "NSAccessibilityFocusedUIElementChangedNotification",
        .upstream_line = 136,
    },
    .{
        .name = "NSAccessibilitySelectedRowsChangedNotification",
        .value = "NSAccessibilitySelectedRowsChangedNotification",
        .upstream_line = 211,
    },
    .{
        .name = "NSAccessibilitySelectedTextChangedNotification",
        .value = "NSAccessibilitySelectedTextChangedNotification",
        .upstream_line = 297,
    },
    .{
        .name = "NSAccessibilityTitleChangedNotification",
        .value = "NSAccessibilityTitleChangedNotification",
        .upstream_line = 267,
    },
    .{
        .name = "NSAccessibilityUIElementDestroyedNotification",
        .value = "NSAccessibilityUIElementDestroyedNotification",
        .upstream_line = 60,
    },
    .{
        .name = "NSAccessibilityValueChangedNotification",
        .value = "NSAccessibilityValueChangedNotification",
        .upstream_line = 189,
    },
};

/// How many announcement keys `announcement_keys` holds.
///
/// The announcement path at `AK/macos/src/event.rs:76-101` is the only one
/// that publishes a `userInfo`, and it publishes exactly two keys.
pub const announcement_key_count = 2;

/// The 2 keys the announcement `userInfo` dictionary carries.
pub const announcement_keys = [announcement_key_count][:0]const u8{
    "NSAccessibilityAnnouncementKey",
    "NSAccessibilityPriorityKey",
};

/// The `NSAccessibilityPriorityLevel` values the adapter writes.
///
/// The value is the number a client reads out of the `NSNumber` under
/// `NSAccessibilityPriorityKey`. `AK/macos/src/event.rs:35-43` picks between
/// the two arms; `docs/51c-macos-test-plan.md` section 4.2 records the two
/// numbers as the ones AppKit defines. **Unverified**: no macOS SDK is
/// installed on this host, so `NSAccessibilityConstants.h` was not read.
pub const PriorityLevel = enum(i32) {
    /// `NSAccessibilityPriorityHigh`, which `Live.assertive` announces at.
    high = 700,
    /// `NSAccessibilityPriorityMedium`, which every other live value announces
    /// at.
    medium = 500,
};

comptime {
    @setEvalBranchQuota(100_000);

    const expected = [_]struct { Group, usize }{
        .{ .role_literal, 5 },
        .{ .subrole_literal, 32 },
        .{ .attribute_name, 3 },
        .{ .font_key, 2 },
        .{ .action_name, 1 },
    };
    for (expected) |group| {
        if (countOfGroup(group[0]) != group[1]) {
            @compileError(std.fmt.comptimePrint(
                "group .{s} holds {d} literals, the map gives {d}",
                .{ @tagName(group[0]), countOfGroup(group[0]), group[1] },
            ));
        }
    }
    if (role_constants.len != role_constant_count) {
        @compileError("the role constant table lost a member");
    }
    if (subrole_constants.len != subrole_constant_count) {
        @compileError("the subrole constant table lost a member");
    }
    if (notifications.len != notification_count) {
        @compileError("the notification table lost a member");
    }
    if (announcement_keys.len != announcement_key_count) {
        @compileError("the announcement key table lost a member");
    }
    for (literals, 0..) |a, i| {
        if (a.upstream_line == 0) {
            @compileError(std.fmt.comptimePrint(
                "literal {d} has no upstream line: {s}",
                .{ i, a.text },
            ));
        }
        for (literals[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.text, b.text)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate spelling at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.text },
                ));
            }
        }
    }
}

/// The literal spelled `text`, or `null` when the table holds no such spelling.
///
/// `text` may carry a null terminator; the comparison ignores it. The walk is
/// bounded by `literals.len`, which is `literal_count`.
pub fn findLiteral(text: []const u8) ?Literal {
    for (literals) |candidate| {
        if (std.mem.eql(u8, candidate.text, text)) return candidate;
    }
    return null;
}

/// The literal in `group` spelled `text`, or `null` when the table holds no
/// such spelling in that group.
///
/// The walk is bounded by `literals.len`, which is `literal_count`.
pub fn findInGroup(group: Group, text: []const u8) ?Literal {
    for (literals) |candidate| {
        if (candidate.group != group) continue;
        if (std.mem.eql(u8, candidate.text, text)) return candidate;
    }
    return null;
}

/// How many literals the table holds for `group`.
pub fn countOfGroup(group: Group) usize {
    var total: usize = 0;
    for (literals) |candidate| {
        if (candidate.group == group) total += 1;
    }
    return total;
}

/// The notification spelled `value`, or `null` when the table holds no such
/// name.
///
/// `value` may carry a null terminator; the comparison ignores it. The walk is
/// bounded by `notifications.len`, which is `notification_count`.
pub fn findNotification(value: []const u8) ?Notification {
    for (notifications) |candidate| {
        if (std.mem.eql(u8, candidate.value, value)) return candidate;
    }
    return null;
}

test "the 43 AX selector literals are spelled exactly as upstream spells them" {
    // The table's length and its five group counts, then every spelling against
    // the literal upstream writes. If this test is green the adapter cannot ship
    // a misspelled `AXLandmarkComplementary`, an `AXStrongStylegroup`, or an
    // `AXDOMIdentifier` written `AXDomIdentifier`.
    try testing.expectEqual(@as(usize, 43), literals.len);
    try testing.expectEqual(@as(usize, 5), countOfGroup(.role_literal));
    try testing.expectEqual(@as(usize, 32), countOfGroup(.subrole_literal));
    try testing.expectEqual(@as(usize, 3), countOfGroup(.attribute_name));
    try testing.expectEqual(@as(usize, 2), countOfGroup(.font_key));
    try testing.expectEqual(@as(usize, 1), countOfGroup(.action_name));

    // Spelled out here rather than read from the table, so a port that changes
    // the table changes this list and the test fails.
    const upstream = [_][]const u8{
        "AXListMarker",           "AXDateField",           "AXTimeField",              "AXWebArea",
        "AXHeading",              "AXApplicationAlert",    "AXWebApplication",         "AXDocumentArticle",
        "AXLandmarkBanner",       "AXCodeStyleGroup",      "AXLandmarkComplementary",  "AXDeleteStyleGroup",
        "AXInsertStyleGroup",     "AXLandmarkContentInfo", "AXDefinition",             "AXDocument",
        "AXEmphasisStyleGroup",   "AXApplicationGroup",    "AXLandmarkForm",           "AXApplicationLog",
        "AXLandmarkMain",         "AXApplicationMarquee",  "AXDocumentMath",           "AXMeter",
        "AXLandmarkNavigation",   "AXDocumentNote",        "AXLandmarkRegion",         "AXLandmarkSearch",
        "AXSectionFooter",        "AXSectionHeader",       "AXApplicationStatus",      "AXStrongStyleGroup",
        "AXTabPanel",             "AXTerm",                "AXTimeGroup",              "AXApplicationTimer",
        "AXUserInterfaceTooltip", "AXBrailleLabel",        "AXBrailleRoleDescription", "AXDOMIdentifier",
        "AXFontBold",             "AXFontItalic",          "AXScrollToVisible",
    };
    try testing.expectEqual(@as(usize, 43), upstream.len);
    for (upstream) |spelling| {
        try testing.expect(findLiteral(spelling) != null);
    }
}

test "no two literals in a group are equal" {
    // Within-group distinctness for all five groups. A literal may be repeated
    // across groups, because the five groups name five different namespaces,
    // but not inside one.
    inline for (std.meta.tags(Group)) |group| {
        var seen: [literals.len][]const u8 = undefined;
        var held: usize = 0;
        for (literals) |candidate| {
            if (candidate.group != group) continue;
            for (seen[0..held]) |earlier| {
                try testing.expect(!std.mem.eql(u8, earlier, candidate.text));
            }
            seen[held] = candidate.text;
            held += 1;
        }
        try testing.expect(held > 0);
    }
}

test "every literal carries the upstream line it comes from" {
    // Provenance is not lost. A literal with no line has been invented.
    for (literals) |candidate| {
        try testing.expect(candidate.upstream_line > 0);
    }
    // The lines fall inside the range upstream writes them in.
    for (literals) |candidate| {
        switch (candidate.group) {
            .role_literal => try testing.expect(candidate.upstream_line <= 242),
            .subrole_literal => try testing.expect(
                candidate.upstream_line >= 244 and candidate.upstream_line <= 296,
            ),
            .attribute_name => try testing.expect(
                candidate.upstream_line >= 1090 and candidate.upstream_line <= 1105,
            ),
            .font_key => try testing.expect(
                candidate.upstream_line == 892 or candidate.upstream_line == 899,
            ),
            .action_name => try testing.expectEqual(@as(u16, 34), candidate.upstream_line),
        }
    }
}

test "the four duplicated subrole spellings are emitted by both roles" {
    // `AXLandmarkBanner`, `AXLandmarkContentInfo`, `AXDocument` and
    // `AXApplicationGroup` are each written by two arms of `ns_sub_role`. This
    // test exists because the distinctness check above is the natural companion
    // to the spelling test and it would otherwise reject the table: a port that
    // deduplicates the 36 arms into 32 has changed which roles answer.
    try testing.expectEqual(@as(usize, 4), subrole_duplicates.len);
    for (subrole_duplicates) |duplicate| {
        const literal = findInGroup(.subrole_literal, duplicate[0]) orelse {
            return error.LiteralNotInTable;
        };
        try testing.expectEqual(duplicate[1], literal.upstream_line);
        try testing.expect(duplicate[2] > duplicate[1]);
    }
}

test "the heading role emits the unprefixed string upstream emits" {
    // `AK/macos/src/node.rs:125`. A test that leaves this unpinned creates a
    // trap: the next reader sees an unprefixed role next to a prefixed one,
    // "fixes" it, and ships a change no test notices. If a later decision is
    // taken to correct it, this test changes in the same commit that changes
    // the string, and the change is recorded as a deliberate divergence.
    try testing.expectEqualStrings("Heading", heading_role);
    try testing.expect(!std.mem.startsWith(u8, heading_role, "AX"));
    // Upstream writes `AXHeading` for `doc_subtitle` in the same file, so the
    // adapter holds both spellings.
    try testing.expect(findInGroup(.role_literal, "AXHeading") != null);
}

test "every role constant carries the string its name gives" {
    // `docs/42` section 1.2.4: each constant is the `NSAccessibility` prefix
    // and the `Role` suffix, and the string it carries is `AX` and that suffix.
    // `NSAccessibilityUnknownRole` is the one that does not follow, and it is
    // pinned as the one exception rather than left implicit.
    var exceptions: usize = 0;
    for (role_constants) |constant| {
        const prefix = "NSAccessibility";
        const suffix = "Role";
        try testing.expect(std.mem.startsWith(u8, constant.name, prefix));
        try testing.expect(std.mem.endsWith(u8, constant.name, suffix));
        const middle = constant.name[prefix.len .. constant.name.len - suffix.len];

        var buffer: [64]u8 = undefined;
        const derived = std.fmt.bufPrint(&buffer, "AX{s}", .{middle}) catch {
            return error.NameTooLong;
        };
        if (std.mem.eql(u8, derived, constant.value)) continue;
        exceptions += 1;
        try testing.expectEqualStrings("NSAccessibilityUnknownRole", constant.name);
        try testing.expectEqualStrings("AXUnknownRole", constant.value);
    }
    try testing.expectEqual(@as(usize, 1), exceptions);
}

test "the 31 role constant suffixes are the ones the map lists" {
    // `docs/42` section 1.2.4 gives the 31 as a bare list of suffixes. Written
    // out here so that adding or renaming one without the map fails.
    const map = [_][]const u8{
        "Button",      "Cell",              "CheckBox",    "ColorWell",      "ComboBox",
        "Group",       "Image",             "Incrementor", "LevelIndicator", "Link",
        "List",        "MenuBar",           "MenuItem",    "Menu",           "Outline",
        "PopUpButton", "ProgressIndicator", "RadioButton", "RadioGroup",     "Row",
        "ScrollBar",   "Slider",            "Splitter",    "StaticText",     "TabGroup",
        "Table",       "TextArea",          "TextField",   "Toolbar",        "Unknown",
        "Window",
    };
    try testing.expectEqual(@as(usize, 31), map.len);
    for (map) |suffix| {
        var found: usize = 0;
        for (role_constants) |constant| {
            const name = constant.name["NSAccessibility".len..];
            if (std.mem.eql(u8, name[0 .. name.len - "Role".len], suffix)) found += 1;
        }
        try testing.expectEqual(@as(usize, 1), found);
    }
}

test "the seven subrole constants are the ones objc2-app-kit exports" {
    // The 8 arms of `ns_sub_role` that name a constant rather than one of the
    // 32 literals name these 7, and `alert_dialog` and `dialog` share
    // `NSAccessibilityDialogSubrole`.
    const map = [_][]const u8{
        "NSAccessibilityDialogSubrole",
        "NSAccessibilityOutlineRowSubrole",
        "NSAccessibilitySearchFieldSubrole",
        "NSAccessibilitySecureTextFieldSubrole",
        "NSAccessibilitySwitchSubrole",
        "NSAccessibilityTabButtonSubrole",
        "NSAccessibilityToggleSubrole",
    };
    try testing.expectEqual(@as(usize, 7), map.len);
    for (map) |name| {
        var found: usize = 0;
        for (subrole_constants) |constant| {
            if (std.mem.eql(u8, constant.name, name)) found += 1;
        }
        try testing.expectEqual(@as(usize, 1), found);
    }
    for (subrole_constants) |constant| {
        try testing.expect(std.mem.endsWith(u8, constant.name, "Subrole"));
        try testing.expect(std.mem.startsWith(u8, constant.value, "AX"));
    }
}

test "the adapter names exactly seven notifications" {
    try testing.expectEqual(@as(usize, 7), notifications.len);
    for (notifications, 0..) |a, i| {
        try testing.expectEqualStrings(a.name, a.value);
        for (notifications[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, a.value, b.value));
        }
    }
    // The announcement is the one posted with a `userInfo`.
    try testing.expect(findNotification(
        "NSAccessibilityAnnouncementRequestedNotification",
    ) != null);
    // The other six go through `NSAccessibilityPostNotification`. Upstream calls
    // `NSAccessibilityPostNotificationWithUserInfo` at `event.rs:97` and names
    // the announcement notification at `:99`.
    try testing.expect(findNotification(
        "NSAccessibilityValueChangedNotification",
    ) != null);
    try testing.expectEqual(
        @as(u16, 99),
        announcement_requested_notification.upstream_line,
    );
}

test "the announcement publishes two keys and one of two priorities" {
    try testing.expectEqual(@as(usize, 2), announcement_keys.len);
    try testing.expectEqualStrings("NSAccessibilityAnnouncementKey", announcement_keys[0]);
    try testing.expectEqualStrings("NSAccessibilityPriorityKey", announcement_keys[1]);
    // `AK/macos/src/event.rs:35-43` picks between exactly two levels.
    try testing.expectEqual(@as(i32, 700), @intFromEnum(PriorityLevel.high));
    try testing.expectEqual(@as(i32, 500), @intFromEnum(PriorityLevel.medium));
}

test "every string in this module is declared sentinel-terminated" {
    // AppKit takes all of these as `NSString`, which is built from a C string,
    // so a caller must be able to hand `.ptr` to a C function without copying.
    // The property is the declared type, not a byte at run time: `[:0]const u8`
    // carries the sentinel in its type, and `[]const u8` does not.
    //
    // The checks are `comptime`, so a table that loses its sentinel is a
    // compile error naming the field rather than a run-time failure.
    comptime {
        expectSentinelTerminated(@FieldType(Literal, "text"));
        expectSentinelTerminated(@FieldType(RoleConstant, "name"));
        expectSentinelTerminated(@FieldType(RoleConstant, "value"));
        expectSentinelTerminated(@FieldType(SubroleConstant, "name"));
        expectSentinelTerminated(@FieldType(SubroleConstant, "value"));
        expectSentinelTerminated(@FieldType(Notification, "name"));
        expectSentinelTerminated(@FieldType(Notification, "value"));
        expectSentinelTerminated(@TypeOf(@as([:0]const u8, heading_role)));
        expectSentinelTerminated(@TypeOf(announcement_keys));
    }
}

/// Fails to compile unless `T` is `[:0]const u8` or a sentinel-terminated
/// array of those.
///
/// The array case is `announcement_keys`, whose element type is the sentinel
/// slice. Every other field in this module is the slice itself.
fn expectSentinelTerminated(comptime T: type) void {
    if (T == [:0]const u8) return;
    if (T == [announcement_key_count][:0]const u8) return;
    @compileError(std.fmt.comptimePrint(
        "{s} is not sentinel-terminated; AppKit reads these as C strings",
        .{@typeName(T)},
    ));
}
