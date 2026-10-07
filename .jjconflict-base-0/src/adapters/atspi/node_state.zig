//! The set of AT-SPI states one node reports, and the predicate the port calls
//! it through.
//!
//! **Upstream.** `accesskit_atspi_common/src/node.rs:301-389` is
//! `NodeWrapper::state` and `node.rs:1002-1008` is `PlatformNode::state`, which
//! forwards to it and answers the one-member `defunct` set when the node is gone.
//! `docs/41-atspi-build-map.md` section 1.4 records `au` as the wire type of
//! `Accessible.GetState`.
//!
//! **Why this module is the one that unblocks `StateChanged`.**
//! `platform_adapter.zig` records the gap in its module doc: a `StateChanged`
//! needs this map and the map was not ported, so an update raises `Focus` and
//! nothing else. The set is a pure function of one node and one flag, so it is
//! testable here with a fixture tree and no bus.
//!
//! **The order of the inserts does not matter and the order of the conditions
//! does.** A `StateSet` is a bit set, so two conditions that both hold insert
//! two bits and the answer is the same either way. What the order does fix is
//! which condition wins a disagreement, and there is exactly one of those: a
//! node that is both read only and not read-only-supported reports `read_only`
//! and not `enabled` with `sensitive`, at `node.rs:376-382`.
//!
//! **Two inputs are not the node's own.** `is_window_focused` decides the
//! `active` state of a window or of the active dialog, at `node.rs:305-311`,
//! because a window in a window that has lost focus is not active. The
//! `focused` state at `node.rs:384-386` reads the tree's own focus id instead
//! and takes no flag. Passing the same flag to both is a defect and the two
//! tests at the end of this file name the difference.
//!
//! **No allocator.** Every input is a scalar, a flag read off the node, or a
//! walk of the tree, so the answer is one `u64` of packed bits.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const node_role = @import("node_role.zig");
const schema = @import("../../schema/root.zig");
const wire = @import("wire.zig");
const assert = std.debug.assert;

const FilterFn = consumer.filter.FilterFn;
const FilterResult = consumer.filter.FilterResult;
const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree.QueryError;
const StateSet = wire.StateSet;

/// Upstream `filters.rs` `filter`, which every filtered walk in this module
/// uses. The port's `commonFilter` takes the node directly, so this is the
/// one-line adapter that puts it behind the `FilterFn` the walks ask for.
fn commonFilterTrampoline(context: ?*anyopaque, node: NodeRef) QueryError!FilterResult {
    // Upstream `filters.rs:39-41` asserts the same thing, for the same reason:
    // the filter holds no state, so a caller that supplied some is a caller that
    // expects it to be read.
    assert(context == null);
    return consumer.filter.commonFilter(node);
}

/// The filter every walk in this module passes, built once because it holds no
/// state.
pub const node_filter: FilterFn = .{ .context = null, .filter = commonFilterTrampoline };

