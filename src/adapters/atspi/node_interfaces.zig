//! Which AT-SPI interfaces one node exports, what it reports as its attributes,
//! and what actions it offers.
//!
//! **Upstream.** `accesskit_atspi_common/src/node.rs:445-538` is the block of
//! `NodeWrapper` predicates the interface set is built from, `:570-587` is the
//! document attribute pair, and `:516-538` is `live`, `n_actions` and
//! `get_action_name`. `node.rs:484-514` is `NodeWrapper::interfaces` itself.
//! `docs/41-atspi-build-map.md` section 1.5 records the ten checks that decide
//! the set.
//!
//! **One node exports `Accessible` and whatever else these predicates say.**
//! A client reads the set with `Accessible.GetInterfaces` and then calls a
//! member on the interface it found, so a set that names an interface the node
//! cannot answer is worse than a set that omits one it can.
//!
//! **The attributes are a list, not a map.** Upstream returns a `HashMap`, and a
//! Rust hash map has no constant initialiser, so upstream paid for it. The
//! wire type is `a{ss}`, which is a dictionary, and a dictionary has at most one
//! value per key. The port therefore holds at most `attribute_slots` entries in
//! a fixed array, which is why `put` is a replace rather than an append and why
//! there is no allocation in the container itself. Only the values allocate,
//! because two of the six are numbers upstream formats.
//!
//! **The action list has one slot because the count is one.** Upstream's
//! `n_actions` is `1` or `0` at `node.rs:525-527`, so a list of `action_slots`
//! entries holds every answer the reference can produce. A port that grew the
//! list would be inventing an answer the reference does not give.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const node_state = @import("node_state.zig");
const schema = @import("../../schema/root.zig");
const wire = @import("wire.zig");
const wire_action = @import("wire/action.zig");

const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree.QueryError;
const FilterFn = consumer.filter.FilterFn;
const Live = schema.Live;

/// The failures one of these accessors reports.
///
/// Every accessor walks the tree or formats a number, so the union of the
/// consumer walk's set and the allocator's is the whole of it.
///
/// `std.Io.Writer.Error` is in the union because `strings.label` at
/// `consumer/node_ref/strings.zig:346` declares it: the label is built through
/// a collecting writer, and a writer carries one error tag. `documentAttributes`
/// calls that function, so an accessor error set without the tag cannot hold
/// the call.
pub const AccessorError = QueryError || std.Io.Writer.Error || std.mem.Allocator.Error;

/// The `Accessible.GetAttributes` key for the placeholder of an empty input,
/// `node.rs:420`.
pub const key_placeholder_text: []const u8 = "placeholder-text";
/// The `Accessible.GetAttributes` key for a node's one-based position in its
/// set, `node.rs:423`.
pub const key_position_in_set: []const u8 = "posinset";
/// The `Accessible.GetAttributes` key for the size of the set a node is in,
/// `node.rs:426`.
pub const key_size_of_set: []const u8 = "setsize";
/// The `Accessible.GetAttributes` key for a node's HTML id, `node.rs:429`.
pub const key_html_id: []const u8 = "id";
/// The `Accessible.GetAttributes` key for a braille label, `node.rs:432`.
pub const key_braille_label: []const u8 = "braillelabel";
/// The `Accessible.GetAttributes` key for a braille role description,
/// `node.rs:435`.
pub const key_braille_role_description: []const u8 = "brailleroledescription";

/// The `Document.GetAttributes` key for a document's title, `node.rs:573`.
pub const key_title: []const u8 = "Title";
/// The `Document.GetAttributes` key for a document's URL, `node.rs:576`.
pub const key_uri: []const u8 = "URI";

/// The number of attribute keys `node.rs:419-437` can insert, which is the
/// bound on every walk over the set.
pub const attribute_slots: usize = 6;

/// The number of document attribute keys `node.rs:570-580` can insert.
pub const document_attribute_slots: usize = 2;

/// The number of actions `node.rs:525-527` can report.
pub const action_slots: usize = 1;

/// The name the one action this adapter offers carries, `node.rs:534`.
pub const action_click: []const u8 = "click";

/// One attribute: a borrowed key and a value the caller owns.
pub const Attribute = struct {
    /// The key. Every key is a string literal in this module, so it outlives
    /// the set that holds it.
    key: []const u8,
    /// The value. The caller releases it with the allocator the accessor took.
    value: []u8,
};

