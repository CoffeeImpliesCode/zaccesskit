//! The list-valued node properties, from `accesskit/src/lib.rs:2334-2425` and
//! `:2679-2682`, plus the list representation `vec_type_methods!` writes at
//! `:2020-2023`.
//!
//! Five properties live here. `CharacterLengths` and `WordStarts` carry one
//! `u8` per character of a text run, `CharacterPositions` and
//! `CharacterWidths` carry one `f32` per character, and `CustomActions` carries
//! the actions a node offers. The eight `NodeId` list properties are not here:
//! they are `props/ids.zig`, and they reach the representation through
//! `getNodeIdVec`, `setNodeIdVec` and `pushToNodeIdVec`, which this module owns
//! because `vec_type_methods!` generated them for both element types.
//!
//! **Why four of the five carry no push.** Upstream gives a pusher only to the
//! `vec_property_methods!` family (`accesskit/src/lib.rs:1319-1332`), so
//! `length_vec_property_methods!` (`:2334-2385`) and
//! `coord_vec_property_methods!` (`:2387-2425`) generate three methods each
//! and `CustomActions` generates four. The port keeps that split. Appending one
//! character to a run would let a caller break the two invariants the upstream
//! doc comments state, that the lengths sum to the byte length of `value`
//! (`:2336-2337`) and that a coordinate list is as long as the length list
//! (`:2392-2393`). Nothing in the core crate can check either, so a per-
//! character list is written whole or not at all. `CustomActions` keeps both a
//! setter and a push because they are not two spellings of one operation: the
//! setter drops the stored actions and the push keeps them.
//!
//! **Where the guards are.** A setter builds a fresh list, so it owns an
//! allocation between `appendSlice` and `set` and guards it with `errdefer`. A
//! push asks `Properties.getOrInsert` for the stored list and appends to it in
//! place, which is upstream's `Properties::get_mut` (`lib.rs:1122-1136`) and is
//! why n pushes cost one allocation rather than n. Nothing sits between the
//! insert and the append, so a push owns no buffer of its own to release; what
//! it guards is the item it was handed, because the store takes that only once
//! the append has succeeded.
//!
//! Nothing here blocks, so no function takes `io`. Every getter borrows the
//! store and allocates nothing. The store owns every buffer a setter installs
//! and every item a push hands it, so the caller of a setter or a push releases
//! nothing, and `Properties.deinit` releases the lot. A caller drives the
//! module as
//!
//! ```zig
//! var properties: Properties = .init(gpa);
//! defer properties.deinit();
//! try vectors.setCharacterLengths(&properties, &.{ 1, 2, 3 });
//! for (vectors.characterLengths(&properties)) |character_bytes| { ... }
//! ```

const std = @import("std");

const table = @import("table.zig");
const ids = @import("../ids.zig");

const CustomAction = @import("../values.zig").CustomAction;
const NodeId = ids.NodeId;
const Properties = table.Properties;
const PropertyId = table.PropertyId;

const testing = std.testing;

/// The failures the two pushers report.
///
/// `error.OutOfMemory` is the store's. The second is the store holding a value
/// whose payload is not the list this accessor appends to, which no path
/// through this module can produce: a setter writes the tag the descriptor
/// table names for the id, and a pusher installs the same tag itself.
pub const ListPushError = std.mem.Allocator.Error || error{
    /// The store holds the property with some other payload. The property is
    /// unchanged and `item` has been released.
    PropertyTagMismatch,
};

/// The property ids this module writes, all of them list-valued.
const owned_property_ids = [_]PropertyId{
    .character_lengths,
    .word_starts,
    .character_positions,
    .character_widths,
    .custom_actions,
};

comptime {
    // Two entries claiming one id would leave the second property with no
    // accessor at all, and nothing else in the build sees it: this list is the
    // only place the module's whole domain is written down.
    for (owned_property_ids, 0..) |first, i| {
        for (owned_property_ids[i + 1 ..], i + 1..) |second, j| {
            if (first == second) {
                @compileError(std.fmt.comptimePrint(
                    "property {s} is claimed twice, at entries {d} and {d}",
                    .{ @tagName(first), i, j },
                ));
            }
        }
    }
}

