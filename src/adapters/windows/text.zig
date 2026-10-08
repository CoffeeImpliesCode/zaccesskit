//! Windows UIA text ranges over guarded consumer tree leases.
//! `create` transfers owned weak handles only on success. Clients release returned COM references.
//! Text limits count UTF-16 code units. A limit never splits a surrogate pair.

const std = @import("std");
const bindings = @import("bindings.zig");
const com = @import("com.zig");
const context = @import("context.zig");
const errors = @import("error_codes.zig");
const util = @import("util.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const ranges = consumer.text.range;
const query = consumer.text.query;
const position = consumer.text.position;
const motion = consumer.text.position_motion;
const inner = consumer.text.position_inner;
const uia = bindings.uia;
const Range = ranges.Range;
const WeakRange = ranges.WeakRange;
const Position = position.Position;
const ProviderError = context.ProviderError;
const Interface = bindings.ITextRangeProvider;
const Hresult = bindings.Hresult;
const Endpoint = uia.TextPatternRangeEndpoint;
const Unit = uia.TextUnit;

const inherited = consumer.text.inherited;
const State = struct {
    weak: context.WeakContext,
    range: WeakRange,
    mutex: std.Io.Mutex = .init,

    pub fn deinit(self: *State) void {
        self.range.deinit();
        self.weak.deinit();
    }

    fn lock(self: *State) void {
        self.mutex.lockUncancelable(self.weak.io());
    }

    fn unlock(self: *State) void {
        self.mutex.unlock(self.weak.io());
    }
};

const Object = if (bindings.winapi_resolves) com.Object(State, .{
    com.Descriptor{ .Interface = Interface, .Iid = uia.IID_ITextRangeProvider },
}) else void;

/// Creates one caller-owned COM reference. On error, the caller still owns both inputs.
/// The allocator and context's runtime and automation table must outlive the returned reference.
pub fn create(gpa: std.mem.Allocator, weak: context.WeakContext,
    range: WeakRange) ProviderError!*Interface
{
    if (comptime !bindings.winapi_resolves) return error.NotImplemented;
    const object = try Object.create(gpa, .{@ptrCast(&vtable)}, .{
        .weak = weak, .range = range,
    });
    return @ptrCast(@constCast(object.iface(0)));
}

const vtable: Interface.VTable = if (bindings.winapi_resolves) .{
    .base = Object.baseVTable(0),
    .Clone = clone,
    .Compare = compare,
    .CompareEndpoints = compareEndpoints,
    .ExpandToEnclosingUnit = expand,
    .FindAttribute = findAttribute,
    .FindText = findText,
    .GetAttributeValue = getAttributeValue,
    .GetBoundingRectangles = getBoundingRectangles,
    .GetEnclosingElement = getEnclosingElement,
    .GetText = getText,
    .Move = move,
    .MoveEndpointByUnit = moveEndpointByUnit,
    .MoveEndpointByRange = moveEndpointByRange,
    .Select = select,
    .AddToSelection = addToSelection,
    .RemoveFromSelection = removeFromSelection,
    .ScrollIntoView = scrollIntoView,
    .GetChildren = getChildren,
} else undefined;

fn objectOf(raw: *const Interface) *Object {
    return Object.fromIface(Interface, @ptrCast(raw));
}

fn foreignState(raw: ?*Interface) ProviderError!*State {
    const present = raw orelse return error.InvalidArgument;
    // Check the public vtable word before accessing this implementation's allocation.
    if (present.vtable != &vtable) return error.InvalidArgument;
    return &objectOf(present).state;
}

fn status(err: ProviderError) Hresult {
    return switch (err) {
        error.OutOfMemory, error.ProviderLimitExceeded => errors.fromBits(0x8007000e),
        error.ElementNotAvailable, error.NoSuchNode, error.WindowUnavailable =>
            errors.elementNotAvailable(),
        error.InvalidArgument, error.InvalidPosition, error.IndexOutOfRange,
        error.InvalidUtf8, error.InvalidUtf16,
        error.StringTooLong, error.ArrayTooLong, error.LocaleNameInvalid,
        error.WindowTitleTooLong, error.InteriorNul => errors.invalidArg(),
        error.BadVariantType => errors.fromBits(0x80020008),
        error.BadArrayIndex => errors.fromBits(0x8002000b),
        error.ArrayLocked => errors.fromBits(0x8002000d),
        error.InvalidOperation => errors.invalidOperation(),
        error.NotImplemented => errors.notImplemented(),
        else => errors.fail(),
    };
}

const StateLocks = struct {
    first: *State,
    second: ?*State,

    fn acquire(a: *State, b: *State) StateLocks {
        const first = if (@intFromPtr(a) <= @intFromPtr(b)) a else b;
        const second: ?*State = if (a == b) null else if (first == a) b else a;
        first.lock();
        if (second) |held| held.lock();
        return .{ .first = first, .second = second };
    }

    fn deinit(self: *StateLocks) void {
        if (self.second) |held| held.unlock();
        self.first.unlock();
    }
};

const Read = struct {
    lease: context.ContextLease,
    state: *State,
    live: Range,
    locked: bool = true,

    fn acquire(state: *State) ProviderError!Read {
        var lease = try state.weak.lease();
        errdefer lease.deinit();
        state.lock();
        errdefer state.unlock();
        const live = try query.upgrade(state.range, lease.state()) orelse
            return error.ElementNotAvailable;
        return .{ .lease = lease, .state = state, .live = live };
    }

    fn unlock(self: *Read) void {
        if (!self.locked) return;
        self.state.unlock();
        self.locked = false;
    }

    fn deinit(self: *Read) void {
        self.unlock();
        self.lease.deinit();
    }

    fn save(self: *Read) ProviderError!void {
        const replacement = try ranges.downgrade(self.lease.allocator(), self.live);
        self.state.range.deinit();
        self.state.range = replacement;
    }
};

fn copyPath(gpa: std.mem.Allocator, path: inner.ComparablePath)
    std.mem.Allocator.Error!inner.ComparablePath
{
    var result: inner.ComparablePath = .{
        .gpa = gpa, .indices = .empty, .character_index = path.character_index,
    };
    try result.indices.appendSlice(gpa, path.indices.items);
    return result;
}

fn copyWeak(gpa: std.mem.Allocator, value: WeakRange) std.mem.Allocator.Error!WeakRange {
    var start = try copyPath(gpa, value.start_comparable);
    errdefer start.deinit();
    const end = try copyPath(gpa, value.end_comparable);
    return .{
        .node_id = value.node_id, .start = value.start, .end = value.end,
        .start_comparable = start, .end_comparable = end,
    };
}

fn clone(raw: *const Interface, output: ?*?*Interface) callconv(.winapi) Hresult {
    const out = output orelse return errors.invalidArg();
    out.* = null;
    const object = objectOf(raw);
    const state = &object.state;
    state.lock();
    defer state.unlock();
    var range = copyWeak(object.gpa, state.range) catch |err| return status(err);
    var weak = state.weak.clone();
    out.* = create(object.gpa, weak, range) catch |err| {
        weak.deinit();
        range.deinit();
        return status(err);
    };
    return errors.ok();
}

fn compare(raw: *const Interface, other_raw: ?*Interface,
    output: ?*bindings.Bool) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = 0;
    const state = &objectOf(raw).state;
    const other = foreignState(other_raw) catch |err| return status(err);
    if (!state.weak.same(other.weak)) return errors.ok();
    var locks = StateLocks.acquire(state, other);
    defer locks.deinit();
    const a = state.range;
    const b = other.range;
    out.* = @intFromBool(std.meta.eql(a.node_id, b.node_id) and
        std.meta.eql(a.start, b.start) and std.meta.eql(a.end, b.end) and
        a.start_comparable.order(b.start_comparable) == .eq and
        a.end_comparable.order(b.end_comparable) == .eq);
    return errors.ok();
}