/// A fixed-capacity attribute dictionary.
///
/// `put` replaces an entry whose key the set already holds, because a
/// dictionary has one value per key and a client reads the first match.
pub const AttributeSet = struct {
    /// The slots. An empty slot is `null` and `count` says how many are full.
    items: [attribute_slots]?Attribute,
    /// How many slots hold an entry.
    count: usize,

    /// A set with no entry.
    ///
    /// **Errors.** This function does not fail.
    pub fn empty() AttributeSet {
        return .{ .items = @splat(null), .count = 0 };
    }

    /// Stores `value` under `key`, replacing what is there.
    ///
    /// **Bound.** `items.len`, which is `attribute_slots` and a comptime
    /// constant, so the duplicate scan cannot run past the end.
    ///
    /// **Errors.** This function does not fail. A full set drops the write, and
    /// a caller that needs more slots raises the constant above.
    pub fn put(self: *AttributeSet, key: []const u8, value: []u8) void {
        for (self.items[0..self.count], 0..) |*slot, index| {
            const held = slot.* orelse continue;
            if (std.mem.eql(u8, held.key, key)) {
                // The whole entry is written rather than one field, because
                // `slot.*` is an optional and a replace keeps the key the
                // entry was filed under.
                self.items[index] = .{ .key = held.key, .value = value };
                return;
            }
        }
        if (self.count >= self.items.len) return;
        self.items[self.count] = .{ .key = key, .value = value };
        self.count += 1;
    }

    /// The value stored under `key`, or `null` when the set holds none.
    ///
    /// **Bound.** `count`, which does not change while the scan runs.
    ///
    /// **Errors.** This function does not fail.
    pub fn get(self: AttributeSet, key: []const u8) ?[]const u8 {
        for (self.items[0..self.count]) |slot| {
            const held = slot orelse continue;
            if (std.mem.eql(u8, held.key, key)) return held.value;
        }
        return null;
    }

    /// The entry at `index`, in the order the entries were first put, or `null`
    /// when `index` is past the last one.
    ///
    /// This returns the entry rather than a slice of them because the entries
    /// live in the set itself: a function that returned a slice would be
    /// returning a pointer into a local array.
    ///
    /// **Errors.** This function does not fail.
    pub fn at(self: AttributeSet, index: usize) ?Attribute {
        if (index >= self.count) return null;
        return self.items[index];
    }

    /// Releases every value the caller still owns. The keys are literals and
    /// the container holds no buffer of its own.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *AttributeSet, gpa: std.mem.Allocator) void {
        for (self.items[0..self.count]) |held| {
            if (held) |entry| gpa.free(entry.value);
        }
        self.* = undefined;
    }
};

/// The actions one node offers, and how many of them there are.
pub const ActionList = struct {
    /// The slots. `count` says how many are full.
    items: [action_slots]wire_action.Action,
    /// How many slots hold an action.
    count: usize,

    /// A list with no action.
    ///
    /// **Errors.** This function does not fail.
    pub fn empty() ActionList {
        return .{
            // SAFETY: A caller fills each slot before including it in count.
            .items = undefined,
            .count = 0,
        };
    }

    /// Releases nothing. Every string in an `Action` is borrowed, so the list
    /// owns no buffer.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *ActionList) void {
        self.* = undefined;
    }
};

/// Whether the node accepts a click, which is the whole of the `Action`
/// interface test. `node.rs:445-447`.
pub fn supportsAction(node: NodeRef, filter: FilterFn) QueryError!bool {
    return consumer.node_ref.predicates.isClickable(node, filter);
}

/// Whether the node has a box or is the tree root, which is the whole of the
/// `Component` interface test. `node.rs:449-451`.
pub fn supportsComponent(node: NodeRef) bool {
    return consumer.node_ref.geometry.rawBounds(node) != null or
        consumer.node_ref.hierarchy.isRoot(node);
}

/// Whether the node is a document, which is the whole of the `Document`
/// interface test. `node.rs:453-455`.
pub fn supportsDocument(node: NodeRef) bool {
    return switch (consumer.node_ref.properties.role(node)) {
        .root_web_area, .pdf_root => true,
        else => false,
    };
}

