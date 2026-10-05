//! The tree state machine one AT-SPI window owns: the materialised tree, the
//! focus flag, the window boxes, and the events an update produced.
//!
//! **Upstream.** `accesskit_atspi_common/src/adapter.rs:352-597` is
//! `PlatformAdapter` and `:30-278` is the `ChangeHandler` it calls.
//! `accesskit_unix/src/adapter.rs:80-244` is the `Adapter` that owns one.
//! `docs/41-atspi-build-map.md` section 2.2 gives this module
//! `adapter.rs:352-597`, and section 1.7 records the events it raises.
//!
//! **What this module decides.** An update arrives as a whole `TreeUpdate`, the
//! consumer layer folds it into a tree, and the consumer layer then reports
//! what changed through four slots. This module turns each of those four
//! reports into AT-SPI events, and nothing else. It holds no D-Bus connection,
//! reads no clock and takes no `std.Io`, so a test drives every branch of it
//! with a fixture tree and no bus.
//!
//! **The four reports, and the event each produces.**
//!
//! | Consumer report | Event raised |
//! |---|---|
//! | node added | `Cache.AddAccessible` on the cache object, naming the node |
//! | node updated | `Object.BoundsChanged` on the node, when the box moved |
//! | node removed | `Cache.RemoveAccessible` on the cache object, naming the node |
//! | focus moved | `Object.Focus` on the new node and on the old one |
//!
//! **The gaps, written down rather than hidden.** Three, and a reader of this
//! file must not have to guess at them.
//!
//! 1. **No `StateChanged`.** A `StateChanged` needs the forty-three-value
//!    `wire.StateSet` the AT-SPI reference numbers, which is the role and state
//!    mapping at `node.rs:87-443` upstream. That mapping is **not ported**;
//!    `node.zig` is the module that owns it upstream and it does not exist here.
//!    A node that gains focus therefore raises `Focus` and not the
//!    `StateChanged` a client would use to learn `STATE_FOCUSABLE`.
//! 2. **No `ChildrenChanged`, `Announcement` or `TextChanged`.** The same
//!    mapping is what tells the adapter that a node has children worth
//!    announcing and that a live region became polite or assertive.
//! 3. **No inbound member dispatch.** `Accessible.GetRole`,
//!    `Component.GetExtents` and the other answers live in `interfaces/*.zig`
//!    upstream and are **not ported**. They need the same D-Bus connection the
//!    events need, so both are blocked on the same missing dependency.
//!
//! **Why the events are collected rather than raised.** Upstream raises each
//! event the moment it produces it. This module has no connection to raise it
//! on, so it leaves every event in `raised`. That is the whole of the
//! difference, and it is what lets a test assert that an update produced
//! exactly these three events in this order without a bus daemon.
//! `EventQueue.drainInto` is how a caller takes them.
//!
//! **The failure a change slot cannot return.** A `TreeChangeHandler` slot has
//! the signature `fn (*anyopaque, NodeRef) void`. It may not fail, because the
//! consumer layer calls it while it holds a half-applied update and has no way
//! to unwind one event's failure. Appending to the queue can, so the slot
//! records the first failure in `slot_error` and the caller reads it after the
//! operation returns. That is why no error is discarded: `apply` and
//! `updateWindowFocusState` clear the slot before they start and copy it into
//! `last_event_error` before they return.
//!
//! **Every loop in this module is bounded, and by what.**
//!
//! | Walk | Bound |
//! |---|---|
//! | `announceWholeTree` over the first update's tree | `nodes.count()`, the map's own length |
//! | the four change slots | the number of nodes one update named |
//! | the event queue | `raised.items.items.len`, the bound `events.EventQueue` names |
//!
//! The four change slots are driven by the consumer layer and cannot be bounded
//! here, so the bound is the property of the update that reached them: one
//! update names each node it adds, updates or removes at most once, which is
//! `docs/33` invariant I1 and the reason the consumer layer accepts the update
//! at all. The count is `update.nodes.items.len`, read before the update is
//! transferred.

