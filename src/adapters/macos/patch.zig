//! Irreversible NSWindow accessibility focus forwarding, matching pinned patch.rs.
const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const NativeError = @import("context.zig").NativeError;

pub const class_limit = 1024;
pub const superclass_depth_limit = 1024;

// The SDK cannot remove methods. Main-thread admission serializes this process-lifetime registry.
var installed_classes: [class_limit]objc.Class = undefined;
var installed_class_count: usize = 0;

/// Installs the upstream window-to-content-view focus dispatch. No allocator state escapes.
/// This module's code must remain loaded for the entire process after a successful call.
/// Refuses non-window classes, conflicting methods, off-main-thread calls and registry exhaustion.
pub fn installFocusForwarderForClass(
    _: std.mem.Allocator,
    class: objc.Class,
) NativeError!void {
    if (builtin.os.tag != .macos) return error.NativeUnsupported;
    if (!foundation.isMainThread()) return error.WrongThread;
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    if (!try classDescendsFrom(class, window_class)) return error.InvalidView;
    const selector = objc.sel("accessibilityFocusedUIElement");
    const implementation: objc.IMP = @ptrCast(&focusForwarder);
    for (installed_classes[0..installed_class_count]) |installed_class| {
        if (installed_class != class) continue;
        const method = objc.class_getInstanceMethod(class, selector) orelse
            return error.MethodRegistrationFailed;
        if (objc.method_getImplementation(method) != implementation) {
            return error.MethodRegistrationFailed;
        }
        const encoding = objc.method_getTypeEncoding(method) orelse
            return error.MethodRegistrationFailed;
        if (!std.mem.eql(u8, std.mem.span(encoding), "@@:")) {
            return error.MethodRegistrationFailed;
        }
        return;
    }
    if (installed_class_count == class_limit) return error.ProviderLimitExceeded;
    // class_addMethod refuses an own override, but intentionally allows inherited NSWindow methods.
    if (objc.class_addMethod(class, selector, implementation, "@@:") == 0) {
        return error.MethodRegistrationFailed;
    }
    installed_classes[installed_class_count] = class;
    installed_class_count += 1;
}

/// Looks up a real runtime class; the same irreversible lifetime contract applies.
pub fn installFocusForwarderForClassNamed(
    gpa: std.mem.Allocator,
    name: [:0]const u8,
) NativeError!void {
    if (builtin.os.tag != .macos) return error.NativeUnsupported;
    if (!foundation.isMainThread()) return error.WrongThread;
    const class = objc.getClass(name) orelse return error.ObjectiveCUnavailable;
    try installFocusForwarderForClass(gpa, class);
}

pub fn classDescendsFrom(class: objc.Class, ancestor: objc.Class) NativeError!bool {
    var current: ?objc.Class = class;
    for (0..superclass_depth_limit) |_| {
        const candidate = current orelse return false;
        if (candidate == ancestor) return true;
        current = objc.class_getSuperclass(candidate);
    }
    if (current == null) return false;
    return error.ProviderLimitExceeded;
}

fn focusForwarder(this: objc.Object, _: objc.Sel) callconv(.c) ?objc.Object {
    const content_view = objc.send(?objc.Object, this, "contentView", .{}) orelse return null;
    return objc.send(?objc.Object, content_view, "accessibilityFocusedUIElement", .{});
}

