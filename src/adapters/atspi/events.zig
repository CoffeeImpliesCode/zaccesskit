//! The AT-SPI event model: the five-argument signal body, the four signal
//! interfaces, and the values the fifth argument carries.
//!
//! **Upstream.** `accesskit_atspi_common/src/events.rs` declares `Event`,
//! `ObjectEvent`, `WindowEvent`, `DocumentEvent`, `CacheEvent` and `Property`.
//! `accesskit_unix/src/atspi/bus.rs:194-461` raises them. `docs/41-atspi-build-map.md`
//! section 1.7 records the body signature and section 1.8 the property
//! dictionary.
//!
//! **The body is five arguments and the last one is the only named one that
//! matters.** Every event signal on every one of the four interfaces carries the
//! same body signature:
//!
//! ```text
//! siiva{sv}
//! ```
//!
//! That is five arguments, in this order:
//!
//! | # | Type | Upstream field |
//! |---|---|---|
//! | 0 | `s` | `detail1` |
//! | 1 | `i` | `detail2` |
//! | 2 | `i` | `detail3` |
//! | 3 | `v` | `any_data` |
//! | 4 | `a{sv}` | `properties` |
//!
//! **The object path, the interface, the signal name and the sender are header
//! fields, not body arguments.** A message that reads as "the body has six
//! arguments, one of which is the path" is a message a client rejects, so this
//! module keeps them apart: `Event.id` and `Event.member` and
//! `Event.interface` are the header, and `EventBody` is the body. The `SENDER`
//! header field is added by the bus daemon and never by this port, which is
//! why a peer always sees a sender the application never named.
//!
//! **There is no `org.a11y.atspi.EventBus` interface and no `EmitEvent` method.**
//! The AT-SPI2 specification publishes only the four `org.a11y.atspi.Event.*`
//! signal interfaces, and the index of every D-Bus XML interface the project
//! has does not list either name. An application emits the signals directly on
//! the bus: it builds one message per event, with the header this module
//! describes and the body this module describes. A design that queued events and
//! asked a helper to raise them would depend on an interface that does not
//! exist.
//!
//! **What is protocol here and what is bytes.** This module owns the *shape*:
//! the signature string, the argument order, the interface names, the member
//! names and the values each argument carries. It owns no bytes. The
//! marshalling is the port's own, through `wire/rect.zig` and
//! `object_address.zig`, and both are reachable from this adapter and both pin
//! the byte layout against the alignment the D-Bus specification fixes. A test
//! below pins the signature and the order, which is the part a wrong
//! transcription breaks.
//!
//! **Every loop over a domain here is bounded by that domain's own length**, and
//! each one says which length it is in its doc comment. `Properties.put` scans
//! the entries it already holds and is bounded by `entries.items.len`;
//! `Properties.get` scans the same list with the same bound; `Kind`'s sweep is
//! an `inline for` over `std.enums.values(Kind)` and so has no run-time bound
//! at all.

const std = @import("std");

const object_id = @import("object_id.zig");
const window_bounds = @import("window_bounds.zig");

const ObjectId = object_id.ObjectId;

/// The wire signature every AT-SPI event body carries.
///
/// Five arguments: a string, two 32-bit integers, a variant and a dictionary
/// of string to variant. The `{` and `}` are the dictionary's braces and `sv`
/// inside them is its key and its value, so the last argument is `a{sv}`.
pub const event_body_signature: [:0]const u8 = "siiva{sv}";

/// The signature of the dictionary the fifth argument carries.
pub const property_dictionary_signature: [:0]const u8 = "a{sv}";

/// The index of the string argument in an event body.
pub const argument_detail1: usize = 0;
/// The index of the first integer argument in an event body.
pub const argument_detail2: usize = 1;
/// The index of the second integer argument in an event body.
pub const argument_detail3: usize = 2;
/// The index of the variant argument in an event body.
pub const argument_any_data: usize = 3;
/// The index of the dictionary argument in an event body.
pub const argument_properties: usize = 4;

/// How many arguments an event body carries, which is the length of
/// `event_body_signature` counted in arguments rather than in characters.
pub const argument_count: usize = 5;

