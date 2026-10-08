//! Native AppKit adapter ownership, publication, and lifecycle.

const std = @import("std");
const builtin = @import("builtin");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const boundary = @import("../../capi/boundary.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const context_mod = @import("context.zig");
const platform_node = @import("platform_node.zig");
const view_mod = @import("view.zig");
const events = @import("events.zig");
const native_events = @import("native_events.zig");

pub const NativeError = context_mod.NativeError;
pub const RuntimeRelease = context_mod.RuntimeRelease;
pub const CreateError = NativeError;
pub const AttachError = NativeError;
pub const CloseError = NotificationError || error{ NativeUnsupported, WrongThread, Closed };
pub const UpdateError = consumer.tree.UpdateError ||
    error{ NativeUnsupported, WrongThread, Closed, NotAttached, ProviderLimitExceeded };
pub const NotificationError = native_events.NotificationError;
pub const NativeNotifications = native_events.NativeNotifications;
const FullNodeId = consumer.tree_index.FullNodeId;
const provider_limit = 65536;
const ProviderMap = std.array_hash_map.Auto(FullNodeId, objc.Object);

/// Native activation requests a future full frame; C activation transfers an initial update.
pub const ActivationSink = union(enum) {
    native: struct {
        callback: *const fn (?*anyopaque) void,
        userdata: ?*anyopaque,
    },
    c: struct {
        callback: ?boundary.ActivationHandler,
        userdata: ?*anyopaque,
    },
};

/// Callbacks borrow userdata until close joins them and run on native query threads.
/// Actions borrow payloads until return and may read or update the tree synchronously.
/// Native activation callbacks may query, but only request later full publication.
/// C activation callbacks transfer the initial update synchronously. Neither may mutate inline.
/// Neither callback may close or deinit its adapter.
pub const Options = struct {
    action_handler: *const fn (?*anyopaque, *const schema.ActionRequest) void,
    activation_sink: ActivationSink,
    userdata: ?*anyopaque = null,
    /// Transfers only on successful create; final weak disposal releases the adopted authority.
    runtime_release: ?RuntimeRelease = null,
};

/// A live NSView, or a live NSWindow whose contentView is attached.
pub const AttachTarget = union(enum) { view: objc.Object, window: objc.Object };

/// Same-frame full loan; get must not allocate, recompute, or call native APIs.
pub const FullTreeSupplier = struct {
    context: ?*anyopaque,
    get: *const fn (?*anyopaque) *const schema.TreeUpdate,
};

/// Rejection preserves the baseline; committed survives notification failure.
pub const UpdateOutcome = union(enum) {
    inactive,
    rejected: UpdateError,
    committed: struct {
        notification_error: ?NotificationError,
        /// True only when this commit selected the synchronous current-full loan.
        used_full_tree: bool,
    },
};

/// A non-null queue is single-owned and must be raised or dropped exactly once.
pub const PreparedUpdateOutcome = union(enum) {
    inactive,
    rejected: UpdateError,
    committed: struct {
        events: ?*NativeNotifications,
        notification_error: ?NotificationError,
        used_full_tree: bool,
    },
};

/// A single synchronized native phase/cache observation. Contains no borrowed tree pointers.
pub const DebugSnapshot = struct {
    state: enum { inactive, placeholder, active, closed },
    provider_count: usize,
};

/// Stable owner; gpa outlives native objects and remains valid after the Io disposal hook.
/// Main-thread mutations share a guard with query loans. Do not copy the owner.
pub const NativeAdapter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    context: *context_mod.Context,
    options: Options,
    tree: ?consumer.tree.Tree = null,
    metadata: MetadataOwners = .{},
    retained_view: ?objc.Object = null,
    retained_window: ?objc.Object = null,
    attachment: ?view_mod.Attachment = null,
    providers: ProviderMap = .empty,
    state_mutex: std.Io.Mutex = .init,
    activation_mutex: std.Io.Mutex = .init,
    activation_condition: std.Io.Condition = .init,
    activation_in_flight: bool = false,
    activation_admitted: bool = false,
    activation_pending: bool = false,
    /// Exactly one placeholder-to-full provider replacement; view weak anchors are unscoped.
    provider_epoch: u1 = 0,
    activation_error: ?UpdateError = null,
    focused: bool = false,
    closed: bool = false,

    /// Failure leaves runtime authority with the caller; success adopts it on final return.
    pub fn create(gpa: std.mem.Allocator, io: std.Io, options: Options) CreateError!*NativeAdapter {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        const owner = try gpa.create(NativeAdapter);
        errdefer gpa.destroy(owner);
        owner.* = .{ .gpa = gpa, .io = io, .context = undefined, .options = options };
        owner.context = try context_mod.Context.create(gpa, io, owner, platform_node.create);
        // No fallible work follows this success-only ownership transfer.
        if (options.runtime_release) |authority| owner.context.setRuntimeRelease(authority);
        return owner;
    }

    /// Retains the host and patches its four selectors; errors undo per-instance changes.
    pub fn attach(self: *NativeAdapter, target: AttachTarget, focused: bool) AttachError!void {
        try self.attachImpl(target, focused, true);
    }

    /// Retains a C host whose queries are manually forwarded, without changing its class.
    pub fn attachUnsubclassed(
        self: *NativeAdapter,
        target: AttachTarget,
        focused: bool,
    ) AttachError!void {
        try self.attachImpl(target, focused, false);
    }

    fn attachImpl(
        self: *NativeAdapter,
        target: AttachTarget,
        focused: bool,
        subclassing: bool,
    ) AttachError!void {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.closed) return error.Closed;
        if (self.retained_view != null) return error.AlreadyAttached;
        const host_view = switch (target) {
            .view => |object| object,
            .window => |object| blk: {
                const window_type = objc.getClass("NSWindow") orelse
                    return error.ObjectiveCUnavailable;
                if (objc.send(objc.BOOL, object, "isKindOfClass:", .{window_type}) == 0) {
                    return error.InvalidView;
                }
                break :blk objc.send(?objc.Object, object, "contentView", .{}) orelse
                    return error.InvalidView;
            },
        };
        const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
        if (objc.send(objc.BOOL, host_view, "isKindOfClass:", .{view_class}) == 0) {
            return error.InvalidView;
        }
        const host_window = switch (target) {
            .window => |object| @as(?objc.Object, object),
            .view => objc.send(?objc.Object, host_view, "window", .{}),
        };
        const held_view = objc.retain(host_view);
        errdefer objc.release(held_view);
        const held_window = if (host_window) |object| objc.retain(object) else null;
        errdefer if (held_window) |object| objc.release(object);
        var attached: ?view_mod.Attachment = null;
        if (subclassing) {
            var weak = self.context.weak();
            attached = view_mod.Attachment.attach(self.gpa, weak, host_view) catch |err| {
                weak.deinit();
                return err;
            };
        }
        self.retained_view = held_view;
        self.retained_window = held_window;
        self.attachment = attached;
        self.focused = focused;
    }

    /// Binds the base C source before its first query; admission freezes that source.
    pub fn setCActivationHandler(
        self: *NativeAdapter,
        callback: boundary.ActivationHandler,
        userdata: ?*anyopaque,
    ) void {
        self.activation_mutex.lockUncancelable(self.io);
        defer self.activation_mutex.unlock(self.io);
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.activation_admitted or self.closed) return;
        switch (self.options.activation_sink) {
            .c => self.options.activation_sink = .{ .c = .{
                .callback = callback,
                .userdata = userdata,
            } },
            .native => @panic("C activation callback on native adapter"),
        }
    }

    /// True after activation admission, including a placeholder awaiting full publication.
    pub fn isActive(self: *const NativeAdapter) bool {
        const mutable = @constCast(self);
        mutable.state_mutex.lockUncancelable(self.io);
        defer mutable.state_mutex.unlock(self.io);
        return self.activation_admitted and !self.closed;
    }

    /// Observes phase and actual provider ownership together without native calls or allocation.
    /// Valid until deinit, including after close. The returned value owns no resources.
    pub fn debugSnapshot(self: *const NativeAdapter) DebugSnapshot {
        const mutable = @constCast(self);
        mutable.state_mutex.lockUncancelable(self.io);
        defer mutable.state_mutex.unlock(self.io);
        self.context.provider_mutex.lockUncancelable(self.io);
        defer self.context.provider_mutex.unlock(self.io);
        return .{
            .state = if (self.closed)
                .closed
            else if (!self.activation_admitted)
                .inactive
            else if (self.activation_pending)
                .placeholder
            else
                .active,
            .provider_count = self.providers.count(),
        };
    }

    /// Returns a +1 actual NSArray; the caller releases or autorelease-returns it.
    pub fn viewChildrenChecked(self: *NativeAdapter) NativeError!?objc.Object {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        var weak = self.context.weak();
        defer weak.deinit();
        var lease = try weak.lease();
        defer lease.deinit();
        lease.requestActivation();
        return lease.viewChildren();
    }

    /// Returns a +1 focused exposed element, or null.
    pub fn focusChecked(self: *NativeAdapter) NativeError!?objc.Object {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        var weak = self.context.weak();
        defer weak.deinit();
        var lease = try weak.lease();
        defer lease.deinit();
        lease.requestActivation();
        return lease.focus();
    }

    /// Returns a +1 actual element at a screen point, falling back to the root.
    pub fn hitTestChecked(self: *NativeAdapter, point: objc.NSPoint) NativeError!?objc.Object {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        var weak = self.context.weak();
        defer weak.deinit();
        var lease = try weak.lease();
        defer lease.deinit();
        lease.requestActivation();
        return lease.hitTest(point);
    }

    /// Borrowed action callback invoked only while the caller holds an admission pin.
    pub fn dispatchBorrowed(self: *NativeAdapter, request: *const schema.ActionRequest) void {
        self.options.action_handler(self.options.userdata, request);
    }

    /// Borrows weak and returns a borrowed map object; consumes only the factory clone.
    pub fn leaseProvider(
        self: *NativeAdapter,
        id: FullNodeId,
        factory: context_mod.NodeFactory,
        weak: context_mod.WeakContext,
    ) NativeError!objc.Object {
        if (self.providers.get(id)) |object| return object;
        if (self.providers.count() == provider_limit) return error.ProviderLimitExceeded;
        try self.providers.ensureUnusedCapacity(self.gpa, 1);
        var node_weak = weak.clone();
        node_weak.provider_epoch = self.provider_epoch;
        const object = factory(self.gpa, node_weak, id) catch |err| {
            node_weak.deinit();
            return err;
        };
        self.providers.putAssumeCapacity(id, object);
        return object;
    }

    /// Refuses new calls, joins admitted callbacks, then makes retained elements defunct.
    /// Posts destroyed notifications outside all guards. A posting error still closes
    /// the owner completely; deinit remains required to release its final anchor.
    pub fn close(self: *NativeAdapter) CloseError!void {
        if (builtin.os.tag != .macos) return error.NativeUnsupported;
        if (!foundation.isMainThread()) return error.WrongThread;
        if (self.closed) return error.Closed;
        self.context.close();
        self.state_mutex.lockUncancelable(self.io);
        // The owner anchor keeps Io authority alive until deinit.
        self.closed = true;
        var detached_attachment = self.attachment;
        self.attachment = null;
        self.context.provider_mutex.lockUncancelable(self.io);
        if (self.providers.count() > provider_limit) @panic("native provider bound violated");
        var destroyed = self.providers;
        self.providers = .empty;
        self.context.provider_mutex.unlock(self.io);
        if (self.tree) |*tree| tree.deinit();
        self.tree = null;
        self.metadata.deinit(self.gpa);
        const detached_view = self.retained_view;
        const detached_window = self.retained_window;
        self.retained_view = null;
        self.retained_window = null;
        self.state_mutex.unlock(self.io);
        if (detached_attachment) |*attached| attached.detach();
        if (detached_view) |object| objc.release(object);
        if (detached_window) |object| objc.release(object);
        defer {
            for (destroyed.values()) |object| objc.release(object);
            destroyed.deinit(self.gpa);
        }
        var pool = try objc.AutoreleasePool.init();
        defer pool.deinit();
        var failure: ?CloseError = null;
        while (destroyed.count() != 0) {
            const key = destroyed.keys()[destroyed.count() - 1];
            const object = destroyed.fetchSwapRemove(key).?.value;
            defer objc.release(object);
            foundation.post(object, events.notificationFor(.node_destroyed).?) catch |err| {
                if (failure == null) failure = err;
            };
        }
        if (failure) |err| return err;
    }

    /// After close commits, including on posting failure, frees the stable owner once.
    pub fn deinit(self: *NativeAdapter) void {
        if (!self.closed) @panic("native adapter must be closed before deinit");
        if (!foundation.isMainThread()) @panic("native adapter deinit on wrong thread");
        const gpa = self.gpa;
        const control = self.context;
        gpa.destroy(self);
        control.deinit();
    }

    /// Requests activation once with the read guard released and an owner pin held by the lease.
    pub fn requestActivation(self: *NativeAdapter) void {
        objc.requireNative() catch return;
        if (!foundation.isMainThread()) return;
        self.activation_mutex.lockUncancelable(self.io);
        self.state_mutex.lockUncancelable(self.io);
        if (self.closed or self.activation_admitted or self.retained_view == null) {
            self.state_mutex.unlock(self.io);
            self.activation_mutex.unlock(self.io);
            return;
        }
        const sink = self.options.activation_sink;
        if (sink == .c and sink.c.callback == null) {
            self.state_mutex.unlock(self.io);
            self.activation_mutex.unlock(self.io);
            return;
        }
        self.activation_admitted = true;
        self.activation_pending = true;
        self.activation_in_flight = true;
        self.state_mutex.unlock(self.io);
        self.activation_mutex.unlock(self.io);
        defer {
            self.activation_mutex.lockUncancelable(self.io);
            self.activation_in_flight = false;
            self.activation_condition.broadcast(self.io);
            self.activation_mutex.unlock(self.io);
        }
        switch (sink) {
            .native => |source| {
                self.installPlaceholder();
                source.callback(source.userdata);
            },
            .c => |source| {
                const handle = source.callback.?(source.userdata);
                if (handle) |owned_handle| {
                    defer c_tree_update.discard(owned_handle);
                    const owned: *c_tree_update.accesskit_tree_update =
                        @ptrCast(@alignCast(owned_handle));
                    self.state_mutex.lockUncancelable(self.io);
                    defer self.state_mutex.unlock(self.io);
                    const loan = self.metadata.prepare(self.gpa, &owned.update) catch |err| {
                        self.activation_error = err;
                        return;
                    };
                    defer self.metadata.reap(self.gpa, if (self.tree) |*tree| tree else null);
                    self.tree = consumer.tree.Tree.initBorrowed(
                        self.gpa,
                        &loan,
                        self.focused,
                    ) catch |err| {
                        self.activation_error = err;
                        return;
                    };
                    self.activation_pending = false;
                } else {
                    self.installPlaceholder();
                }
            },
        }
    }

    fn installPlaceholder(self: *NativeAdapter) void {
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        var entry = [_]schema.NodeEntry{.{
            .node_id = .{ .value = 0 },
            .node = schema.Node.init(self.gpa, .window),
        }};
        defer entry[0].node.deinit();
        const placeholder: schema.TreeUpdate = .{
            .nodes = .{ .items = &entry, .capacity = 0 },
            .tree = schema.TreeInfo.init(.{ .value = 0 }),
            .focus = .{ .value = 0 },
        };
        self.tree = consumer.tree.Tree.initBorrowed(self.gpa, &placeholder, false) catch |err| {
            self.activation_error = err;
            return;
        };
    }

    /// Publishes a borrowed delta and synchronously posts outside every tree guard.
    pub fn updateIfActiveBorrowedChecked(
        self: *NativeAdapter,
        delta: *const schema.TreeUpdate,
        current_full: FullTreeSupplier,
    ) UpdateOutcome {
        if (builtin.os.tag != .macos) return .{ .rejected = error.NativeUnsupported };
        if (!foundation.isMainThread()) return .{ .rejected = error.WrongThread };
        var weak = self.context.weak();
        defer weak.deinit();
        var pin = weak.lease() catch |err| return .{ .rejected = updateAdmissionError(err) };
        defer pin.deinit();
        pin.releaseGuard();
        return raisePrepared(self.prepareUpdateWithPin(delta, current_full, &pin));
    }

    /// Prepares but never posts; inactive never invokes the full supplier or takes input.
    pub fn prepareUpdateIfActiveBorrowedChecked(
        self: *NativeAdapter,
        delta: *const schema.TreeUpdate,
        current_full: FullTreeSupplier,
    ) PreparedUpdateOutcome {
        if (builtin.os.tag != .macos) return .{ .rejected = error.NativeUnsupported };
        if (!foundation.isMainThread()) return .{ .rejected = error.WrongThread };
        var weak = self.context.weak();
        defer weak.deinit();
        var pin = weak.lease() catch |err| return .{ .rejected = updateAdmissionError(err) };
        defer pin.deinit();
        return self.prepareUpdateWithPin(delta, current_full, &pin);
    }

    fn prepareUpdateWithPin(
        self: *NativeAdapter,
        delta: *const schema.TreeUpdate,
        current_full: FullTreeSupplier,
        pin: *context_mod.ContextLease,
    ) PreparedUpdateOutcome {
        pin.reacquireGuard() catch |err| return .{ .rejected = updateAdmissionError(err) };
        if (self.closed) return .{ .rejected = error.Closed };
        if (self.retained_view == null) return .{ .rejected = error.NotAttached };
        if (!self.activation_admitted) return .inactive;
        var targets = self.captureCurrentTargets(pin);
        defer releaseTargets(targets);
        var discarded: ?*NativeNotifications = null;
        defer if (discarded) |queue| queue.deinit();
        self.activation_mutex.lockUncancelable(self.io);
        defer self.activation_mutex.unlock(self.io);
        while (self.activation_in_flight) {
            self.activation_condition.waitUncancelable(self.io, &self.activation_mutex);
        }
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.closed) return .{ .rejected = error.Closed };
        if (self.retained_view == null) return .{ .rejected = error.NotAttached };
        if (!self.activation_admitted) return .inactive;
        const used_full_tree = self.activation_pending;
        const update = if (used_full_tree) current_full.get(current_full.context) else delta;
        const loan = self.metadata.prepare(self.gpa, update) catch |err| {
            return .{ .rejected = err };
        };
        defer self.metadata.reap(self.gpa, if (self.tree) |*tree| tree else null);
        var generator = events.EventGenerator.init(self.gpa);
        defer generator.deinit();
        var detached: ProviderMap = .empty;
        defer {
            for (detached.values()) |object| objc.release(object);
            detached.deinit(self.gpa);
        }
        if (used_full_tree) {
            const next = consumer.tree.Tree.initBorrowed(self.gpa, &loan, self.focused) catch |err| {
                return .{ .rejected = err };
            };
            if (self.tree) |*old| old.deinit();
            self.tree = next;
            self.activation_pending = false;
            self.activation_error = null;
            if (self.provider_epoch != 0) @panic("native placeholder provider epoch advanced twice");
            self.provider_epoch = 1;
            self.context.provider_mutex.lockUncancelable(self.io);
            detached = self.providers;
            self.providers = .empty;
            self.context.provider_mutex.unlock(self.io);
            for (detached.keys()) |id| {
                generator.events.append(self.gpa, .{ .node_destroyed = id }) catch |err| {
                    return .{ .committed = .{
                        .events = null,
                        .notification_error = err,
                        .used_full_tree = used_full_tree,
                    } };
                };
            }
            if (self.tree.?.state.focus()) |node| {
                generator.events.append(self.gpa, .{ .generic = .{
                    .node_id = node.id(),
                    .notification = events.notificationFor(.focus_moved).?,
                } }) catch |err| {
                    return .{ .committed = .{
                        .events = null,
                        .notification_error = err,
                        .used_full_tree = used_full_tree,
                    } };
                };
            }
        } else {
            const handler = events.slotsOf(&generator);
            self.tree.?.updateBorrowedAndProcessChanges(&loan, &handler) catch |err| {
                return .{ .rejected = err };
            };
        }
        return self.prepareGenerated(
            &generator,
            used_full_tree,
            if (used_full_tree) &detached else null,
            &targets,
            &discarded,
        );
    }

    /// Publishes host focus and synchronously posts with an admission pin until return.
    pub fn updateViewFocusState(self: *NativeAdapter, focused: bool) UpdateOutcome {
        if (builtin.os.tag != .macos) return .{ .rejected = error.NativeUnsupported };
        if (!foundation.isMainThread()) return .{ .rejected = error.WrongThread };
        var weak = self.context.weak();
        defer weak.deinit();
        var pin = weak.lease() catch |err| return .{ .rejected = updateAdmissionError(err) };
        defer pin.deinit();
        pin.releaseGuard();
        return raisePrepared(self.prepareFocusWithPin(focused, &pin));
    }

    /// Prepares host focus notifications; committed focus survives every queue failure.
    pub fn prepareViewFocusState(self: *NativeAdapter, focused: bool) PreparedUpdateOutcome {
        if (builtin.os.tag != .macos) return .{ .rejected = error.NativeUnsupported };
        if (!foundation.isMainThread()) return .{ .rejected = error.WrongThread };
        var weak = self.context.weak();
        defer weak.deinit();
        var pin = weak.lease() catch |err| return .{ .rejected = updateAdmissionError(err) };
        defer pin.deinit();
        return self.prepareFocusWithPin(focused, &pin);
    }

    fn prepareFocusWithPin(self: *NativeAdapter, focused: bool, pin: *context_mod.ContextLease) PreparedUpdateOutcome {
        pin.reacquireGuard() catch |err| return .{ .rejected = updateAdmissionError(err) };
        if (self.closed) return .{ .rejected = error.Closed };
        if (self.retained_view == null) return .{ .rejected = error.NotAttached };
        if (!self.activation_admitted or self.activation_pending) {
            self.focused = focused;
            return .inactive;
        }
        var targets = self.captureCurrentTargets(pin);
        defer releaseTargets(targets);
        var discarded: ?*NativeNotifications = null;
        defer if (discarded) |queue| queue.deinit();
        self.activation_mutex.lockUncancelable(self.io);
        defer self.activation_mutex.unlock(self.io);
        while (self.activation_in_flight) {
            self.activation_condition.waitUncancelable(self.io, &self.activation_mutex);
        }
        self.state_mutex.lockUncancelable(self.io);
        defer self.state_mutex.unlock(self.io);
        if (self.closed) return .{ .rejected = error.Closed };
        if (self.retained_view == null) return .{ .rejected = error.NotAttached };
        if (!self.activation_admitted or self.activation_pending) {
            self.focused = focused;
            return .inactive;
        }
        var generator = events.EventGenerator.init(self.gpa);
        defer generator.deinit();
        const handler = events.slotsOf(&generator);
        self.tree.?.updateHostFocusStateAndProcessChanges(focused, &handler) catch |err| {
            return .{ .rejected = err };
        };
        self.focused = focused;
        return self.prepareGenerated(&generator, false, null, &targets, &discarded);
    }

    /// The pin keeps the owner/view alive; every foreign host call occurs without a tree guard.
    fn captureCurrentTargets(self: *NativeAdapter, pin: *context_mod.ContextLease) native_events.Targets {
        const view = self.retained_view.?;
        pin.releaseGuard();
        const held_view = objc.retain(view);
        const window = objc.send(?objc.Object, held_view, "window", .{});
        return .{ .view = held_view, .window = if (window) |object| objc.retain(object) else null };
    }

    fn releaseTargets(targets: native_events.Targets) void {
        if (targets.view) |object| objc.release(object);
        if (targets.window) |object| objc.release(object);
    }

    fn prepareGenerated(
        self: *NativeAdapter,
        generator: *events.EventGenerator,
        used_full_tree: bool,
        detached: ?*ProviderMap,
        targets: *native_events.Targets,
        discarded: *?*NativeNotifications,
    ) PreparedUpdateOutcome {
        var committed = self.prepareGeneratedQueue(
            generator,
            used_full_tree,
            detached,
            targets,
            discarded,
        );
        self.sweepDefunctProviders() catch |err| {
            committed.notification_error = err;
        };
        return .{ .committed = committed };
    }

    fn prepareGeneratedQueue(
        self: *NativeAdapter,
        generator: *events.EventGenerator,
        used_full_tree: bool,
        detached: ?*ProviderMap,
        targets: *native_events.Targets,
        discarded: *?*NativeNotifications,
    ) @FieldType(PreparedUpdateOutcome, "committed") {
        if (generator.failure) |err| {
            return .{
                .events = null,
                .notification_error = err,
                .used_full_tree = used_full_tree,
            };
        }
        if (generator.events.items.len == 0) {
            return .{
                .events = null,
                .notification_error = null,
                .used_full_tree = used_full_tree,
            };
        }
        var weak = self.context.weak();
        defer weak.deinit();
        var source: NotificationSource = .{ .owner = self, .detached = detached };
        const queue = NativeNotifications.create(self.gpa, weak, targets.*) catch |err| {
            retireDestroyedEvents(&source, generator.events.items);
            return .{
                .events = null,
                .notification_error = err,
                .used_full_tree = used_full_tree,
            };
        };
        targets.* = .{ .view = null, .window = null };
        queue.prepare(generator.events.items, .{
            .context = &source,
            .provider = notificationProvider,
            .takeRemoved = notificationTakeRemoved,
        }) catch |err| {
            retireDestroyedEvents(&source, generator.events.items);
            discarded.* = queue;
            return .{
                .events = null,
                .notification_error = err,
                .used_full_tree = used_full_tree,
            };
        };
        return .{
            .events = queue,
            .notification_error = null,
            .used_full_tree = used_full_tree,
        };
    }

    fn retireDestroyedEvents(source: *NotificationSource, batch: []const events.QueuedEvent) void {
        for (batch) |event| switch (event) {
            .node_destroyed => |id| {
                if (notificationTakeRemoved(source, id)) |object| objc.release(object);
            },
            else => {},
        };
    }

    const NotificationSource = struct {
        owner: *NativeAdapter,
        detached: ?*ProviderMap,
    };

    fn notificationProvider(value: ?*anyopaque, id: FullNodeId) NativeError!objc.Object {
        const source: *NotificationSource = @ptrCast(@alignCast(value.?));
        const self = source.owner;
        self.context.provider_mutex.lockUncancelable(self.io);
        defer self.context.provider_mutex.unlock(self.io);
        var weak = self.context.weak();
        defer weak.deinit();
        return self.leaseProvider(id, platform_node.create, weak);
    }

    fn notificationTakeRemoved(value: ?*anyopaque, id: FullNodeId) ?objc.Object {
        const source: *NotificationSource = @ptrCast(@alignCast(value.?));
        if (source.detached) |old| {
            const removed = old.fetchSwapRemove(id) orelse return null;
            return removed.value;
        }
        const self = source.owner;
        self.context.provider_mutex.lockUncancelable(self.io);
        defer self.context.provider_mutex.unlock(self.io);
        const removed = self.providers.fetchSwapRemove(id) orelse return null;
        return removed.value;
    }

    fn sweepDefunctProviders(self: *NativeAdapter) error{ProviderLimitExceeded}!void {
        self.context.provider_mutex.lockUncancelable(self.io);
        defer self.context.provider_mutex.unlock(self.io);
        var index: usize = 0;
        for (0..provider_limit) |_| {
            if (index == self.providers.count()) return;
            const id = self.providers.keys()[index];
            const alive = if (self.tree) |*tree|
                consumer.node_id.NodeRef.init(&tree.state, id) != null
            else
                false;
            if (alive) {
                index += 1;
            } else {
                const removed = self.providers.fetchSwapRemove(id).?;
                objc.release(removed.value);
            }
        }
        if (index < self.providers.count()) return error.ProviderLimitExceeded;
    }
};

