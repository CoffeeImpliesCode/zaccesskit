//! Windows strings, automation values, and coordinates from AccessKit at
//! `466e24e252103f4d82bd6fbab98141b551e46e0c`, `adapters/windows/src/util.rs`.
//! Reach these functions through the Windows namespace's `util` module.
//! Owners borrow `AutomationApi` until cleanup or transfer. Do not copy them as second owners.
//! Native allocation and window calls use the injected table. This module installs no native table.

const std = @import("std");
const builtin = @import("builtin");
const TreeState = @import("../../consumer/tree_state.zig").TreeState;
const testing = std.testing;
const bindings = @import("bindings.zig");
const schema = @import("../../schema/root.zig");
const text_range = @import("../../consumer/text/range.zig");

/// Conversion failures and the native resource errors this module preserves.
pub const AutomationError = error{
    OutOfMemory,
    InvalidUtf8,
    InvalidUtf16,
    StringTooLong,
    ArrayTooLong,
    InvalidArgument,
    BadVariantType,
    BadArrayIndex,
    ArrayLocked,
    UnexpectedNativeFailure,
    LocaleNameInvalid,
    WindowUnavailable,
    WindowTitleTooLong,
};

/// Native allocation authority, borrowed by each owner until cleanup or transfer.
/// Slots run synchronously on the calling thread. Their arguments are borrowed for that call.
/// String allocation accepts a null source for writable storage with a trailing zero.
/// Array insertion copies scalars and retains COM values. It must not retain or lock the array.
/// Clear and destroy failures leave resources owned by the caller for retry.
/// Callbacks may reenter disjoint owners, but must not mutate this call's owner.
pub const AutomationApi = struct {
    context: ?*anyopaque = null,
    alloc_string_len: *const fn (?*anyopaque, ?[*]const u16, u32) ?bindings.Bstr,
    string_len: *const fn (?*anyopaque, bindings.Bstr) u32,
    free_string: *const fn (?*anyopaque, bindings.Bstr) void,
    variant_clear: *const fn (?*anyopaque, *bindings.Variant) bindings.Hresult,
    array_create_vector: *const fn (?*anyopaque, u16, i32, u32) ?*bindings.SafeArray,
    array_put_element: *const fn (
        ?*anyopaque,
        *bindings.SafeArray,
        *const i32,
        *const anyopaque,
    ) bindings.Hresult,
    array_destroy: *const fn (?*anyopaque, *bindings.SafeArray) bindings.Hresult,
    reserved_mixed_value: *const fn (?*anyopaque, *?*bindings.IUnknown) bindings.Hresult,
    reserved_not_supported_value: *const fn (?*anyopaque, *?*bindings.IUnknown) bindings.Hresult,
    host_provider_from_hwnd: *const fn (
        ?*anyopaque,
        bindings.Hwnd,
        *?*bindings.IRawElementProviderSimple,
    ) bindings.Hresult,
    locale_name_to_lcid: *const fn (?*anyopaque, [*:0]const u16, u32) u32,
    client_to_screen: *const fn (?*anyopaque, bindings.Hwnd, *bindings.Point) bindings.Bool,
    def_window_proc: *const fn (
        ?*anyopaque,
        bindings.Hwnd,
        u32,
        bindings.Wparam,
        bindings.Lparam,
    ) bindings.Lresult,
};

/// The BSTR byte-count prefix must fit in u32, excluding the trailing zero.
pub const bstr_units_max: usize = @divFloor(std.math.maxInt(u32), @sizeOf(u16));
/// UTF-8 can use at most three bytes per UTF-16 unit accepted by counted BSTR storage.
pub const utf8_bytes_max: usize = std.math.mul(usize, bstr_units_max, 3) catch
    std.math.maxInt(usize);
/// Every zero-based SAFEARRAY index must fit in a signed LONG.
pub const array_elements_max: usize = std.math.maxInt(i32);
/// LocaleNameToLCID accepts at most 84 code units before its trailing zero.
pub const locale_name_units_max: usize = 84;
/// WM_GETTEXT uses a signed LONG-sized character count, including its trailing zero.
pub const window_title_units_max: usize = std.math.maxInt(i32) - 1;

const vt_empty: u16 = 0;
const vt_i4: u16 = 3;
const vt_r8: u16 = 5;
const vt_bstr: u16 = 8;
const vt_bool: u16 = 11;
const vt_unknown: u16 = 13;
const vt_array: u16 = 0x2000;

/// Reads the native VARTYPE word, including flags absent from zigwin32's closed VARENUM enum.
pub fn variantType(raw: *const bindings.Variant) u16 {
    const tag: *const u16 = @ptrCast(raw);
    return tag.*;
}

fn taggedVariant(tag: u16) bindings.Variant {
    var raw = std.mem.zeroes(bindings.Variant);
    const native_tag: *u16 = @ptrCast(&raw);
    native_tag.* = tag;
    return raw;
}

/// Preserves documented allocation, array, and VARIANT failures from an HRESULT.
pub fn checkAutomationStatus(status: bindings.Hresult) AutomationError!void {
    if (!status.failed) return;
    return switch (@as(u32, @bitCast(status))) {
        0x8007000e => error.OutOfMemory,
        0x80070057 => error.InvalidArgument,
        0x80020008 => error.BadVariantType,
        0x8002000b => error.BadArrayIndex,
        0x8002000d => error.ArrayLocked,
        else => error.UnexpectedNativeFailure,
    };
}

/// Owns one raw VARIANT and borrows its allocation authority.
/// Copies share resources and must not be cleaned as independent owners.
/// Use `take` to transfer, or `deinit` to clear. These operations reset this owner after success.
pub const VariantOwner = struct {
    api: *const AutomationApi,
    raw: bindings.Variant,

    /// Constructs VT_EMPTY without allocation.
    pub fn init(api: *const AutomationApi) VariantOwner {
        return .{ .api = api, .raw = taggedVariant(vt_empty) };
    }

    /// Reports VT_EMPTY, including the state left after cleanup or transfer.
    pub fn isEmpty(self: *const VariantOwner) bool {
        return variantType(&self.raw) == vt_empty;
    }

    /// Clears once. Failure preserves this owner's resources for a later retry.
    pub fn deinit(self: *VariantOwner) AutomationError!void {
        if (!self.isEmpty()) {
            try checkAutomationStatus(self.api.variant_clear(self.api.context, &self.raw));
        }
        self.* = .{ .api = self.api, .raw = taggedVariant(vt_empty) };
    }

    /// Transfers the raw value. The recipient must clear it with the same allocation authority.
    pub fn take(self: *VariantOwner) bindings.Variant {
        const raw = self.raw;
        self.raw = taggedVariant(vt_empty);
        return raw;
    }

    /// Encodes VARIANT_BOOL as -1 for true and 0 for false.
    pub fn fromBool(api: *const AutomationApi, value: bool) VariantOwner {
        var result: VariantOwner = .{ .api = api, .raw = taggedVariant(vt_bool) };
        result.raw.Anonymous.Anonymous.Anonymous.boolVal = if (value) -1 else 0;
        return result;
    }

    /// Encodes a signed LONG as VT_I4.
    pub fn fromI32(api: *const AutomationApi, value: i32) VariantOwner {
        var result: VariantOwner = .{ .api = api, .raw = taggedVariant(vt_i4) };
        result.raw.Anonymous.Anonymous.Anonymous.lVal = value;
        return result;
    }

    /// Encodes a double as VT_R8 without rounding or coercion.
    pub fn fromF64(api: *const AutomationApi, value: f64) VariantOwner {
        var result: VariantOwner = .{ .api = api, .raw = taggedVariant(vt_r8) };
        result.raw.Anonymous.Anonymous.Anonymous.dblVal = value;
        return result;
    }

    /// Takes one caller-owned BSTR. Null is VT_BSTR with no allocation, not VT_EMPTY.
    pub fn fromOwnedBstr(api: *const AutomationApi, value: ?bindings.Bstr) VariantOwner {
        var result: VariantOwner = .{ .api = api, .raw = taggedVariant(vt_bstr) };
        result.raw.Anonymous.Anonymous.Anonymous.bstrVal = value;
        return result;
    }

    /// Copies UTF-8 through counted BSTR allocation. Errors leave no owned result.
    pub fn fromUtf8(api: *const AutomationApi, value: []const u8) AutomationError!VariantOwner {
        return fromOwnedBstr(api, try utf8ToBstr(api, value));
    }

    /// Copies native UTF-16 units, including embedded NUL and unpaired surrogates.
    pub fn fromUtf16(api: *const AutomationApi, value: []const u16) AutomationError!VariantOwner {
        return fromOwnedBstr(api, try utf16ToBstr(api, value));
    }

    /// Retains a borrowed interface with AddRef before constructing VT_UNKNOWN.
    pub fn fromUnknown(api: *const AutomationApi, value: *bindings.IUnknown) VariantOwner {
        _ = value.AddRef();
        return fromOwnedUnknown(api, value);
    }

    /// Takes one owned interface reference, without an additional AddRef.
    pub fn fromOwnedUnknown(api: *const AutomationApi, value: *bindings.IUnknown) VariantOwner {
        var result: VariantOwner = .{ .api = api, .raw = taggedVariant(vt_unknown) };
        result.raw.Anonymous.Anonymous.Anonymous.punkVal = value;
        return result;
    }

    /// Packs RGB as COLORREF and omits alpha, as upstream `util.rs:226-232` does.
    pub fn fromColor(api: *const AutomationApi, value: schema.Color) VariantOwner {
        const rgb = @as(u32, value.red) | (@as(u32, value.green) << 8) |
            (@as(u32, value.blue) << 16);
        return fromI32(api, @intCast(rgb));
    }

    /// Returns VT_EMPTY for no COM values, otherwise an owned VT_ARRAY | VT_UNKNOWN.
    /// Inputs remain borrowed. Every inserted element gets one array-owned reference.
    pub fn fromComSlice(
        api: *const AutomationApi,
        values: []const *bindings.IUnknown,
    ) AutomationError!VariantOwner {
        if (values.len == 0) return init(api);
        var array = try safeArrayFromComSlice(api, values);
        return array.intoVariant(vt_unknown);
    }

    /// Converts a locale to VT_I4. An unknown locale becomes VT_EMPTY, as upstream specifies.
    /// Allocation and encoding failures remain errors rather than absent values.
    pub fn fromLocaleName(
        gpa: std.mem.Allocator,
        api: *const AutomationApi,
        name: []const u8,
    ) AutomationError!VariantOwner {
        const lcid = localeNameToLcid(gpa, api, name) catch |failure| switch (failure) {
            error.LocaleNameInvalid => return init(api),
            else => return failure,
        };
        return fromI32(api, lcid);
    }

    /// Takes the UIA mixed-value singleton reference returned by the allocation authority.
    pub fn mixed(api: *const AutomationApi) AutomationError!VariantOwner {
        var value: ?*bindings.IUnknown = null;
        try checkAutomationStatus(api.reserved_mixed_value(api.context, &value));
        return fromOwnedUnknown(api, value orelse return error.UnexpectedNativeFailure);
    }

    /// Takes the UIA not-supported singleton reference, distinct from VT_EMPTY.
    pub fn notSupported(api: *const AutomationApi) AutomationError!VariantOwner {
        var value: ?*bindings.IUnknown = null;
        try checkAutomationStatus(api.reserved_not_supported_value(api.context, &value));
        return fromOwnedUnknown(api, value orelse return error.UnexpectedNativeFailure);
    }

    /// Converts upstream scalar, enum, optional, string, color, and decoration values.
    /// A null optional becomes VT_EMPTY. Enum values must use the native i32 UIA domain.
    /// Unsupported input types cause a compile error instead of runtime coercion.
    pub fn fromValue(
        api: *const AutomationApi,
        comptime T: type,
        value: T,
    ) AutomationError!VariantOwner {
        if (T == bool) return fromBool(api, value);
        if (T == i32) return fromI32(api, value);
        if (T == f64) return fromF64(api, value);
        if (T == []const u8 or T == []u8) return fromUtf8(api, value);
        if (T == []const u16 or T == []u16) return fromUtf16(api, value);
        if (T == bindings.Bstr) return fromOwnedBstr(api, value);
        if (T == *bindings.IUnknown) return fromUnknown(api, value);
        if (T == []const *bindings.IUnknown) return fromComSlice(api, value);
        if (T == schema.Color) return fromColor(api, value);
        if (T == schema.TextDecoration) return fromValue(api, schema.TextDecorationStyle, value.style);
        if (T == schema.TextDecorationStyle) return fromI32(api, @backingInt(switch (value) {
            .solid => bindings.uia.TextDecorationLineStyle.Single,
            .dotted => bindings.uia.TextDecorationLineStyle.Dot,
            .dashed => bindings.uia.TextDecorationLineStyle.Dash,
            .double => bindings.uia.TextDecorationLineStyle.Double,
            .wavy => bindings.uia.TextDecorationLineStyle.Wavy,
        }));
        if (T == schema.TextAlign) return fromI32(api, @backingInt(switch (value) {
            .left => bindings.uia.HorizontalTextAlignment.Left,
            .center => bindings.uia.HorizontalTextAlignment.Centered,
            .right => bindings.uia.HorizontalTextAlignment.Right,
            .justify => bindings.uia.HorizontalTextAlignment.Justified,
        }));
        switch (@typeInfo(T)) {
            .optional => |optional| {
                if (value) |present| return fromValue(api, optional.child, present);
                return init(api);
            },
            .@"enum" => return fromI32(api, @intCast(@backingInt(value))),
            else => @compileError("Automation value needs bool, i32, f64, UTF string, COM, or UIA enum."),
        }
    }

    /// Converts a uniform optional text property, or obtains UIA's reserved mixed value.
    pub fn fromRangeProperty(
        api: *const AutomationApi,
        comptime T: type,
        value: text_range.RangePropertyValue(T),
    ) AutomationError!VariantOwner {
        return switch (value) {
            .single => |single| fromValue(api, ?T, single),
            .mixed => mixed(api),
        };
    }
};

