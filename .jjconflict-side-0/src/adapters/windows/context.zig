//! Shared owner control for Windows providers and text ranges.
//! Providers own weak handles. Each query takes a guarded owner lease.
//! Close rejects new work and waits for every reader and callback pin.
//! The control block and optional runtime authority survive until final weak release.

const std = @import("std");
const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const adapter = @import("adapter.zig");
const bindings = @import("bindings.zig");
const consumer = @import("../../consumer/root.zig");
const elements = @import("elements.zig");
const queued_events = @import("queued_events.zig");
const schema = @import("../../schema/root.zig");
const syscalls = @import("syscalls.zig");
const util = @import("util.zig");

const FullNodeId = consumer.tree_index.FullNodeId;
const WeakRange = consumer.text.range.WeakRange;
const Tree = consumer.tree.Tree;
const TreeState = consumer.tree_state.TreeState;

/// Exact query, automation, allocation, and provider outcomes.
pub const ProviderError = std.mem.Allocator.Error || consumer.tree_state.QueryError ||
    util.AutomationError || error{
    ElementNotAvailable,
    InvalidOperation,
    NotImplemented,
    ProviderLimitExceeded,
    InteriorNul,
};

/// Runs synchronously while old and new node borrows are valid.
pub const PropertyCalculator = *const fn (
    std.mem.Allocator,
    syscalls.Platform,
    *elements.Registry,
    *queued_events.QueuedEvents,
    consumer.node_id.NodeRef,
    consumer.node_id.NodeRef,
) ProviderError!void;

/// Constructors consume weak handles and ranges only when they succeed.
/// Constructors must not query the tree or call application callbacks.
pub const ProviderFactory = struct {
    create_node: *const fn (
        std.mem.Allocator,
        WeakContext,
        ?FullNodeId,
    ) ProviderError!*bindings.IRawElementProviderSimple,
    create_range: *const fn (std.mem.Allocator, WeakContext, WeakRange) ProviderError!*bindings.ITextRangeProvider,
    enqueue_properties: PropertyCalculator,
};

/// Releases runtime storage after the control block's final release.
/// The callback must be safe on the thread that releases the last weak handle.
/// It must not access the disposed control block or destroy the provider allocator:
/// final COM Release still destroys its object allocation after state cleanup.
/// Borrowed runtime storage must instead outlive every weak handle.
pub const RuntimeRelease = struct {
    userdata: ?*anyopaque,
    release: *const fn (?*anyopaque) void,
};

/// A weak handle owns one control reference, never an adapter reference.
/// Copying the handle does not retain it. Use clone before independent ownership.
pub const WeakContext = struct {
    control: *Context,

    /// Retains the control block. Refcount exhaustion is a caller contract failure.
    pub fn clone(self: WeakContext) WeakContext {
        self.control.retainControl();
        return self;
    }

    /// Releases this handle once. Final release may dispose the owned runtime authority.
    pub fn deinit(self: *WeakContext) void {
        const control = self.control;
        self.* = undefined;
        control.releaseControl();
    }

    /// Compares control-block identity, including after close.
    pub fn same(self: WeakContext, other: WeakContext) bool {
        return self.control == other.control;
    }

    /// Borrows the runtime for range-state synchronization, including after close.
    /// An owned weak handle must remain held until the operation finishes.
    pub fn io(self: WeakContext) std.Io {
        return self.control.io;
    }

    /// Borrows the value authority while this weak handle remains owned.
    pub fn automation(self: WeakContext) *const util.AutomationApi {
        return self.control.automation;
    }

    /// Returns the allocator whose lifetime covers this weak handle.
    pub fn allocator(self: WeakContext) std.mem.Allocator {
        return self.control.gpa;
    }

    /// Resolves a live tree and pins its owner while the guard is held.
    pub fn lease(self: WeakContext) ProviderError!ContextLease {
        var guard = try self.control.enter();
        errdefer guard.deinit();
        const held = guard.owner.tree() orelse return error.ElementNotAvailable;
        return .{ .guard = guard, .held = held };
    }

    /// Creates one independently owned COM reference without taking the tree lock.
    pub fn createNode(
        self: WeakContext,
        node_id: ?FullNodeId,
    ) ProviderError!*bindings.IRawElementProviderSimple {
        const control = self.control;
        try control.pin();
        defer control.unpin();
        var owned = self.clone();
        errdefer owned.deinit();
        return control.factory.create_node(control.gpa, owned, node_id);
    }
};

