//! `PlatformNode`, `PlatformRoot`, `CacheNode`: the per-node and per-application
//! values an AT-SPI client reads.
//!
//! **Upstream.** `accesskit_atspi_common/src/node.rs` for the rows this module
//! owns: `NodeWrapper::cache_node` at `:58-81`, `notify_changes` at `:593-705`,
//! `PlatformNode` at `:708-1787`, `PlatformRoot` at `:1804-2034`,
//! `NodeIdOrRoot` at `:2048-2052` and `CacheNode` at `:2054-2065`. The six
//! sibling modules hold the parts of `NodeWrapper` this file calls:
//! `node_role.zig` the role map, `node_state.zig` the state set,
//! `node_interfaces.zig` the interface set and the attribute dictionaries,
//! `text_attributes.zig` the ten named getters, `util.zig` the offset
//! conversions and `window_bounds.zig` the coordinate conversions.
//! `app_context.zig` holds upstream `context.rs:89-122`.
//!
//! ## What this file is and is not
//!
//! **It owns no object and registers nothing.** Upstream's `PlatformNode` is a
//! cheap cloneable handle a D-Bus method body receives; the port's is a value
//! carrying a pointer to the window's context and a node identifier. Every
//! method below is a function of that value and the tree behind it, so a fixture
//! tree drives all of them with no bus and no object register. What is still
//! missing is the register itself: `docs/41` section 3.3 names `objects.zig`
//! under milestone M5, and until it lands nothing calls these methods. That is
//! a wiring gap, not a value gap, and the values are here.
//!
//! ## Three things a reader should not have to guess
//!
//! 1. **A method that raises an action hands the request to a sink and returns.**
//!    Upstream calls `context.do_action`, which forwards one `ActionRequest` to
//!    the application handler. The port holds the handler in
//!    `app_context.ActionSink` and reports `error.NoActionSink` while no handler
//!    is installed, because `root.zig:64-79` records that the C ABI cannot
//!    install one: the request it would receive has to be allocated by
//!    `src/capi/allocation.zig`, and an adapter cannot reach that module without
//!    closing the cycle `src/capi/boundary.zig` exists to break.
//! 2. **`indexInParent` and `root` read the application registry.** A window no
//!    registry lists has no index and no application object, and both report
//!    `error.Defunct`, which is upstream's answer when the `Weak<Context>` it
//!    reads the registry through will not upgrade.
//! 3. **`PlatformRoot` numbers its children by list position.** Upstream
//!    `child_at_index` reads `context.adapters.get(index)`, and the list is in
//!    registration order, so the index a client sends is a position and not an
//!    adapter number.
//!
//! ## Every loop and its bound
//!
//! | Walk | Bound |
//! |---|---|
//! | `childAtIndex`, `childCount`, `isChildSelected`, `selectChild`, `deselectChild` | the filtered child cursor, which visits each child once |
//! | `selectedItems` | `treeWalkStepBound(nodes.count())`, enforced by the consumer's own item walk |
//! | `notifyStateChanges` | `wire.state_count`, through `StateSet.difference` |
//! | `notifyChildrenChanges` | each of the two child lists, and the membership scan is over the other |
//! | `mapDescendants`, `mapDescendantCacheNodes` | `treeWalkStepBound(nodes.count())` per window, one step per node visited |
//!
//! The two descendant walks are the only recursive ones. Upstream recurses with
//! no bound at all, because a Rust `Vec` cannot hold a cycle; the port's tree can
//! be given one by a malformed update, so both walks count the nodes they have
//! visited and report `error.TreeCycle` at the bound. `docs/41` section 7 row 4
//! hands that decision to `docs/30`, and the consumer layer already answers the
//! same exhaustion with `error.TreeCycle` at `tree_state.zig:605`, so the port
//! uses that name.

const std = @import("std");

const adapter_errors = @import("error.zig");
const app_context = @import("app_context.zig");
const events = @import("events.zig");
const node_interfaces = @import("node_interfaces.zig");
const node_role = @import("node_role.zig");
const node_state = @import("node_state.zig");
const object_id = @import("object_id.zig");
const text_attributes = @import("text_attributes.zig");
const util = @import("util.zig");
const window_bounds = @import("window_bounds.zig");
const wire = @import("wire.zig");
const wire_rect = @import("wire/rect.zig");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const affine = @import("../../schema/geometry/affine.zig");

const ActionRequest = schema.ActionRequest;
const AppContext = app_context.AppContext;
const Attribute = node_interfaces.Attribute;
const AttributeSet = node_interfaces.AttributeSet;
const FullNodeId = consumer.tree_index.FullNodeId;
const NodeContext = app_context.NodeContext;
const NodeRef = consumer.node_id.NodeRef;
const ObjectId = object_id.ObjectId;
const Point = schema.Point;
const QueryError = consumer.tree.QueryError;
const Rect = schema.Rect;
const TreeState = consumer.tree_state.TreeState;

/// The failures any member of this file reports.
///
/// It is the adapter's own set joined to the consumer walk's, to the geometry
/// conversion's and to the allocator's. `error.NoActionSink` is this file's own
/// and is declared here: upstream's `context.do_action` cannot fail because the
/// handler it forwards to has no return, and the port reports the missing
/// handler rather than dropping the request.
pub const NodeError = util.UtilError ||
    QueryError ||
    std.Io.Writer.Error ||
    window_bounds.GeometryError ||
    error{NoActionSink};

/// The failures `notifyChanges` reports. It builds the same values the members
/// build and allocates for them, so the set is the same one.
pub const NotifyError = NodeError;

// --- signal names -------------------------------------------------------------
// These four are the ones `bus.rs:270-281` and `bus.rs:430` spell. They live
// here because `events.zig` declares the other six and the only raisers of
// three of these four are the functions below.

/// The signal that says a node gained or lost a child. Upstream
/// `ObjectEvent::ChildAdded` and `ChildRemoved` both take this name at
/// `bus.rs:275`.
pub const member_children_changed: [:0]const u8 = "ChildrenChanged";

/// The signal that says one property of a node changed. Upstream `bus.rs:276`.
pub const member_property_change: [:0]const u8 = "PropertyChange";

/// The signal that says a document finished loading. Upstream `bus.rs:430`.
pub const member_load_complete: [:0]const u8 = "LoadComplete";

/// The first body argument of `ChildrenChanged` for an addition. `bus.rs:314`.
pub const child_change_add: []const u8 = "add";

/// The first body argument of `ChildrenChanged` for a removal. `bus.rs:325`.
pub const child_change_remove: []const u8 = "remove";

/// The property key for a node's name. `bus.rs:333`.
pub const key_accessible_name: []const u8 = "accessible-name";

/// The property key for a node's description. `bus.rs:334`.
pub const key_accessible_description: []const u8 = "accessible-description";

/// The property key for a node's parent. `bus.rs:335`.
pub const key_accessible_parent: []const u8 = "accessible-parent";

/// The property key for a node's role. `bus.rs:336`.
pub const key_accessible_role: []const u8 = "accessible-role";

/// The property key for a node's numeric value. `bus.rs:337`.
pub const key_accessible_value: []const u8 = "accessible-value";

/// The parent an event about a node names, or the application object.
///
/// Upstream `node.rs:2048-2052`. Upstream derives `Clone`, `Copy`, `Debug`,
/// `PartialEq` and `Eq`; the port carries the two payloads and writes `eql`.
pub const NodeIdOrRoot = union(enum) {
    /// A node of one adapter's tree. Upstream `NodeIdOrRoot::Node`.
    node: FullNodeId,
    /// The application object. Upstream `NodeIdOrRoot::Root`.
    root,

    /// Whether two names point at the same thing.
    ///
    /// `FullNodeId` is a plain struct and Zig derives nothing for it, so the
    /// comparison is `std.meta.eql`.
    ///
    /// **Errors.** This function does not fail.
    pub fn eql(self: NodeIdOrRoot, other: NodeIdOrRoot) bool {
        return switch (self) {
            .root => other == .root,
            .node => |mine| other == .node and std.meta.eql(mine, other.node),
        };
    }

    /// The object path this name is about, for the adapter `adapter_id`.
    ///
    /// **Errors.** This function does not fail.
    pub fn objectId(self: NodeIdOrRoot, adapter_id: usize) ObjectId {
        return switch (self) {
            .root => .root,
            .node => |id| .{ .node = .{ .adapter = adapter_id, .node = id } },
        };
    }
};

/// Everything the cache needs about one node, and nothing else.
///
/// Upstream `node.rs:2054-2065`. `name` and `description` are owned strings
/// upstream and owned buffers here, so `deinit` releases them with the allocator
/// that produced them. Every other member is a bit set, a scalar or an
/// identifier, and none of them owns anything.
pub const CacheNode = struct {
    /// The window this node belongs to.
    adapter_id: usize,
    /// The node itself.
    id: FullNodeId,
    /// The nearest ancestor the filter keeps, or the application object.
    parent: NodeIdOrRoot,
    /// The position among the children the filter keeps.
    index_in_parent: i32,
    /// How many children the filter keeps.
    child_count: i32,
    /// The interfaces this node exports.
    interfaces: wire.InterfaceSet,
    /// The node's name, or the empty slice when it states none.
    name: []u8,
    /// The node's description, or the empty slice when it states none.
    description: []u8,
    /// The AT-SPI role this node reports.
    role: wire.Role,
    /// The states this node reports, given that the window holds focus.
    states: wire.StateSet,

    /// Releases the two texts. The set, the identifier and the two bit sets own
    /// nothing.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *CacheNode, gpa: std.mem.Allocator) void {
        gpa.free(self.name);
        gpa.free(self.description);
        self.* = undefined;
    }
};

/// The cache entry for `node`.
///
/// Upstream `NodeWrapper::cache_node` at `node.rs:58-81`. The parent is the
/// nearest ancestor the filter keeps, so a client that walks the cache sees the
/// same tree the interface members answer about.
///
/// **Bound.** The two walks `nodeName` and `nodeDescription` perform are the
/// consumer layer's own, and each reports `error.TreeCycle` through its own
/// bound. This function adds no walk of its own.
///
/// **Errors.** `error.TreeCycle` and `error.OutOfMemory` from the two texts and
/// from the label walk behind the name.
pub fn cacheNodeFor(
    gpa: std.mem.Allocator,
    node: NodeRef,
    adapter_id: usize,
    index_in_parent: i32,
    child_count: i32,
    window_focused: bool,
) NodeError!CacheNode {
    const parent = try parentOrRootOf(node);
    const interfaces = try node_interfaces.interfaces(node, node_state.node_filter);
    const states = try node_state.stateOf(node, window_focused);
    const name = try takeText(gpa, try nodeName(gpa, node));
    errdefer gpa.free(name);
    const description = try takeText(gpa, try nodeDescription(gpa, node));
    errdefer gpa.free(description);
    return .{
        .adapter_id = adapter_id,
        .id = node.id(),
        .parent = parent,
        .index_in_parent = index_in_parent,
        .child_count = child_count,
        .interfaces = interfaces,
        .name = name,
        .description = description,
        .role = node_role.roleOf(node),
        .states = states,
    };
}

/// The text `text` holds, or an empty slice the caller still owns.
///
/// `NodeWrapper::name` and `NodeWrapper::description` answer `unwrap_or_default`
/// upstream, and both answers are owned strings. A `null` becomes a zero-length
/// slice rather than a null pointer, because every caller releases the buffer
/// with `gpa` and `free` is not a function that takes a null.
///
/// The returned slice retains the allocation length needed by `gpa.free`.
/// The function releases the list if the ownership transfer fails.
///
/// **Errors.** `error.OutOfMemory` when the list cannot resize to its text length.
/// A missing text returns an empty slice without an allocation.
fn takeText(gpa: std.mem.Allocator, text: ?std.ArrayList(u8)) std.mem.Allocator.Error![]u8 {
    var held = text orelse return std.ArrayList(u8).empty.items;
    defer held.deinit(gpa);
    return held.toOwnedSlice(gpa);
}

/// The nearest ancestor of `node` the filter keeps, or the application object.
///
/// Upstream writes this as `filtered_parent(&filter).map_or(NodeIdOrRoot::Root,
/// |node| NodeIdOrRoot::Node(node.id()))` at `node.rs:65-68`, at `node.rs:877-879`
/// and at `node.rs:648-650`.
///
/// **Errors.** `error.TreeCycle` from the climb to the root.
pub fn parentOrRootOf(node: NodeRef) NodeError!NodeIdOrRoot {
    const parent = try consumer.node_ref.hierarchy.filteredParent(
        node,
        node_state.node_filter,
    ) orelse return .root;
    return .{ .node = parent.id() };
}

/// The name a client reads for `node`.
///
/// Upstream `NodeWrapper::name` at `node.rs:38-44`: a node whose label comes
/// from its value reports the value, and every other node reports its label.
/// The consumer answers the condition with `labelComesFromValue` and hands both
/// texts over as buffers the caller owns, so the caller releases the answer
/// with `gpa`.
///
/// **Errors.** `error.TreeCycle` and `error.OutOfMemory` from the label walk,
/// which follows the labelled-by chain.
pub fn nodeName(gpa: std.mem.Allocator, node: NodeRef) NodeError!?std.ArrayList(u8) {
    if (consumer.node_ref.strings.labelComesFromValue(node)) {
        return consumer.node_ref.set_state.value(gpa, node);
    }
    return consumer.node_ref.strings.label(gpa, node);
}

/// The description a client reads for `node`.
///
/// Upstream `NodeWrapper::description` at `node.rs:46-48`. The consumer's own
/// `description` walks the chain of nodes that describe this one, so the answer
/// is not the node's own text alone.
///
/// **Errors.** `error.OutOfMemory` from the copy.
pub fn nodeDescription(gpa: std.mem.Allocator, node: NodeRef) NodeError!?std.ArrayList(u8) {
    return consumer.node_ref.strings.description(gpa, node);
}

/// The node's box in the space `coord_type` counts from, or `null` when the node
/// states none.
///
/// Upstream `NodeWrapper::extents` at `node.rs:545-568`. Three steps, and the
/// order is upstream's. A node with no box of its own is first clipped to the
/// window's drawn box when it is the root, and then every answer is moved into
/// the requested coordinate space by adding the corner that space starts at.
///
/// **Errors.** `error.TreeCycle` from the walk that reads the parent's box.
pub fn nodeExtents(
    node: NodeRef,
    bounds: window_bounds.WindowBounds,
    coord_type: wire.CoordType,
) QueryError!?Rect {
    var box = try consumer.node_ref.geometry.boundingBox(node);
    if (consumer.node_ref.hierarchy.isRoot(node)) {
        const window_box = bounds.innerBox().withOrigin(.{ .x = 0.0, .y = 0.0 });
        if (!window_box.isEmpty()) {
            if (box) |*held| {
                held.x0 = @min(held.x0, window_box.x1);
                held.y0 = @min(held.y0, window_box.y1);
                held.x1 = @min(held.x1, window_box.x1);
                held.y1 = @min(held.y1, window_box.y1);
            } else {
                box = window_box;
            }
        }
    }
    const found = box orelse return null;
    const parent = try consumer.node_ref.hierarchy.filteredParent(
        node,
        node_state.node_filter,
    );
    const corner = try bounds.accesskitPointToAtspiPoint(found.topLeft(), parent, coord_type);
    return found.withOrigin(corner);
}

/// How many entries one text attribute run carries, which is one slot for every
/// name `text_attributes.rs:69-78` declares.
///
/// It is not `node_interfaces.attribute_slots`: that is the six the
/// `Accessible.GetAttributes` dictionary holds, and a text attribute run holds
/// up to ten. A port that reused the six-slot container would drop four
/// attributes without saying so.
pub const text_attribute_slots: usize = text_attributes.attribute_count;