/// Owns one SAFEARRAY, or no array after transfer or cleanup.
/// The allocation authority stays live until cleanup. Copies are not independent owners.
pub const ArrayOwner = struct {
    api: *const AutomationApi,
    raw: ?*bindings.SafeArray,

    /// Destroys once. A failed destroy leaves the array owned for retry.
    pub fn deinit(self: *ArrayOwner) AutomationError!void {
        if (self.raw) |raw| {
            try checkAutomationStatus(self.api.array_destroy(self.api.context, raw));
        }
        self.* = .{ .api = self.api, .raw = null };
    }

    /// Transfers the array. Its recipient must destroy it with the same allocation authority.
    pub fn take(self: *ArrayOwner) ?*bindings.SafeArray {
        const raw = self.raw;
        self.raw = null;
        return raw;
    }

    /// Transfers a non-null array into VARIANT. `element_vt` must match its creation type.
    pub fn intoVariant(self: *ArrayOwner, element_vt: u16) VariantOwner {
        std.debug.assert(self.raw != null);
        std.debug.assert(element_vt == vt_i4 or element_vt == vt_r8 or element_vt == vt_unknown);
        var result: VariantOwner = .{ .api = self.api, .raw = taggedVariant(vt_array | element_vt) };
        result.raw.Anonymous.Anonymous.Anonymous.parray = self.take();
        return result;
    }
};

/// Copies signed LONGs into a zero-based VT_I4 SAFEARRAY, including an allocated empty array.
/// Allocation or insertion errors release all partial values and leave the caller owning nothing.
pub fn safeArrayFromI32Slice(
    api: *const AutomationApi,
    values: []const i32,
) AutomationError!ArrayOwner {
    return safeArrayFromSlice(i32, api, vt_i4, values);
}

/// Copies doubles into a zero-based VT_R8 SAFEARRAY with the same failure guarantee.
pub fn safeArrayFromF64Slice(
    api: *const AutomationApi,
    values: []const f64,
) AutomationError!ArrayOwner {
    return safeArrayFromSlice(f64, api, vt_r8, values);
}

/// Builds VT_UNKNOWN, retaining each borrowed interface once, including repeated references.
/// Partial cleanup releases every successfully inserted reference.
pub fn safeArrayFromComSlice(
    api: *const AutomationApi,
    values: []const *bindings.IUnknown,
) AutomationError!ArrayOwner {
    return safeArrayFromSlice(*bindings.IUnknown, api, vt_unknown, values);
}

fn safeArrayFromSlice(
    comptime T: type,
    api: *const AutomationApi,
    element_vt: u16,
    values: []const T,
) AutomationError!ArrayOwner {
    if (values.len > array_elements_max) return error.ArrayTooLong;
    const array = api.array_create_vector(api.context, element_vt, 0, @intCast(values.len)) orelse
        return error.OutOfMemory;
    var owner: ArrayOwner = .{ .api = api, .raw = array };
    errdefer owner.deinit() catch |failure| {
        // An unexposed array cannot be locked. A backend violation cannot discard its sole owner.
        @panic(@errorName(failure));
    };
    for (values, 0..) |*value, position| {
        const index: i32 = @intCast(position);
        const element: *const anyopaque = if (T == *bindings.IUnknown) value.* else value;
        try checkAutomationStatus(api.array_put_element(api.context, array, &index, element));
    }
    return owner;
}

/// Copies counted native UTF-16 into a BSTR. The caller releases it with `api.free_string`.
/// Unpaired surrogates and embedded NUL are copied, not interpreted as terminators.
pub fn utf16ToBstr(api: *const AutomationApi, value: []const u16) AutomationError!bindings.Bstr {
    if (value.len > bstr_units_max) return error.StringTooLong;
    return api.alloc_string_len(api.context, value.ptr, @intCast(value.len)) orelse
        error.OutOfMemory;
}

/// Decodes UTF-8 directly into counted BSTR storage, without an intermediate allocation.
/// The caller releases the result with `api.free_string`. Errors retain no allocation.
pub fn utf8ToBstr(api: *const AutomationApi, value: []const u8) AutomationError!bindings.Bstr {
    if (value.len > utf8_bytes_max) return error.StringTooLong;
    const count = std.unicode.calcUtf16LeLen(value) catch return error.InvalidUtf8;
    if (count > bstr_units_max) return error.StringTooLong;
    const string = api.alloc_string_len(api.context, null, @intCast(count)) orelse
        return error.OutOfMemory;
    errdefer api.free_string(api.context, string);
    const units: [*]u16 = @ptrCast(string);
    const written = try std.unicode.utf8ToUtf16Le(units[0..count], value);
    std.debug.assert(written == count);
    if (comptime builtin.cpu.arch.endian() == .big) {
        for (units[0..count]) |*unit| unit.* = std.mem.littleToNative(u16, unit.*);
    }
    units[count] = 0;
    return string;
}

fn nextUtf16Codepoint(value: []const u16, index: *usize) AutomationError!u21 {
    const first = value[index.*];
    index.* += 1;
    if (first >= 0xd800 and first <= 0xdbff) {
        if (index.* == value.len) return error.InvalidUtf16;
        const second = value[index.*];
        if (second < 0xdc00 or second > 0xdfff) return error.InvalidUtf16;
        index.* += 1;
        return 0x10000 + (@as(u21, first - 0xd800) << 10) + (second - 0xdc00);
    }
    if (first >= 0xdc00 and first <= 0xdfff) return error.InvalidUtf16;
    return first;
}

