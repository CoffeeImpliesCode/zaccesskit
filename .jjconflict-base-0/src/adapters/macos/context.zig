//! Callback admission, owner pins, and retained native-node weak anchors.
const std = @import("std");
const schema = @import("../../schema/root.zig");
const consumer = @import("../../consumer/root.zig");
const objc = @import("objc.zig");
const native = @import("native.zig");
const foundation = @import("foundation.zig");
const affine = @import("../../schema/geometry/affine.zig");
const view_mod = @import("view.zig");

/// Failures of native query admission, construction, and initial activation.
pub const NativeError = objc.RuntimeError || consumer.tree_state.QueryError ||
    consumer.tree.UpdateError || std.Io.Writer.Error ||
    error{ WrongThread, Closed, InvalidView, AlreadyAttached, NotAttached, ProviderLimitExceeded };

/// Called once after the final anchor allocation is released.
pub const RuntimeRelease = struct {
    userdata: ?*anyopaque,
    release: *const fn (?*anyopaque) void,
};

/// Constructs +1 native ownership; consumes weak only on success.
pub const NodeFactory = *const fn (
    gpa: std.mem.Allocator,
    weak: WeakContext,
    id: consumer.tree_index.FullNodeId,
) NativeError!objc.Object;

/// Stable weak control block. Allocator and Io outlive final weak release.
/// Close joins pins; deinit drops the initial owner reference after native teardown.
pub const Context = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    owner: ?*native.NativeAdapter,
    factory: NodeFactory,
    gate: std.Io.Mutex = .init,
    drained: std.Io.Condition = .init,
    provider_mutex: std.Io.Mutex = .init,
    references: u32 = 1,
    pins: u32 = 0,
    closing: bool = false,
    runtime_release: ?RuntimeRelease = null,
    /// First unexpected selector failure, protected by `gate`; null means none pending.
    selector_error: ?NativeError = null,

    pub const admission_limit: u32 = 65536;

    /// Allocates the owner anchor without constructing any native provider.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        owner: *native.NativeAdapter,
        factory: NodeFactory,
    ) std.mem.Allocator.Error!*Context {
        const control = try gpa.create(Context);
        control.* = .{ .gpa = gpa, .io = io, .owner = owner, .factory = factory };
        return control;
    }

    /// Returns one owned weak reference.
    pub fn weak(self: *Context) WeakContext {
        return (WeakContext{ .control = self }).clone();
    }

    /// Installs final disposal authority once, before publication.
    pub fn setRuntimeRelease(self: *Context, authority: RuntimeRelease) void {
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        if (self.runtime_release != null) @panic("runtime release already installed");
        if (self.references != 1 or self.pins != 0 or self.closing)
            @panic("runtime release must precede publication");
        self.runtime_release = authority;
    }

    /// Records the first unexpected native selector failure without allocating.
    /// Closed and removed-node sentinels are normal and do not replace a pending cause.
    /// Recording does not disable callbacks; successful retries leave the cause pending.
    pub fn recordSelectorError(self: *Context, err: NativeError) void {
        switch (err) {
            error.Closed, error.NoSuchNode => return,
            else => {},
        }
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        if (self.selector_error == null) self.selector_error = err;
    }

    /// Atomically returns and clears the first unexpected native selector failure.
    /// Null means none pending. Thread-safe and allocation-free; callable after close,
    /// but only while the owner or a retained weak anchor keeps this context alive.
    pub fn takeSelectorError(self: *Context) ?NativeError {
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        const err = self.selector_error;
        self.selector_error = null;
        return err;
    }

    /// Refuses admission, condition-joins all pins, then clears the owner.
    /// Must not run inside a callback admitted by this context.
    pub fn close(self: *Context) void {
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        self.closing = true;
        self.drained.broadcast(self.io);
        while (self.pins != 0) self.drained.waitUncancelable(self.io, &self.gate);
        self.owner = null;
    }

    /// Drops the owner reference once after close and native resource teardown.
    pub fn deinit(self: *Context) void {
        self.gate.lockUncancelable(self.io);
        if (!self.closing or self.owner != null or self.pins != 0)
            @panic("context deinit before joined close");
        self.gate.unlock(self.io);
        var initial: WeakContext = .{ .control = self };
        initial.deinit();
    }

    fn releasePin(self: *Context) void {
        self.gate.lockUncancelable(self.io);
        defer self.gate.unlock(self.io);
        std.debug.assert(self.pins > 0);
        self.pins -= 1;
        if (self.pins == 0) self.drained.broadcast(self.io);
    }
};