const std = @import("std");

const boundary = @import("../../capi/boundary.zig");
const consumer = @import("../../consumer/root.zig");
const tree_index = @import("../../consumer/tree_index.zig");
const schema = @import("../../schema/root.zig");
const events = @import("events.zig");
const object_id = @import("object_id.zig");
const window_bounds = @import("window_bounds.zig");

const CRect = boundary.CRect;
const CTreeUpdate = boundary.CTreeUpdate;
const FullNodeId = tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const Rect = schema.Rect;
const Tree = consumer.tree.Tree;
const TreeChangeHandler = consumer.tree.TreeChangeHandler;
const ObjectId = object_id.ObjectId;

/// The failures a tree operation on this adapter reports.
///
/// It is the consumer layer's own set merged with the geometry conversion's,
/// and it is declared here rather than in either module because the set a
/// caller of this module catches is not either module's set alone.
pub const AdapterError = consumer.tree.UpdateError || window_bounds.GeometryError;

/// One AT-SPI window's tree, its focus flag, its boxes and the events its last
/// update produced.
///
/// The value owns the tree, the allocator and the event queue. It has no copy
/// operation, because two owners of one tree release it twice, so the only way
/// to hand one to a callee is a pointer.
///
/// **The adapter number is part of every node path.** `id` is what
/// `object_id.ObjectId` puts in the middle of every node path, and two windows
/// that shared a number would have their nodes share a path. It is a parameter
/// of `init` and not a counter this module owns, because a module that generates
/// it holds global state; `root.zig` says who supplies it.
pub const PlatformAdapter = struct {
    /// The allocator every buffer under this value was grown with and the only
    /// one any release goes through.
    gpa: std.mem.Allocator,
    /// The number that separates this window's node paths from every other
    /// window's.
    id: usize,
    /// The materialised tree, or `null` until the first update builds it.
    /// Upstream builds the tree in `PlatformAdapter::new`, which the C ABI calls
    /// with no update in hand, so the port builds it on the first one.
    tree: ?Tree,
    /// The root window's two boxes.
    bounds: window_bounds.WindowBounds,
    /// Whether the window holds focus. The consumer tree holds its own copy and
    /// this one survives the tree so `debug` can report it.
    is_host_focused: bool,
    /// The events the last operation produced, oldest first.
    raised: events.EventQueue,
    /// How many updates have been folded into `tree`, including the one that
    /// built it.
    applied_updates: u64,
    /// The first failure one of the four change slots hit, or `null`. A caller
    /// reads it after every `apply` and every `updateWindowFocusState`.
    last_event_error: ?AdapterError,

    /// The first failure one of the four change slots hit during the operation
    /// now running. It is cleared at the head of every operation and copied
    /// into `last_event_error` at the end of one, because a slot may not
    /// return a failure and the caller reads exactly one field.
    slot_error: ?AdapterError = null,

    /// Builds an adapter with no tree, no focus and no boxes. Upstream
    /// `PlatformAdapter::new`.
    ///
    /// **Errors.** This function does not fail.
    pub fn init(
        gpa: std.mem.Allocator,
        id: usize,
        is_host_focused: bool,
    ) PlatformAdapter {
        return .{
            .gpa = gpa,
            .id = id,
            .tree = null,
            .bounds = window_bounds.WindowBounds.empty,
            .is_host_focused = is_host_focused,
            .raised = events.EventQueue.empty(),
            .applied_updates = 0,
            .last_event_error = null,
        };
    }

    /// Releases the tree and the events, exactly once. A second call releases
    /// nothing, because the reset leaves empty containers behind.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *PlatformAdapter) void {
        if (self.tree) |*tree| tree.deinit();
        self.tree = null;
        self.raised.deinit(self.gpa);
        const gpa = self.gpa;
        self.* = init(gpa, 0, false);
    }

    /// Whether a tree has been built. An adapter with no tree answers nothing
    /// to a member call, which is upstream's `Defunct` case.
    ///
    /// **Errors.** This function does not fail.
    pub fn hasTree(self: *const PlatformAdapter) bool {
        return self.tree != null;
    }

    /// How many nodes the committed tree holds, or zero when there is none.
    ///
    /// **Errors.** This function does not fail.
    pub fn nodeCount(self: *const PlatformAdapter) usize {
        const tree = self.tree orelse return 0;
        return tree.stateOf().nodes.count();
    }

    /// Records `outer` and `inner` as the root window's boxes, which is what
    /// `accesskit_unix_adapter_set_root_window_bounds` does.
    ///
    /// Upstream stores the pair in `WindowBounds` and every `GetExtents` answer
    /// reads it back. This module stores it and raises nothing, because a
    /// change to the window's box is not an event the reference defines.
    ///
    /// **Errors.** This function does not fail.
    pub fn setRootWindowBounds(self: *PlatformAdapter, outer: CRect, inner: CRect) void {
        self.bounds.set(outer, inner);
    }

    /// Records whether the window holds focus and lets the consumer tree commit
    /// the change, which raises `focus_moved` and so a `Focus` event.
    ///
    /// An adapter with no tree records the flag and raises nothing: there is no
    /// focus to move, which is upstream's behaviour too.
    ///
    /// **Errors.** `error.OutOfMemory` from the consumer layer's commit.
    pub fn updateWindowFocusState(self: *PlatformAdapter, is_host_focused: bool) !void {
        self.is_host_focused = is_host_focused;
        if (self.tree) |*tree| {
            self.slot_error = null;
            try tree.updateHostFocusStateAndProcessChanges(is_host_focused, &self.changeHandler());
            self.last_event_error = self.slot_error;
        }
    }

    /// Folds `update` into the tree and collects the events it produced.
    ///
    /// `update` is transferred in and released by the consumer layer on every
    /// path, so the caller's binding is spent and must not be released again.
    ///
    /// The first update builds the tree; every later one applies to it. An
    /// update naming a subtree the tree does not hold is rejected by the
    /// consumer layer, and this module does not soften that.
    ///
    /// **Errors.** `error.OutOfMemory` and the consumer layer's `UpdateError`
    /// set. `last_event_error` carries a failure one of the four change slots
    /// hit, which the caller reads after this returns.
    pub fn apply(self: *PlatformAdapter, update: CTreeUpdate) !void {
        self.slot_error = null;
        self.last_event_error = null;
        if (self.tree == null) {
            var built = try Tree.init(self.gpa, update, self.is_host_focused);
            errdefer built.deinit();
            self.tree = built;
            self.applied_updates = 1;
            // The first update builds the whole tree, and the consumer layer
            // reports that as a commit rather than as node additions, so the
            // cache entries the tree needs are announced here from the tree
            // itself. Upstream raises them from `PlatformAdapter::new` for the
            // same reason.
            self.announceWholeTree();
            self.last_event_error = self.slot_error;
            return;
        }
        const tree = &self.tree.?;
        try tree.updateAndProcessChanges(update, &self.changeHandler());
        self.applied_updates += 1;
        self.last_event_error = self.slot_error;
    }

    /// The identifier for the node `id` names in this adapter.
    ///
    /// `id` is taken as `anytype` and must answer `toU128`, which is what
    /// `object_id.ObjectId` needs from a `FullNodeId`. A generic parameter is
    /// not an import edge, so this module still names no consumer type it does
    /// not already name.
    ///
    /// **Errors.** This function does not fail.
    pub fn objectId(self: *const PlatformAdapter, id: anytype) ObjectId {
        return .{ .node = .{ .adapter = self.id, .node = id } };
    }

    /// The four change slots, bound to this adapter.
    ///
    /// **Errors.** This function does not fail.
    fn changeHandler(self: *PlatformAdapter) TreeChangeHandler {
        return .{
            .ptr = @ptrCast(self),
            .node_added = onNodeAdded,
            .node_updated = onNodeUpdated,
            .node_removed = onNodeRemoved,
            .focus_moved = onFocusMoved,
        };
    }

    /// Announces every node of the tree the first update built, as one cache
    /// event each, in the order the store holds them.
    ///
    /// The bound is `nodes.count()`, which is the map's own length and does not
    /// change while the walk runs.
    ///
    /// **Errors.** This function does not fail. A failure inside the queue is
    /// recorded in `slot_error` by `record`.
    fn announceWholeTree(self: *PlatformAdapter) void {
        const tree = self.tree orelse return;
        var ids = tree.stateOf().nodes.iterator();
        while (ids.next()) |entry| {
            const id = entry.key_ptr.*;
            self.record(cacheEvent(
                self.gpa,
                self.id,
                id,
                events.member_add_accessible,
            ) catch |err| {
                self.noteSlotFailure(err);
                continue;
            });
        }
    }

    /// Appends one event.
    ///
    /// **Errors.** This function does not fail. An allocation failure is stored
    /// in `slot_error` and copied into `last_event_error` by the caller.
    fn record(self: *PlatformAdapter, event: events.Event) void {
        self.raised.push(self.gpa, event) catch |err| self.noteSlotFailure(err);
    }

    /// Stores the first failure and leaves any later one alone.
    ///
    /// Leaving the later ones is not discarding them: the first is the cause and
    /// the rest follow from the same exhausted allocator, so one tag is the
    /// whole of the information.
    ///
    /// **Errors.** This function does not fail.
    fn noteSlotFailure(self: *PlatformAdapter, failure: AdapterError) void {
        if (self.slot_error == null) self.slot_error = failure;
    }

    /// The adapter that `ptr` names. Every slot below casts through this, so the
    /// cast appears once rather than four times.
    ///
    /// **Errors.** This function does not fail.
    fn adapterOf(ptr: *anyopaque) *PlatformAdapter {
        return @ptrCast(@alignCast(ptr));
    }
};