/// Copies a counted BSTR into caller-owned UTF-8. Null stays null. Empty stays allocated empty.
/// Invalid UTF-16 fails without a result. Release a present result with `gpa.free`.
pub fn bstrToUtf8(
    gpa: std.mem.Allocator,
    api: *const AutomationApi,
    value: ?bindings.Bstr,
) AutomationError!?[]u8 {
    const string = value orelse return null;
    const count = api.string_len(api.context, string);
    if (count > bstr_units_max) return error.StringTooLong;
    const units: [*]const u16 = @ptrCast(string);
    const bytes = try utf16ToUtf8(gpa, units[0..count]);
    return bytes;
}

/// Copies counted native UTF-16 into UTF-8, including embedded NUL.
/// The caller frees the result with `gpa.free`. Invalid input leaves no allocation.
pub fn utf16ToUtf8(gpa: std.mem.Allocator, source: []const u16) AutomationError![]u8 {
    if (source.len > bstr_units_max) return error.StringTooLong;
    var index: usize = 0;
    var byte_count: usize = 0;
    while (index < source.len) {
        const codepoint = try nextUtf16Codepoint(source, &index);
        const sequence_bytes = std.unicode.utf8CodepointSequenceLength(codepoint) catch
            return error.InvalidUtf16;
        byte_count = std.math.add(usize, byte_count, sequence_bytes) catch
            return error.StringTooLong;
    }
    const bytes = try gpa.alloc(u8, byte_count);
    errdefer gpa.free(bytes);
    index = 0;
    var position: usize = 0;
    while (index < source.len) {
        const codepoint = try nextUtf16Codepoint(source, &index);
        position += std.unicode.utf8Encode(codepoint, bytes[position..]) catch
            return error.InvalidUtf16;
    }
    std.debug.assert(position == byte_count);
    return bytes;
}

/// Resolves a UTF-8 locale name with LOCALE_ALLOW_NEUTRAL_NAMES.
/// Invalid, embedded-NUL, or unknown names return LocaleNameInvalid, not a default culture.
pub fn localeNameToLcid(
    gpa: std.mem.Allocator,
    api: *const AutomationApi,
    name: []const u8,
) AutomationError!i32 {
    if (name.len > locale_name_units_max * 3) return error.StringTooLong;
    if (std.mem.indexOfScalar(u8, name, 0) != null) return error.LocaleNameInvalid;
    const count = std.unicode.calcUtf16LeLen(name) catch return error.InvalidUtf8;
    if (count > locale_name_units_max) return error.StringTooLong;
    const units = try gpa.allocSentinel(u16, count, 0);
    defer gpa.free(units);
    const written = try std.unicode.utf8ToUtf16Le(units, name);
    std.debug.assert(written == count);
    if (comptime builtin.cpu.arch.endian() == .big) {
        for (units) |*unit| unit.* = std.mem.littleToNative(u16, unit.*);
    }
    const lcid = api.locale_name_to_lcid(api.context, units.ptr, 0x08000000);
    if (lcid == 0) return error.LocaleNameInvalid;
    return @bitCast(lcid);
}

/// Returns the native host provider with one caller-owned reference, or null when no host exists.
/// A present result must be released through its IUnknown interface.
pub fn hostProviderFromHwnd(
    api: *const AutomationApi,
    hwnd: bindings.Hwnd,
) AutomationError!?*bindings.IRawElementProviderSimple {
    var result: ?*bindings.IRawElementProviderSimple = null;
    try checkAutomationStatus(api.host_provider_from_hwnd(api.context, hwnd, &result));
    return result;
}

/// Returns the client origin in screen coordinates, or WindowUnavailable.
pub fn clientTopLeft(api: *const AutomationApi, hwnd: bindings.Hwnd) AutomationError!schema.Point {
    var point: bindings.Point = .{ .x = 0, .y = 0 };
    if (api.client_to_screen(api.context, hwnd, &point) == 0) return error.WindowUnavailable;
    return .{ .x = @floatFromInt(point.x), .y = @floatFromInt(point.y) };
}

/// Gets a title through DefWindowProc WM_GETTEXT, never SendMessage.
/// No title returns null. A shorter title uses its copied count. The caller releases a present BSTR.
pub fn windowTitle(
    gpa: std.mem.Allocator,
    api: *const AutomationApi,
    hwnd: bindings.Hwnd,
) AutomationError!?bindings.Bstr {
    const length = api.def_window_proc(api.context, hwnd, 14, 0, 0);
    if (length <= 0) return null;
    if (@as(usize, @intCast(length)) > window_title_units_max) return error.WindowTitleTooLong;
    const units = try gpa.alloc(u16, @as(usize, @intCast(length)) + 1);
    defer gpa.free(units);
    const copied = api.def_window_proc(
        api.context,
        hwnd,
        13,
        units.len,
        @bitCast(@intFromPtr(units.ptr)),
    );
    if (copied <= 0) return null;
    if (@as(usize, @intCast(copied)) >= units.len) return error.WindowTitleTooLong;
    return utf16ToBstr(api, units[0..@intCast(copied)]);
}

/// Caller-owned scratch storage, replacing the upstream thread-local pool.
/// Reuse one buffer between conversions. Copies do not create independent owners.
pub const StringBuffer = struct {
    units: std.ArrayList(u16),

    /// Starts empty without allocation. The caller chooses storage through write operations.
    pub fn acquire() StringBuffer {
        return .{ .units = .empty };
    }

    /// Releases the buffer with its allocation authority and resets it to empty.
    pub fn deinit(self: *StringBuffer, gpa: std.mem.Allocator) void {
        self.units.deinit(gpa);
        self.* = .{ .units = .empty };
    }
};

/// Counted native UTF-16 writer borrowing caller-owned scratch storage.
/// Input copies can grow the buffer. Keep it alive until this writer's last use.
pub const WideString = struct {
    buffer: *std.ArrayList(u16),

    /// Clears the existing contents and borrows the reusable buffer.
    pub fn new(buffer: *std.ArrayList(u16)) WideString {
        buffer.clearRetainingCapacity();
        return .{ .buffer = buffer };
    }

    /// Appends all UTF-8 codepoints, preserving completed content on error.
    pub fn writeStr(
        self: *WideString,
        gpa: std.mem.Allocator,
        value: []const u8,
    ) AutomationError!void {
        if (value.len > utf8_bytes_max) return error.StringTooLong;
        const count = std.unicode.calcUtf16LeLen(value) catch return error.InvalidUtf8;
        const final_count = std.math.add(usize, self.buffer.items.len, count) catch
            return error.StringTooLong;
        if (final_count > bstr_units_max) return error.StringTooLong;
        try self.buffer.ensureUnusedCapacity(gpa, count);
        const destination = self.buffer.allocatedSlice()[self.buffer.items.len..final_count];
        const written = try std.unicode.utf8ToUtf16Le(destination, value);
        std.debug.assert(written == count);
        if (comptime builtin.cpu.arch.endian() == .big) {
            for (destination) |*unit| unit.* = std.mem.littleToNative(u16, unit.*);
        }
        self.buffer.items.len = final_count;
    }

    /// Appends one Unicode scalar. Invalid scalars fail without changing completed content.
    pub fn writeChar(
        self: *WideString,
        gpa: std.mem.Allocator,
        value: u21,
    ) AutomationError!void {
        var bytes: [4]u8 = undefined;
        const count = std.unicode.utf8Encode(value, &bytes) catch return error.InvalidArgument;
        try self.writeStr(gpa, bytes[0..count]);
    }

    /// Compares complete code-unit contents rather than borrowed buffer identities.
    pub fn eql(self: WideString, other: WideString) bool {
        return std.mem.eql(u16, self.buffer.items, other.buffer.items);
    }

    /// Copies this counted buffer into a caller-owned BSTR, without consuming scratch storage.
    pub fn toBstr(self: WideString, api: *const AutomationApi) AutomationError!bindings.Bstr {
        return utf16ToBstr(api, self.buffer.items);
    }

    /// Copies this counted buffer into an owning VT_BSTR.
    pub fn toVariant(self: WideString, api: *const AutomationApi) AutomationError!VariantOwner {
        return VariantOwner.fromOwnedBstr(api, try self.toBstr(api));
    }
};

/// Borrowed UTF-8 value for equality and counted VARIANT conversion.
/// Direct BSTR decoding removes the upstream wrapper's scratch-buffer borrow.
pub const StrWrapper = struct {
    value: []const u8,

    /// Borrows bytes until conversion or comparison. The caller keeps them alive and unchanged.
    pub fn new(value: []const u8) StrWrapper {
        return .{ .value = value };
    }

    /// Compares complete bytes, including embedded NUL.
    pub fn eql(self: StrWrapper, other: StrWrapper) bool {
        return std.mem.eql(u8, self.value, other.value);
    }

    /// Copies the bytes directly into an owning VT_BSTR.
    pub fn toVariant(self: StrWrapper, api: *const AutomationApi) AutomationError!VariantOwner {
        return VariantOwner.fromUtf8(api, self.value);
    }
};

/// An owned description could not be allocated or decoded as UTF-8.
pub const DescriptionError = error{ OutOfMemory, InvalidUtf8 };