/// One owned weak anchor. Copies do not own another reference; use clone.
pub const WeakContext = struct {
    control: *Context,
    /// Null admits view/queue anchors across placeholder replacement.
    /// Scoped node anchors are defunct after the one placeholder-to-full transition.
    provider_epoch: ?u1 = null,

    /// Refcount exhaustion is an explicit contract trap in every optimize mode.
    pub fn clone(self: WeakContext) WeakContext {
        const control = self.control;
        control.gate.lockUncancelable(control.io);
        defer control.gate.unlock(control.io);
        const next = @addWithOverflow(control.references, @as(u32, 1));
        if (next[1] != 0) @panic("native weak reference count exhausted");
        std.debug.assert(control.references > 0);
        control.references = next[0];
        return self;
    }

    /// Releases once; final release destroys the allocation before runtime authority.
    pub fn deinit(self: *WeakContext) void {
        const control = self.control;
        const io = control.io;
        control.gate.lockUncancelable(io);
        std.debug.assert(control.references > 0);
        control.references -= 1;
        if (control.references != 0) {
            control.gate.unlock(io);
            self.* = undefined;
            return;
        }
        std.debug.assert(control.owner == null);
        std.debug.assert(control.pins == 0);
        const gpa = control.gpa;
        const authority = control.runtime_release;
        control.gate.unlock(io);
        gpa.destroy(control);
        self.* = undefined;
        if (authority) |owned| owned.release(owned.userdata);
    }

    /// Pins the owner before taking its state mutex, the actual tree read guard.
    pub fn lease(self: WeakContext) NativeError!ContextLease {
        const control = self.control;
        control.gate.lockUncancelable(control.io);
        if (control.closing) {
            control.gate.unlock(control.io);
            return error.Closed;
        }
        const owner = control.owner orelse {
            control.gate.unlock(control.io);
            return error.Closed;
        };
        if (control.pins == Context.admission_limit) {
            control.gate.unlock(control.io);
            return error.ProviderLimitExceeded;
        }
        control.pins += 1;
        control.gate.unlock(control.io);
        owner.state_mutex.lockUncancelable(control.io);
        var admitted: ContextLease = .{
            .control = control,
            .owner = owner,
            .guard_held = true,
            .provider_epoch = self.provider_epoch,
        };
        if (self.provider_epoch) |epoch| {
            if (epoch != owner.provider_epoch) {
                admitted.deinit();
                return error.Closed;
            }
        }
        return admitted;
    }

    /// Allocator borrowed until this anchor is released.
    pub fn allocator(self: WeakContext) std.mem.Allocator {
        return self.control.gpa;
    }
};

