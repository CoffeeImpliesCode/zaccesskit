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
//! Per-node properties come from an injected synchronous calculator. It borrows NodeRefs only
//! during the callback. The queue owns the resulting VARIANTs and provider references.
//!
//! **Loop bounds.** Three walks outside a test, each with the bound named
//! beside it: the filtered-children cursor inside `enqueueSelectionChanges`,
//! bounded by the cursor's own budget from `hierarchy.zig`; the two walks over
//! the selection map and over its two sets, each bounded by that collection's
//! length at the moment the walk starts. Nothing grows while they run.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const bindings = @import("bindings.zig");
const elements = @import("elements.zig");
const context_mod = @import("context.zig");
const filters = @import("filters.zig");
const queued_events = @import("queued_events.zig");
const syscalls = @import("syscalls.zig");
const util = @import("util.zig");

const EventId = syscalls.EventId;
const Platform = syscalls.Platform;
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

/// Exact query, provider, allocation, and automation errors from event construction.
pub const HandlerError = context_mod.ProviderError;

/// Runs on the update thread after inclusion filtering, before implied and live-region events.
/// NodeRefs are borrowed only for this call. The callback must not retain them or reenter the tree.
pub const PropertyCalculator = *const fn (
    gpa: std.mem.Allocator,
    platform: Platform,
    registry: *elements.Registry,
    queue: *queued_events.QueuedEvents,
    old: NodeRef,
    new: NodeRef,
) HandlerError!void;

/// The first exact cause. A nonempty failure means the partial queue must be cancelled, not raised.
pub const Failure = struct {
    first_error: ?HandlerError = null,

    pub fn isEmpty(self: Failure) bool {
        return self.first_error == null;
    }
};

