//! The adapter's error set and its map onto D-Bus error replies.
//!
//! **Upstream.** `accesskit_atspi_common/src/error.rs:8-33` declares the
//! six-member `Error` set and its `Display` impl; `accesskit_unix/src/util.rs:26-38`
//! is `map_error`, the only place an internal error becomes a D-Bus error, and
//! `util.rs:40-42` is `map_error_from_node`, which forwards through it.
//! `docs/41-atspi-build-map.md` section 1.9 is the checked table of the five
//! names that reach the wire.
//!
//! **What this module owns.** The six member errors, the three transport errors
//! and the predicate over them, the five D-Bus error names, and the text each
//! carries. No other module may name `org.freedesktop.DBus.Error.*` except the
//! dispatch layer, which is what puts a name on the wire and does not exist yet.
//!
//! **Why the source is a path and not an `ObjectId`.** `docs/41` section 2.3
//! puts `object_id.zig` below every other module and gives `error.zig` no
//! import edge. Naming `ObjectId` in a parameter would add one and make the two
//! modules mutually reachable in ownership terms. So `mapError` takes the
//! object's own path, which is all upstream's `UnknownObject` arm uses, and
//! `mapErrorFromNode` takes anything with a `path` method as an `anytype`
//! parameter. A generic parameter is not an import edge, so the graph the build
//! map states still holds.
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
/// carries a negative index; the interface modules `docs/41` schedules name it
/// for those two sites, and they do not exist yet.
pub const error_invalid_args: [:0]const u8 = "org.freedesktop.DBus.Error.InvalidArgs";

/// The D-Bus error name an unimplemented member produces, at `document.rs:10-12`,
/// `editable_text.rs:10-12` and `image.rs:31-33`. The interface modules
/// `docs/41` schedules name it for those three sites, and they do not exist yet.
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
        error.TooManyCharacters => .{
            .name = error_failed,
            .message = message_too_many_characters,
        },
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
/// keeps `docs/41` section 2.3 free of an import edge, so the caller is an
/// interface module or the dispatch layer and neither imports the other. Those
/// modules do not exist yet.
///
/// `source` must answer `path() []const u8`. `Node` and `Root` at the
/// `node.zig` that `docs/41` schedules both do.
///
/// **Errors.** This function does not fail.
pub fn mapErrorFromNode(source: anytype, err: Error) DbusError {
    return mapError(source.path(), err);
}

/// The three failures a call on the accessibility bus can report.
///
/// Upstream classifies a `zbus::Error` at `bus.rs:505-510`, which is a foreign
/// enum this port never names. `docs/12:1392` requires the surviving cases to be
/// members of a declared set, so a comptime sweep over `@typeInfo` proves that
/// every path is handled, and it names the three: `BusUnavailable`,
/// `InterfaceExists` and `MissingParameter`.
///
/// **Why it is declared after the member-error map.** `Error`, `DbusError`,
/// `mapError` and `mapErrorFromNode` sit at the lines the translation ledger
/// records for them, and `docs/35` section 1.3 makes the disposition the whole
/// claim of a row. Inserting above them would move four cited lines for no gain.
/// Read the two sets as a pair: this one answers whether a call may be
/// swallowed, and the other answers what a member that answered writes.
///
/// **Who raises a member.** The bus connection and the object register arrive
/// with milestone M5, at `docs/40-plan.md:256`. Until then nothing in this
/// adapter performs a call, so nothing raises these three.
pub const BusError = error{
    /// The accessibility bus is not reachable, or the socket it lives on is
    /// gone. Recoverable: the adapter drops the bus and waits for
    /// `org.a11y.Status` to report `IsEnabled` again.
    BusUnavailable,
    /// A name this adapter asked the bus daemon to own already belongs to
    /// someone else. Not recoverable: asking again asks for the same name.
    InterfaceExists,
    /// A method call arrived without one of its arguments. Not recoverable: the
    /// peer sent the message, and no reply makes it send a different one.
    MissingParameter,
};