/// Returns native UTF-16 code units without a terminator.
/// Upstream `toolkit_description`, `util.rs:413-424`, writes the name then an optional space/version.
/// A present empty version still adds the space. `TreeState` decides the fallback name.
/// The result copies the state strings. The caller releases it once with `gpa.free`.
/// Errors leave the state unchanged and release all temporary storage.
pub fn toolkitDescription(gpa: std.mem.Allocator, state: *const TreeState) DescriptionError![]u16 {
    const name = state.toolkitName();
    const version = state.toolkitVersion();
    var byte_count = name.len;
    if (version) |value| {
        byte_count = std.math.add(usize, byte_count, 1) catch return error.OutOfMemory;
        byte_count = std.math.add(usize, byte_count, value.len) catch return error.OutOfMemory;
    }
    _ = std.math.mul(usize, byte_count, @sizeOf(u16)) catch return error.OutOfMemory;

    var result: std.ArrayList(u16) = .empty;
    errdefer result.deinit(gpa);
    // A UTF-8 byte count is an upper bound on the number of UTF-16 code units.
    try result.ensureTotalCapacityPrecise(gpa, byte_count);
    const name_units = try std.unicode.utf8ToUtf16Le(result.allocatedSlice(), name);
    result.items.len = name_units;
    if (version) |value| {
        result.appendAssumeCapacity(std.mem.nativeToLittle(u16, ' '));
        const version_units = try std.unicode.utf8ToUtf16Le(
            result.allocatedSlice()[result.items.len..],
            value,
        );
        result.items.len += version_units;
    }
    if (comptime builtin.cpu.arch.endian() == .big) {
        const item_count = result.items.len;
        for (result.items[0..item_count]) |*unit| {
            unit.* = std.mem.littleToNative(u16, unit.*);
        }
    }
    return result.toOwnedSlice(gpa);
}

/// A complete property could not be allocated.
pub const PropertyError = error{OutOfMemory};

/// Owns bytes for upstream `AriaProperties`, `util.rs:433-436`.
/// `bytes` holds complete `name=value` pairs. `need_separator` records at least one completed pair.
/// Do not modify these fields or copy the builder as a second owner.
/// Use the same allocator for all writes, transfer, and `deinit`. No allocator is retained.
/// Input slices must not overlap `bytes`. Calls copy them and retain no input borrows.
/// Concurrent writes require caller synchronization.
pub const AriaProperties = struct {
    bytes: std.ArrayList(u8),
    need_separator: bool,

    /// Borrowed bytes for one call, copied verbatim without escaping.
    pub const Property = struct {
        name: []const u8,
        value: []const u8,
    };

    /// Starts empty without allocation. Upstream `new`, `util.rs:439-444`.
    pub fn init() AriaProperties {
        return .{ .bytes = .empty, .need_separator = false };
    }

    /// Releases the buffer once and resets this owner to the usable empty state.
    /// Copies made before release are invalid and must not be released separately.
    pub fn deinit(self: *AriaProperties, gpa: std.mem.Allocator) void {
        self.bytes.deinit(gpa);
        self.* = .{ .bytes = .empty, .need_separator = false };
    }

    /// Adds an exact `name=value` pair, with `;` only after a completed pair.
    /// Upstream `write_property`, `util.rs:446-455`. Empty names and values are accepted.
    /// Allocation or size overflow preserves all completed bytes and the separator state.
    /// Successful writes can invalidate slices into `bytes`.
    pub fn writeProperty(
        gpa: std.mem.Allocator,
        self: *AriaProperties,
        options: Property,
    ) PropertyError!void {
        std.debug.assert(self.need_separator == (self.bytes.items.len != 0));
        const punctuation: usize = if (self.need_separator) 2 else 1;
        const name_bytes = std.math.add(usize, punctuation, options.name.len) catch
            return error.OutOfMemory;
        const property_bytes = std.math.add(usize, name_bytes, options.value.len) catch
            return error.OutOfMemory;
        // Reserve the entire property before exposing even its separator.
        try self.bytes.ensureUnusedCapacity(gpa, property_bytes);
        if (self.need_separator) self.bytes.appendAssumeCapacity(';');
        self.bytes.appendSliceAssumeCapacity(options.name);
        self.bytes.appendAssumeCapacity('=');
        self.bytes.appendSliceAssumeCapacity(options.value);
        self.need_separator = true;
        std.debug.assert(self.need_separator == (self.bytes.items.len != 0));
    }

    /// Adds lowercase `true` or `false`. Upstream `write_bool_property`, `util.rs:457-459`.
    /// Has the same ownership and error guarantees as `writeProperty`.
    pub fn writeBoolProperty(
        gpa: std.mem.Allocator,
        self: *AriaProperties,
        name: []const u8,
        value: bool,
    ) PropertyError!void {
        try writeProperty(gpa, self, .{ .name = name, .value = if (value) "true" else "false" });
    }

    /// Adds unsigned decimal digits. Upstream `write_usize_property`, `util.rs:461-463`.
    /// Has the same ownership and error guarantees as `writeProperty`.
    pub fn writeUsizeProperty(
        gpa: std.mem.Allocator,
        self: *AriaProperties,
        name: []const u8,
        value: usize,
    ) PropertyError!void {
        var buffer: [@bitSizeOf(usize)]u8 = undefined;
        const decimal = std.fmt.bufPrint(&buffer, "{d}", .{value}) catch
            unreachable; // A usize's binary bit count bounds its decimal digits, including zero.
        try writeProperty(gpa, self, .{ .name = name, .value = decimal });
    }

    /// Reports any completed property. Upstream `has_properties`, `util.rs:465-467`.
    pub fn hasProperties(self: *const AriaProperties) bool {
        return self.need_separator;
    }

    /// Transfers the bytes to the caller, which releases them once with `gpa.free`.
    /// Success resets this builder to empty. `error.OutOfMemory` preserves bytes and separator state.
    pub fn toOwnedSlice(gpa: std.mem.Allocator, self: *AriaProperties) error{OutOfMemory}![]u8 {
        const owned = try self.bytes.toOwnedSlice(gpa);
        self.need_separator = false;
        return owned;
    }
};

test "toolkit description preserves Unicode code units and version presence" {
    // Expected code units come from the source strings, not from another decoder.
    const Case = struct {
        name: ?[]const u8,
        version: ?[]const u8,
        expected: []const u16,
    };
    const cases = [_]Case{
        .{ .name = null, .version = "ignored", .expected = &.{ 65, 99, 99, 101, 115, 115, 75, 105, 116 } },
        .{ .name = "", .version = null, .expected = &.{} },
        .{ .name = "Qt", .version = null, .expected = &.{ 81, 116 } },
        .{ .name = "Qt", .version = "", .expected = &.{ 81, 116, 32 } },
        .{ .name = "", .version = "6", .expected = &.{ 32, 54 } },
        .{ .name = "é😀", .version = "β.1", .expected = &.{ 0xe9, 0xd83d, 0xde00, 32, 0x3b2, 46, 49 } },
        .{ .name = "A\x00B", .version = "1", .expected = &.{ 65, 0, 66, 32, 49 } },
    };
    const case_count = cases.len;
    for (cases[0..case_count]) |case| {
        var state: TreeState = .{};
        state.info.toolkit_name = case.name;
        state.info.toolkit_version = case.version;
        const owned = try toolkitDescription(testing.allocator, &state);
        defer testing.allocator.free(owned);
        try testing.expectEqualSlices(u16, case.expected, owned);
    }
}

test "ARIA empty and exact multiple properties have no invented escaping" {
    var properties = AriaProperties.init();
    defer properties.deinit(testing.allocator);
    try testing.expect(!properties.hasProperties());
    try testing.expectEqualStrings("", properties.bytes.items);
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "", .value = "" });
    try testing.expect(properties.hasProperties());
    try testing.expectEqualStrings("=", properties.bytes.items);
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "a;b", .value = "c=d\\é" });
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "x", .value = "" });
    try testing.expectEqualStrings("=;a;b=c=d\\é;x=", properties.bytes.items);
    const owned = try AriaProperties.toOwnedSlice(testing.allocator, &properties);
    defer testing.allocator.free(owned);
    try testing.expectEqualStrings("=;a;b=c=d\\é;x=", owned);
    try testing.expect(!properties.hasProperties());
    try AriaProperties.writeProperty(testing.allocator, &properties, .{ .name = "new", .value = "value" });
    try testing.expectEqualStrings("new=value", properties.bytes.items);
}

test "ARIA booleans and usize use lowercase and exact decimal digits" {
    var properties = AriaProperties.init();
    defer properties.deinit(testing.allocator);
    try AriaProperties.writeBoolProperty(testing.allocator, &properties, "enabled", true);
    try AriaProperties.writeBoolProperty(testing.allocator, &properties, "hidden", false);
    try AriaProperties.writeUsizeProperty(testing.allocator, &properties, "zero", 0);
    try AriaProperties.writeUsizeProperty(testing.allocator, &properties, "max", std.math.maxInt(usize));
    const maximum = switch (@bitSizeOf(usize)) {
        32 => "4294967295",
        64 => "18446744073709551615",
        else => @compileError("Add the exact usize decimal fixture for this target."),
    };
    try testing.expectEqualStrings("enabled=true;hidden=false;zero=0;max=" ++ maximum, properties.bytes.items);
}

fn toolkitAllocationFailures(gpa: std.mem.Allocator) !void {
    var state: TreeState = .{};
    state.info.toolkit_name = "é😀";
    state.info.toolkit_version = "β.1";
    const owned = try toolkitDescription(gpa, &state);
    defer gpa.free(owned);
    try testing.expectEqualSlices(u16, &.{ 0xe9, 0xd83d, 0xde00, 32, 0x3b2, 46, 49 }, owned);
}

test "toolkit description fail-N releases all intermediate buffers" {
    try testing.checkAllAllocationFailures(testing.allocator, toolkitAllocationFailures, .{});
}

fn ariaAllocationFailures(gpa: std.mem.Allocator) !void {
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    AriaProperties.writeProperty(gpa, &properties, .{ .name = "first", .value = "done" }) catch |failure| {
        try testing.expectEqualStrings("", properties.bytes.items);
        try testing.expect(!properties.hasProperties());
        return failure;
    };
    const large_value = @as([256]u8, @splat('z'));
    AriaProperties.writeProperty(gpa, &properties, .{ .name = "second", .value = &large_value }) catch |failure| {
        try testing.expectEqualStrings("first=done", properties.bytes.items);
        try testing.expect(properties.hasProperties());
        // The failed property added neither a separator nor a partial name.
        return failure;
    };
    const owned = AriaProperties.toOwnedSlice(gpa, &properties) catch |failure| {
        try testing.expectEqualStrings("first=done;second=" ++ large_value, properties.bytes.items);
        try testing.expect(properties.hasProperties());
        return failure;
    };
    defer gpa.free(owned);
    try testing.expectEqualStrings("first=done;second=" ++ large_value, owned);
    try testing.expect(!properties.hasProperties());
}

