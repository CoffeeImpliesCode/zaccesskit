//! Windows adapter state and ownership.
//!
//! Upstream: adapters/windows/src/adapter.rs:376-594. Context guards protect
//! the mutable owner. Providers and pending events retain weak control handles,
//! not adapter or tree pointers. Native callbacks run without the tree guard.

const std = @import("std");
const builtin = @import("builtin");
const action_request = @import("../../capi/action_request.zig");
const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const change_handler = @import("change_handler.zig");
const consumer = @import("../../consumer/root.zig");
const owner_context = @import("context.zig");
const elements = @import("elements.zig");
const queued_events = @import("queued_events.zig");
const schema = @import("../../schema/root.zig");
const syscalls = @import("syscalls.zig");
const util = @import("util.zig");

const ActivationHandler = boundary.ActivationHandler;
const COptLResult = boundary.COptLResult;
const Hwnd = boundary.Hwnd;
const LParam = boundary.LParam;
const LResult = syscalls.LResult;
const WParam = boundary.WParam;
const Platform = syscalls.Platform;
const ProviderSlot = syscalls.ProviderSlot;
const RaiseReport = queued_events.RaiseReport;
const CleanupReport = queued_events.CleanupReport;
const Tree = consumer.tree.Tree;
const FullNodeId = consumer.tree_index.FullNodeId;

/// Exact structural, provider, and automation failures. No query tag is collapsed.
pub const Error = consumer.tree.UpdateError || owner_context.ProviderError || error{NullTreeUpdate};

/// Native callbacks borrow the request only until they return.
/// C callbacks receive ownership and must eventually free the converted request.
pub const ActionSink = union(enum) {
    c: struct { callback: boundary.ActionHandler, userdata: ?*anyopaque },
    native: struct {
        callback: *const fn (*const schema.ActionRequest, ?*anyopaque) void,
        userdata: ?*anyopaque,
    },
};

/// A synchronous loan. The consumer must not retain the supplied view.
pub const ActivationConsumer = *const fn (?*const schema.TreeUpdate, ?*anyopaque) void;

/// Invokes the consumer exactly once while its complete cached view remains valid.
/// A null view requests the placeholder. Do not retain consumer_data or the consumer.
pub const BorrowedActivationHandler = *const fn (
    ActivationConsumer,
    ?*anyopaque,
    ?*anyopaque,
) void;

/// C activation transfers a handle. Native activation loans a scoped full view.
pub const ActivationSource = union(enum) {
    c: struct { callback: ActivationHandler, userdata: ?*anyopaque },
    native: struct { callback: BorrowedActivationHandler, userdata: ?*anyopaque },
};

/// A rejected update did not publish. A committed update must not be replayed,
/// even if its notifications failed. Owned input is consumed; borrowed input is unchanged.
pub const UpdateOutcome = union(enum) {
    inactive: void,
    rejected: Error,
    committed: struct {
        events: ?QueuedEventsHolder,
        notification_error: ?owner_context.ProviderError,
        /// The accepted branch initialized the real tree from a full view.
        used_full_tree: bool,
    },
};
/// Inputs for a borrowed native update.
///
/// Both pointers must remain valid for the call. The adapter borrows the selected view and
/// consumes neither input allocation.
pub const BorrowedUpdateOptions = struct {
    /// Delta view borrowed when the owner is active.
    delta: *const schema.TreeUpdate,
    /// Full view borrowed when the owner is a placeholder.
    current_full: *const schema.TreeUpdate,
};

const State = union(enum) {
    inactive: void,
    placeholder: Tree,
    active: Tree,
};