/// Whether `err` has to reach the caller rather than be replaced by a default.
///
/// **Upstream.** `zbus_error_is_unrecoverable` at `bus.rs:505-510`, whose
/// `matches!` names exactly `InterfaceExists` and `MissingParameter` and
/// answers `false` for everything else. `docs/12:1051` gives this the name
/// `isUnrecoverable` with no host dependency, and `docs/41:1269` merges it into
/// this module.
///
/// **The contract.** The answer is `true` for the two members the upstream
/// `matches!` names and `false` for every other member of `BusError`, which is
/// today `BusUnavailable` alone. The `else` arm is the default arm
/// `docs/12:1392` asks for: a member added later is recoverable until someone
/// writes the arm that says otherwise, and the sweep in the test below names
/// every member so the addition cannot pass unseen.
///
/// **Errors.** This function does not fail and allocates nothing.
pub fn isUnrecoverable(err: BusError) bool {
    return switch (err) {
        error.InterfaceExists, error.MissingParameter => true,
        else => false,
    };
}

/// Applies `apply` to `result`, or substitutes `default` when `result` holds
/// a recoverable failure.
///
/// This is `map_or_ignoring_recoverable_error` at `bus.rs:512-525`, whose
/// three arms are `bus.rs:521-523`. `docs/12:1052` gives it the name
/// `orDefault` with no host dependency, and `docs/41` section 7 records the
/// disposition as a `catch` into the declared set.
///
/// **The contract.** `Ok` becomes `apply`'s answer. An unrecoverable failure
/// reaches the caller unchanged, because asking again asks the same question.
/// Every other failure becomes `default`, because the alternative is dropping
/// a call the adapter cannot make. `apply` runs on the `Ok` arm alone, which
/// is the property `bus.rs:521` states and the property the test below pins.
///
/// **The classification is `isUnrecoverable`, not a second switch here.** The
/// two are one decision written once, so a member added to `BusError` reaches
/// both or neither.
///
/// `apply` is a `fn (T) U` and not a closure that captures, because `AGENTS.md`
/// section 2 requires the state a step reads to be a parameter. A captured
/// counter would hide which failures ran it.
///
/// **Why this function carries no caller yet.** Its five upstream call sites
/// are the four `emit_*` arms and the register and remove path, at
/// `bus.rs:187`, `:249`, `:467`, `:489` and `:279`. Every one of them is a
/// call on a `zbus::Connection`, and `build.zig.zon` declares `zio` and
/// `win32` and no D-Bus client, so no module under `src/` holds a connection.
/// That is a missing dependency in the manifest, not a missing host: this host
/// has `/usr/include/dbus-1.0/dbus/dbus.h` and `pkg-config dbus-1` at
/// 1.14.10, so the port takes the connection under milestone M5.
///
/// **Errors.** `BusError`, on the unrecoverable arm alone.
pub fn orDefault(
    comptime T: type,
    comptime U: type,
    result: BusError!T,
    default: U,
    apply: fn (T) U,
) BusError!U {
    const value = result catch |err| {
        if (isUnrecoverable(err)) return err;
        return default;
    };
    return apply(value);
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
        .error_set => |set| set.error_names orelse return error.EmptyErrorSet,
        else => return error.NotAnErrorSet,
    };
    try testing.expectEqual(@as(usize, 6), members.len);

    // Each member is named here by its own line, so a test failure names the
    // member rather than a line number in the switch above.
    try testing.expectEqual(error_unknown_object, mapError("/p", error.Defunct).name);
    try testing.expectEqual(error_unknown_object, mapError("/p", error.UnsupportedInterface).name);
    try testing.expectEqualStrings(
        "Too many children.",
        mapError("/p", error.TooManyChildren).message,
    );
    try testing.expectEqualStrings(
        "Index is too big.",
        mapError("/p", error.IndexOutOfRange).message,
    );
    try testing.expectEqualStrings(
        "Too many characters.",
        mapError("/p", error.TooManyCharacters).message,
    );
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

// The transport set gets the same sweep `AGENTS.md` section 3 asks for. The
// predicate is total, so every member reaches it; the count pins the set, and
// naming each member on its own line is what makes a failure name the member
// rather than a line in the switch above. A fourth member added later fails the
// count here rather than falling silently into the default arm.
test "the transport set names three members and the sweep reaches every one" {
    const members = switch (@typeInfo(BusError)) {
        .error_set => |set| set.error_names orelse return error.EmptyErrorSet,
        else => return error.NotAnErrorSet,
    };
    try testing.expectEqual(@as(usize, 3), members.len);

    try testing.expect(!isUnrecoverable(error.BusUnavailable));
    try testing.expect(isUnrecoverable(error.InterfaceExists));
    try testing.expect(isUnrecoverable(error.MissingParameter));
}

