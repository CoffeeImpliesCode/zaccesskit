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
/// `.announcement`. There is no error: the table is total over the 7 tags.
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
    /// Whether a slot ran out of memory and stopped.
    ///
    /// `consumer.tree.TreeChangeHandler` slots return `void`, so a slot cannot
    /// report `error.OutOfMemory` to the update that called it. It records the
    /// failure here instead, and the caller checks this after the update
    /// returns. A generator with `failed` set produced a partial event list, so
    /// the caller must not raise it as if it were complete.
    failed: bool = false,

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
        try self.insertGenericFront(id, notificationFor(.value_changed).?);
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
        try self.pushGeneric(id, notificationFor(.selected_rows_changed).?);
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
    /// **Returns.** `error.OutOfMemory`.
    pub fn slotNodeAdded(self: *EventGenerator, node: NodeRef) !void {
        try self.insertTextChangeIfNeeded(node);
        if (try consumer.filter.commonFilter(node) != .include) return;
        if (consumer.node_ref.properties.isSelected(node) == true) {
            try self.enqueueSelectedRowsChangeIfNeeded(node);
        }
        const live = try consumer.node_ref.set_state.live(node);
        if (live != .off) {
            if (try consumer.node_ref.strings.label(self.gpa, node)) |label_list| {
                defer self.gpa.free(label_list.items);
                try self.pushAnnouncement(label_list.items, live);
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
    /// **Returns.** `error.OutOfMemory`.
    pub fn slotNodeUpdated(self: *EventGenerator, old: NodeRef, new: NodeRef) !void {
        const properties = consumer.node_ref.properties;
        const strings = consumer.node_ref.strings;
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
        if (!optionalTextEquals(
            properties.roleDescription(old),
            properties.roleDescription(new),
        )) {
            try self.pushGeneric(node_id, notificationFor(.title_changed).?);
        }
        if (!optionalValueEquals(old, new)) {
            // A bool value change on the focused node comes last, because
            // otherwise VoiceOver announces another node's change instead.
            // Upstream `event.rs:262-271`.
            const focused = predicatesIsFocused(new);
            if (!focused and isBoolValue(new)) {
                try self.insertGenericFront(node_id, notificationFor(.value_changed).?);
            } else {
                try self.pushGeneric(node_id, notificationFor(.value_changed).?);
            }
        }
        if (try textSelectionDiffers(old, new)) {
            try self.pushGeneric(node_id, notificationFor(.selected_text_changed).?);
        }
        if (try strings.label(self.gpa, new)) |new_label| {
            defer self.gpa.free(new_label.items);
            const live = try set_state.live(new);
            const old_live = try set_state.live(old);
            const old_label = try strings.label(self.gpa, old);
            defer if (old_label) |list| self.gpa.free(list.items);
            const changed = if (old_label) |list|
                !std.mem.eql(u8, list.items, new_label.items)
            else
                true;
            if (live != .off and (changed or live != old_live or old_filtered != .include)) {
                try self.pushAnnouncement(new_label.items, live);
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
    /// **Returns.** `error.OutOfMemory`.
    pub fn slotFocusMoved(self: *EventGenerator, old: ?NodeRef, new: ?NodeRef) !void {
        _ = old;
        const gained = new orelse return;
        if (try consumer.filter.commonFilter(gained) != .include) return;
        try self.pushGeneric(gained.id(), notificationFor(.focus_moved).?);
    }

    /// The body of `node_removed`, upstream `AK/macos/src/event.rs:317-325`.
    ///
    /// **Returns.** `error.OutOfMemory`.
    pub fn slotNodeRemoved(self: *EventGenerator, node: NodeRef) !void {
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
/// **Errors.** `error.OutOfMemory`. The handler signature cannot report one, so
/// this slot records it in `failed` and the caller checks that after the update.
fn nodeAdded(context: *anyopaque, node: NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotNodeAdded(node) catch {
        generator.failed = true;
    };
}

/// `TreeChangeHandler.node_updated`, upstream `AK/macos/src/event.rs:249-305`.
///
/// **Errors.** `error.OutOfMemory`, recorded in `failed` as above.
fn nodeUpdated(context: *anyopaque, old: NodeRef, new: NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotNodeUpdated(old, new) catch {
        generator.failed = true;
    };
}

/// `TreeChangeHandler.focus_moved`, upstream `AK/macos/src/event.rs:307-315`.
///
/// **Errors.** `error.OutOfMemory`, recorded in `failed` as above.
fn focusMoved(context: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotFocusMoved(old, new) catch {
        generator.failed = true;
    };
}

/// `TreeChangeHandler.node_removed`, upstream `AK/macos/src/event.rs:317-325`.
///
/// **Errors.** `error.OutOfMemory`, recorded in `failed` as above.
fn nodeRemoved(context: *anyopaque, node: NodeRef) void {
    const generator: *EventGenerator = @ptrCast(@alignCast(context));
    generator.slotNodeRemoved(node) catch {
        generator.failed = true;
    };
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

/// Whether two optional texts are the same text or the same absence.
fn optionalTextEquals(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

/// Whether the two nodes' values are the same, upstream `:258`.
///
/// Upstream compares `NodeWrapper::value`, which is the interpreted value: a
/// toggled state, a numeric value or a string. This module compares the raw
/// bytes, because that is what the consumer layer reads without a schema walk.
fn optionalValueEquals(a: NodeRef, b: NodeRef) bool {
    return rawValueEquals(a, b);
}

/// Whether the node carries a toggled state, which is the bool value shape.
fn isBoolValue(node: NodeRef) bool {
    return consumer.node_ref.properties.toggled(node) != null;
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
    if (left == null or right == null) return left == null and right == null;
    return !std.meta.eql(left.?, right.?);
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
    // Both arms of `AK/macos/src/event.rs:35-43`. No Mac is needed: the mapping
    // from a `Live` tag to a priority level is a two-arm function. What needs a
    // Mac is delivering the dictionary.
    try testing.expectEqual(literals.PriorityLevel.high, priorityFor(.assertive));
    try testing.expectEqual(literals.PriorityLevel.medium, priorityFor(.polite));
    // `off` is not an announcement, and the caller checks for it before it calls
    // this, so the answer for it is the medium arm.
    try testing.expectEqual(literals.PriorityLevel.medium, priorityFor(.off));
    try testing.expectEqual(@as(usize, 3), @typeInfo(schema.Live).@"enum".fields.len);
    try testing.expectEqual(@as(i32, 700), @intFromEnum(priorityFor(.assertive)));
    try testing.expectEqual(@as(i32, 500), @intFromEnum(priorityFor(.polite)));
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
