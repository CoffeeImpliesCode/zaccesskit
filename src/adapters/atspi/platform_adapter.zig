//! Per-window consumer tree and ordered, owned AT-SPI notifications.
//!
//! Pinned upstream `adapters/atspi-common/src/adapter.rs:30-365,421-615`
//! defines the change handler and lifecycle; `node.rs:606-705` defines the
//! existing state/property/bounds/children/document pipeline.
//!
//! Text diffs run before node filtering and are deduplicated per text parent.
//! Focus activation emits window, active state and application descendant
//! notifications before focused state/selection/caret. On transfer the new
//! focus is announced before the old focus is cleared. Selection-container
//! notifications follow the consumer commit.
//!
//! The queue owns text and full cache snapshots independently of tree updates.
//! Slots latch the first typed notification error because consumer callbacks
//! cannot fail. A successful commit exposes that cause through last_event_error.
//! Walks use the consumer node-count bound; text scans use their byte lengths.
//! This module owns no transport, clock, runtime or user callbacks.

const std = @import("std");

const boundary = @import("../../capi/boundary.zig");
const consumer = @import("../../consumer/root.zig");
const tree_index = @import("../../consumer/tree_index.zig");
const schema = @import("../../schema/root.zig");
const events = @import("events.zig");
const node_notifications = @import("node.zig");
const object_id = @import("object_id.zig");
const window_bounds = @import("window_bounds.zig");
const app_context = @import("app_context.zig");
const node_interfaces = @import("node_interfaces.zig");
const node_state = @import("node_state.zig");

const Visit = struct { node: NodeRef, exit: bool = false };
const WalkMode = enum { initial, add, remove };

const CRect = boundary.CRect;
const FullNodeId = tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const Tree = consumer.tree.Tree;
const TreeChangeHandler = consumer.tree.TreeChangeHandler;
const ObjectId = object_id.ObjectId;