/// The states `node` reports, given whether the window that holds it has focus.
///
/// `is_window_focused` is `tree.state().focus_id().is_some()` at `node.rs:967`,
/// which is the flag the tree itself keeps and the flag that decides the
/// `active` state.
///
/// **Errors.** `error.TreeCycle` from the focusability test, the filter, and the
/// active-dialog walk. Nothing is written, so the tree is the same before and
/// after the call.
pub fn stateOf(node: NodeRef, is_window_focused: bool) QueryError!StateSet {
    const accesskit_role = consumer.node_ref.properties.role(node);
    const atspi_role = node_role.roleOf(node);
    var out: StateSet = .empty;

    // `node.rs:305-311`. A top-level window, or the dialog the tree names as
    // active, is active while its window holds focus.
    if (is_window_focused and
        ((consumer.node_ref.hierarchy.parentId(node) == null and accesskit_role == .window) or
            (consumer.node_ref.predicates.isDialog(node) and try isActiveDialog(node))))
    {
        out.insert(.active);
    }

    // `node.rs:312-314`.
    if (consumer.node_ref.predicates.isTextInput(node) and
        !consumer.node_ref.predicates.isReadOnly(node))
    {
        out.insert(.editable);
    }

    // `node.rs:316-318`.
    if (try consumer.node_ref.predicates.isFocusable(node, node_filter)) {
        out.insert(.focusable);
    }

    // `node.rs:319-322`. A node the filter clips away is not visible and not
    // showing, which is the whole of what the check means.
    if (try node_filter.call(node) == .include) {
        out.insert(.visible);
        out.insert(.showing);
    }

    // `node.rs:323-328`.
    if (consumer.node_ref.set_state.isRequired(node)) {
        out.insert(.required);
    }
    if (consumer.node_ref.predicates.isMultiselectable(node)) {
        out.insert(.multi_selectable);
    }

    // `node.rs:329-335`.
    if (consumer.node_ref.predicates.orientation(node)) |orientation| {
        out.insert(switch (orientation) {
            .horizontal => .horizontal,
            .vertical => .vertical,
        });
    }

    // `node.rs:336-338`. A toggle button is checkable by its role, so the
    // condition excludes it rather than adding a state the role already implies.
    if (atspi_role != .toggle_button and
        consumer.node_ref.properties.toggled(node) != null)
    {
        out.insert(.checkable);
    }

    // `node.rs:339-344`.
    if (consumer.node_ref.properties.isBusy(node)) {
        out.insert(.busy);
    }
    if (consumer.node_ref.predicates.isModal(node)) {
        out.insert(.modal);
    }

    // `node.rs:345-352`. A node that states no selection is neither selectable
    // nor selected; a node that states `false` is selectable and not selected.
    if (consumer.node_ref.properties.isSelected(node)) |selected| {
        if (!consumer.node_ref.properties.isDisabled(node)) {
            out.insert(.selectable);
        }
        if (selected) {
            out.insert(.selected);
        }
    }

    // `node.rs:353-359`.
    if (consumer.node_ref.predicates.isTextInput(node)) {
        out.insert(.selectable_text);
        out.insert(if (consumer.node_ref.predicates.isMultiline(node))
            .multi_line
        else
            .single_line);
    }

    // `node.rs:361-364`. A progress indicator with no value is running without
    // a known fraction.
    if (accesskit_role == .progress_indicator and
        consumer.node_ref.properties.numericValue(node) == null)
    {
        out.insert(.indeterminate);
    }

    // `node.rs:366-374`.
    switch (consumer.node_ref.properties.toggled(node) orelse .false_) {
        .mixed => out.insert(.indeterminate),
        .true_ => out.insert(if (atspi_role == .toggle_button) .pressed else .checked),
        .false_ => {},
    }

    // `node.rs:376-382`. A disabled node states none of the three. A node that
    // is read only states `read_only` and not `enabled` with `sensitive`.
    if (!consumer.node_ref.properties.isDisabled(node)) {
        if (consumer.node_ref.predicates.isReadOnlySupported(node) and
            consumer.node_ref.predicates.isReadOnly(node))
        {
            out.insert(.read_only);
        } else {
            out.insert(.enabled);
            out.insert(.sensitive);
        }
    }

    // `node.rs:384-386`. This is the tree's own focus, not the window's.
    if (consumer.node_ref.predicates.isFocused(node)) {
        out.insert(.focused);
    }

    return out;
}

/// Whether `node` is the dialog the tree names as active, which is the nearest
/// dialog at or above the focus.
///
/// `TreeState.activeDialog` at `consumer/tree_state.zig:525` answers
/// `QueryError!NodeRef`, where upstream returns an optional. It reports
/// `error.NoSuchNode` when the host holds no focus or when the chain from the
/// focus reaches the root without a dialog, and upstream answered `None` for
/// both. This function catches that one tag and answers `false`, so a node
/// that is not the active dialog is not active rather than a failed state
/// read. `error.TreeCycle` propagates, because the port's own bounded walk is
/// what raises it and upstream had no such tag.
///
/// The comparison is on node ids rather than handles, because the two handles
/// come from two separate lookups and only the ids are the same value.
///
/// **Errors.** `error.TreeCycle` from the walk to the root.
fn isActiveDialog(node: NodeRef) QueryError!bool {
    const active = node.tree_state.activeDialog() catch |err| switch (err) {
        error.NoSuchNode => return false,
        else => |other| return other,
    };
    return std.meta.eql(active.id(), node.id());
}

const testing = std.testing;

/// Stores `node` under `value` with `parent` as its parent id, so a test can
/// build a tree without the update algorithm. `consumer/text/query.zig:434`.
fn insert(
    gpa: std.mem.Allocator,
    state: *consumer.tree_state.TreeState,
    value: u64,
    parent: ?u64,
    node: schema.Node,
) !void {
    const id = consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0));
    const parent_and_index: ?consumer.tree_index.ParentAndIndex = if (parent) |parent_value|
        .{
            .parent_id = consumer.tree_index.FullNodeId.init(
                .{ .value = parent_value },
                .init(0),
            ),
            .index = 0,
        }
    else
        null;
    try state.nodes.put(gpa, id, .{
        .parent_and_index = parent_and_index,
        .data = node,
    });
}

/// The handle to the node stored under `value`.
fn handle(state: *const consumer.tree_state.TreeState, value: u64) !NodeRef {
    return NodeRef.init(
        state,
        consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0)),
    ) orelse error.NodeMissingFromFixture;
}