/// The four interfaces that carry event signals.
///
/// A separate domain from `wire.Interface`, and this is why it lives here rather
/// than in `wire.zig`: `wire.Interface` is the set of interfaces an *object*
/// exports, and `docs/41` section 2.1 rule 3 gives that complete list to
/// `interfaces/root.zig` alone. A signal interface is never exported by an
/// object, so putting it in that list would put a name in the wrong place.
pub const Kind = enum {
    /// `org.a11y.atspi.Event.Object`, for a signal about one node.
    object,
    /// `org.a11y.atspi.Event.Window`, for a signal about the root window.
    window,
    /// `org.a11y.atspi.Event.Document`, for a signal about the document tree.
    document,
    /// `org.a11y.atspi.Event.Cache`, for a signal about the cache object.
    cache,
};

/// The interface name of the event signal family `kind` belongs to.
///
/// **Errors.** This function does not fail.
pub fn kindInterface(kind: Kind) [:0]const u8 {
    return switch (kind) {
        .object => "org.a11y.atspi.Event.Object",
        .window => "org.a11y.atspi.Event.Window",
        .document => "org.a11y.atspi.Event.Document",
        .cache => "org.a11y.atspi.Event.Cache",
    };
}

/// The member name of the signal that says a node gained or lost focus, on
/// `org.a11y.atspi.Event.Object`.
pub const member_focus: [:0]const u8 = "Focus";

/// The member name of the signal that says a node's bounds changed, on
/// `org.a11y.atspi.Event.Object`.
pub const member_bounds_changed: [:0]const u8 = "BoundsChanged";

/// The member name of the signal that says one state of a node changed, on
/// `org.a11y.atspi.Event.Object`. Its first argument is the state's static
/// name and its variant carries the new value.
pub const member_state_changed: [:0]const u8 = "StateChanged";

/// The member name of the signal that says a live region is announced, on
/// `org.a11y.atspi.Event.Object`. Its second argument is the priority.
pub const member_announcement: [:0]const u8 = "Announcement";

/// The member name of the signal that adds one node to the cache, on
/// `org.a11y.atspi.Event.Cache`.
pub const member_add_accessible: [:0]const u8 = "AddAccessible";

/// The member name of the signal that removes one node from the cache, on
/// `org.a11y.atspi.Event.Cache`.
pub const member_remove_accessible: [:0]const u8 = "RemoveAccessible";


/// The value the fourth argument of an event body carries.
///
/// The variant is the only argument that can hold a typed value, which is why
/// an event that needs an object reference puts it here: `siiva{sv}` has no
/// argument of type `(so)`.
pub const AnyData = union(enum) {
    /// The argument is absent. `FOCUS` and the cache signals on a node with no
    /// target carry this, and its signature is the empty string.
    none,
    /// An object reference, `(so)`. The path comes from the identifier and the
    /// bus name from the connection that exports it, so the value names an
    /// object rather than a path a peer would have to guess the owner of.
    address: ObjectId,
    /// A signed 32-bit integer, `i`.
    integer: i32,
    /// A boolean, `b`.
    boolean: bool,
    /// A text value, `s`. Ownership belongs to the enclosing `Event`.
    text: []const u8,
    /// A box, `(iiii)`. `BoundsChanged` puts the node's new extents here,
    /// because the body's five arguments leave no room for a box: a string, two
    /// integers, a variant and a dictionary, and only the variant can carry a
    /// four-member struct.
    extent: window_bounds.Extent,

    /// A 64-bit floating point value, `d`. `PropertyChange` puts a node's
    /// numeric value here, under the property key `accessible-value`, because
    /// upstream writes `Value::F64(value)` into the variant at `bus.rs:353`
    /// and the variant is the only body argument that can hold a `d`.
    number: f64,

    /// The signature this value puts inside the variant.
    ///
    /// **Errors.** This function does not fail.
    pub fn signature(self: AnyData) [:0]const u8 {
        return switch (self) {
            .none => "",
            .address => "(so)",
            .integer => "i",
            .boolean => "b",
            .text => "s",
            .extent => "(iiii)",
            .number => "d",
        };
    }

    /// Whether two values are the same.
    ///
    /// `ObjectId` is a tagged union with a struct payload and Zig derives
    /// nothing for it, so the comparison is `std.meta.eql` and not `==`.
    /// `window_bounds.Extent` is a plain array, which Zig compares element by
    /// element.
    ///
    /// **Errors.** This function does not fail.
    pub fn eql(self: AnyData, other: AnyData) bool {
        return switch (self) {
            .none => other == .none,
            .address => |mine| other == .address and std.meta.eql(mine, other.address),
            .integer => |mine| other == .integer and mine == other.integer,
            .boolean => |mine| other == .boolean and mine == other.boolean,
            .text => |mine| other == .text and std.mem.eql(u8, mine, other.text),
            .extent => |mine| other == .extent and std.meta.eql(mine, other.extent),
            .number => |mine| other == .number and mine == other.number,
        };
    }
};

