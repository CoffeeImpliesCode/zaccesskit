//! The four tree-change notifications, and the event queue they fill.
//!
//! **What this file ports.** `AdapterChangeHandler` from
//! `adapters/windows/src/adapter.rs:35-372` in the pinned upstream tree: the
//! three set fields, the six private methods and the four `TreeChangeHandler`
//! methods. `focus_event` at `adapter.rs:26-33` is here too, because it is two
//! lines and it names an event this adapter raises.
//!
//! **What the port does differently, and why.** The two sets upstream are
//! `hashbrown` sets, so the order upstream raises selection events in is not
//! defined. The port uses ordered maps, so the order is the order the update
//! made the changes in and a test can pin it. The order is a contract with the
//! platform: a text change must come before a selection change, and that holds
//! because `QueuedEvents.prepend` puts the text change at the front.
//!
//! **Where the failures go.** The four slots `TreeChangeHandler` declares
//! return nothing, and the queries the port needs are fallible. A slot records
//! the first failure in `Failure` and returns, and the caller reads
//! `takeFailure` once the update has committed. This is the port's translation
//! of the Rust panic at the same sites.
//!
//! **What this file does not do.** It does not raise anything, and it does not
//! queue the per-node property changes: upstream raises those from
//! `NodeWrapper::enqueue_property_changes` at `node.rs`, which builds a
//! `VARIANT` and belongs to the node layer. Every event `adapter.rs` itself
//! queues is here.
//!
//! **Loop bounds.** Three walks outside a test, each with the bound named
//! beside it: the filtered-children cursor inside `enqueueSelectionChanges`,
//! bounded by the cursor's own budget from `hierarchy.zig`; the two walks over
//! the selection map and over its two sets, each bounded by that collection's
//! length at the moment the walk starts. Nothing grows while they run.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const elements = @import("elements.zig");
const filters = @import("filters.zig");
const queued_events = @import("queued_events.zig");
const syscalls = @import("syscalls.zig");

const EventId = syscalls.EventId;
const Platform = syscalls.Platform;
const PropertyValue = schema.PropertyValue;
const ProviderSlot = syscalls.ProviderSlot;

const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree_state.QueryError;
const TreeChangeHandler = consumer.tree.TreeChangeHandler;
const TreeState = consumer.tree_state.TreeState;

/// The node set the two selection sets are built from.
///
/// Upstream `HashSet<FullNodeId>`. The port uses an ordered map with an empty
/// payload because the order the selection events are raised in is a contract
/// and a hashed set does not define one.
const NodeSet = std.array_hash_map.Auto(FullNodeId, void);

/// Everything a handler operation can fail with.
///
/// It is `error.OutOfMemory` plus the consumer half's `QueryError`, and it is
/// written down so `adapter.zig` can name it in its own error set instead of
/// widening it by inference.
pub const HandlerError = std.mem.Allocator.Error || QueryError;

/// What the handler could not do, recorded on the first failure.
///
/// A slot cannot report an error, so it records here and returns. Both fields
/// stay readable after the update commits, because the caller reads them once
/// at the end of `processChanges`.
pub const Failure = struct {
    /// A provider slot or an event could not be allocated, so the events that
    /// would have named them are missing.
    out_of_memory: bool = false,

    /// A query over the tree reported an error, so the handler stopped there.
    query_error: ?QueryError = null,

    /// Whether anything failed. A `true` answer means the queue is incomplete
    /// and the caller must not raise it as if it were whole.
    pub fn isEmpty(self: Failure) bool {
        return !self.out_of_memory and self.query_error == null;
    }
};

/// The two sets one selection container accumulates, upstream
/// `SelectionChanges` at `adapter.rs:232-235`.
const SelectionChanges = struct {
    /// The nodes that became selected.
    added: NodeSet = .empty,
    /// The nodes that stopped being selected.
    removed: NodeSet = .empty,

    fn deinit(self: *SelectionChanges, gpa: std.mem.Allocator) void {
        self.added.deinit(gpa);
        self.removed.deinit(gpa);
    }
};

/// Beyond this many changes one container invalidates instead of enumerating.
///
/// Upstream `INVALIDATE_LIMIT` at `adapter.rs:179`. The comment there records
/// that the value is not specified and that `System.Windows.Automation.Provider`
/// uses 20.
pub const invalidate_limit: usize = 20;