fn updateAdmissionError(err: NativeError) UpdateError {
    return switch (err) {
        error.Closed => error.Closed,
        error.ProviderLimitExceeded => error.ProviderLimitExceeded,
        else => @panic("unexpected error from allocation-free context admission"),
    };
}

fn raisePrepared(outcome: PreparedUpdateOutcome) UpdateOutcome {
    return switch (outcome) {
        .inactive => .inactive,
        .rejected => |err| .{ .rejected = err },
        .committed => |committed| blk: {
            var failure = committed.notification_error;
            if (committed.events) |queue| {
                queue.raiseAndDeinit() catch |err| {
                    if (failure == null) failure = err;
                };
            }
            break :blk .{ .committed = .{
                .notification_error = failure,
                .used_full_tree = committed.used_full_tree,
            } };
        },
    };
}

// Two snapshot borrows and one precommit loan require three owned string pairs.
const MetadataOwners = struct {
    slots: [3]?Pair = .{ null, null, null },
    const Pair = struct { name: ?[]u8, version: ?[]u8 };

    fn prepare(
        self: *MetadataOwners,
        gpa: std.mem.Allocator,
        source: *const schema.TreeUpdate,
    ) std.mem.Allocator.Error!schema.TreeUpdate {
        var loan = source.*;
        var info = source.tree orelse return loan;
        if (info.toolkit_name == null and info.toolkit_version == null) return loan;
        const name: ?[]u8 = if (info.toolkit_name) |bytes|
            if (bytes.len == 0) null else try gpa.dupe(u8, bytes)
        else
            null;
        errdefer if (name) |bytes| gpa.free(bytes);
        const version: ?[]u8 = if (info.toolkit_version) |bytes|
            if (bytes.len == 0) null else try gpa.dupe(u8, bytes)
        else
            null;
        errdefer if (version) |bytes| gpa.free(bytes);
        // Empty strings own no bytes and use permanent storage, not ambiguous alloc(0) owners.
        info.toolkit_name = if (name) |bytes| bytes else if (info.toolkit_name != null) "" else null;
        info.toolkit_version = if (version) |bytes| bytes else if (info.toolkit_version != null) "" else null;
        loan.tree = info;
        if (name == null and version == null) return loan;
        for (&self.slots) |*slot| {
            if (slot.* == null) {
                slot.* = .{ .name = name, .version = version };
                return loan;
            }
        }
        @panic("native toolkit metadata owner bound exhausted");
    }

    fn reap(
        self: *MetadataOwners,
        gpa: std.mem.Allocator,
        tree: ?*const consumer.tree.Tree,
    ) void {
        for (&self.slots) |*slot| {
            const pair = slot.* orelse continue;
            if (tree) |live| {
                if (borrows(live.state.info, pair) or borrows(live.next_state.info, pair)) continue;
            }
            if (pair.name) |bytes| gpa.free(bytes);
            if (pair.version) |bytes| gpa.free(bytes);
            slot.* = null;
        }
    }

    fn borrows(info: schema.TreeInfo, pair: Pair) bool {
        return sameStorage(info.toolkit_name, pair.name) or
            sameStorage(info.toolkit_version, pair.version);
    }

    fn sameStorage(borrowed: ?[]const u8, owned: ?[]u8) bool {
        const bytes = borrowed orelse return false;
        const storage = owned orelse return false;
        return bytes.len == storage.len and bytes.ptr == storage.ptr;
    }

    fn deinit(self: *MetadataOwners, gpa: std.mem.Allocator) void {
        self.reap(gpa, null);
        self.* = .{};
    }
};

