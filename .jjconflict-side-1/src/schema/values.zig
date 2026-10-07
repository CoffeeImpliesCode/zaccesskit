//! Value types a node carries in its properties, from
//! `accesskit/src/lib.rs:761-855`.
//!
//! `CustomAction` is the only type here that owns memory. It takes its
//! allocator as a parameter at `init` and at `deinit`, so this module stores
//! none and names no global. The other four types hold only numbers and copy
//! freely. Nothing here performs I/O, so no function takes `io`.
//!
//! Zig rejects `==` for a struct, so every equality below is an explicit
//! `eql`. Upstream derived `PartialEq` and `Eq` on all five types
//! (`accesskit/src/lib.rs:756`, `:766`, `:779`, `:829`, `:842`).
//!
//! The four types that cross the C ABI are `extern struct`: `TextPosition`,
//! `TextSelection`, `Color` and `TextDecoration`. Their offsets are the
//! declaration order, and a `comptime` block below each of them pins the size,
//! the alignment and every offset, so a field added to one is a compile error
//! for every consumer. The tests below repeat those numbers, because a runtime
//! assertion names the field that moved and a comptime block names the type.
//!
//! `CustomAction` is the exception and the only plain struct here, because an
//! `extern struct` cannot hold the slice inside `description`. Zig 0.16.0
//! reorders the fields of a plain struct to remove padding, so the offsets
//! asserted for it are measured, never read from `docs/10`, and no comptime
//! block pins them.
//!
//! `NodeId` comes from `ids.zig` and `TextDecorationStyle` from
//! `node_enums.zig`. Neither is declared here.
//!
//! Five upstream items have no Zig counterpart, and one field departs from
//! rule Z4.
//!
//! - The five `Debug` derives (`accesskit/src/lib.rs:756`, `:766`, `:779`,
//!   `:829` and `:842`) give the five types an upstream `format`. The port
//!   declares none, because nothing in the port renders one of them.
//! - `TextPosition.node` at `accesskit/src/lib.rs:773` becomes `node_id`. Rule
//!   Z4 keeps a field spelling, so this is a deliberate departure from Z4:
//!   `node` alone is ambiguous beside the other node-bearing types in this
//!   module, and `node_id` names the identifier.

const std = @import("std");

const ids = @import("ids.zig");
const node_enums = @import("node_enums.zig");

const NodeId = ids.NodeId;
const TextDecorationStyle = node_enums.TextDecorationStyle;

/// One action a node offers, declared under its `CustomActions` property.
///
/// An `ActionRequest` whose `ActionData` is `custom_action` carries the `id`
/// back to the application, which matches it against this list. The core never
/// checks that the two agree.
///
/// `CustomAction` owns `description`. One value has one owner, which calls
/// `deinit` once with the allocator `init` was given. Copying a `CustomAction`
/// copies the handle and not the storage, so a copy is not a second owner and
/// a second `deinit` is a double free.
///
/// This is a plain struct and must stay one. It owns a buffer, and an
/// `extern struct` cannot hold a slice, so it is not a C-representable layout
/// and its byte offsets are no one's contract. The C form is built in
/// `capi/marshal.zig`, which is the one place where the two meet.
pub const CustomAction = struct {
    /// The failures `init` reports. It fails with `error.OutOfMemory` and
    /// with nothing else.
    pub const InitError = error{
        /// `gpa` could not supply the bytes for `description`. The call then
        /// owns nothing.
        OutOfMemory,
    };

    /// The identifier an `ActionRequest` matches against. The core crate treats
    /// it as opaque: it neither allocates nor checks it.
    id: i32,
    /// Human-readable text naming the action.
    description: std.ArrayList(u8),

    /// Copies `description` into memory obtained from `gpa`.
    ///
    /// Returns `error.OutOfMemory` when `gpa` cannot supply
    /// `description.len` bytes. On that path the call has copied nothing and
    /// holds no allocation, so there is nothing for the caller to release. An
    /// empty `description` allocates nothing and cannot fail.
    pub fn init(gpa: std.mem.Allocator, id: i32, description: []const u8) InitError!CustomAction {
        // `initCapacity` reserves the whole buffer or fails before it takes
        // one, so there is no partial result to release here.
        var owned: std.ArrayList(u8) = try .initCapacity(gpa, description.len);
        owned.appendSliceAssumeCapacity(description);
        return .{ .id = id, .description = owned };
    }

    /// Releases `description` through `gpa`, which must be the allocator `init`
    /// was given. The allocator itself is not released.
    ///
    /// `self` is unusable afterward. A second call is a double free.
    pub fn deinit(self: *CustomAction, gpa: std.mem.Allocator) void {
        self.description.deinit(gpa);
        self.* = undefined;
    }

    /// Whether both actions carry the same `id` and the same description
    /// bytes.
    ///
    /// The bytes, not the addresses, because `std.meta.eql` would descend into
    /// `description` as a slice and compare its pointer, which makes two
    /// equal descriptions unequal. Upstream's derived `Eq` compares the
    /// contents of the `String`.
    pub fn eql(self: CustomAction, other: CustomAction) bool {
        if (self.id != other.id) return false;
        return std.mem.eql(u8, self.description.items, other.description.items);
    }
};

