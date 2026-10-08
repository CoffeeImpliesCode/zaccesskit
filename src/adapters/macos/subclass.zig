//! Dynamic view subclass and retained NSObject association, matching pinned subclass.rs.
const std = @import("std");
const objc = @import("objc.zig");
const context = @import("context.zig");
const NativeError = context.NativeError;

pub const class_limit = 1024;
const Entry = struct { original: objc.Class, subclass: objc.Class };

// Registration is main-thread-only; runtime classes and implementations have process-code lifetime.
var subclasses: [class_limit]Entry = undefined;
var subclass_count: usize = 0;
var associated_class: ?objc.Class = null;
var associated_superclass: ?objc.Class = null;
var state_offset: usize = 0;
var association_key: u8 = 0;

pub const State = struct {
    gpa: std.mem.Allocator,
    weak: ?context.WeakContext,
    original_class: objc.Class,
};

pub fn associationKey() *const anyopaque {
    return &association_key;
}

/// Returns a runtime subclass without changing the instance layout of the foreign NSView.
pub fn classForView(original: objc.Class) NativeError!objc.Class {
    for (subclasses[0..subclass_count]) |entry| {
        if (entry.original == original) return entry.subclass;
    }
    if (subclass_count == class_limit) return error.ProviderLimitExceeded;
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buffer, "ZAccessKitView_{x}", .{@intFromPtr(original)}) catch
        return error.ClassRegistrationFailed;
    const class = objc.objc_allocateClassPair(original, name.ptr, 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    try addMethod(class, "superclass", @ptrCast(&originalSuperclass), "#@:");
    try addMethod(class, "accessibilityChildren", @ptrCast(&children), "@@:");
    try addMethod(class, "accessibilityFocusedUIElement", @ptrCast(&focus), "@@:");
    try addMethod(class, "accessibilityHitTest:", @ptrCast(&hitTest), "@@:{CGPoint=dd}");
    objc.objc_registerClassPair(class);
    subclasses[subclass_count] = .{ .original = original, .subclass = class };
    subclass_count += 1;
    return class;
}