/// One adapter pin plus an optional tree guard and callback pin.
/// The owner is valid until deinit. Do not copy a lease.
pub const OwnerLease = struct {
    control: *Context,
    owner: *adapter.WindowsAdapter,
    locked: bool = true,
    callback: bool = false,
    live: bool = true,

    /// Consumes request and lease. The callback runs under the close barrier, not the tree guard.
    pub fn dispatch(self: *OwnerLease, request: schema.ActionRequest) ProviderError!void {
        const control = self.control;
        self.beginCallback() catch |err| {
            var owned = request;
            owned.deinit(control.gpa);
            self.deinit();
            return err;
        };
        self.releaseTreeGuard();
        defer self.deinit();
        control.action_lock.lockUncancelable(control.io);
        defer control.action_lock.unlock(control.io);
        try self.owner.dispatchPinnedAction(request);
    }

    /// Releases guards and pins. Repeated cleanup of this variable is safe.
    pub fn deinit(self: *OwnerLease) void {
        if (self.live) {
            const control = self.control;
            self.endCallback();
            self.releaseTreeGuard();
            self.* = .{
                .control = undefined,
                .owner = undefined,
                .locked = false,
                .callback = false,
                .live = false,
            };
            control.unpin();
        }
    }

    /// Drops the tree guard while retaining the owner pin.
    pub fn releaseTreeGuard(self: *OwnerLease) void {
        std.debug.assert(self.live);
        if (!self.locked) return;
        self.locked = false;
        self.control.tree_lock.unlock(self.control.io);
    }

    /// Reacquires the tree guard. No old NodeRef or Range borrow may survive suspend.
    pub fn reacquireTree(self: *OwnerLease) void {
        std.debug.assert(self.live);
        std.debug.assert(!self.locked);
        self.control.tree_lock.lockUncancelable(self.control.io);
        self.locked = true;
    }

    /// Enters the close barrier before application code can start.
    pub fn beginCallback(self: *OwnerLease) ProviderError!void {
        std.debug.assert(self.live);
        std.debug.assert(!self.callback);
        const control = self.control;
        control.life_lock.lockUncancelable(control.io);
        defer control.life_lock.unlock(control.io);
        if (control.closed.load(.acquire)) return error.ElementNotAvailable;
        if (control.callbacks == Context.pin_count_max) return error.ProviderLimitExceeded;
        control.callbacks += 1;
        self.callback = true;
    }

    /// Leaves the callback barrier, preserving the owner pin.
    pub fn endCallback(self: *OwnerLease) void {
        if (!self.callback) return;
        const control = self.control;
        control.life_lock.lockUncancelable(control.io);
        defer control.life_lock.unlock(control.io);
        std.debug.assert(control.callbacks > 0);
        control.callbacks -= 1;
        self.callback = false;
        control.drained.broadcast(control.io);
    }
};

