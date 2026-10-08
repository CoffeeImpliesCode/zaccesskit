//! Owned UI Automation events for one tree update.
//!
//! This ports `util.rs:76-92` and `adapter.rs:628-668` from the pinned Windows adapter.
//! Each event retains its provider slot and owns its old/new automation values.
//! No tree, NodeRef, or borrowed property buffer survives in the queue.
//! Failed cleanup keeps the queue and its providers alive for a later retry.

const std = @import("std");
const consumer = @import("../../consumer/root.zig");
const elements = @import("elements.zig");
const syscalls = @import("syscalls.zig");
const util = @import("util.zig");

pub const consumer_node_id = consumer.tree_index.FullNodeId;
const EventId = syscalls.EventId;
const Platform = syscalls.Platform;
const PropertyId = syscalls.PropertyId;
const ProviderSlot = syscalls.ProviderSlot;
const RaiseStatus = syscalls.RaiseStatus;
pub const RaiseSlot = syscalls.RaiseEventSlot;
pub const RaisePropertySlot = syscalls.RaisePropertyChangedSlot;

/// One event reference, retained by the queue after successful insertion.
pub const SimpleEvent = struct {
    slot: *const ProviderSlot,
    event_id: EventId,
};

/// Owns both VARIANTs. Their allocation authorities must outlive cleanup, including retries.
pub const PropertyChangedEvent = struct {
    slot: *const ProviderSlot,
    property_id: PropertyId,
    old: util.VariantOwner,
    new: util.VariantOwner,
};

/// Insertion consumes property owners only on success. Copying does not create another owner.
pub const QueuedEvent = union(enum) {
    simple: SimpleEvent,
    property_changed: PropertyChangedEvent,

    fn provider(self: *const QueuedEvent) *const ProviderSlot {
        return switch (self.*) {
            .simple => |*event| event.slot,
            .property_changed => |*event| event.slot,
        };
    }
};

/// Cleanup attempts every value. A failure keeps all storage and slot references for retry.
pub const CleanupReport = struct {
    first_error: ?util.AutomationError = null,
    error_count: usize = 0,

    fn record(self: *CleanupReport, err: util.AutomationError) void {
        if (self.first_error == null) self.first_error = err;
        self.error_count += 1;
    }
};

/// Delivery counts cover this call only. Cleanup failures do not change a delivered event's status.
pub const RaiseReport = struct {
    raised: usize = 0,
    refused: usize = 0,
    unavailable: usize = 0,
    cleanup: CleanupReport = .{},

    pub fn total(self: RaiseReport) usize {
        return self.raised + self.refused + self.unavailable;
    }
};

pub const QueueError = std.mem.Allocator.Error || error{ ProviderLimitExceeded, InvalidOperation };

/// Leaves room for one non-event slot reference in the u32 provider reference count.
pub const event_count_max: usize = std.math.maxInt(u32) - 1;

