//! The 43 Android SDK constants the adapter names at `AK/android/src/util.rs:14-68`.
//!
//! `docs/42-native-adapter-build-map.md` section 1.4.1 measured the figure by
//! reading those 55 lines. The map states that the constants are plain integers
//! and strings rather than header entries, so a Zig port copies them verbatim.
//! This module copies the 43 **names**, in the map's ten groups, and holds the
//! one value the map gives: `host_view_id` is `-1` at `util.rs:52`.
//!
//! **The other 42 have no value here, and that is a recorded gap rather than an
//! oversight.** No document under `docs/` records the integer behind any of
//! them, and the upstream file is not on this host. A Zig declaration that
//! guessed `ACTION_CLICK = 16` would be a claim with nothing behind it, and
//! `GetFieldID` would fail on a device for exactly that reason. Milestone M10
//! fills these from `AK/android/src/util.rs:14-68`.
//!
//! **Why the spellings are still pinned.** The five `ACTION_ARGUMENT_*` names
//! and `android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE` are not
//! integers at all: they are the keys the adapter reads out of the `Bundle`
//! that Android hands with an action. A misspelt key is a silent miss at run
//! time, so the exact spelling is the part that has to be pinned.
//!
//! **The loop bound.** Every loop over `constants` walks the array, whose
//! length is `constant_count` and is a type-level fact. The loop over `groups`
//! walks the 10 group records.

const std = @import("std");

const testing = std.testing;

/// Which kind of Android constant one name is.
pub const Group = enum {
    /// One of the 10 action ids the adapter puts on a node.
    action_id,
    /// One of the 5 keys read out of the action `Bundle`.
    action_argument,
    /// One of the 12 `AccessibilityEvent` type ids the adapter sends.
    event_type,
    /// The 1 content-change type the adapter sends with a subtree change.
    content_change_type,
    /// One of the 2 focus input modes the adapter answers `findFocus` with.
    focus_input_mode,
    /// One of the 3 live-region levels.
    live_region,
    /// One of the 3 hover motion actions.
    motion_action,
    /// One of the 4 movement granularities.
    movement_granularity,
    /// One of the 2 range types on a text range.
    range_type,
    /// The 1 sentinel that means the host view itself.
    host_sentinel,
};

/// One Android constant, as the identifier the upstream source writes.
///
/// `name` is the exact spelling, including the package-qualified form of
/// `ARGUMENT_PROGRESS_VALUE`, because that is what `Bundle.get` and
/// `Bundle.putString` are given.
pub const Constant = struct {
    group: Group,
    name: [:0]const u8,
};

/// How many names `constants` holds.
pub const constant_count = 43;

/// The ten groups, with the row count the map gives each.
pub const groups = [_]struct { group: Group, rows: usize }{
    .{ .group = .action_id, .rows = 10 },
    .{ .group = .action_argument, .rows = 5 },
    .{ .group = .event_type, .rows = 12 },
    .{ .group = .content_change_type, .rows = 1 },
    .{ .group = .focus_input_mode, .rows = 2 },
    .{ .group = .live_region, .rows = 3 },
    .{ .group = .motion_action, .rows = 3 },
    .{ .group = .movement_granularity, .rows = 4 },
    .{ .group = .range_type, .rows = 2 },
    .{ .group = .host_sentinel, .rows = 1 },
};

