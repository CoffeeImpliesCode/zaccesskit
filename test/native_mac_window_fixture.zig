//! A real AppKit caller-owned window class must survive native attachment unchanged.
//! All runtime calls use the SDK-backed Objective-C helpers in the published package.
const std = @import("std");
const builtin = @import("builtin");
const package = @import("zaccesskit");
const macos = package.adapters.macos;
const objc = macos.objc;
const foundation = macos.foundation;

pub fn checkAttachPreservesWindowClass(gpa: std.mem.Allocator, io: std.Io) !void {
    if (comptime builtin.os.tag == .macos and
        (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64))
    {
        try checkNativeAttachPreservesWindowClass(gpa, io);
    } else {
        return error.NativeUnsupported;
    }
}

const Object = objc.Object;
const Class = objc.Class;
const Selector = objc.Sel;
const Method = objc.Method;
const Implementation = objc.IMP;

fn checkNativeAttachPreservesWindowClass(gpa: std.mem.Allocator, io: std.Io) !void {
    if (!foundation.isMainThread()) return error.WrongThread;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();

    const application_class = objc.getClass("NSApplication") orelse
        return error.ObjectiveCUnavailable;
    const application = objc.send(?Object, application_class, "sharedApplication", .{}) orelse
        return error.NativeObjectCreationFailed;
    const retained_application = objc.retain(application);
    defer objc.release(retained_application);

    const window_class = try callerWindowClass();
    const allocated_window = objc.send(?Object, window_class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const rectangle: objc.NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = .{ .width = 160, .height = 100 },
    };
    // NSRect is passed by value using the C ABI on both supported LP64 architectures.
    // These initializers return id, so neither architecture uses objc_msgSend_stret.
    const window = objc.send(
        ?Object,
        allocated_window,
        "initWithContentRect:styleMask:backing:defer:",
        .{ rectangle, @as(usize, 0), @as(usize, 2), @as(objc.BOOL, 1) },
    ) orelse return error.NativeObjectCreationFailed;
    defer {
        objc.send(void, window, "close", .{});
        objc.release(window);
    }
    // Closing must not consume the fixture's alloc/init ownership.
    objc.send(void, window, "setReleasedWhenClosed:", .{@as(objc.BOOL, 0)});

    const view_class = objc.getClass("NSView") orelse return error.ObjectiveCUnavailable;
    const allocated_view = objc.send(?Object, view_class, "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const content_view = objc.send(?Object, allocated_view, "initWithFrame:", .{rectangle}) orelse
        return error.NativeObjectCreationFailed;
    defer objc.release(content_view);
    objc.send(void, window, "setContentView:", .{content_view});
    const attached_view = objc.send(?Object, window, "contentView", .{}) orelse
        return error.ObjectiveCUnavailable;
    try std.testing.expectEqual(content_view, attached_view);

    const focus_selector = objc.sel("accessibilityFocusedUIElement");
    const class_before = objc.object_getClass(window) orelse return error.ObjectiveCUnavailable;
    try std.testing.expectEqual(window_class, class_before);
    const method_before = objc.class_getInstanceMethod(class_before, focus_selector) orelse
        return error.ObjectiveCUnavailable;
    const implementation_before = objc.method_getImplementation(method_before);
    const caller_implementation: Implementation = @ptrCast(&callerWindowFocusedUIElement);
    try std.testing.expectEqual(caller_implementation, implementation_before);
    const focused_before = objc.send(?Object, window, "accessibilityFocusedUIElement", .{}) orelse
        return error.ObjectiveCUnavailable;
    try std.testing.expectEqual(window, focused_before);

    const NativeAdapter = package.adapters.macos.NativeAdapter;
    const native = try NativeAdapter.create(gpa, io, .{
        .action_handler = unexpectedAction,
        .activation_sink = .{ .native = .{
            .callback = unexpectedActivation,
            .userdata = null,
        } },
        .userdata = null,
        .runtime_release = null,
    });
    // Capture assertion/attach errors so close and deinit precede all host releases.
    const attachment_result = attachAndCheck(
        native,
        window,
        class_before,
        method_before,
        implementation_before,
        focus_selector,
    );
    const close_result = native.close();
    native.deinit();
    try attachment_result;
    try close_result;
}

fn attachAndCheck(
    native: *package.adapters.macos.NativeAdapter,
    window: Object,
    class_before: Class,
    method_before: Method,
    implementation_before: Implementation,
    focus_selector: Selector,
) !void {
    // The optional irreversible class focus patch is deliberately never installed.
    try native.attach(.{ .window = window }, false);
    const class_after = objc.object_getClass(window) orelse return error.ObjectiveCUnavailable;
    try std.testing.expectEqual(class_before, class_after);
    const method_after = objc.class_getInstanceMethod(class_after, focus_selector) orelse
        return error.ObjectiveCUnavailable;
    try std.testing.expectEqual(method_before, method_after);
    const implementation_after = objc.method_getImplementation(method_after);
    try std.testing.expectEqual(implementation_before, implementation_after);
    const focused_after = objc.send(?Object, window, "accessibilityFocusedUIElement", .{}) orelse
        return error.ObjectiveCUnavailable;
    try std.testing.expectEqual(window, focused_after);
}

fn callerWindowClass() !Class {
    const class_name = "ZAccessKitNativeContractCallerWindow";
    const superclass = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const focus_selector = objc.sel("accessibilityFocusedUIElement");
    const caller_implementation: Implementation = @ptrCast(&callerWindowFocusedUIElement);
    // Registered classes have process lifetime; repeat calls reuse and verify this exact class.
    if (objc.getClass(class_name)) |existing| {
        const existing_superclass = objc.class_getSuperclass(existing) orelse
            return error.ObjectiveCUnavailable;
        try std.testing.expectEqual(superclass, existing_superclass);
        const existing_method = objc.class_getInstanceMethod(existing, focus_selector) orelse
            return error.ObjectiveCUnavailable;
        try std.testing.expectEqual(
            caller_implementation,
            objc.method_getImplementation(existing_method),
        );
        return existing;
    }
    const class = objc.objc_allocateClassPair(superclass, class_name, 0) orelse
        return error.ObjectiveCUnavailable;
    if (objc.class_addMethod(class, focus_selector, caller_implementation, "@@:") == 0) {
        objc.objc_disposeClassPair(class);
        return error.ObjectiveCUnavailable;
    }
    objc.objc_registerClassPair(class);
    return class;
}

fn callerWindowFocusedUIElement(receiver: Object, _: Selector) callconv(.c) ?Object {
    return receiver;
}

fn unexpectedAction(_: ?*anyopaque, _: *const package.schema.ActionRequest) void {
    @panic("attaching an unfocused window must not dispatch an action");
}

fn unexpectedActivation(_: ?*anyopaque) void {
    @panic("the caller's window focus override must not activate the provider");
}