/// Single-owned owner pin and tree guard. Deinit after dispatch is harmless.
/// NodeRef and TreeState borrows end when the guard is released.
pub const ContextLease = struct {
    control: *Context,
    owner: ?*native.NativeAdapter,
    guard_held: bool,
    /// Scope captured at admission; null allows the view lease across placeholder replacement.
    provider_epoch: ?u1 = null,

    /// Releases the tree guard before its owner pin.
    pub fn deinit(self: *ContextLease) void {
        if (self.owner == null) return;
        self.releaseGuard();
        self.owner = null;
        self.control.releasePin();
    }

    /// Releases tree borrows while keeping admission for callbacks or notifications.
    pub fn releaseGuard(self: *ContextLease) void {
        if (!self.guard_held) return;
        self.owner.?.state_mutex.unlock(self.control.io);
        self.guard_held = false;
    }

    /// Reacquires tree access and rejects a replaced scoped provider.
    /// Refusal releases the guard but retains the owner pin until deinit.
    pub fn reacquireGuard(self: *ContextLease) NativeError!void {
        const owner = self.owner orelse return error.Closed;
        if (!self.guard_held) {
            owner.state_mutex.lockUncancelable(self.control.io);
            self.guard_held = true;
        }
        if (self.provider_epoch) |epoch| {
            if (epoch != owner.provider_epoch) {
                self.releaseGuard();
                return error.Closed;
            }
        }
    }

    /// Current committed state or null if absent, consumed, or without a guard.
    pub fn state(self: *ContextLease) ?*const consumer.tree_state.TreeState {
        if (!self.guard_held) return null;
        const owner = self.owner orelse return null;
        const current_tree = if (owner.tree) |*value| value else return null;
        return current_tree.stateOf();
    }

    /// Removed nodes and leases without a guard resolve to null.
    pub fn resolve(
        self: *ContextLease,
        id: consumer.tree_index.FullNodeId,
    ) ?consumer.node_id.NodeRef {
        return consumer.node_id.NodeRef.init(self.state() orelse return null, id);
    }

    /// Allocator for owned requests consumed by dispatch.
    pub fn allocator(self: *ContextLease) std.mem.Allocator {
        return self.control.gpa;
    }

    /// Borrows the retained view while this lease pins its owner.
    pub fn view(self: *ContextLease) ?objc.Object {
        return (self.owner orelse return null).retained_view;
    }

    /// Returns +1 ownership of the view's current window, or null when detached.
    /// SDK calls run outside the tree guard; stale scopes return Closed with pin retained.
    pub fn window(self: *ContextLease) NativeError!?objc.Object {
        const owner = self.owner orelse return error.Closed;
        const host_view = owner.retained_view orelse return null;
        self.releaseGuard();
        const held_window: ?objc.Object = blk: {
            const held_view = objc.retain(host_view);
            defer objc.release(held_view);
            const found = objc.send(?objc.Object, held_view, "window", .{}) orelse
                break :blk null;
            break :blk objc.retain(found);
        };
        self.reacquireGuard() catch |err| {
            if (held_window) |object| objc.release(object);
            return err;
        };
        return held_window;
    }

    /// Returns +1 independent ownership, not the reference owned by the map.
    pub fn provider(
        self: *ContextLease,
        id: consumer.tree_index.FullNodeId,
    ) NativeError!objc.Object {
        const owner = self.owner orelse return error.Closed;
        if (self.resolve(id) == null) return error.Closed;
        self.control.provider_mutex.lockUncancelable(self.control.io);
        defer self.control.provider_mutex.unlock(self.control.io);
        const object = try owner.leaseProvider(
            id,
            self.control.factory,
            .{ .control = self.control },
        );
        return objc.retain(object);
    }
    fn queryState(self: *ContextLease) NativeError!?*const consumer.tree_state.TreeState {
        if (self.owner == null) return error.Closed;
        if (self.owner.?.activation_error) |err| return err;
        return self.state();
    }

    /// Returns +1 NSArray containing the included root or its filtered children.
    /// Frontends request activation first; errors retain the exact activation failure.
    pub fn viewChildren(self: *ContextLease) NativeError!?objc.Object {
        const current = try self.queryState() orelse return null;
        const root = current.root();
        if (try consumer.filter.commonFilter(root) == .include) {
            const object = try self.provider(root.id());
            defer objc.release(object);
            const children_array = try foundation.array(&.{object});
            return children_array;
        }
        var objects: std.ArrayList(objc.Object) = .empty;
        defer {
            for (objects.items) |object| objc.release(object);
            objects.deinit(self.allocator());
        }
        var children = try consumer.node_ref.hierarchy.filteredChildren(root, common_filter);
        var steps: usize = 0;
        const bound = consumer.tree_state.treeWalkStepBound(current.nodes.count());
        while (try children.next()) |child| {
            if (steps == bound) return error.TreeCycle;
            steps += 1;
            const object = try self.provider(child.id());
            errdefer objc.release(object);
            try objects.append(self.allocator(), object);
        }
        const children_array = try foundation.array(objects.items);
        return children_array;
    }

    /// Returns +1 focused provider; absent, excluded, and window-role focus return null.
    pub fn focus(self: *ContextLease) NativeError!?objc.Object {
        const current = try self.queryState() orelse return null;
        const focused = current.focus() orelse return null;
        if (consumer.node_ref.properties.role(focused) == .window) return null;
        if (try consumer.filter.commonFilter(focused) != .include) return null;
        const focused_provider = try self.provider(focused.id());
        return focused_provider;
    }

    /// Converts AppKit screen coordinates to current root space and queries geometry.
    /// Returns +1 provider, falling back to the root when no filtered node contains point.
    pub fn hitTest(self: *ContextLease, point: objc.NSPoint) NativeError!?objc.Object {
        if ((try self.queryState()) == null) return null;
        const host_view = self.view() orelse return null;
        self.releaseGuard();
        const view_point = blk: {
            const held_view = objc.retain(host_view);
            defer objc.release(held_view);
            break :blk try foundation.fromScreenPoint(held_view, point);
        };
        try self.reacquireGuard();
        const current = try self.queryState() orelse return null;
        const root = current.root();
        const root_transform = try consumer.node_ref.geometry.transform(root);
        const root_point = affine.mulPoint(affine.inverse(root_transform), view_point);
        const found = try consumer.node_ref.geometry.nodeAtPoint(
            self.allocator(),
            root,
            root_point,
            common_filter,
        );
        const hit_provider = try self.provider((found orelse root).id());
        return hit_provider;
    }

    /// Runs activation outside the tree guard but under this lease's owner pin.
    pub fn requestActivation(self: *ContextLease) void {
        const owner = self.owner orelse return;
        self.releaseGuard();
        owner.requestActivation();
        self.reacquireGuard() catch return;
    }

    /// Consumes the owned request and lease on every path, keeping a pin through callback.
    /// The callback borrows payload until return and may query or mutate after guard release.
    pub fn dispatch(self: *ContextLease, request: schema.ActionRequest) NativeError!void {
        var owned = request;
        defer self.deinit();
        defer owned.deinit(self.allocator());
        const owner = self.owner orelse return error.Closed;
        const current = self.state() orelse return error.Closed;
        if (current.nodeByTreeLocalId(request.target_node, request.target_tree) == null)
            return error.Closed;
        if (owner.activation_pending) return error.Closed;
        self.releaseGuard();
        owner.dispatchBorrowed(&owned);
    }
};
fn commonFilter(
    _: ?*anyopaque,
    node: consumer.node_id.NodeRef,
) consumer.tree_state.QueryError!consumer.filter.FilterResult {
    return consumer.filter.commonFilter(node);
}

