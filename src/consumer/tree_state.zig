//! The state an application reads: every node the tree holds, the graft and
//! focus facts around them, and the queries over both.
//!
//! **Upstream.** `accesskit_consumer/src/tree.rs:59-83` gives `SubtreeState`,
//! `TreeState` and `InternalChanges`; `:488-576` gives the fifteen queries.
//! `NodeState` is `node.rs:58-61`, which `docs/33-consumer-interface-contract.md`
//! section 2 places here.
//!
//! ## What this module owns, and why the layer below it does not
//!
//! `NodeState`, `SubtreeState`, `InternalChanges` and `TreeState` are declared
//! here and nowhere else. `TreeState.nodes` is a map keyed on `FullNodeId` and
//! holding `NodeState`, so this module owns `NodeState` by the rule that a type
//! belongs to the module whose data structure holds it.
//!
//! **The import cycle with `node_id.zig` is legal and is not the reason.**
//! `NodeRef.state` is a `*const NodeState`, so `node_id.zig` needs `NodeState`,
//! and `nodeById` returns a `NodeRef`, so this file needs `NodeRef`. Zig accepts
//! circular file imports — four modules under `src/schema/` rely on it and
//! their tests run — so the cycle costs nothing. Placement is still right for
//! the ownership reason above: a second copy of `NodeState` would make
//! `NodeRef.state` point at a different type than `TreeState.nodes` holds, and
//! `nodeById` would stop typechecking at integration. A legal cycle does not
//! make the layering arbitrary.
//!
//! ## I1 to I4, and which half of each is compile time
//!
//! All four invariants are claims about the *contents* of the maps at run time,
//! so none of them is a `comptime` assertion. The split matters, because a
//! reader who assumes the list is all compile time will trust the wrong half.
//!
//! - **I1 — exactly one node has `parent_and_index == null`, and it is
//!   `root`.** Run time. The claim is about one entry out of `nodes.count()`,
//!   and no value of a type can witness another. Its *shape premise* is
//!   compile time and is pinned below: `parent_and_index` is `?ParentAndIndex`,
//!   so "no parent" is one `null` rather than a sentinel id. Run-time check:
//!   `validateGlobal` in `tree_validate.zig`, tag `error.RootNotInTree`, from
//!   the panic at `tree.rs:88`.
//! - **I2 — every id named in some `children` list has a `NodeState`.** Run
//!   time, and it is the one invariant with no compile-time half at all. It
//!   relates two run-time collections, `nodes` and the `children` property of
//!   every node, and no part of it is a statement about a type.
//!   `docs/30-port-design.md` section 4.4 records that the update algorithm
//!   establishes it and the fixture suite checks it, because a full traversal
//!   costs O(n) on an O(k) operation.
//! - **I3 — every non-root `TreeId` is in `graft_parents` once, and its subtree
//!   root's parent is that graft node at index 0.** The two clauses land in
//!   different places. The *once* clause cannot be violated by any value of
//!   `graft_parents`, because the field is a map keyed on `TreeId` and a map
//!   holds one value per key; that is a property of the type and needs no
//!   assertion. The *parent is the graft node at index 0* clause is run-time
//!   state, established by `tree.rs:469-481` inside `update`, so it belongs to
//!   `tree_apply.zig`.
//! - **I4 — `focus` is a key of `nodes`.** Run time. `focus` is a field and
//!   `nodes` is a map, so the claim is a lookup on run-time contents. Run-time
//!   check: `validateGlobal`, tag `error.FocusNotInTree`, from the panic at
//!   `tree.rs:91`.
//!
//! The invariant text is quoted from section 2, which spells the two members
//! `root` and `focus`. They are `root_id` and `focus_id` here, for the reason
//! deviation 5 gives, and the run-time checks in `tree_validate.zig` read those
//! two names.
//!
//! The defaults are why the run-time half cannot be dropped. A
//! default-constructed `TreeState` holds an empty `nodes` map, so it satisfies
//! none of the four: I1 wants exactly one parentless node and there are none,
//! and I4 wants `focus` to be a key of an empty map. The `comptime` block below
//! pins the defaults; only a run-time check over the maps establishes the
//! invariants.
//!
//! ## The store, the allocator, and who releases what
//!
//! `Node.data.properties` is a `Properties`, and `Properties` owns every buffer
//! `items` grows and stores the allocator that grew them. The stored allocator
//! must stay valid for the life of the value, and it must be the allocator that
//! released the memory this value last held, or `deinit` is a mismatched free.
//! So every buffer under `TreeState.nodes` is owned by this state, and
//! `TreeState.deinit` is what releases it.
//!
//! **The allocator is a parameter, not a ninth field.** `docs/33` section 2
//! fixes `TreeState` at eight fields, and section 4 lists `Properties`, `Tree`
//! and `ComparablePath` as the types that *hold* an allocator. `Tree` is the one
//! that holds it here: `Tree.init` seeds `next_state` with
//! `next_state.cloneInto(gpa, &state)`, so the allocator reaches this module on
//! every call that grows or releases. A field would be a second copy of the
//! handle the owner already holds.
//!
//! Copying a `TreeState` copies the five map headers, not their entries, so a
//! copy is a handle and not a second owner, and it must not be deinitialised
//! separately. `cloneInto` is the deep copy that does make a second owner.
//!
//! Every query here is a borrow the caller must not outlive. A `NodeRef` borrows
//! a node out of a `TreeState` and owns nothing; the borrow ends at the next
//! call that can grow `TreeState.nodes`, because growing the map moves its
//! entries and `state` would dangle, so rebuild every `NodeRef` after an
//! update. `toolkitName` and `toolkitVersion` borrow a slice out of the state
//! and it stays valid until the next call that writes `TreeState.info`, which
//! is an `update` carrying a `TreeInfo`.
//!
//! ## What the queries cost
//!
//! Fourteen of the fifteen are a hash lookup, a field read or a slice copy, and
//! none of them allocates. One walks: `activeDialog` at `tree.rs:547`, which
//! takes `treeWalkStepBound(self.nodes.count())` and returns `error.TreeCycle`.
//!
//! **The bound.** Each step moves to the parent, and a step that does not move
//! on to a node the walk has not seen repeats one, so a walk that has taken
//! `nodes.count()` steps has visited `nodes.count()` distinct nodes and the next
//! step must be a repeat. The count is read once at entry, because the map does
//! not grow while the walk runs. Returning the old value on exhaustion would be
//! a lie and rule C8 bans the `unreachable` that would replace the error, so
//! exhaustion is a tag.
//!
//! `docs/33` section 7 declares five bound functions and names no owning
//! module, so the split follows the ownership rule. `graftChainStepBound` and
//! `treeWalkStepBound` are here because the L4, L5, L6 and L7 walks all size
//! themselves with them and they must sit at or below L2.
//! `removalStepBound` and `subtreeRemovalBound` have exactly one consumer each
//! and belong beside it in `tree_grafts.zig`; do not move one of those here when
//! a second caller appears, and do not move one of these two down when a caller
//! moves.
//!
//! ## Recorded deviations from `docs/33`, each with its reason
//!
//! 1. **`info: TreeInfo = TreeInfo.init(.{ .value = 0 })`** where section 2
//!    writes `info: TreeInfo = .{}`. `schema/update.zig:97` gives `TreeInfo` no
//!    default field values, so `.{}` is a missing-field error rather than a
//!    default. The field initialiser exists because the type has no defaults;
//!    do not "simplify" it back. Upstream seeds the field explicitly at
//!    `tree.rs:606`, and the value is not load-bearing.
//! 2. **`root`, `focusInTree` and `focus` keep the section 2 signatures that
//!    return `NodeRef`, not an error union**, and assert where upstream writes
//!    `.unwrap()` at `tree.rs:514`, `:531` and `:540`. `docs/30-port-design.md`
//!    section 4.5 puts those three in the "an invariant the same function just
//!    established" class, so the house rule's answer is the boundary-assertion
//!    branch. Each assertion names the invariant it leans on, I1 for `root` and
//!    I4 for the other two, because `validateGlobal` is what establishes it.
//! 3. **`activeDialog` returns `QueryError!NodeRef`, so upstream's `None` at
//!    `tree.rs:553` becomes `error.NoSuchNode`.** Upstream returned an optional
//!    here; a caller migrating must expect an error and not a `?`. Section 5's
//!    seven tags leave no better fit, and `NoSuchNode` is the tag the same
//!    lookup would raise had it stayed a `?NodeRef`.
//! 4. **The two error sets are declared here rather than in `tree.zig`.** The
//!    section 5 block is headed `// src/consumer/tree.zig`, but `QueryError` is
//!    returned by this module and by the L5 and L6 walks, and `UpdateError` is
//!    returned by `tree_validate.zig`, whose import column in section 1.1 does
//!    not include `tree.zig`. Neither set is reachable from there, so `tree.zig`
//!    re-exports both and declares neither.
//! 5. **A public field and a public method cannot share a name in Zig, so where
//!    the design asks for both, the method keeps the name and the field is
//!    disambiguated.** `docs/33` section 2 spells this struct with a field
//!    `root` beside a method `root()` and a field `focus` beside a method
//!    `focus()`, and Zig 0.16.0 rejects both pairs with `duplicate struct
//!    member name`. `docs/33` section 8 pins `root`, `focus` and
//!    `focusIdInTree` as operations other modules call, so the methods keep
//!    those names and the members become `root_id` and `focus_id`, each named
//!    for the thing it holds. `node_id.zig` resolved the same collision on
//!    `NodeRef` by naming the member `node_id`, so the rule is written down
//!    twice on purpose: the next module hits the same compiler error and the
//!    sentence is what stops it being rediscovered.
//! 6. **The error-set sweep reads `error_set.?` and not `error_set.keys`.**
//!    `docs/33` section 5 writes `.error_set.keys` and `.error_set.fields.len`.
//!    Zig 0.16.0 makes `error_set` a `?[]const builtin.Type.Error` and has no
//!    `keys`, so the working form unwraps it and counts the slice. The member
//!    list and both counts are unchanged; only the accessor differs.
//!
//! ## What in the range is deliberately not ported, and why
//!
//! **The derived `Debug` impls at `tree.rs:60`, `:66` and `:78`.** Upstream
//! derives `Debug` on `SubtreeState`, `TreeState` and, through `Default` on
//! `InternalChanges`, and a `TreeUpdate` has its own `Debug` in the schema
//! layer. `docs/33` section 2 lists no `format` on any of the three, no
//! published consumer reads one, and a `format` method on `TreeState` would
//! have to walk every map and every property store, which is a cost nothing
//! here asks for. The derive is dropped rather than stubbed, because a stub
//! that prints nothing is a second source of truth about what a state holds.
//!
//! **The `Clone` derive at `tree.rs:66`.** Upstream's `#[derive(Clone)]` on
//! `TreeState` is a deep copy in Rust and a shared-storage copy in Zig, so
//! copying the name across would make two calls with one meaning into two with
//! the other. `cloneInto` is the deep copy, and the module doc above states
//! what a plain assignment is.
//!
//! **The `#[derive(Default)]` at `tree.rs:78`.** Every field of `InternalChanges`
//! defaults to `.empty`, so `InternalChanges{}` is upstream's `Default::default`
//! and the derive has no separate behaviour to carry.
//!
//! **What this module deliberately does not do.** It does not perform I/O, read
//! a clock or hold global state, so no function here takes `io: std.Io` and no
//! file under `src/consumer/` names `zio`. The update algorithm is
//! `tree_apply.zig` and the graft passes are `tree_grafts.zig`.