/// The two sets one selection container accumulates, upstream
/// `SelectionChanges` at `adapter.rs:232-235`.
const SelectionChanges = struct {
    /// The nodes that became selected.
    added: NodeSet = .empty,
    /// The nodes that stopped being selected.
    removed: NodeSet = .empty,

    /// Releases both sets and leaves the value in its empty form, so a second
    /// call releases nothing and a read after the call answers the empty sets
    /// rather than freed storage.
    ///
    /// The last line is that reset, and it is the whole of this teardown:
    /// `self.* = .{}` puts both sets back to the value their declarations
    /// give them. Z030 wants `self.* = undefined` and cannot read this line.
    /// The rule counts a terminal state from a whole-receiver assign only on
    /// the literal `undefined`, and from a field assign only on a lifecycle
    /// name or a slice field. Neither set is either, so the reset is invisible
    /// to the rule and correct here. `undefined` would break the promise
    /// above rather than the rule, because the second call reads both fields.
    fn deinit(self: *SelectionChanges, gpa: std.mem.Allocator) void {
        self.added.deinit(gpa);
        self.removed.deinit(gpa);
        self.* = .{};
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
    /// Null disables per-node calculations for injected event-only tests.
    /// Native adapters must set their factory's calculator before processing changes.
    property_calculator: ?PropertyCalculator = null,
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
        automation: *const util.AutomationApi,
    ) Handler {
        std.debug.assert(queue.automation == automation);
        return .{ .gpa = gpa, .platform = platform, .registry = registry, .queue = queue };
    }

    /// Releases the two sets and the selection map.
    ///
    /// The registry and the queue are borrowed, so this call does not touch
    /// them. A slot the queue took ownership of is the queue's to release.
    ///
    /// The two collections the handler owns are left in their empty form and
    /// the failure is cleared, so a second call releases nothing. The two
    /// borrowed pointers are left as they are: they were never this value's to
    /// release, and resetting them would name storage the caller still holds.
    ///
    /// The last three lines are that reset, and Z030 cannot see it. The rule
    /// counts a terminal state from a whole-receiver assign of the literal
    /// `undefined`, or from a field assign whose name is a lifecycle name or
    /// whose type is a slice. `selection_changed`, `text_changed` and
    /// `failure` are none of those, and no other field is.
    /// `self.* = undefined` would take `gpa` and the two borrowed pointers
    /// with it, so the second call this function promises would read an
    /// allocator out of undefined memory.
    pub fn deinit(self: *Handler) void {
        const gpa = self.gpa;
        var containers = self.selection_changed.iterator();
        while (containers.next()) |entry| {
            entry.value_ptr.deinit(gpa);
        }
        self.selection_changed.deinit(gpa);
        self.text_changed.deinit(gpa);
        self.selection_changed = .empty;
        self.text_changed = .empty;
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

    fn record(self: *Handler, err: HandlerError) void {
        if (self.failure.first_error == null) self.failure.first_error = err;
    }

    /// Turns the selection sets into events, once the update has committed.
    ///
    /// This is the port of `enqueue_selection_changes` at `adapter.rs:125-229`.
    /// The caller must call it after `updateAndProcessChanges` and before it
    /// hands the queue out, because a selection event names a node the
    /// committed tree holds.
    ///
    /// Exact HandlerError tags are returned. The caller cancels the partial queue on failure.
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
            const slot = try self.registry.slotFor(self.platform, child.id());
            try self.pushSimple(slot, .selection_item_element_selected);
            try self.pushSelected(slot, false, true);
            var removed = changes.removed.iterator();
            while (removed.next()) |entry| {
                const removed_slot = try self.detachedSlotFor(entry.key_ptr.*, state);
                try self.pushSelected(removed_slot, true, false);
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
                const slot = try self.registry.slotFor(self.platform, node.id());
                try self.pushSimple(slot, .selection_invalidated);
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
    /// Returns exact HandlerError tags; queued owners remain available for cancellation.
    pub fn nodeAdded(self: *Handler, node: NodeRef) HandlerError!void {
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
        if (supportsSelectionItemPattern(node) and nodeIsSelected(node)) {
            try self.handleSelectionStateChange(node, true);
        }
    }

    /// One node the update rewrote. Upstream `node_updated` at
    /// `adapter.rs:269-339`.
    ///
    /// Calculates properties, then implied selection, live, dialog, and selection-item changes.
    /// Returns exact HandlerError tags; no NodeRef escapes this call.
    pub fn nodeUpdated(self: *Handler, old: NodeRef, new: NodeRef) HandlerError!void {
        if (!rawValuesEqual(old, new)) try self.insertTextChangeIfNeeded(new);
        const old_filtered = try filters.filter(old);
        if (try filters.filter(new) != .include) {
            if (old_filtered == .include) {
                if (consumer.node_ref.predicates.isDialog(old)) {
                    const slot = try self.registry.slotFor(self.platform, old.id());
                    try self.pushSimple(slot, .window_window_closed);
                }
                if (supportsSelectionItemPattern(old) and nodeIsSelected(old)) {
                    try self.handleSelectionStateChange(old, false);
                }
            }
            return;
        }

        if (self.property_calculator) |calculate| {
            try calculate(self.gpa, self.platform, self.registry, self.queue, old, new);
        }
        if (try consumer.text.query.supportsTextRanges(old)) {
            if (try consumer.text.query.supportsTextRanges(new) and !rawSelectionsEqual(old, new)) {
                const slot = try self.registry.slotFor(self.platform, new.id());
                try self.pushSimple(slot, .text_text_selection_changed);
            }
        }

        if (try liveRegionChanged(self.gpa, old, new, old_filtered != .include)) {
            const slot = try self.registry.slotFor(self.platform, new.id());
            try self.pushSimple(slot, .live_region_changed);
        }
        if (old_filtered != .include and consumer.node_ref.predicates.isDialog(new)) {
            const slot = try self.registry.slotFor(self.platform, new.id());
            try self.pushSimple(slot, .window_window_opened);
        }
        if (supportsSelectionItemPattern(new)) {
            const new_selected = nodeIsSelected(new);
            const old_selected = nodeIsSelected(old);
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
    /// Returns exact HandlerError tags from provider creation and queue growth.
    pub fn focusMoved(self: *Handler, new: ?NodeRef) HandlerError!void {
        const node = new orelse return;
        const slot = try self.registry.slotFor(self.platform, node.id());
        try self.pushSimple(slot, .automation_focus_changed);
    }

    /// One node the update removed. Upstream `node_removed` at
    /// `adapter.rs:347-369`.
    ///
    /// Drops registry ownership before any fallible notification work.
    pub fn nodeRemoved(self: *Handler, node: NodeRef) HandlerError!void {
        // Removal must release registry ownership even when a later tree query fails.
        _ = self.registry.removeSlot(self.platform, node.id());
        try self.insertTextChangeIfNeeded(node);
        if (try filters.filter(node) != .include) return;

        if (consumer.node_ref.predicates.isDialog(node)) {
            const slot = try self.newDetachedSlot(node.id());
            try self.pushSimple(slot, .window_window_closed);
        }
        if (supportsSelectionItemPattern(node)) {
            try self.handleSelectionStateChange(node, false);
        }
    }

    // --- The helpers `adapter.rs` writes -------------------------------------

    /// Queues a text change for the parent of `node` when `node` is a text run.
    ///
    /// Upstream `insert_text_change_if_needed` at `adapter.rs:77-84`.
    ///
    /// Returns exact HandlerError tags from tree queries, provider creation, and queue growth.
    fn insertTextChangeIfNeeded(self: *Handler, node: NodeRef) HandlerError!void {
        if (consumer.node_ref.properties.role(node) != .text_run) return;
        const parent = try consumer.node_ref.hierarchy.filteredParent(
            node,
            filters.filter_fn,
        ) orelse return;
        try self.insertTextChangeForParent(parent);
    }

    /// Queues a text change for `parent` unless one is queued already.
    ///
    /// Upstream `insert_text_change_if_needed_parent` at `adapter.rs:54-75`.
    ///
    /// Returns exact HandlerError tags. Failed enqueue rolls back text-change deduplication.
    fn insertTextChangeForParent(self: *Handler, parent: NodeRef) HandlerError!void {
        if (!try consumer.text.query.supportsTextRanges(parent)) return;
        const entry = try self.text_changed.getOrPut(self.gpa, parent.id());
        if (entry.found_existing) return;
        errdefer {
            const removed = self.text_changed.orderedRemove(parent.id());
            std.debug.assert(removed);
        }
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
    /// Returns exact HandlerError tags. Detached slots are queue-owned after transfer succeeds.
    fn detachedSlotFor(
        self: *Handler,
        node_id: FullNodeId,
        state: *const TreeState,
    ) HandlerError!*const ProviderSlot {
        if (state.nodeById(node_id) != null) return self.registry.slotFor(self.platform, node_id);
        return self.newDetachedSlot(node_id);
    }

    fn newDetachedSlot(self: *Handler, node_id: FullNodeId) HandlerError!*const ProviderSlot {
        const slot = try self.registry.detachedSlotFor(self.platform, node_id);
        self.queue.takeOwnership(slot) catch |err| {
            elements.Registry.releaseSlot(self.registry.gpa, self.platform, slot);
            return err;
        };
        return slot;
    }

    fn pushSimple(
        self: *Handler,
        slot: *const ProviderSlot,
        event_id: EventId,
    ) HandlerError!void {
        try self.queue.append(.{ .simple = .{ .slot = slot, .event_id = event_id } });
    }

    fn pushSelected(
        self: *Handler,
        slot: *const ProviderSlot,
        old: bool,
        new: bool,
    ) HandlerError!void {
        try self.queue.appendBoolProperty(slot, .selection_item_is_selected, .{ .old = old, .new = new });
    }
};

fn rawValuesEqual(old: NodeRef, new: NodeRef) bool {
    const before = consumer.node_ref.set_state.rawValue(old);
    const after = consumer.node_ref.set_state.rawValue(new);
    if (before) |text| return std.mem.eql(u8, text, after orelse return false);
    return after == null;
}

fn rawSelectionsEqual(old: NodeRef, new: NodeRef) bool {
    const before = consumer.node_ref.set_state.rawTextSelection(old);
    const after = consumer.node_ref.set_state.rawTextSelection(new);
    if (before) |selection| return selection.*.eql((after orelse return false).*);
    return after == null;
}

/// Whether `node` announces a name at all.
///
/// Upstream `NodeWrapper::name` at `adapters/windows/src/node.rs:404-413`
/// answers `Some` exactly when the write it performed wrote something, and the
/// write is `write_value` for a node whose label comes from its value and
/// `write_label` for every other node. The port asks the same question through
/// the two consumer predicates those writes bottom out in, so it agrees with
/// upstream on the two cases a bare stored label gets wrong: a node whose name
/// comes from a `labelled_by` contributor, and a `label`-role node whose text
/// is its `value`.
///
/// **Errors.** `QueryError`, from the `labelled_by` walk and the value walk.
fn nodeHasName(node: NodeRef) QueryError!bool {
    if (consumer.node_ref.strings.labelComesFromValue(node))
        return consumer.node_ref.set_state.hasValue(node);
    return consumer.node_ref.strings.hasLabel(node);
}

/// The name `node` presents, as a UTF-8 buffer the caller releases.
///
/// This is the same question `nodeHasName` asks, with the text the caller
/// needs to compare two of them. Upstream builds a `WideString`; the port's
/// strings are UTF-8 from `schema` down and the only caller that needs the
/// text compares two names, so the encoding is not observable here.
///
/// Allocates, so it takes `gpa` first. A `null` answer means there is nothing
/// to release, and `error.OutOfMemory` leaves nothing behind.
fn nodeName(
    gpa: std.mem.Allocator,
    node: NodeRef,
) (QueryError || std.mem.Allocator.Error)!?std.ArrayList(u8) {
    const name = if (consumer.node_ref.strings.labelComesFromValue(node))
        consumer.node_ref.set_state.value(gpa, node)
    else
        consumer.node_ref.strings.label(gpa, node);
    // Both `label` and `value` collect through `std.Io.Writer.Allocating`, which
    // carries one error tag, so a failed growth arrives as `WriteFailed` and
    // means exactly `error.OutOfMemory`. `strings.zig:355-358` maps the same tag.
    return name catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

/// Whether the two nodes present different names.
///
/// Upstream compares the two `Option<WideString>` values `name` built at
/// `adapter.rs:313-318`, so a name against no name is a difference and two
/// names differ when their code units differ.
fn namesDiffer(
    gpa: std.mem.Allocator,
    old: NodeRef,
    new: NodeRef,
) (QueryError || std.mem.Allocator.Error)!bool {
    const before = try nodeName(gpa, old);
    defer releaseName(gpa, before);
    const after = try nodeName(gpa, new);
    defer releaseName(gpa, after);
    const old_text = before orelse return true;
    const new_text = after orelse return true;
    return !std.mem.eql(u8, old_text.items, new_text.items);
}

/// Releases what `nodeName` answered. A `null` answer owns nothing, so this
/// releases nothing.
///
/// The parameter is `const` because both call sites hold a `const` binding and
/// `ArrayList.deinit` takes `*Self`, so the mutable copy is local to this
/// function and the caller's binding is never touched.
fn releaseName(gpa: std.mem.Allocator, name: ?std.ArrayList(u8)) void {
    var held = name;
    if (held) |*text| text.deinit(gpa);
}

/// Whether `node` is the selected item.
///
/// Upstream `NodeWrapper::is_selected` at
/// `adapters/windows/src/node.rs:669-680`. A radio role answers through
/// `toggled`, so a radio button that states `aria-checked` and no
/// `aria-selected` is selected here, and the consumer half's `is_selected`
/// refuses to answer for that role at all.
fn nodeIsSelected(node: NodeRef) bool {
    const properties = consumer.node_ref.properties;
    return switch (properties.role(node)) {
        // `node.rs:672-674`: `toggled == Some(Toggled::True)`, so neither of the
        // tags `accesskit_consumer/src/node.rs:482` adds nor an absent state
        // counts as selected.
        .radio_button, .menu_item_radio => (properties.toggled(node) orelse return false) == .true_,
        // `node.rs:677-678`: `is_selected().unwrap_or(false)`.
        else => properties.isSelected(node) orelse false,
    };
}

/// Whether `node` announces itself as a live region.
///
/// A node with no name announces nothing, and a node whose inherited `live`
/// setting is `off` announces nothing.
///
/// **Errors.** `QueryError` from the name walks and the inherited `live` walk.
fn isLiveRegion(node: NodeRef) QueryError!bool {
    if (!try nodeHasName(node)) return false;
    const live = try consumer.node_ref.set_state.live(node);
    return live != .off;
}

/// Whether an update to `new` must raise `UIA_LiveRegionChangedEventId`.
///
/// Upstream `adapter.rs:313-318`. A live region announces itself when it has a
/// name, when its inherited `live` setting is not `off`, and when the update
/// changed that setting, or brought the node into the tree, or changed the
/// name. A name alone is not enough: an update that touches an unrelated
/// property of a live region announces nothing upstream, and raising the event
/// there makes a screen reader repeat itself on every update.
fn liveRegionChanged(
    gpa: std.mem.Allocator,
    old: NodeRef,
    new: NodeRef,
    old_was_filtered_out: bool,
) (QueryError || std.mem.Allocator.Error)!bool {
    if (!try nodeHasName(new)) return false;
    const live = try consumer.node_ref.set_state.live(new);
    if (live == .off) return false;
    if (old_was_filtered_out) return true;
    if (live != try consumer.node_ref.set_state.live(old)) return true;
    return namesDiffer(gpa, old, new);
}

/// Whether `node` supports the selection item pattern.
///
/// Upstream `NodeWrapper::is_selection_item_pattern_supported` at
/// `adapters/windows/src/node.rs:648-667`, transcribed arm for arm. The match
/// is on the role, so this is not the consumer half's `is_selectable` at
/// `accesskit_consumer/src/node.rs:620-623`, which asks a different question:
/// whether the node states a selection state at all. That method answers for a
/// role this one refuses and refuses for a role this one accepts.
fn supportsSelectionItemPattern(node: NodeRef) bool {
    const properties = consumer.node_ref.properties;
    // The read is hoisted out of the arm that uses it, because the five role
    // names and the read do not fit one line under the column limit.
    const states_aria_selected = properties.isSelected(node) != null;
    return switch (properties.role(node)) {
        // `node.rs:650-656`: a radio role exposes `SelectionItem.IsSelected`
        // when `aria-checked` is true or false, so the arm reads `toggled` and
        // never reads `is_selected`. `Toggled` carries a third tag at
        // `accesskit/src/lib.rs:486-490`, and `node.rs:655` names the other
        // two, so a mixed radio states no selection.
        .radio_button, .menu_item_radio => switch (properties.toggled(node) orelse return false) {
            .true_, .false_ => true,
            .mixed => false,
        },
        // `node.rs:657-663`: these five expose it when `aria-selected` is true
        // or false, so a stored false is the pattern supported.
        .list_box_option, .list_item, .menu_list_option, .tab, .tree_item => states_aria_selected,
        // `node.rs:664`, and the `TODO: tables (#29)` at `node.rs:650`. A
        // table exposes the pattern on every cell, so the arm reads nothing.
        .grid_cell => true,
        // `node.rs:665`. No other role supports the pattern, whatever the
        // node states, and no role in the match reads the disabled flag.
        else => false,
    };
}

// --- The four trampolines `TreeChangeHandler` declares ----------------------

fn nodeAddedSlot(context: *anyopaque, node: NodeRef) void {
    const self: *Handler = @ptrCast(@alignCast(context));
    self.nodeAdded(node) catch |err| self.record(err);
}

fn nodeUpdatedSlot(context: *anyopaque, old: NodeRef, new: NodeRef) void {
    const self: *Handler = @ptrCast(@alignCast(context));
    self.nodeUpdated(old, new) catch |err| self.record(err);
}

fn focusMovedSlot(context: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    _ = old;
    const self: *Handler = @ptrCast(@alignCast(context));
    self.focusMoved(new) catch |err| self.record(err);
}

fn nodeRemovedSlot(context: *anyopaque, node: NodeRef) void {
    const self: *Handler = @ptrCast(@alignCast(context));
    self.nodeRemoved(node) catch |err| self.record(err);
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

const adapter = @import("adapter.zig");

const ProviderFixture = struct {
    runtime: *std.Io.Threaded,
    owner: *adapter.WindowsAdapter,

    fn init() !ProviderFixture {
        if (!bindings.winapi_resolves) return error.SkipZigTest;
        const runtime = try testing.allocator.create(std.Io.Threaded);
        errdefer testing.allocator.destroy(runtime);
        runtime.* = .init(testing.allocator, .{});
        errdefer runtime.deinit();
        const owner = try adapter.testOwner(testing.allocator, runtime.io(), queued_events.testAutomationApi());
        return .{ .runtime = runtime, .owner = owner };
    }

    fn deinit(self: *ProviderFixture) void {
        self.owner.deinit();
        self.runtime.deinit();
        testing.allocator.destroy(self.runtime);
        self.* = undefined;
    }
};

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
    /// The pressed state the node carries, or none.
    toggled: ?schema.Toggled = null,
    /// Whether the node carries the disabled flag.
    disabled: bool = false,
    /// The value the node carries, or none. A `label`-role node names itself
    /// through this rather than through its label.
    value: ?[]const u8 = null,
    /// The local identifiers whose labels name this node, in order.
    labelled_by: []const u64 = &.{},
    text_selection: ?schema.TextSelection = null,
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
        if (spec.toggled) |value| try schema.enums.setToggled(&node.properties, value);
        if (spec.value) |text| try schema.strings.setValue(&node.properties, text);
        if (spec.text_selection) |selection|
            try schema.option.setTextSelection(&node.properties, selection);
        var labelled_by_ids: std.ArrayList(schema.NodeId) = .empty;
        defer labelled_by_ids.deinit(gpa);
        for (spec.labelled_by) |local| {
            try labelled_by_ids.append(gpa, .{ .value = local });
        }
        try schema.ids_props.setLabelledBy(&node.properties, labelled_by_ids.items);
        schema.flags.setDisabled(&node.flags, spec.disabled);
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

/// What `supportsSelectionItemPattern` answered, beside the role it switched
/// on, so that a failed comparison names the role and not a bare `true` or
/// `false`.
const PatternAnswer = struct {
    /// The role the match switched on.
    role: schema.Role,
    /// What the match answered for that role.
    supported: bool,
};

/// The role the node declares beside the answer that role gets.
fn answeredFor(node: NodeRef) PatternAnswer {
    return .{
        .role = consumer.node_ref.properties.role(node),
        .supported = supportsSelectionItemPattern(node),
    };
}

/// The roles `adapters/windows/src/node.rs:654-664` names, in the tags the
/// upstream Rust names map to. Every role outside this list answers `false` at
/// `node.rs:665`, whatever the node states.
const upstream_pattern_roles = [_]schema.Role{
    .radio_button,
    .menu_item_radio,
    .list_box_option,
    .list_item,
    .menu_list_option,
    .tab,
    .tree_item,
    .grid_cell,
};

test "a dialog node added queues the window opened event" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    try handler.nodeAdded(dialog);

    // The dialog is the only thing that queues anything, and it queues one.
    try testing.expectEqual(@as(usize, 1), queue.len());
    const only = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.window_window_opened, only.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        only.simple.slot,
    );
}

test "a text run queues its parent's text change at the front" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .document, .children = &.{4} },
        .{ .local = 3, .role = .dialog },
        .{ .local = 4, .role = .text_run },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
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
    const first = queue.at(0) orelse return error.NoQueuedEvent;
    const second = queue.at(1) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.text_text_changed, first.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        first.simple.slot,
    );
    try testing.expectEqual(EventId.window_window_opened, second.simple.event_id);
}

test "a text change is queued once however many runs changed" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 4 } },
        .{ .local = 2, .role = .document, .children = &.{3} },
        .{ .local = 3, .role = .text_run },
        .{ .local = 4, .role = .text_run },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
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
    const only = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.text_text_changed, only.simple.event_id);
}