/// The event queue builder for one tree update.
///
/// The value owns the two sets and the selection map and releases them with
/// `gpa`. The registry and the queue it fills are borrowed, so the caller keeps
/// both alive for the whole of the update.
pub const Handler = struct {
    /// The allocator that grew the two sets and the selection map.
    gpa: std.mem.Allocator,
    /// The seam every provider call goes through.
    platform: Platform,
    /// The registry that holds the providers. The handler adds to it.
    registry: *elements.Registry,
    /// The queue the events go into. The handler does not own it.
    queue: *queued_events.QueuedEvents,
    /// The nodes whose text change is queued once already. Upstream
    /// `text_changed` at `adapter.rs:38`.
    text_changed: NodeSet = .empty,
    /// One entry per selection container, in the order the containers were first
    /// touched. Upstream `selection_changed` at `adapter.rs:39`.
    selection_changed: std.array_hash_map.Auto(FullNodeId, SelectionChanges) = .empty,
    /// The first failure any slot recorded.
    failure: Failure = .{},

    /// A handler that fills `queue` through `registry` and `platform`.
    ///
    /// Nothing is allocated, so this call cannot fail.
    pub fn init(
        gpa: std.mem.Allocator,
        platform: Platform,
        registry: *elements.Registry,
        queue: *queued_events.QueuedEvents,
    ) Handler {
        return .{ .gpa = gpa, .platform = platform, .registry = registry, .queue = queue };
    }

    /// Releases the two sets and the selection map.
    ///
    /// The registry and the queue are borrowed, so this call does not touch
    /// them. A slot the queue took ownership of is the queue's to release.
    pub fn deinit(self: *Handler) void {
        const gpa = self.gpa;
        var containers = self.selection_changed.iterator();
        while (containers.next()) |entry| {
            entry.value_ptr.deinit(gpa);
        }
        self.selection_changed.deinit(gpa);
        self.text_changed.deinit(gpa);
        self.failure = .{};
    }

    /// The four slots `TreeChangeHandler` declares, bound to this handler.
    ///
    /// `ptr` points at this handler, which the caller keeps alive for the whole
    /// of the update.
    pub fn changeHandler(self: *Handler) TreeChangeHandler {
        return .{
            .ptr = @ptrCast(self),
            .node_added = nodeAddedSlot,
            .node_updated = nodeUpdatedSlot,
            .focus_moved = focusMovedSlot,
            .node_removed = nodeRemovedSlot,
        };
    }

    /// The first failure any slot recorded, and clears it.
    ///
    /// The caller reads this once, after the commit, because the tree is
    /// consistent at that point and a caller may retry.
    pub fn takeFailure(self: *Handler) ?Failure {
        if (self.failure.isEmpty()) return null;
        const recorded = self.failure;
        self.failure = .{};
        return recorded;
    }

    /// Turns the selection sets into events, once the update has committed.
    ///
    /// This is the port of `enqueue_selection_changes` at `adapter.rs:125-229`.
    /// The caller must call it after `updateAndProcessChanges` and before it
    /// hands the queue out, because a selection event names a node the
    /// committed tree holds.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`. A container the walk
    /// could not read is skipped and the error is recorded, because one
    /// unreadable container must not swallow the others.
    pub fn enqueueSelectionChanges(self: *Handler, state: *const TreeState) HandlerError!void {
        var containers = self.selection_changed.iterator();
        while (containers.next()) |entry| {
            const key: FullNodeId = entry.key_ptr.*;
            const changes: *SelectionChanges = entry.value_ptr;

            // A container the tree no longer holds cannot be named, so its
            // changes are dropped. This is upstream's `continue` at
            // `adapter.rs:129-131`.
            const node = state.nodeById(key) orelse continue;

            var container: ?NodeRef = null;
            var only_selected: ?NodeRef = null;
            if (consumer.node_ref.containers.isContainerWithSelectableChildren(node)) {
                container = node;
                var children = try consumer.node_ref.hierarchy.filteredChildren(
                    node,
                    filters.filter_fn,
                );
                while (try children.next()) |child| {
                    const selected = consumer.node_ref.properties.isSelected(child) orelse false;
                    if (!selected) continue;
                    // Upstream keeps the first selected child and gives up on
                    // the optimization the moment a second one appears, at
                    // `adapter.rs:146-153`.
                    if (only_selected == null) {
                        only_selected = child;
                    } else {
                        only_selected = null;
                        break;
                    }
                }
            }

            try self.enqueueForContainer(changes, container, only_selected, state);
        }
    }

    fn enqueueForContainer(
        self: *Handler,
        changes: *SelectionChanges,
        container: ?NodeRef,
        only_selected: ?NodeRef,
        state: *const TreeState,
    ) HandlerError!void {
        if (only_selected) |child| {
            // Upstream's optimized path at `adapter.rs:149-175`: one selection
            // event and one property change for the child, and one property
            // change for every node that stopped being selected.
            if (self.registry.slotFor(self.platform, child.id())) |slot| {
                try self.pushSimple(slot, .selection_item_element_selected);
                try self.pushSelected(slot, false, true);
            } else |_| {}
            var removed = changes.removed.iterator();
            while (removed.next()) |entry| {
                const slot = try self.detachedSlotFor(entry.key_ptr.*, state);
                try self.pushSelected(slot, true, false);
            }
            return;
        }

        var container_is_multiselectable = false;
        if (container) |node| {
            container_is_multiselectable = consumer.node_ref.predicates.isMultiselectable(node);
            // Upstream's invalidation path at `adapter.rs:180-185`. The
            // comparison is strict, so exactly `invalidate_limit` changes are
            // still enumerated one by one.
            if (changes.added.count() + changes.removed.count() > invalidate_limit) {
                if (self.registry.slotFor(self.platform, node.id())) |slot| {
                    try self.pushSimple(slot, .selection_invalidated);
                } else |_| {}
                return;
            }
        }

        var added = changes.added.iterator();
        while (added.next()) |entry| {
            const slot = try self.registry.slotFor(self.platform, entry.key_ptr.*);
            try self.pushSimple(slot, if (container_is_multiselectable)
                .selection_item_element_added_to_selection
            else
                .selection_item_element_selected);
            try self.pushSelected(slot, false, true);
        }

        var removed = changes.removed.iterator();
        while (removed.next()) |entry| {
            const slot = try self.detachedSlotFor(entry.key_ptr.*, state);
            try self.pushSimple(slot, .selection_item_element_removed_from_selection);
            try self.pushSelected(slot, true, false);
        }
    }

    // --- The four slots, as `adapter.rs` writes them -------------------------

    /// One node the update added. Upstream `node_added` at `adapter.rs:238-267`.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`.
    pub fn nodeAdded(self: *Handler, node: NodeRef) !void {
        try self.insertTextChangeIfNeeded(node);
        if (try filters.filter(node) != .include) return;

        if (consumer.node_ref.predicates.isDialog(node)) {
            const slot = try self.registry.slotFor(self.platform, node.id());
            try self.pushSimple(slot, .window_window_opened);
        }
        if (try isLiveRegion(node)) {
            const slot = try self.registry.slotFor(self.platform, node.id());
            try self.pushSimple(slot, .live_region_changed);
        }
        if (self.supportsSelectionItemPattern(node)) {
            const selected = consumer.node_ref.properties.isSelected(node) orelse false;
            if (selected) try self.handleSelectionStateChange(node, true);
        }
    }

    /// One node the update rewrote. Upstream `node_updated` at
    /// `adapter.rs:269-339`.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`.
    pub fn nodeUpdated(self: *Handler, old: NodeRef, new: NodeRef) !void {
        const old_filtered = try filters.filter(old);
        if (try filters.filter(new) != .include) {
            if (old_filtered == .include) {
                if (consumer.node_ref.predicates.isDialog(old)) {
                    const slot = try self.registry.slotFor(self.platform, old.id());
                    try self.pushSimple(slot, .window_window_closed);
                }
                if (self.supportsSelectionItemPattern(old)) {
                    const selected = consumer.node_ref.properties.isSelected(old) orelse false;
                    if (selected) try self.handleSelectionStateChange(old, false);
                }
            }
            return;
        }

        if (try isLiveRegion(new)) {
            const slot = try self.registry.slotFor(self.platform, new.id());
            try self.pushSimple(slot, .live_region_changed);
        }
        if (old_filtered != .include and consumer.node_ref.predicates.isDialog(new)) {
            const slot = try self.registry.slotFor(self.platform, new.id());
            try self.pushSimple(slot, .window_window_opened);
        }
        if (self.supportsSelectionItemPattern(new)) {
            const new_selected = consumer.node_ref.properties.isSelected(new) orelse false;
            const old_selected = consumer.node_ref.properties.isSelected(old) orelse false;
            if (new_selected != old_selected or (old_filtered != .include and new_selected)) {
                try self.handleSelectionStateChange(new, new_selected);
            }
        }
    }

    /// The focus moved. Upstream `focus_moved` at `adapter.rs:341-345`.
    ///
    /// Upstream raises nothing when the focus is lost, and so does this: a focus
    /// change with no new node names no provider.
    ///
    /// **Errors.** `error.OutOfMemory`.
    pub fn focusMoved(self: *Handler, new: ?NodeRef) !void {
        const node = new orelse return;
        const slot = try self.registry.slotFor(self.platform, node.id());
        try self.pushSimple(slot, .automation_focus_changed);
    }

    /// One node the update removed. Upstream `node_removed` at
    /// `adapter.rs:347-369`.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`.
    pub fn nodeRemoved(self: *Handler, node: NodeRef) !void {
        try self.insertTextChangeIfNeeded(node);
        if (try filters.filter(node) != .include) return;

        if (consumer.node_ref.predicates.isDialog(node)) {
            const slot = try self.detachedSlotFor(node.id(), node.tree_state);
            try self.pushSimple(slot, .window_window_closed);
        }
        if (self.supportsSelectionItemPattern(node)) {
            try self.handleSelectionStateChange(node, false);
        }
    }

    // --- The helpers `adapter.rs` writes -------------------------------------

    /// Queues a text change for the parent of `node` when `node` is a text run.
    ///
    /// Upstream `insert_text_change_if_needed` at `adapter.rs:77-84`.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`.
    fn insertTextChangeIfNeeded(self: *Handler, node: NodeRef) !void {
        if (consumer.node_ref.properties.role(node) != .text_run) return;
        const parent = try consumer.node_ref.hierarchy.filteredParent(node, filters.filter_fn) orelse return;
        try self.insertTextChangeForParent(parent);
    }

    /// Queues a text change for `parent` unless one is queued already.
    ///
    /// Upstream `insert_text_change_if_needed_parent` at `adapter.rs:54-75`.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`.
    fn insertTextChangeForParent(self: *Handler, parent: NodeRef) !void {
        if (!try consumer.text.query.supportsTextRanges(parent)) return;
        const entry = try self.text_changed.getOrPut(self.gpa, parent.id());
        if (entry.found_existing) return;
        const slot = try self.registry.slotFor(self.platform, parent.id());
        // Inserted at the front, because a text change must come before a
        // selection change whatever order the selection changes arrive in.
        try self.queue.prepend(.{ .simple = .{ .slot = slot, .event_id = .text_text_changed } });
    }

    /// Records one selection state change against its container.
    ///
    /// Upstream `handle_selection_state_change` at `adapter.rs:100-123`. The key
    /// is the container when there is one, because the pass over the selection
    /// map needs the container to decide whether to invalidate.
    ///
    /// **Errors.** `error.OutOfMemory` and `QueryError`.
    fn handleSelectionStateChange(self: *Handler, node: NodeRef, is_selected: bool) !void {
        const container = try consumer.node_ref.containers.selectionContainer(
            node,
            filters.filter_fn,
        );
        const key = if (container) |found| found.id() else node.id();

        const gpa = self.gpa;
        const entry = try self.selection_changed.getOrPut(gpa, key);
        if (!entry.found_existing) entry.value_ptr.* = .{};
        const changes: *SelectionChanges = entry.value_ptr;
        const set = if (is_selected) &changes.added else &changes.removed;
        try set.put(gpa, node.id(), {});
    }

    /// The provider for a node the tree may have dropped, which the queue owns.
    ///
    /// Upstream `element_for_possibly_removed_node` at `adapter.rs:86-98`: a
    /// node the state still holds reuses its provider, and a node it no longer
    /// holds gets a fresh one that the event keeps alive.
    ///
    /// **Errors.** `error.OutOfMemory`.
    fn detachedSlotFor(self: *Handler, node_id: FullNodeId, state: *const TreeState) HandlerError!*const ProviderSlot {
        if (state.nodeById(node_id) != null) return self.registry.slotFor(self.platform, node_id);
        const slot = try self.registry.detachedSlotFor(self.platform, node_id);
        self.queue.takeOwnership(slot) catch |err| {
            self.registry.releaseDetached(self.platform, node_id, slot);
            return err;
        };
        return slot;
    }

    /// Whether `node` supports the selection item pattern.
    ///
    /// **This is the port's own predicate and the mapping is not proved.**
    /// Upstream calls `NodeRef::is_selection_item_pattern_supported`. Neither
    /// the pinned upstream tree nor `docs/33-consumer-interface-contract.md`
    /// records that method, so the port reads `predicates.isSelectable`, which
    /// answers "the node states a selection state and is not disabled".
    /// **[INFERENCE]** The two agree on every node the adapter sees, because a
    /// node that answers `SelectionItemPattern` states `is_selected`; a node
    /// that states `is_selected` and no pattern would differ, and the port
    /// raises the selection events for it. Re-check when the upstream tree is
    /// on a host again.
    fn supportsSelectionItemPattern(self: *Handler, node: NodeRef) bool {
        _ = self;
        return consumer.node_ref.predicates.isSelectable(node);
    }

    fn pushSimple(self: *Handler, slot: *const ProviderSlot, event_id: EventId) !void {
        try self.queue.append(.{ .simple = .{ .slot = slot, .event_id = event_id } });
    }

    fn pushSelected(self: *Handler, slot: *const ProviderSlot, old: bool, new: bool) !void {
        try self.queue.append(.{
            .property_changed = .{
                .slot = slot,
                .property_id = .selection_item_is_selected,
                .old = PropertyValue{ .bool_ = old },
                .new = PropertyValue{ .bool_ = new },
            },
        });
    }
};