const std = @import("std");

const schema = @import("../schema/root.zig");
const tree_index = @import("tree_index.zig");
const node_id = @import("node_id.zig");

const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const TreeIndexMap = tree_index.TreeIndexMap;
const NodeRef = node_id.NodeRef;
const Node = schema.Node;
const NodeId = schema.NodeId;
const Role = schema.Role;
const TreeId = schema.TreeId;
const TreeInfo = schema.TreeInfo;

const assert = std.debug.assert;
const testing = std.testing;

/// Every node the tree holds, keyed by the tree that registered it.
pub const NodeMap = std.array_hash_map.Auto(FullNodeId, NodeState);
/// The root and focus of each grafted subtree, keyed by the subtree's id.
pub const TreeIdMap = std.array_hash_map.Auto(TreeId, SubtreeState);
/// The node that carries each grafted subtree, keyed by the subtree's id.
pub const TreeIdNodeMap = std.array_hash_map.Auto(TreeId, FullNodeId);
/// A set of node ids. Upstream's `HashSet<FullNodeId>` at `tree.rs:80`.
pub const NodeIdSet = std.array_hash_map.Auto(FullNodeId, void);
/// A set of tree ids. Upstream's `grafts_to_remove` at `tree.rs:180`.
pub const TreeIdSet = std.array_hash_map.Auto(TreeId, void);