/// The UTF-8 byte length of every character in this text run, in run order, or
/// an empty slice when the property is unset.
///
/// A character is the smallest selectable unit of text and is not always one
/// Unicode scalar value, so the text editing implementation supplies these
/// lengths and AccessKit never computes them (`accesskit/src/lib.rs:2335-2343`).
/// Their sum is the byte length of the node's `value`, and a hard line break
/// ending a run counts as a single character (`:2345-2349`).
///
/// The slice borrows `properties`, and any later `set` on the same store may
/// reallocate the buffer it points into, so a caller finishes reading before it
/// writes. Allocates nothing and cannot fail.
pub fn characterLengths(properties: *const Properties) []const u8 {
    const stored = properties.get(.character_lengths) orelse return &.{};
    return switch (stored.*) {
        .length_vec => |list| list.items,
        else => &.{},
    };
}

/// Replaces the per-character lengths of this text run with a copy of `values`.
///
/// Releases the list a previous call installed and stores one holding `values`,
/// so every length this run reported is invalidated. Returns
/// `error.OutOfMemory` when the store cannot take the copy; the previous list
/// then survives whole, because the new buffer is released before the error
/// escapes. The caller keeps `values` and releases nothing.
pub fn setCharacterLengths(
    properties: *Properties,
    values: []const u8,
) std.mem.Allocator.Error!void {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(properties.gpa);
    try list.appendSlice(properties.gpa, values);
    try properties.set(.character_lengths, table.propertyValueFrom(.length_vec, list));
}

/// Removes the per-character lengths from this text run.
///
/// The property leaves the store rather than becoming an empty list, so
/// `Properties.get` reports it absent and `characterLengths` reports an empty
/// slice. Releases the list. Invalidates every slice `characterLengths`
/// returned.
pub fn clearCharacterLengths(properties: *Properties) void {
    properties.clear(.character_lengths);
}

/// The index of every word start in this text run, counted in characters as
/// `characterLengths` counts them, or an empty slice when the property is unset.
///
/// The list is sorted, and a run holding only the middle or the end of a word
/// has an empty list. A run that opens a paragraph may begin the list with `0`
/// but need not (`accesskit/src/lib.rs:2355-2370`). AccessKit does not decide
/// word boundaries itself, because a tree whose boundaries disagree with the
/// editor produces unpredictable results for the user.
///
/// The slice borrows `properties`, and any later `set` on the same store may
/// reallocate the buffer it points into. Allocates nothing and cannot fail.
pub fn wordStarts(properties: *const Properties) []const u8 {
    const stored = properties.get(.word_starts) orelse return &.{};
    return switch (stored.*) {
        .length_vec => |list| list.items,
        else => &.{},
    };
}

/// Replaces the word starts of this text run with a copy of `values`.
///
/// Releases the list a previous call installed and stores one holding `values`.
/// Returns `error.OutOfMemory` when the store cannot take the copy; the
/// previous list then survives whole. The caller keeps `values` and releases
/// nothing.
pub fn setWordStarts(
    properties: *Properties,
    values: []const u8,
) std.mem.Allocator.Error!void {
    var list: std.ArrayList(u8) = .empty;
    errdefer list.deinit(properties.gpa);
    try list.appendSlice(properties.gpa, values);
    try properties.set(.word_starts, table.propertyValueFrom(.length_vec, list));
}

/// Removes the word starts from this text run.
///
/// The property leaves the store rather than becoming an empty list. Releases
/// the list. Invalidates every slice `wordStarts` returned.
pub fn clearWordStarts(properties: *Properties) void {
    properties.clear(.word_starts);
}

/// The position of every character of this text run inside its bounding box, or
/// `null` when the property is unset.
///
/// A present list is as long as `characterLengths`, including for a run ending
/// in a hard line break, where the line break takes the position an end-of-
/// paragraph marker would be drawn at (`accesskit/src/lib.rs:2388-2398`). The
/// property is optional because a screen magnifier tracking the caret or a
/// screen reader drawing a highlight cursor needs it and little else does.
///
/// `null` and an empty slice are different answers: `null` says the editor
/// supplied no positions, an empty slice says it supplied a run of zero
/// characters.
///
/// The slice borrows `properties`, and any later `set` on the same store may
/// reallocate the buffer it points into. Allocates nothing and cannot fail.
pub fn characterPositions(properties: *const Properties) ?[]const f32 {
    const stored = properties.get(.character_positions) orelse return null;
    return switch (stored.*) {
        .coord_vec => |list| list.items,
        else => null,
    };
}