fn weakEndpoint(value: WeakRange, endpoint: Endpoint) ProviderError!inner.ComparablePath {
    return switch (@intFromEnum(endpoint)) {
        0 => value.start_comparable,
        1 => value.end_comparable,
        else => error.InvalidArgument,
    };
}

fn endpointPosition(value: Range, endpoint: Endpoint) ProviderError!Position {
    return switch (@intFromEnum(endpoint)) {
        0 => ranges.start(value),
        1 => ranges.end(value),
        else => error.InvalidArgument,
    };
}

fn setEndpoint(gpa: std.mem.Allocator, value: *Range, endpoint: Endpoint,
    pos: Position) ProviderError!void
{
    switch (@intFromEnum(endpoint)) {
        0 => try ranges.setStart(gpa, value, pos),
        1 => try ranges.setEnd(gpa, value, pos),
        else => return error.InvalidArgument,
    }
}

fn orderNumber(value: std.math.Order) i32 {
    return switch (value) { .lt => -1, .eq => 0, .gt => 1 };
}

fn compareEndpoints(raw: *const Interface, endpoint: Endpoint, other_raw: ?*Interface,
    other_endpoint: Endpoint, output: ?*i32) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = 0;
    const state = &objectOf(raw).state;
    const other = foreignState(other_raw) catch |err| return status(err);
    if (state == other) {
        state.lock();
        defer state.unlock();
        const a = weakEndpoint(state.range, endpoint) catch |err| return status(err);
        const b = weakEndpoint(state.range, other_endpoint) catch |err| return status(err);
        out.* = orderNumber(a.order(b));
        return errors.ok();
    }
    if (!state.weak.same(other.weak)) return errors.invalidArg();
    var lease = state.weak.lease() catch |err| return status(err);
    defer lease.deinit();
    var locks = StateLocks.acquire(state, other);
    defer locks.deinit();
    const a = (query.upgrade(state.range, lease.state()) catch |err| return status(err)) orelse
        return errors.elementNotAvailable();
    const b = (query.upgrade(other.range, lease.state()) catch |err| return status(err)) orelse
        return errors.elementNotAvailable();
    if (!std.meta.eql(a.node.id(), b.node.id())) return errors.invalidArg();
    const a_pos = endpointPosition(a, endpoint) catch |err| return status(err);
    const b_pos = endpointPosition(b, other_endpoint) catch |err| return status(err);
    var a_key = inner.comparable(lease.allocator(), a_pos.inner, a_pos.root_node) catch |err|
        return status(err);
    defer a_key.deinit();
    var b_key = inner.comparable(lease.allocator(), b_pos.inner, b_pos.root_node) catch |err|
        return status(err);
    defer b_key.deinit();
    out.* = orderNumber(a_key.order(b_key));
    return errors.ok();
}

fn backToUnitStart(pos: Position, unit: Unit) ProviderError!Position {
    return switch (@intFromEnum(unit)) {
        0 => pos,
        1 => if (try position.isFormatStart(pos)) pos else try motion.backwardToFormatStart(pos),
        2 => if (position.isWordStart(pos)) pos else try motion.backwardToWordStart(pos),
        3 => if (position.isLineStart(pos)) pos else try motion.backwardToLineStart(pos),
        4 => if (try position.isParagraphStart(pos)) pos else try motion.backwardToParagraphStart(pos),
        5 => if (try position.isPageStart(pos)) pos else try motion.backwardToPageStart(pos),
        6 => if (try position.isDocumentStart(pos)) pos else try motion.documentStart(pos),
        else => error.InvalidArgument,
    };
}

fn forward(pos: Position, unit: Unit, to_end: bool) ProviderError!Position {
    return switch (@intFromEnum(unit)) {
        0 => if (to_end) try position.forwardToCharacterEnd(pos) else
            try position.forwardToCharacterStart(pos),
        1 => if (to_end) try motion.forwardToFormatEnd(pos) else try motion.forwardToFormatStart(pos),
        2 => if (to_end) try motion.forwardToWordEnd(pos) else try motion.forwardToWordStart(pos),
        3 => if (to_end) try motion.forwardToLineEnd(pos) else try motion.forwardToLineStart(pos),
        4 => if (to_end) try motion.forwardToParagraphEnd(pos) else
            try motion.forwardToParagraphStart(pos),
        5 => if (to_end) try motion.forwardToPageEnd(pos) else try motion.forwardToPageStart(pos),
        6 => try motion.documentEnd(pos),
        else => error.InvalidArgument,
    };
}

fn backward(pos: Position, unit: Unit) ProviderError!Position {
    return switch (@intFromEnum(unit)) {
        0 => try position.backwardToCharacterStart(pos),
        1 => try motion.backwardToFormatStart(pos),
        2 => try motion.backwardToWordStart(pos),
        3 => try motion.backwardToLineStart(pos),
        4 => try motion.backwardToParagraphStart(pos),
        5 => try motion.backwardToPageStart(pos),
        6 => try motion.documentStart(pos),
        else => error.InvalidArgument,
    };
}

const Movement = struct { pos: Position, count: i32 };
/// The magnitude of the minimum signed count is representable in u32.
const movement_steps_max: u32 = @as(u32, std.math.maxInt(i32)) + 1;

fn movePosition(initial: Position, unit: Unit, to_end: bool, count: i32)
    ProviderError!Movement
{
    var pos = initial;
    const requested: u32 = @intCast(if (count < 0) -@as(i64, count) else @as(i64, count));
    std.debug.assert(requested <= movement_steps_max);
    var moved: u32 = 0;
    while (moved < requested) : (moved += 1) {
        if (count > 0) {
            if (try position.isDocumentEnd(pos)) break;
            pos = try forward(pos, unit, to_end);
        } else {
            if (try position.isDocumentStart(pos)) break;
            pos = try backward(pos, unit);
        }
    }
    const signed: i64 = if (count < 0) -@as(i64, moved) else @as(i64, moved);
    return .{ .pos = pos, .count = @intCast(signed) };
}