/// The text attributes one run carries.
///
/// Upstream builds a `HashMap<&'static str, String>` at `node.rs:1663` and
/// fills it from the getter table. The port holds a fixed-capacity list of
/// `text_attribute_slots` entries, which is the whole domain, and every value is
/// one the caller owns.
///
/// **Bound.** `text_attribute_slots`, a comptime constant, so the duplicate scan
/// and the append cannot run past the end.
pub const TextAttributeSet = struct {
    /// The slots. An empty slot is `null` and `count` says how many are full.
    items: [text_attribute_slots]?Attribute = @splat(null),
    /// How many slots hold an entry.
    count: usize = 0,

    /// A set with no entry.
    ///
    /// **Errors.** This function does not fail.
    pub fn empty() TextAttributeSet {
        return .{};
    }

    /// Stores `value` under `name`, replacing what is there. Every name in this
    /// set is a literal in `text_attributes.zig` and the ten are distinct, so a
    /// replace never runs; the function keeps the rule of a dictionary anyway.
    ///
    /// **Errors.** This function does not fail. A full set drops the write, and
    /// `text_attribute_slots` is the whole domain, so that arm is unreachable.
    pub fn put(self: *TextAttributeSet, name: []const u8, value: []u8) void {
        for (self.items[0..self.count], 0..) |*slot, index| {
            const held = slot.* orelse continue;
            if (std.mem.eql(u8, held.key, name)) {
                self.items[index] = .{ .key = held.key, .value = value };
                return;
            }
        }
        if (self.count >= self.items.len) return;
        self.items[self.count] = .{ .key = name, .value = value };
        self.count += 1;
    }

    /// The value stored under `name`, or `null` when the set holds none.
    ///
    /// **Bound.** `count`, which does not change while the scan runs.
    ///
    /// **Errors.** This function does not fail.
    pub fn get(self: TextAttributeSet, name: []const u8) ?[]const u8 {
        for (self.items[0..self.count]) |slot| {
            const held = slot orelse continue;
            if (std.mem.eql(u8, held.key, name)) return held.value;
        }
        return null;
    }

    /// Releases every value the caller still owns.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *TextAttributeSet, gpa: std.mem.Allocator) void {
        for (self.items[0..self.count]) |held| {
            if (held) |entry| gpa.free(entry.value);
        }
        self.* = undefined;
    }
};

/// The relations one node holds.
///
/// Upstream `PlatformNode::relation_set` at `node.rs:972-989` returns a
/// `HashMap<RelationType, Vec<T>>` and inserts exactly one relation,
/// `ControllerFor`. The port therefore holds one list rather than a map: a map
/// with one entry is a key that can never vary.
pub const RelationSet = struct {
    /// The nodes this one controls, in the order the node lists them. Empty
    /// when it controls none, which is upstream's `if !controls.is_empty()`.
    controller_for: std.ArrayList(FullNodeId) = .empty,

    /// Releases the list and nothing else. The identifiers own nothing.
    ///
    /// **Errors.** This function does not fail.
    pub fn deinit(self: *RelationSet, gpa: std.mem.Allocator) void {
        self.controller_for.deinit(gpa);
        self.* = undefined;
    }
};

