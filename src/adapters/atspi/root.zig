//! C ownership bridge for the Linux AT-SPI adapter.
//!
//! Each owner keeps its environment snapshot, I/O provider, runtime and callback
//! table alive until native close joins the transport and all callbacks. The
//! checked constructor starts the real bus; a startup failure is not an inactive
//! success. C updates use the native attachment and commit result.
//!
//! Activation lends a complete C snapshot until native releases the loan. A
//! factory transfers its C update only when native requests it on the owned lane.
//! Action requests and debug strings use the declared C allocation domain, and
//! their public C free functions release raw allocations, not allocation heads.

const std = @import("std");
const zio = @import("zio");
const native = @import("adapter.zig");
pub const bus = @import("bus.zig");
const boundary = @import("../../capi/boundary.zig");
const allocation = @import("../../capi/allocation.zig");
const action_request = @import("../../capi/action_request.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const schema = @import("../../schema/root.zig");

pub const dbus = @import("dbus.zig");
pub const pump = @import("pump.zig");
pub const address = @import("address.zig");
pub const dbus_signature = @import("dbus_signature.zig");
pub const dispatch = @import("dispatch.zig");
pub const objects = @import("objects.zig");
pub const app_context = @import("app_context.zig");
pub const interfaces = @import("interfaces/root.zig");
pub const wire = @import("wire.zig");
pub const NativeAdapter = native.NativeAdapter;
pub const Runtime = native.Runtime;
pub const Callbacks = native.Callbacks;
pub const EditableTextRequest = native.EditableTextRequest;
pub const Options = native.Options;
pub const ActivationSnapshot = native.ActivationSnapshot;
pub const ActivationStatus = native.ActivationStatus;
pub const UpdateOutcome = native.UpdateOutcome;
pub const BorrowedUpdateOptions = native.BorrowedUpdateOptions;
pub const UpdateContext = native.UpdateContext;
pub const UpdateTicket = native.UpdateTicket;
pub const FactoryUpdate = native.FactoryUpdate;
pub const UpdateFactory = native.UpdateFactory;
pub const CallbackError = native.CallbackError;
pub const RejectError = native.RejectError;
pub const NotificationError = native.NotificationError;
pub const ActivationError = native.ActivationError;
pub const CreateError = native.CreateError;
pub const StartError = native.StartError;
pub const WindowBounds = @import("window_bounds.zig").WindowBounds;

pub const RuntimeInitError = error{
    OutOfMemory,
    EntropyUnavailable,
    SystemResources,
    ProcessFdQuotaExceeded,
    SystemFdQuotaExceeded,
    AccessDenied,
    LockedMemoryLimitExceeded,
    MemoryMappingNotSupported,
    InvalidFlags,
    ParamsOutsideAccessibleAddressSpace,
    Unexpected,
};

pub const ConstructorError = native.CreateError || native.StartError ||
    native.ActivationError || std.process.Environ.CreateMapError || RuntimeInitError;

pub const ConstructorOptions = struct {
    activation_handler: boundary.ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: boundary.ActionHandler,
    action_handler_userdata: ?*anyopaque,
    deactivation_handler: boundary.DeactivationHandler,
    deactivation_handler_userdata: ?*anyopaque,
    /// Null reads the actual host machine-id; a supplied value is validated.
    machine_id: ?[]const u8 = null,
    /// Initially empty caller-owned output for an exact remote startup error name.
    /// Release its contents through the same configured constructor allocator.
    failure_diagnostic: ?*bus.Diagnostic = null,
};

const CallbackTable = struct {
    activation: boundary.ActivationHandler,
    activation_context: ?*anyopaque,
    action: boundary.ActionHandler,
    action_context: ?*anyopaque,
    deactivation: boundary.DeactivationHandler,
    deactivation_context: ?*anyopaque,
};

/// A stable, single owner. Callers must stop using the pointer before destruction.
/// Callback pointers and user data remain borrowed through the close barrier.
/// Explicit allocators must be thread-safe and support normal Zig alignment.
/// The C constructor uses the declared pair's alignment-aware allocator adapter.
pub const UnixAdapter = struct {
    gpa: std.mem.Allocator,
    id: usize,
    environ: std.process.Environ.Map,
    io: std.Io.Threaded,
    runtime: *native.Runtime,
    native_adapter: *native.NativeAdapter,
    callbacks: CallbackTable,
    diagnostics_mutex: zio.Mutex = .init,
    last_outcome: ?native.UpdateOutcome = null,
    last_c_update_attachment: u64 = 0,

    /// Creates an unstarted owner, with an owned copy of the explicit environment.
    /// This seam does not manufacture a bus connection or an active tree.
    pub fn create(
        gpa: std.mem.Allocator,
        environ: std.process.Environ,
        options: ConstructorOptions,
    ) ConstructorError!*UnixAdapter {
        const self = try gpa.create(UnixAdapter);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .id = nextAdapterNumber(),
            .environ = try environ.createMap(gpa),
            .io = undefined,
            .runtime = undefined,
            .native_adapter = undefined,
            .callbacks = .{
                .activation = options.activation_handler,
                .activation_context = options.activation_handler_userdata,
                .action = options.action_handler,
                .action_context = options.action_handler_userdata,
                .deactivation = options.deactivation_handler,
                .deactivation_context = options.deactivation_handler_userdata,
            },
        };
        errdefer self.environ.deinit();
        self.io = std.Io.Threaded.init(gpa, .{ .environ = .empty });
        errdefer self.io.deinit();
        self.runtime = try createRuntime(gpa);
        errdefer self.runtime.deinit();
        self.native_adapter = try native.NativeAdapter.create(
            gpa,
            self.io.io(),
            self.runtime,
            .{
                .adapter_id = self.id,
                .machine_id = options.machine_id,
                .bus = .{
                    .environ = &self.environ,
                    .uid = std.c.getuid(),
                    .failure_diagnostic = options.failure_diagnostic,
                },
            },
            .{
                .context = self,
                .activation = activationCallback,
                .action = actionCallback,
                .deactivation = deactivationCallback,
                .activation_completed = activationCompleted,
            },
        );
        return self;
    }

    /// Starts the real transport. Retains the actual activation failure cause.
    pub fn start(self: *UnixAdapter) ConstructorError!void {
        self.native_adapter.start() catch |err| {
            if (err == error.ActivationFailed) {
                if (self.native_adapter.activationError()) |cause| return cause;
            }
            return err;
        };
    }

    /// Rejects callback self-close without changing admission or releasing storage.
    pub fn close(self: *UnixAdapter) error{Reentrant}!void {
        try self.native_adapter.close();
    }

    /// Exclusive final destruction. C callback self-free uses the checked export,
    /// which keeps the owner alive when close rejects with Reentrant.
    pub fn deinit(self: *UnixAdapter) void {
        self.close() catch terminate();
        self.native_adapter.destroy();
        self.runtime.deinit();
        self.io.deinit();
        self.environ.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
    }

    pub fn lastOutcome(self: *const UnixAdapter) ?native.UpdateOutcome {
        const mutable = @constCast(self);
        mutable.diagnostics_mutex.lockUncancelable();
        defer mutable.diagnostics_mutex.unlock();
        return self.last_outcome;
    }

    fn remember(self: *UnixAdapter, outcome: native.UpdateOutcome, c_update: bool) void {
        self.diagnostics_mutex.lockUncancelable();
        defer self.diagnostics_mutex.unlock();
        self.last_outcome = outcome;
        if (c_update) switch (outcome) {
            .committed => |committed| {
                // Concurrent callers must not move the C epoch backwards.
                self.last_c_update_attachment = @max(self.last_c_update_attachment, committed.attachment);
            },
            else => {},
        };
    }

    fn cAttachment(self: *UnixAdapter) u64 {
        self.diagnostics_mutex.lockUncancelable();
        defer self.diagnostics_mutex.unlock();
        return self.last_c_update_attachment;
    }

    fn fromContext(context: ?*anyopaque) *UnixAdapter {
        return @ptrCast(@alignCast(context.?));
    }

    fn activationCallback(context: ?*anyopaque) native.CallbackError!?native.ActivationSnapshot {
        const self = fromContext(context);
        const handle = self.callbacks.activation(self.callbacks.activation_context) orelse return null;
        const held: *c_tree_update.accesskit_tree_update = @ptrCast(@alignCast(handle));
        // No consume, conversion, allocation or native call in the loan supplier.
        return .{
            .update = &held.update,
            .release_context = held,
            .release = releaseActivation,
        };
    }

    fn releaseActivation(context: ?*anyopaque) void {
        const held: *c_tree_update.accesskit_tree_update = @ptrCast(@alignCast(context.?));
        c_tree_update.treeUpdateFree(held);
    }

    fn activationCompleted(context: ?*anyopaque, outcome: native.UpdateOutcome) void {
        // An attachment alone cannot validate the application's prepared C delta.
        fromContext(context).remember(outcome, false);
    }

    fn actionCallback(context: ?*anyopaque, request: *const schema.ActionRequest) native.CallbackError!void {
        const self = fromContext(context);
        const copy = try boundary.createActionRequest(allocation.allocator(), request.*);
        // The C handler owns the copy; native retains its borrowed source request.
        action_request.callActionHandler(self.callbacks.action, copy, self.callbacks.action_context);
    }

    fn deactivationCallback(context: ?*anyopaque) void {
        const self = fromContext(context);
        self.callbacks.deactivation(self.callbacks.deactivation_context);
    }

    const FactoryContext = struct {
        owner: *UnixAdapter,
        callback: boundary.TreeUpdateFactory,
        userdata: ?*anyopaque,
    };

    fn updateFactory(
        context: ?*anyopaque,
        gpa: std.mem.Allocator,
        update_context: native.UpdateContext,
    ) native.CallbackError!?native.FactoryUpdate {
        _ = gpa;
        const factory: *FactoryContext = @ptrCast(@alignCast(context.?));
        const self = factory.owner;
        // Native never calls this thunk while inactive. Active and pending calls
        // invoke the C factory exactly once and take ownership of its result.
        const prepared = factory.callback(factory.userdata) orelse terminate();
        const refresh = !update_context.requires_full_tree and
            update_context.attachment != self.cAttachment();
        const handle = if (refresh) refreshed: {
            // Dispose of the stale delta before requesting a current full tree.
            c_tree_update.discard(prepared);
            break :refreshed self.callbacks.activation(self.callbacks.activation_context) orelse return null;
        } else prepared;
        return .{
            .update = try self.native_adapter.consumeC(handle),
            .kind = if (refresh or update_context.requires_full_tree) .full else .delta,
        };
    }
};

