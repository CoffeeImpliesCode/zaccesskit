//! Owned AppKit notifications prepared from the authoritative pure event generator.
//!
//! Create, prepare while the adapter's state is guarded, then raise after releasing
//! those guards. Each queue has one owner; an admitted `raiseAndDeinit` or a `deinit`
//! ends ownership exactly once. Preparation copies strings and retains targets; raising does not
//! resolve tree data or dereference the adapter, view host, or provider resolver.

const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const context = @import("context.zig");
const native = @import("native.zig");
const events = @import("events.zig");
const literals = @import("literals.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const FullNodeId = consumer.tree_index.FullNodeId;

/// Exact generator, provider-construction, and Foundation failure vocabulary.
pub const NotificationError = events.SlotError || context.NativeError;

/// Maximum source events accepted by one queue; exhaustion is `ProviderLimitExceeded`.
pub const notification_limit: usize = 65536;

/// Targets captured before state guards, with one owned +1 reference per non-null field.
/// `create` consumes them only on success; `null` means no attached view/window.
pub const Targets = struct {
    view: ?objc.Object,
    window: ?objc.Object,
};

/// Borrowed only during `prepare`, on the main thread under the caller's state guard.
/// Callbacks must not reenter the queue or mutate its storage.
pub const ProviderResolver = struct {
    context: ?*anyopaque,
    /// Returns a borrowed native provider; the queue retains its own reference.
    provider: *const fn (?*anyopaque, FullNodeId) context.NativeError!objc.Object,
    /// Removes the map entry before returning its transferred +1 native reference.
    /// `null` means no native provider was ever exposed for this removed node.
    takeRemoved: *const fn (?*anyopaque, FullNodeId) ?objc.Object,
};

const Notification = struct {
    target: objc.Object,
    name: [:0]u8,
};

const Announcement = struct {
    text: []u8,
    priority: i32,
};

const OwnedEvent = union(enum) {
    notification: Notification,
    announcement: Announcement,
};

/// Single-owned heap queue with independent native references and a weak runtime pin.
/// The supplied allocator must outlive the queue. Do not copy or concurrently access
/// its storage. Its weak pin permits raising or dropping after adapter close.
pub const NativeNotifications = struct {
    gpa: std.mem.Allocator,
    weak: context.WeakContext,
    retained_view: ?objc.Object,
    retained_window: ?objc.Object,
    items: std.ArrayList(OwnedEvent) = .empty,
    prepared: bool = false,
    failure: ?NotificationError = null,

    /// Clones caller-owned `weak` and consumes the supplied owned +1 targets on success.
    /// Performs no native retain. On refusal/allocation failure, caller keeps every target
    /// and must release those captures after its state guards have been released.
    pub fn create(
        gpa: std.mem.Allocator,
        weak: context.WeakContext,
        targets: Targets,
    ) NotificationError!*NativeNotifications {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        const self = try gpa.create(NativeNotifications);
        const queue_weak = weak.clone();
        self.* = .{
            .gpa = gpa,
            .weak = queue_weak,
            .retained_view = targets.view,
            .retained_window = targets.window,
        };
        return self;
    }

    /// Prepares once, preserving generator order and borrowing no source data afterward.
    /// A removed provider leaves its map before any destroyed-notification construction.
    /// The first conversion error is returned exactly; remaining destruction entries
    /// still leave the map, and no partial queue may be raised. Caller must `deinit`
    /// after failure. Above `notification_limit`, no resolver is called; the adapter's
    /// postcommit defunct-provider sweep remains responsible for map cleanup.
    pub fn prepare(
        self: *NativeNotifications,
        source: []const events.QueuedEvent,
        resolver: ProviderResolver,
    ) NotificationError!void {
        std.debug.assert(!self.prepared);
        self.prepared = true;
        if (builtin.os.tag != .macos) {
            self.record(error.NativeUnsupported);
            return error.NativeUnsupported;
        }
        if (!foundation.isMainThread()) {
            self.record(error.WrongThread);
            return error.WrongThread;
        }
        if (source.len > notification_limit) {
            self.record(error.ProviderLimitExceeded);
            return error.ProviderLimitExceeded;
        }
        self.items.ensureTotalCapacityPrecise(self.gpa, source.len) catch |err| {
            self.record(err);
        };
        for (source) |event| {
            switch (event) {
                .generic => |generic| {
                    if (self.failure != null) continue;
                    const target = resolver.provider(resolver.context, generic.node_id) catch |err| {
                        self.record(err);
                        continue;
                    };
                    self.appendNotification(objc.retain(target), generic.notification) catch |err| {
                        self.record(err);
                    };
                },
                .node_destroyed => |id| {
                    const target = resolver.takeRemoved(resolver.context, id) orelse continue;
                    if (self.failure != null) {
                        objc.release(target);
                        continue;
                    }
                    const name = events.notificationFor(.node_destroyed) orelse {
                        // The authoritative table is total for this generator tag.
                        objc.release(target);
                        unreachable;
                    };
                    self.appendNotification(target, name) catch |err| {
                        self.record(err);
                    };
                },
                .announcement => |announcement| {
                    if (self.failure != null) continue;
                    if (self.retained_window == null) continue;
                    const text = self.gpa.dupe(u8, announcement.text) catch |err| {
                        self.record(err);
                        continue;
                    };
                    self.items.appendAssumeCapacity(.{ .announcement = .{
                        .text = text,
                        .priority = nativePriority(announcement.priority),
                    } });
                },
            }
        }
        if (self.failure) |err| return err;
    }

    /// Refuses unsupported native targets and foreign threads without spending ownership.
    /// After main-thread admission, every posting success/error path consumes the queue.
    pub fn raiseAndDeinit(self: *NativeNotifications) NotificationError!void {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        defer self.deinit();
        try self.raiseAdmitted();
    }

    /// Posts in generator order without consuming any queue resources, even on error.
    /// Requires the AppKit main thread, including after adapter close. A construction
    /// error stops subsequent posts; already-posted notifications cannot be undone.
    /// Calling again reposts the batch. Caller must eventually consume the queue.
    pub fn raise(self: *NativeNotifications) NotificationError!void {
        try objc.requireNative();
        if (!foundation.isMainThread()) return error.WrongThread;
        try self.raiseAdmitted();
    }

    // Both public entry points establish native/main-thread admission before posting.
    fn raiseAdmitted(self: *NativeNotifications) NotificationError!void {
        if (self.failure) |err| return err;
        var pool = try objc.AutoreleasePool.init();
        defer pool.deinit();
        for (self.items.items) |event| {
            switch (event) {
                .notification => |notification| {
                    try foundation.post(notification.target, notification.name);
                },
                .announcement => |announcement| {
                    // Preparation only records announcements when the retained window exists.
                    try foundation.announce(
                        self.retained_window.?,
                        announcement.text,
                        announcement.priority,
                    );
                },
            }
        }
    }

    /// Drops unraised notifications and frees this heap queue exactly once.
    /// The weak runtime authority is released last, after all allocator/native work.
    /// Call on the main thread when AppKit view/window targets were retained.
    pub fn deinit(self: *NativeNotifications) void {
        const gpa = self.gpa;
        var weak = self.weak;
        for (self.items.items) |event| {
            switch (event) {
                .notification => |notification| {
                    gpa.free(notification.name);
                    objc.release(notification.target);
                },
                .announcement => |announcement| gpa.free(announcement.text),
            }
        }
        self.items.deinit(gpa);
        if (self.retained_view) |view| objc.release(view);
        if (self.retained_window) |window| objc.release(window);
        self.* = undefined;
        gpa.destroy(self);
        weak.deinit();
    }

    fn appendNotification(
        self: *NativeNotifications,
        target: objc.Object,
        name: [:0]const u8,
    ) NotificationError!void {
        errdefer objc.release(target);
        const owned_name = try self.gpa.dupeZ(u8, name);
        self.items.appendAssumeCapacity(.{ .notification = .{
            .target = target,
            .name = owned_name,
        } });
    }

    fn record(self: *NativeNotifications, err: NotificationError) void {
        if (self.failure == null) self.failure = err;
    }
};

// Apple-authored MacOSX11.3.sdk AppKit/NSAccessibilityConstants.h:571-575.
// SDK mirror blob d46725739a34f180d2d7913e0ca96a50c783a72d defines high=90, medium=50.
// Only the generator's high/medium semantic tags are supported here.
fn nativePriority(priority: literals.PriorityLevel) i32 {
    return @intFromEnum(priority);
}

test "native announcement priorities use SDK integer levels" {
    try std.testing.expectEqual(@as(i32, 90), nativePriority(.high));
    try std.testing.expectEqual(@as(i32, 50), nativePriority(.medium));
}
test "native notifications own removed targets and copied strings before source expires" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try nativeOwnershipTest(std.testing.allocator);
}

