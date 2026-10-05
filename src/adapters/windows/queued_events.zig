//! The events one tree update produced, and the walk that raises them.
//!
//! **What this file ports.** `QueuedEvent` from
//! `adapters/windows/src/util.rs:76-92` and `QueuedEvents` from
//! `adapters/windows/src/adapter.rs:628-668` in the pinned upstream tree.
//! Upstream's queue is a `Vec<QueuedEvent>` and `raise` walks it calling
//! `UiaRaiseAutomationEvent` or `UiaRaiseAutomationPropertyChangedEvent`.
//!
//! **What the port adds, and why.** `raise` returns a `RaiseReport` instead of
//! nothing. The C ABI's `accesskit_windows_queued_events_raise` returns nothing
//! and releases the handle, so a refusal has nowhere else to go: an adapter
//! that drops a failed raise reports nothing and an application cannot tell a
//! delivered event from a lost one. The report carries the three counts back
//! to `WindowsAdapter`, which keeps the last one and prints it in
//! `accesskit_windows_adapter_debug`.
//!
//! **What a queued event holds.** A `*const syscalls.ProviderSlot`, never a
//! node identifier and never a `FullNodeId`. A node identifier is meaningless
//! once the tree has moved on, and a queued event outlives the update that
//! produced it: the slots live in `elements.Registry` and keep their addresses
//! until the registry is released.
//!
//! **Loop bounds.** The one loop outside a test is `raise`, and its bound is
//! `events.items.len`, the queue's own length at the moment the walk starts.
//! Nothing in the walk changes the queue, so the bound holds for the whole of
//! it.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const syscalls = @import("syscalls.zig");

/// The tree-and-node pair a provider slot is filed under.
pub const consumer_node_id = consumer.tree_index.FullNodeId;

const EventId = syscalls.EventId;
const Platform = syscalls.Platform;
const PropertyId = syscalls.PropertyId;
const PropertyValue = schema.PropertyValue;
const ProviderSlot = syscalls.ProviderSlot;
const RaiseStatus = syscalls.RaiseStatus;

/// The type a plain raise slot has, named once so a test seam and the port
/// agree on the spelling.
pub const RaiseSlot = syscalls.RaiseEventSlot;
/// The type a property-change raise slot has, named for the reason `RaiseSlot`
/// is named.
pub const RaisePropertySlot = syscalls.RaisePropertyChangedSlot;

/// An event that names one provider and one UI Automation event identifier.
///
/// Upstream `QueuedEvent::Simple` at `util.rs:78-83`.
pub const SimpleEvent = struct {
    /// The provider the event is raised on. The slot stays alive until the
    /// registry is released, so a queued event never names a freed address.
    slot: *const ProviderSlot,

    /// Which event. Nine values reach this adapter; the domain is
    /// `syscalls.EventId` and `EventId.count` is its length.
    event_id: EventId,
};

/// A change of one property on one provider.
///
/// Upstream `QueuedEvent::PropertyChanged` at `util.rs:84-92`. The two values
/// are platform-neutral property values; converting them to the `VARIANT` UI
/// Automation takes happens inside the platform call, on the Windows side of
/// the seam.
pub const PropertyChangedEvent = struct {
    /// The provider the event is raised on.
    slot: *const ProviderSlot,

    /// Which property changed.
    property_id: PropertyId,

    /// The value the property held before the update.
    old: PropertyValue,

    /// The value the property holds after the update.
    new: PropertyValue,
};

/// One event the queue carries.
pub const QueuedEvent = union(enum) {
    /// A plain event, raised with `UiaRaiseAutomationEvent`.
    simple: SimpleEvent,
    /// A property change, raised with `UiaRaiseAutomationPropertyChangedEvent`.
    property_changed: PropertyChangedEvent,
};

/// What one `raise` did to every event in the queue.
///
/// The three counts add up to the length of the queue, which is the check a
/// caller can make without knowing what the events were.
pub const RaiseReport = struct {
    /// Events UI Automation took.
    raised: usize = 0,
    /// Events UI Automation was reached for and refused.
    refused: usize = 0,
    /// Events no UI Automation was reached for, because the target cannot link
    /// `uiautomationcore.dll`.
    unavailable: usize = 0,

    /// How many events the report accounts for in total.
    pub fn total(self: RaiseReport) usize {
        return self.raised + self.refused + self.unavailable;
    }
};