/// Owns one stable Context, one tree, and the registry.
/// The allocator, runtime, and automation table must outlive retained clients.
/// Do not free this owner from a lease or callback on the calling thread.
pub const WindowsAdapter = struct {
    gpa: std.mem.Allocator,
    platform: Platform,
    hwnd: Hwnd,
    is_window_focused: bool,
    action_sink: ActionSink,
    context: *owner_context.Context,
    registry: elements.Registry,
    state: State = .inactive,
    activating: bool = false,
    metadata_owners: c_tree_update.LiveMetadataOwners = .{},
    native_metadata_owners: NativeMetadataOwners = .{},
    last_raise_report: RaiseReport = .{},
    last_error: ?Error = null,

    const UpdateOwnership = enum { owned, borrowed };

    /// Required capabilities and callback ownership. No runtime is implicit.
    pub const Options = struct {
        io: std.Io,
        platform: Platform,
        factory: owner_context.ProviderFactory,
        automation: *const util.AutomationApi,
        hwnd: Hwnd,
        is_window_focused: bool,
        action_sink: ActionSink,
        /// Transfers only when `create` succeeds. On failure, the caller retains authority.
        /// The last weak release invokes the hook once, on that releasing thread.
        /// The hook must not destroy `gpa`. COM wrappers can still need it afterward.
        /// `null` leaves runtime lifetime management with the caller.
        runtime_release: ?owner_context.RuntimeRelease = null,
    };

    const ActivationFrame = struct {
        owner: *WindowsAdapter,
        guard: *owner_context.OwnerLease,
        calls: u32 = 0,
        result: Error!*const ProviderSlot = undefined,

        fn consume(view: ?*const schema.TreeUpdate, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (self.calls != 0) @panic("Native activation consumer called more than once");
            self.calls = 1;
            self.guard.reacquireTree();
            self.result = self.owner.acceptBorrowedActivation(view);
            self.guard.releaseTreeGuard();
        }
    };

    /// Returns an owned adapter. Call `deinit` once after all owner operations end.
    /// Allocation or admission failure rolls back adapter resources without invoking the hook.
    /// Successful creation installs `runtime_release` under an owner pin before publication.
    pub fn create(
        gpa: std.mem.Allocator,
        options: Options,
    ) owner_context.ProviderError!*WindowsAdapter {
        _ = options.platform.init_uia();
        const adapter = try gpa.create(WindowsAdapter);
        errdefer gpa.destroy(adapter);
        adapter.* = .{
            .gpa = gpa,
            .platform = options.platform,
            .hwnd = options.hwnd,
            .is_window_focused = options.is_window_focused,
            .action_sink = options.action_sink,
            .context = undefined,
            .registry = undefined,
        };
        adapter.context = try owner_context.Context.create(
            gpa,
            options.io,
            adapter,
            options.factory,
            options.automation,
        );
        errdefer adapter.context.close();
        adapter.registry = elements.Registry.init(gpa, adapter.context.weak());
        errdefer adapter.registry.deinit(adapter.platform);
        var guard = try adapter.context.enter();
        defer guard.deinit();
        if (options.runtime_release) |authority| {
            guard.control.setRuntimeRelease(authority);
        }
        return adapter;
    }

    /// Closes admission and waits for readers and callbacks before owner teardown.
    /// Retained providers and event holders keep only the closed control block.
    pub fn deinit(self: *WindowsAdapter) void {
        const gpa = self.gpa;
        self.context.close();
        self.destroyCurrentTree();
        self.metadata_owners.deinit();
        self.native_metadata_owners.reap(gpa, null);
        self.registry.deinit(self.platform);
        gpa.destroy(self);
    }

    /// Reads owner state under a guard. Closed admission answers false.
    pub fn isActive(self: *const WindowsAdapter) bool {
        var guard = self.context.enter() catch return false;
        defer guard.deinit();
        return guard.owner.state != .inactive;
    }

    /// Reads placeholder state under a guard. Do not call inside another tree guard.
    pub fn isPlaceholder(self: *const WindowsAdapter) bool {
        var guard = self.context.enter() catch return false;
        defer guard.deinit();
        return guard.owner.state == .placeholder;
    }

    /// Borrows the tree. The caller must already hold this owner's tree guard.
    /// The borrow ends before guard suspension or release.
    pub fn tree(self: *WindowsAdapter) ?*Tree {
        return switch (self.state) {
            .inactive => null,
            .placeholder => |*held| held,
            .active => |*held| held,
        };
    }

    /// Consumes a native update on every path. Its node array uses this owner's gpa.
    /// Toolkit strings are copied before publication. Native data never enters C.
    pub fn updateIfActiveChecked(self: *WindowsAdapter, update: schema.TreeUpdate) UpdateOutcome {
        var owned = update;
        var guard = self.context.enter() catch |err| {
            owned.deinit(self.gpa);
            return .{ .rejected = err };
        };
        defer guard.deinit();
        if (self.state == .inactive) {
            owned.deinit(self.gpa);
            return self.recordOutcome(.inactive);
        }
        self.native_metadata_owners.prepare(self.gpa, self.tree(), &owned) catch |err| {
            owned.deinit(self.gpa);
            self.reapMetadata();
            return self.recordOutcome(.{ .rejected = err });
        };
        return self.recordOutcome(self.applyUpdate(.owned, owned));
    }

    /// Borrows the selected view only during this call; consumes no input allocation.
    /// Full initialization versus delta application is selected under the owner guard.
    pub fn updateIfActiveBorrowedChecked(
        self: *WindowsAdapter,
        options: BorrowedUpdateOptions,
    ) UpdateOutcome {
        var guard = self.context.enter() catch |err| return .{ .rejected = err };
        defer guard.deinit();
        if (self.state == .inactive) return self.recordOutcome(.inactive);
        const selected = switch (self.state) {
            .placeholder => options.current_full,
            .active => options.delta,
            .inactive => unreachable,
        };
        var prepared = selected.*;
        self.native_metadata_owners.prepare(self.gpa, self.tree(), &prepared) catch |err| {
            self.reapMetadata();
            return self.recordOutcome(.{ .rejected = err });
        };
        return self.recordOutcome(self.applyUpdate(.borrowed, &prepared));
    }

    /// C callback wrapper. An inactive owner does not call the factory.
    /// The factory runs within the close barrier, without the tree guard.
    /// Notification errors remain exact but this historical C surface has no commit arm.
    pub fn updateIfActive(
        self: *WindowsAdapter,
        update_factory: boundary.TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) Error!?QueuedEventsHolder {
        var guard = try self.context.enter();
        defer guard.deinit();
        if (self.state == .inactive) {
            self.last_error = null;
            return null;
        }
        const update = self.takeUpdate(&guard, update_factory, update_factory_userdata) catch |err| {
            self.reapMetadata();
            self.last_error = err;
            return err;
        };
        const outcome = self.recordOutcome(self.applyUpdate(.owned, update));
        return switch (outcome) {
            .inactive => null,
            .rejected => |err| err,
            .committed => |result| if (result.notification_error) |err| err else result.events,
        };
    }

    fn recordOutcome(self: *WindowsAdapter, outcome: UpdateOutcome) UpdateOutcome {
        self.last_error = switch (outcome) {
            .inactive => null,
            .rejected => |err| err,
            .committed => |result| if (result.notification_error) |err| err else null,
        };
        return outcome;
    }

    fn applyUpdate(
        self: *WindowsAdapter,
        comptime ownership: UpdateOwnership,
        update: if (ownership == .owned) schema.TreeUpdate else *const schema.TreeUpdate,
    ) UpdateOutcome {
        defer self.reapMetadata();
        switch (self.state) {
            .inactive => {
                if (ownership == .owned) {
                    var owned = update;
                    owned.deinit(self.gpa);
                }
                return .inactive;
            },
            .placeholder => {
                const events = self.replacePlaceholder(ownership, update) catch |err|
                    return .{ .rejected = err };
                return .{ .committed = .{
                    .events = events,
                    .notification_error = null,
                    .used_full_tree = true,
                } };
            },
            .active => {
                var queue = QueuedEventsHolder.init(self);
                var handler = self.makeHandler(&queue.queue);
                defer handler.deinit();
                const held = self.tree().?;
                if (ownership == .owned) {
                    held.updateAndProcessChanges(update, &handler.changeHandler()) catch |err| {
                        queue.deinitUnraised();
                        return .{ .rejected = err };
                    };
                } else {
                    held.updateBorrowedAndProcessChanges(update, &handler.changeHandler()) catch |err| {
                        queue.deinitUnraised();
                        return .{ .rejected = err };
                    };
                }
                // Core preflight rejects before invoking change slots.
                // Handler failures therefore describe notifications after acceptance.
                if (handler.takeFailure()) |failure| {
                    queue.deinitUnraised();
                    return .{ .committed = .{
                        .events = null,
                        .notification_error = failure.first_error.?,
                        .used_full_tree = false,
                    } };
                }
                handler.enqueueSelectionChanges(held.stateOf()) catch |err| {
                    queue.deinitUnraised();
                    return .{ .committed = .{
                        .events = null,
                        .notification_error = err,
                        .used_full_tree = false,
                    } };
                };
                if (handler.takeFailure()) |failure| {
                    queue.deinitUnraised();
                    return .{ .committed = .{
                        .events = null,
                        .notification_error = failure.first_error.?,
                        .used_full_tree = false,
                    } };
                }
                return .{ .committed = .{
                    .events = queue,
                    .notification_error = null,
                    .used_full_tree = false,
                } };
            },
        }
    }

    fn replacePlaceholder(
        self: *WindowsAdapter,
        comptime ownership: UpdateOwnership,
        update: if (ownership == .owned) schema.TreeUpdate else *const schema.TreeUpdate,
    ) Error!QueuedEventsHolder {
        const focused = self.tree().?.stateOf().isHostFocused();
        var real = if (ownership == .owned)
            try Tree.init(self.gpa, update, focused)
        else
            try Tree.initBorrowed(self.gpa, update, focused);
        errdefer real.deinit();
        var queue = QueuedEventsHolder.init(self);
        errdefer queue.deinitUnraised();
        var created_slot: ?FullNodeId = null;
        errdefer if (created_slot) |id| {
            const removed = self.registry.removeSlot(self.platform, id);
            std.debug.assert(removed);
        };
        if (real.stateOf().focus()) |node| {
            const existed = self.registry.existingSlot(node.id()) != null;
            const slot = try self.registry.slotFor(self.platform, node.id());
            if (!existed) created_slot = node.id();
            try queue.append(.{
                .simple = .{ .slot = slot, .event_id = .automation_focus_changed },
            });
        }
        // No fallible work follows this ownership transfer.
        self.destroyCurrentTree();
        self.state = .{ .active = real };
        return queue;
    }

    fn makeHandler(self: *WindowsAdapter, queue: *queued_events.QueuedEvents) change_handler.Handler {
        var handler = change_handler.Handler.init(
            self.gpa,
            self.platform,
            &self.registry,
            queue,
            self.context.automation,
        );
        handler.property_calculator = self.context.factory.enqueue_properties;
        return handler;
    }

    /// Updates focus under a guard. Inactive owners only record the flag.
    pub fn updateWindowFocusState(
        self: *WindowsAdapter,
        is_focused: bool,
    ) Error!?QueuedEventsHolder {
        var guard = try self.context.enter();
        defer guard.deinit();
        if (self.state == .inactive) {
            self.is_window_focused = is_focused;
            self.last_error = null;
            return null;
        }
        const result = self.applyWindowFocus(is_focused) catch |err| {
            self.last_error = err;
            return err;
        };
        self.last_error = null;
        return result;
    }

    fn applyWindowFocus(self: *WindowsAdapter, is_focused: bool) Error!QueuedEventsHolder {
        defer self.reapMetadata();
        var queue = QueuedEventsHolder.init(self);
        errdefer queue.deinitUnraised();
        var handler = self.makeHandler(&queue.queue);
        defer handler.deinit();
        const held = self.tree().?;
        try held.updateHostFocusStateAndProcessChanges(is_focused, &handler.changeHandler());
        if (handler.takeFailure()) |failure| return failure.first_error.?;
        try handler.enqueueSelectionChanges(held.stateOf());
        if (handler.takeFailure()) |failure| return failure.first_error.?;
        return queue;
    }

    /// Retains the provider and owner pin while the native call runs without a tree guard.
    pub fn handleWmGetobject(
        self: *WindowsAdapter,
        wparam: WParam,
        lparam: LParam,
        source: ActivationSource,
    ) Error!COptLResult {
        const objid = syscalls.normalizeObjId(lparam);
        if (objid < 0 and objid != syscalls.uia_root_object_id and
            objid != syscalls.objid_client) return noLResult();
        var guard = try self.context.enter();
        defer guard.deinit();
        const slot = self.rootSlot(&guard, source) catch |err| {
            self.last_error = err;
            return err;
        };
        const platform = self.platform;
        const gpa = self.gpa;
        const hwnd = self.hwnd;
        defer elements.Registry.releaseSlot(platform, gpa, slot);
        guard.beginCallback() catch |err| {
            self.last_error = err;
            return err;
        };
        self.last_error = null;
        guard.releaseTreeGuard();
        const value: LResult = platform.return_raw_element_provider(hwnd, wparam, lparam, slot);
        return .{ .has_value = true, .value = value };
    }

    /// Returns one owned slot reference, including across a native source loan.
    fn rootSlot(
        self: *WindowsAdapter,
        guard: *owner_context.OwnerLease,
        source: ActivationSource,
    ) Error!*const ProviderSlot {
        const slot = switch (self.state) {
            .inactive => return self.activate(guard, source),
            .placeholder => try self.registry.placeholderSlot(self.platform),
            .active => try self.registry.slotFor(self.platform, self.tree().?.stateOf().rootId()),
        };
        elements.Registry.retainSlot(slot);
        return slot;
    }

    /// Consumes a native request, including failed admission and C conversion.
    /// Context serializes action callbacks and installs their single close barrier.
    pub fn dispatchAction(
        self: *WindowsAdapter,
        request: schema.ActionRequest,
    ) owner_context.ProviderError!void {
        try self.context.dispatch(request);
    }

    /// Context-only sink operation. The caller owns a lifetime pin and callback barrier,
    /// holds action serialization, and has released the tree guard.
    pub fn dispatchPinnedAction(
        self: *WindowsAdapter,
        request: schema.ActionRequest,
    ) owner_context.ProviderError!void {
        var owned = request;
        defer owned.deinit(self.gpa);
        switch (self.action_sink) {
            .native => |sink| sink.callback(&owned, sink.userdata),
            .c => |sink| {
                const built = try boundary.createActionRequest(allocation.allocator(), owned);
                action_request.callActionHandler(sink.callback, built, sink.userdata);
            },
        }
    }

    fn activate(
        self: *WindowsAdapter,
        guard: *owner_context.OwnerLease,
        source: ActivationSource,
    ) Error!*const ProviderSlot {
        if (self.activating) return error.InvalidOperation;
        self.activating = true;
        defer self.activating = false;
        defer self.reapMetadata();
        try guard.beginCallback();
        guard.releaseTreeGuard();
        switch (source) {
            .c => |handler| {
                const produced = handler.callback(handler.userdata);
                guard.reacquireTree();
                guard.endCallback();
                const update = if (produced) |handle|
                    try self.metadata_owners.consume(self.gpa, handle, self.tree())
                else
                    try self.placeholderUpdate();
                return self.acceptActivationUpdate(update, produced == null);
            },
            .native => |handler| {
                var frame: ActivationFrame = .{ .owner = self, .guard = guard };
                handler.callback(ActivationFrame.consume, &frame, handler.userdata);
                guard.reacquireTree();
                guard.endCallback();
                if (frame.calls != 1) @panic("Native activation consumer was not called");
                return frame.result;
            },
        }
    }

    fn acceptBorrowedActivation(
        self: *WindowsAdapter,
        view: ?*const schema.TreeUpdate,
    ) Error!*const ProviderSlot {
        if (view) |borrowed| {
            var prepared = borrowed.*;
            try self.native_metadata_owners.prepare(self.gpa, self.tree(), &prepared);
            var real = try Tree.initBorrowed(self.gpa, &prepared, self.is_window_focused);
            return self.publishActivationTree(&real, false);
        }
        return self.acceptActivationUpdate(try self.placeholderUpdate(), true);
    }

    fn acceptActivationUpdate(
        self: *WindowsAdapter,
        update: schema.TreeUpdate,
        placeholder: bool,
    ) Error!*const ProviderSlot {
        var real = try Tree.init(self.gpa, update, self.is_window_focused);
        return self.publishActivationTree(&real, placeholder);
    }

    fn publishActivationTree(
        self: *WindowsAdapter,
        real: *Tree,
        placeholder: bool,
    ) Error!*const ProviderSlot {
        errdefer real.deinit();
        const slot = if (placeholder)
            try self.registry.placeholderSlot(self.platform)
        else
            try self.registry.slotFor(self.platform, real.stateOf().rootId());
        self.state = if (placeholder) .{ .placeholder = real.* } else .{ .active = real.* };
        // The source resumes with the tree guard suspended after its consumer returns.
        // This reference prevents a concurrent removal from freeing the returned slot.
        elements.Registry.retainSlot(slot);
        return slot;
    }

    fn placeholderUpdate(self: *WindowsAdapter) std.mem.Allocator.Error!schema.TreeUpdate {
        var update: schema.TreeUpdate = .{};
        errdefer update.deinit(self.gpa);
        const id: schema.NodeId = .{ .value = 0 };
        try update.pushNode(self.gpa, id, schema.Node.init(self.gpa, .window));
        update.tree = schema.TreeInfo.init(id);
        update.focus = id;
        return update;
    }

    fn takeUpdate(
        self: *WindowsAdapter,
        guard: *owner_context.OwnerLease,
        update_factory: boundary.TreeUpdateFactory,
        userdata: ?*anyopaque,
    ) Error!schema.TreeUpdate {
        try guard.beginCallback();
        guard.releaseTreeGuard();
        const produced = update_factory(userdata);
        guard.reacquireTree();
        guard.endCallback();
        const handle = produced orelse return error.NullTreeUpdate;
        return self.metadata_owners.consume(self.gpa, handle, self.tree());
    }

    fn reapMetadata(self: *WindowsAdapter) void {
        self.metadata_owners.reap(self.tree());
        self.native_metadata_owners.reap(self.gpa, self.tree());
    }

    fn destroyCurrentTree(self: *WindowsAdapter) void {
        switch (self.state) {
            .inactive => {},
            .placeholder => |*held| held.deinit(),
            .active => |*held| held.deinit(),
        }
        self.state = .inactive;
    }
};