test "native notifications release every partial allocation and remove destroyed providers" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, nativeOwnershipTest, .{});
}

// A real NSObject map implements the same borrowed/owned resolution boundary as the adapter.
fn nativeOwnershipTest(gpa: std.mem.Allocator) !void {
    var io_provider = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_provider.deinit();
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const owner = try native.NativeAdapter.create(std.testing.allocator, io_provider.io(), .{
        .action_handler = TestProviders.action,
        .activation_sink = .{ .native = .{
            .callback = TestProviders.activate,
            .userdata = null,
        } },
    });
    defer {
        owner.close() catch @panic("native test adapter close failed");
        owner.deinit();
    }
    var weak = owner.context.weak();
    defer weak.deinit();
    const object_class = objc.getClass("NSObject") orelse return error.ObjectiveCUnavailable;
    const target = objc.send(?objc.Object, object_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(target);
    const baseline = objc.send(usize, target, "retainCount", .{});
    defer std.testing.expectEqual(baseline, objc.send(usize, target, "retainCount", .{})) catch
        @panic("native queue leaked a target");
    var providers: TestProviders = .{};
    defer providers.deinit();
    const first = testId(1);
    const removed = testId(2);
    try providers.put(first, target);
    try providers.put(removed, target);
    var owned_targets: Targets = .{
        .view = objc.retain(target),
        .window = objc.retain(target),
    };
    defer {
        if (owned_targets.view) |view| objc.release(view);
        if (owned_targets.window) |window| objc.release(window);
    }
    const queue = try NativeNotifications.create(gpa, weak, owned_targets);
    owned_targets = .{ .view = null, .window = null };
    defer queue.deinit();
    var name = [_:0]u8{ 'n', 'a', 'm', 'e' };
    var text = [_]u8{ 'a', 0, 'b' };
    const source = [_]events.QueuedEvent{
        .{ .generic = .{ .node_id = first, .notification = &name } },
        .{ .announcement = .{ .text = &text, .priority = .high } },
        .{ .node_destroyed = removed },
    };
    queue.prepare(&source, providers.resolver()) catch |err| {
        try std.testing.expect(providers.objects.get(removed) == null);
        return err;
    };
    try std.testing.expect(providers.objects.get(removed) == null);
    name[0] = 'X';
    text[0] = 'X';
    try std.testing.expectEqual(target, queue.items.items[0].notification.target);
    try std.testing.expectEqualStrings("name", queue.items.items[0].notification.name);
    try std.testing.expectEqualSlices(u8, "a\x00b", queue.items.items[1].announcement.text);
    try std.testing.expectEqual(@as(i32, 90), queue.items.items[1].announcement.priority);
    try std.testing.expectEqual(target, queue.items.items[2].notification.target);
    try std.testing.expectEqualStrings(
        events.notificationFor(.node_destroyed).?,
        queue.items.items[2].notification.name,
    );
    try std.testing.expectEqual(baseline + 5, objc.send(usize, target, "retainCount", .{}));
}
test "native notifications keep runtime authority alive after adapter close" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var io_provider = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_provider.deinit();
    var released: u32 = 0;
    const owner = try native.NativeAdapter.create(std.testing.allocator, io_provider.io(), .{
        .action_handler = TestProviders.action,
        .activation_sink = .{ .native = .{
            .callback = TestProviders.activate,
            .userdata = null,
        } },
        .runtime_release = .{ .userdata = &released, .release = TestProviders.releaseRuntime },
    });
    var owner_alive = true;
    defer if (owner_alive) {
        owner.close() catch @panic("native test adapter close failed");
        owner.deinit();
    };
    var weak = owner.context.weak();
    var weak_alive = true;
    defer if (weak_alive) weak.deinit();
    const queue = try NativeNotifications.create(std.testing.allocator, weak, .{
        .view = null,
        .window = null,
    });
    var queue_alive = true;
    defer if (queue_alive) queue.deinit();
    weak.deinit();
    weak_alive = false;
    try owner.close();
    owner.deinit();
    owner_alive = false;
    try std.testing.expectEqual(@as(u32, 0), released);
    queue_alive = false;
    try queue.raiseAndDeinit();
    try std.testing.expectEqual(@as(u32, 1), released);
}