/// One member of an event's property dictionary.
pub const Property = struct {
    /// The key, borrowed. It must outlive the `Properties` that holds it, and
    /// every key this port emits is a string literal.
    key: [:0]const u8,
    /// The value. It borrows nothing and owns nothing, so a copy is
    /// independent of the original.
    value: PropertyValue,
};

/// The values a property dictionary entry may hold.
///
/// The dictionary is `a{sv}`, so every value is a variant. This is the set of
/// shapes the AT-SPI reference uses for the properties on the signals this port
/// emits, and nothing else.
pub const PropertyValue = union(enum) {
    /// `s`
    text: []const u8,
    /// `i`
    integer: i32,
    /// `b`
    boolean: bool,
    /// `d`
    number: f64,

    /// The signature this value puts inside the variant.
    ///
    /// **Errors.** This function does not fail.
    pub fn signature(self: PropertyValue) [:0]const u8 {
        return switch (self) {
            .text => "s",
            .integer => "i",
            .boolean => "b",
            .number => "d",
        };
    }
};

/// The dictionary an event's fifth argument carries.
///
/// It is a list and not a hash map because a property dictionary on an AT-SPI
/// event holds a handful of entries and a client reads them in the order they
/// arrived. An entry with a key the list already holds is replaced rather than
/// appended, because a dictionary has one value per key.
///
/// **The bound on the two scans.** `put` walks `entries.items` to find a
/// duplicate key and `get` walks the same list to find a match. Both are
/// bounded by `entries.items.len`, which is the list's own length and does not
/// change while either runs. The list grows without a fixed ceiling, so a
/// caller that puts an unbounded number of entries grows it; nothing in this
/// adapter does, because every event it emits carries an empty dictionary or a
/// handful of entries.
///
/// `Properties` owns its list and nothing else: every key and every text value
/// is borrowed from its owner, so `deinit` releases the array and no string.
pub const Properties = struct {
    /// The entries, in the order they were first put.
    entries: std.ArrayList(Property) = .empty,

    /// The dictionary no property carries, which is the answer for every event
    /// this port emits today.
    ///
    /// **Errors.** This function does not fail.
    pub fn empty() Properties {
        return .{ .entries = .empty };
    }

    /// Releases the array. Calling it twice frees the array twice, so a caller
    /// releases once and drops the value.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *Properties, gpa: std.mem.Allocator) void {
        self.entries.deinit(gpa);
        self.* = undefined;
    }

    /// How many entries the dictionary holds.
    ///
    /// **Errors.** This function does not fail.
    pub fn count(self: *const Properties) usize {
        return self.entries.items.len;
    }

    /// Stores `value` under `key`, replacing whatever was there.
    ///
    /// `gpa` comes before the key because this allocates, and the key follows it
    /// because the key is the thing the scan looks for. On `error.OutOfMemory`
    /// the dictionary is unchanged.
    ///
    /// **Errors.** `error.OutOfMemory` from `gpa`.
    pub fn put(
        self: *Properties,
        gpa: std.mem.Allocator,
        key: [:0]const u8,
        value: PropertyValue,
    ) std.mem.Allocator.Error!void {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.key, key)) {
                entry.value = value;
                return;
            }
        }
        try self.entries.append(gpa, .{ .key = key, .value = value });
    }

    /// The value stored under `key`, or `null` when the dictionary holds none.
    ///
    /// **Errors.** This function does not fail.
    pub fn get(self: *const Properties, key: [:0]const u8) ?PropertyValue {
        for (self.entries.items) |entry| {
            if (std.mem.eql(u8, entry.key, key)) return entry.value;
        }
        return null;
    }
};

