//! Checked, owner-held Linux AT-SPI lifecycle.
const std = @import("std");
const schema = @import("../../schema/root.zig");
const tree_id_root = @import("../../schema/ids.zig").tree_id_root;
const platform_adapter = @import("platform_adapter.zig");
const PlatformAdapter = platform_adapter.PlatformAdapter;
const zio = @import("zio");
const consumer = @import("../../consumer/root.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const boundary = @import("../../capi/boundary.zig");
const app_context = @import("app_context.zig");
const events = @import("events.zig");
const objects = @import("objects.zig");
const dispatch = @import("dispatch.zig");
const interfaces = @import("interfaces/root.zig");
const cache_interface = @import("interfaces/cache.zig");
const dbus = @import("dbus.zig");
const bus = @import("bus.zig");
const pump = @import("pump.zig");
const WindowBounds = @import("window_bounds.zig").WindowBounds;
const object_id = @import("object_id.zig");

pub const Runtime = zio.Runtime;
pub const EditableTextRequest = objects.EditableTextRequest;
pub const CallbackError = error{ OutOfMemory, CallbackFailed, InteriorNul };
pub const RejectError = platform_adapter.AdapterError ||
    CallbackError || pump.SubmitError ||
    error{ StaleAttachment, NotStarted, AttachmentExhausted, MissingFullNode, RegisterLimit };
pub const NotificationError = platform_adapter.NotificationError || objects.SyncError ||
    interfaces.Error || bus.Error || error{InvalidCachePayload};
pub const ActivationError = RejectError || NotificationError;
pub const CreateError = pump.Error || std.Io.Dir.ReadFileError || error{InvalidMachineId};
pub const StartError = pump.Error;

/// A host may advance its diff baseline only for `committed`, even if delivery failed.
/// Rejection and inactive never change the committed tree. No result owns memory.
pub const UpdateOutcome = union(enum) {
    inactive,
    rejected: RejectError,
    committed: Committed,

    pub const Committed = struct {
        attachment: u64,
        /// First notification/register/write failure after tree commit, or null.
        notification_error: ?NotificationError = null,
        /// True when native admitted current FULL input, not a delta or focus/bounds change.
        used_full_tree: bool = false,
    };
};

/// Capture before preparing a delta. Reattachment invalidates every previous ticket.
pub const UpdateTicket = struct {
    attachment: u64,

    pub fn matches(self: UpdateTicket, current_attachment: u64) bool {
        return self.attachment == current_attachment;
    }
};

/// Supplied to the factory on the owned lane, not when its operation was enqueued.
pub const UpdateContext = struct {
    attachment: u64,
    /// A pending adapter requires a complete initial tree, not a prepared delta.
    requires_full_tree: bool,
};

/// Preflighted inputs borrowed by `NativeAdapter.updateIfActiveBorrowedChecked`.
/// Both headers and all referenced node and metadata storage must stay live and
/// unmodified until that call returns. Native never deinitializes source storage.
pub const BorrowedUpdateOptions = struct {
    /// Prepared delta for the current accepted publication epoch.
    delta: *const schema.TreeUpdate,
    /// Complete current tree for pending or first-new-epoch publication.
    current_full: *const schema.TreeUpdate,
};

/// An owned factory result. Full input must contain every referenced local node;
/// delta input may reuse existing nodes. The adapter consumes either on every outcome.
pub const FactoryUpdate = struct {
    pub const Kind = enum { delta, full };
    update: schema.TreeUpdate,
    kind: Kind = .delta,
};

/// Factories transfer node storage made with `gpa`. Metadata ownership is captured before completion;
/// its source bytes must remain live through this call. Null leaves a pending tree pending.
pub const UpdateFactory = *const fn (
    std.mem.Allocator,
    ?*anyopaque,
    UpdateContext,
) CallbackError!?FactoryUpdate;

/// A scoped, preflighted FULL snapshot loan for one actual native attachment.
/// Returning the loan requires no allocation/native calls. Native copies/applies
/// while update and all its node/metadata storage remain pinned, then calls release
/// exactly once on every outcome BEFORE activation_completed. Native never deinitializes
/// the borrowed update. A host read lock/pin may be released by release.
pub const ActivationSnapshot = struct {
    update: *const schema.TreeUpdate,
    release_context: ?*anyopaque,
    release: *const fn (?*anyopaque) void,
};

/// All callbacks run serially on the pump's owned lane, without a tree/query lock.
/// User data and function pointers must live through close. Callbacks may not reenter
/// start/update/close/destroy; reentry rejects with Reentrant (or Closed after admission closes).
pub const Callbacks = struct {
    context: ?*anyopaque,
    /// Requested on EVERY attachment, including reattachment after a late prepared delta.
    /// Supply the current FULL cached snapshot, without cloning/allocating in this callback.
    activation: *const fn (?*anyopaque) CallbackError!?ActivationSnapshot,
    /// The request and UTF8 payload borrow native storage only through this callback.
    action: *const fn (?*anyopaque, *const schema.ActionRequest) CallbackError!void,
    /// Runs after objects/tree release, before close returns.
    deactivation: *const fn (?*anyopaque) void,
    /// Null skips the notification. Hosts tracking a baseline use only committed results.
    activation_completed: ?*const fn (?*anyopaque, UpdateOutcome) void = null,
    /// `null` preserves stock `NotSupported` for positioned text edits.
    /// Runs once on the pump's owner lane, without a tree/query lock.
    /// The request and replacement UTF-8 bytes borrow native storage through return only.
    /// Must not reenter this NativeAdapter's start/update/close/destroy operations.
    /// Return `true` only after accepting the edit. `false` means no accepted edit
    /// and becomes `error.CallbackFailed`. A `CallbackError` also means no accepted edit.
    editable_text: ?*const fn (?*anyopaque, *const EditableTextRequest) CallbackError!bool = null,
};

/// One connection/application and its window. Addresses are copied; the environment,
/// allocator, io provider and runtime remain borrowed through close and destroy.
pub const Options = struct {
    adapter_id: usize,
    app_name: ?[]const u8 = null,
    bus: pump.Options,
    is_host_focused: bool = false,
    bounds: WindowBounds = .empty,
    /// Null reads the actual host machine-id. A supplied value is validated and copied.
    machine_id: ?[]const u8 = null,
};

pub const ActivationStatus = enum(u8) { inactive, pending, active, closed };

/// Stable, single-owner adapter. Concurrent checked operations are serialized by its pump.
/// close stops admission and joins every task/callback; destroy then frees the owner.
/// Copying this pointer does not extend its lifetime. Callers must stop using it before destroy.
pub const NativeAdapter = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    runtime: *Runtime,
    callbacks: Callbacks,
    options_arena: std.heap.ArenaAllocator,
    platform: PlatformAdapter,
    app: app_context.AppContext,
    node_context: ?app_context.NodeContext = null,
    register: objects.Register,
    metadata: MetadataOwners,
    c_metadata: c_tree_update.LiveMetadataOwners = .{},
    machine_id: [32]u8,
    pump: *pump.Pump,
    status: std.atomic.Value(ActivationStatus) = .init(.inactive),
    attachment: std.atomic.Value(u64) = .init(0),
    started: std.atomic.Value(bool) = .init(false),
    start_failed: std.atomic.Value(bool) = .init(false),
    closing: std.atomic.Value(bool) = .init(false),
    closed: std.atomic.Value(bool) = .init(false),
    close_mutex: std.Io.Mutex = .init,
    activation_error: std.atomic.Value(u32) = .init(0),
    transport_error: std.atomic.Value(u32) = .init(0),
    dispatch_error: std.atomic.Value(u32) = .init(0),
    action_error: std.atomic.Value(u32) = .init(0),
    close_error: std.atomic.Value(u32) = .init(0),
    cycle_open: bool = false,
    cycle_attached: bool = false,
    last_borrowed_committed_epoch: u64 = 0,
    /// Owner-lane only. Failed registration leaves raised events owned until a
    /// successful sync reconciles them, or terminal teardown releases them.
    registration_pending: bool = false,

    /// Builds a stable owner without starting the bus or invoking a callback.
    /// Failure releases every acquired resource; caller retains all input storage.
    pub fn create(
        gpa: std.mem.Allocator,
        io: std.Io,
        runtime: *Runtime,
        options: Options,
        callbacks: Callbacks,
    ) CreateError!*NativeAdapter {
        const machine_id = try readMachineId(io, options.machine_id);
        const self = try gpa.create(NativeAdapter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .io = io,
            .runtime = runtime,
            .callbacks = callbacks,
            .options_arena = .init(gpa),
            .platform = PlatformAdapter.init(gpa, options.adapter_id, options.is_host_focused),
            .app = try app_context.AppContext.init(gpa, options.app_name),
            .register = undefined,
            .metadata = MetadataOwners.init(gpa),
            .machine_id = machine_id,
            .pump = undefined,
        };
        errdefer self.app.deinit();
        errdefer self.options_arena.deinit();
        self.platform.bounds = options.bounds;
        self.platform.app = &self.app;
        self.register = objects.Register.init(gpa, &self.app);
        errdefer self.register.deinit();
        self.register.machine_id = &self.machine_id;
        self.register.limits = options.bus.limits;
        self.register.sink = .{ .context = self, .raise = deliverAction };
        if (callbacks.editable_text != null) {
            self.register.editable_text_sink = .{ .context = self, .raise = deliverEditableText };
        }
        const arena = self.options_arena.allocator();
        var copied_options = options.bus;
        if (copied_options.session_address) |text| {
            copied_options.session_address = try arena.dupe(u8, text);
        }
        if (copied_options.accessibility_address) |text| {
            copied_options.accessibility_address = try arena.dupe(u8, text);
        }
        copied_options.root_path = try arena.dupe(u8, copied_options.root_path);
        self.pump = try pump.Pump.create(gpa, io, runtime, copied_options, .{
            .context = self,
            .activate = activate,
            .attached = attached,
            .failure = failure,
            .deactivate = deactivate,
            .request = request,
        });
        return self;
    }

    /// Starts real transport and waits for checked startup on the owned runtime lane.
    /// ActivationFailed retains the exact native cause in activationError.
    pub fn start(self: *NativeAdapter) StartError!void {
        if (self.pump.onLane()) return error.Reentrant;
        if (self.closing.load(.acquire)) return error.Closed;
        if (self.started.swap(true, .acq_rel)) return error.AlreadyStarted;
        self.pump.start() catch |err| {
            self.start_failed.store(true, .release);
            return err;
        };
    }

    /// Captures the attachment generation before the host prepares a delta.
    pub fn updateTicket(self: *const NativeAdapter) UpdateTicket {
        return .{ .attachment = self.attachment.load(.acquire) };
    }

    /// Current native attachment/tree state, never an offline fake-active state.
    pub fn activationStatus(self: *const NativeAdapter) ActivationStatus {
        return self.status.load(.acquire);
    }

    /// An actual attached transport AND materialized tree; Pending remains false.
    pub fn isActive(self: *const NativeAdapter) bool {
        return self.activationStatus() == .active;
    }

    /// Exact remote startup error name after failed start, borrowed until destroy.
    /// Null means no failed start/name. No active mutable diagnostic is exposed.
    pub fn startupErrorName(self: *const NativeAdapter) ?[]const u8 {
        if (!self.start_failed.load(.acquire)) return null;
        return self.pump.lastRemoteErrorName();
    }

    /// Exact last remote name after close's callback/task barrier, borrowed until destroy.
    /// Calling before close is a programmer error; active diagnostics belong to their lane.
    pub fn remoteErrorNameAfterClose(self: *const NativeAdapter) ?[]const u8 {
        std.debug.assert(self.closed.load(.acquire));
        return self.pump.lastRemoteErrorName();
    }

    pub fn activationError(self: *const NativeAdapter) ?ActivationError {
        return loadedError(ActivationError, &self.activation_error);
    }

    pub fn transportError(self: *const NativeAdapter) ?bus.Error {
        return loadedError(bus.Error, &self.transport_error);
    }

    pub fn actionError(self: *const NativeAdapter) ?CallbackError {
        return loadedError(CallbackError, &self.action_error);
    }

    /// Last exact codec/writer failure producing a dispatch reply; null until failure.
    pub fn dispatchError(self: *const NativeAdapter) ?bus.Error {
        return loadedError(bus.Error, &self.dispatch_error);
    }

    /// First typed teardown notification failure, retained until destroy.
    pub fn closeError(self: *const NativeAdapter) ?NotificationError {
        return loadedError(NotificationError, &self.close_error);
    }

    /// Invokes factory only when attached, on the callback lane, and waits for its outcome.
    /// The factory's userdata and borrowed metadata remain valid until this call returns.
    pub fn updateIfActive(
        self: *NativeAdapter,
        factory: UpdateFactory,
        context: ?*anyopaque,
    ) UpdateOutcome {
        var operation: Operation = .{
            .adapter = self,
            .command = .{ .factory = .{ .callback = factory, .context = context } },
        };
        return self.submit(&operation);
    }

    /// Borrows both preflighted headers, nodes and toolkit bytes only through return.
    /// Source pins must not block callbacks on this adapter's owned lane. No source storage
    /// is deinitialized. Pending/first-new-epoch publication uses options.current_full;
    /// otherwise options.delta. Only committed advances the accepted borrowed publication epoch.
    pub fn updateIfActiveBorrowedChecked(
        self: *NativeAdapter,
        options: BorrowedUpdateOptions,
    ) UpdateOutcome {
        var operation: Operation = .{
            .adapter = self,
            .command = .{ .borrowed = .{
                .delta = options.delta,
                .current_full = options.current_full,
            } },
        };
        return self.submit(&operation);
    }

    /// Consumes update on every path. Stale tickets reject without touching the baseline.
    /// Node-entry arrays must use this adapter's allocator; node properties own theirs.
    pub fn update(self: *NativeAdapter, ticket: UpdateTicket, update_value: schema.TreeUpdate) UpdateOutcome {
        var operation: Operation = .{
            .adapter = self,
            .command = .{ .update = .{ .ticket = ticket, .value = update_value } },
        };
        return self.submit(&operation);
    }

    /// Records focus even while inactive. Active focus commits and delivery failures are distinct.
    pub fn updateWindowFocusState(self: *NativeAdapter, focused: bool) UpdateOutcome {
        var operation: Operation = .{ .adapter = self, .command = .{ .focus = focused } };
        return self.submit(&operation);
    }

    /// Records window geometry on the owner lane, including while inactive.
    pub fn setRootWindowBounds(self: *NativeAdapter, outer: schema.Rect, inner: schema.Rect) UpdateOutcome {
        var operation: Operation = .{
            .adapter = self,
            .command = .{ .bounds = .{ .outer = outer, .inner = inner } },
        };
        return self.submit(&operation);
    }

    /// C callback bridge, called only from this adapter's activation/factory lane.
    /// Consumes the handle on success/error; retained C metadata is reaped after the attempt.
    pub fn consumeC(self: *NativeAdapter, handle: *boundary.CTreeUpdate) error{OutOfMemory}!schema.TreeUpdate {
        std.debug.assert(self.pump.onLane());
        return self.c_metadata.consume(self.gpa, handle, self.tree());
    }

    /// Stops new operations, settles/rejects accepted work and joins callbacks/tasks.
    /// A callback's self-close returns Reentrant without changing admission.
    /// Concurrent external closers all wait for the same callback/task barrier.
    /// Start and destroy require exclusive administrative ownership.
    pub fn close(self: *NativeAdapter) error{Reentrant}!void {
        if (self.pump.onLane()) return error.Reentrant;
        self.close_mutex.lockUncancelable(self.io);
        defer self.close_mutex.unlock(self.io);
        if (self.closed.load(.acquire)) return;
        self.closing.store(true, .release);
        if (self.started.load(.acquire)) {
            var operation: Operation = .{ .adapter = self, .command = .teardown };
            self.pump.submit(operation.work()) catch |err| {
                switch (err) {
                    error.Reentrant => return error.Reentrant,
                    error.Closed, error.Canceled => {},
                }
            };
            switch (operation.outcome) {
                .committed => |completed| {
                    if (completed.notification_error) |err| {
                        self.close_error.store(@intFromError(err), .release);
                    }
                },
                .inactive, .rejected => {},
            }
        }
        try self.pump.close();
        self.status.store(.closed, .release);
        self.closed.store(true, .release);
    }

    /// Releases the closed owner exactly once. Runtime/io/user data are not released here.
    pub fn destroy(self: *NativeAdapter) void {
        std.debug.assert(self.closed.load(.acquire));
        self.pump.destroy();
        self.register.deinit();
        self.platform.deinit();
        self.metadata.deinit();
        self.c_metadata.deinit();
        self.app.deinit();
        self.options_arena.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    fn submit(self: *NativeAdapter, operation: *Operation) UpdateOutcome {
        defer operation.discard();
        if (self.closing.load(.acquire)) return .{ .rejected = error.Closed };
        if (!self.started.load(.acquire)) return .{ .rejected = error.NotStarted };
        self.pump.submit(operation.work()) catch |err| return .{ .rejected = err };
        return operation.outcome;
    }

    fn tree(self: *NativeAdapter) ?*const consumer.tree.Tree {
        return if (self.platform.tree) |*held| held else null;
    }

    fn applyLoan(
        self: *NativeAdapter,
        connection: *bus.Bus,
        loan: ActivationSnapshot,
    ) UpdateOutcome {
        defer loan.release(loan.release_context);
        var outcome = applyPrepared(.borrowed, self, connection, loan.update.*);
        if (outcome == .committed) outcome.committed.used_full_tree = true;
        return outcome;
    }

    fn applyOwned(self: *NativeAdapter, connection: *bus.Bus, incoming: schema.TreeUpdate) UpdateOutcome {
        return applyPrepared(.owned, self, connection, incoming);
    }

    fn applyFactoryUpdate(
        self: *NativeAdapter,
        connection: *bus.Bus,
        incoming: FactoryUpdate,
    ) UpdateOutcome {
        // An empty consumer already validates complete initial input. Only active
        // full admission needs this incoming-only set to forbid borrowing old nodes.
        if (incoming.kind == .full and self.platform.hasTree()) {
            validateFullIds(self.gpa, &incoming.update) catch |err| {
                var rejected = incoming.update;
                rejected.deinit(self.gpa);
                self.c_metadata.reap(self.tree());
                return .{ .rejected = err };
            };
        }
        var outcome = self.applyOwned(connection, incoming.update);
        if (outcome == .committed) outcome.committed.used_full_tree = incoming.kind == .full;
        return outcome;
    }

    fn applyPrepared(
        comptime ownership: enum { owned, borrowed },
        self: *NativeAdapter,
        connection: *bus.Bus,
        incoming: schema.TreeUpdate,
    ) UpdateOutcome {
        defer self.metadata.reap(self.tree());
        defer self.c_metadata.reap(self.tree());
        const captured = if (ownership == .borrowed)
            self.metadata.captureBorrowed(&incoming, self.tree()) catch |err| {
                return .{ .rejected = err };
            }
        else if (self.cRetainsMetadata(incoming.tree))
            normalizeEmptyMetadata(incoming)
        else
            self.metadata.capture(incoming, self.tree()) catch |err| {
                return .{ .rejected = err };
            };
        var pending_update: ?schema.TreeUpdate = if (ownership == .owned) captured else null;
        defer if (pending_update) |*value| value.deinit(self.gpa);
        var prepared_metadata: ?app_context.PreparedToolkitMetadata = null;
        defer if (prepared_metadata) |*value| value.deinit(self.gpa);
        const prospective_info: ?schema.TreeInfo = if (captured.tree != null and
            (captured.tree_id.eql(tree_id_root) or self.platform.tree == null))
            captured.tree
        else if (self.tree()) |held|
            held.state.info
        else
            null;
        if (prospective_info) |info| {
            if (self.node_context == null or self.app.adapters.items.len == 0) {
                self.app.reserveAdapter() catch |err| return .{ .rejected = err };
            }
            prepared_metadata = self.app.prepareToolkitMetadata(
                info.toolkit_name orelse "AccessKit",
                if (info.toolkit_name != null) info.toolkit_version else null,
            ) catch |err| return .{ .rejected = err };
        }
        // Owned input is consumed on every core result; loan input is never freed.
        // Preparation failure publishes neither metadata nor a registry entry.
        pending_update = null;
        if (ownership == .owned) {
            self.platform.apply(captured) catch |err| return .{ .rejected = err };
        } else {
            self.platform.applyBorrowed(&captured) catch |err| return .{ .rejected = err };
        }
        std.debug.assert(prospective_info != null);
        if (prepared_metadata) |value| self.app.commitToolkitMetadata(value);
        prepared_metadata = null;
        self.refreshContext();
        var first: ?NotificationError = self.platform.last_event_error;
        const delivery_error: ?NotificationError = if (self.prepareNotifications()) |_|
            self.emitEvents(connection)
        else |err|
            err;
        if (first == null) first = delivery_error;
        if (self.cycle_attached) self.status.store(.active, .release);
        return .{ .committed = .{
            .attachment = self.attachment.load(.acquire),
            .notification_error = first,
        } };
    }

    fn refreshContext(self: *NativeAdapter) void {
        const held = &self.platform.tree.?;
        const newly_registered = self.node_context == null;
        self.node_context = .{
            .state = &held.state,
            .app = &self.app,
            .bounds = self.platform.bounds,
            .sink = null,
            .gpa = self.gpa,
        };
        self.platform.context = &self.node_context.?;
        if (newly_registered or self.app.adapters.items.len == 0) {
            self.app.pushAdapterAssumeCapacity(self.platform.id, &self.node_context.?);
        }
    }

    fn cRetainsMetadata(self: *const NativeAdapter, info: ?schema.TreeInfo) bool {
        const value = info orelse return false;
        for (self.c_metadata.owners) |slot| {
            const owner = slot orelse continue;
            if (MetadataOwners.matchesOwner(
                value,
                owner.toolkit_name_storage,
                owner.toolkit_version_storage,
            )) return true;
        }
        return false;
    }

    fn prepareNotifications(self: *NativeAdapter) NotificationError!void {
        self.register.sync() catch |err| {
            self.registration_pending = true;
            return err;
        };
        if (self.registration_pending) try self.reconcileDeferredEvents();
        self.register.clearChanges();
        self.registration_pending = false;
    }

    fn registeredEntry(
        self: *const NativeAdapter,
        id: object_id.ObjectId,
    ) ?objects.Entry {
        var buffer: [128]u8 = undefined;
        const path: []const u8 = switch (id) {
            .root => object_id.root_path,
            .cache => object_id.cache_path,
            // The prefix, usize decimal and u128 decimal fit this fixed buffer.
            .node => |pair| std.fmt.bufPrint(&buffer, "{s}{d}/{d}", .{
                object_id.accessible_path_prefix,
                pair.adapter,
                object_id.nodeSegment(pair.node),
            }) catch unreachable,
        };
        return self.register.lookup(path);
    }

    fn reconcileDeferredEvents(self: *NativeAdapter) NotificationError!void {
        const items = self.platform.raised.items.items;
        const event_count_max = items.len;
        self.platform.added_nodes.clearRetainingCapacity();
        try self.platform.added_nodes.ensureTotalCapacity(
            self.gpa,
            @intCast(@min(event_count_max, self.register.paths.count())),
        );
        // Refresh before compacting: failure must leave one owner for every
        // queued payload, even after earlier snapshots were refreshed.
        for (items[0..event_count_max]) |*event| {
            if (event.cache_item) |cache| {
                const entry = self.registeredEntry(.{ .node = .{
                    .adapter = cache.adapter_id,
                    .node = cache.id,
                } }) orelse continue;
                const seen = self.platform.added_nodes.getOrPutAssumeCapacity(cache.id);
                if (seen.found_existing) continue;
                const refreshed = try entry.node.?.cacheNode();
                event.cache_item.?.deinit(self.gpa);
                event.cache_item = refreshed;
            }
        }
        self.platform.added_nodes.clearRetainingCapacity();
        var retained: usize = 0;
        for (items[0..event_count_max]) |*event| {
            var keep = true;
            if (event.cache_item) |cache| {
                keep = self.registeredEntry(.{ .node = .{
                    .adapter = cache.adapter_id,
                    .node = cache.id,
                } }) != null;
                if (keep) {
                    const seen = self.platform.added_nodes.getOrPutAssumeCapacity(cache.id);
                    keep = !seen.found_existing;
                }
            } else {
                const removal = std.mem.eql(u8, event.member, events.member_remove_accessible) or
                    (std.mem.eql(u8, event.member, "ChildrenChanged") and
                        std.mem.eql(u8, event.detail1, "remove")) or
                    (std.mem.eql(u8, event.member, "StateChanged") and
                        std.mem.eql(u8, event.detail1, "defunct"));
                if (!removal) {
                    keep = self.registeredEntry(event.id) != null;
                    if (keep and event.any_data == .address) {
                        keep = self.registeredEntry(event.any_data.address) != null;
                    }
                }
            }
            if (keep) {
                items[retained] = event.*;
                retained += 1;
            } else {
                event.deinit(self.gpa);
            }
        }
        self.platform.raised.items.items.len = retained;
    }

    fn announceTerminalRemoval(self: *NativeAdapter) void {
        const root_registered = self.registeredEntry(self.platform.objectId(
            self.platform.tree.?.stateOf().root().id(),
        )) != null;
        if (self.registration_pending) {
            // Close cannot wait for capacity or publish deferred adds.
            self.platform.raised.deinit(self.gpa);
            self.platform.raised = events.EventQueue.empty();
            self.registration_pending = false;
        }
        if (root_registered) self.platform.announceRemoval();
    }

    fn emitEvents(self: *NativeAdapter, connection: *bus.Bus) ?NotificationError {
        std.debug.assert(!self.registration_pending);
        var first: ?NotificationError = null;
        const name = connection.uniqueName() orelse {
            for (self.platform.raised.items.items) |*event| event.deinit(self.gpa);
            self.platform.raised.items.clearRetainingCapacity();
            return error.Disconnected;
        };
        for (self.platform.raised.items.items) |*event| {
            defer event.deinit(self.gpa);
            var signal = OwnedSignal.init(
                self.gpa,
                &self.app,
                name,
                event.*,
                self.register.limits,
            ) catch |err| {
                if (first == null) first = err;
                continue;
            };
            defer signal.deinit();
            connection.send(signal.message, &signal.body) catch |err| {
                if (first == null) first = err;
            };
        }
        self.platform.raised.items.clearRetainingCapacity();
        return first;
    }

    fn fromContext(context: *anyopaque) *NativeAdapter {
        return @ptrCast(@alignCast(context));
    }

    fn activate(context: *anyopaque, connection: *bus.Bus) bus.Error!void {
        const self = fromContext(context);
        std.debug.assert(self.pump.onLane());
        self.cycle_open = true;
        self.cycle_attached = false;
        self.status.store(.pending, .release);
        const old_attachment = self.attachment.load(.acquire);
        if (old_attachment == std.math.maxInt(u64)) {
            self.activation_error.store(@intFromError(error.AttachmentExhausted), .release);
            return error.ActivationFailed;
        }
        self.attachment.store(old_attachment + 1, .release);
        self.activation_error.store(0, .release);
        self.register.bus_name = connection.uniqueName() orelse return error.Disconnected;
        self.register.desktop = .{};
        const initial = self.callbacks.activation(self.callbacks.context) catch |err| {
            self.activation_error.store(@intFromError(err), .release);
            self.completeActivation(.{ .rejected = err });
            return error.ActivationFailed;
        };
        const outcome: UpdateOutcome = if (initial) |loan|
            self.applyLoan(connection, loan)
        else
            .inactive;
        self.completeActivation(outcome);
        switch (outcome) {
            .rejected => |err| {
                self.activation_error.store(@intFromError(err), .release);
                return error.ActivationFailed;
            },
            .committed => |result| {
                if (result.notification_error) |err| {
                    self.activation_error.store(@intFromError(err), .release);
                }
            },
            .inactive => {},
        }
    }

    fn completeActivation(self: *NativeAdapter, outcome: UpdateOutcome) void {
        if (self.callbacks.activation_completed) |callback| {
            callback(self.callbacks.context, outcome);
        }
    }

    fn attached(context: *anyopaque, connection: *bus.Bus) void {
        const self = fromContext(context);
        self.cycle_attached = true;
        const desktop = connection.desktopReference() orelse {
            self.transport_error.store(@intFromError(error.InvalidReply), .release);
            return;
        };
        self.register.desktop = .{ .bus_name = desktop.bus_name, .path = desktop.path };
        self.status.store(if (self.platform.hasTree()) .active else .pending, .release);
    }

    fn deactivate(context: *anyopaque, cause: ?bus.Error) void {
        const self = fromContext(context);
        if (cause) |err| self.transport_error.store(@intFromError(err), .release);
        self.releaseCycle();
    }

    fn releaseCycle(self: *NativeAdapter) void {
        const had_callback = self.cycle_open;
        self.cycle_open = false;
        self.cycle_attached = false;
        self.registration_pending = false;
        self.register.reset();
        self.register.bus_name = "";
        self.register.desktop = .{};
        self.app.removeAdapter(self.platform.id);
        const saved_id = self.platform.id;
        const saved_focus = self.platform.is_host_focused;
        const saved_bounds = self.platform.bounds;
        self.platform.deinit();
        self.platform = PlatformAdapter.init(self.gpa, saved_id, saved_focus);
        self.platform.bounds = saved_bounds;
        self.platform.app = &self.app;
        self.node_context = null;
        self.metadata.reap(null);
        self.c_metadata.reap(null);
        self.status.store(.inactive, .release);
        if (had_callback) self.callbacks.deactivation(self.callbacks.context);
    }

    fn failure(context: *anyopaque, cause: bus.Error) void {
        const self = fromContext(context);
        self.transport_error.store(@intFromError(cause), .release);
        if (self.cycle_open) self.releaseCycle();
    }
    fn request(
        context: *anyopaque,
        connection: *bus.Bus,
        message: dbus.Message,
    ) bus.Error!dbus.OwnedReply {
        const self = fromContext(context);
        var prepared = self.prepareRequest(message) catch |err| {
            self.dispatch_error.store(@intFromError(err), .release);
            return err;
        };
        errdefer prepared.reply.deinit();
        defer if (prepared.signal) |*signal| signal.deinit();
        if (prepared.signal) |*signal| {
            connection.send(signal.message, &signal.body) catch |err| {
                self.dispatch_error.store(@intFromError(err), .release);
                return err;
            };
        }
        return prepared.reply;
    }

    const PreparedRequest = struct {
        reply: dbus.OwnedReply,
        signal: ?OwnedSignal = null,

        fn deinit(self: *PreparedRequest) void {
            self.reply.deinit();
            if (self.signal) |*signal| signal.deinit();
            self.* = undefined;
        }
    };

    /// Dispatch completes query/action scopes before actual getter readback or signal work.
    fn prepareRequest(self: *NativeAdapter, message: dbus.Message) bus.Error!PreparedRequest {
        var reply = try dispatch.handle(self.gpa, &self.register, message);
        errdefer reply.deinit();
        if (reply.error_name != null or !emitsPropertiesChanged(message)) {
            return .{ .reply = reply };
        }
        var getter_message = message;
        getter_message.member = "Get";
        getter_message.signature = "ss";
        getter_message.body = message.body[0..2];
        var readback = try dispatch.handle(self.gpa, &self.register, getter_message);
        if (readback.error_name != null) {
            reply.deinit();
            return .{ .reply = readback };
        }
        defer readback.deinit();
        if (readback.body.values.len != 1 or readback.body.values[0] != .variant) {
            return error.InvalidHeader;
        }
        var body = try dispatch.propertiesChangedBody(
            self.gpa,
            message.body[0].string,
            message.body[1].string,
            readback.body.values[0],
            self.register.limits,
        );
        errdefer body.deinit();
        const path = try body.arena.allocator().dupe(u8, message.path orelse return error.InvalidHeader);
        return .{
            .reply = reply,
            .signal = .{
                .message = .{
                    .kind = .signal,
                    .path = path,
                    .interface = "org.freedesktop.DBus.Properties",
                    .member = "PropertiesChanged",
                    .signature = body.signature,
                },
                .body = body,
            },
        };
    }

    fn emitsPropertiesChanged(message: dbus.Message) bool {
        if (message.kind != .method_call or message.body.len != 3 or
            message.interface == null or message.member == null or
            !std.mem.eql(u8, message.interface.?, "org.freedesktop.DBus.Properties") or
            !std.mem.eql(u8, message.member.?, "Set") or
            message.body[0] != .string or message.body[1] != .string) return false;
        const interface_name = message.body[0].string;
        const property_name = message.body[1].string;
        return (std.mem.eql(u8, interface_name, "org.a11y.atspi.Application") and
            std.mem.eql(u8, property_name, "Id")) or
            (std.mem.eql(u8, interface_name, "org.a11y.atspi.Value") and
                std.mem.eql(u8, property_name, "CurrentValue"));
    }

    fn deliverAction(context: ?*anyopaque, request_value: schema.ActionRequest) objects.ActionDeliveryError!void {
        const self = fromContext(context.?);
        var owned = request_value;
        defer owned.deinit(self.gpa);
        if (self.closing.load(.acquire)) return error.Closed;
        std.debug.assert(self.pump.onLane());
        self.callbacks.action(self.callbacks.context, &owned) catch |err| {
            self.action_error.store(@intFromError(err), .release);
            return err;
        };
    }

    fn deliverEditableText(
        context: ?*anyopaque,
        request_value: *const EditableTextRequest,
    ) objects.ActionDeliveryError!bool {
        const self = fromContext(context.?);
        if (self.closing.load(.acquire)) return error.Closed;
        std.debug.assert(self.pump.onLane());
        const accepted = self.callbacks.editable_text.?(self.callbacks.context, request_value) catch |err| {
            self.action_error.store(@intFromError(err), .release);
            return err;
        };
        if (!accepted) {
            self.action_error.store(@intFromError(error.CallbackFailed), .release);
            return error.CallbackFailed;
        }
        return true;
    }
};

const Operation = struct {
    adapter: *NativeAdapter,
    command: union(enum) {
        factory: struct { callback: UpdateFactory, context: ?*anyopaque },
        update: struct { ticket: UpdateTicket, value: ?schema.TreeUpdate },
        borrowed: struct { delta: *const schema.TreeUpdate, current_full: *const schema.TreeUpdate },
        focus: bool,
        bounds: struct { outer: schema.Rect, inner: schema.Rect },
        teardown,
    },
    outcome: UpdateOutcome = .{ .rejected = error.NotStarted },

    fn work(self: *Operation) pump.Work {
        return .{ .context = self, .execute = execute, .reject = reject };
    }

    fn discard(self: *Operation) void {
        if (self.command == .update) {
            if (self.command.update.value) |*value| value.deinit(self.adapter.gpa);
            self.command.update.value = null;
        }
    }

    fn execute(context: *anyopaque, connection: *bus.Bus) void {
        const self: *Operation = @ptrCast(@alignCast(context));
        const adapter = self.adapter;
        if (self.command == .teardown) {
            if (adapter.platform.hasTree() and connection.isActive()) {
                adapter.announceTerminalRemoval();
                const emitted = adapter.emitEvents(connection);
                const first: ?NotificationError = if (adapter.platform.last_event_error) |err|
                    err
                else
                    emitted;
                self.outcome = .{ .committed = .{
                    .attachment = adapter.attachment.load(.acquire),
                    .notification_error = first,
                } };
            }
            adapter.releaseCycle();
            return;
        }
        if (adapter.closing.load(.acquire)) {
            self.outcome = .{ .rejected = error.Closed };
            self.discard();
            return;
        }
        switch (self.command) {
            .factory => |factory| {
                if (adapter.activationStatus() == .inactive) {
                    self.outcome = .inactive;
                    return;
                }
                const produced = factory.callback(adapter.gpa, factory.context, .{
                    .attachment = adapter.attachment.load(.acquire),
                    .requires_full_tree = !adapter.platform.hasTree(),
                }) catch |err| {
                    self.outcome = .{ .rejected = err };
                    return;
                };
                self.outcome = if (produced) |value|
                    adapter.applyFactoryUpdate(connection, value)
                else
                    .inactive;
            },
            .update => |*incoming| {
                if (!incoming.ticket.matches(adapter.attachment.load(.acquire))) {
                    self.outcome = .{ .rejected = error.StaleAttachment };
                    self.discard();
                    return;
                }
                if (adapter.activationStatus() == .inactive) {
                    self.outcome = .inactive;
                    self.discard();
                    return;
                }
                const value = incoming.value.?;
                incoming.value = null;
                self.outcome = adapter.applyOwned(connection, value);
            },
            .focus => |focused| {
                adapter.platform.updateWindowFocusState(focused) catch |err| {
                    self.outcome = .{ .rejected = err };
                    return;
                };
                if (adapter.node_context) |*node_context| {
                    node_context.state = &adapter.platform.tree.?.state;
                }
                const emitted: ?NotificationError = if (connection.isActive())
                    if (adapter.registration_pending)
                        if (adapter.prepareNotifications()) |_|
                            adapter.emitEvents(connection)
                        else |err|
                            err
                    else
                        adapter.emitEvents(connection)
                else
                    null;
                self.outcome = .{ .committed = .{
                    .attachment = adapter.attachment.load(.acquire),
                    .notification_error = if (adapter.platform.last_event_error) |err| err else emitted,
                } };
            },
            .borrowed => |publication| {
                if (adapter.activationStatus() == .inactive) {
                    self.outcome = .inactive;
                    return;
                }
                const epoch = adapter.attachment.load(.acquire);
                const use_full = !adapter.platform.hasTree() or
                    epoch != adapter.last_borrowed_committed_epoch;
                const incoming = if (use_full) publication.current_full else publication.delta;
                if (use_full and adapter.platform.hasTree()) {
                    validateFullIds(adapter.gpa, incoming) catch |err| {
                        self.outcome = .{ .rejected = err };
                        return;
                    };
                }
                self.outcome = NativeAdapter.applyPrepared(.borrowed, adapter, connection, incoming.*);
                if (self.outcome == .committed) {
                    self.outcome.committed.used_full_tree = use_full;
                    adapter.last_borrowed_committed_epoch = epoch;
                }
            },
            .bounds => |bounds| {
                adapter.platform.setRootWindowBounds(bounds.outer, bounds.inner);
                if (adapter.node_context) |*node_context| {
                    node_context.bounds = adapter.platform.bounds;
                }
                self.outcome = .{ .committed = .{
                    .attachment = adapter.attachment.load(.acquire),
                } };
            },
            // The teardown guard releases the cycle and returns before this switch.
            .teardown => unreachable,
        }
    }

    fn reject(context: *anyopaque, reason: pump.RejectReason) void {
        const self: *Operation = @ptrCast(@alignCast(context));
        self.outcome = .{ .rejected = switch (reason) {
            .closed => error.Closed,
            .canceled => error.Canceled,
        } };
        self.discard();
    }
};

fn loadedError(comptime ErrorSet: type, value: *const std.atomic.Value(u32)) ?ErrorSet {
    const code = value.load(.acquire);
    if (code == 0) return null;
    return @errorCast(@errorFromInt(@as(u16, @intCast(code))));
}

fn validMachineId(value: []const u8) bool {
    if (value.len != 32) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

fn readMachineId(io: std.Io, supplied: ?[]const u8) (std.Io.Dir.ReadFileError || error{InvalidMachineId})![32]u8 {
    var buffer: [128]u8 = undefined;
    const bytes = if (supplied) |text| text else blk: {
        const contents = std.Io.Dir.cwd().readFile(io, "/var/lib/dbus/machine-id", &buffer) catch
            try std.Io.Dir.cwd().readFile(io, "/etc/machine-id", &buffer);
        break :blk contents;
    };
    const trimmed = std.mem.trim(u8, bytes, " \t\r\n");
    if (!validMachineId(trimmed)) return error.InvalidMachineId;
    var result: [32]u8 = undefined;
    for (trimmed, 0..) |byte, index| result[index] = std.ascii.toLower(byte);
    return result;
}

/// Owns toolkit bytes referenced by the committed/working tree plus one incoming update.
/// Node storage is consumed on every capture path. Reap after every attempted update.
const MetadataOwners = struct {
    gpa: std.mem.Allocator,
    owners: [3]?Pair = .{ null, null, null },

    const Pair = struct {
        name: ?[]u8 = null,
        version: ?[]u8 = null,

        fn deinit(gpa: std.mem.Allocator, self: Pair) void {
            if (self.name) |text| gpa.free(text);
            if (self.version) |text| gpa.free(text);
        }
    };

    fn init(gpa: std.mem.Allocator) MetadataOwners {
        return .{ .gpa = gpa };
    }

    fn capture(
        self: *MetadataOwners,
        input: schema.TreeUpdate,
        tree: ?*const consumer.tree.Tree,
    ) error{OutOfMemory}!schema.TreeUpdate {
        var owned = input;
        errdefer owned.deinit(self.gpa);
        return self.captureBorrowed(&owned, tree);
    }

    /// Copies/retains only metadata. The returned header BORROWS nodes and their array;
    /// it must never be deinitialized unless the caller already owned the input storage.
    fn captureBorrowed(
        self: *MetadataOwners,
        input: *const schema.TreeUpdate,
        tree: ?*const consumer.tree.Tree,
    ) error{OutOfMemory}!schema.TreeUpdate {
        self.reap(tree);
        var owned = input.*;
        const info = input.tree orelse return owned;
        for (self.owners) |slot| {
            const retained = slot orelse continue;
            if (matchesOwner(info, retained.name, retained.version)) {
                return normalizeEmptyMetadata(owned);
            }
        }
        var pair: Pair = .{};
        errdefer Pair.deinit(self.gpa, pair);
        if (info.toolkit_name) |name| {
            if (name.len == 0) {
                owned.tree.?.toolkit_name = "";
            } else {
                pair.name = try self.gpa.dupe(u8, name);
                owned.tree.?.toolkit_name = pair.name;
            }
        }
        if (info.toolkit_version) |version| {
            if (version.len == 0) {
                owned.tree.?.toolkit_version = "";
            } else {
                pair.version = try self.gpa.dupe(u8, version);
                owned.tree.?.toolkit_version = pair.version;
            }
        }
        if (pair.name == null and pair.version == null) return owned;
        for (&self.owners) |*slot| {
            if (slot.* == null) {
                slot.* = pair;
                return owned;
            }
        }
        unreachable; // Two tree snapshots plus one incoming update fit three slots.
    }

    fn reap(self: *MetadataOwners, tree: ?*const consumer.tree.Tree) void {
        for (&self.owners) |*slot| {
            const pair = slot.* orelse continue;
            if (tree) |held| {
                if (borrows(held.state.info, pair)) continue;
                if (borrows(held.next_state.info, pair)) continue;
            }
            Pair.deinit(self.gpa, pair);
            slot.* = null;
        }
    }

    fn deinit(self: *MetadataOwners) void {
        self.reap(null);
        self.* = .{ .gpa = self.gpa };
    }

    fn borrows(info: schema.TreeInfo, pair: Pair) bool {
        return sameStorage(info.toolkit_name, pair.name) or
            sameStorage(info.toolkit_version, pair.version);
    }

    fn matchesOwner(info: schema.TreeInfo, name: ?[]u8, version: ?[]u8) bool {
        var has_storage = false;
        if (info.toolkit_name) |value| {
            if (value.len != 0) {
                if (!sameStorage(value, name)) return false;
                has_storage = true;
            }
        }
        if (info.toolkit_version) |value| {
            if (value.len != 0) {
                if (!sameStorage(value, version)) return false;
                has_storage = true;
            }
        }
        return has_storage;
    }

    fn sameStorage(view: ?[]const u8, storage: ?[]u8) bool {
        const borrowed = view orelse return false;
        const owned = storage orelse return false;
        return borrowed.ptr == owned.ptr and borrowed.len == owned.len;
    }
};

/// An owned signal survives tree mutation and removal until the synchronous writer settles.
const OwnedSignal = struct {
    message: dbus.Message,
    body: dbus.OwnedBody,

    fn init(
        gpa: std.mem.Allocator,
        app: ?*app_context.AppContext,
        bus_name: []const u8,
        event: events.Event,
        limits: dbus.Limits,
    ) NotificationError!OwnedSignal {
        const arena_owner = try gpa.create(std.heap.ArenaAllocator);
        errdefer gpa.destroy(arena_owner);
        arena_owner.* = .init(gpa);
        errdefer arena_owner.deinit();
        const arena = arena_owner.allocator();
        if (event.properties.entries.items.len > limits.max_values / 4) {
            return error.LimitExceeded;
        }
        const values = try arena.alloc(dbus.Value, if (event.kind == .cache) 1 else 5);
        if (event.kind == .cache) {
            if (std.mem.eql(u8, event.member, events.member_add_accessible)) {
                const snapshot = event.cache_item orelse return error.InvalidCachePayload;
                var context: interfaces.Context = .{
                    .arena = arena,
                    .app = app orelse return error.InvalidCachePayload,
                    .bus_name = bus_name,
                    .limits = limits,
                };
                values[0] = try cache_interface.cacheItem(&context, &snapshot);
            } else {
                if (event.any_data != .address) return error.InvalidCachePayload;
                values[0] = try addressValue(arena, bus_name, event.any_data.address);
            }
        } else {
            values[0] = .{ .string = try copyText(arena, limits, event.detail1) };
            values[1] = .{ .int32 = event.detail2 };
            values[2] = .{ .int32 = event.detail3 };
            const variant = try arena.create(dbus.Variant);
            variant.* = .{
                .signature = event.any_data.signature(),
                .value = try anyDataValue(arena, bus_name, event.any_data, limits),
            };
            values[3] = .{ .variant = variant };
            const entries = try arena.alloc(dbus.Value, event.properties.entries.items.len);
            for (event.properties.entries.items, 0..) |property, index| {
                const pair = try arena.alloc(dbus.Value, 2);
                pair[0] = .{ .string = try copyText(arena, limits, property.key) };
                const property_variant = try arena.create(dbus.Variant);
                property_variant.* = .{
                    .signature = property.value.signature(),
                    .value = switch (property.value) {
                        .text => |text| .{ .string = try copyText(arena, limits, text) },
                        .integer => |value| .{ .int32 = value },
                        .boolean => |value| .{ .boolean = value },
                        .number => |value| .{ .double = value },
                    },
                };
                pair[1] = .{ .variant = property_variant };
                entries[index] = .{ .dict_entry = pair };
            }
            values[4] = .{ .array = .{ .element_signature = "{sv}", .values = entries } };
        }
        const path = try event.id.path(arena);
        return .{
            .message = .{
                .kind = .signal,
                .path = path,
                .interface = event.interface(),
                .member = event.member,
            },
            .body = .{
                .arena = arena_owner,
                .signature = event.bodySignature(),
                .values = values,
            },
        };
    }

    fn deinit(self: *OwnedSignal) void {
        self.body.deinit();
        self.* = undefined;
    }

    fn addressValue(
        arena: std.mem.Allocator,
        bus_name: []const u8,
        id: object_id.ObjectId,
    ) error{OutOfMemory}!dbus.Value {
        const fields = try arena.alloc(dbus.Value, 2);
        fields[0] = .{ .string = try arena.dupe(u8, bus_name) };
        fields[1] = .{ .object_path = try id.path(arena) };
        return .{ .structure = fields };
    }

    fn anyDataValue(
        arena: std.mem.Allocator,
        bus_name: []const u8,
        value: events.AnyData,
        limits: dbus.Limits,
    ) (std.mem.Allocator.Error || error{LimitExceeded})!dbus.Value {
        return switch (value) {
            .none => .{ .int32 = 0 },
            .address => |id| try addressValue(arena, bus_name, id),
            .integer => |integer| .{ .int32 = integer },
            .unsigned_integer => |integer| .{ .uint32 = integer },
            .boolean => |boolean| .{ .boolean = boolean },
            .text => |text| .{ .string = try copyText(arena, limits, text) },
            .number => |number| .{ .double = number },
            .extent => |extent| blk: {
                const fields = try arena.alloc(dbus.Value, 4);
                for (extent, 0..) |integer, index| fields[index] = .{ .int32 = integer };
                break :blk .{ .structure = fields };
            },
        };
    }

    fn copyText(
        arena: std.mem.Allocator,
        limits: dbus.Limits,
        text: []const u8,
    ) (std.mem.Allocator.Error || error{LimitExceeded})![]const u8 {
        if (text.len > limits.max_string_bytes or text.len > limits.max_frame_bytes) {
            return error.LimitExceeded;
        }
        return arena.dupe(u8, text);
    }
};

test "native metadata copied before caller storage changes and rejected update retains baseline" {
    const gpa = std.testing.allocator;
    var metadata = MetadataOwners.init(gpa);
    defer metadata.deinit();
    var platform = PlatformAdapter.init(gpa, 7, false);
    defer platform.deinit();
    var source = [_]u8{ 'T', 'o', 'o', 'l' };
    var initial: schema.TreeUpdate = .{ .tree = schema.TreeInfo.init(.{ .value = 1 }), .focus = .{ .value = 1 } };
    initial.tree.?.toolkit_name = &source;
    try initial.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    const captured = try metadata.capture(initial, null);
    @memset(&source, 'X');
    try platform.apply(captured);
    metadata.reap(&platform.tree.?);
    try std.testing.expectEqualStrings("Tool", platform.tree.?.state.info.toolkit_name.?);
    var rejected: schema.TreeUpdate = .{ .tree = schema.TreeInfo.init(.{ .value = 999 }), .focus = .{ .value = 1 } };
    rejected.tree.?.toolkit_name = "Rejected";
    const incoming = try metadata.capture(rejected, &platform.tree.?);
    if (platform.apply(incoming)) |_| {
        return error.InvalidUpdateAccepted;
    } else |_| {}
    metadata.reap(&platform.tree.?);
    try std.testing.expectEqualStrings("Tool", platform.tree.?.state.info.toolkit_name.?);
}

test "native attachment ticket rejects delta prepared before reattachment" {
    const prepared: UpdateTicket = .{ .attachment = 4 };
    try std.testing.expect(prepared.matches(4));
    try std.testing.expect(!prepared.matches(5));
    try std.testing.expect(!prepared.matches(6));
}

test "native signal ownership preserves text and final properties dictionary" {
    const gpa = std.testing.allocator;
    var text = [_]u8{ 'a', 'b', 'c' };
    const event: events.Event = .{
        .kind = .object,
        .id = .root,
        .member = "TextChanged",
        .detail1 = "insert",
        .detail2 = 2,
        .detail3 = 3,
        .any_data = .{ .text = &text },
    };
    var signal = try OwnedSignal.init(gpa, null, ":1.7", event, .{});
    defer signal.deinit();
    @memset(&text, 'X');
    try std.testing.expectEqualStrings("siiva{sv}", signal.body.signature);
    try std.testing.expectEqual(@as(usize, 5), signal.body.values.len);
    try std.testing.expectEqualStrings("abc", signal.body.values[3].variant.value.string);
    try std.testing.expectEqualStrings("{sv}", signal.body.values[4].array.element_signature);
    try std.testing.expectEqual(@as(usize, 0), signal.body.values[4].array.values.len);
    try std.testing.expect(signal.message.destination == null);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", signal.message.path.?);
}

test "native machine identity validates actual hexadecimal value" {
    const valid = "0123456789abcdef0123456789abcdef";
    try std.testing.expect(validMachineId(valid));
    try std.testing.expect(!validMachineId(valid[0..31]));
    try std.testing.expect(!validMachineId("z123456789abcdef0123456789abcdef"));
}

fn metadataAllocationFailure(gpa: std.mem.Allocator) !void {
    var metadata = MetadataOwners.init(gpa);
    defer metadata.deinit();
    var platform = PlatformAdapter.init(gpa, 7, false);
    defer platform.deinit();
    var initial: schema.TreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    initial.tree.?.toolkit_name = "Toolkit";
    initial.tree.?.toolkit_version = "2.0";
    try initial.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    const captured = try metadata.capture(initial, null);
    platform.apply(captured) catch |failure| {
        try std.testing.expect(platform.tree == null);
        try std.testing.expectEqual(@as(u64, 0), platform.applied_updates);
        return failure;
    };
    metadata.reap(&platform.tree.?);
    try std.testing.expectEqualStrings("Toolkit", platform.tree.?.state.info.toolkit_name.?);
    try std.testing.expectEqualStrings("2.0", platform.tree.?.state.info.toolkit_version.?);
    try std.testing.expectEqual(@as(u64, 1), platform.applied_updates);
    if (platform.last_event_error) |failure| {
        try std.testing.expectEqual(error.OutOfMemory, failure);
        return error.OutOfMemory;
    }
    try ownedMetadataRejectedAllocationCase(gpa);
}

test "native metadata allocator failure consumes incoming update without leaks" {
    const allocation_attempt_bound = 512;
    for (0..allocation_attempt_bound) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        metadataAllocationFailure(failing.allocator()) catch |failure| {
            try std.testing.expectEqual(error.OutOfMemory, failure);
            try std.testing.expect(failing.has_induced_failure);
            try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
            continue;
        };
        try std.testing.expect(!failing.has_induced_failure);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
        return;
    }
    return error.AllocationAttemptBoundExceeded;
}

fn ownedMetadataRejectedAllocationCase(gpa: std.mem.Allocator) !void {
    var adapter: NativeAdapter = undefined;
    adapter.gpa = gpa;
    adapter.platform = PlatformAdapter.init(gpa, 1, false);
    adapter.metadata = MetadataOwners.init(gpa);
    adapter.c_metadata = .{};
    adapter.app = try app_context.AppContext.init(gpa, null);
    adapter.node_context = null;
    defer {
        adapter.platform.deinit();
        adapter.metadata.deinit();
        adapter.c_metadata.deinit();
        adapter.app.deinit();
    }
    var incoming: schema.TreeUpdate = .{
        .tree_id = .{ .bytes = @splat(1) },
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "RejectedToolkit",
            .toolkit_version = "2",
        },
        .focus = .{ .value = 1 },
    };
    try incoming.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    // An invalid root-tree identity rejects before registration or transport.
    var unread_connection: bus.Bus = undefined;
    const outcome = NativeAdapter.applyPrepared(.owned, &adapter, &unread_connection, incoming);
    try std.testing.expect(outcome == .rejected);
    try std.testing.expect(outcome.rejected == error.OutOfMemory or
        outcome.rejected == error.NotTheRootTree);
    try std.testing.expect(adapter.platform.tree == null);
    try std.testing.expectEqual(@as(u64, 0), adapter.platform.applied_updates);
    try std.testing.expect(adapter.node_context == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.app.adapters.items.len);
    try std.testing.expect(adapter.app.toolkit_name == null);
    for (adapter.metadata.owners) |owner| try std.testing.expect(owner == null);
    if (outcome.rejected == error.OutOfMemory) return error.OutOfMemory;
}