// Refused construction leaves an actual Io resource owned by the caller.
test "native constructor refusal preserves caller runtime authority" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    var resource = try ConstructorRuntime.init();
    defer if (resource.releases == 0) ConstructorRuntime.release(&resource);
    const Callback = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    try std.testing.expectError(error.NativeUnsupported, NativeAdapter.create(
        std.testing.allocator,
        resource.provider.io(),
        .{
            .action_handler = Callback.action,
            .activation_sink = .{ .native = .{
                .callback = Callback.activate,
                .userdata = null,
            } },
            .runtime_release = .{ .userdata = &resource, .release = ConstructorRuntime.release },
        },
    ));
    try std.testing.expectEqual(@as(usize, 0), resource.releases);
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(resource.provider.io());
    mutex.unlock(resource.provider.io());
    ConstructorRuntime.release(&resource);
    try std.testing.expectEqual(@as(usize, 1), resource.releases);
}

// The real consumer must own nodes and toolkit bytes after the full supplier loan ends.
test "native borrowed publication owns source nodes and toolkit metadata" {
    const gpa = std.testing.allocator;
    var update: schema.TreeUpdate = .{};
    defer update.deinit(gpa);
    var root = schema.Node.init(gpa, .window);
    try schema.strings.setLabel(&root.properties, "original root");
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var toolkit = [_]u8{ 'l', 'o', 'a', 'n' };
    update.tree = .{
        .root = .{ .value = 1 },
        .toolkit_name = &toolkit,
        .toolkit_version = null,
    };
    update.focus = .{ .value = 1 };
    var owners: MetadataOwners = .{};
    defer owners.deinit(gpa);
    const loan = try owners.prepare(gpa, &update);
    var tree = try consumer.tree.Tree.initBorrowed(gpa, &loan, false);
    defer tree.deinit();
    owners.reap(gpa, &tree);
    @memset(&toolkit, 'x');
    try schema.strings.setLabel(&update.nodes.items[0].node.properties, "changed source");
    try std.testing.expectEqualStrings("loan", tree.state.info.toolkit_name.?);
    try std.testing.expectEqualStrings(
        "original root",
        schema.strings.label(&tree.state.root().data().properties).?,
    );
}