fn expand(raw: *const Interface, unit: Unit) callconv(.winapi) Hresult {
    const state = &objectOf(raw).state;
    if (@intFromEnum(unit) == 6) {
        var lease = state.weak.lease() catch |err| return status(err);
        defer lease.deinit();
        state.lock();
        defer state.unlock();
        const node = (query.upgradeNode(state.range, lease.state()) catch |err|
            return status(err)) orelse return errors.elementNotAvailable();
        const live = query.documentRange(lease.allocator(), node) catch |err| return status(err);
        const replacement = ranges.downgrade(lease.allocator(), live) catch |err| return status(err);
        state.range.deinit();
        state.range = replacement;
        return errors.ok();
    }
    var read = Read.acquire(state) catch |err| return status(err);
    defer read.deinit();
    const initial = ranges.start(read.live);
    if (@intFromEnum(unit) == 0 and
        (position.isDocumentEnd(initial) catch |err| return status(err))) return errors.ok();
    const start = backToUnitStart(initial, unit) catch |err| return status(err);
    ranges.setStart(read.lease.allocator(), &read.live, start) catch |err| return status(err);
    if (!(position.isDocumentEnd(start) catch |err| return status(err))) {
        const end = forward(start, unit, true) catch |err| return status(err);
        ranges.setEnd(read.lease.allocator(), &read.live, end) catch |err| return status(err);
    }
    read.save() catch |err| return status(err);
    return errors.ok();
}

fn findAttribute(_: *const Interface, _: uia.UIA_TEXTATTRIBUTE_ID, _: bindings.Variant,
    _: bindings.Bool, output: ?*?*Interface) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = null;
    // AccessKit has no text attribute search. Null success is its native result.
    return errors.ok();
}

fn findText(_: *const Interface, _: ?bindings.Bstr, _: bindings.Bool, _: bindings.Bool,
    output: ?*?*Interface) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = null;
    // AccessKit does not expose text search through this provider.
    return errors.ok();
}

fn fontSize(value: f32) f64 { return value; }
fn fontWeight(value: f32) i32 {
    // Rust's float-to-integer cast saturates and maps NaN to zero.
    if (std.math.isNan(value)) return 0;
    if (value >= @as(f32, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    if (value <= @as(f32, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    return @intFromFloat(value);
}
fn decorationStyle(value: schema.TextDecoration) schema.TextDecorationStyle { return value.style; }
fn decorationColor(value: schema.TextDecoration) schema.Color { return value.color; }
fn isSubscript(value: schema.VerticalOffset) bool { return value == .subscript; }
fn isSuperscript(value: schema.VerticalOffset) bool { return value == .superscript; }

fn attribute(read: *Read, id: uia.UIA_TEXTATTRIBUTE_ID) ProviderError!util.VariantOwner {
    const gpa = read.lease.allocator();
    const api = read.lease.automation();
    const live = read.live;
    return switch (@intFromEnum(id)) {
        @intFromEnum(uia.UIA_IsReadOnlyAttributeId) =>
            util.VariantOwner.fromBool(api, consumer.node_ref.predicates.isReadOnly(live.node)),
        @intFromEnum(uia.UIA_CaretPositionAttributeId) => blk: {
            var caret: i32 = 0;
            if (try ranges.isDegenerate(gpa, live)) {
                const pos = ranges.start(live);
                if (position.isLineStart(pos)) {
                    caret = 1;
                } else if (position.isLineEnd(pos)) {
                    caret = 2;
                }
            }
            break :blk util.VariantOwner.fromI32(api, caret);
        },
        @intFromEnum(uia.UIA_CultureAttributeId) => blk: {
            const value = try inherited.rangeLanguage(gpa, live);
            break :blk switch (value) {
                .mixed => try util.VariantOwner.mixed(api),
                .single => |language| if (language) |name|
                    try util.VariantOwner.fromLocaleName(gpa, api, name) else
                    util.VariantOwner.init(api),
            };
        },
        @intFromEnum(uia.UIA_FontNameAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, []const u8, try inherited.rangeFontFamily(gpa, live)),
        @intFromEnum(uia.UIA_FontSizeAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, f64, ranges.map(f32, f64, try inherited.rangeFontSize(gpa, live), fontSize)),
        @intFromEnum(uia.UIA_FontWeightAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, i32, ranges.map(f32, i32, try inherited.rangeFontWeight(gpa, live), fontWeight)),
        @intFromEnum(uia.UIA_IsItalicAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, bool, try inherited.rangeIsItalic(gpa, live)),
        @intFromEnum(uia.UIA_BackgroundColorAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.Color, try inherited.rangeBackgroundColor(gpa, live)),
        @intFromEnum(uia.UIA_ForegroundColorAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.Color, try inherited.rangeForegroundColor(gpa, live)),
        @intFromEnum(uia.UIA_OverlineStyleAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.TextDecorationStyle, ranges.map(schema.TextDecoration,
                schema.TextDecorationStyle, try inherited.rangeOverline(gpa, live), decorationStyle)),
        @intFromEnum(uia.UIA_OverlineColorAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.Color, ranges.map(schema.TextDecoration, schema.Color,
                try inherited.rangeOverline(gpa, live), decorationColor)),
        @intFromEnum(uia.UIA_StrikethroughStyleAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.TextDecorationStyle, ranges.map(schema.TextDecoration,
                schema.TextDecorationStyle, try inherited.rangeStrikethrough(gpa, live), decorationStyle)),
        @intFromEnum(uia.UIA_StrikethroughColorAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.Color, ranges.map(schema.TextDecoration, schema.Color,
                try inherited.rangeStrikethrough(gpa, live), decorationColor)),
        @intFromEnum(uia.UIA_UnderlineStyleAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.TextDecorationStyle, ranges.map(schema.TextDecoration,
                schema.TextDecorationStyle, try inherited.rangeUnderline(gpa, live), decorationStyle)),
        @intFromEnum(uia.UIA_UnderlineColorAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, schema.Color, ranges.map(schema.TextDecoration, schema.Color,
                try inherited.rangeUnderline(gpa, live), decorationColor)),
        @intFromEnum(uia.UIA_HorizontalTextAlignmentAttributeId) =>
            try util.VariantOwner.fromRangeProperty(api, schema.TextAlign,
                try inherited.rangeTextAlign(gpa, live)),
        @intFromEnum(uia.UIA_IsSubscriptAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, bool, ranges.map(schema.VerticalOffset, bool,
                try inherited.rangeVerticalOffset(gpa, live), isSubscript)),
        @intFromEnum(uia.UIA_IsSuperscriptAttributeId) => try util.VariantOwner.fromRangeProperty(
            api, bool, ranges.map(schema.VerticalOffset, bool,
                try inherited.rangeVerticalOffset(gpa, live), isSuperscript)),
        else => try util.VariantOwner.notSupported(api),
    };
}

fn getAttributeValue(raw: *const Interface, id: uia.UIA_TEXTATTRIBUTE_ID,
    output: ?*bindings.Variant) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = std.mem.zeroes(bindings.Variant);
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    var owned = attribute(&read, id) catch |err| return status(err);
    out.* = owned.take();
    return errors.ok();
}

fn getBoundingRectangles(raw: *const Interface,
    output: ?*?*bindings.SafeArray) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = null;
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    const gpa = read.lease.allocator();
    var boxes = ranges.boundingBoxes(gpa, read.live) catch |err| return status(err);
    defer boxes.deinit(gpa);
    if (boxes.items.len == 0) return errors.ok();
    if (boxes.items.len > util.array_elements_max / 4) return status(error.ArrayTooLong);
    const hwnd = read.lease.hwnd() orelse return status(error.WindowUnavailable);
    const origin = util.clientTopLeft(read.lease.automation(), @ptrCast(hwnd)) catch |err|
        return status(err);
    const values = gpa.alloc(f64, boxes.items.len * 4) catch |err| return status(err);
    defer gpa.free(values);
    for (boxes.items, 0..) |box, index| {
        const offset = index * 4;
        values[offset] = box.x0 + origin.x;
        values[offset + 1] = box.y0 + origin.y;
        values[offset + 2] = box.x1 - box.x0;
        values[offset + 3] = box.y1 - box.y0;
    }
    var array = util.safeArrayFromF64Slice(read.lease.automation(), values) catch |err|
        return status(err);
    out.* = array.take();
    return errors.ok();
}

fn getEnclosingElement(raw: *const Interface,
    output: ?*?*bindings.IRawElementProviderSimple) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = null;
    const state = &objectOf(raw).state;
    var lease = state.weak.lease() catch |err| return status(err);
    defer lease.deinit();
    state.lock();
    defer state.unlock();
    const node = (query.upgradeNode(state.range, lease.state()) catch |err| return status(err)) orelse
        return errors.elementNotAvailable();
    out.* = lease.provider(node.id()) catch |err| return status(err);
    return errors.ok();
}

const TextSink = struct {
    gpa: std.mem.Allocator,
    wide: util.WideString,
    units_limit: usize,
    limited: bool,
    failure: ?util.AutomationError = null,

    fn append(userdata: ?*anyopaque, _: consumer.node_id.NodeRef, bytes: []const u8) bool {
        const self: *TextSink = @ptrCast(@alignCast(userdata.?));
        if (!self.limited) {
            self.wide.writeStr(self.gpa, bytes) catch |err| {
                self.failure = err;
                return false;
            };
            return true;
        }
        var remaining = self.units_limit - self.wide.buffer.items.len;
        if (remaining == 0) return false;
        var iterator = (std.unicode.Utf8View.init(bytes) catch {
            self.failure = error.InvalidUtf8;
            return false;
        }).iterator();
        var prefix_bytes: usize = 0;
        // Each iteration consumes one scalar from this bounded, validated input slice.
        while (iterator.nextCodepointSlice()) |scalar_bytes| {
            const units: usize = if (scalar_bytes.len == 4) 2 else 1;
            if (units > remaining) break;
            remaining -= units;
            prefix_bytes += scalar_bytes.len;
        }
        self.wide.writeStr(self.gpa, bytes[0..prefix_bytes]) catch |err| {
            self.failure = err;
            return false;
        };
        return prefix_bytes == bytes.len;
    }
};

fn getText(raw: *const Interface, max_length: i32,
    output: ?*?bindings.Bstr) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = null;
    if (max_length < -1) return errors.invalidArg();
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    const gpa = read.lease.allocator();
    var buffer = util.StringBuffer.acquire();
    defer buffer.deinit(gpa);
    var sink = TextSink{
        .gpa = gpa, .wide = util.WideString.new(&buffer.units),
        .units_limit = if (max_length == -1) util.bstr_units_max else @intCast(max_length),
        .limited = max_length != -1,
    };
    const completed = ranges.traverseText(gpa, read.live, &sink, TextSink.append) catch |err|
        return status(err);
    _ = completed;
    if (sink.failure) |err| return status(err);
    out.* = sink.wide.toBstr(read.lease.automation()) catch |err| return status(err);
    return errors.ok();
}