/// One character offset inside one text run.
///
/// The value is meaningful only inside the tree that produced it. `node_id`
/// names a node whose role is `TextRun`, and `character_index` indexes that
/// node's `character_lengths`, or equals the length of that slice when the
/// position sits at the end of the line (`accesskit/src/lib.rs:772-776`). This
/// type owns nothing and copies freely.
///
/// `extern struct` because the offsets are a contract:
/// `accesskit-c/include/accesskit.h:970-973` declares `accesskit_text_position`
/// with the node id first and the index second, and `ActionData` carries this
/// value in an `extern union`, which cannot hold a plain struct.
pub const TextPosition = extern struct {
    /// The text run the offset belongs to. Renamed from the upstream field
    /// `node` at `accesskit/src/lib.rs:773`. Rule Z4 keeps a field spelling, so
    /// this is a deliberate departure from Z4: `node` alone is ambiguous beside
    /// the other node-bearing types in this module, and `node_id` names the
    /// identifier.
    node_id: NodeId,
    /// The character offset within `node_id`.
    character_index: usize,

    /// Whether both positions name the same offset in the same text run.
    ///
    /// The two fields are compared one by one so that this agrees with
    /// `compare` on one pair of answers: `compare` returns `.eq` exactly when
    /// this returns true.
    pub fn eql(self: TextPosition, other: TextPosition) bool {
        if (!self.node_id.eql(other.node_id)) return false;
        return self.character_index == other.character_index;
    }

    /// Orders two offsets inside one text run, or reports that they are not
    /// comparable.
    ///
    /// `null` means the two positions name different text runs. This crate
    /// never sees the tree, so it cannot say which run comes first in document
    /// order. Upstream reports the same case the same way for the borrowed
    /// position type it exposes to adapters, at
    /// `accesskit_consumer/src/text.rs:583-592`.
    ///
    /// The result is `.eq` exactly when `eql` is true, so a caller that only
    /// needs equality uses `eql` and a caller that needs the order uses this.
    pub fn compare(self: TextPosition, other: TextPosition) ?std.math.Order {
        if (!self.node_id.eql(other.node_id)) return null;
        return std.math.order(self.character_index, other.character_index);
    }
};

comptime {
    // The offsets `accesskit-c/include/accesskit.h:970-973` promises. A
    // container-level `comptime` block does not have the bare `assert` builtin
    // on Zig 0.16.0, so these go through `std.debug.assert`, and every number
    // here is one the runtime test below asserts as well.
    std.debug.assert(@sizeOf(TextPosition) == 16);
    std.debug.assert(@alignOf(TextPosition) == 8);
    std.debug.assert(@offsetOf(TextPosition, "node_id") == 0);
    std.debug.assert(@offsetOf(TextPosition, "character_index") == 8);
}