test "the focus move queues the automation focus changed event" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .button },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    const button = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;

    // A focus change with no new node names no provider, so it queues nothing.
    try handler.focusMoved(null);
    try testing.expectEqual(@as(usize, 0), queue.len());

    try handler.focusMoved(button);
    try testing.expectEqual(@as(usize, 1), queue.len());
    const only = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.automation_focus_changed, only.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        only.simple.slot,
    );
}

test "a live region queues the live region changed event once" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .button, .label = "Save", .live = .polite },
        .{ .local = 3, .role = .button, .label = "Cancel" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
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
    const only = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.live_region_changed, only.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        only.simple.slot,
    );
}

test "one selected child takes the optimized selection path" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .list_box_option, .is_selected = true },
        .{ .local = 4, .role = .list_box_option, .is_selected = false },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    const chosen = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })) orelse
        return error.MissingNode;
    try handler.nodeAdded(chosen);
    try handler.enqueueSelectionChanges(state);

    // Upstream's optimized path: one selection event and one property change
    // for the only selected child, and nothing for the unselected one.
    try testing.expectEqual(@as(usize, 2), queue.len());
    const chosen_event = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(
        EventId.selection_item_element_selected,
        chosen_event.simple.event_id,
    );
    const change = queue.at(1) orelse return error.NoQueuedEvent;
    try testing.expectEqual(
        syscalls.PropertyId.selection_item_is_selected,
        change.property_changed.property_id,
    );
    try testing.expectEqual(@as(i16, 0), change.property_changed.old.raw.Anonymous.Anonymous.Anonymous.boolVal);
    try testing.expectEqual(@as(i16, -1), change.property_changed.new.raw.Anonymous.Anonymous.Anonymous.boolVal);
}

