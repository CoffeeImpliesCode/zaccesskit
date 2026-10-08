//! The thirty movement methods: every way a position moves through a document.
//!
//! Upstream `accesskit_consumer/src/text.rs:333-594`, plus the three character
//! movements at `text.rs:308-341`. `docs/30-port-design.md` section 3.2 takes
//! `text.rs:107-141` out of that file for `text/line_walk.zig`, because those two
//! walks need a bounded body, an error tag and tests of their own. This file is
//! the rest.
//!
//! **A movement never allocates and never fails on a well-formed document.** It
//! takes a `Position`, computes another one, and returns it. Three movements can
//! return an error, and each for a named reason stated on the function:
//! `forwardToParagraphStart`, `forwardToParagraphEnd` and `backwardToParagraphStart`
//! walk line by line and report `error.TreeCycle` when the walk overruns
//! `treeWalkStepBound`, because upstream's `loop` at `text.rs:518`, `:534` and
//! `:545` has no bound at all; `backwardToLineStart` and the format and word
//! movements reach `text/line_walk.zig`, which reports `error.LineChainCycle` on a
//! repeating `previous_on_line` or `next_on_line` chain; and the document and
//! bias helpers report `error.NoSuchNode` when a `children` list names a node
//! the state does not hold. Every one of those replaces an upstream `unwrap()` or
//! `panic!`. Rule C8 of `AGENTS.md` bans `unreachable`, so no movement asserts
//! where upstream aborts.
//!
//! **The three index units do not appear in this file, and that is the point.**
//! Every `character_index` here is a **character index**: an offset into the run's
//! `character_lengths`, counting Unicode scalar values. It is never a byte offset
//! into `value` and never a UTF-16 code unit index. `text/position_inner.zig`
//! states all three and `text/position.zig` states which unit each of its
//! conversions returns; this file crosses none of them, so a movement cannot
//! answer in the wrong unit.
//!
//! **The two biases, and that both appear in almost every movement.** A
//! position at the boundary between two runs names that boundary twice, so a
//! movement must say which run it lands in. `position_inner.biasedToStart` moves
//! **forward** to the start of the next run; `position_inner.biasedToEnd` moves
//! **backward** to the end of the previous one. They are not inverses, and the
//! difference is the whole of what distinguishes the movements below: forward to
//! a character start biases forward, backward to a character start biases
//! backward, and a format or word start is found by looking at the run *behind* a
//! position while its end is found by looking at the run *ahead* of it.
//!
//! **How the thirty are grouped.** Seven boundaries, each with a forward and a
//! backward movement, plus a paragraph and a page: format (`:343`, `:358`,
//! `:362`), word (`:390`, `:434`, `:438`), line (`:493`, `:500`, `:508`),
//! paragraph (`:516`, `:532`, `:543`), character (`text.rs:308`, `:320`, `:331`),
//! and page (`:554`, `:558`, `:562`), plus `documentStart` and `documentEnd`.
//! The character movements are here rather than in `text/position.zig` for one
//! reason: they are movements, and splitting one group across two files is how a
//! reader misses three of thirty.
//!
//! **What this module deliberately does not own.** The type and the index-unit
//! conversions are `text/position.zig`'s. The bias helpers, the run walks and
//! `textAttributesDiffer` are `text/position_inner.zig`'s. The two bounded line
//! walks are `text/line_walk.zig`'s, and this file calls them rather than
//! reimplementing either.
//!
//! No function here takes `gpa`, `io` or a clock, and every `const` is a `const`.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const line_walk = @import("line_walk.zig");
const node_ids = @import("../node_id.zig");
const position = @import("position.zig");
const position_inner = @import("position_inner.zig");
const tree_state = @import("../tree_state.zig");

const InnerPosition = position_inner.InnerPosition;
const NodeRef = node_ids.NodeRef;
const Position = position.Position;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const assert = std.debug.assert;
const testing = std.testing;

// --- Format, text.rs:343-388 ---------------------------------------------------

/// The next format run's start after `position_value`: the first character of the
/// following text run whose text formats differently from this one, or the
/// document end when no following run differs.
///
/// Walks **forward** over the following runs and compares each against
/// `position_value.inner.node`, so the first run that differs ends the walk. Upstream
/// `Position::forward_to_format_start` at `text.rs:343-356`.
///
/// **`error.TreeCycle`** and **`error.NoSuchNode`** come from the run walk.
/// Allocates nothing.
pub fn forwardToFormatStart(position_value: Position) QueryError!Position {
    var runs = try position_inner.followingTextRuns(
        position_value.inner.node,
        position_value.root_node,
    );
    while (try runs.next()) |run| {
        if (!position_inner.textAttributesDiffer(position_value.inner.node, run)) continue;
        return .{
            .root_node = position_value.root_node,
            .inner = .{ .node = run, .character_index = 0 },
        };
    }
    return documentEnd(position_value);
}