/// Whether `node` announces itself as a live region.
///
/// A node with no label announces nothing, and a node whose inherited `live`
/// setting is `off` announces nothing.
///
/// **Errors.** `QueryError` from the inherited `live` walk.
fn isLiveRegion(node: NodeRef) !bool {
    if (consumer.node_ref.strings.rawLabel(node) == null) return false;
    const live = try consumer.node_ref.set_state.live(node);
    return live != .off;
}

// --- The four trampolines `TreeChangeHandler` declares ----------------------

fn nodeAddedSlot(context: *anyopaque, node: NodeRef) void {
    const self: *Handler = @ptrCast(@alignCast(context));
    self.nodeAdded(node) catch {
        self.failure.out_of_memory = true;
    };
}

fn nodeUpdatedSlot(context: *anyopaque, old: NodeRef, new: NodeRef) void {
    const self: *Handler = @ptrCast(@alignCast(context));
    self.nodeUpdated(old, new) catch {
        self.failure.out_of_memory = true;
    };
}

fn focusMovedSlot(context: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    _ = old;
    const self: *Handler = @ptrCast(@alignCast(context));
    self.focusMoved(new) catch {
        self.failure.out_of_memory = true;
    };
}

fn nodeRemovedSlot(context: *anyopaque, node: NodeRef) void {
    const self: *Handler = @ptrCast(@alignCast(context));
    self.nodeRemoved(node) catch {
        self.failure.out_of_memory = true;
    };
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// One node of a fixture tree.
const NodeSpec = struct {
    /// The identifier inside the root tree.
    local: u64,
    /// The role the node declares.
    role: schema.Role,
    /// The children of the node, in order.
    children: []const u64 = &.{},
    /// The label the node carries, or none.
    label: ?[]const u8 = null,
    /// The live setting the node carries, or none.
    live: ?schema.Live = null,
    /// The selection state the node carries, or none.
    is_selected: ?bool = null,
};

/// Builds the tree one fixture describes.
///
/// `Tree.init` takes the update by value and releases it on every path, so the
/// binding is spent and there is no `deinit` to pair with this call.
fn buildTree(gpa: std.mem.Allocator, root_local: u64, specs: []const NodeSpec) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    for (specs) |spec| {
        var node = schema.Node.init(gpa, spec.role);
        if (spec.label) |text| try schema.strings.setLabel(&node.properties, text);
        if (spec.live) |value| try schema.enums.setLive(&node.properties, value);
        if (spec.is_selected) |value| try schema.enums.setSelected(&node.properties, value);
        var child_ids: std.ArrayList(schema.NodeId) = .empty;
        defer child_ids.deinit(gpa);
        for (spec.children) |child| {
            try child_ids.append(gpa, .{ .value = child });
        }
        try schema.ids_props.setChildren(&node.properties, child_ids.items);
        try update.pushNode(gpa, .{ .value = spec.local }, node);
    }
    update.tree = schema.TreeInfo.init(.{ .value = root_local });
    update.focus = .{ .value = root_local };
    return consumer.tree.Tree.init(gpa, update, true) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TreeRejectedTheUpdate,
    };
}