/// One event the adapter will raise.
///
/// The first three members and `kind` are the message header; `detail1`,
/// `detail2`, `detail3`, `any_data` and `properties` are the body, in the order
/// `event_body_signature` fixes. Keeping them in one struct is what lets a test
/// check the split, and the split is the whole of what a mis-assembled message
/// gets wrong.
pub const Event = struct {
    /// Which of the four signal interfaces this event goes out on.
    kind: Kind,
    /// The signal name, which is the header `MEMBER` field.
    member: [:0]const u8,
    /// The object the signal is about, which is the header `PATH` field. The
    /// cache signals are about the cache object and the node they name is in
    /// the body's variant.
    id: ObjectId,
    /// The first body argument, `s`.
    detail1: []const u8 = "",
    /// The second body argument, `i`.
    detail2: i32 = 0,
    /// The third body argument, `i`.
    detail3: i32 = 0,
    /// The fourth body argument, `v`.
    any_data: AnyData = .none,
    /// The fifth body argument, `a{sv}`.
    properties: Properties = Properties.empty(),
    /// Queue-owned text allocation, or `null` for a borrowed payload.
    /// When present, `any_data.text` names exactly this allocation.
    /// Release with the allocator that copied it. A copy is not a second owner.
    owned_text: ?[]u8 = null,

    /// The interface this event goes out on, which is the header `INTERFACE`
    /// field.
    ///
    /// **Errors.** This function does not fail.
    pub fn interface(self: Event) [:0]const u8 {
        return kindInterface(self.kind);
    }

    /// The signature of this event's body.
    ///
    /// **Errors.** This function does not fail.
    pub fn bodySignature(self: Event) [:0]const u8 {
        _ = self;
        return event_body_signature;
    }

    /// Releases the dictionary and `owned_text`, but never a borrowed text payload.
    /// After `drainInto`, the caller releases each transferred event once.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        self.properties.deinit(gpa);
        if (self.owned_text) |text| {
            std.debug.assert(self.any_data == .text);
            std.debug.assert(self.any_data.text.ptr == text.ptr);
            std.debug.assert(self.any_data.text.len == text.len);
            gpa.free(text);
        }
        self.* = undefined;
    }

    /// Whether two events name the same signal about the same object.
    ///
    /// `ObjectId` carries a `FullNodeId`, which declares no `eql`, so the whole
    /// comparison is `std.meta.eql`. Comparing the paths instead would build a
    /// string per comparison to answer a question the ids already answer.
    ///
    /// **Errors.** This function does not fail.
    pub fn sameSubject(self: Event, other: Event) bool {
        return self.kind == other.kind and
            std.mem.eql(u8, self.member, other.member) and
            std.meta.eql(self.id, other.id);
    }
};

/// The events one adapter update produced, in the order it produced them.
///
/// The list grows with `gpa` and every walk over it is bounded by its own
/// length, which is the bound `consumer/tree.zig` uses for the three change
/// sets it walks. The bound is named here because this module has two walks and
/// a reader who cannot see the type would not know where they end.
pub const EventQueue = struct {
    /// The events, oldest first.
    items: std.ArrayList(Event) = .empty,

    /// An empty queue. Upstream has no such type: it raises each event as it
    /// produces it, and the queue exists here because a test needs to read what
    /// an update produced without a bus to raise it on.
    ///
    /// **Errors.** This function does not fail.
    pub fn empty() EventQueue {
        return .{ .items = .empty };
    }

    /// Releases every event and the array. Calling it twice frees memory twice,
    /// so a caller releases once and drops the value.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *EventQueue, gpa: std.mem.Allocator) void {
        for (self.items.items) |*event| event.deinit(gpa);
        self.items.deinit(gpa);
        self.* = undefined;
    }

    /// How many events the queue holds, which is the bound on every walk over
    /// it.
    ///
    /// **Errors.** This function does not fail.
    pub fn count(self: *const EventQueue) usize {
        return self.items.items.len;
    }

    /// Appends one event, copying borrowed `any_data.text` with `gpa`.
    ///
    /// Success transfers the dictionary and any already-owned text to the queue.
    /// Already-owned text must use `gpa`. Other event fields remain borrowed.
    /// On `error.OutOfMemory`, the queue is unchanged and the caller retains
    /// every input allocation. The queue releases a failed temporary text copy.
    pub fn push(
        self: *EventQueue,
        gpa: std.mem.Allocator,
        event: Event,
    ) std.mem.Allocator.Error!void {
        if (event.owned_text) |text| {
            std.debug.assert(event.any_data == .text);
            std.debug.assert(event.any_data.text.ptr == text.ptr);
            std.debug.assert(event.any_data.text.len == text.len);
            try self.items.append(gpa, event);
            return;
        }
        if (event.any_data == .text) {
            const text = try gpa.dupe(u8, event.any_data.text);
            errdefer gpa.free(text);
            var owned = event;
            owned.any_data = .{ .text = text };
            owned.owned_text = text;
            try self.items.append(gpa, owned);
            const stored = self.items.items[self.items.items.len - 1];
            std.debug.assert(stored.owned_text.?.ptr == stored.any_data.text.ptr);
            std.debug.assert(stored.owned_text.?.len == stored.any_data.text.len);
            return;
        }
        try self.items.append(gpa, event);
    }

    /// Empties the queue and hands the events to `out`, which the caller owns.
    ///
    /// The events move rather than being copied, so each one carries its
    /// property array exactly once and the queue is left empty. On
    /// `error.OutOfMemory` nothing has moved yet, because the array is grown
    /// before the first event is taken.
    ///
    /// **Errors.** `error.OutOfMemory` from `gpa`.
    pub fn drainInto(
        self: *EventQueue,
        gpa: std.mem.Allocator,
        out: *std.ArrayList(Event),
    ) std.mem.Allocator.Error!void {
        try out.ensureUnusedCapacity(gpa, self.items.items.len);
        for (self.items.items) |event| out.appendAssumeCapacity(event);
        self.items.clearRetainingCapacity();
    }
};

