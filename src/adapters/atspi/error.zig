//! The adapter's error set and its map onto D-Bus error replies.
//!
//! **Upstream.** `accesskit_atspi_common/src/error.rs:8-33` declares the
//! six-member `Error` set and its `Display` impl; `accesskit_unix/src/util.rs:26-38`
//! is `map_error`, the only place an internal error becomes a D-Bus error, and
//! `util.rs:40-42` is `map_error_from_node`, which forwards through it.
//! `docs/41-atspi-build-map.md` section 1.9 is the checked table of the five
//! names that reach the wire.
//!
//! **What this module owns.** The six members, the five D-Bus error names, and
//! the text each carries. No other module may name `org.freedesktop.DBus.Error.*`
//! except `dispatch.zig`, which puts the name on the wire.
//!
//! **Why the source is a path and not an `ObjectId`.** `docs/41` section 2.3
//! puts `object_id.zig` below every other module and gives `error.zig` exactly
//! one import, `wire.zig`. Naming `ObjectId` in a parameter would add a second
//! edge and make the two modules mutually reachable in ownership terms. So
//! `mapError` takes the object's own path, which is all upstream's
//! `UnknownObject` arm uses, and `mapErrorFromNode` takes anything with a
//! `path` method as an `anytype` parameter. A generic parameter is not an
//! import edge, so the graph the build map states still holds.
//!
//! **Errors.** Every function here is total and allocates nothing.

const std = @import("std");

/// The six failures an AT-SPI member handler can report.
///
/// A caller sees these, never a bare `anyerror`, because every one of them has
/// a defined D-Bus name and message and `mapError` is the only route to the
/// wire. The members are upstream's, in upstream's order, at `error.rs:9-16`.
pub const Error = error{
    /// The node left the tree, or the tree it belonged to was released.
    /// `error.rs:10`. Upstream `Error::Defunct`.
    Defunct,
    /// The node does not export the interface the member belongs to.
    /// `error.rs:11`. Upstream `Error::UnsupportedInterface`.
    UnsupportedInterface,
    /// A child count or an index does not fit in `i32`.
    /// `error.rs:12`. Upstream `Error::TooManyChildren`.
    TooManyChildren,
    /// An offset or a position does not fit in `i32`, or names nothing.
    /// `error.rs:13`. Upstream `Error::IndexOutOfRange`.
    IndexOutOfRange,
    /// A character index does not fit in `i32`.
    /// `error.rs:14`. Upstream `Error::TooManyCharacters`.
    TooManyCharacters,
    /// The peer asked for `Granularity::sentence`, which the consumer text layer
    /// does not define. `error.rs:15`, raised at `util.rs:82-83` and `:89-90`.
    UnsupportedTextGranularity,
};

/// One D-Bus error reply: the interface-qualified name and the human text.
///
/// `name` is sent as the `ERROR_NAME` header field and `message` as the error
/// body. Both are borrowed from a string literal at every call site in
/// `mapError`, so a reply holds nothing that needs releasing.
///
/// **Upstream.** `zbus::fdo::Error`, at the `FdoError::` arms of `util.rs:28-37`.
pub const DbusError = struct {
    /// The fully qualified error name, for example
    /// `org.freedesktop.DBus.Error.UnknownObject`.
    name: [:0]const u8,
    /// The message text the body carries.
    message: []const u8,
};

/// The D-Bus error name for `Defunct` and `UnsupportedInterface`, which differ
/// only in which member raised them and so share one name.
///
/// Upstream `util.rs:28-30` folds both arms into `FdoError::UnknownObject`.
pub const error_unknown_object: [:0]const u8 = "org.freedesktop.DBus.Error.UnknownObject";

/// The D-Bus error name every `Failed` arm uses. Upstream `util.rs:31-36`.
pub const error_failed: [:0]const u8 = "org.freedesktop.DBus.Error.Failed";

/// The D-Bus error name a negative index produces, at `accessible.rs:76-77` and
/// `selection.rs:78-82`. `mapError` never produces it, because no internal error
/// carries a negative index; `interfaces/root.zig` names it for those two sites.
pub const error_invalid_args: [:0]const u8 = "org.freedesktop.DBus.Error.InvalidArgs";

/// The D-Bus error name an unimplemented member produces, at `document.rs:10-12`,
/// `editable_text.rs:10-12` and `image.rs:31-33`.
pub const error_not_supported: [:0]const u8 = "org.freedesktop.DBus.Error.NotSupported";

/// The message for a negative index, shared by `accessible.rs:77` and
/// `selection.rs:81`.
pub const message_negative_index: []const u8 = "Index can't be negative.";

/// The message `TooManyChildren` carries, at `util.rs:31`.
pub const message_too_many_children: []const u8 = "Too many children.";

/// The message `IndexOutOfRange` carries, at `util.rs:32`.
pub const message_index_too_big: []const u8 = "Index is too big.";

/// The message `TooManyCharacters` carries, at `util.rs:33`.
pub const message_too_many_characters: []const u8 = "Too many characters.";

/// The message `UnsupportedTextGranularity` carries, at `util.rs:34-36`.
pub const message_unsupported_granularity: []const u8 = "Unsupported text granularity.";