/// One node as the tree holds it: where it sits, and its data.
///
/// The `data` store owns every property buffer, so a `NodeState` is released
/// with its `TreeState` and never on its own.
pub const NodeState = struct {
    /// The node whose `children` list holds this one and this one's position
    /// in it, or `null` for the one node that has no parent.
    parent_and_index: ?ParentAndIndex,

    /// The node itself, with the property store that owns its buffers.
    ///
    /// **Safety.** A copy of this field is **detached from the map that indexes
    /// it**, and writing through the copy is a use-after-free rather than a
    /// lost write. The map hands entries out by value, so
    /// `state.nodes.get(id).?.data` produces exactly such a copy; its
    /// `Properties` still shares the backing array with the map's entry, so a
    /// property setter frees the payload the map's entry points at and writes
    /// the replacement into the shared buffer. `TreeState.deinit` then walks
    /// freed memory. Five fixtures in `text/query.zig` did this before it was
    /// found.
    ///
    /// Take the pointer instead. `TreeState.getPtr` returns `*NodeState`, and
    /// `NodeRef.state` returns the same, which is what every write in this
    /// layer goes through. `NodeRef.data` returns `*const Node` and cannot be
    /// written through at all, so a read through it is always safe.
    data: Node,
};

/// The root and the focus of one grafted subtree. Upstream `tree.rs:59-64`.
///
/// Both fields are ids, so a copy is the same subtree and not a second
/// description of it.
pub const SubtreeState = struct {
    /// The node the subtree's tree data is rooted at.
    root: FullNodeId,
    /// The subtree's last effective focus, which the graft chain walks on to.
    focus: FullNodeId,
};

/// What one update changed. A caller-passed value, not a field. Upstream
/// `tree.rs:78-83`.
///
/// The three sets name the nodes each kind of change touched. `null` selects
/// the default upstream, which is to record nothing, and the default here is
/// the empty value with nothing to record.
pub const InternalChanges = struct {
    /// Nodes the update added for the first time.
    added_node_ids: NodeIdSet = .empty,
    /// Nodes the update rewrote, counting a node that was also added.
    updated_node_ids: NodeIdSet = .empty,
    /// Nodes the update removed, which the caller reports after the state has
    /// been folded in.
    removed_node_ids: NodeIdSet = .empty,

    /// Releases the three sets. The value is unusable afterwards and a second
    /// call is a double free. `gpa` must be the allocator that grew the sets.
    pub fn deinit(self: *InternalChanges, gpa: std.mem.Allocator) void {
        self.added_node_ids.deinit(gpa);
        self.updated_node_ids.deinit(gpa);
        self.removed_node_ids.deinit(gpa);
        // SAFETY: every set this value owned was released above, which is the
        // whole teardown, and no statement after this reads `self`.
        self.* = undefined;
    }
};