const common_filter: consumer.filter.FilterFn = .{ .context = null, .filter = commonFilter };

// These tests use the real admission and condition join, without native Objective-C objects.
test "native context close refuses admission and joins an admitted owner pin" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = testOwner(gpa, io, null);
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    lease.releaseGuard();
    {
        const closer = try std.Thread.spawn(.{}, Context.close, .{control});
        defer closer.join();
        defer lease.deinit();
        {
            control.gate.lockUncancelable(io);
            defer control.gate.unlock(io);
            while (!control.closing) control.drained.waitUncancelable(io, &control.gate);
            try std.testing.expectEqual(@as(u32, 1), control.pins);
            try std.testing.expect(control.owner != null);
        }
        try std.testing.expectError(error.Closed, weak.lease());
        lease.deinit();
    }
    try std.testing.expect(control.owner == null);
    try std.testing.expectError(error.Closed, weak.lease());
}

test "native context retained weak delays runtime release beyond owner close" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var releases: u32 = 0;
    var owner = testOwner(gpa, io, null);
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    control.setRuntimeRelease(.{ .userdata = &releases, .release = testRuntimeRelease });
    var weak = control.weak();
    var retained = weak.clone();
    control.close();
    control.deinit();
    try std.testing.expectError(error.Closed, retained.lease());
    weak.deinit();
    try std.testing.expectEqual(@as(u32, 0), releases);
    retained.deinit();
    try std.testing.expectEqual(@as(u32, 1), releases);
}

