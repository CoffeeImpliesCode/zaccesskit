//! Allocation-explicit D-Bus 1.0 framing and recursive value codec.
//! Source contract: https://dbus.freedesktop.org/doc/dbus-specification.html,
//! version 0.43, Type System, Marshaling (Wire Format), and Message Format.
//! OwnedBody/OwnedFrame require exactly-once disposal and a live backing allocator.
//! No runtime, I/O, Rust dependency, or Unix descriptor passing is used.

const std = @import("std");
const signatures = @import("dbus_signature.zig");

const default_limits: Limits = .{};
const protocol_frame_bytes_max = 128 * 1024 * 1024;
const protocol_array_bytes_max = 64 * 1024 * 1024;
const protocol_depth_max = 64;

/// Pure D-Bus 1.0 codec. Unix descriptor passing is never negotiated.
pub const CodecError = error{
    OutOfMemory,
    Truncated,
    InvalidEndian,
    InvalidMessageType,
    InvalidProtocolVersion,
    InvalidSerial,
    InvalidHeader,
    MissingHeader,
    DuplicateHeader,
    InvalidPadding,
    InvalidSignature,
    SignatureMismatch,
    InvalidBoolean,
    InvalidString,
    InvalidObjectPath,
    InvalidLength,
    TrailingBytes,
    LimitExceeded,
    UnsupportedUnixFd,
};

/// Bounds apply to headers and bodies together. Depth includes runtime variants.
/// Defaults: 16 MiB frame, 8 MiB arrays/strings, 64 container levels, 65536 values.
/// Raised caller limits never exceed protocol ceilings: 128 MiB frame,
/// 64 MiB array, 64 total containers, 32 arrays and 32 struct/dict levels.
/// Value count includes known and unknown header values. Strings must be UTF-8.
pub const Limits = struct {
    max_frame_bytes: usize = 16 * 1024 * 1024,
    max_array_bytes: usize = 8 * 1024 * 1024,
    max_string_bytes: usize = 8 * 1024 * 1024,
    max_depth: usize = 64,
    max_values: usize = 65536,
};

pub const Kind = enum(u8) {
    method_call = 1,
    method_return = 2,
    error_reply = 3,
    signal = 4,
};
pub const Array = struct { element_signature: []const u8, values: []const Value };
pub const Variant = struct { signature: []const u8, value: Value };
pub const Value = union(enum) {
    byte: u8,
    boolean: bool,
    int16: i16,
    uint16: u16,
    int32: i32,
    uint32: u32,
    int64: i64,
    uint64: u64,
    double: f64,
    unix_fd: u32,
    string: []const u8,
    object_path: []const u8,
    signature: []const u8,
    array: Array,
    structure: []const Value,
    variant: *const Variant,
    dict_entry: []const Value,
};
pub const Message = struct {
    kind: Kind,
    flags: u8 = 0,
    serial: u32 = 0,
    reply_serial: ?u32 = null,
    path: ?[]const u8 = null,
    interface: ?[]const u8 = null,
    member: ?[]const u8 = null,
    error_name: ?[]const u8 = null,
    destination: ?[]const u8 = null,
    sender: ?[]const u8 = null,
    signature: []const u8 = "",
    body: []const Value = &.{},
};
pub const ObjectReference = struct { bus_name: []const u8, path: []const u8 };

/// Owns all recursive values and signatures; dispose exactly once.
pub const OwnedBody = struct {
    arena: *std.heap.ArenaAllocator,
    signature: []const u8,
    values: []const Value,

    pub fn init(gpa: std.mem.Allocator, signature: []const u8, values: []const Value) CodecError!OwnedBody {
        try validateBody(signature, values);
        const arena = try newArena(gpa);
        errdefer destroyArena(arena);
        var budget: Budget = .{ .limits = .{} };
        const owned = try cloneValues(arena.allocator(), values, &budget, 0);
        return .{ .arena = arena, .signature = try arena.allocator().dupe(u8, signature), .values = owned };
    }

    pub fn deinit(self: *OwnedBody) void {
        destroyArena(self.arena);
        self.* = undefined;
    }
};
pub const OwnedReply = struct {
    body: OwnedBody,
    error_name: ?[]const u8 = null,

    pub fn deinit(self: *OwnedReply) void {
        self.body.deinit();
        self.* = undefined;
    }
};
/// Owns a raw frame copy and every decoded node. Message slices borrow this owner.
pub const OwnedFrame = struct {
    arena: *std.heap.ArenaAllocator,
    bytes: []const u8,
    message: Message,

    pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) CodecError!OwnedFrame {
        return decodeFrame(gpa, bytes, limits);
    }

    pub fn deinit(self: *OwnedFrame) void {
        destroyArena(self.arena);
        self.* = undefined;
    }
};

fn newArena(gpa: std.mem.Allocator) CodecError!*std.heap.ArenaAllocator {
    const arena = try gpa.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(gpa);
    return arena;
}

fn destroyArena(arena: *std.heap.ArenaAllocator) void {
    const gpa = arena.child_allocator;
    arena.deinit();
    gpa.destroy(arena);
}

const Budget = struct {
    limits: Limits,
    values: usize = 0,
    text_bytes: usize = 0,

    fn enter(self: *Budget, depth: usize) CodecError!void {
        if (depth > @min(self.limits.max_depth, protocol_depth_max))
            return error.LimitExceeded;
        if (self.values >= self.limits.max_values) return error.LimitExceeded;
        self.values += 1;
    }
};

/// Deep copy into the caller's arena, using default depth/value/string bounds.
/// The caller releases allocations in bulk; on failure no partial value escapes.
pub fn cloneValue(arena: std.mem.Allocator, value: Value) CodecError!Value {
    var budget: Budget = .{ .limits = .{} };
    return cloneOne(arena, value, &budget, 0);
}

/// Checks a complete body without allocating, using the default codec bounds.
pub fn validateBody(signature: []const u8, values: []const Value) CodecError!void {
    const byte_count = try measureBody(signature, values, default_limits);
    std.debug.assert(byte_count <= default_limits.max_frame_bytes);
}

/// Validates and measures the actual aligned body bytes without allocating.
/// Bodies start on an eight-byte frame boundary, so body-relative offset zero
/// preserves wire alignment. This excludes header bytes and header value counts.
/// All supplied length/depth/value bounds and hard protocol ceilings apply.
pub fn measureBody(signature: []const u8, values: []const Value, limits: Limits) CodecError!usize {
    try signatures.validate(signature, limits.max_depth);
    var counter: Encoder = .{ .gpa = undefined, .limits = limits, .endian = .little, .count_only = true };
    try counter.sequence(signature, values, 0);
    return counter.position;
}

/// Validates and measures a complete frame without allocation. Header and body
/// share the same value budget as encode/decode; no conservative reservation.
/// Supply exact reply/destination/error fields and any nonzero serial placeholder.
pub fn measureMessage(message: Message, limits: Limits) CodecError!usize {
    var counter: Encoder = .{ .gpa = undefined, .limits = limits, .endian = .little, .count_only = true };
    try encodeFrame(&counter, message);
    return counter.position;
}

/// Returns the next complete type, advancing position only on success.
/// End-of-signature is null; an out-of-range position is invalid.
pub fn signatureNext(signature: []const u8, position: *usize) CodecError!?[]const u8 {
    if (position.* > signature.len) return error.InvalidSignature;
    if (position.* == signature.len) {
        try signatures.validate(signature, default_limits.max_depth);
        return null;
    }
    const end = try signatures.typeEnd(signature, position.*, default_limits.max_depth);
    const next = signature[position.*..end];
    position.* = end;
    return next;
}

fn containerDepth(code: u8, depth: usize, limits: Limits) CodecError!void {
    if (std.mem.indexOfScalar(u8, "a({v", code) != null and
        depth >= @min(limits.max_depth, protocol_depth_max)) return error.LimitExceeded;
}

fn supportedSignature(signature: []const u8) CodecError!void {
    if (std.mem.indexOfScalar(u8, signature, 'h') != null) return error.UnsupportedUnixFd;
}

fn cloneValues(arena: std.mem.Allocator, values: []const Value, budget: *Budget, depth: usize) CodecError![]const Value {
    if (values.len > budget.limits.max_values - budget.values) return error.LimitExceeded;
    const owned = try arena.alloc(Value, values.len);
    for (values, owned) |value, *target| target.* = try cloneOne(arena, value, budget, depth);
    return owned;
}