/// Whether the node is a writable text node, which is the whole of the
/// `EditableText` interface test. `node.rs:457-459`.
pub fn supportsEditableText(node: NodeRef) QueryError!bool {
    return consumer.node_ref.predicates.isTextInput(node) and
        try consumer.text.query.supportsTextRanges(node);
}

/// Whether the node is a hyperlink, which is the whole of the `Hyperlink`
/// interface test. `node.rs:461-463`.
pub fn supportsHyperlink(node: NodeRef) bool {
    return consumer.node_ref.strings.supportsUrl(node);
}

/// Whether the node is an image, which is the whole of the `Image` interface
/// test. `node.rs:465-470`.
pub fn supportsImage(node: NodeRef) bool {
    return switch (consumer.node_ref.properties.role(node)) {
        .canvas, .doc_cover, .graphics_symbol, .image, .svg_root => true,
        else => false,
    };
}

/// Whether the node holds selectable children, which is the whole of the
/// `Selection` interface test. `node.rs:472-474`.
pub fn supportsSelection(node: NodeRef) bool {
    return consumer.node_ref.containers.isContainerWithSelectableChildren(node);
}

/// Whether the node carries text runs, which is the whole of the `Text`
/// interface test. `node.rs:476-478`.
pub fn supportsText(node: NodeRef) QueryError!bool {
    return consumer.text.query.supportsTextRanges(node);
}

/// Whether the node carries a numeric value, which is the whole of the `Value`
/// interface test. `node.rs:480-482`.
pub fn supportsValue(node: NodeRef) bool {
    return currentValue(node) != null;
}

/// The value the `Value` interface reports as the node's current value, or
/// `null` when the node carries none.
///
/// `node.rs:589-591`. It reads the same property the interface test reads, so a
/// node that exports `Value` always answers this with a number.
///
/// **Errors.** This function does not fail.
pub fn currentValue(node: NodeRef) ?f64 {
    return consumer.node_ref.properties.numericValue(node);
}

/// The interfaces `node` exports, with `Accessible` first and always.
///
/// `node.rs:484-514`. The order of the nine tests is upstream's, and it does not
/// matter to a client, because the set is a bit set and a client asks for the
/// members rather than reading positions.
///
/// **Errors.** `error.TreeCycle` from the two tests that walk: the clickability
/// test and the text-range test.
pub fn interfaces(node: NodeRef, filter: FilterFn) QueryError!wire.InterfaceSet {
    var set: wire.InterfaceSet = .empty;
    set.insert(.accessible);
    if (try supportsAction(node, filter)) set.insert(.action);
    if (supportsComponent(node)) set.insert(.component);
    if (supportsDocument(node)) set.insert(.document);
    if (try supportsEditableText(node)) set.insert(.editable_text);
    if (supportsHyperlink(node)) set.insert(.hyperlink);
    if (supportsImage(node)) set.insert(.image);
    if (supportsSelection(node)) set.insert(.selection);
    if (try supportsText(node)) set.insert(.text);
    if (supportsValue(node)) set.insert(.value);
    return set;
}

/// The announcement priority a live region announces at, or `none`.
///
/// `node.rs:516-523`. The consumer's three-value `Live` narrows onto the
/// three-value `Politeness` with the same spelling, so the map is the identity
/// on the tag and this function exists to name the narrowing.
///
/// **Errors.** `error.TreeCycle` from the inherited live walk.
pub fn live(node: NodeRef) QueryError!wire.Politeness {
    return switch (try consumer.node_ref.set_state.live(node)) {
        .off => .none,
        .polite => .polite,
        .assertive => .assertive,
    };
}