/// The selection, or the caret, inside a text run.
///
/// A selection with no extent, only a caret, holds `anchor` equal to `focus`
/// (`accesskit/src/lib.rs:785-788`). Nothing here requires `focus` to follow
/// `anchor`, so a selection that runs backwards is held and ordered like any
/// other. The type owns nothing and copies freely.
///
/// `extern struct` because the offsets are a contract:
/// `accesskit-c/include/accesskit.h:975-978` declares `accesskit_text_selection`
/// as an anchor followed by a focus, and `ActionData` carries this value in an
/// `extern union`, which cannot hold a plain struct.
pub const TextSelection = extern struct {
    /// Where the selection started. It does not move as the selection is
    /// expanded or contracted, and it equals `focus` when there is only a
    /// caret.
    anchor: TextPosition,
    /// The active end of the selection. It moves as the selection is expanded
    /// or contracted, and it is the caret position when there is no selection.
    focus: TextPosition,

    /// Whether both selections hold the same anchor and the same focus.
    pub fn eql(self: TextSelection, other: TextSelection) bool {
        if (!self.anchor.eql(other.anchor)) return false;
        return self.focus.eql(other.focus);
    }

    /// Orders two selections by `anchor` first and by `focus` second, or
    /// reports that they are not comparable.
    ///
    /// `null` comes from `TextPosition.compare` and means either that the two
    /// anchors name different text runs, or that the anchors are equal and the
    /// two focus positions name different text runs. The result is `.eq`
    /// exactly when `eql` is true.
    pub fn compare(self: TextSelection, other: TextSelection) ?std.math.Order {
        const anchor_order = self.anchor.compare(other.anchor) orelse return null;
        if (anchor_order != .eq) return anchor_order;
        return self.focus.compare(other.focus);
    }
};

comptime {
    // The offsets `accesskit-c/include/accesskit.h:975-978` promises, which the
    // runtime test below asserts as well.
    std.debug.assert(@sizeOf(TextSelection) == 32);
    std.debug.assert(@alignOf(TextSelection) == 8);
    std.debug.assert(@offsetOf(TextSelection, "anchor") == 0);
    std.debug.assert(@offsetOf(TextSelection, "focus") == 16);
}

/// One color as 8-bit sRGB plus an alpha channel.
///
/// `extern struct` because upstream marks the type `#[repr(C)]`
/// (`accesskit/src/lib.rs:833`) and `accesskit-c/include/accesskit.h:754-759`
/// exposes the four channels in this order. A plain struct would let the
/// compiler move them. Each channel is one byte, so 255 is the full channel.
pub const Color = extern struct {
    red: u8,
    green: u8,
    blue: u8,
    /// How opaque the color is. 255 is fully opaque and 0 fully transparent.
    alpha: u8,

    /// Whether both colors carry the same four channels.
    pub fn eql(self: Color, other: Color) bool {
        if (self.red != other.red) return false;
        if (self.green != other.green) return false;
        if (self.blue != other.blue) return false;
        return self.alpha == other.alpha;
    }
};

comptime {
    // The offsets `accesskit-c/include/accesskit.h:754-759` promises, which the
    // runtime test below asserts as well.
    std.debug.assert(@sizeOf(Color) == 4);
    std.debug.assert(@alignOf(Color) == 1);
    std.debug.assert(@offsetOf(Color, "red") == 0);
    std.debug.assert(@offsetOf(Color, "green") == 1);
    std.debug.assert(@offsetOf(Color, "blue") == 2);
    std.debug.assert(@offsetOf(Color, "alpha") == 3);
}