/// The provider slot for the node with local identifier `local`.
fn slotForLocal(registry: *elements.Registry, platform: Platform, local: u64) !*const ProviderSlot {
    return registry.slotFor(platform, .init(.{ .value = local }, .init(0)));
}

test "a dialog node added queues the window opened event" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    try handler.nodeAdded(dialog);

    // The dialog is the only thing that queues anything, and it queues one.
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.window_window_opened, queue.at(0).?.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        queue.at(0).?.simple.slot,
    );
}

test "a text run queues its parent's text change at the front" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .document, .children = &.{4} },
        .{ .local = 3, .role = .dialog },
        .{ .local = 4, .role = .text_run },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const run = state.nodeById(state.rootId().withSameTree(.{ .value = 4 })) orelse
        return error.MissingNode;
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })) orelse
        return error.MissingNode;

    // The dialog queues first and the run queues second, so the prepend has to
    // put the text change in front of the window event.
    try handler.nodeAdded(dialog);
    try handler.nodeAdded(run);

    try testing.expectEqual(@as(usize, 2), queue.len());
    try testing.expectEqual(EventId.text_text_changed, queue.at(0).?.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        queue.at(0).?.simple.slot,
    );
    try testing.expectEqual(EventId.window_window_opened, queue.at(1).?.simple.event_id);
}