fn createRuntime(gpa: std.mem.Allocator) RuntimeInitError!*native.Runtime {
    return native.Runtime.init(gpa, .{
        .executors = .exact(1),
        .enable_main_executor = false,
        .thread_pool = .{ .min_threads = 0, .max_threads = 0 },
        .dns = .{ .custom_resolver = false },
    }) catch |err| {
        const cause: RuntimeInitError = switch (err) {
            error.OutOfMemory,
            error.EntropyUnavailable,
            error.SystemResources,
            error.ProcessFdQuotaExceeded,
            error.SystemFdQuotaExceeded,
            error.AccessDenied,
            error.LockedMemoryLimitExceeded,
            error.MemoryMappingNotSupported,
            error.InvalidFlags,
            error.ParamsOutsideAccessibleAddressSpace,
            error.Unexpected,
            => @errorCast(err),
            // Worker init stores anyerror; unknown native errno already uses
            // Unexpected. It must never become OutOfMemory.
            else => error.Unexpected,
        };
        return cause;
    };
}

/// C dispatcher preserves its six-argument ABI and builds these named options.
/// Snapshots libc environ before the library starts its owned callback worker.
/// Concurrent foreign mutation of libc environ during this call is not permitted.
pub fn unixAdapterNewChecked(options: ConstructorOptions) ConstructorError!*UnixAdapter {
    const entries: [*:null]const ?[*:0]const u8 = @ptrCast(std.c.environ);
    const environ: std.process.Environ = .{ .block = .{ .slice = std.mem.span(entries) } };
    const self = try UnixAdapter.create(allocation.allocator(), environ, options);
    errdefer self.deinit();
    try self.start();
    return self;
}