/// The whole tree an application reads. Upstream `tree.rs:66-76`.
///
/// **Ownership.** The state owns every buffer in `nodes`. `deinit` releases all
/// of them once; a second call is a double free. Copying the value copies the
/// five map headers and not their entries, so a copy is a handle rather than a
/// second owner and must not be deinitialised separately; `cloneInto` is the
/// deep copy. `gpa` must be the allocator every node's store was built with.
///
/// **The default value satisfies none of I1 to I4**, because `nodes` is empty
/// and I1 wants one parentless node while I4 wants `focus` to be a key. A
/// caller builds a valid state through `Tree.init`, never by defaulting it.
pub const TreeState = struct {
    /// Every node the tree holds. Growing it moves its entries, which ends every
    /// `NodeRef` and `NodeState` pointer taken before the growth.
    ///
    /// **Reading a node out of this map is a trap.** `get` returns a `NodeState`
    /// by value, and a `NodeState` by value cannot be written safely — see the
    /// note on `NodeState.data`. Use `getPtr` for anything that writes and `get`
    /// only for a node whose fields you intend to read.
    nodes: NodeMap = .empty,

    /// What the tree says about itself. Its two toolkit strings are borrowed
    /// from the update that carried them and this type never releases them.
    info: TreeInfo = TreeInfo.init(.{ .value = 0 }),

    /// The node the tree is rooted at. Its `tree_index` is `0` because
    /// `Tree.init` registers the root tree first, which is what
    /// `nodeByTreeLocalId` relies on. The member is `root_id` rather than the
    /// `root` of section 2, for the reason deviation 5 gives.
    root_id: FullNodeId = .{ .local = .{ .value = 0 }, .tree_index = .init(0) },

    /// The tree's last effective focus, graft chain included. Carried
    /// unconditionally; `is_host_focused` is what decides whether the
    /// application may read it as a focus. The member is `focus_id` for the
    /// reason `root_id` is spelled the way it is.
    focus_id: FullNodeId = .{ .local = .{ .value = 0 }, .tree_index = .init(0) },

    /// Whether the host application holds focus. It does not make `focus`
    /// absent; it makes `focusId` and `focus` report `null`.
    is_host_focused: bool = false,

    /// The root and focus of every registered subtree, keyed by that subtree's
    /// id. The root tree has an entry here too.
    subtrees: TreeIdMap = .empty,

    /// The node that carries each grafted subtree, keyed by that subtree's id.
    graft_parents: TreeIdNodeMap = .empty,

    /// The two directions of the tree-number assignment, and the counter that
    /// hands out the next number.
    tree_index_map: TreeIndexMap = .empty,

    /// Releases every property buffer in `nodes` and the five maps that hold
    /// them. `gpa` must be the allocator every node's store was built with; it
    /// is not released itself.
    ///
    /// The value is unusable afterwards and a second call is a double free. On
    /// success and on failure alike nothing survives; the only way to keep part
    /// of a state across an update is `cloneInto`.
    pub fn deinit(self: *TreeState, gpa: std.mem.Allocator) void {
        for (self.nodes.values()) |*node_state| node_state.data.deinit();
        self.nodes.deinit(gpa);
        self.subtrees.deinit(gpa);
        self.graft_parents.deinit(gpa);
        self.tree_index_map.deinit(gpa);
        // SAFETY: every buffer this value owned was released above, which is
        // the whole teardown, and no statement after this reads `self`.
        self.* = undefined;
    }

    /// Replaces what `self` held with a deep copy of `source`, and leaves
    /// `source` alone. This is upstream's `Clone` at `tree.rs:68` driven from
    /// `tree.rs:613`, and it is what makes `self` a second owner rather than a
    /// handle.
    ///
    /// The copy is built whole before `self` is touched, so `error.OutOfMemory`
    /// leaves `self` exactly as the caller passed it and the caller may retry
    /// with the same destination. On success `self` has released its old
    /// buffers and holds the copies, so `self` and `source` share nothing and
    /// releasing either releases only its own.
    ///
    /// The receiver is the destination, not `source`, and `gpa` follows it
    /// rather than coming last. Zig only builds method-call syntax when the
    /// receiver is the first parameter, so the receiver stays first and the
    /// allocator takes the next place. Section 4 rule 1 of `docs/33` asks for
    /// `gpa` first on an allocating function, and ziglint rule Z023 reports an
    /// allocator that follows any other parameter. See `tree_index.zig` for the
    /// same ruling on `TreeIndexMap`.
    pub fn cloneInto(
        self: *TreeState,
        gpa: std.mem.Allocator,
        source: *const TreeState,
    ) std.mem.Allocator.Error!void {
        var scratch: TreeState = .{
            .info = source.info,
            .root_id = source.root_id,
            .focus_id = source.focus_id,
            .is_host_focused = source.is_host_focused,
        };
        // Every allocation below lands in `scratch`, so one teardown covers the
        // nodes copied so far as well as the maps.
        errdefer scratch.deinit(gpa);

        try scratch.nodes.ensureTotalCapacity(gpa, source.nodes.count());
        var nodes = source.nodes.iterator();
        while (nodes.next()) |entry| {
            const node_state = entry.value_ptr.*;
            try scratch.nodes.put(gpa, entry.key_ptr.*, .{
                .parent_and_index = node_state.parent_and_index,
                .data = try Node.clone(gpa, &node_state.data),
            });
        }

        try scratch.subtrees.ensureTotalCapacity(gpa, source.subtrees.count());
        var subtrees = source.subtrees.iterator();
        while (subtrees.next()) |entry| {
            try scratch.subtrees.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
        }

        try scratch.graft_parents.ensureTotalCapacity(gpa, source.graft_parents.count());
        var grafts = source.graft_parents.iterator();
        while (grafts.next()) |entry| {
            try scratch.graft_parents.put(gpa, entry.key_ptr.*, entry.value_ptr.*);
        }

        try scratch.tree_index_map.cloneInto(gpa, &source.tree_index_map);

        self.deinit(gpa);
        self.* = scratch;
    }

    // --- The queries. None allocates and none returns an error set: a missing
    // --- node is `null`.

    /// Whether `id` names a node this state holds. Upstream `tree.rs:488-490`.
    pub fn hasNode(self: *const TreeState, id: FullNodeId) bool {
        return self.nodes.contains(id);
    }

    /// The node `id` names, or `null` when the state holds no entry for it.
    /// Upstream `tree.rs:492-498`.
    ///
    /// The result borrows the state: it ends at the next call that can grow
    /// `nodes`, and a plain struct assignment of the state is not a substitute
    /// for `cloneInto` while a result is held.
    pub fn nodeById(self: *const TreeState, id: FullNodeId) ?NodeRef {
        return NodeRef.init(self, id);
    }

    /// The node `local` names inside the tree `tree`, or `null` when `tree`
    /// was never registered or the node is not one of its nodes. A `null`
    /// return therefore has two causes and the caller cannot tell them apart,
    /// which is upstream's shape at `tree.rs:500-507`.
    pub fn nodeByTreeLocalId(self: *const TreeState, local: NodeId, tree: TreeId) ?NodeRef {
        const index = self.tree_index_map.getIndex(tree) orelse return null;
        return self.nodeById(.{ .local = local, .tree_index = index });
    }

    /// The node the tree is rooted at. Upstream `tree.rs:509-511`.
    pub fn rootId(self: *const TreeState) FullNodeId {
        return self.root_id;
    }

    /// The node the tree is rooted at. Upstream `tree.rs:513-515`.
    ///
    /// Precondition, from I1: `root` is a key of `nodes`, which
    /// `validateGlobal` establishes and reports as `error.RootNotInTree`.
    /// Upstream's `.unwrap()` on that precondition becomes the assertion below.
    pub fn root(self: *const TreeState) NodeRef {
        assert(self.nodes.contains(self.root_id));
        return self.nodeById(self.root_id).?;
    }

    /// The root of the subtree `tree_id` names, or `null` when no such subtree
    /// is registered. Upstream `tree.rs:517-520`.
    pub fn subtreeRoot(self: *const TreeState, tree_id: TreeId) ?FullNodeId {
        const subtree = self.subtrees.get(tree_id) orelse return null;
        return subtree.root;
    }

    /// Whether the host application holds focus. Upstream `tree.rs:522-524`.
    pub fn isHostFocused(self: *const TreeState) bool {
        return self.is_host_focused;
    }

    /// The tree's last effective focus whether or not the host holds focus.
    /// Upstream `tree.rs:526-528`. `focusId` is the one that answers that
    /// question, and this is the raw field read it is built on.
    pub fn focusIdInTree(self: *const TreeState) FullNodeId {
        return self.focus_id;
    }

    /// The node `focus` names. Upstream `tree.rs:530-532`.
    ///
    /// Precondition, from I4: `focus` is a key of `nodes`, which
    /// `validateGlobal` establishes and reports as `error.FocusNotInTree`.
    pub fn focusInTree(self: *const TreeState) NodeRef {
        assert(self.nodes.contains(self.focus_id));
        return self.nodeById(self.focus_id).?;
    }

    /// The focused node's id when the host holds focus, `null` otherwise.
    /// Upstream `tree.rs:534-536`.
    pub fn focusId(self: *const TreeState) ?FullNodeId {
        if (!self.is_host_focused) return null;
        return self.focus_id;
    }

    /// The focused node, or the node its `active_descendant` names, or `null`
    /// when the host holds no focus. Upstream `tree.rs:538-543`.
    ///
    /// Precondition, from I4: `focus` is a key of `nodes` whenever
    /// `is_host_focused`, which `validateGlobal` establishes and reports as
    /// `error.FocusNotInTree`. The `active_descendant` lookup may legitimately
    /// miss, and upstream's `unwrap_or` at `tree.rs:541` turns that miss into
    /// the focused node, so it is not an error here either.
    pub fn focus(self: *const TreeState) ?NodeRef {
        const id = self.focusId() orelse return null;
        assert(self.nodes.contains(id));
        const focused = self.nodeById(id) orelse return null;
        return node_id.activeDescendant(focused) orelse focused;
    }

    /// The nearest dialog at or above the focus, walking the parent chain.
    /// Upstream `tree.rs:545-554`.
    ///
    /// `error.NoSuchNode` when the host holds no focus, or when the chain from
    /// the focus reaches the root without a dialog. Upstream returned `None`
    /// for both, and the port returns an error instead: a caller migrating must
    /// not look for an optional here.
    ///
    /// `error.TreeCycle` when the chain takes `treeWalkStepBound(nodes.count())`
    /// steps, which a tree whose `parent_and_index` entries form a loop
    /// reaches. Upstream's `while` at `tree.rs:547` has no bound and hangs
    /// there. The count is read once at entry, because the map does not grow
    /// while the walk runs.
    pub fn activeDialog(self: *const TreeState) QueryError!NodeRef {
        const step_bound = treeWalkStepBound(self.nodes.count());
        var current = self.focus();
        var steps: usize = 0;
        while (current) |candidate| {
            switch (candidate.data().role) {
                .alert_dialog, .dialog => return candidate,
                else => {},
            }
            const parent = candidate.state.parent_and_index orelse
                return error.NoSuchNode;
            steps += 1;
            if (steps > step_bound) return error.TreeCycle;
            current = self.nodeById(parent.parent_id);
        }
        return error.NoSuchNode;
    }

    /// The toolkit name, or `"AccessKit"` when the tree does not name one.
    /// Upstream `tree.rs:556-558`.
    ///
    /// The returned bytes are borrowed from `info.toolkit_name`, or from this
    /// file's string literal when the tree names no toolkit. A literal is
    /// never invalidated.
    pub fn toolkitName(self: *const TreeState) []const u8 {
        return self.info.toolkit_name orelse "AccessKit";
    }

    /// The toolkit version, or `null`. Upstream `tree.rs:560-565`.
    ///
    /// The version is reported only when `info.toolkit_name` is set, because
    /// upstream filters the version on the name being present and the port
    /// follows upstream rather than correcting it. The bytes are borrowed from
    /// `info.toolkit_version` and end at the next write to `info`.
    pub fn toolkitVersion(self: *const TreeState) ?[]const u8 {
        if (self.info.toolkit_name == null) return null;
        return self.info.toolkit_version;
    }

    /// The local id and the tree id behind `id`, or `null` when the state holds
    /// no node for it or its `tree_index` names no registered tree.
    /// Upstream `tree.rs:567-575`.
    ///
    /// The two causes are one `null` here, as they are upstream, so a caller
    /// cannot tell a stale id from an unregistered tree.
    pub fn locateNode(self: *const TreeState, id: FullNodeId) ?struct {
        local_id: NodeId,
        tree_id: TreeId,
    } {
        if (!self.hasNode(id)) return null;
        const tree = self.tree_index_map.getId(id.tree_index) orelse return null;
        return .{ .local_id = id.local, .tree_id = tree };
    }
};