// An invalid delta cannot replace the published readback or release its metadata owner.
test "native rejected borrowed delta preserves published readback metadata" {
    const gpa = std.testing.allocator;
    var initial: schema.TreeUpdate = .{};
    defer initial.deinit(gpa);
    try initial.nodes.append(gpa, .{
        .node_id = .{ .value = 1 },
        .node = schema.Node.init(gpa, .window),
    });
    initial.tree = .{
        .root = .{ .value = 1 },
        .toolkit_name = "baseline",
        .toolkit_version = null,
    };
    initial.focus = .{ .value = 1 };
    var owners: MetadataOwners = .{};
    defer owners.deinit(gpa);
    const initial_loan = try owners.prepare(gpa, &initial);
    var tree = try consumer.tree.Tree.initBorrowed(gpa, &initial_loan, false);
    defer tree.deinit();
    var bad: schema.TreeUpdate = .{};
    defer bad.deinit(gpa);
    bad.tree = .{
        .root = .{ .value = 999 },
        .toolkit_name = "rejected",
        .toolkit_version = null,
    };
    bad.focus = .{ .value = 999 };
    const bad_loan = try owners.prepare(gpa, &bad);
    var callback_context: u8 = 0;
    const handler: consumer.tree.TreeChangeHandler = .{ .ptr = &callback_context };
    try std.testing.expectError(
        error.RootNotInTree,
        tree.updateBorrowedAndProcessChanges(&bad_loan, &handler),
    );
    owners.reap(gpa, &tree);
    try std.testing.expectEqual(@as(u64, 1), tree.state.root().id().local.value);
    try std.testing.expectEqualStrings("baseline", tree.state.info.toolkit_name.?);
}

// Failed construction preserves caller-owned Io; success transfers its disposal hook.
test "native constructor allocation failures preserve caller runtime authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        constructorAllocationFailure,
        .{},
    );
}

fn constructorAllocationFailure(gpa: std.mem.Allocator) !void {
    var resource = try ConstructorRuntime.init();
    defer if (resource.releases == 0) ConstructorRuntime.release(&resource);
    const Callback = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    const adapter = NativeAdapter.create(gpa, resource.provider.io(), .{
        .action_handler = Callback.action,
        .activation_sink = .{ .native = .{
            .callback = Callback.activate,
            .userdata = null,
        } },
        .runtime_release = .{ .userdata = &resource, .release = ConstructorRuntime.release },
    }) catch |err| {
        try std.testing.expectEqual(@as(usize, 0), resource.releases);
        var mutex: std.Io.Mutex = .init;
        mutex.lockUncancelable(resource.provider.io());
        mutex.unlock(resource.provider.io());
        return err;
    };
    try adapter.close();
    adapter.deinit();
    try std.testing.expectEqual(@as(usize, 1), resource.releases);
}

