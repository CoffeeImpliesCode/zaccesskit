//! `Node`: one accessible object. A complete user interface is a tree of these.
//!
//! A node holds the role a platform reads to decide how to present the object,
//! two action masks, the flag mask, and a property store. It allocates, so it
//! carries `deinit`, and that `deinit` runs exactly once.
//!
//! **No role restricts a property, because upstream restricts none.** The Rust
//! type system accepts every property on every role and nothing at runtime
//! checks the pair, so a `Role.unknown` node may carry a scroll offset and a
//! `Role.scroll_bar` node may carry a label. The port keeps that. A platform
//! that wants the constraint needs the tree around the node, and the consumer
//! has it.
//!
//! **The property accessors are not in this file.** Zig cannot add a method to a
//! type it does not own, and giving `Node` 270 forwarders would only reproduce
//! a Rust method set that Zig has no use for. Each accessor is a free function
//! over the store, in the module that owns its family, and `Node` imports
//! neither them nor each other:
//!
//! | Family | Module |
//! |---|---|
//! | generic `get`, `set` and `clear` by `PropertyId` | `props/table.zig` |
//! | the 18 flags, one bit each | `props/flags.zig` |
//! | the 15 node-id and node-id-list properties | `props/ids.zig` |
//! | the 21 string properties | `props/strings.zig` |
//! | the 22 number properties | `props/numbers.zig` |
//! | the 6 colour and text-decoration properties | `props/colors.zig` |
//! | the 5 list properties | `props/vectors.zig` |
//! | the 14 boolean and enum properties | `props/enums.zig` |
//! | the 4 option properties, `transform` and `tree_id` among them | `props/option.zig` |
//!
//! Every property accessor takes the store as its first argument, so a caller
//! passes the address of the field:
//!
//! ```zig
//! try props.strings.setLabel(&node.properties, "Save");
//! ```
//!
//! The flags are the one family whose receiver is not the store, because the
//! 18 flags have no `PropertyId` and live in the node's own `u32`. Their
//! getter reads that field and their setter writes through a pointer to it:
//!
//! ```zig
//! const hidden: bool = props.flags.isHidden(node.flags);
//! props.flags.setHidden(&node.flags, true);
//! ```
//!
//! There is no accessor for the store itself: Zig rejects a method and a field
//! of one name, and rule Z4 fixes the field as `properties`.
//!
//! **Upstream's `Node::role` is the field here.** The same Zig rule deletes the
//! `role()` accessor for the same reason, and one name for one thing is the
//! house rule, so `setRole` stays and `node.role` is the read.
//!
//! **Layout.** Nothing in `Node` crosses the C ABI, so it is a plain struct and
//! its field offsets are not a contract. Zig 0.16.0 reorders plain-struct fields
//! to remove padding, so this file asserts no offset and no size. Measured on
//! Zig 0.16.0 with the store as it stands: 56 bytes at alignment 8, with
//! `properties` at offset 0 and `role` last, because the store carries an
//! allocator interface and the compiler puts the widest field first.
//!
//! **Import direction.** `schema/update.zig` imports this file, because a
//! `TreeUpdate` carries `Node` values. This file never imports it.
//!
//! Upstream: `accesskit/src/lib.rs:1107-1113`, the written methods at
//! `:1828-1907`, and the `Debug` implementation at `:2753-2791`.

const std = @import("std");

const action = @import("action.zig");
const role_module = @import("role.zig");
const table = @import("props/table.zig");

const Action = action.Action;
const Flag = table.Flag;
const Properties = table.Properties;
const Role = role_module.Role;

const assert = std.debug.assert;
const testing = std.testing;