fn move(raw: *const Interface, unit: Unit, count: i32,
    output: ?*i32) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = 0;
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    const gpa = read.lease.allocator();
    const degenerate = ranges.isDegenerate(gpa, read.live) catch |err| return status(err);
    const start = if (degenerate) ranges.start(read.live) else
        backToUnitStart(ranges.start(read.live), unit) catch |err| return status(err);
    const movement = movePosition(start, unit, false, count) catch |err| return status(err);
    if (movement.count != 0) {
        ranges.setStart(gpa, &read.live, movement.pos) catch |err| return status(err);
        const end = if (degenerate or
            (position.isDocumentEnd(movement.pos) catch |err| return status(err)))
            movement.pos else forward(movement.pos, unit, true) catch |err| return status(err);
        ranges.setEnd(gpa, &read.live, end) catch |err| return status(err);
        read.save() catch |err| return status(err);
    }
    out.* = movement.count;
    return errors.ok();
}

fn moveEndpointByUnit(raw: *const Interface, endpoint: Endpoint, unit: Unit, count: i32,
    output: ?*i32) callconv(.winapi) Hresult
{
    const out = output orelse return errors.invalidArg();
    out.* = 0;
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    const pos = endpointPosition(read.live, endpoint) catch |err| return status(err);
    const movement = movePosition(pos, unit, @intFromEnum(endpoint) == 1, count) catch |err|
        return status(err);
    setEndpoint(read.lease.allocator(), &read.live, endpoint, movement.pos) catch |err|
        return status(err);
    read.save() catch |err| return status(err);
    out.* = movement.count;
    return errors.ok();
}

fn moveEndpointByRange(raw: *const Interface, endpoint: Endpoint, other_raw: ?*Interface,
    other_endpoint: Endpoint) callconv(.winapi) Hresult
{
    const state = &objectOf(raw).state;
    const other = foreignState(other_raw) catch |err| return status(err);
    if (!state.weak.same(other.weak)) return errors.invalidArg();
    var lease = state.weak.lease() catch |err| return status(err);
    defer lease.deinit();
    var locks = StateLocks.acquire(state, other);
    defer locks.deinit();
    var live = (query.upgrade(state.range, lease.state()) catch |err| return status(err)) orelse
        return errors.elementNotAvailable();
    const other_live = (query.upgrade(other.range, lease.state()) catch |err|
        return status(err)) orelse return errors.elementNotAvailable();
    if (!std.meta.eql(live.node.id(), other_live.node.id())) return errors.invalidArg();
    const pos = endpointPosition(other_live, other_endpoint) catch |err| return status(err);
    setEndpoint(lease.allocator(), &live, endpoint, pos) catch |err| return status(err);
    const replacement = ranges.downgrade(lease.allocator(), live) catch |err| return status(err);
    state.range.deinit();
    state.range = replacement;
    return errors.ok();
}

fn select(raw: *const Interface) callconv(.winapi) Hresult {
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    const target = read.lease.state().locateNode(read.live.node.id()) orelse
        return errors.elementNotAvailable();
    const request: schema.ActionRequest = .{
        .action = .set_text_selection, .target_node = target.local_id,
        .target_tree = target.tree_id, .data = .{ .set_text_selection = ranges.toTextSelection(read.live) },
    };
    read.unlock();
    read.live = undefined;
    read.lease.dispatch(request) catch |err| return status(err);
    return errors.ok();
}

fn addToSelection(_: *const Interface) callconv(.winapi) Hresult {
    return errors.invalidOperation();
}

fn removeFromSelection(_: *const Interface) callconv(.winapi) Hresult {
    return errors.invalidOperation();
}