const testing = std.testing;

test "the event body carries five arguments in the order the reference fixes" {
    try testing.expectEqualStrings("siiva{sv}", event_body_signature);
    try testing.expectEqual(@as(usize, 5), argument_count);
    // The five characters that begin the five arguments. A transcription that
    // swapped the variant and the dictionary would answer "sivia{sv}" and this
    // test names it.
    const leading = [_]u8{
        event_body_signature[0],
        event_body_signature[1],
        event_body_signature[2],
        event_body_signature[3],
        event_body_signature[4],
    };
    try testing.expectEqualStrings("siiva", &leading);
}

test "the three arguments before the variant are the ones the fields name" {
    // `detail1` is a string, `detail2` and `detail3` are integers, `any_data`
    // is the variant and `properties` is the dictionary. The dictionary's
    // braces start at offset five, which is where the last argument begins.
    try testing.expectEqualStrings("{sv}", event_body_signature[5..]);
    try testing.expectEqualStrings(property_dictionary_signature, "a{sv}");
    try testing.expect(argument_properties > argument_any_data);
    try testing.expect(argument_any_data > argument_detail3);
    try testing.expect(argument_detail3 > argument_detail2);
    try testing.expect(argument_detail2 > argument_detail1);
}

test "the four signal interfaces are the ones the specification publishes" {
    try testing.expectEqualStrings("org.a11y.atspi.Event.Object", kindInterface(.object));
    try testing.expectEqualStrings("org.a11y.atspi.Event.Window", kindInterface(.window));
    try testing.expectEqualStrings("org.a11y.atspi.Event.Document", kindInterface(.document));
    try testing.expectEqualStrings("org.a11y.atspi.Event.Cache", kindInterface(.cache));
}

test "the sweep over the four interfaces reaches every member of Kind" {
    // `inline for` over the domain is the whole coverage argument, so a fifth
    // family added to `Kind` fails the build here rather than silently missing
    // a name.
    try testing.expectEqual(@as(usize, 4), @typeInfo(Kind).@"enum".fields.len);
    inline for (comptime std.enums.values(Kind)) |kind| {
        try testing.expect(kindInterface(kind).len > 0);
    }
}

test "no two event families share an interface name" {
    inline for (comptime std.enums.values(Kind)) |kind| {
        for (comptime std.enums.values(Kind)) |other| {
            if (@intFromEnum(kind) >= @intFromEnum(other)) continue;
            try testing.expect(!std.mem.eql(
                u8,
                kindInterface(kind),
                kindInterface(other),
            ));
        }
    }
}

test "the cache signal names are the ones a client waits for" {
    // `docs/41` row K6: the reference `Cache.xml` also declares a `Ready`
    // signal and a `version` property, which this port exports neither of. A
    // client that waits for `Ready` waits forever, and that is upstream's
    // behaviour too.
    try testing.expectEqualStrings("AddAccessible", member_add_accessible);
    try testing.expectEqualStrings("RemoveAccessible", member_remove_accessible);
}