/// Bound 1 of 9 in `docs/33` section 7. The graft chain
/// `computeEffectiveFocus` follows, `tree.rs:101-120`.
///
/// Each step moves to a node whose `tree_id` is set, and every non-root tree id
/// is in `graft_parents` once, so the chain is one step per registered subtree
/// plus one final step.
///
/// It is declared here rather than beside `computeEffectiveFocus`, which is a
/// function and not a data structure. `tree_state.zig` is the lowest module
/// that returns it, and `tree_validate.zig` and `tree_apply.zig` both do.
pub fn graftChainStepBound(registered_subtree_count: usize) usize {
    return registered_subtree_count + 1;
}

/// Bound 5 of 9 in `docs/33` section 7, and the bound of every other walk in
/// the layer. Upstream's five ancestor and child walks at `node.rs:143`, `:240`,
/// `:259`, `:278`, `:302` and `:312`, and `tree_state.zig` at `tree.rs:547`.
///
/// Each step moves to a different node and the tree holds at most `node_count`
/// nodes, so a walk cannot take more. A cycle repeats a node, and the count
/// catches the repeat. Every caller returns `error.TreeCycle` on exhaustion.
///
/// It is declared here because four modules below and beside this one size a
/// walk with it, so it must sit at or below L2 rather than beside its first
/// caller.
pub fn treeWalkStepBound(node_count: usize) usize {
    return node_count;
}

/// Failures of `Tree.init`, `Tree.updateAndProcessChanges`,
/// `Tree.updateHostFocusStateAndProcessChanges` and the update algorithm they
/// call.
///
/// The first thirteen tags are conditions a platform can send. The remaining two
/// come from the port: `NodeMissingFromState` replaces an `.unwrap()` at
/// `tree.rs:367` and `GraftChainTooLong` replaces an unbounded walk.
///
/// The thirteen platform tags replace the 15 upstream `panic!` sites in
/// `accesskit_consumer/src/tree.rs` outside test code. `grep -c` reports 21
/// hits, of which 6 sit after `#[cfg(test)]` at `tree.rs:735`. Two pairs
/// collapse, `:211` with `:273` and `:191` with `:449`, because each pair is
/// one condition, so 15 sites give 13 tags. The other 2 of the 19 sites sit at
/// `text.rs:256`, `:278`, `:1600` and `:1639` and give the tags in
/// `QueryError`.
pub const UpdateError = error{
    /// `Tree.init` given an update whose `tree` is absent. tree.rs:594
    NoRootTree,
    /// `Tree.init` given a subtree update. tree.rs:599
    NotTheRootTree,
    /// The root has no NodeState. tree.rs:88
    RootNotInTree,
    /// The recorded focus has no NodeState. tree.rs:91
    FocusNotInTree,
    /// Focus on a graft node with no subtree. tree.rs:112
    GraftWithoutSubtree,
    /// Subtree pushed with no graft node. tree.rs:135
    SubtreeWithoutGraft,
    /// Subtree updated before its tree data. tree.rs:142
    SubtreeDoesNotExist,
    /// An update grafts the root tree. tree.rs:188
    CannotGraftTheRootTree,
    /// Two graft parents, or a second at commit. :191, :449
    DuplicateGraftParent,
    /// tree_id and a non-empty children list. :211, :273
    GraftWithChildren,
    /// One node names the same child twice. tree.rs:236
    DuplicateChild,
    /// A node is neither present nor a child. tree.rs:318
    OrphanNode,
    /// A child id is neither present nor a node. tree.rs:325
    OrphanChild,
    /// An internal removal found no node. tree.rs:367
    NodeMissingFromState,
    /// The bound in section 7.1 row 1. No upstream site.
    GraftChainTooLong,
    OutOfMemory,
};

/// Failures of every query that walks the tree. The first six tags are the set
/// `docs/30-port-design.md` section 4.5 records. `TreeCycle` is this document's
/// addition: the six walks in section 7.1 rows 5 to 9 must report exhaustion and
/// rule C8 bans `unreachable`, so they need a tag. It joins this set, so one
/// catch.
pub const QueryError = error{
    /// text.rs:256, :278
    InvalidPosition,
    /// text.rs:1600, :1639
    IndexOutOfRange,
    /// Replaces the unbounded walk at text.rs:117, :131
    LineChainCycle,
    /// Upstream drops this value inside Properties.get_mut
    WrongPropertyKind,
    /// The state holds no node for the id
    NoSuchNode,
    /// A parent, child or transform walk hit its bound. No upstream site.
    TreeCycle,
    OutOfMemory,
};