test "native context dispatch consumes rejected owned payload and lease" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = testOwner(gpa, io, null);
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    try std.testing.expectError(error.Closed, lease.dispatch(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .value = try gpa.dupe(u8, "rejected\x00payload") },
    }));
    try std.testing.expectEqual(@as(u32, 0), control.pins);
}

test "native context dispatch drops tree guard but holds pin through callback" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var observed: TestDispatch = .{ .io = io };
    var owner = testOwner(gpa, io, &observed);
    observed.owner = &owner;
    var update: schema.TreeUpdate = .{};
    update.tree = .init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .button));
    owner.tree = try consumer.tree.Tree.init(gpa, update, true);
    defer owner.tree.?.deinit();
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    try lease.dispatch(.{
        .action = .set_value,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .value = try gpa.dupe(u8, "accepted\x00payload") },
    });
    try std.testing.expect(observed.called);
    try std.testing.expect(observed.guard_released);
    try std.testing.expectEqual(@as(u32, 1), observed.callback_pins);
    try std.testing.expectEqual(@as(u32, 0), control.pins);
}

const TestDispatch = struct {
    io: std.Io,
    owner: ?*native.NativeAdapter = null,
    called: bool = false,
    guard_released: bool = false,
    callback_pins: u32 = 0,
};

fn testOwner(gpa: std.mem.Allocator, io: std.Io, userdata: ?*anyopaque) native.NativeAdapter {
    return .{
        .gpa = gpa,
        .io = io,
        .context = undefined,
        .options = .{
            .action_handler = testAction,
            .activation_sink = .{ .native = .{ .callback = testActivation, .userdata = null } },
            .userdata = userdata,
        },
    };
}

fn testAction(userdata: ?*anyopaque, request: *const schema.ActionRequest) void {
    const observed: *TestDispatch = @ptrCast(@alignCast(userdata orelse return));
    const owner = observed.owner.?;
    observed.called = true;
    observed.guard_released = owner.state_mutex.tryLock();
    if (observed.guard_released) owner.state_mutex.unlock(observed.io);
    owner.context.gate.lockUncancelable(observed.io);
    observed.callback_pins = owner.context.pins;
    owner.context.gate.unlock(observed.io);
    std.testing.expectEqualStrings("accepted\x00payload", request.data.?.value) catch
        @panic("dispatch changed the owned payload");
}

fn testActivation(_: ?*anyopaque) void {}
fn testFactory(_: std.mem.Allocator, _: WeakContext, _: consumer.tree_index.FullNodeId) NativeError!objc.Object {
    return error.ProviderLimitExceeded;
}
fn testRuntimeRelease(userdata: ?*anyopaque) void {
    const releases: *u32 = @ptrCast(@alignCast(userdata.?));
    releases.* += 1;
}

test "native context admission limit counts actual retained pins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = testOwner(gpa, io, null);
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    var weak = control.weak();
    defer weak.deinit();
    const leases = try gpa.alloc(ContextLease, Context.admission_limit);
    defer gpa.free(leases);
    var admitted: usize = 0;
    defer for (leases[0..admitted]) |*lease| lease.deinit();
    while (admitted < leases.len) : (admitted += 1) {
        leases[admitted] = try weak.lease();
        leases[admitted].releaseGuard();
    }
    try std.testing.expectError(error.ProviderLimitExceeded, weak.lease());
    leases[admitted - 1].deinit();
    var replacement = try weak.lease();
    replacement.deinit();
}