fn noLResult() COptLResult {
    return .{ .has_value = false, .value = 0 };
}

/// Owns event providers and a weak control handle, never a borrowed adapter.
/// Keep its allocator and automation authority alive until successful cleanup.
/// Failed cleanup leaves this same holder available for a retry.
pub const QueuedEventsHolder = struct {
    weak: ?owner_context.WeakContext,
    gpa: std.mem.Allocator,
    platform: Platform,
    queue: queued_events.QueuedEvents,

    /// The caller guards the owner while copying these lifetime authorities.
    pub fn init(adapter: *WindowsAdapter) QueuedEventsHolder {
        return .{
            .weak = adapter.context.weak(),
            .gpa = adapter.gpa,
            .platform = adapter.platform,
            .queue = queued_events.QueuedEvents.init(adapter.gpa, adapter.context.automation),
        };
    }

    /// Retains the event's stable provider only when enqueue succeeds.
    pub fn append(
        self: *QueuedEventsHolder,
        event: queued_events.QueuedEvent,
    ) queued_events.QueueError!void {
        try self.queue.append(event);
    }

    /// Cancels delivery. Failure preserves all remaining values and weak authority.
    pub fn deinit(self: *QueuedEventsHolder) CleanupReport {
        const report = self.queue.deinit(self.platform);
        if (report.first_error == null) self.releaseWeak();
        return report;
    }

    /// Native delivery happens without an owner guard. Reports use fresh admission only.
    /// Cleanup failure preserves this holder and suppresses repeated delivery.
    pub fn raise(self: *QueuedEventsHolder) RaiseReport {
        const report = self.queue.raise(self.platform);
        if (self.weak) |weak| {
            if (weak.control.enter()) |entered| {
                var guard = entered;
                defer guard.deinit();
                guard.owner.last_raise_report = report;
            } else |_| {
                // Closed owners have no report destination.
            }
        }
        if (report.cleanup.first_error == null) self.releaseWeak();
        return report;
    }

    /// Returns the number of events still owned by this holder.
    pub fn len(self: *const QueuedEventsHolder) usize {
        return self.queue.len();
    }

    fn releaseWeak(self: *QueuedEventsHolder) void {
        if (self.weak) |held| {
            var owned = held;
            self.weak = null;
            owned.deinit();
        }
    }

    fn deinitUnraised(self: *QueuedEventsHolder) void {
        // Fresh local values have not been exposed to native clients.
        // Their backend must not retain or lock them during error unwinding.
        if (self.deinit().first_error) |err| @panic(@errorName(err));
    }
};

const NativeMetadata = struct {
    name: ?[]u8 = null,
    version: ?[]u8 = null,

    fn deinit(self: *NativeMetadata, gpa: std.mem.Allocator) void {
        if (self.name) |bytes| gpa.free(bytes);
        if (self.version) |bytes| gpa.free(bytes);
        self.* = .{};
    }

    fn borrows(self: NativeMetadata, info: schema.TreeInfo) bool {
        return sameStorage(info.toolkit_name, self.name) or
            sameStorage(info.toolkit_version, self.version);
    }

    fn sameStorage(view: ?[]const u8, storage: ?[]u8) bool {
        const borrowed = view orelse return false;
        const owned = storage orelse return false;
        return borrowed.ptr == owned.ptr and borrowed.len == owned.len;
    }
};

/// Mirrors C metadata liveness without converting native updates to C.
/// Two snapshots plus one incoming update bound the fixed owner slots.
const NativeMetadataOwners = struct {
    const slot_count = 3;
    owners: [slot_count]?NativeMetadata = @splat(null),

    fn prepare(
        self: *NativeMetadataOwners,
        gpa: std.mem.Allocator,
        held: ?*const Tree,
        update: *schema.TreeUpdate,
    ) std.mem.Allocator.Error!void {
        self.reap(gpa, held);
        const info = if (update.tree) |*value| value else return;
        var owned: NativeMetadata = .{};
        errdefer owned.deinit(gpa);
        if (info.toolkit_name) |bytes| {
            if (bytes.len == 0) {
                info.toolkit_name = "";
            } else {
                owned.name = try gpa.dupe(u8, bytes);
                info.toolkit_name = owned.name;
            }
        }
        if (info.toolkit_version) |bytes| {
            if (bytes.len == 0) {
                info.toolkit_version = "";
            } else {
                owned.version = try gpa.dupe(u8, bytes);
                info.toolkit_version = owned.version;
            }
        }
        if (owned.name == null and owned.version == null) return;
        for (&self.owners) |*slot| {
            if (slot.* == null) {
                slot.* = owned;
                return;
            }
        }
        // Only the two root snapshots can retain earlier metadata.
        @panic("Native metadata snapshot bound exceeded");
    }

    fn reap(self: *NativeMetadataOwners, gpa: std.mem.Allocator, held: ?*const Tree) void {
        for (&self.owners) |*slot| {
            var owned = slot.* orelse continue;
            if (held) |live| {
                if (owned.borrows(live.state.info)) continue;
                if (owned.borrows(live.next_state.info)) continue;
            }
            slot.* = null;
            owned.deinit(gpa);
        }
    }
};

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

/// A shared test owner with explicit runtime and automation lifetimes.
pub fn testOwner(
    gpa: std.mem.Allocator,
    io: std.Io,
    automation: *const util.AutomationApi,
) owner_context.ProviderError!*WindowsAdapter {
    if (!builtin.is_test) @compileError("Test-only Windows owner");
    return WindowsAdapter.create(gpa, .{
        .io = io,
        .platform = testPlatform(),
        .factory = testProviderFactory(),
        .automation = automation,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = null } },
    });
}

/// Allocates actual COM references. Native UIA delivery remains unavailable.
pub fn testPlatform() Platform {
    if (!builtin.is_test) @compileError("Test-only provider platform");
    var platform = syscalls.unavailablePlatform();
    platform.create_provider = TestFactory.createProvider;
    platform.destroy_provider = TestFactory.destroyProvider;
    platform.return_raw_element_provider = TestFactory.returnProvider;
    return platform;
}

/// A narrow fixture factory, not the native node or text implementation.
pub fn testProviderFactory() owner_context.ProviderFactory {
    if (!builtin.is_test) @compileError("Test-only provider factory");
    return .{
        .create_node = TestFactory.createNode,
        .create_range = TestFactory.createRange,
        .enqueue_properties = TestFactory.properties,
    };
}