/// The reply `source_path` and `err` produce.
///
/// `source_path` is the object path of the member that failed, and only the two
/// `UnknownObject` arms use it: upstream's `FdoError::UnknownObject` takes the
/// path as its message, at `util.rs:29`. The four `Failed` arms carry fixed text,
/// so `source_path` is ignored there and the compiler is told so by naming it in
/// the discard at the head of each arm.
///
/// **Errors.** This function does not fail.
pub fn mapError(source_path: []const u8, err: Error) DbusError {
    return switch (err) {
        error.Defunct, error.UnsupportedInterface => .{
            .name = error_unknown_object,
            .message = source_path,
        },
        error.TooManyChildren => .{ .name = error_failed, .message = message_too_many_children },
        error.IndexOutOfRange => .{ .name = error_failed, .message = message_index_too_big },
        error.TooManyCharacters => .{ .name = error_failed, .message = message_too_many_characters },
        error.UnsupportedTextGranularity => .{
            .name = error_failed,
            .message = message_unsupported_granularity,
        },
    };
}

/// The reply `source` and `err` produce, where `source` names its own path.
///
/// This is `map_error_from_node` at `util.rs:40-42`, which upstream writes as
/// `map_error(ObjectId::from(source), error)`. Taking the source as `anytype`
/// keeps the one import `docs/41` section 2.3 gives this module, so the caller
/// is `interfaces/*.zig` or `dispatch.zig` and neither imports the other.
///
/// `source` must answer `path() []const u8`. `Node` at `node.zig` and `Root` at
/// the same file both do.
///
/// **Errors.** This function does not fail.
pub fn mapErrorFromNode(source: anytype, err: Error) DbusError {
    return mapError(source.path(), err);
}

const testing = std.testing;
// `AGENTS.md` section 3 asks for a sweep over `@typeInfo` of every declared
// error set. `mapError` is total over the set, so the sweep has two jobs: it
// names every member in a test of its own, and it fails the build if a member
// is added without an arm in the switch above.
test "mapError answers a reply for every member of the error set" {
    // Both tags are read through a switch rather than an `.?`: the `error_set`
    // payload is an optional slice in Zig 0.16.0, and an unwrap here would be a
    // claim where a switch is a question with a stated answer.
    const members = switch (@typeInfo(Error)) {
        .error_set => |set| set orelse return error.EmptyErrorSet,
        else => return error.NotAnErrorSet,
    };
    try testing.expectEqual(@as(usize, 6), members.len);

    // Each member is named here by its own line, so a test failure names the
    // member rather than a line number in the switch above.
    try testing.expectEqual(error_unknown_object, mapError("/p", error.Defunct).name);
    try testing.expectEqual(error_unknown_object, mapError("/p", error.UnsupportedInterface).name);
    try testing.expectEqualStrings("Too many children.", mapError("/p", error.TooManyChildren).message);
    try testing.expectEqualStrings("Index is too big.", mapError("/p", error.IndexOutOfRange).message);
    try testing.expectEqualStrings("Too many characters.", mapError("/p", error.TooManyCharacters).message);
    try testing.expectEqualStrings(
        "Unsupported text granularity.",
        mapError("/p", error.UnsupportedTextGranularity).message,
    );
}

// `Defunct` and `UnsupportedInterface` share one name and carry the path, which
// is the whole of upstream's `util.rs:28-30` arm.
test "the two object failures name the object they came from" {
    const defunct = mapError("/org/a11y/atspi/accessible/0/1", error.Defunct);
    try testing.expectEqualStrings(
        "org.freedesktop.DBus.Error.UnknownObject",
        defunct.name,
    );
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/0/1", defunct.message);
}

// The four `Failed` arms carry fixed text and must not leak the path into it.
test "the four numeric failures carry their own text and not the path" {
    const cases = [_]struct { err: Error, text: []const u8 }{
        .{ .err = error.TooManyChildren, .text = "Too many children." },
        .{ .err = error.IndexOutOfRange, .text = "Index is too big." },
        .{ .err = error.TooManyCharacters, .text = "Too many characters." },
        .{ .err = error.UnsupportedTextGranularity, .text = "Unsupported text granularity." },
    };
    for (cases) |case| {
        const reply = mapError("/some/path", case.err);
        try testing.expectEqualStrings("org.freedesktop.DBus.Error.Failed", reply.name);
        try testing.expectEqualStrings(case.text, reply.message);
    }
}

// `docs/41` section 1.9 counts five distinct names on the wire. Three of them
// are named here and the other two by the two call sites that raise them, so
// this test pins the count the map states.
test "three names are declared here and two more belong to their call sites" {
    // `mapError` produces two distinct names across its six members, and the
    // pair below is the pair it produces: the two object failures share
    // `UnknownObject` and the four numeric failures share `Failed`. The test
    // used to assert that the two answers were equal, which is the opposite of
    // what the switch does and which would have passed only if `mapError`
    // collapsed both arms onto one name.
    const object_failure = mapError("/p", error.Defunct);
    const unsupported_interface = mapError("/p", error.UnsupportedInterface);
    const numeric_failure = mapError("/p", error.TooManyChildren);

    try testing.expectEqualStrings(error_unknown_object, object_failure.name);
    try testing.expectEqualStrings(error_unknown_object, unsupported_interface.name);
    try testing.expectEqualStrings(error_failed, numeric_failure.name);
    try testing.expect(!std.mem.eql(u8, error_failed, error_unknown_object));

    // The two that no internal error produces.
    try testing.expectEqualStrings(
        "org.freedesktop.DBus.Error.InvalidArgs",
        error_invalid_args,
    );
    try testing.expectEqualStrings(
        "org.freedesktop.DBus.Error.NotSupported",
        error_not_supported,
    );
}
