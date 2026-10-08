//! The 15 node-id properties: 8 ordered lists and 7 single ids.
//!
//! Upstream: `accesskit/src/lib.rs:2025-2095`, the invocations
//! `node_id_vec_property_methods!` at `:2025` and `node_id_property_methods!`
//! at `:2069`. The first expands through `vec_property_methods!` at `:1319` and
//! the second through `property_methods!` at `:1299`, which is where the 4
//! methods per list and the 3 per single id come from. The property text below
//! is upstream's own, carried from the doc comments those invocations hold.
//!
//! **Not methods on `Node`.** Zig attaches a method to the container that
//! declares it, and `schema/node.zig` owns `Node`, so this module publishes one
//! function per accessor and takes the store as the first parameter.
//!
//! **The store owns its allocator.** `Properties` is created with one
//! allocator and every write here goes through it. No accessor in this file
//! takes an allocator, because a caller that passes a second one would let the
//! store free a payload it did not allocate. `props/table.zig` owns
//! `Properties`, its `get`, `set` and `clear`, and its `deinit`.
//!
//! **Where the list work lives.** `props/vectors.zig` owns the three generic
//! list accessors that upstream generates in `vec_type_methods!` at
//! `accesskit/src/lib.rs:2020-2023`, and the 8 list properties here call them.
//! This module owns the scalar arm read that `copy_type_getters!` generates and
//! the 7 single-id properties.
//!
//! **Where the `errdefer` guards live.** `setChildren` and its seven siblings
//! own an allocation, because the store takes a copy of the caller's slice. The
//! copy is guarded in `props/vectors.zig`, which is where the setter is written,
//! and the guard is what turns a refused write into an error instead of a leak.
//! The 7 single-id setters store an inline `NodeId`, which owns nothing, so no
//! accessor in this file carries a guard of its own and none is missing one.
//!
//! **The one error a pusher cannot reach.** `pushChild` and its seven siblings
//! return `vectors.ListPushError`, which carries `error.PropertyTagMismatch`
//! beside `error.OutOfMemory`. No path through these 15 accessors produces it:
//! every setter here writes the tag the descriptor table names for the id, and
//! a pusher installs that tag itself before it appends.
//!
//! **A list getter returns a borrow.** A slice from `children`, `controls`,
//! `details`, `describedBy`, `flowTo`, `labelledBy`, `owns` or `radioGroup`
//! points into the array the store owns, and the next write to that same
//! property invalidates it. A caller that needs the ids after such a write
//! copies them first.
//!
//! The shortest use is one push and one read:
//!
//! ```zig
//! var properties: Properties = .init(gpa);
//! defer properties.deinit();
//! try pushChild(&properties, .{ .value = 7 });
//! const first_child = children(&properties);
//! ```

const std = @import("std");

const ids = @import("../ids.zig");
const NodeId = ids.NodeId;

const table = @import("table.zig");
const Properties = table.Properties;
const PropertyId = table.PropertyId;
const PropertyValue = table.PropertyValue;

const vectors = @import("vectors.zig");

const testing = std.testing;

comptime {
    // These are the only two payloads the 15 accessors read. A port that folded
    // the list family into the single-id arm, or the other way round, drops one
    // of the fields and fails here instead of silently changing what a getter
    // hands back.
    std.debug.assert(@hasField(PropertyValue, "node_id"));
    std.debug.assert(@hasField(PropertyValue, "node_id_vec"));
}

/// The 15 properties this family publishes a getter, a setter and a clearer
/// for, in upstream order: the eight lists of
/// `node_id_vec_property_methods!` at `accesskit/src/lib.rs:2025-2067`, then
/// the seven single ids of `node_id_property_methods!` at `:2069-2095`.
///
/// This is the family's whole domain in one place, so
/// `table.assertFamilyReachable` can hold it against the descriptor table: a
/// property with a row in `property_descriptors` and no row here is a
/// compile error. The eight lists also publish a pusher, which this table does
/// not name, because the pusher is a second spelling of one operation rather
/// than a third accessor for the property.
pub const property_ids = [_]PropertyId{
    .children,
    .controls,
    .details,
    .described_by,
    .flow_to,
    .labelled_by,
    .owns,
    .radio_group,
    .active_descendant,
    .error_message,
    .in_page_link_target,
    .member_of,
    .next_on_line,
    .previous_on_line,
    .popup_for,
};