/// Single-owner queue. Keep its allocator and automation authority alive until cleanup succeeds.
/// Provider slots must use the same allocator. Copies must not raise or release the shared storage.
/// Do not mutate this receiver from delivery callbacks or share it between threads.
pub const QueuedEvents = struct {
    gpa: std.mem.Allocator,
    automation: *const util.AutomationApi,
    events: std.ArrayList(QueuedEvent) = .empty,
    /// Detached baseline references, independent of the reference each event retains.
    owned_slots: std.ArrayList(*ProviderSlot) = .empty,
    /// Failed cleanup leaves records here, but they must never be delivered again.
    delivery_complete: bool = false,

    /// Creates an empty queue without allocating. Borrows both authorities through cleanup retries.
    pub fn init(gpa: std.mem.Allocator, automation: *const util.AutomationApi) QueuedEvents {
        return .{ .gpa = gpa, .automation = automation };
    }

    /// Cancels delivery and attempts every owner. Success releases every slot reference and resets.
    /// Failure preserves failed owners, storage, and providers. The caller must retain and retry it.
    pub fn deinit(self: *QueuedEvents, platform: Platform) CleanupReport {
        self.delivery_complete = true;
        var report: CleanupReport = .{};
        // Both walks are bounded by their stored lengths, each at most event_count_max.
        for (self.events.items) |*event| {
            switch (event.*) {
                .simple => {},
                .property_changed => |*change| {
                    change.old.deinit() catch |err| report.record(err);
                    change.new.deinit() catch |err| report.record(err);
                },
            }
        }
        if (report.first_error != null) return report;
        for (self.events.items) |*event| {
            elements.Registry.releaseSlot(platform, self.gpa, event.provider());
        }
        for (self.owned_slots.items) |slot| {
            elements.Registry.releaseSlot(platform, self.gpa, slot);
        }
        self.events.deinit(self.gpa);
        self.owned_slots.deinit(self.gpa);
        self.* = init(self.gpa, self.automation);
        return report;
    }

    /// Consumes one detached baseline reference on success. On failure it remains the caller's.
    /// Passing the same baseline reference twice violates ownership.
    pub fn takeOwnership(self: *QueuedEvents, slot: *ProviderSlot) QueueError!void {
        try self.requireOpen();
        if (self.owned_slots.items.len >= event_count_max) return error.ProviderLimitExceeded;
        try self.owned_slots.append(self.gpa, slot);
    }

    /// Appends an event and retains its slot only after allocation succeeds.
    /// A property event transfers both owners on success, never on failure.
    pub fn append(self: *QueuedEvents, event: QueuedEvent) QueueError!void {
        try self.reserveEvent();
        self.events.appendAssumeCapacity(event);
        elements.Registry.retainSlot(event.provider());
    }

    /// Prepends a text event before selection events, as upstream `adapter.rs:67-73` does.
    /// Ownership and failure behavior are the same as append.
    pub fn prepend(self: *QueuedEvents, event: QueuedEvent) QueueError!void {
        try self.reserveEvent();
        self.events.insertAssumeCapacity(0, event);
        elements.Registry.retainSlot(event.provider());
    }

    /// Reserves and owns the event before either value is constructed.
    /// Fill old then new directly here. A later constructor failure leaves earlier values owned.
    /// The result borrows the array and is invalidated by insertion, growth, raise, or cleanup.
    pub fn beginProperty(
        self: *QueuedEvents,
        slot: *const ProviderSlot,
        property_id: PropertyId,
    ) QueueError!*PropertyChangedEvent {
        try self.reserveEvent();
        self.events.appendAssumeCapacity(.{ .property_changed = .{
            .slot = slot,
            .property_id = property_id,
            .old = util.VariantOwner.init(self.automation),
            .new = util.VariantOwner.init(self.automation),
        } });
        elements.Registry.retainSlot(slot);
        return &self.events.items[self.events.items.len - 1].property_changed;
    }

    /// Transfers two independent owners on success, resetting both inputs. Failure changes neither.
    pub fn appendProperty(
        self: *QueuedEvents,
        slot: *const ProviderSlot,
        property_id: PropertyId,
        old: *util.VariantOwner,
        new: *util.VariantOwner,
    ) QueueError!void {
        std.debug.assert(old != new);
        const change = try self.beginProperty(slot, property_id);
        change.old = .{ .api = old.api, .raw = old.take() };
        change.new = .{ .api = new.api, .raw = new.take() };
    }

    /// Reserves before constructing scalars, so an allocation failure cannot strand local owners.
    pub fn appendBoolProperty(
        self: *QueuedEvents,
        slot: *const ProviderSlot,
        property_id: PropertyId,
        values: struct { old: bool, new: bool },
    ) QueueError!void {
        const change = try self.beginProperty(slot, property_id);
        change.old = util.VariantOwner.fromBool(self.automation, values.old);
        change.new = util.VariantOwner.fromBool(self.automation, values.new);
    }

    /// Includes records retained for cleanup after delivery or cancellation.
    pub fn len(self: *const QueuedEvents) usize {
        return self.events.items.len;
    }

    /// Borrowed event, invalidated by insertion, growth, raise, or cleanup. Null means out of bounds.
    pub fn at(self: *const QueuedEvents, index: usize) ?*const QueuedEvent {
        if (index >= self.events.items.len) return null;
        return &self.events.items[index];
    }

    /// Delivers each event once, then attempts cleanup. Refusals never stop later events.
    /// Release tree guards first: UIA can synchronously reenter WM_GETOBJECT.
    /// After failed cleanup, this method retries cleanup only. The queue must stay owned.
    pub fn raise(self: *QueuedEvents, platform: Platform) RaiseReport {
        var report: RaiseReport = .{};
        if (!self.delivery_complete) {
            self.delivery_complete = true;
            for (self.events.items) |*event| {
                const status: RaiseStatus = switch (event.*) {
                    .simple => |*simple| platform.raise_event(simple.slot, simple.event_id),
                    .property_changed => |*change| platform.raise_property_changed(
                        change.slot, change.property_id, change.old.raw, change.new.raw,
                    ),
                };
                switch (status) {
                    .raised => report.raised += 1,
                    .refused => report.refused += 1,
                    .unavailable => report.unavailable += 1,
                }
            }
        }
        report.cleanup = self.deinit(platform);
        return report;
    }

    fn requireOpen(self: *const QueuedEvents) QueueError!void {
        if (self.delivery_complete) return error.InvalidOperation;
    }

    fn reserveEvent(self: *QueuedEvents) QueueError!void {
        try self.requireOpen();
        if (self.events.items.len >= event_count_max) return error.ProviderLimitExceeded;
        try self.events.ensureUnusedCapacity(self.gpa, 1);
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn expectCleanup(report: CleanupReport) void {
    if (report.first_error) |err| @panic(@errorName(err));
    std.debug.assert(report.error_count == 0);
}

fn testSlot(queue: *QueuedEvents) QueueError!*ProviderSlot {
    const slot = try queue.gpa.create(ProviderSlot);
    errdefer queue.gpa.destroy(slot);
    slot.* = .{ .interface = null };
    try queue.takeOwnership(slot);
    return slot;
}

test "a new queue carries nothing and a report accounts for nothing" {
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    defer expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
    try testing.expectEqual(@as(usize, 0), queue.len());
    try testing.expect(queue.at(0) == null);
    const report = queue.raise(syscalls.unavailablePlatform());
    try testing.expectEqual(@as(usize, 0), report.total());
    try testing.expect(report.cleanup.first_error == null);
}

test "append and prepend put the events where the two calls say" {
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    defer expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
    const opened = try testSlot(&queue);
    const text = try testSlot(&queue);
    const selected = try testSlot(&queue);
    try queue.append(.{ .simple = .{ .slot = opened, .event_id = .window_window_opened } });
    try queue.prepend(.{ .simple = .{ .slot = text, .event_id = .text_text_changed } });
    try queue.appendBoolProperty(selected, .selection_item_is_selected,
        .{ .old = false, .new = true });
    try testing.expectEqual(@as(usize, 3), queue.len());
    try testing.expectEqual(EventId.text_text_changed, queue.at(0).?.simple.event_id);
    try testing.expectEqual(EventId.window_window_opened, queue.at(1).?.simple.event_id);
    try testing.expectEqual(PropertyId.selection_item_is_selected,
        queue.at(2).?.property_changed.property_id);
    try testing.expect(queue.at(3) == null);
}

test "the queue hands each event the slot it was given" {
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    defer expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
    const first = try testSlot(&queue);
    const second = try testSlot(&queue);
    try queue.append(.{ .simple = .{ .slot = first, .event_id = .automation_focus_changed } });
    try queue.append(.{ .simple = .{ .slot = second, .event_id = .automation_focus_changed } });
    try testing.expect(first != second);
    try testing.expect(queue.at(0).?.simple.slot == first);
    try testing.expect(queue.at(1).?.simple.slot == second);
}

test "raise counts every refusal and reaches every event" {
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    defer expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
    const slot = try testSlot(&queue);
    const event_count = 3;
    for (0..event_count) |_| {
        try queue.append(.{ .simple = .{ .slot = slot, .event_id = .automation_focus_changed } });
    }
    const report = queue.raise(syscalls.unavailablePlatform());
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 0), report.refused);
    try testing.expectEqual(@as(usize, event_count), report.unavailable);
    try testing.expectEqual(@as(usize, event_count), report.total());
    try testing.expectEqual(@as(usize, 0), queue.len());
}