// Native queries must request exactly one full frame; supplier replacement beats stale delta.
test "native pending activation publishes current full rather than stale delta" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    var full = try fixture.full("current full");
    defer full.deinit(fixture.gpa);
    var stale = try fixture.full("stale delta");
    defer stale.deinit(fixture.gpa);
    const Supplier = struct {
        update: *const schema.TreeUpdate,
        calls: usize = 0,
        const Self = @This();

        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            const source: *Self = @ptrCast(@alignCast(value.?));
            source.calls += 1;
            return source.update;
        }
    };
    var source: Supplier = .{ .update = &full };
    const supplier: FullTreeSupplier = .{ .context = &source, .get = Supplier.get };
    try std.testing.expect(fixture.adapter.prepareUpdateIfActiveBorrowedChecked(
        &stale,
        supplier,
    ) == .inactive);
    try std.testing.expectEqual(@as(usize, 0), fixture.activation_calls.*);
    try std.testing.expectEqual(@as(usize, 0), source.calls);
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    try std.testing.expect(fixture.adapter.isActive());
    try std.testing.expectEqual(@as(usize, 1), fixture.activation_calls.*);
    const outcome = fixture.adapter.updateIfActiveBorrowedChecked(&stale, supplier);
    try std.testing.expect(outcome == .committed);
    try std.testing.expect(outcome.committed.notification_error == null);
    try std.testing.expect(outcome.committed.used_full_tree);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    try std.testing.expectEqualStrings(
        "current full",
        schema.strings.label(&fixture.adapter.tree.?.state.root().data().properties).?,
    );
    const delta_outcome = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&stale, supplier);
    try std.testing.expect(delta_outcome == .committed);
    defer if (delta_outcome.committed.events) |queue| queue.deinit();
    try std.testing.expect(!delta_outcome.committed.used_full_tree);
    try std.testing.expectEqual(@as(usize, 1), source.calls);
    const focus_outcome = fixture.adapter.prepareViewFocusState(true);
    try std.testing.expect(focus_outcome == .committed);
    defer if (focus_outcome.committed.events) |queue| queue.deinit();
    try std.testing.expect(!focus_outcome.committed.used_full_tree);
}

// Real slot allocation failure after a native commit must not turn it into rejection.
test "native postcommit event error preserves committed label and baseline" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    var full = try fixture.full("baseline");
    defer full.deinit(fixture.gpa);
    // Window roots suppress title notifications; a button root exposes the changed label.
    full.nodes.items[0].node.setRole(.button);
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const supplier: FullTreeSupplier = .{ .context = &full, .get = Supplier.get };
    try std.testing.expect(fixture.adapter.updateIfActiveBorrowedChecked(
        &full,
        supplier,
    ) == .committed);
    var delta = try fixture.full("committed label");
    defer delta.deinit(fixture.gpa);
    delta.nodes.items[0].node.setRole(.button);
    delta.tree = null;
    var failing = std.testing.FailingAllocator.init(fixture.gpa, .{ .fail_index = 0 });
    fixture.adapter.gpa = failing.allocator();
    const outcome = fixture.adapter.updateIfActiveBorrowedChecked(&delta, supplier);
    fixture.adapter.gpa = fixture.gpa;
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(
        @as(NotificationError, error.OutOfMemory),
        outcome.committed.notification_error.?,
    );
    try std.testing.expectEqualStrings(
        "committed label",
        schema.strings.label(&fixture.adapter.tree.?.state.root().data().properties).?,
    );
}

const NativeFixture = struct {
    gpa: std.mem.Allocator,
    runtime: *std.Io.Threaded,
    adapter: *NativeAdapter,
    activation_calls: *usize,

    fn init(gpa: std.mem.Allocator) !NativeFixture {
        return initWithRuntimeRelease(gpa, null);
    }

    fn initWithRuntimeRelease(gpa: std.mem.Allocator, authority: ?RuntimeRelease) !NativeFixture {
        const runtime = try gpa.create(std.Io.Threaded);
        errdefer gpa.destroy(runtime);
        runtime.* = .init(gpa, .{});
        errdefer runtime.deinit();
        const calls = try gpa.create(usize);
        errdefer gpa.destroy(calls);
        calls.* = 0;
        const Callback = struct {
            fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
            fn activate(value: ?*anyopaque) void {
                const count: *usize = @ptrCast(@alignCast(value.?));
                count.* += 1;
            }
        };
        const adapter = try NativeAdapter.create(gpa, runtime.io(), .{
            .action_handler = Callback.action,
            .activation_sink = .{ .native = .{
                .callback = Callback.activate,
                .userdata = calls,
            } },
            .runtime_release = authority,
        });
        errdefer {
            adapter.close() catch @panic("fixture close failed");
            adapter.deinit();
        }
        const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
        const object = objc.send(?objc.Object, @ptrCast(view_class), "new", .{}) orelse
            return error.NativeObjectCreationFailed;
        defer objc.release(object);
        try adapter.attach(.{ .view = object }, false);
        return .{ .gpa = gpa, .runtime = runtime, .adapter = adapter, .activation_calls = calls };
    }

    fn full(self: NativeFixture, label: []const u8) !schema.TreeUpdate {
        var update: schema.TreeUpdate = .{};
        errdefer update.deinit(self.gpa);
        var root = schema.Node.init(self.gpa, .window);
        schema.strings.setLabel(&root.properties, label) catch |err| {
            root.deinit();
            return err;
        };
        try update.pushNode(self.gpa, .{ .value = 1 }, root);
        update.tree = schema.TreeInfo.init(.{ .value = 1 });
        update.focus = .{ .value = 1 };
        return update;
    }

    fn deinit(self: *NativeFixture) void {
        if (!self.adapter.closed) self.adapter.close() catch @panic("fixture close failed");
        self.adapter.deinit();
        self.runtime.deinit();
        self.gpa.destroy(self.runtime);
        self.gpa.destroy(self.activation_calls);
        self.* = undefined;
    }
};

// C activation transfers real source storage; it is consumed now, not discarded until a delta.
test "native C initial activation accepts borrowed source and owns metadata immediately" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    var toolkit = [_]u8{ 'C', 'l', 'o', 'a', 'n' };
    var source_arena = std.heap.ArenaAllocator.init(fixture.gpa);
    var source_alive = true;
    defer if (source_alive) source_arena.deinit();
    const source_gpa = source_arena.allocator();
    const handle = blk: {
        var update: schema.TreeUpdate = .{};
        errdefer update.deinit(source_gpa);
        var root = schema.Node.init(source_gpa, .window);
        schema.strings.setLabel(&root.properties, "C initial") catch |err| {
            root.deinit();
            return err;
        };
        try update.pushNode(source_gpa, .{ .value = 1 }, root);
        update.tree = schema.TreeInfo.init(.{ .value = 1 });
        update.focus = .{ .value = 1 };
        const owned = try source_gpa.create(c_tree_update.accesskit_tree_update);
        owned.* = .{ .gpa = source_gpa, .update = update, .info = null };
        break :blk owned;
    };
    handle.update.tree.?.toolkit_name = &toolkit;
    var source: ?*boundary.CTreeUpdate = @ptrCast(handle);
    defer if (source) |remaining| c_tree_update.discard(remaining);
    const Callback = struct {
        fn activate(value: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const slot: *?*boundary.CTreeUpdate = @ptrCast(@alignCast(value.?));
            const owned = slot.*;
            slot.* = null;
            return owned;
        }
    };
    fixture.adapter.options.activation_sink = .{ .c = .{ .callback = null, .userdata = null } };
    fixture.adapter.setCActivationHandler(Callback.activate, &source);
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    try std.testing.expect(source == null);
    try std.testing.expect(!fixture.adapter.activation_pending);
    source_arena.deinit();
    source_alive = false;
    @memset(&toolkit, 'x');
    try std.testing.expectEqualStrings(
        "C initial",
        schema.strings.label(&fixture.adapter.tree.?.state.root().data().properties).?,
    );
    try std.testing.expectEqualStrings("Cloan", fixture.adapter.tree.?.state.info.toolkit_name.?);
}

// Invalid initial C input is released and reported exactly, while full repair stays admitted.
test "native invalid C initial activation releases source and reports root error" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const handle = try fixture.gpa.create(c_tree_update.accesskit_tree_update);
    handle.* = .{
        .gpa = fixture.gpa,
        .update = .{
            .tree = schema.TreeInfo.init(.{ .value = 999 }),
            .focus = .{ .value = 999 },
        },
        .info = null,
    };
    var source: ?*boundary.CTreeUpdate = @ptrCast(handle);
    defer if (source) |remaining| c_tree_update.discard(remaining);
    const Callback = struct {
        fn activate(value: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const slot: *?*boundary.CTreeUpdate = @ptrCast(@alignCast(value.?));
            const owned = slot.*;
            slot.* = null;
            return owned;
        }
    };
    fixture.adapter.options.activation_sink = .{ .c = .{ .callback = null, .userdata = null } };
    fixture.adapter.setCActivationHandler(Callback.activate, &source);
    try std.testing.expectError(error.RootNotInTree, fixture.adapter.viewChildrenChecked());
    try std.testing.expect(source == null);
    try std.testing.expect(fixture.adapter.activation_pending);
    try std.testing.expect(fixture.adapter.isActive());
}