test "native repeated empty metadata does not retain zero length allocation identities" {
    const gpa = std.testing.allocator;
    var metadata = MetadataOwners.init(gpa);
    defer metadata.deinit();
    var platform = PlatformAdapter.init(gpa, 7, false);
    defer platform.deinit();
    var initial: schema.TreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    initial.tree.?.toolkit_name = "";
    initial.tree.?.toolkit_version = "";
    try initial.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    try platform.apply(try metadata.capture(initial, null));
    for (0..8) |_| {
        var update_value: schema.TreeUpdate = .{
            .tree = schema.TreeInfo.init(.{ .value = 1 }),
            .focus = .{ .value = 1 },
        };
        update_value.tree.?.toolkit_name = "";
        update_value.tree.?.toolkit_version = "";
        try platform.apply(try metadata.capture(update_value, &platform.tree.?));
        metadata.reap(&platform.tree.?);
        try std.testing.expectEqualStrings("", platform.tree.?.state.info.toolkit_name.?);
        try std.testing.expectEqualStrings("", platform.tree.?.state.info.toolkit_version.?);
        for (metadata.owners) |owner| try std.testing.expect(owner == null);
    }
}

test "native signal rejects configured string limit before copying oversized payload" {
    const event: events.Event = .{
        .kind = .object,
        .id = .root,
        .member = "TextChanged",
        .detail1 = "insert",
        .any_data = .{ .text = "oversized" },
    };
    try std.testing.expectError(error.LimitExceeded, OwnedSignal.init(
        std.testing.allocator,
        null,
        ":1.7",
        event,
        .{ .max_string_bytes = 8 },
    ));
}

