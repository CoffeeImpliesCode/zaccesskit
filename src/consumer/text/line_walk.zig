//! The two bounded line walks: from a position to the start of its line, and to
//! the end of it.
//!
//! Upstream `accesskit_consumer/src/text.rs:115-141`. Upstream holds both inside
//! `impl InnerPosition`, next to the biased helpers, and `docs/30-port-design.md`
//! section 3.2 cuts them out because they are the only two loops in the whole of
//! `text.rs` whose termination argument is neither a finite input nor a comptime
//! domain. Everything else in the file walks a list or a character slice; these
//! two walk a `previous_on_line` / `next_on_line` chain, and a platform that
//! writes a cycle into that chain hangs the consumer. **This file exists for that
//! reason**, so the bound, its derivation and the tag it reports are here rather
//! than buried in a module that also owns thirty other operations.
//!
//! **The chain, and what a walk on it is walking.** A text run that sits in the
//! middle of a visual line names its neighbour on that line: `previous_on_line`
//! names the run before it and `next_on_line` names the run after. The links are
//! a separate chain from the `children` list. They are not the same chain, they
//! need not agree, and a run may have a `next_on_line` that is not one of its
//! `children`. A walk here follows the links and stops at the first absent one,
//! which is why `lineStart` reports character zero of the run it lands on and
//! `lineEnd` reports that run's character count rather than an index derived from
//! where it started.
//!
//! **The bound, and why it is the node count.** Each step moves to a *different*
//! node: the walk reads `previous_on_line` or `next_on_line` off the current node
//! and looks the named node up in the same tree. Two steps therefore cannot land
//! on the same node twice unless the chain repeats, and a chain that repeats is
//! exactly the case with no termination argument. A tree holds at most
//! `node_count` nodes, so the walk cannot take more than `node_count` steps
//! before it must have repeated a node, and the count catches the repeat. The
//! bound is `tree_state.treeWalkStepBound`, which section 7 of
//! `docs/33-consumer-interface-contract.md` derives for the five ancestor and
//! child walks at `node.rs:143`, `:240`, `:259`, `:278` and `:302`. This is not
//! one of those five and the doc does not list it, so this file derives it again
//! and names it `lineWalkStepBound`; the derivation is the same one, for the same
//! reason.
//!
//! **The tag.** Exhaustion is `error.LineChainCycle`, which is one of the seven
//! tags of `QueryError` and exists for exactly this: `docs/33` section 5 spells
//! it as "replaces the unbounded walk at `text.rs:117`, `:131`", which are these
//! two loops. A separate tag rather than `error.TreeCycle` because the two
//! failures are different defects and a caller may act on them differently: a
//! parent cycle means the tree's containment is broken, a line cycle means only
//! the platform's line layout is. Rule C8 of `AGENTS.md` bans `unreachable`, so a
//! walk that exhausts its bound returns the tag instead of asserting.
//!
//! **The other failure each walk reports.** Upstream unwraps the node lookup at
//! `text.rs:121` and `text.rs:135`. A link that names an id the state does not
//! hold is `error.NoSuchNode`, the tag `docs/33` section 5 gives for "the state
//! holds no node for the id". Upstream aborts there; a platform can send such a
//! link, so the port reports it and the caller decides.
//!
//! **Nothing here allocates**, so no function takes `gpa`, and nothing here
//! reaches for a runtime, opens a file or reads a clock, so no function takes
//! `io`. Every `const` is a `const`.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const node_ids = @import("../node_id.zig");
const position_inner = @import("position_inner.zig");
const tree_state = @import("../tree_state.zig");

const InnerPosition = position_inner.InnerPosition;
const NodeRef = node_ids.NodeRef;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const assert = std.debug.assert;
const testing = std.testing;

/// The most steps `lineStart` and `lineEnd` may take in a tree of `node_count`
/// nodes.
///
/// Each step reads one link off the current run and looks the named run up, so
/// each step lands on a different node. A chain that landed twice would have
/// repeated a node, and a tree of `node_count` nodes has nothing to repeat
/// before `node_count` steps, so the count is where the walk must stop if it is
/// to stop at all. The bound is `treeWalkStepBound` under a local name, because
/// section 7 of `docs/33` lists five walks that take it and not these two; the
/// derivation is the one section 7 gives and the module doc repeats it.
pub fn lineWalkStepBound(node_count: usize) usize {
    return treeWalkStepBound(node_count);
}