/// Typed notification causes, including query, cache, text and allocation errors.
pub const NotificationError = node_notifications.NodeError || error{InvalidUtf8};
/// Consumer rejection errors and post-commit notification causes.
pub const AdapterError = consumer.tree.UpdateError || NotificationError;

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
    last_event_error: ?NotificationError,

    /// The first failure one of the four change slots hit during the operation
    /// now running. It is cleared at the head of every operation and copied
    /// into `last_event_error` at the end of one, because a slot may not
    /// return a failure and the caller reads exactly one field.
    slot_error: ?NotificationError = null,
    /// Borrowed, address-stable native query context. Null before attachment.
    context: ?*app_context.NodeContext = null,
    /// Borrowed native application context. Null for the transport-free seam.
    app: ?*app_context.AppContext = null,
    /// Per-operation deduplication; cleared before each consumer operation.
    added_nodes: std.AutoHashMapUnmanaged(FullNodeId, void) = .empty,
    removed_nodes: std.AutoHashMapUnmanaged(FullNodeId, void) = .empty,
    checked_text: std.AutoHashMapUnmanaged(FullNodeId, void) = .empty,
    selection_changed: std.AutoHashMapUnmanaged(FullNodeId, void) = .empty,
    /// Scratch stack; contains no borrowed NodeRef after a walk returns.
    visits: std.ArrayList(Visit) = .empty,

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
        self.added_nodes.deinit(self.gpa);
        self.removed_nodes.deinit(self.gpa);
        self.checked_text.deinit(self.gpa);
        self.selection_changed.deinit(self.gpa);
        self.visits.deinit(self.gpa);
        self.* = .{
            .gpa = self.gpa,
            .id = 0,
            .tree = null,
            .bounds = .empty,
            .is_host_focused = false,
            .raised = events.EventQueue.empty(),
            .applied_updates = 0,
            .last_event_error = null,
        };
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
        if (self.context) |context| context.bounds = self.bounds;
    }

    /// Commits host focus and collects upstream window/state/selection events.
    /// With no tree only the host flag changes. A notification failure is
    /// reported through last_event_error after the consumer commit.
    pub fn updateWindowFocusState(
        self: *PlatformAdapter,
        is_host_focused: bool,
    ) consumer.tree.UpdateError!void {
        self.beginNotifications();
        if (self.tree) |*tree| {
            try tree.updateHostFocusStateAndProcessChanges(is_host_focused, &self.changeHandler());
        }
        self.is_host_focused = is_host_focused;
        self.refreshContext();
        self.last_event_error = self.slot_error;
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
    pub fn apply(self: *PlatformAdapter, update: schema.TreeUpdate) consumer.tree.UpdateError!void {
        return self.applyInternal(false, update);
    }

    /// Applies a callback-duration borrow without freeing or modifying its nodes.
    /// The consumer copies accepted data into its owned state. Events own their
    /// cache/text payloads and never retain update memory. Rejections leave the
    /// input and baseline intact; notification causes follow a successful commit
    /// through last_event_error exactly as for the transferred apply path.
    pub fn applyBorrowed(
        self: *PlatformAdapter,
        update: *const schema.TreeUpdate,
    ) AdapterError!void {
        return self.applyInternal(true, update);
    }

    fn applyInternal(
        self: *PlatformAdapter,
        comptime borrowed: bool,
        update: if (borrowed) *const schema.TreeUpdate else schema.TreeUpdate,
    ) consumer.tree.UpdateError!void {
        self.beginNotifications();
        if (self.tree == null) {
            var built = if (borrowed)
                try Tree.initBorrowed(self.gpa, update, self.is_host_focused)
            else
                try Tree.init(self.gpa, update, self.is_host_focused);
            errdefer built.deinit();
            self.tree = built;
            self.applied_updates = 1;
            self.announceWholeTree();
            self.refreshContext();
            self.last_event_error = self.slot_error;
            return;
        }
        const tree = &self.tree.?;
        if (borrowed) {
            try tree.updateBorrowedAndProcessChanges(update, &self.changeHandler());
        } else {
            try tree.updateAndProcessChanges(update, &self.changeHandler());
        }
        self.applied_updates += 1;
        self.emitSelectionChanged() catch |err| self.noteSlotFailure(err);
        self.refreshContext();
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

    /// Refreshes the borrowed native context only after a successful commit.
    fn refreshContext(self: *PlatformAdapter) void {
        if (self.context) |context| {
            if (self.tree) |*tree| context.state = tree.stateOf();
            context.bounds = self.bounds;
        }
    }

    /// Builds a live query handle. It borrows context until native close.
    /// Returns Defunct before context injection or after tree teardown.
    pub fn platformNode(
        self: *const PlatformAdapter,
        id: FullNodeId,
    ) error{Defunct}!node_notifications.PlatformNode {
        if (self.tree == null) return error.Defunct;
        const context = self.context orelse return error.Defunct;
        return context.platformNode(self.id, id);
    }

    /// Live context's root; returns Defunct before attachment or after teardown.
    pub fn rootId(self: *const PlatformAdapter) error{Defunct}!FullNodeId {
        if (self.tree == null) return error.Defunct;
        return (self.context orelse return error.Defunct).rootId();
    }

    /// Application query handle forwarding the borrowed live context.
    /// Returns Defunct when context or its application registry is absent.
    pub fn platformRoot(self: *const PlatformAdapter) error{Defunct}!node_notifications.PlatformRoot {
        if (self.tree == null) return error.Defunct;
        return (self.context orelse return error.Defunct).platformRoot();
    }

    /// Queues application ChildrenChanged(remove) before native detachment.
    /// Notification errors are retained in last_event_error; no tree is removed.
    pub fn announceRemoval(self: *PlatformAdapter) void {
        self.beginNotifications();
        self.last_event_error = null;
        const tree = if (self.tree) |*tree| tree else return;
        self.emitWindowChild(tree.stateOf().root().id(), false) catch |err| self.noteSlotFailure(err);
        self.last_event_error = self.slot_error;
    }

    fn beginNotifications(self: *PlatformAdapter) void {
        self.slot_error = null;
        self.added_nodes.clearRetainingCapacity();
        self.removed_nodes.clearRetainingCapacity();
        self.checked_text.clearRetainingCapacity();
        self.selection_changed.clearRetainingCapacity();
    }

    /// Initial registration is root-first and projects away excluded descendants.
    fn announceWholeTree(self: *PlatformAdapter) void {
        const tree = &self.tree.?;
        self.walkSubtree(tree.stateOf().root(), .initial) catch |err| self.noteSlotFailure(err);
        if (self.slot_error == null) {
            if (tree.stateOf().focus()) |focus| {
                self.emitState(focus.id(), "focused", true) catch |err| self.noteSlotFailure(err);
            }
        }
    }

    fn emit(self: *PlatformAdapter, event: events.Event) NotificationError!void {
        var owned = event;
        errdefer owned.deinit(self.gpa);
        try self.raised.push(self.gpa, owned);
    }

    fn emitState(
        self: *PlatformAdapter,
        id: FullNodeId,
        state: []const u8,
        enabled: bool,
    ) NotificationError!void {
        try self.emit(.{
            .kind = .object,
            .member = events.member_state_changed,
            .id = self.objectId(id),
            .detail1 = state,
            .detail2 = if (enabled) 1 else 0,
        });
    }

    fn emitWindowChild(self: *PlatformAdapter, id: FullNodeId, added: bool) NotificationError!void {
        const index = if (self.app) |app| app.adapterIndex(self.id) catch 0 else 0;
        try self.emit(.{
            .kind = .object,
            .member = "ChildrenChanged",
            .id = .root,
            .detail1 = if (added) "add" else "remove",
            .detail2 = if (added) std.math.cast(i32, index) orelse return error.IndexOutOfRange else -1,
            .any_data = .{ .address = self.objectId(id) },
        });
    }

    fn emitCacheAdded(self: *PlatformAdapter, node: NodeRef) NotificationError!void {
        var children = try consumer.node_ref.hierarchy.filteredChildren(node, node_state.node_filter);
        var child_count: usize = 0;
        while (try children.next()) |_| child_count += 1;
        const parent = try consumer.node_ref.hierarchy.filteredParent(node, node_state.node_filter);
        var index: usize = 0;
        if (parent != null) {
            var siblings = try consumer.node_ref.hierarchy.precedingFilteredSiblings(
                node,
                node_state.node_filter,
            );
            while (try siblings.next()) |_| index += 1;
        } else if (self.app) |app| {
            index = app.adapterIndex(self.id) catch 0;
        }
        const snapshot = try node_notifications.cacheNodeFor(
            self.gpa,
            node,
            self.id,
            std.math.cast(i32, index) orelse return error.IndexOutOfRange,
            std.math.cast(i32, child_count) orelse return error.TooManyChildren,
            node.tree_state.focusId() != null,
        );
        try self.emit(.{
            .kind = .cache,
            .member = events.member_add_accessible,
            .id = .cache,
            .cache_item = snapshot,
        });
    }

    fn addNode(self: *PlatformAdapter, node: NodeRef) NotificationError!void {
        const entry = try self.added_nodes.getOrPut(self.gpa, node.id());
        if (entry.found_existing) return;
        try self.emitCacheAdded(node);
        if (consumer.node_ref.hierarchy.isRoot(node) and node.data().role == .window) {
            try self.emitWindowChild(node.id(), true);
        }
        const live = try node_interfaces.live(node);
        if (live != .none) {
            if (try node_notifications.nodeName(self.gpa, node)) |name_| {
                var name = name_;
                defer name.deinit(self.gpa);
                try self.emit(.{
                    .kind = .object,
                    .member = events.member_announcement,
                    .id = self.objectId(node.id()),
                    .detail2 = @backingInt(live),
                    .any_data = .{ .text = name.items },
                });
            }
        }
        if (consumer.node_ref.properties.isSelected(node) == true) try self.enqueueSelection(node);
    }

    fn removeNode(self: *PlatformAdapter, node: NodeRef) NotificationError!void {
        const entry = try self.removed_nodes.getOrPut(self.gpa, node.id());
        if (entry.found_existing) return;
        if (consumer.node_ref.hierarchy.isRoot(node) and node.data().role == .window) {
            try self.emitWindowChild(node.id(), false);
        }
        try self.emitState(node.id(), "defunct", true);
        try self.emit(.{
            .kind = .cache,
            .member = events.member_remove_accessible,
            .id = .cache,
            .any_data = .{ .address = self.objectId(node.id()) },
        });
        if (consumer.node_ref.properties.isSelected(node) == true) try self.enqueueSelection(node);
    }

    /// At most two visits per consumer node. Removes use forward-child postorder.
    fn walkSubtree(self: *PlatformAdapter, root: NodeRef, mode: WalkMode) NotificationError!void {
        const bound = std.math.mul(usize, root.tree_state.nodes.count(), 2) catch return error.TreeCycle;
        self.visits.clearRetainingCapacity();
        defer self.visits.clearRetainingCapacity();
        try self.visits.ensureTotalCapacity(self.gpa, bound);
        self.visits.appendAssumeCapacity(.{ .node = root });
        var steps: usize = 0;
        while (self.visits.pop()) |visit| {
            if (steps >= bound) return error.TreeCycle;
            steps += 1;
            if (visit.exit) {
                try self.removeNode(visit.node);
                continue;
            }
            switch (mode) {
                .initial => {
                    try self.emitCacheAdded(visit.node);
                    if (consumer.node_ref.hierarchy.isRoot(visit.node)) {
                        try self.emitWindowChild(visit.node.id(), true);
                    }
                },
                .add => try self.addNode(visit.node),
                .remove => self.visits.appendAssumeCapacity(.{ .node = visit.node, .exit = true }),
            }
            var children = try consumer.node_ref.hierarchy.filteredChildren(
                visit.node,
                node_state.node_filter,
            );
            while (try children.nextBack()) |child| {
                self.visits.appendAssumeCapacity(.{ .node = child });
            }
        }
    }

    fn enqueueSelection(self: *PlatformAdapter, node: NodeRef) NotificationError!void {
        if (!consumer.node_ref.containers.isItemLike(node)) return;
        if (try consumer.node_ref.containers.selectionContainer(node, node_state.node_filter)) |parent| {
            if (!consumer.node_ref.containers.isContainerWithSelectableChildren(parent)) return;
            try self.selection_changed.put(self.gpa, parent.id(), {});
        }
    }

    fn emitSelectionChanged(self: *PlatformAdapter) NotificationError!void {
        if (self.slot_error != null) return;
        var ids = self.selection_changed.keyIterator();
        while (ids.next()) |id| {
            if (self.removed_nodes.contains(id.*)) continue;
            try self.emit(.{ .kind = .object, .member = "SelectionChanged", .id = self.objectId(id.*) });
        }
    }

    /// Stores the first failure and leaves any later one alone.
    ///
    /// Leaving the later ones is not discarding them: the first is the cause and
    /// the rest follow from the same exhausted allocator, so one tag is the
    /// whole of the information.
    ///
    /// **Errors.** This function does not fail.
    fn noteSlotFailure(self: *PlatformAdapter, failure: NotificationError) void {
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

/// Consumer callback failures are retained until the enclosing operation returns.
fn onNodeAdded(ptr: *anyopaque, node: NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    if (self.slot_error != null) return;
    onNodeAddedChecked(self, node) catch |err| self.noteSlotFailure(err);
}

fn onNodeAddedChecked(self: *PlatformAdapter, node: NodeRef) NotificationError!void {
    if (try node_state.node_filter.call(node) == .include) try self.addNode(node);
}

fn onNodeRemoved(ptr: *anyopaque, node: NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    if (self.slot_error != null) return;
    onNodeRemovedChecked(self, node) catch |err| self.noteSlotFailure(err);
}

fn onNodeRemovedChecked(self: *PlatformAdapter, node: NodeRef) NotificationError!void {
    if (try node_state.node_filter.call(node) == .include) try self.removeNode(node);
}

fn onNodeUpdated(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    if (self.slot_error != null) return;
    onNodeUpdatedChecked(self, old, new) catch |err| self.noteSlotFailure(err);
}

fn onNodeUpdatedChecked(self: *PlatformAdapter, old: NodeRef, new: NodeRef) NotificationError!void {
    try emitTextChanged(self, old, new);
    const filter_old = try node_state.node_filter.call(old);
    const filter_new = try node_state.node_filter.call(new);
    if (filter_old != filter_new) {
        if (filter_new == .include) {
            if (filter_old == .exclude_subtree) {
                try self.walkSubtree(new, .add);
            } else {
                try self.addNode(new);
            }
        } else if (filter_old == .include) {
            if (filter_new == .exclude_subtree) {
                try self.walkSubtree(old, .remove);
            } else {
                try self.removeNode(old);
            }
        }
    } else if (filter_new == .include) {
        try node_notifications.notifyChanges(self.gpa, &self.raised, new, old, self.bounds, self.id);
        try emitTextSelection(self, old, new);
        if (consumer.node_ref.properties.isSelected(new) != consumer.node_ref.properties.isSelected(old)) {
            try self.enqueueSelection(new);
        }
    }
}

fn onFocusMoved(ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    const self = PlatformAdapter.adapterOf(ptr);
    if (self.slot_error != null) return;
    onFocusMovedChecked(self, old, new) catch |err| self.noteSlotFailure(err);
}

fn onFocusMovedChecked(
    self: *PlatformAdapter,
    old: ?NodeRef,
    new: ?NodeRef,
) NotificationError!void {
    if (old == null and new != null) {
        if (rootWindow(new.?.tree_state)) |window| try emitWindowFocus(self, window, true);
    } else if (old != null and new == null) {
        if (rootWindow(old.?.tree_state)) |window| try emitWindowFocus(self, window, false);
    }
    if (new) |node| {
        try self.emitState(node.id(), "focused", true);
        try emitTextSelection(self, null, node);
    }
    if (old) |node| try self.emitState(node.id(), "focused", false);
}

fn rootWindow(state: *const consumer.tree_state.TreeState) ?NodeRef {
    const root = state.root();
    return switch (root.data().role) {
        .window, .dialog, .alert_dialog => root,
        else => null,
    };
}

fn emitWindowFocus(self: *PlatformAdapter, window: NodeRef, focused: bool) NotificationError!void {
    var name = (try node_notifications.nodeName(self.gpa, window)) orelse std.ArrayList(u8).empty;
    defer name.deinit(self.gpa);
    try self.emit(.{
        .kind = .window,
        .member = if (focused) "Activate" else "Deactivate",
        .id = self.objectId(window.id()),
        .any_data = .{ .text = name.items },
    });
    try self.emitState(window.id(), "active", focused);
    if (focused) {
        try self.emit(.{
            .kind = .object,
            .member = "ActiveDescendantChanged",
            .id = .root,
            .any_data = .{ .address = self.objectId(window.id()) },
        });
    }
}

fn emitTextSelection(
    self: *PlatformAdapter,
    old: ?NodeRef,
    new: NodeRef,
) NotificationError!void {
    if (!try consumer.text.query.supportsTextRanges(new)) return;
    const new_raw = schema.option.textSelection(&new.data().properties);
    const old_raw = if (old) |node| schema.option.textSelection(&node.data().properties) else null;
    if (old) |node| {
        if (!consumer.node_ref.predicates.isFocused(node) or std.meta.eql(old_raw, new_raw)) return;
    }
    if (try consumer.text.query.textSelection(self.gpa, new)) |selection| {
        var changed = !try consumer.text.range.isDegenerate(self.gpa, selection);
        if (!changed) {
            if (old) |node| {
                if (try consumer.text.query.textSelection(self.gpa, node)) |previous| {
                    changed = !try consumer.text.range.isDegenerate(self.gpa, previous);
                }
            }
        }
        if (changed) {
            try self.emit(.{ .kind = .object, .member = "TextSelectionChanged", .id = self.objectId(new.id()) });
        }
    }
    const old_focus: ?schema.TextPosition = if (old_raw) |selection| selection.focus else null;
    const new_focus: ?schema.TextPosition = if (new_raw) |selection| selection.focus else null;
    if (old == null or !std.meta.eql(old_focus, new_focus)) {
        if (consumer.text.query.textSelectionFocus(new)) |focus| {
            try self.emit(.{
                .kind = .object,
                .member = "TextCaretMoved",
                .id = self.objectId(new.id()),
                .detail2 = try node_notifications.toOffset(focus),
            });
        }
    }
}

fn emitTextChanged(self: *PlatformAdapter, old: NodeRef, new: NodeRef) NotificationError!void {
    if (new.data().role == .text_run or new.data().role == .generic_container) {
        const old_parent = try consumer.node_ref.hierarchy.filteredParent(old, node_state.node_filter);
        const new_parent = try consumer.node_ref.hierarchy.filteredParent(new, node_state.node_filter);
        if (old_parent != null and new_parent != null) {
            try emitTextDiff(self, old_parent.?, new_parent.?);
        }
    } else {
        try emitTextDiff(self, old, new);
    }
}

/// Finds common prefix and suffix in Unicode scalar values, never UTF-8 bytes.
fn emitTextDiff(self: *PlatformAdapter, old: NodeRef, new: NodeRef) NotificationError!void {
    if (!try consumer.text.query.supportsTextRanges(old)) return;
    if (!try consumer.text.query.supportsTextRanges(new)) return;
    const entry = try self.checked_text.getOrPut(self.gpa, new.id());
    if (entry.found_existing) return;
    var old_text = try consumer.text.range.text(
        self.gpa,
        try consumer.text.query.documentRange(self.gpa, old),
    );
    defer old_text.deinit(self.gpa);
    var new_text = try consumer.text.range.text(
        self.gpa,
        try consumer.text.query.documentRange(self.gpa, new),
    );
    defer new_text.deinit(self.gpa);
    const old_view = try std.unicode.Utf8View.init(old_text.items);
    const new_view = try std.unicode.Utf8View.init(new_text.items);
    var old_chars = old_view.iterator();
    var new_chars = new_view.iterator();
    var prefix_bytes: usize = 0;
    var prefix_scalars: usize = 0;
    while (old_chars.nextCodepointSlice()) |old_scalar| {
        const new_scalar = new_chars.nextCodepointSlice() orelse break;
        if (!std.mem.eql(u8, old_scalar, new_scalar)) break;
        prefix_bytes += old_scalar.len;
        prefix_scalars += 1;
    }
    if (prefix_bytes == old_text.items.len and prefix_bytes == new_text.items.len) return;
    var old_end = old_text.items.len;
    var new_end = new_text.items.len;
    while (old_end > prefix_bytes and new_end > prefix_bytes) {
        const old_start = previousScalar(old_text.items, old_end);
        const new_start = previousScalar(new_text.items, new_end);
        if (!std.mem.eql(u8, old_text.items[old_start..old_end], new_text.items[new_start..new_end])) break;
        old_end = old_start;
        new_end = new_start;
    }
    const start = std.math.cast(i32, prefix_scalars) orelse return error.TooManyCharacters;
    try emitTextPart(self, new.id(), "delete", start, old_text.items[prefix_bytes..old_end]);
    try emitTextPart(self, new.id(), "insert", start, new_text.items[prefix_bytes..new_end]);
}

/// Input was validated by Utf8View; at most four bytes precede end.
fn previousScalar(text: []const u8, end: usize) usize {
    var start = end - 1;
    while (start > 0 and text[start] & 0xc0 == 0x80) start -= 1;
    return start;
}

fn emitTextPart(
    self: *PlatformAdapter,
    id: FullNodeId,
    kind: []const u8,
    start: i32,
    text: []const u8,
) NotificationError!void {
    if (text.len == 0) return;
    const view = try std.unicode.Utf8View.init(text);
    var chars = view.iterator();
    var count: usize = 0;
    while (chars.nextCodepointSlice()) |_| count += 1;
    const length = std.math.cast(i32, count) orelse return error.TooManyCharacters;
    try self.emit(.{
        .kind = .object,
        .member = "TextChanged",
        .id = self.objectId(id),
        .detail1 = kind,
        .detail2 = start,
        .detail3 = length,
        .any_data = .{ .text = text },
    });
}

const testing = std.testing;

/// Builds one update that names `count` nodes in a chain, with `root` first.
///
/// The root node's id is `1` and every child follows it, which is the shape a
/// tree takes when an application pushes one button.
fn chainUpdate(gpa: std.mem.Allocator, count: u64) !schema.TreeUpdate {
    var update: schema.TreeUpdate = .{
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

    // Root-first filtered cache snapshots surround the app's root child add.
    try testing.expectEqual(@as(usize, 4), adapter.raised.count());
    try testing.expectEqualStrings("ChildrenChanged", adapter.raised.items.items[1].member);
    for ([_]usize{ 0, 2, 3 }, 1..) |event_index, node_id| {
        const event = adapter.raised.items.items[event_index];
        try testing.expectEqual(events.Kind.cache, event.kind);
        try testing.expectEqualStrings(events.member_add_accessible, event.member);
        try testing.expect(std.meta.eql(ObjectId.cache, event.id));
        try testing.expect(std.meta.eql(FullNodeId.init(.{ .value = node_id }, .init(0)), event.cache_item.?.id));
    }
}

test "a second update is folded into the tree the first one built" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 0, false);
    defer adapter.deinit();

    try adapter.apply(try chainUpdate(gpa, 2));
    var taken: std.ArrayList(events.Event) = .empty;
    defer taken.deinit(gpa);
    defer for (taken.items) |*event| event.deinit(gpa);
    try adapter.raised.drainInto(gpa, &taken);

    try adapter.apply(try chainUpdate(gpa, 3));

    try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
    try testing.expectEqual(@as(usize, 3), adapter.nodeCount());
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 2), raised.len);
    try testing.expectEqualStrings(events.member_add_accessible, raised[0].member);
    try testing.expectEqualStrings("ChildrenChanged", raised[1].member);
    try testing.expectEqualStrings("add", raised[1].detail1);
    try testing.expectEqual(@as(i32, 0), raised[1].detail2);
    try testing.expect(std.meta.eql(
        adapter.objectId(FullNodeId.init(.{ .value = 2 }, .init(0))),
        raised[1].id,
    ));
    try testing.expect(std.meta.eql(
        adapter.objectId(FullNodeId.init(.{ .value = 3 }, .init(0))),
        raised[1].any_data.address,
    ));
}