const TestFactory = struct {
    const native = @import("bindings.zig");
    const com = @import("com.zig");
    const ProviderState = struct {
        weak: owner_context.WeakContext,
        node_id: ?FullNodeId,

        pub fn deinit(self: *@This()) void {
            self.weak.deinit();
        }
    };
    const Provider = com.Object(ProviderState, .{com.Descriptor{
        .Interface = native.IRawElementProviderSimple,
        .Iid = native.uia.IID_IRawElementProviderSimple,
    }});
    const vtable: native.IRawElementProviderSimple.VTable = .{
        .base = Provider.baseVTable(0),
        .get_ProviderOptions = options,
        .GetPatternProvider = pattern,
        .GetPropertyValue = property,
        .get_HostRawElementProvider = host,
    };

    fn createNode(
        gpa: std.mem.Allocator,
        weak: owner_context.WeakContext,
        node_id: ?FullNodeId,
    ) owner_context.ProviderError!*native.IRawElementProviderSimple {
        if (comptime native.winapi_resolves) {
            const object = try Provider.create(gpa, .{&vtable}, .{
                .weak = weak,
                .node_id = node_id,
            });
            return @ptrCast(@constCast(object.iface(0)));
        } else {
            return error.NotImplemented;
        }
    }

    fn createRange(
        gpa: std.mem.Allocator,
        weak: owner_context.WeakContext,
        range: consumer.text.range.WeakRange,
    ) owner_context.ProviderError!*native.ITextRangeProvider {
        _ = gpa;
        _ = weak;
        _ = range;
        @panic("This fixture does not construct text ranges");
    }

    fn properties(
        gpa: std.mem.Allocator,
        platform: Platform,
        registry: *elements.Registry,
        queue: *queued_events.QueuedEvents,
        old: consumer.node_id.NodeRef,
        new: consumer.node_id.NodeRef,
    ) owner_context.ProviderError!void {
        _ = gpa;
        _ = platform;
        _ = registry;
        _ = queue;
        // The fixture supports unchanged node data, not missing native deltas.
        if (!old.data().eql(new.data())) return error.InvalidOperation;
    }

    fn createProvider(
        gpa: std.mem.Allocator,
        weak: owner_context.WeakContext,
        node_id: FullNodeId,
        slot: *ProviderSlot,
    ) owner_context.ProviderError!void {
        _ = gpa;
        std.debug.assert(slot.interface == null);
        std.debug.assert(std.meta.eql(slot.node_id.?, node_id));
        slot.interface = @ptrCast(try weak.createNode(slot.node_id));
    }

    fn destroyProvider(gpa: std.mem.Allocator, node_id: FullNodeId, slot: *ProviderSlot) void {
        _ = gpa;
        _ = node_id;
        if (comptime native.winapi_resolves) {
            if (slot.interface) |raw| {
                const unknown: *native.IUnknown = @ptrCast(@alignCast(raw));
                _ = unknown.vtable.Release(unknown);
                slot.interface = null;
            }
        } else {
            std.debug.assert(slot.interface == null);
        }
    }

    fn returnProvider(hwnd: Hwnd, wparam: WParam, lparam: LParam, slot: *const ProviderSlot) LResult {
        _ = hwnd;
        _ = wparam;
        _ = lparam;
        if (comptime native.winapi_resolves) {
            const simple: *native.IRawElementProviderSimple = @ptrCast(@alignCast(slot.interface.?));
            const object = Provider.fromIface(native.IRawElementProviderSimple, @ptrCast(simple));
            const control = object.state.weak.control;
            if (!control.tree_lock.tryLock()) @panic("WM_GETOBJECT held the tree guard");
            control.tree_lock.unlock(control.io);
        }
        return 0;
    }

    fn providerObject(self: *const native.IRawElementProviderSimple) *Provider {
        return Provider.fromIface(native.IRawElementProviderSimple, @ptrCast(self));
    }

    fn lease(self: *const native.IRawElementProviderSimple) owner_context.ProviderError!
        owner_context.ContextLease
    {
        const state = &providerObject(self).state;
        var held = try state.weak.lease();
        errdefer held.deinit();
        if (state.node_id) |id| {
            if (held.state().nodeById(id) == null) return error.ElementNotAvailable;
        }
        return held;
    }

    fn options(
        self: *const native.IRawElementProviderSimple,
        result: ?*native.uia.ProviderOptions,
    ) callconv(.winapi) native.Hresult {
        _ = self;
        const output = result orelse return @bitCast(@as(u32, 0x80004003));
        output.* = .ServerSideProvider;
        return @bitCast(@as(u32, 0));
    }

    fn pattern(
        self: *const native.IRawElementProviderSimple,
        pattern_id: native.uia.UIA_PATTERN_ID,
        result: ?*?*native.IUnknown,
    ) callconv(.winapi) native.Hresult {
        _ = pattern_id;
        const output = result orelse return @bitCast(@as(u32, 0x80004003));
        output.* = null;
        var held = lease(self) catch return @bitCast(native.uia.UIA_E_ELEMENTNOTAVAILABLE);
        defer held.deinit();
        return @bitCast(@as(u32, 0));
    }

    fn property(
        self: *const native.IRawElementProviderSimple,
        property_id: native.uia.UIA_PROPERTY_ID,
        result: ?*native.Variant,
    ) callconv(.winapi) native.Hresult {
        _ = property_id;
        const output = result orelse return @bitCast(@as(u32, 0x80004003));
        output.* = std.mem.zeroes(native.Variant);
        var held = lease(self) catch return @bitCast(native.uia.UIA_E_ELEMENTNOTAVAILABLE);
        defer held.deinit();
        return @bitCast(@as(u32, 0));
    }

    fn host(
        self: *const native.IRawElementProviderSimple,
        result: ?*?*native.IRawElementProviderSimple,
    ) callconv(.winapi) native.Hresult {
        const output = result orelse return @bitCast(@as(u32, 0x80004003));
        output.* = null;
        var held = lease(self) catch return @bitCast(native.uia.UIA_E_ELEMENTNOTAVAILABLE);
        defer held.deinit();
        return @bitCast(@as(u32, 0));
    }
};

/// Owns the explicit runtime until every adapter and retained client is released.
const Fixture = struct {
    gpa: std.mem.Allocator,
    runtime: std.Io.Threaded,
    activation_calls: usize = 0,
    update_calls: usize = 0,

    fn init(gpa: std.mem.Allocator) Fixture {
        return .{ .gpa = gpa, .runtime = std.Io.Threaded.init(gpa, .{}) };
    }

    fn deinit(self: *Fixture) void {
        self.runtime.deinit();
    }
};

/// The fixture behind a callback, or `null` when the caller passed no context.
fn fixtureOf(context: ?*anyopaque) ?*Fixture {
    const any = context orelse return null;
    return @ptrCast(@alignCast(any));
}

/// One whole tree: a window that is its own root and holds the focus.
///
/// The concrete C handle captures the allocator that owns its native update.
/// Every failing path releases what it built.
fn buildWholeTree(gpa: std.mem.Allocator) ?*boundary.CTreeUpdate {
    var update: schema.TreeUpdate = .{};
    const node = schema.Node.init(gpa, .window);
    update.pushNode(gpa, .{ .value = 1 }, node) catch {
        update.deinit(gpa);
        return null;
    };
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const boxed = gpa.create(c_tree_update.accesskit_tree_update) catch {
        update.deinit(gpa);
        return null;
    };
    boxed.* = .{ .gpa = gpa, .update = update, .info = null };
    return @ptrCast(boxed);
}

/// An activation handler that answers one whole tree.
fn activateWithTree(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    const fixture = fixtureOf(context) orelse return null;
    fixture.activation_calls += 1;
    return buildWholeTree(fixture.gpa);
}

/// An activation handler that answers no tree, which is an ordinary answer
/// upstream and means the adapter builds the placeholder.
fn activateWithNothing(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    const fixture = fixtureOf(context) orelse return null;
    fixture.activation_calls += 1;
    return null;
}

/// An update factory that answers one whole tree.
fn wholeTreeFactory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    const fixture = fixtureOf(context) orelse return null;
    fixture.update_calls += 1;
    return buildWholeTree(fixture.gpa);
}

/// An update factory that answers `null`, which upstream unwraps and the port
/// reports as a contract violation.
fn nullFactory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    return null;
}

/// An action handler that releases the request it is handed, which is the duty
/// `dispatchAction` puts on every callback.
fn releaseAction(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
    _ = context;
    const c_gpa = allocation.allocator();
    schema.cActionRequestDeinit(c_gpa, request);
    c_gpa.destroy(request);
}

/// Uses real injected COM ownership and unavailable native event delivery.
fn buildTestAdapter(
    gpa: std.mem.Allocator,
    fixture: *Fixture,
    hwnd: boundary.Hwnd,
    is_window_focused: bool,
) owner_context.ProviderError!*WindowsAdapter {
    return WindowsAdapter.create(gpa, .{
        .io = fixture.runtime.io(),
        .platform = testPlatform(),
        .factory = testProviderFactory(),
        .automation = queued_events.testAutomationApi(),
        .hwnd = hwnd,
        .is_window_focused = is_window_focused,
        .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = fixture } },
    });
}

/// Asserts the state an adapter must be in once it has answered a tree: active,
/// not the placeholder, and holding the tree it answered.
fn expectActivated(target: *WindowsAdapter) !void {
    var guard = try target.context.enter();
    defer guard.deinit();
    try testing.expect(guard.owner.state == .active);
    try testing.expect(guard.owner.tree() != null);
}

fn testHasTree(target: *WindowsAdapter) !bool {
    var guard = try target.context.enter();
    defer guard.deinit();
    return guard.owner.tree() != null;
}

/// How many allocation failures the placeholder sweep tries before it gives
/// up.
///
/// The bound is this constant because the sweep is over an allocator counter
/// rather than over a domain of the adapter: the placeholder arm builds a tree
/// and one provider, and how many allocations that is depends on how the
/// consumer half grows its arrays. The sweep stops at the first attempt that
/// gets past the install, so the bound only has to sit above that count, and a
/// bound that did not would fail the test rather than pass it quietly.
const placeholder_failure_bound: usize = 64;

test "a new adapter is inactive and holds nothing" {
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4000), false);
    defer target.deinit();

    try testing.expect(!target.isActive());
    try testing.expect(!target.isPlaceholder());
    try testing.expect(!try testHasTree(target));
    try testing.expectEqual(@as(usize, 0), target.registry.nodeCount());
    try testing.expectEqual(@as(?Error, null), target.last_error);
    try testing.expectEqual(@as(usize, 0), target.last_raise_report.total());
}

test "an update on an inactive adapter answers null and never calls the factory" {
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4100), false);
    defer target.deinit();

    // `adapter.rs:468` answers `None` in the inactive state, and a factory call
    // there would build a tree the adapter has nowhere to put.
    if (try target.updateIfActive(&wholeTreeFactory, &fixture) != null) {
        return error.EventsOnAnInactiveAdapter;
    }
    try testing.expectEqual(@as(usize, 0), fixture.update_calls);
    try testing.expect(!target.isActive());
}

test "the inactive focus arm records the flag and answers null" {
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4200), false);
    defer target.deinit();

    if (try target.updateWindowFocusState(true) != null) return error.EventsOnAnInactiveAdapter;
    // The flag is the whole of what this arm records, at `adapter.rs:502-506`,
    // because an adapter with no tree has no tree to apply it to.
    try testing.expect(target.is_window_focused);
    try testing.expect(!target.isActive());
    try testing.expect(!try testHasTree(target));
}

test "a WM_GETOBJECT for an identifier this adapter does not own stays inactive" {
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4300), false);
    defer target.deinit();
    {
        var guard = try target.context.enter();
        defer guard.deinit();
        guard.owner.last_error = error.InvalidOperation;
    }

    // `adapter.rs:544-547` passes every negative identifier that is neither
    // `UiaRootObjectId` nor `OBJID_CLIENT` to `DefWindowProc`, so the
    // activation handler is never reached.
    const answer = try target.handleWmGetobject(
        0,
        @as(LParam, -5),
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    try testing.expect(!answer.has_value);
    try testing.expectEqual(@as(isize, 0), answer.value);
    try testing.expectEqual(@as(usize, 0), fixture.activation_calls);
    try testing.expect(!target.isActive());
    var guard = try target.context.enter();
    defer guard.deinit();
    try testing.expectEqual(error.InvalidOperation, guard.owner.last_error.?);
}