pub fn unixAdapterFree(adapter: *UnixAdapter) void {
    allocation.clearError();
    if (@intFromPtr(adapter) == 0) terminate();
    adapter.close() catch |err| {
        adapter.remember(.{ .rejected = err }, false);
        allocation.failWithError(err);
        return;
    };
    const close_error = adapter.native_adapter.closeError();
    adapter.deinit();
    if (close_error) |err| allocation.failWithError(err);
}

pub fn unixAdapterSetRootWindowBounds(adapter: *UnixAdapter, outer: boundary.CRect, inner: boundary.CRect) void {
    allocation.clearError();
    const outcome = adapter.native_adapter.setRootWindowBounds(outer, inner);
    adapter.remember(outcome, false);
    reportOutcome(outcome);
}

pub fn unixAdapterUpdateIfActive(
    adapter: *UnixAdapter,
    update_factory: boundary.TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) void {
    allocation.clearError();
    var factory: UnixAdapter.FactoryContext = .{
        .owner = adapter,
        .callback = update_factory,
        .userdata = update_factory_userdata,
    };
    const outcome = adapter.native_adapter.updateIfActive(UnixAdapter.updateFactory, &factory);
    adapter.remember(outcome, true);
    reportOutcome(outcome);
}

pub fn unixAdapterUpdateWindowFocusState(adapter: *UnixAdapter, is_focused: bool) void {
    allocation.clearError();
    const outcome = adapter.native_adapter.updateWindowFocusState(is_focused);
    adapter.remember(outcome, false);
    reportOutcome(outcome);
}