comptime {
    // The two invocations carry eight entries and seven. A row added here
    // without an upstream entry changes the number of functions this module
    // publishes, so the count is the check.
    std.debug.assert(property_ids.len == 15);
    table.assertFamilyReachable(.ids, property_ids);
}

/// Reads the `NodeId` arm. `copy_type_getters!` at
/// `accesskit/src/lib.rs:1248-1259` returns the stored value and `null` for
/// every other arm.
fn readNodeId(properties: *const Properties, id: PropertyId) ?NodeId {
    const stored = properties.get(id) orelse return null;
    return switch (stored.*) {
        .node_id => |identifier| identifier,
        else => null,
    };
}

// -- NodeId lists: 8 properties, `accesskit/src/lib.rs:2025-2067` --

/// The ordered list of this node's direct children in the tree. The order
/// should match the intended reading and navigation order.
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn children(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .children);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setChildren(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .children, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushChild(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .children, item);
}

/// Makes the property read as one that was never set. A later `pushChild`
/// starts a new list.
pub fn clearChildren(properties: *Properties) void {
    properties.clear(.children);
}

/// The nodes whose contents or presence are controlled by this node.
/// ARIA equivalent: `aria-controls`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-controls>
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn controls(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .controls);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setControls(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .controls, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushControlled(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .controls, item);
}

/// Makes the property read as one that was never set. A later `pushControlled`
/// starts a new list.
pub fn clearControls(properties: *Properties) void {
    properties.clear(.controls);
}

/// The nodes that give detailed, structured descriptions for this node and that
/// a user can navigate to. Use `describedBy` when a plain-text description is
/// enough. ARIA equivalent: `aria-details`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-details>
///
/// `aria-details` names one element, while this property names several.
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn details(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .details);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setDetails(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .details, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushDetail(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .details, item);
}

/// Makes the property read as one that was never set. A later `pushDetail`
/// starts a new list.
pub fn clearDetails(properties: *Properties) void {
    properties.clear(.details);
}

/// The nodes whose contents give a plain-text description for this node. Use
/// `details` for structured content that a user can navigate to.
/// ARIA equivalent: `aria-describedby`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-describedby>
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn describedBy(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .described_by);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setDescribedBy(
    properties: *Properties,
    values: []const NodeId,
) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .described_by, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushDescribedBy(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .described_by, item);
}

/// Makes the property read as one that was never set. A later `pushDescribedBy`
/// starts a new list.
pub fn clearDescribedBy(properties: *Properties) void {
    properties.clear(.described_by);
}

/// The nodes that follow this node in an alternate reading order.
/// ARIA equivalent: `aria-flowto`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-flowto>
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn flowTo(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .flow_to);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setFlowTo(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .flow_to, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushFlowTo(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .flow_to, item);
}

/// Makes the property read as one that was never set. A later `pushFlowTo`
/// starts a new list.
pub fn clearFlowTo(properties: *Properties) void {
    properties.clear(.flow_to);
}

/// The nodes that label this node. ARIA equivalent: `aria-labelledby`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-labelledby>
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn labelledBy(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .labelled_by);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setLabelledBy(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .labelled_by, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushLabelledBy(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .labelled_by, item);
}

/// Makes the property read as one that was never set. A later `pushLabelledBy`
/// starts a new list.
pub fn clearLabelledBy(properties: *Properties) void {
    properties.clear(.labelled_by);
}

/// The nodes this node owns that are not already its descendants in the tree.
/// This property is unnecessary for direct children or for any other
/// descendant. ARIA equivalent: `aria-owns`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-owns>
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn owns(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .owns);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setOwns(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .owns, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushOwned(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .owns, item);
}

/// Makes the property read as one that was never set. A later `pushOwned`
/// starts a new list.
pub fn clearOwns(properties: *Properties) void {
    properties.clear(.owns);
}

/// For a radio button, every radio button in the same group, including this
/// node.
///
/// An empty slice when the property is unset. Borrows the store: the next write
/// to this property invalidates the slice.
pub fn radioGroup(properties: *const Properties) []const NodeId {
    return vectors.getNodeIdVec(properties, .radio_group);
}