/// The end of the next format run: `forwardToFormatStart` biased **backward** to
/// the end of the run before it.
///
/// Upstream `Position::forward_to_format_end` at `text.rs:358-360`, which is the
/// forward format start followed by a backward bias. The bias goes backward
/// because the start already names the run, and what is wanted is that run's end.
///
/// **`error.TreeCycle`** and **`error.NoSuchNode`** come from the forward walk and
/// the bias. Allocates nothing.
pub fn forwardToFormatEnd(position_value: Position) QueryError!Position {
    const start = try forwardToFormatStart(position_value);
    const end_inner = try position_inner.biasedToEnd(start.inner, position_value.root_node);
    return .{ .root_node = position_value.root_node, .inner = end_inner };
}

/// The previous format run's start at or before `position`: character zero of
/// this run when this position is past it and this run begins a format, then the
/// nearest preceding run that begins a format, or the document start.
///
/// Looks **backward**, at the runs behind `position`, which is the opposite
/// direction from `forwardToFormatStart`. Upstream
/// `Position::backward_to_format_start` at `text.rs:362-388`.
///
/// **`error.TreeCycle`** and **`error.NoSuchNode`** come from the run walk.
/// Allocates nothing.
pub fn backwardToFormatStart(position_value: Position) QueryError!Position {
    if (position_value.inner.character_index != 0) {
        // The position is past the start of its own run, so the start of this run
        // is the nearest candidate and no earlier run is.
        const candidate: Position = .{
            .root_node = position_value.root_node,
            .inner = .{ .node = position_value.inner.node, .character_index = 0 },
        };
        if (try position.isFormatStart(candidate)) return candidate;
    }
    var runs = try position_inner.precedingTextRuns(
        position_value.inner.node,
        position_value.root_node,
    );
    while (try runs.next()) |run| {
        const candidate: Position = .{
            .root_node = position_value.root_node,
            .inner = .{ .node = run, .character_index = 0 },
        };
        if (try position.isFormatStart(candidate)) return candidate;
    }
    return documentStart(position_value);
}

// --- Word, text.rs:390-491 -----------------------------------------------------

/// The next word start after `position_value`: the first listed word start in this run
/// past the position, then the first run ahead that begins a word, or the
/// document end.
///
/// The search is a binary search over `word_starts`, so the key is the
/// character's index narrowed to a `u8`; see `position_inner.wordStartSlot`, which
/// narrows it the same way and says why. When the position is itself a word start
/// the search takes the *next* entry rather than the one it is on, which is what
/// makes this a forward movement rather than an identity on a word boundary.
/// Upstream `Position::forward_to_word_start` at `text.rs:390-432`.
///
/// **`error.TreeCycle`** and **`error.NoSuchNode`** come from the run walk.
/// Allocates nothing.
pub fn forwardToWordStart(position_value: Position) QueryError!Position {
    const biased = try position_inner.biasedToStart(position_value.inner, position_value.root_node);
    const slot = position_inner.wordStartSlot(
        schema.vectors.wordStarts(&biased.node.data().properties),
        biased.character_index,
    );
    // An exact hit moves one entry on, so a position already on a word start
    // advances to the next one; a gap is already the place the next word begins.
    if (slot.exact) {
        if (slot.index + 1 < schema.vectors.wordStarts(&biased.node.data().properties).len) {
            const starts = schema.vectors.wordStarts(&biased.node.data().properties);
            return .{
                .root_node = position_value.root_node,
                .inner = .{ .node = biased.node, .character_index = starts[slot.index + 1] },
            };
        }
    } else if (slot.index < schema.vectors.wordStarts(&biased.node.data().properties).len) {
        const starts = schema.vectors.wordStarts(&biased.node.data().properties);
        return .{
            .root_node = position_value.root_node,
            .inner = .{ .node = biased.node, .character_index = starts[slot.index] },
        };
    }

    var runs = try position_inner.followingTextRuns(biased.node, position_value.root_node);
    while (try runs.next()) |run| {
        const run_starts = schema.vectors.wordStarts(&run.data().properties);
        if (run_starts.len == 0) continue;
        return .{
            .root_node = position_value.root_node,
            .inner = .{ .node = run, .character_index = run_starts[0] },
        };
    }
    return documentEnd(position_value);
}

/// The end of the next word: `forwardToWordStart` biased **backward** to the end
/// of the run before it.
///
/// Upstream `Position::forward_to_word_end` at `text.rs:434-436`.
///
/// **`error.TreeCycle`** and **`error.NoSuchNode`** come from the forward walk and
/// the bias. Allocates nothing.
pub fn forwardToWordEnd(position_value: Position) QueryError!Position {
    const start = try forwardToWordStart(position_value);
    const end_inner = try position_inner.biasedToEnd(start.inner, position_value.root_node);
    return .{ .root_node = position_value.root_node, .inner = end_inner };
}

