//! The text-run filter and the character a point falls on.
//!
//! Upstream `accesskit_consumer/src/text.rs:932-978`. `docs/30-port-design.md`
//! section 3.2 cuts this block out of `text.rs:932-1364` because the
//! inherited-accessor macro below the two functions has nothing in common with
//! them. This file is the two-function half of that split, and
//! `text/inherited.zig` is the macro half.
//!
//! **Why there are two filters.** Descendant and hit-test walks visit nodes
//! below the requested root, so they use the stateless text-run filter.
//! Sibling scans also offer ancestors to the filter while climbing. They must
//! include the document root to stop there, without yielding that ancestor as
//! a run. Their cursors own the root ID by value and borrow it as the filter
//! context only during each synchronous scan.
//!
//! **What this module deliberately does not own.** The hit test itself belongs
//! to `node_ref/geometry.zig`, the text-run iterators to `text/position_inner.zig`,
//! and the inherited walk this file uses to read a run's direction to
//! `node_ref/properties.zig`. This module holds no state.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const filter = @import("../filter.zig");
const properties = @import("../node_ref/properties.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");

const FilterFn = filter.FilterFn;
const FilterResult = filter.FilterResult;
const FullNodeId = tree_index.FullNodeId;
const NodeRef = @import("../node_id.zig").NodeRef;
const ParentAndIndex = tree_index.ParentAndIndex;
const Point = schema.Point;
const QueryError = tree_state.QueryError;
const TextDirection = schema.TextDirection;

const testing = std.testing;

/// Includes the root node and every `Role.text_run` node, and excludes every
/// other node. Upstream `text_node_filter` at `text.rs:932-938`.
///
/// `context` borrows a `FullNodeId` for this synchronous call. A sibling cursor
/// retains the ID by value and supplies its address anew for each scan.
pub fn textNodeFilter(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    const root_id: *const FullNodeId = @ptrCast(@alignCast(context orelse return .exclude_node));
    const id = node.id();
    if (id.tree_index == root_id.tree_index and id.local.eql(root_id.local)) return .include;
    return textRunFilter(null, node);
}

/// The stateless `FilterFn` for descendant and hit-test walks. Sibling walks
/// instead use `textNodeFilter` with their owned document root ID.
pub const text_run_filter: FilterFn = .{ .context = null, .filter = textRunFilter };

/// Includes a `Role.text_run` node and excludes every other node.
///
/// Unlike `textNodeFilter`, this does not stop an ascending sibling scan at
/// the document root, so it must not be used for text sibling walks.
pub fn textRunFilter(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = context;
    return if (node.data().role == .text_run) .include else .exclude_node;
}

/// The index of the character of `node` that holds `point`, and the character
/// count of the run when the point lies past every character.
///
/// `point` is in the run's own coordinate space. A run whose
/// `character_positions` or `character_widths` is absent, or whose effective
/// `text_direction` is absent, reports `0`, which is upstream's early return at
/// `text.rs:945-961`.
///
/// `null` means the node declares no `bounds`. Upstream unwraps the same read at
/// `text.rs:943`, on the ground that a hit test only offers a node that has
/// one. The port turns that panic into a value, because a malformed tree
/// reaches this function and a caller can act on `null`.
///
/// `error.TreeCycle` means the walk for the inherited text direction reached its
/// bound, and `error.NoSuchNode` means a node on that walk names a parent the
/// state does not hold. Allocates nothing here; the inherited walk allocates
/// its ordering key.
pub fn characterIndexAtPoint(node: NodeRef, point: Point) QueryError!?usize {
    const node_properties = &node.data().properties;
    const rect = schema.option.bounds(node_properties) orelse return null;
    const character_lengths = schema.vectors.characterLengths(node_properties);
    const positions = schema.vectors.characterPositions(node_properties) orelse return 0;
    const widths = schema.vectors.characterWidths(node_properties) orelse return 0;
    const direction = try inheritedTextDirection(node) orelse return 0;

    // The bound is the shorter of the two lists, because upstream zips them at
    // `text.rs:963` and a zip stops at the shorter one.
    const character_pair_count = @min(positions.len, widths.len);
    var index = character_pair_count;
    while (index > 0) {
        index -= 1;
        const character_start: f64 = positions[index];
        const character_end: f64 = @as(f64, positions[index]) + @as(f64, widths[index]);
        const offset = switch (direction) {
            // The two horizontal cases measure from the leading edge and the
            // two vertical ones from the top, because the rectangle is y-down
            // in the node's own coordinate space.
            .left_to_right => point.x - rect.x0,
            .right_to_left => rect.x1 - point.x,
            .top_to_bottom => point.y - rect.y0,
            .bottom_to_top => rect.y1 - point.y,
        };
        // The near edge belongs to the character and the far edge does not, so
        // a point on a shared edge names the character that starts there.
        if (offset >= character_start and offset < character_end) return index;
    }
    return character_lengths.len;
}