fn cloneText(arena: std.mem.Allocator, text: []const u8, budget: *Budget) CodecError![]const u8 {
    if (text.len > budget.limits.max_string_bytes) return error.LimitExceeded;
    if (text.len > budget.limits.max_frame_bytes - budget.text_bytes)
        return error.LimitExceeded;
    budget.text_bytes += text.len;
    return arena.dupe(u8, text);
}

fn cloneOne(arena: std.mem.Allocator, value: Value, budget: *Budget, depth: usize) CodecError!Value {
    try budget.enter(depth);
    const container_code: u8 = switch (value) {
        .array => 'a',
        .structure => '(',
        .dict_entry => '{',
        .variant => 'v',
        else => 'y',
    };
    try containerDepth(container_code, depth, budget.limits);
    return switch (value) {
        .unix_fd => error.UnsupportedUnixFd,
        .string => |text| .{ .string = try cloneText(arena, text, budget) },
        .object_path => |text| .{ .object_path = try cloneText(arena, text, budget) },
        .signature => |text| .{ .signature = try cloneText(arena, text, budget) },
        .structure => |values| .{ .structure = try cloneValues(arena, values, budget, depth + 1) },
        .dict_entry => |values| blk: {
            if (values.len != 2) return error.SignatureMismatch;
            break :blk .{ .dict_entry = try cloneValues(arena, values, budget, depth + 1) };
        },
        .array => |array| .{ .array = .{
            .element_signature = try cloneText(arena, array.element_signature, budget),
            .values = try cloneValues(arena, array.values, budget, depth + 1),
        } },
        .variant => |variant| blk: {
            const owned = try arena.create(Variant);
            owned.* = .{ .signature = try cloneText(arena, variant.signature, budget), .value = try cloneOne(arena, variant.value, budget, depth + 1) };
            break :blk .{ .variant = owned };
        },
        else => value,
    };
}

fn byteOrder(byte: u8) CodecError!std.builtin.Endian {
    return switch (byte) {
        'l' => .little,
        'B' => .big,
        else => error.InvalidEndian,
    };
}

fn readInteger(comptime T: type, bytes: []const u8, endian: std.builtin.Endian) T {
    return std.mem.readInt(T, @as(*const [@sizeOf(T)]u8, @ptrCast(bytes.ptr)), endian);
}

fn aligned(position: usize, alignment: usize) CodecError!usize {
    const rounded = std.math.add(usize, position, alignment - 1) catch return error.InvalidLength;
    return rounded & ~(alignment - 1);
}

/// Validates the fixed header before a transport reserves a frame buffer.
/// Unknown flag bits are retained, as required by the protocol.
pub fn frameLength(header: [16]u8, limits: Limits) CodecError!usize {
    const endian = try byteOrder(header[0]);
    if (header[1] < 1 or header[1] > 4) return error.InvalidMessageType;
    if (header[3] != 1) return error.InvalidProtocolVersion;
    if (readInteger(u32, header[8..12], endian) == 0) return error.InvalidSerial;
    const body_len: usize = readInteger(u32, header[4..8], endian);
    const fields_len: usize = readInteger(u32, header[12..16], endian);
    if (fields_len > @min(limits.max_array_bytes, protocol_array_bytes_max))
        return error.LimitExceeded;
    const header_end = std.math.add(usize, 16, fields_len) catch return error.InvalidLength;
    const body_start = try aligned(header_end, 8);
    const total = std.math.add(usize, body_start, body_len) catch return error.InvalidLength;
    if (total > @min(limits.max_frame_bytes, protocol_frame_bytes_max))
        return error.LimitExceeded;
    return total;
}

pub fn decode(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) CodecError!OwnedFrame {
    return decodeFrame(gpa, bytes, limits);
}

fn decodeFrame(gpa: std.mem.Allocator, bytes: []const u8, limits: Limits) CodecError!OwnedFrame {
    try validateFrameBytes(bytes, limits);
    const arena = try newArena(gpa);
    errdefer destroyArena(arena);
    const raw = try arena.allocator().dupe(u8, bytes);
    return parseFrame(arena, raw, limits);
}

/// Parses bytes already allocated in this heap-allocated arena without copying.
/// On success ownership of arena transfers to the returned frame. On error the
/// caller retains arena and must dispose it, including partially allocated nodes.
/// Precondition: bytes belong to arena. The arena pointer must come from
/// arena.child_allocator.create(std.heap.ArenaAllocator), never stack storage.
pub fn decodeInArena(arena: *std.heap.ArenaAllocator, bytes: []const u8, limits: Limits) CodecError!OwnedFrame {
    try validateFrameBytes(bytes, limits);
    return parseFrame(arena, bytes, limits);
}

fn validateFrameBytes(bytes: []const u8, limits: Limits) CodecError!void {
    if (bytes.len < 16) return error.Truncated;
    const length = try frameLength(bytes[0..16].*, limits);
    if (bytes.len < length) return error.Truncated;
    if (bytes.len != length) return error.TrailingBytes;
}

fn parseFrame(arena: *std.heap.ArenaAllocator, raw: []const u8, limits: Limits) CodecError!OwnedFrame {
    const endian = try byteOrder(raw[0]);
    const fields_end = 16 + @as(usize, readInteger(u32, raw[12..16], endian));
    var reader: Decoder = .{ .arena = arena.allocator(), .bytes = raw, .endian = endian, .position = 16, .end = fields_end, .budget = .{ .limits = limits } };
    var message: Message = .{ .kind = @enumFromInt(raw[1]), .flags = raw[2], .serial = readInteger(u32, raw[8..12], endian) };
    var seen = [_]bool{false} ** 256;
    while (reader.position < fields_end) {
        try reader.pad(8);
        const code = (try reader.take(1))[0];
        if (code == 0) return error.InvalidHeader;
        if (seen[code]) return error.DuplicateHeader;
        seen[code] = true;
        const value = try reader.value("v", 0);
        try applyHeader(&message, code, value.variant.*);
    }
    reader.end = raw.len;
    try reader.pad(8);
    try validateMessage(message);
    try signatures.validate(message.signature, limits.max_depth);
    message.body = try reader.sequence(message.signature, 0);
    if (reader.position != raw.len) return error.TrailingBytes;
    return .{ .arena = arena, .bytes = raw, .message = message };
}