// The public attachment refusal leaves an ordinary native object's class unchanged.
test "native invalid view attachment preserves Objective-C class and inactive owner" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var threaded = std.Io.Threaded.init(gpa, .{});
    defer threaded.deinit();
    const Callback = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    const adapter = try NativeAdapter.create(gpa, threaded.io(), .{
        .action_handler = Callback.action,
        .activation_sink = .{ .native = .{
            .callback = Callback.activate,
            .userdata = null,
        } },
    });
    defer {
        adapter.close() catch @panic("invalid attachment fixture close failed");
        adapter.deinit();
    }
    const object_class = objc.getClass("NSObject") orelse return error.ObjectiveCUnavailable;
    const object = objc.send(?objc.Object, @ptrCast(object_class), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(object);
    const original = objc.object_getClass(object);
    try std.testing.expectError(error.InvalidView, adapter.attach(.{ .view = object }, false));
    try std.testing.expectError(error.InvalidView, adapter.attach(.{ .window = object }, false));
    try std.testing.expectEqual(original, objc.object_getClass(object));
    try std.testing.expect(adapter.retained_view == null);
    try std.testing.expect(!adapter.isActive());
}

// Rejected initial full publication keeps the activation request and the actual placeholder.
test "native rejected full publication keeps pending activation for repair" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    var rejected: schema.TreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 999 }),
        .focus = .{ .value = 999 },
    };
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const outcome = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&rejected, .{
        .context = &rejected,
        .get = Supplier.get,
    });
    try std.testing.expect(outcome == .rejected);
    try std.testing.expectEqual(@as(UpdateError, error.RootNotInTree), outcome.rejected);
    try std.testing.expect(fixture.adapter.activation_pending);
    try std.testing.expectEqual(@as(u64, 0), fixture.adapter.tree.?.state.rootId().local.value);
    var full = try fixture.full("repaired full");
    defer full.deinit(fixture.gpa);
    const repaired = fixture.adapter.updateIfActiveBorrowedChecked(&rejected, .{
        .context = &full,
        .get = Supplier.get,
    });
    try std.testing.expect(repaired == .committed);
    try std.testing.expect(!fixture.adapter.activation_pending);
    try std.testing.expectEqualStrings(
        "repaired full",
        schema.strings.label(&fixture.adapter.tree.?.state.root().data().properties).?,
    );
}

// Both string allocations are independent, and every failed allocation releases earlier strings.
test "native metadata loan preparation fails atomically at every allocation" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        metadataAllocationFailure,
        .{},
    );
}

fn metadataAllocationFailure(gpa: std.mem.Allocator) !void {
    var owners: MetadataOwners = .{};
    defer owners.deinit(gpa);
    var name = [_]u8{ 'n', 'a', 'm', 'e' };
    var version = [_]u8{ 'v', '1' };
    const source: schema.TreeUpdate = .{ .tree = .{
        .root = .{ .value = 1 },
        .toolkit_name = &name,
        .toolkit_version = &version,
    } };
    const loan = try owners.prepare(gpa, &source);
    @memset(&name, 'x');
    @memset(&version, 'x');
    try std.testing.expectEqualStrings("name", loan.tree.?.toolkit_name.?);
    try std.testing.expectEqualStrings("v1", loan.tree.?.toolkit_version.?);
    try std.testing.expectEqualStrings("xxxx", source.tree.?.toolkit_name.?);
    try std.testing.expectEqualStrings("xx", source.tree.?.toolkit_version.?);
}

// A wrong-thread constructor refusal leaves the caller's authority untouched.
test "native wrong-thread constructor preserves caller runtime authority" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const ThreadState = struct {
        io: std.Io,
        releases: usize = 0,
        refusal: ?CreateError = null,
        const Self = @This();

        fn release(value: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(value.?));
            self.releases += 1;
        }
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
        fn run(self: *Self) void {
            const owner = NativeAdapter.create(std.testing.allocator, self.io, .{
                .action_handler = action,
                .activation_sink = .{ .native = .{
                    .callback = activate,
                    .userdata = null,
                } },
                .runtime_release = .{ .userdata = self, .release = release },
            }) catch |err| {
                self.refusal = err;
                return;
            };
            // A successful foreign-thread constructor violates the API and cannot be torn down here.
            _ = owner;
            @panic("native constructor unexpectedly succeeded on worker thread");
        }
    };
    var state: ThreadState = .{ .io = threaded.io() };
    const worker = try std.Thread.spawn(.{}, ThreadState.run, .{&state});
    worker.join();
    try std.testing.expectEqual(@as(CreateError, error.WrongThread), state.refusal.?);
    try std.testing.expectEqual(@as(usize, 0), state.releases);
}

// Activation releases both mutation locks before a borrowed callback makes a nested query.
test "native activation callback can reenter a checked read-only query" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const CallbackState = struct {
        adapter: *NativeAdapter,
        calls: usize = 0,
        children: ?objc.Object = null,
        failure: ?NativeError = null,
        const Self = @This();

        fn activate(value: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(value.?));
            self.calls += 1;
            self.children = self.adapter.viewChildrenChecked() catch |err| {
                self.failure = err;
                return;
            };
        }
    };
    var state: CallbackState = .{ .adapter = fixture.adapter };
    defer if (state.children) |children| objc.release(children);
    fixture.adapter.options.activation_sink = .{ .native = .{
        .callback = CallbackState.activate,
        .userdata = &state,
    } };
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    try std.testing.expect(state.failure == null);
    try std.testing.expect(state.children != null);
    try std.testing.expectEqual(@as(usize, 1), state.calls);
    try std.testing.expectEqual(
        @as(usize, 1),
        objc.send(usize, state.children.?, "count", .{}),
    );
}

// Debug output observes one guarded phase/cache snapshot, including map removal at close.
test "native debug snapshot reports real activation phase and provider ownership" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const inactive = fixture.adapter.debugSnapshot();
    try std.testing.expect(inactive.state == .inactive);
    try std.testing.expectEqual(@as(usize, 0), inactive.provider_count);
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    const placeholder = fixture.adapter.debugSnapshot();
    try std.testing.expect(placeholder.state == .placeholder);
    try std.testing.expectEqual(@as(usize, 1), placeholder.provider_count);
    var failing = std.testing.FailingAllocator.init(fixture.gpa, .{ .fail_index = 0 });
    fixture.adapter.gpa = failing.allocator();
    defer fixture.adapter.gpa = fixture.gpa;
    try fixture.adapter.close();
    try std.testing.expect(!failing.has_induced_failure);
    try std.testing.expectEqual(@as(usize, 0), failing.allocations);
    const closed = fixture.adapter.debugSnapshot();
    try std.testing.expect(closed.state == .closed);
    try std.testing.expectEqual(@as(usize, 0), closed.provider_count);
}

// An action callback may commit a new borrowed frame after its tree read guard ends.
test "native action callback can synchronously publish a borrowed update" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const children = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(children);
    var full = try fixture.full("before action");
    defer full.deinit(fixture.gpa);
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const supplier: FullTreeSupplier = .{ .context = &full, .get = Supplier.get };
    try std.testing.expect(fixture.adapter.updateIfActiveBorrowedChecked(
        &full,
        supplier,
    ) == .committed);
    var delta = try fixture.full("after action");
    defer delta.deinit(fixture.gpa);
    delta.tree = null;
    const CallbackState = struct {
        adapter: *NativeAdapter,
        delta: *const schema.TreeUpdate,
        supplier: FullTreeSupplier,
        outcome: ?UpdateOutcome = null,
        const Self = @This();

        fn action(value: ?*anyopaque, request: *const schema.ActionRequest) void {
            const self: *Self = @ptrCast(@alignCast(value.?));
            std.debug.assert(request.target_tree.eql(schema.tree_id_root));
            self.outcome = self.adapter.updateIfActiveBorrowedChecked(self.delta, self.supplier);
        }
    };
    var state: CallbackState = .{
        .adapter = fixture.adapter,
        .delta = &delta,
        .supplier = supplier,
    };
    fixture.adapter.options.action_handler = CallbackState.action;
    fixture.adapter.options.userdata = &state;
    var weak = fixture.adapter.context.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    try lease.dispatch(.{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = null,
    });
    try std.testing.expect(state.outcome.? == .committed);
    try std.testing.expectEqualStrings(
        "after action",
        schema.strings.label(&fixture.adapter.tree.?.state.root().data().properties).?,
    );
}