/// One node of one AT-SPI window, as a client sees it.
///
/// Upstream `PlatformNode` at `node.rs:708-713`. The three fields are the three
/// upstream holds: a `Weak<Context>`, an adapter number and a `FullNodeId`. The
/// port replaces the weak handle with a plain pointer, because `AGENTS.md`
/// section 3 forbids shared ownership and section 6 asks for a lifetime to
/// become a named pointer.
///
/// **Equality.** Upstream derives `PartialEq`, `Eq` and `Hash` over the adapter
/// number and the identifier at `node.rs:1789-1802`. `eql` below is that
/// comparison.
pub const PlatformNode = struct {
    /// The window this node reads from. It must outlive the node.
    context: *const NodeContext,
    /// The number every object path under this window carries.
    adapter_id: usize,
    /// The node itself.
    id: FullNodeId,

    /// Builds a node handle. Upstream `PlatformNode::new` at `node.rs:716-722`.
    ///
    /// **Errors.** This function does not fail.
    pub fn init(
        context: *const NodeContext,
        adapter_id: usize,
        id: FullNodeId,
    ) PlatformNode {
        return .{ .context = context, .adapter_id = adapter_id, .id = id };
    }

    /// The same window and the same adapter, naming a different node.
    ///
    /// Upstream `PlatformNode::relative` at `node.rs:854-860`. It is how one
    /// member answers about a child without building a second window context.
    ///
    /// **Errors.** This function does not fail.
    pub fn relative(self: PlatformNode, id: FullNodeId) PlatformNode {
        return .{ .context = self.context, .adapter_id = self.adapter_id, .id = id };
    }

    /// The number every object path under this window carries. Upstream
    /// `PlatformNode::adapter_id` at `node.rs:891-893`.
    ///
    /// **Errors.** This function does not fail.
    pub fn adapterNumber(self: PlatformNode) usize {
        return self.adapter_id;
    }

    /// The node this handle names. Upstream `PlatformNode::id` at
    /// `node.rs:895-897`.
    ///
    /// **Errors.** This function does not fail.
    pub fn nodeId(self: PlatformNode) FullNodeId {
        return self.id;
    }

    /// Whether two handles name the same node of the same window. Upstream's
    /// `PartialEq` at `node.rs:1791`.
    ///
    /// **Errors.** This function does not fail.
    pub fn eql(self: PlatformNode, other: PlatformNode) bool {
        return self.adapter_id == other.adapter_id and std.meta.eql(self.id, other.id);
    }

    /// The application object this window is a child of.
    ///
    /// Upstream `PlatformNode::root` at `node.rs:862-865` builds the root from
    /// the registry the window's context holds. A window no registry lists has
    /// no application object, which is `error.Defunct` here and upstream's
    /// `upgrade_context` refusing a released `Weak`.
    ///
    /// **Errors.** `error.Defunct` when no application context is installed.
    pub fn root(self: PlatformNode) NodeError!PlatformRoot {
        const app = self.context.app orelse return error.Defunct;
        return PlatformRoot.init(app);
    }

    /// The object path this node is exported on.
    ///
    /// **Errors.** This function does not fail.
    pub fn objectId(self: PlatformNode) ObjectId {
        return .{ .node = .{ .adapter = self.adapter_id, .node = self.id } };
    }

    /// The node behind this handle, or `error.Defunct` when it left the tree.
    ///
    /// Upstream `resolve_with_context` at `node.rs:755-766`, whose `None` arm is
    /// `Error::Defunct`. The `upgrade_context` half is not a check here: a
    /// `*const NodeContext` cannot be null, and the caller that builds it has
    /// already refused an adapter that holds no tree.
    ///
    /// **Errors.** `error.Defunct` when the tree holds no such node.
    pub fn resolve(self: PlatformNode) adapter_errors.Error!NodeRef {
        return self.context.state.nodeById(self.id) orelse error.Defunct;
    }

    /// The node behind this handle, after checking that it selects children.
    ///
    /// Upstream `resolve_for_selection` at `node.rs:803-815`.
    ///
    /// **Errors.** `error.Defunct` and `error.UnsupportedInterface`.
    pub fn resolveForSelection(self: PlatformNode) adapter_errors.Error!NodeRef {
        const node = try self.resolve();
        if (!node_interfaces.supportsSelection(node)) return error.UnsupportedInterface;
        return node;
    }

    /// The node behind this handle, after checking that it carries text runs.
    ///
    /// Upstream `resolve_for_text` at `node.rs:817-822`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface` and
    /// `error.TreeCycle` from the text-range support test.
    pub fn resolveForText(self: PlatformNode) NodeError!NodeRef {
        const node = try self.resolve();
        if (!try node_interfaces.supportsText(node)) return error.UnsupportedInterface;
        return node;
    }

    /// The `(local identifier, tree)` pair this handle names, or
    /// `error.Defunct`.
    ///
    /// Upstream's `locate_node` step appears in `do_action_internal` at
    /// `node.rs:830`, in `scroll_to_point` at `:1213`, in
    /// `set_text_contents` at `:1231`, in the three selection members at `:1329`,
    /// `:1355` and `:1398`, in `set_caret_offset` at `:1471`, in
    /// `remove_selection` at `:1597`, in `set_selection` at `:1624`, in
    /// `scroll_substring_to` at `:1712` and in `scroll_substring_to_point` at
    /// `:1747`.
    ///
    /// **Errors.** `error.Defunct` when the tree no longer locates the node.
    pub fn locateNode(self: PlatformNode) adapter_errors.Error!LocateResult {
        return locate(self.context.state, self.id);
    }

    /// Hands `request` to the installed handler and reports whether one was
    /// there.
    ///
    /// This is the whole of upstream's `do_action_internal` at
    /// `node.rs:824-838` and `Context::do_action` at `context.rs:76-78`, minus
    /// the locate step that every caller above performs itself.
    ///
    /// The handler owns the request and releases it with
    /// `ActionRequest.deinit`, which is the contract at `update.zig:263-271`.
    ///
    /// **Errors.** `error.NoActionSink` when the window has no handler.
    fn raise(self: PlatformNode, request: ActionRequest) NodeError!void {
        const sink = self.context.sink orelse return error.NoActionSink;
        sink.raise(sink.context, request);
    }

    /// The name a client reads for this node. Upstream `PlatformNode::name` at
    /// `node.rs:840-845`, which wraps `NodeWrapper::name` in
    /// `unwrap_or_default`.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn name(self: PlatformNode, gpa: std.mem.Allocator) NodeError!std.ArrayList(u8) {
        const node = try self.resolve();
        return (try nodeName(gpa, node)) orelse .empty;
    }

    /// The description a client reads for this node. Upstream
    /// `PlatformNode::description` at `node.rs:847-852`.
    ///
    /// **Errors.** `error.Defunct` and `error.OutOfMemory`.
    pub fn description(self: PlatformNode, gpa: std.mem.Allocator) NodeError!std.ArrayList(u8) {
        const node = try self.resolve();
        return (try nodeDescription(gpa, node)) orelse .empty;
    }

    /// The toolkit name this window's tree declares. Upstream
    /// `PlatformNode::toolkit_name` at `node.rs:867-869`.
    ///
    /// The answer borrows the tree's own buffer and stays valid until the next
    /// write to the tree's info block.
    ///
    /// **Errors.** This function does not fail.
    pub fn toolkitName(self: PlatformNode) []const u8 {
        return self.context.state.toolkitName();
    }

    /// The toolkit version this window's tree declares, or the empty slice.
    /// Upstream `PlatformNode::toolkit_version` at `node.rs:871-873`.
    ///
    /// **Errors.** This function does not fail.
    pub fn toolkitVersion(self: PlatformNode) []const u8 {
        return self.context.state.toolkitVersion() orelse "";
    }

    /// The AT-SPI role this node reports. Upstream `PlatformNode::role` at
    /// `node.rs:991-996`, which forwards to `node_role.roleOf`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn role(self: PlatformNode) adapter_errors.Error!wire.Role {
        const node = try self.resolve();
        return node_role.roleOf(node);
    }

    /// The localized role name, or the empty slice when the node states none.
    /// Upstream `PlatformNode::localized_role_name` at `node.rs:998-1000`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn localizedRoleName(self: PlatformNode) adapter_errors.Error![]const u8 {
        const node = try self.resolve();
        return consumer.node_ref.properties.roleDescription(node) orelse "";
    }

    /// The interfaces this node exports. Upstream `PlatformNode::interfaces` at
    /// `node.rs:1083-1088`, which forwards to `node_interfaces.interfaces`.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn interfaces(self: PlatformNode) NodeError!wire.InterfaceSet {
        const node = try self.resolve();
        return node_interfaces.interfaces(node, node_state.node_filter);
    }

    /// The `Accessible.GetAttributes` dictionary for this node. Upstream
    /// `PlatformNode::attributes` at `node.rs:1010-1015`.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn attributes(self: PlatformNode, gpa: std.mem.Allocator) NodeError!AttributeSet {
        const node = try self.resolve();
        return node_interfaces.attributes(gpa, node, node_state.node_filter);
    }

    /// The states this node reports. Upstream `PlatformNode::state` at
    /// `node.rs:1002-1008`, whose `unwrap_or(State::Defunct.into())` is the
    /// one-member defunct set here.
    ///
    /// **Errors.** `error.TreeCycle` from the focusability test. A node that
    /// left the tree is not an error here, because upstream swallows it.
    pub fn state(self: PlatformNode) NodeError!wire.StateSet {
        const node = self.resolve() catch |err| switch (err) {
            error.Defunct => return wire.StateSet.defunct,
            else => |other| return other,
        };
        return node_state.stateOf(node, self.context.state.focusId() != null);
    }

    /// The announcement priority this node announces at. Upstream
    /// `NodeWrapper::live` at `node.rs:516-523`, which
    /// `notify_property_changes` reads at `node.rs:631`.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn live(self: PlatformNode) NodeError!wire.Politeness {
        const node = try self.resolve();
        return node_interfaces.live(node);
    }

    /// The number of actions this node offers. Upstream
    /// `PlatformNode::n_actions` at `node.rs:1090-1095`.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn nActions(self: PlatformNode) NodeError!i32 {
        const node = try self.resolve();
        return node_interfaces.nActions(node, node_state.node_filter);
    }

    /// The name of the action at `index`, or the empty slice. Upstream
    /// `PlatformNode::action_name` at `node.rs:1097-1102`.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn actionName(self: PlatformNode, index: i32) NodeError![]const u8 {
        const node = try self.resolve();
        return node_interfaces.actionName(node, node_state.node_filter, index);
    }

    /// The actions this node offers. Upstream `PlatformNode::actions` at
    /// `node.rs:1104-1118`, which builds one entry per action with the empty
    /// description and the empty key binding.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn actions(self: PlatformNode) NodeError!node_interfaces.ActionList {
        const node = try self.resolve();
        return node_interfaces.actions(node, node_state.node_filter);
    }

    /// The `Document.GetAttributes` dictionary for this node. Upstream
    /// `PlatformNode::document_attributes` at `node.rs:1035-1037`.
    ///
    /// **Errors.** `error.Defunct` and `error.OutOfMemory`.
    pub fn documentAttributes(self: PlatformNode, gpa: std.mem.Allocator) NodeError!AttributeSet {
        const node = try self.resolve();
        return node_interfaces.documentAttributes(gpa, node);
    }

    /// The one document attribute `attribute_name` names, or the empty slice.
    /// Upstream `PlatformNode::document_attribute_value` at `node.rs:1039-1045`.
    ///
    /// **Errors.** `error.Defunct` and `error.OutOfMemory`.
    pub fn documentAttributeValue(
        self: PlatformNode,
        gpa: std.mem.Allocator,
        attribute_name: []const u8,
    ) NodeError![]u8 {
        const node = try self.resolve();
        const found = try node_interfaces.documentAttributeValue(gpa, node, attribute_name);
        return found orelse gpa.alloc(u8, 0);
    }

    /// The author's identifier for this node, or the empty slice. Upstream
    /// `PlatformNode::accessible_id` at `node.rs:899-907`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn accessibleId(self: PlatformNode) adapter_errors.Error![]const u8 {
        const node = try self.resolve();
        return consumer.node_ref.set_state.authorId(node) orelse "";
    }

    /// The nearest ancestor this client can see, or the application object.
    /// Upstream `PlatformNode::parent` at `node.rs:875-882`.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn parent(self: PlatformNode) NodeError!NodeIdOrRoot {
        const node = try self.resolve();
        return parentOrRootOf(node);
    }

    /// How many children this client can see. Upstream
    /// `PlatformNode::child_count` at `node.rs:884-889`.
    ///
    /// **Bound.** The filtered child cursor, which visits each child once.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and
    /// `error.TooManyChildren`.
    pub fn childCount(self: PlatformNode) NodeError!i32 {
        const node = try self.resolve();
        const count = try countFilteredChildren(node);
        return std.math.cast(i32, count) orelse error.TooManyChildren;
    }

    /// The child at `index`, or `null` when the node has fewer. Upstream
    /// `PlatformNode::child_at_index` at `node.rs:909-917`.
    ///
    /// **Bound.** The filtered child cursor, which visits each child once.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn childAtIndex(self: PlatformNode, index: usize) NodeError!?FullNodeId {
        const child = (try filteredChildAtIndex(try self.resolve(), index)) orelse return null;
        return child.id();
    }

    /// Every child identifier, each put through `map_child`.
    ///
    /// Upstream `PlatformNode::map_children` at `node.rs:919-931`, whose
    /// `FromIterator` is the list this function returns.
    ///
    /// **Bound.** The filtered child cursor, which visits each child once.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn mapChildren(
        self: PlatformNode,
        gpa: std.mem.Allocator,
        map_child: anytype,
    ) !std.ArrayList(ReturnTypeOf(map_child)) {
        var out: std.ArrayList(ReturnTypeOf(map_child)) = .empty;
        errdefer out.deinit(gpa);
        const node = try self.resolve();
        var children = try consumer.node_ref.hierarchy.filteredChildren(
            node,
            node_state.node_filter,
        );
        while (try children.next()) |child| {
            try out.append(gpa, map_child(child.id()));
        }
        return out;
    }

    /// The position of this node among the children its parent exposes, or the
    /// position of its window in the application registry.
    ///
    /// Upstream `PlatformNode::index_in_parent` at `node.rs:933-946`. A node
    /// with no visible parent is a window root, and a window's index is its slot
    /// in the registry rather than a position in a sibling list.
    ///
    /// **Bound.** The sibling cursor and the registry list, each of its own
    /// length, plus the binary search's own bound at
    /// `app_context.binarySearchStepBound`.
    ///
    /// **Errors.** `error.Defunct`, `error.IndexOutOfRange` and
    /// `error.TreeCycle`.
    pub fn indexInParent(self: PlatformNode) NodeError!i32 {
        const node = try self.resolve();
        const parent_node = try consumer.node_ref.hierarchy.filteredParent(
            node,
            node_state.node_filter,
        );
        if (parent_node == null) {
            const app = self.context.app orelse return error.Defunct;
            const index = app.adapterIndex(self.adapter_id) catch return error.Defunct;
            return std.math.cast(i32, index) orelse error.IndexOutOfRange;
        }
        var siblings = try consumer.node_ref.hierarchy.precedingFilteredSiblings(
            node,
            node_state.node_filter,
        );
        var count: usize = 0;
        while (try siblings.next()) |_| count += 1;
        return std.math.cast(i32, count) orelse error.IndexOutOfRange;
    }

    /// The cache entry for this node. Upstream `PlatformNode::cache_node` at
    /// `node.rs:948-970`, which computes the position and the child count the
    /// same way `indexInParent` and `childCount` do and then calls
    /// `NodeWrapper::cache_node`.
    ///
    /// **Errors.** Every error `indexInParent`, `childCount` and `cacheNodeFor`
    /// report.
    pub fn cacheNode(self: PlatformNode) NodeError!CacheNode {
        const index_in_parent = try self.indexInParent();
        const child_count = try self.childCount();
        const node = try self.resolve();
        return cacheNodeFor(
            self.context.gpa,
            node,
            self.adapter_id,
            index_in_parent,
            child_count,
            self.context.state.focusId() != null,
        );
    }

    /// The relations this node holds. Upstream `PlatformNode::relation_set` at
    /// `node.rs:972-989`, whose only relation is `ControllerFor`.
    ///
    /// **Bound.** The controls cursor, which visits each stored identifier once.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn relationSet(self: PlatformNode, gpa: std.mem.Allocator) NodeError!RelationSet {
        const node = try self.resolve();
        var out: RelationSet = .{};
        errdefer out.deinit(gpa);
        var controlled = consumer.node_ref.set_state.controls(node);
        while (try controlled.next()) |target| {
            const verdict = try node_state.node_filter.call(target);
            if (verdict != .include) continue;
            try out.controller_for.append(gpa, target.id());
        }
        return out;
    }

    /// The node's box in the space `coord_type` counts from, or the invalid box
    /// when it states none. Upstream `PlatformNode::extents` at
    /// `node.rs:1163-1171`, whose `map_or(AtspiRect::INVALID, ...)` is the
    /// conversion here.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and
    /// `error.GeometryOutOfRange` from the `f64` to `i32` conversion.
    pub fn extents(self: PlatformNode, coord_type: wire.CoordType) NodeError!wire_rect.Rect {
        const node = try self.resolve();
        const found = try nodeExtents(node, self.context.bounds, coord_type) orelse
            return wire_rect.Rect.invalid;
        return toWireRect(found);
    }

    /// Whether the point lies inside this node's box. Upstream
    /// `PlatformNode::contains` at `node.rs:1133-1143`, whose `None` arm answers
    /// `false` rather than an error.
    ///
    /// **Errors.** `error.Defunct` and `error.TreeCycle`.
    pub fn contains(
        self: PlatformNode,
        x: i32,
        y: i32,
        coord_type: wire.CoordType,
    ) NodeError!bool {
        const node = try self.resolve();
        const found = try nodeExtents(node, self.context.bounds, coord_type) orelse return false;
        return found.contains(.{ .x = @floatFromInt(x), .y = @floatFromInt(y) });
    }

    /// The deepest node at the point, or `null`. Upstream
    /// `PlatformNode::accessible_at_point` at `node.rs:1145-1161`.
    ///
    /// The point travels two steps: out of the client's coordinate space, then
    /// through the inverse of the node's own transform. The descent is the
    /// consumer's hit test.
    ///
    /// **Bound.** `hitTestStepBound(nodes.count())`, which the consumer's own
    /// walk enforces.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn accessibleAtPoint(
        self: PlatformNode,
        x: i32,
        y: i32,
        coord_type: wire.CoordType,
    ) NodeError!?FullNodeId {
        const node = try self.resolve();
        const point = try self.context.bounds.atspiPointToAccesskitPoint(
            .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
            node,
            coord_type,
        );
        const local = affine.mulPoint(
            affine.inverse(try consumer.node_ref.geometry.transform(node)),
            point,
        );
        const found = try consumer.node_ref.geometry.nodeAtPoint(
            self.context.gpa,
            node,
            local,
            node_state.node_filter,
        ) orelse return null;
        return found.id();
    }

    /// The drawing layer this node reports.
    ///
    /// Upstream `PlatformNode::layer` at `node.rs:1173-1182` answers
    /// `Layer::Window` for a node whose mapped role is the AT-SPI window role and
    /// `Layer::Widget` for every other node. The role map sends every window to
    /// `.frame` at `node.rs:287`, and `wire.Role` declares no `window` member
    /// because no consumer role can produce one, so the comparison upstream makes
    /// has no left-hand side to match in this port and every node answers
    /// `Layer::Widget`. The test at the end of this file is the evidence.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn layer(self: PlatformNode) adapter_errors.Error!wire.Layer {
        const node = try self.resolve();
        return switch (node_role.roleOf(node)) {
            // Every member of the enum reaches this arm, and the doc comment
            // above says why none of them can reach a window arm.
            else => .widget,
        };
    }

    /// Runs this node's one action, which is a click.
    ///
    /// Upstream `PlatformNode::do_action` at `node.rs:1120-1131`. An index other
    /// than zero answers `false` without raising anything, which is upstream's
    /// early return.
    ///
    /// **Errors.** `error.Defunct` and `error.NoActionSink`.
    pub fn doAction(self: PlatformNode, index: i32) NodeError!bool {
        if (index != 0) return false;
        const located = try self.locateNode();
        try self.raise(.{
            .action = .click,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = null,
        });
        return true;
    }

    /// Asks the application to move the focus here. Upstream
    /// `PlatformNode::grab_focus` at `node.rs:1184-1192`.
    ///
    /// **Errors.** `error.Defunct` and `error.NoActionSink`.
    pub fn grabFocus(self: PlatformNode) NodeError!bool {
        const located = try self.locateNode();
        try self.raise(.{
            .action = .focus,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = null,
        });
        return true;
    }

    /// Asks the application to bring this node into view, at the edge
    /// `scroll_type` names when it names one. Upstream
    /// `PlatformNode::scroll_to` at `node.rs:1194-1202`.
    ///
    /// **Errors.** `error.Defunct` and `error.NoActionSink`.
    pub fn scrollTo(self: PlatformNode, scroll_type: wire.ScrollType) NodeError!bool {
        const located = try self.locateNode();
        try self.raise(.{
            .action = .scroll_into_view,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = if (util.atspiScrollTypeToScrollHint(scroll_type)) |hint|
                .{ .scroll_hint = hint }
            else
                null,
        });
        return true;
    }

    /// Asks the application to scroll so this node's top left corner is at the
    /// point. Upstream `PlatformNode::scroll_to_point` at `node.rs:1204-1223`.
    ///
    /// **Errors.** `error.Defunct`, `error.TreeCycle` and `error.NoActionSink`.
    pub fn scrollToPoint(
        self: PlatformNode,
        coord_type: wire.CoordType,
        x: i32,
        y: i32,
    ) NodeError!bool {
        const node = try self.resolve();
        const parent_node = try consumer.node_ref.hierarchy.filteredParent(
            node,
            node_state.node_filter,
        );
        const point = try self.context.bounds.atspiPointToAccesskitPoint(
            .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
            parent_node,
            coord_type,
        );
        const located = try self.locateNode();
        try self.raise(.{
            .action = .scroll_to_point,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .scroll_to_point = point },
        });
        return true;
    }

    /// Replaces this node's text. Upstream `PlatformNode::set_text_contents` at
    /// `node.rs:1225-1240`, which answers `false` for a read-only node without
    /// raising anything.
    ///
    /// The text is copied into the request, because the handler frees the buffer
    /// and the caller's own buffer does not outlive the call.
    ///
    /// **Errors.** `error.Defunct`, `error.OutOfMemory` and
    /// `error.NoActionSink`.
    pub fn setTextContents(self: PlatformNode, value: []const u8) NodeError!bool {
        const node = try self.resolve();
        if (consumer.node_ref.predicates.isReadOnly(node)) return false;
        const located = try self.locateNode();
        try self.raise(.{
            .action = .set_value,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .value = try self.context.gpa.dupe(u8, value) },
        });
        return true;
    }

    /// How many anchors this node carries, which is one when it states a URL and
    /// zero otherwise. Upstream `PlatformNode::n_anchors` at `node.rs:1242-1244`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn nAnchors(self: PlatformNode) adapter_errors.Error!i32 {
        const node = try self.resolve();
        return if (consumer.node_ref.strings.url(node) != null) 1 else 0;
    }

    /// The character index where this node's first anchor starts, which is `-1`
    /// because this adapter reports no rich text. Upstream
    /// `PlatformNode::hyperlink_start_index` at `node.rs:1246-1251`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn hyperlinkStartIndex(self: PlatformNode) adapter_errors.Error!i32 {
        _ = try self.resolve();
        return -1;
    }

    /// The character index where this node's last anchor ends, which is `-1`
    /// for the same reason as `hyperlinkStartIndex`. Upstream
    /// `PlatformNode::hyperlink_end_index` at `node.rs:1253-1258`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn hyperlinkEndIndex(self: PlatformNode) adapter_errors.Error!i32 {
        _ = try self.resolve();
        return -1;
    }

    /// The node anchor `index` names, or `null`. Upstream
    /// `PlatformNode::hyperlink_object` at `node.rs:1260-1268`, whose index zero
    /// answers this node itself.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn hyperlinkObject(self: PlatformNode, index: i32) adapter_errors.Error!?FullNodeId {
        _ = try self.resolve();
        if (index != 0) return null;
        return self.id;
    }

    /// The URL anchor `index` names, or the empty slice. Upstream
    /// `PlatformNode::uri` at `node.rs:1270-1278`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn uri(self: PlatformNode, index: i32) adapter_errors.Error![]const u8 {
        const node = try self.resolve();
        if (index != 0) return "";
        return consumer.node_ref.strings.url(node) orelse "";
    }

    /// Whether this node carries a usable URL. Upstream
    /// `PlatformNode::hyperlink_is_valid` at `node.rs:1280-1282`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn hyperlinkIsValid(self: PlatformNode) adapter_errors.Error!bool {
        const node = try self.resolve();
        return consumer.node_ref.strings.url(node) != null;
    }

    /// The description a client reads as this image's description. Upstream
    /// `PlatformNode::image_description` at `node.rs:1284-1286`, which forwards
    /// to `Accessible.GetDescription`.
    ///
    /// **Errors.** `error.Defunct` and `error.OutOfMemory`.
    pub fn imageDescription(
        self: PlatformNode,
        gpa: std.mem.Allocator,
    ) NodeError!std.ArrayList(u8) {
        return self.description(gpa);
    }

    /// This image's box, which is this node's box. Upstream
    /// `PlatformNode::image_extents` at `node.rs:1288-1290`.
    ///
    /// **Errors.** Every error `extents` reports.
    pub fn imageExtents(self: PlatformNode, coord_type: wire.CoordType) NodeError!wire_rect.Rect {
        return self.extents(coord_type);
    }

    /// This image's top left corner. Upstream `PlatformNode::image_position` at
    /// `node.rs:1292-1295`, which reads two members of the box it just asked for.
    ///
    /// **Errors.** Every error `extents` reports.
    pub fn imagePosition(self: PlatformNode, coord_type: wire.CoordType) NodeError!Point {
        const box = try self.extents(coord_type);
        return .{ .x = box.x, .y = box.y };
    }

    /// This image's width and height, both measured in window coordinates.
    /// Upstream `PlatformNode::image_size` at `node.rs:1297-1300`, which asks
    /// for `CoordType::Window` and not for the caller's space.
    ///
    /// **Errors.** Every error `extents` reports.
    pub fn imageSize(self: PlatformNode) NodeError!ImageSize {
        const box = try self.extents(.window);
        return .{ .width = box.width, .height = box.height };
    }

    /// How many of this container's items are selected. Upstream
    /// `PlatformNode::n_selected_children` at `node.rs:1302-1310`.
    ///
    /// **Bound.** `treeWalkStepBound(nodes.count())`, which the consumer's own
    /// item walk enforces.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.TooManyChildren` and `error.OutOfMemory`.
    pub fn nSelectedChildren(self: PlatformNode) NodeError!i32 {
        const node = try self.resolveForSelection();
        var held = try selectedItems(self.context.gpa, node);
        defer held.deinit(self.context.gpa);
        return std.math.cast(i32, held.items.len) orelse error.TooManyChildren;
    }

    /// The `selected_child_index`-th selected item, or `null`. Upstream
    /// `PlatformNode::selected_child` at `node.rs:1312-1320`.
    ///
    /// **Errors.** Every error `nSelectedChildren` reports.
    pub fn selectedChild(
        self: PlatformNode,
        selected_child_index: usize,
    ) NodeError!?FullNodeId {
        const node = try self.resolveForSelection();
        var held = try selectedItems(self.context.gpa, node);
        defer held.deinit(self.context.gpa);
        if (selected_child_index >= held.items.len) return null;
        return held.items[selected_child_index].id();
    }

    /// Selects the child at `child_index`, if it can be selected.
    ///
    /// Upstream `PlatformNode::select_child` at `node.rs:1322-1344`. A child
    /// that is already selected answers `true` and raises nothing, a child that
    /// is selectable and clickable raises a click, and any other child answers
    /// `false`. An index past the last child is `error.Defunct`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.NoActionSink` and `error.OutOfMemory`.
    pub fn selectChild(self: PlatformNode, child_index: usize) NodeError!bool {
        const node = try self.resolveForSelection();
        const handle = (try filteredChildAtIndex(node, child_index)) orelse return error.Defunct;
        const child = handle.id();
        if (consumer.node_ref.properties.isSelected(handle) == true) return true;
        if (consumer.node_ref.predicates.isSelectable(handle) and
            try consumer.node_ref.predicates.isClickable(handle, node_state.node_filter))
        {
            const located = try locate(self.context.state, child);
            try self.raise(.{
                .action = .click,
                .target_tree = located.tree_id,
                .target_node = located.local_id,
                .data = null,
            });
            return true;
        }
        return false;
    }

    /// Deselects the `selected_child_index`-th selected item, if it can be
    /// clicked. Upstream `PlatformNode::deselect_selected_child` at
    /// `node.rs:1346-1370`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.NoActionSink` and `error.OutOfMemory`.
    pub fn deselectSelectedChild(self: PlatformNode, selected_child_index: usize) NodeError!bool {
        const node = try self.resolveForSelection();
        var held = try selectedItems(self.context.gpa, node);
        defer held.deinit(self.context.gpa);
        if (selected_child_index >= held.items.len) return error.Defunct;
        const child = held.items[selected_child_index];
        if (!try consumer.node_ref.predicates.isClickable(child, node_state.node_filter)) {
            return false;
        }
        const located = try locate(self.context.state, child.id());
        try self.raise(.{
            .action = .click,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = null,
        });
        return true;
    }

    /// Whether the child at `child_index` is an item that is selected. Upstream
    /// `PlatformNode::is_child_selected` at `node.rs:1372-1379`, whose `.ok_or`
    /// turns an index past the last child into `Error::Defunct`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface` and
    /// `error.TreeCycle`.
    pub fn isChildSelected(self: PlatformNode, child_index: usize) NodeError!bool {
        const node = try self.resolveForSelection();
        const handle = (try filteredChildAtIndex(node, child_index)) orelse return error.Defunct;
        return consumer.node_ref.containers.isItemLike(handle) and
            consumer.node_ref.properties.isSelected(handle) == true;
    }

    /// Always `false`, because this adapter cannot select every child at once.
    /// Upstream `PlatformNode::select_all` at `node.rs:1381-1384`.
    ///
    /// **Errors.** This function does not fail and does not resolve the node.
    pub fn selectAll(self: PlatformNode) error{}!bool {
        _ = self;
        return false;
    }

    /// Always `false`, because this adapter cannot clear every child at once.
    /// Upstream `PlatformNode::clear_selection` at `node.rs:1386-1389`.
    ///
    /// **Errors.** This function does not fail and does not resolve the node.
    pub fn clearSelection(self: PlatformNode) error{}!bool {
        _ = self;
        return false;
    }

    /// Deselects the child at `child_index`, if it can be selected.
    ///
    /// Upstream `PlatformNode::deselect_child` at `node.rs:1391-1413`. It is
    /// `selectChild` with the two tests at `node.rs:1325` and `node.rs:1394`
    /// exchanged, and the exchange is the whole difference.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.NoActionSink` and `error.OutOfMemory`.
    pub fn deselectChild(self: PlatformNode, child_index: usize) NodeError!bool {
        const node = try self.resolveForSelection();
        const handle = (try filteredChildAtIndex(node, child_index)) orelse return error.Defunct;
        const child = handle.id();
        if (consumer.node_ref.properties.isSelected(handle) == false) return true;
        if (consumer.node_ref.predicates.isSelectable(handle) and
            try consumer.node_ref.predicates.isClickable(handle, node_state.node_filter))
        {
            const located = try locate(self.context.state, child);
            try self.raise(.{
                .action = .click,
                .target_tree = located.tree_id,
                .target_node = located.local_id,
                .data = null,
            });
            return true;
        }
        return false;
    }

    /// How many characters this node's document holds. Upstream
    /// `PlatformNode::character_count` at `node.rs:1415-1423`, which reads the
    /// end of the document range.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle` and `error.TooManyCharacters`.
    pub fn characterCount(self: PlatformNode) NodeError!i32 {
        const node = try self.resolveForText();
        return toOffset(try consumer.text.query.documentEnd(node));
    }

    /// Where the caret sits, or `-1` when the node states none. Upstream
    /// `PlatformNode::caret_offset` at `node.rs:1425-1434`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle` and `error.TooManyCharacters`.
    pub fn caretOffset(self: PlatformNode) NodeError!i32 {
        const node = try self.resolveForText();
        const focus = consumer.text.query.textSelectionFocus(node) orelse return -1;
        return toOffset(focus);
    }

    /// The text of the unit `offset` names, and where that unit starts and ends.
    /// Upstream `PlatformNode::string_at_offset` at `node.rs:1436-1457`.
    ///
    /// **Errors.** Every error `util.textRangeFromOffset` reports, plus the
    /// three of `resolveForText` and `error.OutOfMemory`.
    pub fn stringAtOffset(
        self: PlatformNode,
        offset: i32,
        granularity: wire.Granularity,
    ) NodeError!StringAtOffset {
        const node = try self.resolveForText();
        const range = try util.textRangeFromOffset(self.context.gpa, node, offset, granularity);
        var held_text = try consumer.text.range.text(self.context.gpa, range);
        errdefer held_text.deinit(self.context.gpa);
        return .{
            .text = held_text,
            .start_offset = try toOffset(consumer.text.range.start(range)),
            .end_offset = try toOffset(consumer.text.range.end(range)),
        };
    }

    /// The text between two offsets, or `error.IndexOutOfRange`. Upstream
    /// `PlatformNode::text` at `node.rs:1459-1465`, whose `ok_or` turns a range
    /// that names nothing into that tag.
    ///
    /// **Errors.** Every error `util.textRangeFromOffsets` reports, plus the
    /// three of `resolveForText` and `error.OutOfMemory`.
    pub fn text(
        self: PlatformNode,
        start_offset: i32,
        end_offset: i32,
    ) NodeError!std.ArrayList(u8) {
        const node = try self.resolveForText();
        const range = (try util.textRangeFromOffsets(
            self.context.gpa,
            node,
            start_offset,
            end_offset,
        )) orelse return error.IndexOutOfRange;
        return consumer.text.range.text(self.context.gpa, range);
    }

    /// Moves the caret to `offset`. Upstream `PlatformNode::set_caret_offset` at
    /// `node.rs:1467-1482`, which refuses a negative offset before it reaches
    /// the tree.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.IndexOutOfRange`, `error.TreeCycle`, `error.NoActionSink` and
    /// `error.OutOfMemory`.
    pub fn setCaretOffset(self: PlatformNode, offset: i32) NodeError!bool {
        const node = try self.resolveForText();
        const position = (try util.textPositionFromOffset(node, offset)) orelse
            return error.IndexOutOfRange;
        const located = try self.locateNode();
        const range = try consumer.text.range.toDegenerateRange(self.context.gpa, position);
        try self.raise(.{
            .action = .set_text_selection,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .set_text_selection = consumer.text.range.toTextSelection(range) },
        });
        return true;
    }

    /// The value of the named text attribute at `offset`, or the empty slice.
    /// Upstream `PlatformNode::text_attribute_value` at `node.rs:1484-1492`.
    ///
    /// The getter runs against the run that holds the offset and not against the
    /// node, which is what makes two offsets in one document answer differently.
    /// An unknown name answers the empty slice, which is upstream's
    /// `ATTRIBUTE_GETTERS.get(..)` returning `None` into `unwrap_or_default`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.IndexOutOfRange`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn textAttributeValue(
        self: PlatformNode,
        offset: i32,
        attribute_name: []const u8,
    ) NodeError![]u8 {
        const node = try self.resolveForText();
        const position = (try util.textPositionFromOffset(node, offset)) orelse
            return error.IndexOutOfRange;
        const getter = text_attributes.lookup(attribute_name) orelse
            return self.context.gpa.alloc(u8, 0);
        const found = try getter(self.context.gpa, consumer.text.position.innerNode(position));
        return found orelse self.context.gpa.alloc(u8, 0);
    }

    /// The attributes of the run `offset` names, without the defaults. Upstream
    /// `PlatformNode::text_attributes` at `node.rs:1494-1499`, which forwards to
    /// `text_attribute_run(offset, false)`.
    ///
    /// **Errors.** Every error `textAttributeRun` reports.
    pub fn textAttributes(self: PlatformNode, offset: i32) NodeError!TextAttributeRun {
        return self.textAttributeRun(offset, false);
    }

    /// Every text attribute the node itself declares. Upstream
    /// `PlatformNode::default_text_attributes` at `node.rs:1501-1511`.
    ///
    /// **Bound.** `text_attributes.attribute_count`, the whole domain, through
    /// the table's own length.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle` and `error.OutOfMemory`.
    pub fn defaultTextAttributes(self: PlatformNode) NodeError!TextAttributeSet {
        const node = try self.resolveForText();
        var out: TextAttributeSet = .empty();
        errdefer out.deinit(self.context.gpa);
        for (text_attributes.attributes) |entry| {
            if (try entry.getter(self.context.gpa, node)) |value| {
                out.put(entry.name, value);
            }
        }
        return out;
    }

    /// The box of the one character at `offset`, or the invalid box. Upstream
    /// `PlatformNode::character_extents` at `node.rs:1513-1528`.
    ///
    /// Only the first box of the range is used, which is upstream's `.first()`.
    /// A character that spans two boxes is therefore drawn in the first one.
    ///
    /// **Errors.** Every error `resolveForText`, `util.textRangeFromOffset` and
    /// `window_bounds.truncate` reports.
    pub fn characterExtents(
        self: PlatformNode,
        offset: i32,
        coord_type: wire.CoordType,
    ) NodeError!wire_rect.Rect {
        const node = try self.resolveForText();
        const range = try util.textRangeFromOffset(
            self.context.gpa,
            node,
            offset,
            .char,
        );
        var boxes = try consumer.text.range.boundingBoxes(self.context.gpa, range);
        defer boxes.deinit(self.context.gpa);
        if (boxes.items.len == 0) return wire_rect.Rect.invalid;
        const corner = try self.context.bounds.accesskitPointToAtspiPoint(
            boxes.items[0].topLeft(),
            node,
            coord_type,
        );
        return toWireRect(boxes.items[0].withOrigin(corner));
    }

    /// The character index nearest the point. Upstream
    /// `PlatformNode::offset_at_point` at `node.rs:1530-1544`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.TooManyCharacters` and `error.OutOfMemory`.
    pub fn offsetAtPoint(
        self: PlatformNode,
        x: i32,
        y: i32,
        coord_type: wire.CoordType,
    ) NodeError!i32 {
        const node = try self.resolveForText();
        const point = try self.context.bounds.atspiPointToAccesskitPoint(
            .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
            node,
            coord_type,
        );
        const local = affine.mulPoint(
            affine.inverse(try consumer.node_ref.geometry.transform(node)),
            point,
        );
        const position = try consumer.text.query.textPositionAtPoint(
            self.context.gpa,
            node,
            local,
        );
        return toOffset(position);
    }

    /// How many selections this node holds, which is one when it holds a
    /// selection with an extent and zero otherwise. Upstream
    /// `PlatformNode::n_selections` at `node.rs:1546-1553`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle` and `error.OutOfMemory`.
    pub fn nSelections(self: PlatformNode) NodeError!i32 {
        const node = try self.resolveForText();
        const held = try consumer.text.query.textSelection(self.context.gpa, node);
        if (held) |range| {
            if (!try consumer.text.range.isDegenerate(self.context.gpa, range)) return 1;
        }
        return 0;
    }

    /// The offsets selection `selection_num` spans, or `(-1, -1)`. Upstream
    /// `PlatformNode::selection` at `node.rs:1555-1578`, whose early return for a
    /// number other than zero is the same answer as a node with no selection.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.TooManyCharacters` and `error.OutOfMemory`.
    pub fn selection(self: PlatformNode, selection_num: i32) NodeError!SelectionOffsets {
        if (selection_num != 0) return .{ .start_offset = -1, .end_offset = -1 };
        const node = try self.resolveForText();
        const held = try consumer.text.query.textSelection(self.context.gpa, node);
        const range = held orelse return .{ .start_offset = -1, .end_offset = -1 };
        if (try consumer.text.range.isDegenerate(self.context.gpa, range)) {
            return .{ .start_offset = -1, .end_offset = -1 };
        }
        return .{
            .start_offset = try toOffset(consumer.text.range.start(range)),
            .end_offset = try toOffset(consumer.text.range.end(range)),
        };
    }

    /// Sets the one selection this node holds. Upstream
    /// `PlatformNode::add_selection` at `node.rs:1580-1583`, whose whole body is
    /// a call to `set_selection(0, ...)` because this adapter holds one
    /// selection.
    ///
    /// **Errors.** Every error `setSelection` reports.
    pub fn addSelection(self: PlatformNode, start_offset: i32, end_offset: i32) NodeError!bool {
        return self.setSelection(0, start_offset, end_offset);
    }

    /// Collapses the one selection to the caret, or to the start of the
    /// document when there is no caret. Upstream
    /// `PlatformNode::remove_selection` at `node.rs:1585-1608`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.NoActionSink`, `error.TreeCycle` and `error.OutOfMemory`.
    pub fn removeSelection(self: PlatformNode, selection_num: i32) NodeError!bool {
        if (selection_num != 0) return false;
        const node = try self.resolveForText();
        const end = consumer.text.query.textSelectionFocus(node) orelse
            try consumer.text.query.documentStart(node);
        const located = try self.locateNode();
        const range = try consumer.text.range.toDegenerateRange(self.context.gpa, end);
        try self.raise(.{
            .action = .set_text_selection,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .set_text_selection = consumer.text.range.toTextSelection(range) },
        });
        return true;
    }

    /// Sets the one selection this node holds. Upstream
    /// `PlatformNode::set_selection` at `node.rs:1610-1633`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.IndexOutOfRange`, `error.NoActionSink`, `error.TreeCycle` and
    /// `error.OutOfMemory`.
    pub fn setSelection(
        self: PlatformNode,
        selection_num: i32,
        start_offset: i32,
        end_offset: i32,
    ) NodeError!bool {
        if (selection_num != 0) return false;
        const node = try self.resolveForText();
        const range = (try util.textRangeFromOffsets(
            self.context.gpa,
            node,
            start_offset,
            end_offset,
        )) orelse return error.IndexOutOfRange;
        const located = try self.locateNode();
        try self.raise(.{
            .action = .set_text_selection,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .set_text_selection = consumer.text.range.toTextSelection(range) },
        });
        return true;
    }

    /// The box of the run between two offsets, or the invalid box. Upstream
    /// `PlatformNode::range_extents` at `node.rs:1635-1654`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle` and `error.GeometryOutOfRange`.
    pub fn rangeExtents(
        self: PlatformNode,
        start_offset: i32,
        end_offset: i32,
        coord_type: wire.CoordType,
    ) NodeError!wire_rect.Rect {
        const node = try self.resolveForText();
        const box = (try util.textRangeBoundsFromOffsets(
            self.context.gpa,
            node,
            start_offset,
            end_offset,
        )) orelse return wire_rect.Rect.invalid;
        const corner = try self.context.bounds.accesskitPointToAtspiPoint(
            box.topLeft(),
            node,
            coord_type,
        );
        return toWireRect(box.withOrigin(corner));
    }

    /// The attributes of the format run `offset` names, and where that run
    /// starts and ends.
    ///
    /// Upstream `PlatformNode::text_attribute_run` at `node.rs:1656-1693`. With
    /// `include_defaults` false, an attribute whose value at the offset equals
    /// its value at the node is left out, so the client sees only what the run
    /// overrides.
    ///
    /// **Bound.** `text_attributes.attribute_count` through the table, and one
    /// comparison per attribute.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.IndexOutOfRange`, `error.TreeCycle`, `error.TooManyCharacters`
    /// and `error.OutOfMemory`.
    pub fn textAttributeRun(
        self: PlatformNode,
        offset: i32,
        include_defaults: bool,
    ) NodeError!TextAttributeRun {
        const node = try self.resolveForText();
        const position = (try util.textPositionFromOffset(node, offset)) orelse
            return error.IndexOutOfRange;
        const inner = consumer.text.position.innerNode(position);
        var out: TextAttributeRun = .{
            .attributes = .empty(),
            .start_offset = 0,
            .end_offset = 0,
        };
        errdefer out.attributes.deinit(self.context.gpa);
        for (text_attributes.attributes) |entry| {
            const value = (try entry.getter(self.context.gpa, inner)) orelse continue;
            if (!include_defaults) {
                if (try entry.getter(self.context.gpa, node)) |fallback| {
                    defer self.context.gpa.free(fallback);
                    if (std.mem.eql(u8, value, fallback)) {
                        self.context.gpa.free(value);
                        continue;
                    }
                }
            }
            out.attributes.put(entry.name, value);
        }
        const start = if (try consumer.text.position.isFormatStart(position))
            position
        else
            try consumer.text.position_motion.backwardToFormatStart(position);
        out.start_offset = try toOffset(start);
        out.end_offset = try toOffset(try consumer.text.position_motion.forwardToFormatEnd(position));
        return out;
    }

    /// Brings the run between two offsets into view. Upstream
    /// `PlatformNode::scroll_substring_to` at `node.rs:1695-1726`.
    ///
    /// The three edges that name the bottom or the right of the range scroll to
    /// its end and every other edge scrolls to its start, which is upstream's
    /// `matches!` at `node.rs:1703-1710`. A range that names nothing answers
    /// `false` and raises nothing.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.NoActionSink` and `error.OutOfMemory`.
    pub fn scrollSubstringTo(
        self: PlatformNode,
        start_offset: i32,
        end_offset: i32,
        scroll_type: wire.ScrollType,
    ) NodeError!bool {
        const node = try self.resolveForText();
        const range = (try util.textRangeFromOffsets(
            self.context.gpa,
            node,
            start_offset,
            end_offset,
        )) orelse return false;
        const from_end = switch (scroll_type) {
            .bottom_right, .bottom_edge, .right_edge => true,
            .top_left, .top_edge, .left_edge, .anywhere => false,
        };
        const position = if (from_end)
            consumer.text.range.end(range)
        else
            consumer.text.range.start(range);
        const located = try locate(
            self.context.state,
            consumer.text.position.innerNode(position).id(),
        );
        try self.raise(.{
            .action = .scroll_into_view,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = if (util.atspiScrollTypeToScrollHint(scroll_type)) |hint|
                .{ .scroll_hint = hint }
            else
                null,
        });
        return true;
    }

    /// Scrolls so the run between two offsets has its top left corner at the
    /// point. Upstream `PlatformNode::scroll_substring_to_point` at
    /// `node.rs:1728-1758`.
    ///
    /// **Errors.** `error.Defunct`, `error.UnsupportedInterface`,
    /// `error.TreeCycle`, `error.NoActionSink` and `error.OutOfMemory`.
    pub fn scrollSubstringToPoint(
        self: PlatformNode,
        start_offset: i32,
        end_offset: i32,
        coord_type: wire.CoordType,
        x: i32,
        y: i32,
    ) NodeError!bool {
        const node = try self.resolveForText();
        const target = try self.context.bounds.atspiPointToAccesskitPoint(
            .{ .x = @floatFromInt(x), .y = @floatFromInt(y) },
            node,
            coord_type,
        );
        const box = (try util.textRangeBoundsFromOffsets(
            self.context.gpa,
            node,
            start_offset,
            end_offset,
        )) orelse return false;
        const located = try self.locateNode();
        try self.raise(.{
            .action = .scroll_to_point,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .scroll_to_point = .{ .x = target.x - box.x0, .y = target.y - box.y0 } },
        });
        return true;
    }

    /// The smallest value this node accepts, or the smallest `f64`. Upstream
    /// `PlatformNode::minimum_value` at `node.rs:1760-1762`, whose
    /// `unwrap_or(f64::MIN)` is `-floatMax(f64)` here: Rust's `f64::MIN` is the
    /// most negative finite value and not the smallest positive normal number.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn minimumValue(self: PlatformNode) adapter_errors.Error!f64 {
        const node = try self.resolve();
        return schema.numbers.minNumericValue(&node.data().properties) orelse
            -std.math.floatMax(f64);
    }

    /// The largest value this node accepts, or the largest `f64`. Upstream
    /// `PlatformNode::maximum_value` at `node.rs:1764-1766`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn maximumValue(self: PlatformNode) adapter_errors.Error!f64 {
        const node = try self.resolve();
        return schema.numbers.maxNumericValue(&node.data().properties) orelse
            std.math.floatMax(f64);
    }

    /// How much one step changes the value, or zero. Upstream
    /// `PlatformNode::minimum_increment` at `node.rs:1768-1770`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn minimumIncrement(self: PlatformNode) adapter_errors.Error!f64 {
        const node = try self.resolve();
        return schema.numbers.numericValueStep(&node.data().properties) orelse 0.0;
    }

    /// The value this node holds now, or zero. Upstream
    /// `PlatformNode::current_value` at `node.rs:1772-1777`, which reads the
    /// same property the `Value` interface test reads at `node.rs:480-482`.
    ///
    /// **Errors.** `error.Defunct`.
    pub fn currentValue(self: PlatformNode) adapter_errors.Error!f64 {
        const node = try self.resolve();
        return node_interfaces.currentValue(node) orelse 0.0;
    }

    /// Asks the application to set this node's value. Upstream
    /// `PlatformNode::set_current_value` at `node.rs:1779-1786`, whose whole body
    /// is a `do_action_internal` with no other check.
    ///
    /// **Errors.** `error.Defunct` and `error.NoActionSink`.
    pub fn setCurrentValue(self: PlatformNode, value: f64) NodeError!void {
        const located = try self.locateNode();
        try self.raise(.{
            .action = .set_value,
            .target_tree = located.tree_id,
            .target_node = located.local_id,
            .data = .{ .numeric_value = value },
        });
    }
};