const Decoder = struct {
    arena: std.mem.Allocator,
    bytes: []const u8,
    endian: std.builtin.Endian,
    position: usize,
    end: usize,
    budget: Budget,

    fn take(self: *Decoder, length: usize) CodecError![]const u8 {
        if (length > self.end - self.position) return error.Truncated;
        const start = self.position;
        self.position += length;
        return self.bytes[start..self.position];
    }

    fn pad(self: *Decoder, alignment: usize) CodecError!void {
        const next = try aligned(self.position, alignment);
        const padding = try self.take(next - self.position);
        for (padding) |byte| if (byte != 0) return error.InvalidPadding;
    }

    fn integer(self: *Decoder, comptime T: type) CodecError!T {
        return readInteger(T, try self.take(@sizeOf(T)), self.endian);
    }

    fn text(self: *Decoder, code: u8) CodecError![]const u8 {
        const length: usize = if (code == 'g') try self.integer(u8) else try self.integer(u32);
        if (length > self.budget.limits.max_string_bytes) return error.LimitExceeded;
        const result = try self.take(length);
        if ((try self.take(1))[0] != 0) return error.InvalidString;
        try validateText(code, result, self.budget.limits.max_depth);
        return result;
    }

    fn sequence(self: *Decoder, signature: []const u8, depth: usize) CodecError![]const Value {
        var values: std.ArrayList(Value) = .empty;
        var offset: usize = 0;
        while (offset < signature.len) {
            const end = try signatures.typeEnd(signature, offset, self.budget.limits.max_depth);
            try values.append(self.arena, try self.value(signature[offset..end], depth));
            offset = end;
        }
        return values.toOwnedSlice(self.arena);
    }

    fn value(self: *Decoder, signature: []const u8, depth: usize) CodecError!Value {
        try self.budget.enter(depth);
        const code = signature[0];
        try supportedSignature(signature);
        try containerDepth(code, depth, self.budget.limits);
        try self.pad(try signatures.alignment(code));
        return switch (code) {
            'y' => .{ .byte = try self.integer(u8) },
            'b' => blk: {
                const number = try self.integer(u32);
                if (number > 1) return error.InvalidBoolean;
                break :blk .{ .boolean = number == 1 };
            },
            'n' => .{ .int16 = try self.integer(i16) },
            'q' => .{ .uint16 = try self.integer(u16) },
            'i' => .{ .int32 = try self.integer(i32) },
            'u' => .{ .uint32 = try self.integer(u32) },
            'x' => .{ .int64 = try self.integer(i64) },
            't' => .{ .uint64 = try self.integer(u64) },
            'd' => .{ .double = @bitCast(try self.integer(u64)) },
            's' => .{ .string = try self.text(code) },
            'o' => .{ .object_path = try self.text(code) },
            'g' => .{ .signature = try self.text(code) },
            'v' => blk: {
                const inner_signature = try self.text('g');
                try signatures.single(inner_signature, self.budget.limits.max_depth);
                const variant = try self.arena.create(Variant);
                variant.* = .{ .signature = inner_signature, .value = try self.value(inner_signature, depth + 1) };
                break :blk .{ .variant = variant };
            },
            'a' => try self.array(signature[1..], depth + 1),
            '(', '{' => blk: {
                const members = signature[1 .. signature.len - 1];
                const values = try self.sequence(members, depth + 1);
                break :blk if (code == '(') .{ .structure = values } else .{ .dict_entry = values };
            },
            else => error.InvalidSignature,
        };
    }

    fn array(self: *Decoder, element_signature: []const u8, depth: usize) CodecError!Value {
        const length: usize = try self.integer(u32);
        if (length > @min(self.budget.limits.max_array_bytes, protocol_array_bytes_max))
            return error.LimitExceeded;
        try self.pad(try signatures.alignment(element_signature[0]));
        if (length > self.end - self.position) return error.Truncated;
        const old_end = self.end;
        self.end = self.position + length;
        defer self.end = old_end;
        var values: std.ArrayList(Value) = .empty;
        while (self.position < self.end) {
            try values.append(self.arena, try self.value(element_signature, depth));
        }
        return .{ .array = .{ .element_signature = element_signature, .values = try values.toOwnedSlice(self.arena) } };
    }
};

fn validateText(code: u8, text: []const u8, max_depth: usize) CodecError!void {
    if (code == 'g') return signatures.validate(text, max_depth);
    if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidString;
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidString;
    if (code == 'o' and !validPath(text)) return error.InvalidObjectPath;
}

fn validPath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    if (path.len == 1) return true;
    if (path[path.len - 1] == '/') return false;
    var previous_slash = true;
    for (path[1..]) |byte| {
        if (byte == '/') {
            if (previous_slash) return false;
            previous_slash = true;
        } else {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_') return false;
            previous_slash = false;
        }
    }
    return true;
}

fn validName(name: []const u8, dotted: bool, bus: bool) bool {
    if (name.len == 0 or name.len > 255) return false;
    const unique = bus and name[0] == ':';
    const start: usize = if (unique) 1 else 0;
    var component_start = true;
    var dots: usize = 0;
    for (name[start..]) |byte| {
        if (byte == '.') {
            if (!dotted or component_start) return false;
            component_start = true;
            dots += 1;
        } else {
            if (!std.ascii.isAlphanumeric(byte) and byte != '_' and
                !(bus and byte == '-')) return false;
            if (component_start and std.ascii.isDigit(byte) and !unique) return false;
            component_start = false;
        }
    }
    return !component_start and (!dotted or dots != 0);
}

fn validateMessage(message: Message) CodecError!void {
    if (message.serial == 0) return error.InvalidSerial;
    if (message.reply_serial) |serial| if (serial == 0) return error.InvalidSerial;
    if (message.path) |path| if (!validPath(path)) return error.InvalidObjectPath;
    if (message.interface) |name| if (!validName(name, true, false)) return error.InvalidHeader;
    if (message.member) |name| if (!validName(name, false, false)) return error.InvalidHeader;
    if (message.error_name) |name| if (!validName(name, true, false)) return error.InvalidHeader;
    if (message.destination) |name| if (!validName(name, true, true)) return error.InvalidHeader;
    if (message.sender) |name| {
        if (!validName(name, true, true)) return error.InvalidHeader;
        // zbus_names 4.3.4 accepts the bus driver identity as well as colon-prefixed peers.
        // https://docs.rs/crate/zbus_names/4.3.4/source/src/unique_name.rs#L31-L39
        if (name[0] != ':' and !std.mem.eql(u8, name, "org.freedesktop.DBus"))
            return error.InvalidHeader;
    }
    switch (message.kind) {
        .method_call => if (message.path == null or message.member == null)
            return error.MissingHeader,
        .method_return => if (message.reply_serial == null) return error.MissingHeader,
        .error_reply => if (message.error_name == null or message.reply_serial == null)
            return error.MissingHeader,
        .signal => if (message.path == null or message.interface == null or
            message.member == null) return error.MissingHeader,
    }
}

fn applyHeader(message: *Message, code: u8, variant: Variant) CodecError!void {
    const expected: ?u8 = switch (code) {
        1 => 'o',
        2, 3, 4, 6, 7 => 's',
        5, 9 => 'u',
        8 => 'g',
        else => null,
    };
    if (expected) |character| {
        if (variant.signature.len != 1 or variant.signature[0] != character)
            return error.InvalidHeader;
    }
    switch (code) {
        1 => message.path = variant.value.object_path,
        2 => message.interface = variant.value.string,
        3 => message.member = variant.value.string,
        4 => message.error_name = variant.value.string,
        5 => message.reply_serial = variant.value.uint32,
        6 => message.destination = variant.value.string,
        7 => message.sender = variant.value.string,
        8 => message.signature = variant.value.signature,
        9 => if (variant.value.uint32 != 0) return error.UnsupportedUnixFd,
        else => {},
    }
}

/// Returns an exact-size, caller-owned frame. Every value is checked against its signature.
pub fn encode(gpa: std.mem.Allocator, message: Message, endian: std.builtin.Endian, limits: Limits) CodecError![]u8 {
    var writer: Encoder = .{ .gpa = gpa, .endian = endian, .limits = limits };
    errdefer writer.bytes.deinit(gpa);
    try encodeFrame(&writer, message);
    return writer.bytes.toOwnedSlice(gpa);
}

fn encodeFrame(writer: *Encoder, message: Message) CodecError!void {
    try validateMessage(message);
    try signatures.validate(message.signature, writer.limits.max_depth);
    try writer.zeros(16);
    if (message.path) |text| try writer.header(1, "o", .{ .object_path = text });
    if (message.interface) |text| try writer.header(2, "s", .{ .string = text });
    if (message.member) |text| try writer.header(3, "s", .{ .string = text });
    if (message.error_name) |text| try writer.header(4, "s", .{ .string = text });
    if (message.reply_serial) |serial| try writer.header(5, "u", .{ .uint32 = serial });
    if (message.destination) |text| try writer.header(6, "s", .{ .string = text });
    if (message.sender) |text| try writer.header(7, "s", .{ .string = text });
    if (message.signature.len != 0)
        try writer.header(8, "g", .{ .signature = message.signature });
    const fields_len = writer.position - 16;
    if (fields_len > @min(writer.limits.max_array_bytes, protocol_array_bytes_max))
        return error.LimitExceeded;
    try writer.pad(8);
    const body_start = writer.position;
    try writer.sequence(message.signature, message.body, 0);
    const body_len = writer.position - body_start;
    if (fields_len > std.math.maxInt(u32) or body_len > std.math.maxInt(u32))
        return error.InvalidLength;
    if (!writer.count_only) {
        writer.bytes.items[0] = if (writer.endian == .little) 'l' else 'B';
        writer.bytes.items[1] = @intFromEnum(message.kind);
        writer.bytes.items[2] = message.flags;
        writer.bytes.items[3] = 1;
    }
    writer.patchU32(4, @intCast(body_len));
    writer.patchU32(8, message.serial);
    writer.patchU32(12, @intCast(fields_len));
}