test "ARIA fail-N preserves completed properties separators and transfer ownership" {
    try testing.checkAllAllocationFailures(testing.allocator, ariaAllocationFailures, .{});
}

test "ARIA allocation failure does not leave a separator before a later retry" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .fail_index = 0,
        .resize_fail_index = 0,
    });
    const gpa = failing.allocator();
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    try testing.expectError(
        error.OutOfMemory,
        AriaProperties.writeProperty(gpa, &properties, .{ .name = "", .value = "" }),
    );
    try testing.expect(!properties.hasProperties());
    failing.fail_index = std.math.maxInt(usize);
    try AriaProperties.writeProperty(gpa, &properties, .{ .name = "first", .value = "done" });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(
        error.OutOfMemory,
        AriaProperties.writeProperty(gpa, &properties, .{ .name = "second", .value = &@as([256]u8, @splat('z')) }),
    );
    try testing.expectEqualStrings("first=done", properties.bytes.items);
    try testing.expect(properties.hasProperties());
    failing.fail_index = std.math.maxInt(usize);
    try AriaProperties.writeProperty(gpa, &properties, .{ .name = "retry", .value = "ok" });
    try testing.expectEqualStrings("first=done;retry=ok", properties.bytes.items);
}

test "ARIA failed ownership transfer keeps completed bytes until a successful transfer" {
    var failing: testing.FailingAllocator = .init(testing.allocator, .{
        .resize_fail_index = 0,
    });
    const gpa = failing.allocator();
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    try AriaProperties.writeProperty(gpa, &properties, .{ .name = "a", .value = "b" });
    failing.fail_index = failing.alloc_index;
    try testing.expectError(error.OutOfMemory, AriaProperties.toOwnedSlice(gpa, &properties));
    try testing.expectEqualStrings("a=b", properties.bytes.items);
    try testing.expect(properties.hasProperties());
    failing.fail_index = std.math.maxInt(usize);
    const owned = try AriaProperties.toOwnedSlice(gpa, &properties);
    defer gpa.free(owned);
    try testing.expectEqualStrings("a=b", owned);
    try testing.expectEqualStrings("", properties.bytes.items);
    try testing.expect(!properties.hasProperties());
}

fn ariaBoolAllocationFailures(gpa: std.mem.Allocator) !void {
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    AriaProperties.writeBoolProperty(gpa, &properties, "on", true) catch |failure| {
        try testing.expect(!properties.hasProperties());
        try testing.expectEqualStrings("", properties.bytes.items);
        return failure;
    };
    try testing.expectEqualStrings("on=true", properties.bytes.items);
}

fn ariaUsizeAllocationFailures(gpa: std.mem.Allocator) !void {
    var properties = AriaProperties.init();
    defer properties.deinit(gpa);
    AriaProperties.writeUsizeProperty(gpa, &properties, "count", std.math.maxInt(usize)) catch |failure| {
        try testing.expect(!properties.hasProperties());
        try testing.expectEqualStrings("", properties.bytes.items);
        return failure;
    };
    try testing.expect(properties.hasProperties());
}

test "ARIA typed writers fail-N leave an empty builder usable and leak nothing" {
    try testing.checkAllAllocationFailures(testing.allocator, ariaBoolAllocationFailures, .{});
    try testing.checkAllAllocationFailures(testing.allocator, ariaUsizeAllocationFailures, .{});
}

test "toolkit description rejects invalid UTF-8 in name and version" {
    var state: TreeState = .{};
    state.info.toolkit_name = "\xff";
    try testing.expectError(error.InvalidUtf8, toolkitDescription(testing.allocator, &state));
    state.info.toolkit_name = "a";
    state.info.toolkit_version = "\xf0\x9f";
    try testing.expectError(error.InvalidUtf8, toolkitDescription(testing.allocator, &state));
}

test "automation counted BSTR preserves Unicode embedded NUL empty and null" {
    // The allocation ABI stores a count, not a sentinel-derived length.
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const string = try utf8ToBstr(&api, "é\x00😀");
    try testing.expectEqualSlices(u16, &.{ 0xe9, 0, 0xd83d, 0xde00 }, abi.stringUnits(string));
    const bytes = (try bstrToUtf8(testing.allocator, &api, string)).?;
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("é\x00😀", bytes);
    api.free_string(api.context, string);
    const empty = try utf16ToBstr(&api, &.{});
    const empty_bytes = (try bstrToUtf8(testing.allocator, &api, empty)).?;
    defer testing.allocator.free(empty_bytes);
    try testing.expectEqual(@as(usize, 0), empty_bytes.len);
    api.free_string(api.context, empty);
    try testing.expect((try bstrToUtf8(testing.allocator, &api, null)) == null);
    try testing.expectEqual(@as(u32, 2), abi.string_frees);
    try testing.expectEqual(@as(u32, 0), abi.live_strings);
}

test "automation exact scalar variant tags bool bits numbers and RGB" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var value = VariantOwner.fromBool(&api, true);
    try testing.expectEqual(@as(u16, 11), variantType(&value.raw));
    try testing.expectEqual(@as(i16, -1), value.raw.Anonymous.Anonymous.Anonymous.boolVal);
    try value.deinit();
    value = VariantOwner.fromBool(&api, false);
    try testing.expectEqual(@as(i16, 0), value.raw.Anonymous.Anonymous.Anonymous.boolVal);
    value = VariantOwner.fromI32(&api, -23);
    try testing.expectEqual(@as(u16, 3), variantType(&value.raw));
    try testing.expectEqual(@as(i32, -23), value.raw.Anonymous.Anonymous.Anonymous.lVal);
    value = VariantOwner.fromF64(&api, -0.125);
    try testing.expectEqual(@as(u16, 5), variantType(&value.raw));
    try testing.expectEqual(@as(f64, -0.125), value.raw.Anonymous.Anonymous.Anonymous.dblVal);
    value = VariantOwner.fromColor(&api, .{ .red = 1, .green = 128, .blue = 255, .alpha = 7 });
    try testing.expectEqual(@as(i32, 0x00ff8001), value.raw.Anonymous.Anonymous.Anonymous.lVal);
    try value.deinit();
    try testing.expect(value.isEmpty());
}

test "automation variant BSTR clear and take release exactly once" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var value = try VariantOwner.fromUtf8(&api, "A\x00B");
    const raw = value.take();
    try testing.expectEqual(@as(u16, 8), variantType(&raw));
    try testing.expect(value.isEmpty());
    try value.deinit();
    try testing.expectEqual(@as(u32, 0), abi.string_frees);
    var recipient: VariantOwner = .{ .api = &api, .raw = raw };
    try recipient.deinit();
    try recipient.deinit();
    try testing.expectEqual(@as(u32, 1), abi.string_frees);
    try testing.expectEqual(@as(u32, 1), abi.clear_calls);
}

test "automation COM variants and arrays balance borrowed and owned references" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var object = AutomationTestUnknown.init();
    var variant = VariantOwner.fromUnknown(&api, &object.interface);
    try testing.expectEqual(@as(u16, 13), variantType(&variant.raw));
    try testing.expect(variant.raw.Anonymous.Anonymous.Anonymous.punkVal == &object.interface);
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.references, .monotonic));
    try variant.deinit();
    try variant.deinit();
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    var array = try safeArrayFromComSlice(&api, &.{ &object.interface, &object.interface });
    try testing.expectEqual(@as(u32, 3), @atomicLoad(u32, &object.references, .monotonic));
    variant = array.intoVariant(13);
    try testing.expect(array.raw == null);
    try testing.expectEqual(@as(u16, 0x200d), variantType(&variant.raw));
    try variant.deinit();
    try variant.deinit();
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    variant = VariantOwner.fromOwnedUnknown(&api, &object.interface);
    try variant.deinit();
    try variant.deinit();
    try testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 3), @atomicLoad(u32, &object.adds, .monotonic));
    try testing.expectEqual(@as(u32, 4), @atomicLoad(u32, &object.releases, .monotonic));
}

test "automation typed arrays store exact elements and zero-element arrays remain present" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var integers = try safeArrayFromI32Slice(&api, &.{ -5, 0, 2147483647 });
    try testing.expectEqualSlices(i32, &.{ -5, 0, 2147483647 }, abi.array(integers.raw.?).ints);
    const transferred = integers.take().?;
    try integers.deinit();
    try testing.expectEqual(@as(u32, 0), abi.array_frees);
    try checkAutomationStatus(api.array_destroy(api.context, transferred));
    var doubles = try safeArrayFromF64Slice(&api, &.{ -1.25, 0.0, 2.5 });
    try testing.expectEqualSlices(f64, &.{ -1.25, 0.0, 2.5 }, abi.array(doubles.raw.?).doubles);
    try doubles.deinit();
    var empty = try safeArrayFromComSlice(&api, &.{});
    try testing.expect(empty.raw != null);
    try testing.expectEqual(@as(usize, 0), abi.array(empty.raw.?).objects.len);
    try empty.deinit();
    var absent = try VariantOwner.fromComSlice(&api, &.{});
    try testing.expect(absent.isEmpty());
    try absent.deinit();
    try testing.expectEqual(@as(u32, 3), abi.array_frees);
}