/// The direction a node lays its text out in, read from the nearest ancestor
/// that declares one.
pub fn inheritedTextDirection(node: NodeRef) QueryError!?TextDirection {
    return properties.fetchInheritedProperty(TextDirection, node, textDirectionOf);
}

fn textDirectionOf(data: *const schema.Node) ?TextDirection {
    return schema.enums.textDirection(&data.properties);
}

// --- Tests -------------------------------------------------------------------

/// Stores `node` under `value` with `parent` as its parent id, so a test can
/// build a tree without the update algorithm. Inserting moves the map, so a
/// caller must insert every node before taking a handle.
fn insert(
    gpa: std.mem.Allocator,
    state: *tree_state.TreeState,
    value: u64,
    parent: ?u64,
    node: schema.Node,
) !void {
    const id = FullNodeId.init(.{ .value = value }, .init(0));
    const parent_and_index: ?ParentAndIndex = if (parent) |parent_value| blk: {
        const parent_id = FullNodeId.init(.{ .value = parent_value }, .init(0));
        const parent_ref = NodeRef.init(state, parent_id) orelse
            return error.NodeMissingFromFixture;
        const listed = schema.ids_props.children(&parent_ref.data().properties);
        var found: usize = 0;
        for (listed, 0..) |child, position| {
            if (child.eql(.{ .value = value })) {
                found = position;
                break;
            }
        }
        break :blk .{ .parent_id = parent_id, .index = found };
    } else null;
    try state.nodes.put(gpa, id, .{ .parent_and_index = parent_and_index, .data = node });
}

fn handle(state: *const tree_state.TreeState, value: u64) !NodeRef {
    return NodeRef.init(state, FullNodeId.init(.{ .value = value }, .init(0))) orelse
        error.NodeMissingFromFixture;
}

/// A run of four single-byte characters, 10 units apart and 40 units wide.
fn fourCharRun(gpa: std.mem.Allocator) !schema.Node {
    var node = schema.Node.init(gpa, .text_run);
    errdefer node.deinit();
    try schema.strings.setValue(&node.properties, "abcd");
    try schema.vectors.setCharacterLengths(&node.properties, &.{ 1, 1, 1, 1 });
    try schema.vectors.setCharacterPositions(&node.properties, &.{ 0, 10, 20, 30 });
    try schema.vectors.setCharacterWidths(&node.properties, &.{ 10, 10, 10, 10 });
    try schema.option.setBounds(&node.properties, schema.rectInit(0, 0, 40, 20));
    try schema.enums.setTextDirection(&node.properties, .left_to_right);
    return node;
}

test "textRunFilter includes a text run and excludes every other role" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try insert(gpa, &state, 1, null, try fourCharRun(gpa));
    try insert(gpa, &state, 2, null, schema.Node.init(gpa, .button));

    try testing.expectEqual(
        FilterResult.include,
        try text_run_filter.call(try handle(&state, 1)),
    );
    try testing.expectEqual(
        FilterResult.exclude_node,
        try text_run_filter.call(try handle(&state, 2)),
    );
}

test "textNodeFilter adds the root that the stateless filter excludes" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try insert(gpa, &state, 1, null, try fourCharRun(gpa));
    try insert(gpa, &state, 2, null, schema.Node.init(gpa, .text_input));

    // The root is not a text run, so only the root clause includes it. A text
    // run is never a candidate that could be the root, which is why the
    // stateless filter loses nothing for the iterators.
    const root_id = FullNodeId.init(.{ .value = 2 }, .init(0));
    const with_root: FilterFn = .{ .context = @constCast(&root_id), .filter = textNodeFilter };
    try testing.expectEqual(FilterResult.include, try with_root.call(try handle(&state, 2)));
    // The run is not the root, so the run clause alone includes it and the root
    // clause adds nothing for this node.
    try testing.expectEqual(FilterResult.include, try with_root.call(try handle(&state, 1)));
}