fn scrollIntoView(raw: *const Interface, align_to_top: bindings.Bool) callconv(.winapi) Hresult {
    var read = Read.acquire(&objectOf(raw).state) catch |err| return status(err);
    defer read.deinit();
    const request: schema.ActionRequest = blk: {
        const pos = if (align_to_top != 0) ranges.start(read.live) else ranges.end(read.live);
        const target = read.lease.state().locateNode(pos.inner.node.id()) orelse
            return errors.elementNotAvailable();
        break :blk .{
            .action = .scroll_into_view, .target_node = target.local_id, .target_tree = target.tree_id,
            .data = .{ .scroll_hint = if (align_to_top != 0) .top_edge else .bottom_edge },
        };
    };
    read.unlock();
    read.live = undefined;
    read.lease.dispatch(request) catch |err| return status(err);
    return errors.ok();
}

fn getChildren(raw: *const Interface, output: ?*?*bindings.SafeArray) callconv(.winapi) Hresult {
    const out = output orelse return errors.invalidArg();
    out.* = null;
    const state = &objectOf(raw).state;
    var array = util.safeArrayFromComSlice(state.weak.automation(), &.{}) catch |err|
        return status(err);
    out.* = array.take();
    return errors.ok();
}

const TestFixture = struct {
    runtime: std.Io.Threaded = undefined,
    abi: util.AutomationTestAbi = undefined,
    api: util.AutomationApi = undefined,
    owner: ?*@import("adapter.zig").WindowsAdapter = null,
    last_action: ?schema.Action = null,
    last_selection: ?schema.TextSelection = null,
    last_hint: ?schema.ScrollHint = null,
    last_target: ?schema.NodeId = null,
    action_reentered: bool = false,

    fn init(self: *TestFixture) !void {
        const gpa = std.testing.allocator;
        self.runtime = .init(gpa, .{});
        errdefer self.runtime.deinit();
        self.abi = .init(gpa);
        self.api = self.abi.api();
        const node_provider = @import("node.zig");
        self.owner = try @import("adapter.zig").WindowsAdapter.create(gpa, .{
            .io = self.runtime.io(),
            .platform = @import("adapter.zig").testPlatform(),
            .factory = .{
                .create_node = node_provider.create,
                .create_range = create,
                .enqueue_properties = node_provider.enqueuePropertyChanges,
            },
            .automation = &self.api,
            .hwnd = @ptrFromInt(1),
            .is_window_focused = false,
            .action_sink = .{ .native = .{ .callback = action, .userdata = self } },
        });
        errdefer self.owner.?.deinit();
        var update: schema.TreeUpdate = .{};
        errdefer update.deinit(gpa);
        const document_node = blk: {
            var node = schema.Node.init(gpa, .text_input);
            errdefer node.deinit();
            try schema.ids_props.setChildren(&node.properties, &.{.{ .value = 2 }});
            break :blk node;
        };
        try update.pushNode(gpa, .{ .value = 1 }, document_node);
        const run = blk: {
            var node = schema.Node.init(gpa, .text_run);
            errdefer node.deinit();
            try schema.strings.setValue(&node.properties, "Aé\x00😀 Z");
            try schema.vectors.setCharacterLengths(&node.properties, &.{ 1, 2, 1, 4, 1, 1 });
            try schema.vectors.setWordStarts(&node.properties, &.{ 0, 5 });
            break :blk node;
        };
        try update.pushNode(gpa, .{ .value = 2 }, run);
        update.tree = schema.TreeInfo.init(.{ .value = 1 });
        update.focus = .{ .value = 1 };
        const initial = update;
        update = .{};
        const tree = try consumer.tree.Tree.init(gpa, initial, true);
        self.owner.?.state = .{ .active = tree };
    }

    fn deinit(self: *TestFixture) void {
        if (self.owner) |owner| owner.deinit();
        self.runtime.deinit();
    }

    fn document(self: *TestFixture) !*Interface {
        var weak = self.owner.?.context.weak();
        errdefer weak.deinit();
        var lease = try weak.lease();
        defer lease.deinit();
        const node = lease.state().nodeById(.init(.{ .value = 1 }, .init(0))).?;
        var value = try ranges.downgrade(std.testing.allocator, try query.documentRange(
            std.testing.allocator, node,
        ));
        errdefer value.deinit();
        return create(std.testing.allocator, weak, value);
    }

    fn action(request: schema.ActionRequest, userdata: ?*anyopaque) void {
        const self: *TestFixture = @ptrCast(@alignCast(userdata.?));
        self.last_action = request.action;
        self.last_target = request.target_node;
        if (request.data) |data| {
            switch (data) {
                .set_text_selection => |selection| self.last_selection = selection,
                .scroll_hint => |hint| self.last_hint = hint,
                else => @panic("Unexpected text action."),
            }
        }
        var lease = self.owner.?.context.enter() catch @panic("Action must reenter the tree.");
        self.action_reentered = lease.owner == self.owner.?;
        lease.deinit();
    }
};

fn releaseRange(value: *Interface) void {
    const unknown: *bindings.IUnknown = @ptrCast(value);
    _ = unknown.vtable.Release(unknown);
}

fn expectText(fixture: *TestFixture, value: *Interface, max_length: i32,
    expected: []const u16) !void
{
    var string: ?bindings.Bstr = null;
    try std.testing.expectEqual(errors.ok(), value.vtable.GetText(value, max_length, &string));
    defer if (string) |owned| fixture.api.free_string(fixture.api.context, owned);
    try std.testing.expectEqualSlices(u16, expected, fixture.abi.stringUnits(string.?));
}

test "UIA text COM counted Unicode honors maxLength without splitting surrogate pairs" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    const expected = [_]u16{ 'A', 0xe9, 0, 0xd83d, 0xde00, ' ', 'Z' };
    try expectText(&fixture, value, -1, &expected);
    try expectText(&fixture, value, 0, &.{});
    try expectText(&fixture, value, 1, &.{'A'});
    try expectText(&fixture, value, 4, expected[0..3]);
    try expectText(&fixture, value, 5, expected[0..5]);
    try expectText(&fixture, value, 100, &expected);
    var string: ?bindings.Bstr = null;
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetText(value, -2, &string));
    try std.testing.expect(string == null);
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetText(value, -1, null));
}

test "UIA text COM clone comparison movement and endpoint collapse" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    var copied: ?*Interface = null;
    try std.testing.expectEqual(errors.ok(), value.vtable.Clone(value, &copied));
    defer releaseRange(copied.?);
    var equal: bindings.Bool = 0;
    try std.testing.expectEqual(errors.ok(), value.vtable.Compare(value, copied, &equal));
    try std.testing.expectEqual(@as(bindings.Bool, 1), equal);
    var moved: i32 = 0;
    try std.testing.expectEqual(errors.ok(), value.vtable.MoveEndpointByUnit(
        value, .Start, .Character, 3, &moved,
    ));
    try std.testing.expectEqual(@as(i32, 3), moved);
    try expectText(&fixture, value, -1, &.{ 0xd83d, 0xde00, ' ', 'Z' });
    var ordering: i32 = 0;
    try std.testing.expectEqual(errors.ok(), value.vtable.CompareEndpoints(
        value, .Start, copied, .Start, &ordering,
    ));
    try std.testing.expectEqual(@as(i32, 1), ordering);
    try std.testing.expectEqual(errors.ok(), value.vtable.MoveEndpointByRange(
        value, .End, copied, .Start,
    ));
    try expectText(&fixture, value, -1, &.{});
    try std.testing.expectEqual(errors.ok(), value.vtable.Move(value, .Character, 100, &moved));
    try std.testing.expectEqual(@as(i32, 6), moved);
    try expectText(&fixture, value, -1, &.{});
    try std.testing.expectEqual(errors.ok(), value.vtable.Move(value, .Character, -1, &moved));
    try std.testing.expectEqual(@as(i32, -1), moved);
    try expectText(&fixture, value, -1, &.{});
}