/// The `Accessible.GetAttributes` dictionary for `node`.
///
/// `node.rs:417-439`. A node states at most six of them, and the set holds one
/// slot for each, so no call here can grow the container.
///
/// **The caller owns every value** and releases them with `gpa` through
/// `AttributeSet.deinit`. Two of the six are numbers upstream formats, which is
/// the only reason this function allocates at all.
///
/// **Errors.** `error.TreeCycle` from the walk that resolves the size of the
/// set a node is in, and `error.OutOfMemory` from the two numbers.
pub fn attributes(
    gpa: std.mem.Allocator,
    node: NodeRef,
    filter: FilterFn,
) AccessorError!AttributeSet {
    var out: AttributeSet = .empty();
    errdefer out.deinit(gpa);

    if (try consumer.node_ref.strings.placeholder(node)) |text| {
        out.put(key_placeholder_text, try gpa.dupe(u8, text));
    }
    // `node.rs:395-397` adds one, because ARIA counts from zero and AT-SPI
    // counts from one.
    if (consumer.node_ref.predicates.positionInSet(node)) |position| {
        out.put(key_position_in_set, try std.fmt.allocPrint(gpa, "{d}", .{position + 1}));
    }
    if (try consumer.node_ref.predicates.sizeOfSetFromContainer(node, filter)) |size| {
        out.put(key_size_of_set, try std.fmt.allocPrint(gpa, "{d}", .{size}));
    }
    if (consumer.node_ref.set_state.htmlId(node)) |html_id| {
        out.put(key_html_id, try gpa.dupe(u8, html_id));
    }
    if (consumer.node_ref.properties.brailleLabel(node)) |label| {
        out.put(key_braille_label, try gpa.dupe(u8, label));
    }
    if (consumer.node_ref.properties.brailleRoleDescription(node)) |description| {
        out.put(key_braille_role_description, try gpa.dupe(u8, description));
    }
    return out;
}

/// The `Document.GetAttributes` dictionary for `node`.
///
/// `node.rs:570-580`. A document states at most a title and a URL, so the set
/// holds `document_attribute_slots` entries.
///
/// **The caller owns the title** and releases it with `gpa`. The URL is borrowed
/// from the tree's own buffer and stays valid as long as the tree does, so it
/// is copied too and the rule is one rule.
///
/// **Errors.** `error.OutOfMemory` from the label the title is built from.
pub fn documentAttributes(
    gpa: std.mem.Allocator,
    node: NodeRef,
) AccessorError!AttributeSet {
    var out: AttributeSet = .empty();
    errdefer out.deinit(gpa);

    if (try consumer.node_ref.strings.label(gpa, node)) |found| {
        // `ArrayList.deinit` at `std/array_list.zig:623` takes `*Self`, and an
        // `if` capture binds by value and is const, so the list is named by a
        // `var` before it is released.
        var label = found;
        defer label.deinit(gpa);
        out.put(key_title, try gpa.dupe(u8, label.items));
    }
    if (consumer.node_ref.strings.url(node)) |url| {
        out.put(key_uri, try gpa.dupe(u8, url));
    }
    return out;
}

/// The one document attribute `name` names, matched without regard to case, or
/// `null` when the document states no such attribute.
///
/// `node.rs:582-587`. The case-insensitive match is upstream's
/// `eq_ignore_ascii_case`, and a client that sends `title` for the key `Title`
/// is asking the same question.
///
/// **The caller owns the answer** and releases it with `gpa`, which is what the
/// `?[]u8` return and the two `errors` in the callers say. The set this builds
/// releases its own copy when it goes, so the value is copied out rather than
/// handed back as a borrow of a buffer that is about to be freed.
///
/// **Bound.** `items.len` through `AttributeSet.get`, which is
/// `document_attribute_slots` and a comptime constant.
///
/// **Errors.** `error.OutOfMemory` from the two values the dictionary holds
/// and from the copy of the one that matches.
pub fn documentAttributeValue(
    gpa: std.mem.Allocator,
    node: NodeRef,
    name: []const u8,
) AccessorError!?[]u8 {
    var held = try documentAttributes(gpa, node);
    defer held.deinit(gpa);

    for (held.items[0..held.count]) |entry| {
        const one = entry.?;
        if (std.ascii.eqlIgnoreCase(one.key, name)) return gpa.dupe(u8, one.value);
    }
    return null;
}

/// How many actions the node offers, which is one when it is clickable and zero
/// otherwise. `node.rs:525-527`.
pub fn nActions(node: NodeRef, filter: FilterFn) QueryError!i32 {
    return if (try consumer.node_ref.predicates.isClickable(node, filter)) 1 else 0;
}