test "a point on the shared edge of two characters names the one that starts there" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try insert(gpa, &state, 1, null, try fourCharRun(gpa));
    const run_node = try handle(&state, 1);

    // x = 9 is inside character 0, and x = 10 sits exactly on the edge the
    // first character ends at and the second begins at. A closed far edge would
    // answer 0 there, and the whole point of this test is that it does not.
    try testing.expectEqual(
        @as(?usize, 0),
        try characterIndexAtPoint(run_node, schema.pointInit(9, 10)),
    );
    try testing.expectEqual(
        @as(?usize, 1),
        try characterIndexAtPoint(run_node, schema.pointInit(10, 10)),
    );
    try testing.expectEqual(
        @as(?usize, 1),
        try characterIndexAtPoint(run_node, schema.pointInit(19, 10)),
    );
    try testing.expectEqual(
        @as(?usize, 2),
        try characterIndexAtPoint(run_node, schema.pointInit(20, 10)),
    );
}

test "a point on the far edge of the last character is the character count" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try insert(gpa, &state, 1, null, try fourCharRun(gpa));
    const run_node = try handle(&state, 1);

    try testing.expectEqual(
        @as(?usize, 3),
        try characterIndexAtPoint(run_node, schema.pointInit(39, 10)),
    );
    // x = 40 is the rectangle's own far edge, which no character claims, so the
    // walk falls out and reports the count rather than the last index.
    try testing.expectEqual(
        @as(?usize, 4),
        try characterIndexAtPoint(run_node, schema.pointInit(40, 10)),
    );
}

test "a right-to-left run measures the point from the right edge" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var run_node = try fourCharRun(gpa);
    errdefer run_node.deinit();
    try schema.enums.setTextDirection(&run_node.properties, .right_to_left);
    try insert(gpa, &state, 1, null, run_node);
    const node_ref = try handle(&state, 1);

    // Measured from the right edge, x = 31 is 9 units in and so is inside the
    // first character, and x = 30 is exactly 10 units in, on the edge.
    try testing.expectEqual(
        @as(?usize, 0),
        try characterIndexAtPoint(node_ref, schema.pointInit(31, 10)),
    );
    try testing.expectEqual(
        @as(?usize, 1),
        try characterIndexAtPoint(node_ref, schema.pointInit(30, 10)),
    );
}

test "a run with no bounds reports no character index instead of unwrapping" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "abcd");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1, 1, 1 });
    try schema.enums.setTextDirection(&run_node.properties, .left_to_right);
    try insert(gpa, &state, 1, null, run_node);

    try testing.expectEqual(
        @as(?usize, null),
        try characterIndexAtPoint(try handle(&state, 1), schema.pointInit(1, 1)),
    );
}

test "a run with no text direction reports character zero" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1, 1, 1 });
    try schema.vectors.setCharacterPositions(&run_node.properties, &.{ 0, 10, 20, 30 });
    try schema.vectors.setCharacterWidths(&run_node.properties, &.{ 10, 10, 10, 10 });
    try schema.option.setBounds(&run_node.properties, schema.rectInit(0, 0, 40, 20));
    try insert(gpa, &state, 1, null, run_node);

    // No declared direction and no ancestor declares one, so upstream returns 0
    // at `text.rs:957-961` and the port returns the same value.
    try testing.expectEqual(
        @as(?usize, 0),
        try characterIndexAtPoint(try handle(&state, 1), schema.pointInit(25, 10)),
    );
}

test "a direction on the parent reaches the run that declares none" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.enums.setTextDirection(&document.properties, .right_to_left);
    try insert(gpa, &state, 0, null, document);

    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1, 1, 1 });
    try schema.vectors.setCharacterPositions(&run_node.properties, &.{ 0, 10, 20, 30 });
    try schema.vectors.setCharacterWidths(&run_node.properties, &.{ 10, 10, 10, 10 });
    try schema.option.setBounds(&run_node.properties, schema.rectInit(0, 0, 40, 20));
    try insert(gpa, &state, 1, 0, run_node);

    // The run declares no direction, so the inherited walk answers from the
    // document one step up and the run is measured from its right edge.
    try testing.expectEqual(
        @as(?usize, 0),
        try characterIndexAtPoint(try handle(&state, 1), schema.pointInit(31, 10)),
    );
}
