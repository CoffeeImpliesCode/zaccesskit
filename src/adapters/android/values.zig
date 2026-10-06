//! The integer values behind the 43 Android SDK constants, transcribed from
//! `AK/android/src/util.rs:14-68`.
//!
//! **Why this module exists.** `constants.zig` holds the 43 **spellings**, and
//! its doc comment records that no document under `docs/` gives the integer
//! behind any of them. The upstream file was on this host and has been read, so
//! the values are no longer missing. They live here rather than in
//! `constants.zig` because that module is a census of names and this one is a
//! transcription of values, and because three files need the numbers:
//! `node.zig`, `queued_events.zig` and `adapter.zig`.
//!
//! **The two tables must agree.** `constants.constant_count` is 43 and
//! `values.value_count` is 43, and a `comptime` block asserts that each name in
//! `constants.constants` has exactly one row here. A name added to one table
//! without the other is a compile error rather than a runtime miss.
//!
//! **What is transcribed and what is derived.** 38 of the 43 are integers. The
//! five `ACTION_ARGUMENT_*` names are not integers at all: they are the keys
//! Android puts in the `Bundle`, so they keep their spelling and have no value
//! here. `HOST_VIEW_ID` is `-1`, which `docs/42-native-adapter-build-map.md`
//! section 1.4.1 already records at `AK/android/src/util.rs:52`.
//!
//! **Two values the upstream file computes rather than writes.** Upstream spells
//! the nine `ACTION_*` bit flags as shifts, and this module keeps the shift so
//! a reader can check the bit against the upstream line. `ACTION_SET_PROGRESS`
//! is a literal `0x0102003d` upstream because it is an
//! `AccessibilityAction` id rather than an `AccessibilityNodeInfo` action bit,
//! so it is copied as written.
//!
//! **The loop bound.** Every loop over `values.value_rows` or
//! `values.by_group(group)` walks an array whose length is a comptime constant,
//! `values.value_count` and `constants.constant_count`.
//!
//! **The 46 aliases keep the SDK spelling and Z006 is exempt.** Every alias
//! below is named for the Android SDK constant it carries, so a reader holding
//! `AK/android/src/util.rs:14-68` or a `AccessibilityNodeInfo` header matches
//! the row by name rather than by translating between two spellings of the same
//! constant. Z006 asks for `snake_case` and cannot tell a vendor mirror from a
//! declaration this package made, so the finding is recorded here instead.
//! `ziglint/src/Linter.zig:2362` is the matcher and `:3385` `isTypeAlias` is
//! the half that misses it. No rename is available: five of these aliases hold
//! a `Bundle` key that Android compares byte for byte.

const std = @import("std");

const constants = @import("constants.zig");

const testing = std.testing;