/// Empty metadata never borrows an allocator-specific zero-sized storage identity.
fn normalizeEmptyMetadata(incoming: schema.TreeUpdate) schema.TreeUpdate {
    var owned = incoming;
    if (owned.tree) |info| {
        if (info.toolkit_name) |value| {
            if (value.len == 0) owned.tree.?.toolkit_name = "";
        }
        if (info.toolkit_version) |value| {
            if (value.len == 0) owned.tree.?.toolkit_version = "";
        }
    }
    return owned;
}

test "native retained metadata capture reuses owned storage without copying" {
    const gpa = std.testing.allocator;
    var platform = PlatformAdapter.init(gpa, 9, false);
    var metadata = MetadataOwners.init(gpa);
    defer {
        platform.deinit();
        metadata.deinit();
    }
    var first: schema.TreeUpdate = .{
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "Toolkit",
            .toolkit_version = "1",
        },
        .focus = .{ .value = 1 },
    };
    try first.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    try platform.apply(try metadata.capture(first, null));
    const before = platform.tree.?.state.info;
    var second: schema.TreeUpdate = .{ .tree = before, .focus = .{ .value = 1 } };
    defer second.deinit(gpa);
    second = try metadata.capture(second, &platform.tree.?);
    try std.testing.expectEqual(before.toolkit_name.?.ptr, second.tree.?.toolkit_name.?.ptr);
    try std.testing.expectEqual(before.toolkit_version.?.ptr, second.tree.?.toolkit_version.?.ptr);
}

