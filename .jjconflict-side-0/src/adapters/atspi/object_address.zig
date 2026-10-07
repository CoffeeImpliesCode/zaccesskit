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
//! the struct's two fields, so a third field on the wire struct would make the
//! decoder read a `bool` out of the path.
//!
//! **Why the members are sentinel slices.** A D-Bus `STRING` and an
//! `OBJECT_PATH` are the same wire shape, a `u32` byte count, the bytes and a
//! NUL. A `[:0]const u8` is what a marshaller can write without copying, and it
//! is what `object_id.zig` already builds, so neither type owns a byte.
//!
//! **Why `ser` is hand-written.** Upstream derives `zvariant::Type`, and that
//! derive is what produced `(so)`. A Zig port has no derive, so the struct
//! carries the signature as a `comptime` constant and a `ser` method that
//! appends the two strings to a message body. `docs/12` section 11 records this
//! substitution: a hand-written marshal per wire type, checked against recorded
//! bytes. `docs/12` section 9.1 records the same choice for a body the library
//! cannot marshal.
//!
//! **Wire layout.** The D-Bus specification, section "Byte order and
//! alignment", says a struct starts on an 8-byte boundary and that each of its
//! members is then aligned naturally. A `STRING` and an `OBJECT_PATH` are both
//! 4-aligned, so the pad between the bus name and the path is part of the
//! encoding and not optional. A bus name of five bytes ends the body at ten,
//! two bytes short of the path's alignment, which makes the whole address 48
//! bytes rather than 46.
//!
//! **The one edge this module owns.** The padding and string helpers below are
//! this module's own, and `docs/41` section 2.3 keeps them that way, so
//! `wire/action.zig` carries its own copy rather than importing one.
//! `initFromObjectId` is the one exception: it names the `ObjectId` type,
//! because an `anytype` parameter binds the type of its argument as written and
//! the argument at every call site is an enum literal whose natural type is the
//! union's tag, which has no `path`. `object_id.zig` imports nothing here, so
//! the edge runs one way and the object-path scheme still tests on its own.

const std = @import("std");

const object_id = @import("object_id.zig");

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
    pub const signature: [:0]const u8 = "(so)";

    /// The unique name of the connection that owns `path`. Empty for the null
    /// address, where no connection owns anything.
    bus_name: [:0]const u8,
    /// The path of the named object on that connection.
    path: [:0]const u8,

    /// Builds an address from a bus name and a path, copying neither.
    ///
    /// The two slices must be sentinel-terminated and must outlive the
    /// `ObjectAddress` that borrows them.
    ///
    /// **Errors.** This function does not fail.
    pub fn fromSlices(bus_name: [:0]const u8, path: [:0]const u8) ObjectAddress {
        return .{ .bus_name = bus_name, .path = path };
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

    /// Appends the bus name and then the path, which is the order the AT-SPI
    /// reference fixes and the order a peer decodes in.
    ///
    /// The struct is eight-aligned and each member is a four-aligned string.
    /// The bytes are appended to `out`, which the caller owns and releases.
    ///
    /// **Errors.** `error.OutOfMemory` from `out`.
    pub fn ser(
        self: ObjectAddress,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) std.mem.Allocator.Error!void {
        try padTo(gpa, 8, out);
        try writeString(gpa, out, self.bus_name);
        try writePath(gpa, out, self.path);
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
    /// type. The edge runs this way and not the other, so `object_id.zig` keeps
    /// no edge to this file.
    ///
    /// `id` is named rather than taken as `anytype`, and that naming is what
    /// makes the function compile. An `anytype` parameter binds the type of its
    /// argument as written, and `ObjectId.root` written at a call site is an
    /// enum literal whose natural type is the union's tag type
    /// `@typeInfo(ObjectId).@"union".tag_type.?`, which answers no `path`. The
    /// named parameter makes the union the type, so the lookup lands in the
    /// union's own namespace where `path` is declared at `object_id.zig:88`.
    ///
    /// There is no switch at the call site to write. `ObjectId.path` takes the
    /// whole union as its receiver and switches on the tag itself, at
    /// `object_id.zig:89-102`, so this function has no payload to take apart.
    ///
    /// The caller releases the result with `deinit`. On `error.OutOfMemory` the
    /// temporary path is released here and nothing is left allocated.
    ///
    /// **Errors.** `error.OutOfMemory` from `gpa`.
    pub fn initFromObjectId(
        gpa: std.mem.Allocator,
        bus_name: []const u8,
        id: object_id.ObjectId,
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
        gpa.free(self.value.bus_name);
        gpa.free(self.value.path);
        self.* = undefined;
    }
};

comptime {
    // `(so)` names a string and an object path, and a peer walks the struct's
    // two fields in order, so a third field would make the decoder read past the
    // path. The arity and the type of each member are checked here.
    const fields = @typeInfo(ObjectAddress).@"struct".fields;
    if (fields.len != 2) {
        @compileError("the (so) signature names exactly two members");
    }
    for (fields) |field| {
        if (field.type != [:0]const u8) {
            @compileError("every (so) member is a sentinel-terminated slice");
        }
    }
}

/// Appends zero bytes until the body length is a multiple of `alignment`.
///
/// The D-Bus specification pads to the minimum that aligns the value that
/// follows and forbids both a shorter pad and a longer one. Eight and four are
/// the only two alignments this module passes: eight for a struct and four for
/// a string.
///
/// **Errors.** `error.OutOfMemory` from `out`.
fn padTo(
    gpa: std.mem.Allocator,
    comptime alignment: usize,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    if (alignment != 4 and alignment != 8) {
        @compileError("a D-Bus struct is 8-aligned and a string is 4-aligned");
    }
    const missing = alignment - (out.items.len % alignment);
    if (missing == alignment) return;
    try out.appendNTimes(gpa, 0, missing);
}

/// Appends a D-Bus string: four-aligned, a `u32` byte count, the bytes, a NUL.
///
/// `wire/action.zig` carries its own copy of this. `docs/41` section 2.3 gives
/// the two modules no edge, so the helper is written twice rather than hoisted.
///
/// **Errors.** `error.OutOfMemory` from `out`.
fn writeString(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    try padTo(gpa, 4, out);
    var header: [4]u8 = undefined;
    // A D-Bus string length is a `u32`. No object path or bus name comes near
    // four gigabytes, and truncating instead would put a length on the wire that
    // does not match the bytes behind it.
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, bytes);
    try out.append(gpa, 0);
}