/// The name of the action at `index`, or the empty string.
///
/// `node.rs:529-538`. Every index other than zero answers empty, and index zero
/// of a node that is not clickable answers empty too, so the two cases are one
/// answer.
///
/// **Errors.** `error.TreeCycle` from the clickability walk.
pub fn actionName(node: NodeRef, filter: FilterFn, index: i32) QueryError![]const u8 {
    if (index != 0) return "";
    if (!try consumer.node_ref.predicates.isClickable(node, filter)) return "";
    return action_click;
}

/// The actions the node offers, with the empty description and the empty key
/// binding upstream writes at `node.rs:1112-1113`.
///
/// **Bound.** `action_slots`, which is one, and which is the largest number
/// `nActions` can return.
///
/// **Errors.** `error.TreeCycle` from the clickability walk.
pub fn actions(node: NodeRef, filter: FilterFn) QueryError!ActionList {
    var out: ActionList = .empty();
    const count = try nActions(node, filter);
    if (count == 0) return out;
    out.items[0] = wire_action.Action.init(action_click, "", "");
    out.count = 1;
    return out;
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

/// The map entry for `value`, which is where a fixture writes.
fn mapEntry(state: *consumer.tree_state.TreeState, value: u64) !*consumer.tree_state.NodeState {
    return state.nodes.getPtr(consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0))) orelse
        error.NodeMissingFromFixture;
}

/// A tree whose root is `role`, which is the state most of these tests start
/// from.
fn rootState(
    gpa: std.mem.Allocator,
    state: *consumer.tree_state.TreeState,
    role: schema.Role,
) !void {
    try insert(gpa, state, 0, null, schema.Node.init(gpa, role));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;
}

test "a node exports Accessible and nothing else it cannot answer" {
    // `node.rs:485`. The unconditional insert is the whole of this check.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);

    const set = try interfaces(try handle(&state, 0), node_state.node_filter);
    try testing.expect(set.contains(.accessible));
    try testing.expect(!set.contains(.text));
    try testing.expect(!set.contains(.value));
}

test "a document exports Document and a page that is not one does not" {
    // `node.rs:453-455`. The two roles are named because they are the two.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try insert(gpa, &state, 0, null, schema.Node.init(gpa, .group));
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .root_web_area));
    try insert(gpa, &state, 2, 0, schema.Node.init(gpa, .pdf_root));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    try testing.expect(supportsDocument(try handle(&state, 1)));
    try testing.expect(supportsDocument(try handle(&state, 2)));
    try testing.expect(!supportsDocument(try handle(&state, 0)));
}

test "the five image roles export Image and no other role does" {
    // `node.rs:465-470`. The list is closed, so a check on one member would pass
    // for a port that matched one role instead of five.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try insert(gpa, &state, 0, null, schema.Node.init(gpa, .group));
    const image_roles = [_]schema.Role{
        .canvas, .doc_cover, .graphics_symbol, .image, .svg_root,
    };
    for (image_roles, 1..) |role, index| {
        try insert(gpa, &state, @intCast(index), 0, schema.Node.init(gpa, role));
    }
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    for (image_roles, 1..) |_, index| {
        try testing.expect(supportsImage(try handle(&state, @intCast(index))));
    }
    try testing.expect(!supportsImage(try handle(&state, 0)));
}

test "the tree root exports Component even without a box" {
    // `node.rs:449-451`. The second half of the condition, and a root is the
    // one node that is always true for it.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);

    try testing.expect(supportsComponent(try handle(&state, 0)));
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .group));
    try testing.expect(!supportsComponent(try handle(&state, 1)));
}

test "a node with a box exports Component and one without does not" {
    // `node.rs:450`. The first half of the condition, which a nested child is
    // the only way to reach.
    //
    // The node that carries no box has to be a child rather than the root: the
    // second half of the condition at `node.rs:451` answers true for the tree
    // root whatever box it has, which is the other half of this test. So the
    // fixture holds a root, a boxed child and a boxless child, and the check
    // that names the boxless one is the only node the first half can reject.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .group));
    try insert(gpa, &state, 2, 0, schema.Node.init(gpa, .group));

    // The box is written through the map's own entry rather than into a local
    // node copied into the map: `NodeState.data` is copied by value, so the two
    // would share one property buffer and one of them would release it twice.
    // `consumer/tree_state.zig:234` names that trap.
    const boxed = try mapEntry(&state, 1);
    try schema.option.setBounds(&boxed.data.properties, schema.rectInit(0, 0, 10, 10));

    try testing.expect(supportsComponent(try handle(&state, 1)));
    try testing.expect(!supportsComponent(try handle(&state, 2)));
}