test "native context creation is failure atomic" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testCreateFailure, .{});
}

fn testCreateFailure(gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    const io = std.testing.io;
    var owner = testOwner(gpa, io, null);
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    control.close();
    control.deinit();
}

test "native context factory rejection preserves weak ownership for current tree queries" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = testOwner(gpa, io, null);
    var update: schema.TreeUpdate = .{};
    update.tree = .init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .generic_container));
    owner.tree = try consumer.tree.Tree.init(gpa, update, true);
    defer owner.tree.?.deinit();
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    defer owner.providers.deinit(gpa);
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    // Focus exposes a generic container; the rejecting factory proves it remains queryable.
    try std.testing.expectError(error.ProviderLimitExceeded, lease.viewChildren());
    try std.testing.expectError(error.ProviderLimitExceeded, lease.focus());
    control.gate.lockUncancelable(io);
    defer control.gate.unlock(io);
    try std.testing.expectEqual(@as(u32, 2), control.references);
}

test "native context activation callback runs outside guard and retains admitted pin" {
    if (!objc.native_supported) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const host_view = objc.send(?objc.Object, view_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(host_view);
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var observed: TestActivation = .{ .io = io };
    var owner = testOwner(gpa, io, null);
    owner.retained_view = host_view;
    observed.owner = &owner;
    owner.options.activation_sink = .{
        .native = .{ .callback = testPinnedActivation, .userdata = &observed },
    };
    defer if (owner.tree) |*current| current.deinit();
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    lease.requestActivation();
    lease.requestActivation();
    try std.testing.expectEqual(@as(u32, 1), observed.calls);
    try std.testing.expect(observed.guard_released);
    try std.testing.expectEqual(@as(u32, 1), observed.callback_pins);
    try std.testing.expect(lease.guard_held);
}

const TestActivation = struct {
    io: std.Io,
    owner: ?*native.NativeAdapter = null,
    calls: u32 = 0,
    guard_released: bool = false,
    callback_pins: u32 = 0,
};

fn testPinnedActivation(userdata: ?*anyopaque) void {
    const observed: *TestActivation = @ptrCast(@alignCast(userdata.?));
    const owner = observed.owner.?;
    observed.calls += 1;
    observed.guard_released = owner.state_mutex.tryLock();
    if (observed.guard_released) owner.state_mutex.unlock(observed.io);
    owner.context.gate.lockUncancelable(observed.io);
    observed.callback_pins = owner.context.pins;
    owner.context.gate.unlock(observed.io);
}

test "native context window focus never constructs a provider" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var owner = testOwner(gpa, io, null);
    var update: schema.TreeUpdate = .{};
    update.tree = .init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    owner.tree = try consumer.tree.Tree.init(gpa, update, true);
    defer owner.tree.?.deinit();
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    defer owner.providers.deinit(gpa);
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    // A rejecting factory proves that window focus never reaches native construction.
    try std.testing.expectEqual(@as(?objc.Object, null), try lease.focus());
}

