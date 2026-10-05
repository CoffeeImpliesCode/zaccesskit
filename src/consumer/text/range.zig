//! `Range`, `WeakRange` and the folds over the runs a range covers.
//!
//! Upstream `accesskit_consumer/src/text.rs:595-931`. Upstream holds all of it
//! in one `impl` block; the port splits it because the three types involved
//! live in three modules. `Range` and `WeakRange` are declared here,
//! `Position` is `text/position.zig`'s, and `InnerPosition` is
//! `text/position_inner.zig`'s.
//!
//! **Every operation is a free function whose first parameter is the range.**
//! A Zig method is declared only inside the body of the struct it belongs to,
//! so an operation on `Range` written in another file is not callable at all.
//! This file owns the body and could carry the methods, but the rest of the
//! layer is written against free functions, so it does.
//!
//! **`WeakRange` is split across two modules.** `upgradeNode` and `upgrade`
//! need `supportsTextRanges`, which is `text/query.zig`'s, and this file may
//! not import `text/query.zig` because `text/query.zig` needs `Range`. Those
//! two are free functions over the type declared here, and they live in
//! `text/query.zig`.
//!
//! **Two layer rules, said once because this file has the most parameters and
//! the most allocating entry points of the four.** An allocating free function
//! takes `gpa` first, per `AGENTS.md:99`; an allocating method takes the
//! receiver first, because Zig builds the call syntax only in that order. A
//! parameter may not shadow a file-scope or type-level declaration, because
//! Zig 0.16.0 rejects it and the rejection reads like a mistake in the wrong
//! file: `node`, `start`, `end`, `text` and `position` are all taken here, so
//! the parameters that meet them are named `node_ref`, `start_position`,
//! `end_position`, `text_bytes` and `position_value`.
//!
//! **`toDegenerateRange` moved here.** Upstream declares it on `Position`, and
//! this file owns it because it returns a `Range`. `text/position.zig` needs
//! `Range` for the text-selection and movement accessors, so a `Range`-returning
//! function over a `Position` declared there would close a cycle between two
//! modules that have to stay separable. The consequence is that
//! `text/position.zig` can spell a degenerate range only as its three fields.
//!
//! **What this module deliberately does not own.** The text-run iterators and
//! the transform walk belong to `text/query.zig` and `node_ref/geometry.zig`,
//! and the walk that gives a position its ordering key belongs to
//! `text/position_inner.zig`. The run walk below is bounded by
//! `node_ref/hierarchy.zig`, which bounds its own sibling scan.

const std = @import("std");
const schema = @import("../../schema/root.zig");
const affine = @import("../../schema/geometry/affine.zig");

const geometry = @import("../node_ref/geometry.zig");
const hierarchy = @import("../node_ref/hierarchy.zig");
const properties = @import("../node_ref/properties.zig");
const hit_test = @import("hit_test.zig");
const position = @import("position.zig");
const position_inner = @import("position_inner.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");

const ComparablePath = position_inner.ComparablePath;
const FullNodeId = tree_index.FullNodeId;
const InnerPosition = position_inner.InnerPosition;
const ParentAndIndex = tree_index.ParentAndIndex;
const node_ids = @import("../node_id.zig");
const NodeRef = node_ids.NodeRef;
const Position = position.Position;
const QueryError = tree_state.QueryError;
const TextDirection = schema.TextDirection;
const TextPosition = schema.TextPosition;
const TextSelection = schema.TextSelection;

const testing = std.testing;

/// One property across a range: the value every run agrees on, or `mixed`.
///
/// `single` is `null` when no run declares the property, which is a different
/// answer from `mixed`. It holds no memory.
pub fn RangePropertyValue(comptime T: type) type {
    return union(enum) {
        single: ?T,
        mixed,
    };
}

/// One text range: a node it is measured against and two positions inside it.
///
/// **A range is two positions, and each position borrows a node of its own.**
/// `start` and `end` are `InnerPosition` values, and each holds a `NodeRef`
/// naming the text run that position sits in. A range over two runs holds two
/// different nodes, and after a graft those two runs can sit in two different
/// trees. `node` names a third node, the one the range is measured against.
/// Nothing in this type says the three are related, so a caller must not read
/// `range.start.node.id()` as if it were `range.node.id()`.
///
/// **What invalidates each borrow.** All three `NodeRef` values borrow one
/// `NodeState` each out of a `TreeState`, and every one of them ends at the
/// same event: the next call that can grow `TreeState.nodes`, because growing
/// the map moves its entries and every pointer into it dangles. Rebuild every
/// `Range` after an update. No position carries an extra obligation, so there
/// is nothing a caller could check per position instead.
///
/// Copying a `Range` copies three handles and no nodes, so a copy is not a
/// second owner and needs no release.
pub const Range = struct {
    /// The node the range is measured against. Borrows one `NodeState`, and
    /// neither `start` nor `end` has to sit inside it.
    node: NodeRef,
    /// The first position of the range, in the text `node` measures.
    start: InnerPosition,
    /// Where the range ends, past the last character it names.
    end: InnerPosition,
};