/// Every Android constant the adapter names, in the map's group order.
pub const constants = [constant_count]Constant{
    // 10 action ids.
    .{ .group = .action_id, .name = "ACTION_FOCUS" },
    .{ .group = .action_id, .name = "ACTION_CLICK" },
    .{ .group = .action_id, .name = "ACTION_ACCESSIBILITY_FOCUS" },
    .{ .group = .action_id, .name = "ACTION_CLEAR_ACCESSIBILITY_FOCUS" },
    .{ .group = .action_id, .name = "ACTION_NEXT_AT_MOVEMENT_GRANULARITY" },
    .{ .group = .action_id, .name = "ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY" },
    .{ .group = .action_id, .name = "ACTION_SCROLL_FORWARD" },
    .{ .group = .action_id, .name = "ACTION_SCROLL_BACKWARD" },
    .{ .group = .action_id, .name = "ACTION_SET_SELECTION" },
    .{ .group = .action_id, .name = "ACTION_SET_PROGRESS" },
    // 5 action argument names.
    .{ .group = .action_argument, .name = "ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT" },
    .{ .group = .action_argument, .name = "ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN" },
    .{ .group = .action_argument, .name = "ACTION_ARGUMENT_SELECTION_START_INT" },
    .{ .group = .action_argument, .name = "ACTION_ARGUMENT_SELECTION_END_INT" },
    .{
        .group = .action_argument,
        .name = "android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE",
    },
    // 12 event type ids.
    .{ .group = .event_type, .name = "EVENT_VIEW_CLICKED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_SELECTED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_FOCUSED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_TEXT_CHANGED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_HOVER_ENTER" },
    .{ .group = .event_type, .name = "EVENT_VIEW_HOVER_EXIT" },
    .{ .group = .event_type, .name = "EVENT_VIEW_SCROLLED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_TEXT_SELECTION_CHANGED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_ACCESSIBILITY_FOCUSED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED" },
    .{ .group = .event_type, .name = "EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY" },
    .{ .group = .event_type, .name = "EVENT_WINDOW_CONTENT_CHANGED" },
    // 1 content change type.
    .{ .group = .content_change_type, .name = "CONTENT_CHANGE_TYPE_SUBTREE" },
    // 2 focus input modes.
    .{ .group = .focus_input_mode, .name = "FOCUS_INPUT" },
    .{ .group = .focus_input_mode, .name = "FOCUS_ACCESSIBILITY" },
    // 3 live region levels.
    .{ .group = .live_region, .name = "LIVE_REGION_NONE" },
    .{ .group = .live_region, .name = "LIVE_REGION_POLITE" },
    .{ .group = .live_region, .name = "LIVE_REGION_ASSERTIVE" },
    // 3 hover motion actions.
    .{ .group = .motion_action, .name = "MOTION_ACTION_HOVER_MOVE" },
    .{ .group = .motion_action, .name = "MOTION_ACTION_HOVER_ENTER" },
    .{ .group = .motion_action, .name = "MOTION_ACTION_HOVER_EXIT" },
    // 4 movement granularities.
    .{ .group = .movement_granularity, .name = "MOVEMENT_GRANULARITY_CHARACTER" },
    .{ .group = .movement_granularity, .name = "MOVEMENT_GRANULARITY_WORD" },
    .{ .group = .movement_granularity, .name = "MOVEMENT_GRANULARITY_LINE" },
    .{ .group = .movement_granularity, .name = "MOVEMENT_GRANULARITY_PARAGRAPH" },
    // 2 range types.
    .{ .group = .range_type, .name = "RANGE_TYPE_INT" },
    .{ .group = .range_type, .name = "RANGE_TYPE_FLOAT" },
    // The 1 host sentinel.
    .{ .group = .host_sentinel, .name = "HOST_VIEW_ID" },
};

/// The virtual view id that means the host view itself.
///
/// `AK/android/src/util.rs:52` gives this value, and
/// `docs/29-apple-android-apis.md` row 52 confirms it. The root of every tree
/// the adapter builds carries it, and `docs/42` section 4.3 names it as the
/// reason Android needs a virtual id map at all.
pub const host_view_id: i32 = -1;

comptime {
    @setEvalBranchQuota(200_000);
    for (groups) |group| {
        if (countOf(group.group) != group.rows) {
            @compileError(std.fmt.comptimePrint(
                "group .{s} holds {d} constants, the map gives {d}",
                .{ @tagName(group.group), countOf(group.group), group.rows },
            ));
        }
    }
    for (constants, 0..) |a, i| {
        for (constants[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate constant at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.name },
                ));
            }
        }
    }
    if (constants.len != constant_count) @compileError("the array length is the count");
}

/// How many rows of `constants` belong to `group`.
pub fn countOf(group: Group) usize {
    var total: usize = 0;
    for (constants) |constant| {
        if (constant.group == group) total += 1;
    }
    return total;
}

/// The constant spelled `name`, or `null` when the table holds no such
/// spelling.
pub fn find(name: []const u8) ?Constant {
    for (constants) |candidate| {
        if (std.mem.eql(u8, candidate.name, name)) return candidate;
    }
    return null;
}

