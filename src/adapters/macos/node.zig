//! The node wrapper and the five answers it gives, upstream
//! `AK/macos/src/node.rs:302-382`.
//!
//! **What this module is.** `NodeWrapper` is the one-field newtype over a
//! `NodeRef` that `AK/macos/src/node.rs:309` declares, and `title`, `label`,
//! `description`, `placeholder` and `value` are its five methods. `Value` is
//! the three-payload enum of `:302-307`. The two comparison helpers at the end
//! are the ones `AK/macos/src/event.rs:264` and `:270-271` write as
//! `old_wrapper.title() != new_wrapper.title()` and
//! `old_wrapper.value() != new_wrapper.value()`, and `event.rs:236` and
//! `:300-302` read the label through the same method.
//!
//! **Why the wrapper is a struct and not a free function.** Upstream needs it
//! because the methods are called from a `declare_class!` body, where `self` is
//! the Objective-C object. The port has no such body, so the struct is the port
//! of the type rather than a helper, and `events.zig` builds one per node.
//!
//! **Where the answers live.** `labelIsExposedInValue` is at
//! `roles.zig:432`, which ports `AK/macos/src/node.rs:233-242`. Every property
//! read is a `consumer.node_ref` call, so this module adds no tree walk of its
//! own and needs no loop bound.
//!
//! **Who reads a wrapper.** `events.zig` at `slotNodeAdded` and
//! `slotNodeUpdated`. The `accessibilityTitle`, `accessibilityHelp`,
//! `accessibilityPlaceholderValue` and `accessibilityValue` selectors of
//! `AK/macos/src/node.rs:534-578` are the other reader upstream, and the port
//! holds those four as table rows in `attributes.zig` with no body, because
//! answering them needs an Objective-C object.
//!
//! **The allocator.** Every method that builds a buffer takes the allocator from
//! the struct, so a caller cannot answer with a buffer from a second allocator.
//! A `null` answer means nothing was written and there is nothing to release.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const roles = @import("roles.zig");
const schema = @import("../../schema/root.zig");

const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;
const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree_state.QueryError;
const testing = std.testing;

/// What the five methods can report.
///
/// `QueryError` comes from the consumer walks behind the label, the value and
/// the placeholder. `std.Io.Writer.Error` comes from the collecting writer the
/// consumer builds those two with, and `labelText` and `valueText` map its one
/// tag to `error.OutOfMemory`, because a failed growth is the only way that
/// writer fails.
pub const NodeError = QueryError || std.Io.Writer.Error;

/// The interpreted value of a node, upstream `AK/macos/src/node.rs:302-307`.
///
/// Upstream writes an enum of a bool, a number and a string and derives
/// `PartialEq` on it, so this writes a tagged union with the same three payloads
/// and an `eql` that answers the same question. `attributes.ValueShape` is the
/// class-name view of the same three tags, and it stays because
/// `attributes.valueClassName` is keyed on the tag alone rather than on the
/// payload.
pub const Value = union(enum) {
    /// `Value::Bool`. A toggled state, or the selection state of a tab.
    boolean: bool,
    /// `Value::Number`. The numeric value.
    number: f64,
    /// `Value::String`. The value, or the label of a role that exposes it.
    string: ArrayList(u8),

    /// Releases the string payload and owns nothing for the other two.
    ///
    /// The list is copied into a mutable binding because a capture of a `const`
    /// operand is a `*const` and `ArrayList.deinit` takes `*Self`.
    pub fn deinit(self: Value, gpa: Allocator) void {
        switch (self) {
            .boolean, .number => {},
            .string => |text| {
                var owned = text;
                owned.deinit(gpa);
            },
        }
    }

    /// Whether two answers are the same value, upstream's `PartialEq`.
    ///
    /// An absent value is equal to an absent value and to nothing else, which is
    /// the `Option` half of upstream's `!=`. Two answers of different tags are
    /// never equal, and that test comes first so the field read below cannot
    /// name a tag the other answer does not carry.
    pub fn eql(a: ?Value, b: ?Value) bool {
        const left = a orelse return b == null;
        const right = b orelse return false;
        if (std.meta.activeTag(left) != std.meta.activeTag(right)) return false;
        return switch (left) {
            .boolean => |flag| flag == right.boolean,
            .number => |number| number == right.number,
            .string => |text| std.mem.eql(u8, text.items, right.string.items),
        };
    }
};

