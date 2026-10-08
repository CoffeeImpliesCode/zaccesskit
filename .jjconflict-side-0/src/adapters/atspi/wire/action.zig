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
//! and never frees one, and a test reads the three members back out of the body
//! the way a peer does.
//!
//! **Why `ser` is hand-written.** Upstream derives `zvariant::Type`, and that
//! derive is what produced `(sss)`. A Zig port has no derive, so the struct
//! carries the signature as a `comptime` constant and a `ser` method that
//! appends the three strings to a message body. `docs/12` section 11 records
//! this substitution: a hand-written marshal per wire type, checked against
//! recorded bytes. `docs/12` section 9.1 records the same choice for a body the
//! library cannot marshal.
//!
//! **Wire layout.** The D-Bus specification, section "Byte order and
//! alignment", says a struct starts on an 8-byte boundary and that each of its
//! members is then aligned naturally. A `STRING` is 4-aligned, and its length
//! counts the bytes and not the trailing nul, so each member occupies
//! `4 + len + 1` bytes plus the padding that aligns the next one. The pad
//! between two members is not optional: a struct whose members were packed
//! without it decodes into a peer that reads every string one field late.

const std = @import("std");

/// One entry of the `GetActions` reply: a name, a description and a key binding.
///
/// The wire type is `(sss)`. Upstream `action.rs:10-13`.
pub const Action = struct {
    /// The wire signature of `Action`, and of each element of the `a(sss)`
    /// array `GetActions` returns.
    pub const signature: [:0]const u8 = "(sss)";

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

    /// Appends the three strings in the order `localized_name`, `description`,
    /// `key_binding`.
    ///
    /// The struct is eight-aligned; each member is a D-Bus string, which is a
    /// four-aligned length, the bytes and a NUL. The bytes are appended to
    /// `out`, which the caller owns and releases.
    ///
    /// **Errors.** `error.OutOfMemory` from `out`.
    pub fn ser(
        self: Action,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(u8),
    ) std.mem.Allocator.Error!void {
        try padTo(8, gpa, out);
        try writeString(gpa, out, self.localized_name);
        try writeString(gpa, out, self.description);
        try writeString(gpa, out, self.key_binding);
    }
};

/// The wire signature of the whole `GetActions` reply, which is an array of one
/// `Action` per element.
pub const get_actions_reply_signature: [:0]const u8 = "a(sss)";

comptime {
    // `(sss)` names three strings and the reply is one triple per element, so
    // the reply signature is the element signature with `a` in front of it.
    // Written as two constants, they drift apart the moment a member is added,
    // and only the reply is what a client checks.
    const fields = @typeInfo(Action).@"struct".fields;
    if (fields.len != 3) {
        @compileError("the (sss) signature names exactly three members");
    }
    for (fields) |field| {
        if (field.type != []const u8) {
            @compileError("every (sss) member is a borrowed byte slice");
        }
    }
    if (!std.mem.eql(u8, get_actions_reply_signature, "a" ++ Action.signature)) {
        @compileError("the GetActions reply is an array of the element signature");
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
    comptime alignment: usize,
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
) std.mem.Allocator.Error!void {
    if (alignment != 4 and alignment != 8) {
        @compileError("a D-Bus struct is 8-aligned and a string is 4-aligned");
    }
    const missing = alignment - (out.items.len % alignment);
    if (missing == alignment) return;
    try out.appendNTimes(gpa, 0, missing);
}

/// Appends one D-Bus string: four-aligned, a `u32` byte count, the bytes, a
/// NUL.
///
/// The length counts the bytes and not the NUL, and the NUL is part of the
/// encoding. The padding before a string is the padding the specification
/// requires and the padding after the NUL belongs to the value that follows.
///
/// `object_address.zig` carries its own copy of these lines. `docs/41` section
/// 2.3 gives the two modules no edge, so the helper is written twice rather
/// than hoisted.
///
/// **Errors.** `error.OutOfMemory` from `out`.
fn writeString(
    gpa: std.mem.Allocator,
    out: *std.ArrayList(u8),
    bytes: []const u8,
) std.mem.Allocator.Error!void {
    try padTo(4, gpa, out);
    var header: [4]u8 = undefined;
    // A D-Bus string length is a `u32`. No action name, description or key
    // binding comes near four gigabytes, and truncating instead would put a
    // length on the wire that does not match the bytes behind it.
    std.mem.writeInt(u32, &header, @intCast(bytes.len), .little);
    try out.appendSlice(gpa, &header);
    try out.appendSlice(gpa, bytes);
    try out.append(gpa, 0);
}

/// Reads the D-Bus string that begins at `offset`, which is how a peer walks a
/// `(sss)`.
fn readString(body: []const u8, offset: usize) []const u8 {
    const len = std.mem.readInt(u32, body[offset..][0..4], .little);
    return body[offset + 4 ..][0..len];
}

/// Reads the `u32` length that begins at `offset`, which is the first four
/// bytes of a D-Bus string and so the field a wrong alignment shows first.
fn stringLengthAt(body: []const u8, offset: usize) u32 {
    return std.mem.readInt(u32, body[offset..][0..4], .little);
}

/// Writes one triple into a body this helper owns.
///
/// **Errors.** `error.OutOfMemory` from the body.
fn writeEmptyAction(gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);
    try Action.init("", "", "").ser(gpa, &body);
}