test "UIA text COM stale endpoints closed context and cross context rejection" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var other: TestFixture = .{};
    try other.init();
    defer other.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    const foreign = try other.document();
    defer releaseRange(foreign);
    var equal: bindings.Bool = 99;
    try std.testing.expectEqual(errors.ok(), value.vtable.Compare(value, foreign, &equal));
    try std.testing.expectEqual(@as(bindings.Bool, 0), equal);
    var ordering: i32 = 0;
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.CompareEndpoints(
        value, .Start, foreign, .Start, &ordering,
    ));
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const state = &lease.owner.tree().?.state;
        const removed = state.nodes.fetchRemove(.init(.{ .value = 2 }, .init(0))).?;
        var owned = removed.value.data;
        owned.deinit();
    }
    var string: ?bindings.Bstr = null;
    try std.testing.expectEqual(errors.elementNotAvailable(), value.vtable.GetText(value, -1, &string));
    try std.testing.expect(string == null);
    try std.testing.expectEqual(errors.ok(), value.vtable.CompareEndpoints(
        value, .Start, value, .End, &ordering,
    ));
    try std.testing.expectEqual(@as(i32, -1), ordering);
    fixture.owner.?.deinit();
    fixture.owner = null;
    try std.testing.expectEqual(errors.elementNotAvailable(), value.vtable.GetText(value, -1, &string));
    var copied: ?*Interface = null;
    try std.testing.expectEqual(errors.ok(), value.vtable.Clone(value, &copied));
    releaseRange(copied.?);
}

test "UIA text COM selection dispatch drops guard and real unsupported semantics" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    try std.testing.expectEqual(errors.ok(), value.vtable.Select(value));
    try std.testing.expectEqual(schema.Action.set_text_selection, fixture.last_action.?);
    try std.testing.expectEqual(@as(usize, 0), fixture.last_selection.?.anchor.character_index);
    try std.testing.expectEqual(@as(usize, 6), fixture.last_selection.?.focus.character_index);
    try std.testing.expect(fixture.action_reentered);
    try std.testing.expectEqual(errors.invalidOperation(), value.vtable.AddToSelection(value));
    try std.testing.expectEqual(errors.invalidOperation(), value.vtable.RemoveFromSelection(value));
    var found: ?*Interface = value;
    try std.testing.expectEqual(errors.ok(), value.vtable.FindText(value, null, 0, 0, &found));
    try std.testing.expect(found == null);
    try std.testing.expectEqual(errors.ok(), value.vtable.FindAttribute(
        value, .AnimationStyleAttributeId, std.mem.zeroes(bindings.Variant), 0, &found,
    ));
    try std.testing.expect(found == null);
    var children: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(errors.ok(), value.vtable.GetChildren(value, &children));
    var owned = util.ArrayOwner{ .api = &fixture.api, .raw = children };
    defer owned.deinit() catch @panic("Valid array must destroy.");
    try std.testing.expect(children != null);
    try std.testing.expectEqual(@as(usize, 0), fixture.abi.array(children.?).objects.len);
}

test "UIA text COM all unit expansion and directional movement boundaries" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const units = [_]Unit{ .Character, .Format, .Word, .Line, .Paragraph, .Page, .Document };
    for (units) |unit| {
        const value = try fixture.document();
        defer releaseRange(value);
        try std.testing.expectEqual(errors.ok(), value.vtable.ExpandToEnclosingUnit(value, unit));
        switch (unit) {
            .Character => try expectText(&fixture, value, -1, &.{'A'}),
            .Word => try expectText(&fixture, value, -1, &.{ 'A', 0xe9, 0, 0xd83d, 0xde00, ' ' }),
            else => try expectText(&fixture, value, -1, &.{ 'A', 0xe9, 0, 0xd83d, 0xde00, ' ', 'Z' }),
        }
        var moved: i32 = 0;
        try std.testing.expectEqual(errors.ok(), value.vtable.Move(value, unit, 1, &moved));
        try std.testing.expectEqual(@as(i32, 1), moved);
        switch (unit) {
            .Character => try expectText(&fixture, value, -1, &.{0xe9}),
            .Word => try expectText(&fixture, value, -1, &.{'Z'}),
            else => try expectText(&fixture, value, -1, &.{}),
        }
        try std.testing.expectEqual(errors.ok(), value.vtable.MoveEndpointByUnit(
            value, .Start, .Document, std.math.minInt(i32), &moved,
        ));
        try std.testing.expectEqual(@as(i32, -1), moved);
    }
}

test "UIA text COM foreign implementation is rejected without private state access" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    var weak = fixture.owner.?.context.weak();
    defer weak.deinit();
    const node = try weak.createNode(null);
    const foreign: *Interface = @ptrCast(node);
    defer {
        const unknown: *bindings.IUnknown = @ptrCast(node);
        _ = unknown.vtable.Release(unknown);
    }
    var equal: bindings.Bool = 99;
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.Compare(value, foreign, &equal));
    try std.testing.expectEqual(@as(bindings.Bool, 0), equal);
    var ordering: i32 = 99;
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.CompareEndpoints(
        value, .Start, foreign, .End, &ordering,
    ));
    try std.testing.expectEqual(@as(i32, 0), ordering);
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.MoveEndpointByRange(
        value, .Start, foreign, .End,
    ));
}

test "UIA text COM reserved attribute transfers and releases an independent reference" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    const unknown: *bindings.IUnknown = @ptrCast(value);
    fixture.abi.reserved_object = unknown;
    var raw: bindings.Variant = std.mem.zeroes(bindings.Variant);
    try std.testing.expectEqual(errors.ok(), value.vtable.GetAttributeValue(
        value, .AnimationStyleAttributeId, &raw,
    ));
    var owned = util.VariantOwner{ .api = &fixture.api, .raw = raw };
    try std.testing.expectEqual(@as(u16, 13), util.variantType(&raw));
    try std.testing.expectEqual(@as(u32, 3), unknown.vtable.AddRef(unknown));
    try std.testing.expectEqual(@as(u32, 2), unknown.vtable.Release(unknown));
    try owned.deinit();
    try std.testing.expectEqual(@as(u32, 2), unknown.vtable.AddRef(unknown));
    try std.testing.expectEqual(@as(u32, 1), unknown.vtable.Release(unknown));
    fixture.abi.reserved_failure = errors.toBits(errors.invalidArg());
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetAttributeValue(
        value, .AnimationStyleAttributeId, &raw,
    ));
    try std.testing.expectEqual(@as(u16, 0), util.variantType(&raw));
}