/// Replaces the per-character positions of this text run with a copy of
/// `values`.
///
/// Releases the list a previous call installed and stores one holding `values`.
/// Returns `error.OutOfMemory` when the store cannot take the copy; the
/// previous list then survives whole, and the property stays set rather than
/// reverting to `null`. The caller keeps `values` and releases nothing.
pub fn setCharacterPositions(
    properties: *Properties,
    values: []const f32,
) std.mem.Allocator.Error!void {
    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(properties.gpa);
    try list.appendSlice(properties.gpa, values);
    try properties.set(.character_positions, table.propertyValueFrom(.coord_vec, list));
}

/// Removes the per-character positions from this text run.
///
/// The property leaves the store, so `characterPositions` reports `null` rather
/// than an empty slice. Releases the list. Invalidates every slice
/// `characterPositions` returned.
pub fn clearCharacterPositions(properties: *Properties) void {
    properties.clear(.character_positions);
}

/// The advance width of every character of this text run, in the direction
/// `textDirection` gives, or `null` when the property is unset.
///
/// A present list is as long as `characterLengths`. The width of a hard line
/// break is non-zero when selecting it alone highlights something visibly, as
/// in Microsoft Word, and zero when it does not, as in Windows Notepad
/// (`accesskit/src/lib.rs:2400-2415`). Both are valid, so the port does not
/// substitute one for the other.
///
/// The slice borrows `properties`, and any later `set` on the same store may
/// reallocate the buffer it points into. Allocates nothing and cannot fail.
pub fn characterWidths(properties: *const Properties) ?[]const f32 {
    const stored = properties.get(.character_widths) orelse return null;
    return switch (stored.*) {
        .coord_vec => |list| list.items,
        else => null,
    };
}

/// Replaces the per-character widths of this text run with a copy of `values`.
///
/// Releases the list a previous call installed and stores one holding `values`.
/// Returns `error.OutOfMemory` when the store cannot take the copy; the
/// previous list then survives whole, and the property stays set rather than
/// reverting to `null`. The caller keeps `values` and releases nothing.
pub fn setCharacterWidths(
    properties: *Properties,
    values: []const f32,
) std.mem.Allocator.Error!void {
    var list: std.ArrayList(f32) = .empty;
    errdefer list.deinit(properties.gpa);
    try list.appendSlice(properties.gpa, values);
    try properties.set(.character_widths, table.propertyValueFrom(.coord_vec, list));
}

/// Removes the per-character widths from this text run.
///
/// The property leaves the store, so `characterWidths` reports `null` rather
/// than an empty slice. Releases the list. Invalidates every slice
/// `characterWidths` returned.
pub fn clearCharacterWidths(properties: *Properties) void {
    properties.clear(.character_widths);
}

/// The actions this node offers, in declaration order, or an empty slice when
/// the property is unset.
///
/// A custom-action `ActionRequest` carries an id back to the application,
/// which matches it against this list. The core never checks that the two
/// agree, and an id with no matching action is the application's to reject
/// (`accesskit/src/lib.rs:2680`).
///
/// The slice borrows `properties`, and a `set` or a push may reallocate the
/// buffer it points into. Allocates nothing and cannot fail.
pub fn customActions(properties: *const Properties) []const CustomAction {
    const stored = properties.get(.custom_actions) orelse return &.{};
    return switch (stored.*) {
        .custom_action_vec => |list| list.items,
        else => &.{},
    };
}