/// The cache event that adds or removes one node.
///
/// `gpa` is a parameter and not used, because the event borrows everything it
/// names and allocates nothing. It is there so a caller reads the same shape
/// as every other allocating function in this module and is marked by the
/// compiler rather than by a comment.
fn cacheEvent(
    gpa: std.mem.Allocator,
    adapter: usize,
    id: anytype,
    member: [:0]const u8,
) error{OutOfMemory}!events.Event {
    _ = gpa;
    return .{
        .kind = .cache,
        .member = member,
        // The cache signals go out on the cache object, and the node they are
        // about rides in the variant because `siiva{sv}` has no `(so)` argument.
        .id = .cache,
        .any_data = .{ .address = .{ .node = .{ .adapter = adapter, .node = id } } },
    };
}

/// One node entered the tree, so the cache gains it.
fn onNodeAdded(ptr: *anyopaque, node: NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    self.record(cacheEvent(
        self.gpa,
        self.id,
        node.id(),
        events.member_add_accessible,
    ) catch |err| {
        self.noteSlotFailure(err);
        return;
    });
}

/// One node left the tree, so the cache loses it.
fn onNodeRemoved(ptr: *anyopaque, node: NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    self.record(cacheEvent(
        self.gpa,
        self.id,
        node.id(),
        events.member_remove_accessible,
    ) catch |err| {
        self.noteSlotFailure(err);
        return;
    });
}

