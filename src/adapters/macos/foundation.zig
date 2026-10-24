//! Owned Foundation/AppKit values. Constructors return +1; utf8 and SDK constants borrow.
//! No Zig heap allocation is needed: each collection initializer copies/retains inputs.
//! Call inside an autorelease scope; notifications and view geometry require the
//! AppKit main thread. The native adapter checks WrongThread before reaching them.
//! NSString ABI: https://developer.apple.com/documentation/foundation/nsstring
//! AppKit SDK: https://github.com/phracker/MacOSX-SDKs
//! Headers: MacOSX11.3.sdk/System/Library/Frameworks/AppKit.framework/Versions/C/Headers
//! Parent verification must compare reached declarations with its actual target SDK.

const std = @import("std");
const objc = @import("objc.zig");
const schema = @import("../../schema/root.zig");

pub const Object = objc.Object;
pub const RuntimeError = objc.RuntimeError;
pub const utf8_encoding: usize = 4;
pub const collection_count_max: usize = std.math.maxInt(isize);

pub const AccessibilityTextConstant = enum {
    background_color,
    foreground_color,
    font,
    font_family,
    font_size,
    underline,
    underline_color,
    strikethrough,
    strikethrough_color,
    language,
    text_alignment,
};

/// Borrows an immutable, process-lifetime NSString from the selected AppKit SDK.
/// Do not release it. Font family/size are nested font-dictionary keys; the other
/// constants identify attributes on the accessibility attributed string.
pub fn accessibilityTextConstant(comptime constant: AccessibilityTextConstant) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const value = switch (constant) {
        .background_color => objc.sdk.zaccesskit_macos_ax_background_color(),
        .foreground_color => objc.sdk.zaccesskit_macos_ax_foreground_color(),
        .font => objc.sdk.zaccesskit_macos_ax_font(),
        .font_family => objc.sdk.zaccesskit_macos_ax_font_family(),
        .font_size => objc.sdk.zaccesskit_macos_ax_font_size(),
        .underline => objc.sdk.zaccesskit_macos_ax_underline(),
        .underline_color => objc.sdk.zaccesskit_macos_ax_underline_color(),
        .strikethrough => objc.sdk.zaccesskit_macos_ax_strikethrough(),
        .strikethrough_color => objc.sdk.zaccesskit_macos_ax_strikethrough_color(),
        .language => objc.sdk.zaccesskit_macos_ax_language(),
        .text_alignment => objc.sdk.zaccesskit_macos_ax_text_alignment(),
    } orelse return error.ObjectiveCUnavailable;
    // Objective-C handles do not encode NSString pointee constness; this cast
    // removes only the pure-C projection's annotation, not the SDK ownership.
    return @constCast(value);
}

fn allocate(class_name: [:0]const u8) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const class = objc.getClass(class_name) orelse return error.ObjectiveCUnavailable;
    return objc.send(?Object, class, "alloc", .{}) orelse error.NativeObjectCreationFailed;
}

fn checkedCount(count: usize) RuntimeError!void {
    if (count > collection_count_max) return error.RangeOverflow;
}

pub fn string(bytes: []const u8) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    try checkedCount(bytes.len);
    if (!std.unicode.utf8ValidateSlice(bytes)) return error.InvalidUtf8;
    const allocated = try allocate("NSString");
    // init consumes the allocated receiver even when it returns nil.
    return objc.send(?Object, allocated, "initWithBytes:length:encoding:", .{
        @as([*]const u8, bytes.ptr), bytes.len, utf8_encoding,
    }) orelse error.NativeObjectCreationFailed;
}

/// The slice is valid only while the receiving NSString and its autorelease scope
/// remain live. UTF8String has an inner-pointer lifetime; embedded NUL is not a terminator.
pub fn utf8(value: Object) RuntimeError![]const u8 {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const pointer = objc.send(?[*]const u8, value, "UTF8String", .{}) orelse
        return error.NativeStringConversionFailed;
    const count = objc.send(usize, value, "lengthOfBytesUsingEncoding:", .{utf8_encoding});
    try checkedCount(count);
    if (count == 0 and objc.send(usize, value, "length", .{}) != 0) {
        return error.NativeStringConversionFailed;
    }
    return pointer[0..count];
}

pub fn array(values: []const Object) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    try checkedCount(values.len);
    const allocated = try allocate("NSArray");
    return objc.send(?Object, allocated, "initWithObjects:count:", .{
        @as([*]const Object, values.ptr), values.len,
    }) orelse error.NativeObjectCreationFailed;
}

pub fn number(value: f64) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, try allocate("NSNumber"), "initWithDouble:", .{value}) orelse
        error.NativeObjectCreationFailed;
}

pub fn integer(value: isize) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, try allocate("NSNumber"), "initWithInteger:", .{value}) orelse
        error.NativeObjectCreationFailed;
}

pub fn boolean(value: bool) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, try allocate("NSNumber"), "initWithBool:", .{
        @as(objc.BOOL, @intFromBool(value)),
    }) orelse error.NativeObjectCreationFailed;
}