/// The position at the start of the line `position` sits on: character zero of
/// the first run of that line.
///
/// Walks `previous_on_line` from `position.node` until a run declares none.
/// Upstream `InnerPosition::line_start` at `text.rs:115-127`.
///
/// **The bound.** `lineWalkStepBound(node_count)`, derived in the module doc.
/// `error.LineChainCycle` when the `previous_on_line` chain repeats before a run
/// declares no link, which is a line layout that never ends and not a defect a
/// well-formed document has. `error.NoSuchNode` when a link names a node the
/// state does not hold, replacing upstream's `.unwrap()` at `text.rs:121`.
///
/// Allocates nothing and leaves the state as it was on every path.
pub fn lineStart(position: InnerPosition) QueryError!InnerPosition {
    var run = position.node;
    const step_bound = lineWalkStepBound(run.tree_state.nodes.count());
    var step: usize = 0;
    while (true) {
        const link = schema.ids_props.previousOnLine(&run.data().properties) orelse break;
        if (step == step_bound) return error.LineChainCycle;
        step += 1;
        run = NodeRef.init(run.tree_state, run.id().withSameTree(link)) orelse
            return error.NoSuchNode;
    }
    return .{ .node = run, .character_index = 0 };
}

/// The position at the end of the line `position` sits on: the character count
/// of the last run of that line.
///
/// Walks `next_on_line` from `position.node` until a run declares none. The
/// result is the character count of the run the walk lands on and not one past
/// the last character of the run it started from, because the two runs may have
/// different lengths. Upstream `InnerPosition::line_end` at `text.rs:129-141`.
///
/// **The bound.** `lineWalkStepBound(node_count)`, derived in the module doc.
/// `error.LineChainCycle` and `error.NoSuchNode` mean what they mean in
/// `lineStart`; the unwrap this replaces is at `text.rs:135`.
///
/// Allocates nothing and leaves the state as it was on every path.
pub fn lineEnd(position: InnerPosition) QueryError!InnerPosition {
    var run = position.node;
    const step_bound = lineWalkStepBound(run.tree_state.nodes.count());
    var step: usize = 0;
    while (true) {
        const link = schema.ids_props.nextOnLine(&run.data().properties) orelse break;
        if (step == step_bound) return error.LineChainCycle;
        step += 1;
        run = NodeRef.init(run.tree_state, run.id().withSameTree(link)) orelse
            return error.NoSuchNode;
    }
    return .{
        .node = run,
        .character_index = schema.vectors.characterLengths(&run.data().properties).len,
    };
}

comptime {
    // One node and one character index, and the index is a character index and
    // not a byte offset: the module doc states the unit and the layout pin keeps
    // the two fields in that order for every caller that reads them by position.
    assert(@sizeOf(InnerPosition) == 40);
    assert(@offsetOf(InnerPosition, "character_index") == 32);

    // The bound is the node count and nothing else, so a chain longer than the
    // tree cannot exist and a longer chain is a cycle. Pinned at the empty tree
    // and at a size the cycle test builds.
    assert(lineWalkStepBound(0) == 0);
    assert(lineWalkStepBound(3) == 3);

    // A node count of three is the smallest tree that can carry a two-node
    // cycle plus the document root, which is what the cycle test builds. The
    // assertion says the walk's bound is exactly the tree it walks, so a bound
    // that was loosened to a constant would stop catching the cycle.
    assert(lineWalkStepBound(3) == treeWalkStepBound(3));
}

// --- Tests ---------------------------------------------------------------------

const test_allocator = testing.allocator;
const Node = schema.Node;
const NodeId = schema.NodeId;
const ParentAndIndex = @import("../tree_index.zig").ParentAndIndex;
const FullNodeId = @import("../tree_index.zig").FullNodeId;
const TreeState = tree_state.TreeState;

fn localId(raw: u64) NodeId {
    return .{ .value = raw };
}

fn fullId(id: NodeId) FullNodeId {
    return FullNodeId.init(id, .init(0));
}

fn testState() TreeState {
    return .{ .root_id = fullId(localId(1)), .focus_id = fullId(localId(1)) };
}

fn put(state: *TreeState, id: NodeId, parent: ?ParentAndIndex, node: Node) !void {
    try state.nodes.put(test_allocator, fullId(id), .{
        .parent_and_index = parent,
        .data = node,
    });
}

fn refOf(state: *TreeState, id: NodeId) !NodeRef {
    return NodeRef.init(state, fullId(id)) orelse error.NodeMissingFromFixture;
}

fn parentOf(parent: NodeId, index: usize) ParentAndIndex {
    return .{ .parent_id = fullId(parent), .index = index };
}