test "activation that answers no tree enters the placeholder state" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4400), false);
    defer target.deinit();

    const answer = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    try testing.expect(answer.has_value);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    try testing.expect(target.isActive());
    try testing.expect(target.isPlaceholder());
    // The placeholder provider names no node, so it is not in the map and the
    // count stays at zero. `adapter.rs:575` builds it with
    // `PlatformNode::unspecified_root`.
    try testing.expectEqual(@as(usize, 0), target.registry.nodeCount());
}

test "activation that answers a tree enters the active state" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4500), false);
    defer target.deinit();

    const answer = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    try testing.expect(answer.has_value);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    try expectActivated(target);
    // The real tree has a root node, so the adapter publishes a provider for
    // it rather than naming the placeholder.
    try testing.expectEqual(@as(usize, 1), target.registry.nodeCount());
}

test "a second WM_GETOBJECT in the placeholder state answers the same provider" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4600), false);
    defer target.deinit();

    const first = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    const second = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    try testing.expect(first.has_value);
    try testing.expect(second.has_value);
    // The activation handler ran once. A second run would build a second
    // placeholder over the first, and the three states have no edge between
    // them that would allow it.
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    try testing.expect(target.isPlaceholder());
}

test "the first update replaces the placeholder with the real tree" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4700), true);
    defer target.deinit();

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    try testing.expect(target.isPlaceholder());

    // The window holds focus and the tree declares one, so the placeholder arm
    // queues the single focus event of `adapter.rs:470-480`.
    var events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try expectActivated(target);
    try testing.expectEqual(@as(usize, 1), fixture.update_calls);
    try testing.expectEqual(@as(usize, 1), target.registry.nodeCount());
    try testing.expectEqual(@as(usize, 1), events.len());
    _ = events.raise();
}

test "a focus update on the placeholder keeps the placeholder state" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4800), true);
    defer target.deinit();

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    var events = (try target.updateWindowFocusState(false)) orelse return error.NoEvents;

    // The focus arm applies the flag to the tree the state holds, and the
    // placeholder tree is the tree the state holds.
    try testing.expect(target.isActive());
    try testing.expect(target.isPlaceholder());
    try testing.expectEqual(@as(usize, 0), fixture.update_calls);
    _ = events.raise();
}

test "no call takes an activated adapter back to inactive or to the placeholder" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4900), true);
    defer target.deinit();

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    try expectActivated(target);

    // Each state has one direction. There is no `deactivate` in this module or
    // upstream, and the only place that releases a tree outside `deinit` is the
    // placeholder arm of `updateIfActive`, which installs the real tree where
    // the placeholder was. Every public operation is walked here, so an
    // operation added later is covered by the same assertion. The activation
    // handler here answers no tree, so an arm that reached it would leave the
    // adapter in the placeholder and fail the second assertion.
    var events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try expectActivated(target);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
    _ = events.raise();

    var focused = (try target.updateWindowFocusState(false)) orelse return error.NoEvents;
    try expectActivated(target);
    _ = focused.raise();

    const answered = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    try testing.expect(answered.has_value);
    try expectActivated(target);
    try testing.expectEqual(@as(usize, 1), fixture.activation_calls);
}

test "a factory that answers null is refused and leaves the state untouched" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4A00), true);
    defer target.deinit();

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    try testing.expectError(error.NullTreeUpdate, target.updateIfActive(&nullFactory, &fixture));
    const recorded = target.last_error orelse return error.NoLastError;
    try testing.expectEqual(error.NullTreeUpdate, recorded);
    try expectActivated(target);
}

/// Runs one placeholder-to-active update whose `index`-th allocation fails,
/// and asserts that the adapter still holds a tree afterwards.
///
/// Answers whether the call got past the install of the real tree, which is
/// what ends the sweep: an index above that one exercises the active arm and
/// the queue rather than the placeholder arm this test is about.
///
/// **Errors.** `error.OutOfMemory` from building the adapter, plus the tags the
/// body names.
fn placeholderUpdateFailingAt(gpa: std.mem.Allocator, index: usize) !bool {
    var fixture = Fixture.init(gpa);
    defer fixture.deinit();
    // The default configuration never fails, so the adapter and the
    // placeholder are built whole and `index` counts from the update's own
    // first allocation.
    var failing: std.testing.FailingAllocator = .init(gpa, .{});
    fixture.gpa = failing.allocator();
    const target = try buildTestAdapter(failing.allocator(), &fixture, @ptrFromInt(0x4B00), true);
    defer target.deinit();

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    try testing.expect(target.isPlaceholder());

    failing.fail_index = failing.alloc_index + index;
    const outcome = target.updateIfActive(&wholeTreeFactory, &fixture) catch |err| {
        // Two tags can come back. `error.OutOfMemory` is the failure the
        // contract is about, and `error.NullTreeUpdate` is the same failure
        // arriving inside the factory, which answers `null` rather than a tree
        // when it cannot build one. What is asserted is the state, not the tag.
        try testing.expect(err == error.OutOfMemory or err == error.NullTreeUpdate);
        try testing.expect(target.isActive());
        try testing.expect(try testHasTree(target));
        try testing.expect(target.isPlaceholder());
        return false;
    };
    try testing.expect(target.isActive());
    var events = outcome orelse return error.NoEvents;
    _ = events.raise();
    return true;
}

test "no allocation failure leaves the adapter without the tree it held" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    // Every allocation the update makes is failed in turn, each on an adapter
    // of its own, and one property has to hold at every index: an adapter that
    // has a tree still has one. The alternative is an adapter left inactive,
    // which answers `null` to every later update and needs the application to
    // activate it a second time.
    //
    // The adapters run on `std.testing.allocator`, so every index is under the
    // per-test leak check and a block lost on any of them is a leak rather
    // than a silent success.
    var index: usize = 0;
    while (index <= placeholder_failure_bound) : (index += 1) {
        if (try placeholderUpdateFailingAt(testing.allocator, index)) return;
    }
    return error.SweepReachedItsBound;
}

test "the raise records its report on the adapter that produced the events" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4C00), true);
    defer target.deinit();

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.uia_root_object_id),
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    var events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try testing.expectEqual(@as(usize, 0), target.last_raise_report.total());

    // The seam for this target refuses every event, so the report counts one
    // event as unavailable rather than as raised, and it lands on the adapter
    // that `windowsAdapterDebug` reads.
    const report = events.raise();
    try testing.expectEqual(@as(usize, 1), report.total());
    try testing.expectEqual(@as(usize, 1), report.unavailable);
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.total());
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.unavailable);
}

test "deinit releases the tree, the providers and the adapter" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, @ptrFromInt(0x4D00), true);

    _ = try target.handleWmGetobject(
        0,
        @as(LParam, syscalls.objid_client),
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    var events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    try expectActivated(target);
    _ = events.raise();

    // Every block above comes from `testing.allocator`, so the per-test leak
    // check is the assertion: a tree, a provider or the adapter left behind is
    // reported as a leak instead of passing quietly. An event holder owns its
    // providers independently; it can also be raised after adapter close.
    target.deinit();
}

test "dispatch consumes an owned value request when C conversion rejects an interior nul" {
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    defer target.deinit();
    const value = try testing.allocator.dupe(u8, "x\x00y");
    try testing.expectError(error.InteriorNul, target.dispatchAction(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .value = value },
    }));
}

test "a provider weak context refuses all reads after adapter close" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    var weak = target.context.weak();
    defer weak.deinit();
    _ = try target.handleWmGetobject(
        0,
        syscalls.objid_client,
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    target.deinit();
    try testing.expectError(error.ElementNotAvailable, weak.lease());
}

test "outstanding events can raise and release their providers after adapter close" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, true);
    _ = try target.handleWmGetobject(
        0,
        syscalls.objid_client,
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    var events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    target.deinit();
    const report = events.raise();
    try testing.expectEqual(@as(usize, 1), report.unavailable);
    try testing.expectEqual(@as(usize, 1), report.total());
    try testing.expectEqual(@as(usize, 0), events.len());
}

test "outstanding events can be cancelled after adapter close" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, true);
    _ = try target.handleWmGetobject(
        0,
        syscalls.objid_client,
        .{ .c = .{ .callback = &activateWithNothing, .userdata = &fixture } },
    );
    var events = (try target.updateIfActive(&wholeTreeFactory, &fixture)) orelse
        return error.NoEvents;
    target.deinit();
    const report = events.deinit();
    try testing.expectEqual(@as(usize, 0), report.error_count);
    try testing.expectEqual(@as(usize, 0), events.len());
}

test "an update factory can lease and read the active tree without a tree lock" {
    const Reentrant = struct {
        owner: *WindowsAdapter,
        saw_root: bool = false,

        fn produce(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            var weak = self.owner.context.weak();
            defer weak.deinit();
            var lease = weak.lease() catch return null;
            self.saw_root = lease.state().rootId().local.value == 1;
            lease.deinit();
            return buildWholeTree(self.owner.gpa);
        }
    };
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, true);
    defer target.deinit();
    _ = try target.handleWmGetobject(
        0,
        syscalls.objid_client,
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    );
    var reentrant: Reentrant = .{ .owner = target };
    var events = (try target.updateIfActive(&Reentrant.produce, &reentrant)) orelse
        return error.NoEvents;
    try testing.expect(reentrant.saw_root);
    try testing.expectEqual(@as(usize, 0), events.deinit().error_count);
}

test "activation preserves its exact provider factory error and the inactive state" {
    const Reject = struct {
        fn create(
            gpa: std.mem.Allocator,
            weak: @import("context.zig").WeakContext,
            node_id: ?consumer.tree_index.FullNodeId,
        ) @import("context.zig").ProviderError!*@import("bindings.zig").IRawElementProviderSimple {
            _ = gpa;
            _ = weak;
            _ = node_id;
            return error.ProviderLimitExceeded;
        }
    };
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    var factory = testProviderFactory();
    factory.create_node = Reject.create;
    const target = try WindowsAdapter.create(testing.allocator, .{
        .io = fixture.runtime.io(),
        .platform = testPlatform(),
        .factory = factory,
        .automation = queued_events.testAutomationApi(),
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = &fixture } },
    });
    defer target.deinit();
    try testing.expectError(error.ProviderLimitExceeded, target.handleWmGetobject(
        0,
        syscalls.objid_client,
        .{ .c = .{ .callback = &activateWithTree, .userdata = &fixture } },
    ));
    try testing.expectEqual(error.ProviderLimitExceeded, target.last_error.?);
    try testing.expect(!target.isActive());
    try testing.expectEqual(@as(usize, 0), target.registry.nodeCount());
}