/// One accessible object in the accessibility tree.
///
/// The value owns its property store, so it allocates and `deinit` releases
/// every string and list the store holds. The store was built with one
/// allocator and keeps it, so `deinit` takes none.
///
/// **A copy is not a second owner.** Zig has no move-only type, so a byte copy
/// duplicates the store's header, an allocator and a slice, while the buffers
/// behind that slice stay shared: both copies name one allocation. Release the
/// node through one copy only, because a `deinit` through the other frees those
/// buffers twice. The header belongs to each copy, so a write that grows the
/// store is visible only through the copy that made it, which is why `clone`
/// exists for a node that must stand on its own.
///
/// **No role restricts a property**, because upstream restricts none. See the
/// module doc.
pub const Node = struct {
    /// How a platform API interprets the object. It has no unset value in the
    /// stored form: `init` always writes one.
    role: Role,

    /// One bit per `Action` the node itself accepts.
    actions: u32,

    /// One bit per `Action` the node's direct children accept, in the filtered
    /// tree rather than in the raw one.
    child_actions: u32,

    /// One bit per `Flag`. These 18 flags have no `PropertyId` and are reached
    /// only through the one-bit accessors in `props/flags.zig`.
    flags: u32,

    /// The property store, sorted by `PropertyId`. A cleared property leaves
    /// this store rather than leaving a sentinel behind.
    properties: Properties,

    /// A node with `role` and nothing else: no action, no child action, no
    /// flag, and an empty store.
    ///
    /// `gpa` is kept by the store and is the allocator that must release the
    /// node's property buffers, so it is also the allocator `clone` gives the
    /// copy.
    pub fn init(gpa: std.mem.Allocator, role: Role) Node {
        return .{
            .role = role,
            .actions = 0,
            .child_actions = 0,
            .flags = 0,
            .properties = Properties.init(gpa),
        };
    }

    /// Replaces the role. A node otherwise keeps the role it was built with.
    pub fn setRole(self: *Node, value: Role) void {
        self.role = value;
    }

    /// True when the node itself accepts `action`.
    pub fn supportsAction(self: *const Node, value: Action) bool {
        return action.actionSetContains(self.actions, value);
    }

    /// Accepts `action` from now on. Adding an action the node already accepts
    /// changes nothing.
    pub fn addAction(self: *Node, value: Action) void {
        self.actions = action.actionSetUnion(self.actions, action.actionMask(value));
    }

    /// Stops accepting `action`. Removing an action the node never accepted
    /// changes nothing.
    pub fn removeAction(self: *Node, value: Action) void {
        self.actions = action.actionSetDifference(self.actions, action.actionMask(value));
    }

    /// Accepts no action at all.
    pub fn clearActions(self: *Node) void {
        self.actions = 0;
    }

    /// True when the node's direct children, in the filtered tree, accept
    /// `action`. A node reports for its children and holds no child's own mask.
    pub fn childSupportsAction(self: *const Node, value: Action) bool {
        return action.actionSetContains(self.child_actions, value);
    }

    /// Records that the node's direct children, in the filtered tree, accept
    /// `action`.
    pub fn addChildAction(self: *Node, value: Action) void {
        self.child_actions = action.actionSetUnion(self.child_actions, action.actionMask(value));
    }

    /// Withdraws `action` from the node's direct children.
    pub fn removeChildAction(self: *Node, value: Action) void {
        self.child_actions = action.actionSetDifference(
            self.child_actions,
            action.actionMask(value),
        );
    }

    /// Records that the node's direct children accept no action.
    pub fn clearChildActions(self: *Node) void {
        self.child_actions = 0;
    }

    /// A deep copy that owns its own buffers, so the copy and `source` are two
    /// owners and each needs its own `deinit`.
    ///
    /// This is upstream's `Clone::clone`. `gpa` becomes the copy's allocator.
    pub fn clone(gpa: std.mem.Allocator, source: *const Node) std.mem.Allocator.Error!Node {
        var out: Node = .init(gpa, source.role);
        errdefer out.deinit();
        try source.cloneInto(&out);
        return out;
    }

    /// Copies every field of `source` into `out`, keeping `out`'s buffers where
    /// the value shapes match.
    ///
    /// This is upstream's `Clone::clone_from`. Consumer update application
    /// reuses it in the private working state. Atomic commit preparation
    /// instead clones changed payloads before callbacks, so publication has
    /// no fallible property-copy step.
    ///
    /// `out` must already own a live store, and that store's allocator is the
    /// one every write goes through, so this takes none: `docs/30` section 4.3
    /// spells the same call with a `gpa`, which the store-owned-allocator
    /// ruling dropped.
    pub fn cloneInto(source: Node, out: *Node) std.mem.Allocator.Error!void {
        out.role = source.role;
        out.actions = source.actions;
        out.child_actions = source.child_actions;
        out.flags = source.flags;
        try source.properties.cloneInto(&out.properties);
    }

    /// Releases every property value and the store's backing array.
    ///
    /// Call it once, through one owner. The store remembers the allocator that
    /// grew it, so this cannot free through a second one. `self` is unusable
    /// afterwards: the property storage behind it is gone, and a read of any
    /// field is a read of freed memory.
    pub fn deinit(self: *Node) void {
        self.properties.deinit();
        // SAFETY: every buffer this node owns was released by the line above,
        // which is the whole teardown, and no statement after it reads `self`.
        // A caller that reads a field anyway gets a trap in Debug instead of a
        // value built from a freed store, which is the state this documents.
        self.* = undefined;
    }

    /// True when both nodes carry the same role, the same masks, the same flags
    /// and the same properties.
    ///
    /// Property equality is by id, so two nodes whose properties were stored in
    /// different orders compare equal. Upstream made that deliberate in commit
    /// `05ea5c5`, after comparing by slot position had broken once clone buffer
    /// reuse moved the slots.
    pub fn eql(self: *const Node, other: *const Node) bool {
        return self.role == other.role and
            self.actions == other.actions and
            self.child_actions == other.child_actions and
            self.flags == other.flags and
            self.properties.eql(&other.properties);
    }

    /// Writes the node the way upstream's `Debug` writes it, for example
    /// `Node { role: button, actions: [click, focus], hidden: true }`.
    ///
    /// An empty action set is left out, as upstream leaves it out, and only the
    /// flags and the properties that are set are written. Upstream walks its
    /// property families in macro order; the store is already in `PropertyId`
    /// order and holds no cleared entry, so the same set of properties appears
    /// without `custom_actions` needing its own case.
    ///
    /// Two spellings differ from upstream's text and neither changes what the
    /// dump carries. Upstream writes the Rust names, so this writes `button`
    /// where upstream writes `Button`. Upstream names a flag after its getter,
    /// so this writes `hidden` where upstream writes `is_hidden`: those getter
    /// names live in `props/flags.zig`, which is a sibling this file does not
    /// import, and a second copy of them here would be a second source of
    /// truth for the flag domain.
    pub fn format(self: *const Node, writer: *std.Io.Writer) std.Io.Writer.Error!void {
        try writer.writeAll("Node { role: ");
        try writer.writeAll(@tagName(self.role));
        try writeActionMask(writer, self.actions, "actions");
        try writeActionMask(writer, self.child_actions, "child_actions");
        try writeFlagMask(writer, self.flags);
        try writeProperties(writer, self.properties);
        try writer.writeAll(" }");
    }
};

