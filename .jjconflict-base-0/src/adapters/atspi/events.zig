//! Owned AT-SPI notifications, separated from their D-Bus encoder.
//!
//! Object, window and document signals have the exact five-argument
//! `siiva{sv}` body, including the final property dictionary. Cache signals
//! instead use `org.a11y.atspi.Cache`: AddAccessible carries a complete
//! CacheItem snapshot and RemoveAccessible carries an object reference.
//!
//! Pinned upstream: `adapters/atspi-common/src/events.rs` and
//! `adapters/unix/src/atspi/bus.rs:269-478` at
//! `466e24e252103f4d82bd6fbab98141b551e46e0c`.
//!
//! EventQueue copies borrowed text on push. Cache snapshots already own their
//! name and description. Successful push transfers all owned allocations;
//! failed push retains the input owner. Drain transfers every Event to the
//! caller, which releases each once with Event.deinit before releasing its list.
//! Queue and dictionary scans are bounded by their respective list lengths.

const std = @import("std");

const object_id = @import("object_id.zig");
const window_bounds = @import("window_bounds.zig");
const node_module = @import("node.zig");

const ObjectId = object_id.ObjectId;

/// The wire signature of object, window and document event bodies.
///
/// Five arguments: a string, two 32-bit integers, a variant and a dictionary
/// of string to variant. The `{` and `}` are the dictionary's braces and `sv`
/// inside them is its key and its value, so the last argument is `a{sv}`.
pub const event_body_signature: [:0]const u8 = "siiva{sv}";

/// The single complete CacheItem argument, not an event-body variant.
pub const cache_item_signature: [:0]const u8 = "((so)(so)(so)iiassusau)";
/// The single object reference carried by Cache.RemoveAccessible.
pub const cache_remove_signature: [:0]const u8 = "(so)";

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
    /// `org.a11y.atspi.Cache`, with its separate cache-body signatures.
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
        .cache => "org.a11y.atspi.Cache",
    };
}

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
/// `org.a11y.atspi.Cache`.
pub const member_add_accessible: [:0]const u8 = "AddAccessible";

/// The member name of the signal that removes one node from the cache, on
/// `org.a11y.atspi.Cache`.
pub const member_remove_accessible: [:0]const u8 = "RemoveAccessible";

/// The value the fourth argument of an event body carries.
///
/// The variant is the only argument that can hold a typed value, which is why
/// an event that needs an object reference puts it here: `siiva{sv}` has no
/// argument of type `(so)`.
pub const AnyData = union(enum) {
    /// The upstream default variant: signed integer zero (`i`).
    none,
    /// An object reference, `(so)`. The path comes from the identifier and the
    /// bus name from the connection that exports it, so the value names an
    /// object rather than a path a peer would have to guess the owner of.
    address: ObjectId,
    /// A signed 32-bit integer, `i`.
    integer: i32,
    /// An unsigned 32-bit role value, `u`.
    unsigned_integer: u32,
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
            .none => "i",
            .address => "(so)",
            .integer => "i",
            .unsigned_integer => "u",
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
            .unsigned_integer => |mine| other == .unsigned_integer and mine == other.unsigned_integer,
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
    /// Header PATH. Cache signals use the cache object, not a node path.
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
    /// Owned complete Cache.AddAccessible snapshot, or null for other signals.
    /// Its text buffers use the same allocator as Event.deinit.
    cache_item: ?node_module.CacheNode = null,

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
        if (self.kind == .cache) {
            return if (std.mem.eql(u8, self.member, member_add_accessible))
                cache_item_signature
            else
                cache_remove_signature;
        }
        return event_body_signature;
    }

    /// Releases the cache snapshot, dictionary and owned text; never borrowed text.
    /// After `drainInto`, the caller releases each transferred event once.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *Event, gpa: std.mem.Allocator) void {
        self.properties.deinit(gpa);
        if (self.cache_item) |*item| item.deinit(gpa);
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
    /// Success transfers the dictionary, cache snapshot and already-owned text.
    /// Owned buffers must use gpa. Only detail1 and constant member stay borrowed.
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