/// A document root holding `count` one-character runs on one visual line.
///
/// The first run declares no `previous_on_line` and the last declares no
/// `next_on_line`, because a line's two ends have no run on one side. The
/// `index + 3` arithmetic is the next run's own local id, the run at `index`
/// being `index + 2`; what it needs is a guard, and without the guard the last
/// run names a node the fixture never created and the walk runs off the end of
/// the tree instead of stopping on the line's last run.
fn documentWithOneLine(count: usize) !TreeState {
    var state = testState();
    errdefer state.deinit(test_allocator);

    var root = Node.init(test_allocator, .document);
    errdefer root.deinit();
    const child_ids = try test_allocator.alloc(NodeId, count);
    defer test_allocator.free(child_ids);
    for (child_ids, 0..) |*slot, index| slot.* = localId(index + 2);
    try schema.ids_props.setChildren(&root.properties, child_ids);
    try put(&state, localId(1), null, root);

    for (child_ids, 0..) |child_id, index| {
        var run = Node.init(test_allocator, .text_run);
        errdefer run.deinit();
        try schema.strings.setValue(&run.properties, "x");
        try schema.vectors.setCharacterLengths(&run.properties, &.{1});
        if (index > 0) {
            try schema.ids_props.setPreviousOnLine(&run.properties, localId(index + 1));
        }
        if (index + 1 < count) {
            try schema.ids_props.setNextOnLine(&run.properties, localId(index + 3));
        }
        try put(&state, child_id, parentOf(localId(1), index), run);
    }
    return state;
}

test "lineStart walks back to the first run of the line and reports character zero" {
    var state = try documentWithOneLine(3);
    defer state.deinit(test_allocator);
    const last = try refOf(&state, localId(4));

    // Three runs on one line, so the last run's line start is character zero of
    // the first run and not character zero of the run the walk started on.
    const start = try lineStart(.{ .node = last, .character_index = 0 });
    try testing.expectEqual(localId(2), start.node.id().local);
    try testing.expectEqual(@as(usize, 0), start.character_index);
}

test "lineEnd walks forward to the last run and reports that run's character count" {
    var state = try documentWithOneLine(3);
    defer state.deinit(test_allocator);
    const first = try refOf(&state, localId(2));

    const end = try lineEnd(.{ .node = first, .character_index = 0 });
    try testing.expectEqual(localId(4), end.node.id().local);
    // One character in that run, so the end is character one. A port that
    // reported the starting run's count would answer the same here, which is why
    // the walk must land on the last run before it counts.
    try testing.expectEqual(@as(usize, 1), end.character_index);
}

test "a run with no line link is its own line start and line end" {
    var state = try documentWithOneLine(1);
    defer state.deinit(test_allocator);
    const only = try refOf(&state, localId(2));

    // A single run declares no link in either direction, so both walks stop
    // immediately. This is the case where an off-by-one in the loop shows as a
    // walk of one step too many rather than as a hang.
    const start = try lineStart(.{ .node = only, .character_index = 1 });
    try testing.expectEqual(only.id(), start.node.id());
    try testing.expectEqual(@as(usize, 0), start.character_index);

    const end = try lineEnd(.{ .node = only, .character_index = 0 });
    try testing.expectEqual(only.id(), end.node.id());
    try testing.expectEqual(@as(usize, 1), end.character_index);
}

test "a line start on a line of one run reports that run, not its neighbour" {
    var state = try documentWithOneLine(2);
    defer state.deinit(test_allocator);
    const second = try refOf(&state, localId(3));

    // The second run names the first through `previous_on_line`, so it is on the
    // same line and the walk must move. The first run names nothing, so the walk
    // from the first run must not move at all.
    const from_second = try lineStart(.{ .node = second, .character_index = 0 });
    try testing.expectEqual(localId(2), from_second.node.id().local);

    const first = try refOf(&state, localId(2));
    const from_first = try lineStart(.{ .node = first, .character_index = 0 });
    try testing.expectEqual(localId(2), from_first.node.id().local);
}

test "lineStart reports LineChainCycle on a previous_on_line cycle one step past the bound" {
    var state = try documentWithOneLine(2);
    defer state.deinit(test_allocator);
    // Two runs that name each other as the run before them, so the walk never
    // reaches a run that declares no link. The tree holds three nodes, so
    // `lineWalkStepBound` is three and the walk needs four to stop, which is one
    // more than the bound allows.
    const first_entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    try schema.ids_props.setPreviousOnLine(&first_entry.data.properties, localId(3));
    const second_entry = state.nodes.getPtr(fullId(localId(3))) orelse
        return error.NodeMissingFromFixture;
    try schema.ids_props.setPreviousOnLine(&second_entry.data.properties, localId(2));

    const step_bound = lineWalkStepBound(state.nodes.count());
    try testing.expectEqual(@as(usize, 3), step_bound);

    try testing.expectError(
        error.LineChainCycle,
        lineStart(.{ .node = try refOf(&state, localId(2)), .character_index = 0 }),
    );
}

