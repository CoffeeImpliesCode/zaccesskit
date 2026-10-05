//! The text queries a node answers: its runs, its document, its selection, the
//! position nearest a point, and the two index-unit conversions.
//!
//! Upstream `accesskit_consumer/src/text.rs:1365-1650`. `docs/30-port-design.md`
//! section 3.2 calls this module "the string-driven queries", which is the two
//! index conversions and the queries around them.
//!
//! **`text_attributes_differ` is not here.** Upstream puts it at `text.rs:1366`,
//! in this range. It belongs to `text/position_inner.zig`, because
//! `Position::is_format_start` at `text.rs:175` and the three format walks at
//! `text.rs:343`, `:358` and `:362` all call it and none of them may import this
//! module: this module needs `text/position.zig`, so a second edge back would
//! close a cycle. `text/position_inner.zig` is below all three callers and
//! already owns the walk the comparison uses.
//!
//! **`WeakRange::upgrade` and `upgrade_node` are here.** They need
//! `supportsTextRanges`, and `text/range.zig` may not import this module for the
//! same reason, so those two methods of the type declared in `text/range.zig`
//! are free functions in this module.
//!
//! **Every operation is a free function whose first parameter is the receiver.**
//! This module declares no struct body.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const geometry = @import("../node_ref/geometry.zig");
const predicates = @import("../node_ref/predicates.zig");
const properties = @import("../node_ref/properties.zig");
const hit_test = @import("hit_test.zig");
const position = @import("position.zig");
const position_inner = @import("position_inner.zig");
const position_motion = @import("position_motion.zig");
const range = @import("range.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const InnerPosition = position_inner.InnerPosition;
const NodeRef = @import("../node_id.zig").NodeRef;
const Point = schema.Point;
const Position = position.Position;
const QueryError = tree_state.QueryError;
const TreeState = tree_state.TreeState;
const WeakRange = range.WeakRange;

const testing = std.testing;

// --- Document extent ------------------------------------------------------
//
// `textRuns`, `followingTextRuns` and `precedingTextRuns` are
// `text/position_inner.zig`'s. Upstream holds them at `text.rs:1381-1400`, and
// `position_inner.zig`'s biased helpers call them at `text.rs:76`, `:80`, `:85`
// and `:97`, so that module owns them and this one reuses them. See that
// module's doc for the placement argument.

// --- Document extent ---------------------------------------------------------

/// Whether the node's role allows text and at least one run exists.
///
/// `Role.label`, `Role.document` and `Role.terminal` allow text without being a
/// text input. Upstream `supports_text_ranges` at `text.rs:1402-1406`.
///
/// This is the precondition of `documentStart`, `documentEnd` and
/// `documentRange`, and of `rangeIsItalic` and the other range folds, because
/// those need at least one run to visit.
pub fn supportsTextRanges(node: NodeRef) QueryError!bool {
    if (!predicates.isTextInput(node)) {
        switch (properties.role(node)) {
            .label, .document, .terminal => {},
            else => return false,
        }
    }
    var runs = try position_inner.textRuns(node);
    return (try runs.next()) != null;
}

/// The first position of the document, at character 0 of the first run.
pub fn documentStart(node: NodeRef) QueryError!Position {
    return .{ .root_node = node, .inner = try documentStartInner(node) };
}

/// The position past the last character of the last run.
pub fn documentEnd(node: NodeRef) QueryError!Position {
    return .{ .root_node = node, .inner = try documentEndInner(node) };
}

/// The whole document as one range, from its first position to its last.
///
/// `error.InvalidPosition` is not reachable: the two positions are ordered
/// because they come from the first and the last run, and `error.OutOfMemory`
/// means the ordering keys could not be allocated.
pub fn documentRange(gpa: std.mem.Allocator, node: NodeRef) QueryError!range.Range {
    return range.init(gpa, node, try documentStartInner(node), try documentEndInner(node));
}

fn documentStartInner(node: NodeRef) QueryError!InnerPosition {
    var runs = try position_inner.textRuns(node);
    const first = try runs.next();
    // `supportsTextRanges` is the precondition of every caller and it requires
    // at least one run, so this read cannot be null. Upstream unwraps it at
    // `text.rs:1409`, and the port asserts it rather than panicking.
    std.debug.assert(first != null);
    return .{ .node = first.?, .character_index = 0 };
}

fn documentEndInner(node: NodeRef) QueryError!InnerPosition {
    var runs = try position_inner.textRuns(node);
    const last = try runs.nextBack();
    std.debug.assert(last != null);
    return .{
        .node = last.?,
        .character_index = schema.vectors.characterLengths(&last.?.data().properties).len,
    };
}

// --- Selection ---------------------------------------------------------------

/// Whether the node carries a text selection or a caret.
pub fn hasTextSelection(node: NodeRef) bool {
    return schema.option.textSelection(&node.data().properties) != null;
}

/// The selection as a range over the node's text, or `null` when the node
/// declares no selection or when the stored selection names a run that is gone.
///
/// Upstream `text_selection` at `text.rs:1448-1457` unwraps both endpoints at
/// `:1452` and `:1454`. The port answers `null`, because a selection stored
/// before an update can outlive the run it names and a caller can act on that.
pub fn textSelection(gpa: std.mem.Allocator, node: NodeRef) QueryError!?range.Range {
    const stored = schema.option.textSelection(&node.data().properties) orelse return null;
    const anchor = position_inner.clampedUpgrade(node.tree_state, stored.anchor, node.id()) orelse
        return null;
    const focus = position_inner.clampedUpgrade(node.tree_state, stored.focus, node.id()) orelse
        return null;
    return try range.init(gpa, node, anchor, focus);
}

/// The selection anchor as a position, or `null` when there is no selection or
/// the anchor names a run that is gone.
pub fn textSelectionAnchor(node: NodeRef) ?Position {
    const stored = schema.option.textSelection(&node.data().properties) orelse return null;
    const anchor = position_inner.clampedUpgrade(node.tree_state, stored.anchor, node.id()) orelse
        return null;
    return .{ .root_node = node, .inner = anchor };
}

/// The selection focus as a position, or `null` when there is no selection or
/// the focus names a run that is gone.
pub fn textSelectionFocus(node: NodeRef) ?Position {
    const stored = schema.option.textSelection(&node.data().properties) orelse return null;
    const focus = position_inner.clampedUpgrade(node.tree_state, stored.focus, node.id()) orelse
        return null;
    return .{ .root_node = node, .inner = focus };
}

// --- Points ------------------------------------------------------------------

/// The position in the node's text nearest `point`.
///
/// `point` is in the node's own coordinate space. The search is in three steps:
/// the deepest text run holding the point, then the document start when the
/// point lies before every run, then the end of the last run the point is past.
/// A point that is inside the node but outside every run lands on one of the
/// two edges. Upstream `text_position_at_point` at `text.rs:1485-1546`.
///
/// `error.TreeCycle` means the inherited-direction or transform walk reached its
/// bound.
pub fn textPositionAtPoint(
    gpa: std.mem.Allocator,
    node: NodeRef,
    point: Point,
) QueryError!Position {
    if (try geometry.hitTest(gpa, node, point, hit_test.text_run_filter)) |hit| {
        if (hit.node.data().role == .text_run) {
            const index = (try hit_test.characterIndexAtPoint(hit.node, hit.point)) orelse 0;
            return .{
                .root_node = node,
                .inner = .{ .node = hit.node, .character_index = index },
            };
        }
    }

    // Past this point the node is known to hold no text run at `point`, which is
    // the state upstream states in its comment at `text.rs:1500-1501`.
    var forward = try position_inner.textRuns(node);
    if (try forward.next()) |first_run| {
        if (try geometry.boundingBoxInCoordinateSpace(first_run, node)) |box| {
            if (point.x < box.x0 or point.y < box.y0) return try documentStart(node);
        }
    }
    var backward = try position_inner.textRuns(node);
    while (try backward.nextBack()) |run| {
        const box = (try geometry.boundingBoxInCoordinateSpace(run, node)) orelse continue;
        const direction = try hit_test.inheritedTextDirection(run) orelse continue;
        // The two vertical cases treat the box as y-down in the node's own
        // coordinate space, which is the assumption upstream states at
        // `text.rs:1522-1524`.
        const past_end = switch (direction) {
            .left_to_right => point.y >= box.y0 and point.y < box.y1 and point.x >= box.x1,
            .right_to_left => point.y >= box.y0 and point.y < box.y1 and point.x < box.x0,
            .top_to_bottom => point.x >= box.x0 and point.x < box.x1 and point.y >= box.y1,
            .bottom_to_top => point.x >= box.x0 and point.x < box.x1 and point.y < box.y0,
        };
        if (past_end) {
            return .{
                .root_node = node,
                .inner = .{
                    .node = run,
                    .character_index = schema.vectors.characterLengths(
                        &run.data().properties,
                    ).len,
                },
            };
        }
    }
    return try documentEnd(node);
}

/// The range covering line `line_index`, counting the first line as 0.
///
/// `null` when the document has fewer lines than that. Upstream
/// `line_range_from_index` at `text.rs:1548-1569`. The loop is bounded by
/// `line_index`, which is the caller's own number, so it cannot outlive the
/// document test above it.
pub fn lineRangeFromIndex(
    gpa: std.mem.Allocator,
    node: NodeRef,
    line_index: usize,
) QueryError!?range.Range {
    var current = try documentStart(node);
    if (line_index > 0) {
        if (try position.isDocumentEnd(current)) return null;
        if (try position.isDocumentEnd(try position_motion.forwardToLineEnd(current))) return null;
        var remaining = line_index;
        while (remaining > 0) {
            if (try position.isDocumentEnd(current)) return null;
            current = try position_motion.forwardToLineStart(current);
            remaining -= 1;
        }
    }
    const line_end = if (try position.isDocumentEnd(current))
        current
    else
        try position_motion.forwardToLineEnd(current);
    return try range.init(gpa, node, current.inner, line_end.inner);
}

// --- Index conversions -------------------------------------------------------

/// The position at `index`, counted in Unicode scalar values over every run of
/// the document.
///
/// An index equal to the whole document length answers the document end, and an
/// index past it answers `null`. Upstream
/// `text_position_from_global_usv_index` at `text.rs:1571-1608`.
///
/// `error.IndexOutOfRange` replaces the panic at `text.rs:1600`. It reports a
/// run whose `character_lengths` covers fewer characters than its `value`
/// holds, or a character length that runs past the end of the value, so the
/// two properties of that run disagree.
pub fn textPositionFromGlobalUsvIndex(
    node: NodeRef,
    index: usize,
) QueryError!?Position {
    var total_length: usize = 0;
    var runs = try position_inner.textRuns(node);
    while (try runs.next()) |run| {
        const value = runValue(run);
        const run_length = std.unicode.utf8CountCodepoints(value) catch 0;
        const new_total_length = total_length + run_length;
        if (index >= total_length and index < new_total_length) {
            return try usvPositionIn(node, run, value, index - total_length);
        }
        total_length = new_total_length;
    }
    if (index == total_length) return try documentEnd(node);
    return null;
}

/// The position at `index`, counted in UTF-16 code units over every run of the
/// document.
///
/// A code point outside the basic multilingual plane counts as two units, which
/// is what upstream's `char::len_utf16` sum at `text.rs:1614` counts. An index
/// equal to the whole document length answers the document end, and an index
/// past it answers `null`.
///
/// `error.IndexOutOfRange` replaces the panic at `text.rs:1639`, with the same
/// meaning as in `textPositionFromGlobalUsvIndex`.
pub fn textPositionFromGlobalUtf16Index(
    node: NodeRef,
    index: usize,
) QueryError!?Position {
    var total_length: usize = 0;
    var runs = try position_inner.textRuns(node);
    while (try runs.next()) |run| {
        const value = runValue(run);
        const new_total_length = total_length + utf16Length(value);
        if (index >= total_length and index < new_total_length) {
            return try utf16PositionIn(node, run, value, index - total_length);
        }
        total_length = new_total_length;
    }
    if (index == total_length) return try documentEnd(node);
    return null;
}

/// The value of a run, or an empty slice when the run declares none. Upstream
/// unwraps the same read at `text.rs:1574` and `text.rs:1613`; a run with no
/// value contributes no characters here rather than ending the scan.
fn runValue(run: NodeRef) []const u8 {
    return schema.strings.value(&run.data().properties) orelse "";
}

fn usvPositionIn(
    node: NodeRef,
    run: NodeRef,
    value: []const u8,
    index: usize,
) QueryError!Position {
    var utf8_length: usize = 0;
    var scalar_length: usize = 0;
    // The bound is the run's own character count, which is the length of the
    // list upstream enumerates at `text.rs:1582`.
    const lengths = schema.vectors.characterLengths(&run.data().properties);
    for (lengths, 0..) |utf8_char_length, character_index| {
        const new_utf8_length = utf8_length + @as(usize, utf8_char_length);
        if (new_utf8_length > value.len) return error.IndexOutOfRange;
        const character_scalars = std.unicode.utf8CountCodepoints(
            value[utf8_length..new_utf8_length],
        ) catch 0;
        const new_scalar_length = scalar_length + character_scalars;
        if (index >= scalar_length and index < new_scalar_length) {
            return .{
                .root_node = node,
                .inner = .{ .node = run, .character_index = character_index },
            };
        }
        utf8_length = new_utf8_length;
        scalar_length = new_scalar_length;
    }
    return error.IndexOutOfRange;
}

fn utf16PositionIn(
    node: NodeRef,
    run: NodeRef,
    value: []const u8,
    index: usize,
) QueryError!Position {
    var utf8_length: usize = 0;
    var utf16_length: usize = 0;
    const lengths = schema.vectors.characterLengths(&run.data().properties);
    for (lengths, 0..) |utf8_char_length, character_index| {
        const new_utf8_length = utf8_length + @as(usize, utf8_char_length);
        if (new_utf8_length > value.len) return error.IndexOutOfRange;
        const new_utf16_length = utf16_length + utf16Length(value[utf8_length..new_utf8_length]);
        if (index >= utf16_length and index < new_utf16_length) {
            return .{
                .root_node = node,
                .inner = .{ .node = run, .character_index = character_index },
            };
        }
        utf8_length = new_utf8_length;
        utf16_length = new_utf16_length;
    }
    return error.IndexOutOfRange;
}

/// The number of UTF-16 code units `bytes` holds, which is the code point count
/// plus one for every code point outside the basic multilingual plane.
fn utf16Length(bytes: []const u8) usize {
    var total: usize = 0;
    var view = std.unicode.Utf8View.init(bytes) catch return 0;
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        total += if (slice.len == 4) 2 else 1;
    }
    return total;
}

