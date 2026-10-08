const std = @import("std");
const builtin = @import("builtin");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");

test "nativeMac runtime rejects unsupported hosts before Objective-C reach" {
    if (builtin.os.tag == .macos) return error.SkipZigTest;
    try std.testing.expectError(error.NativeUnsupported, foundation.string("a\x00b"));
    try std.testing.expectError(error.NativeUnsupported, foundation.array(&.{}));
    try std.testing.expectError(error.NativeUnsupported, foundation.number(42.5));
    try std.testing.expectError(error.NativeUnsupported, foundation.boolean(true));
    try std.testing.expectError(error.NativeUnsupported, foundation.url("https://example.org"));
    try std.testing.expectError(error.NativeUnsupported, objc.AutoreleasePool.init());
    try std.testing.expect(!foundation.isMainThread());
    try std.testing.expect(objc.getClass("NSObject") == null);
}

test "nativeMac NSString preserves embedded NUL and multibyte bytes" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const bytes = "a\x00é𝄞b";
    const value = try foundation.string(bytes);
    defer objc.release(value);
    try std.testing.expectEqualStrings(bytes, try foundation.utf8(value));
    try std.testing.expectError(error.InvalidUtf8, foundation.string("\xff"));
    const empty = try foundation.string("");
    defer objc.release(empty);
    try std.testing.expectEqual(@as(usize, 0), (try foundation.utf8(empty)).len);
}

test "nativeMac NSArray retains objects after caller reference release" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const first = try foundation.string("first\x00last");
    const values = try foundation.array(&.{first});
    defer objc.release(values);
    objc.release(first);
    try std.testing.expectEqual(@as(usize, 1), objc.send(usize, values, "count", .{}));
    const item = objc.send(?objc.Object, values, "objectAtIndex:", .{@as(usize, 0)}).?;
    try std.testing.expectEqualStrings("first\x00last", try foundation.utf8(item));
}

test "nativeMac NSNumber and NSURL return real typed Foundation objects" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const numeric = try foundation.number(-42.25);
    defer objc.release(numeric);
    try std.testing.expectEqual(@as(f64, -42.25), objc.send(f64, numeric, "doubleValue", .{}));
    const truth = try foundation.boolean(true);
    defer objc.release(truth);
    try std.testing.expectEqual(@as(objc.BOOL, 1), objc.send(objc.BOOL, truth, "boolValue", .{}));
    const address = (try foundation.url("https://example.org/path")).?;
    defer objc.release(address);
    const absolute = objc.send(?objc.Object, address, "absoluteString", .{}).?;
    try std.testing.expectEqualStrings("https://example.org/path", try foundation.utf8(absolute));
}

test "nativeMac NSValue roundtrips CGRect and NSRange native ABI" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const rect: objc.NSRect = .{ .origin = .{ .x = 12.25, .y = -9.5 }, .size = .{ .width = 44, .height = 18 } };
    const boxed = try foundation.valueRect(rect);
    defer objc.release(boxed);
    const result = objc.send(objc.NSRect, boxed, "rectValue", .{});
    try std.testing.expectEqual(rect.origin.x, result.origin.x);
    try std.testing.expectEqual(rect.origin.y, result.origin.y);
    try std.testing.expectEqual(rect.size.width, result.size.width);
    try std.testing.expectEqual(rect.size.height, result.size.height);
    const range: objc.NSRange = .{ .location = 7, .length = 4 };
    const boxed_range = try foundation.valueRange(range);
    defer objc.release(boxed_range);
    const range_result = objc.send(objc.NSRange, boxed_range, "rangeValue", .{});
    try std.testing.expectEqual(range.location, range_result.location);
    try std.testing.expectEqual(range.length, range_result.length);
}

test "nativeMac attributed text owns string and color and validates UTF16 ranges" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const color = try foundation.color(0.25, 0.5, 0.75, 1);
    defer objc.release(color);
    const attributes = [_]foundation.Attribute{.{ .key = "NSColor", .value = color }};
    const runs = [_]foundation.AttributeRun{.{ .range = .{ .location = 1, .length = 2 }, .attributes = &attributes }};
    const value = try foundation.attributedString("a𝄞b", &runs);
    defer objc.release(value);
    const backing = objc.send(?objc.Object, value, "string", .{}).?;
    try std.testing.expectEqualStrings("a𝄞b", try foundation.utf8(backing));
    const key = try foundation.string("NSColor");
    defer objc.release(key);
    const selected = objc.send(
        ?objc.Object,
        value,
        "attribute:atIndex:effectiveRange:",
        .{ key, @as(usize, 1), @as(?*objc.NSRange, null) },
    );
    try std.testing.expect(selected != null);
    const invalid = [_]foundation.AttributeRun{.{
        .range = .{ .location = std.math.maxInt(usize), .length = 2 },
        .attributes = &attributes,
    }};
    try std.testing.expectError(error.RangeOverflow, foundation.attributedString("a", &invalid));
}