/// A range that outlives the tree it was taken from.
///
/// It keeps the node id, the two weak positions and the two ordering keys, so a
/// caller can still sort a stale range without the tree. It owns the two
/// `ComparablePath` lists, and `deinit` releases both.
pub const WeakRange = struct {
    node_id: FullNodeId,
    start: TextPosition,
    end: TextPosition,
    start_comparable: ComparablePath,
    end_comparable: ComparablePath,

    /// Releases both ordering keys. The weak positions and the node id are
    /// values, so nothing else is freed, and a second call is a double free.
    pub fn deinit(self: *WeakRange) void {
        self.start_comparable.deinit();
        self.end_comparable.deinit();
        // SAFETY: both keys above were released, which is everything the value
        // owned, and no statement after them reads `self`.
        self.* = undefined;
    }

    /// The node the range was measured against, as an id rather than a handle.
    pub fn nodeId(self: WeakRange) FullNodeId {
        return self.node_id;
    }

    /// The precomputed ordering key of the start position. It holds the
    /// allocator it was built with, so a caller that keeps it must keep that
    /// allocator alive.
    pub fn startComparable(self: WeakRange) ComparablePath {
        return self.start_comparable;
    }

    /// The precomputed ordering key of the end position. It holds the
    /// allocator it was built with, so a caller that keeps it must keep that
    /// allocator alive.
    pub fn endComparable(self: WeakRange) ComparablePath {
        return self.end_comparable;
    }
};

/// A range from `start` to `end` inside `node`, with the two ends in order.
///
/// `end` moves in front of `start` when the ordering key of `start` is greater,
/// which is what upstream `Range::new` does at `text.rs:620-625`.
///
/// Allocates two ordering keys and releases both. On `error.OutOfMemory`
/// nothing is allocated and the caller keeps both positions.
pub fn init(
    gpa: std.mem.Allocator,
    node_ref: NodeRef,
    start_position: InnerPosition,
    end_position: InnerPosition,
) QueryError!Range {
    var start_key = try position_inner.comparable(gpa, start_position, node_ref);
    defer start_key.deinit();
    var end_key = try position_inner.comparable(gpa, end_position, node_ref);
    defer end_key.deinit();
    return if (start_key.order(end_key) == .gt)
        .{ .node = node_ref, .start = end_position, .end = start_position }
    else
        .{ .node = node_ref, .start = start_position, .end = end_position };
}

/// The degenerate range at `position_value`: both ends are that position, so
/// the range names no characters.
///
/// Upstream `Position::to_degenerate_range` at `text.rs:237-239`, which builds
/// the same value through `Range::new`. `gpa` is a parameter because the port's
/// `init` builds both ordering keys and compares them to order the two ends,
/// where upstream's `Range::new` compared two borrowed keys it then dropped.
pub fn toDegenerateRange(
    gpa: std.mem.Allocator,
    position_value: Position,
) QueryError!Range {
    return init(gpa, position_value.root_node, position_value.inner, position_value.inner);
}

/// The node the range is measured against. Reading `range.node` says the same
/// thing without a call.
pub fn node(range: Range) NodeRef {
    return range.node;
}

/// The start position, lifted into the document the range belongs to.
pub fn start(range: Range) Position {
    return .{ .root_node = range.node, .inner = range.start };
}

/// The end position, lifted into the document the range belongs to.
pub fn end(range: Range) Position {
    return .{ .root_node = range.node, .inner = range.end };
}

/// Whether both ends name the same offset, so the range names no characters.
///
/// Allocates two ordering keys and releases both.
pub fn isDegenerate(gpa: std.mem.Allocator, range: Range) QueryError!bool {
    var start_key = try position_inner.comparable(gpa, range.start, range.node);
    defer start_key.deinit();
    var end_key = try position_inner.comparable(gpa, range.end, range.node);
    defer end_key.deinit();
    return start_key.order(end_key) == .eq;
}

/// Visits every text run the range covers, in document order, and returns
/// `true` when the walk reached the end of the range.
///
/// `visit` returns `false` to stop the walk, which is how upstream's
/// `Option<T>` says "this is the result". A degenerate range is not
/// normalized, so a caret at the end of a wrapped line reports the line it sits
/// on rather than the next one. This is `Range::walk` at `text.rs:649-678`.
///
/// The run loop is bounded by `node_ref/hierarchy.zig`, which bounds its own
/// sibling scan with `treeWalkStepBound`.
///
/// **The sibling filter is the plain text-run filter.** Upstream builds its
/// filter at `text.rs:1391` out of the id of the range's own node, so that the
/// root is one of the nodes the filter includes. The port does not need that
/// clause here, and passing it would be wrong: the filter answers "may this
/// node be a run in the walk", and the document node is not one, so a scan that
/// climbed out of the last run would hand the walk the document itself. The
/// far end of a sibling cursor comes from the tree and not from the filter,
/// which is `iterators/following.zig`'s rule.
///
/// `visit` runs on the calling thread before this call returns and must not
/// modify the tree, because the borrow every `NodeRef` in the range rests on
/// ends there. `context` reaches it unchanged and must outlive the call.
pub fn walk(
    gpa: std.mem.Allocator,
    range: Range,
    context: ?*anyopaque,
    visit: *const fn (context: ?*anyopaque, node_ref: NodeRef) bool,
) QueryError!bool {
    var start_position = range.start;
    var end_position = range.end;
    if (!try isDegenerate(gpa, range)) {
        start_position = try position_inner.biasedToStart(start_position, range.node);
        end_position = try position_inner.biasedToEnd(end_position, range.node);
    }
    if (!visit(context, start_position.node)) return false;
    if (sameNode(start_position.node, end_position.node)) return true;
    var runs = try hierarchy.followingFilteredSiblings(
        start_position.node,
        hit_test.text_run_filter,
    );
    while (try runs.next()) |run| {
        if (!visit(context, run)) return false;
        if (sameNode(run, end_position.node)) break;
    }
    return true;
}