/// A tree borrow valid only until deinit or dispatch.
pub const ContextLease = struct {
    guard: OwnerLease,
    held: *Tree,

    /// Releases this tree borrow and owner pin.
    pub fn deinit(self: *ContextLease) void {
        self.guard.deinit();
        self.* = .{ .guard = self.guard, .held = undefined };
    }

    /// Returns the guarded mutable tree. Callers must not retain it.
    pub fn tree(self: *ContextLease) *Tree {
        std.debug.assert(self.guard.live);
        std.debug.assert(self.guard.locked);
        return self.held;
    }

    /// Returns the guarded tree state.
    pub fn state(self: *ContextLease) *const TreeState {
        return self.tree().stateOf();
    }

    /// Tests placeholder state without reacquiring the tree guard.
    pub fn isPlaceholder(self: *ContextLease) bool {
        std.debug.assert(self.guard.locked);
        return self.guard.owner.state == .placeholder;
    }

    /// Returns the nullable boundary window handle.
    pub fn hwnd(self: *ContextLease) boundary.Hwnd {
        std.debug.assert(self.guard.live);
        return self.guard.owner.hwnd;
    }

    /// The allocator must outlive all COM references created from this lease.
    pub fn allocator(self: *ContextLease) std.mem.Allocator {
        return self.guard.control.gpa;
    }

    /// Returns the borrowed automation table with the control-block lifetime.
    pub fn automation(self: *ContextLease) *const util.AutomationApi {
        return self.guard.control.automation;
    }

    /// Returns a new COM reference independent of registry ownership.
    pub fn provider(
        self: *ContextLease,
        node_id: ?FullNodeId,
    ) ProviderError!*bindings.IRawElementProviderSimple {
        std.debug.assert(self.guard.locked);
        const owner = self.guard.owner;
        const slot = if (node_id) |id|
            try owner.registry.slotFor(owner.platform, id)
        else
            try owner.registry.placeholderSlot(owner.platform);
        const raw = slot.interface orelse return error.ElementNotAvailable;
        const result: *bindings.IRawElementProviderSimple = @ptrCast(@alignCast(raw));
        const unknown: *bindings.IUnknown = @ptrCast(result);
        _ = unknown.vtable.AddRef(unknown);
        return result;
    }

    /// Transfers the weak range to the new COM object on success only.
    pub fn range(
        self: *ContextLease,
        value: WeakRange,
    ) ProviderError!*bindings.ITextRangeProvider {
        std.debug.assert(self.guard.live);
        var weak = self.guard.control.weak();
        errdefer weak.deinit();
        return self.guard.control.factory.create_range(self.allocator(), weak, value);
    }

    /// Consumes request and lease, including on error. User code runs without the tree lock.
    pub fn dispatch(self: *ContextLease, request: schema.ActionRequest) ProviderError!void {
        try self.guard.dispatch(request);
    }
};