test "native stale attachment rejection consumes update before touching transport" {
    const gpa = std.testing.allocator;
    var adapter: NativeAdapter = undefined;
    adapter.gpa = gpa;
    adapter.attachment = .init(4);
    adapter.closing = .init(false);
    var value: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    try value.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    var operation: Operation = .{
        .adapter = &adapter,
        .command = .{ .update = .{ .ticket = .{ .attachment = 3 }, .value = value } },
    };
    // The stale branch must never inspect a connection or the materialized tree.
    var unread_connection: bus.Bus = undefined;
    Operation.execute(&operation, &unread_connection);
    try std.testing.expect(operation.outcome == .rejected);
    try std.testing.expect(operation.outcome.rejected == error.StaleAttachment);
    try std.testing.expect(operation.command.update.value == null);
    operation.discard();
}

test "native canceled accepted update releases its payload exactly once" {
    const gpa = std.testing.allocator;
    var adapter: NativeAdapter = undefined;
    adapter.gpa = gpa;
    var value: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    try value.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    var operation: Operation = .{
        .adapter = &adapter,
        .command = .{ .update = .{ .ticket = .{ .attachment = 3 }, .value = value } },
    };
    Operation.reject(&operation, .canceled);
    try std.testing.expect(operation.outcome == .rejected);
    try std.testing.expect(operation.outcome.rejected == error.Canceled);
    try std.testing.expect(operation.command.update.value == null);
    operation.discard();
}