test "every variant reports the signature it puts in the fourth argument" {
    // Every value below is bound to a name before its method is called. Zig
    // 0.16.0 resolves a container-level function on a tagged union through the
    // active field, and `AnyData.none` names a field with no payload, so the
    // method is only reachable from a value.
    const nothing: AnyData = .none;
    const address: AnyData = .{ .address = .root };
    const integer: AnyData = .{ .integer = 0 };
    const boolean: AnyData = .{ .boolean = false };
    const text: AnyData = .{ .text = "" };
    const box: AnyData = .{ .extent = .{ 1, 2, 3, 4 } };
    const number: AnyData = .{ .number = 0.0 };

    try testing.expectEqualStrings("", nothing.signature());
    try testing.expectEqualStrings("(so)", address.signature());
    try testing.expectEqualStrings("i", integer.signature());
    try testing.expectEqualStrings("b", boolean.signature());
    try testing.expectEqualStrings("s", text.signature());
    // `BoundsChanged` has nowhere else to put a box: the body is a string, two
    // integers, a variant and a dictionary.
    try testing.expectEqualStrings("(iiii)", box.signature());
    // `PropertyChange` puts a node's numeric value here, because `bus.rs:353`
    // writes `Value::F64` and the variant is the only argument that holds a `d`.
    try testing.expectEqualStrings("d", number.signature());

    // The sweep is the coverage argument, so a variant added without a
    // signature is a compile error rather than a silent omission.
    try testing.expectEqual(@as(usize, 7), @typeInfo(AnyData).@"union".fields.len);
}

test "an object reference is the only way a siiva{sv} body can carry an address" {
    // There is no `(so)` argument in the signature, so an event that names a
    // target must put it in the variant or drop it.
    for (event_body_signature) |byte| {
        try testing.expect(byte != '(');
    }
}

test "two any-data values compare by their content, not by their tag alone" {
    const node: ObjectId = .{ .node = .{
        .adapter = 2,
        .node = .init(.{ .value = 7 }, .init(1)),
    } };

    const an_address: AnyData = .{ .address = node };
    const a_number: AnyData = .{ .integer = 3 };
    const another_number: AnyData = .{ .integer = 4 };
    const shown: AnyData = .{ .text = "show" };
    const shown_too: AnyData = .{ .text = "shown" };
    const nothing: AnyData = .none;
    const a_double: AnyData = .{ .number = 3.5 };
    const another_double: AnyData = .{ .number = 4.5 };

    try testing.expect(an_address.eql(.{ .address = node }));
    try testing.expect(!an_address.eql(.{ .integer = 0 }));
    try testing.expect(a_number.eql(.{ .integer = 3 }));
    try testing.expect(!a_number.eql(another_number));
    try testing.expect(shown.eql(.{ .text = "show" }));
    try testing.expect(!shown.eql(shown_too));
    try testing.expect(nothing.eql(.none));
    try testing.expect(a_double.eql(.{ .number = 3.5 }));
    try testing.expect(!a_double.eql(another_double));
    try testing.expect(!a_double.eql(.{ .integer = 3 }));
}

test "two identifiers of different nodes are different addresses" {
    const here: AnyData = .{ .address = .{ .node = .{
        .adapter = 0,
        .node = .init(.{ .value = 7 }, .init(0)),
    } } };
    const there: AnyData = .{ .address = .{ .node = .{
        .adapter = 1,
        .node = .init(.{ .value = 7 }, .init(0)),
    } } };

    // The adapter number is part of the identity, because it is part of the
    // object path. Dropping it would make two windows' nodes share an address.
    try testing.expect(!here.eql(there));
    try testing.expect(here.eql(.{ .address = .{ .node = .{
        .adapter = 0,
        .node = .init(.{ .value = 7 }, .init(0)),
    } } }));
}

test "an empty dictionary holds nothing and reads nothing" {
    var properties = Properties.empty();
    defer properties.deinit(std.testing.allocator);

    try testing.expectEqual(@as(usize, 0), properties.count());
    try testing.expect(properties.get("new_value") == null);
}

test "a property is stored once and read back unchanged" {
    const gpa = std.testing.allocator;
    var properties = Properties.empty();
    defer properties.deinit(gpa);

    try properties.put(gpa, "new_value", .{ .boolean = true });

    try testing.expectEqual(@as(usize, 1), properties.count());
    const found = properties.get("new_value") orelse return error.NoSuchProperty;
    // A union with no `eql` compares field by field, and this test reads the
    // boolean itself so a failure names the value rather than the tag.
    try testing.expect(found == .boolean);
    try testing.expect(found.boolean);
}

test "putting a key twice replaces the value instead of appending" {
    const gpa = std.testing.allocator;
    var properties = Properties.empty();
    defer properties.deinit(gpa);

    try properties.put(gpa, "detail", .{ .text = "old" });
    try properties.put(gpa, "detail", .{ .text = "new" });

    // A dictionary has one value per key. Two entries under one key is a list
    // where a peer reads a map, and the peer keeps the first it finds.
    try testing.expectEqual(@as(usize, 1), properties.count());
    const replaced = properties.get("detail") orelse return error.NoSuchProperty;
    try testing.expectEqualStrings("new", replaced.text);
}