test "native action sinks borrow the complete owned value including embedded nul" {
    const Seen = struct {
        calls: usize = 0,
        value: [3]u8 = undefined,
        owner: ?*WindowsAdapter = null,
        tree_unlocked: bool = false,
        callback_count: u32 = 0,

        fn action(request: *const schema.ActionRequest, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            const bytes = request.data.?.value;
            std.debug.assert(bytes.len == self.value.len);
            @memcpy(&self.value, bytes);
            const control = self.owner.?.context;
            self.tree_unlocked = control.tree_lock.tryLock();
            if (self.tree_unlocked) control.tree_lock.unlock(control.io);
            control.life_lock.lockUncancelable(control.io);
            self.callback_count = control.callbacks;
            control.life_lock.unlock(control.io);
        }
    };
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    var seen: Seen = .{};
    const target = try WindowsAdapter.create(testing.allocator, .{
        .io = runtime.io(),
        .platform = testPlatform(),
        .factory = testProviderFactory(),
        .automation = queued_events.testAutomationApi(),
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .native = .{ .callback = Seen.action, .userdata = &seen } },
    });
    defer target.deinit();
    seen.owner = target;
    const value = try testing.allocator.dupe(u8, "x\x00y");
    try target.dispatchAction(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .value = value },
    });
    try testing.expectEqual(@as(usize, 1), seen.calls);
    try testing.expectEqualSlices(u8, "x\x00y", &seen.value);
    try testing.expect(seen.tree_unlocked);
    try testing.expectEqual(@as(u32, 1), seen.callback_count);
}

test "activation callback has one close barrier and can enter the inactive owner" {
    const Seen = struct {
        owner: *WindowsAdapter,
        entered: bool = false,
        callback_count: u32 = 0,

        fn activate(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            var guard = self.owner.context.enter() catch return null;
            defer guard.deinit();
            self.entered = guard.owner.state == .inactive;
            guard.control.life_lock.lockUncancelable(guard.control.io);
            self.callback_count = guard.control.callbacks;
            guard.control.life_lock.unlock(guard.control.io);
            return null;
        }
    };
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    defer target.deinit();
    var seen: Seen = .{ .owner = target };
    const answer = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = Seen.activate, .userdata = &seen },
    });
    try testing.expect(answer.has_value);
    try testing.expect(seen.entered);
    try testing.expectEqual(@as(u32, 1), seen.callback_count);
    try testing.expect(target.isPlaceholder());
}

test "an active update preserves the exact injected property calculator failure" {
    const Reject = struct {
        fn properties(
            gpa: std.mem.Allocator,
            platform: Platform,
            registry: *elements.Registry,
            queue: *queued_events.QueuedEvents,
            old: consumer.node_id.NodeRef,
            new: consumer.node_id.NodeRef,
        ) @import("context.zig").ProviderError!void {
            _ = gpa;
            _ = platform;
            _ = registry;
            _ = queue;
            _ = old;
            _ = new;
            return error.InvalidOperation;
        }

        fn changed(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const fixture = fixtureOf(userdata).?;
            var update: schema.TreeUpdate = .{};
            update.pushNode(fixture.gpa, .{ .value = 1 }, schema.Node.init(
                fixture.gpa,
                .button,
            )) catch {
                update.deinit(fixture.gpa);
                return null;
            };
            update.tree = schema.TreeInfo.init(.{ .value = 1 });
            update.focus = .{ .value = 1 };
            const boxed = fixture.gpa.create(c_tree_update.accesskit_tree_update) catch {
                update.deinit(fixture.gpa);
                return null;
            };
            boxed.* = .{ .gpa = fixture.gpa, .update = update, .info = null };
            return @ptrCast(boxed);
        }
    };
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    var factory = testProviderFactory();
    factory.enqueue_properties = Reject.properties;
    const target = try WindowsAdapter.create(testing.allocator, .{
        .io = fixture.runtime.io(),
        .platform = testPlatform(),
        .factory = factory,
        .automation = queued_events.testAutomationApi(),
        .hwnd = null,
        .is_window_focused = true,
        .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = &fixture } },
    });
    defer target.deinit();
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithTree, .userdata = &fixture },
    });
    try testing.expectError(
        error.InvalidOperation,
        target.updateIfActive(Reject.changed, &fixture),
    );
    try testing.expectEqual(error.InvalidOperation, target.last_error.?);
    try testing.expect(target.isActive());

    var accepted: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    try accepted.pushNode(testing.allocator, .{ .value = 1 }, schema.Node.init(
        testing.allocator,
        .window,
    ));
    const committed = target.updateIfActiveChecked(accepted);
    switch (committed) {
        .committed => |result| {
            try testing.expect(!result.used_full_tree);
            try testing.expectEqual(error.InvalidOperation, result.notification_error.?);
            try testing.expect(result.events == null);
        },
        else => return error.AcceptedUpdateReportedAsRejected,
    }
    var rejected: schema.TreeUpdate = .{ .focus = .{ .value = 999 } };
    try rejected.pushNode(testing.allocator, .{ .value = 1 }, schema.Node.init(
        testing.allocator,
        .button,
    ));
    switch (target.updateIfActiveChecked(rejected)) {
        .rejected => |err| try testing.expectEqual(error.FocusNotInTree, err),
        else => return error.InvalidUpdateReportedAsCommitted,
    }
    var guard = try target.context.enter();
    defer guard.deinit();
    const root = guard.owner.tree().?.stateOf().root();
    try testing.expectEqual(schema.Role.window, root.data().role);
}

test "holder cleanup retries retain all authority after adapter close without redelivery" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    const ClearState = struct {
        locked: bool = true,
        cleared_i4: usize = 0,

        fn clear(
            userdata: ?*anyopaque,
            raw: *@import("bindings.zig").Variant,
        ) @import("bindings.zig").Hresult {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            if (@intFromEnum(raw.Anonymous.Anonymous.vt) == 3) {
                if (self.locked and raw.Anonymous.Anonymous.Anonymous.lVal == 7) {
                    return @bitCast(@as(u32, 0x8002000d));
                }
                self.cleared_i4 += 1;
            }
            raw.* = std.mem.zeroes(@import("bindings.zig").Variant);
            return @bitCast(@as(u32, 0));
        }
    };
    inline for (.{ false, true }) |raise| {
        var runtime = std.Io.Threaded.init(testing.allocator, .{});
        defer runtime.deinit();
        var state: ClearState = .{};
        var api = queued_events.testAutomationApi().*;
        api.context = &state;
        api.variant_clear = ClearState.clear;
        const target = try testOwner(testing.allocator, runtime.io(), &api);
        var owner_live = true;
        defer if (owner_live) target.deinit();
        var holder = QueuedEventsHolder.init(target);
        defer {
            state.locked = false;
            if (holder.deinit().first_error) |err| @panic(@errorName(err));
        }
        var guard = try target.context.enter();
        defer guard.deinit();
        const slot = try target.registry.slotFor(target.platform, .init(
            .{ .value = 1 },
            .init(0),
        ));
        var old = @import("util.zig").VariantOwner.fromI32(&api, 7);
        var new = @import("util.zig").VariantOwner.fromI32(&api, 9);
        try holder.queue.appendProperty(slot, .selection_item_is_selected, &old, &new);
        guard.deinit();
        owner_live = false;
        target.deinit();
        const first = if (raise) blk: {
            const report = holder.raise();
            try testing.expectEqual(@as(usize, 1), report.unavailable);
            break :blk report.cleanup;
        } else holder.deinit();
        try testing.expectEqual(error.ArrayLocked, first.first_error.?);
        try testing.expectEqual(@as(usize, 1), first.error_count);
        try testing.expectEqual(@as(usize, 1), state.cleared_i4);
        try testing.expectEqual(@as(usize, 1), holder.len());
        state.locked = false;
        const second = if (raise) blk: {
            const report = holder.raise();
            try testing.expectEqual(@as(usize, 0), report.total());
            break :blk report.cleanup;
        } else holder.deinit();
        try testing.expect(second.first_error == null);
        try testing.expectEqual(@as(usize, 2), state.cleared_i4);
        try testing.expectEqual(@as(usize, 0), holder.len());
    }
}

test "a retained COM provider returns element unavailable after its adapter closes" {
    const native = @import("bindings.zig");
    if (!native.winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    var owner_live = true;
    defer if (owner_live) target.deinit();
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithTree, .userdata = &fixture },
    });
    var weak = target.context.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    const provider = try lease.provider(lease.state().rootId());
    const unknown: *native.IUnknown = @ptrCast(provider);
    defer _ = unknown.vtable.Release(unknown);
    lease.deinit();
    var raw = std.mem.zeroes(native.Variant);
    const before = provider.vtable.GetPropertyValue(provider, native.uia.UIA_NamePropertyId, &raw);
    try testing.expectEqual(@as(u32, 0), @as(u32, @bitCast(before)));
    owner_live = false;
    target.deinit();
    const after = provider.vtable.GetPropertyValue(provider, native.uia.UIA_NamePropertyId, &raw);
    try testing.expectEqual(native.uia.UIA_E_ELEMENTNOTAVAILABLE, @as(u32, @bitCast(after)));
}

test "an inactive checked update consumes the owned node array" {
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const target = try testOwner(testing.allocator, runtime.io(), queued_events.testAutomationApi());
    defer target.deinit();
    var update: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    try update.pushNode(testing.allocator, .{ .value = 1 }, schema.Node.init(
        testing.allocator,
        .window,
    ));
    switch (target.updateIfActiveChecked(update)) {
        .inactive => {},
        else => return error.InactiveUpdateWasApplied,
    }
    try testing.expect(!target.isActive());
}