test "native notification nonconsuming failure retains queue until consuming raise" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var io_provider = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_provider.deinit();
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    var released: u32 = 0;
    const owner = try native.NativeAdapter.create(std.testing.allocator, io_provider.io(), .{
        .action_handler = TestProviders.action,
        .activation_sink = .{ .native = .{
            .callback = TestProviders.activate,
            .userdata = null,
        } },
        .runtime_release = .{ .userdata = &released, .release = TestProviders.releaseRuntime },
    });
    var owner_alive = true;
    defer if (owner_alive) {
        owner.close() catch @panic("native test adapter close failed");
        owner.deinit();
    };
    var weak = owner.context.weak();
    var weak_alive = true;
    defer if (weak_alive) weak.deinit();
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const app_class = objc.getClass("NSApplication") orelse return error.ObjectiveCUnavailable;
    const app = objc.send(?objc.Object, app_class, "sharedApplication", .{}) orelse
        return error.NativeObjectCreationFailed;
    _ = app;
    const allocated = objc.send(?objc.Object, window_class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const window = objc.send(?objc.Object, allocated, "initWithContentRect:styleMask:backing:defer:", .{
        objc.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 64, .height = 64 } },
        @as(usize, 0),
        @as(usize, 2),
        @as(u8, 0),
    }) orelse return error.NativeObjectCreationFailed;
    defer objc.release(window);
    const baseline = objc.send(usize, window, "retainCount", .{});
    var owned_targets: Targets = .{
        .view = null,
        .window = objc.retain(window),
    };
    defer if (owned_targets.window) |captured_window| objc.release(captured_window);
    const queue = try NativeNotifications.create(std.testing.allocator, weak, owned_targets);
    owned_targets = .{ .view = null, .window = null };
    var queue_alive = true;
    defer if (queue_alive) queue.deinit();
    var providers: TestProviders = .{};
    defer providers.deinit();
    var invalid = [_]u8{0xff};
    const source = [_]events.QueuedEvent{
        .{ .announcement = .{ .text = &invalid, .priority = .medium } },
    };
    try queue.prepare(&source, providers.resolver());
    weak.deinit();
    weak_alive = false;
    try owner.close();
    owner.deinit();
    owner_alive = false;
    try std.testing.expectError(error.InvalidUtf8, queue.raise());
    try std.testing.expectEqual(baseline + 1, objc.send(usize, window, "retainCount", .{}));
    try std.testing.expectEqual(@as(u32, 0), released);
    try std.testing.expectEqualSlices(u8, &invalid, queue.items.items[0].announcement.text);
    queue_alive = false;
    try std.testing.expectError(error.InvalidUtf8, queue.raiseAndDeinit());
    try std.testing.expectEqual(baseline, objc.send(usize, window, "retainCount", .{}));
    try std.testing.expectEqual(@as(u32, 1), released);
}