/// Visits every text run the range covers with the text that run contributes,
/// and returns `true` when the walk reached the end of the range.
///
/// `visit` returns `false` to stop the walk. A run that declares no `value`
/// contributes an empty slice rather than ending the walk, because upstream
/// unwraps the same read at `text.rs:696` and a run with no text is malformed
/// rather than empty. This is `Range::traverse_text` at `text.rs:680-717`.
pub fn traverseText(
    gpa: std.mem.Allocator,
    range: Range,
    context: ?*anyopaque,
    visit: *const fn (context: ?*anyopaque, node_ref: NodeRef, text_bytes: []const u8) bool,
) QueryError!bool {
    var slice_visitor: SliceVisitor = .{ .range = range, .context = context, .visit = visit };
    return walk(gpa, range, @ptrCast(&slice_visitor), SliceVisitor.onNode);
}

/// Writes the text of `range` to `writer`, in run order.
///
/// The writer is a sink the caller owns, so this function reaches no I/O
/// backend. On an error the writer holds the bytes written before the walk
/// stopped, and the caller cannot tell from the tag alone how many those are.
pub fn writeText(
    gpa: std.mem.Allocator,
    range: Range,
    writer: *std.Io.Writer,
) (QueryError || std.Io.Writer.Error)!void {
    var sink: WriteVisitor = .{ .writer = writer, .failed = false };
    _ = try traverseText(gpa, range, @ptrCast(&sink), WriteVisitor.onNode);
    if (sink.failed) return error.WriteFailed;
}

/// The text of `range`, which the caller owns and releases with `gpa`.
///
/// On `error.OutOfMemory` the list holds a prefix of the range and is already
/// released, so there is nothing for the caller to free.
pub fn text(gpa: std.mem.Allocator, range: Range) QueryError!std.ArrayList(u8) {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var sink: AppendVisitor = .{ .gpa = gpa, .out = &out, .failed = false };
    _ = try traverseText(gpa, range, @ptrCast(&sink), AppendVisitor.onNode);
    if (sink.failed) return error.OutOfMemory;
    return out;
}

/// One rectangle per text run the range covers, in the tree's container space.
///
/// An empty list means the source tree does not carry enough geometry, which is
/// upstream's early return at `text.rs:742-766`: the first run without `bounds`,
/// without `character_positions`, without `character_widths` or without an
/// effective `text_direction` ends the walk with nothing. Otherwise there is at
/// least one rectangle, and a degenerate range still has one, zero width
/// included.
///
/// The caller owns the list. `error.TreeCycle` means the inherited-direction
/// walk or the transform walk reached its bound, and `error.OutOfMemory` means
/// a list could not grow; on either one the list is already released.
pub fn boundingBoxes(
    gpa: std.mem.Allocator,
    range: Range,
) QueryError!std.ArrayList(schema.Rect) {
    var out: std.ArrayList(schema.Rect) = .empty;
    errdefer out.deinit(gpa);
    var folder: BoxFolder = .{
        .gpa = gpa,
        .range = range,
        .out = &out,
        .failure = null,
    };
    _ = try walk(gpa, range, @ptrCast(&folder), BoxFolder.onNode);
    if (folder.failure) |failure| return failure;
    return out;
}

/// The value of one property across the range, or `mixed` when the runs
/// disagree.
///
/// `getter` reads the property from one node. It runs once per covered run and
/// may report `error.TreeCycle`; the first error stops the walk, is returned,
/// and leaves every earlier value the getter produced dropped.
/// The walk stops at the first run whose value differs, because the answer is
/// `mixed` from that run on and a later run cannot take it back.
///
/// Upstream `Range::fetch_property` at `text.rs:823-840`. Upstream unwraps the
/// folded value at the end of that function, and the port asserts it instead,
/// because the walk always visits at least one run.
pub fn fetchProperty(
    comptime T: type,
    gpa: std.mem.Allocator,
    range: Range,
    getter: *const fn (NodeRef) QueryError!?T,
) QueryError!RangePropertyValue(T) {
    var folder: FoldFolder(T) = .{
        .getter = getter,
        .value = null,
        .mixed = false,
        .failure = null,
        .visited = false,
    };
    _ = try walk(gpa, range, @ptrCast(&folder), FoldFolder(T).onNode);
    if (folder.failure) |failure| return failure;
    // The walk visits the start run before anything else, so a fold with no
    // visit has no answer at all. That path does not exist, and the assertion
    // says so rather than inventing one.
    std.debug.assert(folder.visited);
    // Upstream stops at the first run that disagrees and answers `Mixed`
    // without reading a run again, so the fold does the same.
    if (folder.mixed) return .mixed;
    return .{ .single = folder.value };
}

/// Moves the start of `range` to `pos`.
///
/// `pos` must belong to the same node as the range, and `error.InvalidPosition`
/// says it does not. Upstream asserts the same condition at `text.rs:849`. A
/// start that reaches or passes the end moves the end onto it, so the two ends
/// never invert, and a non-degenerate range then biases the start onto the run
/// that owns it.
pub fn setStart(
    gpa: std.mem.Allocator,
    range: *Range,
    pos: Position,
) QueryError!void {
    if (!sameNode(pos.root_node, range.node)) return error.InvalidPosition;
    range.start = pos.inner;
    var start_key = try position_inner.comparable(gpa, range.start, range.node);
    defer start_key.deinit();
    var end_key = try position_inner.comparable(gpa, range.end, range.node);
    defer end_key.deinit();
    if (start_key.order(end_key) != .lt) range.end = range.start;
    try fixStartBias(gpa, range);
}

/// Moves the end of `range` to `pos`.
///
/// `pos` must belong to the same node as the range, and `error.InvalidPosition`
/// says it does not. Upstream asserts the same condition at `text.rs:860`. An
/// end that reaches or passes the start moves the start onto it, so the two
/// ends never invert, and a non-degenerate range then biases the start onto the
/// run that owns it.
pub fn setEnd(
    gpa: std.mem.Allocator,
    range: *Range,
    pos: Position,
) QueryError!void {
    if (!sameNode(pos.root_node, range.node)) return error.InvalidPosition;
    range.end = pos.inner;
    var start_key = try position_inner.comparable(gpa, range.start, range.node);
    defer start_key.deinit();
    var end_key = try position_inner.comparable(gpa, range.end, range.node);
    defer end_key.deinit();
    if (start_key.order(end_key) != .lt) range.start = range.end;
    try fixStartBias(gpa, range);
}