test "UIA text COM document expansion recovers invalid endpoints and enclosing node" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const run = lease.owner.tree().?.state.nodes.getPtr(
            .init(.{ .value = 2 }, .init(0)),
        ).?;
        try schema.strings.setValue(&run.data.properties, "A");
        try schema.vectors.setCharacterLengths(&run.data.properties, &.{1});
    }
    var string: ?bindings.Bstr = null;
    try std.testing.expectEqual(errors.elementNotAvailable(), value.vtable.GetText(value, -1, &string));
    try std.testing.expectEqual(errors.ok(), value.vtable.ExpandToEnclosingUnit(value, .Document));
    try expectText(&fixture, value, -1, &.{'A'});
}

test "UIA text COM rectangles are screen f64 arrays and allocation errors preserve null" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    var boxes: ?*bindings.SafeArray = null;
    try std.testing.expectEqual(errors.ok(), value.vtable.GetBoundingRectangles(value, &boxes));
    try std.testing.expect(boxes == null);
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const run = lease.owner.tree().?.state.nodes.getPtr(
            .init(.{ .value = 2 }, .init(0)),
        ).?;
        try schema.vectors.setCharacterPositions(&run.data.properties, &.{ 0, 10, 20, 30, 40, 50 });
        try schema.vectors.setCharacterWidths(&run.data.properties, &.{ 10, 10, 10, 10, 10, 10 });
        try schema.option.setBounds(&run.data.properties, schema.rectInit(0, 0, 60, 10));
        try schema.enums.setTextDirection(&run.data.properties, .left_to_right);
    }
    try std.testing.expectEqual(errors.ok(), value.vtable.GetBoundingRectangles(value, &boxes));
    var owned = util.ArrayOwner{ .api = &fixture.api, .raw = boxes };
    try std.testing.expectEqual(@as(u16, 5), fixture.abi.array(boxes.?).element_vt);
    try std.testing.expectEqualSlices(f64, &.{ -120, 47, 60, 10 },
        fixture.abi.array(boxes.?).doubles);
    try owned.deinit();
    boxes = null;
    fixture.abi.fail_array = true;
    try std.testing.expectEqual(errors.fromBits(0x8007000e),
        value.vtable.GetBoundingRectangles(value, &boxes));
    try std.testing.expect(boxes == null);
    fixture.abi.fail_array = false;
    fixture.abi.window_present = false;
    try std.testing.expectEqual(errors.elementNotAvailable(),
        value.vtable.GetBoundingRectangles(value, &boxes));
    try std.testing.expect(boxes == null);
}

test "UIA text COM enclosing element resolves current node and scroll chooses endpoint run" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    var node: ?*bindings.IRawElementProviderSimple = null;
    try std.testing.expectEqual(errors.ok(), value.vtable.GetEnclosingElement(value, &node));
    defer {
        const unknown: *bindings.IUnknown = @ptrCast(node.?);
        _ = unknown.vtable.Release(unknown);
    }
    var raw: bindings.Variant = std.mem.zeroes(bindings.Variant);
    try std.testing.expectEqual(errors.ok(), node.?.vtable.GetPropertyValue(
        node.?, .ControlTypePropertyId, &raw,
    ));
    var owned = util.VariantOwner{ .api = &fixture.api, .raw = raw };
    defer owned.deinit() catch @panic("Valid property must clear.");
    try std.testing.expectEqual(@as(u16, 3), util.variantType(&raw));
    try std.testing.expectEqual(@as(i32, 50004), raw.Anonymous.Anonymous.Anonymous.lVal);
    try std.testing.expectEqual(errors.ok(), value.vtable.ScrollIntoView(value, 1));
    try std.testing.expectEqual(schema.Action.scroll_into_view, fixture.last_action.?);
    try std.testing.expectEqual(schema.ScrollHint.top_edge, fixture.last_hint.?);
    try std.testing.expectEqual(@as(u64, 2), fixture.last_target.?.value);
    try std.testing.expect(fixture.action_reentered);
    try std.testing.expectEqual(errors.ok(), value.vtable.ScrollIntoView(value, 0));
    try std.testing.expectEqual(schema.ScrollHint.bottom_edge, fixture.last_hint.?);
    try std.testing.expectEqual(@as(u64, 2), fixture.last_target.?.value);
}

test "UIA text COM inherited attributes preserve uniform native value types" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const run = lease.owner.tree().?.state.nodes.getPtr(
            .init(.{ .value = 2 }, .init(0)),
        ).?;
        const props = &run.data.properties;
        try schema.strings.setFontFamily(props, "Fé\x00😀");
        try schema.numbers.setFontSize(props, 12.5);
        try schema.numbers.setFontWeight(props, 650.75);
        schema.flags.setItalic(&run.data.flags, true);
        const color: schema.Color = .{ .red = 1, .green = 2, .blue = 3, .alpha = 7 };
        try schema.colors.setBackgroundColor(props, color);
        try schema.colors.setForegroundColor(props, color);
        const decoration: schema.TextDecoration = .{ .style = .wavy, .color = color };
        try schema.colors.setOverline(props, decoration);
        try schema.colors.setStrikethrough(props, decoration);
        try schema.colors.setUnderline(props, decoration);
        try schema.enums.setTextAlign(props, .center);
        try schema.enums.setVerticalOffset(props, .superscript);
    }
    const value = try fixture.document();
    defer releaseRange(value);
    const cases = [_]struct { id: uia.UIA_TEXTATTRIBUTE_ID, tag: u16, integer: i32 }{
        .{ .id = .IsReadOnlyAttributeId, .tag = 11, .integer = 0 },
        .{ .id = .CaretPositionAttributeId, .tag = 3, .integer = 0 },
        .{ .id = .FontWeightAttributeId, .tag = 3, .integer = 650 },
        .{ .id = .IsItalicAttributeId, .tag = 11, .integer = -1 },
        .{ .id = .BackgroundColorAttributeId, .tag = 3, .integer = 0x030201 },
        .{ .id = .ForegroundColorAttributeId, .tag = 3, .integer = 0x030201 },
        .{ .id = .OverlineStyleAttributeId, .tag = 3, .integer = 8 },
        .{ .id = .StrikethroughStyleAttributeId, .tag = 3, .integer = 8 },
        .{ .id = .UnderlineStyleAttributeId, .tag = 3, .integer = 8 },
        .{ .id = .OverlineColorAttributeId, .tag = 3, .integer = 0x030201 },
        .{ .id = .StrikethroughColorAttributeId, .tag = 3, .integer = 0x030201 },
        .{ .id = .UnderlineColorAttributeId, .tag = 3, .integer = 0x030201 },
        .{ .id = .HorizontalTextAlignmentAttributeId, .tag = 3, .integer = 1 },
        .{ .id = .IsSubscriptAttributeId, .tag = 11, .integer = 0 },
        .{ .id = .IsSuperscriptAttributeId, .tag = 11, .integer = -1 },
    };
    for (cases) |case| {
        var raw: bindings.Variant = std.mem.zeroes(bindings.Variant);
        try std.testing.expectEqual(errors.ok(), value.vtable.GetAttributeValue(value, case.id, &raw));
        var owned = util.VariantOwner{ .api = &fixture.api, .raw = raw };
        defer owned.deinit() catch @panic("Valid attribute must clear.");
        try std.testing.expectEqual(case.tag, util.variantType(&raw));
        if (case.tag == 11) {
            try std.testing.expectEqual(@as(i16, @intCast(case.integer)),
                raw.Anonymous.Anonymous.Anonymous.boolVal);
        } else {
            try std.testing.expectEqual(case.integer, raw.Anonymous.Anonymous.Anonymous.lVal);
        }
    }
    var raw: bindings.Variant = std.mem.zeroes(bindings.Variant);
    try std.testing.expectEqual(errors.ok(),
        value.vtable.GetAttributeValue(value, .FontSizeAttributeId, &raw));
    var size = util.VariantOwner{ .api = &fixture.api, .raw = raw };
    defer size.deinit() catch @panic("Valid size must clear.");
    try std.testing.expectEqual(@as(u16, 5), util.variantType(&raw));
    try std.testing.expectEqual(@as(f64, 12.5), raw.Anonymous.Anonymous.Anonymous.dblVal);
    try std.testing.expectEqual(errors.ok(),
        value.vtable.GetAttributeValue(value, .FontNameAttributeId, &raw));
    var font = util.VariantOwner{ .api = &fixture.api, .raw = raw };
    defer font.deinit() catch @panic("Valid font must clear.");
    try std.testing.expectEqual(@as(u16, 8), util.variantType(&raw));
    try std.testing.expectEqualSlices(u16, &.{ 'F', 0xe9, 0, 0xd83d, 0xde00 },
        fixture.abi.stringUnits(raw.Anonymous.Anonymous.Anonymous.bstrVal.?));
}