/// The style and the color of one kind of text decoration.
///
/// `extern struct` because upstream marks the type `#[repr(C)]`
/// (`accesskit/src/lib.rs:846`) and `accesskit-c/include/accesskit.h:774-777`
/// puts the style first and the color second. The style is one byte and the
/// color is four, so the struct carries no padding.
pub const TextDecoration = extern struct {
    /// Which line the decoration draws. A node carries one of these each for
    /// its overline, its strikethrough and its underline.
    style: TextDecorationStyle,
    /// The color the line is drawn in.
    color: Color,

    /// Whether both decorations carry the same style and the same color.
    pub fn eql(self: TextDecoration, other: TextDecoration) bool {
        if (self.style != other.style) return false;
        return self.color.eql(other.color);
    }
};

comptime {
    // The offsets `accesskit-c/include/accesskit.h:774-777` promises, which the
    // runtime test below asserts as well.
    std.debug.assert(@sizeOf(TextDecoration) == 5);
    std.debug.assert(@alignOf(TextDecoration) == 1);
    std.debug.assert(@offsetOf(TextDecoration, "style") == 0);
    std.debug.assert(@offsetOf(TextDecoration, "color") == 1);
}

test "CustomAction owns its description and releases it once" {
    var action = try CustomAction.init(std.testing.allocator, 7, "drag");
    defer action.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 7), action.id);
    try std.testing.expectEqualStrings("drag", action.description.items);
    try std.testing.expectEqual(@as(usize, 4), action.description.capacity);
}

test "an empty description copies no bytes and holds no capacity" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    var action = try CustomAction.init(failing.allocator(), 0, "");
    defer action.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(i32, 0), action.id);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    try std.testing.expectEqual(@as(usize, 0), action.description.capacity);
    try std.testing.expectEqual(@as(usize, 0), action.description.items.len);
}

test "every failing allocation of CustomAction.init returns OutOfMemory and leaks nothing" {
    // `init` makes one allocation, so `first_success_index` is the first index
    // at which it succeeds. Raising the bound would let a second allocation go
    // unnoticed; lowering it to 0 would stop covering `error.OutOfMemory`.
    const first_success_index: usize = 1;
    const gpa = std.testing.allocator;

    var fail_index: usize = 0;
    while (fail_index <= first_success_index) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        const outcome = CustomAction.init(failing.allocator(), 1, "drag");
        if (fail_index == 0) {
            try std.testing.expectError(error.OutOfMemory, outcome);
            continue;
        }
        var action = try outcome;
        action.deinit(gpa);
    }
}

test "every failure of init is named, and OutOfMemory is reachable" {
    var failing: std.testing.FailingAllocator = .init(std.testing.allocator, .{ .fail_index = 0 });
    const outcome = CustomAction.init(failing.allocator(), 1, "drag");

    // The switch has no `_` arm, so a member added to `InitError` is a
    // compile error here until a test names it. Zig 0.16.0 has no reflection
    // that enumerates an error set, so the exhaustive switch is the sweep.
    const named = outcome catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
    };
    try std.testing.expectError(error.OutOfMemory, named);
}

test "CustomAction equality reads the description bytes, not the buffer address" {
    var first = try CustomAction.init(std.testing.allocator, 1, "drag");
    defer first.deinit(std.testing.allocator);
    var second = try CustomAction.init(std.testing.allocator, 1, "drag");
    defer second.deinit(std.testing.allocator);

    // Two distinct allocations holding equal bytes. An address comparison
    // would call these unequal, which is the defect this test names.
    try std.testing.expect(first.description.items.ptr != second.description.items.ptr);
    try std.testing.expect(first.eql(second));

    var other_id = try CustomAction.init(std.testing.allocator, 2, "drag");
    defer other_id.deinit(std.testing.allocator);
    try std.testing.expect(!first.eql(other_id));

    var other_text = try CustomAction.init(std.testing.allocator, 1, "drop");
    defer other_text.deinit(std.testing.allocator);
    try std.testing.expect(!first.eql(other_text));

    var empty_a = try CustomAction.init(std.testing.allocator, 1, "");
    defer empty_a.deinit(std.testing.allocator);
    var empty_b = try CustomAction.init(std.testing.allocator, 1, "");
    defer empty_b.deinit(std.testing.allocator);
    try std.testing.expect(empty_a.eql(empty_b));
}