/// The range as the core `TextSelection`, which holds weak positions and so
/// borrows nothing.
pub fn toTextSelection(range: Range) TextSelection {
    return .{
        .anchor = position_inner.downgrade(range.start),
        .focus = position_inner.downgrade(range.end),
    };
}

/// The range without its borrows, keeping the two ordering keys so a caller can
/// sort it after the tree is gone.
///
/// The result owns both ordering keys, so the caller releases it with
/// `WeakRange.deinit`. On `error.OutOfMemory` nothing is allocated.
pub fn downgrade(gpa: std.mem.Allocator, range: Range) QueryError!WeakRange {
    var start_key = try position_inner.comparable(gpa, range.start, range.node);
    errdefer start_key.deinit();
    const end_key = try position_inner.comparable(gpa, range.end, range.node);
    return .{
        .node_id = range.node.id(),
        .start = position_inner.downgrade(range.start),
        .end = position_inner.downgrade(range.end),
        .start_comparable = start_key,
        .end_comparable = end_key,
    };
}

/// Whether two ranges name the same node and the same two offsets.
pub fn eql(a: Range, b: Range) bool {
    if (!sameNode(a.node, b.node)) return false;
    if (!sameNode(a.start.node, b.start.node)) return false;
    if (!sameNode(a.end.node, b.end.node)) return false;
    return a.start.character_index == b.start.character_index and
        a.end.character_index == b.end.character_index;
}

// --- Shared helpers ----------------------------------------------------------

/// The text direction a node lays its text out in, read from the nearest
/// ancestor that declares one.
pub fn inheritedTextDirection(node_ref: NodeRef) QueryError!?TextDirection {
    return properties.fetchInheritedProperty(TextDirection, node_ref, textDirectionOf);
}

fn textDirectionOf(node_ref: *const schema.Node) ?TextDirection {
    return schema.enums.textDirection(&node_ref.properties);
}

fn sameNode(a: NodeRef, b: NodeRef) bool {
    const a_id = a.id();
    const b_id = b.id();
    return a_id.tree_index == b_id.tree_index and a_id.local.eql(b_id.local);
}

fn fixStartBias(gpa: std.mem.Allocator, range: *Range) QueryError!void {
    if (!try isDegenerate(gpa, range.*)) {
        range.start = try position_inner.biasedToStart(range.start, range.node);
    }
}

const SliceVisitor = struct {
    range: Range,
    context: ?*anyopaque,
    visit: *const fn (context: ?*anyopaque, node_ref: NodeRef, text_bytes: []const u8) bool,

    fn onNode(context: ?*anyopaque, node_ref: NodeRef) bool {
        const self: *SliceVisitor = @ptrCast(@alignCast(context.?));
        return self.visit(self.context, node_ref, sliceFor(self.range, node_ref));
    }
};

/// The part of `node`'s text that `range` covers.
fn sliceFor(range: Range, node_ref: NodeRef) []const u8 {
    const properties_of_node = &node_ref.data().properties;
    const value = schema.strings.value(properties_of_node) orelse return "";
    const lengths = schema.vectors.characterLengths(properties_of_node);
    // An index past the end of the run is clamped. Upstream indexes the slice
    // directly at `text.rs:702` and `text.rs:708`, so a position past the end
    // of a run that declares fewer lengths would panic there.
    const start_index = @min(runStartIndex(range, node_ref), lengths.len);
    const end_index = @min(runEndIndex(range, node_ref), lengths.len);
    if (start_index == end_index) return "";
    if (start_index == 0 and end_index == lengths.len) return value;
    const slice_start = byteOffset(lengths[0..start_index]);
    const slice_end = slice_start + byteOffset(lengths[start_index..end_index]);
    return value[slice_start..slice_end];
}

fn runStartIndex(range: Range, node_ref: NodeRef) usize {
    return if (sameNode(node_ref, range.start.node)) range.start.character_index else 0;
}

fn runEndIndex(range: Range, node_ref: NodeRef) usize {
    return if (sameNode(node_ref, range.end.node))
        range.end.character_index
    else
        schema.vectors.characterLengths(&node_ref.data().properties).len;
}

fn byteOffset(lengths: []const u8) usize {
    var total: usize = 0;
    for (lengths) |length| total += length;
    return total;
}

const WriteVisitor = struct {
    writer: *std.Io.Writer,
    failed: bool,

    fn onNode(context: ?*anyopaque, node_ref: NodeRef, text_bytes: []const u8) bool {
        _ = node_ref;
        const self: *WriteVisitor = @ptrCast(@alignCast(context.?));
        self.writer.writeAll(text_bytes) catch {
            self.failed = true;
            return false;
        };
        return true;
    }
};

const AppendVisitor = struct {
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    failed: bool,

    fn onNode(context: ?*anyopaque, node_ref: NodeRef, text_bytes: []const u8) bool {
        _ = node_ref;
        const self: *AppendVisitor = @ptrCast(@alignCast(context.?));
        self.out.appendSlice(self.gpa, text_bytes) catch {
            self.failed = true;
            return false;
        };
        return true;
    }
};