test "two selected children take the enumerated selection path" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .list_box_option, .is_selected = true },
        .{ .local = 4, .role = .list_box_option, .is_selected = true },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
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
    const first_event = queue.at(0) orelse return error.NoQueuedEvent;
    const third_event = queue.at(2) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.selection_item_element_selected, first_event.simple.event_id);
    try testing.expectEqual(EventId.selection_item_element_selected, third_event.simple.event_id);
}

test "more changes than the limit invalidate the container instead of enumerating" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
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

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    option_index = 0;
    while (option_index < option_count) : (option_index += 1) {
        const option = state.nodeById(
            state.rootId().withSameTree(.{ .value = 3 + option_index }),
        ) orelse return error.MissingNode;
        try handler.nodeAdded(option);
    }
    try handler.enqueueSelectionChanges(state);

    // One event, not two per option.
    try testing.expectEqual(@as(usize, 1), queue.len());
    const only = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.selection_invalidated, only.simple.event_id);
    try testing.expectEqual(
        try slotForLocal(&registry, platform, 2),
        only.simple.slot,
    );
}

test "a removed dialog queues the closed event on a provider the queue owns" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    try handler.nodeRemoved(dialog);

    try testing.expectEqual(@as(usize, 1), queue.len());
    const only = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.window_window_closed, only.simple.event_id);
    try testing.expect(registry.existingSlot(dialog.id()) == null);
    try testing.expectEqual(@as(usize, 0), registry.slots.count());
    try testing.expectEqual(dialog.id(), only.simple.slot.node_id.?);
    try testing.expectEqual(@as(u32, 2), only.simple.slot.ref_count.load(.monotonic));

    // Delivery releases both the event reference and its detached baseline reference.
    const report = queue.raise(platform);
    try testing.expectEqual(@as(usize, 1), report.total());
}