test "a node with a numeric value exports Value and one without does not" {
    // `node.rs:480-482` and `:589-591`. The two read the same property, so a
    // node that exports the interface must answer a number.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .slider);
    errdefer node.deinit();
    try schema.numbers.setNumericValue(&node.properties, 4.5);
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    const handle_value = try handle(&state, 0);
    try testing.expect(supportsValue(handle_value));
    try testing.expectEqual(@as(?f64, 4.5), currentValue(handle_value));
}

test "a link with a url exports Hyperlink and a link without one does not" {
    // `node.rs:461-463`, which reads `supports_url` rather than the URL itself.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try insert(gpa, &state, 0, null, schema.Node.init(gpa, .group));
    var with_url = schema.Node.init(gpa, .link);
    errdefer with_url.deinit();
    try schema.strings.setUrl(&with_url.properties, "https://example.invalid/");
    try insert(gpa, &state, 1, 0, with_url);
    var without_url = schema.Node.init(gpa, .link);
    errdefer without_url.deinit();
    try insert(gpa, &state, 2, 0, without_url);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    try testing.expect(supportsHyperlink(try handle(&state, 1)));
    try testing.expect(!supportsHyperlink(try handle(&state, 2)));
}

test "a clickable node offers one action named click" {
    // `node.rs:525-538` and `:1104-1118`. All three answers come from the one
    // clickability test, so a port that split them would answer inconsistently.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .button);
    errdefer node.deinit();
    // There is no `schema.actions` module: the action mask is the node's own
    // `u32`, and `Node.addAction` at `schema/node.zig:146` sets one bit of it
    // through `actionMask`. It takes `*Node` and answers `void`.
    node.addAction(.click);
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;
    const node_ref = try handle(&state, 0);

    try testing.expect(try supportsAction(node_ref, node_state.node_filter));
    try testing.expectEqual(@as(i32, 1), try nActions(node_ref, node_state.node_filter));
    try testing.expectEqualStrings(
        action_click,
        try actionName(node_ref, node_state.node_filter, 0),
    );
    try testing.expectEqualStrings(
        "",
        try actionName(node_ref, node_state.node_filter, 1),
    );

    var offered = try actions(node_ref, node_state.node_filter);
    defer offered.deinit();
    try testing.expectEqual(@as(usize, 1), offered.count);
    try testing.expectEqualStrings(action_click, offered.items[0].localized_name);
    try testing.expectEqualStrings("", offered.items[0].description);
    try testing.expectEqualStrings("", offered.items[0].key_binding);
}

test "a node that takes no click offers no action at any index" {
    // `node.rs:530-532` and `:534-537`. Index zero of a node that is not
    // clickable answers empty, which is a different reason from a bad index and
    // the same answer.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);
    const node_ref = try handle(&state, 0);

    try testing.expect(!try supportsAction(node_ref, node_state.node_filter));
    try testing.expectEqual(@as(i32, 0), try nActions(node_ref, node_state.node_filter));
    try testing.expectEqualStrings(
        "",
        try actionName(node_ref, node_state.node_filter, 0),
    );
    var offered = try actions(node_ref, node_state.node_filter);
    defer offered.deinit();
    try testing.expectEqual(@as(usize, 0), offered.count);
}

test "an action list holds at most the one action the reference names" {
    // `action_slots` is the whole domain of `nActions`, so a list that reached
    // two would be reporting an action the reference does not define.
    try testing.expectEqual(@as(usize, 1), action_slots);
    try testing.expectEqual(@as(usize, 0), @typeInfo(wire_action.Action).@"struct".fields.len - 3);
}

test "the live region priorities map onto the announcement priorities" {
    // `node.rs:516-523`. The two enums have the same three tags, so a
    // transcription that reordered them would announce the wrong urgency.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node_slot = try mapEntry(&state, 0);
    const node_ref = try handle(&state, 0);

    try testing.expectEqual(wire.Politeness.none, try live(node_ref));
    for ([_]struct { stored: Live, announced: wire.Politeness }{
        .{ .stored = .off, .announced = .none },
        .{ .stored = .polite, .announced = .polite },
        .{ .stored = .assertive, .announced = .assertive },
    }) |one| {
        try schema.enums.setLive(&node_slot.data.properties, one.stored);
        try testing.expectEqual(one.announced, try live(node_ref));
    }
}