test "a node whose box moved raises the upstream BoundsChanged payload" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 1, false);
    defer adapter.deinit();

    var update: schema.TreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    var node = schema.Node.init(gpa, .button);
    try schema.option.setBounds(&node.properties, schema.rectInit(0, 0, 10, 10));
    try update.pushNode(gpa, .{ .value = 1 }, node);
    try adapter.apply(update);
    var taken: std.ArrayList(events.Event) = .empty;
    defer taken.deinit(gpa);
    defer for (taken.items) |*event| event.deinit(gpa);
    try adapter.raised.drainInto(gpa, &taken);

    // The same box under a different node is an update that moves nothing, and
    // a `BoundsChanged` for it would make a client repaint for no reason.
    var still: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    var same = schema.Node.init(gpa, .button);
    try schema.option.setBounds(&same.properties, schema.rectInit(0, 0, 10, 10));
    try still.pushNode(gpa, .{ .value = 1 }, same);
    try adapter.apply(still);
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());

    // A different extent is a size change, and the new box rides in the variant
    // because `siiva{sv}` has no argument of type `(iiii)`.
    var moved: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    var wider = schema.Node.init(gpa, .button);
    try schema.option.setBounds(&wider.properties, schema.rectInit(0, 0, 20, 10));
    try moved.pushNode(gpa, .{ .value = 1 }, wider);
    try adapter.apply(moved);

    try testing.expectEqual(@as(usize, 1), adapter.raised.count());
    const raised = adapter.raised.items.items[0];
    try testing.expectEqualStrings(events.member_bounds_changed, raised.member);
    try testing.expectEqualStrings("", raised.detail1);
    try testing.expectEqualStrings("(iiii)", raised.any_data.signature());
    const extent = raised.any_data.extent;
    try testing.expectEqual(@as(i32, 20), extent[2]);
}

