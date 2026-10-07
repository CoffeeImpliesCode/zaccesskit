//! The free functions of `atspi-common/src/util.rs`: the text-offset
//! conversions and the scroll-edge map.
//!
//! **Upstream.** `accesskit_atspi_common/src/util.rs:59-134`. The three
//! `WindowBounds` methods at `util.rs:23-56` are in `window_bounds.zig`, which
//! already declares the type they hang off.
//!
//! **Why the file is split.** `AGENTS.md` section 6 says one upstream Rust file
//! becomes one Zig file, and `window_bounds.zig` holds `util.rs:9-134`. The
//! struct and its three methods are 130 lines and the free functions are another
//! 75, so one file would hold two unrelated jobs: a window's two boxes, and the
//! document text. `docs/41` section 2.2 lets a 250-line file split along its
//! function clusters, and the cluster boundary here is the type boundary.
//!
//! **What an offset is.** Every offset on this interface is a global USV
//! character index into the node's document, which is what `Text.GetStringAtOffset`
//! and `Text.GetText` carry. A negative offset names nothing and every function
//! here answers `null` or `error.IndexOutOfRange` for it, which is upstream's
//! `offset.try_into().ok()?` at `util.rs:61`.
//!
//! **One index name for the one concept.** `end_offset` of `-1` is the AT-SPI
//! spelling of "the end of the document", and `textRangeFromOffsets` is the only
//! function here that reads it. Every other offset is a plain index.
//!
//! **No allocator on the two functions that need none, and one on each that
//! does.** `textPositionFromOffset` allocates nothing. The three range functions
//! build ordering keys, which the consumer text layer allocates, so each takes
//! `gpa` first. `atspiScrollTypeToScrollHint` maps one enum onto another and
//! allocates nothing at all.
//!
//! **`error.IndexOutOfRange` means the same thing on both sides of the union.**
//! `adapter_errors.Error` declares it at `error.zig:43` and the consumer's
//! `QueryError` declares it at `tree_state.zig:667`. Zig merges two error sets by
//! member name, so a caller of the functions below catches one tag. That is
//! correct here: upstream raises the same tag for the same reason at
//! `util.rs:71` and `util.rs:75`, and the consumer's tag means the same thing.

const std = @import("std");