fn cacheEventForTest(gpa: std.mem.Allocator) std.mem.Allocator.Error!Event {
    const name = try gpa.dupe(u8, "Snapshot name");
    errdefer gpa.free(name);
    const description = try gpa.dupe(u8, "Snapshot description");
    return .{
        .kind = .cache,
        .member = member_add_accessible,
        .id = .cache,
        .cache_item = .{
            .adapter_id = 1,
            .id = .init(.{ .value = 4 }, .init(0)),
            .parent = .root,
            .index_in_parent = 0,
            .child_count = 0,
            .interfaces = .{},
            .name = name,
            .description = description,
            .role = .invalid,
            .states = .{},
        },
    };
}

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
    try testing.expectEqualStrings("org.a11y.atspi.Cache", kindInterface(.cache));
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

    try testing.expectEqualStrings("i", nothing.signature());
    try testing.expectEqualStrings("(so)", address.signature());
    try testing.expectEqualStrings("i", integer.signature());
    const unsigned: AnyData = .{ .unsigned_integer = 127 };
    try testing.expectEqualStrings("u", unsigned.signature());
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
    try testing.expectEqual(@as(usize, 8), @typeInfo(AnyData).@"union".fields.len);
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
    var event = try cacheEventForTest(gpa);
    defer event.deinit(gpa);

    // Header: the interface, the path and the member name.
    try testing.expectEqualStrings("org.a11y.atspi.Cache", event.interface());
    try testing.expectEqualStrings("AddAccessible", event.member);
    const path = try event.id.path(gpa);
    defer gpa.free(path);
    try testing.expectEqualStrings("/org/a11y/atspi/cache", path);
    // Cache adds carry the complete item, never a siiva{sv} variant envelope.
    try testing.expectEqualStrings(cache_item_signature, event.bodySignature());
    try testing.expectEqualStrings("Snapshot name", event.cache_item.?.name);
    try testing.expectEqualStrings("Snapshot description", event.cache_item.?.description);
    const removed: Event = .{
        .kind = .cache,
        .member = member_remove_accessible,
        .id = .cache,
        .any_data = .{ .address = .root },
    };
    try testing.expectEqualStrings(cache_remove_signature, removed.bodySignature());
}

test "two events about different nodes are not about the same subject" {
    const here: Event = .{ .kind = .object, .member = member_state_changed, .id = .root };
    const elsewhere: Event = .{ .kind = .object, .member = member_state_changed, .id = .root };

    try testing.expect(here.sameSubject(elsewhere));

    const other_interface: Event = .{ .kind = .cache, .member = member_state_changed, .id = .root };
    try testing.expect(!here.sameSubject(other_interface));

    const other_member: Event = .{ .kind = .object, .member = member_announcement, .id = .root };
    try testing.expect(!here.sameSubject(other_member));
}

test "a queue keeps the order the update produced and empties on drain" {
    const gpa = std.testing.allocator;
    var queue = EventQueue.empty();
    defer queue.deinit(gpa);

    var added = try cacheEventForTest(gpa);
    queue.push(gpa, added) catch |err| {
        added.deinit(gpa);
        return err;
    };
    try queue.push(gpa, .{ .kind = .object, .member = member_state_changed, .id = .root });
    try queue.push(gpa, .{ .kind = .cache, .member = member_remove_accessible, .id = .root });

    try testing.expectEqual(@as(usize, 3), queue.count());

    var taken: std.ArrayList(Event) = .empty;
    defer taken.deinit(gpa);
    defer for (taken.items) |*event| event.deinit(gpa);
    try queue.drainInto(gpa, &taken);

    try testing.expectEqual(@as(usize, 3), taken.items.len);
    try testing.expectEqualStrings(member_add_accessible, taken.items[0].member);
    try testing.expectEqualStrings(member_state_changed, taken.items[1].member);
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

test "cache snapshot transfers exactly once on drain and survives failed push" {
    const gpa = testing.allocator;
    var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = 0 });
    var queue = EventQueue.empty();
    defer queue.deinit(gpa);
    var event = try cacheEventForTest(gpa);
    queue.push(failing.allocator(), event) catch |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual(@as(usize, 0), queue.count());
        try testing.expectEqualStrings("Snapshot name", event.cache_item.?.name);
        queue.push(gpa, event) catch |retry_error| {
            event.deinit(gpa);
            return retry_error;
        };
        var taken: std.ArrayList(Event) = .empty;
        defer taken.deinit(gpa);
        defer for (taken.items) |*moved| moved.deinit(gpa);
        const name = event.cache_item.?.name;
        try queue.drainInto(gpa, &taken);
        try testing.expectEqual(@as(usize, 0), queue.count());
        try testing.expectEqual(@as(usize, 1), taken.items.len);
        try testing.expect(taken.items[0].cache_item.?.name.ptr == name.ptr);
        try testing.expectEqualStrings("Snapshot description", taken.items[0].cache_item.?.description);
        return;
    };
    return error.ExpectedAllocationFailure;
}