fn reportOutcome(outcome: native.UpdateOutcome) void {
    switch (outcome) {
        .inactive => {},
        .rejected => |err| allocation.failWithError(err),
        .committed => |committed| if (committed.notification_error) |err| allocation.failWithError(err),
    }
}

fn outcomeName(outcome: ?native.UpdateOutcome) []const u8 {
    const value = outcome orelse return "none";
    return switch (value) {
        .inactive => "inactive",
        .rejected => "rejected",
        .committed => "committed",
    };
}

fn outcomeError(outcome: ?native.UpdateOutcome) ?anyerror {
    const value = outcome orelse return null;
    return switch (value) {
        .inactive => null,
        .rejected => |err| err,
        .committed => |committed| committed.notification_error,
    };
}

fn errorName(optional_error: anytype) []const u8 {
    return if (optional_error) |err| @errorName(err) else "none";
}

/// Uses only atomic native status/error snapshots and the protected last result.
/// The raw declared-allocator string outlives the owner and uses accesskit_string_free.
pub fn unixAdapterDebug(adapter: *const UnixAdapter) ?[*:0]u8 {
    allocation.clearError();
    const outcome = adapter.lastOutcome();
    var buffer: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(
        &buffer,
        "UnixAdapter {{ id: {d}, status: {s}, outcome: {s}, error: {s}, " ++
            "activation_error: {s}, action_error: {s}, transport_error: {s}, close_error: {s} }}",
        .{
            adapter.id,
            @tagName(adapter.native_adapter.activationStatus()),
            outcomeName(outcome),
            errorName(outcomeError(outcome)),
            errorName(adapter.native_adapter.activationError()),
            errorName(adapter.native_adapter.actionError()),
            errorName(adapter.native_adapter.transportError()),
            errorName(adapter.native_adapter.closeError()),
        },
    ) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const owned = allocation.allocator().dupeZ(u8, text) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    return owned.ptr;
}

/// Existing process-wide path ID allocation; connections and callback state are per owner.
pub fn nextAdapterNumber() usize {
    return next_adapter_number.fetchAdd(1, .monotonic);
}

var next_adapter_number = std.atomic.Value(usize).init(0);

/// A null C factory result or an invalid final-destruction precondition is fatal.
pub fn terminate() noreturn {
    std.process.exit(1);
}