test "native consuming raise refuses background thread without spending owned queue" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var io_provider = std.Io.Threaded.init(std.testing.allocator, .{});
    defer io_provider.deinit();
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    var released: u32 = 0;
    const owner = try native.NativeAdapter.create(std.testing.allocator, io_provider.io(), .{
        .action_handler = TestProviders.action,
        .activation_sink = .{ .native = .{
            .callback = TestProviders.activate,
            .userdata = null,
        } },
        .runtime_release = .{ .userdata = &released, .release = TestProviders.releaseRuntime },
    });
    var owner_alive = true;
    defer if (owner_alive) {
        owner.close() catch @panic("native test adapter close failed");
        owner.deinit();
    };
    var weak = owner.context.weak();
    var weak_alive = true;
    defer if (weak_alive) weak.deinit();
    const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const view = objc.send(?objc.Object, view_class, "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(view);
    const baseline = objc.send(usize, view, "retainCount", .{});
    var providers: TestProviders = .{};
    defer providers.deinit();
    const id = testId(3);
    try providers.put(id, view);
    const source_name = try std.testing.allocator.dupeZ(
        u8,
        events.notificationFor(.value_changed).?,
    );
    defer std.testing.allocator.free(source_name);
    var owned_targets: Targets = .{
        .view = objc.retain(view),
        .window = null,
    };
    defer if (owned_targets.view) |captured_view| objc.release(captured_view);
    const queue = try NativeNotifications.create(std.testing.allocator, weak, owned_targets);
    owned_targets = .{ .view = null, .window = null };
    var queue_alive = true;
    defer if (queue_alive) queue.deinit();
    const source = [_]events.QueuedEvent{
        .{ .generic = .{ .node_id = id, .notification = source_name } },
    };
    try queue.prepare(&source, providers.resolver());
    source_name[0] = 'X';
    const map_entry = providers.objects.fetchRemove(id).?;
    objc.release(map_entry.value);
    weak.deinit();
    weak_alive = false;
    try owner.close();
    owner.deinit();
    owner_alive = false;
    var refusal: ?NotificationError = null;
    const background = try std.Thread.spawn(.{}, backgroundConsumingRaise, .{ queue, &refusal });
    background.join();
    // A faulty consuming refusal frees the queue. Detect it before any stale queue access.
    if (released != 0) queue_alive = false;
    try std.testing.expectEqual(@as(u32, 0), released);
    try std.testing.expectEqual(@as(?NotificationError, error.WrongThread), refusal);
    try std.testing.expectEqual(baseline + 2, objc.send(usize, view, "retainCount", .{}));
    try std.testing.expectEqual(view, queue.items.items[0].notification.target);
    try std.testing.expectEqualStrings(
        events.notificationFor(.value_changed).?,
        queue.items.items[0].notification.name,
    );
    queue_alive = false;
    try queue.raiseAndDeinit();
    try std.testing.expectEqual(@as(u32, 1), released);
}