test "a slot that runs out of memory records it and the caller reads it" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var registry = elements.Registry.init(failing.allocator(), fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(failing.allocator(), queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(failing.allocator(), platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;

    // The slot cannot report, so it records. `takeFailure` is the only way out
    // and it answers the flag.
    try testing.expectEqual(@as(?Failure, null), handler.takeFailure());
    handler.nodeAdded(dialog) catch |err| handler.record(err);
    const recorded = handler.takeFailure() orelse return error.NoFailureRecorded;
    try testing.expectEqual(@as(?HandlerError, error.OutOfMemory), recorded.first_error);
    try testing.expect(!recorded.isEmpty());
    try testing.expectEqual(@as(?Failure, null), handler.takeFailure());
}

test "every handler error is recorded without changing its exact tag" {
    // Malformed trees are rejected before delivery; drive each tag through the shared recorder.
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    // Include newly added provider and automation tags without duplicating the error set.
    inline for (@typeInfo(HandlerError).error_set.error_names.?) |member| {
        const tag: HandlerError = @field(HandlerError, member);
        handler.record(tag);
        const recorded = handler.takeFailure() orelse return error.NoFailureRecorded;
        try testing.expectEqual(@as(?HandlerError, tag), recorded.first_error);
    }
}

test "the four slots of the change handler are all bound" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
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
    const no_memory: Failure = .{ .first_error = error.OutOfMemory };
    const query: Failure = .{ .first_error = error.TreeCycle };
    try testing.expect(neither.isEmpty());
    try testing.expect(!no_memory.isEmpty());
    try testing.expect(!query.isEmpty());
}

test "the selection item pattern answer is the match upstream writes" {
    // The defect this pins. `supportsSelectionItemPattern` read
    // `predicates.isSelectable`, which answers `accesskit_consumer/src/node.rs:620-623`,
    // and the two disagree on four groups: a radio role, which upstream reads
    // `toggled` for and never reads `is_selected` for; a grid cell, which
    // upstream answers `true` for whatever it carries; a role the match drops,
    // which upstream answers `false` for whatever it carries; and the disabled
    // flag, which upstream never reads. Every expected value below is the arm
    // `adapters/windows/src/node.rs:648-667` names, not the old answer.
    const cases = [_]struct {
        role: schema.Role,
        toggled: ?schema.Toggled = null,
        is_selected: ?bool = null,
        disabled: bool = false,
        supported: bool,
    }{
        // `node.rs:654-656`: a radio role reads `toggled` and answers true for
        // either tag it names.
        .{ .role = .radio_button, .toggled = .true_, .supported = true },
        .{ .role = .radio_button, .toggled = .false_, .supported = true },
        .{ .role = .menu_item_radio, .toggled = .true_, .supported = true },
        .{ .role = .menu_item_radio, .toggled = .false_, .supported = true },
        // `Toggled` has a third tag at `accesskit/src/lib.rs:486-490` and
        // `node.rs:655` names the other two, so a mixed radio answers false.
        .{ .role = .radio_button, .toggled = .mixed, .supported = false },
        .{ .role = .menu_item_radio, .toggled = .mixed, .supported = false },
        // No `toggled` at all answers false, and a selection state changes
        // nothing because the arm never reads one.
        .{ .role = .radio_button, .supported = false },
        .{ .role = .radio_button, .is_selected = true, .supported = false },
        .{ .role = .menu_item_radio, .is_selected = false, .supported = false },
        .{ .role = .menu_item_radio, .disabled = true, .is_selected = true, .supported = false },
        // `node.rs:659-663`: these five read `is_selected`, and a stored false
        // is the pattern supported.
        .{ .role = .list_box_option, .is_selected = true, .supported = true },
        .{ .role = .list_box_option, .is_selected = false, .supported = true },
        .{ .role = .list_item, .is_selected = true, .supported = true },
        .{ .role = .list_item, .is_selected = false, .supported = true },
        .{ .role = .menu_list_option, .is_selected = true, .supported = true },
        .{ .role = .menu_list_option, .is_selected = false, .supported = true },
        .{ .role = .tab, .is_selected = true, .supported = true },
        .{ .role = .tab, .is_selected = false, .supported = true },
        .{ .role = .tree_item, .is_selected = true, .supported = true },
        .{ .role = .tree_item, .is_selected = false, .supported = true },
        // The arm reads `is_selected` and nothing else, so a missing state and
        // a toggle state both answer false.
        .{ .role = .list_box_option, .supported = false },
        .{ .role = .tab, .toggled = .true_, .supported = false },
        // `node.rs:622` reads `is_disabled` and `node.rs` never does, so a
        // disabled item of a named role still supports the pattern.
        .{ .role = .list_box_option, .is_selected = true, .disabled = true, .supported = true },
        .{ .role = .tab, .is_selected = false, .disabled = true, .supported = true },
        // `node.rs:664`: a grid cell answers true whatever it carries.
        .{ .role = .grid_cell, .supported = true },
        .{ .role = .grid_cell, .disabled = true, .supported = true },
        .{ .role = .grid_cell, .toggled = .mixed, .supported = true },
        .{ .role = .grid_cell, .is_selected = true, .supported = true },
        // `node.rs:665`: every other role answers false whatever it carries,
        // which is the group the old predicate answered true for.
        .{ .role = .button, .is_selected = true, .supported = false },
        .{ .role = .check_box, .is_selected = true, .toggled = .true_, .supported = false },
        .{ .role = .grid, .is_selected = true, .supported = false },
        .{ .role = .list_box, .is_selected = true, .supported = false },
        .{ .role = .menu_item, .is_selected = true, .supported = false },
    };

    const gpa = testing.allocator;
    var child_ids: std.ArrayList(u64) = .empty;
    defer child_ids.deinit(gpa);
    var specs: std.ArrayList(NodeSpec) = .empty;
    defer specs.deinit(gpa);
    for (cases, 0..) |case, index| {
        // The first child sits at 2, because the root is 1.
        const local: u64 = @intCast(2 + index);
        try child_ids.append(gpa, local);
        try specs.append(gpa, .{
            .local = local,
            .role = case.role,
            .toggled = case.toggled,
            .is_selected = case.is_selected,
            .disabled = case.disabled,
        });
    }
    try specs.append(gpa, .{ .local = 1, .role = .window, .children = child_ids.items });
    var tree = try buildTree(gpa, 1, specs.items);
    defer tree.deinit();

    const state = tree.stateOf();
    for (cases, 0..) |case, index| {
        const local: u64 = @intCast(2 + index);
        const node = state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
            return error.MissingNode;
        const expected: PatternAnswer = .{ .role = case.role, .supported = case.supported };
        try testing.expectEqual(expected, answeredFor(node));
    }
}

test "no role outside the upstream match supports the selection item pattern" {
    // The sweep that covers the arm at `node.rs:665` over the whole role
    // domain, so a role added to `schema.Role` is named here without an edit.
    // Every node carries a selection state and a pressed state, because the
    // old predicate answered true for all of them and this one must not.
    const fields = @typeInfo(schema.Role).@"enum";
    const gpa = testing.allocator;
    var child_ids: std.ArrayList(u64) = .empty;
    defer child_ids.deinit(gpa);
    var specs: std.ArrayList(NodeSpec) = .empty;
    defer specs.deinit(gpa);
    inline for (fields.field_values, 0..) |field_value, index| {
        const local: u64 = @intCast(2 + index);
        try child_ids.append(gpa, local);
        try specs.append(gpa, .{
            .local = local,
            .role = @fromBackingInt(@intCast(field_value)),
            .toggled = .true_,
            .is_selected = true,
        });
    }
    try specs.append(gpa, .{ .local = 1, .role = .window, .children = child_ids.items });
    var tree = try buildTree(gpa, 1, specs.items);
    defer tree.deinit();

    const state = tree.stateOf();
    inline for (fields.field_values, 0..) |field_value, index| {
        const local: u64 = @intCast(2 + index);
        const node = state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
            return error.MissingNode;
        const role: schema.Role = @fromBackingInt(@intCast(field_value));
        var wanted = false;
        for (upstream_pattern_roles) |candidate| {
            if (candidate == role) wanted = true;
        }
        const expected: PatternAnswer = .{ .role = role, .supported = wanted };
        try testing.expectEqual(expected, answeredFor(node));
    }
}

test "a radio button reads its selection from the pressed state" {
    // The defect this pins. `nodeAdded` read
    // `properties.isSelected(node) orelse false`, which is
    // `accesskit_consumer/src/node.rs:912-914`, and that method never reads
    // `toggled`. Upstream `node.rs:669-680` reads `toggled` for a radio role, so
    // a radio button that states `aria-checked=true` and no `aria-selected` is
    // selected upstream and was not selected in the port.
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .radio_button, .toggled = .true_ },
        .{ .local = 3, .role = .radio_button, .toggled = .false_ },
        .{ .local = 4, .role = .radio_button },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    // Every one of the three carries the pattern, so the answer comes from the
    // pressed state alone: the first is selected, the second is not, and the
    // third states nothing.
    inline for (.{ 2, 3, 4 }) |local| {
        const node = state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
            return error.MissingNode;
        const wanted = local == 2;
        try testing.expectEqual(wanted, nodeIsSelected(node));
    }

    // The selected radio button queues its selection change, and the other two
    // queue nothing. Only the first radio role reaches the pattern answer, so
    // this pins the call site and not only the predicate.
    const chosen = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    try handler.nodeAdded(chosen);
    try handler.enqueueSelectionChanges(state);
    try testing.expectEqual(@as(usize, 2), queue.len());
    const event = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.selection_item_element_selected, event.simple.event_id);
    const change = queue.at(1) orelse return error.NoQueuedEvent;
    try testing.expectEqual(@as(i16, 0), change.property_changed.old.raw.Anonymous.Anonymous.Anonymous.boolVal);
    try testing.expectEqual(@as(i16, -1), change.property_changed.new.raw.Anonymous.Anonymous.Anonymous.boolVal);
}