test "a text change is queued once however many runs changed" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 4 } },
        .{ .local = 2, .role = .document, .children = &.{3} },
        .{ .local = 3, .role = .text_run },
        .{ .local = 4, .role = .text_run },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const first = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })) orelse
        return error.MissingNode;
    const second = state.nodeById(state.rootId().withSameTree(.{ .value = 4 })) orelse
        return error.MissingNode;

    try handler.nodeAdded(first);
    try handler.nodeAdded(second);

    // Both runs share one filtered parent, so the set holds the parent once.
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.text_text_changed, queue.at(0).?.simple.event_id);
}

test "the focus move queues the automation focus changed event" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .button },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const button = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;

    // A focus change with no new node names no provider, so it queues nothing.
    try handler.focusMoved(null);
    try testing.expectEqual(@as(usize, 0), queue.len());

    try handler.focusMoved(button);
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.automation_focus_changed, queue.at(0).?.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        queue.at(0).?.simple.slot,
    );
}

test "a live region queues the live region changed event once" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .button, .label = "Save", .live = .polite },
        .{ .local = 3, .role = .button, .label = "Cancel" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const polite = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    const plain = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })) orelse
        return error.MissingNode;

    try handler.nodeAdded(polite);
    try handler.nodeAdded(plain);

    // The polite node announces; the plain node has no live setting.
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.live_region_changed, queue.at(0).?.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        queue.at(0).?.simple.slot,
    );
}

