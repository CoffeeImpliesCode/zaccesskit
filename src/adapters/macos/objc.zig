//! Minimal non-ARC Objective-C runtime bridge for the AppKit provider.
//! Runtime C declarations come from translate-C over the selected macOS SDK.
//! Only polymorphic messengers need handwritten symbols: message.h requires casts
//! to each call's complete argument/result ABI, which a fixed extern cannot express.
//! ABI authority: https://github.com/apple-oss-distributions/objc4/blob/main/runtime/message.h
//! Runtime authority: https://github.com/apple-oss-distributions/objc4/blob/main/runtime/runtime.h

const std = @import("std");
const builtin = @import("builtin");

const util = @import("util.zig");
pub const sdk = if (builtin.os.tag == .macos) @import("macobjc") else struct {};
pub const Object = *anyopaque;
pub const Class = *anyopaque;
pub const Sel = *anyopaque;
pub const Ivar = *anyopaque;
pub const Method = *anyopaque;
pub const IMP = *const fn () callconv(.c) void;
// The provider represents BOOL as the SDK's one-byte scalar, never Zig bool.
pub const BOOL = u8;
pub const NSPoint = util.NsPoint;
pub const NSSize = util.NsSize;
pub const NSRect = util.NsRect;
pub const NSRange = util.NsRange;
pub const NSNotFound: usize = std.math.maxInt(isize);
pub const Super = extern struct { receiver: ?Object, super_class: Class };
pub const native_supported = builtin.os.tag == .macos and
    (builtin.cpu.arch == .x86_64 or builtin.cpu.arch == .aarch64);
pub const association_retain_nonatomic: usize = if (native_supported)
    sdk.OBJC_ASSOCIATION_RETAIN_NONATOMIC
else
    1;
pub const association_retain: usize = if (native_supported)
    sdk.OBJC_ASSOCIATION_RETAIN
else
    0x301;

comptime {
    if (native_supported) {
        // NSGeometry.h makes NSPoint/NSSize/NSRect aliases of the SDK's CG types on LP64.
        std.debug.assert(@sizeOf(NSPoint) == @sizeOf(sdk.CGPoint));
        std.debug.assert(@alignOf(NSPoint) == @alignOf(sdk.CGPoint));
        std.debug.assert(@offsetOf(NSPoint, "x") == @offsetOf(sdk.CGPoint, "x"));
        std.debug.assert(@offsetOf(NSPoint, "y") == @offsetOf(sdk.CGPoint, "y"));
        std.debug.assert(@sizeOf(NSSize) == @sizeOf(sdk.CGSize));
        std.debug.assert(@alignOf(NSSize) == @alignOf(sdk.CGSize));
        std.debug.assert(@offsetOf(NSSize, "width") == @offsetOf(sdk.CGSize, "width"));
        std.debug.assert(@offsetOf(NSSize, "height") == @offsetOf(sdk.CGSize, "height"));
        std.debug.assert(@sizeOf(NSRect) == @sizeOf(sdk.CGRect));
        std.debug.assert(@alignOf(NSRect) == @alignOf(sdk.CGRect));
        std.debug.assert(@offsetOf(NSRect, "origin") == @offsetOf(sdk.CGRect, "origin"));
        std.debug.assert(@offsetOf(NSRect, "size") == @offsetOf(sdk.CGRect, "size"));
        std.debug.assert(@sizeOf(BOOL) == @sizeOf(sdk.BOOL));
        std.debug.assert(@sizeOf(Object) == @sizeOf(sdk.id));
        std.debug.assert(@sizeOf(usize) == @sizeOf(sdk.objc_AssociationPolicy));
        std.debug.assert(@sizeOf(Super) == @sizeOf(sdk.struct_objc_super));
        std.debug.assert(@alignOf(Super) == @alignOf(sdk.struct_objc_super));
        std.debug.assert(@offsetOf(Super, "receiver") ==
            @offsetOf(sdk.struct_objc_super, "receiver"));
        std.debug.assert(@offsetOf(Super, "super_class") ==
            @offsetOf(sdk.struct_objc_super, "super_class"));
    }
}