/// The previous word start at or before `position`: the listed word start below
/// this position, then the paragraph start this run begins, then the nearest
/// preceding run that lists a word start or begins a paragraph, or the document
/// start.
///
/// Looks **backward**. When the position is itself a word start the search keeps
/// that entry rather than moving on, so a position on a word boundary stays on
/// it. Upstream `Position::backward_to_word_start` at `text.rs:438-491`.
///
/// **`error.TreeCycle`** and **`error.NoSuchNode`** come from the run walk.
/// Allocates nothing.
pub fn backwardToWordStart(position_value: Position) QueryError!Position {
    const starts = schema.vectors.wordStarts(&position_value.inner.node.data().properties);
    const slot = position_inner.wordStartSlot(starts, position_value.inner.character_index);
    // The entry below the slot is the nearest word start behind the position. A
    // slot of zero has nothing behind it, so the search moves to the run ahead of
    // this one.
    if (slot.index > 0) {
        return .{
            .root_node = position_value.root_node,
            .inner = .{
                .node = position_value.inner.node,
                .character_index = starts[slot.index - 1],
            },
        };
    }

    if (position_value.inner.character_index != 0) {
        const candidate: Position = .{
            .root_node = position_value.root_node,
            .inner = .{ .node = position_value.inner.node, .character_index = 0 },
        };
        if (try position.isParagraphStart(candidate)) return candidate;
    }

    var runs = try position_inner.precedingTextRuns(
        position_value.inner.node,
        position_value.root_node,
    );
    while (try runs.next()) |run| {
        const run_starts = schema.vectors.wordStarts(&run.data().properties);
        if (run_starts.len != 0) {
            return .{
                .root_node = position_value.root_node,
                .inner = .{
                    .node = run,
                    .character_index = run_starts[run_starts.len - 1],
                },
            };
        }
        const candidate: Position = .{
            .root_node = position_value.root_node,
            .inner = .{ .node = run, .character_index = 0 },
        };
        if (try position.isParagraphStart(candidate)) return candidate;
    }
    return documentStart(position_value);
}

// --- Line, text.rs:493-514 -----------------------------------------------------

/// The end of the line `position` sits on, biased **forward**.
///
/// Walks `next_on_line` to the end of the line and then takes the forward bias,
/// which normalizes the result across the run boundary at that end. Upstream
/// `Position::forward_to_line_start` at `text.rs:493-498`.
///
/// **`error.LineChainCycle`** when the `next_on_line` chain repeats, and
/// **`error.NoSuchNode`** when a link names a node the state does not hold; both
/// come from `text/line_walk.zig` and replace upstream's `.unwrap()` at
/// `text.rs:121`. Allocates nothing.
pub fn forwardToLineStart(position_value: Position) QueryError!Position {
    const end = try line_walk.lineEnd(position_value.inner);
    return .{
        .root_node = position_value.root_node,
        .inner = try position_inner.biasedToStart(end, position_value.root_node),
    };
}

/// The end of the line `position` sits on.
///
/// Walks `next_on_line` from the forward-biased position, so a position at the
/// end of a run is measured from the start of the next run. Upstream
/// `Position::forward_to_line_end` at `text.rs:500-506`.
///
/// **`error.LineChainCycle`** and **`error.NoSuchNode`** come from the walk.
/// Allocates nothing.
pub fn forwardToLineEnd(position_value: Position) QueryError!Position {
    const biased = try position_inner.biasedToStart(position_value.inner, position_value.root_node);
    return .{
        .root_node = position_value.root_node,
        .inner = try line_walk.lineEnd(biased),
    };
}

/// The start of the line `position` sits on, biased **forward**.
///
/// Walks `previous_on_line` from the backward-biased position. Upstream
/// `Position::backward_to_line_start` at `text.rs:508-514`.
///
/// **`error.LineChainCycle`** and **`error.NoSuchNode`** come from the walk.
/// Allocates nothing.
pub fn backwardToLineStart(position_value: Position) QueryError!Position {
    const biased = try position_inner.biasedToEnd(position_value.inner, position_value.root_node);
    return .{
        .root_node = position_value.root_node,
        .inner = try position_inner.biasedToStart(
            try line_walk.lineStart(biased),
            position_value.root_node,
        ),
    };
}

// --- Paragraph, text.rs:516-552 -------------------------------------------------

/// The start of the next paragraph: the first line start whose line ends a
/// paragraph, or the document end.
///
/// Walks **forward** one line at a time. Upstream
/// `Position::forward_to_paragraph_start` at `text.rs:516-530`, whose `loop` at
/// `:518` has no bound.
///
/// **The bound.** `treeWalkStepBound(node_count)`, and `docs/33` section 7's
/// "walks that take the same bound" list names `text.rs:518` for this file.
/// **`error.LineChainCycle`** when the inner `next_on_line` walk cycles, and
/// **`error.TreeCycle`** when this loop itself overruns its bound. The inner walk
/// is bounded first, so a cyclic chain reports `LineChainCycle` and `TreeCycle`
/// is the guard for a chain the inner walk completes more times than the tree
/// holds nodes. `error.NoSuchNode` comes from a line link. Allocates nothing.
pub fn forwardToParagraphStart(position_value: Position) QueryError!Position {
    var current = position_value;
    var step: usize = 0;
    const step_bound = treeWalkStepBound(position_value.root_node.tree_state.nodes.count());
    while (true) {
        current = try forwardToLineStart(current);
        if (try position.isDocumentEnd(current)) return current;
        const run_end = try position_inner.biasedToEnd(current.inner, current.root_node);
        if (position_inner.isParagraphEnd(run_end)) {
            return current;
        }
        if (step == step_bound) return error.TreeCycle;
        step += 1;
    }
}