const testing = std.testing;
const c_tree_info = @import("../../capi/tree_info.zig");
const C = struct {
    extern fn accesskit_string_free([*:0]u8) void;
    extern fn accesskit_action_request_free(*boundary.CActionRequest) void;
};

const Probe = struct {
    activation_calls: usize = 0,
    deactivation_calls: usize = 0,
    factory_calls: usize = 0,
    handle: ?*boundary.CTreeUpdate = null,
    callback_thread: ?std.Thread.Id = null,

    fn activation(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
        const self: *Probe = @ptrCast(@alignCast(context.?));
        self.activation_calls += 1;
        self.callback_thread = std.Thread.getCurrentId();
        const handle = self.handle;
        self.handle = null;
        return handle;
    }

    fn factory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
        const self: *Probe = @ptrCast(@alignCast(context.?));
        self.factory_calls += 1;
        const handle = self.handle;
        self.handle = null;
        return handle;
    }

    fn action(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
        _ = context;
        C.accesskit_action_request_free(request);
    }

    fn deactivation(context: ?*anyopaque) callconv(.c) void {
        const self: *Probe = @ptrCast(@alignCast(context.?));
        self.deactivation_calls += 1;
        self.callback_thread = std.Thread.getCurrentId();
    }

    fn options(self: *Probe) ConstructorOptions {
        return .{
            .activation_handler = activation,
            .activation_handler_userdata = self,
            .action_handler = action,
            .action_handler_userdata = self,
            .deactivation_handler = deactivation,
            .deactivation_handler_userdata = self,
            .machine_id = "0123456789abcdef0123456789abcdef",
        };
    }

    fn deinit(self: *Probe) void {
        if (self.handle) |handle| c_tree_update.discard(handle);
        self.handle = null;
    }
};

fn ownerFor(probe: *Probe) ConstructorError!*UnixAdapter {
    return UnixAdapter.create(testing.allocator, .empty, probe.options());
}

test "C unstarted native update preserves its pending handle and reports NotStarted" {
    var activation: Probe = .{};
    const adapter = try ownerFor(&activation);
    defer adapter.deinit();
    var factory: Probe = .{
        .handle = @ptrCast(try c_tree_update.treeUpdateWithCapacityAndFocus(testing.allocator, 1, 41)),
    };
    defer factory.deinit();
    const pending = factory.handle;
    unixAdapterUpdateIfActive(adapter, Probe.factory, &factory);
    try testing.expect(factory.handle == pending);
    try testing.expectEqual(@as(usize, 0), factory.factory_calls);
    try testing.expectEqual(@as(usize, 0), activation.activation_calls);
    try testing.expectEqual(native.ActivationStatus.inactive, adapter.native_adapter.activationStatus());
    try testing.expectEqual(error.NotStarted, adapter.lastOutcome().?.rejected);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
}

test "C closed native update rejects exactly and does not call or consume the factory" {
    var activation: Probe = .{};
    const adapter = try ownerFor(&activation);
    defer adapter.deinit();
    var factory: Probe = .{
        .handle = @ptrCast(try c_tree_update.treeUpdateWithCapacityAndFocus(testing.allocator, 1, 41)),
    };
    defer factory.deinit();
    const pending = factory.handle;
    try adapter.close();
    unixAdapterUpdateIfActive(adapter, Probe.factory, &factory);
    try testing.expect(factory.handle == pending);
    try testing.expectEqual(@as(usize, 0), factory.factory_calls);
    try testing.expectEqual(@as(usize, 0), activation.activation_calls);
    try testing.expectEqual(@as(usize, 0), activation.deactivation_calls);
    try testing.expectEqual(native.ActivationStatus.closed, adapter.native_adapter.activationStatus());
    try testing.expectEqual(error.Closed, adapter.lastOutcome().?.rejected);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    const text = unixAdapterDebug(adapter) orelse return error.DebugTextNotBuilt;
    defer C.accesskit_string_free(text);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "error: Closed") != null);
}