/// One node was rewritten, which raises `BoundsChanged` and only when the box
/// moved.
fn onNodeUpdated(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    const before = schema.option.bounds(&old.data().properties);
    const after = schema.option.bounds(&new.data().properties);
    const reason = reasonFor(before, after);
    if (reason == .unchanged) return;
    var members: events.AnyData = .none;
    if (after) |box| {
        const extent = window_bounds.toWire(box) catch |err| {
            self.noteSlotFailure(err);
            return;
        };
        members = events.AnyData{ .extent = extent };
    }
    self.record(.{
        .kind = .object,
        .member = events.member_bounds_changed,
        .id = self.objectId(new.id()),
        // The reference declares this argument as a string and a client matches
        // it against "1" and "2", so it is decimal text and not an integer.
        .detail1 = reason.text(),
        .any_data = members,
    });
}

/// Why a box moved, which is what the first argument of `BoundsChanged` names.
pub const BoundsReason = enum {
    /// Nothing moved. The consumer layer reported the node because something
    /// else about it changed, and `BoundsChanged` is not the signal for that.
    unchanged,
    /// Only the extents moved.
    size,
    /// Only the origin moved.
    location,
    /// Both moved. The reference has no single reason for this, so the port
    /// reports the one a client acts on first, which is the size.
    both,

    /// The decimal text the reference spells this reason with.
    ///
    /// **Errors.** This function does not fail.
    pub fn text(self: BoundsReason) []const u8 {
        return switch (self) {
            .unchanged, .size, .both => events.bounds_reason_size,
            .location => events.bounds_reason_location,
        };
    }
};

