//! The one filter the Windows adapter walks with.
//!
//! **What this file ports.** `adapters/windows/src/filters.rs:1-8` in the
//! pinned upstream tree, which is 8 lines and exports two names:
//! `common_filter as filter` and `common_filter_with_root_exception as
//! filter_with_root_exception`, both re-exported from `accesskit_consumer`.
//! The port keeps the two names and points them at the port's own consumer
//! half, so the adapter and the consumer walk the tree the same way.
//!
//! **Why this file exists at all.** Upstream re-exports because the adapter
//! names `filter` at twenty-odd call sites and the two spellings are the
//! whole of the filtering vocabulary. The port keeps the file so those sites
//! read the same, and so a reader who holds the upstream line numbers finds
//! the same two names in the same place.
//!
//! **The one difference from upstream.** Upstream's `filter` is a bare
//! function of a `NodeRef`. The port's `commonFilter` takes a `NodeRef` and
//! returns `QueryError!FilterResult`, because a ported walk can hit its
//! cycle bound where a Rust walk panics. Both outcomes reach the adapter as
//! `error.QueryError`, which the caller handles rather than ignores.

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

/// The outcome of one filter test: keep the node, drop the node, or drop the
/// node and its subtree.
pub const FilterResult = consumer.filter.FilterResult;

/// The filter the adapter walks with.
///
/// A caller holds one of these by value. Its `context` is `null` because the
/// Windows filter reads only the node, and upstream has the same shape.
pub const filter_fn: consumer.filter.FilterFn = .{
    .context = null,
    .filter = commonFilterTrampoline,
};

/// Whether a node and its subtree are exposed to UI Automation.
///
/// Upstream `common_filter`, re-exported at `filters.rs:6-7` as `filter`.
///
/// `error.QueryError` reaches the caller unchanged. Nothing is written, so the
/// tree is the same before and after the call.
pub fn filter(node: consumer.node_id.NodeRef) consumer.tree.QueryError!FilterResult {
    return consumer.filter.commonFilter(node);
}

/// Whether a node and its subtree are exposed, with the root always kept.
///
/// Upstream `common_filter_with_root_exception`, re-exported at `filters.rs:7`
/// as `filter_with_root_exception`. The adapter uses it where the root must
/// survive even when the common filter would drop it, which is every place a
/// window names itself.
///
/// `error.QueryError` reaches the caller unchanged.
pub fn filterWithRootException(
    node: consumer.node_id.NodeRef,
) consumer.tree.QueryError!FilterResult {
    return consumer.filter.commonFilterWithRootException(node);
}

/// The steps the common filter may walk.
///
/// Upstream `common_filter` is bounded by the parent chain, and the port's
/// bound is `treeWalkStepBound` from `tree_state.zig`, which is derived in
/// that module's doc. The adapter reads it through this name so a walk over
/// an unknown node count cannot pick a bound of its own.
pub fn filterStepBound(node_count: usize) usize {
    return consumer.filter.commonFilterStepBound(node_count);
}

/// Adapts the bare function to the two-parameter shape `FilterFn` declares.
fn commonFilterTrampoline(
    context: ?*anyopaque,
    node: consumer.node_id.NodeRef,
) consumer.tree.QueryError!FilterResult {
    std.debug.assert(context == null);
    return filter(node);
}

const std = @import("std");

// --- Tests -----------------------------------------------------------------

test "the filter value answers for the node it is given" {
    // The value is what the adapter walks with, so a test drives it with a
    // real node from a real tree. A window is the one role the common filter
    // always keeps, so the answer is fixed and a filter that ignored the node
    // would answer the same for a role that is dropped.
    const gpa = std.testing.allocator;
    // `Tree.init` takes the update by value and releases it on every path, so
    // there is no `deinit` here: the binding is spent either way.
    var update: schema.TreeUpdate = .{};
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };

    var tree = consumer.tree.Tree.init(gpa, update, true) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => return error.TreeRejectedTheUpdate,
    };
    defer tree.deinit();

    const state = tree.stateOf();
    const node = state.nodeById(state.rootId()) orelse return error.MissingRootNode;
    const outcome = try filter_fn.call(node);
    try std.testing.expectEqual(consumer.filter.FilterResult.include, outcome);
}

test "the step bound is the node count the consumer half names" {
    // `treeWalkStepBound` is the identity on the node count
    // (`consumer/tree_state.zig:603-605`), so the adapter's bound is the node
    // count and a filter walk over `n` nodes takes at most `n` steps. The test
    // pins the values rather than the ordering, because an ordering assertion
    // passes for a bound that is too small.
    try std.testing.expectEqual(@as(usize, 1), filterStepBound(1));
    try std.testing.expectEqual(@as(usize, 64), filterStepBound(64));
    try std.testing.expectEqual(@as(usize, 0), filterStepBound(0));
}