/// The child cursor owns the walk bound and reports `error.TreeCycle` on exhaustion.
fn filteredChildAtIndex(node: NodeRef, index: usize) QueryError!?NodeRef {
    var children = try consumer.node_ref.hierarchy.filteredChildren(
        node,
        node_state.node_filter,
    );
    var seen: usize = 0;
    while (try children.next()) |child| {
        if (seen == index) return child;
        seen += 1;
    }
    return null;
}

/// The width and height `Image.GetImageSize` returns, in whole pixels.
pub const ImageSize = struct {
    /// The extent rightward, in pixels.
    width: i32,
    /// The extent downward, in pixels.
    height: i32,
};

/// The two offsets `Text.GetSelection` returns, both in characters.
pub const SelectionOffsets = struct {
    /// The first selected character, or `-1`.
    start_offset: i32,
    /// The character after the last one selected, or `-1`.
    end_offset: i32,
};

/// The three answers `Text.GetStringAtOffset` returns.
pub const StringAtOffset = struct {
    /// The text of the unit. The caller releases it with the window's allocator.
    text: std.ArrayList(u8),
    /// Where the unit starts, in global characters.
    start_offset: i32,
    /// Where the unit ends, in global characters.
    end_offset: i32,
};

/// The three answers `Text.GetAttributes` returns. `Text.GetDefaultAttributes`
/// returns the attributes alone.
pub const TextAttributeRun = struct {
    /// The attributes themselves. The caller releases them with the window's
    /// allocator through `TextAttributeSet.deinit`.
    attributes: TextAttributeSet,
    /// Where the run of one format starts, in global characters.
    start_offset: i32,
    /// Where it ends, in global characters.
    end_offset: i32,
};