// --- Weak ranges -------------------------------------------------------------

/// The node a weak range was measured against, or `null` when the tree no
/// longer holds it or when it no longer declares text runs.
///
/// Upstream `WeakRange::upgrade_node` at `text.rs:918-922`.
pub fn upgradeNode(weak: WeakRange, state: *const TreeState) QueryError!?NodeRef {
    const node = state.nodeById(weak.node_id) orelse return null;
    if (!(try supportsTextRanges(node))) return null;
    return node;
}

/// The range a weak range names, or `null` when the node, either endpoint or the
/// run behind an endpoint is gone.
///
/// The endpoints keep the stored character index as it was; `upgrade` validates
/// it against the run rather than clamping it, which is what separates it from
/// `textSelection`. Upstream `WeakRange::upgrade` at `text.rs:924-929`.
pub fn upgrade(weak: WeakRange, state: *const TreeState) QueryError!?range.Range {
    const node = try upgradeNode(weak, state) orelse return null;
    const start = position_inner.upgrade(state, weak.start, weak.node_id) orelse return null;
    const end = position_inner.upgrade(state, weak.end, weak.node_id) orelse return null;
    return .{ .node = node, .start = start, .end = end };
}

// --- Tests -------------------------------------------------------------------

/// Stores `node` under `value` with `parent` as its parent id, so a test can
/// build a tree without the update algorithm.
fn insert(
    state: *TreeState,
    gpa: std.mem.Allocator,
    value: u64,
    parent: ?u64,
    node: schema.Node,
) !void {
    const id = FullNodeId.init(.{ .value = value }, .init(0));
    const parent_and_index: ?tree_index.ParentAndIndex = if (parent) |parent_value|
        .{ .parent_id = FullNodeId.init(.{ .value = parent_value }, .init(0)), .index = 0 }
    else
        null;
    try state.nodes.put(gpa, id, .{
        .parent_and_index = parent_and_index,
        .data = node,
    });
}