const Encoder = struct {
    gpa: std.mem.Allocator,
    endian: std.builtin.Endian,
    limits: Limits,
    bytes: std.ArrayList(u8) = .empty,
    position: usize = 0,
    values: usize = 0,
    count_only: bool = false,

    fn reserve(self: *Encoder, length: usize) CodecError!usize {
        const frame_limit = @min(self.limits.max_frame_bytes, protocol_frame_bytes_max);
        if (self.position > frame_limit or length > frame_limit - self.position)
            return error.LimitExceeded;
        const start = self.position;
        self.position += length;
        if (!self.count_only) try self.bytes.resize(self.gpa, self.position);
        return start;
    }

    fn zeros(self: *Encoder, length: usize) CodecError!void {
        const start = try self.reserve(length);
        if (!self.count_only) @memset(self.bytes.items[start..self.position], 0);
    }

    fn pad(self: *Encoder, alignment: usize) CodecError!void {
        try self.zeros((try aligned(self.position, alignment)) - self.position);
    }

    fn integer(self: *Encoder, comptime T: type, number: T) CodecError!void {
        const start = try self.reserve(@sizeOf(T));
        if (!self.count_only) std.mem.writeInt(T, @as(*[@sizeOf(T)]u8, @ptrCast(self.bytes.items[start..].ptr)), number, self.endian);
    }

    fn patchU32(self: *Encoder, position: usize, number: u32) void {
        if (!self.count_only) std.mem.writeInt(u32, @as(*[4]u8, @ptrCast(self.bytes.items[position..].ptr)), number, self.endian);
    }

    fn text(self: *Encoder, code: u8, text_value: []const u8) CodecError!void {
        try validateText(code, text_value, self.limits.max_depth);
        if (text_value.len > self.limits.max_string_bytes) return error.LimitExceeded;
        if (code == 'g') {
            if (text_value.len > 255) return error.InvalidSignature;
            try self.integer(u8, @intCast(text_value.len));
        } else {
            if (text_value.len > std.math.maxInt(u32)) return error.InvalidLength;
            try self.integer(u32, @intCast(text_value.len));
        }
        const start = try self.reserve(text_value.len);
        if (!self.count_only) @memcpy(self.bytes.items[start..self.position], text_value);
        try self.integer(u8, 0);
    }

    fn header(self: *Encoder, code: u8, signature: []const u8, header_value: Value) CodecError!void {
        try self.pad(8);
        try self.integer(u8, code);
        const variant: Variant = .{ .signature = signature, .value = header_value };
        try self.value("v", .{ .variant = &variant }, 0);
    }

    fn sequence(self: *Encoder, signature: []const u8, values: []const Value, depth: usize) CodecError!void {
        var offset: usize = 0;
        var index: usize = 0;
        while (offset < signature.len) {
            if (index >= values.len) return error.SignatureMismatch;
            const end = try signatures.typeEnd(signature, offset, self.limits.max_depth);
            try self.value(signature[offset..end], values[index], depth);
            offset = end;
            index += 1;
        }
        if (index != values.len) return error.SignatureMismatch;
    }

    fn value(self: *Encoder, signature: []const u8, item: Value, depth: usize) CodecError!void {
        if (depth > @min(self.limits.max_depth, protocol_depth_max) or
            self.values >= self.limits.max_values) return error.LimitExceeded;
        self.values += 1;
        const code = signature[0];
        try supportedSignature(signature);
        if (item == .unix_fd) return error.UnsupportedUnixFd;
        try containerDepth(code, depth, self.limits);
        try self.pad(try signatures.alignment(code));
        switch (item) {
            .byte => |number| {
                if (code != 'y') return error.SignatureMismatch;
                try self.integer(u8, number);
            },
            .boolean => |boolean| {
                if (code != 'b') return error.SignatureMismatch;
                try self.integer(u32, @intFromBool(boolean));
            },
            .int16 => |number| {
                if (code != 'n') return error.SignatureMismatch;
                try self.integer(i16, number);
            },
            .uint16 => |number| {
                if (code != 'q') return error.SignatureMismatch;
                try self.integer(u16, number);
            },
            .int32 => |number| {
                if (code != 'i') return error.SignatureMismatch;
                try self.integer(i32, number);
            },
            .uint32 => |number| {
                if (code != 'u') return error.SignatureMismatch;
                try self.integer(u32, number);
            },
            .int64 => |number| {
                if (code != 'x') return error.SignatureMismatch;
                try self.integer(i64, number);
            },
            .uint64 => |number| {
                if (code != 't') return error.SignatureMismatch;
                try self.integer(u64, number);
            },
            .double => |number| {
                if (code != 'd') return error.SignatureMismatch;
                try self.integer(u64, @bitCast(number));
            },
            .string => |text_value| {
                if (code != 's') return error.SignatureMismatch;
                try self.text('s', text_value);
            },
            .object_path => |text_value| {
                if (code != 'o') return error.SignatureMismatch;
                try self.text('o', text_value);
            },
            .signature => |text_value| {
                if (code != 'g') return error.SignatureMismatch;
                try self.text('g', text_value);
            },
            .structure => |members| {
                if (code != '(') return error.SignatureMismatch;
                try self.sequence(signature[1 .. signature.len - 1], members, depth + 1);
            },
            .dict_entry => |members| {
                if (code != '{' or members.len != 2) return error.SignatureMismatch;
                try self.sequence(signature[1 .. signature.len - 1], members, depth + 1);
            },
            .array => |array_value| {
                if (code != 'a') return error.SignatureMismatch;
                if (!std.mem.eql(u8, signature[1..], array_value.element_signature))
                    return error.SignatureMismatch;
                const length_position = self.position;
                try self.integer(u32, 0);
                try self.pad(try signatures.alignment(signature[1]));
                const start = self.position;
                if (array_value.values.len > self.limits.max_values - self.values)
                    return error.LimitExceeded;
                for (array_value.values) |child|
                    try self.value(signature[1..], child, depth + 1);
                const length = self.position - start;
                if (length > @min(self.limits.max_array_bytes, protocol_array_bytes_max))
                    return error.LimitExceeded;
                if (length > std.math.maxInt(u32)) return error.InvalidLength;
                self.patchU32(length_position, @intCast(length));
            },
            .variant => |variant| {
                if (code != 'v') return error.SignatureMismatch;
                try signatures.single(variant.signature, self.limits.max_depth);
                try self.text('g', variant.signature);
                try self.value(variant.signature, variant.value, depth + 1);
            },
            .unix_fd => return error.UnsupportedUnixFd,
        }
    }
};

/// Fuzz boundary: bounded arbitrary input, then a canonical encode/decode fixed point.
/// Invalid wire input is expected; allocation errors still propagate to the harness.
pub fn fuzzInput(gpa: std.mem.Allocator, bytes: []const u8) CodecError!void {
    const limits: Limits = .{ .max_frame_bytes = 4096, .max_array_bytes = 4096, .max_string_bytes = 4096, .max_depth = 16, .max_values = 256 };
    var frame = decode(gpa, bytes, limits) catch |err| {
        if (err == error.OutOfMemory) return err;
        return;
    };
    defer frame.deinit();
    const encoded = try encode(gpa, frame.message, .little, .{});
    defer gpa.free(encoded);
    var canonical = try decode(gpa, encoded, .{});
    defer canonical.deinit();
    const fixed_point = try encode(gpa, canonical.message, .little, .{});
    defer gpa.free(fixed_point);
    if (!std.mem.eql(u8, encoded, fixed_point)) return error.InvalidHeader;
}

// Rule-derived from the D-Bus specification v0.43 message layout, not a captured packet:
// a return with reply serial 1 and one UINT32 (42), excluding final header padding.
// https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-messages
const recorded_little_return = [_]u8{
    'l', 2, 0,   1, 4, 0, 0, 0, 2, 0, 0,   0, 15, 0,   0, 0,
    5,   1, 'u', 0, 1, 0, 0, 0, 8, 1, 'g', 0, 1,  'u', 0, 0,
    42,  0, 0,   0,
};
const recorded_big_return = [_]u8{
    'B', 2, 0,   1,  0, 0, 0, 4, 0, 0, 0,   2, 0, 0,   0, 15,
    5,   1, 'u', 0,  0, 0, 0, 1, 8, 1, 'g', 0, 1, 'u', 0, 0,
    0,   0, 0,   42,
};