comptime {
    // The eight fields of `TreeState`, in the order section 2 names them. A
    // field added or renamed is a build failure rather than a diff a reviewer
    // has to notice, and the count is what keeps the "allocator is a parameter,
    // not a ninth field" sentence in the module doc checkable.
    const tree_fields = @typeInfo(TreeState).@"struct";
    const tree_wanted = [_]struct { name: []const u8, ty: type }{
        .{ .name = "nodes", .ty = NodeMap },
        .{ .name = "info", .ty = TreeInfo },
        .{ .name = "root_id", .ty = FullNodeId },
        .{ .name = "focus_id", .ty = FullNodeId },
        .{ .name = "is_host_focused", .ty = bool },
        .{ .name = "subtrees", .ty = TreeIdMap },
        .{ .name = "graft_parents", .ty = TreeIdNodeMap },
        .{ .name = "tree_index_map", .ty = TreeIndexMap },
    };
    assert(tree_fields.field_names.len == tree_wanted.len);
    // A `comptime` block already unrolls this loop, and Zig 0.16 rejects the
    // `inline` keyword there as redundant.
    for (tree_wanted, tree_fields.field_names, tree_fields.field_types) |want, got_name, got_type| {
        assert(std.mem.eql(u8, got_name, want.name));
        assert(got_type == want.ty);
    }

    // I1's shape premise: "no parent" is one `null`, not a sentinel id, so the
    // root is the only node that can carry it. I2 has no shape premise, which
    // is why it has no assertion here.
    const node_fields = @typeInfo(NodeState).@"struct";
    assert(node_fields.field_names.len == 2);
    assert(node_fields.field_types[0] == ?ParentAndIndex);
    assert(node_fields.field_types[1] == Node);

    // I3's "once" clause: both fields are ids, so a `SubtreeState` copy is the
    // same subtree rather than a second description of it.
    const subtree_fields = @typeInfo(SubtreeState).@"struct";
    assert(subtree_fields.field_names.len == 2);
    assert(subtree_fields.field_types[0] == FullNodeId);
    assert(subtree_fields.field_types[1] == FullNodeId);

    // I1 and I4 cannot be compile-time claims, and the default value is why.
    // An empty `nodes` satisfies neither, so the run-time check in
    // `tree_validate.zig` is load-bearing rather than decorative.
    const blank: TreeState = .{};
    assert(blank.nodes.count() == 0);
    assert(blank.root_id.local.eql(blank.focus_id.local));
    assert(blank.root_id.tree_index == blank.focus_id.tree_index);

    // Section 7 pins the derivations of the two bounds this module owns, at
    // zero and at a size a test uses. The last line says the graft chain is
    // strictly longer than the node bound, so they are not one constant.
    assert(graftChainStepBound(0) == 1);
    assert(graftChainStepBound(65_535) == 65_536);
    assert(treeWalkStepBound(0) == 0);
    assert(treeWalkStepBound(65_536) == 65_536);
    assert(graftChainStepBound(65_535) > treeWalkStepBound(65_535));

    // Every tag of both sets is named, and a delete is a compile error. Zig
    // 0.16.0 makes `error_set` an optional slice and has no `keys`, so the
    // sweep takes the unwrapped value; `docs/33` section 5's `.keys` spelling
    // predates it and is recorded as deviation 6.
    for (@typeInfo(UpdateError).error_set.error_names.?) |tag| {
        assert(tag.len > 0);
    }
    for (@typeInfo(QueryError).error_set.error_names.?) |tag| {
        assert(tag.len > 0);
    }
    // 13 platform tags, 2 port tags and OutOfMemory.
    assert(@typeInfo(UpdateError).error_set.error_names.?.len == 16);
    assert(@typeInfo(QueryError).error_set.error_names.?.len == 7);
}

// --- Fixtures ----------------------------------------------------------------

const test_tree = schema.tree_id_root;
const test_subtree = schema.treeIdFromBytes(.{ 7, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

/// Puts one parentless node into `state` and returns its id.
fn putNode(
    gpa: std.mem.Allocator,
    state: *TreeState,
    local: u64,
    role: Role,
) std.mem.Allocator.Error!FullNodeId {
    const id = FullNodeId.init(.{ .value = local }, .init(0));
    try state.nodes.put(gpa, id, .{
        .parent_and_index = null,
        .data = Node.init(gpa, role),
    });
    return id;
}

/// Records `child` as the `index`th entry of `parent`'s `children` list.
fn setParent(
    state: *TreeState,
    child: FullNodeId,
    parent: FullNodeId,
    index: usize,
) UpdateError!void {
    const entry = state.nodes.getPtr(child) orelse return error.NodeMissingFromState;
    entry.parent_and_index = .{ .parent_id = parent, .index = index };
}

/// A state with three nodes, a label, a subtree, a graft parent and two
/// registered trees, so that every map in the struct owns memory.
fn populatedState(gpa: std.mem.Allocator, state: *TreeState) UpdateError!void {
    _ = try state.tree_index_map.getOrCreateIndex(gpa, test_tree);
    _ = try state.tree_index_map.getOrCreateIndex(gpa, test_subtree);

    const root_id = try putNode(gpa, state, 1, .group);
    const child = try putNode(gpa, state, 2, .button);
    _ = try putNode(gpa, state, 3, .label);

    const root_entry = state.nodes.getPtr(root_id) orelse return error.NodeMissingFromState;
    try schema.strings.setLabel(&root_entry.data.properties, "root label");

    state.root_id = root_id;
    state.focus_id = child;
    try state.subtrees.put(gpa, test_tree, .{ .root = root_id, .focus = root_id });
    try state.graft_parents.put(gpa, test_subtree, root_id);
    try setParent(state, child, root_id, 0);
}

/// A parent chain `count` deep: the returned id is the deepest node, each one
/// above it is the `parent_id` of the one below, and the topmost node keeps a
/// `null` `parent_and_index` so a walk ends there. `top_role` goes on that
/// topmost node, because a walk from the focus upwards reaches it last.
fn chain(
    gpa: std.mem.Allocator,
    state: *TreeState,
    count: usize,
    top_role: Role,
) UpdateError!FullNodeId {
    var ids: [8]FullNodeId = undefined;
    // The array is the bound on the loop below, and the assertion is what makes
    // it a named one instead of an out-of-bounds trap the caller reaches by
    // accident.
    assert(count >= 1);
    assert(count <= ids.len);
    for (0..count) |position| {
        ids[position] = try putNode(gpa, state, @intCast(position + 1), .group);
    }
    for (1..count) |position| {
        try setParent(state, ids[position], ids[position - 1], 0);
    }
    const top_entry = state.nodes.getPtr(ids[0]) orelse
        return error.NodeMissingFromState;
    top_entry.data.setRole(top_role);
    return ids[count - 1];
}

// --- Tests -------------------------------------------------------------------

test "hasNode answers for a node the state holds and against one it does not" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const present = try putNode(gpa, &state, 1, .group);
    const absent = FullNodeId.init(.{ .value = 404 }, .init(0));

    try testing.expect(state.hasNode(present));
    try testing.expect(!state.hasNode(absent));
}

test "nodeById finds the entry and reports absent as null" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = try putNode(gpa, &state, 2, .button);
    const node = state.nodeById(id) orelse return error.NodeMissingFromState;
    try testing.expectEqual(Role.button, node.data().role);

    const absent = FullNodeId.init(.{ .value = 77 }, .init(0));
    try testing.expect(state.nodeById(absent) == null);
}