fn runtimeTestRect(_: objc.Object, _: objc.Sel) callconv(.c) objc.NSRect {
    return .{ .origin = .{ .x = 13.5, .y = -8.25 }, .size = .{ .width = 77, .height = 19 } };
}

test "nativeMac sendSuper uses first superclass and correct large struct return ABI" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const base = objc.objc_allocateClassPair(
        objc.getClass("NSObject").?,
        "ZAccessKitRuntimeTestRectBase",
        0,
    ) orelse return error.ClassRegistrationFailed;
    if (objc.class_addMethod(
        base,
        objc.sel("runtimeTestRect"),
        @ptrCast(&runtimeTestRect),
        "{CGRect={CGPoint=dd}{CGSize=dd}}@:",
    ) == 0) {
        objc.objc_disposeClassPair(base);
        return error.MethodRegistrationFailed;
    }
    objc.objc_registerClassPair(base);
    const derived = objc.objc_allocateClassPair(base, "ZAccessKitRuntimeTestRectDerived", 0) orelse
        return error.ClassRegistrationFailed;
    objc.objc_registerClassPair(derived);
    const instance = objc.send(?objc.Object, derived, "new", .{}).?;
    defer objc.release(instance);
    const rect = objc.sendSuper(objc.NSRect, instance, base, "runtimeTestRect", .{});
    try std.testing.expectEqual(@as(f64, 13.5), rect.origin.x);
    try std.testing.expectEqual(@as(f64, -8.25), rect.origin.y);
    try std.testing.expectEqual(@as(f64, 77), rect.size.width);
    try std.testing.expectEqual(@as(f64, 19), rect.size.height);
}

test "nativeMac associated object survives local release and weak reference becomes nil" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const owner = objc.send(?objc.Object, objc.getClass("NSObject").?, "new", .{}).?;
    defer objc.release(owner);
    const associated = objc.send(?objc.Object, objc.getClass("NSObject").?, "new", .{}).?;
    var weak: ?objc.Object = null;
    _ = objc.objc_storeWeak(&weak, associated);
    defer _ = objc.objc_storeWeak(&weak, null);
    var key: u8 = 0;
    objc.objc_setAssociatedObject(owner, &key, associated, objc.association_retain_nonatomic);
    objc.release(associated);
    try std.testing.expect(objc.objc_getAssociatedObject(owner, &key) != null);
    {
        var query_pool = try objc.AutoreleasePool.init();
        defer query_pool.deinit();
        const pinned = objc.objc_loadWeak(&weak);
        try std.testing.expect(pinned != null);
    }
    objc.objc_setAssociatedObject(owner, &key, null, objc.association_retain_nonatomic);
    try std.testing.expect(objc.objc_loadWeak(&weak) == null);
    try std.testing.expect(objc.objc_getAssociatedObject(owner, &key) == null);
}

test "nativeMac notifications reject invalid UTF8 before posting" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const target = objc.send(?objc.Object, objc.getClass("NSObject").?, "new", .{}).?;
    defer objc.release(target);
    try std.testing.expectError(error.InvalidUtf8, foundation.announce(target, "\xff", 90));
    try std.testing.expectError(error.InvalidUtf8, foundation.post(target, "\xff"));
}

test "nativeMac pointer ivar registration and runtime access agree" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const class = objc.objc_allocateClassPair(
        objc.getClass("NSObject").?,
        "ZAccessKitRuntimeTestPointerIvar",
        0,
    ) orelse return error.ClassRegistrationFailed;
    if (objc.class_addIvar(
        class,
        "runtimePointer",
        @sizeOf(?*anyopaque),
        @intCast(@ctz(@as(usize, @alignOf(?*anyopaque)))),
        "^v",
    ) == 0) {
        objc.objc_disposeClassPair(class);
        return error.ClassRegistrationFailed;
    }
    objc.objc_registerClassPair(class);
    const instance = objc.send(?objc.Object, class, "new", .{}).?;
    defer objc.release(instance);
    var data: u64 = 0x1234_abcd;
    const written = objc.object_setInstanceVariable(instance, "runtimePointer", &data).?;
    const declared = objc.class_getInstanceVariable(class, "runtimePointer").?;
    try std.testing.expectEqual(declared, written);
    var read_back: ?*anyopaque = null;
    const read_ivar = objc.object_getInstanceVariable(instance, "runtimePointer", &read_back).?;
    try std.testing.expectEqual(declared, read_ivar);
    try std.testing.expectEqual(@as(?*anyopaque, &data), read_back);
    const offset = objc.ivar_getOffset(declared);
    try std.testing.expect(offset > 0);
    const slot: *?*anyopaque = @ptrFromInt(@intFromPtr(instance) + @as(usize, @intCast(offset)));
    try std.testing.expectEqual(@as(?*anyopaque, &data), slot.*);
}