/// The `(local identifier, tree)` pair an action request names.
pub const LocateResult = struct {
    /// The node inside `tree_id`.
    local_id: schema.NodeId,
    /// The tree that owns the node.
    tree_id: schema.TreeId,
};

/// One window's number and its tree root, which is what
/// `Accessible.GetChildAtIndex` on the application object answers with.
pub const ChildId = struct {
    /// The window's own number.
    adapter_id: usize,
    /// The node the client must ask next, which is that window's tree root.
    id: FullNodeId,
};

/// Whether two window identifiers name the same node of the same window.
///
/// **Errors.** This function does not fail.
pub fn childIdEql(left: ChildId, right: ChildId) bool {
    return left.adapter_id == right.adapter_id and std.meta.eql(left.id, right.id);
}

/// The `(local identifier, tree)` pair for `id`, or `error.Defunct`.
///
/// Upstream's `tree.state().locate_node(id)`, whose `None` arm every caller
/// turns into `Error::Defunct`.
///
/// **Errors.** `error.Defunct`.
pub fn locate(state: *const TreeState, id: FullNodeId) adapter_errors.Error!LocateResult {
    const found = state.locateNode(id) orelse return error.Defunct;
    return .{ .local_id = found.local_id, .tree_id = found.tree_id };
}

/// The `i32` character offset `position` names, or the failure upstream maps
/// `TryFromIntError` onto.
///
/// Upstream calls `.try_into()` on a `usize` at `node.rs:1420`, `:1430`, `:1447`,
/// `:1541`, `:1552`, `:1567` and `:1686`, and every one of them reports
/// `Error::TooManyCharacters`.
///
/// **Errors.** `error.TooManyCharacters` and `error.TreeCycle` from the walk
/// that counts the characters before the position.
pub fn toOffset(position: consumer.text.position.Position) NodeError!i32 {
    const index = try consumer.text.position.toGlobalUsvIndex(position);
    return std.math.cast(i32, index) orelse error.TooManyCharacters;
}

/// How many children of `node` the filter keeps.
///
/// Upstream counts `node.filtered_children(&filter)` at `node.rs:886` and `:960`,
/// and both callers report `Error::TooManyChildren`.
///
/// **Bound.** The filtered child cursor, which visits each child once.
///
/// **Errors.** `error.TreeCycle`.
pub fn countFilteredChildren(node: NodeRef) QueryError!usize {
    var children = try consumer.node_ref.hierarchy.filteredChildren(
        node,
        node_state.node_filter,
    );
    var count: usize = 0;
    while (try children.next()) |_| count += 1;
    return count;
}

/// The items of `node` that state they are selected, in tree order.
///
/// Upstream `node.items(filter).filter(|item| item.is_selected() == Some(true))`
/// at `node.rs:1304-1306`, `:1315-1317` and `:1349-1351`. The three call sites
/// are the same filter over the same list, so the port builds the list once and
/// names it.
///
/// **Bound.** `treeWalkStepBound(nodes.count())`, which the consumer's own item
/// walk enforces.
///
/// **Errors.** `error.TreeCycle` and `error.OutOfMemory`.
pub fn selectedItems(gpa: std.mem.Allocator, node: NodeRef) NodeError!std.ArrayList(NodeRef) {
    var all = try consumer.node_ref.containers.items(gpa, node, node_state.node_filter);
    defer all.deinit(gpa);
    var out: std.ArrayList(NodeRef) = .empty;
    errdefer out.deinit(gpa);
    for (all.items) |item| {
        if (consumer.node_ref.properties.isSelected(item) == true) {
            try out.append(gpa, item);
        }
    }
    return out;
}

/// The four wire members of `box`, or the failure the conversion reports.
///
/// **Errors.** `error.GeometryOutOfRange` from any of the four members.
pub fn toWireRect(box: Rect) window_bounds.GeometryError!wire_rect.Rect {
    return .{
        .x = try window_bounds.truncate(box.x0),
        .y = try window_bounds.truncate(box.y0),
        .width = try window_bounds.truncate(box.width()),
        .height = try window_bounds.truncate(box.height()),
    };
}

/// The application object every window of a process hangs under.
///
/// Upstream `PlatformRoot` at `node.rs:1804-1807`. It holds one pointer to the
/// registry, which is the whole of upstream's `Weak<RwLock<AppContext>>`: the
/// lock is gone because the port has no shared ownership and no threads at this
/// layer.
///
/// **Equality.** Upstream derives `PartialEq` and `Hash` over the pointer at
/// `node.rs:2036-2046`. Two handles built from the same registry are the same
/// object, and `eql` says so by comparing the pointers.
pub const PlatformRoot = struct {
    /// The registry every answer is read from.
    app: *const AppContext,

    /// Builds the application object. Upstream `PlatformRoot::new` at
    /// `node.rs:1810-1814`.
    ///
    /// **Errors.** This function does not fail.
    pub fn init(app: *const AppContext) PlatformRoot {
        return .{ .app = app };
    }

    /// Whether two handles name the same application object.
    ///
    /// **Errors.** This function does not fail.
    pub fn eql(self: PlatformRoot, other: PlatformRoot) bool {
        return self.app == other.app;
    }

    /// The application's name, or the empty slice. Upstream
    /// `PlatformRoot::name` at `node.rs:1828-1830`, whose
    /// `clone().unwrap_or_default()` is `nameOrEmpty`.
    ///
    /// **Errors.** This function does not fail.
    pub fn name(self: PlatformRoot) []const u8 {
        return self.app.nameOrEmpty();
    }

    /// The empty slice, always. Upstream `PlatformRoot::description` at
    /// `node.rs:1832-1834` answers a constant and never reads the registry.
    ///
    /// **Errors.** This function does not fail.
    pub fn description(self: PlatformRoot) []const u8 {
        _ = self;
        return "";
    }

    /// How many windows hang under the application. Upstream
    /// `PlatformRoot::child_count` at `node.rs:1836-1840`, which converts the
    /// registry length and reports `Error::TooManyChildren`.
    ///
    /// **Errors.** `error.TooManyChildren`.
    pub fn childCount(self: PlatformRoot) adapter_errors.Error!i32 {
        return self.app.childCount();
    }

    /// `Accessible` and `Application`, and nothing else. Upstream
    /// `PlatformRoot::interfaces` at `node.rs:1842-1844`.
    ///
    /// **Errors.** This function does not fail.
    pub fn interfaces(self: PlatformRoot) wire.InterfaceSet {
        _ = self;
        var out: wire.InterfaceSet = .empty;
        out.insert(.accessible);
        out.insert(.application);
        return out;
    }

    /// Always the AT-SPI application role. Upstream `PlatformRoot::role` at
    /// `node.rs:1846-1848`.
    ///
    /// **Errors.** This function does not fail.
    pub fn role(self: PlatformRoot) wire.Role {
        _ = self;
        return .application;
    }

    /// Always `-1`, because the application object is not a child of anything.
    /// Upstream `PlatformRoot::index_in_parent` at `node.rs:1850-1852`.
    ///
    /// **Errors.** This function does not fail.
    pub fn indexInParent(self: PlatformRoot) i32 {
        _ = self;
        return -1;
    }

    /// Always the empty set. Upstream `PlatformRoot::state` at
    /// `node.rs:1854-1856`.
    ///
    /// **Errors.** This function does not fail.
    pub fn state(self: PlatformRoot) wire.StateSet {
        _ = self;
        return .empty;
    }

    /// The window at `index`, or `null`. Upstream `PlatformRoot::child_at_index`
    /// at `node.rs:1858-1866`, which builds the child's handle from that
    /// window's own tree root.
    ///
    /// **Errors.** This function does not fail.
    pub fn childAtIndex(self: PlatformRoot, index: usize) ?PlatformNode {
        const entry = self.app.entryAt(index) orelse return null;
        return PlatformNode.init(entry.context, entry.id, entry.context.state.rootId());
    }

    /// The window's own number and its tree root at `index`, or `null`. Upstream
    /// `PlatformRoot::child_id_at_index` at `node.rs:1868-1876`.
    ///
    /// **Errors.** This function does not fail.
    pub fn childIdAtIndex(self: PlatformRoot, index: usize) ?ChildId {
        const entry = self.app.entryAt(index) orelse return null;
        return .{ .adapter_id = entry.id, .id = entry.context.state.rootId() };
    }

    /// Every window, each put through `map_child`. Upstream
    /// `PlatformRoot::map_children` at `node.rs:1878-1891`.
    ///
    /// **Bound.** The registry list, which does not grow while the walk runs.
    ///
    /// **Errors.** `error.OutOfMemory`.
    pub fn mapChildren(
        self: PlatformRoot,
        gpa: std.mem.Allocator,
        map_child: anytype,
    ) !std.ArrayList(ReturnTypeOf(map_child)) {
        var out: std.ArrayList(ReturnTypeOf(map_child)) = .empty;
        errdefer out.deinit(gpa);
        for (self.app.adapters.items) |entry| {
            try out.append(gpa, map_child(PlatformNode.init(
                entry.context,
                entry.id,
                entry.context.state.rootId(),
            )));
        }
        return out;
    }

    /// Every window's number and tree root, each put through `map_child`.
    /// Upstream `PlatformRoot::map_child_ids` at `node.rs:1893-1906`.
    ///
    /// **Bound.** The registry list, which does not grow while the walk runs.
    ///
    /// **Errors.** `error.OutOfMemory`.
    pub fn mapChildIds(
        self: PlatformRoot,
        gpa: std.mem.Allocator,
        map_child: anytype,
    ) !std.ArrayList(ReturnTypeOf(map_child)) {
        var out: std.ArrayList(ReturnTypeOf(map_child)) = .empty;
        errdefer out.deinit(gpa);
        for (self.app.adapters.items) |entry| {
            try out.append(gpa, map_child(.{
                .adapter_id = entry.id,
                .id = entry.context.state.rootId(),
            }));
        }
        return out;
    }

    /// The toolkit name the registry holds, or the empty slice. Upstream
    /// `PlatformRoot::toolkit_name` at `node.rs:1908-1910`.
    ///
    /// **Errors.** This function does not fail.
    pub fn toolkitName(self: PlatformRoot) []const u8 {
        return self.app.toolkitNameOrEmpty();
    }

    /// The toolkit version the registry holds, or the empty slice. Upstream
    /// `PlatformRoot::toolkit_version` at `node.rs:1912-1914`.
    ///
    /// **Errors.** This function does not fail.
    pub fn toolkitVersion(self: PlatformRoot) []const u8 {
        return self.app.toolkitVersionOrEmpty();
    }

    /// The number the AT-SPI registry assigned this application, or `-1`. Upstream
    /// `PlatformRoot::id` at `node.rs:1916-1918`.
    ///
    /// **Errors.** This function does not fail.
    pub fn id(self: PlatformRoot) i32 {
        return self.app.idOrMinusOne();
    }

    /// Records the number the AT-SPI registry assigned. Upstream
    /// `PlatformRoot::set_id` at `node.rs:1920-1928`, which takes the write lock
    /// and sets one field.
    ///
    /// The port's handle is behind a `*const`, because upstream's `set_id` is
    /// the only member of this struct that needs a write lock. A caller that
    /// owns the registry calls `AppContext` directly through the pointer it
    /// built the handle from, which is `platform.zig` at the C ABI.
    ///
    /// **Errors.** This function does not fail.
    pub fn setId(app: *AppContext, new_id: i32) void {
        app.id = new_id;
    }

    /// Every node of every window, each put through `map_node` together with its
    /// position and how many siblings it has.
    ///
    /// Upstream `PlatformRoot::map_descendants` at `node.rs:1930-1971`. The walk
    /// is parent before child, and the root of each window is reported with that
    /// window's own slot in the registry as its position.
    ///
    /// **Bound.** `treeWalkStepBound(nodes.count())` per window, one step per
    /// node visited, reported as `error.TreeCycle`. Upstream recurses with no
    /// bound because a Rust `Vec` cannot hold a cycle and a port's map can.
    ///
    /// **Errors.** `error.TreeCycle`, `error.IndexOutOfRange` and
    /// `error.OutOfMemory`.
    pub fn mapDescendants(
        self: PlatformRoot,
        gpa: std.mem.Allocator,
        map_node: anytype,
    ) !std.ArrayList(ReturnTypeOf(map_node)) {
        var out: std.ArrayList(ReturnTypeOf(map_node)) = .empty;
        errdefer out.deinit(gpa);
        for (self.app.adapters.items, 0..) |entry, slot| {
            const budget = consumer.tree_state.treeWalkStepBound(
                entry.context.state.nodes.count(),
            );
            try collectDescendants(
                ReturnTypeOf(map_node),
                gpa,
                entry.context,
                entry.id,
                entry.context.state.root(),
                slot,
                budget,
                &out,
                map_node,
            );
        }
        return out;
    }

    /// Every node of every window as a cache entry, passed to `mapDescendantCacheNodes_callback`.
    ///
    /// Upstream `PlatformRoot::map_descendant_cache_nodes` at `node.rs:1973-2033`.
    /// It is `mapDescendants` with a cache entry built at each step and the
    /// window's own focus flag, and it reports the first failure rather than
    /// collecting one per node: upstream pushes `Err` into the result list and
    /// `collect` stops at the first, which is what a Zig error union does.
    ///
    /// **Bound.** `treeWalkStepBound(nodes.count())` per window, as above.
    ///
    /// `mapDescendantCacheNodes_callback(gpa, entry)` consumes `entry` on success and error.
    /// It must release or transfer both owned text buffers and return a closed error union.
    /// `mapDescendantCacheNodes_release_callback(gpa, *item)` releases each item on failure.
    /// The release callback must not retain the item pointer after it returns.
    /// Both callbacks run on the calling thread and must not change the registry or trees.
    /// On success, the caller owns every item and the list buffer, all allocated with `gpa`.
    /// On error, no result survives. Mapper side effects are not undone.
    ///
    /// **Errors.** `NodeError` joined to the mapper's closed error set. `anyerror` is rejected.
    pub fn mapDescendantCacheNodes(
        self: PlatformRoot,
        gpa: std.mem.Allocator,
        mapDescendantCacheNodes_release_callback: anytype,
        mapDescendantCacheNodes_callback: anytype,
    ) (NodeError || CacheMapperErrorSet(mapDescendantCacheNodes_callback))!
        std.ArrayList(@typeInfo(ReturnTypeOf(mapDescendantCacheNodes_callback)).error_union.payload)
    {
        const Item = @typeInfo(ReturnTypeOf(mapDescendantCacheNodes_callback)).error_union.payload;
        var out: std.ArrayList(Item) = .empty;
        errdefer {
            const mapped_item_count_max = out.items.len;
            for (out.items[0..mapped_item_count_max]) |*item| {
                mapDescendantCacheNodes_release_callback(gpa, item);
            }
            out.deinit(gpa);
        }
        for (self.app.adapters.items, 0..) |entry, slot| {
            const window_focused = entry.context.state.focusId() != null;
            const budget = consumer.tree_state.treeWalkStepBound(
                entry.context.state.nodes.count(),
            );
            const slot_index = std.math.cast(i32, slot) orelse return error.IndexOutOfRange;
            try collectCacheDescendants(
                Item,
                gpa,
                entry.context,
                entry.id,
                entry.context.state.root(),
                slot_index,
                window_focused,
                budget,
                &out,
                mapDescendantCacheNodes_callback,
            );
        }
        return out;
    }
};