/// Fixed decoder seeds. SHA-256 and length literals identify the committed bytes.
/// Numeric return frames are rule-derived. The daemon Hello return is captured traffic.
/// Invalid seeds are deterministic single-change/truncation derivatives.
pub const CorpusEntry = struct {
    name: []const u8,
    bytes: []const u8,
    sha256: [32]u8,
    length: usize,
    expected_error: ?CodecError = null,
};

pub const corpus = [_]CorpusEntry{
    .{
        .name = "little-return.bin",
        .bytes = @embedFile("dbus_corpus/little-return.bin"),
        .length = 36,
        .sha256 = .{
            0xed, 0xe9, 0x50, 0xac, 0x51, 0xa6, 0x24, 0xec,
            0xcf, 0x96, 0x6e, 0x2e, 0x1d, 0x21, 0xbc, 0xe9,
            0x32, 0xd9, 0xfc, 0xdd, 0x78, 0x8c, 0x3a, 0xa8,
            0x8e, 0xeb, 0xec, 0xca, 0xc9, 0x08, 0xaa, 0x66,
        },
    },
    .{
        .name = "big-return.bin",
        .bytes = @embedFile("dbus_corpus/big-return.bin"),
        .length = 36,
        .sha256 = .{
            0x18, 0x74, 0x47, 0x09, 0xfc, 0x14, 0x4e, 0x1e,
            0xa9, 0x16, 0x0e, 0xf4, 0x08, 0x4d, 0xf8, 0x41,
            0x3e, 0x31, 0xac, 0x7a, 0x4a, 0xdc, 0x41, 0x2f,
            0x3b, 0x26, 0x47, 0xbc, 0xe3, 0xc4, 0x3c, 0xa6,
        },
    },
    .{
        .name = "invalid-boolean.bin",
        .bytes = @embedFile("dbus_corpus/invalid-boolean.bin"),
        .length = 36,
        .expected_error = error.InvalidBoolean,
        .sha256 = .{
            0xb0, 0xe6, 0x31, 0xee, 0xa8, 0xae, 0x59, 0xe0,
            0x71, 0x4c, 0xfb, 0x35, 0xb9, 0xff, 0x5d, 0x86,
            0xb8, 0x88, 0xd4, 0xa8, 0xc0, 0xf4, 0x90, 0x48,
            0x1b, 0x33, 0x36, 0x5b, 0x9d, 0xa9, 0x8c, 0xe0,
        },
    },
    .{
        .name = "truncated-header.bin",
        .bytes = @embedFile("dbus_corpus/truncated-header.bin"),
        .length = 15,
        .expected_error = error.Truncated,
        .sha256 = .{
            0xda, 0xb5, 0x3b, 0x54, 0x1c, 0x3d, 0x28, 0xb6,
            0xaa, 0x97, 0xf3, 0xb2, 0x31, 0x66, 0x94, 0xd3,
            0x52, 0x43, 0xb4, 0x08, 0x21, 0xee, 0x66, 0x77,
            0x3a, 0x33, 0x55, 0xca, 0x26, 0x51, 0x85, 0xcd,
        },
    },
    .{
        .name = "daemon-hello-return.bin",
        .bytes = @embedFile("dbus_corpus/daemon-hello-return.bin"),
        .length = 89,
        .expected_error = null,
        .sha256 = .{
            0x59, 0xde, 0x2c, 0x6f, 0x17, 0x73, 0x7b, 0x66,
            0x07, 0x04, 0x38, 0x67, 0x54, 0xa9, 0x04, 0xf8,
            0x23, 0xfd, 0x2e, 0x55, 0x43, 0xc2, 0x54, 0x27,
            0x71, 0x90, 0xfb, 0x12, 0xc5, 0x9e, 0x39, 0xd7,
        },
    },
};

test "dbus rule-derived specification frames decode and encode exactly" {
    inline for (.{ .{ recorded_little_return, std.builtin.Endian.little }, .{ recorded_big_return, std.builtin.Endian.big } }) |fixture| {
        const wire_bytes: [36]u8 = fixture[0];
        var frame = try decode(std.testing.allocator, &wire_bytes, .{});
        defer frame.deinit();
        try std.testing.expectEqual(Kind.method_return, frame.message.kind);
        try std.testing.expectEqual(@as(?u32, 1), frame.message.reply_serial);
        try std.testing.expectEqualStrings("u", frame.message.signature);
        try std.testing.expectEqual(@as(u32, 42), frame.message.body[0].uint32);
        const bytes = try encode(std.testing.allocator, frame.message, fixture[1], .{});
        defer std.testing.allocator.free(bytes);
        try std.testing.expectEqualSlices(u8, &wire_bytes, bytes);
    }
}

test "dbus fixed header rejects malformed and bounded lengths before allocation" {
    var header: [16]u8 = recorded_little_return[0..16].*;
    try std.testing.expectEqual(@as(usize, 36), try frameLength(header, .{}));
    header[0] = 'x';
    try std.testing.expectError(error.InvalidEndian, frameLength(header, .{}));
    header = recorded_little_return[0..16].*;
    header[1] = 0;
    try std.testing.expectError(error.InvalidMessageType, frameLength(header, .{}));
    header = recorded_little_return[0..16].*;
    header[3] = 2;
    try std.testing.expectError(error.InvalidProtocolVersion, frameLength(header, .{}));
    header = recorded_little_return[0..16].*;
    @memset(header[8..12], 0);
    try std.testing.expectError(error.InvalidSerial, frameLength(header, .{}));
    header = recorded_little_return[0..16].*;
    try std.testing.expectError(error.LimitExceeded, frameLength(header, .{ .max_frame_bytes = 35 }));
}

test "dbus strict padding truncated bodies and signatures" {
    var bytes = recorded_little_return;
    bytes[31] = 1;
    try std.testing.expectError(error.InvalidPadding, decode(std.testing.allocator, &bytes, .{}));
    try std.testing.expectError(error.Truncated, decode(std.testing.allocator, recorded_little_return[0..35], .{}));
    bytes = recorded_little_return;
    bytes[29] = 'h';
    try std.testing.expectError(error.UnsupportedUnixFd, decode(std.testing.allocator, &bytes, .{}));
    bytes = recorded_little_return;
    bytes[29] = 'b';
    try std.testing.expectError(error.InvalidBoolean, decode(std.testing.allocator, &bytes, .{}));
}

const scalar_values = [_]Value{
    .{ .byte = 255 },                .{ .boolean = true },                    .{ .int16 = -123 },
    .{ .uint16 = 65535 },            .{ .int32 = -123456 },                   .{ .uint32 = 123456 },
    .{ .int64 = -1234567890123 },    .{ .uint64 = 1234567890123 },            .{ .double = -1.25 },
    .{ .string = "hello \xc3\xa9" }, .{ .object_path = "/org/example/Test" }, .{ .signature = "a{sv}" },
};

fn allocationRoundtrip(gpa: std.mem.Allocator) !void {
    var body = try OwnedBody.init(gpa, "ybnqiuxtdsog", &scalar_values);
    defer body.deinit();
    const message: Message = .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .signature = body.signature, .body = body.values };
    const bytes = try encode(gpa, message, .big, .{});
    defer gpa.free(bytes);
    var frame = try decode(gpa, bytes, .{});
    defer frame.deinit();
    const encoded = try encode(gpa, frame.message, .big, .{});
    defer gpa.free(encoded);
    try std.testing.expectEqualSlices(u8, bytes, encoded);
    try std.testing.expectEqual(@as(i16, -123), frame.message.body[2].int16);
    try std.testing.expectEqualStrings("hello \xc3\xa9", frame.message.body[9].string);
}

test "dbus all scalar values and allocation failures" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRoundtrip, .{});
}

fn allocationNested(gpa: std.mem.Allocator) !void {
    var source_string = [_]u8{ 'v', 'a', 'l', 'u', 'e' };
    const variant: Variant = .{ .signature = "s", .value = .{ .string = &source_string } };
    const pair = [_]Value{ .{ .string = "key" }, .{ .variant = &variant } };
    const entries = [_]Value{.{ .dict_entry = &pair }};
    const fields = [_]Value{ .{ .int32 = -1 }, .{ .array = .{ .element_signature = "{sv}", .values = &entries } } };
    const values = [_]Value{.{ .structure = &fields }};
    var body = try OwnedBody.init(gpa, "(ia{sv})", &values);
    defer body.deinit();
    source_string[0] = 'X';
    try std.testing.expectEqualStrings("value", body.values[0].structure[1].array.values[0].dict_entry[1].variant.value.string);
    const bytes = try encode(gpa, .{ .kind = .method_return, .serial = 3, .reply_serial = 1, .signature = body.signature, .body = body.values }, .little, .{});
    defer gpa.free(bytes);
    var frame = try decode(gpa, bytes, .{});
    defer frame.deinit();
    const second = try encode(gpa, frame.message, .little, .{});
    defer gpa.free(second);
    try std.testing.expectEqualSlices(u8, bytes, second);
}