test "C checked focus and bounds retain the native rejection rather than OOM" {
    var probe: Probe = .{};
    const adapter = try ownerFor(&probe);
    defer adapter.deinit();
    try adapter.close();
    unixAdapterUpdateWindowFocusState(adapter, true);
    try testing.expectEqual(error.Closed, adapter.lastOutcome().?.rejected);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
    unixAdapterSetRootWindowBounds(adapter, .{ .x0 = 10, .y0 = 20, .x1 = 80, .y1 = 100 }, .{ .x0 = 13, .y0 = 26, .x1 = 70, .y1 = 90 });
    try testing.expectEqual(error.Closed, adapter.lastOutcome().?.rejected);
    try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
}

test "C native constructor rejects an invalid machine id with failure-atomic owner cleanup" {
    var probe: Probe = .{};
    var options = probe.options();
    options.machine_id = "0123456789abcdef0123456789abcdeg";
    try testing.expectError(error.InvalidMachineId, UnixAdapter.create(testing.allocator, .empty, options));
    try testing.expectEqual(@as(usize, 0), probe.activation_calls);
    try testing.expectEqual(@as(usize, 0), probe.deactivation_calls);
}

fn fullCUpdate(gpa: std.mem.Allocator) !*c_tree_update.accesskit_tree_update {
    const held = try c_tree_update.treeUpdateWithCapacityAndFocus(gpa, 1, 41);
    errdefer c_tree_update.treeUpdateFree(held);
    try held.update.pushNode(gpa, .{ .value = 41 }, schema.Node.init(gpa, .window));
    const info = try c_tree_info.treeInfoNew(gpa, 41);
    errdefer c_tree_info.treeInfoFree(info);
    try c_tree_info.treeInfoSetToolkitName(info, "C Loan Toolkit");
    try c_tree_info.treeInfoSetToolkitVersion(info, "loan-release");
    c_tree_update.treeUpdateSetTreeInfo(held, info);
    return held;
}

const LoanObservation = struct {
    same_update: bool,
    focus: u64,
    root: u64,
    role: schema.Role,
    metadata_matches: bool,
};

fn inspectActivationLoan(owner: *UnixAdapter, expected: *const schema.TreeUpdate) !LoanObservation {
    const loan = (try UnixAdapter.activationCallback(owner)) orelse return error.ActivationDeclined;
    defer loan.release(loan.release_context);
    const info = loan.update.tree orelse return error.MissingTreeInfo;
    if (loan.update.nodes.items.len != 1) return error.InvalidSnapshot;
    return .{
        .same_update = loan.update == expected,
        .focus = loan.update.focus.value,
        .root = info.root.value,
        .role = loan.update.nodes.items[0].node.role,
        .metadata_matches = if (info.toolkit_name) |name|
            if (info.toolkit_version) |version|
                std.mem.eql(u8, name, "C Loan Toolkit") and std.mem.eql(u8, version, "loan-release")
            else
                false
        else
            false,
    };
}

test "C activation lends the actual full snapshot and metadata until owned-worker release" {
    var captured = testing.FailingAllocator.init(testing.allocator, .{});
    const held = try fullCUpdate(captured.allocator());
    const expected = &held.update;
    var probe: Probe = .{ .handle = @ptrCast(held) };
    defer probe.deinit();
    const adapter = try ownerFor(&probe);
    defer adapter.deinit();
    const caller_thread = std.Thread.getCurrentId();
    var task = try adapter.runtime.spawn(inspectActivationLoan, .{ adapter, expected });
    const observation = try task.join();
    try testing.expect(observation.same_update);
    try testing.expectEqual(@as(u64, 41), observation.focus);
    try testing.expectEqual(@as(u64, 41), observation.root);
    try testing.expectEqual(schema.Role.window, observation.role);
    try testing.expect(observation.metadata_matches);
    try testing.expect(probe.handle == null);
    try testing.expectEqual(@as(usize, 1), probe.activation_calls);
    try testing.expect(probe.callback_thread.? != caller_thread);
    try testing.expect(captured.allocated_bytes > 0);
    try testing.expectEqual(captured.allocated_bytes, captured.freed_bytes);
}