/// The return type of `callable`, whether it is a function or a pointer to one.
///
/// Upstream's `map_children`, `map_child_ids` and `map_descendants` take an
/// `impl Fn` and return `T: FromIterator<I>`, so the item type is an output of
/// the closure rather than a type the caller writes twice. The port names it
/// once here so that a caller passes one function and reads one list type.
///
/// **Errors.** This function does not fail.
fn ReturnTypeOf(comptime callable: anytype) type {
    const Fn = switch (@typeInfo(@TypeOf(callable))) {
        .pointer => |pointer| pointer.child,
        else => @TypeOf(callable),
    };
    return @typeInfo(Fn).@"fn".return_type.?;
}

fn CacheMapperErrorSet(comptime CacheMapperErrorSet_callback: anytype) type {
    const MapperError = @typeInfo(ReturnTypeOf(CacheMapperErrorSet_callback)).error_union.error_set;
    if (@typeInfo(MapperError).error_set == null) {
        @compileError("mapDescendantCacheNodes mapper must return a closed error set, not anyerror");
    }
    return MapperError;
}

/// Reports `node`, then every descendant of it, parent before child.
///
/// The shared body of `mapDescendants`. `budget` is the number of nodes this walk
/// may still visit and it drops by one per visit, so a tree with a cycle stops
/// with `error.TreeCycle` instead of running until the stack gives.
///
/// **Bound.** `budget`, which the caller derives from
/// `treeWalkStepBound(nodes.count())`.
///
/// **Errors.** `error.TreeCycle` and `error.OutOfMemory`.
fn collectDescendants(
    comptime Item: type,
    gpa: std.mem.Allocator,
    context: *const NodeContext,
    adapter_id: usize,
    node: NodeRef,
    index_in_parent: usize,
    budget: usize,
    out: *std.ArrayList(Item),
    map_node: anytype,
) NodeError!void {
    if (budget == 0) return error.TreeCycle;
    var children = try consumer.node_ref.hierarchy.filteredChildren(
        node,
        node_state.node_filter,
    );
    var held: std.ArrayList(NodeRef) = .empty;
    defer held.deinit(gpa);
    while (try children.next()) |child| try held.append(gpa, child);

    try out.append(gpa, map_node(
        PlatformNode.init(context, adapter_id, node.id()),
        index_in_parent,
        held.items.len,
    ));
    for (held.items, 0..) |child, child_index| {
        try collectDescendants(
            Item,
            gpa,
            context,
            adapter_id,
            child,
            child_index,
            budget - 1,
            out,
            map_node,
        );
    }
}

/// Reports `node` as a cache entry, then every descendant of it.
///
/// The shared body of `mapDescendantCacheNodes`, with the same bound and the
/// same parent-before-child order.
///
/// **Bound.** `budget`, as above.
///
/// **Errors.** Every error `cacheNodeFor` reports, plus `error.TreeCycle`,
/// `error.IndexOutOfRange` and `error.OutOfMemory`.
fn collectCacheDescendants(
    comptime Item: type,
    gpa: std.mem.Allocator,
    context: *const NodeContext,
    adapter_id: usize,
    node: NodeRef,
    index_in_parent: i32,
    window_focused: bool,
    budget: usize,
    out: *std.ArrayList(Item),
    collectCacheDescendants_callback: anytype,
) (NodeError || CacheMapperErrorSet(collectCacheDescendants_callback))!void {
    if (budget == 0) return error.TreeCycle;
    var children = try consumer.node_ref.hierarchy.filteredChildren(
        node,
        node_state.node_filter,
    );
    var held: std.ArrayList(NodeRef) = .empty;
    defer held.deinit(gpa);
    while (try children.next()) |child| try held.append(gpa, child);

    const child_count = std.math.cast(i32, held.items.len) orelse return error.TooManyChildren;
    // Reserve before creating the entry, so the collector retains no ownership at handoff.
    try out.ensureUnusedCapacity(gpa, 1);
    const entry = try cacheNodeFor(
        gpa,
        node,
        adapter_id,
        index_in_parent,
        child_count,
        window_focused,
    );
    out.appendAssumeCapacity(try collectCacheDescendants_callback(gpa, entry));

    for (held.items, 0..) |child, child_index| {
        const position = std.math.cast(i32, child_index) orelse return error.IndexOutOfRange;
        try collectCacheDescendants(
            Item,
            gpa,
            context,
            adapter_id,
            child,
            position,
            window_focused,
            budget - 1,
            out,
            collectCacheDescendants_callback,
        );
    }
}

/// The events one rewrite of one node produced.
///
/// Upstream `NodeWrapper::notify_changes` at `node.rs:593-604`, which calls five
/// comparisons in a fixed order. The order is the contract: a client that saw
/// `StateChanged` before `PropertyChange` and not the other way round reacts
/// differently to a rename.
///
/// | Step | Upstream | Events |
/// |---|---|---|
/// | 1 | `notify_state_changes` `:606-620` | one `StateChanged` per differing member, never for `focused` |
/// | 2 | `notify_property_changes` `:622-671` | `PropertyChange` for name, description, parent, role and value, plus one `Announcement` |
/// | 3 | `notify_bounds_changes` `:673-684` | one `BoundsChanged` |
/// | 4 | `notify_children_changes` `:692-705` | one `ChildrenChanged` per added and per removed child |
/// | 5 | `notify_document_changes` `:686-690` | one `LoadComplete` |
///
/// **The skipped state.** Step 1 never reports `focused`, because upstream says
/// so at `node.rs:611-614` and handles focus in the adapter's own focus-moved
/// path. A port that reported it would send a second signal for one change.
///
/// **Bound.** Step 1 walks `wire.state_count` through `StateSet.difference`.
/// Step 4 walks each of the two child lists and scans the other, so the cost is
/// the product of two lengths, both of which the tree fixes for the duration.
///
/// **Errors.** Every error the value members report, plus `error.OutOfMemory`
/// from the queue and from the copies of the two texts.
pub fn notifyChanges(
    gpa: std.mem.Allocator,
    queue: *events.EventQueue,
    new_node: NodeRef,
    old_node: NodeRef,
    bounds: window_bounds.WindowBounds,
    adapter_id: usize,
) NotifyError!void {
    try notifyStateChanges(gpa, queue, new_node, old_node, adapter_id);
    try notifyPropertyChanges(gpa, queue, new_node, old_node, adapter_id);
    try notifyBoundsChanges(gpa, queue, new_node, old_node, bounds, adapter_id);
    try notifyChildrenChanges(gpa, queue, new_node, old_node, adapter_id);
    try notifyDocumentChanges(gpa, queue, new_node, old_node, adapter_id);
}

/// One `StateChanged` per state the two nodes disagree on, never for `focused`.
///
/// Upstream `node.rs:606-620`. The comparison is `old_state ^ new_state`, which
/// is `StateSet.difference`, and the value each signal carries is the membership
/// of the new set.
///
/// **Bound.** `wire.state_count`, the width of the domain `StateSet.difference`
/// sweeps.
///
/// **Errors.** `error.TreeCycle` and `error.OutOfMemory`.
fn notifyStateChanges(
    gpa: std.mem.Allocator,
    queue: *events.EventQueue,
    new_node: NodeRef,
    old_node: NodeRef,
    adapter_id: usize,
) NodeError!void {
    // `node.rs:607-608`. Both sets are read with the window focused, because a
    // state that depends on focus must not report a change when only the focus
    // moved.
    const old_state = try node_state.stateOf(old_node, true);
    const new_state = try node_state.stateOf(new_node, true);
    var differing: [wire.state_count]wire.State = undefined;
    for (old_state.difference(new_state, &differing)) |state| {
        if (state == .focused) continue;
        try queue.push(gpa, .{
            .kind = .object,
            .member = events.member_state_changed,
            .id = nodeObjectId(new_node.id(), adapter_id),
            .detail1 = wire.stateName(state),
            .detail2 = if (new_state.contains(state)) 1 else 0,
        });
    }
}

/// One `PropertyChange` per property that moved, and one `Announcement`.
///
/// Upstream `notify_property_changes` at `node.rs:622-671`. The order is
/// upstream's: name, then the announcement that follows the name, then
/// description, then parent, then role, then value. A node whose name moved and
/// whose live priority is not `None` therefore announces before its description
/// is reported.
///
/// **Bound.** Six events, five comparisons and two list walks, all of which the
/// tree fixes for the duration of the call.
///
/// **Errors.** `error.TreeCycle`, `error.OutOfMemory` and the writer error from
/// the label walk.
fn notifyPropertyChanges(
    gpa: std.mem.Allocator,
    queue: *events.EventQueue,
    new_node: NodeRef,
    old_node: NodeRef,
    adapter_id: usize,
) NodeError!void {
    const id = nodeObjectId(new_node.id(), adapter_id);

    var name = (try nodeName(gpa, new_node)) orelse std.ArrayList(u8).empty;
    defer name.deinit(gpa);
    var old_name = (try nodeName(gpa, old_node)) orelse std.ArrayList(u8).empty;
    defer old_name.deinit(gpa);
    if (!std.mem.eql(u8, name.items, old_name.items)) {
        const text = try gpa.dupe(u8, name.items);
        errdefer gpa.free(text);
        try queue.push(gpa, .{
            .kind = .object,
            .member = member_property_change,
            .id = id,
            .detail1 = key_accessible_name,
            .any_data = .{ .text = text },
        });

        // `node.rs:631-634`. A live region announces its new name and a region
        // that is not live announces nothing.
        const live = try node_interfaces.live(new_node);
        if (live != .none) {
            try queue.push(gpa, .{
                .kind = .object,
                .member = events.member_announcement,
                .id = id,
                .detail2 = @intFromEnum(live),
                .any_data = .{ .text = text },
            });
        }
    }

    var description = (try nodeDescription(gpa, new_node)) orelse std.ArrayList(u8).empty;
    defer description.deinit(gpa);
    var old_description = (try nodeDescription(gpa, old_node)) orelse std.ArrayList(u8).empty;
    defer old_description.deinit(gpa);
    if (!std.mem.eql(u8, description.items, old_description.items)) {
        const text = try gpa.dupe(u8, description.items);
        try queue.push(gpa, .{
            .kind = .object,
            .member = member_property_change,
            .id = id,
            .detail1 = key_accessible_description,
            .any_data = .{ .text = text },
        });
    }

    const parent = try parentOrRootOf(new_node);
    const old_parent = try parentOrRootOf(old_node);
    if (!parent.eql(old_parent)) {
        try queue.push(gpa, .{
            .kind = .object,
            .member = member_property_change,
            .id = id,
            .detail1 = key_accessible_parent,
            .any_data = .{ .address = parent.objectId(adapter_id) },
        });
    }

    const role = node_role.roleOf(new_node);
    if (role != node_role.roleOf(old_node)) {
        try queue.push(gpa, .{
            .kind = .object,
            .member = member_property_change,
            .id = id,
            .detail1 = key_accessible_role,
            .any_data = .{ .integer = @intCast(@intFromEnum(role)) },
        });
    }

    // `node.rs:663-670`. A node that declares no value reports nothing at all,
    // which is upstream's `if let Some(value)` guard, and a node whose value did
    // not move reports nothing.
    if (node_interfaces.currentValue(new_node)) |value| {
        if (node_interfaces.currentValue(old_node) != value) {
            try queue.push(gpa, .{
                .kind = .object,
                .member = member_property_change,
                .id = id,
                .detail1 = key_accessible_value,
                .any_data = .{ .number = value },
            });
        }
    }
}