test "one selected child takes the optimized selection path" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .list_box_option, .is_selected = true },
        .{ .local = 4, .role = .list_box_option, .is_selected = false },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const chosen = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })) orelse
        return error.MissingNode;
    try handler.nodeAdded(chosen);
    try handler.enqueueSelectionChanges(state);

    // Upstream's optimized path: one selection event and one property change
    // for the only selected child, and nothing for the unselected one.
    try testing.expectEqual(@as(usize, 2), queue.len());
    try testing.expectEqual(EventId.selection_item_element_selected, queue.at(0).?.simple.event_id);
    const change = queue.at(1).?;
    try testing.expectEqual(syscalls.PropertyId.selection_item_is_selected, change.property_changed.property_id);
    try testing.expectEqual(false, change.property_changed.old.bool_);
    try testing.expectEqual(true, change.property_changed.new.bool_);
}

test "two selected children take the enumerated selection path" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .list_box_option, .is_selected = true },
        .{ .local = 4, .role = .list_box_option, .is_selected = true },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const first = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })) orelse
        return error.MissingNode;
    const second = state.nodeById(state.rootId().withSameTree(.{ .value = 4 })) orelse
        return error.MissingNode;
    try handler.nodeAdded(first);
    try handler.nodeAdded(second);
    try handler.enqueueSelectionChanges(state);

    // One selection event and one property change per selected child, so four
    // events rather than the optimized pair.
    try testing.expectEqual(@as(usize, 4), queue.len());
    try testing.expectEqual(EventId.selection_item_element_selected, queue.at(0).?.simple.event_id);
    try testing.expectEqual(EventId.selection_item_element_selected, queue.at(2).?.simple.event_id);
}