/// Replaces the actions this node offers with a copy of `values`.
///
/// Releases every action a previous call installed, including the description
/// buffers, and stores copies of `values`. A `CustomAction` owns its
/// description, and this call copies the action rather than adopting it, so the
/// copy is what the store owns afterwards.
///
/// Returns `error.OutOfMemory` when the store cannot take the copy. The
/// previous list then survives whole and no action in `values` reached the
/// store, so the caller still owns every one of them and releases them itself.
pub fn setCustomActions(
    properties: *Properties,
    values: []const CustomAction,
) std.mem.Allocator.Error!void {
    var list: std.ArrayList(CustomAction) = .empty;
    errdefer {
        // Releasing the list is not enough: each element owns a description
        // buffer, and an element added by this call owns one **this call**
        // allocated. Without the loop a failed append leaks one description
        // per action already copied.
        for (list.items) |*action| action.deinit(properties.gpa);
        list.deinit(properties.gpa);
    }

    // `appendSlice` is a **shallow** copy: it copies the `CustomAction` structs
    // and leaves their `description` buffers shared with the caller. The store
    // would then own a buffer the caller also owns, and the second release is a
    // double free. `CustomAction.init` copies the description, so each action is
    // built rather than copied.
    try list.ensureTotalCapacity(properties.gpa, values.len);
    for (values) |value| {
        list.appendAssumeCapacity(try CustomAction.init(
            properties.gpa,
            value.id,
            value.description.items,
        ));
    }
    try properties.set(.custom_actions, table.propertyValueFrom(.custom_action_vec, list));
}

/// Appends `item` to the actions this node offers, keeping the stored order.
///
/// Takes ownership of `item` on entry. The store takes the action only once
/// the append has succeeded, so every failure before that releases the
/// description buffer `item` carries, and the caller gets neither the action
/// nor a store to find it in. On `error.OutOfMemory` the store keeps every
/// earlier action whole, and `error.PropertyTagMismatch` leaves it unchanged
/// for the same reason. The list grows in place, so the slice `customActions`
/// returned survives a push that fits the stored capacity and is invalidated
/// by one that does not.
pub fn pushCustomAction(
    properties: *Properties,
    item: CustomAction,
) ListPushError!void {
    var owned_item = item;
    errdefer owned_item.deinit(properties.gpa);
    const stored = try properties.getOrInsert(
        .custom_actions,
        table.propertyValueFrom(.custom_action_vec, .empty),
    );
    switch (stored.*) {
        .custom_action_vec => |*list| try list.append(properties.gpa, owned_item),
        else => return error.PropertyTagMismatch,
    }
}

/// Removes every action this node offers.
///
/// The property leaves the store rather than becoming an empty list, and every
/// description buffer goes with it. Invalidates every slice `customActions`
/// returned.
pub fn clearCustomActions(properties: *Properties) void {
    properties.clear(.custom_actions);
}

/// Borrows the `NodeId` list stored under `id`, or an empty slice when that
/// property is unset.
///
/// One implementation for the eight node-id list properties of `props/ids.zig`,
/// because upstream generates the borrow inside `slice_type_getters!`
/// (`accesskit/src/lib.rs:1234-1243`) and reaches it from every entry of
/// `node_id_vec_property_methods!` (`:2025-2067`). An empty slice means unset:
/// the getter family upstream returns `&[]` for a missing value and the port
/// keeps that.
///
/// The slice borrows `properties`, and any later `set` or push on the same
/// store may reallocate the buffer it points into.
pub fn getNodeIdVec(properties: *const Properties, id: PropertyId) []const NodeId {
    const stored = properties.get(id) orelse return &.{};
    return switch (stored.*) {
        .node_id_vec => |list| list.items,
        else => &.{},
    };
}

/// Replaces the `NodeId` list stored under `id` with a copy of `values`.
///
/// Releases the list a previous call installed and stores one holding `values`.
/// Returns `error.OutOfMemory` when the store cannot take the copy; the
/// previous list then survives whole. The caller keeps `values` and releases
/// nothing.
pub fn setNodeIdVec(
    properties: *Properties,
    id: PropertyId,
    values: []const NodeId,
) std.mem.Allocator.Error!void {
    var list: std.ArrayList(NodeId) = .empty;
    errdefer list.deinit(properties.gpa);
    try list.appendSlice(properties.gpa, values);
    try properties.set(id, table.propertyValueFrom(.node_id_vec, list));
}