/// One `BoundsChanged` when the node's own box or its own transform moved.
///
/// Upstream `notify_bounds_changes` at `node.rs:673-684`. The comparison is on
/// the pair `(raw_bounds, direct_transform)`, so a node whose inherited box moved
/// because an ancestor moved raises nothing here and raises one event for that
/// ancestor instead.
///
/// **Errors.** `error.TreeCycle`, `error.GeometryOutOfRange` and
/// `error.OutOfMemory`.
fn notifyBoundsChanges(
    gpa: std.mem.Allocator,
    queue: *events.EventQueue,
    new_node: NodeRef,
    old_node: NodeRef,
    bounds: window_bounds.WindowBounds,
    adapter_id: usize,
) NodeError!void {
    const before = consumer.node_ref.geometry.rawBounds(old_node);
    const after = consumer.node_ref.geometry.rawBounds(new_node);
    const same_box = if (before) |held| (if (after) |now| std.meta.eql(held, now) else false) else after == null;
    if (same_box and std.meta.eql(
        consumer.node_ref.geometry.directTransform(old_node),
        consumer.node_ref.geometry.directTransform(new_node),
    )) return;

    const box = (try nodeExtents(new_node, bounds, .window)) orelse return;
    try queue.push(gpa, .{
        .kind = .object,
        .member = events.member_bounds_changed,
        .id = nodeObjectId(new_node.id(), adapter_id),
        .any_data = .{ .extent = try window_bounds.toWire(box) },
    });
}

/// One `ChildrenChanged` per added child and per removed child.
///
/// Upstream `notify_children_changes` at `node.rs:692-705`. The two loops are
/// upstream's and the order they run in is the order a client sees: every
/// addition first, then every removal.
///
/// **Bound.** The two child lists, each of its own length, and the membership
/// scan is over the other list, so the cost is the product of two lengths.
///
/// **Errors.** `error.TreeCycle`, `error.IndexOutOfRange` and
/// `error.OutOfMemory`.
fn notifyChildrenChanges(
    gpa: std.mem.Allocator,
    queue: *events.EventQueue,
    new_node: NodeRef,
    old_node: NodeRef,
    adapter_id: usize,
) NodeError!void {
    const id = nodeObjectId(new_node.id(), adapter_id);
    var before = try childIdsOf(gpa, old_node);
    defer before.deinit(gpa);
    var after = try childIdsOf(gpa, new_node);
    defer after.deinit(gpa);

    for (after.items, 0..) |child, index| {
        if (containsId(before.items, child)) continue;
        const position = std.math.cast(i32, index) orelse return error.IndexOutOfRange;
        try queue.push(gpa, .{
            .kind = .object,
            .member = member_children_changed,
            .id = id,
            .detail1 = child_change_add,
            .detail2 = position,
            .any_data = .{ .address = nodeObjectId(child, adapter_id) },
        });
    }
    for (before.items) |child| {
        if (containsId(after.items, child)) continue;
        try queue.push(gpa, .{
            .kind = .object,
            .member = member_children_changed,
            .id = id,
            .detail1 = child_change_remove,
            // `bus.rs:326`. A removal names no position, and the reference
            // writes minus one rather than the index it once had.
            .detail2 = -1,
            .any_data = .{ .address = nodeObjectId(child, adapter_id) },
        });
    }
}

/// One `LoadComplete` when a document stopped being busy.
///
/// Upstream `notify_document_changes` at `node.rs:686-690`. The condition has
/// three parts and all three are needed: the new node is a document, the old one
/// was busy, and the new one is not.
///
/// **Errors.** `error.OutOfMemory`.
fn notifyDocumentChanges(
    gpa: std.mem.Allocator,
    queue: *events.EventQueue,
    new_node: NodeRef,
    old_node: NodeRef,
    adapter_id: usize,
) NodeError!void {
    if (!node_interfaces.supportsDocument(new_node)) return;
    if (!consumer.node_ref.properties.isBusy(old_node)) return;
    if (consumer.node_ref.properties.isBusy(new_node)) return;
    try queue.push(gpa, .{
        .kind = .document,
        .member = member_load_complete,
        .id = nodeObjectId(new_node.id(), adapter_id),
    });
}

/// The object path a node identifier is about.
///
/// **Errors.** This function does not fail.
fn nodeObjectId(id: FullNodeId, adapter_id: usize) ObjectId {
    return .{ .node = .{ .adapter = adapter_id, .node = id } };
}

/// The identifiers of the children of `node` the filter keeps, in tree order.
///
/// **Bound.** The filtered child cursor, which visits each child once.
///
/// **Errors.** `error.TreeCycle` and `error.OutOfMemory`.
fn childIdsOf(gpa: std.mem.Allocator, node: NodeRef) NodeError!std.ArrayList(FullNodeId) {
    var children = try consumer.node_ref.hierarchy.filteredChildren(
        node,
        node_state.node_filter,
    );
    var out: std.ArrayList(FullNodeId) = .empty;
    errdefer out.deinit(gpa);
    while (try children.next()) |child| try out.append(gpa, child.id());
    return out;
}

/// Whether `list` holds `id`.
///
/// **Bound.** `list.len`, which does not change while the scan runs.
///
/// **Errors.** This function does not fail.
fn containsId(list: []const FullNodeId, id: FullNodeId) bool {
    for (list) |held| {
        if (std.meta.eql(held, id)) return true;
    }
    return false;
}

test "unsupported bulk selection returns false without resolving a node" {
    // Upstream answers false even when the node is absent or has no selection interface.
    var state: TreeState = .{};
    defer state.deinit(std.testing.allocator);
    const context: NodeContext = .{
        .state = &state,
        .app = null,
        .bounds = .empty,
        .sink = null,
        .gpa = std.testing.allocator,
    };
    const node = PlatformNode.init(&context, 7, .init(.{ .value = 99 }, .init(0)));
    try std.testing.expect(!try node.selectAll());
    try std.testing.expect(!try node.clearSelection());
}

fn fixtureId(value: u64) FullNodeId {
    return .init(.{ .value = value }, .init(0));
}

fn fixtureInsert(
    gpa: std.mem.Allocator,
    state: *TreeState,
    value: u64,
    parent_value: ?u64,
    index: usize,
    data: schema.Node,
) !void {
    try state.nodes.put(gpa, fixtureId(value), .{
        .parent_and_index = if (parent_value) |parent_value_|
            .{ .parent_id = fixtureId(parent_value_), .index = index }
        else
            null,
        .data = data,
    });
}

fn fixtureState(gpa: std.mem.Allocator, state: *TreeState) !void {
    const tree_index = try state.tree_index_map.getOrCreateIndex(gpa, schema.tree_id_root);
    try std.testing.expectEqual(@as(u32, 0), tree_index.value());
    state.root_id = fixtureId(0);
    state.focus_id = fixtureId(0);
    state.info = schema.TreeInfo.init(.{ .value = 0 });
    state.info.toolkit_name = "fixture-toolkit";
    state.info.toolkit_version = "2.0";

    {
        var root_node = schema.Node.init(gpa, .window);
        errdefer root_node.deinit();
        try schema.ids_props.setChildren(&root_node.properties, &.{
            .{ .value = 1 }, .{ .value = 2 }, .{ .value = 3 },
        });
        try fixtureInsert(gpa, state, 0, null, 0, root_node);
    }

    {
        var image = schema.Node.init(gpa, .image);
        errdefer image.deinit();
        try schema.strings.setLabel(&image.properties, "Diagram");
        try schema.strings.setDescription(&image.properties, "A tree");
        try schema.strings.setUrl(&image.properties, "https://example.test/tree");
        try schema.strings.setRoleDescription(&image.properties, "diagram");
        try schema.strings.setAuthorId(&image.properties, "diagram-id");
        try schema.option.setBounds(&image.properties, schema.rectInit(10, 20, 50, 60));
        try schema.numbers.setNumericValue(&image.properties, 4.5);
        try schema.numbers.setNumericValueStep(&image.properties, 0.25);
        try schema.ids_props.setControls(&image.properties, &.{.{ .value = 2 }});
        try fixtureInsert(gpa, state, 1, 0, 0, image);
    }

    {
        var list = schema.Node.init(gpa, .list_box);
        errdefer list.deinit();
        try schema.ids_props.setChildren(&list.properties, &.{ .{ .value = 4 }, .{ .value = 5 } });
        try fixtureInsert(gpa, state, 2, 0, 1, list);
    }
    const selected_states = [_]bool{ true, false };
    for (selected_states, 0..) |selected, index| {
        var item = schema.Node.init(gpa, .list_box_option);
        errdefer item.deinit();
        try schema.enums.setSelected(&item.properties, selected);
        item.addAction(.click);
        try fixtureInsert(gpa, state, @intCast(index + 4), 2, index, item);
    }

    {
        var document = schema.Node.init(gpa, .text_input);
        errdefer document.deinit();
        try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 6 }});
        try schema.option.setTextSelection(&document.properties, .{
            .anchor = .{ .node_id = .{ .value = 6 }, .character_index = 1 },
            .focus = .{ .node_id = .{ .value = 6 }, .character_index = 3 },
        });
        try fixtureInsert(gpa, state, 3, 0, 2, document);
    }
    {
        var run = schema.Node.init(gpa, .text_run);
        errdefer run.deinit();
        try schema.strings.setValue(&run.properties, "abcd");
        try schema.strings.setFontFamily(&run.properties, "Fixture Sans");
        try schema.vectors.setCharacterLengths(&run.properties, &.{ 1, 1, 1, 1 });
        try schema.option.setBounds(&run.properties, schema.rectInit(0, 0, 40, 20));
        try schema.vectors.setCharacterPositions(&run.properties, &.{ 0, 10, 20, 30 });
        try schema.vectors.setCharacterWidths(&run.properties, &.{ 10, 10, 10, 10 });
        try schema.enums.setTextDirection(&run.properties, .left_to_right);
        try fixtureInsert(gpa, state, 6, 3, 0, run);
    }
}

const ActionProbe = struct {
    count: usize = 0,
    last: ?ActionRequest = null,

    fn receive(context: ?*anyopaque, request: ActionRequest) void {
        const pointer = context orelse @panic("The fixture action sink requires its probe.");
        const self: *ActionProbe = @ptrCast(@alignCast(pointer));
        self.count += 1;
        self.last = request;
    }
};

fn fixtureContext(gpa: std.mem.Allocator, state: *const TreeState) NodeContext {
    return .{
        .state = state,
        .app = null,
        .bounds = .init(
            schema.rectInit(100, 200, 300, 400),
            schema.rectInit(105, 210, 295, 395),
        ),
        .sink = null,
        .gpa = gpa,
    };
}

test "node values use the real filtered tree and preserve handle identity" {
    const gpa = std.testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try fixtureState(gpa, &state);
    var app = try AppContext.init(gpa, "Fixture");
    defer app.deinit();
    var context = fixtureContext(gpa, &state);
    context.app = &app;
    try app.pushAdapter(7, &context);
    const root_node = PlatformNode.init(&context, 7, fixtureId(0));
    const image = root_node.relative(fixtureId(1));
    try std.testing.expectEqual(@as(usize, 7), image.adapterNumber());
    try std.testing.expectEqual(fixtureId(1), image.nodeId());
    try std.testing.expect(image.context == root_node.context);
    try std.testing.expectEqualStrings("Fixture", (try image.root()).name());
    try std.testing.expectEqualStrings("fixture-toolkit", image.toolkitName());
    try std.testing.expectEqualStrings("2.0", image.toolkitVersion());
    try std.testing.expectEqualStrings("diagram-id", try image.accessibleId());
    try std.testing.expectEqualStrings("diagram", try image.localizedRoleName());
    try std.testing.expectEqual(node_role.roleOf(try image.resolve()), try image.role());
    try std.testing.expectEqual(@as(i32, 3), try root_node.childCount());
    try std.testing.expectEqual(fixtureId(1), (try root_node.childAtIndex(0)).?);
    try std.testing.expectEqual(@as(?FullNodeId, null), try root_node.childAtIndex(3));
    try std.testing.expect((try image.parent()).eql(.{ .node = fixtureId(0) }));
    try std.testing.expect((try root_node.parent()) == .root);
    try std.testing.expectEqual(@as(i32, 0), try image.indexInParent());
    try std.testing.expectEqual(image.objectId().node.node, fixtureId(1));
    var name_ = try image.name(gpa);
    defer name_.deinit(gpa);
    try std.testing.expectEqualStrings("Diagram", name_.items);
    var description_ = try image.description(gpa);
    defer description_.deinit(gpa);
    try std.testing.expectEqualStrings("A tree", description_.items);
    var cache = try image.cacheNode();
    defer cache.deinit(gpa);
    try std.testing.expectEqualStrings("Diagram", cache.name);
    try std.testing.expectEqualStrings("A tree", cache.description);
    try std.testing.expectEqual(@as(usize, 7), cache.adapter_id);
    try std.testing.expectEqual(fixtureId(1), cache.id);
    try std.testing.expectEqual(@as(i32, 0), cache.child_count);
    var relations = try image.relationSet(gpa);
    defer relations.deinit(gpa);
    try std.testing.expectEqualSlices(FullNodeId, &.{fixtureId(2)}, relations.controller_for.items);
    try std.testing.expectEqual(@as(i32, 1), try image.nAnchors());
    try std.testing.expectEqual(@as(i32, 0), try root_node.nAnchors());
    try std.testing.expect(try image.hyperlinkIsValid());
    try std.testing.expect(!try root_node.hyperlinkIsValid());
    var mapped = try root_node.mapChildren(gpa, fixtureIdentity);
    defer mapped.deinit(gpa);
    try std.testing.expectEqualSlices(
        FullNodeId,
        &.{ fixtureId(1), fixtureId(2), fixtureId(3) },
        mapped.items,
    );
    try std.testing.expectEqual(@as(i32, -1), try image.hyperlinkStartIndex());
    try std.testing.expectEqual(@as(i32, -1), try image.hyperlinkEndIndex());
    var image_description = try image.imageDescription(gpa);
    defer image_description.deinit(gpa);
    try std.testing.expectEqualStrings("A tree", image_description.items);
    try std.testing.expectEqual(wire_rect.Rect.init(115, 230, 40, 40), try image.imageExtents(.screen));
    try std.testing.expectEqual(Point{ .x = 115, .y = 230 }, try image.imagePosition(.screen));
    try std.testing.expectEqual(ImageSize{ .width = 40, .height = 40 }, try image.imageSize());
    try std.testing.expectEqual(fixtureId(1), (try image.accessibleAtPoint(120, 235, .screen)).?);
    try std.testing.expectEqual(@as(?FullNodeId, null), try image.accessibleAtPoint(0, 0, .screen));
    try std.testing.expectEqual(@as(f64, 0.25), try image.minimumIncrement());
    try std.testing.expectEqual(@as(f64, 4.5), try image.currentValue());
    try std.testing.expectEqual(@as(f64, 0), try root_node.minimumIncrement());
    try std.testing.expectEqual(@as(f64, 0), try root_node.currentValue());
}