test "the reference matches two of the three and the third takes the default arm" {
    // Upstream `bus.rs:506-509` is
    // `matches!(error, InterfaceExists(..) | MissingParameter(..))`, so two of
    // the three members are unrecoverable and the third reaches the `else` arm
    // this predicate writes. The count is the claim: a change that swallowed all
    // three, or none, gives a different number and fails here.
    const members = [_]BusError{
        error.BusUnavailable,
        error.InterfaceExists,
        error.MissingParameter,
    };
    var unrecoverable_count: usize = 0;
    for (members) |member| {
        if (isUnrecoverable(member)) unrecoverable_count += 1;
    }
    try testing.expectEqual(@as(usize, 2), unrecoverable_count);

    // The two names the reference names, and the one it does not.
    try testing.expect(isUnrecoverable(error.InterfaceExists));
    try testing.expect(isUnrecoverable(error.MissingParameter));
    try testing.expect(!isUnrecoverable(error.BusUnavailable));
}

/// The mapper the two arms below share. `bus.rs:521` passes the whole `T`
/// through `f`, so a value that is not the identity proves the mapper ran and
/// a value that is the identity proves it did not.
fn doubled(value: i32) i32 {
    return value * 2;
}

test "the Ok arm runs the mapper and the recoverable arm does not" {
    // `bus.rs:521` is `Ok(result) => Ok(f(result))`, so the mapped value is
    // the answer and the default never appears.
    try testing.expectEqual(
        @as(i32, 84),
        try orDefault(i32, i32, @as(BusError!i32, 42), 0, doubled),
    );

    // `bus.rs:523` is `Err(_) => Ok(default)`. `BusUnavailable` is the one
    // recoverable member, and the default below is a value `doubled` cannot
    // produce from any `T` the caller passes, so an answer of 7 proves the
    // mapper was skipped.
    try testing.expectEqual(
        @as(i32, 7),
        try orDefault(i32, i32, error.BusUnavailable, 7, doubled),
    );
}

test "the unrecoverable arm reaches the caller and skips the default" {
    // `bus.rs:522` is `Err(error) if zbus_error_is_unrecoverable(&error) =>
    // Err(error)`. Both members it names are checked, and each is compared by
    // identity against the tag it must carry, so an `orDefault` that returned
    // the default for either one fails here rather than passing on the count.
    try testing.expectError(error.InterfaceExists, orDefault(
        i32,
        i32,
        error.InterfaceExists,
        7,
        doubled,
    ));
    try testing.expectError(error.MissingParameter, orDefault(
        i32,
        i32,
        error.MissingParameter,
        7,
        doubled,
    ));
}

test "the sweep reaches every member and pins which arm each one takes" {
    // The three arms of `bus.rs:521-523` cover every member of the set, so the
    // sweep is over the members themselves rather than over a sample. Each
    // row names the arm its member must take, and a member added later has no
    // row, which is what makes this test fail.
    const cases = [_]struct {
        err: BusError,
        recoverable: bool,
        named: [:0]const u8,
    }{
        .{
            .err = error.BusUnavailable,
            .recoverable = true,
            .named = "BusUnavailable",
        },
        .{
            .err = error.InterfaceExists,
            .recoverable = false,
            .named = "InterfaceExists",
        },
        .{
            .err = error.MissingParameter,
            .recoverable = false,
            .named = "MissingParameter",
        },
    };
    try testing.expectEqual(@as(usize, 3), cases.len);

    inline for (cases) |case| {
        try testing.expectEqual(
            !case.recoverable,
            isUnrecoverable(case.err),
        );
        // The default below is 7 and the mapper below doubles, so an answer of
        // 14 means the mapper ran on a failure and an answer of 7 means it did
        // not. `bus.rs:521` runs it on the `Ok` arm alone.
        const answer = orDefault(i32, i32, case.err, 7, doubled) catch |err| blk: {
            try testing.expectEqual(case.err, err);
            break :blk @as(i32, 0);
        };
        if (case.recoverable) {
            try testing.expectEqual(@as(i32, 7), answer);
        } else {
            try testing.expectEqual(@as(i32, 0), answer);
        }
        // The name is read so a renamed member fails the sweep rather than
        // silently leaving the table one row short of the set.
        try testing.expectEqualStrings(case.named, @errorName(case.err));
        try testing.expect(case.named.len > 0);
    }
}