test "automation partial array failures release inserted COM values" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var object = AutomationTestUnknown.init();
    abi.put_failure_index = 1;
    abi.put_failure = 0x80070057;
    try testing.expectError(error.InvalidArgument, safeArrayFromComSlice(
        &api,
        &.{ &object.interface, &object.interface, &object.interface },
    ));
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.adds, .monotonic));
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.releases, .monotonic));
    try testing.expectEqual(@as(u32, 1), abi.array_frees);
    try testing.expectEqual(@as(u32, 0), abi.live_arrays);
    abi.put_failure = 0x8007000e;
    try testing.expectError(error.OutOfMemory, safeArrayFromI32Slice(&api, &.{ 7, 9 }));
    abi.put_failure = 0x80004005;
    try testing.expectError(error.UnexpectedNativeFailure, safeArrayFromF64Slice(&api, &.{ 1, 2 }));
    try testing.expectEqual(@as(u32, 3), abi.array_frees);
}

test "automation clear and destroy errors retain ownership for a successful retry" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var value = try VariantOwner.fromUtf8(&api, "retained");
    abi.clear_failure = 0x80020008;
    try testing.expectError(error.BadVariantType, value.deinit());
    try testing.expectEqual(@as(u16, 8), variantType(&value.raw));
    try testing.expectEqual(@as(u32, 0), abi.string_frees);
    abi.clear_failure = 0;
    try value.deinit();
    var array = try safeArrayFromI32Slice(&api, &.{1});
    abi.destroy_failure = 0x8002000d;
    try testing.expectError(error.ArrayLocked, array.deinit());
    try testing.expect(array.raw != null);
    abi.destroy_failure = 0;
    try array.deinit();
    try array.deinit();
    try testing.expectEqual(@as(u32, 1), abi.string_frees);
    try testing.expectEqual(@as(u32, 1), abi.array_frees);
}

test "automation encoding locale and platform errors remain distinct" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    try testing.expectError(error.InvalidUtf8, utf8ToBstr(&api, "\xff"));
    const malformed = try utf16ToBstr(&api, &.{0xd800});
    defer api.free_string(api.context, malformed);
    try testing.expectError(error.InvalidUtf16, bstrToUtf8(testing.allocator, &api, malformed));
    abi.fail_string = true;
    try testing.expectError(error.OutOfMemory, utf8ToBstr(&api, "a"));
    abi.fail_string = false;
    abi.fail_array = true;
    try testing.expectError(error.OutOfMemory, safeArrayFromI32Slice(&api, &.{1}));
    try testing.expectError(error.LocaleNameInvalid, localeNameToLcid(testing.allocator, &api, "en\x00US"));
    try testing.expectEqual(@as(i32, 0x409), try localeNameToLcid(testing.allocator, &api, "en-US"));
    try testing.expectError(error.LocaleNameInvalid, localeNameToLcid(testing.allocator, &api, "unknown"));
    abi.window_present = false;
    const hwnd: bindings.Hwnd = @ptrFromInt(1);
    try testing.expectError(error.WindowUnavailable, clientTopLeft(&api, hwnd));
    abi.title_length = window_title_units_max + 1;
    try testing.expectError(error.WindowTitleTooLong, windowTitle(testing.allocator, &api, hwnd));
}

test "automation client origin and title use counted UTF16 without message dispatch" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const hwnd: bindings.Hwnd = @ptrFromInt(1);
    const origin = try clientTopLeft(&api, hwnd);
    try testing.expectEqual(@as(f64, -120), origin.x);
    try testing.expectEqual(@as(f64, 47), origin.y);
    abi.title = &.{ 0xe9, 0, 0xd83d, 0xde00 };
    abi.title_length = abi.title.len;
    const title = (try windowTitle(testing.allocator, &api, hwnd)).?;
    defer api.free_string(api.context, title);
    try testing.expectEqualSlices(u16, abi.title, abi.stringUnits(title));
    try testing.expectEqual(@as(u32, 2), abi.def_proc_calls);
}

/// Test-only allocation ABI. It allocates counted strings and stores actual typed array elements.
/// Nothing installs this table as a native backend. Each fixture and allocator outlives its owners.
pub const AutomationTestAbi = if (builtin.is_test) TestAutomationAbi else void;

const TestAutomationAbi = struct {
    gpa: std.mem.Allocator,
    string_frees: u32 = 0,
    live_strings: u32 = 0,
    array_frees: u32 = 0,
    live_arrays: u32 = 0,
    clear_calls: u32 = 0,
    def_proc_calls: u32 = 0,
    fail_string: bool = false,
    fail_array: bool = false,
    put_failure_index: ?usize = null,
    put_failure: u32 = 0x80070057,
    clear_failure: u32 = 0,
    destroy_failure: u32 = 0,
    reserved_failure: u32 = 0,
    reserved_object: ?*bindings.IUnknown = null,
    host_object: ?*bindings.IRawElementProviderSimple = null,
    host_failure: u32 = 0,
    window_present: bool = true,
    title: []const u16 = &.{},
    title_length: usize = 0,

    const Array = struct {
        element_vt: u16,
        ints: []i32 = &.{},
        doubles: []f64 = &.{},
        objects: []?*bindings.IUnknown = &.{},
    };

    /// Starts an isolated allocation record. All resources must be released before fixture reuse.
    pub fn init(gpa: std.mem.Allocator) AutomationTestAbi {
        return .{ .gpa = gpa };
    }

    /// Borrows this fixture as table context. The returned table and fixture must outlive owners.
    pub fn api(self: *TestAutomationAbi) AutomationApi {
        return .{
            .context = self,
            .alloc_string_len = allocString,
            .string_len = stringLen,
            .free_string = freeString,
            .variant_clear = clearVariant,
            .array_create_vector = createArray,
            .array_put_element = putElement,
            .array_destroy = destroyArray,
            .reserved_mixed_value = reservedValue,
            .reserved_not_supported_value = reservedValue,
            .host_provider_from_hwnd = hostProvider,
            .locale_name_to_lcid = localeLcid,
            .client_to_screen = clientOrigin,
            .def_window_proc = defProc,
        };
    }

    fn fixture(context: ?*anyopaque) *TestAutomationAbi {
        return @ptrCast(@alignCast(context.?));
    }

    /// Reads the count prefix rather than scanning for NUL.
    pub fn stringUnits(self: *TestAutomationAbi, string: bindings.Bstr) []const u16 {
        const units: [*]const u16 = @ptrCast(string);
        return units[0..stringLen(self, string)];
    }

    fn stringStorage(string: bindings.Bstr) [*]u32 {
        const address = @intFromPtr(string) - @sizeOf(u32);
        return @ptrFromInt(address);
    }

    fn allocString(context: ?*anyopaque, source: ?[*]const u16, count: u32) ?bindings.Bstr {
        const self = fixture(context);
        if (self.fail_string) return null;
        const words_count = 1 + (std.math.divCeil(usize, (@as(usize, count) + 1) * 2, 4) catch
            return null);
        const words = self.gpa.alloc(u32, words_count) catch return null;
        words[0] = count * 2;
        const units: [*]u16 = @ptrCast(words.ptr + 1);
        if (source) |input| {
            @memcpy(units[0..count], input[0..count]);
        } else {
            @memset(units[0..count], 0);
        }
        units[count] = 0;
        self.live_strings += 1;
        return @ptrCast(units);
    }

    fn stringLen(_: ?*anyopaque, string: bindings.Bstr) u32 {
        return @divExact(stringStorage(string)[0], 2);
    }

    fn freeString(context: ?*anyopaque, string: bindings.Bstr) void {
        const self = fixture(context);
        const words = stringStorage(string);
        const words_count = 1 + @divFloor(@as(usize, words[0]) + 2 + 3, 4);
        self.gpa.free(words[0..words_count]);
        self.live_strings -= 1;
        self.string_frees += 1;
    }

    fn clearVariant(context: ?*anyopaque, raw: *bindings.Variant) bindings.Hresult {
        const self = fixture(context);
        self.clear_calls += 1;
        if (self.clear_failure != 0) return @bitCast(self.clear_failure);
        const payload = raw.Anonymous.Anonymous.Anonymous;
        switch (variantType(raw)) {
            vt_empty, vt_i4, vt_r8, vt_bool => {},
            vt_bstr => if (payload.bstrVal) |string| freeString(context, string),
            vt_unknown => if (payload.punkVal) |object| {
                if (comptime bindings.winapi_resolves) {
                    _ = object.Release();
                } else {
                    @panic("COM tests require a supported winapi calling convention.");
                }
            },
            vt_array | vt_i4, vt_array | vt_r8, vt_array | vt_unknown => {
                const status = destroyArray(context, payload.parray.?);
                if (status.failed) return status;
            },
            else => return @bitCast(@as(u32, 0x80020008)),
        }
        raw.* = taggedVariant(vt_empty);
        return @bitCast(@as(u32, 0));
    }

    /// Reads the stored array values for test assertions.
    pub fn array(_: *TestAutomationAbi, raw: *bindings.SafeArray) *Array {
        return @ptrCast(@alignCast(raw));
    }

    fn createArray(
        context: ?*anyopaque,
        element_vt: u16,
        lower_bound: i32,
        count: u32,
    ) ?*bindings.SafeArray {
        const self = fixture(context);
        std.debug.assert(lower_bound == 0);
        if (self.fail_array) return null;
        const value = self.gpa.create(Array) catch return null;
        value.* = .{ .element_vt = element_vt };
        switch (element_vt) {
            vt_i4 => {
                value.ints = self.gpa.alloc(i32, count) catch {
                    self.gpa.destroy(value);
                    return null;
                };
                @memset(value.ints, 0);
            },
            vt_r8 => {
                value.doubles = self.gpa.alloc(f64, count) catch {
                    self.gpa.destroy(value);
                    return null;
                };
                @memset(value.doubles, 0);
            },
            vt_unknown => {
                value.objects = self.gpa.alloc(?*bindings.IUnknown, count) catch {
                    self.gpa.destroy(value);
                    return null;
                };
                @memset(value.objects, null);
            },
            else => {
                self.gpa.destroy(value);
                return null;
            },
        }
        self.live_arrays += 1;
        return @ptrCast(value);
    }

    fn putElement(
        context: ?*anyopaque,
        raw: *bindings.SafeArray,
        index: *const i32,
        element: *const anyopaque,
    ) bindings.Hresult {
        const self = fixture(context);
        const position: usize = @intCast(index.*);
        if (self.put_failure_index) |failed_position| {
            if (position == failed_position) return @bitCast(self.put_failure);
        }
        const value = self.array(raw);
        switch (value.element_vt) {
            vt_i4 => {
                const input: *const i32 = @ptrCast(@alignCast(element));
                value.ints[position] = input.*;
            },
            vt_r8 => {
                const input: *const f64 = @ptrCast(@alignCast(element));
                value.doubles[position] = input.*;
            },
            vt_unknown => {
                const input: *bindings.IUnknown = @ptrCast(@alignCast(@constCast(element)));
                if (comptime bindings.winapi_resolves) {
                    _ = input.AddRef();
                    if (value.objects[position]) |previous| {
                        _ = previous.Release();
                    }
                } else {
                    @panic("COM tests require a supported winapi calling convention.");
                }
                value.objects[position] = input;
            },
            else => return @bitCast(@as(u32, 0x80020008)),
        }
        return @bitCast(@as(u32, 0));
    }

    fn destroyArray(context: ?*anyopaque, raw: *bindings.SafeArray) bindings.Hresult {
        const self = fixture(context);
        if (self.destroy_failure != 0) return @bitCast(self.destroy_failure);
        const value = self.array(raw);
        switch (value.element_vt) {
            vt_i4 => self.gpa.free(value.ints),
            vt_r8 => self.gpa.free(value.doubles),
            vt_unknown => {
                for (value.objects) |optional| {
                    if (optional) |object| {
                        if (comptime bindings.winapi_resolves) {
                            _ = object.Release();
                        } else {
                            @panic("COM tests require a supported winapi calling convention.");
                        }
                    }
                }
                self.gpa.free(value.objects);
            },
            else => return @bitCast(@as(u32, 0x80020008)),
        }
        self.gpa.destroy(value);
        self.live_arrays -= 1;
        self.array_frees += 1;
        return @bitCast(@as(u32, 0));
    }

    fn reservedValue(context: ?*anyopaque, out: *?*bindings.IUnknown) bindings.Hresult {
        const self = fixture(context);
        if (self.reserved_failure != 0) return @bitCast(self.reserved_failure);
        if (self.reserved_object) |object| {
            if (comptime bindings.winapi_resolves) {
                _ = object.AddRef();
            } else {
                @panic("COM tests require a supported winapi calling convention.");
            }
            out.* = object;
        }
        return @bitCast(@as(u32, 0));
    }

    fn hostProvider(
        context: ?*anyopaque,
        _: bindings.Hwnd,
        out: *?*bindings.IRawElementProviderSimple,
    ) bindings.Hresult {
        const self = fixture(context);
        if (self.host_failure != 0) return @bitCast(self.host_failure);
        if (self.host_object) |host| {
            if (comptime bindings.winapi_resolves) {
                _ = host.IUnknown.AddRef();
            } else {
                @panic("COM tests require a supported winapi calling convention.");
            }
            out.* = host;
        }
        return @bitCast(@as(u32, 0));
    }

    fn localeLcid(_: ?*anyopaque, name: [*:0]const u16, flags: u32) u32 {
        std.debug.assert(flags == 0x08000000);
        const expected = [_]u16{ 'e', 'n', '-', 'U', 'S', 0 };
        for (expected, 0..) |unit, position| {
            if (name[position] != unit) return 0;
        }
        return 0x409;
    }

    fn clientOrigin(
        context: ?*anyopaque,
        _: bindings.Hwnd,
        point: *bindings.Point,
    ) bindings.Bool {
        if (!fixture(context).window_present) return 0;
        std.debug.assert(point.x == 0);
        std.debug.assert(point.y == 0);
        point.* = .{ .x = -120, .y = 47 };
        return 1;
    }

    fn defProc(
        context: ?*anyopaque,
        _: bindings.Hwnd,
        message: u32,
        capacity: bindings.Wparam,
        buffer: bindings.Lparam,
    ) bindings.Lresult {
        const self = fixture(context);
        self.def_proc_calls += 1;
        switch (message) {
            14 => return @intCast(self.title_length),
            13 => {
                std.debug.assert(capacity > self.title.len);
                const units: [*]u16 = @ptrFromInt(@as(usize, @bitCast(buffer)));
                @memcpy(units[0..self.title.len], self.title);
                units[self.title.len] = 0;
                return @intCast(self.title.len);
            },
            else => @panic("Only WM_GETTEXTLENGTH and WM_GETTEXT are allowed."),
        }
    }
};

