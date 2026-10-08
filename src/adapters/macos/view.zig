//! Main-thread NSView attachment; tree publication and explicit host focus updates live in native.zig.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const context = @import("context.zig");
const subclass = @import("subclass.zig");
const patch = @import("patch.zig");

/// Single-owned view attachment. Successful attach consumes weak; refusal leaves it with the caller.
/// The allocator outlives the association, and attach/detach require the AppKit main thread.
/// Copies are not independent owners. Native callback code must remain loaded for process lifetime.
pub const Attachment = struct {
    view: objc.Object,
    associated: objc.Object,
    original_class: objc.Class,
    attached_class: objc.Class,
    attached: bool,

    pub fn attach(
        gpa: std.mem.Allocator,
        weak: context.WeakContext,
        view: objc.Object,
    ) context.NativeError!Attachment {
        if (builtin.os.tag != .macos) return error.NativeUnsupported;
        if (!foundation.isMainThread()) return error.WrongThread;
        const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
        const original_class = objc.object_getClass(view) orelse return error.InvalidView;
        if (!try patch.classDescendsFrom(original_class, view_class)) return error.InvalidView;
        if (objc.objc_getAssociatedObject(view, subclass.associationKey()) != null) {
            return error.AlreadyAttached;
        }
        const associated = try subclass.createAssociation(gpa, original_class);
        errdefer objc.release(associated);
        // The holder owns an independent pin before any callback can see the new isa.
        subclass.stateForAssociation(associated).weak = weak.clone();
        const attached_class = try subclass.classForView(original_class);
        const retained_view = objc.retain(view);
        errdefer objc.release(retained_view);
        objc.objc_setAssociatedObject(
            view,
            subclass.associationKey(),
            associated,
            objc.association_retain,
        );
        errdefer objc.objc_setAssociatedObject(
            view,
            subclass.associationKey(),
            null,
            objc.association_retain,
        );
        if (objc.objc_getAssociatedObject(view, subclass.associationKey()) != associated) {
            return error.NativeObjectCreationFailed;
        }
        const previous = objc.object_setClass(view, attached_class);
        errdefer {
            const restored = objc.object_setClass(view, original_class);
            std.debug.assert(restored != null);
        }
        if (previous != original_class) return error.InvalidView;
        if (objc.object_getClass(view) != attached_class) return error.InvalidView;
        // The holder's immutable clone survives rollback races; success consumes caller ownership.
        var consumed_weak = weak;
        consumed_weak.deinit();
        return .{
            .view = retained_view,
            .associated = associated,
            .original_class = original_class,
            .attached_class = attached_class,
            .attached = true,
        };
    }

    /// Restores the original class before removing the associated state and releasing the view.
    /// The owner checks WrongThread before entering this infallible teardown.
    pub fn detach(self: *Attachment) void {
        if (!self.attached) return;
        std.debug.assert(builtin.os.tag == .macos);
        std.debug.assert(foundation.isMainThread());
        std.debug.assert(objc.object_getClass(self.view) == self.attached_class);
        const previous = objc.object_setClass(self.view, self.original_class);
        std.debug.assert(previous == self.attached_class);
        std.debug.assert(objc.object_getClass(self.view) == self.original_class);
        objc.objc_setAssociatedObject(
            self.view,
            subclass.associationKey(),
            null,
            objc.association_retain,
        );
        std.debug.assert(objc.objc_getAssociatedObject(self.view, subclass.associationKey()) == null);
        self.attached = false;
        objc.release(self.associated);
        objc.release(self.view);
    }
};