/// A stable control block. The adapter reference keeps it alive until close.
/// Borrowed io and automation tables must remain valid until final control release.
pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    factory: ProviderFactory,
    automation: *const util.AutomationApi,
    owner: ?*adapter.WindowsAdapter,
    control_refs: std.atomic.Value(u32) = .init(1),
    closed: std.atomic.Value(bool) = .init(false),
    life_lock: std.Io.Mutex = .init,
    tree_lock: std.Io.Mutex = .init,
    action_lock: std.Io.Mutex = .init,
    drained: std.Io.Condition = .init,
    pins: u32 = 0,
    callbacks: u32 = 0,
    runtime_release: ?RuntimeRelease = null,

    /// Bounds simultaneous tree/factory/callback owner pins.
    pub const pin_count_max: u32 = 65536;
    /// COM-style control refcount representation limit.
    pub const control_refs_max: u32 = std.math.maxInt(u32);

    /// Creates the control block without publishing a provider.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        owner: *adapter.WindowsAdapter,
        factory: ProviderFactory,
        automation: *const util.AutomationApi,
    ) std.mem.Allocator.Error!*Context {
        const control = try gpa.create(Context);
        control.* = .{
            .gpa = gpa,
            .io = io,
            .owner = owner,
            .factory = factory,
            .automation = automation,
        };
        return control;
    }

    /// Installs runtime disposal once, before the adapter reaches another thread.
    pub fn setRuntimeRelease(self: *Context, authority: RuntimeRelease) void {
        std.debug.assert(self.runtime_release == null);
        std.debug.assert(!self.closed.load(.acquire));
        self.runtime_release = authority;
    }

    /// Returns one owned weak handle.
    pub fn weak(self: *Context) WeakContext {
        self.retainControl();
        return .{ .control = self };
    }

    /// Pins an active or inactive owner and takes its tree guard.
    pub fn enter(self: *Context) ProviderError!OwnerLease {
        try self.pin();
        self.tree_lock.lockUncancelable(self.io);
        // Close cannot clear owner while this pin remains held.
        return .{ .control = self, .owner = self.owner.? };
    }

    /// Admits an action without requiring an active tree. Consumes the request on every path.
    pub fn dispatch(self: *Context, request: schema.ActionRequest) ProviderError!void {
        var guard = self.enter() catch |err| {
            var owned = request;
            owned.deinit(self.gpa);
            return err;
        };
        defer guard.deinit();
        try guard.dispatch(request);
    }

    /// Refuses new work, waits for admitted work, then detaches the adapter.
    /// Call once, with no owner lease on the calling thread.
    pub fn close(self: *Context) void {
        self.life_lock.lockUncancelable(self.io);
        std.debug.assert(!self.closed.load(.acquire));
        self.closed.store(true, .release);
        self.drained.broadcast(self.io);
        // This condition wait joins admitted pins. It is not a polling loop.
        while (self.pins != 0 or self.callbacks != 0) {
            self.drained.waitUncancelable(self.io, &self.life_lock);
        }
        self.owner = null;
        self.life_lock.unlock(self.io);
        self.releaseControl();
    }

    fn pin(self: *Context) ProviderError!void {
        if (self.closed.load(.acquire)) return error.ElementNotAvailable;
        self.life_lock.lockUncancelable(self.io);
        defer self.life_lock.unlock(self.io);
        if (self.closed.load(.acquire)) return error.ElementNotAvailable;
        if (self.pins == pin_count_max) return error.ProviderLimitExceeded;
        std.debug.assert(self.owner != null);
        self.pins += 1;
    }

    fn unpin(self: *Context) void {
        self.life_lock.lockUncancelable(self.io);
        defer self.life_lock.unlock(self.io);
        std.debug.assert(self.pins > 0);
        self.pins -= 1;
        if (self.pins == 0) self.drained.broadcast(self.io);
    }

    fn retainControl(self: *Context) void {
        const previous = self.control_refs.fetchAdd(1, .monotonic);
        if (previous == control_refs_max) @panic("Windows context reference limit exceeded");
        std.debug.assert(previous > 0);
    }

    fn releaseControl(self: *Context) void {
        const previous = self.control_refs.fetchSub(1, .acq_rel);
        std.debug.assert(previous > 0);
        if (previous != 1) return;
        std.debug.assert(self.closed.load(.acquire));
        std.debug.assert(self.owner == null);
        const gpa = self.gpa;
        const authority = self.runtime_release;
        gpa.destroy(self);
        if (authority) |runtime| runtime.release(runtime.userdata);
    }
};
fn contextTestAction(request: *schema.CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const c_gpa = allocation.allocator();
    schema.cActionRequestDeinit(c_gpa, request);
    c_gpa.destroy(request);
}

test "weak context remains valid after adapter close and rejects new leases" {
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    const owner = try adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = runtime.io(),
        .platform = syscalls.unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = contextTestAction, .userdata = null } },
    });
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    var first = owner.context.weak();
    defer first.deinit();
    var second = first.clone();
    defer second.deinit();
    try std.testing.expect(first.same(second));
    var guard = try owner.context.enter();
    defer guard.deinit();
    try std.testing.expectEqual(owner, guard.owner);
    guard.deinit();
    owner.deinit();
    owner_live = false;
    try std.testing.expectError(error.ElementNotAvailable, first.lease());
    try std.testing.expectError(error.ElementNotAvailable, second.createNode(null));
    const rejected = try std.testing.allocator.dupe(u8, "x\x00y");
    try std.testing.expectError(error.ElementNotAvailable, first.control.dispatch(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .value = rejected },
    }));
}

test "native provider reference survives adapter close without retaining the owner" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    const owner = try adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = runtime.io(),
        .platform = syscalls.unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = contextTestAction, .userdata = null } },
    });
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    var weak = owner.context.weak();
    defer weak.deinit();
    const provider = try weak.createNode(null);
    const unknown: *bindings.IUnknown = @ptrCast(provider);
    defer _ = unknown.vtable.Release(unknown);
    owner.deinit();
    owner_live = false;
    try std.testing.expectError(error.ElementNotAvailable, weak.lease());
    try std.testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try std.testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
}