/// Appends `item` to the `NodeId` list stored under `id`, keeping the stored
/// order.
///
/// A push after the property was cleared starts a new list holding only `item`,
/// which is the 0.25.0 fix `572addd` and the case the upstream test
/// `pusher_should_start_a_new_list_after_the_clearer` guards
/// (`accesskit/src/lib.rs:1359-1365`). `item` holds no memory, so nothing
/// survives a failure and the stored list stays whole. The list grows in place,
/// so the slice `getNodeIdVec` returned survives a push that fits the stored
/// capacity and is invalidated by one that does not.
pub fn pushToNodeIdVec(
    properties: *Properties,
    id: PropertyId,
    item: NodeId,
) ListPushError!void {
    const stored = try properties.getOrInsert(
        id,
        table.propertyValueFrom(.node_id_vec, .empty),
    );
    switch (stored.*) {
        .node_id_vec => |*list| try list.append(properties.gpa, item),
        else => return error.PropertyTagMismatch,
    }
}

fn setOneCharacterLength(properties: *Properties) std.mem.Allocator.Error!void {
    return setCharacterLengths(properties, &.{1});
}

fn readCharacterLengthCount(properties: *const Properties) u32 {
    return @intCast(characterLengths(properties).len);
}

fn setOneWordStart(properties: *Properties) std.mem.Allocator.Error!void {
    return setWordStarts(properties, &.{2});
}

fn readWordStartCount(properties: *const Properties) u32 {
    return @intCast(wordStarts(properties).len);
}

fn setOneCharacterPosition(properties: *Properties) std.mem.Allocator.Error!void {
    return setCharacterPositions(properties, &.{4.5});
}

fn readCharacterPositionCount(properties: *const Properties) u32 {
    return if (characterPositions(properties)) |list| @intCast(list.len) else 0;
}

fn setOneCharacterWidth(properties: *Properties) std.mem.Allocator.Error!void {
    return setCharacterWidths(properties, &.{6.5});
}

fn readCharacterWidthCount(properties: *const Properties) u32 {
    return if (characterWidths(properties)) |list| @intCast(list.len) else 0;
}

fn setOneCustomAction(properties: *Properties) std.mem.Allocator.Error!void {
    var action = try CustomAction.init(properties.gpa, 1, "first");
    // `setCustomActions` copies rather than adopting, so a refused copy leaves
    // the action with this function and the store holding nothing.
    errdefer action.deinit(properties.gpa);
    return setCustomActions(properties, &.{action});
}

/// Installs one action and releases it again if the store refuses it, which is
/// what every caller of `setCustomActions` owes on the failure path.
fn setSingleAction(
    properties: *Properties,
    id: i32,
    description: []const u8,
) std.mem.Allocator.Error!void {
    var action = try CustomAction.init(properties.gpa, id, description);
    errdefer action.deinit(properties.gpa);
    return setCustomActions(properties, &.{action});
}

fn pushOneCustomAction(properties: *Properties) ListPushError!void {
    return pushCustomAction(properties, try CustomAction.init(properties.gpa, 1, "first"));
}

fn readCustomActionCount(properties: *const Properties) u32 {
    return @intCast(customActions(properties).len);
}

/// Allocation indices the fail-N sweep visits. One property install makes at
/// most three allocations: the list, an element that owns one, and the store's
/// own item slice, so six visits every one of them.
const fail_n_bound = 6;

/// Runs `mutate` once per allocation index below `fail_n_bound`, over a store
/// whose every allocation is routed through a failing allocator.
///
/// `read` counts the elements a mutated property holds and counts an unset
/// property as none. After every failure the store must read back exactly what
/// the last successful call wrote, which is what a missing `errdefer` breaks.
/// `testing.allocator` sits under the failing allocator, so the same omission
/// also surfaces as a leak at the end of the iteration.
fn assertFailsAtEveryAllocation(
    comptime mutate: *const fn (*Properties) ListPushError!void,
    comptime read: *const fn (*const Properties) u32,
    first_count: u32,
) !void {
    var reached_success = false;
    var induced_failures: usize = 0;
    var fail_index: usize = 0;
    while (fail_index < fail_n_bound) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator =
            .init(testing.allocator, .{ .fail_index = fail_index });
        var properties: Properties = .init(failing.allocator());
        defer properties.deinit();

        mutate(&properties) catch |err| {
            try testing.expect(err == error.OutOfMemory);
            induced_failures += 1;
            try testing.expectEqual(@as(u32, 0), read(&properties));
            continue;
        };
        reached_success = true;
        try testing.expectEqual(first_count, read(&properties));

        mutate(&properties) catch |err| {
            try testing.expect(err == error.OutOfMemory);
            try testing.expectEqual(first_count, read(&properties));
            induced_failures += 1;
        };
    }
    try testing.expect(reached_success);
    // Without this a store that never fails an allocation would pass the
    // sweep, which is the shape a stub takes.
    try testing.expect(induced_failures > 0);
}

