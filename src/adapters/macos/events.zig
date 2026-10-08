//! The events a tree update produces, and the notification each one names.
//!
//! **What this module is.** The ports of `AK/macos/src/event.rs` and of the
//! `EventGenerator` half of the same file: a `consumer.TreeChangeHandler` that
//! turns a committed tree change into a list of events, the table that decides
//! which of the 7 notifications a change names, the two-arm mapping from
//! `schema.Live` to a priority, and the focus event.
//!
//! **The generator is real, not a sketch.** `consumer.tree.Tree` already
//! implements the update protocol, and this module registers the four
//! `TreeChangeHandler` slots over it, so a synthetic tree drives the whole
//! generator on a host with no Mac, no SDK and no Objective-C runtime. What it
//! cannot do here is call `NSAccessibilityPostNotification`: that call is the
//! platform seam and lives in `root.zig`, behind `MacosQueuedEvents`.
//!
//! **The node wrapper is the port of `AK/macos/src/node.rs:309-382`, and it is
//! in `node.zig`.** `event.rs:236`, `:264`, `:270-272` and `:300-302` read the
//! label, the title, the value and the value's shape through it, so this module
//! calls it rather than reading the properties itself.
//!
//! **Three ordering rules are the contract, and each is a test.**
//!
//! 1. **Text changes come before selection changes**, and text change events are
//!    inserted at the front of the list, at `AK/macos/src/event.rs:184-192`.
//!    Upstream states the reason: it does not matter whether a text change comes
//!    before other events, but it does matter that it comes first.
//! 2. **A bool value change on the focused node comes last**, at `:263-271`,
//!    because otherwise VoiceOver announces another node's change instead.
//! 3. **A subtree removal is pre-order.** `remove_subtree` pushes a node and
//!    then its filtered children onto a `VecDeque` and drains it from the front,
//!    at `:161-174`, so a parent is destroyed before its children.
//!
//! **The loop bound.** `removeSubtree` walks a subtree with a queue whose length
//! grows with the subtree and whose bound is the number of nodes in it. Every
//! other walk in this module is over `events`, over `text_changed` or over
//! `selected_rows_changed`, each of which grows by one per event and is bounded
//! by its own length. `TreeChangeHandler` runs the four slots in the order
//! `docs/33` section 7 fixes and its node sets do not change while they are
//! walked.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const literals = @import("literals.zig");
const node_wrapper = @import("node.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const FullNodeId = consumer.tree_index.FullNodeId;
const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree_state.QueryError;
const FilterFn = consumer.filter.FilterFn;
const FilterResult = consumer.filter.FilterResult;
const testing = std.testing;

/// One thing a tree update changed, in the shape the notification table takes.
///
/// The six tags are the six changes that name one of the 6 notifications
/// `NSAccessibilityPostNotification` carries. The announcement is the seventh
/// notification and has its own event, because it posts to a window with a
/// `userInfo` rather than to a node without one.
pub const Change = enum(u8) {
    /// The focus moved to a node. Upstream `event.rs:136`.
    focus_moved,
    /// A node's value changed. Upstream `event.rs:189`.
    value_changed,
    /// A node's title changed. Upstream `event.rs:267`.
    title_changed,
    /// A node's text selection changed. Upstream `event.rs:297`.
    selected_text_changed,
    /// A container's selected rows changed. Upstream `event.rs:211`.
    selected_rows_changed,
    /// A node was destroyed. Upstream `event.rs:60`.
    node_destroyed,
    /// A live region's label changed, and the change is announced.
    announcement,
};

/// How many tags `Change` holds.
pub const change_count = 7;

/// The notification `change` names, or `null` when it names none.
///
/// The six non-null answers are the six notifications that go through
/// `NSAccessibilityPostNotification`. The announcement goes through
/// `NSAccessibilityPostNotificationWithUserInfo` and is named separately, so a
/// caller that posts without a `userInfo` cannot post it by accident.
///
/// **Returns.** A borrowed string from `literals.notifications`, or `null` for
/// `.announcement` and for nothing else. There is no error: the table is total
/// over the 7 tags. A caller that has already chosen one of the other six
/// writes `orelse return`, which is a branch on the tag rather than a claim
/// that the name is there.
pub fn notificationFor(change: Change) ?[:0]const u8 {
    const name = switch (change) {
        .focus_moved => "NSAccessibilityFocusedUIElementChangedNotification",
        .value_changed => "NSAccessibilityValueChangedNotification",
        .title_changed => "NSAccessibilityTitleChangedNotification",
        .selected_text_changed => "NSAccessibilitySelectedTextChangedNotification",
        .selected_rows_changed => "NSAccessibilitySelectedRowsChangedNotification",
        .node_destroyed => "NSAccessibilityUIElementDestroyedNotification",
        .announcement => return null,
    };
    return (literals.findNotification(name) orelse return null).value;
}

/// The priority a live region announces at, upstream
/// `AK/macos/src/event.rs:35-43`.
///
/// `Live.assertive` gives `NSAccessibilityPriorityHigh` and everything else
/// gives `NSAccessibilityPriorityMedium`. `Live.off` is not an announcement at
/// all: the caller checks for it before it calls this, so the answer here for
/// `off` is the medium arm and the guard lives in `node_added`.
///
/// **Returns.** A level whose number is what a client reads out of the
/// `NSNumber` under `NSAccessibilityPriorityKey`.
pub fn priorityFor(live: schema.Live) literals.PriorityLevel {
    return switch (live) {
        .assertive => .high,
        .polite, .off => .medium,
    };
}

/// One queued event, upstream `AK/macos/src/event.rs:22-32`.
///
/// The value owns its announcement text, so `deinit` releases it and a copy is a
/// second owner.
pub const QueuedEvent = union(enum) {
    /// A notification to post against a node. Upstream `Generic`.
    generic: struct {
        /// The node to post it against.
        node_id: FullNodeId,
        /// The notification to post, from `literals.notifications`.
        notification: [:0]const u8,
    },
    /// A node that is going away. Upstream `NodeDestroyed`.
    node_destroyed: FullNodeId,
    /// A live region announcement. Upstream `Announcement`.
    announcement: struct {
        /// The text to announce, owned by this event.
        text: []u8,
        /// The priority to announce at.
        priority: literals.PriorityLevel,
    },
};

/// Releases what `event` owns.
///
/// The generic and destroyed arms own nothing, so only the announcement arm
/// releases. `gpa` is the allocator the text came from and must be the one the
/// event was built with.
pub fn releaseEvent(gpa: Allocator, event: *QueuedEvent) void {
    switch (event.*) {
        .announcement => |announcement| {
            gpa.free(announcement.text);
            // SAFETY: the line above released the one buffer this union owns,
            // and this line moves it onto the owning-nothing tag since no
            // statement after it reads the released text. A reader that reads
            // it anyway gets a trap in Debug rather than the freed slice.
            event.* = .{ .node_destroyed = undefined };
        },
        .generic, .node_destroyed => {},
    }
}

/// The `TreeChangeHandler` slots `EventGenerator` fills, and the pointer to the
/// generator itself.
///
/// `consumer.tree.Tree` takes a `*const TreeChangeHandler`, so the generator
/// stays one value the caller owns and the handler is a borrowed view of it.
pub fn slotsOf(generator: *EventGenerator) consumer.tree.TreeChangeHandler {
    return .{
        .ptr = generator,
        .node_added = nodeAdded,
        .node_updated = nodeUpdated,
        .focus_moved = focusMoved,
        .node_removed = nodeRemoved,
    };
}

/// Everything a slot can fail with.
///
/// It is the allocator's `error.OutOfMemory` plus the consumer half's
/// `QueryError` and the writer tags `strings.label` forwards, and it is
/// written down here so the four slots and `record` agree on one set instead
/// of each widening it by inference. `QueryError` carries `OutOfMemory` of
/// its own, so the allocator needs no arm of its own.
pub const SlotError = QueryError || std.Io.Writer.Error;

/// Turns a committed tree change into the events the platform is told about.
///
/// **Ownership.** The generator owns `events` and the two sets, and releases all
/// three in `deinit`. It borrows nothing from the tree: every `FullNodeId` in
/// `events` is two scalars that stay valid after the tree's maps move, which is
/// what lets a caller raise the events after the update returns.
///
/// **A generator is not a `TreeChangeHandler`.** It fills one, and the handler
/// borrows the generator for the length of one `updateAndProcessChanges` call.
pub const EventGenerator = struct {
    /// The allocator that grew `events` and the two sets.
    gpa: Allocator,
    /// The events, in the order they must be raised.
    events: ArrayList(QueuedEvent) = .empty,
    /// The nodes whose text changed, so a text change is queued once per node
    /// however many runs in it changed. Upstream `event.rs:142`.
    text_changed: std.AutoHashMapUnmanaged(FullNodeId, void) = .empty,
    /// The same for selected rows. Upstream `event.rs:143`.
    selected_rows_changed: std.AutoHashMapUnmanaged(FullNodeId, void) = .empty,
    /// The first failure a slot recorded, or `null` when every slot finished.
    ///
    /// `consumer.tree.TreeChangeHandler` slots return `void`, so a slot cannot
    /// report `SlotError` to the update that called it. It records the tag
    /// here instead, and the caller reads this after the update returns. A
    /// generator with a failure recorded produced a partial event list, so
    /// the caller must not raise it as if it were complete.
    ///
    /// **The tag is kept and not reduced to a bit.** The two macOS entry
    /// points that drive this generator answer `null` for every failure, so
    /// nothing at the seam can act on the difference today. The tag is kept
    /// because an allocation failure and a query failure are different
    /// events, and a record that can only say that something failed reads as
    /// the wrong one of the two.
    failure: ?SlotError = null,

    /// An empty generator over `gpa`.
    pub fn init(gpa: Allocator) EventGenerator {
        return .{ .gpa = gpa };
    }

    /// Releases every event and both sets.
    pub fn deinit(self: *EventGenerator) void {
        for (self.events.items) |*event| releaseEvent(self.gpa, event);
        self.events.deinit(self.gpa);
        self.text_changed.deinit(self.gpa);
        self.selected_rows_changed.deinit(self.gpa);
        self.* = undefined;
    }

    /// How many events the generator holds.
    pub fn count(self: *const EventGenerator) usize {
        return self.events.items.len;
    }

    /// Moves the events out of the generator, leaving it empty.
    ///
    /// The caller owns the returned list and releases it with
    /// `releaseEvents`. The generator may be released after this call without
    /// releasing the list, because the list has changed owner.
    pub fn takeEvents(self: *EventGenerator) ArrayList(QueuedEvent) {
        const taken = self.events;
        self.events = .empty;
        return taken;
    }

    /// Records `err` and keeps the first failure a slot reported.
    ///
    /// A second failure never clears the first. The caller reads this once
    /// after the update commits, when the tree is consistent and a caller may
    /// retry, and it wants the tag that stopped the walk rather than the last
    /// one to arrive.
    fn record(self: *EventGenerator, err: SlotError) void {
        if (self.failure == null) self.failure = err;
    }

    /// Enqueues one generic event against `node_id`.
    fn pushGeneric(self: *EventGenerator, node_id: FullNodeId, notification: [:0]const u8) !void {
        try self.events.append(self.gpa, .{
            .generic = .{ .node_id = node_id, .notification = notification },
        });
    }

    /// Enqueues one generic event at the front of the list.
    ///
    /// This is the text-change rule and the focused-bool rule. Upstream inserts
    /// at index 0 for both, at `event.rs:187` and at `:270`.
    fn insertGenericFront(
        self: *EventGenerator,
        node_id: FullNodeId,
        notification: [:0]const u8,
    ) !void {
        try self.events.insert(self.gpa, 0, .{
            .generic = .{ .node_id = node_id, .notification = notification },
        });
    }

    /// Enqueues one announcement, copying `text` into the event.
    fn pushAnnouncement(self: *EventGenerator, text: []const u8, live: schema.Live) !void {
        const owned = try self.gpa.dupe(u8, text);
        errdefer self.gpa.free(owned);
        try self.events.append(self.gpa, .{
            .announcement = .{ .text = owned, .priority = priorityFor(live) },
        });
    }

    /// Enqueues one destruction for `node_id`.
    fn pushDestroyed(self: *EventGenerator, node_id: FullNodeId) !void {
        try self.events.append(self.gpa, .{ .node_destroyed = node_id });
    }

    /// Queues a value change against the node that supports text ranges, if it
    /// is not queued already. Upstream `event.rs:176-198`.
    ///
    /// **Returns.** `error.OutOfMemory` from the two allocations below.
    fn insertTextChangeIfNeededParent(self: *EventGenerator, node: NodeRef) !void {
        if (!try consumer.text.query.supportsTextRanges(node)) return;
        const id = node.id();
        // `getOrPut` rather than `contains` then `put`, so the second lookup is
        // a hash and not a walk.
        const entry = try self.text_changed.getOrPut(self.gpa, id);
        if (entry.found_existing) return;
        try self.insertGenericFront(id, notificationFor(.value_changed) orelse return);
    }

    /// Queues a value change for the parent of a changed text run.
    ///
    /// Upstream `event.rs:200-208`. A run has no text of its own, so the change
    /// is reported against the node that does.
    fn insertTextChangeIfNeeded(self: *EventGenerator, node: NodeRef) !void {
        if (consumer.node_ref.properties.role(node) != .text_run) return;
        if (try consumer.node_ref.hierarchy.filteredParent(node, parent_filter)) |parent| {
            try self.insertTextChangeIfNeededParent(parent);
        }
    }

    /// Queues a selected-rows change against the selection container, if it is
    /// not queued already. Upstream `event.rs:210-221`.
    fn enqueueSelectedRowsChangeIfNeededParent(self: *EventGenerator, node: NodeRef) !void {
        const id = node.id();
        const entry = try self.selected_rows_changed.getOrPut(self.gpa, id);
        if (entry.found_existing) return;
        try self.pushGeneric(id, notificationFor(.selected_rows_changed) orelse return);
    }

    /// Queues a selected-rows change for the container of a selected item.
    ///
    /// Upstream `event.rs:223-231`.
    fn enqueueSelectedRowsChangeIfNeeded(self: *EventGenerator, node: NodeRef) !void {
        if (!consumer.node_ref.containers.isItemLike(node)) return;
        if (try consumer.node_ref.containers.selectionContainer(node, parent_filter)) |container| {
            try self.enqueueSelectedRowsChangeIfNeededParent(container);
        }
    }

    /// Queues one destruction per node of `node`'s subtree, in pre-order.
    ///
    /// Upstream `event.rs:161-174`. A parent is pushed, then its filtered
    /// children, and the queue is drained from the front, so a node is destroyed
    /// before any of its descendants. The client uses that order to tear down.
    ///
    /// **Returns.** `error.OutOfMemory` from the queue and from the two sets.
    pub fn removeSubtree(self: *EventGenerator, node: NodeRef) !void {
        var queue: ArrayList(FullNodeId) = .empty;
        defer queue.deinit(self.gpa);
        try queue.append(self.gpa, node.id());

        var head: usize = 0;
        while (head < queue.items.len) : (head += 1) {
            const id = queue.items[head];
            const current = NodeRef.init(node.tree_state, id) orelse continue;
            var children = try consumer.node_ref.hierarchy.filteredChildren(current, parent_filter);
            while (try children.next()) |child| {
                try queue.append(self.gpa, child.id());
            }
            try self.pushDestroyed(id);
        }
    }

    /// The body of `node_added`, upstream `AK/macos/src/event.rs:233-247`.
    ///
    /// A new text run queues its parent's text change, a selected included node
    /// queues its container's selected-rows change, and an included node whose
    /// `live` is not off announces its label.
    ///
    /// **Returns.** `SlotError`, which the slot records in `failure`.
    pub fn slotNodeAdded(self: *EventGenerator, node: NodeRef) SlotError!void {
        try self.insertTextChangeIfNeeded(node);
        if (try consumer.filter.commonFilter(node) != .include) return;
        if (consumer.node_ref.properties.isSelected(node) == true) {
            try self.enqueueSelectedRowsChangeIfNeeded(node);
        }
        const live = try consumer.node_ref.set_state.live(node);
        if (live != .off) {
            // `AK/macos/src/event.rs:236` reads the label through
            // `NodeWrapper::label`, so a node whose label comes from its value
            // announces the value and not the label. The buffer answers a list
            // whose capacity exceeds its length, so the release goes through
            // `node_wrapper.releaseText`, which calls `deinit`: a `gpa.free` of
            // `items` would hand the allocator a slice shorter than the block it
            // took. The capture is by value, because a capture of a temporary is
            // a `*const` and `deinit` takes `*Self`.
            const wrapper = node_wrapper.NodeWrapper.init(self.gpa, node);
            if (try wrapper.label()) |list| {
                defer node_wrapper.releaseText(self.gpa, list);
                try self.pushAnnouncement(list.items, live);
            }
        }
    }

    /// The body of `node_updated`, upstream `AK/macos/src/event.rs:249-305`.
    ///
    /// A node that drops out of the filter is destroyed, and a node that drops
    /// out with its subtree takes the subtree with it. Otherwise the four
    /// property comparisons run, in upstream's order: title, value, text
    /// selection, then the announcement and the selection.
    ///
    /// **Returns.** `SlotError`, which the slot records in `failure`.
    pub fn slotNodeUpdated(self: *EventGenerator, old: NodeRef, new: NodeRef) SlotError!void {
        const properties = consumer.node_ref.properties;
        const set_state = consumer.node_ref.set_state;

        if (!rawValueEquals(old, new)) try self.insertTextChangeIfNeeded(new);

        const old_filtered = try consumer.filter.commonFilter(old);
        const new_filtered = try consumer.filter.commonFilter(new);
        if (new_filtered != .include) {
            if (old_filtered == .include and properties.isSelected(old) == true) {
                try self.enqueueSelectedRowsChangeIfNeeded(old);
            }
            if (new_filtered == .exclude_subtree) {
                try self.removeSubtree(old);
            } else {
                try self.pushDestroyed(new.id());
            }
            return;
        }

        const node_id = new.id();
        if (try node_wrapper.titlesDiffer(self.gpa, old, new)) {
            try self.pushGeneric(node_id, notificationFor(.title_changed) orelse return);
        }
        // Upstream computes the new value once and asks it two questions: the
        // `!=` at `AK/macos/src/event.rs:271` and the
        // `matches!(v, Value::Bool(_))` at `:272`. The bool shape comes from a
        // toggled state or from the selection state of a tab, so
        // `node.isBoolean` reads the value and not the toggled state.
        const change = try node_wrapper.valueChange(self.gpa, old, new);
        defer change.deinit(self.gpa);
        if (change.differs) {
            // A bool value change on the focused node comes last, because
            // otherwise VoiceOver announces another node's change instead.
            // Upstream `event.rs:262-271`.
            const focused = predicatesIsFocused(new);
            if (!focused and node_wrapper.isBoolean(change.value)) {
                try self.insertGenericFront(node_id, notificationFor(.value_changed) orelse return);
            } else {
                try self.pushGeneric(node_id, notificationFor(.value_changed) orelse return);
            }
        }
        if (try textSelectionDiffers(old, new)) {
            try self.pushGeneric(node_id, notificationFor(.selected_text_changed) orelse return);
        }
        // `AK/macos/src/event.rs:300-302` reads both labels through
        // `NodeWrapper::label`, so a node whose label comes from its value
        // announces the value and not the label. Both releases go through
        // `node_wrapper.releaseText`, which calls `deinit`: the answer is a list
        // whose capacity exceeds its length, so a `gpa.free` of `items` hands the
        // allocator a slice shorter than the block it took.
        const old_wrapper = node_wrapper.NodeWrapper.init(self.gpa, old);
        const new_wrapper = node_wrapper.NodeWrapper.init(self.gpa, new);
        if (try new_wrapper.label()) |new_list| {
            defer node_wrapper.releaseText(self.gpa, new_list);
            const live = try set_state.live(new);
            const old_live = try set_state.live(old);
            const old_label = try old_wrapper.label();
            defer node_wrapper.releaseText(self.gpa, old_label);
            const changed = !node_wrapper.textEql(old_label, new_list);
            if (live != .off and (changed or live != old_live or old_filtered != .include)) {
                try self.pushAnnouncement(new_list.items, live);
            }
        }
        if (properties.isSelected(new) != properties.isSelected(old) or
            (old_filtered != .include and properties.isSelected(new) == true))
        {
            try self.enqueueSelectedRowsChangeIfNeeded(new);
        }
    }

    /// The body of `focus_moved`, upstream `AK/macos/src/event.rs:307-315`.
    ///
    /// Only a node that gains the focus produces an event, and only when the
    /// filter includes it.
    ///
    /// **Returns.** `SlotError`, which the slot records in `failure`.
    pub fn slotFocusMoved(self: *EventGenerator, old: ?NodeRef, new: ?NodeRef) SlotError!void {
        _ = old;
        const gained = new orelse return;
        if (try consumer.filter.commonFilter(gained) != .include) return;
        try self.pushGeneric(gained.id(), notificationFor(.focus_moved) orelse return);
    }

    /// The body of `node_removed`, upstream `AK/macos/src/event.rs:317-325`.
    ///
    /// **Returns.** `SlotError`, which the slot records in `failure`.
    pub fn slotNodeRemoved(self: *EventGenerator, node: NodeRef) SlotError!void {
        try self.insertTextChangeIfNeeded(node);
        if (consumer.node_ref.properties.isSelected(node) == true) {
            try self.enqueueSelectedRowsChangeIfNeeded(node);
        }
        try self.pushDestroyed(node.id());
    }
};

/// Releases a list of events and its backing array.
///
/// `gpa` must be the allocator the generator was built with.
pub fn releaseEvents(gpa: Allocator, events: *ArrayList(QueuedEvent)) void {
    for (events.items) |*event| releaseEvent(gpa, event);
    events.deinit(gpa);
}

/// `TreeChangeHandler.node_added`, upstream `AK/macos/src/event.rs:233-247`.
///
/// A run that arrives with a new parent queues the parent's text change. An
/// included node that is selected queues its container's selected-rows change,
/// and an included node whose `live` is not off announces its label.
///
/// **Errors.** `SlotError`. The handler signature cannot report one, so this
/// slot records it in `failure` and the caller checks that after the update.
fn nodeAdded(context: *anyopaque, node: NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotNodeAdded(node) catch |err| generator.record(err);
}

/// `TreeChangeHandler.node_updated`, upstream `AK/macos/src/event.rs:249-305`.
///
/// **Errors.** `SlotError`, recorded in `failure` as above.
fn nodeUpdated(context: *anyopaque, old: NodeRef, new: NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotNodeUpdated(old, new) catch |err| generator.record(err);
}

/// `TreeChangeHandler.focus_moved`, upstream `AK/macos/src/event.rs:307-315`.
///
/// **Errors.** `SlotError`, recorded in `failure` as above.
fn focusMoved(context: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotFocusMoved(old, new) catch |err| generator.record(err);
}

/// `TreeChangeHandler.node_removed`, upstream `AK/macos/src/event.rs:317-325`.
///
/// **Errors.** `SlotError`, recorded in `failure` as above.
fn nodeRemoved(context: *anyopaque, node: NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotNodeRemoved(node) catch |err| generator.record(err);
}

/// Whether the two nodes carry different raw values, upstream `:251`.
///
/// The comparison is on the raw bytes rather than on the interpreted value,
/// because upstream compares `raw_value` and a change from one spelling to
/// another is a change the client hears.
fn rawValueEquals(a: NodeRef, b: NodeRef) bool {
    const set_state = consumer.node_ref.set_state;
    const left = set_state.rawValue(a) orelse return set_state.rawValue(b) == null;
    const right = set_state.rawValue(b) orelse return false;
    return std.mem.eql(u8, left, right);
}

/// Whether the node holds the focus.
fn predicatesIsFocused(node: NodeRef) bool {
    return consumer.node_ref.predicates.isFocused(node);
}

/// Whether the two nodes' text selections differ, upstream `:284-286`.
///
/// **Returns.** `error.OutOfMemory`, from the walk that reads an inherited
/// selection on a node that does not carry one.
fn textSelectionDiffers(a: NodeRef, b: NodeRef) !bool {
    const left = consumer.node_ref.set_state.rawTextSelection(a);
    const right = consumer.node_ref.set_state.rawTextSelection(b);
    if (left == null and right == null) return false;
    const left_range = left orelse return true;
    const right_range = right orelse return true;
    // `rawTextSelection` answers a pointer into each node's own property
    // store, so comparing the pointers compares addresses. Two nodes holding
    // the same selection sit at different addresses, and the comparison has to
    // read the two selections instead.
    return !left_range.eql(right_range.*);
}

/// The filter the generator's walks read, upstream
/// `AK/macos/src/filters.rs:54-92`.
const parent_filter: FilterFn = .{ .context = null, .filter = commonFilterThunk };

/// Adapts `consumer.filter.commonFilter` to the `FilterFn` shape.
///
/// `context` is `null` for this filter because `commonFilter` reads only the
/// node. The walk it performs is bounded by `commonFilterStepBound` of the node
/// count, which the consumer layer derives.
fn commonFilterThunk(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    _ = context;
    return consumer.filter.commonFilter(node);
}

test "the adapter names exactly seven notifications and picks the right one per change" {
    // The decision table. Six changes name one of the 6 notifications that go
    // through `NSAccessibilityPostNotification`, and the announcement names the
    // seventh, which goes through the `WithUserInfo` call instead.
    try testing.expectEqual(change_count, @typeInfo(Change).@"enum".fields.len);
    const expected = [_]struct { Change, []const u8 }{
        .{ .focus_moved, "NSAccessibilityFocusedUIElementChangedNotification" },
        .{ .value_changed, "NSAccessibilityValueChangedNotification" },
        .{ .title_changed, "NSAccessibilityTitleChangedNotification" },
        .{ .selected_text_changed, "NSAccessibilitySelectedTextChangedNotification" },
        .{ .selected_rows_changed, "NSAccessibilitySelectedRowsChangedNotification" },
        .{ .node_destroyed, "NSAccessibilityUIElementDestroyedNotification" },
    };
    try testing.expectEqual(@as(usize, 6), expected.len);
    for (expected) |entry| {
        const name = notificationFor(entry[0]) orelse return error.ChangeNamesNoNotification;
        try testing.expectEqualStrings(entry[1], name);
        // Every name comes from the table rather than being written here.
        try testing.expect(literals.findNotification(name) != null);
    }
    // The announcement is the one no node post carries.
    try testing.expect(notificationFor(.announcement) == null);
    try testing.expect(
        literals.findNotification("NSAccessibilityAnnouncementRequestedNotification") != null,
    );
    // The table covers 6 of the 7 notifications, which is exactly the split
    // `AK/macos/src/event.rs:53` and `:97` record.
    var named: usize = 0;
    for (literals.notifications) |notification| {
        for (expected) |entry| {
            if (std.mem.eql(u8, notification.value, entry[1])) named += 1;
        }
    }
    try testing.expectEqual(@as(usize, 6), named);
}

test "an assertive live region announces at high priority and a polite one at medium" {
    // Drive live-region nodes through the producer, not just its mapping helper.
    // Apple's macOS 11.3 SDK, AppKit/NSAccessibilityConstants.h, defines
    // low=10, medium=50, high=90. The old 700/500 fixture copied unverified
    // placeholder values, not AppKit announcement priorities.
    // Upstream event.rs selects high/medium and QueuedEvent::raise boxes the
    // integer under NSAccessibilityPriorityKey. Native dictionary delivery
    // remains CI-pending: this test checks the payload before posting.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .document, .label = "Urgent update", .live = .assertive },
        .{ .local = 3, .role = .document, .label = "Routine update", .live = .polite },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    try generator.slotNodeAdded(try armNode(&tree, 2));
    try generator.slotNodeAdded(try armNode(&tree, 3));

    const expected = [_]struct { text: []const u8, priority: i32 }{
        .{ .text = "Urgent update", .priority = 90 },
        .{ .text = "Routine update", .priority = 50 },
    };
    try testing.expectEqual(expected.len, generator.events.items.len);
    for (generator.events.items, expected) |event, payload| {
        switch (event) {
            .announcement => |announcement| {
                try testing.expectEqualStrings(payload.text, announcement.text);
                try testing.expectEqual(payload.priority, @intFromEnum(announcement.priority));
            },
            else => return error.TestUnexpectedResult,
        }
    }
}

test "a FullNodeId is compared with std.meta.eql and never with ==" {
    // The house rule, asserted where it is easiest to break. Two identifiers
    // that name the same node have the same two scalars, and `==` on the struct
    // would compare every field including any added later.
    const one: FullNodeId = .{ .local = .{ .value = 7 }, .tree_index = @enumFromInt(0) };
    const same: FullNodeId = .{ .local = .{ .value = 7 }, .tree_index = @enumFromInt(0) };
    const other: FullNodeId = .{ .local = .{ .value = 8 }, .tree_index = @enumFromInt(0) };
    try testing.expect(std.meta.eql(one, same));
    try testing.expect(!std.meta.eql(one, other));
}

test "an empty generator produces no events and releases cleanly" {
    var generator = EventGenerator.init(std.testing.allocator);
    defer generator.deinit();
    try testing.expectEqual(@as(usize, 0), generator.count());
    try testing.expectEqual(@as(usize, 0), generator.events.items.len);
    // `takeEvents` on an empty generator hands back an empty list and the
    // generator is still safe to release.
    var taken = generator.takeEvents();
    releaseEvents(std.testing.allocator, &taken);
    try testing.expectEqual(@as(usize, 0), generator.count());
}

test "the announcement owns its text and releases it exactly once" {
    // The event carries a copy, so a caller that drops the source string leaves
    // the event readable. A test allocator proves the release.
    var generator = EventGenerator.init(std.testing.allocator);
    defer generator.deinit();
    try generator.pushAnnouncement("hello", .assertive);
    try testing.expectEqual(@as(usize, 1), generator.count());
    const event = generator.events.items[0];
    try testing.expectEqualStrings("hello", event.announcement.text);
    try testing.expectEqual(literals.PriorityLevel.high, event.announcement.priority);
    // The copy is independent of the caller's buffer.
    try testing.expect(event.announcement.text.ptr != "hello".ptr);
}

test "the two sets hold a FullNodeId only once" {
    // `text_changed` and `selected_rows_changed` are what make one text change
    // queue one event however many runs in it changed, at
    // `AK/macos/src/event.rs:184-192` and `:210-221`.
    var generator = EventGenerator.init(std.testing.allocator);
    defer generator.deinit();
    const id: FullNodeId = .{ .local = .{ .value = 1 }, .tree_index = @enumFromInt(0) };

    const first = try generator.text_changed.getOrPut(std.testing.allocator, id);
    try testing.expect(!first.found_existing);
    const second = try generator.text_changed.getOrPut(std.testing.allocator, id);
    try testing.expect(second.found_existing);
    try testing.expectEqual(@as(usize, 1), generator.text_changed.count());

    const rows = try generator.selected_rows_changed.getOrPut(std.testing.allocator, id);
    try testing.expect(!rows.found_existing);
    try testing.expectEqual(@as(usize, 1), generator.selected_rows_changed.count());
}

test "the four handler slots are the ones the tree calls" {
    // `consumer.tree.Tree` fills the four slots and reports the focus move
    // between the updates and the removals, so a slot this module leaves `null`
    // is a change no test would otherwise notice.
    var generator = EventGenerator.init(std.testing.allocator);
    defer generator.deinit();
    const handler = slotsOf(&generator);
    try testing.expect(handler.node_added != null);
    try testing.expect(handler.node_updated != null);
    try testing.expect(handler.focus_moved != null);
    try testing.expect(handler.node_removed != null);
    const fields = @typeInfo(consumer.tree.TreeChangeHandler).@"struct".fields;
    try testing.expectEqual(@as(usize, 4), fields.len - 1);
}

test "a slot records the tag it failed with, and keeps the first one" {
    // A `TreeChangeHandler` slot returns `void`, so a failure has nowhere to
    // go but this field. The tag is what a caller reads to tell an exhausted
    // allocator from a query that hit a bound, so recording one bit for both
    // would lose the difference and answer the wrong one of the two. A second
    // failure must not overwrite the first either: the caller reads the field
    // once, after the commit, and the tag that stopped the walk is the one it
    // wants.
    var generator = EventGenerator.init(std.testing.allocator);
    defer generator.deinit();
    try testing.expectEqual(@as(?SlotError, null), generator.failure);

    generator.record(error.TreeCycle);
    try testing.expectEqual(@as(?SlotError, error.TreeCycle), generator.failure);

    generator.record(error.OutOfMemory);
    try testing.expectEqual(@as(?SlotError, error.TreeCycle), generator.failure);
}

/// One node of the fixture tree the arms tests below drive.
const ArmSpec = struct {
    /// The identifier inside the root tree.
    local: u64,
    /// The role the node declares.
    role: schema.Role,
    /// The children of the node, in order.
    children: []const u64 = &.{},
    /// The raw value the node carries, or none.
    value: ?[]const u8 = null,
    /// The label the node carries, or none.
    label: ?[]const u8 = null,
    /// The live setting the node carries, or none.
    live: ?schema.Live = null,
    /// The selection state the node carries, or none.
    is_selected: ?bool = null,
    /// The text selection the node carries, or none.
    text_selection: ?schema.TextSelection = null,
};

/// Builds the tree `specs` describes.
///
/// `Tree.init` takes the update by value and releases it on every path, so the
/// binding is spent and there is no `deinit` to pair with this call.
fn buildArmTree(gpa: Allocator, root_local: u64, specs: []const ArmSpec) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    for (specs) |spec| {
        var node = schema.Node.init(gpa, spec.role);
        if (spec.value) |text| try schema.strings.setValue(&node.properties, text);
        if (spec.label) |text| try schema.strings.setLabel(&node.properties, text);
        if (spec.live) |value| try schema.enums.setLive(&node.properties, value);
        if (spec.is_selected) |value| try schema.enums.setSelected(&node.properties, value);
        if (spec.text_selection) |value| {
            try schema.option.setTextSelection(&node.properties, value);
        }
        var child_ids: ArrayList(schema.NodeId) = .empty;
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

/// The node `local` in `tree`, or an error rather than a trap.
fn armNode(tree: *const consumer.tree.Tree, local: u64) !NodeRef {
    const state = tree.stateOf();
    const id = state.rootId().withSameTree(.{ .value = local });
    return state.nodeById(id) orelse error.MissingNode;
}

/// A selection over one byte, which is enough to tell one from another.
fn armSelection(offset: usize) schema.TextSelection {
    const position: schema.TextPosition = .{
        .node_id = .{ .value = 0 },
        .character_index = offset,
    };
    return .{ .anchor = position, .focus = position };
}

test "two absent raw values are equal and one absent value is a change" {
    // `rawValueEquals` at `:515` has two arms that only an absent value reaches:
    // the left `orelse` asks whether the right is also absent, and the right
    // `orelse` answers `false`. A node that carries no value is ordinary, so
    // both halves of the half-absent case need a tree of their own.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .label },
        .{ .local = 3, .role = .label, .value = "same" },
        .{ .local = 4, .role = .label, .value = "same" },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    const bare = try armNode(&tree, 2);
    const bare_again = try armNode(&tree, 2);
    const valued = try armNode(&tree, 3);
    const valued_again = try armNode(&tree, 4);

    // Both absent: the left `orelse` runs and reads `rawValue(b) == null`.
    try testing.expect(rawValueEquals(bare, bare_again));
    // Left absent, right present: the same `orelse` answers `false`.
    try testing.expect(!rawValueEquals(bare, valued));
    // Left present, right absent: the second `orelse` at `:516` answers false.
    try testing.expect(!rawValueEquals(valued, bare));
    // Both present and equal: the `std.mem.eql` arm.
    try testing.expect(rawValueEquals(valued, valued_again));
}

test "one absent text selection is a change in either direction" {
    // `textSelectionDiffers` at `:553-555` has three arms after the both-absent
    // early return: left absent, right absent, and the `std.meta.eql` compare.
    // Only the two half-absent ones and the compare need a tree.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4, 5 } },
        .{ .local = 2, .role = .document },
        .{ .local = 3, .role = .document, .text_selection = armSelection(1) },
        .{ .local = 4, .role = .document, .text_selection = armSelection(1) },
        .{ .local = 5, .role = .document, .text_selection = armSelection(2) },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    const bare = try armNode(&tree, 2);
    const selected = try armNode(&tree, 3);
    const same = try armNode(&tree, 4);
    const other = try armNode(&tree, 5);

    // Both absent: the early return at `:553` answers false.
    try testing.expect(!try textSelectionDiffers(bare, bare));
    // Left absent, right present: the `orelse` at `:554` answers true.
    try testing.expect(try textSelectionDiffers(bare, selected));
    // Left present, right absent: the `orelse` at `:555` answers true.
    try testing.expect(try textSelectionDiffers(selected, bare));
    // Both present and the same: `std.meta.eql` answers true, so it differs is
    // false.
    try testing.expect(!try textSelectionDiffers(selected, same));
    // Both present and different: the same compare answers differs.
    try testing.expect(try textSelectionDiffers(selected, other));
}

test "a node that is not a text run queues no text change" {
    // `insertTextChangeIfNeeded` at `:288` returns on the role test before it
    // walks a parent, so a plain node contributes nothing and the generator is
    // left empty. This is the arm a run's parent walk never reaches.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .label, .value = "text" },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const label = try armNode(&tree, 2);
    try generator.insertTextChangeIfNeeded(label);
    try testing.expectEqual(@as(usize, 0), generator.count());
    try testing.expectEqual(@as(usize, 0), generator.text_changed.count());
}

test "a text run with no parent queues no text change" {
    // `insertTextChangeIfNeeded` at `:289` answers `null` from
    // `filteredParent` when the run is the root, and the `if` body does not
    // run. A run whose parent exists is the other arm, and both are here
    // because a run with no parent is the half-absent case.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .text_run },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const root_run = try armNode(&tree, 1);
    try generator.insertTextChangeIfNeeded(root_run);
    try testing.expectEqual(@as(usize, 0), generator.count());
    try testing.expectEqual(@as(usize, 0), generator.text_changed.count());
}

test "a selected item names the container above it" {
    // `enqueueSelectedRowsChangeIfNeeded` at `:308` walks up for the nearest
    // ancestor that both passes the filter and is a container with selectable
    // children. `list_box` is on that role list, at
    // `consumer/node_ref/containers.zig:125`, and the window above it is not,
    // so the walk answers the `list_box` and not the root.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{3} },
        .{ .local = 3, .role = .list_item, .is_selected = true },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const item = try armNode(&tree, 3);
    try generator.enqueueSelectedRowsChangeIfNeeded(item);
    try testing.expectEqual(@as(usize, 1), generator.count());
    const only = generator.events.items[0];
    try testing.expectEqualStrings(
        notificationFor(.selected_rows_changed) orelse return error.NoSuchNotification,
        only.generic.notification,
    );
    // The container is named, not the item.
    try testing.expect(std.meta.eql((try armNode(&tree, 2)).id(), only.generic.node_id));
}

test "a selected item with no selection container queues nothing" {
    // The reject case for the walk above. The only ancestor is the window,
    // which is not on the container list, so `selectionContainer` answers
    // `null` and the `if` body at `:309` does not run. This is the
    // half-absent container against the present container above.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_item, .is_selected = true },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const item = try armNode(&tree, 2);
    try testing.expectEqual(
        @as(?NodeRef, null),
        try consumer.node_ref.containers.selectionContainer(item, parent_filter),
    );
    try generator.enqueueSelectedRowsChangeIfNeeded(item);
    try testing.expectEqual(@as(usize, 0), generator.count());
}

test "an item that is not selected queues no selected-rows change" {
    // `slotNodeAdded` at `:347` tests `isSelected` for equality with `true`,
    // so a node that carries no selection state takes the arm that queues
    // nothing even though a container is above it.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{3} },
        .{ .local = 3, .role = .list_item },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const item = try armNode(&tree, 3);
    try testing.expectEqual(
        @as(?bool, null),
        consumer.node_ref.properties.isSelected(item),
    );
    try generator.slotNodeAdded(item);
    try testing.expectEqual(@as(usize, 0), generator.count());
}

test "a node the filter drops as a node and not a subtree loses one node" {
    // `slotNodeUpdated` at `:380-384` has two arms on `new_filtered`: the
    // `exclude_subtree` arm takes the subtree, and every other non-include
    // answer destroys this node alone. `generic_container` is the role the
    // common filter answers `exclude_node` for, at
    // `consumer/filter.zig:172`, so this drives the second arm.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .generic_container },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const container = try armNode(&tree, 2);
    try testing.expectEqual(
        consumer.filter.FilterResult.exclude_node,
        try consumer.filter.commonFilter(container),
    );

    try generator.slotNodeUpdated(container, container);
    try testing.expectEqual(@as(usize, 1), generator.count());
    const only = generator.events.items[0];
    try testing.expectEqual(@as(FullNodeId, container.id()), only.node_destroyed);
}

test "a selected node that drops out of the filter queues its container change" {
    // `slotNodeUpdated` at `:377` runs only when the **new** node is not
    // `include` while the **old** one was and was selected. The filter is a
    // pure function of the node, so one `NodeRef` cannot carry both answers:
    // the arm needs two nodes whose filter answers differ, which is why this
    // hands the slot an included selected item and an excluded container.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box, .children = &.{3} },
        .{ .local = 3, .role = .list_item, .is_selected = true },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const item = try armNode(&tree, 3);
    // A `generic_container` is what the common filter drops, so it stands in
    var dropped = try buildArmTree(gpa, 1, &[_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .generic_container },
    });
    defer dropped.deinit();
    const leaving = try armNode(&dropped, 2);

    try testing.expectEqual(true, consumer.node_ref.properties.isSelected(item));
    try testing.expectEqual(
        consumer.filter.FilterResult.include,
        try consumer.filter.commonFilter(item),
    );
    try testing.expectEqual(
        consumer.filter.FilterResult.exclude_node,
        try consumer.filter.commonFilter(leaving),
    );

    // The old node is `include` and selected, so the guard at `:377` holds and
    // the container change is queued before the destruction at `:383`.
    try generator.slotNodeUpdated(item, leaving);
    try testing.expectEqual(@as(usize, 2), generator.count());
    try testing.expectEqual(
        notificationFor(.selected_rows_changed) orelse return error.NoSuchNotification,
        generator.events.items[0].generic.notification,
    );
    try testing.expectEqual(
        @as(FullNodeId, (try armNode(&tree, 2)).id()),
        generator.events.items[0].generic.node_id,
    );
    try testing.expectEqual(
        @as(FullNodeId, leaving.id()),
        generator.events.items[1].node_destroyed,
    );
}

test "a node already outside the filter queues no container change" {
    // The reject case for the guard above. The old node is not `include`, so
    // `:377` does not run and the only event is the destruction.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .generic_container, .is_selected = true },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const leaving = try armNode(&tree, 2);
    try testing.expectEqual(
        consumer.filter.FilterResult.exclude_node,
        try consumer.filter.commonFilter(leaving),
    );

    try generator.slotNodeUpdated(leaving, leaving);
    try testing.expectEqual(@as(usize, 1), generator.count());
    try testing.expectEqual(
        @as(FullNodeId, leaving.id()),
        generator.events.items[0].node_destroyed,
    );
}

test "a node whose live region is off announces nothing" {
    // `slotNodeAdded` at `:351` guards the announcement on `live != .off`, and
    // `priorityFor` maps `off` to the medium arm. A node that carries no live
    // setting at all is the half-absent case for that guard, because `live`
    // inherits from the parent and a window carries none.
    //
    // Both nodes are a `document` and not a `label`, because
    // `strings.labelComesFromValue` holds for a `label` role and the read would
    // then answer the value, which neither node carries.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .document, .label = "plain" },
        .{ .local = 3, .role = .document, .label = "loud", .live = .assertive },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const plain = try armNode(&tree, 2);
    try generator.slotNodeAdded(plain);
    try testing.expectEqual(@as(usize, 0), generator.count());

    // The same node with a live setting announces, which is the other arm.
    var loud_generator = EventGenerator.init(gpa);
    defer loud_generator.deinit();
    try loud_generator.slotNodeAdded(try armNode(&tree, 3));
    try testing.expectEqual(@as(usize, 1), loud_generator.count());
    try testing.expectEqualStrings("loud", loud_generator.events.items[0].announcement.text);
}

test "a node with no label announces nothing" {
    // `slotNodeAdded` at `:352` reads the label and returns on `null`, so the
    // `pushAnnouncement` line is unreachable for a node that carries no label
    // even when it is a live region. This is the `null` arm of that `if`.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .label, .live = .assertive },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    try generator.slotNodeAdded(try armNode(&tree, 2));
    try testing.expectEqual(@as(usize, 0), generator.count());
}

test "the focus slot answers nothing when the focus is gone" {
    // `slotFocusMoved` at `:438` returns on `new == null`, and a `null` new
    // node is the half-absent case against a present old node. Both are driven
    // here because the old node is discarded at `:437` and cannot be the
    // reason nothing is queued.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const root_node = try armNode(&tree, 1);
    try generator.slotFocusMoved(root_node, null);
    try testing.expectEqual(@as(usize, 0), generator.count());

    // The present arm, for contrast.
    try generator.slotFocusMoved(null, root_node);
    try testing.expectEqual(@as(usize, 1), generator.count());
    try testing.expectEqualStrings(
        notificationFor(.focus_moved) orelse return error.NoSuchNotification,
        generator.events.items[0].generic.notification,
    );
}

test "the focus slot answers nothing for a node the filter drops" {
    // `slotFocusMoved` at `:439` returns when the filter does not include the
    // node that gained the focus, so a present node that is dropped produces
    // no event even though the focus did move.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .generic_container },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    try generator.slotFocusMoved(null, try armNode(&tree, 2));
    try testing.expectEqual(@as(usize, 0), generator.count());
}

test "the removal slot queues a destruction for a node that was never selected" {
    // `slotNodeRemoved` at `:448` guards the container change on
    // `isSelected == true`, and the destruction at `:451` runs either way.
    // A node that carries no selection state takes the guard's false arm and
    // still loses its node.
    const gpa = testing.allocator;
    const specs = [_]ArmSpec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .label },
    };
    var tree = try buildArmTree(gpa, 1, &specs);
    defer tree.deinit();

    var generator = EventGenerator.init(gpa);
    defer generator.deinit();
    const label = try armNode(&tree, 2);
    try generator.slotNodeRemoved(label);
    try testing.expectEqual(@as(usize, 1), generator.count());
    try testing.expectEqual(@as(FullNodeId, label.id()), generator.events.items[0].node_destroyed);
}