/// One tree node with the five answers `AK/macos/src/node.rs:311-382` gives it.
pub const NodeWrapper = struct {
    /// The allocator every buffer the methods build came from.
    gpa: Allocator,
    /// The node the answers are read from.
    node: NodeRef,

    /// A wrapper over `node` that builds its buffers from `gpa`.
    pub fn init(gpa: Allocator, node: NodeRef) NodeWrapper {
        return .{ .gpa = gpa, .node = node };
    }

    /// `NodeRef::is_root`, upstream `:312-314`.
    pub fn isRoot(self: NodeWrapper) bool {
        return consumer.node_ref.hierarchy.isRoot(self.node);
    }

    /// The title `accessibilityTitle` answers, upstream `:316-326`.
    ///
    /// The window the adapter exposes for the tree reports no title, because a
    /// group element with a title breaks VoiceOver, and the five roles that
    /// carry their label in their value report none either, because
    /// `accessibilityLabel` already carries it. Everything else answers the
    /// node's own label.
    pub fn title(self: NodeWrapper) NodeError!?ArrayList(u8) {
        const role = consumer.node_ref.properties.role(self.node);
        if (self.isRoot() and role == .window) return null;
        if (roles.labelIsExposedInValue(role)) return null;
        return self.label();
    }

    /// The label `accessibilityLabel` would answer, upstream `:328-334`.
    ///
    /// A node whose label comes from its value answers the value, and every
    /// other node answers its label. The two reads are `Node::value` and
    /// `Node::label`, which is what `self.0` names upstream, so neither arm goes
    /// through `value` below.
    pub fn label(self: NodeWrapper) NodeError!?ArrayList(u8) {
        if (consumer.node_ref.strings.labelComesFromValue(self.node)) {
            return valueText(self.gpa, self.node);
        }
        return labelText(self.gpa, self.node);
    }

    /// The description `accessibilityHelp` answers, upstream `:336-338`.
    pub fn description(self: NodeWrapper) NodeError!?ArrayList(u8) {
        return consumer.node_ref.strings.description(self.gpa, self.node);
    }

    /// The placeholder `accessibilityPlaceholderValue` answers, upstream
    /// `:340-342`.
    ///
    /// The buffer is the node's own, so there is nothing to release.
    pub fn placeholder(self: NodeWrapper) QueryError!?[]const u8 {
        return consumer.node_ref.strings.placeholder(self.node);
    }

    /// The value `accessibilityValue` answers, upstream `:344-365`.
    ///
    /// The four arms are upstream's and the order is upstream's: a toggled state
    /// answers a bool, a tab answers the selection state because macOS exposes a
    /// tab as a radio button, a role that exposes its label in its value answers
    /// that label, and everything else answers the value, then the numeric
    /// value, then nothing.
    pub fn value(self: NodeWrapper) NodeError!?Value {
        const properties = consumer.node_ref.properties;
        if (properties.toggled(self.node)) |toggled| {
            return Value{ .boolean = toggled != .false_ };
        }
        const role = properties.role(self.node);
        if (role == .tab) {
            return Value{ .boolean = properties.isSelected(self.node) orelse false };
        }
        if (roles.labelIsExposedInValue(role)) {
            if (try labelText(self.gpa, self.node)) |label_text| {
                return Value{ .string = label_text };
            }
        }
        if (try valueText(self.gpa, self.node)) |text| {
            return Value{ .string = text };
        }
        if (properties.numericValue(self.node)) |number| {
            return Value{ .number = number };
        }
        return null;
    }
};

/// Whether two answers are the same text or the same absence.
///
/// The two absent arms are the ones a title change turns on: a node that loses
/// its title changed, and a node that never had one did not.
pub fn textEql(a: ?ArrayList(u8), b: ?ArrayList(u8)) bool {
    const left = a orelse return b == null;
    const right = b orelse return false;
    return std.mem.eql(u8, left.items, right.items);
}

/// Releases an answer that owns a buffer. A `null` answer owns nothing.
///
/// The list is copied into a mutable binding because the parameter is `const`,
/// so a capture from it is a `*const` and `ArrayList.deinit` takes `*Self`.
pub fn releaseText(gpa: Allocator, text: ?ArrayList(u8)) void {
    var answer = text orelse return;
    answer.deinit(gpa);
}