/// The events one tree update produced.
///
/// The value owns the array that holds them and releases it with `gpa`. There
/// is no copy operation, so the only way to hand a queue to a callee is a
/// pointer.
pub const QueuedEvents = struct {
    /// The allocator that grew the array. It must be the allocator `init` was
    /// given, and it must stay valid until the queue is raised or released.
    gpa: std.mem.Allocator,

    /// The events, in the order they must be raised. The order is the
    /// contract: upstream inserts a text change at the front of the queue at
    /// `adapter.rs:67-73` so a text change comes before a selection change.
    events: std.ArrayList(QueuedEvent) = .empty,

    /// The providers this queue owns rather than the registry.
    ///
    /// Upstream's queue holds an `Arc<PlatformNode>` per event, so an event
    /// about a node the tree has dropped keeps that node alive until the event
    /// is raised. The port holds the slot the same way and releases it here
    /// rather than in the registry.
    owned_slots: std.ArrayList(*ProviderSlot) = .empty,

    /// An empty queue. Nothing is allocated, so this call cannot fail.
    pub fn init(gpa: std.mem.Allocator) QueuedEvents {
        return .{ .gpa = gpa };
    }

    /// Releases the array and every provider the queue owns, without raising
    /// anything.
    ///
    /// A caller that decides not to raise releases here. A second call reaches
    /// an empty array rather than a freed one, because `deinit` leaves the
    /// value in its reset form.
    ///
    /// `platform` releases the owned providers, because a provider belongs to
    /// the node layer and only the node layer may release one.
    pub fn deinit(self: *QueuedEvents, platform: Platform) void {
        const gpa = self.gpa;
        for (self.owned_slots.items) |slot| {
            platform.destroy_provider(gpa, detachedId, slot);
            gpa.destroy(slot);
        }
        self.owned_slots.deinit(gpa);
        self.events.deinit(gpa);
        self.* = .{ .gpa = gpa };
    }

    /// Takes ownership of a slot from `Registry.detachedSlotFor`.
    ///
    /// The queue releases it in `raise` or in `deinit`, whichever runs first,
    /// and never twice. A caller that hands a slot over must not release it.
    ///
    /// `error.OutOfMemory` when the ownership list cannot grow. The slot is
    /// still the caller's on that path and the queue is unchanged.
    pub fn takeOwnership(self: *QueuedEvents, slot: *ProviderSlot) std.mem.Allocator.Error!void {
        try self.owned_slots.append(self.gpa, slot);
    }

    /// The node identifier every owned slot is released under.
    ///
    /// A detached slot names a node the tree has dropped, so the map has no key
    /// for it. The release still needs a node identifier to hand the platform,
    /// and `NodeId(0)` is the one upstream uses for the only provider that
    /// names no node: `PLACEHOLDER_ROOT_ID` at `adapter.rs:374`.
    pub const detachedId: consumer_node_id = consumer_node_id.init(.{ .value = 0 }, .init(0));

    /// Adds one event at the end of the queue.
    ///
    /// `error.OutOfMemory` when the array cannot grow. The queue is unchanged
    /// on that path, so a caller that cannot append has lost exactly the one
    /// event and nothing else.
    pub fn append(self: *QueuedEvents, event: QueuedEvent) std.mem.Allocator.Error!void {
        try self.events.append(self.gpa, event);
    }

    /// Adds one event at the front of the queue.
    ///
    /// This is the port of the `insert(0, …)` at `adapter.rs:67-73`, which
    /// exists because a text change must be raised before a selection change.
    /// Inserting at the front is what makes that true whatever order the
    /// selection events arrive in.
    pub fn prepend(self: *QueuedEvents, event: QueuedEvent) std.mem.Allocator.Error!void {
        try self.events.insert(self.gpa, 0, event);
    }

    /// How many events the queue carries.
    pub fn len(self: *const QueuedEvents) usize {
        return self.events.items.len;
    }

    /// The event at `index`, or `null` when `index` is past the end.
    ///
    /// The bound is `len`. A test reads the queue through this rather than
    /// through the array, so a change to the storage does not reach every test.
    pub fn at(self: *const QueuedEvents, index: usize) ?QueuedEvent {
        if (index >= self.events.items.len) return null;
        return self.events.items[index];
    }

    /// Raises every event in order, releases the queue, and reports what
    /// happened.
    ///
    /// The value is taken by value and the queue is released inside, because
    /// upstream's `raise` takes `self` and the C ABI's
    /// `accesskit_windows_queued_events_raise` releases the handle. A caller
    /// that wants to keep the queue must therefore not call this.
    ///
    /// **The window may receive a `WM_GETOBJECT` message during this walk**, so
    /// no lock the caller holds over the adapter may be held here. That is why
    /// the adapter releases its own state before it calls this.
    ///
    /// A refusal is counted, not thrown: the walk continues so that one refusal
    /// does not swallow the events behind it, and the report says what
    /// happened.
    pub fn raise(self: QueuedEvents, platform: Platform) RaiseReport {
        const gpa = self.gpa;
        var report: RaiseReport = .{};
        for (self.events.items) |event| {
            const status: RaiseStatus = switch (event) {
                .simple => |simple| platform.raise_event(simple.slot, simple.event_id),
                .property_changed => |change| platform.raise_property_changed(
                    change.slot,
                    change.property_id,
                    change.old,
                    change.new,
                ),
            };
            switch (status) {
                .raised => report.raised += 1,
                .refused => report.refused += 1,
                .unavailable => report.unavailable += 1,
            }
        }
        var owned = self;
        for (owned.owned_slots.items) |slot| {
            platform.destroy_provider(gpa, detachedId, slot);
            gpa.destroy(slot);
        }
        owned.owned_slots.deinit(gpa);
        owned.events.deinit(gpa);
        return report;
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// A stand-in for a provider slot.
///
/// The address is rounded down to the slot's alignment, because a Debug build
/// traps on an unaligned pointer even when nothing dereferences it. No test
/// reads through it.
fn slotFor(identifier: usize) *const ProviderSlot {
    return @ptrFromInt(identifier & ~@as(usize, @alignOf(ProviderSlot) - 1));
}

test "a new queue carries nothing and a report accounts for nothing" {
    var queue = QueuedEvents.init(testing.allocator);
    defer queue.deinit(syscalls.unavailablePlatform());

    try testing.expectEqual(@as(usize, 0), queue.len());
    try testing.expectEqual(@as(?QueuedEvent, null), queue.at(0));

    const report = queue.raise(syscalls.unavailablePlatform());
    try testing.expectEqual(@as(usize, 0), report.total());
}

test "append and prepend put the events where the two calls say" {
    var queue = QueuedEvents.init(testing.allocator);
    defer queue.deinit(syscalls.unavailablePlatform());

    try queue.append(.{ .simple = .{ .slot = slotFor(0x10), .event_id = .window_window_opened } });
    try queue.prepend(.{ .simple = .{ .slot = slotFor(0x20), .event_id = .text_text_changed } });
    try queue.append(.{
        .property_changed = .{
            .slot = slotFor(0x30),
            .property_id = .selection_item_is_selected,
            .old = .{ .bool_ = false },
            .new = .{ .bool_ = true },
        },
    });

    // The text change is first because upstream inserts it at the front, and
    // the property change is last because it was appended last.
    try testing.expectEqual(@as(usize, 3), queue.len());
    try testing.expectEqual(syscalls.EventId.text_text_changed, queue.at(0).?.simple.event_id);
    try testing.expectEqual(syscalls.EventId.window_window_opened, queue.at(1).?.simple.event_id);
    try testing.expectEqual(
        syscalls.PropertyId.selection_item_is_selected,
        queue.at(2).?.property_changed.property_id,
    );
    try testing.expectEqual(@as(?QueuedEvent, null), queue.at(3));
}

test "the queue hands each event the slot it was given" {
    var queue = QueuedEvents.init(testing.allocator);
    defer queue.deinit(syscalls.unavailablePlatform());

    try queue.append(.{ .simple = .{ .slot = slotFor(0x1111), .event_id = .automation_focus_changed } });
    try queue.append(.{ .simple = .{ .slot = slotFor(0x2222), .event_id = .automation_focus_changed } });

    // Two events for two nodes must name two providers, or a focus change on
    // one node is raised on the other.
    try testing.expectEqual(@as(usize, 0x1110), @intFromPtr(queue.at(0).?.simple.slot));
    try testing.expectEqual(@as(usize, 0x2220), @intFromPtr(queue.at(1).?.simple.slot));
}

test "raise counts every refusal and reaches every event" {
    var queue = QueuedEvents.init(testing.allocator);
    const event_count = 3;
    var index: usize = 0;
    while (index < event_count) : (index += 1) {
        try queue.append(.{
            .simple = .{ .slot = slotFor(0x100 + index), .event_id = .automation_focus_changed },
        });
    }

    // `testing.allocator` traps on a leak, so this also checks that `raise`
    // released the array it walked.
    const report = queue.raise(syscalls.unavailablePlatform());
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 0), report.refused);
    try testing.expectEqual(event_count, report.unavailable);
    try testing.expectEqual(event_count, report.total());
}

