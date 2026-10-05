//! `Action`: the `(sss)` triple `org.a11y.atspi.Action.GetActions` returns.
//!
//! **Upstream.** `accesskit_atspi_common/src/action.rs:9-13` declares the
//! struct, with `localized_name` first, then `description`, then `key_binding`.
//! `docs/41-atspi-build-map.md` section 1.5 records `a(sss)` as the wire type of
//! `Action.GetActions` and names the triple at `action.rs:44-46`.
//!
//! **Why the strings are borrowed.** A client decodes the array into memory it
//! owns and hands the port an allocator and a body; a name that must outlive the
//! call is the caller's to copy. The port therefore borrows every string here
//! and never frees one, and a test decodes with `BodyDecoder.decode`, which
//! borrows from the body, to keep that honest.

const std = @import("std");

const goose = @import("goose");
const DBusWriter = goose.core.value.DBusWriter;

/// One entry of the `GetActions` reply: a name, a description and a key binding.
///
/// The wire type is `(sss)`. Upstream `action.rs:10-13`.
pub const Action = struct {
    /// The wire signature of `Action`, and of each element of the `a(sss)`
    /// array `GetActions` returns.
    pub const SIGNATURE: [:0]const u8 = "(sss)";

    /// The action's name as a client should show it. Upstream `action.rs:11`.
    localized_name: []const u8,
    /// What the action does. Upstream `action.rs:12`.
    description: []const u8,
    /// The key combination that runs the action. Upstream `action.rs:13`.
    key_binding: []const u8,

    /// Builds a triple from its three strings, in the wire order.
    ///
    /// No string is copied and none is owned, so all three must outlive the
    /// `Action` that borrows them.
    ///
    /// **Errors.** This function does not fail.
    pub fn init(
        localized_name: []const u8,
        description: []const u8,
        key_binding: []const u8,
    ) Action {
        return .{
            .localized_name = localized_name,
            .description = description,
            .key_binding = key_binding,
        };
    }

    /// Writes the three strings in the order `localized_name`, `description`,
    /// `key_binding`.
    ///
    /// The struct is eight-aligned; each member is a D-Bus string, which is a
    /// four-aligned length, the bytes and a NUL.
    ///
    /// **Errors.** `error.OutOfMemory` from the goose writer, and
    /// `error.SignatureTooLong` is not reachable here because a `s` signature is
    /// one byte.
    pub fn ser(self: Action, w: *DBusWriter) !void {
        try w.padTo(8);
        try writeString(w, self.localized_name);
        try writeString(w, self.description);
        try writeString(w, self.key_binding);
    }
};

/// The signature goose derives for `Action` from the three string members
/// alone, checked against the declared constant. A port that declared `(sss)`
/// over a differently ordered struct would pass the first test and fail this
/// one.
const derived_signature: [:0]const u8 = blk: {
    const len = goose.core.value.Value.reprLength(Action);
    var buf: [len]u8 = undefined;
    goose.core.value.Value.getRepr(Action, len, 0, &buf);
    break :blk buf[0..len :0];
};

/// Writes one D-Bus string: four-aligned, a `u32` byte count, the bytes, a NUL.
///
/// `object_address.zig` carries its own copy of this. `docs/41` section 2.3 gives
/// `wire/action.zig` and `object_address.zig` no edge to each other, so the
/// helper is duplicated rather than hoisted into a module one of them would then
/// have to import. It is six lines and the duplication is deliberate.
fn writeString(w: *DBusWriter, bytes: []const u8) !void {
    try w.padTo(4);
    try w.writeInt(u32, @intCast(bytes.len));
    try w.buffer.appendSlice(w.gpa, bytes);
    try w.buffer.append(w.gpa, 0);
}

test "Action marshals as (sss)" {
    try std.testing.expectEqualStrings("(sss)", Action.SIGNATURE);
}

test "goose derives the declared signature from the three string members" {
    try std.testing.expectEqualStrings(Action.SIGNATURE, derived_signature);
}

test "the three strings reach the wire in the order name, description, binding" {
    const gpa = std.testing.allocator;

    var encoder = try goose.message.BodyEncoder.encode(gpa, Action.init("click", "", "Alt+C"));
    defer encoder.deinit();

    try std.testing.expectEqualStrings("(sss)", encoder.signature());
    const body = encoder.body();

    // The eight-byte struct alignment is already satisfied at body offset zero,
    // so each member is a four-aligned length, its bytes and a NUL. "click" is
    // five bytes, the empty description is none, and "Alt+C" is five again:
    // 10 + 5 + 10 = 25 bytes.
    try std.testing.expectEqual(@as(usize, 25), body.len);
    try std.testing.expectEqualStrings("click", readString(body, 0));
    try std.testing.expectEqualStrings("", readString(body, 10));
    try std.testing.expectEqualStrings("Alt+C", readString(body, 15));
}

/// The three members as goose's decoder walks them, which is what a peer does.
/// `Action` itself holds plain slices, so the decode test uses this mirror.
const DecodedAction = struct {
    pub const SIGNATURE: [:0]const u8 = "(sss)";
    localized_name: goose.core.value.GStr,
    description: goose.core.value.GStr,
    key_binding: goose.core.value.GStr,
};

test "a peer decoding the reply reads all three strings back in wire order" {
    const gpa = std.testing.allocator;

    var encoder = try goose.message.BodyEncoder.encode(gpa, Action.init("click", "Presses", ""));
    defer encoder.deinit();

    var decoder = goose.message.BodyDecoder.init(gpa, encoder.body(), encoder.signature(), .little);
    const decoded = try decoder.decode(DecodedAction);

    try std.testing.expectEqualStrings("click", decoded.localized_name.s);
    try std.testing.expectEqualStrings("Presses", decoded.description.s);
    try std.testing.expectEqualStrings("", decoded.key_binding.s);
}

test "the GetActions array signature is a(sss), one Action per element" {
    // `Value.Array` composes the element signature with `a`, which is what
    // `GetActions` puts in its reply.
    const Array = goose.core.value.Value.Array(Action);
    try std.testing.expectEqualStrings("a(sss)", Array.SIGNATURE);
}

/// Reads the D-Bus string that begins at `offset` and returns its bytes.
fn readString(body: []const u8, offset: usize) []const u8 {
    const len = std.mem.readInt(u32, body[offset..][0..4], .little);
    return body[offset + 4 ..][0..len];
}