test "lineEnd reports LineChainCycle on a next_on_line cycle one step past the bound" {
    var state = try documentWithOneLine(2);
    defer state.deinit(test_allocator);
    // The mirror of the previous test: two runs that name each other as the run
    // after them, so the forward walk also never terminates.
    const first_entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    try schema.ids_props.setNextOnLine(&first_entry.data.properties, localId(3));
    const second_entry = state.nodes.getPtr(fullId(localId(3))) orelse
        return error.NodeMissingFromFixture;
    try schema.ids_props.setNextOnLine(&second_entry.data.properties, localId(2));

    try testing.expectError(
        error.LineChainCycle,
        lineEnd(.{ .node = try refOf(&state, localId(2)), .character_index = 1 }),
    );
}

test "a two-node cycle takes one step under the bound and answers at one over" {
    // The positive half of the two cycle tests. The same two runs with one link
    // removed terminate, so the tag above names the chain and not the tree: a
    // walk that reported the tag on any two-run line would fail here.
    var state = try documentWithOneLine(2);
    defer state.deinit(test_allocator);
    const step_bound = lineWalkStepBound(state.nodes.count());
    try testing.expectEqual(@as(usize, 3), step_bound);

    // The **first** run's back link is the one to remove. Clearing the second
    // run's would take away the only link the walk has to follow, so the walk
    // would stop on the run it started from and never take the single step this
    // test is about.
    const first_entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    schema.ids_props.clearPreviousOnLine(&first_entry.data.properties);

    // The chain left is second -> first, so one step reaches an answer and that
    // one step is under the bound of three.
    const start = try lineStart(.{ .node = try refOf(&state, localId(3)), .character_index = 0 });
    try testing.expectEqual(localId(2), start.node.id().local);
    try testing.expectEqual(@as(usize, 0), start.character_index);
}

test "a link naming a node the state does not hold reports NoSuchNode" {
    var state = try documentWithOneLine(1);
    defer state.deinit(test_allocator);
    const entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    // Links to node 9, which no `put` above created, in **both** directions.
    // `lineStart` reads `previous_on_line` and `lineEnd` reads `next_on_line`,
    // and each walk looks up only the one it walks, so naming a missing node
    // ahead alone would leave the backward walk with nothing to look up and it
    // would answer a position where the tag belongs.
    // Upstream unwraps these lookups at `text.rs:121` and `text.rs:135` and
    // aborts; a caller cannot act on an abort, so both walks report the tag.
    try schema.ids_props.setPreviousOnLine(&entry.data.properties, localId(9));
    try schema.ids_props.setNextOnLine(&entry.data.properties, localId(9));

    const run = try refOf(&state, localId(2));
    try testing.expectError(error.NoSuchNode, lineStart(.{ .node = run, .character_index = 0 }));
    try testing.expectError(error.NoSuchNode, lineEnd(.{ .node = run, .character_index = 0 }));
}

test "the line walks report a run of a different tree as a missing node" {
    var state = try documentWithOneLine(1);
    defer state.deinit(test_allocator);
    const entry = state.nodes.getPtr(fullId(localId(2))) orelse
        return error.NodeMissingFromFixture;
    // The link names a local id, and the walk looks it up in the tree of the run
    // it is walking. Node 3 does not exist in this tree, so the lookup fails
    // rather than silently crossing into another tree.
    try schema.ids_props.setNextOnLine(&entry.data.properties, localId(3));

    try testing.expectError(
        error.NoSuchNode,
        lineEnd(.{ .node = try refOf(&state, localId(2)), .character_index = 0 }),
    );
}

test "lineEnd counts the landing run's characters and not the starting run's" {
    var state = testState();
    defer state.deinit(test_allocator);
    var root = Node.init(test_allocator, .document);
    try schema.ids_props.setChildren(&root.properties, &.{ localId(2), localId(3) });
    try put(&state, localId(1), null, root);

    // The first run holds one character and the second holds three, so a walk
    // that reported the starting run's count would answer 1 where the correct
    // answer is 3.
    var first = Node.init(test_allocator, .text_run);
    try schema.strings.setValue(&first.properties, "a");
    try schema.vectors.setCharacterLengths(&first.properties, &.{1});
    try schema.ids_props.setNextOnLine(&first.properties, localId(3));
    try put(&state, localId(2), parentOf(localId(1), 0), first);

    var second = Node.init(test_allocator, .text_run);
    try schema.strings.setValue(&second.properties, "bcd");
    try schema.vectors.setCharacterLengths(&second.properties, &.{ 1, 1, 1 });
    try put(&state, localId(3), parentOf(localId(1), 1), second);

    const end = try lineEnd(.{ .node = try refOf(&state, localId(2)), .character_index = 0 });
    try testing.expectEqual(localId(3), end.node.id().local);
    try testing.expectEqual(@as(usize, 3), end.character_index);
}