const adapter_errors = @import("error.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const wire = @import("wire.zig");

const NodeRef = consumer.node_id.NodeRef;
const Position = consumer.text.position.Position;
const QueryError = consumer.tree.QueryError;
const Range = consumer.text.range.Range;
const Rect = schema.Rect;
const ScrollHint = schema.ScrollHint;

/// The failures a text-offset conversion reports.
///
/// It is the adapter's own set joined to the consumer walk's set and to the
/// allocator's, because a conversion walks the text runs and builds ordering
/// keys and so can fail all three ways.
pub const UtilError = adapter_errors.Error || QueryError || std.mem.Allocator.Error;

/// The position `offset` names in `node`, or `null` when the offset is negative
/// or names nothing.
///
/// Upstream `text_position_from_offset` at `util.rs:59-65`, whose
/// `offset.try_into().ok()?` is the negative arm and whose
/// `text_position_from_global_usv_index` is the rest.
///
/// A character index past the end of the document raises `error.IndexOutOfRange`
/// rather than answering `null`, because that is what the consumer text layer
/// reports at `query.zig:268` and a caller has to see the difference between
/// "an index I refuse" and "an index that is past the end".
///
/// **Errors.** `error.TreeCycle` from a walk the lookup performed.
pub fn textPositionFromOffset(node: NodeRef, offset: i32) QueryError!?Position {
    if (offset < 0) return null;
    return consumer.text.query.textPositionFromGlobalUsvIndex(node, @intCast(offset));
}

/// The range `offset` names at `granularity`, from that position to the end of
/// the unit.
///
/// Upstream `text_range_from_offset` at `util.rs:67-94`. The start moves back to
/// the start of its unit and the end moves forward to the end of the same unit,
/// so a caller asking for the word at an offset gets that word and not the rest
/// of the document.
///
/// `granularity` of `.sentence` is refused with `error.UnsupportedTextGranularity`
/// at both of the places upstream refuses it, `util.rs:82-83` and `util.rs:89-90`,
/// because the consumer text layer defines no sentence boundary.
///
/// **Errors.** `error.IndexOutOfRange` when the offset names nothing,
/// `error.UnsupportedTextGranularity` for a sentence, `error.TreeCycle` from a
/// walk, and `error.OutOfMemory` from the ordering keys the range holds.
pub fn textRangeFromOffset(
    gpa: std.mem.Allocator,
    node: NodeRef,
    offset: i32,
    granularity: wire.Granularity,
) UtilError!Range {
    const start_offset = (try textPositionFromOffset(node, offset)) orelse
        return error.IndexOutOfRange;

    const start: Position = switch (granularity) {
        .char => start_offset,
        .line => if (consumer.text.position.isLineStart(start_offset))
            start_offset
        else
            try consumer.text.position_motion.backwardToLineStart(start_offset),
        .paragraph => if (try consumer.text.position.isParagraphStart(start_offset))
            start_offset
        else
            try consumer.text.position_motion.backwardToParagraphStart(start_offset),
        .sentence => return error.UnsupportedTextGranularity,
        .word => if (consumer.text.position.isWordStart(start_offset))
            start_offset
        else
            try consumer.text.position_motion.backwardToWordStart(start_offset),
    };

    const end: Position = switch (granularity) {
        .char => if (try consumer.text.position.isDocumentEnd(start_offset))
            start_offset
        else
            // The three character movements live in `text/position.zig`, not in
            // `text/position_motion.zig`: `position.zig:316` is
            // `forwardToCharacterEnd`, ported from `text.rs:320-329`. The
            // movement module holds the other thirty.
            try consumer.text.position.forwardToCharacterEnd(start),
        .line => try consumer.text.position_motion.forwardToLineEnd(start),
        .paragraph => try consumer.text.position_motion.forwardToParagraphEnd(start),
        // The `.char` arm above already refused a sentence, so this arm never
        // runs. It stays because upstream writes the refusal in both switches
        // and a switch with a missing member does not compile.
        .sentence => return error.UnsupportedTextGranularity,
        .word => try consumer.text.position_motion.forwardToWordEnd(start),
    };

    var range = try consumer.text.range.toDegenerateRange(gpa, start);
    try consumer.text.range.setEnd(gpa, &range, end);
    return range;
}

/// The range between two offsets, or `null` when either names nothing.
///
/// Upstream `text_range_from_offsets` at `util.rs:96-111`. An `end_offset` of
/// `-1` is the end of the document, which is the spelling `Text.GetText` uses
/// for "to the end".
///
/// **Errors.** `error.TreeCycle` from a walk, and `error.OutOfMemory` from the
/// ordering keys the range holds.
pub fn textRangeFromOffsets(
    gpa: std.mem.Allocator,
    node: NodeRef,
    start_offset: i32,
    end_offset: i32,
) UtilError!?Range {
    const start = (try textPositionFromOffset(node, start_offset)) orelse return null;
    const end = if (end_offset == document_end_offset)
        try consumer.text.query.documentEnd(node)
    else
        (try textPositionFromOffset(node, end_offset)) orelse return null;
    var range = try consumer.text.range.toDegenerateRange(gpa, start);
    try consumer.text.range.setEnd(gpa, &range, end);
    return range;
}

/// The `end_offset` that names the end of the document rather than a position.
///
/// Upstream writes the literal at `util.rs:101` and compares it at `node.rs:1460`
/// through this same function. It is a constant here so that the two spellings
/// are one value and a test can name it.
pub const document_end_offset: i32 = -1;

/// The one box that holds both endpoints of a range, or `null` when the range
/// covers no run.
///
/// Upstream `text_range_bounds_from_offsets` at `util.rs:113-122`, whose
/// `reduce` over the boxes is a union of each with the next. An empty list of
/// boxes reduces to nothing in Rust and answers `null` here.
///
/// **Bound.** The union walk is `boxes.items.len`, the list's own length, which
/// does not change while the walk runs.
///
/// **Errors.** `error.TreeCycle` from a walk, and `error.OutOfMemory` from the
/// boxes the range produces or from the ordering keys it holds.
pub fn textRangeBoundsFromOffsets(
    gpa: std.mem.Allocator,
    node: NodeRef,
    start_offset: i32,
    end_offset: i32,
) UtilError!?Rect {
    const range = (try textRangeFromOffsets(gpa, node, start_offset, end_offset)) orelse
        return null;
    var boxes = try consumer.text.range.boundingBoxes(gpa, range);
    defer boxes.deinit(gpa);
    if (boxes.items.len == 0) return null;

    var joined = boxes.items[0];
    var index: usize = 1;
    while (index < boxes.items.len) : (index += 1) {
        joined = joined.unionRect(boxes.items[index]);
    }
    return joined;
}

/// The hint a scroll edge names, or `null` for the edge that names none.
///
/// Upstream `atspi_scroll_type_to_scroll_hint` at `util.rs:124-134`. Six of the
/// seven AT-SPI scroll edges name a hint and `ScrollType::Anywhere` does not, so
/// a caller gets `null` and sends no hint rather than one a screen reader would
/// read as a direction.
///
/// **Errors.** This function does not fail.
pub fn atspiScrollTypeToScrollHint(scroll_type: wire.ScrollType) ?ScrollHint {
    return switch (scroll_type) {
        .top_left => .top_left,
        .bottom_right => .bottom_right,
        .top_edge => .top_edge,
        .bottom_edge => .bottom_edge,
        .left_edge => .left_edge,
        .right_edge => .right_edge,
        .anywhere => null,
    };
}

const testing = std.testing;

/// The `error.IndexOutOfRange` the two sources raise, named once so a test can
/// ask for it.
const no_position = error.IndexOutOfRange;

/// Stores `node` under `value` with `parent` as its parent id, so a test can
/// build a tree without the update algorithm. `consumer/text/query.zig:434`.
fn insert(
    gpa: std.mem.Allocator,
    state: *consumer.tree_state.TreeState,
    value: u64,
    parent: ?u64,
    node: schema.Node,
) !void {
    const id = consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0));
    const parent_and_index: ?consumer.tree_index.ParentAndIndex = if (parent) |parent_value|
        .{
            .parent_id = consumer.tree_index.FullNodeId.init(
                .{ .value = parent_value },
                .init(0),
            ),
            .index = 0,
        }
    else
        null;
    try state.nodes.put(gpa, id, .{
        .parent_and_index = parent_and_index,
        .data = node,
    });
}