test "native context scoped placeholder epoch refuses stale admission without leaking pins" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var releases: u32 = 0;
    var owner = testOwner(gpa, io, null);
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    control.setRuntimeRelease(.{ .userdata = &releases, .release = testRuntimeRelease });
    var scoped = control.weak();
    scoped.provider_epoch = 0;
    var retained = scoped.clone();
    try std.testing.expectEqual(@as(?u1, 0), retained.provider_epoch);
    var before = try retained.lease();
    before.releaseGuard();
    owner.state_mutex.lockUncancelable(io);
    owner.provider_epoch = 1;
    owner.state_mutex.unlock(io);
    try std.testing.expectError(error.Closed, before.reacquireGuard());
    try std.testing.expectEqual(@as(u32, 1), control.pins);
    try std.testing.expect(!before.guard_held);
    before.deinit();
    try std.testing.expectError(error.Closed, retained.lease());
    try std.testing.expectEqual(@as(u32, 0), control.pins);
    try std.testing.expect(owner.state_mutex.tryLock());
    owner.state_mutex.unlock(io);
    var unscoped = control.weak();
    try std.testing.expectEqual(@as(?u1, null), unscoped.provider_epoch);
    var unscoped_lease = try unscoped.lease();
    unscoped_lease.releaseGuard();
    try unscoped_lease.reacquireGuard();
    unscoped_lease.deinit();
    var current = unscoped.clone();
    current.provider_epoch = 1;
    var after = try current.lease();
    after.releaseGuard();
    try after.reacquireGuard();
    after.deinit();
    try std.testing.expectError(error.Closed, after.reacquireGuard());
    control.close();
    control.deinit();
    try std.testing.expectEqual(@as(u32, 0), releases);
    scoped.deinit();
    retained.deinit();
    unscoped.deinit();
    try std.testing.expectError(error.Closed, current.lease());
    current.deinit();
    try std.testing.expectEqual(@as(u32, 1), releases);
}