/// The end of the next paragraph: the first line end that ends a paragraph, or
/// the document end.
///
/// Walks **forward** one line at a time. Upstream
/// `Position::forward_to_paragraph_end` at `text.rs:532-541`, whose `loop` at
/// `:534` has no bound.
///
/// **The bound.** `treeWalkStepBound(node_count)`, named for `text.rs:534`.
/// **`error.LineChainCycle`** when the inner `next_on_line` walk cycles, and
/// **`error.TreeCycle`** when this loop itself overruns its bound; the inner walk
/// is bounded first, so a cyclic chain reports `LineChainCycle`. Allocates nothing.
pub fn forwardToParagraphEnd(position_value: Position) QueryError!Position {
    var current = position_value;
    var step: usize = 0;
    const step_bound = treeWalkStepBound(position_value.root_node.tree_state.nodes.count());
    while (true) {
        current = try forwardToLineEnd(current);
        if (try position.isDocumentEnd(current)) return current;
        if (position_inner.isParagraphEnd(current.inner)) return current;
        if (step == step_bound) return error.TreeCycle;
        step += 1;
    }
}

/// The start of the paragraph `position_value` is in, or of the nearest earlier one.
///
/// Walks **backward** one line at a time until the position opens a paragraph.
/// Upstream `Position::backward_to_paragraph_start` at `text.rs:543-552`, whose
/// `loop` at `:545` has no bound.
///
/// **The bound.** `treeWalkStepBound(node_count)`, named for `text.rs:545`.
/// **`error.LineChainCycle`** when the inner `previous_on_line` walk cycles, and
/// **`error.TreeCycle`** when this loop itself overruns its bound; the inner walk
/// is bounded first, so a cyclic chain reports `LineChainCycle`. Allocates nothing.
pub fn backwardToParagraphStart(position_value: Position) QueryError!Position {
    var current = position_value;
    var step: usize = 0;
    const step_bound = treeWalkStepBound(position_value.root_node.tree_state.nodes.count());
    while (true) {
        current = try backwardToLineStart(current);
        if (try position.isParagraphStart(current)) return current;
        if (step == step_bound) return error.TreeCycle;
        step += 1;
    }
}

// --- Page, text.rs:554-564 -----------------------------------------------------

/// The end of the document.
///
/// Upstream `Position::forward_to_page_start` at `text.rs:554-556` returns
/// `self.document_end()`, not a page start. A text document has one page, so a
/// forward page movement has nowhere to go but the end; the port says so rather
/// than inventing a second notion of position on a text document.
///
/// **`error.NoSuchNode`** when the document declares no text run. Allocates nothing.
pub fn forwardToPageStart(position_value: Position) QueryError!Position {
    return documentEnd(position_value);
}

/// The end of the document. Upstream `Position::forward_to_page_end` at
/// `text.rs:558-560`.
///
/// **`error.NoSuchNode`** when the document declares no text run. Allocates nothing.
pub fn forwardToPageEnd(position_value: Position) QueryError!Position {
    return documentEnd(position_value);
}

/// The start of the document. Upstream `Position::backward_to_page_start` at
/// `text.rs:562-564`.
///
/// **`error.NoSuchNode`** when the document declares no text run. Allocates nothing.
pub fn backwardToPageStart(position_value: Position) QueryError!Position {
    return documentStart(position_value);
}

/// The end of the document. Upstream `Position::document_end` at `text.rs:566-568`.
///
/// **`error.NoSuchNode`** when the document declares no text run, and
/// **`error.TreeCycle`** from the descendant scan. Allocates nothing.
pub fn documentEnd(position_value: Position) QueryError!Position {
    const end_inner = try position_inner.documentEndInner(position_value.root_node);
    return .{ .root_node = position_value.root_node, .inner = end_inner };
}

/// The start of the document. Upstream `Position::document_start` at
/// `text.rs:570-572`.
///
/// **`error.NoSuchNode`** when the document declares no text run, replacing
/// upstream's `.unwrap()` at `text.rs:1409`, and **`error.TreeCycle`** from the
/// descendant scan. Allocates nothing.
pub fn documentStart(position_value: Position) QueryError!Position {
    const start_inner = try position_inner.documentStartInner(position_value.root_node);
    return .{ .root_node = position_value.root_node, .inner = start_inner };
}