test "three character lengths round-trip and the clear leaves the property unset" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setCharacterLengths(&properties, &.{ 1, 2, 3 });
    const lengths = characterLengths(&properties);
    try testing.expectEqual(@as(usize, 3), lengths.len);
    try testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, lengths);

    clearCharacterLengths(&properties);
    try testing.expectEqual(@as(usize, 0), characterLengths(&properties).len);
    try testing.expect(properties.get(.character_lengths) == null);
}

test "three word starts round-trip and the clear leaves the property unset" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setWordStarts(&properties, &.{ 0, 4, 9 });
    const starts = wordStarts(&properties);
    try testing.expectEqual(@as(usize, 3), starts.len);
    try testing.expectEqualSlices(u8, &.{ 0, 4, 9 }, starts);

    clearWordStarts(&properties);
    try testing.expectEqual(@as(usize, 0), wordStarts(&properties).len);
    try testing.expect(properties.get(.word_starts) == null);
}

test "three character positions round-trip and the clear reverts to null" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setCharacterPositions(&properties, &.{ 0.0, 7.25, 13.5 });
    const positions = characterPositions(&properties) orelse return error.PositionsAbsent;
    try testing.expectEqual(@as(usize, 3), positions.len);
    try testing.expectEqual(@as(f32, 0.0), positions[0]);
    try testing.expectEqual(@as(f32, 7.25), positions[1]);
    try testing.expectEqual(@as(f32, 13.5), positions[2]);

    clearCharacterPositions(&properties);
    try testing.expect(characterPositions(&properties) == null);
}

test "an unset coordinate list and an empty one are different answers" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(characterPositions(&properties) == null);
    try testing.expect(characterWidths(&properties) == null);

    try setCharacterPositions(&properties, &.{});
    try testing.expectEqual(@as(usize, 0), characterPositions(&properties).?.len);
    try testing.expect(properties.get(.character_positions) != null);

    try setCharacterWidths(&properties, &.{});
    try testing.expectEqual(@as(usize, 0), characterWidths(&properties).?.len);
    try testing.expect(properties.get(.character_widths) != null);
}

test "three character widths round-trip and the clear reverts to null" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setCharacterWidths(&properties, &.{ 1.5, 2.5, 3.5 });
    const widths = characterWidths(&properties) orelse return error.WidthsAbsent;
    try testing.expectEqual(@as(usize, 3), widths.len);
    try testing.expectEqual(@as(f32, 1.5), widths[0]);
    try testing.expectEqual(@as(f32, 2.5), widths[1]);
    try testing.expectEqual(@as(f32, 3.5), widths[2]);

    clearCharacterWidths(&properties);
    try testing.expect(characterWidths(&properties) == null);
}

test "a coordinate list keeps negative zero apart from positive zero" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setCharacterPositions(&properties, &.{ -0.0, 0.0 });
    const positions = characterPositions(&properties) orelse return error.PositionsAbsent;
    try testing.expectEqual(@as(u32, 0x8000_0000), @as(u32, @bitCast(positions[0])));
    try testing.expectEqual(@as(u32, 0x0000_0000), @as(u32, @bitCast(positions[1])));
}

test "a byte length at each end of the u8 range round-trips" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setCharacterLengths(&properties, &.{ 0, std.math.maxInt(u8) });
    const lengths = characterLengths(&properties);
    try testing.expectEqual(@as(u8, 0), lengths[0]);
    try testing.expectEqual(@as(u8, 255), lengths[1]);
}

test "three pushed actions read back in the order they were pushed" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    const first = try CustomAction.init(testing.allocator, 1, "first");
    const second = try CustomAction.init(testing.allocator, 2, "second");
    const third = try CustomAction.init(testing.allocator, 3, "third");
    try pushCustomAction(&properties, first);
    try pushCustomAction(&properties, second);
    try pushCustomAction(&properties, third);

    const actions = customActions(&properties);
    try testing.expectEqual(@as(usize, 3), actions.len);
    try testing.expectEqual(@as(i32, 1), actions[0].id);
    try testing.expectEqualSlices(u8, "first", actions[0].description.items);
    try testing.expectEqual(@as(i32, 2), actions[1].id);
    try testing.expectEqualSlices(u8, "second", actions[1].description.items);
    try testing.expectEqual(@as(i32, 3), actions[2].id);
    try testing.expectEqualSlices(u8, "third", actions[2].description.items);
}