pub const RuntimeError = error{
    NativeUnsupported,
    ObjectiveCUnavailable,
    ClassRegistrationFailed,
    MethodRegistrationFailed,
    NativeObjectCreationFailed,
    NativeStringConversionFailed,
    InvalidUtf8,
    RangeOverflow,
    OutOfMemory,
};

fn boolResult(value: anytype) BOOL {
    return if (@TypeOf(value) == bool) @intFromBool(value) else @intFromBool(value != 0);
}

pub fn objc_getClass(name: [*:0]const u8) ?Class {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.objc_getClass(name));
}

pub fn sel_registerName(name: [*:0]const u8) Sel {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.sel_registerName(name).?);
}

pub fn sel_getName(selector: Sel) [*:0]const u8 {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.sel_getName(@ptrCast(@alignCast(selector))));
}

pub fn objc_allocateClassPair(superclass: ?Class, name: [*:0]const u8, extra: usize) ?Class {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.objc_allocateClassPair(@ptrCast(@alignCast(superclass)), name, extra));
}

pub fn objc_registerClassPair(class: Class) void {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    sdk.objc_registerClassPair(@ptrCast(@alignCast(class)));
}

pub fn objc_disposeClassPair(class: Class) void {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    sdk.objc_disposeClassPair(@ptrCast(@alignCast(class)));
}

pub fn class_addMethod(class: Class, selector: Sel, imp: IMP, types: [*:0]const u8) BOOL {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return boolResult(sdk.class_addMethod(@ptrCast(@alignCast(class)),
        @ptrCast(@alignCast(selector)), @ptrCast(imp), types));
}

pub fn class_replaceMethod(class: Class, selector: Sel, imp: IMP, types: [*:0]const u8) ?IMP {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.class_replaceMethod(@ptrCast(@alignCast(class)),
        @ptrCast(@alignCast(selector)), @ptrCast(imp), types));
}

pub fn class_addIvar(class: Class, name: [*:0]const u8, size: usize, alignment: u8,
    types: [*:0]const u8) BOOL
{
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return boolResult(sdk.class_addIvar(@ptrCast(@alignCast(class)), name, size, alignment, types));
}

pub fn class_getInstanceVariable(class: Class, name: [*:0]const u8) ?Ivar {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.class_getInstanceVariable(@ptrCast(@alignCast(class)), name));
}

pub fn class_getInstanceSize(class: Class) usize {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return sdk.class_getInstanceSize(@ptrCast(@alignCast(class)));
}

pub fn class_getName(class: Class) [*:0]const u8 {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.class_getName(@ptrCast(@alignCast(class))));
}

pub fn class_getSuperclass(class: Class) ?Class {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.class_getSuperclass(@ptrCast(@alignCast(class))));
}

pub fn class_getInstanceMethod(class: Class, selector: Sel) ?Method {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.class_getInstanceMethod(@ptrCast(@alignCast(class)),
        @ptrCast(@alignCast(selector))));
}

pub fn class_getMethodImplementation(class: Class, selector: Sel) IMP {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const result = sdk.class_getMethodImplementation(@ptrCast(@alignCast(class)),
        @ptrCast(@alignCast(selector)));
    return @ptrCast(result.?);
}

pub fn method_getImplementation(method: Method) IMP {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const result = sdk.method_getImplementation(@ptrCast(@alignCast(method)));
    return @ptrCast(result.?);
}

pub fn method_getTypeEncoding(method: Method) ?[*:0]const u8 {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return @ptrCast(sdk.method_getTypeEncoding(@ptrCast(@alignCast(method))));
}

pub fn method_setImplementation(method: Method, imp: IMP) IMP {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const result = sdk.method_setImplementation(@ptrCast(@alignCast(method)), @ptrCast(imp));
    return @ptrCast(result.?);
}