comptime {
    // A movement takes a `Position` and returns a `Position`, so the size of this
    // file's whole interface is one value. Pinned so a field added to either
    // struct is a build failure rather than a silent change to what thirty
    // functions pass by value.
    assert(@sizeOf(Position) == @sizeOf(NodeRef) * 2 + @sizeOf(usize));
    assert(@sizeOf(InnerPosition) == @sizeOf(NodeRef) + @sizeOf(usize));

    // Three of the seven tags of `QueryError` are reachable from this file, and
    // each replaces an upstream site: the three unbounded paragraph loops report
    // `TreeCycle`, the two line walks report `LineChainCycle`, and every
    // `unwrap()` of a node lookup reports `NoSuchNode`.
    // An error set is not an enum, so a membership test compares names: each tag
    // this file can return must appear in the set `QueryError` declares. A
    // rename on either side fails the build rather than leaving one unreachable.
    const reachable = [_][]const u8{ "TreeCycle", "LineChainCycle", "NoSuchNode" };
    for (reachable) |wanted| {
        var found = false;
        for (@typeInfo(QueryError).error_set.?) |member| {
            if (std.mem.eql(u8, member.name, wanted)) found = true;
        }
        assert(found);
    }
}

// --- Tests ---------------------------------------------------------------------

const test_allocator = testing.allocator;
const Node = schema.Node;
const NodeId = schema.NodeId;
const tree_index = @import("../tree_index.zig");
const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const TreeState = tree_state.TreeState;

/// The optional properties a fixture run may carry beyond its text.
///
/// A plain struct rather than a closure, because the house rules forbid a
/// captured variable and a build step is where one would go.
const RunExtras = struct {
    font_size: ?f32 = null,
    word_starts: ?[]const u8 = null,
};

fn localId(raw: u64) NodeId {
    return .{ .value = raw };
}

fn fullId(id: NodeId) FullNodeId {
    return FullNodeId.init(id, .init(0));
}

fn testState() TreeState {
    return .{ .root_id = fullId(localId(1)), .focus_id = fullId(localId(1)) };
}

fn refOf(state: *TreeState, id: NodeId) !NodeRef {
    return NodeRef.init(state, fullId(id)) orelse error.NodeMissingFromFixture;
}

fn parentOf(parent: NodeId, index: usize) ParentAndIndex {
    return .{ .parent_id = fullId(parent), .index = index };
}

fn buildRun(
    text: []const u8,
    byte_lengths: []const u8,
    extras: RunExtras,
) std.mem.Allocator.Error!Node {
    var run = Node.init(test_allocator, .text_run);
    errdefer run.deinit();
    if (extras.font_size) |size| try schema.numbers.setFontSize(&run.properties, size);
    if (extras.word_starts) |starts| try schema.vectors.setWordStarts(&run.properties, starts);
    try schema.strings.setValue(&run.properties, text);
    try schema.vectors.setCharacterLengths(&run.properties, byte_lengths);
    return run;
}

/// Adds one node under `id`, taking ownership of `node` and releasing it on
/// failure, so no caller writes its own guard and none can release it twice.
fn put(state: *TreeState, id: NodeId, parent: ?ParentAndIndex, node: *Node) !void {
    errdefer node.deinit();
    try state.nodes.put(test_allocator, fullId(id), .{
        .parent_and_index = parent,
        .data = node.*,
    });
    // SAFETY: the map copied `node` by value on the lines above, so the
    // caller-owned slot no longer owns the properties, and no statement after
    // it reads `node`. A read anyway traps in Debug rather than aliasing the
    // stored copy with two owners.
    node.* = undefined;
}

fn addRun(
    state: *TreeState,
    id: NodeId,
    index: usize,
    text: []const u8,
    byte_lengths: []const u8,
    extras: RunExtras,
) !NodeRef {
    var run = try buildRun(text, byte_lengths, extras);
    try put(state, id, parentOf(localId(1), index), &run);
    return refOf(state, id);
}

fn addDocumentRoot(state: *TreeState, children: []const NodeId) !NodeRef {
    var root = Node.init(test_allocator, .document);
    errdefer root.deinit();
    try schema.ids_props.setChildren(&root.properties, children);
    try put(state, localId(1), null, &root);
    return refOf(state, localId(1));
}

/// Writes a `previous_on_line` or `next_on_line` onto a run already in the state.
fn setRunLink(state: *TreeState, id: NodeId, previous: ?NodeId, next: ?NodeId) !void {
    const entry = state.nodes.getPtr(fullId(id)) orelse return error.NodeMissingFromFixture;
    if (previous) |target| try schema.ids_props.setPreviousOnLine(&entry.data.properties, target);
    if (next) |target| try schema.ids_props.setNextOnLine(&entry.data.properties, target);
}

/// A document of `runs` one-character runs, each on its own line.
///
/// No `previous_on_line` and no `next_on_line` is written, so each run is a whole
/// line of its own and every movement that crosses a line crosses a run.
fn documentWithRuns(run_count: usize) !TreeState {
    var state = testState();
    errdefer state.deinit(test_allocator);
    const children = try test_allocator.alloc(NodeId, run_count);
    defer test_allocator.free(children);
    for (children, 0..) |*slot, index| slot.* = localId(index + 2);
    _ = try addDocumentRoot(&state, children);
    for (children, 0..) |child_id, index| {
        _ = try addRun(&state, child_id, index, "x", &.{1}, .{});
    }
    return state;
}

fn at(state: *TreeState, id: NodeId, character_index: usize) !Position {
    return .{
        .root_node = try refOf(state, localId(1)),
        .inner = .{ .node = try refOf(state, id), .character_index = character_index },
    };
}