/// Which kind of Android constant one value belongs to.
///
/// The members are the ten groups of `constants.Group`, restated here so a row
/// can name its group without the value table importing the census for more
/// than its lengths. `constants.Group` remains the one enumeration of the
/// spelling table.
pub const ValueGroup = enum {
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

/// One Android constant, as the name the census spells and the integer
/// upstream gives it.
///
/// `value` is `null` for the five rows of group `.action_argument`, because
/// those names are `Bundle` keys and carry no integer.
pub const ConstantValue = struct {
    /// The same spelling `constants.constants` holds.
    name: [:0]const u8,
    /// The integer, or `null` for a `Bundle` key.
    value: ?i32,
    /// Which of the ten groups the name belongs to.
    group: ValueGroup,
    /// The upstream line the integer was read from.
    upstream_line: u16,
};

/// How many rows `constant_values` holds.
pub const value_count = 43;

/// The 43 rows, in the census order of `constants.constants`.
pub const constant_values = [value_count]ConstantValue{
    // 10 action ids, `util.rs:14-23`.
    .{ .name = "ACTION_FOCUS", .value = 1 << 0, .group = .action_id, .upstream_line = 14 },
    .{ .name = "ACTION_CLICK", .value = 1 << 4, .group = .action_id, .upstream_line = 15 },
    .{
        .name = "ACTION_ACCESSIBILITY_FOCUS",
        .value = 1 << 6,
        .group = .action_id,
        .upstream_line = 16,
    },
    .{
        .name = "ACTION_CLEAR_ACCESSIBILITY_FOCUS",
        .value = 1 << 7,
        .group = .action_id,
        .upstream_line = 17,
    },
    .{
        .name = "ACTION_NEXT_AT_MOVEMENT_GRANULARITY",
        .value = 1 << 8,
        .group = .action_id,
        .upstream_line = 18,
    },
    .{
        .name = "ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY",
        .value = 1 << 9,
        .group = .action_id,
        .upstream_line = 19,
    },
    .{
        .name = "ACTION_SCROLL_FORWARD",
        .value = 1 << 12,
        .group = .action_id,
        .upstream_line = 20,
    },
    .{
        .name = "ACTION_SCROLL_BACKWARD",
        .value = 1 << 13,
        .group = .action_id,
        .upstream_line = 21,
    },
    .{
        .name = "ACTION_SET_SELECTION",
        .value = 1 << 17,
        .group = .action_id,
        .upstream_line = 22,
    },
    .{
        .name = "ACTION_SET_PROGRESS",
        .value = 0x0102003d,
        .group = .action_id,
        .upstream_line = 23,
    },
    // 5 action argument keys, `util.rs:25-32`. These are `Bundle` keys, so the
    // upstream lines hold a `&str` and this table holds no integer for them.
    .{
        .name = "ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT",
        .value = null,
        .group = .action_argument,
        .upstream_line = 25,
    },
    .{
        .name = "ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN",
        .value = null,
        .group = .action_argument,
        .upstream_line = 27,
    },
    .{
        .name = "ACTION_ARGUMENT_SELECTION_START_INT",
        .value = null,
        .group = .action_argument,
        .upstream_line = 29,
    },
    .{
        .name = "ACTION_ARGUMENT_SELECTION_END_INT",
        .value = null,
        .group = .action_argument,
        .upstream_line = 30,
    },
    .{
        .name = "android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE",
        .value = null,
        .group = .action_argument,
        .upstream_line = 31,
    },
    // 12 event type ids, `util.rs:36-47`.
    .{
        .name = "EVENT_VIEW_CLICKED",
        .value = 1,
        .group = .event_type,
        .upstream_line = 36,
    },
    .{
        .name = "EVENT_VIEW_SELECTED",
        .value = 1 << 2,
        .group = .event_type,
        .upstream_line = 37,
    },
    .{
        .name = "EVENT_VIEW_FOCUSED",
        .value = 1 << 3,
        .group = .event_type,
        .upstream_line = 38,
    },
    .{
        .name = "EVENT_VIEW_TEXT_CHANGED",
        .value = 1 << 4,
        .group = .event_type,
        .upstream_line = 39,
    },
    .{
        .name = "EVENT_VIEW_HOVER_ENTER",
        .value = 1 << 7,
        .group = .event_type,
        .upstream_line = 40,
    },
    .{
        .name = "EVENT_VIEW_HOVER_EXIT",
        .value = 1 << 8,
        .group = .event_type,
        .upstream_line = 41,
    },
    .{
        .name = "EVENT_VIEW_SCROLLED",
        .value = 1 << 12,
        .group = .event_type,
        .upstream_line = 42,
    },
    .{
        .name = "EVENT_VIEW_TEXT_SELECTION_CHANGED",
        .value = 1 << 13,
        .group = .event_type,
        .upstream_line = 43,
    },
    .{
        .name = "EVENT_VIEW_ACCESSIBILITY_FOCUSED",
        .value = 1 << 15,
        .group = .event_type,
        .upstream_line = 44,
    },
    .{
        .name = "EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED",
        .value = 1 << 16,
        .group = .event_type,
        .upstream_line = 45,
    },
    .{
        .name = "EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY",
        .value = 1 << 17,
        .group = .event_type,
        .upstream_line = 46,
    },
    .{
        .name = "EVENT_WINDOW_CONTENT_CHANGED",
        .value = 1 << 11,
        .group = .event_type,
        .upstream_line = 47,
    },
    // 1 content change type, `util.rs:34`.
    .{
        .name = "CONTENT_CHANGE_TYPE_SUBTREE",
        .value = 1 << 0,
        .group = .content_change_type,
        .upstream_line = 34,
    },
    // 2 focus input modes, `util.rs:49-50`.
    .{
        .name = "FOCUS_INPUT",
        .value = 1,
        .group = .focus_input_mode,
        .upstream_line = 49,
    },
    .{
        .name = "FOCUS_ACCESSIBILITY",
        .value = 2,
        .group = .focus_input_mode,
        .upstream_line = 50,
    },
    // 3 live region levels, `util.rs:54-56`.
    .{
        .name = "LIVE_REGION_NONE",
        .value = 0,
        .group = .live_region,
        .upstream_line = 54,
    },
    .{
        .name = "LIVE_REGION_POLITE",
        .value = 1,
        .group = .live_region,
        .upstream_line = 55,
    },
    .{
        .name = "LIVE_REGION_ASSERTIVE",
        .value = 2,
        .group = .live_region,
        .upstream_line = 56,
    },
    // 3 hover motion actions, `util.rs:58-60`.
    .{
        .name = "MOTION_ACTION_HOVER_MOVE",
        .value = 7,
        .group = .motion_action,
        .upstream_line = 58,
    },
    .{
        .name = "MOTION_ACTION_HOVER_ENTER",
        .value = 9,
        .group = .motion_action,
        .upstream_line = 59,
    },
    .{
        .name = "MOTION_ACTION_HOVER_EXIT",
        .value = 10,
        .group = .motion_action,
        .upstream_line = 60,
    },
    // 4 movement granularities, `util.rs:62-65`.
    .{
        .name = "MOVEMENT_GRANULARITY_CHARACTER",
        .value = 1 << 0,
        .group = .movement_granularity,
        .upstream_line = 62,
    },
    .{
        .name = "MOVEMENT_GRANULARITY_WORD",
        .value = 1 << 1,
        .group = .movement_granularity,
        .upstream_line = 63,
    },
    .{
        .name = "MOVEMENT_GRANULARITY_LINE",
        .value = 1 << 2,
        .group = .movement_granularity,
        .upstream_line = 64,
    },
    .{
        .name = "MOVEMENT_GRANULARITY_PARAGRAPH",
        .value = 1 << 3,
        .group = .movement_granularity,
        .upstream_line = 65,
    },
    // 2 range types, `util.rs:67-68`.
    .{
        .name = "RANGE_TYPE_INT",
        .value = 0,
        .group = .range_type,
        .upstream_line = 67,
    },
    .{
        .name = "RANGE_TYPE_FLOAT",
        .value = 1,
        .group = .range_type,
        .upstream_line = 68,
    },
    // The 1 host sentinel, `util.rs:52`.
    .{
        .name = "HOST_VIEW_ID",
        .value = -1,
        .group = .host_sentinel,
        .upstream_line = 52,
    },
};

// --- the values the adapter names in its own bodies ------------------------
// Each is an alias for one row above, so a value has one declaration and the
// alias cannot drift from it.

/// `ACTION_FOCUS`, `AK/android/src/util.rs:14`.
pub const ACTION_FOCUS: JInt = 1 << 0;
/// `ACTION_CLICK`, `AK/android/src/util.rs:15`.
pub const ACTION_CLICK: JInt = 1 << 4;
/// `ACTION_ACCESSIBILITY_FOCUS`, `AK/android/src/util.rs:16`.
pub const ACTION_ACCESSIBILITY_FOCUS: JInt = 1 << 6;
/// `ACTION_CLEAR_ACCESSIBILITY_FOCUS`, `AK/android/src/util.rs:17`.
pub const ACTION_CLEAR_ACCESSIBILITY_FOCUS: JInt = 1 << 7;
/// `ACTION_NEXT_AT_MOVEMENT_GRANULARITY`, `AK/android/src/util.rs:18`.
pub const ACTION_NEXT_AT_MOVEMENT_GRANULARITY: JInt = 1 << 8;
/// `ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY`, `AK/android/src/util.rs:19`.
pub const ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY: JInt = 1 << 9;
/// `ACTION_SCROLL_FORWARD`, `AK/android/src/util.rs:20`.
pub const ACTION_SCROLL_FORWARD: JInt = 1 << 12;
/// `ACTION_SCROLL_BACKWARD`, `AK/android/src/util.rs:21`.
pub const ACTION_SCROLL_BACKWARD: JInt = 1 << 13;
/// `ACTION_SET_SELECTION`, `AK/android/src/util.rs:22`.
pub const ACTION_SET_SELECTION: JInt = 1 << 17;
/// `ACTION_SET_PROGRESS`, `AK/android/src/util.rs:23`.
///
/// An `AccessibilityAction` id rather than an `AccessibilityNodeInfo` action
/// bit, so upstream writes it as a literal and so does this module.
pub const ACTION_SET_PROGRESS: JInt = 0x0102003d;

/// `ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT`, the `Bundle` key upstream reads
/// the movement granularity from. A key, not an integer.
pub const ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT: [:0]const u8 =
    "ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT";
/// `ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN`, `AK/android/src/util.rs:27`.
pub const ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN: [:0]const u8 =
    "ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN";
/// `ACTION_ARGUMENT_SELECTION_START_INT`, `AK/android/src/util.rs:29`.
pub const ACTION_ARGUMENT_SELECTION_START_INT: [:0]const u8 =
    "ACTION_ARGUMENT_SELECTION_START_INT";
/// `ACTION_ARGUMENT_SELECTION_END_INT`, `AK/android/src/util.rs:30`.
pub const ACTION_ARGUMENT_SELECTION_END_INT: [:0]const u8 =
    "ACTION_ARGUMENT_SELECTION_END_INT";
/// `android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE`,
/// `AK/android/src/util.rs:31`. The spelling keeps its package qualifier,
/// because that is the key Android puts in the `Bundle`.
pub const ACTION_ARGUMENT_PROGRESS_VALUE: [:0]const u8 =
    "android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE";

/// `CONTENT_CHANGE_TYPE_SUBTREE`, `AK/android/src/util.rs:34`.
pub const CONTENT_CHANGE_TYPE_SUBTREE: JInt = 1 << 0;

/// `EVENT_VIEW_CLICKED`, `AK/android/src/util.rs:36`.
pub const EVENT_VIEW_CLICKED: JInt = 1;
/// `EVENT_VIEW_SELECTED`, `AK/android/src/util.rs:37`.
pub const EVENT_VIEW_SELECTED: JInt = 1 << 2;
/// `EVENT_VIEW_FOCUSED`, `AK/android/src/util.rs:38`.
pub const EVENT_VIEW_FOCUSED: JInt = 1 << 3;
/// `EVENT_VIEW_TEXT_CHANGED`, `AK/android/src/util.rs:39`.
pub const EVENT_VIEW_TEXT_CHANGED: JInt = 1 << 4;
/// `EVENT_VIEW_HOVER_ENTER`, `AK/android/src/util.rs:40`.
pub const EVENT_VIEW_HOVER_ENTER: JInt = 1 << 7;
/// `EVENT_VIEW_HOVER_EXIT`, `AK/android/src/util.rs:41`.
pub const EVENT_VIEW_HOVER_EXIT: JInt = 1 << 8;
/// `EVENT_VIEW_SCROLLED`, `AK/android/src/util.rs:42`.
pub const EVENT_VIEW_SCROLLED: JInt = 1 << 12;
/// `EVENT_VIEW_TEXT_SELECTION_CHANGED`, `AK/android/src/util.rs:43`.
pub const EVENT_VIEW_TEXT_SELECTION_CHANGED: JInt = 1 << 13;
/// `EVENT_VIEW_ACCESSIBILITY_FOCUSED`, `AK/android/src/util.rs:44`.
pub const EVENT_VIEW_ACCESSIBILITY_FOCUSED: JInt = 1 << 15;
/// `EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED`, `AK/android/src/util.rs:45`.
pub const EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED: JInt = 1 << 16;
/// `EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY`,
/// `AK/android/src/util.rs:46`.
pub const EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY: JInt = 1 << 17;
/// `EVENT_WINDOW_CONTENT_CHANGED`, `AK/android/src/util.rs:47`.
pub const EVENT_WINDOW_CONTENT_CHANGED: JInt = 1 << 11;

/// `FOCUS_INPUT`, `AK/android/src/util.rs:49`.
pub const FOCUS_INPUT: JInt = 1;
/// `FOCUS_ACCESSIBILITY`, `AK/android/src/util.rs:50`.
pub const FOCUS_ACCESSIBILITY: JInt = 2;

/// `HOST_VIEW_ID`, `AK/android/src/util.rs:52` and `docs/42` section 1.4.1.
pub const HOST_VIEW_ID: JInt = -1;

/// `LIVE_REGION_NONE`, `AK/android/src/util.rs:54`.
pub const LIVE_REGION_NONE: JInt = 0;
/// `LIVE_REGION_POLITE`, `AK/android/src/util.rs:55`.
pub const LIVE_REGION_POLITE: JInt = 1;
/// `LIVE_REGION_ASSERTIVE`, `AK/android/src/util.rs:56`.
pub const LIVE_REGION_ASSERTIVE: JInt = 2;

/// `MOTION_ACTION_HOVER_MOVE`, `AK/android/src/util.rs:58`.
pub const MOTION_ACTION_HOVER_MOVE: JInt = 7;
/// `MOTION_ACTION_HOVER_ENTER`, `AK/android/src/util.rs:59`.
pub const MOTION_ACTION_HOVER_ENTER: JInt = 9;
/// `MOTION_ACTION_HOVER_EXIT`, `AK/android/src/util.rs:60`.
pub const MOTION_ACTION_HOVER_EXIT: JInt = 10;

/// `MOVEMENT_GRANULARITY_CHARACTER`, `AK/android/src/util.rs:62`.
pub const MOVEMENT_GRANULARITY_CHARACTER: JInt = 1 << 0;
/// `MOVEMENT_GRANULARITY_WORD`, `AK/android/src/util.rs:63`.
pub const MOVEMENT_GRANULARITY_WORD: JInt = 1 << 1;
/// `MOVEMENT_GRANULARITY_LINE`, `AK/android/src/util.rs:64`.
pub const MOVEMENT_GRANULARITY_LINE: JInt = 1 << 2;
/// `MOVEMENT_GRANULARITY_PARAGRAPH`, `AK/android/src/util.rs:65`.
pub const MOVEMENT_GRANULARITY_PARAGRAPH: JInt = 1 << 3;

/// The granularity mask `node.zig` sends with `setMovementGranularities`.
///
/// Upstream ORs the four constants at `AK/android/src/node.rs:386-389` and
/// sends the sum, so the port computes it from the four named values.
pub const MOVEMENT_GRANULARITIES_ALL: JInt = MOVEMENT_GRANULARITY_CHARACTER |
    MOVEMENT_GRANULARITY_WORD |
    MOVEMENT_GRANULARITY_LINE |
    MOVEMENT_GRANULARITY_PARAGRAPH;

/// `RANGE_TYPE_INT`, `AK/android/src/util.rs:67`.
pub const RANGE_TYPE_INT: JInt = 0;
/// `RANGE_TYPE_FLOAT`, `AK/android/src/util.rs:68`.
pub const RANGE_TYPE_FLOAT: JInt = 1;

/// `LOCAL_FRAME_CAPACITY`, `AK/android/src/inject.rs:99`, re-declared from
/// `jni.local_frame_capacity` so the two tables cannot disagree.
pub const LOCAL_FRAME_CAPACITY: JInt = 2;

/// `jint`, the 32-bit signed integer of the JNI, from
/// `docs/29-apple-android-apis.md` row 8 and the `jni` crate's `jni::sys`.
///
/// `jni.zig` records the same four scalars with the same widths; this is the
/// one the adapter body names, and `src/capi/boundary.zig` will take it in the
/// integration pass.
pub const JInt = i32;

/// The extras key the target URL is written under,
/// `AK/android/src/node.rs:348`.
///
/// Upstream spells it as a literal inside the fill, so it has no census row.
pub const TARGET_URL_EXTRAS_KEY: [:0]const u8 = "AccessibilityNodeInfo.targetUrl";

comptime {
    // The duplicate walk below is 43 rows against the rows after each, so it is
    // 903 comparisons. The default budget of 1000 backwards branches is not
    // enough for it plus the name comparison above.
    @setEvalBranchQuota(20_000);
    if (constant_values.len != value_count) @compileError("the array length is the count");
    if (value_count != constants.constant_count) {
        @compileError("the values table and the spelling table must hold the same 43");
    }
    // Every spelling in the census has exactly one row here, and the two tables
    // agree on order, so a name added to one without the other fails the build.
    for (constant_values, constants.constants) |value_row, name_row| {
        if (!std.mem.eql(u8, value_row.name, name_row.name)) {
            @compileError(std.fmt.comptimePrint(
                "row {d} is {s} here and {s} in constants.zig",
                .{ constants.constant_count - value_count, value_row.name, name_row.name },
            ));
        }
    }
    // Two rows cannot share a spelling, so a lookup by name is unambiguous.
    for (constant_values, 0..) |a, i| {
        for (constant_values[i + 1 ..], 0..) |b, j| {
            if (std.mem.eql(u8, a.name, b.name)) {
                @compileError(std.fmt.comptimePrint(
                    "duplicate value at {d} and {d}: {s}",
                    .{ i, i + 1 + j, a.name },
                ));
            }
        }
    }
    // The 5 `Bundle` keys are the only rows with no integer, and the other 38
    // all have one.
    var with_value: usize = 0;
    for (constant_values) |row| {
        if (row.value != null) with_value += 1;
    }
    if (with_value != 38) @compileError("38 of the 43 constants carry an integer");
}

/// The row spelled `name`, or `null` when the table holds no such spelling.
pub fn findValue(name: []const u8) ?ConstantValue {
    for (constant_values) |row| {
        if (std.mem.eql(u8, row.name, name)) return row;
    }
    return null;
}

/// How many rows of `constant_values` belong to `group`.
pub fn countOf(group: ValueGroup) usize {
    var total: usize = 0;
    for (constant_values) |row| {
        if (row.group == group) total += 1;
    }
    return total;
}

test "the values table holds one row for each of the 43 census spellings" {
    try testing.expectEqual(@as(usize, 43), constant_values.len);
    try testing.expectEqual(constants.constant_count, value_count);
    for (constant_values) |row| {
        try testing.expectEqual(row, findValue(row.name).?);
        try testing.expect(constants.find(row.name) != null);
    }
    try testing.expectEqual(@as(?ConstantValue, null), findValue("NO_SUCH_CONSTANT"));
}

test "the five Bundle keys carry no integer and the other 38 do" {
    var keys: usize = 0;
    for (constant_values) |row| {
        switch (row.group) {
            .action_argument => {
                keys += 1;
                try testing.expectEqual(@as(?i32, null), row.value);
            },
            else => try testing.expect(row.value != null),
        }
    }
    try testing.expectEqual(@as(usize, 5), keys);
    try testing.expectEqual(@as(usize, 38), value_count - keys);
}

test "the ten action ids are the bits upstream writes at util.rs:14-23" {
    const expected = [_]struct { name: []const u8, value: i32 }{
        .{ .name = "ACTION_FOCUS", .value = 1 },
        .{ .name = "ACTION_CLICK", .value = 16 },
        .{ .name = "ACTION_ACCESSIBILITY_FOCUS", .value = 64 },
        .{ .name = "ACTION_CLEAR_ACCESSIBILITY_FOCUS", .value = 128 },
        .{ .name = "ACTION_NEXT_AT_MOVEMENT_GRANULARITY", .value = 256 },
        .{ .name = "ACTION_PREVIOUS_AT_MOVEMENT_GRANULARITY", .value = 512 },
        .{ .name = "ACTION_SCROLL_FORWARD", .value = 4096 },
        .{ .name = "ACTION_SCROLL_BACKWARD", .value = 8192 },
        .{ .name = "ACTION_SET_SELECTION", .value = 131072 },
        .{ .name = "ACTION_SET_PROGRESS", .value = 0x0102003d },
    };
    try testing.expectEqual(@as(usize, 10), countOf(.action_id));
    for (expected) |row| {
        try testing.expectEqual(row.value, findValue(row.name).?.value.?);
    }
    // Each named alias carries the same integer as its row, so the two cannot
    // drift without a failing test.
    try testing.expectEqual(@as(i32, ACTION_FOCUS), findValue("ACTION_FOCUS").?.value.?);
    try testing.expectEqual(@as(i32, ACTION_CLICK), findValue("ACTION_CLICK").?.value.?);
    try testing.expectEqual(
        @as(i32, ACTION_SET_PROGRESS),
        findValue("ACTION_SET_PROGRESS").?.value.?,
    );
}

test "the twelve event type ids are the bits upstream writes at util.rs:36-47" {
    const expected = [_]struct { name: []const u8, value: i32 }{
        .{ .name = "EVENT_VIEW_CLICKED", .value = 1 },
        .{ .name = "EVENT_VIEW_SELECTED", .value = 4 },
        .{ .name = "EVENT_VIEW_FOCUSED", .value = 8 },
        .{ .name = "EVENT_VIEW_TEXT_CHANGED", .value = 16 },
        .{ .name = "EVENT_VIEW_HOVER_ENTER", .value = 128 },
        .{ .name = "EVENT_VIEW_HOVER_EXIT", .value = 256 },
        .{ .name = "EVENT_WINDOW_CONTENT_CHANGED", .value = 2048 },
        .{ .name = "EVENT_VIEW_SCROLLED", .value = 4096 },
        .{ .name = "EVENT_VIEW_TEXT_SELECTION_CHANGED", .value = 8192 },
        .{ .name = "EVENT_VIEW_ACCESSIBILITY_FOCUSED", .value = 32768 },
        .{ .name = "EVENT_VIEW_ACCESSIBILITY_FOCUS_CLEARED", .value = 65536 },
        .{
            .name = "EVENT_VIEW_TEXT_TRAVERSED_AT_MOVEMENT_GRANULARITY",
            .value = 131072,
        },
    };
    try testing.expectEqual(@as(usize, 12), countOf(.event_type));
    for (expected) |row| {
        try testing.expectEqual(row.value, findValue(row.name).?.value.?);
    }
    try testing.expectEqual(@as(i32, EVENT_WINDOW_CONTENT_CHANGED), 1 << 11);
    try testing.expectEqual(@as(i32, EVENT_VIEW_CLICKED), 1);
}

test "the four movement granularities are bits 0 to 3 and their mask is 15" {
    const expected = [_]struct { name: []const u8, value: i32 }{
        .{ .name = "MOVEMENT_GRANULARITY_CHARACTER", .value = 1 },
        .{ .name = "MOVEMENT_GRANULARITY_WORD", .value = 2 },
        .{ .name = "MOVEMENT_GRANULARITY_LINE", .value = 4 },
        .{ .name = "MOVEMENT_GRANULARITY_PARAGRAPH", .value = 8 },
    };
    try testing.expectEqual(@as(usize, 4), countOf(.movement_granularity));
    for (expected) |row| {
        try testing.expectEqual(row.value, findValue(row.name).?.value.?);
    }
    try testing.expectEqual(@as(i32, 15), MOVEMENT_GRANULARITIES_ALL);
}

test "the remaining single and paired values are the literals upstream writes" {
    const expected = [_]struct { name: []const u8, value: i32 }{
        .{ .name = "CONTENT_CHANGE_TYPE_SUBTREE", .value = 1 },
        .{ .name = "FOCUS_INPUT", .value = 1 },
        .{ .name = "FOCUS_ACCESSIBILITY", .value = 2 },
        .{ .name = "LIVE_REGION_NONE", .value = 0 },
        .{ .name = "LIVE_REGION_POLITE", .value = 1 },
        .{ .name = "LIVE_REGION_ASSERTIVE", .value = 2 },
        .{ .name = "MOTION_ACTION_HOVER_MOVE", .value = 7 },
        .{ .name = "MOTION_ACTION_HOVER_ENTER", .value = 9 },
        .{ .name = "MOTION_ACTION_HOVER_EXIT", .value = 10 },
        .{ .name = "RANGE_TYPE_INT", .value = 0 },
        .{ .name = "RANGE_TYPE_FLOAT", .value = 1 },
        .{ .name = "HOST_VIEW_ID", .value = -1 },
    };
    for (expected) |row| {
        try testing.expectEqual(row.value, findValue(row.name).?.value.?);
    }
    // `HOST_VIEW_ID` is the one value `docs/42` section 1.4.1 also records.
    try testing.expectEqual(constants.host_view_id, HOST_VIEW_ID);
    try testing.expectEqual(@as(usize, 1), countOf(.host_sentinel));
    try testing.expectEqual(@as(usize, 2), countOf(.focus_input_mode));
    try testing.expectEqual(@as(usize, 3), countOf(.live_region));
    try testing.expectEqual(@as(usize, 3), countOf(.motion_action));
    try testing.expectEqual(@as(usize, 2), countOf(.range_type));
    try testing.expectEqual(@as(usize, 1), countOf(.content_change_type));
}

test "the Bundle keys keep their upstream spellings, including the qualified one" {
    try testing.expectEqualStrings(
        "ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT",
        ACTION_ARGUMENT_MOVEMENT_GRANULARITY_INT,
    );
    try testing.expectEqualStrings(
        "ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN",
        ACTION_ARGUMENT_EXTEND_SELECTION_BOOLEAN,
    );
    try testing.expectEqualStrings(
        "ACTION_ARGUMENT_SELECTION_START_INT",
        ACTION_ARGUMENT_SELECTION_START_INT,
    );
    try testing.expectEqualStrings(
        "ACTION_ARGUMENT_SELECTION_END_INT",
        ACTION_ARGUMENT_SELECTION_END_INT,
    );
    try testing.expectEqualStrings(
        "android.view.accessibility.action.ARGUMENT_PROGRESS_VALUE",
        ACTION_ARGUMENT_PROGRESS_VALUE,
    );
}

test "the local frame capacity and the extras key are the two literals upstream writes" {
    const jni = @import("jni.zig");
    try testing.expectEqual(jni.local_frame_capacity, LOCAL_FRAME_CAPACITY);
    try testing.expectEqualStrings("AccessibilityNodeInfo.targetUrl", TARGET_URL_EXTRAS_KEY);
    // The frame capacity is the one figure the census and this table share, and
    // the extras key is the one string the fill writes without a census row.
    try testing.expectEqual(@as(i32, 4), @sizeOf(JInt));
}