fn rejectedActivationLoanAllocationCase(gpa: std.mem.Allocator) !void {
    const source_gpa = std.testing.allocator;
    var source: schema.TreeUpdate = .{
        .tree_id = .{ .bytes = @splat(1) },
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "LoanToolkit",
            .toolkit_version = "1",
        },
        .focus = .{ .value = 1 },
    };
    defer source.deinit(source_gpa);
    try source.pushNode(source_gpa, .{ .value = 1 }, schema.Node.init(source_gpa, .window));
    const source_entries = source.nodes.items.ptr;
    const ReleaseCounter = struct {
        count: usize = 0,
        const Self = @This();

        fn release(context: ?*anyopaque) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.count += 1;
        }
    };
    var releases: ReleaseCounter = .{};
    var adapter: NativeAdapter = undefined;
    adapter.gpa = gpa;
    adapter.platform = PlatformAdapter.init(gpa, 1, false);
    adapter.metadata = MetadataOwners.init(gpa);
    adapter.c_metadata = .{};
    adapter.app = try app_context.AppContext.init(gpa, null);
    adapter.node_context = null;
    defer {
        adapter.platform.deinit();
        adapter.metadata.deinit();
        adapter.c_metadata.deinit();
        adapter.app.deinit();
    }
    // An invalid root-tree identity rejects before transport or registration sync.
    var unread_connection: bus.Bus = undefined;
    const outcome = adapter.applyLoan(&unread_connection, .{
        .update = &source,
        .release_context = &releases,
        .release = ReleaseCounter.release,
    });
    try std.testing.expectEqual(@as(usize, 1), releases.count);
    try std.testing.expect(outcome == .rejected);
    try std.testing.expect(outcome.rejected == error.OutOfMemory or
        outcome.rejected == error.NotTheRootTree);
    try std.testing.expectEqual(@as(usize, 1), source.nodes.items.len);
    try std.testing.expect(source.nodes.items.ptr == source_entries);
    try std.testing.expectEqual(schema.Role.window, source.nodes.items[0].node.role);
    try std.testing.expectEqualStrings("LoanToolkit", source.tree.?.toolkit_name.?);
    try std.testing.expect(adapter.platform.tree == null);
    try std.testing.expect(adapter.node_context == null);
    try std.testing.expectEqual(@as(usize, 0), adapter.app.adapters.items.len);
    try std.testing.expect(adapter.app.toolkit_name == null);
    for (adapter.metadata.owners) |owner| try std.testing.expect(owner == null);
    if (outcome.rejected == error.OutOfMemory) return error.OutOfMemory;
}