/// Appends a D-Bus object path, which has the same layout as a string and the
/// `o` signature.
fn writePath(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: [:0]const u8,
) std.mem.Allocator.Error!void {
    return writeString(gpa, out, bytes);
}

/// Asserts that every byte at `offset` is zero.
///
/// The specification requires alignment padding to be nul bytes and not
/// uninitialized garbage: "it must always be made up of nul bytes. The
/// alignment padding must not be left uninitialized". A length assertion alone
/// does not see this, because an encoder that wrote junk into the pad still
/// produced the right length and a peer that skips the pad still decoded the
/// right strings. `offsets` is a comptime list, so the loop carries a comptime
/// bound and names each byte it checks.
///
/// **Errors.** `error.TestUnexpectedResult` from a non-zero pad byte.
fn expectNulAt(comptime offsets: []const usize, body: []const u8) !void {
    inline for (offsets) |offset| {
        try std.testing.expectEqual(@as(u8, 0), body[offset]);
    }
}

/// Reads the D-Bus string that begins at `offset`, which is how a peer walks a
/// `(so)`.
fn readString(body: []const u8, offset: usize) []const u8 {
    const len = std.mem.readInt(u32, body[offset..][0..4], .little);
    return body[offset + 4 ..][0..len];
}

/// Reads the `u32` length that begins at `offset`, which is the first four
/// bytes of a D-Bus string and so the field a wrong alignment shows first.
fn stringLengthAt(body: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, body[offset..][0..4], .little);
}

/// Writes one borrowed address into a body this helper owns.
///
/// **Errors.** `error.OutOfMemory` from the body.
fn writeBorrowedAddress(gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root")
        .ser(gpa, &body);
}

/// Builds and releases one owned address.
///
/// The leak-detecting allocator behind this helper is what proves the second
/// `dupeZ` failing releases the first copy, which is the `errdefer` in `init`.
///
/// **Errors.** `error.OutOfMemory` from `gpa`.
fn buildOwnedAddress(gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    var owned = try OwnedObjectAddress.init(
        gpa,
        ":1.42",
        "/org/a11y/atspi/accessible/root",
    );
    defer owned.deinit(gpa);
}

test "ObjectAddress marshals as (so)" {
    try std.testing.expectEqualStrings("(so)", ObjectAddress.signature);
}

test "the bus name reaches the wire before the path" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root")
        .ser(gpa, &body);

    try std.testing.expectEqualStrings(":1.42", readString(body.items, 0));
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/root",
        readString(body.items, 12),
    );
}

test "the two members carry their own length and the pad between them" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root")
        .ser(gpa, &body);

    // A struct starts on an 8-byte boundary, so the bus name starts at zero.
    // It is 4 + 5 + 1 = 10 bytes and so ends at ten, which is two bytes short of
    // the path's four-byte alignment. The path is 31 characters long, so it
    // takes 4 + 31 + 1 and the body is 12 + 36 = 48 bytes. A port that packed
    // the two members without the pad would write 46 bytes and a peer would
    // read the path one field late.
    try std.testing.expectEqual(@as(usize, 48), body.items.len);
    try std.testing.expectEqual(@as(u32, 5), stringLengthAt(body.items, 0));
    try std.testing.expectEqualStrings(":1.42", body.items[4..9]);
    try std.testing.expectEqual(@as(u8, 0), body.items[9]);
    try std.testing.expectEqual(@as(u8, 0), body.items[10]);
    try std.testing.expectEqual(@as(u8, 0), body.items[11]);
    try std.testing.expectEqual(@as(u32, 31), stringLengthAt(body.items, 12));
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/root",
        body.items[16..47],
    );
    try std.testing.expectEqual(@as(u8, 0), body.items[47]);
}