test "a push after a clear leaves only the pushed action" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setSingleAction(&properties, 1, "first");
    clearCustomActions(&properties);
    try testing.expect(properties.get(.custom_actions) == null);

    try pushCustomAction(&properties, try CustomAction.init(testing.allocator, 2, "second"));
    const actions = customActions(&properties);
    try testing.expectEqual(@as(usize, 1), actions.len);
    try testing.expectEqual(@as(i32, 2), actions[0].id);
}

test "pushing past the stored capacity keeps every action and moves the buffer" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setSingleAction(&properties, 0, "act");
    const before = customActions(&properties);

    const push_count = 40;
    var index: i32 = 1;
    while (index <= push_count) : (index += 1) {
        const action = try CustomAction.init(testing.allocator, index, "act");
        try pushCustomAction(&properties, action);
    }

    const after = customActions(&properties);
    try testing.expect(before.ptr != after.ptr);
    try testing.expectEqual(@as(usize, push_count + 1), after.len);
    for (after, 0..) |action, position| {
        try testing.expectEqual(@as(i32, @intCast(position)), action.id);
        try testing.expectEqualSlices(u8, "act", action.description.items);
    }
}

test "a custom action id at each end of the i32 range round-trips" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    var low = try CustomAction.init(testing.allocator, std.math.minInt(i32), "low");
    errdefer low.deinit(testing.allocator);
    var high = try CustomAction.init(testing.allocator, std.math.maxInt(i32), "high");
    errdefer high.deinit(testing.allocator);
    try setCustomActions(&properties, &.{ low, high });

    const actions = customActions(&properties);
    try testing.expectEqual(@as(i32, -2147483648), actions[0].id);
    try testing.expectEqual(@as(i32, 2147483647), actions[1].id);
}

test "a custom action with an empty description round-trips" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setSingleAction(&properties, 7, "");
    const actions = customActions(&properties);
    try testing.expectEqual(@as(usize, 1), actions.len);
    try testing.expectEqual(@as(i32, 7), actions[0].id);
    try testing.expectEqual(@as(usize, 0), actions[0].description.items.len);
}

test "every allocation failure leaves the stored list unchanged" {
    try assertFailsAtEveryAllocation(&setOneCharacterLength, &readCharacterLengthCount, 1);
    try assertFailsAtEveryAllocation(&setOneWordStart, &readWordStartCount, 1);
    try assertFailsAtEveryAllocation(&setOneCharacterPosition, &readCharacterPositionCount, 1);
    try assertFailsAtEveryAllocation(&setOneCharacterWidth, &readCharacterWidthCount, 1);
    try assertFailsAtEveryAllocation(&setOneCustomAction, &readCustomActionCount, 1);
    try assertFailsAtEveryAllocation(&pushOneCustomAction, &readCustomActionCount, 1);
}

test "the node-id list representation round-trips through get, set, push and clear" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expectEqual(@as(usize, 0), getNodeIdVec(&properties, .children).len);

    const one = ids.nodeIdFromContent(1);
    const two = ids.nodeIdFromContent(2);
    const three = ids.nodeIdFromContent(3);
    try setNodeIdVec(&properties, .children, &.{ one, two });
    try testing.expectEqualSlices(NodeId, &.{ one, two }, getNodeIdVec(&properties, .children));

    try pushToNodeIdVec(&properties, .children, three);
    const pushed = getNodeIdVec(&properties, .children);
    try testing.expectEqual(@as(usize, 3), pushed.len);
    try testing.expectEqual(@as(u64, 1), pushed[0].value);
    try testing.expectEqual(@as(u64, 2), pushed[1].value);
    try testing.expectEqual(@as(u64, 3), pushed[2].value);

    properties.clear(.children);
    try testing.expectEqual(@as(usize, 0), getNodeIdVec(&properties, .children).len);
    try testing.expect(properties.get(.children) == null);
}