/// Allocates an actual associated NSObject. Weak ownership is assigned only at attach commit.
pub fn createAssociation(gpa: std.mem.Allocator, original: objc.Class) NativeError!objc.Object {
    const class = try associationClass();
    const state = try gpa.create(State);
    errdefer gpa.destroy(state);
    state.* = .{ .gpa = gpa, .weak = null, .original_class = original };
    const object = objc.send(?objc.Object, @ptrCast(class), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    stateSlot(object).* = state;
    return object;
}

pub fn stateForAssociation(object: objc.Object) *State {
    return stateSlot(object).* orelse @panic("missing associated view state");
}

fn associationClass() NativeError!objc.Class {
    if (associated_class) |class| return class;
    const superclass = objc.getClass("NSObject") orelse return error.ObjectiveCUnavailable;
    const class = objc.objc_allocateClassPair(superclass, "ZAccessKitViewAssociation", 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    if (objc.class_addIvar(
        class, "zaccesskit_state", @sizeOf(?*State), @intCast(@ctz(@alignOf(?*State))), "^v",
    ) == 0) return error.ClassRegistrationFailed;
    try addMethod(class, "dealloc", @ptrCast(&associationDealloc), "v@:");
    const ivar = objc.class_getInstanceVariable(class, "zaccesskit_state") orelse
        return error.ClassRegistrationFailed;
    const offset = objc.ivar_getOffset(ivar);
    if (offset < 0) return error.ClassRegistrationFailed;
    state_offset = @intCast(offset);
    associated_superclass = superclass;
    objc.objc_registerClassPair(class);
    associated_class = class;
    return class;
}

fn addMethod(
    class: objc.Class,
    name: [:0]const u8,
    implementation: objc.IMP,
    encoding: [:0]const u8,
) NativeError!void {
    if (objc.class_addMethod(class, objc.sel(name), implementation, encoding.ptr) == 0) {
        return error.MethodRegistrationFailed;
    }
}

fn stateSlot(object: objc.Object) *?*State {
    const bytes: [*]u8 = @ptrCast(object);
    return @ptrCast(@alignCast(bytes + state_offset));
}

fn associationDealloc(this: objc.Object, _: objc.Sel) callconv(.c) void {
    if (stateSlot(this).*) |state| {
        stateSlot(this).* = null;
        const gpa = state.gpa;
        var weak = state.weak;
        gpa.destroy(state);
        // Final weak release may return allocator and Io ownership to the host.
        if (weak) |*owned_weak| owned_weak.deinit();
    }
    // The superclass is immutable once this real runtime class becomes visible.
    objc.sendSuper(void, this, associated_superclass.?, "dealloc", .{});
}

const PinnedState = struct { object: objc.Object, state: *State };

fn stateForView(view: objc.Object) ?PinnedState {
    // Atomic association policy pins the getter result under the runtime lock. The extra retain
    // keeps it alive even if activation causes a nested autorelease-pool drain.
    const associated = objc.objc_getAssociatedObject(view, associationKey()) orelse return null;
    const pinned = objc.retain(associated);
    const state = stateSlot(pinned).* orelse {
        objc.release(pinned);
        return null;
    };
    return .{ .object = pinned, .state = state };
}

fn originalSuperclass(this: objc.Object, _: objc.Sel) callconv(.c) ?objc.Class {
    const pinned = stateForView(this) orelse return null;
    defer objc.release(pinned.object);
    // Immutable original isa needs no tree lease, including reentrant native superclass queries.
    return objc.class_getSuperclass(pinned.state.original_class);
}

fn children(this: objc.Object, _: objc.Sel) callconv(.c) ?objc.Object {
    const pinned = stateForView(this) orelse return null;
    defer objc.release(pinned.object);
    const weak = pinned.state.weak orelse return null;
    var lease = weak.lease() catch return null;
    defer lease.deinit();
    lease.requestActivation();
    const result = (lease.viewChildren() catch return null) orelse return null;
    return objc.autoreleaseReturn(result);
}

fn focus(this: objc.Object, _: objc.Sel) callconv(.c) ?objc.Object {
    const pinned = stateForView(this) orelse return null;
    defer objc.release(pinned.object);
    const weak = pinned.state.weak orelse return null;
    var lease = weak.lease() catch return null;
    defer lease.deinit();
    lease.requestActivation();
    const result = (lease.focus() catch return null) orelse return null;
    return objc.autoreleaseReturn(result);
}

fn hitTest(this: objc.Object, _: objc.Sel, point: objc.NSPoint) callconv(.c) ?objc.Object {
    const pinned = stateForView(this) orelse return null;
    defer objc.release(pinned.object);
    const weak = pinned.state.weak orelse return null;
    var lease = weak.lease() catch return null;
    defer lease.deinit();
    lease.requestActivation();
    const result = (lease.hitTest(point) catch return null) orelse return null;
    return objc.autoreleaseReturn(result);
}

// Objective-C allocation is real; fail-N injection covers the Zig state allocation and dealloc.
test "native associated NSObject releases its Zig state at final release" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const original = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const Exercise = struct {
        const TestError = NativeError || error{ TestExpectedEqual, TestUnexpectedResult };
        fn run(gpa: std.mem.Allocator, class: objc.Class) TestError!void {
            const associated = try createAssociation(gpa, class);
            defer objc.release(associated);
            const state = stateForAssociation(associated);
            try std.testing.expectEqual(class, state.original_class);
            try std.testing.expect(state.weak == null);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Exercise.run, .{original});
}

// The fixed registry count is an injected premise; no native subclass is fabricated or reported.
test "native view subclass registry saturation refuses without registering another class" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const original = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const probe = objc.objc_allocateClassPair(original, "ZAccessKitSubclassLimitProbe", 0) orelse
        return error.ClassRegistrationFailed;
    defer objc.objc_disposeClassPair(probe);
    const saved_count = subclass_count;
    defer subclass_count = saved_count;
    @memset(subclasses[saved_count..], .{ .original = original, .subclass = original });
    subclass_count = class_limit;
    try std.testing.expectError(error.ProviderLimitExceeded, classForView(probe));
}

// An allocation refusal must not irreversibly spend a slot for a previously unseen NSView class.
test "native unseen original view allocation refusal leaves subclass registry unchanged" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const native = @import("native.zig");
    const view = @import("view.zig");
    const schema = @import("../../schema/root.zig");
    const Callbacks = struct {
        fn activate(_: ?*anyopaque) void {}
        fn action(_: ?*anyopaque, _: *const schema.ActionRequest) void {}
    };
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const adapter = try native.NativeAdapter.create(std.testing.allocator, threaded.io(), .{
        .action_handler = &Callbacks.action,
        .activation_sink = .{ .native = .{ .callback = &Callbacks.activate, .userdata = null } },
    });
    defer {
        adapter.close() catch @panic("native unseen-class test close failed");
        adapter.deinit();
    }
    const base = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const source = objc.send(?objc.Object, @ptrCast(base), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(source);
    try adapter.attach(.{ .view = source }, false);
    const source_holder = objc.objc_getAssociatedObject(source, associationKey()).?;
    var weak = stateForAssociation(source_holder).weak.?.clone();
    defer weak.deinit();
    const original = objc.objc_allocateClassPair(base, "ZAccessKitUnseenOriginalFailN", 0) orelse
        return error.ClassRegistrationFailed;
    objc.objc_registerClassPair(original);
    const target = objc.send(?objc.Object, @ptrCast(original), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(target);
    const before = subclass_count;
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, view.Attachment.attach(
        failing.allocator(), weak, target,
    ));
    try std.testing.expectEqual(before, subclass_count);
    try std.testing.expectEqual(original, objc.object_getClass(target).?);
    try std.testing.expectEqual(@as(?objc.Object, null), objc.objc_getAssociatedObject(
        target, associationKey(),
    ));
    var lease = try weak.lease();
    defer lease.deinit();
}