test "native activation loan releases once on every allocation rejection without freeing source" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        rejectedActivationLoanAllocationCase,
        .{},
    );
}

test "native role producer reaches encoded signal as unsigned AT-SPI button role" {
    const gpa = std.testing.allocator;
    var platform = PlatformAdapter.init(gpa, 9, false);
    defer platform.deinit();
    const initial = built: {
        var update: schema.TreeUpdate = .{
            .tree = schema.TreeInfo.init(.{ .value = 1 }),
            .focus = .{ .value = 1 },
        };
        errdefer update.deinit(gpa);
        const root = root_built: {
            var n = schema.Node.init(gpa, .window);
            errdefer n.deinit();
            try schema.ids_props.setChildren(&n.properties, &.{.{ .value = 2 }});
            break :root_built n;
        };
        try update.pushNode(gpa, .{ .value = 1 }, root);
        try update.pushNode(gpa, .{ .value = 2 }, schema.Node.init(gpa, .list_box));
        break :built update;
    };
    try platform.apply(initial);
    platform.raised.deinit(gpa);
    platform.raised = events.EventQueue.empty();
    var delta: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    try delta.pushNode(gpa, .{ .value = 2 }, schema.Node.init(gpa, .button));
    try platform.apply(delta);
    var found = false;
    for (platform.raised.items.items) |event| {
        if (event.kind != .object or
            !std.mem.eql(u8, event.member, "PropertyChange") or
            !std.mem.eql(u8, event.detail1, "accessible-role")) continue;
        try std.testing.expect(!found);
        found = true;
        var signal = try OwnedSignal.init(gpa, null, ":1.7", event, .{});
        defer signal.deinit();
        var message = signal.message;
        message.serial = 1;
        message.signature = signal.body.signature;
        message.body = signal.body.values;
        const bytes = try dbus.encode(gpa, message, .little, .{});
        defer gpa.free(bytes);
        var frame = try dbus.decode(gpa, bytes, .{});
        defer frame.deinit();
        const expected_id: object_id.ObjectId = .{ .node = .{
            .adapter = 9,
            .node = consumer.tree_index.FullNodeId.init(.{ .value = 2 }, .init(0)),
        } };
        const expected_path = try expected_id.path(gpa);
        defer gpa.free(expected_path);
        try std.testing.expect(frame.message.kind == .signal);
        try std.testing.expectEqualStrings("org.a11y.atspi.Event.Object", frame.message.interface.?);
        try std.testing.expectEqualStrings("PropertyChange", frame.message.member.?);
        try std.testing.expectEqualStrings(expected_path, frame.message.path.?);
        try std.testing.expectEqualStrings("siiva{sv}", frame.message.signature);
        try std.testing.expectEqual(@as(usize, 5), frame.message.body.len);
        try std.testing.expectEqualStrings("accessible-role", frame.message.body[0].string);
        const role = frame.message.body[3].variant;
        try std.testing.expectEqualStrings("u", role.signature);
        try std.testing.expectEqual(@as(u32, 43), role.value.uint32);
        try std.testing.expectEqualStrings("{sv}", frame.message.body[4].array.element_signature);
        try std.testing.expectEqual(@as(usize, 0), frame.message.body[4].array.values.len);
    }
    try std.testing.expect(found);
}

/// Same live-object bound as native registration, excluding its root/cache entries.
const max_full_snapshot_nodes: u32 = 65534;

fn validateFullIds(
    gpa: std.mem.Allocator,
    update: *const schema.TreeUpdate,
) (std.mem.Allocator.Error ||
    error{ NoRootTree, RootNotInTree, MissingFullNode, RegisterLimit })!void {
    const info = update.tree orelse return error.NoRootTree;
    if (update.nodes.items.len > max_full_snapshot_nodes) return error.RegisterLimit;
    var ids: std.AutoHashMapUnmanaged(u64, void) = .empty;
    defer ids.deinit(gpa);
    try ids.ensureTotalCapacity(gpa, @intCast(update.nodes.items.len));
    for (update.nodes.items) |entry| ids.putAssumeCapacity(entry.node_id.value, {});
    if (!ids.contains(info.root.value)) return error.RootNotInTree;
    for (update.nodes.items) |entry| {
        for (schema.ids_props.children(&entry.node.properties)) |child| {
            if (!ids.contains(child.value)) return error.MissingFullNode;
        }
    }
}

const PropertyWireFixture = struct {
    native: NativeAdapter,
    context: app_context.NodeContext,
    actions: usize = 0,
    requested_value: ?f64 = null,
    gpa: std.mem.Allocator,

    fn init(self: *PropertyWireFixture, gpa: std.mem.Allocator) !void {
        self.gpa = gpa;
        self.actions = 0;
        self.requested_value = null;
        self.native = undefined;
        self.native.gpa = gpa;
        self.native.app = try app_context.AppContext.init(gpa, null);
        errdefer self.native.app.deinit();
        self.native.platform = PlatformAdapter.init(gpa, 9, false);
        errdefer self.native.platform.deinit();
        const initial = built: {
            var value: schema.TreeUpdate = .{
                .tree = schema.TreeInfo.init(.{ .value = 1 }),
                .focus = .{ .value = 1 },
            };
            errdefer value.deinit(gpa);
            const root = root_built: {
                var n = schema.Node.init(gpa, .window);
                errdefer n.deinit();
                try schema.ids_props.setChildren(&n.properties, &.{.{ .value = 2 }});
                break :root_built n;
            };
            try value.pushNode(gpa, .{ .value = 1 }, root);
            const slider = slider_built: {
                var n = schema.Node.init(gpa, .slider);
                errdefer n.deinit();
                try schema.numbers.setNumericValue(&n.properties, 4.5);
                break :slider_built n;
            };
            try value.pushNode(gpa, .{ .value = 2 }, slider);
            break :built value;
        };
        try self.native.platform.apply(initial);
        self.context = .{
            .state = &self.native.platform.tree.?.state,
            .app = &self.native.app,
            .bounds = .empty,
            .sink = null,
            .gpa = gpa,
        };
        try self.native.app.pushAdapter(9, &self.context);
        self.native.register = objects.Register.init(gpa, &self.native.app);
        errdefer self.native.register.deinit();
        self.native.register.bus_name = ":1.7";
        self.native.register.sink = .{ .context = self, .raise = action };
        try self.native.register.sync();
        self.native.register.clearChanges();
    }

    fn deinit(self: *PropertyWireFixture) void {
        self.native.register.deinit();
        self.native.platform.deinit();
        self.native.app.deinit();
        self.* = undefined;
    }

    fn action(context: ?*anyopaque, request_value: schema.ActionRequest) objects.ActionDeliveryError!void {
        const self: *PropertyWireFixture = @ptrCast(@alignCast(context.?));
        var owned = request_value;
        defer owned.deinit(self.gpa);
        if (owned.action != .set_value or owned.target_node.value != 2 or
            owned.data == null or owned.data.? != .numeric_value) return error.CallbackFailed;
        self.actions += 1;
        self.requested_value = owned.data.?.numeric_value;
    }
};

fn expectPropertiesWire(
    gpa: std.mem.Allocator,
    signal: *const OwnedSignal,
    interface_name: []const u8,
    property_name: []const u8,
    expected: dbus.Value,
) !void {
    var message = signal.message;
    message.serial = 1;
    message.body = signal.body.values;
    message.signature = signal.body.signature;
    const bytes = try dbus.encode(gpa, message, .little, .{});
    defer gpa.free(bytes);
    var frame = try dbus.decode(gpa, bytes, .{});
    defer frame.deinit();
    try std.testing.expect(frame.message.kind == .signal);
    try std.testing.expectEqualStrings("org.freedesktop.DBus.Properties", frame.message.interface.?);
    try std.testing.expectEqualStrings("PropertiesChanged", frame.message.member.?);
    try std.testing.expectEqualStrings("sa{sv}as", frame.message.signature);
    try std.testing.expectEqualStrings(interface_name, frame.message.body[0].string);
    const entries = frame.message.body[1].array;
    try std.testing.expectEqualStrings("{sv}", entries.element_signature);
    try std.testing.expectEqual(@as(usize, 1), entries.values.len);
    const pair = entries.values[0].dict_entry;
    try std.testing.expectEqualStrings(property_name, pair[0].string);
    const value = pair[1].variant;
    switch (expected) {
        .int32 => |integer| {
            try std.testing.expectEqualStrings("i", value.signature);
            try std.testing.expectEqual(integer, value.value.int32);
        },
        .double => |number| {
            try std.testing.expectEqualStrings("d", value.signature);
            try std.testing.expectEqual(number, value.value.double);
        },
        // Both fixture callers pass only int32 or double values.
        else => unreachable,
    }
    try std.testing.expectEqualStrings("s", frame.message.body[2].array.element_signature);
    try std.testing.expectEqual(@as(usize, 0), frame.message.body[2].array.values.len);
}