/// Why the box moved from `before` to `after`, or `.unchanged` when it did not.
///
/// **Errors.** This function does not fail.
pub fn reasonFor(before: ?Rect, after: ?Rect) BoundsReason {
    const was = before orelse return if (after == null) .unchanged else .size;
    const now = after orelse return .size;
    const origin_moved = was.x0 != now.x0 or was.y0 != now.y0;
    const size_moved = was.width() != now.width() or was.height() != now.height();
    // The four cases are written out rather than taken from a two-object switch
    // on a pair of booleans, because Zig 0.16.0 no longer parses one and a
    // reader of this function should be able to see the four combinations
    // without knowing that.
    if (origin_moved) return if (size_moved) .both else .location;
    if (size_moved) return .size;
    return .unchanged;
}

/// The focus moved, which raises `Focus` on the new node and on the old one.
///
/// `Focus` names the node that holds focus now, so both events carry the same
/// address in their variant. A focus that was lost leaves no new node and
/// raises nothing, because `siiva{sv}` has no argument that could carry "none"
/// and a `Focus` with an empty variant says nothing a client can act on.
///
/// **Errors.** This function does not fail. A failure inside the queue is
/// recorded in `slot_error`.
fn onFocusMoved(ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    const target = new orelse return;
    const address: events.AnyData = .{ .address = self.objectId(target.id()) };

    self.record(.{
        .kind = .object,
        .member = events.member_focus,
        .id = self.objectId(target.id()),
        .any_data = address,
    });
    if (old) |previous| {
        if (std.meta.eql(previous.id(), target.id())) return;
        self.record(.{
            .kind = .object,
            .member = events.member_focus,
            .id = self.objectId(previous.id()),
            .any_data = address,
        });
    }
}

const testing = std.testing;

/// Builds one update that names `count` nodes in a chain, with `root` first.
///
/// The root node's id is `1` and every child follows it, which is the shape a
/// tree takes when an application pushes one button.
fn chainUpdate(gpa: std.mem.Allocator, count: u64) !CTreeUpdate {
    var update: CTreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    errdefer update.deinit(gpa);

    // A node lists its children, so node `n` lists node `n + 1`. Building the
    // list the other way round leaves the last node naming no parent, and the
    // consumer layer rejects that as an orphan.
    var index: u64 = 1;
    while (index <= count) : (index += 1) {
        var node = schema.Node.init(gpa, if (index == 1) .window else .button);
        if (index < count) {
            try schema.ids_props.setChildren(&node.properties, &.{.{ .value = index + 1 }});
        }
        try update.pushNode(gpa, .{ .value = index }, node);
    }
    return update;
}