const BoxFolder = struct {
    gpa: std.mem.Allocator,
    range: Range,
    out: *std.ArrayList(schema.Rect),
    failure: ?QueryError,

    fn onNode(context: ?*anyopaque, node_ref: NodeRef) bool {
        const self: *BoxFolder = @ptrCast(@alignCast(context.?));
        const wanted_start = runStartIndex(self.range, node_ref);
        const wanted_end = runEndIndex(self.range, node_ref);
        const box = foldBox(node_ref, wanted_start, wanted_end) catch |err| {
            self.failure = err;
            return false;
        } orelse return false;
        const transform = geometry.transform(node_ref) catch |err| {
            self.failure = err;
            return false;
        };
        self.out.append(self.gpa, affine.transformRectBbox(transform, box)) catch |err| {
            self.failure = err;
            return false;
        };
        return true;
    }
};

/// The part of `node`'s box that the range covers, or `null` when the node does
/// not carry the per-character geometry upstream needs.
fn foldBox(node_ref: NodeRef, wanted_start: usize, wanted_end: usize) QueryError!?schema.Rect {
    const node_properties = &node_ref.data().properties;
    var rect = schema.option.bounds(node_properties) orelse return null;
    const positions = schema.vectors.characterPositions(node_properties) orelse return null;
    const widths = schema.vectors.characterWidths(node_properties) orelse return null;
    const direction = try inheritedTextDirection(node_ref) orelse return null;
    const lengths = schema.vectors.characterLengths(node_properties);
    // Upstream indexes `positions` and `widths` at `text.rs:780` and
    // `text.rs:787` without checking either list against the character index,
    // so the port clamps the two indices to the shortest of the three lists and
    // reports no box when that is empty.
    const character_count = @min(@min(lengths.len, positions.len), widths.len);
    const start_index = @min(wanted_start, character_count);
    const end_index = @min(wanted_end, character_count);
    if (start_index == 0 and end_index == lengths.len) return rect;
    if (character_count == 0) return null;

    // A start at the end of the run has no position of its own, so it takes the
    // far edge of the last character, which is what upstream does at
    // `text.rs:779-783`.
    const pixel_start: f64 = if (start_index < character_count)
        @as(f64, positions[start_index])
    else
        @as(f64, positions[start_index - 1] + widths[start_index - 1]);
    const pixel_end: f64 = if (end_index == start_index)
        pixel_start
    else
        @as(f64, positions[end_index - 1] + widths[end_index - 1]);

    // The two vertical cases treat the rectangle as y-down in the node's own
    // coordinate space, which is the assumption upstream states at
    // `text.rs:802-804`.
    switch (direction) {
        .left_to_right => {
            const origin = rect.x0;
            rect.x0 = origin + pixel_start;
            rect.x1 = origin + pixel_end;
        },
        .right_to_left => {
            const origin = rect.x1;
            rect.x1 = origin - pixel_start;
            rect.x0 = origin - pixel_end;
        },
        .top_to_bottom => {
            const origin = rect.y0;
            rect.y0 = origin + pixel_start;
            rect.y1 = origin + pixel_end;
        },
        .bottom_to_top => {
            const origin = rect.y1;
            rect.y1 = origin - pixel_start;
            rect.y0 = origin - pixel_end;
        },
    }
    return rect;
}

fn FoldFolder(comptime T: type) type {
    return struct {
        const Self = @This();

        getter: *const fn (NodeRef) QueryError!?T,
        value: ?T,
        /// Set by the first run whose value differs from the value the earlier
        /// runs agreed on, which is upstream's early `Some(Mixed)` return at
        /// `text.rs:831-833`. It ends the walk, because no later run can take
        /// the answer back.
        mixed: bool,
        failure: ?QueryError,
        /// Set by the first visit. It answers "did the walk reach a run at all",
        /// for the caller's assertion, and it is also what distinguishes the
        /// first run from a later one — see `onNode`.
        visited: bool,

        fn onNode(context: ?*anyopaque, node_ref: NodeRef) bool {
            const self: *Self = @ptrCast(@alignCast(context.?));

            // Whether a *previous* run contributed a value. Read the flag before
            // setting it, because the flag also answers "did the walk visit
            // anything" and a getter failure on the first run must still count
            // as a visit.
            const first = !self.visited;
            self.visited = true;

            const current = self.getter(node_ref) catch |err| {
                self.failure = err;
                return false;
            };

            if (first) {
                self.value = current;
                return true;
            }

            // Upstream holds an `Option<Option<T>>` at `text.rs:825-834` and
            // compares the whole of it, so a run that declares nothing against a
            // run that declares a value is a disagreement and the answer is
            // `mixed`.
            //
            // Branching on `self.value` being null instead reads the first run's
            // absent value as "no value seen yet" and adopts the second run's
            // value as the answer. A document whose first run declares nothing
            // and whose second declares "Save" then folds to `single("Save")`
            // where upstream folds to `mixed`. That is why the test is on
            // `visited` and not on `value`.
            if (!eqlInherited(T, self.value, current)) {
                self.mixed = true;
                return false;
            }
            return true;
        }
    };
}

/// Compares two inherited values the way upstream's `PartialEq` does, so a
/// borrowed string compares by content and not by slice header.
pub fn eqlInherited(comptime T: type, a: ?T, b: ?T) bool {
    if (a == null or b == null) return a == null and b == null;
    return switch (@typeInfo(T)) {
        .pointer => std.mem.eql(u8, a.?, b.?),
        else => std.meta.eql(a.?, b.?),
    };
}

// --- Tests -------------------------------------------------------------------