// SDK id is an opaque runtime handle, including tagged pointers, not a Zig
// dereferenceable/aligned objc_object. Cast the GENERATED function symbol's pointer
// ABI rather than imposing struct-pointer alignment on legal tagged Foundation values.
pub fn object_getClass(object: ?Object) ?Class {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (?Object) callconv(.c) ?Class = @ptrCast(&sdk.object_getClass);
    return function(object);
}

pub fn object_setClass(object: Object, class: Class) ?Class {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (Object, Class) callconv(.c) ?Class = @ptrCast(&sdk.object_setClass);
    return function(object, class);
}

pub fn object_getIvar(object: ?Object, ivar: Ivar) ?Object {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (?Object, Ivar) callconv(.c) ?Object = @ptrCast(&sdk.object_getIvar);
    return function(object, ivar);
}

pub fn object_setIvar(object: ?Object, ivar: Ivar, value: ?Object) void {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (?Object, Ivar, ?Object) callconv(.c) void =
        @ptrCast(&sdk.object_setIvar);
    function(object, ivar, value);
}

pub fn object_getInstanceVariable(object: ?Object, name: [*:0]const u8,
    value: ?*?*anyopaque) ?Ivar
{
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (?Object, [*:0]const u8, ?*?*anyopaque) callconv(.c) ?Ivar =
        @ptrCast(&sdk.object_getInstanceVariable);
    return function(object, name, value);
}

pub fn object_setInstanceVariable(object: ?Object, name: [*:0]const u8, value: ?*anyopaque) ?Ivar {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (?Object, [*:0]const u8, ?*anyopaque) callconv(.c) ?Ivar =
        @ptrCast(&sdk.object_setInstanceVariable);
    return function(object, name, value);
}

pub fn ivar_getOffset(ivar: Ivar) isize {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    return sdk.ivar_getOffset(@ptrCast(@alignCast(ivar)));
}

pub fn objc_getAssociatedObject(object: Object, key: *const anyopaque) ?Object {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (Object, *const anyopaque) callconv(.c) ?Object =
        @ptrCast(&sdk.objc_getAssociatedObject);
    return function(object, key);
}

pub fn objc_setAssociatedObject(object: Object, key: *const anyopaque,
    value: ?Object, policy: usize) void
{
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (Object, *const anyopaque, ?Object, usize) callconv(.c) void =
        @ptrCast(&sdk.objc_setAssociatedObject);
    function(object, key, value, policy);
}

pub fn objc_loadWeak(location: *?Object) ?Object {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (*?Object) callconv(.c) ?Object = @ptrCast(&sdk.objc_loadWeak);
    return function(location);
}

pub fn objc_storeWeak(location: *?Object, value: ?Object) ?Object {
    if (comptime !native_supported) @panic("Objective-C runtime on unsupported host");
    const function: *const fn (*?Object, ?Object) callconv(.c) ?Object =
        @ptrCast(&sdk.objc_storeWeak);
    return function(location, value);
}
extern fn objc_msgSend() void;
extern fn objc_msgSendSuper() void;
extern fn objc_msgSend_stret() void;
extern fn objc_msgSendSuper_stret() void;

pub fn requireNative() RuntimeError!void {
    if (comptime !native_supported) return error.NativeUnsupported;
}

pub fn getClass(name: [:0]const u8) ?Class {
    if (comptime !native_supported) return null;
    return objc_getClass(name.ptr);
}

pub fn sel(name: [:0]const u8) Sel {
    if (comptime !native_supported) @panic("Objective-C selector on unsupported host");
    return sel_registerName(name.ptr);
}