test "checked native metadata owns toolkit bytes without changing null or empty values" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    defer target.deinit();
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithNothing, .userdata = &fixture },
    });
    const name = try testing.allocator.dupe(u8, "tool\x00kit");
    defer testing.allocator.free(name);
    var update: schema.TreeUpdate = .{
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = name,
            .toolkit_version = "",
        },
        .focus = .{ .value = 1 },
    };
    try update.pushNode(testing.allocator, .{ .value = 1 }, schema.Node.init(
        testing.allocator,
        .window,
    ));
    switch (target.updateIfActiveChecked(update)) {
        .committed => |result| {
            try testing.expect(result.used_full_tree);
            try testing.expect(result.notification_error == null);
            if (result.events) |events| {
                var owned = events;
                if (owned.deinit().first_error) |err| return err;
            }
        },
        else => return error.MetadataUpdateNotCommitted,
    }
    @memset(name, 'x');
    var guard = try target.context.enter();
    defer guard.deinit();
    const info = guard.owner.tree().?.stateOf().info;
    try testing.expectEqualSlices(u8, "tool\x00kit", info.toolkit_name.?);
    try testing.expect(info.toolkit_version != null);
    try testing.expectEqual(@as(usize, 0), info.toolkit_version.?.len);
}

test "native activation clones one scoped full view before any native return call" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    const Loan = struct {
        view: schema.TreeUpdate,
        name: []u8,
        calls: usize = 0,
        returned: bool = false,

        fn provide(consume: ActivationConsumer, consumer_data: ?*anyopaque, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            consume(&self.view, consumer_data);
            self.view.nodes.items[0].node.role = .button;
            const label = schema.strings.label(&self.view.nodes.items[0].node.properties).?;
            @memset(@constCast(label), 'x');
            @memset(self.name, 'x');
            self.returned = true;
        }

        fn nativeReturn(hwnd: Hwnd, w: WParam, l: LParam, slot: *const ProviderSlot) LResult {
            const self: *@This() = @ptrCast(@alignCast(hwnd.?));
            if (!self.returned) @panic("Native return ran inside the borrowed source scope");
            return TestFactory.returnProvider(hwnd, w, l, slot);
        }
    };
    var runtime = std.Io.Threaded.init(testing.allocator, .{});
    defer runtime.deinit();
    const name = try testing.allocator.dupe(u8, "loan\x00meta");
    defer testing.allocator.free(name);
    var loan: Loan = .{
        .view = .{
            .tree = .{ .root = .{ .value = 1 }, .toolkit_name = name, .toolkit_version = null },
            .focus = .{ .value = 1 },
        },
        .name = name,
    };
    defer loan.view.deinit(testing.allocator);
    var node = schema.Node.init(testing.allocator, .window);
    schema.strings.setLabel(&node.properties, "loan-name") catch |err| {
        node.deinit();
        return err;
    };
    try loan.view.pushNode(testing.allocator, .{ .value = 1 }, node);
    var platform = testPlatform();
    platform.return_raw_element_provider = Loan.nativeReturn;
    const target = try WindowsAdapter.create(testing.allocator, .{
        .io = runtime.io(),
        .platform = platform,
        .factory = testProviderFactory(),
        .automation = queued_events.testAutomationApi(),
        .hwnd = @ptrCast(&loan),
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = null } },
    });
    defer target.deinit();
    const answer = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .native = .{ .callback = Loan.provide, .userdata = &loan },
    });
    try testing.expect(answer.has_value);
    try testing.expectEqual(@as(usize, 1), loan.calls);
    var guard = try target.context.enter();
    defer guard.deinit();
    const held = guard.owner.tree().?.stateOf();
    try testing.expectEqual(schema.Role.window, held.root().data().role);
    try testing.expectEqualStrings("loan-name", schema.strings.label(&held.root().data().properties).?);
    try testing.expectEqualSlices(u8, "loan\x00meta", held.info.toolkit_name.?);
    try testing.expect(held.info.toolkit_version == null);
}

test "repeated native metadata updates preserve empty null and nonempty values past the owner bound" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    defer target.deinit();
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithNothing, .userdata = &fixture },
    });
    const names = [_]?[]const u8{ "", "one", null, "", "two", "", null, "three", "", "" };
    for (names) |name| {
        var update: schema.TreeUpdate = .{
            .tree = .{ .root = .{ .value = 1 }, .toolkit_name = name, .toolkit_version = "" },
            .focus = .{ .value = 1 },
        };
        try update.pushNode(testing.allocator, .{ .value = 1 }, schema.Node.init(
            testing.allocator,
            .window,
        ));
        switch (target.updateIfActiveChecked(update)) {
            .committed => |result| {
                try testing.expect(result.notification_error == null);
                if (result.events) |events| {
                    var owned = events;
                    if (owned.deinit().first_error) |err| return err;
                }
            },
            else => return error.MetadataUpdateRejected,
        }
        var guard = try target.context.enter();
        defer guard.deinit();
        const info = guard.owner.tree().?.stateOf().info;
        if (name) |expected| {
            try testing.expectEqualSlices(u8, expected, info.toolkit_name.?);
        } else {
            try testing.expect(info.toolkit_name == null);
        }
        try testing.expect(info.toolkit_version != null);
        try testing.expectEqual(@as(usize, 0), info.toolkit_version.?.len);
        guard.deinit();
    }
}

/// Fails each metadata, tree, provider, and focus-queue allocation before publication.
/// The sweep stops at first success; exhausting the fixed bound is a test failure.
fn nativeMetadataUpdateFailingAt(index: usize) !bool {
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    fixture.gpa = failing.allocator();
    const target = try buildTestAdapter(failing.allocator(), &fixture, null, true);
    defer target.deinit();
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithNothing, .userdata = &fixture },
    });
    var update: schema.TreeUpdate = .{
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "native-name",
            .toolkit_version = "native-version",
        },
        .focus = .{ .value = 1 },
    };
    try update.pushNode(failing.allocator(), .{ .value = 1 }, schema.Node.init(
        failing.allocator(),
        .window,
    ));
    failing.fail_index = failing.alloc_index + index;
    switch (target.updateIfActiveChecked(update)) {
        .rejected => |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            var guard = try target.context.enter();
            defer guard.deinit();
            try testing.expect(guard.owner.state == .placeholder);
            try testing.expectEqual(@as(usize, 0), guard.owner.registry.nodeCount());
            try testing.expect(guard.owner.tree().?.stateOf().info.toolkit_name == null);
            try testing.expect(guard.owner.tree().?.stateOf().info.toolkit_version == null);
            return false;
        },
        .committed => |result| {
            try testing.expect(result.used_full_tree);
            try testing.expect(result.notification_error == null);
            var events = result.events orelse return error.NoEvents;
            defer if (events.deinit().first_error) |err| @panic(@errorName(err));
            var guard = try target.context.enter();
            defer guard.deinit();
            try testing.expect(guard.owner.state == .active);
            const info = guard.owner.tree().?.stateOf().info;
            try testing.expectEqualStrings("native-name", info.toolkit_name.?);
            try testing.expectEqualStrings("native-version", info.toolkit_version.?);
            return true;
        },
        .inactive => return error.NativeUpdateUnexpectedlyInactive,
    }
}

test "native metadata and placeholder preflight failures never publish or leak" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    const allocation_failure_bound = 128;
    for (0..allocation_failure_bound) |index| {
        if (try nativeMetadataUpdateFailingAt(index)) return;
    }
    return error.AllocationFailureSweepExhausted;
}

test "checked borrowed full views remain unchanged and reusable after inactive and repeated commits" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    defer target.deinit();
    const name = try testing.allocator.dupe(u8, "borrowed\x00metadata");
    defer testing.allocator.free(name);
    var view: schema.TreeUpdate = .{
        .tree = .{ .root = .{ .value = 1 }, .toolkit_name = name, .toolkit_version = "" },
        .focus = .{ .value = 1 },
    };
    defer view.deinit(testing.allocator);
    var node = schema.Node.init(testing.allocator, .window);
    schema.strings.setLabel(&node.properties, "cached-label") catch |err| {
        node.deinit();
        return err;
    };
    try view.pushNode(testing.allocator, .{ .value = 1 }, node);
    const entries = view.nodes.items.ptr;
    try testing.expect(target.updateIfActiveBorrowedChecked(.{
        .delta = &view,
        .current_full = &view,
    }) == .inactive);
    try testing.expectEqual(@as(usize, 1), view.nodes.items.len);
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithNothing, .userdata = &fixture },
    });
    view.focus = .{ .value = 999 };
    switch (target.updateIfActiveBorrowedChecked(.{
        .delta = &view,
        .current_full = &view,
    })) {
        .rejected => |err| try testing.expectEqual(error.FocusNotInTree, err),
        else => return error.InvalidBorrowedViewWasAccepted,
    }
    try testing.expectEqual(@as(usize, 1), view.nodes.items.len);
    try testing.expectEqualStrings("cached-label", schema.strings.label(
        &view.nodes.items[0].node.properties,
    ).?);
    try testing.expect(target.isPlaceholder());
    view.focus = .{ .value = 1 };
    for (0..5) |index| {
        switch (target.updateIfActiveBorrowedChecked(.{
            .delta = &view,
            .current_full = &view,
        })) {
            .committed => |result| {
                try testing.expectEqual(index == 0, result.used_full_tree);
                try testing.expect(result.notification_error == null);
                if (result.events) |events| {
                    var owned = events;
                    if (owned.deinit().first_error) |err| return err;
                }
            },
            else => return error.BorrowedUpdateRejected,
        }
        try testing.expectEqual(@as(usize, 1), view.nodes.items.len);
        try testing.expect(view.nodes.items.ptr == entries);
        try testing.expect(view.tree.?.toolkit_name.?.ptr == name.ptr);
        try testing.expectEqualSlices(u8, "borrowed\x00metadata", view.tree.?.toolkit_name.?);
        try testing.expectEqualStrings("cached-label", schema.strings.label(&view.nodes.items[0].node.properties).?);
        var guard = try target.context.enter();
        defer guard.deinit();
        const info = guard.owner.tree().?.stateOf().info;
        try testing.expectEqualSlices(u8, "borrowed\x00metadata", info.toolkit_name.?);
        try testing.expectEqualStrings("cached-label", schema.strings.label(
            &guard.owner.tree().?.stateOf().root().data().properties,
        ).?);
    }
    @memset(name, 'x');
    const source_label = schema.strings.label(&view.nodes.items[0].node.properties).?;
    @memset(@constCast(source_label), 'x');
    var guard = try target.context.enter();
    defer guard.deinit();
    const held = guard.owner.tree().?.stateOf();
    try testing.expectEqualSlices(u8, "borrowed\x00metadata", held.info.toolkit_name.?);
    try testing.expectEqualStrings("cached-label", schema.strings.label(&held.root().data().properties).?);
}