test "nodeByTreeLocalId needs both the tree registered and the node present" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const index = try state.tree_index_map.getOrCreateIndex(gpa, test_tree);
    const id = FullNodeId.init(.{ .value = 5 }, index);
    try state.nodes.put(gpa, id, .{
        .parent_and_index = null,
        .data = Node.init(gpa, .check_box),
    });

    const found = state.nodeByTreeLocalId(.{ .value = 5 }, test_tree) orelse
        return error.NodeMissingFromState;
    try testing.expectEqual(Role.check_box, found.data().role);

    // The tree is registered and the node is not, so the answer is null.
    try testing.expect(state.nodeByTreeLocalId(.{ .value = 6 }, test_tree) == null);
    // The node exists but the tree was never registered, so the lookup cannot
    // build a `FullNodeId` and the answer is null too.
    try testing.expect(state.nodeByTreeLocalId(.{ .value = 5 }, test_subtree) == null);
}

test "rootId and root both name the root the state was given" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = try putNode(gpa, &state, 9, .group);
    state.root_id = id;

    try testing.expectEqual(id, state.rootId());
    try testing.expectEqual(Role.group, state.root().data().role);
    try testing.expectEqual(id, state.root().id());
}

test "subtreeRoot answers for a registered subtree and not for an unknown one" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const root_id = try putNode(gpa, &state, 1, .group);
    try state.subtrees.put(gpa, test_subtree, .{ .root = root_id, .focus = root_id });

    try testing.expectEqual(root_id, state.subtreeRoot(test_subtree).?);

    const unknown = schema.treeIdFromBytes(@splat(200));
    try testing.expect(state.subtreeRoot(unknown) == null);
}

test "isHostFocused reports the flag and nothing else" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    try testing.expect(!state.isHostFocused());
    state.is_host_focused = true;
    try testing.expect(state.isHostFocused());
}

test "focusIdInTree answers even while the host holds no focus" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = try putNode(gpa, &state, 3, .button);
    state.focus_id = id;

    try testing.expectEqual(id, state.focusIdInTree());
    try testing.expect(state.focusId() == null);
}

test "focusInTree names the recorded focus whether or not the host holds it" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = try putNode(gpa, &state, 3, .button);
    state.focus_id = id;

    try testing.expectEqual(Role.button, state.focusInTree().data().role);
    // The precondition is I4 and not the focus flag, so this is unchanged when
    // the host holds no focus. A reader who expected `null` here would read
    // `focus`, which is the query that consults the flag.
    state.is_host_focused = true;
    try testing.expectEqual(id, state.focusInTree().id());
}

test "focusId and focus report null until the host holds focus" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = try putNode(gpa, &state, 4, .button);
    state.focus_id = id;

    try testing.expect(state.focusId() == null);
    try testing.expect(state.focus() == null);

    state.is_host_focused = true;
    try testing.expectEqual(id, state.focusId().?);
    const focused = state.focus() orelse return error.NodeMissingFromState;
    try testing.expectEqual(Role.button, focused.data().role);
}

test "focus follows active_descendant and falls back to the focused node" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const focused_id = try putNode(gpa, &state, 10, .button);
    const descendant_id = try putNode(gpa, &state, 11, .paragraph);
    const focused_entry = state.nodes.getPtr(focused_id) orelse
        return error.NodeMissingFromState;
    try schema.ids_props.setActiveDescendant(&focused_entry.data.properties, .{ .value = 11 });

    state.focus_id = focused_id;
    state.is_host_focused = true;

    const resolved = state.focus() orelse return error.NodeMissingFromState;
    try testing.expectEqual(descendant_id, resolved.id());

    // An `active_descendant` naming a node the state does not hold is not a
    // failure upstream, because `.and_then` turns it into the focused node.
    const dangling_id = try putNode(gpa, &state, 12, .button);
    // That `put` grew `nodes`, so `focused_entry` above no longer points into
    // it. The module doc states this borrow ends at a growth, and this line is
    // the state after the growth rather than a stale pointer.
    const grown_entry = state.nodes.getPtr(focused_id) orelse
        return error.NodeMissingFromState;
    try schema.ids_props.setActiveDescendant(&grown_entry.data.properties, .{ .value = 999 });
    state.focus_id = dangling_id;
    const fallback = state.focus() orelse return error.NodeMissingFromState;
    try testing.expectEqual(dangling_id, fallback.id());
}

test "activeDialog returns the dialog above the focus" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const head = try chain(gpa, &state, 2, .dialog);
    state.focus_id = head;
    state.is_host_focused = true;

    // Two steps is `treeWalkStepBound(2)`, so this is the positive half of the
    // bound: the walk ends on a dialog and never reaches the tag.
    const dialog = try state.activeDialog();
    try testing.expectEqual(Role.dialog, dialog.data().role);
    // The walk moved up one node, so the answer is the focus's parent and not
    // the focus. A query that returned the focus would also answer `.dialog`
    // here, which is why the id is checked.
    try testing.expectEqual(dialog.id().local.value, 1);
    try testing.expect(head.local.value == 2);
}

test "activeDialog reports NoSuchNode when no ancestor is a dialog" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const head = try chain(gpa, &state, 3, .button);
    state.focus_id = head;
    state.is_host_focused = true;

    try testing.expectError(error.NoSuchNode, state.activeDialog());
}

test "activeDialog reports TreeCycle on a parent loop one step past the bound" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    // Two nodes whose `parent_and_index` entries point at each other. The walk
    // alternates between them forever, so only the bound ends it.
    const first = try putNode(gpa, &state, 1, .group);
    const second = try putNode(gpa, &state, 2, .group);
    try setParent(&state, first, second, 0);
    try setParent(&state, second, first, 0);
    state.focus_id = first;
    state.is_host_focused = true;

    // `treeWalkStepBound(2)` and the walk takes three steps before it repeats
    // one, so this is the negative half of section 7's pair.
    try testing.expectEqual(@as(usize, 2), treeWalkStepBound(state.nodes.count()));
    try testing.expectError(error.TreeCycle, state.activeDialog());
}

