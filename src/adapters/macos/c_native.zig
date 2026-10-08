//! Ownership bridge from the existing macOS C ABI to the real AppKit adapter.
//! C factories transfer their source handle, while the core borrows its update
//! directly. Notifications remain owned until the caller explicitly raises them.

const std = @import("std");
const builtin = @import("builtin");
const native = @import("native.zig");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const boundary = @import("../../capi/boundary.zig");
const allocation = @import("../../capi/allocation.zig");
const c_tree_update = @import("../../capi/tree_update.zig");
const action_request = @import("../../capi/action_request.zig");
const schema = @import("../../schema/root.zig");

const Allocator = std.mem.Allocator;

/// A C adapter owns this bridge until close joins all borrowed callbacks.
/// Native objects and queued notifications hold independent weak/runtime owners.
pub const Bridge = struct {
    gpa: Allocator,
    adapter: *native.NativeAdapter,
    action_handler: boundary.ActionHandler,
    action_userdata: ?*anyopaque,

    /// Creates a real native adapter. A constructor failure releases its runtime
    /// authority exactly once and leaves no view subclass installed.
    pub fn create(
        gpa: Allocator,
        target: native.AttachTarget,
        focused: bool,
        subclassing: bool,
        activation_handler: ?boundary.ActivationHandler,
        activation_userdata: ?*anyopaque,
        action_handler: boundary.ActionHandler,
        action_userdata: ?*anyopaque,
    ) native.NativeError!*Bridge {
        if (builtin.os.tag != .macos) return error.NativeUnsupported;
        const self = try gpa.create(Bridge);
        errdefer gpa.destroy(self);
        const runtime = try RuntimeOwner.create(gpa);
        // Runtime authority transfers only after NativeAdapter.create succeeds.
        const adapter = native.NativeAdapter.create(gpa, runtime.threaded.io(), .{
            .action_handler = action,
            .userdata = self,
            .activation_sink = .{ .c = .{
                .callback = activation_handler,
                .userdata = activation_userdata,
            } },
            .runtime_release = .{ .userdata = runtime, .release = releaseRuntime },
        }) catch |err| {
            releaseRuntime(runtime);
            return err;
        };
        self.* = .{
            .gpa = gpa,
            .adapter = adapter,
            .action_handler = action_handler,
            .action_userdata = action_userdata,
        };
        errdefer self.closeNativeAfterFailedAttach();
        if (subclassing) {
            try adapter.attach(target, focused);
        } else {
            try adapter.attachUnsubclassed(target, focused);
        }
        return self;
    }

    /// Prepares notifications without posting. The C source's nodes and node
    /// array are borrowed directly, then released with their captured allocator.
    pub fn update(
        self: *Bridge,
        factory: boundary.TreeUpdateFactory,
        userdata: ?*anyopaque,
    ) native.PreparedUpdateOutcome {
        if (!foundation.isMainThread()) return .{ .rejected = error.WrongThread };
        if (!self.adapter.isActive()) return .inactive;
        const handle = factory(userdata) orelse @trap();
        defer c_tree_update.discard(handle);
        const owned: *c_tree_update.accesskit_tree_update = @ptrCast(@alignCast(handle));
        const supplier: native.FullTreeSupplier = .{
            .context = &owned.update,
            .get = currentFull,
        };
        return self.adapter.prepareUpdateIfActiveBorrowedChecked(&owned.update, supplier);
    }

    /// Preserves the C API's explicit-raise timing for focus notifications.
    pub fn updateFocus(self: *Bridge, focused: bool) native.PreparedUpdateOutcome {
        return self.adapter.prepareViewFocusState(focused);
    }

    /// Returns an autoreleased real NSArray, or nil with the exact checked cause.
    /// The caller's AppKit autorelease pool, not a local drained pool, owns +0.
    pub fn children(
        self: *Bridge,
        activation_handler: boundary.ActivationHandler,
        userdata: ?*anyopaque,
    ) native.NativeError!?objc.Object {
        if (!foundation.isMainThread()) return error.WrongThread;
        self.adapter.setCActivationHandler(activation_handler, userdata);
        const result = try self.adapter.viewChildrenChecked() orelse return null;
        return objc.autoreleaseReturn(result);
    }

    /// Returns the independently retained native focus object at +0.
    pub fn focus(
        self: *Bridge,
        activation_handler: boundary.ActivationHandler,
        userdata: ?*anyopaque,
    ) native.NativeError!?objc.Object {
        if (!foundation.isMainThread()) return error.WrongThread;
        self.adapter.setCActivationHandler(activation_handler, userdata);
        const result = try self.adapter.focusChecked() orelse return null;
        return objc.autoreleaseReturn(result);
    }

    /// Hit-tests the actual native view with the source adapter's screen point.
    pub fn hitTest(
        self: *Bridge,
        point: objc.NSPoint,
        activation_handler: boundary.ActivationHandler,
        userdata: ?*anyopaque,
    ) native.NativeError!?objc.Object {
        if (!foundation.isMainThread()) return error.WrongThread;
        self.adapter.setCActivationHandler(activation_handler, userdata);
        const result = try self.adapter.hitTestChecked(point) orelse return null;
        return objc.autoreleaseReturn(result);
    }

    /// On WrongThread the bridge remains owned and may be closed on main later.
    /// Successful close joins callbacks before this borrowed callback state frees.
    pub fn closeAndDestroy(self: *Bridge) native.NativeError!void {
        var notification_error: ?native.NativeError = null;
        self.adapter.close() catch |err| {
            if (err == error.WrongThread) return err;
            // Every other close error reports posting after close committed.
            // Disposal still consumes this C handle, preserving the exact cause.
            notification_error = err;
        };
        self.adapter.deinit();
        const gpa = self.gpa;
        gpa.destroy(self);
        if (notification_error) |err| return err;
    }

    fn closeNativeAfterFailedAttach(self: *Bridge) void {
        // Both construction and attachment already admitted the main thread.
        self.adapter.close() catch |err| {
            allocation.failWithError(err);
            @panic("native adapter refused main-thread constructor rollback");
        };
        self.adapter.deinit();
    }

    fn action(userdata: ?*anyopaque, request: *const schema.ActionRequest) void {
        const self: *Bridge = @ptrCast(@alignCast(userdata.?));
        const transferred = boundary.createActionRequest(allocation.allocator(), request.*) catch
            |err| {
                allocation.failWithError(err);
                return;
            };
        action_request.callActionHandler(self.action_handler, transferred, self.action_userdata);
    }

    fn currentFull(userdata: ?*anyopaque) *const schema.TreeUpdate {
        return @ptrCast(@alignCast(userdata.?));
    }
};

/// Its final release may follow adapter close because native objects/queues can
/// retain the weak control block. This callback performs no AppKit operations.
const RuntimeOwner = struct {
    gpa: Allocator,
    threaded: std.Io.Threaded,

    fn create(gpa: Allocator) Allocator.Error!*RuntimeOwner {
        const self = try gpa.create(RuntimeOwner);
        self.* = .{ .gpa = gpa, .threaded = std.Io.Threaded.init(gpa, .{}) };
        return self;
    }
};

fn releaseRuntime(userdata: ?*anyopaque) void {
    const runtime: *RuntimeOwner = @ptrCast(@alignCast(userdata.?));
    const gpa = runtime.gpa;
    runtime.threaded.deinit();
    gpa.destroy(runtime);
}