test "Color compares all four channels" {
    const red: Color = .{ .red = 255, .green = 0, .blue = 0, .alpha = 255 };
    try std.testing.expect(red.eql(.{ .red = 255, .green = 0, .blue = 0, .alpha = 255 }));

    try std.testing.expect(!red.eql(.{ .red = 255, .green = 0, .blue = 0, .alpha = 0 }));
    try std.testing.expect(!red.eql(.{ .red = 254, .green = 0, .blue = 0, .alpha = 255 }));
    try std.testing.expect(!red.eql(.{ .red = 255, .green = 1, .blue = 0, .alpha = 255 }));
    try std.testing.expect(!red.eql(.{ .red = 255, .green = 0, .blue = 1, .alpha = 255 }));
}

test "TextDecoration compares the style and then the color" {
    const dotted: TextDecoration = .{ .style = .dotted, .color = opaque_black };
    try std.testing.expect(dotted.eql(.{ .style = .dotted, .color = opaque_black }));

    try std.testing.expect(!dotted.eql(.{ .style = .solid, .color = opaque_black }));
    try std.testing.expect(!dotted.eql(.{ .style = .dotted, .color = clear_black }));
}

test "CustomAction is 32 bytes at alignment 8" {
    // Zig 0.16.0 lays the fields of a plain struct out to remove padding, so
    // `description` takes offset 0 and `id` sits after it. `extern struct`
    // would keep the source order, and the compiler rejects it here because an
    // extern struct cannot hold a slice.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CustomAction));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(CustomAction));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CustomAction, "description"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CustomAction, "id"));
}

test "TextPosition is 16 bytes at alignment 8" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(TextPosition));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(TextPosition));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TextPosition, "node_id"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(TextPosition, "character_index"));
}

test "TextSelection is 32 bytes at alignment 8" {
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(TextSelection));
    try std.testing.expectEqual(@as(usize, 8), @alignOf(TextSelection));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TextSelection, "anchor"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(TextSelection, "focus"));
}

test "Color is 4 bytes at alignment 1" {
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(Color));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Color, "red"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(Color, "green"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(Color, "blue"));
    try std.testing.expectEqual(@as(usize, 3), @offsetOf(Color, "alpha"));
}

test "TextDecoration is 5 bytes at alignment 1" {
    try std.testing.expectEqual(@as(usize, 5), @sizeOf(TextDecoration));
    try std.testing.expectEqual(@as(usize, 1), @alignOf(TextDecoration));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(TextDecoration, "style"));
    try std.testing.expectEqual(@as(usize, 1), @offsetOf(TextDecoration, "color"));
}

test "TextPosition orders by character index inside one text run" {
    const start = position(nodeId(3), 0);
    const middle = position(nodeId(3), 4);
    const end = position(nodeId(3), 9);

    try std.testing.expectEqual(std.math.Order.lt, start.compare(middle));
    try std.testing.expectEqual(std.math.Order.gt, end.compare(start));
    try std.testing.expectEqual(std.math.Order.eq, start.compare(start));
    try std.testing.expectEqual(std.math.Order.eq, middle.compare(position(nodeId(3), 4)));
}

test "TextPosition equality and ordering agree on every pair" {
    const nodes = [_]u64{ 3, 4 };
    const indexes = [_]usize{ 0, 4, 9 };
    for (nodes) |left_node| {
        for (nodes) |right_node| {
            for (indexes) |left_index| {
                for (indexes) |right_index| {
                    const left = position(nodeId(left_node), left_index);
                    const right = position(nodeId(right_node), right_index);
                    const order = left.compare(right);
                    if (left_node != right_node) {
                        try std.testing.expect(order == null);
                        try std.testing.expect(!left.eql(right));
                        continue;
                    }
                    try std.testing.expectEqual(left_index == right_index, left.eql(right));
                    try std.testing.expectEqual(left_index == right_index, order.? == .eq);
                }
            }
        }
    }
}