fn propertiesWireAllocationCase(gpa: std.mem.Allocator) !void {
    var fixture: PropertyWireFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    fixture.native.gpa = gpa;
    const id_variant: dbus.Variant = .{ .signature = "i", .value = .{ .int32 = 42 } };
    const id_args = [_]dbus.Value{
        .{ .string = "org.a11y.atspi.Application" },
        .{ .string = "Id" },
        .{ .variant = &id_variant },
    };
    var id_result = try fixture.native.prepareRequest(.{
        .kind = .method_call,
        .serial = 1,
        .path = "/org/a11y/atspi/accessible/root",
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .body = &id_args,
    });
    defer id_result.deinit();
    try std.testing.expect(id_result.reply.error_name == null);
    try std.testing.expectEqual(@as(?i32, 42), fixture.native.app.id);
    try std.testing.expect(id_result.signal != null);
    try expectPropertiesWire(gpa, &id_result.signal.?, "org.a11y.atspi.Application", "Id", .{ .int32 = 42 });
    const numeric_variant: dbus.Variant = .{ .signature = "d", .value = .{ .double = 9.5 } };
    const numeric_args = [_]dbus.Value{
        .{ .string = "org.a11y.atspi.Value" },
        .{ .string = "CurrentValue" },
        .{ .variant = &numeric_variant },
    };
    const target: object_id.ObjectId = .{ .node = .{
        .adapter = 9,
        .node = consumer.tree_index.FullNodeId.init(.{ .value = 2 }, .init(0)),
    } };
    const path = try target.path(std.testing.allocator);
    defer std.testing.allocator.free(path);
    var numeric_result = try fixture.native.prepareRequest(.{
        .kind = .method_call,
        .serial = 2,
        .flags = 1, // NO_REPLY_EXPECTED does not suppress mutation/readback/signal.
        .path = path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .body = &numeric_args,
    });
    defer numeric_result.deinit();
    try std.testing.expect(numeric_result.reply.error_name == null);
    try std.testing.expectEqual(@as(usize, 1), fixture.actions);
    try std.testing.expectEqual(@as(?f64, 9.5), fixture.requested_value);
    try std.testing.expect(numeric_result.signal != null);
    // The action is delivered but this tree has not accepted a later app update.
    // The real getter returns 4.5, never the requested 9.5 echoed from input.
    try expectPropertiesWire(gpa, &numeric_result.signal.?, "org.a11y.atspi.Value", "CurrentValue", .{ .double = 4.5 });
}

test "native property Set getter signal byte consumer and fail N owned cleanup" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        propertiesWireAllocationCase,
        .{},
    );
}

test "native getter allocation error after delivered action cannot publish Set success" {
    var fixture: PropertyWireFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 1 });
    fixture.native.gpa = failing.allocator();
    const variant: dbus.Variant = .{ .signature = "d", .value = .{ .double = 9.5 } };
    const args = [_]dbus.Value{
        .{ .string = "org.a11y.atspi.Value" },
        .{ .string = "CurrentValue" },
        .{ .variant = &variant },
    };
    const target: object_id.ObjectId = .{ .node = .{
        .adapter = 9,
        .node = consumer.tree_index.FullNodeId.init(.{ .value = 2 }, .init(0)),
    } };
    const path = try target.path(std.testing.allocator);
    defer std.testing.allocator.free(path);
    try std.testing.expectError(error.OutOfMemory, fixture.native.prepareRequest(.{
        .kind = .method_call,
        .serial = 1,
        .path = path,
        .interface = "org.freedesktop.DBus.Properties",
        .member = "Set",
        .signature = "ssv",
        .body = &args,
    }));
    try std.testing.expectEqual(@as(usize, 1), fixture.actions);
    try std.testing.expectEqual(@as(?f64, 9.5), fixture.requested_value);
}

test "native active full admission rejects missing old child without changing metadata baseline" {
    const gpa = std.testing.allocator;
    var adapter: NativeAdapter = undefined;
    adapter.gpa = gpa;
    adapter.platform = PlatformAdapter.init(gpa, 9, false);
    adapter.metadata = MetadataOwners.init(gpa);
    adapter.c_metadata = .{};
    adapter.app = try app_context.AppContext.init(gpa, null);
    defer {
        adapter.platform.deinit();
        adapter.metadata.deinit();
        adapter.c_metadata.deinit();
        adapter.app.deinit();
    }
    const initial = built: {
        var value: schema.TreeUpdate = .{
            .tree = .{
                .root = .{ .value = 1 },
                .toolkit_name = "OldToolkit",
                .toolkit_version = "1",
            },
            .focus = .{ .value = 1 },
        };
        errdefer value.deinit(gpa);
        const root = root_built: {
            var n = schema.Node.init(gpa, .window);
            errdefer n.deinit();
            try schema.ids_props.setChildren(&n.properties, &.{.{ .value = 2 }});
            break :root_built n;
        };
        try value.pushNode(gpa, .{ .value = 1 }, root);
        try value.pushNode(gpa, .{ .value = 2 }, schema.Node.init(gpa, .button));
        break :built value;
    };
    try adapter.platform.apply(try adapter.metadata.capture(initial, null));
    try adapter.app.setToolkitMetadata("OldToolkit", "1");
    const before_info = adapter.platform.tree.?.state.info;
    const before_events = adapter.platform.raised.items.items.len;
    const app_name_pointer = adapter.app.toolkit_name.?.ptr;
    var incomplete: schema.TreeUpdate = .{
        .tree = .{
            .root = .{ .value = 1 },
            .toolkit_name = "NewToolkit",
            .toolkit_version = "2",
        },
        .focus = .{ .value = 1 },
    };
    const missing_root = built: {
        var n = schema.Node.init(gpa, .window);
        errdefer n.deinit();
        try schema.ids_props.setChildren(&n.properties, &.{.{ .value = 2 }});
        break :built n;
    };
    try incomplete.pushNode(gpa, .{ .value = 1 }, missing_root);
    // Node2 exists in baseline but is deliberately omitted from purported FULL input.
    var unread_connection: bus.Bus = undefined;
    const outcome = adapter.applyFactoryUpdate(&unread_connection, .{
        .update = incomplete,
        .kind = .full,
    });
    try std.testing.expect(outcome == .rejected);
    try std.testing.expect(outcome.rejected == error.MissingFullNode);
    try std.testing.expectEqual(@as(usize, 1), adapter.platform.applied_updates);
    try std.testing.expectEqual(before_events, adapter.platform.raised.items.items.len);
    try std.testing.expect(adapter.platform.tree.?.state.info.toolkit_name.?.ptr ==
        before_info.toolkit_name.?.ptr);
    try std.testing.expectEqualStrings("OldToolkit", adapter.platform.tree.?.state.info.toolkit_name.?);
    try std.testing.expect(adapter.app.toolkit_name.?.ptr == app_name_pointer);
    try std.testing.expectEqualStrings("OldToolkit", adapter.app.toolkit_name.?);
}

test "native complete full input validates and consumer accepts required local nodes" {
    var fixture: PropertyWireFixture = undefined;
    try fixture.init(std.testing.allocator);
    defer fixture.deinit();
    const gpa = std.testing.allocator;
    const full = built: {
        var value: schema.TreeUpdate = .{
            .tree = .{
                .root = .{ .value = 1 },
                .toolkit_name = "NewToolkit",
                .toolkit_version = "2",
            },
            .focus = .{ .value = 1 },
        };
        errdefer value.deinit(gpa);
        const root = root_built: {
            var n = schema.Node.init(gpa, .window);
            errdefer n.deinit();
            try schema.ids_props.setChildren(&n.properties, &.{.{ .value = 2 }});
            break :root_built n;
        };
        try value.pushNode(gpa, .{ .value = 1 }, root);
        try value.pushNode(gpa, .{ .value = 2 }, schema.Node.init(gpa, .button));
        break :built value;
    };
    validateFullIds(gpa, &full) catch |err| {
        var rejected = full;
        rejected.deinit(gpa);
        return err;
    };
    try fixture.native.platform.apply(full);
    try std.testing.expectEqual(@as(usize, 2), fixture.native.platform.applied_updates);
    try std.testing.expectEqualStrings("NewToolkit", fixture.native.platform.tree.?.state.info.toolkit_name.?);
    try std.testing.expectEqualStrings("2", fixture.native.platform.tree.?.state.info.toolkit_version.?);
}

test "native registry sync failure commits borrowed tree and withholds owned announcements" {
    // A real registry allocation failure occurs after the borrowed consumer commit.
    // The disconnected transport seam must remain untouched until paths are registered.
    const gpa = std.testing.allocator;
    var native: NativeAdapter = undefined;
    native.gpa = gpa;
    native.platform = PlatformAdapter.init(gpa, 9, false);
    native.metadata = MetadataOwners.init(gpa);
    native.c_metadata = .{};
    native.app = try app_context.AppContext.init(gpa, null);
    native.platform.app = &native.app;
    native.node_context = null;
    native.attachment = .init(1);
    native.cycle_attached = false;
    native.register = objects.Register.init(gpa, &native.app);
    native.registration_pending = false;
    defer {
        native.register.deinit();
        native.platform.deinit();
        native.metadata.deinit();
        native.c_metadata.deinit();
        native.app.deinit();
    }
    var connection: bus.Bus = undefined;
    connection.accessibility = null;
    var initial: schema.TreeUpdate = .{
        .tree = schema.TreeInfo.init(.{ .value = 1 }),
        .focus = .{ .value = 1 },
    };
    defer initial.deinit(gpa);
    try initial.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window));
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    native.register.gpa = failing.allocator();
    const outcome = NativeAdapter.applyPrepared(.borrowed, &native, &connection, initial);
    try std.testing.expect(outcome == .committed);
    try std.testing.expectEqual(error.OutOfMemory, outcome.committed.notification_error.?);
    try std.testing.expectEqual(@as(u64, 1), native.platform.applied_updates);
    try std.testing.expectEqual(@as(usize, 1), native.platform.nodeCount());
    try std.testing.expectEqual(@as(usize, 1), initial.nodes.items.len);
    try std.testing.expectEqual(@as(usize, 0), native.register.paths.count());
    const withheld_count = native.platform.raised.count();
    try std.testing.expectEqual(@as(usize, 2), withheld_count);
    const root_id = native.platform.objectId(native.platform.tree.?.stateOf().root().id());
    const path = try root_id.path(gpa);
    defer gpa.free(path);
    try std.testing.expect(native.register.lookup(path) == null);
    const withheld = native.platform.raised.items.items;
    try std.testing.expectEqualStrings("AddAccessible", withheld[0].member);
    try std.testing.expect(std.meta.eql(object_id.ObjectId.cache, withheld[0].id));
    try std.testing.expect(std.meta.eql(root_id.node.node, withheld[0].cache_item.?.id));
    try std.testing.expectEqual(@as(usize, 9), withheld[0].cache_item.?.adapter_id);
    try std.testing.expectEqualStrings("", withheld[0].cache_item.?.name);
    try std.testing.expectEqualStrings("ChildrenChanged", withheld[1].member);
    try std.testing.expect(std.meta.eql(object_id.ObjectId.root, withheld[1].id));
    try std.testing.expectEqualStrings("add", withheld[1].detail1);
    try std.testing.expectEqual(@as(i32, 0), withheld[1].detail2);
    try std.testing.expect(std.meta.eql(root_id, withheld[1].any_data.address));

    const unchanged: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    native.register.gpa = failing.allocator();
    const repeated = NativeAdapter.applyPrepared(.borrowed, &native, &connection, unchanged);
    try std.testing.expect(repeated == .committed);
    try std.testing.expectEqual(error.OutOfMemory, repeated.committed.notification_error.?);
    try std.testing.expectEqual(withheld_count, native.platform.raised.count());
    try std.testing.expectEqual(@as(u64, 2), native.platform.applied_updates);

    native.register.gpa = gpa;
    try native.prepareNotifications();
    try std.testing.expect(native.register.lookup(path) != null);
    var cache_count: usize = 0;
    for (native.platform.raised.items.items) |event| {
        var signal = try OwnedSignal.init(gpa, &native.app, ":1.7", event, .{});
        defer signal.deinit();
        var message = signal.message;
        message.serial = 1;
        message.signature = signal.body.signature;
        message.body = signal.body.values;
        const bytes = try dbus.encode(gpa, message, .little, .{});
        defer gpa.free(bytes);
        var frame = try dbus.decode(gpa, bytes, .{});
        defer frame.deinit();
        if (event.kind == .cache) {
            cache_count += 1;
            const announced = frame.message.body[0].structure[0].structure[1].object_path;
            try std.testing.expectEqualStrings(path, announced);
            try std.testing.expect(native.register.lookup(announced) != null);
            try std.testing.expectEqualStrings("AddAccessible", frame.message.member.?);
            try std.testing.expectEqualStrings("org.a11y.atspi.Cache", frame.message.interface.?);
            const tuple = frame.message.body[0].structure;
            try std.testing.expectEqual(@as(usize, 10), tuple.len);
            try std.testing.expectEqual(@as(i32, 0), tuple[3].int32);
            try std.testing.expectEqual(@as(i32, 0), tuple[4].int32);
            try std.testing.expectEqualStrings("", tuple[6].string);
            try std.testing.expectEqual(@as(u32, 23), tuple[7].uint32);
            var live_name = try native.register.lookup(announced).?.node.?.name(gpa);
            defer live_name.deinit(gpa);
            try std.testing.expectEqualStrings(live_name.items, tuple[6].string);
        } else {
            try std.testing.expectEqualStrings("ChildrenChanged", frame.message.member.?);
            try std.testing.expectEqualStrings(object_id.root_path, frame.message.path.?);
            try std.testing.expectEqualStrings("add", frame.message.body[0].string);
            try std.testing.expectEqual(@as(i32, 0), frame.message.body[1].int32);
            const child = frame.message.body[3].variant.value.structure[1].object_path;
            try std.testing.expectEqualStrings(path, child);
            try std.testing.expect(native.register.lookup(child) != null);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), cache_count);
    const corrected = NativeAdapter.applyPrepared(.borrowed, &native, &connection, unchanged);
    try std.testing.expect(corrected == .committed);
    try std.testing.expectEqual(error.Disconnected, corrected.committed.notification_error.?);
    try std.testing.expectEqual(@as(usize, 0), native.platform.raised.count());
    try std.testing.expectEqual(@as(u64, 3), native.platform.applied_updates);
}