test "retained clients keep owned runtime alive until final weak release" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    const RuntimeState = struct {
        const Self = @This();
        runtime: std.Io.Threaded,
        releases: *u32,

        fn release(userdata: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const releases = self.releases;
            self.runtime.deinit();
            std.testing.allocator.destroy(self);
            releases.* += 1;
        }
    };
    var releases: u32 = 0;
    const runtime = try std.testing.allocator.create(RuntimeState);
    runtime.* = .{
        .runtime = std.Io.Threaded.init(std.testing.allocator, .{}),
        .releases = &releases,
    };
    var abi = util.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    const owner = adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = runtime.runtime.io(),
        .platform = syscalls.unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = contextTestAction, .userdata = null } },
    }) catch |err| {
        RuntimeState.release(runtime);
        return err;
    };
    owner.context.setRuntimeRelease(.{ .userdata = runtime, .release = RuntimeState.release });
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    var weak = owner.context.weak();
    var weak_live = true;
    defer if (weak_live) weak.deinit();
    const provider = try weak.createNode(null);
    const unknown: *bindings.IUnknown = @ptrCast(provider);
    var provider_live = true;
    defer if (provider_live) {
        _ = unknown.vtable.Release(unknown);
    };
    owner.deinit();
    owner_live = false;
    try std.testing.expectEqual(@as(u32, 0), releases);
    try std.testing.expectError(error.ElementNotAvailable, weak.lease());
    // Range objects can still lock their own state through the retained runtime.
    var state_lock: std.Io.Mutex = .init;
    state_lock.lockUncancelable(weak.io());
    state_lock.unlock(weak.io());
    provider_live = false;
    try std.testing.expectEqual(@as(u32, 0), unknown.vtable.Release(unknown));
    try std.testing.expectEqual(@as(u32, 0), releases);
    weak_live = false;
    weak.deinit();
    try std.testing.expectEqual(@as(u32, 1), releases);
}

test "dispatch drops the tree guard while preserving callback and owner pins" {
    const Seen = struct {
        const Self = @This();
        control: ?*Context = null,
        calls: u32 = 0,
        tree_unlocked: bool = false,
        callback_pinned: bool = false,

        fn action(request: *schema.CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
            defer contextTestAction(request, null);
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            const control = self.control.?;
            self.calls += 1;
            self.tree_unlocked = control.tree_lock.tryLock();
            if (self.tree_unlocked) control.tree_lock.unlock(control.io);
            control.life_lock.lockUncancelable(control.io);
            self.callback_pinned = control.callbacks == 1 and control.pins > 0;
            control.life_lock.unlock(control.io);
        }
    };
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    var seen: Seen = .{};
    const owner = try adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = runtime.io(),
        .platform = syscalls.unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = Seen.action, .userdata = &seen } },
    });
    defer owner.deinit();
    seen.control = owner.context;
    var update: schema.TreeUpdate = .{};
    try update.pushNode(std.testing.allocator, .{ .value = 1 }, schema.Node.init(std.testing.allocator, .window));
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.tree_id = schema.tree_id_root;
    update.focus = .{ .value = 1 };
    owner.state = .{ .active = try Tree.init(std.testing.allocator, update, false) };
    var weak = owner.context.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    try lease.dispatch(.{
        .action = .focus,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = null,
    });
    try std.testing.expectEqual(@as(u32, 1), seen.calls);
    try std.testing.expect(seen.tree_unlocked);
    try std.testing.expect(seen.callback_pinned);
    try std.testing.expect(!lease.guard.live);
    try std.testing.expectEqual(@as(u32, 0), owner.context.pins);
    try std.testing.expectEqual(@as(u32, 0), owner.context.callbacks);
}