test "the window focus flag raises ordered activation and focus states" {
    const gpa = std.testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 4, false);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 2));
    clearNotificationEvents(&adapter);
    try adapter.updateWindowFocusState(true);
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 4), raised.len);
    try testing.expectEqualStrings("Activate", raised[0].member);
    try testing.expectEqual(events.Kind.window, raised[0].kind);
    try testing.expectEqualStrings("", raised[0].any_data.text);
    try testing.expectEqualStrings("StateChanged", raised[1].member);
    try testing.expectEqualStrings("active", raised[1].detail1);
    try testing.expectEqual(@as(i32, 1), raised[1].detail2);
    try testing.expectEqualStrings("ActiveDescendantChanged", raised[2].member);
    try testing.expect(std.meta.eql(ObjectId.root, raised[2].id));
    try testing.expectEqualStrings("StateChanged", raised[3].member);
    try testing.expectEqualStrings("focused", raised[3].detail1);
    try testing.expectEqual(@as(i32, 1), raised[3].detail2);
    try testing.expectEqual(events.AnyData.none, raised[3].any_data);
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

fn notificationUpdate(
    gpa: std.mem.Allocator,
    options: struct {
        initial: bool,
        role: schema.Role,
        busy: bool,
        changed: bool = false,
        child: ?u64 = null,
        live: bool = false,
    },
) !schema.TreeUpdate {
    var update: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    errdefer update.deinit(gpa);
    if (options.initial) update.tree = schema.TreeInfo.init(.{ .value = 1 });
    const built_root = build_root: {
        var root = schema.Node.init(gpa, options.role);
        errdefer root.deinit();
        schema.flags.setBusy(&root.flags, options.busy);
        try schema.strings.setLabel(&root.properties, if (options.changed) "After" else "Before");
        try schema.numbers.setNumericValue(&root.properties, if (options.changed) 2.5 else 1.5);
        if (options.live) {
            try schema.strings.setDescription(
                &root.properties,
                if (options.changed) "New description" else "Old description",
            );
            try schema.enums.setLive(&root.properties, .polite);
        }
        if (options.child) |child| {
            try schema.ids_props.setChildren(&root.properties, &.{.{ .value = child }});
        }
        break :build_root root;
    };
    try update.pushNode(gpa, .{ .value = 1 }, built_root);
    if (options.child) |child| {
        try update.pushNode(gpa, .{ .value = child }, schema.Node.init(gpa, .button));
    }
    return update;
}

fn clearNotificationEvents(adapter: *PlatformAdapter) void {
    adapter.raised.deinit(adapter.gpa);
    adapter.raised = events.EventQueue.empty();
}

fn expectNotification(
    event: events.Event,
    options: struct {
        kind: events.Kind = .object,
        member: []const u8,
        node: u64 = 1,
        detail1: []const u8 = "",
        detail2: i32 = 0,
    },
) !void {
    try testing.expectEqual(options.kind, event.kind);
    try testing.expectEqualStrings(options.member, event.member);
    try testing.expectEqualStrings(options.detail1, event.detail1);
    try testing.expectEqual(options.detail2, event.detail2);
    try testing.expectEqual(@as(i32, 0), event.detail3);
    try testing.expectEqual(@as(usize, 0), event.properties.count());
    const id = FullNodeId.init(.{ .value = options.node }, .init(0));
    const expected: ObjectId = .{ .node = .{ .adapter = 9, .node = id } };
    try testing.expect(std.meta.eql(expected, event.id));
}