test "a node names itself through a labelled by contributor and through its value" {
    // The defect this pins. `isLiveRegion` read
    // `strings.rawLabel(node) == null`, which is the node's own stored label and
    // nothing else. Upstream `name()` at `node.rs:404-413` writes the value for
    // a node whose label comes from its value and `write_label` for every other
    // node, and `write_label` follows `labelled_by`. So a node named by a
    // contributor and a `label`-role node carrying a value were both nameless
    // in the port, and neither announced itself as a live region.
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4, 5 } },
        // Named by node 5's label, with no label of its own.
        .{ .local = 2, .role = .button, .live = .polite, .labelled_by = &.{5} },
        // A label role names itself through its value, with no label of its own.
        .{ .local = 3, .role = .label, .live = .polite, .value = "Save" },
        // Neither a label nor a value and no contributor, so it has no name.
        .{ .local = 4, .role = .button, .live = .polite },
        // The contributor. Its role is not `label`, because
        // `labelNamesThrough` at `strings.zig:285-288` reads a label-role
        // contributor through its value, which is what makes node 3 above name
        // itself. A contributor with a stored label needs a role outside that
        // set.
        .{ .local = 5, .role = .image, .label = "Named by" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const state = tree.stateOf();
    // Node 2 is named by node 5, node 3 by its own value, and node 4 by nothing.
    for ([_]u64{ 2, 3, 4 }) |local| {
        const node = state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
            return error.MissingNode;
        const wanted = local != 4;
        try testing.expectEqual(wanted, try nodeHasName(node));

        const before = queue.len();
        try handler.nodeAdded(node);
        const announced = queue.len() > before;
        try testing.expectEqual(wanted, announced);
    }
}