/// Writes `", name: [a, b]"`, or nothing at all when the mask names no action.
/// Upstream omits an empty action set rather than writing an empty list, so a
/// node with no action and a node whose mask was cleared read the same.
fn writeActionMask(
    writer: *std.Io.Writer,
    mask: u32,
    name: []const u8,
) std.Io.Writer.Error!void {
    var members: [action.actionCount]Action = undefined;
    const listed = action.actionSetMembers(mask, &members);
    if (listed.len == 0) return;
    try writer.print(", {s}: [", .{name});
    // `actionSetMembers` fills a prefix of its own buffer, so this loop runs at
    // most `actionCount` times and `members` is exactly that long.
    for (listed, 0..) |member, index| {
        if (index != 0) try writer.writeAll(", ");
        try writer.writeAll(@tagName(member));
    }
    try writer.writeAll("]");
}

/// Writes `", name: true"` for every flag the mask holds.
///
/// The walk is `props/table.zig`'s, so this file holds no second copy of the
/// flag domain: `flagSetMembers` returns the set flags in discriminant order,
/// which is the order they were declared in, and its buffer is exactly
/// `flagCount` long, so the loop is bounded by that count.
fn writeFlagMask(writer: *std.Io.Writer, mask: u32) std.Io.Writer.Error!void {
    var members: [table.flagCount]Flag = undefined;
    for (table.flagSetMembers(mask, &members)) |member| {
        try writer.print(", {s}: true", .{@tagName(member)});
    }
}

/// Writes one field per stored property.
///
/// The store is sorted by `PropertyId` and keeps no cleared entry, so every
/// entry here is a property the node carries. The walk is bounded by
/// `propertyIdCount`, which is how many entries the store can hold.
fn writeProperties(
    writer: *std.Io.Writer,
    properties: Properties,
) std.Io.Writer.Error!void {
    for (properties.items.items) |entry| {
        try writer.print(", {s}: ", .{@tagName(entry.id)});
        try entry.value.format(writer);
    }
}