test "selection and text methods emit actions for the real consumer tree" {
    const gpa = std.testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try fixtureState(gpa, &state);
    var probe: ActionProbe = .{};
    var context = fixtureContext(gpa, &state);
    context.sink = .{ .context = &probe, .raise = ActionProbe.receive };
    const list = PlatformNode.init(&context, 7, fixtureId(2));
    try std.testing.expectEqual(@as(i32, 1), try list.nSelectedChildren());
    try std.testing.expectEqual(fixtureId(4), (try list.selectedChild(0)).?);
    try std.testing.expectEqual(@as(?FullNodeId, null), try list.selectedChild(1));
    try std.testing.expect(try list.isChildSelected(0));
    try std.testing.expect(!try list.isChildSelected(1));
    try std.testing.expect(try list.selectChild(0));
    try std.testing.expectEqual(@as(usize, 0), probe.count);
    try std.testing.expect(try list.selectChild(1));
    try std.testing.expectEqual(schema.Action.click, probe.last.?.action);
    try std.testing.expectEqual(@as(u64, 5), probe.last.?.target_node.value);
    try std.testing.expect(try list.deselectSelectedChild(0));
    try std.testing.expectEqual(@as(u64, 4), probe.last.?.target_node.value);
    try std.testing.expect(try list.deselectChild(0));
    try std.testing.expectEqual(@as(u64, 4), probe.last.?.target_node.value);
    const count = probe.count;
    try std.testing.expect(try list.deselectChild(1));
    try std.testing.expectEqual(count, probe.count);
    try std.testing.expect(!try list.selectAll());
    try std.testing.expect(!try list.clearSelection());
    try std.testing.expectError(error.Defunct, list.selectChild(2));
    try std.testing.expectError(error.Defunct, list.deselectSelectedChild(1));
    try std.testing.expectError(error.Defunct, list.isChildSelected(2));

    const document = list.relative(fixtureId(3));
    var text_ = try document.text(1, 3);
    defer text_.deinit(gpa);
    try std.testing.expectEqualStrings("bc", text_.items);
    const attribute = try document.textAttributeValue(1, "family-name");
    defer gpa.free(attribute);
    try std.testing.expectEqualStrings("Fixture Sans", attribute);
    const unknown = try document.textAttributeValue(1, "unknown");
    defer gpa.free(unknown);
    try std.testing.expectEqualStrings("", unknown);
    try std.testing.expectError(error.IndexOutOfRange, document.text(9, 10));
    try std.testing.expectError(error.IndexOutOfRange, document.textAttributeValue(9, "family-name"));
    try std.testing.expect(try document.addSelection(0, 2));
    const selection_request = probe.last orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(schema.Action.set_text_selection, selection_request.action);
    const selection_data = selection_request.data orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(selection_data) == .set_text_selection);
    const selection_ = selection_data.set_text_selection;
    try std.testing.expectEqual(@as(u64, 6), selection_.anchor.node_id.value);
    try std.testing.expectEqual(@as(usize, 0), selection_.anchor.character_index);
    try std.testing.expectEqual(@as(usize, 2), selection_.focus.character_index);
    try std.testing.expect(try document.removeSelection(0));
    const remove_request = probe.last orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(schema.Action.set_text_selection, remove_request.action);
    const remove_data = remove_request.data orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(remove_data) == .set_text_selection);
    const removed = remove_data.set_text_selection;
    try std.testing.expectEqual(@as(usize, 3), removed.anchor.character_index);
    try std.testing.expectEqual(removed.anchor, removed.focus);
    try std.testing.expect(!try document.removeSelection(1));
    const image = list.relative(fixtureId(1));
    try std.testing.expect(try image.scrollToPoint(.screen, 150, 260));
    try std.testing.expectEqual(schema.Action.scroll_to_point, probe.last.?.action);
    try std.testing.expectEqual(@as(u64, 1), probe.last.?.target_node.value);
    try std.testing.expectEqual(Point{ .x = 45, .y = 50 }, probe.last.?.data.?.scroll_to_point);
    // Upstream util.rs:44-56 uses zero as the window origin, not the decoration offset.
    try std.testing.expectEqual(
        schema.rectInit(10, 0, 30, 20),
        (try util.textRangeBoundsFromOffsets(gpa, try document.resolve(), 1, 3)).?,
    );
    try std.testing.expect(try document.scrollSubstringToPoint(1, 3, .window, 70, 80));
    try std.testing.expectEqual(@as(u64, 3), probe.last.?.target_node.value);
    try std.testing.expectEqual(Point{ .x = 60, .y = 80 }, probe.last.?.data.?.scroll_to_point);
    try std.testing.expectError(error.UnsupportedInterface, image.text(0, 1));
    try std.testing.expectError(error.UnsupportedInterface, image.selectChild(0));
    try std.testing.expectError(error.UnsupportedInterface, image.isChildSelected(0));
    try std.testing.expectError(error.UnsupportedInterface, image.deselectChild(0));
    context.sink = null;
    try std.testing.expectError(error.NoActionSink, list.selectChild(1));
    try std.testing.expectError(error.NoActionSink, image.scrollToPoint(.window, 0, 0));
}

fn fixtureIdentity(id: FullNodeId) FullNodeId {
    return id;
}

fn allocatingNodeQueries(gpa: std.mem.Allocator) !void {
    const backing = std.testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(backing);
    try fixtureState(backing, &state);
    var probe: ActionProbe = .{};
    var context = fixtureContext(gpa, &state);
    context.sink = .{ .context = &probe, .raise = ActionProbe.receive };
    const root_node = PlatformNode.init(&context, 7, fixtureId(0));
    const image = root_node.relative(fixtureId(1));
    var name_ = try image.name(gpa);
    defer name_.deinit(gpa);
    var description_ = try image.description(gpa);
    defer description_.deinit(gpa);
    var image_description = try image.imageDescription(gpa);
    defer image_description.deinit(gpa);
    var cache = try image.cacheNode();
    defer cache.deinit(gpa);
    var relations = try image.relationSet(gpa);
    defer relations.deinit(gpa);
    var children = try root_node.mapChildren(gpa, fixtureIdentity);
    defer children.deinit(gpa);
    try std.testing.expectEqual(fixtureId(1), (try image.accessibleAtPoint(120, 235, .screen)).?);
    const list = root_node.relative(fixtureId(2));
    try std.testing.expectEqual(@as(i32, 1), try list.nSelectedChildren());
    try std.testing.expectEqual(fixtureId(4), (try list.selectedChild(0)).?);
    try std.testing.expect(try list.deselectSelectedChild(0));
    const document = root_node.relative(fixtureId(3));
    var text_ = try document.text(1, 3);
    defer text_.deinit(gpa);
    const attribute = try document.textAttributeValue(1, "family-name");
    defer gpa.free(attribute);
    try std.testing.expect(try document.addSelection(0, 2));
    try std.testing.expect(try document.removeSelection(0));
    try std.testing.expect(try document.scrollSubstringToPoint(1, 3, .window, 70, 80));
}

test "node allocating queries release every partial result under fail N" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatingNodeQueries,
        .{},
    );
}

test "text caret and point wrappers use the same consumer range and affine APIs" {
    const gpa = std.testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);
    try fixtureState(gpa, &state);
    var probe: ActionProbe = .{};
    var context = fixtureContext(gpa, &state);
    context.sink = .{ .context = &probe, .raise = ActionProbe.receive };
    const document = PlatformNode.init(&context, 7, fixtureId(3));
    try std.testing.expect(try document.setCaretOffset(2));
    const request = probe.last orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(schema.Action.set_text_selection, request.action);
    const data = request.data orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.activeTag(data) == .set_text_selection);
    const selection_ = data.set_text_selection;
    try std.testing.expectEqual(@as(usize, 2), selection_.anchor.character_index);
    try std.testing.expectEqual(selection_.anchor, selection_.focus);
    try std.testing.expectEqual(@as(i32, 1), try document.offsetAtPoint(15, 15, .window));
}

fn allocatingCacheTextTransfers(gpa: std.mem.Allocator) !void {
    const values = [_][]const u8{ "Diagram", "A tree" };
    const fixture_text_count_max = values.len;
    for (values[0..fixture_text_count_max]) |value| {
        var held = try std.ArrayList(u8).initCapacity(gpa, 64);
        held.appendSliceAssumeCapacity(value);
        const transferred = try takeText(gpa, held);
        defer gpa.free(transferred);
        try std.testing.expectEqualStrings(value, transferred);
    }
    const empty = try takeText(gpa, null);
    defer gpa.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}

test "cache text ownership transfer releases grown name and description under fail N" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatingCacheTextTransfers,
        .{},
    );
}

fn cacheWalkTree(gpa: std.mem.Allocator, options: struct {
    focused: bool,
    broken_label: bool,
}) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    var update_transferred = false;
    errdefer if (!update_transferred) update.deinit(gpa);
    const roles = [_]schema.Role{
        .window, .generic_container, .image, .group, .button, .button,
    };
    const fixture_node_count_max = roles.len;
    for (roles[0..fixture_node_count_max], 0..) |role, index| {
        var data = schema.Node.init(gpa, role);
        var data_transferred = false;
        errdefer if (!data_transferred) data.deinit();
        switch (index) {
            0 => {
                try schema.ids_props.setChildren(&data.properties, &.{
                    .{ .value = 1 }, .{ .value = 3 }, .{ .value = 5 },
                });
                try schema.strings.setLabel(&data.properties, "Window");
            },
            1 => try schema.ids_props.setChildren(&data.properties, &.{.{ .value = 2 }}),
            2 => {
                try schema.strings.setLabel(&data.properties, "Retained image");
                try schema.strings.setDescription(&data.properties, "Retained description");
            },
            3 => {
                schema.flags.setHidden(&data.flags, true);
                try schema.ids_props.setChildren(&data.properties, &.{.{ .value = 4 }});
            },
            5 => if (options.broken_label) {
                try schema.ids_props.setLabelledBy(&data.properties, &.{.{ .value = 404 }});
            },
            else => {},
        }
        // pushNode consumes data even on error, so disarm cleanup before the call.
        data_transferred = true;
        try update.pushNode(gpa, .{ .value = @intCast(index) }, data);
    }
    update.tree = schema.TreeInfo.init(.{ .value = 0 });
    update.focus = .{ .value = 2 };
    update_transferred = true;
    return consumer.tree.Tree.init(gpa, update, options.focused);
}

fn cacheWalkIdentity(_: std.mem.Allocator, entry: CacheNode) error{}!CacheNode {
    return entry;
}

fn cacheWalkRelease(gpa: std.mem.Allocator, entry: *CacheNode) void {
    entry.deinit(gpa);
}

test "root cache identity retains owned name and description" {
    // Read transferred strings after the collector and its temporary buffers are gone.
    const gpa = std.testing.allocator;
    var tree = try cacheWalkTree(gpa, .{ .focused = true, .broken_label = false });
    defer tree.deinit();
    var app = try AppContext.init(gpa, "Cache fixture");
    defer app.deinit();
    var context = fixtureContext(gpa, tree.stateOf());
    context.app = &app;
    try app.pushAdapter(7, &context);
    var out = try PlatformRoot.init(&app).mapDescendantCacheNodes(
        gpa,
        cacheWalkRelease,
        cacheWalkIdentity,
    );
    defer {
        const mapped_item_count_max = out.items.len;
        for (out.items[0..mapped_item_count_max]) |*entry| entry.deinit(gpa);
        out.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expectEqualStrings("Retained image", out.items[1].name);
    try std.testing.expectEqualStrings("Retained description", out.items[1].description);
}

test "root cache preserves multi window preorder filtering indices and focus" {
    // A transparent container promotes its child. A hidden subtree contributes no entries.
    const gpa = std.testing.allocator;
    var first = try cacheWalkTree(gpa, .{ .focused = true, .broken_label = false });
    defer first.deinit();
    var second = try cacheWalkTree(gpa, .{ .focused = false, .broken_label = false });
    defer second.deinit();
    var app = try AppContext.init(gpa, "Cache fixture");
    defer app.deinit();
    var first_context = fixtureContext(gpa, first.stateOf());
    var second_context = fixtureContext(gpa, second.stateOf());
    first_context.app = &app;
    second_context.app = &app;
    try app.pushAdapter(7, &first_context);
    try app.pushAdapter(11, &second_context);
    var out = try PlatformRoot.init(&app).mapDescendantCacheNodes(
        gpa,
        cacheWalkRelease,
        cacheWalkIdentity,
    );
    defer {
        const mapped_item_count_max = out.items.len;
        for (out.items[0..mapped_item_count_max]) |*entry| entry.deinit(gpa);
        out.deinit(gpa);
    }
    try std.testing.expectEqual(@as(usize, 6), out.items.len);
    const ids = [_]u32{ 0, 2, 5, 0, 2, 5 };
    const indices = [_]i32{ 0, 0, 1, 1, 0, 1 };
    const counts = [_]i32{ 2, 0, 0, 2, 0, 0 };
    const expected_item_count_max = ids.len;
    for (out.items[0..expected_item_count_max], 0..) |entry, index| {
        try std.testing.expectEqual(fixtureId(ids[index]), entry.id);
        try std.testing.expectEqual(@as(usize, if (index < 3) 7 else 11), entry.adapter_id);
        try std.testing.expectEqual(indices[index], entry.index_in_parent);
        try std.testing.expectEqual(counts[index], entry.child_count);
        if (index == 0 or index == 3) {
            try std.testing.expect(entry.parent == .root);
            try std.testing.expectEqual(index == 0, entry.states.contains(.active));
        } else {
            try std.testing.expect(entry.parent.eql(.{ .node = fixtureId(0) }));
        }
        try std.testing.expectEqual(index == 1, entry.states.contains(.focused));
    }
}

const CacheWalkOwnedItem = struct {
    cache: CacheNode,
    copied_name: []u8,
};

fn cacheWalkReleaseItem(gpa: std.mem.Allocator, item: *CacheWalkOwnedItem) void {
    gpa.free(item.copied_name);
    item.cache.deinit(gpa);
}

fn cacheWalkMapItem(
    gpa: std.mem.Allocator,
    entry: CacheNode,
) error{OutOfMemory}!CacheWalkOwnedItem {
    var owned = entry;
    errdefer owned.deinit(gpa);
    const copied_name = try gpa.dupe(u8, entry.name);
    return .{ .cache = owned, .copied_name = copied_name };
}

fn cacheWalkRejectItem(
    gpa: std.mem.Allocator,
    entry: CacheNode,
) error{ OutOfMemory, MapperRejected }!CacheWalkOwnedItem {
    var item = try cacheWalkMapItem(gpa, entry);
    errdefer cacheWalkReleaseItem(gpa, &item);
    if (entry.id.eql(fixtureId(5))) return error.MapperRejected;
    return item;
}

fn allocatingCacheWalk(gpa: std.mem.Allocator, comptime mode: enum {
    success,
    query_error,
    mapper_error,
}) !void {
    // Keep tree construction outside fail-N so each failure targets collector or mapper storage.
    const backing = std.testing.allocator;
    var tree = try cacheWalkTree(backing, .{
        .focused = true,
        .broken_label = mode == .query_error,
    });
    defer tree.deinit();
    var app = try AppContext.init(backing, "Cache fixture");
    defer app.deinit();
    var context = fixtureContext(gpa, tree.stateOf());
    context.app = &app;
    try app.pushAdapter(7, &context);
    if (mode == .success) {
        // Twelve entries force output growth after earlier items own both input and output buffers.
        const adapter_id_end_max = 11;
        for (8..adapter_id_end_max) |adapter_id| try app.pushAdapter(adapter_id, &context);
    }
    const mapper = if (mode == .mapper_error) cacheWalkRejectItem else cacheWalkMapItem;
    var out = PlatformRoot.init(&app).mapDescendantCacheNodes(
        gpa,
        cacheWalkReleaseItem,
        mapper,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            try std.testing.expectEqual(
                @as(anyerror, if (mode == .query_error) error.NoSuchNode else error.MapperRejected),
                err,
            );
            try std.testing.expect(mode != .success);
            return;
        },
    };
    defer {
        const mapped_item_count_max = out.items.len;
        for (out.items[0..mapped_item_count_max]) |*item| cacheWalkReleaseItem(gpa, item);
        out.deinit(gpa);
    }
    try std.testing.expect(mode == .success);
    try std.testing.expectEqual(@as(usize, 12), out.items.len);
    try std.testing.expectEqualStrings("Retained image", out.items[1].cache.name);
    try std.testing.expectEqualStrings("Retained image", out.items[1].copied_name);
    try std.testing.expectEqualStrings("Retained description", out.items[1].cache.description);
}

test "root cache releases owned inputs and mapped outputs under fail N" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatingCacheWalk,
        .{.success},
    );
}

test "root cache query failure releases partial mapped outputs under fail N" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatingCacheWalk,
        .{.query_error},
    );
}

test "root cache mapper rejection consumes input and releases outputs under fail N" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        allocatingCacheWalk,
        .{.mapper_error},
    );
}