const RegistryEventFixture = struct {
    native: NativeAdapter,
    connection: bus.Bus,

    fn init(self: *RegistryEventFixture, gpa: std.mem.Allocator) !void {
        self.native = undefined;
        self.native.gpa = gpa;
        self.native.platform = PlatformAdapter.init(gpa, 9, false);
        self.native.metadata = MetadataOwners.init(gpa);
        self.native.c_metadata = .{};
        self.native.app = try app_context.AppContext.init(gpa, null);
        self.native.platform.app = &self.native.app;
        self.native.node_context = null;
        self.native.attachment = .init(1);
        self.native.status = .init(.active);
        self.native.cycle_open = false;
        self.native.cycle_attached = false;
        self.native.registration_pending = false;
        self.native.register = objects.Register.init(gpa, &self.native.app);
        self.connection = undefined;
        self.connection.accessibility = null;
    }

    fn deinit(self: *RegistryEventFixture) void {
        self.native.register.deinit();
        self.native.platform.deinit();
        self.native.metadata.deinit();
        self.native.c_metadata.deinit();
        self.native.app.deinit();
        self.* = undefined;
    }
};

fn registryEventUpdate(
    gpa: std.mem.Allocator,
    initial: bool,
    name: []const u8,
    child: ?u64,
) !schema.TreeUpdate {
    var value: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    errdefer value.deinit(gpa);
    if (initial) value.tree = schema.TreeInfo.init(.{ .value = 1 });
    const root = built: {
        var n = schema.Node.init(gpa, .window);
        errdefer n.deinit();
        try schema.strings.setLabel(&n.properties, name);
        if (child) |id| try schema.ids_props.setChildren(&n.properties, &.{.{ .value = id }});
        break :built n;
    };
    try value.pushNode(gpa, .{ .value = 1 }, root);
    if (child) |id| {
        const n = built: {
            var n = schema.Node.init(gpa, .button);
            errdefer n.deinit();
            try schema.strings.setLabel(&n.properties, "Child");
            break :built n;
        };
        try value.pushNode(gpa, .{ .value = id }, n);
    }
    return value;
}

test "native registry deferred cache reconciles current paths and owns regeneration failure" {
    // Both failed admissions commit real borrowed updates. Cache encoding after
    // successful registration must describe the final tree, not vanished paths.
    const gpa = std.testing.allocator;
    var fixture: RegistryEventFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();
    const native = &fixture.native;
    var first = try registryEventUpdate(gpa, true, "Before", 2);
    defer first.deinit(gpa);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    native.register.gpa = failing.allocator();
    const initial = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, first);
    try std.testing.expect(initial == .committed);
    try std.testing.expectEqual(error.OutOfMemory, initial.committed.notification_error.?);
    var current = try registryEventUpdate(gpa, false, "Current", 3);
    defer current.deinit(gpa);
    failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    native.register.gpa = failing.allocator();
    const advanced = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, current);
    try std.testing.expect(advanced == .committed);
    try std.testing.expectEqual(error.OutOfMemory, advanced.committed.notification_error.?);
    try std.testing.expectEqual(@as(u64, 2), native.platform.applied_updates);
    try std.testing.expectEqual(@as(usize, 2), native.platform.nodeCount());
    const queued_before_regeneration = native.platform.raised.count();

    native.register.gpa = gpa;
    var regeneration_failure = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    native.gpa = regeneration_failure.allocator();
    native.node_context.?.gpa = regeneration_failure.allocator();
    try std.testing.expectError(error.OutOfMemory, native.prepareNotifications());
    try std.testing.expect(native.registration_pending);
    try std.testing.expectEqual(queued_before_regeneration, native.platform.raised.count());
    native.gpa = gpa;
    native.node_context.?.gpa = gpa;
    try native.prepareNotifications();
    try std.testing.expect(!native.registration_pending);
    try std.testing.expect(native.register.lookup("/org/a11y/atspi/accessible/9/2") == null);
    const root = native.register.lookup("/org/a11y/atspi/accessible/9/1").?.node.?;
    try std.testing.expectEqual(@as(i32, 1), try root.childCount());
    var adds: usize = 0;
    for (native.platform.raised.items.items) |event| {
        if (event.cache_item == null) continue;
        var signal = try OwnedSignal.init(gpa, &native.app, ":1.7", event, .{});
        defer signal.deinit();
        var message = signal.message;
        message.serial = 1;
        message.signature = signal.body.signature;
        message.body = signal.body.values;
        const bytes = try dbus.encode(gpa, message, .little, .{});
        defer gpa.free(bytes);
        var frame = try dbus.decode(gpa, bytes, .{});
        defer frame.deinit();
        const tuple = frame.message.body[0].structure;
        const path = tuple[0].structure[1].object_path;
        const live = native.register.lookup(path).?.node.?;
        var name = try live.name(gpa);
        defer name.deinit(gpa);
        try std.testing.expectEqualStrings(name.items, tuple[6].string);
        try std.testing.expectEqual(try live.childCount(), tuple[4].int32);
        if (adds == 0) {
            try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/9/1", path);
            try std.testing.expectEqualStrings("Current", tuple[6].string);
            try std.testing.expectEqual(@as(u32, 23), tuple[7].uint32);
        } else {
            try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/9/3", path);
            try std.testing.expectEqualStrings("Child", tuple[6].string);
            try std.testing.expectEqual(@as(u32, 43), tuple[7].uint32);
        }
        adds += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), adds);
    const retry: schema.TreeUpdate = .{ .focus = .{ .value = 1 } };
    const delivered = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, retry);
    try std.testing.expect(delivered == .committed);
    try std.testing.expectEqual(error.Disconnected, delivered.committed.notification_error.?);
    try std.testing.expectEqual(@as(usize, 0), native.platform.raised.count());
}

test "native registry failed focus cannot bypass sync and terminal close retains registered removal" {
    const gpa = std.testing.allocator;
    var fixture: RegistryEventFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();
    const native = &fixture.native;
    var initial = try registryEventUpdate(gpa, true, "Window", null);
    defer initial.deinit(gpa);
    const admitted = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, initial);
    try std.testing.expect(admitted == .committed);
    try std.testing.expectEqual(error.Disconnected, admitted.committed.notification_error.?);
    var delta = try registryEventUpdate(gpa, false, "Window", 2);
    defer delta.deinit(gpa);
    var failing = std.testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    native.register.gpa = failing.allocator();
    const committed = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, delta);
    try std.testing.expect(committed == .committed);
    try std.testing.expectEqual(error.OutOfMemory, committed.committed.notification_error.?);
    try native.platform.updateWindowFocusState(true);
    try std.testing.expectError(error.OutOfMemory, native.prepareNotifications());
    try std.testing.expect(native.registration_pending);
    try std.testing.expect(native.platform.is_host_focused);
    try std.testing.expect(native.register.lookup("/org/a11y/atspi/accessible/9/2") == null);
    native.announceTerminalRemoval();
    try std.testing.expect(!native.registration_pending);
    try std.testing.expectEqual(@as(usize, 1), native.platform.raised.count());
    const event = native.platform.raised.items.items[0];
    try std.testing.expectEqualStrings("ChildrenChanged", event.member);
    var signal = try OwnedSignal.init(gpa, &native.app, ":1.7", event, .{});
    defer signal.deinit();
    var message = signal.message;
    message.serial = 1;
    message.signature = signal.body.signature;
    message.body = signal.body.values;
    const bytes = try dbus.encode(gpa, message, .little, .{});
    defer gpa.free(bytes);
    var frame = try dbus.decode(gpa, bytes, .{});
    defer frame.deinit();
    try std.testing.expectEqualStrings(
        object_id.root_path,
        frame.message.path.?,
    );
    try std.testing.expectEqualStrings("remove", frame.message.body[0].string);
    try std.testing.expectEqual(@as(i32, -1), frame.message.body[1].int32);
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/9/1",
        frame.message.body[3].variant.value.structure[1].object_path,
    );
    native.releaseCycle();
    try std.testing.expectEqual(@as(usize, 0), native.platform.raised.count());
    try std.testing.expectEqual(@as(u32, 0), native.register.paths.count());
    try std.testing.expectEqual(@as(usize, 0), native.app.adapters.items.len);
    try std.testing.expect(!native.platform.hasTree());
    native.releaseCycle();
    try std.testing.expectEqual(@as(usize, 0), native.platform.raised.count());
}

test "native registry real RegisterLimit commits core and withholds new cache path" {
    // Reuse one real live context per registered window, as the registry's
    // existing boundary test does, rather than allocating a 65k-node tree.
    const gpa = std.testing.allocator;
    var fixture: RegistryEventFixture = undefined;
    try fixture.init(gpa);
    defer fixture.deinit();
    const native = &fixture.native;
    var initial = try registryEventUpdate(gpa, true, "Window", null);
    defer initial.deinit(gpa);
    const admitted = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, initial);
    try std.testing.expect(admitted == .committed);
    const adapter_count_max = objects.Register.max_objects / 2;
    for (1..adapter_count_max) |index| {
        try native.app.pushAdapter(9 + index, &native.node_context.?);
    }
    var delta = try registryEventUpdate(gpa, false, "Window", 2);
    defer delta.deinit(gpa);
    const committed = NativeAdapter.applyPrepared(.borrowed, native, &fixture.connection, delta);
    try std.testing.expect(committed == .committed);
    try std.testing.expectEqual(error.RegisterLimit, committed.committed.notification_error.?);
    try std.testing.expectEqual(@as(u64, 2), native.platform.applied_updates);
    try std.testing.expectEqual(@as(usize, 2), native.platform.nodeCount());
    try std.testing.expect(native.register.lookup("/org/a11y/atspi/accessible/9/1") != null);
    try std.testing.expect(native.register.lookup("/org/a11y/atspi/accessible/9/2") == null);
    var cache_adds: usize = 0;
    for (native.platform.raised.items.items) |event| {
        if (event.cache_item) |cache| {
            cache_adds += 1;
            try std.testing.expectEqual(@as(u64, 2), cache.id.local.value);
            try std.testing.expectEqualStrings("Child", cache.name);
        }
    }
    try std.testing.expectEqual(@as(usize, 1), cache_adds);
    native.announceTerminalRemoval();
    try std.testing.expectEqual(@as(usize, 1), native.platform.raised.count());
    try std.testing.expectEqualStrings("remove", native.platform.raised.items.items[0].detail1);
}