test "Action marshals as (sss)" {
    try std.testing.expectEqualStrings("(sss)", Action.signature);
}

test "the reply signature is one Action per element" {
    // An array prefixes the element signature with `a`, which is what
    // `GetActions` puts in its reply.
    try std.testing.expectEqualStrings("a(sss)", get_actions_reply_signature);
}

test "the three strings reach the wire in the order name, description, binding" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try Action.init("click", "", "Alt+C").ser(gpa, &body);

    // The struct alignment is satisfied at body offset zero, so the first
    // string starts at zero. Each member is then four-aligned, which moves the
    // empty description from ten to twelve and the binding from fifteen to
    // twenty: "click" is 4 + 5 + 1, the description is 2 + 4 + 0 + 1, and
    // "Alt+C" is 3 + 4 + 5 + 1. Thirty bytes in all.
    try std.testing.expectEqual(@as(usize, 30), body.items.len);
    try std.testing.expectEqualStrings("click", readString(body.items, 0));
    try std.testing.expectEqualStrings("", readString(body.items, 12));
    try std.testing.expectEqualStrings("Alt+C", readString(body.items, 20));
}

test "each member carries its own length and the pad before it" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try Action.init("click", "", "Alt+C").ser(gpa, &body);

    // "click" is 4 + 5 + 1 = 10 bytes and so ends at ten, which is two bytes
    // short of the description's four-byte alignment. The description is 4 + 0 +
    // 1 = 5 bytes and ends at seventeen, three bytes short of the binding's
    // alignment. A port that packed the members wrote 25 bytes with the
    // description at ten and the binding at fifteen, and a peer that walks the
    // packed offsets reads a length out of the pad instead of the string.
    try std.testing.expectEqual(@as(u32, 5), stringLengthAt(body.items, 0));
    try std.testing.expectEqual(@as(u8, 0), body.items[9]);
    try std.testing.expectEqual(@as(u8, 0), body.items[10]);
    try std.testing.expectEqual(@as(u8, 0), body.items[11]);
    try std.testing.expectEqual(@as(u32, 0), stringLengthAt(body.items, 12));
    try std.testing.expectEqual(@as(u8, 0), body.items[16]);
    try std.testing.expectEqual(@as(u32, 5), stringLengthAt(body.items, 20));
    try std.testing.expectEqualStrings("Alt+C", body.items[24..29]);
}

test "a peer reading the reply takes all three strings back in wire order" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try Action.init("click", "Presses", "").ser(gpa, &body);

    // "click" is 4 + 5 + 1 = 10 bytes and so ends at ten, which is two bytes
    // short of the description's four-byte alignment. "Presses" is
    // 4 + 7 + 1 = 12 bytes and so runs from twelve to twenty-four, and
    // twenty-four is already aligned, so the empty binding starts there.
    try std.testing.expectEqualStrings("click", readString(body.items, 0));
    try std.testing.expectEqualStrings("Presses", readString(body.items, 12));
    try std.testing.expectEqualStrings("", readString(body.items, 24));
}

test "a triple that follows an odd member starts on the next eight-byte boundary" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendSlice(gpa, "ab");
    try Action.init("a", "b", "c").ser(gpa, &body);

    // Two bytes precede the triple, so the struct pads to eight. Each
    // single-character string then takes 4 + 1 + 1 = 6 bytes and leaves the body
    // two bytes short of the next four-byte alignment, so each of the three
    // members is followed by a two-byte pad: eight, sixteen and twenty-four, and
    // thirty bytes in all.
    try std.testing.expectEqual(@as(usize, 30), body.items.len);
    try std.testing.expectEqualStrings("a", readString(body.items, 8));
    try std.testing.expectEqualStrings("b", readString(body.items, 16));
    try std.testing.expectEqualStrings("c", readString(body.items, 24));
}

test "an already aligned body takes no padding at all" {
    const gpa = std.testing.allocator;
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(gpa);

    try body.appendNTimes(gpa, 0, 8);
    try Action.init("a", "b", "c").ser(gpa, &body);

    // The body was already eight-aligned, so the triple starts where the
    // previous member ended and the struct pad is absent. A `padTo` that always
    // padded would add eight bytes here and a peer would read it one alignment
    // late.
    try std.testing.expectEqual(@as(usize, 30), body.items.len);
    try std.testing.expectEqualStrings("a", readString(body.items, 8));
    try std.testing.expectEqualStrings("c", readString(body.items, 24));
}

test "every allocation failure of ser is reported and never swallowed" {
    // `ser` writes into a body the caller owns, so a failure leaves whatever was
    // already written in place and the caller releases it. What must not happen
    // is a swallowed failure, so the sweep fails one allocation at a time up to
    // the first that succeeds.
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        writeEmptyAction,
        .{},
    );
}