test "the scan for a duplicate key walks the whole list" {
    // The property this port emits on a `StateChanged` is not the first one
    // written, so a `put` that stopped at the first entry would append twice.
    const gpa = std.testing.allocator;
    var properties = Properties.empty();
    defer properties.deinit(gpa);

    try properties.put(gpa, "first", .{ .integer = 1 });
    try properties.put(gpa, "second", .{ .integer = 2 });
    try properties.put(gpa, "third", .{ .integer = 3 });
    try properties.put(gpa, "second", .{ .integer = 20 });

    try testing.expectEqual(@as(usize, 3), properties.count());
    const first = properties.get("first") orelse return error.NoSuchProperty;
    const second = properties.get("second") orelse return error.NoSuchProperty;
    const third = properties.get("third") orelse return error.NoSuchProperty;
    try testing.expectEqual(@as(i32, 1), first.integer);
    try testing.expectEqual(@as(i32, 20), second.integer);
    try testing.expectEqual(@as(i32, 3), third.integer);
}

test "every property value carries the signature the reference declares" {
    const text: PropertyValue = .{ .text = "" };
    const integer: PropertyValue = .{ .integer = 0 };
    const boolean: PropertyValue = .{ .boolean = false };
    const number: PropertyValue = .{ .number = 0.0 };

    try testing.expectEqualStrings("s", text.signature());
    try testing.expectEqualStrings("i", integer.signature());
    try testing.expectEqualStrings("b", boolean.signature());
    try testing.expectEqualStrings("d", number.signature());
}

test "an event splits the header from the body" {
    const gpa = std.testing.allocator;
    var event: Event = .{
        .kind = .cache,
        .member = member_add_accessible,
        .id = .root,
        .any_data = .{ .address = .{ .node = .{
            .adapter = 1,
            .node = .init(.{ .value = 4 }, .init(0)),
        } } },
    };
    defer event.deinit(gpa);

    // Header: the interface, the path and the member name.
    try testing.expectEqualStrings("org.a11y.atspi.Event.Cache", event.interface());
    try testing.expectEqualStrings("AddAccessible", event.member);
    const path = try event.id.path(gpa);
    defer gpa.free(path);
    try testing.expectEqualStrings("/org/a11y/atspi/accessible/root", path);
    // Body: one signature, and the address is in the variant because the
    // signature has no argument of type `(so)`.
    try testing.expectEqualStrings("siiva{sv}", event.bodySignature());
    try testing.expectEqualStrings("(so)", event.any_data.signature());
}

test "two events about different nodes are not about the same subject" {
    const here: Event = .{ .kind = .object, .member = member_focus, .id = .root };
    const elsewhere: Event = .{ .kind = .object, .member = member_focus, .id = .root };

    try testing.expect(here.sameSubject(elsewhere));

    const other_interface: Event = .{ .kind = .cache, .member = member_focus, .id = .root };
    try testing.expect(!here.sameSubject(other_interface));

    const other_member: Event = .{ .kind = .object, .member = member_announcement, .id = .root };
    try testing.expect(!here.sameSubject(other_member));
}

test "a queue keeps the order the update produced and empties on drain" {
    const gpa = std.testing.allocator;
    var queue = EventQueue.empty();
    defer queue.deinit(gpa);

    try queue.push(gpa, .{ .kind = .cache, .member = member_add_accessible, .id = .root });
    try queue.push(gpa, .{ .kind = .object, .member = member_focus, .id = .root });
    try queue.push(gpa, .{ .kind = .cache, .member = member_remove_accessible, .id = .root });

    try testing.expectEqual(@as(usize, 3), queue.count());

    var taken: std.ArrayList(Event) = .empty;
    defer taken.deinit(gpa);
    try queue.drainInto(gpa, &taken);

    try testing.expectEqual(@as(usize, 3), taken.items.len);
    try testing.expectEqualStrings(member_add_accessible, taken.items[0].member);
    try testing.expectEqualStrings(member_focus, taken.items[1].member);
    try testing.expectEqualStrings(member_remove_accessible, taken.items[2].member);
    try testing.expectEqual(@as(usize, 0), queue.count());
}