fn handle(state: *const TreeState, value: u64) NodeRef {
    return NodeRef.init(state, FullNodeId.init(.{ .value = value }, .init(0))).?;
}

/// The map entry for `value`, which is where a fixture must write.
///
/// **A `Node` read out of the map by value is detached from it.** `data` owns
/// the property store's buffers and `TreeState.deinit` releases the map's copy,
/// so writing through a copy releases storage the map still names and the next
/// `deinit` walks freed memory. This is memory unsafety rather than a lost
/// write, which is why the trap is worth naming here and not only in each
/// fixture. `NodeRef.data` cannot cause it, because it already answers
/// `*const Node`.
fn entry(state: *TreeState, value: u64) *tree_state.NodeState {
    return state.nodes.getPtr(FullNodeId.init(.{ .value = value }, .init(0))).?;
}

/// A text run whose `value` is `value` and whose `character_lengths` are all
/// one byte, which is right for an ASCII value.
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

/// A `TextInput` over the runs built by `addRuns`.
fn documentOver(
    state: *TreeState,
    gpa: std.mem.Allocator,
    values: []const []const u8,
) !void {
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    const children = try gpa.alloc(schema.NodeId, values.len);
    defer gpa.free(children);
    for (values, 0..) |_, index| children[index] = .{ .value = @intCast(index + 1) };
    try schema.ids_props.setChildren(&document.properties, children);
    try insert(state, gpa, 0, null, document);
    for (values, 0..) |value, index| {
        try insert(state, gpa, @intCast(index + 1), 0, try textRun(gpa, value));
    }
}