fn MessageType(comptime Result: type, comptime Prefix: type, comptime Args: type) type {
    const fields = @typeInfo(Args).@"struct".fields;
    comptime var types: [fields.len + 2]type = undefined;
    types[0] = Prefix;
    types[1] = Sel;
    inline for (fields, 0..) |field, index| {
        if (field.type == bool or field.type == comptime_int or field.type == comptime_float) {
            @compileError("Objective-C arguments require explicit ABI types; use BOOL for boolean");
        }
        types[index + 2] = field.type;
    }
    if (Result == bool) @compileError("Objective-C return requires BOOL, not Zig bool");
    if (@typeInfo(Result) == .float and @sizeOf(Result) > 8) {
        @compileError("Objective-C extended floating-point return is not a provider ABI type");
    }
    const attributes = [_]std.builtin.Type.Fn.Param.Attributes{.{}} ** types.len;
    return @Fn(&types, &attributes, Result, .{ .@"callconv" = .c });
}

fn usesStret(comptime Result: type) bool {
    return builtin.cpu.arch == .x86_64 and @typeInfo(Result) == .@"struct" and
        @sizeOf(Result) > 16;
}

/// The tuple must contain explicitly typed C ABI arguments. The caller must have
/// passed requireNative and provide a receiver that supports the selected method.
pub fn send(comptime Result: type, receiver: ?Object, selector: [:0]const u8, args: anytype) Result {
    if (comptime !native_supported) @panic("Objective-C message on unsupported host");
    if (receiver == null) return std.mem.zeroes(Result);
    const Function = MessageType(Result, ?Object, @TypeOf(args));
    // A typed C function pointer lets the compiler insert the hidden result pointer.
    // NSRect uses stret on x86_64, but ARM64 explicitly forbids the stret symbol.
    const function: *const Function = if (comptime usesStret(Result))
        @ptrCast(&objc_msgSend_stret)
    else
        @ptrCast(&objc_msgSend);
    return @call(.auto, function, .{ receiver, sel(selector) } ++ args);
}

/// superclass is the FIRST class searched, as specified by objc_msgSendSuper;
/// this is deliberately not objc_msgSendSuper2's current-class convention.
pub fn sendSuper(comptime Result: type, receiver: ?Object, superclass: Class, selector: [:0]const u8, args: anytype) Result {
    if (comptime !native_supported) @panic("Objective-C superclass message on unsupported host");
    if (receiver == null) return std.mem.zeroes(Result);
    var super: Super = .{ .receiver = receiver, .super_class = superclass };
    const Function = MessageType(Result, *Super, @TypeOf(args));
    const function: *const Function = if (comptime usesStret(Result))
        @ptrCast(&objc_msgSendSuper_stret)
    else
        @ptrCast(&objc_msgSendSuper);
    return @call(.auto, function, .{ &super, sel(selector) } ++ args);
}

pub fn retain(object: Object) Object {
    if (comptime !native_supported) @panic("Objective-C retain on unsupported host");
    return send(Object, object, "retain", .{});
}

pub fn release(object: Object) void {
    if (comptime !native_supported) @panic("Objective-C release on unsupported host");
    send(void, object, "release", .{});
}

pub fn autorelease(object: Object) Object {
    if (comptime !native_supported) @panic("Objective-C autorelease on unsupported host");
    return send(Object, object, "autorelease", .{});
}

pub fn autoreleaseReturn(object: Object) Object {
    if (comptime !native_supported) @panic("Objective-C return on unsupported host");
    // A normal autorelease implements the same +0 return ownership without relying
    // on compiler-private ARC symbols absent from the public SDK.
    return send(Object, object, "autorelease", .{});
}

/// One thread-local pool owner; call deinit exactly once on the creating thread.
pub const AutoreleasePool = struct {
    token: *anyopaque,

    pub fn init() RuntimeError!AutoreleasePool {
        if (comptime !native_supported) return error.NativeUnsupported;
        const class = getClass("NSAutoreleasePool") orelse return error.ObjectiveCUnavailable;
        const token = send(?Object, class, "new", .{}) orelse return error.NativeObjectCreationFailed;
        return .{ .token = token };
    }

    pub fn deinit(self: *AutoreleasePool) void {
        if (comptime !native_supported) @panic("Objective-C pool on unsupported host");
        send(void, self.token, "drain", .{});
        self.* = undefined;
    }
};