// --- Format --------------------------------------------------------------------

test "forwardToFormatStart stops at the next run that formats its text differently" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3), localId(4) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{ .font_size = 10 });
    // The third run formats the same way as the first, so the walk passes it.
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{ .font_size = 10 });
    // The fourth differs, so it ends the walk.
    _ = try addRun(&state, localId(4), 2, "c", &.{1}, .{ .font_size = 20 });

    const moved = try forwardToFormatStart(try at(&state, localId(2), 0));
    // Character zero of the fourth run, which is three runs on from the start.
    try testing.expectEqual(localId(4), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "forwardToFormatStart falls back to the document end when no run differs" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{ .font_size = 10 });
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{ .font_size = 10 });

    // Nothing ahead differs, so the movement lands on the document end: the end of
    // the last run.
    const moved = try forwardToFormatStart(try at(&state, localId(2), 0));
    try testing.expect(try position.isDocumentEnd(moved));
}

test "forwardToFormatEnd biases backward from the format start to the run before it" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3), localId(4) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{ .font_size = 10 });
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{ .font_size = 10 });
    // The third run formats its text differently, so the walk stops there.
    _ = try addRun(&state, localId(4), 2, "cd", &.{ 1, 1 }, .{ .font_size = 20 });

    const start = try forwardToFormatStart(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(4), start.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), start.inner.character_index);

    // Upstream is `self.forward_to_format_start().biased_to_end()` at
    // `text.rs:358-360`, and the bias runs **backward**: it fires only at the
    // start of a run, so a format start at character zero moves to the end of
    // the run *before* it rather than to that run's own end. Three runs and not
    // two, because with two the run before the format start is the run the
    // position started on, and then the three candidate answers collapse into
    // one.
    const moved = try forwardToFormatEnd(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 1), moved.inner.character_index);
}

test "backwardToFormatStart returns this run's own start when the position is past it" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{ .font_size = 10 });
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{ .font_size = 20 });

    // The position is one character on, so its own run's start is the nearest
    // candidate and no earlier run is consulted.
    const moved = try backwardToFormatStart(try at(&state, localId(2), 1));
    try testing.expectEqual(localId(2), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "backwardToFormatStart walks back to the nearest run that begins a format" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3), localId(4) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{ .font_size = 10 });
    _ = try addRun(&state, localId(3), 1, "b", &.{1}, .{ .font_size = 10 });
    _ = try addRun(&state, localId(4), 2, "c", &.{1}, .{ .font_size = 20 });

    // The fourth run is at character zero, so the search starts with the runs
    // behind it and the second run is the nearest one whose formatting differs
    // from the run in front of it.
    const moved = try backwardToFormatStart(try at(&state, localId(4), 0));
    try testing.expectEqual(localId(2), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "backwardToFormatStart falls back to the document start" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);

    // Every run formats its text the same way, so no earlier run begins a format
    // and the movement lands on the document start.
    const moved = try backwardToFormatStart(try at(&state, localId(4), 1));
    try testing.expect(try position.isDocumentStart(moved));
}

// --- Word ----------------------------------------------------------------------

test "forwardToWordStart takes the entry after the one the position is on" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    // Word starts at characters zero, two and four.
    _ = try addRun(
        &state,
        localId(2),
        0,
        "ab cd ef",
        &.{ 1, 1, 1, 1, 1, 1, 1 },
        .{ .word_starts = &.{ 0, 2, 4 } },
    );

    // A position already on the second word start advances to the third, so this
    // is a forward movement and not an identity on a boundary.
    const moved = try forwardToWordStart(try at(&state, localId(2), 2));
    try testing.expectEqual(@as(usize, 4), moved.inner.character_index);
}

test "forwardToWordStart reports a gap as the place the next word begins" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    _ = try addRun(
        &state,
        localId(2),
        0,
        "ab cd ef",
        &.{ 1, 1, 1, 1, 1, 1, 1 },
        .{ .word_starts = &.{ 0, 2, 4 } },
    );

    // Character three is in the gap between the second and third word starts, so
    // the insertion point is the third entry.
    const moved = try forwardToWordStart(try at(&state, localId(2), 3));
    try testing.expectEqual(@as(usize, 4), moved.inner.character_index);
}

test "forwardToWordStart crosses into the next run that lists a word start" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    // The first run lists no word start, so the walk has to leave it.
    _ = try addRun(&state, localId(2), 0, "abc", &.{ 1, 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "de", &.{ 1, 1 }, .{ .word_starts = &.{1} });

    const moved = try forwardToWordStart(try at(&state, localId(2), 1));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 1), moved.inner.character_index);
}

test "forwardToWordStart falls back to the document end" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);

    // No run lists a word start, so there is nothing ahead to stop at.
    const moved = try forwardToWordStart(try at(&state, localId(2), 0));
    try testing.expect(try position.isDocumentEnd(moved));
}