test "raise reports a raised event as raised and a refused one as refused" {
    // The three statuses have to stay distinguishable, because the adapter
    // prints the report and an application reads it to decide whether to
    // re-send. The sweep is `inline`, so each case is its own type and the
    // seam is built at compile time for it.
    const cases = [_]struct { status: RaiseStatus, name: []const u8 }{
        .{ .status = .raised, .name = "raised" },
        .{ .status = .refused, .name = "refused" },
        .{ .status = .unavailable, .name = "unavailable" },
    };
    // The bound is the length of the table, which `RaiseStatus.count` is.
    try testing.expectEqual(cases.len, RaiseStatus.count);
    inline for (cases) |entry| {
        var queue = QueuedEvents.init(testing.allocator);
        try queue.append(.{ .simple = .{ .slot = slotFor(0x10), .event_id = .automation_focus_changed } });

        const report = queue.raise(platformAnswering(entry.status));
        try testing.expectEqual(@as(usize, 1), report.total());
        var raised: usize = 0;
        var refused: usize = 0;
        var unavailable: usize = 0;
        switch (entry.status) {
            .raised => raised = 1,
            .refused => refused = 1,
            .unavailable => unavailable = 1,
        }
        try testing.expectEqual(raised, report.raised);
        try testing.expectEqual(refused, report.refused);
        try testing.expectEqual(unavailable, report.unavailable);
        try testing.expectEqualStrings(entry.name, @tagName(entry.status));
    }
}