// Keep the COM interface at offset zero. Callbacks update counters through this stable owner.
const AutomationTestUnknown = if (bindings.winapi_resolves) extern struct {
    interface: bindings.IUnknown,
    references: u32 = 1,
    adds: u32 = 0,
    releases: u32 = 0,

    const Self = @This();

    fn init() Self {
        return .{ .interface = .{ .vtable = &vtable } };
    }

    fn owner(raw: *const bindings.IUnknown) *Self {
        const self: *const Self = @fieldParentPtr("interface", raw);
        return @constCast(self);
    }

    const vtable: bindings.IUnknown.VTable = .{
        .QueryInterface = queryInterface,
        .AddRef = addRef,
        .Release = release,
    };

    fn queryInterface(
        raw: *const bindings.IUnknown,
        _: *const bindings.win32.zig.Guid,
        out: **anyopaque,
    ) callconv(.winapi) bindings.Hresult {
        out.* = @ptrCast(@constCast(raw));
        _ = addRef(raw);
        return @bitCast(@as(u32, 0));
    }

    fn addRef(raw: *const bindings.IUnknown) callconv(.winapi) u32 {
        const self = owner(raw);
        const previous = @atomicRmw(u32, &self.references, .Add, 1, .monotonic);
        std.debug.assert(previous > 0);
        _ = @atomicRmw(u32, &self.adds, .Add, 1, .monotonic);
        return previous + 1;
    }

    fn release(raw: *const bindings.IUnknown) callconv(.winapi) u32 {
        const self = owner(raw);
        const previous = @atomicRmw(u32, &self.references, .Sub, 1, .monotonic);
        std.debug.assert(previous > 0);
        _ = @atomicRmw(u32, &self.releases, .Add, 1, .monotonic);
        return previous - 1;
    }
} else void;

test "automation enum optional locale and text values preserve upstream variants" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const decorations = [_]schema.TextDecorationStyle{ .solid, .dotted, .dashed, .double, .wavy };
    const decoration_values = [_]i32{ 1, 4, 5, 3, 8 };
    for (decorations, decoration_values) |decoration, expected| {
        var value = try VariantOwner.fromValue(&api, schema.TextDecorationStyle, decoration);
        try testing.expectEqual(@as(u16, 3), variantType(&value.raw));
        try testing.expectEqual(expected, value.raw.Anonymous.Anonymous.Anonymous.lVal);
        try value.deinit();
    }
    const alignments = [_]schema.TextAlign{ .left, .right, .center, .justify };
    const alignment_values = [_]i32{ 0, 2, 1, 3 };
    for (alignments, alignment_values) |alignment, expected| {
        var value = try VariantOwner.fromValue(&api, schema.TextAlign, alignment);
        try testing.expectEqual(expected, value.raw.Anonymous.Anonymous.Anonymous.lVal);
        try value.deinit();
    }
    const absent = try VariantOwner.fromValue(&api, ?i32, null);
    try testing.expect(absent.isEmpty());
    var present = try VariantOwner.fromRangeProperty(&api, i32, .{ .single = -17 });
    try testing.expectEqual(@as(i32, -17), present.raw.Anonymous.Anonymous.Anonymous.lVal);
    try present.deinit();
    var locale = try VariantOwner.fromLocaleName(testing.allocator, &api, "en-US");
    try testing.expectEqual(@as(i32, 0x409), locale.raw.Anonymous.Anonymous.Anonymous.lVal);
    try locale.deinit();
    locale = try VariantOwner.fromLocaleName(testing.allocator, &api, "unknown");
    try testing.expect(locale.isEmpty());
    try locale.deinit();
    const native_enums = .{
        bindings.uia.ToggleState.On,
        bindings.uia.ExpandCollapseState.Expanded,
        bindings.uia.LiveSetting.Assertive,
        bindings.uia.CaretPosition.EndOfLine,
        bindings.uia.OrientationType.Vertical,
    };
    inline for (native_enums) |input| {
        var value = try VariantOwner.fromValue(&api, @TypeOf(input), input);
        try testing.expectEqual(@as(u16, 3), variantType(&value.raw));
        try testing.expectEqual(@as(i32, @backingInt(input)), value.raw.Anonymous.Anonymous.Anonymous.lVal);
        try value.deinit();
    }
}

test "automation reserved text values own exactly the returned COM reference" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var object = AutomationTestUnknown.init();
    abi.reserved_object = &object.interface;
    var mixed = try VariantOwner.fromRangeProperty(&api, bool, .mixed);
    try testing.expectEqual(@as(u16, 13), variantType(&mixed.raw));
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.references, .monotonic));
    try mixed.deinit();
    var unsupported = try VariantOwner.notSupported(&api);
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.references, .monotonic));
    try unsupported.deinit();
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.adds, .monotonic));
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.releases, .monotonic));
    abi.reserved_failure = 0x8007000e;
    try testing.expectError(error.OutOfMemory, VariantOwner.mixed(&api));
    abi.reserved_failure = 0;
    abi.reserved_object = null;
    try testing.expectError(error.UnexpectedNativeFailure, VariantOwner.notSupported(&api));
}