/// Stores `node` under `value` in the root tree, so a test can build a tree
/// without the update algorithm. Inserting moves the map, so a caller must
/// insert every node before taking a handle.
fn insert(
    gpa: std.mem.Allocator,
    state: *tree_state.TreeState,
    value: u64,
    parent: ?u64,
    node_ref: schema.Node,
) !void {
    const id = FullNodeId.init(.{ .value = value }, .init(0));
    const parent_and_index: ?ParentAndIndex = if (parent) |parent_value| blk: {
        const parent_id = FullNodeId.init(.{ .value = parent_value }, .init(0));
        const parent_ref = NodeRef.init(state, parent_id).?;
        const listed = schema.ids_props.children(&parent_ref.data().properties);
        var found: usize = 0;
        for (listed, 0..) |child, child_slot| {
            if (child.eql(.{ .value = value })) {
                found = child_slot;
                break;
            }
        }
        break :blk .{ .parent_id = parent_id, .index = found };
    } else null;
    try state.nodes.put(gpa, id, .{
        .parent_and_index = parent_and_index,
        .data = node_ref,
    });
}

fn handle(state: *const tree_state.TreeState, value: u64) NodeRef {
    return NodeRef.init(state, FullNodeId.init(.{ .value = value }, .init(0))).?;
}

fn textRun(gpa: std.mem.Allocator, text_value: []const u8) !schema.Node {
    var node_ref = schema.Node.init(gpa, .text_run);
    errdefer node_ref.deinit();
    try schema.strings.setValue(&node_ref.properties, text_value);
    const lengths = try gpa.alloc(u8, text_value.len);
    defer gpa.free(lengths);
    @memset(lengths, 1);
    try schema.vectors.setCharacterLengths(&node_ref.properties, lengths);
    return node_ref;
}

/// A `TextInput` over two runs holding `hello` and `world`.
fn twoRunDocument(gpa: std.mem.Allocator, state: *tree_state.TreeState) !void {
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{
        .{ .value = 1 },
        .{ .value = 2 },
    });
    try insert(gpa, state, 0, null, document);
    try insert(gpa, state, 1, 0, try textRun(gpa, "hello"));
    try insert(gpa, state, 2, 0, try textRun(gpa, "world"));
}

/// A `TextInput` over three runs holding `one`, `two` and `three`, so a test
/// can tell a walk that steps to the next run from a walk that stops at the
/// first one.
fn threeRunDocument(gpa: std.mem.Allocator, state: *tree_state.TreeState) !void {
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{
        .{ .value = 1 },
        .{ .value = 2 },
        .{ .value = 3 },
    });
    try insert(gpa, state, 0, null, document);
    try insert(gpa, state, 1, 0, try textRun(gpa, "one"));
    try insert(gpa, state, 2, 0, try textRun(gpa, "two"));
    try insert(gpa, state, 3, 0, try textRun(gpa, "three"));
}

/// The same two runs under a window, so a walk that climbs out of the last run
/// meets a node that is not a text run and must not report it.
fn nestedRunDocument(gpa: std.mem.Allocator, state: *tree_state.TreeState) !void {
    var window = schema.Node.init(gpa, .window);
    errdefer window.deinit();
    try schema.ids_props.setChildren(&window.properties, &.{.{ .value = 0 }});
    try insert(gpa, state, 9, null, window);
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{
        .{ .value = 1 },
        .{ .value = 2 },
    });
    try insert(gpa, state, 0, 9, document);
    try insert(gpa, state, 1, 0, try textRun(gpa, "hello"));
    try insert(gpa, state, 2, 0, try textRun(gpa, "world"));
}

fn rangeOver(
    gpa: std.mem.Allocator,
    state: *const tree_state.TreeState,
    first: usize,
    last: usize,
) !Range {
    return init(
        gpa,
        handle(state, 0),
        .{ .node = handle(state, 1), .character_index = first },
        .{ .node = handle(state, 2), .character_index = last },
    );
}

fn constantFamily(node_ref: NodeRef) QueryError!?[]const u8 {
    _ = node_ref;
    return "same";
}

fn alternatingFamily(node_ref: NodeRef) QueryError!?[]const u8 {
    const value = schema.strings.value(&node_ref.data().properties) orelse return null;
    return if (value[0] == 'h') "first" else "second";
}

test "a range whose ends are the wrong way round is stored in order" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    const reversed = try init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 2), .character_index = 3 },
        .{ .node = handle(&state, 1), .character_index = 1 },
    );
    // The end moves in front of the start, so the range covers run 1 from index
    // 1 through run 2 at index 3.
    try testing.expect(sameNode(reversed.start.node, handle(&state, 1)));
    try testing.expectEqual(@as(usize, 1), reversed.start.character_index);
    try testing.expect(sameNode(reversed.end.node, handle(&state, 2)));
    try testing.expectEqual(@as(usize, 3), reversed.end.character_index);
}

test "a degenerate range is one whose two ends name the same offset" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    // Both ends are the same offset in the same run, which is the only shape
    // upstream's `==` on the two comparable keys calls degenerate.
    const caret = try init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 2 },
        .{ .node = handle(&state, 1), .character_index = 2 },
    );
    try testing.expect(try isDegenerate(gpa, caret));
    try testing.expect(!try isDegenerate(gpa, try rangeOver(gpa, &state, 0, 5)));
}

test "toDegenerateRange puts the position at both ends" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    const caret = try toDegenerateRange(gpa, .{
        .root_node = handle(&state, 0),
        .inner = .{ .node = handle(&state, 2), .character_index = 4 },
    });
    // A range measured against the same node with the same offset at both ends
    // is degenerate, and it names the document the position came from.
    try testing.expect(try isDegenerate(gpa, caret));
    try testing.expect(sameNode(caret.node, handle(&state, 0)));
    try testing.expect(sameNode(caret.start.node, handle(&state, 2)));
    try testing.expect(sameNode(caret.end.node, handle(&state, 2)));
    try testing.expectEqual(@as(usize, 4), caret.start.character_index);
    try testing.expectEqual(@as(usize, 4), caret.end.character_index);
}