// A real consumer removal transfers its cached native node into a post-close queue.
test "native removed provider queue posts its exact retained node after owner disposal" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var releases: u32 = 0;
    const Authority = struct {
        fn release(value: ?*anyopaque) void {
            const count: *u32 = @ptrCast(@alignCast(value.?));
            count.* += 1;
        }
    };
    var fixture = try NativeFixture.initWithRuntimeRelease(gpa, .{
        .userdata = &releases,
        .release = Authority.release,
    });
    defer {
        fixture.runtime.deinit();
        gpa.destroy(fixture.runtime);
        gpa.destroy(fixture.activation_calls);
    }
    var owner_alive = true;
    defer if (owner_alive) {
        if (!fixture.adapter.closed) fixture.adapter.close() catch @panic("fixture close failed");
        fixture.adapter.deinit();
    };
    const placeholder = (try fixture.adapter.viewChildrenChecked()).?;
    objc.release(placeholder);
    var full = try fixture.full("root");
    defer full.deinit(gpa);
    try schema.ids_props.setChildren(&full.nodes.items[0].node.properties, &.{.{ .value = 2 }});
    var child = schema.Node.init(gpa, .button);
    schema.strings.setLabel(&child.properties, "retained child") catch |err| {
        child.deinit();
        return err;
    };
    try full.pushNode(gpa, .{ .value = 2 }, child);
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const supplier: FullTreeSupplier = .{ .context = &full, .get = Supplier.get };
    try std.testing.expect(fixture.adapter.updateIfActiveBorrowedChecked(&full, supplier) == .committed);
    var child_id: FullNodeId = undefined;
    const native_child = blk: {
        var weak = fixture.adapter.context.weak();
        defer weak.deinit();
        var lease = try weak.lease();
        defer lease.deinit();
        const node = lease.state().?.nodeByTreeLocalId(.{ .value = 2 }, schema.tree_id_root).?;
        child_id = node.id();
        break :blk try lease.provider(child_id);
    };
    var child_alive = true;
    defer if (child_alive) objc.release(native_child);
    const baseline = objc.send(usize, native_child, "retainCount", .{});
    var delta = try fixture.full("root");
    defer delta.deinit(gpa);
    delta.tree = null;
    const outcome = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&delta, supplier);
    try std.testing.expect(outcome == .committed);
    try std.testing.expect(outcome.committed.notification_error == null);
    const queue = outcome.committed.events.?;
    var queue_alive = true;
    defer if (queue_alive) queue.deinit();
    try std.testing.expect(fixture.adapter.providers.get(child_id) == null);
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqual(native_child, queue.items.items[0].notification.target);
    try std.testing.expectEqual(baseline, objc.send(usize, native_child, "retainCount", .{}));
    try fixture.adapter.close();
    fixture.adapter.deinit();
    owner_alive = false;
    try std.testing.expectEqual(@as(u32, 0), releases);
    try std.testing.expect(objc.send(?objc.Object, native_child, "accessibilityRole", .{}) == null);
    queue_alive = false;
    try queue.raiseAndDeinit();
    try std.testing.expectEqual(@as(u32, 0), releases);
    objc.release(native_child);
    child_alive = false;
    try std.testing.expectEqual(@as(u32, 1), releases);
}

// Placeholder replacement retires the old native generation even when root ID0 is reused.
test "native full activation replaces same id placeholder and queues exact old provider" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const placeholder = (try fixture.adapter.viewChildrenChecked()).?;
    const old_root = objc.retain(objc.send(objc.Object, placeholder, "objectAtIndex:", .{@as(usize, 0)}));
    objc.release(placeholder);
    defer objc.release(old_root);
    var old_weak = fixture.adapter.context.weak();
    old_weak.provider_epoch = 0;
    defer old_weak.deinit();
    var full = try fixture.full("real root zero");
    defer full.deinit(fixture.gpa);
    full.nodes.items[0].node_id = .{ .value = 0 };
    full.tree.?.root = .{ .value = 0 };
    full.focus = .{ .value = 0 };
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const supplier: FullTreeSupplier = .{ .context = &full, .get = Supplier.get };
    full.tree.?.root = .{ .value = 99 };
    const rejected = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&full, supplier);
    try std.testing.expect(rejected == .rejected);
    try std.testing.expectEqual(error.RootNotInTree, rejected.rejected);
    try std.testing.expectEqual(@as(u1, 0), fixture.adapter.provider_epoch);
    {
        var lease = try old_weak.lease();
        defer lease.deinit();
        try std.testing.expectEqual(old_root, fixture.adapter.providers.get(lease.state().?.root().id()).?);
    }
    try std.testing.expect(objc.send(?objc.Object, old_root, "accessibilityRole", .{}) != null);
    full.tree.?.root = .{ .value = 0 };
    const outcome = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&full, supplier);
    try std.testing.expect(outcome == .committed);
    try std.testing.expect(outcome.committed.used_full_tree);
    try std.testing.expect(outcome.committed.notification_error == null);
    try std.testing.expect(outcome.committed.events != null);
    const queue = outcome.committed.events.?;
    var queue_alive = true;
    defer if (queue_alive) queue.deinit();
    try std.testing.expectEqual(@as(usize, 1), queue.items.items.len);
    try std.testing.expectEqual(old_root, queue.items.items[0].notification.target);
    try std.testing.expectEqualStrings(
        events.notificationFor(.node_destroyed).?,
        queue.items.items[0].notification.name,
    );
    try std.testing.expectEqual(@as(u1, 1), fixture.adapter.provider_epoch);
    try std.testing.expectError(error.Closed, old_weak.lease());
    try std.testing.expect(objc.send(?objc.Object, old_root, "accessibilityRole", .{}) == null);
    const active = (try fixture.adapter.viewChildrenChecked()).?;
    defer objc.release(active);
    const new_root = objc.send(objc.Object, active, "objectAtIndex:", .{@as(usize, 0)});
    try std.testing.expect(old_root != new_root);
    const root_id = fixture.adapter.tree.?.state.root().id();
    try std.testing.expectEqual(new_root, fixture.adapter.providers.get(root_id).?);
    queue_alive = false;
    try queue.raiseAndDeinit();
    try std.testing.expectEqual(new_root, fixture.adapter.providers.get(root_id).?);
}

test "native repeated empty toolkit metadata preserves present strings without owner exhaustion" {
    const gpa = std.testing.allocator;
    var owners: MetadataOwners = .{};
    defer owners.deinit(gpa);
    var initial: schema.TreeUpdate = .{};
    defer initial.deinit(gpa);
    try initial.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    initial.tree = schema.TreeInfo.init(.{ .value = 1 });
    initial.tree.?.toolkit_name = "";
    initial.tree.?.toolkit_version = "";
    initial.focus = .{ .value = 1 };
    const initial_loan = try owners.prepare(gpa, &initial);
    var tree = try consumer.tree.Tree.initBorrowed(gpa, &initial_loan, false);
    defer tree.deinit();
    const delta: schema.TreeUpdate = .{ .tree = initial.tree, .focus = .{ .value = 1 } };
    var generator = events.EventGenerator.init(gpa);
    defer generator.deinit();
    const handler = events.slotsOf(&generator);
    for (0..8) |_| {
        const loan = try owners.prepare(gpa, &delta);
        try tree.updateBorrowedAndProcessChanges(&loan, &handler);
        owners.reap(gpa, &tree);
        try std.testing.expectEqualStrings("", tree.state.info.toolkit_name.?);
        try std.testing.expectEqualStrings("", tree.state.info.toolkit_version.?);
    }
    for (owners.slots) |slot| try std.testing.expect(slot == null);
}

test "native wrong-thread checked queries refuse before activation callback or publication" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const ThreadState = struct {
        adapter: *NativeAdapter,
        refusals: usize = 0,
        successes: usize = 0,
        unexpected: ?NativeError = null,
        const Self = @This();

        fn record(self: *Self, result: NativeError!?objc.Object) void {
            if (result) |object| {
                self.successes += 1;
                if (object) |owned| objc.release(owned);
            } else |err| {
                if (err == error.WrongThread) self.refusals += 1 else self.unexpected = err;
            }
        }
        fn run(self: *Self) void {
            self.record(self.adapter.viewChildrenChecked());
            self.record(self.adapter.focusChecked());
            self.record(self.adapter.hitTestChecked(.{ .x = 0, .y = 0 }));
            self.adapter.requestActivation();
        }
    };
    var state: ThreadState = .{ .adapter = fixture.adapter };
    const thread = try std.Thread.spawn(.{}, ThreadState.run, .{&state});
    thread.join();
    try std.testing.expectEqual(@as(usize, 3), state.refusals);
    try std.testing.expectEqual(@as(usize, 0), state.successes);
    try std.testing.expect(state.unexpected == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.activation_calls.*);
    try std.testing.expect(!fixture.adapter.isActive());
    try std.testing.expect(fixture.adapter.tree == null);
    try std.testing.expectEqual(@as(usize, 0), fixture.adapter.providers.count());
}

const CloseObserver = struct {
    owner: *NativeAdapter,
    calls: usize = 0,
    closed: bool = false,
    fn slot(object: objc.Object) *?*CloseObserver {
        const class = objc.object_getClass(object) orelse @panic("observer class missing");
        const ivar = objc.class_getInstanceVariable(class, "zaccesskit_close_observer") orelse
            @panic("observer ivar missing");
        const offset = objc.ivar_getOffset(ivar);
        std.debug.assert(offset >= 0);
        const bytes: [*]u8 = @ptrCast(object);
        return @ptrCast(@alignCast(bytes + @as(usize, @intCast(offset))));
    }
    fn dealloc(object: objc.Object, _: objc.Sel) callconv(.c) void {
        if (slot(object).*) |observer| {
            slot(object).* = null;
            observer.calls += 1;
            observer.closed = !observer.owner.isActive() and observer.owner.debugSnapshot().state == .closed;
        }
        objc.sendSuper(void, object, objc.getClass("NSView").?, "dealloc", .{});
    }
};