test "UIA text COM failed construction leaves both weak inputs owned by caller" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    var weak = fixture.owner.?.context.weak();
    defer weak.deinit();
    var lease = try weak.lease();
    defer lease.deinit();
    const node = lease.state().nodeById(.init(.{ .value = 1 }, .init(0))).?;
    var range = try ranges.downgrade(std.testing.allocator,
        try query.documentRange(std.testing.allocator, node));
    defer range.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, create(failing.allocator(), weak, range));
    const live = (try query.upgrade(range, lease.state())).?;
    var text = try ranges.text(std.testing.allocator, live);
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("Aé\x00😀 Z", text.items);
}

test "UIA text COM mixed language owns reserved reference and uniform culture converts locale" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const state = &lease.owner.tree().?.state;
        const run = state.nodes.getPtr(.init(.{ .value = 2 }, .init(0))).?;
        try schema.strings.setLanguage(&run.data.properties, "en-US");
    }
    const value = try fixture.document();
    defer releaseRange(value);
    var raw: bindings.Variant = std.mem.zeroes(bindings.Variant);
    try std.testing.expectEqual(errors.ok(),
        value.vtable.GetAttributeValue(value, .CultureAttributeId, &raw));
    var locale = util.VariantOwner{ .api = &fixture.api, .raw = raw };
    try std.testing.expectEqual(@as(u16, 3), util.variantType(&raw));
    try std.testing.expectEqual(@as(i32, 1033), raw.Anonymous.Anonymous.Anonymous.lVal);
    try locale.deinit();
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const state = &lease.owner.tree().?.state;
        const run = blk: {
            var node = schema.Node.init(std.testing.allocator, .text_run);
            errdefer node.deinit();
            try schema.strings.setValue(&node.properties, "B");
            try schema.vectors.setCharacterLengths(&node.properties, &.{1});
            try schema.strings.setLanguage(&node.properties, "fr-FR");
            break :blk node;
        };
        state.nodes.put(std.testing.allocator, .init(.{ .value = 3 }, .init(0)), .{
            .parent_and_index = .{ .parent_id = .init(.{ .value = 1 }, .init(0)), .index = 1 },
            .data = run,
        }) catch |err| {
            var owned = run;
            owned.deinit();
            return err;
        };
        const root = state.nodes.getPtr(.init(.{ .value = 1 }, .init(0))).?;
        try schema.ids_props.setChildren(&root.data.properties,
            &.{ .{ .value = 2 }, .{ .value = 3 } });
    }
    try std.testing.expectEqual(errors.ok(), value.vtable.ExpandToEnclosingUnit(value, .Document));
    fixture.abi.reserved_object = @ptrCast(value);
    try std.testing.expectEqual(errors.ok(),
        value.vtable.GetAttributeValue(value, .CultureAttributeId, &raw));
    var mixed = util.VariantOwner{ .api = &fixture.api, .raw = raw };
    try std.testing.expectEqual(@as(u16, 13), util.variantType(&raw));
    try mixed.deinit();
}

test "UIA text COM required output pointers fail without mutating range" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    const value = try fixture.document();
    defer releaseRange(value);
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.Clone(value, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.Compare(value, value, null));
    try std.testing.expectEqual(errors.invalidArg(),
        value.vtable.CompareEndpoints(value, .Start, value, .End, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.FindAttribute(
        value, .FontSizeAttributeId, std.mem.zeroes(bindings.Variant), 0, null,
    ));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.FindText(value, null, 0, 0, null));
    try std.testing.expectEqual(errors.invalidArg(),
        value.vtable.GetAttributeValue(value, .FontSizeAttributeId, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetBoundingRectangles(value, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetEnclosingElement(value, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetText(value, -1, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.Move(value, .Character, 1, null));
    try std.testing.expectEqual(errors.invalidArg(),
        value.vtable.MoveEndpointByUnit(value, .Start, .Character, 1, null));
    try std.testing.expectEqual(errors.invalidArg(), value.vtable.GetChildren(value, null));
    try expectText(&fixture, value, -1, &.{ 'A', 0xe9, 0, 0xd83d, 0xde00, ' ', 'Z' });
}

test "UIA text COM finite UTF16 limits on Aé😀B preserve complete scalars" {
    if (comptime !bindings.winapi_resolves) return error.SkipZigTest;
    var fixture: TestFixture = .{};
    try fixture.init();
    defer fixture.deinit();
    {
        var lease = try fixture.owner.?.context.enter();
        defer lease.deinit();
        const run = lease.owner.tree().?.state.nodes.getPtr(
            .init(.{ .value = 2 }, .init(0)),
        ).?;
        try schema.strings.setValue(&run.data.properties, "Aé😀B");
        try schema.vectors.setCharacterLengths(&run.data.properties, &.{ 1, 2, 4, 1 });
    }
    const value = try fixture.document();
    defer releaseRange(value);
    try expectText(&fixture, value, 0, &.{});
    try expectText(&fixture, value, 1, &.{'A'});
    try expectText(&fixture, value, 2, &.{ 'A', 0xe9 });
    try expectText(&fixture, value, 3, &.{ 'A', 0xe9 });
    try expectText(&fixture, value, 4, &.{ 'A', 0xe9, 0xd83d, 0xde00 });
    try expectText(&fixture, value, 100, &.{ 'A', 0xe9, 0xd83d, 0xde00, 'B' });
    try expectText(&fixture, value, -1, &.{ 'A', 0xe9, 0xd83d, 0xde00, 'B' });
}