test "adapter document busy completion follows state notification" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = true,
        .role = .root_web_area,
        .busy = true,
    }));
    clearNotificationEvents(&adapter);
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .root_web_area,
        .busy = false,
    }));
    try testing.expect(adapter.last_event_error == null);
    try testing.expectEqual(@as(usize, 2), adapter.raised.count());
    try expectNotification(adapter.raised.items.items[0], .{
        .member = "StateChanged",
        .detail1 = "busy",
        .detail2 = 0,
    });
    try testing.expectEqual(events.AnyData.none, adapter.raised.items.items[0].any_data);
    try expectNotification(adapter.raised.items.items[1], .{
        .kind = .document,
        .member = "LoadComplete",
    });
    try testing.expectEqual(events.AnyData.none, adapter.raised.items.items[1].any_data);
}

test "adapter non-document busy completion has no document event" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = true,
        .role = .button,
        .busy = true,
    }));
    clearNotificationEvents(&adapter);
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .button,
        .busy = false,
    }));
    try testing.expectEqual(@as(usize, 1), adapter.raised.count());
    try expectNotification(adapter.raised.items.items[0], .{
        .member = "StateChanged",
        .detail1 = "busy",
    });
}

test "adapter unchanged busy state emits nothing" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = true,
        .role = .root_web_area,
        .busy = true,
    }));
    clearNotificationEvents(&adapter);
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .root_web_area,
        .busy = true,
    }));
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());
}

test "adapter orders state name value children and document notifications" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = true,
        .role = .root_web_area,
        .busy = true,
        .child = 2,
    }));
    clearNotificationEvents(&adapter);
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .root_web_area,
        .busy = false,
        .changed = true,
        .child = 3,
    }));
    const raised = adapter.raised.items.items;
    try testing.expect(adapter.last_event_error == null);
    try testing.expectEqual(@as(usize, 9), raised.len);
    try testing.expectEqualStrings("AddAccessible", raised[0].member);
    try testing.expect(std.meta.eql(ObjectId.cache, raised[0].id));
    try expectNotification(raised[1], .{ .member = "StateChanged", .detail1 = "busy" });
    try expectNotification(raised[2], .{
        .member = "PropertyChange",
        .detail1 = "accessible-name",
    });
    try testing.expectEqualStrings("After", raised[2].any_data.text);
    try expectNotification(raised[3], .{
        .member = "PropertyChange",
        .detail1 = "accessible-value",
    });
    try testing.expectEqual(@as(f64, 2.5), raised[3].any_data.number);
    try expectNotification(raised[4], .{
        .member = "ChildrenChanged",
        .detail1 = "add",
        .detail2 = 0,
    });
    try expectNotification(raised[5], .{
        .member = "ChildrenChanged",
        .detail1 = "remove",
        .detail2 = -1,
    });
    try expectNotification(raised[6], .{ .kind = .document, .member = "LoadComplete" });
    try expectNotification(raised[7], .{
        .member = "StateChanged",
        .detail1 = "defunct",
        .detail2 = 1,
        .node = 2,
    });
    try testing.expectEqualStrings("RemoveAccessible", raised[8].member);
    try testing.expect(std.meta.eql(ObjectId.cache, raised[8].id));
    const added = adapter.objectId(FullNodeId.init(.{ .value = 3 }, .init(0)));
    const removed = adapter.objectId(FullNodeId.init(.{ .value = 2 }, .init(0)));
    try testing.expect(std.meta.eql(FullNodeId.init(.{ .value = 3 }, .init(0)), raised[0].cache_item.?.id));
    try testing.expect(std.meta.eql(added, raised[4].any_data.address));
    try testing.expect(std.meta.eql(removed, raised[5].any_data.address));
    try testing.expect(std.meta.eql(removed, raised[8].any_data.address));
}

test "adapter notification fail-N retains owned event prefix after tree commit" {
    const gpa = testing.allocator;
    const allocation_attempt_bound = 128;
    var saw_partial = false;
    for (0..allocation_attempt_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var adapter = PlatformAdapter.init(gpa, 9, false);
        defer adapter.deinit();
        try adapter.apply(try notificationUpdate(gpa, .{
            .initial = true,
            .role = .root_web_area,
            .busy = true,
            .live = true,
        }));
        clearNotificationEvents(&adapter);
        const update = try notificationUpdate(gpa, .{
            .initial = false,
            .role = .root_web_area,
            .busy = false,
            .changed = true,
            .live = true,
        });
        adapter.gpa = failing.allocator();
        try adapter.apply(update);
        try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
        const root = adapter.tree.?.stateOf().root();
        try testing.expectEqualStrings("After", schema.strings.label(&root.data().properties).?);
        const raised = adapter.raised.items.items;
        const expected_members = [_][]const u8{
            "StateChanged",   "PropertyChange", "Announcement",
            "PropertyChange", "PropertyChange", "LoadComplete",
        };
        try testing.expect(raised.len <= expected_members.len);
        for (raised, 0..) |event, index| {
            try testing.expectEqualStrings(expected_members[index], event.member);
            if (index == 1 or index == 2) {
                try testing.expectEqualStrings("After", event.any_data.text);
            }
            if (index == 3) {
                try testing.expectEqualStrings("New description", event.any_data.text);
            }
        }
        if (adapter.last_event_error) |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            if (raised.len != 0) saw_partial = true;
            continue;
        }
        try testing.expectEqual(expected_members.len, raised.len);
        try testing.expect(saw_partial);
        return;
    }
    return error.AllocationAttemptBoundExceeded;
}

fn expectFocusTransfer(adapter: *const PlatformAdapter) !void {
    var focused_count: usize = 0;
    var old_focusable_count: usize = 0;
    var new_focusable_count: usize = 0;
    for (adapter.raised.items.items) |event| {
        try testing.expectEqual(events.Kind.object, event.kind);
        try testing.expectEqualStrings("StateChanged", event.member);
        try testing.expectEqual(events.AnyData.none, event.any_data);
        try testing.expectEqual(@as(i32, 0), event.detail3);
        try testing.expectEqual(@as(usize, 0), event.properties.count());
        const old_id = adapter.objectId(FullNodeId.init(.{ .value = 1 }, .init(0)));
        const new_id = adapter.objectId(FullNodeId.init(.{ .value = 2 }, .init(0)));
        if (std.mem.eql(u8, event.detail1, "focused")) {
            try testing.expect(focused_count < 2);
            try testing.expectEqual(@as(i32, if (focused_count == 0) 1 else 0), event.detail2);
            try testing.expect(std.meta.eql(if (focused_count == 0) new_id else old_id, event.id));
            focused_count += 1;
        } else {
            // Upstream NodeWrapper::state includes focus membership in Focusable.
            try testing.expectEqualStrings("focusable", event.detail1);
            if (std.meta.eql(old_id, event.id)) {
                try testing.expectEqual(@as(i32, 0), event.detail2);
                old_focusable_count += 1;
            } else {
                try testing.expect(std.meta.eql(new_id, event.id));
                try testing.expectEqual(@as(i32, 1), event.detail2);
                new_focusable_count += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 2), focused_count);
    try testing.expectEqual(@as(usize, 1), old_focusable_count);
    try testing.expectEqual(@as(usize, 1), new_focusable_count);
}

test "adapter node updates do not duplicate the focus slot" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, true);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 2));
    clearNotificationEvents(&adapter);
    var update: schema.TreeUpdate = .{ .focus = .{ .value = 2 } };
    try update.pushNode(gpa, .{ .value = 2 }, schema.Node.init(gpa, .button));
    try adapter.apply(update);
    try testing.expect(adapter.last_event_error == null);
    try expectFocusTransfer(&adapter);
}