test "forwardToWordEnd biases backward from the word start to the run before it" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    // The first run lists no word start, so the search has to leave it.
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{ .word_starts = &.{0} });

    const start = try forwardToWordStart(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(3), start.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), start.inner.character_index);

    // Upstream is `self.forward_to_word_start().biased_to_end()` at
    // `text.rs:434-436`, and the bias runs **backward**: the word start is
    // character zero of the second run, so it moves to the end of the first run
    // rather than to the end of the word. A word start that is not at a run
    // start would not fire the bias at all and the movement would answer the
    // word start unchanged, which is why the fixture puts one here.
    const moved = try forwardToWordEnd(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(2), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 2), moved.inner.character_index);
}

test "backwardToWordStart steps to the entry below the one the position is on" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{localId(2)});
    _ = try addRun(
        &state,
        localId(2),
        0,
        "ab cd",
        &.{ 1, 1, 1, 1 },
        .{ .word_starts = &.{ 0, 3 } },
    );

    // A position sitting **on** the second word start moves back to the first.
    // Both arms of the match at `text.rs:443-446` hand back the insertion index
    // rather than a hit flag, so character three slots at one either way, and
    // the `checked_sub` at `text.rs:447` then steps strictly below the slot.
    // The entry is never the one the position is on, so this is not the mirror
    // of `forwardToWordStart` and the previous expectation of three was that
    // mirror, not a reading of the code.
    const moved = try backwardToWordStart(try at(&state, localId(2), 3));
    try testing.expectEqual(localId(2), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "backwardToWordStart walks back into the preceding run's last word start" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(
        &state,
        localId(2),
        0,
        "ab cd",
        &.{ 1, 1, 1, 1 },
        .{ .word_starts = &.{ 0, 3 } },
    );
    _ = try addRun(&state, localId(3), 1, "ef", &.{ 1, 1 }, .{});

    // The second run lists no word start, so the search leaves it and takes the
    // last entry of the run before it.
    const moved = try backwardToWordStart(try at(&state, localId(3), 1));
    try testing.expectEqual(localId(2), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 3), moved.inner.character_index);
}

test "backwardToWordStart falls back to the document start" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);

    // No run lists a word start and the second run does not begin a paragraph, so
    // the walk reaches the front of the document.
    const moved = try backwardToWordStart(try at(&state, localId(3), 0));
    try testing.expect(try position.isDocumentStart(moved));
}

// --- Line ----------------------------------------------------------------------

test "forwardToLineStart crosses a line boundary and normalizes onto the next run" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);

    // The first run's end is the end of its line, and the forward bias moves that
    // to the start of the next run, so the answer is the second run at zero.
    const moved = try forwardToLineStart(try at(&state, localId(2), 1));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "forwardToLineEnd walks to the last run of the line and counts that run" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "a", &.{1}, .{});
    _ = try addRun(&state, localId(3), 1, "bc", &.{ 1, 1 }, .{});
    // The two runs share a line, so the end of the line is the end of the second.
    try setRunLink(&state, localId(2), null, localId(3));

    const moved = try forwardToLineEnd(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    // Two characters in the landing run, so a port that counted the starting run
    // would answer one here.
    try testing.expectEqual(@as(usize, 2), moved.inner.character_index);
}

test "backwardToLineStart walks back to the first run of the line" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});
    // The two runs share a line, so the line start is the first run's zero.
    try setRunLink(&state, localId(3), localId(2), null);

    const moved = try backwardToLineStart(try at(&state, localId(3), 1));
    try testing.expectEqual(localId(2), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "backwardToLineStart leaves a run that opens its own line where it is" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);

    // The second run has no run before it on its line, so the walk stops at once.
    const moved = try backwardToLineStart(try at(&state, localId(3), 1));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "backwardToLineStart reports LineChainCycle on a previous_on_line cycle" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);
    // Two runs naming each other as the run before them, so the walk never
    // reaches a run that declares no link.
    try setRunLink(&state, localId(2), localId(3), null);
    try setRunLink(&state, localId(3), localId(2), null);

    try testing.expectError(
        error.LineChainCycle,
        backwardToLineStart(try at(&state, localId(2), 0)),
    );
}

// --- Paragraph -----------------------------------------------------------------

test "forwardToParagraphStart stops at the line that ends a paragraph" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    // The first run ends a paragraph, so the second run's line start is the next
    // paragraph start.
    _ = try addRun(&state, localId(2), 0, "ab\n", &.{ 1, 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});

    const moved = try forwardToParagraphStart(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "forwardToParagraphStart falls back to the document end" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);

    // No run ends a paragraph, so the walk runs to the end of the document rather
    // than stopping on the way.
    const moved = try forwardToParagraphStart(try at(&state, localId(2), 0));
    try testing.expect(try position.isDocumentEnd(moved));
}