test "nativeMac autorelease return lasts through the caller pool and then dies" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var weak: ?objc.Object = null;
    defer _ = objc.objc_storeWeak(&weak, null);
    {
        var caller_pool = try objc.AutoreleasePool.init();
        defer caller_pool.deinit();
        const value = objc.send(?objc.Object, objc.getClass("NSObject").?, "new", .{}).?;
        _ = objc.objc_storeWeak(&weak, value);
        const returned = objc.autoreleaseReturn(value);
        try std.testing.expectEqual(value, returned);
        {
            var query_pool = try objc.AutoreleasePool.init();
            defer query_pool.deinit();
            try std.testing.expectEqual(@as(?objc.Object, value), objc.objc_loadWeak(&weak));
        }
    }
    try std.testing.expect(objc.objc_loadWeak(&weak) == null);
}

test "nativeMac view geometry maps physical pixels to real window screen points" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try std.testing.expect(foundation.isMainThread());
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    _ = objc.send(?objc.Object, objc.getClass("NSApplication").?, "sharedApplication", .{});
    const frame: objc.NSRect = .{
        .origin = .{ .x = 200, .y = 300 },
        .size = .{ .width = 100, .height = 80 },
    };
    const allocated = objc.send(?objc.Object, objc.getClass("NSWindow").?, "alloc", .{}).?;
    const window = objc.send(?objc.Object, allocated, "initWithContentRect:styleMask:backing:defer:", .{
        frame, @as(usize, 0), @as(usize, 2), @as(objc.BOOL, 0),
    }).?;
    defer objc.release(window);
    objc.send(void, window, "setReleasedWhenClosed:", .{@as(objc.BOOL, 0)});
    const view_allocated = objc.send(?objc.Object, objc.getClass("NSView").?, "alloc", .{}).?;
    const view_frame: objc.NSRect = .{
        .origin = .{ .x = 0, .y = 0 },
        .size = frame.size,
    };
    const view = objc.send(?objc.Object, view_allocated, "initWithFrame:", .{view_frame}).?;
    defer objc.release(view);
    try std.testing.expectError(
        error.NativeObjectCreationFailed,
        foundation.fromScreenPoint(view, .{ .x = 0, .y = 0 }),
    );
    objc.send(void, window, "setContentView:", .{view});
    try std.testing.expectEqual(@as(?objc.Object, view), try foundation.contentView(window));
    try std.testing.expectEqual(@as(?objc.Object, window), try foundation.window(view));
    try std.testing.expectEqual(@as(objc.BOOL, 0), objc.send(objc.BOOL, view, "isFlipped", .{}));
    const factor = objc.send(f64, window, "backingScaleFactor", .{});
    const window_frame = objc.send(objc.NSRect, window, "frame", .{});
    const bounds = objc.send(objc.NSRect, view, "bounds", .{});
    const screen = try foundation.toScreenRect(view, .{ .x0 = 12, .y0 = 8, .x1 = 32, .y1 = 28 });
    try std.testing.expectApproxEqAbs(window_frame.origin.x + 12 / factor, screen.origin.x, 0.000001);
    try std.testing.expectApproxEqAbs(
        window_frame.origin.y + bounds.size.height - 28 / factor,
        screen.origin.y,
        0.000001,
    );
    try std.testing.expectApproxEqAbs(20 / factor, screen.size.width, 0.000001);
    try std.testing.expectApproxEqAbs(20 / factor, screen.size.height, 0.000001);
    const point = try foundation.fromScreenPoint(view, .{
        .x = screen.origin.x + screen.size.width * 0.5,
        .y = screen.origin.y + screen.size.height * 0.5,
    });
    try std.testing.expectApproxEqAbs(@as(f64, 22), point.x, 0.000001);
    try std.testing.expectApproxEqAbs(@as(f64, 18), point.y, 0.000001);
    try std.testing.expectEqual(@as(?objc.Object, view), try foundation.hitTest(view, .{ .x = 10, .y = 10 }));
}

test "nativeMac NSDictionary preserves embedded NUL keys and owns values" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const key = try foundation.string("key\x00suffix");
    const value = try foundation.string("value\x00suffix");
    const dictionary = try foundation.dictionary(&.{key}, &.{value});
    defer objc.release(dictionary);
    objc.release(value);
    objc.release(key);
    const lookup_key = try foundation.string("key\x00suffix");
    defer objc.release(lookup_key);
    const found = objc.send(?objc.Object, dictionary, "objectForKey:", .{lookup_key}).?;
    try std.testing.expectEqualStrings("value\x00suffix", try foundation.utf8(found));
    try std.testing.expectError(error.RangeOverflow, foundation.dictionary(&.{lookup_key}, &.{}));
}

test "nativeMac runtime accepts Foundation tagged object handles" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const value = try foundation.integer(7);
    defer objc.release(value);
    try std.testing.expect(objc.object_getClass(value) != null);
    const owner = objc.send(?objc.Object, objc.getClass("NSObject").?, "new", .{}).?;
    defer objc.release(owner);
    var key: u8 = 0;
    objc.objc_setAssociatedObject(owner, &key, value, objc.association_retain_nonatomic);
    const found = objc.objc_getAssociatedObject(owner, &key).?;
    try std.testing.expectEqual(@as(isize, 7), objc.send(isize, found, "integerValue", .{}));
    objc.objc_setAssociatedObject(owner, &key, null, objc.association_retain_nonatomic);
}