test "native lifecycle regression focus loss emits deactivate and unfocused" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 3, true);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 2));
    clearNotificationEvents(&adapter);
    try adapter.updateWindowFocusState(false);
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 3), raised.len);
    try testing.expectEqualStrings("Deactivate", raised[0].member);
    try testing.expectEqual(events.Kind.window, raised[0].kind);
    try testing.expectEqualStrings("StateChanged", raised[1].member);
    try testing.expectEqualStrings("active", raised[1].detail1);
    try testing.expectEqual(@as(i32, 0), raised[1].detail2);
    try testing.expectEqualStrings("StateChanged", raised[2].member);
    try testing.expectEqualStrings("focused", raised[2].detail1);
    try testing.expectEqual(@as(i32, 0), raised[2].detail2);
    for (raised) |event| {
        try testing.expectEqualStrings("siiva{sv}", event.bodySignature());
        try testing.expectEqual(@as(usize, 0), event.properties.count());
    }
}

test "native lifecycle regression focus transfer uses ordered state changes" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 3, true);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 2));
    clearNotificationEvents(&adapter);
    try adapter.apply(.{ .focus = .{ .value = 2 } });
    try testing.expect(adapter.last_event_error == null);
    try expectFocusTransfer(&adapter);
}

fn textNotificationUpdate(
    gpa: std.mem.Allocator,
    initial: bool,
    value: []const u8,
    lengths: []const u8,
    anchor: usize,
    focus: usize,
) !schema.TreeUpdate {
    var update: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    errdefer update.deinit(gpa);
    if (initial) update.tree = schema.TreeInfo.init(.{ .value = 1 });
    {
        var document = schema.Node.init(gpa, .text_input);
        errdefer document.deinit();
        try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 2 }});
        try schema.option.setTextSelection(&document.properties, .{
            .anchor = .{ .node_id = .{ .value = 2 }, .character_index = anchor },
            .focus = .{ .node_id = .{ .value = 2 }, .character_index = focus },
        });
        try update.pushNode(gpa, .{ .value = 1 }, document);
    }
    {
        var run = schema.Node.init(gpa, .text_run);
        errdefer run.deinit();
        try schema.strings.setValue(&run.properties, value);
        try schema.vectors.setCharacterLengths(&run.properties, lengths);
        try update.pushNode(gpa, .{ .value = 2 }, run);
    }
    return update;
}

test "native lifecycle regression Unicode text diff is ordered and owned" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, true);
    defer adapter.deinit();
    try adapter.apply(try textNotificationUpdate(gpa, true, "é猫z", &.{ 2, 3, 1 }, 0, 0));
    clearNotificationEvents(&adapter);
    try adapter.apply(try textNotificationUpdate(gpa, false, "é🙂z", &.{ 2, 4, 1 }, 0, 0));
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 2), raised.len);
    for (raised, 0..) |event, index| {
        try testing.expectEqualStrings("TextChanged", event.member);
        try testing.expectEqualStrings(if (index == 0) "delete" else "insert", event.detail1);
        try testing.expectEqual(@as(i32, 1), event.detail2);
        try testing.expectEqual(@as(i32, 1), event.detail3);
        try testing.expectEqualStrings(if (index == 0) "猫" else "🙂", event.any_data.text);
        try testing.expect(event.owned_text != null);
        try testing.expectEqualStrings("siiva{sv}", event.bodySignature());
    }
    try adapter.apply(try textNotificationUpdate(gpa, false, "éQz", &.{ 2, 1, 1 }, 0, 0));
    try testing.expectEqualStrings("猫", adapter.raised.items.items[0].any_data.text);
    try testing.expectEqualStrings("🙂", adapter.raised.items.items[1].any_data.text);
}

test "native lifecycle regression text selection precedes Unicode caret" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, true);
    defer adapter.deinit();
    try adapter.apply(try textNotificationUpdate(gpa, true, "é🙂z", &.{ 2, 4, 1 }, 0, 0));
    clearNotificationEvents(&adapter);
    try adapter.apply(try textNotificationUpdate(gpa, false, "é🙂z", &.{ 2, 4, 1 }, 0, 2));
    try testing.expectEqual(@as(usize, 2), adapter.raised.count());
    try expectNotification(adapter.raised.items.items[0], .{ .member = "TextSelectionChanged" });
    try expectNotification(adapter.raised.items.items[1], .{
        .member = "TextCaretMoved",
        .detail2 = 2,
    });
    clearNotificationEvents(&adapter);
    try adapter.apply(try textNotificationUpdate(gpa, false, "é🙂z", &.{ 2, 4, 1 }, 2, 2));
    try testing.expectEqual(@as(usize, 1), adapter.raised.count());
    try expectNotification(adapter.raised.items.items[0], .{ .member = "TextSelectionChanged" });
}

test "native lifecycle regression typed notification failure follows commit" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, true);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 1));
    clearNotificationEvents(&adapter);
    var update: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    var root = schema.Node.init(gpa, .window);
    try schema.option.setBounds(&root.properties, schema.rectInit(3e9, 0, 3e9 + 10, 10));
    try update.pushNode(gpa, .{ .value = 1 }, root);
    try adapter.apply(update);
    try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
    try testing.expectEqual(@as(f64, 3e9), schema.option.bounds(
        &adapter.tree.?.stateOf().root().data().properties,
    ).?.x0);
    try testing.expect(adapter.last_event_error != null);
    try testing.expectEqual(error.GeometryOutOfRange, adapter.last_event_error.?);
}

test "native lifecycle regression focus fail-N distinguishes recovery rejection from notification failure" {
    const gpa = testing.allocator;
    const allocation_attempt_bound = 256;
    for ([_]bool{ false, true }) |dirty| {
        var saw_rejection = false;
        var saw_notification_failure = false;
        for (0..allocation_attempt_bound) |fail_index| {
            var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
            var adapter = PlatformAdapter.init(gpa, 9, true);
            defer adapter.deinit();
            try adapter.apply(try chainUpdate(gpa, 2));
            clearNotificationEvents(&adapter);
            // Clean focus changes allocate only notifications. Dirty recovery allocates before commit.
            adapter.tree.?.working_state_dirty = dirty;
            adapter.tree.?.gpa = failing.allocator();
            adapter.gpa = failing.allocator();
            adapter.updateWindowFocusState(false) catch |failure| {
                saw_rejection = true;
                try testing.expectEqual(error.OutOfMemory, failure);
                try testing.expect(dirty);
                try testing.expect(adapter.is_host_focused);
                try testing.expect(adapter.tree.?.stateOf().is_host_focused);
                try testing.expectEqual(@as(usize, 0), adapter.raised.count());
                adapter.tree.?.gpa = gpa;
                adapter.gpa = gpa;
                try adapter.updateWindowFocusState(false);
                try testing.expect(!adapter.is_host_focused);
                try testing.expect(!adapter.tree.?.stateOf().is_host_focused);
                continue;
            };
            try testing.expect(!adapter.is_host_focused);
            try testing.expect(!adapter.tree.?.stateOf().is_host_focused);
            try testing.expectEqual(@as(u64, 1), adapter.applied_updates);
            const raised = adapter.raised.items.items;
            const expected_members = [_][]const u8{ "Deactivate", "StateChanged", "StateChanged" };
            try testing.expect(raised.len <= expected_members.len);
            for (raised, 0..) |event, index| {
                try testing.expectEqualStrings(expected_members[index], event.member);
                if (index != 0) {
                    try testing.expectEqualStrings(if (index == 1) "active" else "focused", event.detail1);
                    try testing.expectEqual(@as(i32, 0), event.detail2);
                }
            }
            if (adapter.last_event_error) |failure| {
                saw_notification_failure = true;
                try testing.expectEqual(error.OutOfMemory, failure);
                adapter.tree.?.gpa = gpa;
                adapter.gpa = gpa;
                clearNotificationEvents(&adapter);
                try adapter.updateWindowFocusState(false);
                try testing.expectEqual(@as(usize, 0), adapter.raised.count());
                continue;
            }
            try testing.expectEqual(expected_members.len, raised.len);
            try testing.expectEqual(dirty, saw_rejection);
            try testing.expect(saw_notification_failure);
            break;
        } else return error.AllocationAttemptBoundExceeded;
    }
}

