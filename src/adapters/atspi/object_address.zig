//! `ObjectAddress`: the `(so)` pair every AT-SPI member uses to name another
//! object, and the absent-child marker the port answers with.
//!
//! **Upstream.** `accesskit_unix/src/atspi/object_address.rs:16-42` declares
//! `OwnedObjectAddress` with `bus_name` then `path`, `:23-29` is the
//! constructor, and `:30-36` is `null`. `docs/41-atspi-build-map.md` section 1.4
//! records `(so)` as the wire type of `Accessible.Parent`,
//! `Accessible.GetChildAtIndex`, `Accessible.GetApplication`,
//! `Component.GetAccessibleAtPoint`, `Hyperlink.GetObject`,
//! `Selection.GetSelectedChild` and `Document.GetTextSelections`, and section 1.1
//! records `/org/a11y/atspi/null` as the absent-child marker.
//!
//! **Two types, one wire shape.** `ObjectAddress` holds exactly the two members
//! the wire carries and borrows both. `OwnedObjectAddress` holds an
//! `ObjectAddress` and the two allocations behind it, because a reply built by
//! `ObjectId.toAddress` has to outlive the call that built it. Keeping ownership
//! out of `ObjectAddress` is not tidiness: a peer decodes a `(so)` by walking
//! the struct's fields, so a third field on the wire struct would make the
//! decoder read a `bool` out of the path. The test below decodes a reply to keep
//! that true.
//!
//! **Why this module imports nothing.** `docs/41` section 2.3 gives
//! `object_address.zig` no edge. The three paths it names are declared in
//! `object_id.zig`, which sits below it, and the six-line string writer below is
//! this module's own. A construction helper that would need `ObjectId` belongs
//! there.

const std = @import("std");

const goose = @import("goose");
const DBusWriter = goose.core.value.DBusWriter;
const GPath = goose.core.value.GPath;
const GStr = goose.core.value.GStr;

/// The object path every absent child answers with.
///
/// Upstream `object_address.rs:14`, and `interfaces/mod.rs:26-32` is where an
/// `Option` that is `None` becomes this address.
pub const null_path: [:0]const u8 = "/org/a11y/atspi/null";

/// A bus name and an object path, in that order, which is the AT-SPI `(so)`
/// struct. Upstream `object_address.rs:16-19`.
///
/// The two members are borrowed. A caller that allocated them keeps them and
/// releases them; see `OwnedObjectAddress` for the pair that does.
pub const ObjectAddress = struct {
    /// The wire signature of `ObjectAddress`. Every member that returns a peer
    /// checks its decoder against this one constant.
    pub const SIGNATURE: [:0]const u8 = "(so)";

    /// The unique name of the connection that owns `path`. Empty for the null
    /// address, where no connection owns anything.
    bus_name: GStr,
    /// The path of the named object on that connection.
    path: GPath,

    /// Builds an address from a bus name and a path, copying neither.
    ///
    /// The two slices must be sentinel-terminated and must outlive the
    /// `ObjectAddress` that borrows them.
    ///
    /// **Errors.** This function does not fail.
    pub fn fromSlices(bus_name: [:0]const u8, path: [:0]const u8) ObjectAddress {
        return .{ .bus_name = .{ .s = bus_name }, .path = .{ .s = path } };
    }

    /// The absent-child marker: an empty bus name and `/org/a11y/atspi/null`.
    ///
    /// Upstream `object_address.rs:30-36` names this `null`, and the AT-SPI
    /// reference names the path `DBUS_PATH_NULL`. Zig spells the primitive
    /// `null` too, so the Zig name is `nullAddress`; the wire value is
    /// unchanged. The address borrows two string literals, so there is nothing
    /// to release.
    ///
    /// **Errors.** This function does not fail.
    pub fn nullAddress() ObjectAddress {
        return fromSlices("", null_path);
    }

    /// Writes the bus name and then the path, which is the order the AT-SPI
    /// reference fixes and the order a peer decodes in.
    ///
    /// The struct is eight-aligned and each member is a four-aligned string.
    ///
    /// **Errors.** `error.OutOfMemory` from the goose writer.
    pub fn ser(self: ObjectAddress, w: *DBusWriter) !void {
        try w.padTo(8);
        try writeString(w, self.bus_name.s);
        try writePath(w, self.path.s);
    }
};