/// The handle to the node stored under `value`.
fn handle(state: *const consumer.tree_state.TreeState, value: u64) !NodeRef {
    return NodeRef.init(
        state,
        consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0)),
    ) orelse error.NodeMissingFromFixture;
}

/// A text run whose `value` is `value` and whose character lengths are all one
/// byte, which is right for an ASCII value.
fn textRun(gpa: std.mem.Allocator, value: []const u8) !schema.Node {
    var node = schema.Node.init(gpa, .text_run);
    errdefer node.deinit();
    try schema.strings.setValue(&node.properties, value);
    const lengths = try gpa.alloc(u8, value.len);
    defer gpa.free(lengths);
    @memset(lengths, 1);
    try schema.vectors.setCharacterLengths(&node.properties, lengths);
    return node;
}

/// A `TextInput` over the runs `values` names, which is the shape every text
/// function in this file is written against.
fn documentOver(
    gpa: std.mem.Allocator,
    state: *consumer.tree_state.TreeState,
    values: []const []const u8,
) !void {
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    const children = try gpa.alloc(schema.NodeId, values.len);
    defer gpa.free(children);
    for (values, 0..) |_, index| children[index] = .{ .value = @intCast(index + 1) };
    try schema.ids_props.setChildren(&document.properties, children);
    try insert(gpa, state, 0, null, document);
    for (values, 0..) |value, index| {
        try insert(gpa, state, @intCast(index + 1), 0, try textRun(gpa, value));
    }
}

test "an offset names the run that holds it" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{ "hello", "world" });
    const node = try handle(&state, 0);

    const at_zero = (try textPositionFromOffset(node, 0)) orelse
        return error.NoPosition;
    try testing.expectEqual(@as(usize, 0), at_zero.inner.character_index);
    // Index 5 is the leading edge of the second run, so it belongs there.
    const at_five = (try textPositionFromOffset(node, 5)) orelse
        return error.NoPosition;
    try testing.expectEqual(@as(usize, 0), at_five.inner.character_index);
}

test "a negative offset names nothing rather than wrapping" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{"hello"});
    const node = try handle(&state, 0);

    try testing.expectEqual(@as(?Position, null), try textPositionFromOffset(node, -1));
    try testing.expectError(
        no_position,
        textRangeFromOffset(gpa, node, -1, .char),
    );
}

test "one range from an offset at each granularity the reference names" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{"hello"});
    const node = try handle(&state, 0);

    // The whole word is five characters, so a character range at offset one is
    // one character and a word range at the same offset is five.
    const one_character = try textRangeFromOffset(gpa, node, 1, .char);
    const whole_word = try textRangeFromOffset(gpa, node, 1, .word);
    try testing.expectEqual(@as(usize, 1), one_character.start.character_index);
    try testing.expectEqual(@as(usize, 2), one_character.end.character_index);
    try testing.expectEqual(@as(usize, 0), whole_word.start.character_index);
    try testing.expectEqual(@as(usize, 5), whole_word.end.character_index);
}