test "an address that follows an odd member starts on the next eight-byte boundary" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendSlice(gpa, "ab");
    try ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root")
        .ser(gpa, &body);

    // Two bytes precede the address, so the struct pads to eight. The bus name
    // then runs from eight to eighteen, the pad takes the body to twenty, and
    // the path runs from twenty to fifty-six. The six bytes of struct padding
    // and the two before the path are asserted to be nul and not left as
    // whatever the buffer held.
    try expectNulAt(&.{ 2, 3, 4, 5, 6, 7, 18, 19 }, body.items);
    try std.testing.expectEqual(@as(usize, 56), body.items.len);
    try std.testing.expectEqualStrings(":1.42", readString(body.items, 8));
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/root",
        readString(body.items, 20),
    );
}

test "the null address is an empty name and the null path" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try ObjectAddress.nullAddress().ser(gpa, &body);

    // The empty bus name is 4 + 0 + 1 = 5 bytes, so the path's four-byte
    // alignment moves it to eight, where 4 + 20 + 1 takes the body to 33. The
    // three bytes of padding between them are nul.
    try expectNulAt(&.{ 5, 6, 7 }, body.items);
    try std.testing.expectEqual(@as(usize, 33), body.items.len);
    try std.testing.expectEqualStrings("", readString(body.items, 0));
    try std.testing.expectEqualStrings("/org/a11y/atspi/null", readString(body.items, 8));
    try std.testing.expectEqualStrings(null_path, readString(body.items, 8));
}

test "an owned address copies both members and releases them exactly once" {
    const gpa = std.testing.allocator;

    var owned = try OwnedObjectAddress.init(
        gpa,
        ":1.42",
        "/org/a11y/atspi/accessible/root",
    );
    defer owned.deinit(gpa);

    // The copies are separate allocations, so the address does not borrow the
    // literals the caller passed and a later release of the caller's memory
    // cannot reach through it.
    try std.testing.expect(@intFromPtr(owned.value.bus_name.ptr) !=
        @intFromPtr(@as([:0]const u8, ":1.42").ptr));
    try std.testing.expectEqualStrings(":1.42", owned.borrow().bus_name);
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/root",
        owned.borrow().path,
    );
}

test "an owned address writes the same bytes as the borrowed one it copies" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    var owned = try OwnedObjectAddress.init(
        gpa,
        ":1.42",
        "/org/a11y/atspi/accessible/root",
    );
    defer owned.deinit(gpa);

    var borrowed_body: std.ArrayList(u8) = .empty;
    defer borrowed_body.deinit(gpa);
    try ObjectAddress.fromSlices(":1.42", "/org/a11y/atspi/accessible/root")
        .ser(gpa, &borrowed_body);
    try owned.borrow().ser(gpa, &body);

    try std.testing.expectEqualSlices(u8, borrowed_body.items, body.items);
}

test "initFromObjectId names the object on the connection that was passed" {
    const gpa = std.testing.allocator;

    var owned = try OwnedObjectAddress.initFromObjectId(gpa, ":1.42", object_id.ObjectId.root);
    defer owned.deinit(gpa);

    try std.testing.expectEqualStrings(":1.42", owned.borrow().bus_name);
    try std.testing.expectEqualStrings(
        "/org/a11y/atspi/accessible/root",
        owned.borrow().path,
    );
}

test "initFromObjectId writes the same path ObjectId.path builds" {
    const gpa = std.testing.allocator;

    var owned = try OwnedObjectAddress.initFromObjectId(gpa, ":1.42", object_id.ObjectId.root);
    defer owned.deinit(gpa);

    // The two must agree, because `Accessible.Parent` and `GetChildAtIndex`
    // answer with an address whose path a peer then calls back on.
    try std.testing.expectEqualStrings(object_id.root_path, owned.borrow().path);
}

test "every allocation failure of ser is reported and never swallowed" {
    // `ser` writes into a body the caller owns, so a failure leaves whatever was
    // already written in place and the caller releases it. What must not happen
    // is a swallowed failure, so the sweep fails one allocation at a time up to
    // the first that succeeds.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        writeBorrowedAddress,
        .{},
    );
}

test "every allocation failure of init releases the copy it already made" {
    // `init` takes two allocations in a fixed order and releases the first one
    // when the second fails. The leak-detecting allocator behind the sweep is
    // what sees that release, so a removed `errdefer` fails this test.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        buildOwnedAddress,
        .{},
    );
}