/// Releases an answer that may own a buffer. A `null` answer owns nothing.
pub fn releaseValue(gpa: Allocator, value: ?Value) void {
    if (value) |owned| owned.deinit(gpa);
}

/// Whether the two nodes carry different titles, upstream
/// `AK/macos/src/event.rs:264`.
///
/// Both answers are built and both are released, so a caller that asks the
/// question twenty times over an update allocates and frees twice per question.
pub fn titlesDiffer(gpa: Allocator, old: NodeRef, new: NodeRef) NodeError!bool {
    const old_title = try NodeWrapper.init(gpa, old).title();
    defer releaseText(gpa, old_title);
    const new_title = try NodeWrapper.init(gpa, new).title();
    defer releaseText(gpa, new_title);
    return !textEql(old_title, new_title);
}

/// What one value comparison produced, upstream `AK/macos/src/event.rs:270-272`.
///
/// Upstream computes `new_wrapper.value()` once and asks the same answer twice:
/// once for the `!=` and once for `matches!(v, Value::Bool(_))`. This carries
/// both, so the caller builds one value and not two.
pub const ValueChange = struct {
    /// Whether the two answers differ, which is upstream's `!=`.
    differs: bool,
    /// The value the new node carries, which the caller releases.
    value: ?Value,

    /// Releases the value. A `null` value owns nothing.
    pub fn deinit(self: ValueChange, gpa: Allocator) void {
        releaseValue(gpa, self.value);
    }
};

/// Compares the two nodes' interpreted values, upstream
/// `AK/macos/src/event.rs:270-271`.
///
/// This is the interpreted value and not the raw one: a node whose toggled state
/// changed carries no raw value at all, so a comparison on the raw bytes answers
/// that nothing changed where upstream answers that the value changed.
pub fn valueChange(gpa: Allocator, old: NodeRef, new: NodeRef) NodeError!ValueChange {
    const old_value = try NodeWrapper.init(gpa, old).value();
    defer releaseValue(gpa, old_value);
    const new_value = try NodeWrapper.init(gpa, new).value();
    return .{
        .differs = !Value.eql(old_value, new_value),
        .value = new_value,
    };
}

/// Whether an answer is the bool shape, upstream's `matches!(v, Value::Bool(_))`
/// at `AK/macos/src/event.rs:272`.
///
/// Two of the four arms of `value` answer a bool: a toggled state and the
/// selection state of a tab. A port that reads only the toggled state answers
/// `false` for a tab, and the event order is then upstream's reverse.
pub fn isBoolean(value: ?Value) bool {
    const answer = value orelse return false;
    return std.meta.activeTag(answer) == .boolean;
}