// The real view must preserve its layout and superclass answer and regain its original class.
test "native attachment restores class association and rejects duplicate" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const native = @import("native.zig");
    const schema = @import("../../schema/root.zig");
    const Callbacks = struct {
        fn activate(userdata: ?*anyopaque) void {
            const count: *usize = @ptrCast(@alignCast(userdata.?));
            count.* += 1;
        }
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var activation_count: usize = 0;
    const adapter = try native.NativeAdapter.create(std.testing.allocator, threaded.io(), .{
        .action_handler = &Callbacks.action,
        .activation_sink = .{ .native = .{
            .callback = &Callbacks.activate,
            .userdata = &activation_count,
        } },
    });
    var closed = false;
    defer {
        if (!closed) adapter.close() catch @panic("native test adapter close failed");
        adapter.deinit();
    }
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const view_base = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const view_object = objc.send(?objc.Object, @ptrCast(view_base), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(view_object);
    const original = objc.object_getClass(view_object).?;
    try adapter.attach(.{ .view = view_object }, false);
    try std.testing.expect(objc.object_getClass(view_object).? != original);
    try std.testing.expectEqual(objc.class_getSuperclass(original), objc.send(
        ?objc.Class,
        view_object,
        "superclass",
        .{},
    ));
    const selectors = [_][:0]const u8{
        "accessibilityChildren", "accessibilityFocusedUIElement", "accessibilityHitTest:", "superclass",
    };
    for (selectors) |selector| {
        const method = objc.class_getInstanceMethod(
            objc.object_getClass(view_object).?,
            objc.sel(selector),
        ) orelse return error.TestUnexpectedResult;
        if (objc.class_getInstanceMethod(original, objc.sel(selector))) |original_method| {
            try std.testing.expect(objc.method_getImplementation(method) !=
                objc.method_getImplementation(original_method));
        }
    }
    try std.testing.expectError(error.AlreadyAttached, adapter.attach(.{ .view = view_object }, false));
    const associated = objc.retain(objc.objc_getAssociatedObject(
        view_object,
        subclass.associationKey(),
    ).?);
    defer objc.release(associated);
    {
        const other_view = objc.send(?objc.Object, @ptrCast(view_base), "new", .{}) orelse
            return error.NativeObjectCreationFailed;
        defer objc.release(other_view);
        var weak = subclass.stateForAssociation(associated).weak.?.clone();
        defer weak.deinit();
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
        try std.testing.expectError(error.OutOfMemory, Attachment.attach(
            failing.allocator(),
            weak,
            other_view,
        ));
        try std.testing.expectEqual(original, objc.object_getClass(other_view).?);
        try std.testing.expectEqual(@as(?objc.Object, null), objc.objc_getAssociatedObject(
            other_view,
            subclass.associationKey(),
        ));
        var lease = try weak.lease();
        defer lease.deinit();
        // Host superclass dispatch can occur while a native provider already holds the tree guard.
        try std.testing.expectEqual(objc.class_getSuperclass(original), objc.send(
            ?objc.Class,
            view_object,
            "superclass",
            .{},
        ));
    }
    const children = objc.send(?objc.Object, view_object, "accessibilityChildren", .{});
    const focused = objc.send(?objc.Object, view_object, "accessibilityFocusedUIElement", .{});
    const hit = objc.send(?objc.Object, view_object, "accessibilityHitTest:", .{
        objc.NSPoint{ .x = 0, .y = 0 },
    });
    _ = children;
    _ = focused;
    _ = hit;
    try std.testing.expectEqual(@as(usize, 1), activation_count);
    try adapter.close();
    closed = true;
    try std.testing.expectEqual(original, objc.object_getClass(view_object).?);
    try std.testing.expectEqual(@as(?objc.Object, null), objc.objc_getAssociatedObject(
        view_object,
        subclass.associationKey(),
    ));
    const held_state = subclass.stateForAssociation(associated);
    try std.testing.expectError(error.Closed, held_state.weak.?.lease());
}

// The final weak may release Io authority; holder payloads must be freed first.
test "native retained association frees payload before final runtime release" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const native = @import("native.zig");
    const schema = @import("../../schema/root.zig");
    const Probe = struct {
        allocator: *std.testing.FailingAllocator,
        calls: usize = 0,
        reclaimed_before_release: bool = false,
        fn release(userdata: ?*anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(userdata.?));
            self.calls += 1;
            self.reclaimed_before_release =
                self.allocator.allocated_bytes == self.allocator.freed_bytes;
        }
        fn activate(_: ?*anyopaque) void {}
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
    };
    var allocation_counter = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var probe: Probe = .{ .allocator = &allocation_counter };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const adapter = try native.NativeAdapter.create(allocation_counter.allocator(), threaded.io(), .{
        .action_handler = &Probe.action,
        .activation_sink = .{ .native = .{ .callback = &Probe.activate, .userdata = null } },
        .runtime_release = .{ .userdata = &probe, .release = &Probe.release },
    });
    var adapter_live = true;
    defer if (adapter_live) {
        adapter.close() catch @panic("native ownership test close failed");
        adapter.deinit();
    };
    const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const view_object = objc.send(?objc.Object, @ptrCast(view_class), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(view_object);
    const held = capture: {
        var capture_pool = try objc.AutoreleasePool.init();
        defer capture_pool.deinit();
        try adapter.attach(.{ .view = view_object }, false);
        break :capture objc.retain(objc.objc_getAssociatedObject(
            view_object,
            subclass.associationKey(),
        ).?);
    };
    var holder_live = true;
    defer if (holder_live) objc.release(held);
    try adapter.close();
    adapter.deinit();
    adapter_live = false;
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    objc.release(held);
    holder_live = false;
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
    try std.testing.expect(probe.reclaimed_before_release);
}