/// A tree with one root and no focus and no host focus, which is the state
/// every test below starts from.
fn rootState(gpa: std.mem.Allocator, state: *consumer.tree_state.TreeState, role: schema.Role) !void {
    try insert(gpa, state, 0, null, schema.Node.init(gpa, role));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.is_host_focused = false;
}

test "a node the filter includes is visible and showing" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.visible));
    try testing.expect(reported.contains(.showing));
}

test "a node that is not disabled and is not read only is enabled and sensitive" {
    // `node.rs:380-381`. A group has no read-only state, so it takes the else
    // arm, which is the common case.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.enabled));
    try testing.expect(reported.contains(.sensitive));
    try testing.expect(!reported.contains(.read_only));
}

test "a disabled node states none of the three" {
    // `node.rs:376` is the condition, and the whole body is inside it.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .group);
    errdefer node.deinit();
    // `setDisabled` at `schema/props/flags.zig:238` takes `*u32` and a value,
    // because the 18 flags have no property id and live in the node's own word.
    schema.flags.setDisabled(&node.flags, true);
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(!reported.contains(.enabled));
    try testing.expect(!reported.contains(.sensitive));
    try testing.expect(!reported.contains(.read_only));
}

test "a text input that is not read only is editable and single line" {
    // `node.rs:312-314` and `:353-358`. The two conditions are separate and
    // both hold here, so both answer.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .text_input);

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.editable));
    try testing.expect(reported.contains(.selectable_text));
    try testing.expect(reported.contains(.single_line));
    try testing.expect(!reported.contains(.multi_line));
}

test "a multiline text input is multiline and not single line" {
    // `node.rs:355-358`. The two are exclusive, so a check on one alone would
    // pass for a port that inserted both.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .multiline_text_input);

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.multi_line));
    try testing.expect(reported.contains(.single_line) == false);
}

test "a checkbox that states selected is selectable and selected" {
    // `node.rs:345-352`. A node that states no selection answers neither, so
    // the fixture has to state one.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .check_box);
    errdefer node.deinit();
    try schema.enums.setSelected(&node.properties, true);
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.selectable));
    try testing.expect(reported.contains(.selected));
    // A check box is not a toggle button, so the toggled check at `:336` would
    // add `checkable` only when it carries a toggled state. It does not here.
    try testing.expect(!reported.contains(.checkable));
}

test "a mixed toggle is indeterminate and a pressed toggle is pressed" {
    // `node.rs:366-374`. The two arms read the toggled state, and the pressed
    // arm needs the toggle button role, which is what a switch maps to.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .switch_);

    const mixed_entry = try entry(&state);
    try schema.enums.setToggled(&mixed_entry.data.properties, .mixed);
    const mixed = try stateOf(try handle(&state, 0), false);
    try testing.expect(mixed.contains(.indeterminate));
    // A toggle button carries a toggled state and is not checkable by role, so
    // `:336-338` adds nothing and `:369-370` adds `pressed` only for `true`.
    try testing.expect(!mixed.contains(.pressed));

    try schema.enums.setToggled(&mixed_entry.data.properties, .true_);
    const pressed = try stateOf(try handle(&state, 0), false);
    try testing.expect(pressed.contains(.pressed));
    try testing.expect(!pressed.contains(.checked));
}

test "a progress indicator with no value is indeterminate" {
    // `node.rs:361-364`. This is the arm that has nothing to do with a toggle.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .progress_indicator);

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.indeterminate));

    const entry_value = try entry(&state);
    try schema.numbers.setNumericValue(&entry_value.data.properties, 3.0);
    const with_value = try stateOf(try handle(&state, 0), false);
    try testing.expect(!with_value.contains(.indeterminate));
}

test "a window is active only while its window holds focus" {
    // `node.rs:305-311`. This is the one state that reads the flag rather than
    // the node, so the flag has to move for the test to mean anything.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .window);

    const blurred = try stateOf(try handle(&state, 0), false);
    try testing.expect(!blurred.contains(.active));
    const focused = try stateOf(try handle(&state, 0), true);
    try testing.expect(focused.contains(.active));
}

test "a window with a parent is not active" {
    // `node.rs:306` requires `parent_id().is_none()`, so a nested window takes
    // the second arm or neither.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try insert(gpa, &state, 0, null, schema.Node.init(gpa, .group));
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .window));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const reported = try stateOf(try handle(&state, 1), true);
    try testing.expect(!reported.contains(.active));
}