/// Records the local id of every node the walk visits, so a test can pin the
/// shape of the walk and not only one value derived from it.
const TracingVisitor = struct {
    gpa: std.mem.Allocator,
    visited: std.ArrayList(u64) = .empty,

    fn onNode(context: ?*anyopaque, node_ref: NodeRef) bool {
        const self: *TracingVisitor = @ptrCast(@alignCast(context.?));
        self.visited.append(self.gpa, node_ref.id().local.value) catch return false;
        return true;
    }
};

test "the walk visits every run the range covers, in document order" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try threeRunDocument(gpa, &state);

    var tracer: TracingVisitor = .{ .gpa = gpa };
    defer tracer.visited.deinit(gpa);
    // The range starts inside the first run and ends inside the third. A walk
    // that reports the run it starts in and no other answers one id here, and
    // every fold and every join built on it answers the first run's value.
    _ = try walk(
        gpa,
        try init(
            gpa,
            handle(&state, 0),
            .{ .node = handle(&state, 1), .character_index = 1 },
            .{ .node = handle(&state, 3), .character_index = 2 },
        ),
        @ptrCast(&tracer),
        TracingVisitor.onNode,
    );
    try testing.expectEqualSlices(u64, &.{ 1, 2, 3 }, tracer.visited.items);
}

test "a range inside one run does not reach the runs after it" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try threeRunDocument(gpa, &state);

    var tracer: TracingVisitor = .{ .gpa = gpa };
    defer tracer.visited.deinit(gpa);
    // Both ends sit in the middle run, so `walk` answers before it builds the
    // sibling cursor at all.
    _ = try walk(
        gpa,
        try init(
            gpa,
            handle(&state, 0),
            .{ .node = handle(&state, 2), .character_index = 1 },
            .{ .node = handle(&state, 2), .character_index = 3 },
        ),
        @ptrCast(&tracer),
        TracingVisitor.onNode,
    );
    try testing.expectEqualSlices(u64, &.{2}, tracer.visited.items);
}

test "the walk does not leave the document for the node above it" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try nestedRunDocument(gpa, &state);

    var tracer: TracingVisitor = .{ .gpa = gpa };
    defer tracer.visited.deinit(gpa);
    // Stepping past the last run climbs to the document and then to the
    // window. Neither is a text run, and a walk that offered either of them
    // would report a run that holds no text at all.
    _ = try walk(
        gpa,
        try init(
            gpa,
            handle(&state, 0),
            .{ .node = handle(&state, 1), .character_index = 0 },
            .{ .node = handle(&state, 2), .character_index = 5 },
        ),
        @ptrCast(&tracer),
        TracingVisitor.onNode,
    );
    try testing.expectEqualSlices(u64, &.{ 1, 2 }, tracer.visited.items);
}

test "the text of a range joins the runs it covers and drops the rest" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    var whole = try text(gpa, try rangeOver(gpa, &state, 0, 5));
    defer whole.deinit(gpa);
    try testing.expectEqualStrings("helloworld", whole.items);

    // A start inside the first run and an end inside the second keep the tail
    // of the first run. Upstream reads the start index only from the start run
    // and the end index only from the end run at `text.rs:686-695`, so every
    // other run contributes all of itself and each end run contributes the
    // half the range names.
    var middle = try text(gpa, try rangeOver(gpa, &state, 1, 3));
    defer middle.deinit(gpa);
    try testing.expectEqualStrings("ellowor", middle.items);
}

test "a range ending on the leading edge of a run keeps that run's text" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    // The end sits at character 0 of the second run, so the walk visits it and
    // asks for an empty slice. Dropping it would lose the run boundary.
    var to_leading_edge = try text(gpa, try rangeOver(gpa, &state, 0, 0));
    defer to_leading_edge.deinit(gpa);
    try testing.expectEqualStrings("hello", to_leading_edge.items);
}

test "a degenerate range reports the empty string" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    // A caret is two ends at one offset of one run. `rangeOver` puts its
    // second end in the other run, so a caret needs its own range: a range
    // across the run boundary names five characters and is not degenerate.
    const caret = try init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 2 },
        .{ .node = handle(&state, 1), .character_index = 2 },
    );
    try testing.expect(try isDegenerate(gpa, caret));
    var empty = try text(gpa, caret);
    defer empty.deinit(gpa);
    try testing.expectEqualStrings("", empty.items);
}

test "writeText streams the bytes text collects" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    var buffer: [64]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try writeText(gpa, try rangeOver(gpa, &state, 1, 3), &writer);
    try testing.expectEqualStrings("ellowor", writer.buffered());
}

test "writeText reports a full writer and keeps what it took" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    var buffer: [4]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try testing.expectError(
        error.WriteFailed,
        writeText(gpa, try rangeOver(gpa, &state, 0, 5), &writer),
    );
    try testing.expectEqualStrings("hell", writer.buffered());
}

test "a property every run agrees on folds to that value" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    const folded = try fetchProperty(
        []const u8,
        gpa,
        try rangeOver(gpa, &state, 0, 5),
        constantFamily,
    );
    try testing.expectEqualStrings("same", folded.single.?);
}

test "a property the runs disagree on folds to mixed" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    const folded = try fetchProperty(
        []const u8,
        gpa,
        try rangeOver(gpa, &state, 0, 5),
        alternatingFamily,
    );
    try testing.expect(folded == .mixed);
}

test "a property no run declares folds to a single absent value" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    const folded = try fetchProperty(
        []const u8,
        gpa,
        try rangeOver(gpa, &state, 0, 5),
        absentFamily,
    );
    // Absent is a single value and not mixed, which is the difference the fold
    // exists to report.
    try testing.expectEqual(@as(?[]const u8, null), folded.single);
}