fn backgroundConsumingRaise(queue: *NativeNotifications, refusal: *?NotificationError) void {
    queue.raiseAndDeinit() catch |err| {
        refusal.* = err;
        return;
    };
    refusal.* = null;
}

fn testId(value: u64) FullNodeId {
    return .{ .local = .{ .value = value }, .tree_index = @enumFromInt(0) };
}

const TestProviders = struct {
    objects: std.AutoHashMapUnmanaged(FullNodeId, objc.Object) = .empty,

    fn put(self: *TestProviders, id: FullNodeId, object: objc.Object) !void {
        try self.objects.put(std.testing.allocator, id, object);
        _ = objc.retain(object);
    }

    fn deinit(self: *TestProviders) void {
        var iterator = self.objects.valueIterator();
        while (iterator.next()) |object| objc.release(object.*);
        self.objects.deinit(std.testing.allocator);
    }

    fn resolver(self: *TestProviders) ProviderResolver {
        return .{ .context = self, .provider = provider, .takeRemoved = takeRemoved };
    }

    fn provider(raw: ?*anyopaque, id: FullNodeId) context.NativeError!objc.Object {
        const self: *TestProviders = @ptrCast(@alignCast(raw.?));
        return self.objects.get(id) orelse error.Closed;
    }

    fn takeRemoved(raw: ?*anyopaque, id: FullNodeId) ?objc.Object {
        const self: *TestProviders = @ptrCast(@alignCast(raw.?));
        const entry = self.objects.fetchRemove(id) orelse return null;
        return entry.value;
    }

    fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
    fn activate(_: ?*anyopaque) void {}

    fn releaseRuntime(raw: ?*anyopaque) void {
        const released: *u32 = @ptrCast(@alignCast(raw.?));
        released.* += 1;
    }
};