fn borrowedActivationFailingAt(index: usize) !bool {
    const Loan = struct {
        view: *const schema.TreeUpdate,
        calls: usize = 0,

        fn provide(consume: ActivationConsumer, consumer_data: ?*anyopaque, userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            consume(self.view, consumer_data);
        }
    };
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    var failing = testing.FailingAllocator.init(testing.allocator, .{});
    const target = try buildTestAdapter(failing.allocator(), &fixture, null, false);
    defer target.deinit();
    var view: schema.TreeUpdate = .{
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "borrowed-toolkit",
            .toolkit_version = "borrowed-version",
        },
        .focus = .{ .value = 1 },
    };
    defer view.deinit(testing.allocator);
    var node = schema.Node.init(testing.allocator, .window);
    schema.strings.setLabel(&node.properties, "borrowed-activation") catch |err| {
        node.deinit();
        return err;
    };
    try view.pushNode(testing.allocator, .{ .value = 1 }, node);
    var loan: Loan = .{ .view = &view };
    failing.fail_index = failing.alloc_index + index;
    const outcome = target.handleWmGetobject(0, syscalls.objid_client, .{
        .native = .{ .callback = Loan.provide, .userdata = &loan },
    });
    try testing.expectEqual(@as(usize, 1), loan.calls);
    try testing.expectEqual(@as(usize, 1), view.nodes.items.len);
    try testing.expectEqualStrings("borrowed-activation", schema.strings.label(
        &view.nodes.items[0].node.properties,
    ).?);
    try testing.expectEqualStrings("borrowed-toolkit", view.tree.?.toolkit_name.?);
    var guard = try target.context.enter();
    defer guard.deinit();
    const answer = outcome catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expect(guard.owner.state == .inactive);
        try testing.expectEqual(@as(usize, 0), guard.owner.registry.nodeCount());
        return false;
    };
    try testing.expect(answer.has_value);
    try testing.expect(guard.owner.state == .active);
    const held = guard.owner.tree().?.stateOf();
    try testing.expectEqualStrings("borrowed-activation", schema.strings.label(
        &held.root().data().properties,
    ).?);
    try testing.expectEqualStrings("borrowed-toolkit", held.info.toolkit_name.?);
    return true;
}

test "scoped native activation rejects each preflight allocation failure without consuming the loan" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    const allocation_failure_bound = 128;
    for (0..allocation_failure_bound) |index| {
        if (try borrowedActivationFailingAt(index)) return;
    }
    return error.AllocationFailureSweepExhausted;
}

const TestRuntimeAuthority = struct {
    runtime: std.Io.Threaded,
    release_count: usize = 0,

    fn release(userdata: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(userdata.?));
        if (self.release_count != 0) @panic("Runtime authority released twice");
        self.release_count += 1;
        self.runtime.deinit();
    }
};

test "create transfers runtime authority only on success across allocation failure" {
    const allocation_failure_bound = 16;
    var failure_count: usize = 0;
    for (0..allocation_failure_bound) |index| {
        var authority: TestRuntimeAuthority = .{
            .runtime = std.Io.Threaded.init(testing.allocator, .{}),
        };
        // Old failure-consuming constructors must fail the assertion without double cleanup.
        defer if (authority.release_count == 0) TestRuntimeAuthority.release(&authority);
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = index });
        const target = WindowsAdapter.create(failing.allocator(), .{
            .io = authority.runtime.io(),
            .platform = testPlatform(),
            .factory = testProviderFactory(),
            .automation = queued_events.testAutomationApi(),
            .hwnd = null,
            .is_window_focused = false,
            .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = null } },
            .runtime_release = .{ .userdata = &authority, .release = TestRuntimeAuthority.release },
        }) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), authority.release_count);
            var caller_lock: std.Io.Mutex = .init;
            caller_lock.lockUncancelable(authority.runtime.io());
            caller_lock.unlock(authority.runtime.io());
            TestRuntimeAuthority.release(&authority);
            try testing.expectEqual(@as(usize, 1), authority.release_count);
            try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            failure_count += 1;
            continue;
        };
        var owner_live = true;
        defer if (owner_live) target.deinit();
        try testing.expectEqual(@as(usize, 0), authority.release_count);
        owner_live = false;
        target.deinit();
        try testing.expectEqual(@as(usize, 1), authority.release_count);
        try testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        try testing.expect(failure_count >= 2);
        return;
    }
    return error.AllocationFailureSweepExhausted;
}

test "Options runtime authority remains alive through the last retained COM client" {
    const native = @import("bindings.zig");
    if (!native.winapi_resolves) return error.SkipZigTest;
    var authority: TestRuntimeAuthority = .{
        .runtime = std.Io.Threaded.init(testing.allocator, .{}),
    };
    defer if (authority.release_count == 0) TestRuntimeAuthority.release(&authority);
    const target = try WindowsAdapter.create(testing.allocator, .{
        .io = authority.runtime.io(),
        .platform = testPlatform(),
        .factory = testProviderFactory(),
        .automation = queued_events.testAutomationApi(),
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = releaseAction, .userdata = null } },
        .runtime_release = .{ .userdata = &authority, .release = TestRuntimeAuthority.release },
    });
    var owner_live = true;
    defer if (owner_live) target.deinit();
    const provider = block: {
        var weak = target.context.weak();
        defer weak.deinit();
        break :block try weak.createNode(null);
    };
    const unknown: *native.IUnknown = @ptrCast(provider);
    var provider_live = true;
    defer if (provider_live) {
        _ = unknown.vtable.Release(unknown);
    };
    owner_live = false;
    target.deinit();
    try testing.expectEqual(@as(usize, 0), authority.release_count);
    var raw = std.mem.zeroes(native.Variant);
    const status = provider.vtable.GetPropertyValue(provider, native.uia.UIA_NamePropertyId, &raw);
    try testing.expectEqual(native.uia.UIA_E_ELEMENTNOTAVAILABLE, @as(u32, @bitCast(status)));
    try testing.expectEqual(@as(usize, 0), authority.release_count);
    provider_live = false;
    try testing.expectEqual(@as(u32, 0), unknown.vtable.Release(unknown));
    try testing.expectEqual(@as(usize, 1), authority.release_count);
}

test "borrowed update selects full only for placeholder and never retries a rejected active delta" {
    if (!@import("bindings.zig").winapi_resolves) return error.SkipZigTest;
    var fixture = Fixture.init(testing.allocator);
    defer fixture.deinit();
    const target = try buildTestAdapter(testing.allocator, &fixture, null, false);
    defer target.deinit();
    var full: schema.TreeUpdate = .{
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "baseline",
            .toolkit_version = "",
        },
        .focus = .{ .value = 1 },
    };
    defer full.deinit(testing.allocator);
    try full.pushNode(testing.allocator, .{ .value = 1 }, schema.Node.init(
        testing.allocator,
        .window,
    ));
    const source_entries = full.nodes.items.ptr;
    var delta: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    defer delta.deinit(testing.allocator);
    try testing.expect(target.updateIfActiveBorrowedChecked(.{
        .delta = &delta,
        .current_full = &full,
    }) == .inactive);
    _ = try target.handleWmGetobject(0, syscalls.objid_client, .{
        .c = .{ .callback = activateWithNothing, .userdata = &fixture },
    });
    // The delta cannot initialize a tree: it has neither root node nor TreeInfo.
    switch (target.updateIfActiveBorrowedChecked(.{
        .delta = &delta,
        .current_full = &full,
    })) {
        .committed => |result| {
            try testing.expect(result.used_full_tree);
            try testing.expect(result.notification_error == null);
            if (result.events) |events| {
                var owned = events;
                if (owned.deinit().first_error) |err| return err;
            }
        },
        else => return error.PlaceholderFullViewRejected,
    }
    try testing.expectEqual(@as(usize, 1), full.nodes.items.len);
    try testing.expect(full.nodes.items.ptr == source_entries);
    try testing.expect(full.nodes.items[0].node.role == .window);
    {
        var guard = try target.context.enter();
        defer guard.deinit();
        try testing.expect(guard.owner.state == .active);
        try testing.expect(guard.owner.tree().?.stateOf().root().data().role == .window);
        try testing.expectEqualStrings("baseline", guard.owner.tree().?.stateOf().info.toolkit_name.?);
    }
    // An individually valid alternate full view makes accidental replay observable.
    full.nodes.items[0].node.role = .button;
    full.tree.?.toolkit_name = "full-replay";
    for (0..3) |_| {
        switch (target.updateIfActiveBorrowedChecked(.{
            .delta = &delta,
            .current_full = &full,
        })) {
            .committed => |result| {
                try testing.expect(!result.used_full_tree);
                try testing.expect(result.notification_error == null);
                if (result.events) |events| {
                    var owned = events;
                    if (owned.deinit().first_error) |err| return err;
                }
            },
            else => return error.ActiveDeltaRejected,
        }
        var guard = try target.context.enter();
        defer guard.deinit();
        try testing.expect(guard.owner.tree().?.stateOf().root().data().role == .window);
        try testing.expectEqualStrings("baseline", guard.owner.tree().?.stateOf().info.toolkit_name.?);
    }
    delta.focus = .{ .value = 999 };
    switch (target.updateIfActiveBorrowedChecked(.{
        .delta = &delta,
        .current_full = &full,
    })) {
        .rejected => |err| try testing.expectEqual(error.FocusNotInTree, err),
        else => return error.InvalidDeltaWasReplacedWithFullView,
    }
    try testing.expectEqual(@as(usize, 0), delta.nodes.items.len);
    try testing.expect(delta.tree == null);
    try testing.expectEqual(@as(u64, 999), delta.focus.value);
    try testing.expectEqual(@as(usize, 1), full.nodes.items.len);
    try testing.expect(full.nodes.items.ptr == source_entries);
    try testing.expect(full.nodes.items[0].node.role == .button);
    try testing.expectEqualStrings("full-replay", full.tree.?.toolkit_name.?);
    var guard = try target.context.enter();
    defer guard.deinit();
    try testing.expect(guard.owner.tree().?.stateOf().root().data().role == .window);
    try testing.expectEqualStrings("baseline", guard.owner.tree().?.stateOf().info.toolkit_name.?);
}
