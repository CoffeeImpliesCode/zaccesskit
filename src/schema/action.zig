//! `Action`, and the `u32` mask that carries a set of them.
//!
//! A mask holds one bit per variant, at the bit position of that variant's
//! discriminant. The mask a tree node stores and the C header exposes is this
//! module's `u32` unchanged, so nothing converts at the boundary.
//!
//! Conversion and mask operations are file-scope functions prefixed by the type
//! name. `schema/root.zig` re-exports every schema module flat, so a bare
//! `fromInt` in two modules would collide.
//!
//! This module allocates nothing and performs no I/O. An action that carries a
//! payload reads its argument from the `ActionRequest.data` that arrives beside
//! it. `ActionData` and `ActionRequest` live in `schema/update.zig`.

const std = @import("std");
const assert = std.debug.assert;

/// One operation an application can ask the platform to carry out.
///
/// The discriminant is wire-visible. It is the bit position in the mask, and the
/// C header and the JSON name are both built from the upstream name and the
/// upstream number, so the order of the members below is the contract.
pub const Action = enum(u8) {
    /// The default member, and discriminant 0. Do the equivalent of a single
    /// click or tap.
    click = 0,

    focus = 1,
    blur = 2,

    collapse = 3,
    expand = 4,

    /// Requires `ActionRequest.data` to be set to `ActionData.custom_action`.
    custom_action = 5,

    /// Decrease a numeric value by one step.
    decrement = 6,
    /// Increase a numeric value by one step.
    increment = 7,

    hide_tooltip = 8,
    show_tooltip = 9,

    /// Delete any selected text in the control's text value and insert the
    /// specified value in its place, like when typing or pasting. Requires
    /// `ActionRequest.data` to be set to `ActionData.value`.
    replace_selected_text = 10,

    /// Scroll down by the specified unit.
    scroll_down = 11,
    /// Scroll left by the specified unit.
    scroll_left = 12,
    /// Scroll right by the specified unit.
    scroll_right = 13,
    /// Scroll up by the specified unit.
    scroll_up = 14,

    /// Scroll any scrollable containers to make the target node visible.
    /// Optionally set `ActionRequest.data` to `ActionData.scroll_hint`.
    scroll_into_view = 15,

    /// Scroll the given object to a specified point in the tree's container,
    /// for example the window. Requires `ActionRequest.data` to be set to
    /// `ActionData.scroll_to_point`.
    scroll_to_point = 16,

    /// Requires `ActionRequest.data` to be set to
    /// `ActionData.set_scroll_offset`.
    set_scroll_offset = 17,

    /// Requires `ActionRequest.data` to be set to
    /// `ActionData.set_text_selection`.
    set_text_selection = 18,

    /// Do not focus this node, but set it as the sequential focus navigation
    /// starting point, so that pressing Tab moves to the next element following
    /// this one, for example.
    set_sequential_focus_navigation_starting_point = 19,

    /// Replace the value of the control with the specified value and reset the
    /// selection, if applicable. Requires `ActionRequest.data` to be set to
    /// `ActionData.value` or `ActionData.numeric_value`.
    set_value = 20,

    show_context_menu = 21,
};

/// The number of `Action` variants, and so the bit count of a full mask and the
/// bound on every walk over the domain.
pub const actionCount = @typeInfo(Action).@"enum".field_names.len;

comptime {
    // Upstream declares 22 members between `lib.rs:289` and `lib.rs:350`, and
    // its own test asserts `Action::n(22)` is `None` at `lib.rs:3508`. A port
    // that adds or drops one changes every discriminant above it.
    assert(actionCount == 22);

    // A `u32` mask gives each variant one bit. A 33rd variant would need a
    // wider mask, and the C header exposes this one as `uint32_t`.
    assert(actionCount <= 32);

    var full: u32 = 0;
    for (std.enums.values(Action)) |member| {
        full |= actionMask(member);
    }
    const set_bit_count: u32 = @popCount(full);
    assert(actionCount == set_bit_count);

    // The popcount above is satisfied by any set of distinct discriminants. The
    // wire needs them dense, because the C header numbers the members by
    // position and a gap would move every member after it.
    assert(full == (@as(u32, 1) << actionCount) - 1);
}

/// The variant whose discriminant is `value`, or `null` when no variant
/// carries that number.
pub fn actionFromInt(value: u8) ?Action {
    return std.enums.fromInt(Action, value);
}

/// The one-bit `u32` mask that carries `value`.
pub fn actionMask(value: Action) u32 {
    return @as(u32, 1) << @as(u5, @intCast(@backingInt(value)));
}

/// True when `action_set` carries the bit for `action`.
pub fn actionSetContains(action_set: u32, action: Action) bool {
    return action_set & actionMask(action) != 0;
}

/// The union of two masks: an action is in the result when either operand holds
/// its bit.
pub fn actionSetUnion(left: u32, right: u32) u32 {
    return left | right;
}

/// The actions in `left` that `right` does not hold. Bits that name no variant
/// are carried through, the way `actionSetUnion` carries them.
pub fn actionSetDifference(left: u32, right: u32) u32 {
    return left & ~right;
}