test "the table holds the 43 constants of map section 1.4.1" {
    try testing.expectEqual(@as(usize, 43), constants.len);
    var total: usize = 0;
    for (groups) |group| total += group.rows;
    try testing.expectEqual(constant_count, total);
}

test "every action id is spelled as the map spells it" {
    try expectGroup(.action_id, &.{
        "ACTION_FOCUS",
        "ACTION_CLICK",
        "ACTION_ACCESSIBILITY_FOCUS",
        "ACTION_CLEAR_ACCESSIBILITY_FOCUS",
        "ACTION_NEXT_AT_MOVEMENT_GRANULARITY",
        "ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY",
        "ACTION_SCROLL_FORWARD",
        "ACTION_SCROLL_BACKWARD",
        "ACTION_SET_SELECTION",
        "ACTION_SET_PROGRESS",
    });
}

test "every action argument name is spelled as the map spells it" {
    // The last one keeps its package-qualified form, because that is the key
    // Android puts in the `Bundle`.
    try expectGroup(.action_argument, &.{
        "ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT",
        "ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN",
        "ACTION_ARGUMENT_SELECTION_START_INT",
        "ACTION_ARGUMENT_SELECTION_END_INT",
        "android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE",
    });
}

test "every event type id is spelled as the map spells it" {
    try expectGroup(.event_type, &.{
        "EVENT_VIEW_CLICKED",
        "EVENT_VIEW_SELECTED",
        "EVENT_VIEW_FOCUSED",
        "EVENT_VIEW_TEXT_CHANGED",
        "EVENT_VIEW_HOVER_ENTER",
        "EVENT_VIEW_HOVER_EXIT",
        "EVENT_VIEW_SCROLLED",
        "EVENT_VIEW_TEXT_SELECTION_CHANGED",
        "EVENT_VIEW_ACCESSIBILITY_FOCUSED",
        "EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED",
        "EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY",
        "EVENT_WINDOW_CONTENT_CHANGED",
    });
}

// The test name is one string literal, and `test` takes no expression for a
// name, so the line cannot wrap. The name is not reworded either: it lists the
// six groups it covers and matches the sibling test above, which uses the same
// "is spelled as the map spells it" wording.
test "every content change, focus, live region, motion, granularity and range name is spelled as the map spells it" {
    try expectGroup(.content_change_type, &.{"CONTENT_CHANGE_TYPE_SUBTREE"});
    try expectGroup(.focus_input_mode, &.{ "FOCUS_INPUT", "FOCUS_ACCESSIBILITY" });
    try expectGroup(.live_region, &.{
        "LIVE_REGION_NONE",
        "LIVE_REGION_POLITE",
        "LIVE_REGION_ASSERTIVE",
    });
    try expectGroup(.motion_action, &.{
        "MOTION_ACTION_HOVER_MOVE",
        "MOTION_ACTION_HOVER_ENTER",
        "MOTION_ACTION_HOVER_EXIT",
    });
    try expectGroup(.movement_granularity, &.{
        "MOVEMENT_GRANULARITY_CHARACTER",
        "MOVEMENT_GRANULARITY_WORD",
        "MOVEMENT_GRANULARITY_LINE",
        "MOVEMENT_GRANULARITY_PARAGRAPH",
    });
    try expectGroup(.range_type, &.{ "RANGE_TYPE_INT", "RANGE_TYPE_FLOAT" });
}

test "the host sentinel is named and carries the value the map gives" {
    const sentinel = find("HOST_VIEW_ID");
    try testing.expect(sentinel != null);
    try testing.expectEqual(Group.host_sentinel, sentinel.?.group);
    try testing.expectEqual(@as(i32, -1), host_view_id);
    try testing.expectEqual(@as(?Constant, null), find("NO_SUCH_CONSTANT"));
}

/// Checks that the constants of `group` are exactly `expected`, in order.
fn expectGroup(group: Group, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, countOf(group));
    var seen: usize = 0;
    for (constants) |constant| {
        if (constant.group != group) continue;
        try testing.expectEqualStrings(expected[seen], constant.name);
        seen += 1;
    }
    try testing.expectEqual(expected.len, seen);
}