/// A nil result means NSURL rejected the string, not a constructed fake value.
pub fn url(bytes: []const u8) RuntimeError!?Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const text = try string(bytes);
    defer objc.release(text);
    return objc.send(?Object, try allocate("NSURL"), "initWithString:", .{text});
}

pub fn dictionary(keys: []const Object, values: []const Object) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    try checkedCount(keys.len);
    if (keys.len != values.len) return error.RangeOverflow;
    return objc.send(?Object, try allocate("NSDictionary"), "initWithObjects:forKeys:count:", .{
        @as([*]const Object, values.ptr), @as([*]const Object, keys.ptr), keys.len,
    }) orelse error.NativeObjectCreationFailed;
}

pub fn valuePoint(point: objc.NSPoint) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const class = objc.getClass("NSValue") orelse return error.ObjectiveCUnavailable;
    const value = objc.send(?Object, class, "valueWithPoint:", .{point}) orelse
        return error.NativeObjectCreationFailed;
    return objc.retain(value);
}

pub fn valueSize(size: objc.NSSize) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const class = objc.getClass("NSValue") orelse return error.ObjectiveCUnavailable;
    const value = objc.send(?Object, class, "valueWithSize:", .{size}) orelse
        return error.NativeObjectCreationFailed;
    return objc.retain(value);
}

pub fn valueRect(rect: objc.NSRect) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const class = objc.getClass("NSValue") orelse return error.ObjectiveCUnavailable;
    const value = objc.send(?Object, class, "valueWithRect:", .{rect}) orelse
        return error.NativeObjectCreationFailed;
    return objc.retain(value);
}

pub fn valueRange(range: objc.NSRange) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const class = objc.getClass("NSValue") orelse return error.ObjectiveCUnavailable;
    const value = objc.send(?Object, class, "valueWithRange:", .{range}) orelse
        return error.NativeObjectCreationFailed;
    return objc.retain(value);
}

pub fn color(red: f64, green: f64, blue: f64, alpha: f64) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const class = objc.getClass("NSColor") orelse return error.ObjectiveCUnavailable;
    const value = objc.send(?Object, class, "colorWithSRGBRed:green:blue:alpha:", .{
        red, green, blue, alpha,
    }) orelse return error.NativeObjectCreationFailed;
    return objc.retain(value);
}

/// Borrowed CGColor; keep ns_color live until the attributed string retains it.
pub fn cgColor(ns_color: Object) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, ns_color, "CGColor", .{}) orelse error.NativeObjectCreationFailed;
}

pub const Attribute = struct { key: []const u8, value: Object };
pub const AttributeRun = struct { range: objc.NSRange, attributes: []const Attribute };

pub fn attributedString(bytes: []const u8, runs: []const AttributeRun) RuntimeError!Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    try checkedCount(runs.len);
    const text = try string(bytes);
    defer objc.release(text);
    const length = objc.send(usize, text, "length", .{});
    // Validate every UTF-16 range before AppKit's exception-raising mutator.
    for (runs) |run| {
        try checkedCount(run.attributes.len);
        const end = std.math.add(usize, run.range.location, run.range.length) catch
            return error.RangeOverflow;
        if (end > length) return error.RangeOverflow;
        for (run.attributes) |attribute| {
            if (!std.unicode.utf8ValidateSlice(attribute.key)) return error.InvalidUtf8;
        }
    }
    const result = objc.send(
        ?Object,
        try allocate("NSMutableAttributedString"),
        "initWithString:",
        .{text},
    ) orelse return error.NativeObjectCreationFailed;
    errdefer objc.release(result);
    for (runs) |run| {
        for (run.attributes) |attribute| {
            const key = try string(attribute.key);
            defer objc.release(key);
            objc.send(void, result, "addAttribute:value:range:", .{
                key, attribute.value, run.range,
            });
        }
    }
    return result;
}

pub fn post(node: Object, name: [:0]const u8) RuntimeError!void {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const notification = try string(name);
    defer objc.release(notification);
    objc.sdk.zaccesskit_macos_post_notification(node, notification);
}

pub fn announce(window_object: Object, text: []const u8, priority: i32) RuntimeError!void {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const announcement = try string(text);
    defer objc.release(announcement);
    const priority_value = try integer(priority);
    defer objc.release(priority_value);
    const announcement_key = objc.sdk.zaccesskit_macos_announcement_key() orelse
        return error.ObjectiveCUnavailable;
    const priority_key = objc.sdk.zaccesskit_macos_priority_key() orelse
        return error.ObjectiveCUnavailable;
    const notification = objc.sdk.zaccesskit_macos_announcement_requested_notification() orelse
        return error.ObjectiveCUnavailable;
    const info = try dictionary(&.{ announcement_key, priority_key }, &.{
        announcement, priority_value,
    });
    defer objc.release(info);
    objc.sdk.zaccesskit_macos_post_notification_with_user_info(window_object, notification, info);
}

pub fn isMainThread() bool {
    if (comptime !objc.native_supported) return false;
    const class = objc.getClass("NSThread") orelse return false;
    return objc.send(objc.BOOL, class, "isMainThread", .{}) != 0;
}