test "native context hit test window callback reenters accessibility children without tree guard" {
    if (!objc.native_supported) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const host_class = try testReentrantViewClass();
    const host_view = objc.send(?objc.Object, host_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(host_view);
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const host_window = objc.send(?objc.Object, window_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(host_window);
    const moved_host_window = objc.send(?objc.Object, window_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(moved_host_window);
    objc.send(void, host_window, "setContentView:", .{host_view});
    var owner = testOwner(gpa, io, null);
    owner.retained_view = host_view;
    owner.retained_window = host_window;
    owner.activation_admitted = true;
    var update: schema.TreeUpdate = .{};
    update.tree = .init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    try update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .button));
    owner.tree = try consumer.tree.Tree.init(gpa, update, true);
    defer owner.tree.?.deinit();
    const control = try Context.create(gpa, io, &owner, testFactory);
    owner.context = control;
    defer control.deinit();
    defer control.close();
    defer owner.providers.deinit(gpa);
    var probe: TestHitTestProbe = .{ .owner = &owner, .io = io };
    if (objc.object_setInstanceVariable(host_view, "_ak_context_probe", &probe) == null)
        return error.ClassRegistrationFailed;
    defer {
        if (objc.object_setInstanceVariable(host_view, "_ak_context_probe", null) == null)
            @panic("native probe ivar vanished");
    }
    var attachment_weak = control.weak();
    var attachment = view_mod.Attachment.attach(
        gpa,
        attachment_weak,
        host_view,
    ) catch |err| {
        attachment_weak.deinit();
        return err;
    };
    defer attachment.detach();
    var weak = control.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    try std.testing.expectError(error.ProviderLimitExceeded, lease.hitTest(.{ .x = 0, .y = 0 }));
    try std.testing.expect(probe.calls > 0);
    try std.testing.expect(probe.guard_released);
    try std.testing.expect(probe.children_queried);
    try std.testing.expectEqual(@as(u32, 1), probe.owner_pins);
    {
        const first_window = (try lease.window()) orelse return error.NativeObjectCreationFailed;
        defer {
            lease.releaseGuard();
            objc.release(first_window);
        }
        try std.testing.expectEqual(host_window, first_window);
    }
    objc.send(void, host_view, "removeFromSuperview", .{});
    objc.send(void, moved_host_window, "setContentView:", .{host_view});
    try lease.reacquireGuard();
    {
        const moved_window = (try lease.window()) orelse return error.NativeObjectCreationFailed;
        defer {
            lease.releaseGuard();
            objc.release(moved_window);
        }
        try std.testing.expectEqual(moved_host_window, moved_window);
        try std.testing.expectEqual(host_window, owner.retained_window.?);
    }
    try lease.reacquireGuard();
    try std.testing.expect(probe.guard_released);
    try std.testing.expectEqual(@as(u32, 1), probe.owner_pins);
    try std.testing.expect(lease.guard_held);
}

const TestHitTestProbe = struct {
    owner: *native.NativeAdapter,
    io: std.Io,
    calls: u32 = 0,
    guard_released: bool = false,
    children_queried: bool = false,
    owner_pins: u32 = 0,
};

fn testReentrantViewClass() NativeError!objc.Class {
    const name = "AKContextHitTestReentrantView";
    if (objc.getClass(name)) |existing| return existing;
    const base = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const class = objc.objc_allocateClassPair(base, name, 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    if (objc.class_addIvar(
        class,
        "_ak_context_probe",
        @sizeOf(?*anyopaque),
        @intCast(@ctz(@as(usize, @alignOf(?*anyopaque)))),
        "^v",
    ) == 0) return error.ClassRegistrationFailed;
    if (objc.class_addMethod(
        class,
        objc.sel("window"),
        @ptrCast(&testReentrantViewWindow),
        "@@:",
    ) == 0) return error.MethodRegistrationFailed;
    objc.objc_registerClassPair(class);
    return class;
}

fn testReentrantViewWindow(receiver: objc.Object, _: objc.Sel) callconv(.c) ?objc.Object {
    var pointer: ?*anyopaque = null;
    if (objc.object_getInstanceVariable(receiver, "_ak_context_probe", &pointer) == null)
        @panic("native probe ivar vanished");
    if (pointer) |raw| {
        const probe: *TestHitTestProbe = @ptrCast(@alignCast(raw));
        probe.calls += 1;
        probe.guard_released = probe.owner.state_mutex.tryLock();
        if (probe.guard_released) {
            probe.owner.state_mutex.unlock(probe.io);
            probe.owner.context.gate.lockUncancelable(probe.io);
            probe.owner_pins = probe.owner.context.pins;
            probe.owner.context.gate.unlock(probe.io);
            _ = objc.send(?objc.Object, receiver, "accessibilityChildren", .{});
            probe.children_queried = true;
        }
    }
    const base = objc.getClass("NSView") orelse @panic("NSView unavailable");
    return objc.sendSuper(?objc.Object, receiver, base, "window", .{});
}

test "native context armed runtime authority disposes actual Io after retained anchors" {
    const gpa = std.testing.allocator;
    const threaded = try gpa.create(std.Io.Threaded);
    threaded.* = std.Io.Threaded.init(gpa, .{});
    var authority: TestOwnedRuntime = .{ .gpa = gpa, .threaded = threaded };
    defer if (authority.threaded != null) testOwnedRuntimeRelease(&authority);
    var owner = testOwner(gpa, threaded.io(), null);
    const control = try Context.create(gpa, threaded.io(), &owner, testFactory);
    owner.context = control;
    control.setRuntimeRelease(.{ .userdata = &authority, .release = testOwnedRuntimeRelease });
    var associated = control.weak();
    var retained = associated.clone();
    control.close();
    control.deinit();
    associated.deinit();
    try std.testing.expectEqual(@as(u32, 0), authority.releases);
    retained.deinit();
    try std.testing.expectEqual(@as(u32, 1), authority.releases);
    try std.testing.expect(authority.threaded == null);
    // Runtime disposal does not retire the independent allocator of native objects.
    const after_release = try gpa.create(u8);
    gpa.destroy(after_release);
}

const TestOwnedRuntime = struct {
    gpa: std.mem.Allocator,
    threaded: ?*std.Io.Threaded,
    releases: u32 = 0,
};

fn testOwnedRuntimeRelease(userdata: ?*anyopaque) void {
    const authority: *TestOwnedRuntime = @ptrCast(@alignCast(userdata.?));
    const threaded = authority.threaded orelse @panic("runtime authority released twice");
    threaded.deinit();
    authority.gpa.destroy(threaded);
    authority.threaded = null;
    authority.releases += 1;
}