fn absentFamily(node_ref: NodeRef) QueryError!?[]const u8 {
    _ = node_ref;
    return null;
}

test "a run with no per-character positions yields no box" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try insert(gpa, &state, 0, null, document);
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "ab");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1 });
    try schema.option.setBounds(&run_node.properties, schema.rectInit(0, 0, 20, 10));
    try schema.enums.setTextDirection(&run_node.properties, .left_to_right);
    try insert(gpa, &state, 1, 0, run_node);

    var boxes = try boundingBoxes(gpa, try init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 0 },
        .{ .node = handle(&state, 1), .character_index = 2 },
    ));
    defer boxes.deinit(gpa);
    try testing.expectEqual(@as(usize, 0), boxes.items.len);
}

test "a box over part of a run starts on the edge the range starts at" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try insert(gpa, &state, 0, null, document);
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "abcd");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1, 1, 1 });
    try schema.vectors.setCharacterPositions(&run_node.properties, &.{ 0, 10, 20, 30 });
    try schema.vectors.setCharacterWidths(&run_node.properties, &.{ 10, 10, 10, 10 });
    try schema.option.setBounds(&run_node.properties, schema.rectInit(0, 0, 40, 10));
    try schema.enums.setTextDirection(&run_node.properties, .left_to_right);
    try insert(gpa, &state, 1, 0, run_node);

    // Characters 1 through 3 end at 30 and start at 10, so the box is exactly
    // the strip between them. A fold that used a closed far edge would report
    // 40 here and fail.
    var boxes = try boundingBoxes(gpa, try init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 1 },
        .{ .node = handle(&state, 1), .character_index = 3 },
    ));
    defer boxes.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), boxes.items.len);
    try testing.expectEqual(@as(f64, 10), boxes.items[0].x0);
    try testing.expectEqual(@as(f64, 30), boxes.items[0].x1);
}

test "a start at the leading edge of a run takes the whole box" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try insert(gpa, &state, 0, null, document);
    var run_node = schema.Node.init(gpa, .text_run);
    errdefer run_node.deinit();
    try schema.strings.setValue(&run_node.properties, "abcd");
    try schema.vectors.setCharacterLengths(&run_node.properties, &.{ 1, 1, 1, 1 });
    try schema.vectors.setCharacterPositions(&run_node.properties, &.{ 0, 10, 20, 30 });
    try schema.vectors.setCharacterWidths(&run_node.properties, &.{ 10, 10, 10, 10 });
    try schema.option.setBounds(&run_node.properties, schema.rectInit(5, 5, 45, 15));
    try schema.enums.setTextDirection(&run_node.properties, .left_to_right);
    try insert(gpa, &state, 1, 0, run_node);

    // Start 0 and end 4 are the run edges, so upstream leaves the rectangle
    // alone at `text.rs:778` and the box is the stored one.
    var boxes = try boundingBoxes(gpa, try init(
        gpa,
        handle(&state, 0),
        .{ .node = handle(&state, 1), .character_index = 0 },
        .{ .node = handle(&state, 1), .character_index = 4 },
    ));
    defer boxes.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), boxes.items.len);
    try testing.expectEqual(@as(f64, 5), boxes.items[0].x0);
    try testing.expectEqual(@as(f64, 45), boxes.items[0].x1);
}

test "a position from another node is refused by setStart and setEnd" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    var range = try rangeOver(gpa, &state, 0, 5);
    const other: Position = .{
        .root_node = handle(&state, 1),
        .inner = .{ .node = handle(&state, 1), .character_index = 2 },
    };
    try testing.expectError(error.InvalidPosition, setStart(gpa, &range, other));
    // The refused call left the range exactly as it was.
    try testing.expectEqual(@as(usize, 0), range.start.character_index);
    try testing.expect(sameNode(range.start.node, handle(&state, 1)));
    try testing.expectError(error.InvalidPosition, setEnd(gpa, &range, other));
    try testing.expectEqual(@as(usize, 5), range.end.character_index);
}

test "a start that passes the end drags the end with it" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    var range = try rangeOver(gpa, &state, 0, 2);
    const past: Position = .{
        .root_node = handle(&state, 0),
        .inner = .{ .node = handle(&state, 2), .character_index = 4 },
    };
    try setStart(gpa, &range, past);
    // Upstream uses `>=` at `text.rs:853`, so the end follows the start rather
    // than the two ends inverting.
    try testing.expect(sameNode(range.end.node, handle(&state, 2)));
    try testing.expectEqual(@as(usize, 4), range.end.character_index);
}

test "eql compares the node and both offsets" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    const a = try rangeOver(gpa, &state, 0, 5);
    const b = try rangeOver(gpa, &state, 0, 5);
    const c = try rangeOver(gpa, &state, 0, 4);
    try testing.expect(eql(a, b));
    try testing.expect(!eql(a, c));
}

test "downgrade keeps the node id, the weak positions and both ordering keys" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state);

    var weak = try downgrade(gpa, try rangeOver(gpa, &state, 1, 3));
    defer weak.deinit();
    try testing.expect(weak.nodeId().local.eql(.{ .value = 0 }));
    try testing.expect(weak.start.node_id.eql(.{ .value = 1 }));
    try testing.expectEqual(@as(usize, 1), weak.start.character_index);
    try testing.expect(weak.end.node_id.eql(.{ .value = 2 }));
    try testing.expectEqual(@as(usize, 3), weak.end.character_index);
    // The end comes after the start, which is what the precomputed keys are
    // for once the tree is gone.
    try testing.expect(weak.startComparable().order(weak.endComparable()) == .lt);
}