test "supportsTextRanges needs an allowed role and at least one run" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{"hello"});

    try testing.expect(try supportsTextRanges(handle(&state, 0)));
    // A plain label with no runs is not a text node, which is the second half of
    // the condition at `text.rs:1405`.
    var empty_label = schema.Node.init(gpa, .label);
    errdefer empty_label.deinit();
    try insert(&state, gpa, 9, 0, empty_label);
    try testing.expect(!(try supportsTextRanges(handle(&state, 9))));
    // The run itself is not a text input either.
    try testing.expect(!(try supportsTextRanges(handle(&state, 1))));
}

test "a label with a run supports text ranges" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var label = schema.Node.init(gpa, .label);
    errdefer label.deinit();
    try schema.ids_props.setChildren(&label.properties, &.{.{ .value = 1 }});
    try insert(&state, gpa, 0, null, label);
    try insert(&state, gpa, 1, 0, try textRun(gpa, "hi"));

    try testing.expect(try supportsTextRanges(handle(&state, 0)));
}

test "the document range spans every run in order" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{ "hello", "world" });

    const whole = try documentRange(gpa, handle(&state, 0));
    try testing.expect(sameNode(whole.start.node, handle(&state, 1)));
    try testing.expectEqual(@as(usize, 0), whole.start.character_index);
    try testing.expect(sameNode(whole.end.node, handle(&state, 2)));
    try testing.expectEqual(@as(usize, 5), whole.end.character_index);
}