/// An `ObjectAddress` and the two allocations its members point at.
///
/// This is upstream's `OwnedObjectAddress` at `object_address.rs:16-42`: the
/// `ObjectRef<'a>` upstream builds it from is a borrow, and the reply outlives
/// the borrow, so the reply owns.
///
/// `deinit` is the only way to release one, and it releases both members even if
/// only one was allocated, so a partially built address does not leak.
pub const OwnedObjectAddress = struct {
    /// The wire value. Borrow it with `borrow` and write it with `ser`.
    value: ObjectAddress,

    /// Builds an owned address by copying `bus_name` and `path`.
    ///
    /// `gpa` first, because this allocates, and the two sources follow it in the
    /// wire order. On `error.OutOfMemory` nothing is allocated and there is
    /// nothing to release.
    ///
    /// **Errors.** `error.OutOfMemory` from `gpa`.
    pub fn init(
        gpa: std.mem.Allocator,
        bus_name: []const u8,
        path: []const u8,
    ) std.mem.Allocator.Error!OwnedObjectAddress {
        const owned_name = try gpa.dupeZ(u8, bus_name);
        errdefer gpa.free(owned_name);
        const owned_path = try gpa.dupeZ(u8, path);
        return .{ .value = ObjectAddress.fromSlices(owned_name, owned_path) };
    }

    /// Builds an owned address that names `id` on `bus_name`.
    ///
    /// This is upstream's `ObjectId::to_address` at `object_id.rs:29-31`, and
    /// it lives here rather than on `ObjectId` because the `(so)` pair it
    /// produces is this module's type. Upstream can hang it on the identifier
    /// because Rust carries no rule about which module owns which type, and
    /// `docs/41` section 2.1 rule 2 is exactly that rule: one module declares a
    /// type. The effect is that `object_id.zig` keeps no edge to this file,
    /// which is what lets the object-path scheme be tested without a D-Bus
    /// dependency.
    ///
    /// `path` is taken as `anytype` rather than named, for the same reason
    /// `error.mapErrorFromNode` takes its source that way: the identifier is
    /// read through its `path` method, and a generic parameter is not an
    /// import edge. It must answer `path(std.mem.Allocator) ![:0]u8`, which
    /// `ObjectId` does.
    ///
    /// The caller releases the result with `deinit`. On `error.OutOfMemory`
    /// the temporary path is released here and nothing is left allocated.
    ///
    /// **Errors.** `error.OutOfMemory` from `gpa`.
    pub fn initFromObjectId(
        gpa: std.mem.Allocator,
        bus_name: []const u8,
        id: anytype,
    ) std.mem.Allocator.Error!OwnedObjectAddress {
        const borrowed_path = try id.path(gpa);
        defer gpa.free(borrowed_path);
        return init(gpa, bus_name, borrowed_path);
    }

    /// The borrowed wire value this address carries.
    ///
    /// **Errors.** This function does not fail.
    pub fn borrow(self: *const OwnedObjectAddress) ObjectAddress {
        return self.value;
    }

    /// Releases both members. Calling it twice frees memory twice, so the
    /// caller releases once and drops the value.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *OwnedObjectAddress, gpa: std.mem.Allocator) void {
        gpa.free(self.value.bus_name.s);
        gpa.free(self.value.path.s);
        self.* = undefined;
    }
};

/// The signature goose derives from the two members alone.
const derived_signature: [:0]const u8 = blk: {
    const len = goose.core.value.Value.reprLength(ObjectAddress);
    var buf: [len]u8 = undefined;
    goose.core.value.Value.getRepr(ObjectAddress, len, 0, &buf);
    break :blk buf[0..len :0];
};

/// Writes a D-Bus string: four-aligned, a `u32` byte count, the bytes, a NUL.
///
/// `wire/action.zig` carries the same six lines. `docs/41` section 2.3 gives the
/// two modules no edge, so the helper is written twice rather than hoisted.
fn writeString(w: *DBusWriter, bytes: []const u8) !void {
    try w.padTo(4);
    try w.writeInt(u32, @intCast(bytes.len));
    try w.buffer.appendSlice(w.gpa, bytes);
    try w.buffer.append(w.gpa, 0);
}

/// Writes a D-Bus object path, which has the same layout as a string and the
/// `o` signature.
fn writePath(w: *DBusWriter, bytes: []const u8) !void {
    try writeString(w, bytes);
}

test "ObjectAddress marshals as (so)" {
    try std.testing.expectEqualStrings("(so)", ObjectAddress.SIGNATURE);
}

test "goose derives the declared signature from the two members" {
    try std.testing.expectEqualStrings(ObjectAddress.SIGNATURE, derived_signature);
}