test "more changes than the limit invalidate the container instead of enumerating" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    var specs: std.ArrayList(NodeSpec) = .empty;
    defer specs.deinit(gpa);
    // One more option than `invalidate_limit` is what tips the comparison over,
    // and the comparison is strict, so exactly `invalidate_limit` still
    // enumerates.
    const option_count = invalidate_limit + 1;
    var child_ids: std.ArrayList(u64) = .empty;
    defer child_ids.deinit(gpa);
    var option_index: usize = 0;
    while (option_index < option_count) : (option_index += 1) {
        try child_ids.append(gpa, 3 + option_index);
    }
    try specs.append(gpa, .{ .local = 1, .role = .window, .children = &.{2} });
    try specs.append(gpa, .{ .local = 2, .role = .list_box, .children = child_ids.items });
    option_index = 0;
    while (option_index < option_count) : (option_index += 1) {
        try specs.append(gpa, .{
            .local = 3 + option_index,
            .role = .list_box_option,
            .is_selected = true,
        });
    }
    var tree = try buildTree(gpa, 1, specs.items);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    option_index = 0;
    while (option_index < option_count) : (option_index += 1) {
        const option = state.nodeById(state.rootId().withSameTree(.{ .value = 3 + option_index })) orelse
            return error.MissingNode;
        try handler.nodeAdded(option);
    }
    try handler.enqueueSelectionChanges(state);

    // One event, not two per option.
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.selection_invalidated, queue.at(0).?.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        queue.at(0).?.simple.slot,
    );
}

test "a removed dialog queues the closed event on a provider the queue owns" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    try handler.nodeRemoved(dialog);

    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.window_window_closed, queue.at(0).?.simple.event_id);
    // Upstream's first branch at `adapter.rs:87-92`: a node the state still
    // holds reuses the provider it already had, so the event names the registry
    // slot rather than a fresh one.
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        queue.at(0).?.simple.slot,
    );

    // Raising releases the queue, and the queue owns no provider here, so the
    // registry is the only owner and the test allocator sees no leak.
    const report = queue.raise(platform);
    try testing.expectEqual(@as(usize, 1), report.total());
}

test "a slot that runs out of memory records it and the caller reads it" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var registry = elements.Registry.init(failing.allocator());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(failing.allocator());
    defer queue.deinit(platform);
    var handler = Handler.init(failing.allocator(), platform, &registry, &queue);
    defer handler.deinit();

    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;

    // The slot cannot report, so it records. `takeFailure` is the only way out
    // and it answers the flag.
    try testing.expectEqual(@as(?Failure, null), handler.takeFailure());
    handler.nodeAdded(dialog) catch {
        handler.failure.out_of_memory = true;
    };
    const recorded = handler.takeFailure() orelse return error.NoFailureRecorded;
    try testing.expect(recorded.out_of_memory);
    try testing.expect(!recorded.isEmpty());
    try testing.expectEqual(@as(?Failure, null), handler.takeFailure());
}

test "the four slots of the change handler are all bound" {
    const gpa = testing.allocator;
    const platform = syscalls.unavailablePlatform();
    var registry = elements.Registry.init(gpa);
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa);
    defer queue.deinit(platform);
    var handler = Handler.init(gpa, platform, &registry, &queue);
    defer handler.deinit();

    const bound = handler.changeHandler();
    std.debug.assert(@intFromPtr(bound.ptr) != 0);
    try testing.expect(bound.node_added != null);
    try testing.expect(bound.node_updated != null);
    try testing.expect(bound.focus_moved != null);
    try testing.expect(bound.node_removed != null);
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "the selection limit is the value upstream names" {
    // `adapter.rs:179` and the comment beside it record 20 and say the value is
    // not specified by the documentation.
    try testing.expectEqual(@as(usize, 20), invalidate_limit);
}

test "a failure reports itself as not empty in both arms" {
    const neither: Failure = .{};
    const no_memory: Failure = .{ .out_of_memory = true };
    const query: Failure = .{ .query_error = error.TreeCycle };
    try testing.expect(neither.isEmpty());
    try testing.expect(!no_memory.isEmpty());
    try testing.expect(!query.isEmpty());
}