test "a stored selection reads back as a range and as two positions" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{ "hello", "world" });

    const document_entry = entry(&state, 0);
    try schema.option.setTextSelection(&document_entry.data.properties, .{
        .anchor = .{ .node_id = .{ .value = 1 }, .character_index = 1 },
        .focus = .{ .node_id = .{ .value = 2 }, .character_index = 3 },
    });

    const node_ref = handle(&state, 0);
    try testing.expect(hasTextSelection(node_ref));
    const selected = (try textSelection(gpa, node_ref)).?;
    try testing.expectEqual(@as(usize, 1), selected.start.character_index);
    try testing.expectEqual(@as(usize, 3), selected.end.character_index);
    try testing.expectEqual(@as(usize, 1), textSelectionAnchor(node_ref).?.inner.character_index);
    try testing.expectEqual(@as(usize, 3), textSelectionFocus(node_ref).?.inner.character_index);
}

test "a selection naming a run that is gone answers null instead of unwrapping" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{"hello"});

    const document_entry = entry(&state, 0);
    try schema.option.setTextSelection(&document_entry.data.properties, .{
        .anchor = .{ .node_id = .{ .value = 7 }, .character_index = 0 },
        .focus = .{ .node_id = .{ .value = 7 }, .character_index = 0 },
    });

    const node_ref = handle(&state, 0);
    // Upstream unwraps both upgrades at `text.rs:1452` and `:1454`. A stale
    // selection is reachable from an ordinary update, so the port answers null.
    try testing.expectEqual(@as(?range.Range, null), try textSelection(gpa, node_ref));
    try testing.expectEqual(@as(?Position, null), textSelectionAnchor(node_ref));
    try testing.expectEqual(@as(?Position, null), textSelectionFocus(node_ref));
}