test "a position in another text run is not ordered, whatever its index" {
    // The invariant is that one run has a document order inside itself. Two
    // positions in different runs break it, and a total order over the two
    // fields would answer `lt` here from the index alone.
    const here = position(nodeId(3), 0);
    const there = position(nodeId(4), 9);

    try std.testing.expect(here.compare(there) == null);
    try std.testing.expect(there.compare(here) == null);
    try std.testing.expect(!here.eql(there));
}

test "TextSelection orders by anchor first and by focus second" {
    const first = selection(position(nodeId(3), 0), position(nodeId(3), 1));
    const later_anchor = selection(position(nodeId(3), 2), position(nodeId(3), 3));
    const same_anchor_later_focus = selection(position(nodeId(3), 0), position(nodeId(3), 5));

    try std.testing.expectEqual(std.math.Order.lt, first.compare(later_anchor));
    try std.testing.expectEqual(std.math.Order.gt, later_anchor.compare(first));
    try std.testing.expectEqual(std.math.Order.lt, first.compare(same_anchor_later_focus));
    try std.testing.expectEqual(std.math.Order.gt, same_anchor_later_focus.compare(first));
    try std.testing.expectEqual(std.math.Order.eq, first.compare(first));
}

test "a selection whose focus sits in another text run is not ordered" {
    // The anchors agree, so the comparison reaches the focus and stops there.
    // Ordering the two focus indices alone would answer `lt`, and comparing
    // the anchors alone would answer `eq`. Neither is a real order.
    const here = selection(position(nodeId(3), 0), position(nodeId(3), 0));
    const there = selection(position(nodeId(3), 0), position(nodeId(4), 9));

    try std.testing.expectEqual(std.math.Order.eq, here.anchor.compare(there.anchor));
    try std.testing.expect(here.compare(there) == null);
    try std.testing.expect(!here.eql(there));
}

test "a backwards selection is ordered, not rejected" {
    // `focus` may precede `anchor`, so the ordering says which comes first
    // instead of refusing to answer.
    const forward = selection(position(nodeId(3), 0), position(nodeId(3), 9));
    const backward = selection(position(nodeId(3), 9), position(nodeId(3), 0));

    try std.testing.expectEqual(std.math.Order.lt, forward.compare(backward));
    try std.testing.expect(!forward.eql(backward));
}

test "a caret is a selection whose anchor equals its focus" {
    const at = position(nodeId(3), 6);
    const caret = selection(at, at);
    try std.testing.expect(caret.eql(selection(at, at)));
    try std.testing.expectEqual(std.math.Order.eq, caret.compare(selection(at, at)));

    const extended = selection(at, position(nodeId(3), 7));
    try std.testing.expect(!caret.eql(extended));
    try std.testing.expectEqual(std.math.Order.lt, caret.compare(extended));

    // `eql` must read the anchor as well as the focus. These two selections
    // share a focus and differ only in the anchor, and no other test in this
    // file gives `eql` that pair.
    const moved_anchor = selection(position(nodeId(3), 5), at);
    try std.testing.expect(!caret.eql(moved_anchor));
}

/// Black at full opacity.
const opaque_black: Color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 };
/// Black at zero opacity, which differs from `opaque_black` in one channel.
const clear_black: Color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 };

fn nodeId(content: u64) NodeId {
    return ids.nodeIdFromContent(content);
}

fn position(id: NodeId, character_index: usize) TextPosition {
    return .{ .node_id = id, .character_index = character_index };
}

fn selection(anchor: TextPosition, focus: TextPosition) TextSelection {
    return .{ .anchor = anchor, .focus = focus };
}