test "the focused state reads the tree and not the window flag" {
    // `node.rs:384-386` and `predicates.zig:77`. A blurred window with a focus
    // in the tree reports no focus at all, which is the answer a client needs.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);

    const blurred = try stateOf(try handle(&state, 0), false);
    try testing.expect(!blurred.contains(.focused));
    state.is_host_focused = true;
    const focused = try stateOf(try handle(&state, 0), false);
    try testing.expect(focused.contains(.focused));
}

test "a stated orientation answers horizontal and vertical, and the two exclude" {
    // `node.rs:329-335`. The two conditions are exclusive: one answers
    // `horizontal` and the other `vertical`, never both and never neither.
    //
    // The fixture states the property rather than naming two roles, because
    // that is what the predicate reads first. `orientation` at
    // `predicates.zig:121` answers the stored `orientation` when the node
    // declares one, and only falls back to the role for the two roles that have
    // no direction to declare: a list box is vertical and a tab list is
    // horizontal. A scroll bar and a combo box answer `null` from either path,
    // so a fixture built on those two roles asserts a direction the port does
    // not produce for them.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .group));
    try insert(gpa, &state, 2, 0, schema.Node.init(gpa, .group));

    // Written through the map's own entry: `NodeState.data` is copied by value,
    // so a local node and the map's entry would share one property buffer and
    // release it twice. `consumer/tree_state.zig:234` names that trap.
    const across = try entryOf(&state, 1);
    try schema.enums.setOrientation(&across.data.properties, .horizontal);
    const down = try entryOf(&state, 2);
    try schema.enums.setOrientation(&down.data.properties, .vertical);

    const horizontal = try stateOf(try handle(&state, 1), false);
    try testing.expect(horizontal.contains(.horizontal));
    try testing.expect(!horizontal.contains(.vertical));

    const vertical = try stateOf(try handle(&state, 2), false);
    try testing.expect(vertical.contains(.vertical));
    try testing.expect(!vertical.contains(.horizontal));
}

test "a list box is vertical and a tab list is horizontal with no stated property" {
    // The role fallback in `orientation` at `predicates.zig:123`, which is the
    // other half of the condition `node.rs:329` reads. These two roles have no
    // direction to lay out, so the role is the whole answer.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .list_box));
    try insert(gpa, &state, 2, 0, schema.Node.init(gpa, .tab_list));

    const list = try stateOf(try handle(&state, 1), false);
    try testing.expect(list.contains(.vertical));
    try testing.expect(!list.contains(.horizontal));

    const tabs = try stateOf(try handle(&state, 2), false);
    try testing.expect(tabs.contains(.horizontal));
    try testing.expect(!tabs.contains(.vertical));
}

/// The map entry for the node stored under `value`.
fn entryOf(state: *consumer.tree_state.TreeState, value: u64) !*consumer.tree_state.NodeState {
    return state.nodes.getPtr(consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0))) orelse
        error.NodeMissingFromFixture;
}

test "a node that states a selection of false is selectable and not selected" {
    // `node.rs:345-352`. The two inserts are separate conditions, so a port that
    // tied them together would answer both here.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    // `schema.Role` has no `option`: the ARIA role is `list_box_option`, at
    // `schema/role.zig:58`. The state test does not read the role, so this is
    // the name the value is filed under.
    var node = schema.Node.init(gpa, .list_box_option);
    errdefer node.deinit();
    try schema.enums.setSelected(&node.properties, false);
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.selectable));
    try testing.expect(!reported.contains(.selected));
}

test "a disabled node that states selected is selected and not selectable" {
    // `node.rs:346-348`. The two inserts are guarded by different conditions.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .check_box);
    errdefer node.deinit();
    try schema.enums.setSelected(&node.properties, true);
    schema.flags.setDisabled(&node.flags, true);
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const reported = try stateOf(try handle(&state, 0), false);
    try testing.expect(reported.contains(.selected));
    try testing.expect(!reported.contains(.selectable));
}

test "a node states no more states than the wire declares" {
    // Every bit the function sets has to be a bit `StateSet` reserves, or a
    // client decodes a state the reference does not name.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try insert(gpa, &state, 0, null, schema.Node.init(gpa, .window));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const reported = try stateOf(try handle(&state, 0), true);
    var outside: u64 = 0;
    inline for (comptime std.enums.values(wire.State)) |member| {
        const bit = @as(u64, 1) << @as(u6, @intFromEnum(member));
        if (reported.bits & bit != 0) outside |= bit;
    }
    try testing.expectEqual(reported.bits, outside);
}

/// The map entry for the one node in the fixture, which is where a test writes.
fn entry(state: *consumer.tree_state.TreeState) !*consumer.tree_state.NodeState {
    return state.nodes.getPtr(consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0))) orelse
        error.NodeMissingFromFixture;
}