test "an adapter starts with no tree, no nodes and no focus" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 0, false);
    defer adapter.deinit();

    try testing.expect(!adapter.hasTree());
    try testing.expectEqual(@as(usize, 0), adapter.nodeCount());
    try testing.expectEqual(@as(u64, 0), adapter.applied_updates);
    try testing.expect(adapter.last_event_error == null);
}

test "the first update builds the tree and announces every node" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 2, false);
    defer adapter.deinit();

    try adapter.apply(try chainUpdate(gpa, 3));

    try testing.expect(adapter.hasTree());
    try testing.expectEqual(@as(usize, 3), adapter.nodeCount());
    try testing.expectEqual(@as(u64, 1), adapter.applied_updates);

    // One cache event per node, all on the cache object and all naming a node.
    try testing.expectEqual(@as(usize, 3), adapter.raised.count());
    for (adapter.raised.items.items) |event| {
        try testing.expectEqual(events.Kind.cache, event.kind);
        try testing.expectEqualStrings(events.member_add_accessible, event.member);
        const cache: ObjectId = .cache;
        try testing.expect(std.meta.eql(cache, event.id));
    }
}

test "a second update is folded into the tree the first one built" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 0, false);
    defer adapter.deinit();

    try adapter.apply(try chainUpdate(gpa, 2));
    var taken: std.ArrayList(events.Event) = .empty;
    defer taken.deinit(gpa);
    try adapter.raised.drainInto(gpa, &taken);

    try adapter.apply(try chainUpdate(gpa, 3));

    try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
    try testing.expectEqual(@as(usize, 3), adapter.nodeCount());
    // The second update added one node and rewrote the two it already held, so
    // the cache event is the only one it raises.
    try testing.expectEqual(@as(usize, 1), adapter.raised.count());
    try testing.expectEqualStrings(
        events.member_add_accessible,
        adapter.raised.items.items[0].member,
    );
}

test "a node whose box moved raises BoundsChanged and names the reason" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 1, false);
    defer adapter.deinit();

    var update: CTreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    var node = schema.Node.init(gpa, .button);
    try schema.option.setBounds(&node.properties, schema.rectInit(0, 0, 10, 10));
    try update.pushNode(gpa, .{ .value = 1 }, node);
    try adapter.apply(update);
    var taken: std.ArrayList(events.Event) = .empty;
    defer taken.deinit(gpa);
    try adapter.raised.drainInto(gpa, &taken);

    // The same box under a different node is an update that moves nothing, and
    // a `BoundsChanged` for it would make a client repaint for no reason.
    var still: CTreeUpdate = .{ .focus = .{ .value = 1 } };
    var same = schema.Node.init(gpa, .button);
    try schema.option.setBounds(&same.properties, schema.rectInit(0, 0, 10, 10));
    try still.pushNode(gpa, .{ .value = 1 }, same);
    try adapter.apply(still);
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());

    // A different extent is a size change, and the new box rides in the variant
    // because `siiva{sv}` has no argument of type `(iiii)`.
    var moved: CTreeUpdate = .{ .focus = .{ .value = 1 } };
    var wider = schema.Node.init(gpa, .button);
    try schema.option.setBounds(&wider.properties, schema.rectInit(0, 0, 20, 10));
    try moved.pushNode(gpa, .{ .value = 1 }, wider);
    try adapter.apply(moved);

    try testing.expectEqual(@as(usize, 1), adapter.raised.count());
    const raised = adapter.raised.items.items[0];
    try testing.expectEqualStrings(events.member_bounds_changed, raised.member);
    try testing.expectEqualStrings(events.bounds_reason_size, raised.detail1);
    try testing.expectEqualStrings("(iiii)", raised.any_data.signature());
    const extent = raised.any_data.extent;
    try testing.expectEqual(@as(i32, 20), extent[2]);
}