/// Stores `values` as the whole list and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setRadioGroup(properties: *Properties, values: []const NodeId) std.mem.Allocator.Error!void {
    try vectors.setNodeIdVec(properties, .radio_group, values);
}

/// Appends one id after the ids already stored, and starts a new list when the
/// property is unset or was cleared. `error.OutOfMemory` leaves the list as it
/// was.
pub fn pushToRadioGroup(properties: *Properties, item: NodeId) vectors.ListPushError!void {
    try vectors.pushToNodeIdVec(properties, .radio_group, item);
}

/// Makes the property read as one that was never set. A later
/// `pushToRadioGroup` starts a new list.
pub fn clearRadioGroup(properties: *Properties) void {
    properties.clear(.radio_group);
}

// -- NodeId singletons: 7 properties, `accesskit/src/lib.rs:2069-2095` --

/// For a composite widget such as a listbox, a tree or a grid, the currently
/// active descendant. Use it when the focus stays on the container while the
/// active item changes. ARIA equivalent: `aria-activedescendant`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-activedescendant>
///
/// `null` when the property is unset.
pub fn activeDescendant(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .active_descendant);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setActiveDescendant(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.active_descendant, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `activeDescendant`
/// answers `null`.
pub fn clearActiveDescendant(properties: *Properties) void {
    properties.clear(.active_descendant);
}

/// The node that gives an error message for this node. Use it with
/// `Invalid`. ARIA equivalent: `aria-errormessage`.
/// <https://www.w3.org/TR/wai-aria-1.2/#aria-errormessage>
///
/// `null` when the property is unset.
pub fn errorMessage(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .error_message);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setErrorMessage(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.error_message, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `errorMessage`
/// answers `null`.
pub fn clearErrorMessage(properties: *Properties) void {
    properties.clear(.error_message);
}

/// The target of this link when it points to another place in the same
/// document.
///
/// `null` when the property is unset.
pub fn inPageLinkTarget(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .in_page_link_target);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setInPageLinkTarget(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.in_page_link_target, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `inPageLinkTarget`
/// answers `null`.
pub fn clearInPageLinkTarget(properties: *Properties) void {
    properties.clear(.in_page_link_target);
}

/// The group this node belongs to.
///
/// `null` when the property is unset.
pub fn memberOf(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .member_of);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setMemberOf(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.member_of, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `memberOf` answers
/// `null`.
pub fn clearMemberOf(properties: *Properties) void {
    properties.clear(.member_of);
}

/// The next text run on the same visual line. The target's `previousOnLine`
/// points back to this node.
///
/// `null` when the property is unset.
pub fn nextOnLine(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .next_on_line);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setNextOnLine(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.next_on_line, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `nextOnLine` answers
/// `null`.
pub fn clearNextOnLine(properties: *Properties) void {
    properties.clear(.next_on_line);
}

/// The previous text run on the same visual line. The target's `nextOnLine`
/// points back to this node.
///
/// `null` when the property is unset.
pub fn previousOnLine(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .previous_on_line);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setPreviousOnLine(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.previous_on_line, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `previousOnLine`
/// answers `null`.
pub fn clearPreviousOnLine(properties: *Properties) void {
    properties.clear(.previous_on_line);
}

/// The node for which this node is a popup.
///
/// `null` when the property is unset.
pub fn popupFor(properties: *const Properties) ?NodeId {
    return readNodeId(properties, .popup_for);
}

/// Stores `value` and discards whatever the property held.
/// `error.OutOfMemory` leaves the property as it was.
pub fn setPopupFor(properties: *Properties, value: NodeId) std.mem.Allocator.Error!void {
    try properties.set(.popup_for, table.propertyValueFrom(.node_id, value));
}

/// Makes the property read as one that was never set, so `popupFor` answers
/// `null`.
pub fn clearPopupFor(properties: *Properties) void {
    properties.clear(.popup_for);
}

const ListGetter = *const fn (properties: *const Properties) []const NodeId;
const ListSetter = *const fn (
    properties: *Properties,
    values: []const NodeId,
) std.mem.Allocator.Error!void;
const ListPusher = *const fn (properties: *Properties, item: NodeId) vectors.ListPushError!void;
const ListClearer = *const fn (properties: *Properties) void;

const IdGetter = *const fn (properties: *const Properties) ?NodeId;
const IdSetter = *const fn (properties: *Properties, value: NodeId) std.mem.Allocator.Error!void;
const IdClearer = *const fn (properties: *Properties) void;

/// Stores a two-id list, reads it back, pushes a third and reads three, then
/// clears and reads an empty list.
///
/// The four accessors are comptime, so a property declared at the wrong payload
/// or one missing a method fails to coerce here and the compiler names that
/// property rather than the body of this helper.
fn listRoundTrip(
    comptime get: ListGetter,
    comptime set: ListSetter,
    comptime push: ListPusher,
    comptime clear: ListClearer,
) !void {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expectEqual(@as(usize, 0), get(&properties).len);

    const pair = [_]NodeId{ .{ .value = 11 }, .{ .value = 22 } };
    try set(&properties, &pair);
    try testing.expectEqualSlices(NodeId, &pair, get(&properties));

    try push(&properties, .{ .value = 33 });
    const three = [_]NodeId{ .{ .value = 11 }, .{ .value = 22 }, .{ .value = 33 } };
    try testing.expectEqualSlices(NodeId, &three, get(&properties));

    clear(&properties);
    try testing.expectEqual(@as(usize, 0), get(&properties).len);

    // Upstream's `pusher_should_start_a_new_list_after_the_clearer` at
    // `accesskit/src/lib.rs:1382-1388`: the pusher makes a new list rather than
    // reviving the cleared one.
    try push(&properties, .{ .value = 44 });
    try testing.expectEqualSlices(NodeId, &[_]NodeId{.{ .value = 44 }}, get(&properties));
}

/// Stores one id, reads it back, then clears the property and reads `null`.
fn idRoundTrip(
    comptime get: IdGetter,
    comptime set: IdSetter,
    comptime clear: IdClearer,
) !void {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(get(&properties) == null);

    const stored: NodeId = .{ .value = 7 };
    try set(&properties, stored);
    try testing.expectEqual(stored, get(&properties).?);

    clear(&properties);
    try testing.expect(get(&properties) == null);
}

test "children" {
    try listRoundTrip(children, setChildren, pushChild, clearChildren);
}

test "controls" {
    try listRoundTrip(controls, setControls, pushControlled, clearControls);
}

test "details" {
    try listRoundTrip(details, setDetails, pushDetail, clearDetails);
}

test "described_by" {
    try listRoundTrip(describedBy, setDescribedBy, pushDescribedBy, clearDescribedBy);
}

test "flow_to" {
    try listRoundTrip(flowTo, setFlowTo, pushFlowTo, clearFlowTo);
}

test "labelled_by" {
    try listRoundTrip(labelledBy, setLabelledBy, pushLabelledBy, clearLabelledBy);
}

test "owns" {
    try listRoundTrip(owns, setOwns, pushOwned, clearOwns);
}

test "radio_group" {
    try listRoundTrip(radioGroup, setRadioGroup, pushToRadioGroup, clearRadioGroup);
}

test "active_descendant" {
    try idRoundTrip(activeDescendant, setActiveDescendant, clearActiveDescendant);
}

test "error_message" {
    try idRoundTrip(errorMessage, setErrorMessage, clearErrorMessage);
}

test "in_page_link_target" {
    try idRoundTrip(inPageLinkTarget, setInPageLinkTarget, clearInPageLinkTarget);
}

test "member_of" {
    try idRoundTrip(memberOf, setMemberOf, clearMemberOf);
}

test "next_on_line" {
    try idRoundTrip(nextOnLine, setNextOnLine, clearNextOnLine);
}

test "previous_on_line" {
    try idRoundTrip(previousOnLine, setPreviousOnLine, clearPreviousOnLine);
}

test "popup_for" {
    try idRoundTrip(popupFor, setPopupFor, clearPopupFor);
}

test "a list getter hands back the store's own array, not a copy" {
    // A getter that copied the array would allocate a second one per call, so
    // the two reads below would not share an address. The equality is the whole
    // claim: the slice borrows the array the store will grow and free.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setChildren(&properties, &[_]NodeId{ .{ .value = 1 }, .{ .value = 2 } });

    const first_read = children(&properties);
    const second_read = children(&properties);

    try testing.expectEqual(@intFromPtr(first_read.ptr), @intFromPtr(second_read.ptr));
    try testing.expectEqualSlices(
        NodeId,
        &[_]NodeId{ .{ .value = 1 }, .{ .value = 2 } },
        first_read,
    );
}

test "a single-id getter reads through to the store after an overwrite" {
    // A getter that captured the value at set time, or that cached the last
    // read, answers the first id here. `copy_type_setters!` at
    // `accesskit/src/lib.rs:1271-1279` writes the slot, so the second read must
    // see the second write.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setMemberOf(&properties, .{ .value = 1 });
    try testing.expectEqual(@as(u64, 1), memberOf(&properties).?.value);

    try setMemberOf(&properties, .{ .value = 2 });
    try testing.expectEqual(@as(u64, 2), memberOf(&properties).?.value);

    clearMemberOf(&properties);
    try testing.expect(memberOf(&properties) == null);
}

test "a list property and a single-id property hold different payloads" {
    // Both accessors take a `PropertyId` and read one arm of `PropertyValue`.
    // A port that read the wrong arm, or that dropped the id, makes one of
    // these two answers wrong while every round trip above still passes.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setChildren(&properties, &[_]NodeId{.{ .value = 1 }});
    try testing.expect(activeDescendant(&properties) == null);

    clearChildren(&properties);
    try setActiveDescendant(&properties, .{ .value = 2 });
    try testing.expectEqual(@as(usize, 0), children(&properties).len);
}

test "clearing one id property leaves the others in the store" {
    // Upstream's clearer is `properties.clear(id)`
    // (`accesskit/src/lib.rs:1148-1153`), which touches one entry. A port that
    // cleared the whole store still passes every round trip above.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setMemberOf(&properties, .{ .value = 1 });
    try setPopupFor(&properties, .{ .value = 2 });

    clearMemberOf(&properties);

    try testing.expect(memberOf(&properties) == null);
    try testing.expectEqual(@as(u64, 2), popupFor(&properties).?.value);
}

test "one store holds a list and an id at the same time" {
    // `PropertyValue` is a tagged union, so a list payload and a scalar payload
    // are two arms of one entry array. A store that dropped the second write
    // leaves the list short.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setLabelledBy(&properties, &[_]NodeId{.{ .value = 5 }});
    try setPopupFor(&properties, .{ .value = 6 });

    try testing.expectEqualSlices(NodeId, &[_]NodeId{.{ .value = 5 }}, labelledBy(&properties));
    try testing.expectEqual(@as(u64, 6), popupFor(&properties).?.value);
}

test "an empty list is stored, not refused" {
    // `setter_should_update_the_property` at
    // `accesskit/src/lib.rs:1366-1372` stores an empty list and reads an empty
    // list back, so a port that refused an empty slice would fail upstream's own
    // test for every one of the 8 list properties.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setOwns(&properties, &.{});
    try testing.expectEqual(@as(usize, 0), owns(&properties).len);

    try pushOwned(&properties, .{ .value = 9 });
    try testing.expectEqualSlices(NodeId, &[_]NodeId{.{ .value = 9 }}, owns(&properties));
}

test "the zero id is a value, not an absent property" {
    // Upstream's scalar getters answer `Option<NodeId>`, and upstream's own
    // tests store `NodeId(0)` and read `Some(NodeId(0))`
    // (`accesskit/src/lib.rs:1430-1435`). A port that treated the zero content
    // as unset fails here.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setErrorMessage(&properties, ids.nodeIdFromContent(0));

    try testing.expectEqual(@as(u64, 0), errorMessage(&properties).?.value);
}

test "the largest id content survives the store" {
    // A getter that narrows the 64-bit content, or a setter that stores a
    // `usize` where the content is 64 bits, loses the top bit here.
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    const widest = ids.nodeIdFromContent(std.math.maxInt(u64));
    try setNextOnLine(&properties, widest);
    try pushChild(&properties, widest);

    try testing.expect(widest.eql(nextOnLine(&properties).?));
    try testing.expectEqualSlices(NodeId, &[_]NodeId{widest}, children(&properties));
}