test "native lifecycle regression update fail-N preserves committed diff baseline" {
    const gpa = testing.allocator;
    const allocation_attempt_bound = 256;
    var saw_rejection = false;
    for (0..allocation_attempt_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var adapter = PlatformAdapter.init(gpa, 9, false);
        defer adapter.deinit();
        try adapter.apply(try notificationUpdate(gpa, .{
            .initial = true,
            .role = .button,
            .busy = false,
        }));
        clearNotificationEvents(&adapter);
        const update = try notificationUpdate(gpa, .{
            .initial = false,
            .role = .button,
            .busy = true,
            .changed = true,
            .child = 2,
        });
        adapter.tree.?.gpa = failing.allocator();
        adapter.apply(update) catch |failure| {
            saw_rejection = true;
            try testing.expectEqual(error.OutOfMemory, failure);
            try testing.expectEqual(@as(u64, 1), adapter.applied_updates);
            try testing.expectEqual(@as(usize, 1), adapter.nodeCount());
            try testing.expectEqualStrings("Before", schema.strings.label(
                &adapter.tree.?.stateOf().root().data().properties,
            ).?);
            try testing.expectEqual(@as(usize, 0), adapter.raised.count());
            adapter.tree.?.gpa = gpa;
            try adapter.apply(try notificationUpdate(gpa, .{
                .initial = false,
                .role = .button,
                .busy = true,
                .changed = true,
                .child = 2,
            }));
            try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
            try testing.expectEqual(@as(usize, 2), adapter.nodeCount());
            continue;
        };
        try testing.expect(saw_rejection);
        try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
        try testing.expectEqualStrings("After", schema.strings.label(
            &adapter.tree.?.stateOf().root().data().properties,
        ).?);
        return;
    }
    return error.AllocationAttemptBoundExceeded;
}

test "native lifecycle regression initial window creation precedes focus state" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, true);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 2));
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 4), raised.len);
    try testing.expectEqualStrings("AddAccessible", raised[0].member);
    try testing.expectEqualStrings("ChildrenChanged", raised[1].member);
    try testing.expectEqualStrings("add", raised[1].detail1);
    try testing.expect(std.meta.eql(ObjectId.root, raised[1].id));
    try testing.expectEqual(@as(i32, 0), raised[1].detail2);
    try testing.expect(std.meta.eql(adapter.objectId(
        FullNodeId.init(.{ .value = 1 }, .init(0)),
    ), raised[1].any_data.address));
    try testing.expectEqualStrings("AddAccessible", raised[2].member);
    try expectNotification(raised[3], .{
        .member = "StateChanged",
        .detail1 = "focused",
        .detail2 = 1,
    });
}

test "native lifecycle regression cache snapshot survives updates removal and close" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, true);
    defer adapter.deinit();
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = true,
        .role = .window,
        .busy = true,
        .child = 2,
        .live = true,
    }));
    var snapshots: std.ArrayList(events.Event) = .empty;
    defer snapshots.deinit(gpa);
    defer for (snapshots.items) |*event| event.deinit(gpa);
    try adapter.raised.drainInto(gpa, &snapshots);
    const root = snapshots.items[0].cache_item.?;
    const child = snapshots.items[2].cache_item.?;
    try testing.expectEqual(@as(usize, 9), root.adapter_id);
    try testing.expectEqualStrings("Before", root.name);
    try testing.expectEqualStrings("Old description", root.description);
    try testing.expect(std.meta.eql(node_notifications.NodeIdOrRoot.root, root.parent));
    try testing.expectEqual(@as(i32, 0), root.index_in_parent);
    try testing.expectEqual(@as(i32, 1), root.child_count);
    try testing.expect(root.interfaces.bits != 0);
    try testing.expect(root.states.bits != 0);
    try testing.expect(@backingInt(root.role) != 0);
    try testing.expect(std.meta.eql(root.id, child.parent.node));
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .window,
        .busy = false,
        .changed = true,
        .child = 3,
        .live = true,
    }));
    const removed = adapter.raised.items.items[adapter.raised.count() - 1];
    try testing.expectEqualStrings("RemoveAccessible", removed.member);
    try testing.expect(std.meta.eql(adapter.objectId(child.id), removed.any_data.address));
    try testing.expectEqualStrings("(so)", removed.bodySignature());
    adapter.deinit();
    try testing.expectEqualStrings("Before", root.name);
    try testing.expectEqualStrings("Old description", root.description);
    try testing.expectEqualStrings("((so)(so)(so)iiassusau)", snapshots.items[0].bodySignature());
}

test "native lifecycle regression initial registration excludes hidden subtrees" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    var update = try chainUpdate(gpa, 3);
    schema.flags.setHidden(&update.nodes.items[1].node.flags, true);
    try adapter.apply(update);
    try testing.expectEqual(@as(usize, 3), adapter.nodeCount());
    try testing.expectEqual(@as(usize, 2), adapter.raised.count());
    try testing.expectEqualStrings("AddAccessible", adapter.raised.items.items[0].member);
    try testing.expectEqual(@as(i32, 0), adapter.raised.items.items[0].cache_item.?.child_count);
    try testing.expectEqualStrings("ChildrenChanged", adapter.raised.items.items[1].member);
}

test "native lifecycle regression removal queues app child and retains typed error" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.apply(try chainUpdate(gpa, 1));
    clearNotificationEvents(&adapter);
    adapter.announceRemoval();
    const removed = adapter.raised.items.items[0];
    try testing.expectEqualStrings("ChildrenChanged", removed.member);
    try testing.expectEqualStrings("remove", removed.detail1);
    try testing.expectEqual(@as(i32, -1), removed.detail2);
    try testing.expect(std.meta.eql(ObjectId.root, removed.id));
    try testing.expect(std.meta.eql(adapter.objectId(adapter.tree.?.stateOf().rootId()), removed.any_data.address));
    clearNotificationEvents(&adapter);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    adapter.gpa = failing.allocator();
    adapter.announceRemoval();
    try testing.expectEqual(error.OutOfMemory, adapter.last_event_error.?);
    try testing.expect(adapter.hasTree());
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());
}

test "native lifecycle regression bridges borrow refreshed live contexts" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try testing.expectError(error.Defunct, adapter.rootId());
    try testing.expectError(error.Defunct, adapter.platformRoot());
    const id = FullNodeId.init(.{ .value = 1 }, .init(0));
    try testing.expectError(error.Defunct, adapter.platformNode(id));
    var app = try app_context.AppContext.init(gpa, "Test");
    defer app.deinit();
    adapter.app = &app;
    try adapter.apply(try chainUpdate(gpa, 1));
    try testing.expectError(error.Defunct, adapter.rootId());
    try testing.expectError(error.Defunct, adapter.platformRoot());
    try testing.expectError(error.Defunct, adapter.platformNode(id));
    var context: app_context.NodeContext = .{
        .state = adapter.tree.?.stateOf(),
        .app = &app,
        .bounds = adapter.bounds,
        .sink = null,
        .gpa = gpa,
    };
    adapter.context = &context;
    try app.pushAdapter(adapter.id, &context);
    try testing.expect(std.meta.eql(id, try adapter.rootId()));
    const live = try adapter.platformNode(id);
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .window,
        .busy = false,
        .changed = true,
    }));
    try testing.expect(context.state == adapter.tree.?.stateOf());
    var name = try live.name(gpa);
    defer name.deinit(gpa);
    try testing.expectEqualStrings("After", name.items);
    _ = try adapter.platformRoot();
}

test "native lifecycle regression rejected update preserves next diff and typed cause" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = true,
        .role = .button,
        .busy = false,
    }));
    clearNotificationEvents(&adapter);
    adapter.last_event_error = error.GeometryOutOfRange;
    try testing.expectError(error.RootNotInTree, adapter.apply(.{
        .tree = schema.TreeInfo.init(.{ .value = 999 }),
        .focus = .{ .value = 1 },
    }));
    try testing.expectEqual(error.GeometryOutOfRange, adapter.last_event_error.?);
    try testing.expectEqual(@as(u64, 1), adapter.applied_updates);
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());
    try adapter.apply(try notificationUpdate(gpa, .{
        .initial = false,
        .role = .button,
        .busy = true,
        .changed = true,
    }));
    try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
    try testing.expectEqualStrings("After", schema.strings.label(&adapter.tree.?.stateOf().root().data().properties).?);
}