test "an update announces a live region only when the live setting or the name changed" {
    // The defect this pins. `nodeUpdated` raised `UIA_LiveRegionChangedEventId`
    // for every update to a node that named itself and inherited a `live`
    // setting. Upstream `adapter.rs:313-318` raises it when the name is there,
    // the live setting is not `off`, and one of three things changed: the live
    // setting, whether the node was in the tree before, or the name. So an
    // update that touches an unrelated property of a live region announced
    // nothing upstream and announced itself in the port, and a screen reader
    // repeated itself on every update.
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    // Two trees with the same shape: one named "Save" and polite, the other
    // named "Saved" and polite. Node 2 is the live region in both.
    const before_specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .button, .label = "Save", .live = .polite },
    };
    const after_specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .button, .label = "Saved", .live = .polite },
    };
    var old_tree = try buildTree(gpa, 1, &before_specs);
    defer old_tree.deinit();
    var new_tree = try buildTree(gpa, 1, &after_specs);
    defer new_tree.deinit();

    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();

    const old_state = old_tree.stateOf();
    const new_state = new_tree.stateOf();
    const old_node = old_state.nodeById(old_state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    const new_node = new_state.nodeById(new_state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;

    // The name changed, so the update announces.
    try testing.expect(try liveRegionChanged(gpa, old_node, new_node, false));
    try handler.nodeUpdated(old_node, new_node);
    try testing.expectEqual(@as(usize, 1), queue.len());
    const event = queue.at(0) orelse return error.NoQueuedEvent;
    try testing.expectEqual(EventId.live_region_changed, event.simple.event_id);

    // The same name on both sides and the same live setting, so an update to an
    // unrelated property announces nothing.
    const unchanged = new_node;
    try testing.expect(!try liveRegionChanged(gpa, unchanged, unchanged, false));

    // A node that was not in the tree before announces itself, because it is
    // new to the client whatever its name says.
    try testing.expect(try liveRegionChanged(gpa, old_node, new_node, true));

    // A node with no name announces nothing whatever else changed.
    const bare_specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .button, .live = .polite },
    };
    var bare_tree = try buildTree(gpa, 1, &bare_specs);
    defer bare_tree.deinit();
    const bare_state = bare_tree.stateOf();
    const bare_node = bare_state.nodeById(bare_state.rootId().withSameTree(.{ .value = 2 })) orelse
        return error.MissingNode;
    try testing.expect(!try liveRegionChanged(gpa, old_node, bare_node, false));
}

test "updated raw text runs prepend one parent event before focus" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const before = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .document, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .text_run, .value = "before" },
        .{ .local = 4, .role = .text_run, .value = "before" },
    };
    const after = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .document, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .text_run, .value = "after" },
        .{ .local = 4, .role = .text_run, .value = "after" },
    };
    var old_tree = try buildTree(gpa, 1, &before);
    defer old_tree.deinit();
    var new_tree = try buildTree(gpa, 1, &after);
    defer new_tree.deinit();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();
    const old_state = old_tree.stateOf();
    const new_state = new_tree.stateOf();
    try handler.focusMoved(new_state.root());
    for ([_]u64{ 3, 4 }) |local| {
        const id = new_state.rootId().withSameTree(.{ .value = local });
        try handler.nodeUpdated(old_state.nodeById(id).?, new_state.nodeById(id).?);
    }
    try testing.expectEqual(@as(usize, 2), queue.len());
    try testing.expectEqual(EventId.text_text_changed, queue.at(0).?.simple.event_id);
    try testing.expectEqual(EventId.automation_focus_changed, queue.at(1).?.simple.event_id);
    try testing.expectEqual(try slotForLocal(&registry, platform, 2), queue.at(0).?.simple.slot);
}

test "removing a node drops its registry ownership but preserves queued events" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    var tree = try buildTree(gpa, 1, &.{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .dialog },
    });
    defer tree.deinit();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();
    const state = tree.stateOf();
    const dialog = state.nodeById(state.rootId().withSameTree(.{ .value = 2 })).?;
    try handler.nodeAdded(dialog);
    try handler.nodeRemoved(dialog);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
    try testing.expect(registry.existingSlot(dialog.id()) == null);
    try testing.expectEqual(@as(usize, 2), queue.len());
    try testing.expectEqual(EventId.window_window_opened, queue.at(0).?.simple.event_id);
    try testing.expectEqual(EventId.window_window_closed, queue.at(1).?.simple.event_id);
    const report = queue.raise(platform);
    try testing.expectEqual(@as(usize, 2), report.unavailable);
    queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
}

test "text selection events require range support on both nodes and changed raw selection" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const position: schema.TextPosition = .{
        .node_id = .{ .value = 3 },
        .character_index = 0,
    };
    const selection: schema.TextSelection = .{ .anchor = position, .focus = position };
    const extended: schema.TextSelection = .{
        .anchor = position,
        .focus = .{ .node_id = position.node_id, .character_index = 1 },
    };
    const cases = [_]struct {
        old_role: schema.Role,
        new_role: schema.Role,
        old_selection: ?schema.TextSelection,
        new_selection: ?schema.TextSelection,
        old_run: bool = true,
        new_run: bool = true,
        expected: bool,
    }{
        .{
            .old_role = .document,
            .new_role = .document,
            .old_selection = null,
            .new_selection = selection,
            .expected = true,
        },
        .{
            .old_role = .document,
            .new_role = .document,
            .old_selection = selection,
            .new_selection = null,
            .expected = true,
        },
        .{
            .old_role = .document,
            .new_role = .document,
            .old_selection = selection,
            .new_selection = extended,
            .expected = true,
        },
        .{
            .old_role = .document,
            .new_role = .document,
            .old_selection = selection,
            .new_selection = selection,
            .expected = false,
        },
        .{
            .old_role = .button,
            .new_role = .document,
            .old_selection = null,
            .new_selection = selection,
            .expected = false,
        },
        .{
            .old_role = .document,
            .new_role = .button,
            .old_selection = selection,
            .new_selection = null,
            .expected = false,
        },
        .{
            .old_role = .document,
            .new_role = .document,
            .old_run = false,
            .old_selection = null,
            .new_selection = selection,
            .expected = false,
        },
        .{
            .old_role = .document,
            .new_role = .document,
            .new_run = false,
            .old_selection = selection,
            .new_selection = null,
            .expected = false,
        },
    };
    for (cases) |case| {
        var old_tree = try buildTree(gpa, 1, &.{
            .{ .local = 1, .role = .window, .children = &.{2} },
            .{ .local = 2, .role = case.old_role, .children = &.{3}, .text_selection = case.old_selection },
            .{ .local = 3, .role = if (case.old_run) .text_run else .button, .value = "text" },
        });
        defer old_tree.deinit();
        var new_tree = try buildTree(gpa, 1, &.{
            .{ .local = 1, .role = .window, .children = &.{2} },
            .{ .local = 2, .role = case.new_role, .children = &.{3}, .text_selection = case.new_selection },
            .{ .local = 3, .role = if (case.new_run) .text_run else .button, .value = "text" },
        });
        defer new_tree.deinit();
        var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
        defer registry.deinit(platform);
        var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
        defer expectCleanup(queue.deinit(platform));
        var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
        defer handler.deinit();
        const id = old_tree.stateOf().rootId().withSameTree(.{ .value = 2 });
        try handler.nodeUpdated(old_tree.stateOf().nodeById(id).?, new_tree.stateOf().nodeById(id).?);
        try testing.expectEqual(@as(usize, if (case.expected) 1 else 0), queue.len());
        if (case.expected) {
            try testing.expectEqual(EventId.text_text_selection_changed, queue.at(0).?.simple.event_id);
        }
    }
}