/// A one-node tree whose node is a text run, which is what the inherited live
/// walk reads.
fn oneNode(gpa: std.mem.Allocator, state: *consumer.tree_state.TreeState, role: schema.Role) !void {
    try insert(gpa, state, 0, null, schema.Node.init(gpa, role));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;
}

test "the attributes dictionary holds the six keys and no more" {
    // `node.rs:417-439`. A node that states all six is the only fixture that
    // fills every slot, so it is the one that proves the bound.
    //
    // `setsize` is the one key that is not the node's own. `sizeOfSetFromContainer`
    // at `predicates.zig:170` reads the nearest `size_of_set` on the **filtered
    // ancestor chain**, so a node with no parent never states one. The fixture
    // therefore hangs the subject under a parent that states the size, and the
    // parent is a group, which the common filter includes.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);
    const parent = try mapEntry(&state, 0);
    try schema.numbers.setSizeOfSet(&parent.data.properties, 4);
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .text_input));

    // Every property is written through the map's own entry rather than into a
    // local node copied into the map. `NodeState.data` is copied by value, so a
    // local and the map's entry would share one property buffer and release it
    // twice; `consumer/tree_state.zig:234` names that trap.
    const subject = try mapEntry(&state, 1);
    const properties = &subject.data.properties;
    try schema.strings.setPlaceholder(properties, "type here");
    try schema.strings.setHtmlId(properties, "field");
    try schema.strings.setBrailleLabel(properties, "brl");
    try schema.strings.setBrailleRoleDescription(properties, "edit");
    try schema.numbers.setPositionInSet(properties, 0);
    try schema.numbers.setSizeOfSet(properties, 4);

    var held = try attributes(gpa, try handle(&state, 1), node_state.node_filter);
    defer held.deinit(gpa);

    try testing.expectEqual(@as(usize, 6), held.count);
    const placeholder = held.get(key_placeholder_text) orelse return error.TestExpectedEqual;
    try testing.expectEqualStrings("type here", placeholder);
    // `node.rs:395-397` adds one to a position ARIA counts from zero.
    try testing.expectEqualStrings(
        "1",
        held.get(key_position_in_set) orelse return error.TestExpectedEqual,
    );
    try testing.expectEqualStrings(
        "4",
        held.get(key_size_of_set) orelse return error.TestExpectedEqual,
    );
    try testing.expectEqualStrings("field", held.get(key_html_id) orelse return error.TestExpectedEqual);
    try testing.expectEqualStrings("brl", held.get(key_braille_label) orelse return error.TestExpectedEqual);
    try testing.expectEqualStrings(
        "edit",
        held.get(key_braille_role_description) orelse return error.TestExpectedEqual,
    );
}

test "a node that states nothing carries no attribute" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .group);

    var held = try attributes(gpa, try handle(&state, 0), node_state.node_filter);
    defer held.deinit(gpa);

    try testing.expectEqual(@as(usize, 0), held.count);
    try testing.expectEqual(@as(?[]const u8, null), held.get(key_html_id));
}

test "a dictionary holds one value per key" {
    const gpa = testing.allocator;
    var held: AttributeSet = .empty();
    defer held.deinit(gpa);

    // `put` answers `void`: a replace is not a failure, so there is no `try`.
    // It also does not release the value it takes back, because every value in
    // the set belongs to whoever put it. The caller releases it, which is what
    // the second half of this test depends on.
    const one = try gpa.dupe(u8, "one");
    held.put("first", one);
    held.put("second", try gpa.dupe(u8, "two"));
    gpa.free(one);
    held.put("first", try gpa.dupe(u8, "three"));

    // The second put of `first` replaced the first, and the value it replaced
    // was already released by the caller that put it, so a dictionary that
    // appended instead would hold three entries and leak two.
    try testing.expectEqual(@as(usize, 2), held.count);
    try testing.expectEqualStrings("three", held.get("first").?);
    try testing.expectEqualStrings("two", held.get("second").?);
    try testing.expectEqualStrings("first", held.at(0).?.key);
    try testing.expectEqual(@as(?Attribute, null), held.at(2));
}