test "forwardToParagraphStart reports LineChainCycle when the line walk cannot finish" {
    var state = try documentWithRuns(4);
    defer state.deinit(test_allocator);
    // The second and third runs name **each other** as the run after, so the
    // forward line walk cycles between them and never reaches a line end. A
    // chain that merely alternated, naming next a run that declares no link of
    // its own, would end on every single step and hand the failure to the
    // paragraph loop's own bound, which is a different tag for a different
    // defect and is what this fixture used to build.
    try setRunLink(&state, localId(3), null, localId(4));
    try setRunLink(&state, localId(4), null, localId(3));

    // The inner line walk is bounded before the paragraph loop is, so a cyclic
    // chain reports `LineChainCycle` and never reaches the paragraph loop's own
    // bound. That ordering is the reason this test names the tag it sees.
    try testing.expectError(
        error.LineChainCycle,
        forwardToParagraphStart(try at(&state, localId(2), 0)),
    );
}

test "forwardToParagraphEnd stops at the line end that ends a paragraph" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab", &.{ 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd\n", &.{ 1, 1, 1 }, .{});

    // The forward line walk reaches the second run, whose end closes a paragraph.
    const moved = try forwardToParagraphEnd(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 3), moved.inner.character_index);
}

test "forwardToParagraphEnd falls back to the document end" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);

    const moved = try forwardToParagraphEnd(try at(&state, localId(2), 0));
    try testing.expect(try position.isDocumentEnd(moved));
}

test "backwardToParagraphStart walks back to the paragraph the position is in" {
    var state = testState();
    defer state.deinit(test_allocator);
    _ = try addDocumentRoot(&state, &.{ localId(2), localId(3) });
    _ = try addRun(&state, localId(2), 0, "ab\n", &.{ 1, 1, 1 }, .{});
    _ = try addRun(&state, localId(3), 1, "cd", &.{ 1, 1 }, .{});

    // The second run opens a paragraph, so the backward walk stops at its own line
    // start rather than continuing into the first run.
    const moved = try backwardToParagraphStart(try at(&state, localId(3), 1));
    try testing.expectEqual(localId(3), moved.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), moved.inner.character_index);
}

test "backwardToParagraphStart reports LineChainCycle when the line walk cannot finish" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);
    // Each run names the run after it as the run before, so the backward line
    // walk cycles and never reaches a paragraph start.
    try setRunLink(&state, localId(2), localId(4), null);
    try setRunLink(&state, localId(3), localId(2), null);
    try setRunLink(&state, localId(4), localId(3), null);

    // The line walk is bounded before the paragraph loop, so the tag that reaches
    // a caller is `LineChainCycle`. The paragraph loop's own `TreeCycle` is a
    // bound on a walk the line walk has already bounded, and it fires only for a
    // chain the line walk completes more times than the tree holds nodes.
    try testing.expectError(
        error.LineChainCycle,
        backwardToParagraphStart(try at(&state, localId(4), 0)),
    );
}

// --- Page ----------------------------------------------------------------------

test "forwardToPageStart and forwardToPageEnd both report the document end" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);

    // A text document has one page, so a forward page movement has nowhere to go
    // but the end. Upstream says so at `text.rs:554` and `text.rs:558`.
    try testing.expect(try position.isDocumentEnd(
        try forwardToPageStart(try at(&state, localId(2), 0)),
    ));
    try testing.expect(try position.isDocumentEnd(
        try forwardToPageEnd(try at(&state, localId(2), 0)),
    ));
}

test "backwardToPageStart reports the document start" {
    var state = try documentWithRuns(2);
    defer state.deinit(test_allocator);

    try testing.expect(try position.isDocumentStart(
        try backwardToPageStart(try at(&state, localId(3), 0)),
    ));
}

test "the page movements report NoSuchNode for a document with no text run" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .document);
    errdefer root.deinit();
    try put(&state, localId(1), null, &root);
    const empty: Position = .{
        .root_node = try refOf(&state, localId(1)),
        .inner = .{ .node = try refOf(&state, localId(1)), .character_index = 0 },
    };

    // Every page movement bottoms out at a document end or start, and both report
    // the tag when the document holds no run to anchor one.
    try testing.expectError(error.NoSuchNode, forwardToPageStart(empty));
    try testing.expectError(error.NoSuchNode, forwardToPageEnd(empty));
    try testing.expectError(error.NoSuchNode, backwardToPageStart(empty));
}

// --- Document ------------------------------------------------------------------

test "documentStart and documentEnd name the two outer positions of the document" {
    var state = try documentWithRuns(3);
    defer state.deinit(test_allocator);

    const start = try documentStart(try at(&state, localId(3), 0));
    try testing.expectEqual(localId(2), start.inner.node.id().local);
    try testing.expectEqual(@as(usize, 0), start.inner.character_index);

    // The end is one past the last character of the last run.
    const end = try documentEnd(try at(&state, localId(2), 0));
    try testing.expectEqual(localId(4), end.inner.node.id().local);
    try testing.expectEqual(@as(usize, 1), end.inner.character_index);
}

test "documentStart and documentEnd report NoSuchNode for a document with no run" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .document);
    errdefer root.deinit();
    try put(&state, localId(1), null, &root);
    const empty: Position = .{
        .root_node = try refOf(&state, localId(1)),
        .inner = .{ .node = try refOf(&state, localId(1)), .character_index = 0 },
    };

    try testing.expectError(error.NoSuchNode, documentStart(empty));
    try testing.expectError(error.NoSuchNode, documentEnd(empty));
}