test "the bus name reaches the wire before the path" {
    const gpa = std.testing.allocator;

    const address = ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root");
    var encoder = try goose.message.BodyEncoder.encode(gpa, address);
    defer encoder.deinit();

    try std.testing.expectEqualStrings("(so)", encoder.signature());

    var decoder = goose.message.BodyDecoder.init(gpa, encoder.body(), encoder.signature(), .little);
    const decoded = try decoder.decode(ObjectAddress);

    try std.testing.expectEqualStrings(":1.42", decoded.bus_name.s);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", decoded.path.s);
}

test "swapping the two members would decode differently, so the order is pinned" {
    // The two strings have different lengths, so a port that wrote the path
    // first would produce a body a peer decodes into the swapped pair. This
    // asserts the exact byte layout rather than only the decode.
    const gpa = std.testing.allocator;

    var encoder = try goose.message.BodyEncoder.encode(
        gpa,
        ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root"),
    );
    defer encoder.deinit();
    const body = encoder.body();

    // The eight-byte struct alignment is already satisfied at body offset zero,
    // so the bus name occupies bytes zero to nine and the path starts at ten:
    // 4 + 5 + 1 for the name, then 4 + 30 + 1 for the path, so 45 bytes.
    try std.testing.expectEqual(@as(usize, 45), body.len);
    const name_len = std.mem.readInt(u32, body[0..4], .little);
    try std.testing.expectEqual(@as(u32, 5), name_len);
    try std.testing.expectEqualStrings(":1.42", body[4..9]);
    const path_len = std.mem.readInt(u32, body[10..14], .little);
    try std.testing.expectEqual(@as(u32, 30), path_len);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", body[14..44]);
}

test "the null address is an empty name and the null path" {
    const gpa = std.testing.allocator;

    var encoder = try goose.message.BodyEncoder.encode(gpa, ObjectAddress.nullAddress());
    defer encoder.deinit();

    var decoder = goose.message.BodyDecoder.init(gpa, encoder.body(), encoder.signature(), .little);
    const decoded = try decoder.decode(ObjectAddress);
    try std.testing.expectEqualStrings("", decoded.bus_name.s);
    try std.testing.expectEqualStrings("/org/a11y/atspi/null", decoded.path.s);
}

test "an owned address copies both members and releases them exactly once" {
    const gpa = std.testing.allocator;

    var owned = try OwnedObjectAddress.init(gpa, ":1.42", "/org/a11y/atspi/accessible/root");
    defer owned.deinit(gpa);

    // The copies are separate allocations, so the address does not borrow the
    // literals the caller passed and a later release of the caller's memory
    // cannot reach through it.
    try std.testing.expect(@intFromPtr(owned.value.bus_name.s.ptr) !=
        @intFromPtr(@as([:0]const u8, ":1.42").ptr));
    try std.testing.expectEqualStrings(":1.42", owned.borrow().bus_name.s);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", owned.borrow().path.s);
}

test "an owned address writes the same bytes as the borrowed one it copies" {
    const gpa = std.testing.allocator;

    const borrowed = ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root");
    var owned = try OwnedObjectAddress.init(gpa, ":1.42", "/org/a11y/atspi/accessible/root");
    defer owned.deinit(gpa);

    var from_borrowed = try goose.message.BodyEncoder.encode(gpa, borrowed);
    defer from_borrowed.deinit();
    var from_owned = try goose.message.BodyEncoder.encode(gpa, owned.borrow());
    defer from_owned.deinit();

    try std.testing.expectEqualSlices(u8, from_borrowed.body(), from_owned.body());
}

/// The two tests below moved here with `initFromObjectId`. They used to live in
/// `object_id.zig`, which reached this file for the address type and therefore
/// carried the D-Bus dependency with it.

const object_id = @import("object_id.zig");

test "initFromObjectId names the object on the connection that was passed" {
    const gpa = std.testing.allocator;

    var owned = try OwnedObjectAddress.initFromObjectId(gpa, ":1.42", object_id.ObjectId.root);
    defer owned.deinit(gpa);

    try std.testing.expectEqualStrings(":1.42", owned.borrow().bus_name.s);
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/root",
        owned.borrow().path.s,
    );
}

test "initFromObjectId writes the same path ObjectId.path builds" {
    const gpa = std.testing.allocator;

    var owned = try OwnedObjectAddress.initFromObjectId(gpa, ":1.42", object_id.ObjectId.root);
    defer owned.deinit(gpa);

    // The two must agree, because `Accessible.Parent` and `GetChildAtIndex`
    // answer with an address whose path a peer then calls back on.
    try std.testing.expectEqualStrings(object_id.root_path, owned.borrow().path.s);
}