test "the document attributes are a title and a url" {
    // `node.rs:570-580`. Both keys are named because a client matches on them.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .document);
    errdefer node.deinit();
    try schema.strings.setLabel(&node.properties, "A page");
    try schema.strings.setUrl(&node.properties, "https://example.invalid/page");
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;

    var held = try documentAttributes(gpa, try handle(&state, 0));
    defer held.deinit(gpa);

    try testing.expectEqual(@as(usize, 2), held.count);
    try testing.expectEqualStrings("A page", held.get(key_title).?);
    try testing.expectEqualStrings("https://example.invalid/page", held.get(key_uri).?);
}

test "a document attribute is found whatever the case of the name" {
    // `node.rs:585`. The comparison is case-insensitive, so a client that sends
    // `title` gets the value stored under `Title`.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    var node = schema.Node.init(gpa, .document);
    errdefer node.deinit();
    try schema.strings.setLabel(&node.properties, "A page");
    try schema.strings.setUrl(&node.properties, "https://example.invalid/page");
    try insert(gpa, &state, 0, null, node);
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;
    const node_ref = try handle(&state, 0);

    const from_title = (try documentAttributeValue(gpa, node_ref, "Title")) orelse
        return error.TestExpectedEqual;
    defer gpa.free(from_title);
    try testing.expectEqualStrings("A page", from_title);

    const from_lower = (try documentAttributeValue(gpa, node_ref, "title")) orelse
        return error.TestExpectedEqual;
    defer gpa.free(from_lower);
    try testing.expectEqualStrings("A page", from_lower);

    const from_uri = (try documentAttributeValue(gpa, node_ref, "uri")) orelse
        return error.TestExpectedEqual;
    defer gpa.free(from_uri);
    try testing.expectEqualStrings("https://example.invalid/page", from_uri);

    try testing.expectEqual(
        @as(?[]u8, null),
        try documentAttributeValue(gpa, node_ref, "author"),
    );
}

test "the six attribute keys are the six the reference writes" {
    // `node.rs:420`, `:423`, `:426`, `:429`, `:432` and `:435`. A client
    // matches these strings, so a misspelling is a lost attribute.
    try testing.expectEqualStrings("placeholder-text", key_placeholder_text);
    try testing.expectEqualStrings("posinset", key_position_in_set);
    try testing.expectEqualStrings("setsize", key_size_of_set);
    try testing.expectEqualStrings("id", key_html_id);
    try testing.expectEqualStrings("braillelabel", key_braille_label);
    try testing.expectEqualStrings("brailleroledescription", key_braille_role_description);
    // One slot per key, so a dictionary cannot grow past the six.
    try testing.expectEqual(@as(usize, 6), attribute_slots);
    try testing.expectEqual(@as(usize, 2), document_attribute_slots);
}

test "the interface set answers only members the wire declares" {
    // A set carrying a bit no `Interface` names would read as an interface a
    // client asks for and the port cannot answer.
    //
    // `Text` needs a run, not just a text-input role: `supportsTextRanges` at
    // `consumer/text/query.zig:67` walks the runs and answers false when there
    // is none. So the fixture is a window, a text input under it, and a text
    // run under that. The children list names the run, which is the node the
    // walk reads.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try rootState(gpa, &state, .window);
    try insert(gpa, &state, 1, 0, schema.Node.init(gpa, .text_input));
    try insert(gpa, &state, 2, 1, schema.Node.init(gpa, .text_run));

    // Written through the map's own entry: `NodeState.data` is copied by value,
    // so a local node and the map's entry would share one property buffer and
    // release it twice. `consumer/tree_state.zig:234` names that trap.
    const input = try mapEntry(&state, 1);
    try schema.ids_props.setChildren(&input.data.properties, &.{.{ .value = 2 }});
    const node_ref = try handle(&state, 1);

    const set = try interfaces(node_ref, node_state.node_filter);
    var out: [wire.interface_count]wire.Interface = undefined;
    const members = set.members(&out);
    for (members) |member| {
        try testing.expect(wire.interfaceName(member).len > 0);
    }
    // A text input with a run exports the text interface, which is the one the
    // set is most likely to lose.
    try testing.expect(set.contains(.text));
    try testing.expect(members.len > 0);
}