const DeclaredAllocatorProbe = struct {
    bytes: [4096]u8 align(8) = undefined,
    slots: [8]?*anyopaque = [_]?*anyopaque{null} ** 8,
    used: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,
    foreign_frees: usize = 0,

    fn alloc(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        const start = std.mem.alignForward(usize, self.used, 8);
        if (start > self.bytes.len or size > self.bytes.len - start) return null;
        for (&self.slots) |*slot| {
            if (slot.* != null) continue;
            const pointer: *anyopaque = @ptrCast(self.bytes[start..].ptr);
            slot.* = pointer;
            self.used = start + size;
            self.allocations += 1;
            return pointer;
        }
        return null;
    }

    fn free(pointer: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        for (&self.slots) |*slot| {
            if (slot.* == pointer and pointer != null) {
                slot.* = null;
                self.frees += 1;
                return;
            }
        }
        // Refuse an unknown block instead of passing a foreign pointer to free.
        self.foreign_frees += 1;
    }

    fn allFreed(self: *const @This()) bool {
        for (self.slots) |slot| if (slot != null) return false;
        return self.allocations == self.frees and self.foreign_frees == 0;
    }
};

test "C debug string uses the installed raw allocator and survives adapter free" {
    var pair: DeclaredAllocatorProbe = .{};
    allocation.installAllocator(DeclaredAllocatorProbe.alloc, DeclaredAllocatorProbe.free, &pair);
    defer allocation.installAllocator(null, null, null);
    var probe: Probe = .{};
    const adapter = try ownerFor(&probe);
    const text = unixAdapterDebug(adapter) orelse {
        unixAdapterFree(adapter);
        return error.DebugTextNotBuilt;
    };
    unixAdapterFree(adapter);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "UnixAdapter") != null);
    C.accesskit_string_free(text);
    try testing.expectEqual(@as(usize, 0), pair.foreign_frees);
    try testing.expectEqual(@as(usize, 1), pair.allocations);
    try testing.expect(pair.allFreed());
}

const action_text = "caf\u{e9} \u{65e5}\u{672c}";
const action_tree: schema.TreeId = .{ .bytes = @splat(0x17) };
const action_node: schema.NodeId = .{ .value = 0x100000001 };
const ActionProbe = struct {
    expected_source: [*]const u8,
    called: bool = false,
    matches: bool = false,
    independent_string: bool = false,
    callback_thread: ?std.Thread.Id = null,

    fn action(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
        defer C.accesskit_action_request_free(request);
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.called = true;
        self.callback_thread = std.Thread.getCurrentId();
        if (!request.data.has_value or request.data.value.tag != @intFromEnum(schema.ActionDataTag.value)) return;
        const text = request.data.value.payload.value orelse return;
        self.independent_string = text != self.expected_source;
        self.matches = request.action == .set_value and
            std.mem.eql(u8, &request.target_tree.bytes, &action_tree.bytes) and
            request.target_node.value == action_node.value and
            std.mem.eql(u8, std.mem.span(text), action_text);
    }
};

test "C owned-worker action invokes the handler with independent UTF8 and public-free ownership" {
    var pair: DeclaredAllocatorProbe = .{};
    allocation.installAllocator(DeclaredAllocatorProbe.alloc, DeclaredAllocatorProbe.free, &pair);
    defer allocation.installAllocator(null, null, null);
    const value = try testing.allocator.dupe(u8, action_text);
    var request: schema.ActionRequest = .{
        .action = .set_value,
        .target_tree = action_tree,
        .target_node = action_node,
        .data = .{ .value = value },
    };
    defer request.deinit(testing.allocator);
    var action: ActionProbe = .{ .expected_source = value.ptr };
    var callbacks: Probe = .{};
    var options = callbacks.options();
    options.action_handler = ActionProbe.action;
    options.action_handler_userdata = &action;
    const adapter = try UnixAdapter.create(testing.allocator, .empty, options);
    defer adapter.deinit();
    const caller_thread = std.Thread.getCurrentId();
    var task = try adapter.runtime.spawn(UnixAdapter.actionCallback, .{ adapter, &request });
    try task.join();
    try testing.expect(action.called);
    try testing.expect(action.matches);
    try testing.expect(action.independent_string);
    try testing.expect(action.callback_thread.? != caller_thread);
    // Root must not deinitialize or transfer the callback-scoped native request.
    try testing.expectEqualStrings(action_text, request.data.?.value);
    try testing.expectEqual(@as(usize, 2), pair.allocations);
    try testing.expectEqual(@as(usize, 0), pair.foreign_frees);
    try testing.expect(pair.allFreed());
}