fn platformAnswering(comptime status: RaiseStatus) Platform {
    const Callbacks = struct {
        fn simple(_: *const ProviderSlot, _: EventId) RaiseStatus {
            return status;
        }
        fn property(_: *const ProviderSlot, _: PropertyId, _: @import("bindings.zig").Variant,
            _: @import("bindings.zig").Variant) RaiseStatus
        {
            return status;
        }
    };
    var platform = syscalls.unavailablePlatform();
    platform.raise_event = Callbacks.simple;
    platform.raise_property_changed = Callbacks.property;
    return platform;
}

test "raise reports a raised event as raised and a refused one as refused" {
    inline for (.{ RaiseStatus.raised, RaiseStatus.refused, RaiseStatus.unavailable }) |status| {
        var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
        defer expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
        const slot = try testSlot(&queue);
        try queue.append(.{ .simple = .{ .slot = slot, .event_id = .automation_focus_changed } });
        const report = queue.raise(platformAnswering(status));
        try testing.expectEqual(@as(usize, 1), report.total());
        try testing.expectEqual(@as(usize, if (status == .raised) 1 else 0), report.raised);
        try testing.expectEqual(@as(usize, if (status == .refused) 1 else 0), report.refused);
        try testing.expectEqual(@as(usize, if (status == .unavailable) 1 else 0),
            report.unavailable);
    }
}