test "a scalar index addresses the run that holds it" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{ "hello", "world" });
    const node_ref = handle(&state, 0);

    const at_zero = (try textPositionFromGlobalUsvIndex(node_ref, 0)).?;
    try testing.expect(sameNode(at_zero.inner.node, handle(&state, 1)));
    try testing.expectEqual(@as(usize, 0), at_zero.inner.character_index);

    // Index 5 is the leading edge of the second run, so it belongs there and not
    // at the end of the first.
    const at_five = (try textPositionFromGlobalUsvIndex(node_ref, 5)).?;
    try testing.expect(sameNode(at_five.inner.node, handle(&state, 2)));
    try testing.expectEqual(@as(usize, 0), at_five.inner.character_index);

    const at_seven = (try textPositionFromGlobalUsvIndex(node_ref, 7)).?;
    try testing.expectEqual(@as(usize, 2), at_seven.inner.character_index);
}

test "a scalar index equal to the document length answers the document end" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{ "hello", "world" });
    const node_ref = handle(&state, 0);

    const at_end = (try textPositionFromGlobalUsvIndex(node_ref, 10)).?;
    try testing.expect(sameNode(at_end.inner.node, handle(&state, 2)));
    try testing.expectEqual(@as(usize, 5), at_end.inner.character_index);

    try testing.expectEqual(@as(?Position, null), try textPositionFromGlobalUsvIndex(node_ref, 11));
}

test "a scalar index past the run lengths is refused rather than unwrapped" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try insert(&state, gpa, 0, null, document);
    // The value holds three characters and the lengths list names two, so the
    // two properties of the run disagree and index 2 matches neither.
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "abc");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1 });
    try insert(&state, gpa, 1, 0, run_node);

    const second = (try textPositionFromGlobalUsvIndex(handle(&state, 0), 1)).?;
    try testing.expectEqual(@as(usize, 1), second.inner.character_index);
    try testing.expectError(
        error.IndexOutOfRange,
        textPositionFromGlobalUsvIndex(handle(&state, 0), 2),
    );
}

test "a UTF-16 index counts a supplementary code point as two units" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try insert(&state, gpa, 0, null, document);
    // "a" then U+1F600 is four UTF-8 bytes and two UTF-16 units, so the scalar
    // index and the UTF-16 index part company after the first character.
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "a\xF0\x9F\x98\x80");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 4 });
    try insert(&state, gpa, 1, 0, run_node);
    const node_ref = handle(&state, 0);

    const scalar_second = (try textPositionFromGlobalUsvIndex(node_ref, 1)).?;
    try testing.expectEqual(@as(usize, 1), scalar_second.inner.character_index);
    const utf16_second = (try textPositionFromGlobalUtf16Index(node_ref, 1)).?;
    try testing.expectEqual(@as(usize, 1), utf16_second.inner.character_index);
    // Unit 2 is inside the supplementary code point, which the two counts do
    // not share, so the UTF-16 scan still answers character 1.
    const utf16_third = (try textPositionFromGlobalUtf16Index(node_ref, 2)).?;
    try testing.expectEqual(@as(usize, 1), utf16_third.inner.character_index);
    // Unit 3 is past the end of the run, so it is the document end.
    const utf16_end = (try textPositionFromGlobalUtf16Index(node_ref, 3)).?;
    try testing.expectEqual(@as(usize, 2), utf16_end.inner.character_index);
}

test "a UTF-16 index past the document length answers null" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{"hello"});
    const node_ref = handle(&state, 0);

    try testing.expectEqual(
        @as(?Position, null),
        try textPositionFromGlobalUtf16Index(node_ref, 6),
    );
}

test "a UTF-16 index past the run lengths is refused rather than unwrapped" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try insert(&state, gpa, 0, null, document);
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "abc");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1 });
    try insert(&state, gpa, 1, 0, run_node);

    try testing.expectError(
        error.IndexOutOfRange,
        textPositionFromGlobalUtf16Index(handle(&state, 0), 2),
    );
}