test "toolkitName falls back to AccessKit only when the tree names none" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    try testing.expectEqualStrings("AccessKit", state.toolkitName());

    state.info.toolkit_name = "GTK";
    try testing.expectEqualStrings("GTK", state.toolkitName());
}

test "toolkitVersion is reported only when the toolkit name is set" {
    var state: TreeState = .{};
    defer state.deinit(testing.allocator);

    // Upstream filters the version on the name being present, so a version
    // alone is not an answer.
    state.info.toolkit_version = "4.14";
    try testing.expect(state.toolkitVersion() == null);

    state.info.toolkit_name = "GTK";
    try testing.expectEqualStrings("4.14", state.toolkitVersion().?);
}

test "locateNode recovers the two ids behind a node the state holds" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const index = try state.tree_index_map.getOrCreateIndex(gpa, test_subtree);
    const id = FullNodeId.init(.{ .value = 31 }, index);
    try state.nodes.put(gpa, id, .{
        .parent_and_index = null,
        .data = Node.init(gpa, .group),
    });

    const located = state.locateNode(id) orelse return error.NodeMissingFromState;
    try testing.expect(located.local_id.eql(.{ .value = 31 }));
    try testing.expect(located.tree_id.eql(test_subtree));

    // A node the state does not hold has no tree id to report.
    const absent = FullNodeId.init(.{ .value = 32 }, index);
    try testing.expect(state.locateNode(absent) == null);
}

test "InternalChanges releases its three sets and nothing else" {
    const gpa = testing.allocator;
    var changes: InternalChanges = .{};
    try changes.added_node_ids.put(gpa, FullNodeId.init(.{ .value = 1 }, .init(0)), {});
    try changes.updated_node_ids.put(gpa, FullNodeId.init(.{ .value = 2 }, .init(0)), {});
    try changes.removed_node_ids.put(gpa, FullNodeId.init(.{ .value = 3 }, .init(0)), {});

    changes.deinit(gpa);
    // The testing allocator's leak check is live for the rest of this test, so
    // a set `deinit` skipped would be reported when the test returns.
}

test "one state and its deep copy are each released once and a byte copy is no owner" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    try populatedState(gpa, &state);

    // A byte copy shares the storage, so it is a handle rather than a second
    // owner and must not be deinitialised separately. Releasing only `state`
    // below is then correct, and the leak check proves it.
    const alias = state;
    try testing.expect(
        alias.nodes.values()[0].data.properties.items.items.ptr ==
            state.nodes.values()[0].data.properties.items.items.ptr,
    );

    // A deep copy is a second owner, so both are released and the leak check
    // still passes: each buffer is freed once.
    var copy: TreeState = .{};
    defer copy.deinit(gpa);
    try copy.cloneInto(gpa, &state);
    try testing.expectEqual(state.nodes.count(), copy.nodes.count());
    try testing.expectEqual(state.subtrees.count(), copy.subtrees.count());
    try testing.expectEqual(state.graft_parents.count(), copy.graft_parents.count());
    try testing.expectEqual(state.tree_index_map.next, copy.tree_index_map.next);
    try testing.expect(
        copy.nodes.values()[0].data.properties.items.items.ptr !=
            state.nodes.values()[0].data.properties.items.items.ptr,
    );

    // The two states are independent, so a write to the copy leaves the source
    // alone and no buffer is shared between them.
    const copy_entry = copy.nodes.getPtr(copy.root_id) orelse
        return error.NodeMissingFromState;
    try schema.strings.setLabel(&copy_entry.data.properties, "copy label");
    try testing.expectEqualStrings(
        "copy label",
        schema.strings.label(&copy_entry.data.properties).?,
    );
    const source_node = state.nodes.get(state.root_id) orelse
        return error.NodeMissingFromState;
    try testing.expectEqualStrings(
        "root label",
        schema.strings.label(&source_node.data.properties).?,
    );

    state.deinit(gpa);
}

test "cloneInto leaves the destination untouched when an allocation fails" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    try populatedState(gpa, &state);
    defer state.deinit(gpa);

    // `cloneInto` of `populatedState` allocates once for the node map, twice
    // for the labelled node and once for each of the other two, once for the
    // subtree map, once for the graft map and once per index map: eleven in
    // all. The sweep runs past that so the last indices are the ones where the
    // copy succeeds, which is the only way to reach the tail of the function.
    const allocation_bound: usize = 16;
    var fail_index: usize = 0;
    while (fail_index <= allocation_bound) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = fail_index });
        var destination: TreeState = .{};
        defer destination.deinit(gpa);
        const kept = try putNode(gpa, &destination, 500, .button);

        const outcome = destination.cloneInto(failing.allocator(), &state);
        if (outcome) |_| {
            try testing.expectEqual(state.nodes.count(), destination.nodes.count());
            continue;
        } else |failure| {
            try testing.expectEqual(error.OutOfMemory, failure);
            // The whole of `docs/33` section 5's "what survives" note: the
            // destination kept its own buffers, so the retry the doc comment
            // promises is real rather than a claim.
            try testing.expectEqual(@as(usize, 1), destination.nodes.count());
            try testing.expect(destination.nodes.contains(kept));
        }
    }

    // A copy through the real allocator, so the success path is covered
    // outside the sweep as well.
    var destination: TreeState = .{};
    defer destination.deinit(gpa);
    try destination.cloneInto(gpa, &state);
    try testing.expectEqual(state.nodes.count(), destination.nodes.count());
}

test "a query result a caller holds reads a later write to the same property" {
    const gpa = testing.allocator;
    var state: TreeState = .{};
    defer state.deinit(gpa);

    const id = try putNode(gpa, &state, 42, .button);
    const owner = state.nodes.getPtr(id) orelse return error.NodeMissingFromState;
    try schema.strings.setLabel(&owner.data.properties, "Save");

    const held = state.nodeById(id) orelse return error.NodeMissingFromState;
    try testing.expectEqualStrings("Save", schema.strings.label(&held.data().properties).?);

    // The same property, written again through the owner while the query result
    // is still held. A `NodeRef` that copied its node would still answer
    // "Save"; a borrow answers "Save now".
    try schema.strings.setLabel(&owner.data.properties, "Save the document");

    // The borrow is stated on the query, so the caller reads through it after
    // the write rather than caching the slice it got earlier.
    try testing.expectEqualStrings(
        "Save the document",
        schema.strings.label(&held.data().properties).?,
    );
    try testing.expectEqualStrings(
        "Save the document",
        schema.strings.label(&owner.data.properties).?,
    );
}