test "the two event arms reach the two platform slots" {
    const State = struct {
        simple_calls: usize = 0,
        property_calls: usize = 0,
        fn simple(slot: *const ProviderSlot, event: EventId) RaiseStatus {
            const state: *@This() = @ptrCast(@alignCast(slot.interface.?));
            std.debug.assert(event == .automation_focus_changed);
            state.simple_calls += 1;
            return .raised;
        }
        fn property(slot: *const ProviderSlot, id: PropertyId, old: @import("bindings.zig").Variant,
            new: @import("bindings.zig").Variant) RaiseStatus
        {
            const state: *@This() = @ptrCast(@alignCast(slot.interface.?));
            std.debug.assert(id == .selection_item_is_selected);
            std.debug.assert(old.Anonymous.Anonymous.Anonymous.boolVal == -1);
            std.debug.assert(new.Anonymous.Anonymous.Anonymous.boolVal == 0);
            state.property_calls += 1;
            return .raised;
        }
    };
    var state: State = .{};
    var platform = syscalls.unavailablePlatform();
    platform.raise_event = State.simple;
    platform.raise_property_changed = State.property;
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    defer expectCleanup(queue.deinit(platform));
    const slot = try testSlot(&queue);
    slot.interface = &state;
    try queue.append(.{ .simple = .{ .slot = slot, .event_id = .automation_focus_changed } });
    try queue.appendBoolProperty(slot, .selection_item_is_selected, .{ .old = true, .new = false });
    const report = queue.raise(platform);
    try testing.expectEqual(@as(usize, 2), report.raised);
    try testing.expectEqual(@as(usize, 1), state.simple_calls);
    try testing.expectEqual(@as(usize, 1), state.property_calls);
}