test "a weak range whose node and endpoints survive upgrades" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{ "hello", "world" });

    var weak = try range.downgrade(gpa, try range.init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 1 },
        .{ .node = handle(&state, 2), .character_index = 3 },
    ));
    defer weak.deinit();

    const upgraded = (try upgrade(weak, &state)).?;
    try testing.expect(sameNode(upgraded.node, handle(&state, 0)));
    try testing.expectEqual(@as(usize, 1), upgraded.start.character_index);
    try testing.expectEqual(@as(usize, 3), upgraded.end.character_index);
    try testing.expect((try upgradeNode(weak, &state)) != null);
}

test "a weak range over a node that no longer supports text upgrades to null" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{"hello"});

    var weak = try range.downgrade(gpa, try range.init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 1 },
        .{ .node = handle(&state, 1), .character_index = 3 },
    ));
    defer weak.deinit();

    // The role stops allowing text, so the filter at `text.rs:922` drops the
    // node and neither upgrade answers.
    entry(&state, 0).data.setRole(.button);
    try testing.expectEqual(@as(?NodeRef, null), try upgradeNode(weak, &state));
    try testing.expectEqual(@as(?range.Range, null), try upgrade(weak, &state));
}

test "a point on the far edge of a run selects the position past its last character" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{"abcd"});

    const run_entry = entry(&state, 1);
    try schema.option.setBounds(&run_entry.data.properties, schema.rectInit(0, 0, 40, 20));
    try schema.vectors.setCharacterPositions(&run_entry.data.properties, &.{ 0, 10, 20, 30 });
    try schema.vectors.setCharacterWidths(&run_entry.data.properties, &.{ 10, 10, 10, 10 });
    try schema.enums.setTextDirection(&run_entry.data.properties, .left_to_right);

    const node_ref = handle(&state, 0);
    // x = 20 sits exactly on the edge character 1 ends at and character 2
    // begins at, and x = 40 is the run's own far edge.
    const on_edge = try textPositionAtPoint(gpa, node_ref, schema.pointInit(20, 10));
    try testing.expectEqual(@as(usize, 2), on_edge.inner.character_index);
    const past_end = try textPositionAtPoint(gpa, node_ref, schema.pointInit(60, 10));
    try testing.expectEqual(@as(usize, 4), past_end.inner.character_index);
}

test "a property write through the map entry lands in the node the map holds" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{ "hello", "world" });

    // Every write below goes through `entry`, so the state owns exactly one
    // copy of each buffer and the `deinit` above releases it exactly once. A
    // write through a `Node` copied out of the map instead would release table
    // storage the map still names, and `deinit` would abort in
    // `schema/props/table.zig` on a corrupt value rather than fail an
    // assertion here.
    entry(&state, 0).data.setRole(.document);
    try schema.strings.setLabel(&entry(&state, 0).data.properties, "Greeting");
    try schema.option.setTextSelection(&entry(&state, 0).data.properties, .{
        .anchor = .{ .node_id = .{ .value = 1 }, .character_index = 0 },
        .focus = .{ .node_id = .{ .value = 2 }, .character_index = 5 },
    });

    // The writes are visible through the map's own storage, which is what
    // proves they landed in the node rather than on a detached copy.
    const document_node = handle(&state, 0);
    try testing.expectEqual(schema.Role.document, document_node.data().role);
    try testing.expectEqualStrings(
        "Greeting",
        schema.strings.label(&document_node.data().properties).?,
    );
    try testing.expect(hasTextSelection(document_node));
}

test "a line range covers the only line and a line past it is absent" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try documentOver(&state, gpa, &.{"hello"});
    const node_ref = handle(&state, 0);

    // "hello" has no hard line break, so the document is one line and line 0 is
    // the whole document.
    const first = (try lineRangeFromIndex(gpa, node_ref, 0)).?;
    try testing.expect(sameNode(first.start.node, handle(&state, 1)));
    try testing.expectEqual(@as(usize, 0), first.start.character_index);
    try testing.expect(sameNode(first.end.node, handle(&state, 1)));
    try testing.expectEqual(@as(usize, 5), first.end.character_index);
    // Line 1 does not exist, so the answer is null rather than a clamped range.
    try testing.expectEqual(@as(?range.Range, null), try lineRangeFromIndex(gpa, node_ref, 1));
}

fn sameNode(a: NodeRef, b: NodeRef) bool {
    const a_id = a.id();
    const b_id = b.id();
    return a_id.tree_index == b_id.tree_index and a_id.local.eql(b_id.local);
}