// These tests exercise real Objective-C dispatch; foreign-target compilation is not execution.
test "native window forwards focus to its content view and repeats exactly" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const application_class = objc.getClass("NSApplication") orelse return error.ObjectiveCUnavailable;
    const application = objc.send(?objc.Object, @ptrCast(application_class), "sharedApplication", .{});
    try std.testing.expect(application != null);
    const view_base = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const view_class = objc.objc_allocateClassPair(view_base, "ZAccessKitFocusTestView", 0) orelse
        return error.ClassRegistrationFailed;
    try std.testing.expect(objc.class_addMethod(
        view_class,
        objc.sel("accessibilityFocusedUIElement"),
        @ptrCast(&testFocusSelf),
        "@@:",
    ) != 0);
    objc.objc_registerClassPair(view_class);
    const view_object = objc.send(?objc.Object, @ptrCast(view_class), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(view_object);
    const window_base = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const window_class = objc.objc_allocateClassPair(window_base, "ZAccessKitFocusTestWindow", 0) orelse
        return error.ClassRegistrationFailed;
    objc.objc_registerClassPair(window_class);
    try installFocusForwarderForClass(std.testing.allocator, window_class);
    try installFocusForwarderForClassNamed(std.testing.allocator, "ZAccessKitFocusTestWindow");
    const window = objc.send(?objc.Object, @ptrCast(window_class), "new", .{}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(window);
    objc.send(void, window, "setContentView:", .{view_object});
    try std.testing.expectEqual(view_object, objc.send(
        ?objc.Object,
        window,
        "accessibilityFocusedUIElement",
        .{},
    ).?);
}

test "native focus patch rejects foreign class missing class and conflicting method" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const object_class = objc.getClass("NSObject") orelse return error.ObjectiveCUnavailable;
    try std.testing.expectError(error.InvalidView, installFocusForwarderForClass(
        std.testing.allocator,
        object_class,
    ));
    try std.testing.expectError(error.ObjectiveCUnavailable, installFocusForwarderForClassNamed(
        std.testing.allocator,
        "ZAccessKitAbsentWindowClass",
    ));
    const window_base = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const class = objc.objc_allocateClassPair(window_base, "ZAccessKitConflictingWindow", 0) orelse
        return error.ClassRegistrationFailed;
    try std.testing.expect(objc.class_addMethod(
        class,
        objc.sel("accessibilityFocusedUIElement"),
        @ptrCast(&testFocusSelf),
        "@@:",
    ) != 0);
    objc.objc_registerClassPair(class);
    try std.testing.expectError(error.MethodRegistrationFailed, installFocusForwarderForClass(
        std.testing.allocator,
        class,
    ));
}

fn testFocusSelf(this: objc.Object, _: objc.Sel) callconv(.c) ?objc.Object {
    return this;
}

// Only the registry-capacity premise is injected; class lookup and refusal use the SDK runtime.
test "native focus registry saturation refuses before mutating the window class" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const window_base = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const class = objc.objc_allocateClassPair(window_base, "ZAccessKitSaturatedWindow", 0) orelse
        return error.ClassRegistrationFailed;
    objc.objc_registerClassPair(class);
    const before = objc.class_getInstanceMethod(class, objc.sel("accessibilityFocusedUIElement"));
    const saved_count = installed_class_count;
    defer installed_class_count = saved_count;
    @memset(installed_classes[saved_count..], window_base);
    installed_class_count = class_limit;
    try std.testing.expectError(error.ProviderLimitExceeded, installFocusForwarderForClass(
        std.testing.allocator,
        class,
    ));
    try std.testing.expectEqual(before, objc.class_getInstanceMethod(
        class,
        objc.sel("accessibilityFocusedUIElement"),
    ));
}

test "native focus patch rejects background thread before runtime mutation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const Attempt = struct {
        fn run(class: objc.Class, refused: *bool) void {
            installFocusForwarderForClass(std.testing.allocator, class) catch |err| {
                refused.* = err == error.WrongThread;
                return;
            };
            refused.* = false;
        }
    };
    var refused = false;
    const thread = try std.Thread.spawn(.{}, Attempt.run, .{ window_class, &refused });
    thread.join();
    try std.testing.expect(refused);
}

test "non macOS focus installation explicitly refuses native operation" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    try std.testing.expectError(error.NativeUnsupported, installFocusForwarderForClassNamed(
        std.testing.allocator,
        "NSWindow",
    ));
}