test "external close waits for an action callback before releasing borrowed userdata" {
    const Seen = struct {
        const Self = @This();
        weak: WeakContext,
        io: std.Io,
        callback_started: std.Io.Event = .unset,
        callback_release: std.Io.Event = .unset,
        callback_finished: std.Io.Event = .unset,
        close_saw_callback_pin: bool = false,
        dispatch_error: ?ProviderError = null,

        fn action(request: *schema.CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
            defer contextTestAction(request, null);
            const self: *Self = @ptrCast(@alignCast(userdata.?));
            self.callback_started.set(self.io);
            self.callback_release.waitUncancelable(self.io);
            self.callback_finished.set(self.io);
        }

        fn dispatch(self: *Self) void {
            var lease = self.weak.lease() catch |err| {
                self.dispatch_error = err;
                self.callback_started.set(self.io);
                return;
            };
            defer lease.deinit();
            lease.dispatch(.{
                .action = .focus,
                .target_tree = schema.tree_id_root,
                .target_node = .{ .value = 1 },
                .data = null,
            }) catch |err| {
                self.dispatch_error = err;
                self.callback_started.set(self.io);
            };
        }

        fn releaseAfterCloseStarts(self: *Self) void {
            const control = self.weak.control;
            control.life_lock.lockUncancelable(self.io);
            // Close publishes one terminal state. This waits for its notification,
            // not a time estimate or a polling budget.
            while (!control.closed.load(.acquire)) {
                control.drained.waitUncancelable(self.io, &control.life_lock);
            }
            self.close_saw_callback_pin = control.callbacks == 1 and
                control.pins > 0 and !self.callback_finished.isSet();
            control.life_lock.unlock(self.io);
            self.callback_release.set(self.io);
        }
    };
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const io = runtime.io();
    var abi = util.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    const owner = try adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = io,
        .platform = syscalls.unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = Seen.action, .userdata = null } },
    });
    var owner_live = true;
    defer if (owner_live) owner.deinit();
    var update: schema.TreeUpdate = .{};
    try update.pushNode(std.testing.allocator, .{ .value = 1 }, schema.Node.init(std.testing.allocator, .window));
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.tree_id = schema.tree_id_root;
    update.focus = .{ .value = 1 };
    owner.state = .{ .active = try Tree.init(std.testing.allocator, update, false) };
    var seen: Seen = .{ .weak = owner.context.weak(), .io = io };
    defer seen.weak.deinit();
    owner.action_sink.c.userdata = &seen;
    const action_thread = try std.Thread.spawn(.{}, Seen.dispatch, .{&seen});
    var action_live = true;
    defer if (action_live) action_thread.join();
    defer seen.callback_release.set(io);
    seen.callback_started.waitUncancelable(io);
    if (seen.dispatch_error) |err| return err;
    const release_thread = try std.Thread.spawn(.{}, Seen.releaseAfterCloseStarts, .{&seen});
    var release_live = true;
    defer if (release_live) release_thread.join();
    owner.deinit();
    owner_live = false;
    action_thread.join();
    action_live = false;
    release_thread.join();
    release_live = false;
    try std.testing.expect(seen.close_saw_callback_pin);
    try std.testing.expect(seen.callback_finished.isSet());
    try std.testing.expectEqual(@as(?ProviderError, null), seen.dispatch_error);
    try std.testing.expectError(error.ElementNotAvailable, seen.weak.lease());
    try std.testing.expectEqual(@as(?*adapter.WindowsAdapter, null), seen.weak.control.owner);
}

test "owner pin exhaustion preserves exact admission errors and recovers after release" {
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    var abi = util.AutomationTestAbi.init(std.testing.allocator);
    const api = abi.api();
    const owner = try adapter.WindowsAdapter.create(std.testing.allocator, .{
        .io = runtime.io(),
        .platform = syscalls.unavailablePlatform(),
        .factory = adapter.testProviderFactory(),
        .automation = &api,
        .hwnd = null,
        .is_window_focused = false,
        .action_sink = .{ .c = .{ .callback = contextTestAction, .userdata = null } },
    });
    defer owner.deinit();
    var weak = owner.context.weak();
    defer weak.deinit();
    const guards = try std.testing.allocator.alloc(OwnerLease, Context.pin_count_max);
    defer std.testing.allocator.free(guards);
    var count: usize = 0;
    defer for (guards[0..count]) |*guard| guard.deinit();
    for (guards) |*guard| {
        guard.* = try owner.context.enter();
        count += 1;
        guard.releaseTreeGuard();
    }
    try std.testing.expectError(error.ProviderLimitExceeded, owner.context.enter());
    try std.testing.expectError(error.ProviderLimitExceeded, weak.lease());
    try std.testing.expectError(error.ProviderLimitExceeded, weak.createNode(null));
    for (guards[0..count]) |*guard| guard.deinit();
    count = 0;
    var recovered = try owner.context.enter();
    recovered.deinit();
    try std.testing.expectEqual(@as(u32, 0), owner.context.pins);
}