test "native close host deallocation can synchronously observe closed state" {
    if (!objc.native_supported) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const name = "ZAccessKitCloseObserverView";
    const view_class = objc.getClass(name) orelse blk: {
        const created = objc.objc_allocateClassPair(objc.getClass("NSView").?, name, 0) orelse
            return error.NativeObjectCreationFailed;
        errdefer objc.objc_disposeClassPair(created);
        if (objc.class_addIvar(
            created,
            "zaccesskit_close_observer",
            @sizeOf(?*CloseObserver),
            @intCast(@ctz(@alignOf(?*CloseObserver))),
            "^v",
        ) == 0) return error.ClassRegistrationFailed;
        if (objc.class_addMethod(created, objc.sel("dealloc"), @ptrCast(&CloseObserver.dealloc), "v@:") == 0)
            return error.MethodRegistrationFailed;
        objc.objc_registerClassPair(created);
        break :blk created;
    };
    var runtime = std.Io.Threaded.init(std.testing.allocator, .{});
    defer runtime.deinit();
    const Callback = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    const owner = try NativeAdapter.create(std.testing.allocator, runtime.io(), .{
        .action_handler = Callback.action,
        .activation_sink = .{ .native = .{ .callback = Callback.activate, .userdata = null } },
    });
    defer {
        if (!owner.closed) owner.close() catch @panic("observer close failed");
        owner.deinit();
    }
    const object = objc.send(?objc.Object, view_class, "new", .{}) orelse return error.NativeObjectCreationFailed;
    var object_alive = true;
    defer if (object_alive) objc.release(object);
    var observer: CloseObserver = .{ .owner = owner };
    CloseObserver.slot(object).* = &observer;
    try owner.attach(.{ .view = object }, false);
    objc.release(object);
    object_alive = false;
    try owner.close();
    try std.testing.expectEqual(@as(usize, 1), observer.calls);
    try std.testing.expect(observer.closed);
}

test "native queue allocation failure retires a hidden provider still present in core" {
    if (!objc.native_supported) return error.SkipZigTest;
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const placeholder = (try fixture.adapter.viewChildrenChecked()).?;
    objc.release(placeholder);
    var full = try fixture.full("root");
    defer full.deinit(fixture.gpa);
    try schema.ids_props.setChildren(&full.nodes.items[0].node.properties, &.{.{ .value = 2 }});
    try full.pushNode(fixture.gpa, .{ .value = 2 }, schema.Node.init(fixture.gpa, .button));
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const supplier: FullTreeSupplier = .{ .context = &full, .get = Supplier.get };
    try std.testing.expect(fixture.adapter.updateIfActiveBorrowedChecked(&full, supplier) == .committed);
    var id: FullNodeId = undefined;
    const object = blk: {
        var weak = fixture.adapter.context.weak();
        defer weak.deinit();
        var lease = try weak.lease();
        defer lease.deinit();
        id = lease.state().?.nodeByTreeLocalId(.{ .value = 2 }, schema.tree_id_root).?.id();
        break :blk try lease.provider(id);
    };
    defer objc.release(object);
    var hidden = schema.Node.init(fixture.gpa, .button);
    schema.flags.setHidden(&hidden.flags, true);
    var delta: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    defer delta.deinit(fixture.gpa);
    try delta.pushNode(fixture.gpa, .{ .value = 2 }, hidden);
    // One complete destruction event allocation succeeds; heap queue allocation fails.
    var failing = std.testing.FailingAllocator.init(fixture.gpa, .{ .fail_index = 1 });
    fixture.adapter.gpa = failing.allocator();
    const outcome = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&delta, supplier);
    fixture.adapter.gpa = fixture.gpa;
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(error.OutOfMemory, outcome.committed.notification_error.?);
    try std.testing.expect(outcome.committed.events == null);
    try std.testing.expect(
        fixture.adapter.tree.?.state.nodeByTreeLocalId(.{ .value = 2 }, schema.tree_id_root) != null,
    );
    try std.testing.expect(fixture.adapter.providers.get(id) == null);
}

fn nativeTestWindow() NativeError!objc.Object {
    const app_class = objc.getClass("NSApplication") orelse return error.ObjectiveCUnavailable;
    _ = objc.send(?objc.Object, app_class, "sharedApplication", .{}) orelse return error.NativeObjectCreationFailed;
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const allocated = objc.send(?objc.Object, window_class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    return objc.send(?objc.Object, allocated, "initWithContentRect:styleMask:backing:defer:", .{
        objc.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 64, .height = 64 } },
        @as(usize, 0),
        @as(usize, 2),
        @as(u8, 0),
    }) orelse return error.NativeObjectCreationFailed;
}

test "native announcements capture current window after attaching before window insertion" {
    if (!objc.native_supported) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    var fixture = try NativeFixture.init(std.testing.allocator);
    defer fixture.deinit();
    const placeholder = (try fixture.adapter.viewChildrenChecked()).?;
    objc.release(placeholder);
    const view = fixture.adapter.retained_view.?;
    try std.testing.expect(fixture.adapter.retained_window == null);
    var full = try fixture.full("first announcement");
    defer full.deinit(fixture.gpa);
    try schema.enums.setLive(&full.nodes.items[0].node.properties, .polite);
    const Supplier = struct {
        fn get(value: ?*anyopaque) *const schema.TreeUpdate {
            return @ptrCast(@alignCast(value.?));
        }
    };
    const supplier: FullTreeSupplier = .{ .context = &full, .get = Supplier.get };
    try std.testing.expect(fixture.adapter.updateIfActiveBorrowedChecked(&full, supplier) == .committed);
    const first = try nativeTestWindow();
    defer objc.release(first);
    const second = try nativeTestWindow();
    defer objc.release(second);
    for ([_]objc.Object{ first, second }, 0..) |window, index| {
        objc.send(void, view, "removeFromSuperview", .{});
        const content = objc.send(objc.Object, window, "contentView", .{});
        objc.send(void, content, "addSubview:", .{view});
        var delta = try fixture.full(if (index == 0) "window one" else "window two");
        defer delta.deinit(fixture.gpa);
        delta.tree = null;
        try schema.enums.setLive(&delta.nodes.items[0].node.properties, .polite);
        const outcome = fixture.adapter.prepareUpdateIfActiveBorrowedChecked(&delta, supplier);
        try std.testing.expect(outcome == .committed);
        try std.testing.expect(outcome.committed.notification_error == null);
        const queue = outcome.committed.events.?;
        defer queue.deinit();
        try std.testing.expectEqual(window, queue.retained_window.?);
        var announcements: usize = 0;
        for (queue.items.items) |event| if (event == .announcement) {
            announcements += 1;
            try std.testing.expectEqualStrings(if (index == 0) "window one" else "window two", event.announcement.text);
        };
        try std.testing.expectEqual(@as(usize, 1), announcements);
    }
}

const ConstructorRuntime = struct {
    provider: *std.Io.Threaded,
    releases: usize = 0,
    fn init() std.mem.Allocator.Error!ConstructorRuntime {
        const provider = try std.testing.allocator.create(std.Io.Threaded);
        provider.* = .init(std.testing.allocator, .{});
        return .{ .provider = provider };
    }
    fn release(value: ?*anyopaque) void {
        const self: *ConstructorRuntime = @ptrCast(@alignCast(value.?));
        self.releases += 1;
        self.provider.deinit();
        std.testing.allocator.destroy(self.provider);
    }
};

test "native failed attachment preserves adopted runtime until explicit owner disposal" {
    if (!objc.native_supported) return error.SkipZigTest;
    var resource = try ConstructorRuntime.init();
    defer if (resource.releases == 0) ConstructorRuntime.release(&resource);
    const Callback = struct {
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
        fn activate(_: ?*anyopaque) void {}
    };
    const owner = try NativeAdapter.create(std.testing.allocator, resource.provider.io(), .{
        .action_handler = Callback.action,
        .activation_sink = .{ .native = .{ .callback = Callback.activate, .userdata = null } },
        .runtime_release = .{ .userdata = &resource, .release = ConstructorRuntime.release },
    });
    var owner_alive = true;
    defer if (owner_alive) {
        if (!owner.closed) owner.close() catch @panic("attachment rollback close failed");
        owner.deinit();
    };
    const object = objc.send(?objc.Object, objc.getClass("NSObject").?, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(object);
    try std.testing.expectError(error.InvalidView, owner.attach(.{ .view = object }, false));
    try std.testing.expectEqual(@as(usize, 0), resource.releases);
    var mutex: std.Io.Mutex = .init;
    mutex.lockUncancelable(resource.provider.io());
    mutex.unlock(resource.provider.io());
    try owner.close();
    owner.deinit();
    owner_alive = false;
    try std.testing.expectEqual(@as(usize, 1), resource.releases);
}
