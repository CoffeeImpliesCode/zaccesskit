//! Dynamic view subclass and retained NSObject association, matching pinned subclass.rs.
const std = @import("std");
const objc = @import("objc.zig");
const context = @import("context.zig");
const NativeError = context.NativeError;

const foundation = @import("foundation.zig");
const association_key = "zaccesskit.macos.view-association.key.v1";

pub const State = struct {
    gpa: std.mem.Allocator,
    weak: ?context.WeakContext,
    original_class: objc.Class,
};

pub fn associationKey() *const anyopaque {
    return association_key;
}

/// Returns a runtime subclass without changing the instance layout of the foreign NSView.
pub fn classForView(original: objc.Class) NativeError!objc.Class {
    if (!objc.native_supported) return error.NativeUnsupported;
    if (!foundation.isMainThread()) return error.WrongThread;
    var name_buffer: [64]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buffer, "ZAccessKitView_{x}", .{@intFromPtr(original)}) catch
        return error.ClassRegistrationFailed;
    if (objc.getClass(name)) |existing| {
        if (objc.class_getSuperclass(existing) != original) return error.ClassRegistrationFailed;
        try validateMethod(existing, "superclass", @ptrCast(&originalSuperclass), "#@:");
        try validateMethod(existing, "accessibilityChildren", @ptrCast(&children), "@@:");
        try validateMethod(existing, "accessibilityFocusedUIElement", @ptrCast(&focus), "@@:");
        try validateMethod(existing, "accessibilityHitTest:", @ptrCast(&hitTest), "@@:{CGPoint=dd}");
        return existing;
    }
    const class = objc.objc_allocateClassPair(original, name.ptr, 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    try addMethod(class, "superclass", @ptrCast(&originalSuperclass), "#@:");
    try addMethod(class, "accessibilityChildren", @ptrCast(&children), "@@:");
    try addMethod(class, "accessibilityFocusedUIElement", @ptrCast(&focus), "@@:");
    try addMethod(class, "accessibilityHitTest:", @ptrCast(&hitTest), "@@:{CGPoint=dd}");
    objc.objc_registerClassPair(class);
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
    if (!objc.native_supported) return error.NativeUnsupported;
    if (!foundation.isMainThread()) return error.WrongThread;
    const superclass = objc.getClass("NSObject") orelse return error.ObjectiveCUnavailable;
    if (objc.getClass("ZAccessKitViewAssociation")) |existing| {
        if (objc.class_getSuperclass(existing) != superclass) return error.ClassRegistrationFailed;
        try validateMethod(existing, "dealloc", @ptrCast(&associationDealloc), "v@:");
        _ = try stateOffset(existing);
        return existing;
    }
    const class = objc.objc_allocateClassPair(superclass, "ZAccessKitViewAssociation", 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    if (objc.class_addIvar(
        class,
        "zaccesskit_state",
        @sizeOf(?*State),
        @intCast(@ctz(@alignOf(?*State))),
        "^v",
    ) == 0) return error.ClassRegistrationFailed;
    try addMethod(class, "dealloc", @ptrCast(&associationDealloc), "v@:");
    _ = try stateOffset(class);
    objc.objc_registerClassPair(class);
    return class;
}

fn validateMethod(
    class: objc.Class,
    name: [:0]const u8,
    implementation: objc.IMP,
    encoding: [:0]const u8,
) NativeError!void {
    const method = objc.class_getInstanceMethod(class, objc.sel(name)) orelse
        return error.ClassRegistrationFailed;
    if (objc.method_getImplementation(method) != implementation)
        return error.ClassRegistrationFailed;
    const actual = objc.method_getTypeEncoding(method) orelse return error.ClassRegistrationFailed;
    if (!std.mem.eql(u8, std.mem.span(actual), encoding)) return error.ClassRegistrationFailed;
}

fn stateOffset(class: objc.Class) NativeError!usize {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const ivar = objc.class_getInstanceVariable(class, "zaccesskit_state") orelse
        return error.ClassRegistrationFailed;
    const raw_encoding = objc.sdk.ivar_getTypeEncoding(@ptrCast(@alignCast(ivar)));
    if (raw_encoding == null) return error.ClassRegistrationFailed;
    const encoding: [*:0]const u8 = @ptrCast(raw_encoding);
    if (!std.mem.eql(u8, std.mem.span(encoding), "^v")) return error.ClassRegistrationFailed;
    const offset = objc.ivar_getOffset(ivar);
    if (offset < 0) return error.ClassRegistrationFailed;
    const byte_offset: usize = @intCast(offset);
    if (byte_offset % @alignOf(?*State) != 0) return error.ClassRegistrationFailed;
    const size = objc.class_getInstanceSize(class);
    if (byte_offset > size or size - byte_offset < @sizeOf(?*State))
        return error.ClassRegistrationFailed;
    return byte_offset;
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
    const class = objc.object_getClass(object) orelse @panic("association missing runtime class");
    const offset = stateOffset(class) catch @panic("association state ivar metadata changed");
    return @ptrCast(@alignCast(bytes + offset));
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
    const class = objc.getClass("ZAccessKitViewAssociation") orelse
        @panic("association runtime class disappeared");
    const superclass = objc.class_getSuperclass(class) orelse
        @panic("association superclass disappeared");
    objc.sendSuper(void, this, superclass, "dealloc", .{});
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

// Both lookup and dispatch metadata come from actual registered SDK classes.
test "native view subclass registration repeats with validated SDK metadata" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const original = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const first = try classForView(original);
    const repeated = try classForView(original);
    try std.testing.expectEqual(first, repeated);
    try std.testing.expectEqual(original, objc.class_getSuperclass(first).?);
    const original_probe = objc.objc_allocateClassPair(
        original,
        "ZAccessKitSubclassCollisionOriginal",
        0,
    ) orelse return error.ClassRegistrationFailed;
    objc.objc_registerClassPair(original_probe);
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(
        &name_buffer,
        "ZAccessKitView_{x}",
        .{@intFromPtr(original_probe)},
    );
    const collision = objc.objc_allocateClassPair(original_probe, name.ptr, 0) orelse
        return error.ClassRegistrationFailed;
    objc.objc_registerClassPair(collision);
    try std.testing.expectError(error.ClassRegistrationFailed, classForView(original_probe));
    try std.testing.expectEqual(collision, objc.getClass(name).?);
}

// Allocation refusal must not publish a subclass for a previously unseen NSView class.
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
    var name_buffer: [64]u8 = undefined;
    const name = try std.fmt.bufPrintZ(
        &name_buffer,
        "ZAccessKitView_{x}",
        .{@intFromPtr(original)},
    );
    try std.testing.expect(objc.getClass(name) == null);
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, view.Attachment.attach(
        failing.allocator(),
        weak,
        target,
    ));
    try std.testing.expect(objc.getClass(name) == null);
    try std.testing.expectEqual(original, objc.object_getClass(target).?);
    try std.testing.expectEqual(@as(?objc.Object, null), objc.objc_getAssociatedObject(
        target,
        associationKey(),
    ));
    var lease = try weak.lease();
    defer lease.deinit();
}