comptime {
    // Upstream declares five fields and no more at `lib.rs:1108-1112`. Pinning
    // the count and each spelling is what turns the copy rule on `Node` into a
    // checked statement rather than prose: a sixth field carrying a handle would
    // let a byte copy own something of its own, and nothing else in the port
    // would notice.
    const fields = @typeInfo(Node).@"struct";
    assert(fields.field_names.len == 5);

    const wanted = [_]struct { name: []const u8, ty: type }{
        .{ .name = "role", .ty = Role },
        .{ .name = "actions", .ty = u32 },
        .{ .name = "child_actions", .ty = u32 },
        .{ .name = "flags", .ty = u32 },
        .{ .name = "properties", .ty = Properties },
    };
    // A `comptime` block already unrolls this loop, and Zig 0.16 rejects the
    // `inline` keyword there as redundant.
    for (wanted, fields.field_names, fields.field_types) |want, got_name, got_type| {
        assert(std.mem.eql(u8, got_name, want.name));
        assert(got_type == want.ty);
    }
}

test "a new node carries the role it was built with and nothing else" {
    var node: Node = .init(testing.allocator, .button);
    defer node.deinit();

    try testing.expectEqual(Role.button, node.role);
    try testing.expectEqual(@as(u32, 0), node.actions);
    try testing.expectEqual(@as(u32, 0), node.child_actions);
    try testing.expectEqual(@as(u32, 0), node.flags);

    // The bound of both sweeps is `actionCount`, and a mask of zero holds no
    // member, so one assertion per member of the domain replaces a sample.
    inline for (std.enums.values(Action)) |member| {
        try testing.expect(!node.supportsAction(member));
        try testing.expect(!node.childSupportsAction(member));
    }
}

test "a fresh node reads every property as absent" {
    var node: Node = .init(testing.allocator, .unknown);
    defer node.deinit();

    // The bound is `propertyDescriptorCount`, one row per real property. A
    // property the store has never heard of and a property that was cleared
    // read the same, so this one sweep covers both meanings of absent. The
    // sentinel is not swept: it names no property.
    inline for (table.property_descriptors) |descriptor| {
        try testing.expect(node.properties.get(descriptor.id) == null);
    }
}

test "every role accepts the same property, because upstream constrains none" {
    // The bound of the sweep is the `Role` member count. The property is a node
    // id, which no role is expected to carry, and sweeping the whole domain is
    // the strongest form of the claim the module doc makes: not one role is
    // checked, so a check added to this file would fail here.
    //
    // The body is a function because a `defer` inside an `inline for` body
    // belongs to the enclosing scope rather than to the iteration, so 182
    // stores would stay live until the test ended.
    inline for (std.enums.values(Role)) |role_value| {
        try expectAnyRoleAcceptsAGenericProperty(testing.allocator, role_value);
    }
}

/// Stores a node-id property on a node of `role_value`, reads it back, clears
/// it and reads it absent again. Called once per member of the `Role` domain,
/// so the bound of that sweep is the member count.
fn expectAnyRoleAcceptsAGenericProperty(gpa: std.mem.Allocator, role_value: Role) !void {
    var node: Node = .init(gpa, role_value);
    defer node.deinit();

    try node.properties.set(.active_descendant, .{ .node_id = .{ .value = 7 } });
    try testing.expect(node.properties.get(.active_descendant) != null);

    // Clearing leaves the store, so the property reads absent again, and the
    // round trip through `set` and `clear` is checked on every role.
    node.properties.clear(.active_descendant);
    try testing.expect(node.properties.get(.active_descendant) == null);
}

test "a byte copy of a node shares one allocation and is not a second owner" {
    var node: Node = .init(testing.allocator, .button);
    defer node.deinit();
    try node.properties.set(.active_descendant, .{ .node_id = .{ .value = 11 } });

    var alias: Node = node;
    // Both names point at one backing array, which is the whole of the copy
    // rule: one owner and one `deinit`. A type that allocated its own buffers
    // per copy would not answer true here, and the second `deinit` the rule
    // forbids is what the testing allocator would report as a double free.
    try testing.expect(alias.properties.items.items.ptr == node.properties.items.items.ptr);
    try testing.expectEqual(@as(usize, 1), node.properties.count());

    // The header is per copy, so a store the copy grows is visible through the
    // copy and not through the original. That is why a byte copy is no
    // substitute for `clone`, which allocates a store of its own.
    try alias.properties.set(.error_message, .{ .node_id = .{ .value = 12 } });
    try testing.expectEqual(@as(usize, 2), alias.properties.count());
    try testing.expectEqual(@as(usize, 1), node.properties.count());
    try testing.expect(node.properties.get(.error_message) == null);
}