test "deinit releases the array and a second release reaches an empty one" {
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    const slot = try testSlot(&queue);
    try queue.append(.{ .simple = .{ .slot = slot, .event_id = .automation_focus_changed } });
    expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
    try testing.expectEqual(@as(usize, 0), queue.len());
    expectCleanup(queue.deinit(syscalls.unavailablePlatform()));
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "property ownership survives cancellation failures without clearing successful values twice" {
    const values = @import("util.zig");
    var clear_state = TestClearState{ .fail_value = 7 };
    var api = testingAutomationApi();
    api.context = &clear_state;
    const slot = try testing.allocator.create(ProviderSlot);
    slot.* = .{ .interface = null };
    var queue = QueuedEvents.init(testing.allocator, &api);
    try queue.takeOwnership(slot);
    var old = values.VariantOwner.fromI32(&api, 7);
    var new = values.VariantOwner.fromI32(&api, 9);
    try queue.appendProperty(slot, .selection_item_is_selected, &old, &new);
    try testing.expect(old.isEmpty());
    try testing.expect(new.isEmpty());
    const first = queue.deinit(syscalls.unavailablePlatform());
    try testing.expectEqual(error.ArrayLocked, first.first_error.?);
    try testing.expectEqual(@as(usize, 1), first.error_count);
    try testing.expectEqual(@as(usize, 1), clear_state.cleared);
    clear_state.fail_value = null;
    const second = queue.deinit(syscalls.unavailablePlatform());
    try testing.expect(second.first_error == null);
    try testing.expectEqual(@as(usize, 2), clear_state.cleared);
    try testing.expectEqual(@as(usize, 0), queue.len());
    const third = queue.deinit(syscalls.unavailablePlatform());
    try testing.expect(third.first_error == null);
    try testing.expectEqual(@as(usize, 2), clear_state.cleared);
}

test "property enqueue allocation failure keeps both values with the caller" {
    const values = @import("util.zig");
    var clear_state: TestClearState = .{};
    var api = testingAutomationApi();
    api.context = &clear_state;
    const slot = try testing.allocator.create(ProviderSlot);
    defer testing.allocator.destroy(slot);
    slot.* = .{ .interface = null };
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var queue = QueuedEvents.init(failing.allocator(), &api);
    var old = values.VariantOwner.fromI32(&api, 7);
    var new = values.VariantOwner.fromI32(&api, 9);
    try testing.expectError(error.OutOfMemory,
        queue.appendProperty(slot, .selection_item_is_selected, &old, &new));
    try testing.expect(!old.isEmpty());
    try testing.expect(!new.isEmpty());
    try testing.expectEqual(@as(usize, 0), queue.len());
    try testing.expectEqual(@as(usize, 0), clear_state.cleared);
    try old.deinit();
    try new.deinit();
    const cleanup = queue.deinit(syscalls.unavailablePlatform());
    try testing.expect(cleanup.first_error == null);
}

const TestClearState = struct {
    fail_value: ?i32 = null,
    other_fail_value: ?i32 = null,
    cleared: usize = 0,

    fn clear(raw_context: ?*anyopaque, value: *@import("bindings.zig").Variant)
        @import("bindings.zig").Hresult
    {
        if (raw_context) |raw| {
            const state: *TestClearState = @ptrCast(@alignCast(raw));
            if (@intFromEnum(value.Anonymous.Anonymous.vt) == 3) {
                if (state.fail_value) |fail_value| {
                    if (value.Anonymous.Anonymous.Anonymous.lVal == fail_value)
                        return @bitCast(@as(u32, 0x8002000d));
                }
                if (state.other_fail_value) |fail_value| {
                    if (value.Anonymous.Anonymous.Anonymous.lVal == fail_value)
                        return @bitCast(@as(u32, 0x80020008));
                }
            }
            state.cleared += 1;
        }
        value.* = std.mem.zeroes(@import("bindings.zig").Variant);
        return 0;
    }
};

/// Scalar-only injected authority for the queue and handler tests.
/// Other callbacks panic so tests cannot silently use a missing native operation.
pub fn testingAutomationApi() @import("util.zig").AutomationApi {
    if (!@import("builtin").is_test) @compileError("Test-only automation authority");
    const abi = @import("bindings.zig");
    const Unsupported = struct {
        fn alloc(_: ?*anyopaque, _: ?[*]const u16, _: u32) ?abi.Bstr {
            @panic("Unexpected string allocation");
        }
        fn stringLen(_: ?*anyopaque, _: abi.Bstr) u32 {
            @panic("Unexpected string length");
        }
        fn freeString(_: ?*anyopaque, _: abi.Bstr) void {
            @panic("Unexpected string cleanup");
        }
        fn arrayCreate(_: ?*anyopaque, _: u16, _: i32, _: u32) ?*abi.SafeArray {
            @panic("Unexpected array allocation");
        }
        fn arrayPut(_: ?*anyopaque, _: *abi.SafeArray, _: *const i32,
            _: *const anyopaque) abi.Hresult
        {
            @panic("Unexpected array insertion");
        }
        fn arrayDestroy(_: ?*anyopaque, _: *abi.SafeArray) abi.Hresult {
            @panic("Unexpected array cleanup");
        }
        fn reserved(_: ?*anyopaque, _: *?*abi.IUnknown) abi.Hresult {
            @panic("Unexpected reserved value");
        }
        fn locale(_: ?*anyopaque, _: [*:0]const u16, _: u32) u32 {
            @panic("Unexpected locale conversion");
        }
        fn screen(_: ?*anyopaque, _: abi.Hwnd, _: *abi.Point) abi.Bool {
            @panic("Unexpected window conversion");
        }
        fn window(_: ?*anyopaque, _: abi.Hwnd, _: u32, _: abi.Wparam,
            _: abi.Lparam) abi.Lresult
        {
            @panic("Unexpected window query");
        }
        fn hostProvider(_: ?*anyopaque, _: abi.Hwnd,
            _: *?*abi.IRawElementProviderSimple) abi.Hresult
        {
            @panic("Unexpected host provider query");
        }
    };
    return .{
        .alloc_string_len = Unsupported.alloc,
        .string_len = Unsupported.stringLen,
        .free_string = Unsupported.freeString,
        .variant_clear = TestClearState.clear,
        .array_create_vector = Unsupported.arrayCreate,
        .array_put_element = Unsupported.arrayPut,
        .array_destroy = Unsupported.arrayDestroy,
        .reserved_mixed_value = Unsupported.reserved,
        .reserved_not_supported_value = Unsupported.reserved,
        .locale_name_to_lcid = Unsupported.locale,
        .client_to_screen = Unsupported.screen,
        .def_window_proc = Unsupported.window,
        .host_provider_from_hwnd = Unsupported.hostProvider,
    };
}

const test_automation_api = testingAutomationApi();

/// Borrowed authority for scalar-only injected tests, never the native provider.
pub fn testAutomationApi() *const @import("util.zig").AutomationApi {
    if (!@import("builtin").is_test) @compileError("Test-only automation authority");
    return &test_automation_api;
}

test "a refused property raise retains failed cleanup without delivering twice" {
    const values = @import("util.zig");
    const abi = @import("bindings.zig");
    var delivered: usize = 0;
    const Counting = struct {
        fn raise(slot: *const ProviderSlot, property: PropertyId, old: abi.Variant,
            new: abi.Variant) RaiseStatus
        {
            std.debug.assert(property == .selection_item_is_selected);
            std.debug.assert(old.Anonymous.Anonymous.Anonymous.lVal == 7);
            std.debug.assert(new.Anonymous.Anonymous.Anonymous.lVal == 9);
            const count: *usize = @ptrCast(@alignCast(slot.interface.?));
            count.* += 1;
            return .refused;
        }
    };
    var platform = syscalls.unavailablePlatform();
    platform.raise_property_changed = Counting.raise;
    var clear_state = TestClearState{ .fail_value = 7 };
    var api = testingAutomationApi();
    api.context = &clear_state;
    const slot = try testing.allocator.create(ProviderSlot);
    slot.* = .{ .interface = &delivered };
    var queue = QueuedEvents.init(testing.allocator, &api);
    try queue.takeOwnership(slot);
    var old = values.VariantOwner.fromI32(&api, 7);
    var new = values.VariantOwner.fromI32(&api, 9);
    try queue.appendProperty(slot, .selection_item_is_selected, &old, &new);
    const first = queue.raise(platform);
    try testing.expectEqual(@as(usize, 1), first.refused);
    try testing.expectEqual(error.ArrayLocked, first.cleanup.first_error.?);
    try testing.expectEqual(@as(usize, 1), clear_state.cleared);
    try testing.expectEqual(@as(usize, 1), delivered);
    clear_state.fail_value = null;
    const second = queue.raise(platform);
    try testing.expectEqual(@as(usize, 0), second.total());
    try testing.expect(second.cleanup.first_error == null);
    try testing.expectEqual(@as(usize, 2), clear_state.cleared);
    try testing.expectEqual(@as(usize, 0), queue.len());
    try testing.expectEqual(@as(usize, 1), delivered);
}

test "queued provider survives removal and final cancellation releases once" {
    var destroyed: usize = 0;
    const Counting = struct {
        fn destroy(gpa: std.mem.Allocator, node_id: consumer_node_id,
            slot: *ProviderSlot) void
        {
            _ = gpa;
            _ = node_id;
            const counter: *usize = @ptrCast(@alignCast(slot.interface.?));
            counter.* += 1;
            slot.interface = null;
        }
    };
    var platform = syscalls.unavailablePlatform();
    platform.destroy_provider = Counting.destroy;
    const slot = try testing.allocator.create(ProviderSlot);
    slot.* = .{ .interface = &destroyed };
    var queue = QueuedEvents.init(testing.allocator, testAutomationApi());
    try queue.append(.{ .simple = .{
        .slot = slot, .event_id = .automation_focus_changed,
    } });
    @import("elements.zig").Registry.releaseSlot(platform, testing.allocator, slot);
    try testing.expectEqual(@as(usize, 0), destroyed);
    try testing.expectEqual(@as(usize, 1), slot.ref_count.load(.monotonic));
    const cleanup = queue.deinit(platform);
    try testing.expect(cleanup.first_error == null);
    try testing.expectEqual(@as(usize, 1), destroyed);
    const again = queue.deinit(platform);
    try testing.expect(again.first_error == null);
    try testing.expectEqual(@as(usize, 1), destroyed);
}

test "append and prepend allocation failures do not retain the provider" {
    const slot = try testing.allocator.create(ProviderSlot);
    defer testing.allocator.destroy(slot);
    slot.* = .{ .interface = null };
    inline for (.{ false, true }) |prepend_event| {
        var failing: std.testing.FailingAllocator = .init(testing.allocator,
            .{ .fail_index = 0 });
        var queue = QueuedEvents.init(failing.allocator(), testAutomationApi());
        const event: QueuedEvent = .{ .simple = .{
            .slot = slot, .event_id = .automation_focus_changed,
        } };
        const result = if (prepend_event) queue.prepend(event) else queue.append(event);
        try testing.expectError(error.OutOfMemory, result);
        try testing.expectEqual(@as(usize, 0), queue.len());
        try testing.expectEqual(@as(u32, 1), slot.ref_count.load(.monotonic));
        const cleanup = queue.deinit(syscalls.unavailablePlatform());
        try testing.expect(cleanup.first_error == null);
    }
}

test "in place property construction keeps its first value owned on later failure" {
    const Construction = struct {
        fn fill(queue: *QueuedEvents, slot: *const ProviderSlot)
            (QueueError || @import("util.zig").AutomationError)!void
        {
            const property = try queue.beginProperty(slot, .selection_item_is_selected);
            property.old = @import("util.zig").VariantOwner.fromI32(queue.automation, 7);
            property.new = try @import("util.zig").VariantOwner.fromUtf8(
                queue.automation, "\xff",
            );
        }
    };
    var clear_state = TestClearState{ .fail_value = 7 };
    var api = testingAutomationApi();
    api.context = &clear_state;
    const slot = try testing.allocator.create(ProviderSlot);
    slot.* = .{ .interface = null };
    var queue = QueuedEvents.init(testing.allocator, &api);
    try queue.takeOwnership(slot);
    try testing.expectError(error.InvalidUtf8, Construction.fill(&queue, slot));
    try testing.expect(!queue.at(0).?.property_changed.old.isEmpty());
    const first = queue.deinit(syscalls.unavailablePlatform());
    try testing.expectEqual(error.ArrayLocked, first.first_error.?);
    try testing.expectEqual(@as(usize, 0), clear_state.cleared);
    clear_state.fail_value = null;
    const second = queue.deinit(syscalls.unavailablePlatform());
    try testing.expect(second.first_error == null);
    try testing.expectEqual(@as(usize, 1), clear_state.cleared);
}

test "cancellation reports both cleanup failures and retains both owners" {
    const values = @import("util.zig");
    var clear_state = TestClearState{ .fail_value = 7 };
    var api = testingAutomationApi();
    api.context = &clear_state;
    const slot = try testing.allocator.create(ProviderSlot);
    slot.* = .{ .interface = null };
    var queue = QueuedEvents.init(testing.allocator, &api);
    try queue.takeOwnership(slot);
    var old = values.VariantOwner.fromI32(&api, 7);
    var new = values.VariantOwner.fromI32(&api, 7);
    try queue.appendProperty(slot, .selection_item_is_selected, &old, &new);
    const first = queue.deinit(syscalls.unavailablePlatform());
    try testing.expectEqual(error.ArrayLocked, first.first_error.?);
    try testing.expectEqual(@as(usize, 2), first.error_count);
    try testing.expectEqual(@as(usize, 0), clear_state.cleared);
    try testing.expect(!queue.at(0).?.property_changed.old.isEmpty());
    try testing.expect(!queue.at(0).?.property_changed.new.isEmpty());
    clear_state.fail_value = null;
    const second = queue.deinit(syscalls.unavailablePlatform());
    try testing.expect(second.first_error == null);
    try testing.expectEqual(@as(usize, 2), clear_state.cleared);
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "failed cancellation followed by raise never delivers partly cleared values" {
    const values = @import("util.zig");
    const abi = @import("bindings.zig");
    var delivered: usize = 0;
    const Counting = struct {
        fn raise(slot: *const ProviderSlot, _: PropertyId, _: abi.Variant,
            _: abi.Variant) RaiseStatus
        {
            const count: *usize = @ptrCast(@alignCast(slot.interface.?));
            count.* += 1;
            return .raised;
        }
    };
    var platform = syscalls.unavailablePlatform();
    platform.raise_property_changed = Counting.raise;
    var clear_state = TestClearState{ .fail_value = 7 };
    var api = testingAutomationApi();
    api.context = &clear_state;
    const slot = try testing.allocator.create(ProviderSlot);
    slot.* = .{ .interface = &delivered };
    var queue = QueuedEvents.init(testing.allocator, &api);
    try queue.takeOwnership(slot);
    var old = values.VariantOwner.fromI32(&api, 7);
    var new = values.VariantOwner.fromI32(&api, 9);
    try queue.appendProperty(slot, .selection_item_is_selected, &old, &new);
    const first = queue.deinit(platform);
    try testing.expectEqual(error.ArrayLocked, first.first_error.?);
    clear_state.fail_value = null;
    const retry = queue.raise(platform);
    try testing.expect(retry.cleanup.first_error == null);
    try testing.expectEqual(@as(usize, 0), retry.total());
    try testing.expectEqual(@as(usize, 0), delivered);
    try testing.expectEqual(@as(usize, 2), clear_state.cleared);
}

test "whole queue providers stay alive through heterogeneous cleanup failures" {
    const values = @import("util.zig");
    var destroyed: usize = 0;
    const Counting = struct {
        fn destroy(_: std.mem.Allocator, _: consumer_node_id, slot: *ProviderSlot) void {
            const count: *usize = @ptrCast(@alignCast(slot.interface.?));
            count.* += 1;
            slot.interface = null;
        }
    };
    var platform = syscalls.unavailablePlatform();
    platform.destroy_provider = Counting.destroy;
    var clear_state = TestClearState{ .fail_value = 7, .other_fail_value = 8 };
    var api = testingAutomationApi();
    api.context = &clear_state;
    var queue = QueuedEvents.init(testing.allocator, &api);
    var slots: [2]*ProviderSlot = undefined;
    for (&slots, 0..) |*held, index| {
        const slot = try testing.allocator.create(ProviderSlot);
        slot.* = .{ .interface = &destroyed };
        held.* = slot;
        try queue.takeOwnership(slot);
        var old = values.VariantOwner.fromI32(&api, @intCast(7 + index));
        var new = values.VariantOwner.fromI32(&api, @intCast(9 + index));
        try queue.appendProperty(slot, .selection_item_is_selected, &old, &new);
    }
    const first = queue.deinit(platform);
    try testing.expectEqual(error.ArrayLocked, first.first_error.?);
    try testing.expectEqual(@as(usize, 2), first.error_count);
    try testing.expectEqual(@as(usize, 2), clear_state.cleared);
    try testing.expectEqual(@as(usize, 2), queue.len());
    try testing.expectEqual(@as(usize, 0), destroyed);
    for (slots) |slot| try testing.expectEqual(@as(u32, 2), slot.ref_count.load(.monotonic));
    clear_state.fail_value = null;
    clear_state.other_fail_value = null;
    const retry = queue.deinit(platform);
    try testing.expect(retry.first_error == null);
    try testing.expectEqual(@as(usize, 4), clear_state.cleared);
    try testing.expectEqual(@as(usize, 2), destroyed);
    const again = queue.deinit(platform);
    try testing.expect(again.first_error == null);
    try testing.expectEqual(@as(usize, 2), destroyed);
}

fn queueGrowth(gpa: std.mem.Allocator) !void {
    const platform = syscalls.unavailablePlatform();
    const slot = try gpa.create(ProviderSlot);
    slot.* = .{ .interface = null };
    defer @import("elements.zig").Registry.releaseSlot(platform, gpa, slot);
    var queue = QueuedEvents.init(gpa, testAutomationApi());
    defer {
        const report = queue.deinit(platform);
        std.debug.assert(report.first_error == null);
    }
    const event_count = 32;
    for (0..event_count) |index| {
        const event: QueuedEvent = .{ .simple = .{
            .slot = slot, .event_id = .automation_focus_changed,
        } };
        if (index % 2 == 0) {
            try queue.append(event);
        } else {
            try queue.prepend(event);
        }
        try testing.expectEqual(@as(u32, @intCast(queue.len() + 1)),
            slot.ref_count.load(.monotonic));
    }
}

test "every append and prepend growth allocation failure balances provider ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, queueGrowth, .{});
}