test "dbus nested structures dictionary variants own copies and fail every allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationNested, .{});
}

test "dbus refuses unix file descriptors and mismatched outgoing values" {
    const fd = [_]Value{.{ .unix_fd = 0 }};
    try std.testing.expectError(error.UnsupportedUnixFd, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .signature = "h", .body = &fd }, .little, .{}));
    try std.testing.expectError(error.SignatureMismatch, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .signature = "s", .body = &.{.{ .uint32 = 0 }} }, .little, .{}));
    try std.testing.expectError(error.LimitExceeded, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .signature = "u", .body = &.{.{ .uint32 = 0 }} }, .little, .{ .max_values = 0 }));
}

test "dbus bounded arbitrary frames metamorphic fuzz" {
    try std.testing.fuzz(@as(void, {}), fuzzFrame, .{});
}

fn fuzzFrame(_: void, smith: *std.testing.Smith) !void {
    var bytes: [4096]u8 = undefined;
    const len = smith.slice(&bytes);
    try fuzzInput(std.testing.allocator, bytes[0..len]);
}

test "dbus allocation free signature iteration and body validation" {
    var position: usize = 0;
    try std.testing.expectEqualStrings("u", (try signatureNext("ua{sv}", &position)).?);
    try std.testing.expectEqualStrings("a{sv}", (try signatureNext("ua{sv}", &position)).?);
    try std.testing.expect((try signatureNext("ua{sv}", &position)) == null);
    try std.testing.expectError(error.InvalidSignature, signatureNext("a", &position));
    try validateBody("ybnqiuxtdsog", &scalar_values);
    try std.testing.expectError(error.InvalidString, validateBody("s", &.{.{ .string = "\xff" }}));
    try std.testing.expectError(error.InvalidObjectPath, validateBody("o", &.{.{ .object_path = "/bad//path" }}));
    try std.testing.expectError(error.UnsupportedUnixFd, validateBody("ah", &.{.{ .array = .{ .element_signature = "h", .values = &.{} } }}));
}

// Verbatim scalar/container byte examples from the D-Bus specification v0.43,
// Marshaling (Wire Format). Offsets begin on an eight-byte boundary.
// https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling
test "dbus recorded specification string array and variant body bytes" {
    const strings = [_]u8{
        3, 0, 0, 0, 'f', 'o', 'o', 0, 1, 0, 0, 0, '+', 0, 0, 0,
        3, 0, 0, 0, 'b', 'a', 'r', 0,
    };
    const array = [_]u8{
        0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
    };
    const variant = [_]u8{
        1, 't', 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5,
    };
    var writer: Encoder = .{ .gpa = std.testing.allocator, .endian = .little, .limits = .{} };
    defer writer.bytes.deinit(std.testing.allocator);
    try writer.sequence("sss", &.{
        .{ .string = "foo" }, .{ .string = "+" }, .{ .string = "bar" },
    }, 0);
    try std.testing.expectEqualSlices(u8, &strings, writer.bytes.items);
    writer.bytes.clearRetainingCapacity();
    writer.position = 0;
    writer.values = 0;
    writer.endian = .big;
    try writer.sequence("ax", &.{.{ .array = .{
        .element_signature = "x",
        .values = &.{.{ .int64 = 5 }},
    } }}, 0);
    try std.testing.expectEqualSlices(u8, &array, writer.bytes.items);
    writer.bytes.clearRetainingCapacity();
    writer.position = 0;
    writer.values = 0;
    const inner: Variant = .{ .signature = "t", .value = .{ .uint64 = 5 } };
    try writer.sequence("v", &.{.{ .variant = &inner }}, 0);
    try std.testing.expectEqualSlices(u8, &variant, writer.bytes.items);
}

test "dbus runtime variants obey total depth including empty arrays" {
    const empty: Value = .{ .array = .{ .element_signature = "u", .values = &.{} } };
    const inner: Variant = .{ .signature = "au", .value = empty };
    try std.testing.expectError(error.LimitExceeded, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .signature = "v", .body = &.{.{ .variant = &inner }} }, .little, .{ .max_depth = 1 }));
}

test "dbus header duplicates types required fields and unknown extensions" {
    var bytes = recorded_little_return;
    bytes[24] = 5;
    try std.testing.expectError(error.DuplicateHeader, decode(std.testing.allocator, &bytes, .{}));
    bytes = recorded_little_return;
    bytes[16] = 1;
    try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &bytes, .{}));
    bytes = recorded_little_return;
    bytes[16] = 42;
    try std.testing.expectError(error.MissingHeader, decode(std.testing.allocator, &bytes, .{}));
    bytes = recorded_little_return;
    bytes[16] = 0;
    try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &bytes, .{}));
    bytes = recorded_little_return;
    bytes[29] = '(';
    try std.testing.expectError(error.InvalidSignature, decode(std.testing.allocator, &bytes, .{}));
    bytes = recorded_little_return;
    bytes[2] = 0xff;
    var frame = try decode(std.testing.allocator, &bytes, .{});
    defer frame.deinit();
    try std.testing.expectEqual(@as(u8, 0xff), frame.message.flags);
}

test "dbus fixed header obeys hard protocol ceiling despite larger caller limits" {
    var bytes: [16]u8 = recorded_little_return[0..16].*;
    std.mem.writeInt(u32, bytes[4..8], protocol_frame_bytes_max, .little);
    try std.testing.expectError(error.LimitExceeded, frameLength(bytes, .{ .max_frame_bytes = std.math.maxInt(usize) }));
}

// Numeric bytes are recorded by applying the specification's two's-complement,
// IEEE754 and global alignment rules, independently of the implementation.
// https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-marshaling
test "dbus recorded numeric little endian body" {
    const fixture = [_]u8{
        0xfe, 0,    0,    0,    1,    0,    0,    0,    0xfe, 0xff, 0x34, 0x12,
        0xfd, 0xff, 0xff, 0xff, 0x78, 0x56, 0x34, 0x12, 0,    0,    0,    0,
        0xfc, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xef, 0xcd, 0xab, 0x89,
        0x67, 0x45, 0x23, 1,    0,    0,    0,    0,    0,    0,    0xf8, 0x3f,
    };
    const values = [_]Value{
        .{ .byte = 0xfe },     .{ .boolean = true },              .{ .int16 = -2 },
        .{ .uint16 = 0x1234 }, .{ .int32 = -3 },                  .{ .uint32 = 0x12345678 },
        .{ .int64 = -4 },      .{ .uint64 = 0x0123456789abcdef }, .{ .double = 1.5 },
    };
    var writer: Encoder = .{ .gpa = std.testing.allocator, .endian = .little, .limits = .{} };
    defer writer.bytes.deinit(std.testing.allocator);
    try writer.sequence("ybnqiuxtd", &values, 0);
    try std.testing.expectEqualSlices(u8, &fixture, writer.bytes.items);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: Decoder = .{ .arena = arena.allocator(), .bytes = &fixture, .endian = .little, .position = 0, .end = fixture.len, .budget = .{ .limits = .{} } };
    const decoded = try reader.sequence("ybnqiuxtd", 0);
    try std.testing.expectEqual(@as(u8, 0xfe), decoded[0].byte);
    try std.testing.expect(decoded[1].boolean);
    try std.testing.expectEqual(@as(i16, -2), decoded[2].int16);
    try std.testing.expectEqual(@as(u16, 0x1234), decoded[3].uint16);
    try std.testing.expectEqual(@as(i32, -3), decoded[4].int32);
    try std.testing.expectEqual(@as(u32, 0x12345678), decoded[5].uint32);
    try std.testing.expectEqual(@as(i64, -4), decoded[6].int64);
    try std.testing.expectEqual(@as(u64, 0x0123456789abcdef), decoded[7].uint64);
    try std.testing.expectEqual(@as(f64, 1.5), decoded[8].double);
    try std.testing.expectEqual(fixture.len, reader.position);
}