test "property calculator failures preserve the first native error tag" {
    const Calculator = struct {
        fn calculate(
            _: std.mem.Allocator,
            _: Platform,
            _: *elements.Registry,
            _: *queued_events.QueuedEvents,
            _: NodeRef,
            _: NodeRef,
        ) HandlerError!void {
            return error.ArrayLocked;
        }
    };
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    var tree = try buildTree(gpa, 1, &.{.{ .local = 1, .role = .window }});
    defer tree.deinit();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();
    handler.property_calculator = Calculator.calculate;
    const root = tree.stateOf().root();
    const slots = handler.changeHandler();
    slots.node_updated.?(slots.ptr, root, root);
    handler.record(error.OutOfMemory);
    const failure = handler.takeFailure().?;
    try testing.expectEqual(error.ArrayLocked, failure.first_error.?);
    try testing.expect(handler.takeFailure() == null);
}

fn expectCleanup(report: anytype) void {
    testing.expect(report.first_error == null) catch @panic("Unexpected test cleanup failure");
}

test "unchanged raw text runs do not announce a text change" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const specs = [_]NodeSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .document, .children = &.{3} },
        .{ .local = 3, .role = .text_run, .value = "equal bytes" },
    };
    var old_tree = try buildTree(gpa, 1, &specs);
    defer old_tree.deinit();
    var new_tree = try buildTree(gpa, 1, &specs);
    defer new_tree.deinit();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();
    const id = old_tree.stateOf().rootId().withSameTree(.{ .value = 3 });
    try handler.nodeUpdated(old_tree.stateOf().nodeById(id).?, new_tree.stateOf().nodeById(id).?);
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "removal drops registry ownership even when text notification allocation fails" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    var tree = try buildTree(gpa, 1, &.{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .document, .children = &.{3} },
        .{ .local = 3, .role = .text_run, .value = "text" },
    });
    defer tree.deinit();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    const state = tree.stateOf();
    const run = state.nodeById(state.rootId().withSameTree(.{ .value = 3 })).?;
    const stored = try registry.slotFor(platform, run.id());
    try testing.expectEqual(stored, registry.existingSlot(run.id()).?);
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    var queue = queued_events.QueuedEvents.init(failing.allocator(), queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(failing.allocator(), platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();
    try testing.expectError(error.OutOfMemory, handler.nodeRemoved(run));
    try testing.expect(registry.existingSlot(run.id()) == null);
    try testing.expectEqual(@as(usize, 0), registry.nodeCount());
}

test "raw text precedes calculated properties then text selection and calculator failure stops" {
    const Calculator = struct {
        fn calculate(
            _: std.mem.Allocator,
            platform: Platform,
            registry: *elements.Registry,
            queue: *queued_events.QueuedEvents,
            _: NodeRef,
            new: NodeRef,
        ) HandlerError!void {
            const slot = try registry.slotFor(platform, new.id());
            const change = try queue.beginProperty(slot, .selection_item_is_selected);
            change.old = util.VariantOwner.fromI32(queue.automation, 1);
            change.new = util.VariantOwner.fromI32(queue.automation, 2);
        }
        fn fail(
            _: std.mem.Allocator,
            _: Platform,
            _: *elements.Registry,
            _: *queued_events.QueuedEvents,
            _: NodeRef,
            _: NodeRef,
        ) HandlerError!void {
            return error.ArrayLocked;
        }
    };
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    const caret: schema.TextPosition = .{
        .node_id = .{ .value = 3 },
        .character_index = 0,
    };
    const selection: schema.TextSelection = .{ .anchor = caret, .focus = caret };
    var old_tree = try buildTree(gpa, 1, &.{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .document, .children = &.{3} },
        .{ .local = 3, .role = .text_run, .value = "before" },
    });
    defer old_tree.deinit();
    var new_tree = try buildTree(gpa, 1, &.{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .document, .children = &.{3}, .text_selection = selection },
        .{ .local = 3, .role = .text_run, .value = "after" },
    });
    defer new_tree.deinit();
    const old_state = old_tree.stateOf();
    const new_state = new_tree.stateOf();
    const document_id = old_state.rootId().withSameTree(.{ .value = 2 });
    const run_id = old_state.rootId().withSameTree(.{ .value = 3 });
    inline for (.{ false, true }) |fail_calculation| {
        var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
        defer registry.deinit(platform);
        var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
        defer expectCleanup(queue.deinit(platform));
        var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
        defer handler.deinit();
        handler.property_calculator = if (fail_calculation) Calculator.fail else Calculator.calculate;
        const result = handler.nodeUpdated(old_state.nodeById(document_id).?, new_state.nodeById(document_id).?);
        if (fail_calculation) {
            try testing.expectError(error.ArrayLocked, result);
            try testing.expectEqual(@as(usize, 0), queue.len());
        } else {
            try result;
            try handler.nodeUpdated(old_state.nodeById(run_id).?, new_state.nodeById(run_id).?);
            try testing.expectEqual(@as(usize, 3), queue.len());
            try testing.expectEqual(EventId.text_text_changed, queue.at(0).?.simple.event_id);
            try testing.expectEqual(
                syscalls.PropertyId.selection_item_is_selected,
                queue.at(1).?.property_changed.property_id,
            );
            try testing.expectEqual(EventId.text_text_selection_changed, queue.at(2).?.simple.event_id);
        }
    }
}

test "raw text changes distinguish absent and present empty values" {
    const gpa = testing.allocator;
    var fixture = try ProviderFixture.init();
    defer fixture.deinit();
    const platform = adapter.testPlatform();
    var old_tree = try buildTree(gpa, 1, &.{
        .{ .local = 1, .role = .document, .children = &.{2} },
        .{ .local = 2, .role = .text_run },
    });
    defer old_tree.deinit();
    var new_tree = try buildTree(gpa, 1, &.{
        .{ .local = 1, .role = .document, .children = &.{2} },
        .{ .local = 2, .role = .text_run, .value = "" },
    });
    defer new_tree.deinit();
    var registry = elements.Registry.init(gpa, fixture.owner.context.weak());
    defer registry.deinit(platform);
    var queue = queued_events.QueuedEvents.init(gpa, queued_events.testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    var handler = Handler.init(gpa, platform, &registry, &queue, queued_events.testAutomationApi());
    defer handler.deinit();
    const id = old_tree.stateOf().rootId().withSameTree(.{ .value = 2 });
    try handler.nodeUpdated(old_tree.stateOf().nodeById(id).?, new_tree.stateOf().nodeById(id).?);
    try testing.expectEqual(@as(usize, 1), queue.len());
    try testing.expectEqual(EventId.text_text_changed, queue.at(0).?.simple.event_id);
}