pub fn window(view: Object) RuntimeError!?Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, view, "window", .{});
}

pub fn contentView(window_object: Object) RuntimeError!?Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, window_object, "contentView", .{});
}

pub fn hitTest(view: Object, point: objc.NSPoint) RuntimeError!?Object {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    return objc.send(?Object, view, "hitTest:", .{point});
}

/// Screen to physical view coordinates; callers apply the node's inverse transform.
/// Pinned AccessKit util.rs:39-55 deliberately applies that transform AFTER conversion.
pub fn fromScreenPoint(view: Object, point: objc.NSPoint) RuntimeError!schema.Point {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const window_object = objc.retain((try window(view)) orelse
        return error.NativeObjectCreationFailed);
    defer objc.release(window_object);
    const window_point = objc.send(objc.NSPoint, window_object, "convertPointFromScreen:", .{point});
    const view_point = objc.send(objc.NSPoint, view, "convertPoint:fromView:", .{
        window_point, @as(?Object, null),
    });
    const factor = objc.send(f64, window_object, "backingScaleFactor", .{});
    if (!std.math.isFinite(factor) or factor <= 0) return error.RangeOverflow;
    const flipped = objc.send(objc.BOOL, view, "isFlipped", .{}) != 0;
    const y = if (flipped) view_point.y else objc.send(objc.NSRect, view, "bounds", .{}).size.height - view_point.y;
    return .{ .x = view_point.x * factor, .y = y * factor };
}

/// Physical view rectangle to logical screen points, pinned util.rs:57-83.
pub fn toScreenRect(view: Object, rect: schema.Rect) RuntimeError!objc.NSRect {
    if (comptime !objc.native_supported) return error.NativeUnsupported;
    const window_object = objc.retain((try window(view)) orelse
        return error.NativeObjectCreationFailed);
    defer objc.release(window_object);
    const factor = objc.send(f64, window_object, "backingScaleFactor", .{});
    if (!std.math.isFinite(factor) or factor <= 0) return error.RangeOverflow;
    const flipped = objc.send(objc.BOOL, view, "isFlipped", .{}) != 0;
    const y = if (flipped)
        rect.y0 / factor
    else
        objc.send(objc.NSRect, view, "bounds", .{}).size.height - rect.y1 / factor;
    const local: objc.NSRect = .{
        .origin = .{ .x = rect.x0 / factor, .y = y },
        .size = .{ .width = (rect.x1 - rect.x0) / factor, .height = (rect.y1 - rect.y0) / factor },
    };
    const in_window = objc.send(objc.NSRect, view, "convertRect:toView:", .{
        local, @as(?Object, null),
    });
    return objc.send(objc.NSRect, window_object, "convertRectToScreen:", .{in_window});
}

test "nativeMac SDK text constant getters refuse unsupported hosts" {
    if (comptime objc.native_supported) return error.SkipZigTest;
    inline for (@typeInfo(AccessibilityTextConstant).@"enum".field_values) |field_value| {
        try std.testing.expectError(error.NativeUnsupported, accessibilityTextConstant(@fromBackingInt(@intCast(field_value))));
    }
}

test "nativeMac SDK text constants are distinct borrowed NSString dictionary keys" {
    if (comptime !objc.native_supported) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const ns_string = objc.getClass("NSString") orelse return error.ObjectiveCUnavailable;
    const count = @typeInfo(AccessibilityTextConstant).@"enum".field_names.len;
    var keys: [count]Object = undefined;
    {
        var getter_pool = try objc.AutoreleasePool.init();
        defer getter_pool.deinit();
        inline for (@typeInfo(AccessibilityTextConstant).@"enum".field_values, 0..) |field_value, i| {
            keys[i] = try accessibilityTextConstant(@fromBackingInt(@intCast(field_value)));
        }
    }
    // SDK constants remain usable after the getter's temporary autorelease scope.
    for (keys, 0..) |key, i| {
        try std.testing.expect(objc.send(objc.BOOL, key, "isKindOfClass:", .{ns_string}) != 0);
        try std.testing.expect(std.unicode.utf8ValidateSlice(try utf8(key)));
        for (keys[0..i]) |previous| {
            try std.testing.expect(objc.send(objc.BOOL, key, "isEqual:", .{previous}) == 0);
        }
    }
    var values: [count]Object = undefined;
    var owned: usize = 0;
    defer for (values[0..owned]) |value| objc.release(value);
    for (&values, 0..) |*value, i| {
        value.* = try integer(@intCast(i));
        owned += 1;
    }
    const map = try dictionary(&keys, &values);
    defer objc.release(map);
    for (values) |value| objc.release(value);
    owned = 0;
    for (keys, 0..) |key, i| {
        const value = objc.send(?Object, map, "objectForKey:", .{key}) orelse
            return error.NativeObjectCreationFailed;
        try std.testing.expectEqual(@as(isize, @intCast(i)), objc.send(isize, value, "integerValue", .{}));
    }
}