test "dbus all message kinds required metadata and owned raw bytes" {
    const messages = [_]Message{
        .{ .kind = .method_call, .serial = 1, .path = "/org/example/Test", .interface = "org.example.Test", .member = "Method", .destination = "org.example.Test", .sender = ":1.42" },
        .{ .kind = .method_return, .serial = 2, .reply_serial = 1 },
        .{ .kind = .error_reply, .serial = 3, .reply_serial = 1, .error_name = "org.example.Test.Failed", .signature = "s", .body = &.{.{ .string = "failure" }} },
        .{ .kind = .signal, .serial = 4, .path = "/org/example/Test", .interface = "org.example.Test", .member = "Changed" },
    };
    for (messages) |message| {
        const bytes = try encode(std.testing.allocator, message, .little, .{});
        defer std.testing.allocator.free(bytes);
        var frame = try OwnedFrame.decode(std.testing.allocator, bytes, .{});
        defer frame.deinit();
        try std.testing.expectEqual(message.kind, frame.message.kind);
        try std.testing.expectEqual(message.serial, frame.message.serial);
        bytes[0] = 'X';
        try std.testing.expectEqual(@as(u8, 'l'), frame.bytes[0]);
        try std.testing.expectEqualStrings(message.signature, frame.message.signature);
    }
    try std.testing.expectError(error.InvalidHeader, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .sender = "org.example.Test" }, .little, .{}));
}

test "dbus decoder array bound and empty alignment are enforced" {
    const fixture = [_]u8{ 0, 0, 0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 5 };
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: Decoder = .{ .arena = arena.allocator(), .bytes = &fixture, .endian = .big, .position = 0, .end = fixture.len, .budget = .{ .limits = .{ .max_array_bytes = 7 } } };
    try std.testing.expectError(error.LimitExceeded, reader.value("ax", 0));
    const empty_array = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 0 };
    reader = .{ .arena = arena.allocator(), .bytes = &empty_array, .endian = .big, .position = 0, .end = empty_array.len, .budget = .{ .limits = .{} } };
    const value = try reader.value("ax", 0);
    try std.testing.expectEqual(@as(usize, 0), value.array.values.len);
    try std.testing.expectEqual(@as(usize, 8), reader.position);
    const bad_padding = [_]u8{ 0, 0, 0, 0, 0, 0, 0, 1 };
    reader = .{ .arena = arena.allocator(), .bytes = &bad_padding, .endian = .big, .position = 0, .end = bad_padding.len, .budget = .{ .limits = .{} } };
    try std.testing.expectError(error.InvalidPadding, reader.value("ax", 0));
}

// These rule-derived fixtures record the dict/struct alignment independently of
// encode/decode, so a matching mistake in both directions cannot hide.
test "dbus recorded dictionary and padded structure bodies" {
    const dictionary = [_]u8{
        16, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0, 'k', 0, 1, 'b',
        0,  0, 0, 0, 1, 0, 0, 0,
    };
    const structure = [_]u8{
        0xff, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0, 2, 0, 0, 0, '/', 'a', 0,
    };
    const variant: Variant = .{ .signature = "b", .value = .{ .boolean = true } };
    const pair = [_]Value{ .{ .string = "k" }, .{ .variant = &variant } };
    const entries = [_]Value{.{ .dict_entry = &pair }};
    var writer: Encoder = .{ .gpa = std.testing.allocator, .endian = .little, .limits = .{} };
    defer writer.bytes.deinit(std.testing.allocator);
    try writer.sequence("a{sv}", &.{.{ .array = .{
        .element_signature = "{sv}",
        .values = &entries,
    } }}, 0);
    try std.testing.expectEqualSlices(u8, &dictionary, writer.bytes.items);
    writer.bytes.clearRetainingCapacity();
    writer.position = 0;
    writer.values = 0;
    const fields = [_]Value{ .{ .uint32 = 9 }, .{ .object_path = "/a" } };
    try writer.sequence("y(uo)", &.{ .{ .byte = 0xff }, .{ .structure = &fields } }, 0);
    try std.testing.expectEqualSlices(u8, &structure, writer.bytes.items);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var reader: Decoder = .{ .arena = arena.allocator(), .bytes = &dictionary, .endian = .little, .position = 0, .end = dictionary.len, .budget = .{ .limits = .{} } };
    const decoded_dictionary = try reader.value("a{sv}", 0);
    const decoded_pair = decoded_dictionary.array.values[0].dict_entry;
    try std.testing.expectEqualStrings("k", decoded_pair[0].string);
    try std.testing.expect(decoded_pair[1].variant.value.boolean);
    reader = .{ .arena = arena.allocator(), .bytes = &structure, .endian = .little, .position = 0, .end = structure.len, .budget = .{ .limits = .{} } };
    const decoded_structure = try reader.sequence("y(uo)", 0);
    try std.testing.expectEqual(@as(u32, 9), decoded_structure[1].structure[0].uint32);
    try std.testing.expectEqualStrings("/a", decoded_structure[1].structure[1].object_path);
    try std.testing.expectEqual(structure.len, reader.position);
}

fn allocationArenaDecode(gpa: std.mem.Allocator) !void {
    {
        const arena = try newArena(gpa);
        var caller_owned = true;
        errdefer if (caller_owned) destroyArena(arena);
        const bytes = try arena.allocator().dupe(u8, &recorded_little_return);
        var frame = try decodeInArena(arena, bytes, .{});
        caller_owned = false;
        defer frame.deinit();
        try std.testing.expect(frame.arena == arena);
        try std.testing.expect(frame.bytes.ptr == bytes.ptr);
        try std.testing.expectEqual(@as(u32, 42), frame.message.body[0].uint32);
    }
    {
        const arena = try newArena(gpa);
        defer destroyArena(arena);
        const bytes = try arena.allocator().dupe(u8, &recorded_little_return);
        bytes[16] = 0;
        try std.testing.expectError(error.InvalidHeader, decodeInArena(arena, bytes, .{}));
        const retained = try arena.allocator().alloc(u8, 1);
        retained[0] = 42;
        try std.testing.expectEqual(@as(u8, 42), retained[0]);
    }
}

test "dbus in arena decode transfers existing raw pointer only on success and fails allocations" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationArenaDecode, .{});
}

test "dbus committed corpus has fixed hashes lengths and decoder outcomes" {
    for (corpus) |entry| {
        try std.testing.expectEqual(entry.length, entry.bytes.len);
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry.bytes, &digest, .{});
        try std.testing.expectEqualSlices(u8, &entry.sha256, &digest);
        if (entry.expected_error) |expected| {
            try std.testing.expectError(expected, decode(std.testing.allocator, entry.bytes, .{}));
        } else {
            var frame = try decode(std.testing.allocator, entry.bytes, .{});
            defer frame.deinit();
            try std.testing.expectEqual(Kind.method_return, frame.message.kind);
            try std.testing.expectEqual(@as(usize, 1), frame.message.body.len);
            switch (frame.message.body[0]) {
                .uint32 => |value| {
                    try std.testing.expectEqualStrings("u", frame.message.signature);
                    try std.testing.expectEqual(@as(u32, 42), value);
                },
                .string => |value| {
                    try std.testing.expectEqualStrings("s", frame.message.signature);
                    try std.testing.expectEqualStrings(":1.7", value);
                },
                else => return error.TestUnexpectedResult,
            }
            // Fixture tests check semantic values and independent encoder golden bytes.
            // Header order may differ. Every valid seed must reach the canonical fixed point.
            try fuzzInput(std.testing.allocator, frame.bytes);
        }
    }
}