test "a node that only moved raises the location reason" {
    try testing.expectEqual(BoundsReason.unchanged, reasonFor(null, null));
    try testing.expectEqual(BoundsReason.size, reasonFor(null, schema.rectInit(0, 0, 1, 1)));
    try testing.expectEqual(BoundsReason.size, reasonFor(schema.rectInit(0, 0, 1, 1), null));
    try testing.expectEqual(
        BoundsReason.unchanged,
        reasonFor(schema.rectInit(0, 0, 4, 4), schema.rectInit(0, 0, 4, 4)),
    );
    try testing.expectEqual(
        BoundsReason.size,
        reasonFor(schema.rectInit(0, 0, 4, 4), schema.rectInit(0, 0, 8, 4)),
    );
    try testing.expectEqual(
        BoundsReason.location,
        reasonFor(schema.rectInit(0, 0, 4, 4), schema.rectInit(5, 0, 9, 4)),
    );
    try testing.expectEqual(
        BoundsReason.both,
        reasonFor(schema.rectInit(0, 0, 4, 4), schema.rectInit(5, 6, 9, 9)),
    );
}

test "the reason text is the decimal the reference spells" {
    try testing.expectEqualStrings("1", BoundsReason.size.text());
    try testing.expectEqualStrings("2", BoundsReason.location.text());
    try testing.expectEqualStrings("1", BoundsReason.both.text());
    try testing.expectEqualStrings("1", BoundsReason.unchanged.text());
}

test "the window focus flag raises Focus on the node that holds it" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 4, false);
    defer adapter.deinit();

    try adapter.apply(try chainUpdate(gpa, 2));
    var taken: std.ArrayList(events.Event) = .empty;
    defer taken.deinit(gpa);
    try adapter.raised.drainInto(gpa, &taken);

    try adapter.updateWindowFocusState(true);

    // The tree's focus is its root when no node claims it, so the focus lands
    // on the root and exactly one `Focus` is raised.
    try testing.expectEqual(@as(usize, 1), adapter.raised.count());
    const raised = adapter.raised.items.items[0];
    try testing.expectEqualStrings(events.member_focus, raised.member);
    try testing.expectEqualStrings("(so)", raised.any_data.signature());
    try testing.expect(adapter.is_host_focused);
}

test "an adapter with no tree records the focus flag and raises nothing" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 0, false);
    defer adapter.deinit();

    try adapter.updateWindowFocusState(true);

    try testing.expect(adapter.is_host_focused);
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());
}

test "the window boxes are stored as they were reported" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 0, false);
    defer adapter.deinit();

    adapter.setRootWindowBounds(
        schema.rectInit(0, 0, 800, 600),
        schema.rectInit(0, 30, 800, 600),
    );

    try testing.expectEqual(@as(f64, 600), adapter.bounds.outer.height());
    try testing.expectEqual(@as(f64, 570), adapter.bounds.viewportSize().height);
}

test "two adapters number their node paths apart" {
    const gpa = std.testing.allocator;
    var first = PlatformAdapter.init(gpa, 0, false);
    defer first.deinit();
    var second = PlatformAdapter.init(gpa, 1, false);
    defer second.deinit();

    const node_id = FullNodeId.init(.{ .value = 7 }, .init(0));

    const one = try first.objectId(node_id).path(gpa);
    defer gpa.free(one);
    const other = try second.objectId(node_id).path(gpa);
    defer gpa.free(other);

    // The adapter number is the only thing that differs, and it is the whole of
    // the difference: two windows that shared it would share a node path.
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/0/7", one);
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/1/7", other);
}

test "releasing twice releases nothing the second time" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 0, false);

    try adapter.apply(try chainUpdate(gpa, 2));
    adapter.deinit();
    adapter.deinit();

    try testing.expect(!adapter.hasTree());
}