/// The label of `node` as a buffer the caller owns.
///
/// This is `strings.label` with the one tag the collecting writer adds mapped to
/// `error.OutOfMemory`.
fn labelText(gpa: Allocator, node: NodeRef) NodeError!?ArrayList(u8) {
    return consumer.node_ref.strings.label(gpa, node) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

/// The value of `node` as a buffer the caller owns.
///
/// This is `set_state.value` with the same mapping as `labelText`.
fn valueText(gpa: Allocator, node: NodeRef) NodeError!?ArrayList(u8) {
    return consumer.node_ref.set_state.value(gpa, node) catch |err| switch (err) {
        error.WriteFailed => error.OutOfMemory,
        else => |other| other,
    };
}

// --- tests ----------------------------------------------------------------------

/// One node of the fixture tree the tests drive.
const Spec = struct {
    /// The identifier inside the root tree.
    local: u64,
    /// The role the node declares.
    role: schema.Role = .generic_container,
    /// The children of the node, in order.
    children: []const u64 = &.{},
    /// The label the node carries, or none.
    label: ?[]const u8 = null,
    /// The value the node carries, or none.
    value: ?[]const u8 = null,
    /// The description the node carries, or none.
    description: ?[]const u8 = null,
    /// The placeholder the node carries, or none.
    placeholder: ?[]const u8 = null,
    /// The toggled state the node carries, or none.
    toggled: ?schema.Toggled = null,
    /// The selection state the node carries, or none.
    is_selected: ?bool = null,
    /// The numeric value the node carries, or none.
    numeric_value: ?f64 = null,
};

/// Builds the tree `specs` describes, rooted at `root_local`.
///
/// `Tree.init` takes the update by value and releases it whatever it answers, so
/// the binding is spent and there is no `deinit` for the update. The tree itself
/// has one, and the tests call it.
fn buildTree(gpa: Allocator, root_local: u64, specs: []const Spec) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    for (specs) |spec| {
        var node = schema.Node.init(gpa, spec.role);
        if (spec.label) |text| try schema.strings.setLabel(&node.properties, text);
        if (spec.value) |text| try schema.strings.setValue(&node.properties, text);
        if (spec.description) |text| try schema.strings.setDescription(&node.properties, text);
        if (spec.placeholder) |text| try schema.strings.setPlaceholder(&node.properties, text);
        if (spec.toggled) |state| try schema.enums.setToggled(&node.properties, state);
        if (spec.is_selected) |state| try schema.enums.setSelected(&node.properties, state);
        if (spec.numeric_value) |number| {
            try schema.numbers.setNumericValue(&node.properties, number);
        }
        var child_ids: ArrayList(schema.NodeId) = .empty;
        defer child_ids.deinit(gpa);
        for (spec.children) |child| {
            try child_ids.append(gpa, .{ .value = child });
        }
        try schema.ids_props.setChildren(&node.properties, child_ids.items);
        try update.pushNode(gpa, .{ .value = spec.local }, node);
    }
    update.tree = schema.TreeInfo.init(.{ .value = root_local });
    update.focus = .{ .value = root_local };
    const built = consumer.tree.Tree.init(gpa, update, true);
    // `Tree.init` released the update on every path, so the binding is emptied
    // before the `errdefer` above can run a second release over freed memory.
    update = .{};
    return built catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TreeRejectedTheUpdate,
    };
}

/// The node `local` in `tree`, or an error rather than a trap.
fn nodeOf(tree: *const consumer.tree.Tree, local: u64) !NodeRef {
    const state = tree.stateOf();
    return state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
        error.MissingNode;
}

/// An `ArrayList(u8)` that owns a copy of `text`.
///
/// `ArrayList.fromOwnedSlice` is the 0.16 member that takes over a slice the
/// caller already owns, and a string literal is not one, so the buffer is
/// allocated and filled. The caller releases the answer with `releaseText`.
fn ownedText(gpa: Allocator, text: []const u8) !ArrayList(u8) {
    var owned = try ArrayList(u8).initCapacity(gpa, text.len);
    errdefer owned.deinit(gpa);
    try owned.appendSlice(gpa, text);
    return owned;
}

test "the window the adapter exposes for the tree reports no title" {
    // `AK/macos/src/node.rs:317-321` drops the title of a root window because a
    // group element with a title breaks VoiceOver. The root of the fixture tree
    // is a window, so the arm needs no second tree.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{2}, .label = "window" },
        .{ .local = 2, .role = .generic_container },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const root = NodeWrapper.init(gpa, try nodeOf(&tree, 1));
    try testing.expect(root.isRoot());
    try testing.expectEqual(@as(?ArrayList(u8), null), try root.title());

    // The same label on a node that is not the root answers, so the test above
    // reached the root test and not the label read.
    const child = NodeWrapper.init(gpa, try nodeOf(&tree, 2));
    try testing.expect(!child.isRoot());
}

test "a role that exposes its label in its value reports no title and a value" {
    // `roles.labelIsExposedInValue` at `AK/macos/src/node.rs:233-242` holds five
    // roles, and `:322-324` and `:353-357` are its two uses. A `list_box_option`
    // with a label and a value answers the label as its value and no title.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .list_box_option, .label = "choice", .value = "one" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const option = NodeWrapper.init(gpa, try nodeOf(&tree, 2));
    try testing.expectEqual(@as(?ArrayList(u8), null), try option.title());

    const value = (try option.value()).?;
    defer value.deinit(gpa);
    try testing.expectEqual(Value.string, std.meta.activeTag(value));
    try testing.expectEqualStrings("choice", value.string.items);
}