test "dbus body measurement is allocation free and matches normative aligned lengths" {
    const fields = [_]Value{ .{ .uint32 = 9 }, .{ .object_path = "/a" } };
    const structured = [_]Value{ .{ .byte = 0xff }, .{ .structure = &fields } };
    try std.testing.expectEqual(@as(usize, 19), try measureBody("y(uo)", &structured, .{}));
    try std.testing.expectEqual(@as(usize, 19), try measureBody("y(uo)", &structured, .{ .max_frame_bytes = 19 }));
    try std.testing.expectError(error.LimitExceeded, measureBody("y(uo)", &structured, .{ .max_frame_bytes = 18 }));
    try std.testing.expectEqual(@as(usize, 24), try measureBody("sss", &.{
        .{ .string = "foo" }, .{ .string = "+" }, .{ .string = "bar" },
    }, .{}));
    const array = [_]Value{.{ .array = .{
        .element_signature = "x",
        .values = &.{.{ .int64 = 5 }},
    } }};
    try std.testing.expectEqual(@as(usize, 16), try measureBody("ax", &array, .{}));
    try std.testing.expectError(error.LimitExceeded, measureBody("ax", &array, .{ .max_array_bytes = 7 }));
    const inner: Variant = .{ .signature = "t", .value = .{ .uint64 = 5 } };
    try std.testing.expectEqual(@as(usize, 16), try measureBody("v", &.{.{ .variant = &inner }}, .{}));
    try std.testing.expectError(error.LimitExceeded, measureBody("v", &.{.{ .variant = &inner }}, .{ .max_depth = 0 }));
    try std.testing.expectError(error.LimitExceeded, measureBody("u", &.{.{ .uint32 = 1 }}, .{ .max_values = 0 }));
    try std.testing.expectError(error.LimitExceeded, measureBody("s", &.{.{ .string = "abc" }}, .{ .max_string_bytes = 2 }));
    try std.testing.expectError(error.SignatureMismatch, measureBody("s", &.{.{ .uint32 = 1 }}, .{}));
}

test "dbus message measurement equals encoded frame and exact global value budget" {
    const message: Message = .{ .kind = .method_return, .serial = 2, .reply_serial = 1, .signature = "u", .body = &.{.{ .uint32 = 42 }} };
    try std.testing.expectEqual(@as(usize, 36), try measureMessage(message, .{}));
    try std.testing.expectEqual(@as(usize, 36), try measureMessage(message, .{ .max_values = 5, .max_frame_bytes = 36 }));
    try std.testing.expectError(error.LimitExceeded, measureMessage(message, .{ .max_values = 4 }));
    try std.testing.expectError(error.LimitExceeded, measureMessage(message, .{ .max_frame_bytes = 35 }));
    var frame = try decode(std.testing.allocator, &recorded_little_return, .{ .max_values = 5 });
    defer frame.deinit();
    try std.testing.expectError(error.LimitExceeded, decode(std.testing.allocator, &recorded_little_return, .{ .max_values = 4 }));
    const exact_encoded = try encode(std.testing.allocator, frame.message, .little, .{ .max_values = 5, .max_frame_bytes = 36 });
    defer std.testing.allocator.free(exact_encoded);
    try std.testing.expectEqualSlices(u8, &recorded_little_return, exact_encoded);
    try std.testing.expectError(error.LimitExceeded, encode(std.testing.allocator, frame.message, .little, .{ .max_values = 4 }));
    const messages = [_]Message{
        .{ .kind = .method_call, .serial = 1, .path = "/org/example/Test", .interface = "org.example.Test", .member = "Call", .sender = ":1.9", .destination = "org.example.Target", .signature = "s", .body = &.{.{ .string = "arg" }} },
        .{ .kind = .method_return, .serial = 1, .reply_serial = 123, .destination = ":1.999", .signature = "a{sv}", .body = &.{.{ .array = .{
            .element_signature = "{sv}",
            .values = &.{},
        } }} },
        .{ .kind = .error_reply, .serial = 1, .reply_serial = 456, .destination = ":12.123", .error_name = "org.freedesktop.DBus.Error.Failed", .signature = "s", .body = &.{.{ .string = "failure" }} },
        .{ .kind = .signal, .serial = 1, .path = "/org/example/Test", .interface = "org.example.Test", .member = "Changed" },
    };
    for (messages) |candidate| {
        const measured = try measureMessage(candidate, .{});
        inline for (.{ std.builtin.Endian.little, std.builtin.Endian.big }) |endian| {
            const encoded = try encode(std.testing.allocator, candidate, endian, .{});
            defer std.testing.allocator.free(encoded);
            try std.testing.expectEqual(measured, encoded.len);
        }
    }
}

// This actual private dbus-daemon Hello return checks driver sender and assigned name retention.
// Capture receipt: native-startup-bounded-wire-red.json.
test "actual dbus-daemon Hello return retains driver sender and assigned unique name" {
    const fixture = @embedFile("dbus_corpus/daemon-hello-return.bin");
    try std.testing.expectEqual(@as(usize, 89), fixture.len);
    const expected_sha256 = [_]u8{
        0x59, 0xde, 0x2c, 0x6f, 0x17, 0x73, 0x7b, 0x66,
        0x07, 0x04, 0x38, 0x67, 0x54, 0xa9, 0x04, 0xf8,
        0x23, 0xfd, 0x2e, 0x55, 0x43, 0xc2, 0x54, 0x27,
        0x71, 0x90, 0xfb, 0x12, 0xc5, 0x9e, 0x39, 0xd7,
    };
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(fixture, &digest, .{});
    try std.testing.expectEqualSlices(u8, &expected_sha256, &digest);
    try std.testing.expectEqual(@as(u8, 'l'), fixture[0]);
    try std.testing.expectEqual(@as(u32, 9), std.mem.readInt(u32, fixture[4..8], .little));
    try std.testing.expectEqual(@as(u32, 61), std.mem.readInt(u32, fixture[12..16], .little));
    try std.testing.expectEqual(@as(usize, 89), try frameLength(fixture[0..16].*, .{}));

    var frame = try decode(std.testing.allocator, fixture, .{});
    defer frame.deinit();
    try std.testing.expectEqual(Kind.method_return, frame.message.kind);
    try std.testing.expectEqual(@as(u8, 1), frame.message.flags);
    try std.testing.expectEqual(@as(u32, 1), frame.message.serial);
    try std.testing.expectEqual(@as(?u32, 1), frame.message.reply_serial);
    try std.testing.expectEqualStrings("org.freedesktop.DBus", frame.message.sender.?);
    try std.testing.expectEqualStrings(":1.7", frame.message.destination.?);
    try std.testing.expectEqualStrings("s", frame.message.signature);
    try std.testing.expectEqual(@as(usize, 1), frame.message.body.len);
    try std.testing.expect(frame.message.body[0] == .string);
    try std.testing.expectEqualStrings(":1.7", frame.message.body[0].string);
}

test "dbus sender rejects ordinary well known names on encode and actual packet decode" {
    // Replace only the sender bytes. Keep the captured header lengths, padding, and body.
    const fixture = @embedFile("dbus_corpus/daemon-hello-return.bin");
    const sender_start = 56;
    const sender_end = 76;
    try std.testing.expectEqualStrings("org.freedesktop.DBus", fixture[sender_start..sender_end]);
    inline for (.{ "org.example.TestName", "org.freedesktop.Dbus" }) |sender| {
        try std.testing.expect(validName(sender, true, true));
        try std.testing.expectEqual(sender_end - sender_start, sender.len);
        try std.testing.expectError(error.InvalidHeader, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 1, .reply_serial = 1, .sender = sender }, .little, .{}));
        var bytes: [fixture.len]u8 = fixture.*;
        @memcpy(bytes[sender_start..sender_end], sender);
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &bytes, .{}));
    }
}

test "dbus sender syntax guards still reject malformed unique and driver names" {
    const fixture = @embedFile("dbus_corpus/daemon-hello-return.bin");
    inline for (.{ "org.freedesktop..Bus", ":org..example.Testxx" }) |sender| {
        try std.testing.expect(!validName(sender, true, true));
        try std.testing.expectEqual(@as(usize, 20), sender.len);
        try std.testing.expectError(error.InvalidHeader, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 1, .reply_serial = 1, .sender = sender }, .little, .{}));
        var bytes: [fixture.len]u8 = fixture.*;
        @memcpy(bytes[56..76], sender);
        try std.testing.expectError(error.InvalidHeader, decode(std.testing.allocator, &bytes, .{}));
    }
    inline for (.{ "", ":" }) |sender| {
        try std.testing.expectError(error.InvalidHeader, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 1, .reply_serial = 1, .sender = sender }, .little, .{}));
    }
    var overlong: [256]u8 = @splat('a');
    overlong[0] = ':';
    overlong[2] = '.';
    try std.testing.expectError(error.InvalidHeader, encode(std.testing.allocator, .{ .kind = .method_return, .serial = 1, .reply_serial = 1, .sender = &overlong }, .little, .{}));
}