test "automation bounds reject before allocation and preserve no-title null" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const units: [*]const u16 = @ptrFromInt(@alignOf(u16));
    try testing.expectError(error.StringTooLong, utf16ToBstr(&api, units[0 .. bstr_units_max + 1]));
    const integers: [*]const i32 = @ptrFromInt(@alignOf(i32));
    try testing.expectError(error.ArrayTooLong, safeArrayFromI32Slice(
        &api,
        integers[0 .. array_elements_max + 1],
    ));
    try testing.expectError(error.StringTooLong, localeNameToLcid(
        testing.allocator,
        &api,
        &@as([(locale_name_units_max + 1)]u8, @splat('a')),
    ));
    try testing.expectEqual(@as(u32, 0), abi.live_strings);
    try testing.expectEqual(@as(u32, 0), abi.live_arrays);
    const hwnd: bindings.Hwnd = @ptrFromInt(1);
    try testing.expect((try windowTitle(testing.allocator, &api, hwnd)) == null);
    abi.title_length = 4;
    try testing.expect((try windowTitle(testing.allocator, &api, hwnd)) == null);
    try testing.expectEqual(@as(u32, 0), abi.live_strings);
}

fn automationAllocationFailures(gpa: std.mem.Allocator) !void {
    var abi = AutomationTestAbi.init(gpa);
    const api = abi.api();
    var string = try VariantOwner.fromUtf8(&api, "é\x00😀");
    defer string.deinit() catch @panic("Valid BSTR must clear.");
    const bytes = (try bstrToUtf8(gpa, &api, string.raw.Anonymous.Anonymous.Anonymous.bstrVal)).?;
    defer gpa.free(bytes);
    try testing.expectEqualStrings("é\x00😀", bytes);
    var integers = try safeArrayFromI32Slice(&api, &.{ -3, 0, 9 });
    defer integers.deinit() catch @panic("Unexposed integer array must destroy.");
    try testing.expectEqualSlices(i32, &.{ -3, 0, 9 }, abi.array(integers.raw.?).ints);
    var doubles = try safeArrayFromF64Slice(&api, &.{ -0.75, 2.5 });
    defer doubles.deinit() catch @panic("Unexposed double array must destroy.");
    try testing.expectEqualSlices(f64, &.{ -0.75, 2.5 }, abi.array(doubles.raw.?).doubles);
    try testing.expectEqual(@as(i32, 0x409), try localeNameToLcid(gpa, &api, "en-US"));
    abi.title = &.{ 'Q', 't' };
    abi.title_length = 10;
    const title = (try windowTitle(gpa, &api, @ptrFromInt(1))).?;
    defer api.free_string(api.context, title);
    try testing.expectEqualSlices(u16, &.{ 'Q', 't' }, abi.stringUnits(title));
}

test "automation fail-N releases real string array locale and title allocations" {
    try testing.checkAllAllocationFailures(testing.allocator, automationAllocationFailures, .{});
}

test "automation wide builder and string wrapper copy complete counted values" {
    var buffer = StringBuffer.acquire();
    defer buffer.deinit(testing.allocator);
    var wide = WideString.new(&buffer.units);
    try wide.writeStr(testing.allocator, "é\x00");
    try wide.writeChar(testing.allocator, 0x1f600);
    try testing.expectEqualSlices(u16, &.{ 0xe9, 0, 0xd83d, 0xde00 }, buffer.units.items);
    try testing.expectError(error.InvalidUtf8, wide.writeStr(testing.allocator, "\xff"));
    try testing.expectEqualSlices(u16, &.{ 0xe9, 0, 0xd83d, 0xde00 }, buffer.units.items);
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const string = try wide.toBstr(&api);
    defer api.free_string(api.context, string);
    try testing.expectEqualSlices(u16, buffer.units.items, abi.stringUnits(string));
    const wrapper = StrWrapper.new("é\x00😀");
    try testing.expect(wrapper.eql(StrWrapper.new("é\x00😀")));
    try testing.expect(!wrapper.eql(StrWrapper.new("é")));
    var value = try wrapper.toVariant(&api);
    defer value.deinit() catch @panic("Valid string must clear.");
    try testing.expectEqualSlices(
        u16,
        buffer.units.items,
        abi.stringUnits(value.raw.Anonymous.Anonymous.Anonymous.bstrVal.?),
    );
}

test "automation direct native UTF16 decoder retains NUL and rejects lone surrogates" {
    const bytes = try utf16ToUtf8(testing.allocator, &.{ 0xe9, 0, 0xd83d, 0xde00 });
    defer testing.allocator.free(bytes);
    try testing.expectEqualStrings("é\x00😀", bytes);
    try testing.expectError(error.InvalidUtf16, utf16ToUtf8(testing.allocator, &.{0xdc00}));
    try testing.expectError(error.InvalidUtf16, utf16ToUtf8(testing.allocator, &.{ 0xd800, 'x' }));
}

test "automation insertion bad index releases partial primitive storage with its exact error" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    abi.put_failure_index = 1;
    abi.put_failure = 0x8002000b;
    try testing.expectError(error.BadArrayIndex, safeArrayFromI32Slice(&api, &.{ 10, 20 }));
    try testing.expectEqual(@as(u32, 1), abi.array_frees);
    try testing.expectEqual(@as(u32, 0), abi.live_arrays);
}

test "automation null BSTR is not an absent optional property" {
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var null_string = VariantOwner.fromOwnedBstr(&api, null);
    try testing.expectEqual(@as(u16, 8), variantType(&null_string.raw));
    try testing.expect(!null_string.isEmpty());
    try testing.expect(null_string.raw.Anonymous.Anonymous.Anonymous.bstrVal == null);
    try null_string.deinit();
    const missing = try VariantOwner.fromValue(&api, ?bindings.Bstr, null);
    try testing.expect(missing.isEmpty());
    try testing.expectEqual(@as(u32, 0), abi.string_frees);
}

fn automationComAllocationFailures(gpa: std.mem.Allocator) !void {
    var abi = AutomationTestAbi.init(gpa);
    const api = abi.api();
    var object = AutomationTestUnknown.init();
    var owner = safeArrayFromComSlice(&api, &.{ &object.interface, &object.interface }) catch |failure| {
        try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
        return failure;
    };
    try testing.expectEqual(@as(u32, 3), @atomicLoad(u32, &object.references, .monotonic));
    try owner.deinit();
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 0), abi.live_arrays);
}

test "automation COM array fail-N does not leak elements or their allocation" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    try testing.checkAllAllocationFailures(testing.allocator, automationComAllocationFailures, .{});
}

fn automationWideAllocationFailures(gpa: std.mem.Allocator) !void {
    var buffer = StringBuffer.acquire();
    defer buffer.deinit(gpa);
    var wide = WideString.new(&buffer.units);
    wide.writeStr(gpa, "é") catch |failure| {
        try testing.expectEqual(@as(usize, 0), buffer.units.items.len);
        return failure;
    };
    wide.writeStr(gpa, &@as([(256) * 3]u8, @bitCast(@as([256][3]u8, @splat("界".*))))) catch |failure| {
        try testing.expectEqualSlices(u16, &.{0xe9}, buffer.units.items);
        return failure;
    };
    try testing.expectEqual(@as(usize, 257), buffer.units.items.len);
    try testing.expectEqual(@as(u16, 0xe9), buffer.units.items[0]);
    for (buffer.units.items[1..]) |unit| try testing.expectEqual(@as(u16, 0x754c), unit);
}

test "automation wide writer fail-N preserves completed Unicode content" {
    try testing.checkAllAllocationFailures(testing.allocator, automationWideAllocationFailures, .{});
}

test "automation host provider result transfers one owned reference and preserves native errors" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    const hwnd: bindings.Hwnd = @ptrFromInt(1);
    try testing.expect((try hostProviderFromHwnd(&api, hwnd)) == null);
    var object = AutomationTestUnknown.init();
    abi.host_object = @ptrCast(&object.interface);
    const host = (try hostProviderFromHwnd(&api, hwnd)).?;
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 1), host.IUnknown.Release());
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    abi.host_failure = 0x80070057;
    try testing.expectError(error.InvalidArgument, hostProviderFromHwnd(&api, hwnd));
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.adds, .monotonic));
    try testing.expectEqual(@as(u32, 1), @atomicLoad(u32, &object.releases, .monotonic));
    try testing.expectEqual(@as(u32, 0), object.interface.Release());
    try testing.expectEqual(@as(u32, 0), @atomicLoad(u32, &object.references, .monotonic));
    try testing.expectEqual(@as(u32, 2), @atomicLoad(u32, &object.releases, .monotonic));
}

test "automation wide values compare contents and transfer BSTR conversion ownership" {
    var first = StringBuffer.acquire();
    defer first.deinit(testing.allocator);
    var second = StringBuffer.acquire();
    defer second.deinit(testing.allocator);
    var first_writer = WideString.new(&first.units);
    var second_writer = WideString.new(&second.units);
    try first_writer.writeStr(testing.allocator, "é\x00😀");
    try second_writer.writeStr(testing.allocator, "é\x00😀");
    try testing.expect(first_writer.eql(second_writer));
    try testing.expectError(error.InvalidArgument, first_writer.writeChar(testing.allocator, 0xd800));
    try testing.expect(first_writer.eql(second_writer));
    var abi = AutomationTestAbi.init(testing.allocator);
    const api = abi.api();
    var value = try first_writer.toVariant(&api);
    try testing.expectEqual(@as(u16, 8), variantType(&value.raw));
    try testing.expectEqualSlices(
        u16,
        &.{ 0xe9, 0, 0xd83d, 0xde00 },
        abi.stringUnits(value.raw.Anonymous.Anonymous.Anonymous.bstrVal.?),
    );
    try value.deinit();
    try testing.expectEqual(@as(u32, 1), abi.string_frees);
    try second_writer.writeChar(testing.allocator, 'x');
    try testing.expect(!first_writer.eql(second_writer));
}