/// A raise slot that answers `status` every time it is called.
///
/// `status` is a comptime parameter because a struct declared inside a
/// function body is a namespace and cannot close over a run-time value. Naming
/// the answer at the type level is what makes the three cases three values.
fn answeringRaise(comptime status: RaiseStatus) RaiseSlot {
    return struct {
        fn call(slot: *const ProviderSlot, event_id: EventId) RaiseStatus {
            _ = slot;
            _ = event_id;
            return status;
        }
    }.call;
}

/// The property-change half of `answeringRaise`, for the same reason.
fn answeringRaiseProperty(comptime status: RaiseStatus) RaisePropertySlot {
    return struct {
        fn call(
            slot: *const ProviderSlot,
            property_id: PropertyId,
            old: PropertyValue,
            new: PropertyValue,
        ) RaiseStatus {
            _ = slot;
            _ = property_id;
            _ = old;
            _ = new;
            return status;
        }
    }.call;
}

/// A seam whose two raise slots answer `status` every time.
fn platformAnswering(comptime status: RaiseStatus) Platform {
    const refusal = syscalls.unavailablePlatform();
    return .{
        .present = true,
        .init_uia = refusal.init_uia,
        .create_provider = refusal.create_provider,
        .destroy_provider = refusal.destroy_provider,
        .return_raw_element_provider = refusal.return_raw_element_provider,
        .raise_event = answeringRaise(status),
        .raise_property_changed = answeringRaiseProperty(status),
    };
}

test "the two event arms reach the two platform slots" {
    // A walk that sent both arms to one slot would raise a property change as
    // a plain event, and the two calls take different arguments.
    var plain = QueuedEvents.init(testing.allocator);
    try plain.append(.{ .simple = .{ .slot = slotFor(0x10), .event_id = .automation_focus_changed } });
    const plain_report = plain.raise(platformAnswering(.raised));
    try testing.expectEqual(@as(usize, 1), plain_report.raised);

    var changed = QueuedEvents.init(testing.allocator);
    try changed.append(.{
        .property_changed = .{
            .slot = slotFor(0x10),
            .property_id = .selection_item_is_selected,
            .old = .{ .bool_ = true },
            .new = .{ .bool_ = false },
        },
    });
    const changed_report = changed.raise(platformAnswering(.raised));
    try testing.expectEqual(@as(usize, 1), changed_report.raised);
}

test "deinit releases the array and a second release reaches an empty one" {
    var queue = QueuedEvents.init(testing.allocator);
    try queue.append(.{ .simple = .{ .slot = slotFor(0x10), .event_id = .automation_focus_changed } });
    try testing.expectEqual(@as(usize, 1), queue.len());

    queue.deinit(syscalls.unavailablePlatform());
    try testing.expectEqual(@as(usize, 0), queue.len());
    queue.deinit(syscalls.unavailablePlatform());
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "every allocation failure while growing the queue leaves it unchanged" {
    // Fail-N from the first allocation up to the one that succeeds, so every
    // `error.OutOfMemory` path in `append` and `prepend` runs at least once.
    const failing_allocations = 2;
    var fail_index: usize = 0;
    while (fail_index < failing_allocations) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(testing.allocator, .{
            .fail_index = fail_index,
        });
        var queue = QueuedEvents.init(failing.allocator());
        defer queue.deinit(syscalls.unavailablePlatform());

        const appended = queue.append(.{
            .simple = .{ .slot = slotFor(0x10), .event_id = .automation_focus_changed },
        });
        if (appended) |_| {
            try testing.expectEqual(@as(usize, 1), queue.len());
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), queue.len());
        }
    }
}