test "a node whose label comes from its value answers the value as its label" {
    // `AK/macos/src/node.rs:329-331` is the branch. The consumer decides it from
    // the role, so a `generic_container` with a value and a label is not enough:
    // the role that carries the label in its value is `label`.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .label, .label = "text", .value = "typed" },
        .{ .local = 3, .role = .generic_container, .label = "name", .value = "typed" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const from_value = try NodeWrapper.init(gpa, try nodeOf(&tree, 2)).label();
    defer releaseText(gpa, from_value);
    try testing.expectEqualStrings("typed", from_value.?.items);

    const from_label = try NodeWrapper.init(gpa, try nodeOf(&tree, 3)).label();
    defer releaseText(gpa, from_label);
    try testing.expectEqualStrings("name", from_label.?.items);
}

test "a toggled state wins over every other value shape" {
    // `AK/macos/src/node.rs:345-347` is the first arm, and it is the arm a
    // comparison on the raw bytes cannot reach, because a toggle carries no
    // `value` property at all.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .switch_, .value = "ignored", .toggled = .true_ },
        .{ .local = 3, .role = .switch_, .value = "ignored", .toggled = .false_ },
        .{ .local = 4, .role = .switch_, .toggled = .mixed },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const on = (try NodeWrapper.init(gpa, try nodeOf(&tree, 2)).value()).?;
    const off = (try NodeWrapper.init(gpa, try nodeOf(&tree, 3)).value()).?;
    const mixed = (try NodeWrapper.init(gpa, try nodeOf(&tree, 4)).value()).?;
    try testing.expect(on.boolean);
    try testing.expect(!off.boolean);
    // `Toggled::Mixed` is not `False`, so it answers `true`, which is
    // `AK/macos/src/node.rs:346`.
    try testing.expect(mixed.boolean);
}

test "a tab answers its selection state and a node with no value answers none" {
    // `AK/macos/src/node.rs:348-352` and `:358-364`. A tab with no selection
    // state answers `false`, which is upstream's `unwrap_or(false)`, and a node
    // with neither a value nor a numeric value answers `None`.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .tab, .value = "ignored", .is_selected = true },
        .{ .local = 3, .role = .tab },
        .{ .local = 4, .role = .generic_container, .numeric_value = 2.5 },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const selected = (try NodeWrapper.init(gpa, try nodeOf(&tree, 2)).value()).?;
    try testing.expect(selected.boolean);
    const unselected = (try NodeWrapper.init(gpa, try nodeOf(&tree, 3)).value()).?;
    try testing.expect(!unselected.boolean);

    const number = (try NodeWrapper.init(gpa, try nodeOf(&tree, 4)).value()).?;
    try testing.expectEqual(Value.number, std.meta.activeTag(number));
    try testing.expectEqual(@as(f64, 2.5), number.number);
}

test "a description and a placeholder come from the node itself" {
    // `AK/macos/src/node.rs:336-342`. The placeholder answers only for an empty
    // text input, which is `strings.placeholder` at `node_ref/strings.zig:452`,
    // so the fixture gives the node the text input role.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3 } },
        .{ .local = 2, .role = .generic_container, .description = "hint" },
        .{ .local = 3, .role = .text_input, .placeholder = "search" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const described = try NodeWrapper.init(gpa, try nodeOf(&tree, 2)).description();
    defer releaseText(gpa, described);
    try testing.expectEqualStrings("hint", described.?.items);

    const placeholder = try NodeWrapper.init(gpa, try nodeOf(&tree, 3)).placeholder();
    try testing.expectEqualStrings("search", placeholder.?);
}

test "two absent titles are equal and one absent title is a change" {
    // The four arms of `textEql`, which `AK/macos/src/event.rs:264` reaches once
    // per update.
    const gpa = testing.allocator;
    const text = try ownedText(gpa, "text");
    defer releaseText(gpa, text);
    const same = try ownedText(gpa, "text");
    defer releaseText(gpa, same);
    const other = try ownedText(gpa, "other");
    defer releaseText(gpa, other);
    try testing.expect(textEql(null, null));
    try testing.expect(!textEql(null, text));
    try testing.expect(!textEql(text, null));
    try testing.expect(textEql(text, same));
    try testing.expect(!textEql(text, other));
}

test "two values of different shapes are never equal" {
    // `Value.eql` reads the payload only after the tag test, so the arms below
    // are what keeps a bool from being read as a number.
    const gpa = testing.allocator;
    const flag: ?Value = Value{ .boolean = true };
    const number: ?Value = Value{ .number = 1 };
    const text: ?Value = Value{ .string = try ownedText(gpa, "one") };
    defer releaseValue(gpa, text);
    const same: ?Value = Value{ .string = try ownedText(gpa, "one") };
    defer releaseValue(gpa, same);
    const other: ?Value = Value{ .string = try ownedText(gpa, "two") };
    defer releaseValue(gpa, other);

    try testing.expect(!Value.eql(flag, number));
    try testing.expect(!Value.eql(flag, text));
    try testing.expect(!Value.eql(text, flag));
    // Same tag and same payload is upstream's `Value::String(_) ==
    // Value::String(_)`, and a different payload under the same tag is not.
    try testing.expect(Value.eql(text, same));
    try testing.expect(!Value.eql(text, other));
    try testing.expect(Value.eql(null, null));
    try testing.expect(!Value.eql(null, flag));
    try testing.expect(!Value.eql(flag, null));
}

test "a title that changes names a change and a label that does not does not" {
    // This is the question `AK/macos/src/event.rs:264` asks. Two nodes of one
    // tree carry the same label and two carry different ones, so both arms run.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .generic_container, .label = "same" },
        .{ .local = 3, .role = .generic_container, .label = "same" },
        .{ .local = 4, .role = .generic_container, .label = "other" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const same = try nodeOf(&tree, 2);
    const same_again = try nodeOf(&tree, 3);
    const other = try nodeOf(&tree, 4);
    try testing.expect(!try titlesDiffer(gpa, same, same_again));
    try testing.expect(try titlesDiffer(gpa, same, other));
    try testing.expect(try titlesDiffer(gpa, other, same));
}

test "a toggled state that changes is a value change with no raw value" {
    // This is the question `AK/macos/src/event.rs:270-271` asks, and the case a
    // comparison on the raw value misses: neither node declares `value`, so both
    // raw values are absent and upstream still answers that the value changed.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .switch_, .toggled = .false_ },
        .{ .local = 3, .role = .switch_, .toggled = .true_ },
        .{ .local = 4, .role = .switch_, .toggled = .true_ },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const off = try nodeOf(&tree, 2);
    const on = try nodeOf(&tree, 3);
    const on_again = try nodeOf(&tree, 4);
    try testing.expectEqual(
        @as(?[]const u8, null),
        consumer.node_ref.set_state.rawValue(off),
    );
    const changed = try valueChange(gpa, off, on);
    defer changed.deinit(gpa);
    try testing.expect(changed.differs);
    try testing.expect(isBoolean(changed.value));

    const same = try valueChange(gpa, on, on_again);
    defer same.deinit(gpa);
    try testing.expect(!same.differs);
}

test "a tab whose selection state changes is a bool value change" {
    // `AK/macos/src/event.rs:272` asks the new value for the bool shape, and
    // `AK/macos/src/node.rs:348-352` is the arm that answers a bool for a tab.
    // A port that reads the toggled state alone answers `false` here, and the
    // bool change is then pushed at the back of the queue where upstream puts it
    // at the front.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{ 2, 3, 4 } },
        .{ .local = 2, .role = .tab, .is_selected = false },
        .{ .local = 3, .role = .tab, .is_selected = true },
        .{ .local = 4, .role = .list_box_option, .value = "same" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();

    const unselected = try nodeOf(&tree, 2);
    const selected = try nodeOf(&tree, 3);
    const text = try nodeOf(&tree, 4);

    const tab_change = try valueChange(gpa, unselected, selected);
    defer tab_change.deinit(gpa);
    try testing.expect(tab_change.differs);
    try testing.expect(isBoolean(tab_change.value));

    // A string value is not the bool shape, so the ordering rule does not fire.
    const text_change = try valueChange(gpa, text, text);
    defer text_change.deinit(gpa);
    try testing.expect(!text_change.differs);
    try testing.expect(!isBoolean(text_change.value));

    // An absent value is not the bool shape either, which is the `is_some_and`
    // half of `:272`.
    try testing.expect(!isBoolean(null));
}