/// The actions `action_set` names, in ascending declaration order.
///
/// Writes into `out` and returns the filled prefix of it. The loop runs over
/// the whole `Action` domain, so `actionCount` iterations is its bound and `out`
/// is exactly that long. The result borrows `out` and is invalidated when the
/// caller writes there again. A set bit at or above `actionCount` names no
/// variant, so it is skipped, which is what a mask that arrived over the wire
/// carrying an unknown bit does.
pub fn actionSetMembers(action_set: u32, out: *[actionCount]Action) []const Action {
    var len: usize = 0;
    inline for (comptime std.enums.values(Action)) |member| {
        if (actionSetContains(action_set, member)) {
            out[len] = member;
            len += 1;
        }
    }
    return out[0..len];
}

test "Action carries the 22 members of accesskit/src/lib.rs:289-350" {
    try std.testing.expectEqual(@as(usize, 22), actionCount);
    try std.testing.expectEqual(actionCount, std.enums.values(Action).len);
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(Action));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(Action));
    try std.testing.expectEqual(@as(u8, 0), @backingInt(Action.click));
    try std.testing.expectEqual(@as(u8, 21), @backingInt(Action.show_context_menu));
}

test "every Action discriminant is its index in upstream declaration order" {
    // A member moved or renumbered changes the wire number and the C header.
    // The sweep covers the whole domain, so a new member is covered too.
    inline for (std.enums.values(Action), 0..) |member, index| {
        try std.testing.expectEqual(@as(u8, @intCast(index)), @backingInt(member));
    }
}

test "actionFromInt names a variant only where a variant has that discriminant" {
    inline for (std.enums.values(Action)) |member| {
        const value: u8 = @intCast(@backingInt(member));
        try std.testing.expectEqual(member, actionFromInt(value));
        try std.testing.expectEqual(@as(u32, 1), @popCount(actionMask(member)));
    }
    try std.testing.expectEqual(null, actionFromInt(@intCast(actionCount)));
    try std.testing.expectEqual(null, actionFromInt(255));
}

test "a mask of every member round-trips through the action set operations" {
    var lower: u32 = 0;
    var upper: u32 = 0;
    for (std.enums.values(Action), 0..) |member, index| {
        if (index < actionCount / 2) {
            lower |= actionMask(member);
        } else {
            upper |= actionMask(member);
        }
    }
    const every = actionSetUnion(lower, upper);
    try std.testing.expectEqual(@as(u32, 0x003f_ffff), every);
    try std.testing.expect(lower != upper);

    try std.testing.expectEqual(lower, actionSetDifference(every, upper));
    try std.testing.expectEqual(upper, actionSetDifference(every, lower));
    // The two halves share no bit, so subtracting one from the other must leave
    // it whole. A difference written as an intersection returns 0 here.
    try std.testing.expectEqual(lower, actionSetDifference(lower, upper));
    try std.testing.expectEqual(upper, actionSetDifference(upper, lower));
    try std.testing.expectEqual(@as(u32, 0), actionSetDifference(lower, lower));

    var buf: [actionCount]Action = undefined;
    const listed = actionSetMembers(every, &buf);
    try std.testing.expectEqual(actionCount, listed.len);
    inline for (std.enums.values(Action), 0..) |member, index| {
        try std.testing.expectEqual(member, listed[index]);
        try std.testing.expect(actionSetContains(every, member));
    }
    try std.testing.expect(actionSetContains(upper, .show_context_menu));
    try std.testing.expect(!actionSetContains(lower, .show_context_menu));
    const without_upper = actionSetDifference(every, upper);
    try std.testing.expect(!actionSetContains(without_upper, .show_context_menu));
}

test "actionSetMembers visits the set in declaration order" {
    // The mask is accumulated in the opposite order to the one asserted, so an
    // iteration that followed the order the bits were set fails here.
    const set = actionMask(.set_value) |
        actionMask(.click) |
        actionMask(.scroll_up) |
        actionMask(.focus);
    var buf: [actionCount]Action = undefined;
    const listed = actionSetMembers(set, &buf);
    try std.testing.expectEqual(@as(usize, 4), listed.len);
    try std.testing.expectEqual(Action.click, listed[0]);
    try std.testing.expectEqual(Action.focus, listed[1]);
    try std.testing.expectEqual(Action.scroll_up, listed[2]);
    try std.testing.expectEqual(Action.set_value, listed[3]);
}

test "actionSetMembers skips a mask bit that names no variant" {
    // Upstream stops at the first discriminant with no variant, so a mask that
    // arrives with an unknown high bit must not turn it into a member.
    const stray: u32 = @as(u32, 1) << 31;
    var buf: [actionCount]Action = undefined;
    try std.testing.expectEqual(@as(usize, 0), actionSetMembers(stray, &buf).len);
    try std.testing.expect(!actionSetContains(stray, .click));

    const listed = actionSetMembers(stray | actionMask(.click), &buf);
    try std.testing.expectEqual(@as(usize, 1), listed.len);
    try std.testing.expectEqual(Action.click, listed[0]);
}

test "an empty mask names nothing" {
    var buf: [actionCount]Action = undefined;
    try std.testing.expectEqual(@as(usize, 0), actionSetMembers(0, &buf).len);
    inline for (std.enums.values(Action)) |member| {
        try std.testing.expect(!actionSetContains(0, member));
    }
}