test "native lifecycle regression cache notification fail-N owns exact committed prefix" {
    const gpa = testing.allocator;
    const allocation_attempt_bound = 128;
    var saw_failure = false;
    for (0..allocation_attempt_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        var adapter = PlatformAdapter.init(gpa, 9, false);
        defer adapter.deinit();
        try adapter.apply(try notificationUpdate(gpa, .{
            .initial = true,
            .role = .window,
            .busy = false,
            .child = 2,
        }));
        clearNotificationEvents(&adapter);
        var update = try notificationUpdate(gpa, .{
            .initial = false,
            .role = .window,
            .busy = false,
            .child = 3,
        });
        try schema.strings.setLabel(&update.nodes.items[1].node.properties, "Added");
        try schema.strings.setDescription(&update.nodes.items[1].node.properties, "Owned description");
        adapter.gpa = failing.allocator();
        try adapter.apply(update);
        try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
        try testing.expect(adapter.tree.?.stateOf().nodeById(FullNodeId.init(.{ .value = 2 }, .init(0))) == null);
        const expected = [_][]const u8{
            "AddAccessible", "ChildrenChanged", "ChildrenChanged", "StateChanged", "RemoveAccessible",
        };
        const raised = adapter.raised.items.items;
        try testing.expect(raised.len <= expected.len);
        for (raised, 0..) |event, index| try testing.expectEqualStrings(expected[index], event.member);
        if (raised.len != 0) {
            try testing.expectEqualStrings("Added", raised[0].cache_item.?.name);
            try testing.expectEqualStrings("Owned description", raised[0].cache_item.?.description);
        }
        if (adapter.last_event_error) |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            saw_failure = true;
            continue;
        }
        try testing.expect(saw_failure);
        try testing.expectEqual(expected.len, raised.len);
        return;
    }
    return error.AllocationAttemptBoundExceeded;
}

test "native lifecycle regression focus gain orders window selection and Unicode caret" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    var initial = try textNotificationUpdate(gpa, true, "é猫z", &.{ 2, 3, 1 }, 0, 2);
    const window = built: {
        var node = schema.Node.init(gpa, .window);
        errdefer node.deinit();
        try schema.ids_props.setChildren(&node.properties, &.{.{ .value = 1 }});
        try schema.strings.setLabel(&node.properties, "Document");
        break :built node;
    };
    try initial.pushNode(gpa, .{ .value = 3 }, window);
    initial.tree = schema.TreeInfo.init(.{ .value = 3 });
    try adapter.apply(initial);
    clearNotificationEvents(&adapter);
    try adapter.updateWindowFocusState(true);
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 6), raised.len);
    try expectNotification(raised[0], .{ .kind = .window, .member = "Activate", .node = 3 });
    try testing.expectEqualStrings("Document", raised[0].any_data.text);
    try expectNotification(raised[1], .{ .member = "StateChanged", .node = 3, .detail1 = "active", .detail2 = 1 });
    try testing.expectEqualStrings("ActiveDescendantChanged", raised[2].member);
    try testing.expect(std.meta.eql(ObjectId.root, raised[2].id));
    try testing.expect(std.meta.eql(
        adapter.objectId(FullNodeId.init(.{ .value = 3 }, .init(0))),
        raised[2].any_data.address,
    ));
    try expectNotification(raised[3], .{ .member = "StateChanged", .detail1 = "focused", .detail2 = 1 });
    try expectNotification(raised[4], .{ .member = "TextSelectionChanged" });
    try expectNotification(raised[5], .{ .member = "TextCaretMoved", .detail2 = 2 });
    for (raised) |event| {
        try testing.expectEqualStrings("siiva{sv}", event.bodySignature());
        try testing.expectEqual(@as(usize, 0), event.properties.count());
    }
}

test "native lifecycle regression item state changes precede deduplicated container selection" {
    const gpa = testing.allocator;
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    var initial = try notificationUpdate(gpa, .{
        .initial = true,
        .role = .list_box,
        .busy = false,
        .child = 2,
    });
    try schema.ids_props.setChildren(&initial.nodes.items[0].node.properties, &.{
        .{ .value = 2 }, .{ .value = 3 },
    });
    initial.nodes.items[1].node.role = .list_box_option;
    try schema.enums.setSelected(&initial.nodes.items[1].node.properties, false);
    const third = built: {
        var node = schema.Node.init(gpa, .list_box_option);
        errdefer node.deinit();
        try schema.enums.setSelected(&node.properties, false);
        break :built node;
    };
    try initial.pushNode(gpa, .{ .value = 3 }, third);
    try adapter.apply(initial);
    clearNotificationEvents(&adapter);
    var delta: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    for ([_]u64{ 2, 3 }) |id| {
        const selected = built: {
            var node = schema.Node.init(gpa, .list_box_option);
            errdefer node.deinit();
            try schema.enums.setSelected(&node.properties, true);
            break :built node;
        };
        try delta.pushNode(gpa, .{ .value = id }, selected);
    }
    try adapter.apply(delta);
    const raised = adapter.raised.items.items;
    try testing.expectEqual(@as(usize, 3), raised.len);
    for (raised[0..2]) |event| {
        try testing.expectEqualStrings("StateChanged", event.member);
        try testing.expectEqualStrings("selected", event.detail1);
        try testing.expectEqual(@as(i32, 1), event.detail2);
    }
    try expectNotification(raised[2], .{ .member = "SelectionChanged" });
}

test "native lifecycle regression borrowed initial rejection preserves input owner" {
    const gpa = testing.allocator;
    var initial = try chainUpdate(gpa, 2);
    defer initial.deinit(gpa);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var adapter = PlatformAdapter.init(failing.allocator(), 9, true);
    defer adapter.deinit();
    try testing.expectError(error.OutOfMemory, adapter.applyBorrowed(&initial));
    try testing.expectEqual(@as(usize, 2), initial.nodes.items.len);
    try testing.expectEqual(schema.Role.window, initial.nodes.items[0].node.role);
    try testing.expectEqual(@as(u64, 2), schema.ids_props.children(
        &initial.nodes.items[0].node.properties,
    )[0].value);
    try testing.expect(!adapter.hasTree());
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());
    adapter.gpa = gpa;
    try adapter.applyBorrowed(&initial);
    try testing.expectEqual(@as(usize, 2), adapter.nodeCount());
    try testing.expectEqual(@as(usize, 4), adapter.raised.count());
}

test "native lifecycle regression borrowed updates retain caller ownership after notification error" {
    const gpa = testing.allocator;
    var initial = try notificationUpdate(gpa, .{
        .initial = true,
        .role = .window,
        .busy = false,
    });
    defer initial.deinit(gpa);
    var adapter = PlatformAdapter.init(gpa, 9, false);
    defer adapter.deinit();
    try adapter.applyBorrowed(&initial);
    clearNotificationEvents(&adapter);
    var delta = try notificationUpdate(gpa, .{
        .initial = false,
        .role = .window,
        .busy = true,
        .changed = true,
        .child = 2,
    });
    defer delta.deinit(gpa);
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    adapter.gpa = failing.allocator();
    try adapter.applyBorrowed(&delta);
    try testing.expectEqual(error.OutOfMemory, adapter.last_event_error.?);
    try testing.expectEqual(@as(u64, 2), adapter.applied_updates);
    try testing.expectEqual(@as(usize, 2), adapter.nodeCount());
    try testing.expectEqualStrings("After", schema.strings.label(
        &delta.nodes.items[0].node.properties,
    ).?);
    try testing.expectEqualStrings("Before", schema.strings.label(
        &initial.nodes.items[0].node.properties,
    ).?);
    try testing.expectEqual(@as(usize, 0), adapter.raised.count());
}