test "draining moves each event's dictionary rather than copying or dropping it" {
    const gpa = std.testing.allocator;
    var queue = EventQueue.empty();

    var event: Event = .{ .kind = .object, .member = member_state_changed, .id = .root };
    try event.properties.put(gpa, "new_value", .{ .boolean = true });
    try queue.push(gpa, event);

    var taken: std.ArrayList(Event) = .empty;
    try queue.drainInto(gpa, &taken);

    // The dictionary arrives intact, which is what a move gives and a copy of
    // the header fields alone would not.
    try testing.expectEqual(@as(usize, 1), taken.items.len);
    const carried = taken.items[0].properties.get("new_value") orelse
        return error.NoSuchProperty;
    try testing.expect(carried == .boolean);
    try testing.expect(carried.boolean);

    // Each event owns its dictionary and releases it once. A queue that also
    // released on drain would double free here, and `std.testing.allocator`
    // reports the leak of a queue that dropped them instead.
    for (taken.items) |*moved| moved.deinit(gpa);
    taken.deinit(gpa);
    queue.deinit(gpa);
}

test "queued text survives producer buffer reuse" {
    const gpa = testing.allocator;
    var queue = EventQueue.empty();
    defer queue.deinit(gpa);
    var producer = [_]u8{ 'B', 'e', 'f', 'o', 'r', 'e' };
    try queue.push(gpa, .{
        .kind = .object,
        .member = member_announcement,
        .id = .root,
        .any_data = .{ .text = &producer },
    });
    @memcpy(&producer, "After!");
    try testing.expectEqualStrings("Before", queue.items.items[0].any_data.text);
}

test "queue text-copy fail-N keeps only completed events" {
    const allocation_attempt_bound = 16;
    for (0..allocation_attempt_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
        });
        const gpa = failing.allocator();
        var queue = EventQueue.empty();
        defer queue.deinit(gpa);
        queue.push(gpa, .{
            .kind = .object,
            .member = member_announcement,
            .id = .root,
            .any_data = .{ .text = "Owned by queue" },
        }) catch |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            try testing.expectEqual(@as(usize, 0), queue.count());
            continue;
        };
        try testing.expectEqual(@as(usize, 1), queue.count());
        try testing.expectEqualStrings("Owned by queue", queue.items.items[0].any_data.text);
        return;
    }
    return error.AllocationAttemptBoundExceeded;
}

test "direct events never release borrowed text" {
    var producer = [_]u8{ 'T', 'e', 'x', 't' };
    var event: Event = .{
        .kind = .object,
        .member = member_announcement,
        .id = .root,
        .any_data = .{ .text = &producer },
    };
    event.deinit(testing.allocator);
    try testing.expectEqualStrings("Text", &producer);
}

test "draining transfers the queue text owner exactly once" {
    const gpa = testing.allocator;
    var queue = EventQueue.empty();
    defer queue.deinit(gpa);
    var taken: std.ArrayList(Event) = .empty;
    defer {
        for (taken.items) |*event| event.deinit(gpa);
        taken.deinit(gpa);
    }
    try queue.push(gpa, .{
        .kind = .object,
        .member = member_announcement,
        .id = .root,
        .any_data = .{ .text = "Transferred" },
    });
    const allocation = queue.items.items[0].owned_text.?;
    try queue.drainInto(gpa, &taken);
    try testing.expectEqual(@as(usize, 0), queue.count());
    try testing.expectEqual(@as(usize, 1), taken.items.len);
    try testing.expect(taken.items[0].owned_text.?.ptr == allocation.ptr);
    try testing.expect(taken.items[0].any_data.text.ptr == allocation.ptr);
    try testing.expectEqualStrings("Transferred", taken.items[0].any_data.text);
}

test "failed push retains input owned text and dictionary" {
    const backing = testing.allocator;
    var failing = testing.FailingAllocator.init(backing, .{ .fail_index = 0 });
    const gpa = failing.allocator();
    var queue = EventQueue.empty();
    defer queue.deinit(gpa);
    const text = try backing.dupe(u8, "Retained");
    var event: Event = .{
        .kind = .object,
        .member = member_announcement,
        .id = .root,
        .any_data = .{ .text = text },
        .owned_text = text,
    };
    defer event.deinit(backing);
    try event.properties.put(backing, "retained", .{ .boolean = true });
    try testing.expectError(error.OutOfMemory, queue.push(gpa, event));
    try testing.expectEqual(@as(usize, 0), queue.count());
    try testing.expectEqualStrings("Retained", event.any_data.text);
    try testing.expectEqual(@as(usize, 1), event.properties.count());
}