test "a sentence is refused because the text layer defines no sentence" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{"hello"});
    const node = try handle(&state, 0);

    // Upstream refuses it in both switches, at `util.rs:82-83` and `:89-90`.
    try testing.expectError(
        error.UnsupportedTextGranularity,
        textRangeFromOffset(gpa, node, 0, .sentence),
    );
}

test "two offsets name the range between them" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{ "hello", "world" });
    const node = try handle(&state, 0);

    const middle = (try textRangeFromOffsets(gpa, node, 1, 3)) orelse
        return error.NoRange;
    try testing.expectEqual(@as(usize, 1), middle.start.character_index);
    try testing.expectEqual(@as(usize, 3), middle.end.character_index);
}

test "an end offset of minus one is the end of the document" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{ "hello", "world" });
    const node = try handle(&state, 0);

    const to_the_end = (try textRangeFromOffsets(gpa, node, 5, document_end_offset)) orelse
        return error.NoRange;
    // Two runs of five characters each, so the document ends at index ten in the
    // last run.
    try testing.expectEqual(@as(usize, 5), to_the_end.end.character_index);
    // `Range.end` is an `InnerPosition`, which names a run and a character
    // index but not the document. `range.end` at `text/range.zig:204` is the
    // lift that pairs it with the range's own node, so a whole `Position`
    // reaches the index conversion.
    try testing.expectEqual(@as(usize, 10), try consumer.text.position.toGlobalUsvIndex(
        consumer.text.range.end(to_the_end),
    ));
}

test "an offset that names nothing answers null instead of a range" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{"hello"});
    const node = try handle(&state, 0);

    try testing.expectEqual(
        @as(?Range, null),
        try textRangeFromOffsets(gpa, node, -1, 1),
    );
}

test "the bounds of a range are the union of the boxes it covers" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try documentOver(gpa, &state, &.{"hello"});
    const node = try handle(&state, 0);

    // No run in this fixture states a box, so the union of nothing is nothing.
    try testing.expectEqual(
        @as(?Rect, null),
        try textRangeBoundsFromOffsets(gpa, node, 0, 3),
    );
}

test "the six named scroll edges map to a hint and the seventh names none" {
    try testing.expectEqual(
        ScrollHint.top_left,
        atspiScrollTypeToScrollHint(.top_left).?,
    );
    try testing.expectEqual(
        ScrollHint.bottom_right,
        atspiScrollTypeToScrollHint(.bottom_right).?,
    );
    try testing.expectEqual(
        ScrollHint.top_edge,
        atspiScrollTypeToScrollHint(.top_edge).?,
    );
    try testing.expectEqual(
        ScrollHint.bottom_edge,
        atspiScrollTypeToScrollHint(.bottom_edge).?,
    );
    try testing.expectEqual(
        ScrollHint.left_edge,
        atspiScrollTypeToScrollHint(.left_edge).?,
    );
    try testing.expectEqual(
        ScrollHint.right_edge,
        atspiScrollTypeToScrollHint(.right_edge).?,
    );
    // `ScrollType::Anywhere` is `util.rs:133`, the one arm that answers none.
    try testing.expectEqual(@as(?ScrollHint, null), atspiScrollTypeToScrollHint(.anywhere));
}

test "the six named scroll edges have six distinct hints" {
    // The sweep is the coverage argument: a seventh member added to
    // `wire.ScrollType` reaches this loop, and a target two edges share would
    // mean two edges scroll the same way, which is what upstream's six distinct
    // arms at `util.rs:126-132` avoid.
    var seen: u8 = 0;
    inline for (comptime std.enums.values(wire.ScrollType)) |edge| {
        if (atspiScrollTypeToScrollHint(edge)) |hint| {
            // `ScrollHint` is `enum(u8)`, so `@intFromEnum` answers `u8`.
            // The shift amount of a `u8` shift is `u3`, and the enum has six
            // members with tags zero through five, so the narrowing is in
            // range for every member the sweep reaches.
            const bit = @as(u8, 1) << @as(u3, @intCast(@intFromEnum(hint)));
            try testing.expectEqual(@as(u8, 0), seen & bit);
            seen |= bit;
        }
    }
    // Six hints set, which is the six arms that answer one.
    try testing.expectEqual(@as(u8, 0b111111), seen);
}