test "clone gives a second owner that the source does not see" {
    var source: Node = .init(testing.allocator, .button);
    defer source.deinit();
    try source.properties.set(.active_descendant, .{ .node_id = .{ .value = 3 } });
    source.addAction(.click);

    var copy: Node = try Node.clone(testing.allocator, &source);
    defer copy.deinit();

    try testing.expect(source.eql(&copy));

    // Deep copy: a write through one owner is invisible to the other, and the
    // masks came across. A shallow copy would fail the first assertion and a
    // forgotten field would fail the second.
    try copy.properties.set(.active_descendant, .{ .node_id = .{ .value = 4 } });
    try testing.expect(!source.eql(&copy));
    try testing.expect(copy.supportsAction(.click));

    copy.removeAction(.click);
    copy.setRole(.link);
    try testing.expect(!source.eql(&copy));
    try testing.expect(source.supportsAction(.click));
    try testing.expectEqual(Role.button, source.role);
}

test "the two action masks and the flag mask are independent of each other" {
    var node: Node = .init(testing.allocator, .button);
    defer node.deinit();

    node.addAction(.click);
    node.addChildAction(.focus);
    node.flags = table.flagMask(.hidden);

    try testing.expect(node.supportsAction(.click));
    try testing.expect(node.childSupportsAction(.focus));
    // Adding to one mask leaves the others alone: a store that shared one mask
    // would report the child's action on the node.
    try testing.expect(!node.supportsAction(.focus));
    try testing.expect(!node.childSupportsAction(.click));
    try testing.expectEqual(table.flagMask(.hidden), node.flags);

    // Removing and adding are idempotent on a mask that does not hold the bit.
    node.removeAction(.focus);
    node.addAction(.click);
    try testing.expectEqual(action.actionMask(.click), node.actions);
    try testing.expect(node.childSupportsAction(.focus));

    node.clearActions();
    try testing.expectEqual(@as(u32, 0), node.actions);
    try testing.expect(node.childSupportsAction(.focus));

    node.clearChildActions();
    try testing.expectEqual(@as(u32, 0), node.child_actions);
    // Clearing the actions must not disturb the flag mask, which is a third
    // field that happens to hold bits of the same width.
    try testing.expectEqual(table.flagMask(.hidden), node.flags);
}

test "setRole replaces the role and leaves every mask alone" {
    var node: Node = .init(testing.allocator, .button);
    defer node.deinit();

    node.addAction(.click);
    node.addChildAction(.focus);
    node.setRole(.check_box);

    try testing.expectEqual(Role.check_box, node.role);
    try testing.expect(node.supportsAction(.click));
    try testing.expect(node.childSupportsAction(.focus));
}

test "format writes the role, both action sets and the flags it holds" {
    var node: Node = .init(testing.allocator, .button);
    defer node.deinit();

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try node.format(&writer);
    // Nothing else is set, so both action sets and the flag mask are omitted
    // rather than written empty.
    try testing.expectEqualStrings("Node { role: button }", writer.buffered());

    node.addAction(.set_value);
    node.addAction(.click);
    node.addChildAction(.focus);
    node.flags = table.flagMask(.hidden) | table.flagMask(.modal);

    var full_buffer: [256]u8 = undefined;
    var full_writer = std.Io.Writer.fixed(&full_buffer);
    try node.format(&full_writer);
    // The actions come out in declaration order, not in the order they were
    // added, and a set flag is named after the flag rather than after a
    // getter.
    try testing.expectEqualStrings(
        "Node { role: button, actions: [click, set_value], " ++
            "child_actions: [focus], hidden: true, modal: true }",
        full_writer.buffered(),
    );
}

test "format lists the stored properties and leaves the cleared ones out" {
    var node: Node = .init(testing.allocator, .button);
    defer node.deinit();

    try node.properties.set(.active_descendant, .{ .node_id = .{ .value = 9 } });

    var buffer: [256]u8 = undefined;
    var writer = std.Io.Writer.fixed(&buffer);
    try node.format(&writer);
    // The payload text is `props/table.zig`'s to render, so the assertion here
    // is about which fields appear, not about how a node id is spelled. A
    // store walk that dropped entries, or kept a cleared one, fails this.
    try testing.expect(std.mem.indexOf(u8, writer.buffered(), "active_descendant: ") != null);

    node.properties.clear(.active_descendant);
    var after_buffer: [256]u8 = undefined;
    var after_writer = std.Io.Writer.fixed(&after_buffer);
    try node.format(&after_writer);
    // A cleared property leaves the store, so the dump loses the field rather
    // than printing it empty.
    try testing.expectEqualStrings("Node { role: button }", after_writer.buffered());
}