test "C stale attachment thunk disposes its owned factory result before fresh activation" {
    const Stale = struct {
        captured: *testing.FailingAllocator,
        handle: ?*boundary.CTreeUpdate,
        factory_calls: usize = 0,
        activation_calls: usize = 0,
        released_before_activation: bool = false,

        fn factory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.factory_calls += 1;
            const handle = self.handle;
            self.handle = null;
            return handle;
        }

        fn activation(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.activation_calls += 1;
            self.released_before_activation = self.captured.allocated_bytes > 0 and
                self.captured.allocated_bytes == self.captured.freed_bytes;
            return null;
        }
    };
    var captured = testing.FailingAllocator.init(testing.allocator, .{});
    var stale: Stale = .{
        .captured = &captured,
        .handle = @ptrCast(try fullCUpdate(captured.allocator())),
    };
    defer if (stale.handle) |handle| c_tree_update.discard(handle);
    var callbacks: Probe = .{};
    var options = callbacks.options();
    options.activation_handler = Stale.activation;
    options.activation_handler_userdata = &stale;
    const adapter = try UnixAdapter.create(testing.allocator, .empty, options);
    defer adapter.deinit();
    var factory: UnixAdapter.FactoryContext = .{
        .owner = adapter,
        .callback = Stale.factory,
        .userdata = &stale,
    };
    // Exercise the bridge's delivered scope descriptor, without manufacturing
    // an active native tree or bypassing consumeC's owned-pump-lane precondition.
    var task = try adapter.runtime.spawn(UnixAdapter.updateFactory, .{
        &factory,
        testing.allocator,
        native.UpdateContext{ .attachment = 7, .requires_full_tree = false },
    });
    const result = try task.join();
    try testing.expect(result == null);
    try testing.expect(stale.handle == null);
    try testing.expectEqual(@as(usize, 1), stale.factory_calls);
    try testing.expectEqual(@as(usize, 1), stale.activation_calls);
    try testing.expect(stale.released_before_activation);
    try testing.expectEqual(captured.allocated_bytes, captured.freed_bytes);
    try testing.expectEqual(native.ActivationStatus.inactive, adapter.native_adapter.activationStatus());
}

test "C action bridge retains exact InteriorNul and leaves borrowed payload intact" {
    var pair: DeclaredAllocatorProbe = .{};
    allocation.installAllocator(DeclaredAllocatorProbe.alloc, DeclaredAllocatorProbe.free, &pair);
    defer allocation.installAllocator(null, null, null);
    const value = try testing.allocator.dupe(u8, "A\x00B");
    var request: schema.ActionRequest = .{
        .action = .set_value,
        .target_tree = action_tree,
        .target_node = action_node,
        .data = .{ .value = value },
    };
    defer request.deinit(testing.allocator);
    var action: ActionProbe = .{ .expected_source = value.ptr };
    var callbacks: Probe = .{};
    var options = callbacks.options();
    options.action_handler = ActionProbe.action;
    options.action_handler_userdata = &action;
    const adapter = try UnixAdapter.create(testing.allocator, .empty, options);
    defer adapter.deinit();
    var task = try adapter.runtime.spawn(UnixAdapter.actionCallback, .{ adapter, &request });
    try testing.expectError(error.InteriorNul, task.join());
    try testing.expect(!action.called);
    try testing.expectEqualStrings("A\x00B", request.data.?.value);
    try testing.expectEqual(@as(usize, 1), pair.allocations);
    try testing.expectEqual(@as(usize, 0), pair.foreign_frees);
    try testing.expect(pair.allFreed());
}
