//! The tree an application reads: two states, the commit that folds the working
//! state into the committed one, and the handler that hears about the commit.
//!
//! **Upstream.** `accesskit_consumer/src/tree.rs:578-711`:
//!
//! - `ChangeHandler` at `:578-583`, the four calls.
//! - `Tree` at `:585-589`, the two states.
//! - `Tree::new` at `:592`, `update_and_process_changes` at `:620`,
//!   `update_host_focus_state_and_process_changes` at `:630`,
//!   `process_changes` at `:640`, and `state` at `:708`.
//!
//! ## What this module owns
//!
//! `Tree` and `TreeChangeHandler` are declared here and nowhere else. This is
//! one of the two files in the layer that may carry methods on a struct body,
//! because Zig declares a method inside the body it belongs to. Every other
//! operation on a `Tree` is a free function whose first parameter is the tree.
//!
//! This module does not apply an update. `applyUpdateBorrowed` in `tree_apply.zig` owns
//! that algorithm and it needs the state `Tree` owns, so the two cannot be one
//! file. It performs no I/O, reads no clock and holds no global state, so no
//! function here takes `io: std.Io` and nothing here names `zio`.
//!
//! ## This file orchestrates: it calls the passes, and it calls the validators
//! last
//!
//! One update runs in this order, and every step is one module's function:
//!
//! 1. `applyUpdateBorrowed` in `tree_apply.zig` and the removal and graft passes in
//!    `tree_grafts.zig` write the working state.
//! 2. `validateWorkingState` below recomputes the effective focus and then
//!    validates, because a validator called before the last mutation proves
//!    nothing.
//! 3. `processChanges` prepares all fallible work, reports the changes, then commits.
//!
//! The two call sites of step 2 live here rather than in `tree_apply.zig` or
//! `tree_grafts.zig`. `docs/33` section 3 forbids `tree_grafts.zig` from
//! importing `tree_validate.zig`, and `tree_state.zig` sits below
//! `tree_validate.zig` so it may not import it back either. This file is the
//! top of the tree layer, and an orchestrator that calls the thing that
//! validates it is the ordinary shape.
//!
//! ## Decision 1: the store is owned here and nowhere else
//!
//! `Tree` holds the allocator it was built with, `TreeState` passes it down,
//! and every `Properties` inside a node stores that same allocator. The
//! allocator travels three levels, from this struct down to a node's property
//! store, and it must be the same one at each: a `Tree` that grew a node's
//! buffer with one allocator and released it through `Properties` with another
//! is a mismatched free. `Tree` is the only value in the layer that stores an
//! allocator for a tree, which is why every release below reads `self.gpa`
//! instead of taking `gpa` as a parameter.
//!
//! ## Decision 2: `deinit` runs once, and the value says so afterwards
//!
//! `Tree` owns both states. It has no copy operation, because two owners of one
//! set of nodes release it twice, and a copy made by assignment is exactly
//! that. `deinit` releases both states and then resets `self` to its empty
//! form, so a second `deinit` releases nothing rather than freeing twice, and
//! a read of any field of a released `Tree` returns the empty value rather
//! than an address that no longer holds one.
//!
//! The reset does not rescue a `NodeRef` taken before the teardown. A `NodeRef`
//! holds two pointers into the released maps, and a reset cannot reach them.
//! Its `FullNodeId` is two scalars and stays valid; the pointers do not, so a
//! stale `NodeRef` must not be read again, and a caller that needs an id across
//! a teardown copies it out first.
//!
//! ## Decision 3: the change handler is a callback, so four obligations apply
//!
//! What it receives, how long each argument stays valid, which thread it runs
//! on and whether the callee may reenter are all stated on
//! `TreeChangeHandler`, together with what a `null` slot does instead. All
//! update entry points below run every slot before the commit, which is what
//! makes the lifetime sentence true.
//!
//! ## Recorded deviations from `docs/33`, each with its reason
//!
//! 1. **`processChanges` returns `UpdateError!void` where upstream writes
//!    `void`.** Preparation checks each callback and commit lookup and copies
//!    the changed node payloads before publication. A missing node returns
//!    `error.NodeMissingFromState`. An allocation failure returns
//!    `error.OutOfMemory`. Neither rejection changes the committed state or
//!    calls the handler. Emission and commit cannot return an error.
//! 2. **`UpdateError` and `QueryError` are re-exported, not declared.** Section
//!    5 heads its block `// src/consumer/tree.zig`, but `tree_state.zig` returns
//!    both and declares both, and `tree_state.zig` deviation 4 records why the
//!    low layer owns them. This file names each one and declares neither, so
//!    there is one declaration per set.
//! 3. **`gpa` is a field where upstream has no allocator at all.** Upstream
//!    takes the allocator from a thread-local inside `HashMap`, so `Tree::new`
//!    reads no allocator parameter. Rule B4 forbids the thread-local, and
//!    section 4 lists `Tree` as a type that holds one, because a handler reaches
//!    `updateAndProcessChanges` through a fixed vtable signature and the
//!    allocator has to travel inside the handle.
//! 4. **The caller releases `changes`, not `processChanges`.** Upstream moves
//!    `changes` into `process_changes` and drops it in the callee's body. A
//!    callee-side release plus the caller-side `defer` this module needs for the
//!    path where `applyUpdateBorrowed` fails would release the same three sets
//!    twice. One owner, on every path, is the caller.
//! 5. **`TreeInfo` is compared by bytes.** Upstream compares the two values
//!    with `PartialEq` at `tree.rs:693`, which compares `Option<String>` by
//!    content. `std.meta.eql` compares a slice by address and length, so two
//!    independent borrows of equal bytes would compare as different and the
//!    comparison is written out here instead.
//! 6. **`#[derive(Debug)]` at `tree.rs:585` is deleted.** It exists for a Rust
//!    caller that prints a `Tree` in a panic message. Nothing in the port
//!    formats a `Tree`, and no `format` method reaches this layer, so the derive
//!    would have no call site.
//! 7. **Owned and borrowed update entry points share one implementation.**
//!    `init` and `updateAndProcessChanges` release their input exactly once.
//!    `initBorrowed` and `updateBorrowedAndProcessChanges` leave the input
//!    nodes and array with their caller. Both paths copy directly into the
//!    working state, without a temporary full input clone. Toolkit strings
//!    retain the existing `TreeInfo` borrow contract.
//! 8. **Commit preparation replaces fallible work after callbacks.**
//!    Prepared rows own payload copies only for additions or changed data.
//!    Parent-only rewrites keep their committed payload buffers.
//!    A registry copy holds only shallow entries and is needed only for growth.
//!    Equal metadata mappings keep their original backing arrays and order.
//!    Changed mappings are copied privately and transferred after callbacks.
//!
//! ## Atomic rejection and retry
//!
//! A rejected update can leave the working state partly written. The dirty flag
//! makes the next update or host-focus operation restore it from the committed
//! state first. Failed recovery leaves the flag set and publishes nothing.
//! Successful sparse updates do not copy the whole tree for recovery.

const std = @import("std");

const schema = @import("../schema/root.zig");
const node_id = @import("node_id.zig");
const tree_apply = @import("tree_apply.zig");
const tree_index = @import("tree_index.zig");
const tree_state = @import("tree_state.zig");
const tree_validate = @import("tree_validate.zig");

const Node = schema.Node;
const NodeId = schema.NodeId;
const TreeInfo = schema.TreeInfo;
const TreeUpdate = schema.TreeUpdate;
const tree_id_root = schema.tree_id_root;
const FullNodeId = tree_index.FullNodeId;
const NodeRef = node_id.NodeRef;
const InternalChanges = tree_state.InternalChanges;
const NodeState = tree_state.NodeState;
const TreeState = tree_state.TreeState;

const Allocator = std.mem.Allocator;

const testing = std.testing;

/// A parent-only rewrite retains the existing committed payload.
const PreparedNode = struct {
    parent_and_index: ?tree_index.ParentAndIndex,
    /// Null retains an existing committed payload whose data compares equal.
    data: ?Node,
};

/// Private owners needed to make publication infallible.
const PreparedCommit = struct {
    changed_nodes: std.array_hash_map.Auto(FullNodeId, PreparedNode) = .empty,
    // This optional registry owns its arrays, but borrows every node payload.
    registry: ?tree_state.NodeMap = null,
    subtrees: ?tree_state.TreeIdMap = null,
    graft_parents: ?tree_state.TreeIdNodeMap = null,
    tree_index_map: ?tree_index.TreeIndexMap = null,

    fn deinit(self: *PreparedCommit, gpa: Allocator) void {
        for (self.changed_nodes.values()) |*node_state| {
            if (node_state.data) |*data| data.deinit();
        }
        self.changed_nodes.deinit(gpa);
        if (self.registry) |*registry| registry.deinit(gpa);
        if (self.subtrees) |*subtrees| subtrees.deinit(gpa);
        if (self.graft_parents) |*graft_parents| graft_parents.deinit(gpa);
        if (self.tree_index_map) |*index_map| index_map.deinit(gpa);
        // Every owned payload and map has been released or transferred.
        self.* = undefined;
    }
};

/// Failures of owned and borrowed tree construction and update calls, host-focus
/// updates, and commit preparation. Declared in `tree_state.zig` and re-exported
/// here because `Tree` is the first module an application calls.
/// Update rejection preserves the committed tree and emits no callbacks.
pub const UpdateError = tree_state.UpdateError;

/// Failures of the walks that read a tree. Declared in `tree_state.zig` and
/// re-exported here for the same reason. `Tree` returns it from nothing today,
/// and a caller that catches `QueryError` needs the one declaration.
pub const QueryError = tree_state.QueryError;

/// Receives what one update changed, through four optional slots.
///
/// **The four obligations**, one clause each, and they hold for every slot:
///
/// - **What it receives.** The caller's own `ptr`, passed back unchanged, and
///   the `NodeRef`s named in the slot's own signature. Nothing else crosses the
///   boundary, so no other thread observes the call.
/// - **How long each argument stays valid.** Only until the slot returns. Every
///   `NodeRef` points into `Tree.next_state` or `Tree.state`, and
///   `processChanges` commits after the last slot returns. Commit can move
///   committed entries and release their old payloads. A callee that needs
///   node data afterwards copies it before the slot returns.
/// - **Which thread it runs on.** The thread that called an update method,
///   inside that call and before it returns. This layer starts no thread and
///   holds no lock.
/// - **Whether the callee may reenter.** It may read the same `Tree` through
///   `stateOf` and through the queries, and it sees the committed state as it
///   stood before this update, because the commit runs after the slots. It must
///   not call `updateAndProcessChanges`, `updateBorrowedAndProcessChanges`,
///   `updateHostFocusStateAndProcessChanges` or `deinit` from inside a slot,
///   because each of those moves or releases what the arguments point at.
///
/// **A `null` slot skips the call and nothing else.** The update commits
/// exactly as it would with every slot filled, so silence is the default and a
/// caller that fills no slot gets a tree and no notifications. There is no
/// diagnostic for a `null` slot, because a caller that wants a notification
/// asks for one and a caller that does not is not misbehaving.
pub const TreeChangeHandler = struct {
    /// The callee's own context, handed to every slot unchanged. This module
    /// never reads it, and the four slots do not own it, so the caller keeps it
    /// alive for the whole call and past it as long as a slot stored it.
    ptr: *anyopaque,

    /// One node the update added, read from the state that is about to be
    /// committed. `null` skips the call.
    node_added: ?*const fn (ptr: *anyopaque, node: NodeRef) void = null,

    /// One node the update rewrote, as the node the committed state holds and
    /// as the node the working state holds. `null` skips the call.
    node_updated: ?*const fn (ptr: *anyopaque, old: NodeRef, new: NodeRef) void = null,

    /// The focus moved. `null` on the `old` side means the focus was gained and
    /// `null` on the `new` side means it was lost, which is the shape upstream
    /// passes at `tree.rs:672`. `null` as the slot skips the call.
    focus_moved: ?*const fn (ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void = null,

    /// One node the update removed, read from the committed state before the
    /// commit takes it out. `null` skips the call.
    node_removed: ?*const fn (ptr: *anyopaque, node: NodeRef) void = null,
};

/// The tree an application reads: two states and the update calls that write
/// the working one.
///
/// `Tree` owns both states and the allocator that grew them. `Tree` has no copy
/// operation, because two owners of one set of nodes release it twice, so the
/// only way to hand a tree to a callee is a pointer.
///
/// The two states hold separate copies of every node, so `state` and
/// `next_state` share no property buffer and releasing one releases only its
/// own. Every buffer under both states was allocated with `gpa` and is released
/// with `gpa`.
///
/// A `Tree` is not shared across threads without the caller's own
/// synchronisation. It holds no lock of its own, so a second thread calling
/// into it while the first is inside an update is a data race the caller has to
/// prevent.
pub const Tree = struct {
    /// The allocator that grew every buffer under both states and that releases
    /// them. It must stay valid for the life of the tree, and it must be the
    /// allocator `init` was given, because every node's `Properties` stores it
    /// and releases through it.
    gpa: Allocator,

    /// The committed tree, which `stateOf` hands out. Only `processChanges`
    /// writes it, and only after every slot has run.
    state: TreeState,

    /// The working tree that `applyUpdateBorrowed` writes. It owns separate copies of
    /// every node, so growing or freeing it never touches the buffers `state`
    /// reads.
    next_state: TreeState,

    /// A rejected update needs recovery from `state` before the next mutation.
    /// Only a successful publication clears this flag.
    working_state_dirty: bool = false,

    /// Builds the tree from an owned first update. Upstream `tree.rs:592-618`.
    ///
    /// The input must describe the whole root tree. Missing tree data returns
    /// `error.NoRootTree`. A non-root tree id returns `error.NotTheRootTree`.
    /// This call releases the input nodes and array exactly once on every path.
    /// The caller must not release or reuse the transferred update afterwards.
    /// On error, this call also releases every state allocation it built.
    /// Toolkit strings keep the borrowed lifetime required by `TreeInfo`.
    pub fn init(
        gpa: Allocator,
        initial_update: TreeUpdate,
        is_host_focused: bool,
    ) UpdateError!Tree {
        var owned_update = initial_update;
        defer owned_update.deinit(gpa);
        return initImpl(gpa, &owned_update, is_host_focused);
    }

    /// Builds the tree without taking ownership of the first update.
    ///
    /// The source nodes and array must stay live and unchanged until this call
    /// returns. The caller retains them on success and on error. The tree owns
    /// independent node copies, with no intermediate full input clone.
    /// Toolkit byte slices must outlive every state that still borrows them,
    /// as required by `TreeInfo`. Errors match `init`.
    pub fn initBorrowed(
        gpa: Allocator,
        initial_update: *const TreeUpdate,
        is_host_focused: bool,
    ) UpdateError!Tree {
        return initImpl(gpa, initial_update, is_host_focused);
    }

    fn initImpl(
        gpa: Allocator,
        initial_update: *const TreeUpdate,
        is_host_focused: bool,
    ) UpdateError!Tree {
        const info = initial_update.tree orelse return error.NoRootTree;
        if (!initial_update.tree_id.eql(tree_id_root)) return error.NotTheRootTree;

        var state: TreeState = .{};
        errdefer state.deinit(gpa);
        const assigned_index = try state.tree_index_map.getOrCreateIndex(
            gpa,
            initial_update.tree_id,
        );
        state.root_id = .{ .local = info.root, .tree_index = assigned_index };
        state.info = info;
        state.focus_id = .{ .local = initial_update.focus, .tree_index = assigned_index };
        state.is_host_focused = is_host_focused;

        try tree_apply.applyUpdateBorrowed(gpa, &state, initial_update, null);
        try validateWorkingState(&state);

        // The working state owns separate payloads, as at `tree.rs:613`.
        var next_state: TreeState = .{};
        errdefer next_state.deinit(gpa);
        try next_state.cloneInto(gpa, &state);
        return .{ .gpa = gpa, .state = state, .next_state = next_state };
    }

    /// Releases both states and every buffer under them. Upstream has no
    /// counterpart, because `HashMap` in Rust drops itself and the port has to
    /// say when.
    ///
    /// The allocator is not released: `gpa` owns no memory, so the reset value
    /// keeps it and holding it again is not a second owner. The value is left in
    /// its empty form, so a second call releases nothing rather than freeing
    /// twice, and a read of any field afterwards answers the empty tree instead
    /// of an address that no longer holds one.
    ///
    /// A `NodeRef` taken before this call still points into the released maps
    /// and must not be read again. Its `FullNodeId` is two scalars and stays
    /// valid, so a caller that needs an id across the teardown copies it out
    /// first.
    pub fn deinit(self: *Tree) void {
        const gpa = self.gpa;
        self.state.deinit(gpa);
        self.next_state.deinit(gpa);
        // SAFETY: the two lines above released every buffer and every map this
        // value owned, which is the whole teardown, and no statement after them
        // reads a released field. The reset is what a stale read sees: an empty
        // tree whose maps own nothing, so the read answers the empty value and
        // a second `deinit` releases nothing. `gpa` is copied out first because
        // an allocator handle owns no memory and so has nothing to invalidate.
        //
        // The whole-receiver struct literal is deliberate, and ziglint rule Z030
        // reports it at this line. The rule accepts three terminal spellings,
        // read from `tools/ziglint/src/Linter.zig`: `self.* = undefined` at
        // `isSelfUndefinedAssign:2327`, `self.destroy(self)` at
        // `isSelfDestroyCall:2312`, and a per-field reset through
        // `isSafeSelfFieldAssign:2052`. A whole-receiver struct literal is none
        // of the three, so the matcher cannot read this reset as terminal. That
        // was settled by running the tool on this exact shape, not by reading
        // the rule.
        //
        // Both spellings that would satisfy the rule change the contract the doc
        // comment above states. `self.* = undefined` makes a second `deinit`
        // read an undefined allocator, so the double-release safety is lost, and
        // delegating to a helper that poisons `self` does the same one frame
        // down. A per-field reset does not satisfy the rule either:
        // `isSafeTerminalFieldValue:2093` takes a struct literal only for the
        // field names `active`, `closed`, `is_active`, `is_closed` and `state`,
        // and it takes the identifier `empty` rather than `.{}`. `next_state` is
        // not one of those names, and `gpa` holds an allocator rather than an
        // empty marker. Closing this finding needs a behaviour change or a
        // matcher change, and neither belongs to a lint slice.
        self.* = .{ .gpa = gpa, .state = .{}, .next_state = .{} };
    }

    /// The committed state, which is what an application reads. Upstream
    /// `tree.rs:708-710`.
    ///
    /// The borrow ends at the next successful owned, borrowed, or host-focus
    /// update, and at `deinit`. Rejection preserves this borrow, including the
    /// committed backing arrays. A `NodeRef` shares the same borrow.
    pub fn stateOf(self: *const Tree) *const TreeState {
        return &self.state;
    }

    /// Applies an owned update and publishes its changes. Upstream `tree.rs:620-628`.
    ///
    /// This call releases the input nodes and array exactly once on every path,
    /// including a failed recovery before application. The caller must not
    /// release or reuse the transferred input afterwards.
    ///
    /// Every `UpdateError` leaves the committed tree and its backing arrays
    /// unchanged and calls no handler slot. The working state can be partly
    /// written. A later call restores the accepted baseline before it applies
    /// the new update. All callbacks see the old committed state.
    pub fn updateAndProcessChanges(
        self: *Tree,
        update: TreeUpdate,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        var owned_update = update;
        defer owned_update.deinit(self.gpa);
        try self.updateImpl(&owned_update, handler);
    }

    /// Applies a borrowed update with the same atomic publication as the owned call.
    ///
    /// The source nodes and array must stay live and unchanged until this call
    /// returns. This call never releases them, including on rejection or failed
    /// recovery. The tree copies state-owned nodes directly from the source.
    /// Toolkit byte slices retain the `TreeInfo` lifetime contract while either
    /// state still borrows them. Callback borrows follow `TreeChangeHandler`.
    pub fn updateBorrowedAndProcessChanges(
        self: *Tree,
        update: *const TreeUpdate,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        try self.updateImpl(update, handler);
    }

    fn updateImpl(
        self: *Tree,
        update: *const TreeUpdate,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        if (self.working_state_dirty) {
            try self.next_state.cloneInto(self.gpa, &self.state);
        }
        self.working_state_dirty = true;
        var changes: InternalChanges = .{};
        defer changes.deinit(self.gpa);
        try tree_apply.applyUpdateBorrowed(self.gpa, &self.next_state, update, &changes);
        try validateWorkingState(&self.next_state);
        try self.processChanges(changes, handler);
        self.working_state_dirty = false;
    }

    /// Publishes the host focus flag. Upstream `tree.rs:630-638`.
    ///
    /// A dirty working state is restored first. Failed recovery leaves it dirty.
    /// Failed preparation restores the previous working host flag. Every error
    /// leaves the committed tree unchanged and calls no handler slot.
    /// A clean focus-only update needs no node or unchanged metadata copies.
    /// Focus callbacks include synthetic node updates in the upstream order.
    pub fn updateHostFocusStateAndProcessChanges(
        self: *Tree,
        is_host_focused: bool,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        if (self.working_state_dirty) {
            try self.next_state.cloneInto(self.gpa, &self.state);
        }
        const previous_host_flag = self.next_state.is_host_focused;
        self.next_state.is_host_focused = is_host_focused;
        errdefer self.next_state.is_host_focused = previous_host_flag;
        var changes: InternalChanges = .{};
        defer changes.deinit(self.gpa);
        try self.processChanges(changes, handler);
        self.working_state_dirty = false;
    }

    /// Checks and allocates before callbacks, then publishes without failure.
    /// `changes` remains caller-owned. All loops use immutable container counts.
    fn processChanges(
        self: *Tree,
        changes: InternalChanges,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        var prepared = try self.prepareCommit(changes);
        defer prepared.deinit(self.gpa);
        self.emitChanges(changes, handler);
        self.commitPrepared(changes, &prepared);
    }

    fn prepareCommit(self: *const Tree, changes: InternalChanges) UpdateError!PreparedCommit {
        var missing_added_count: usize = 0;
        for (changes.added_node_ids.keys()) |id| {
            if (self.next_state.nodeById(id) == null) return error.NodeMissingFromState;
            if (!self.state.nodes.contains(id)) missing_added_count += 1;
        }
        for (changes.updated_node_ids.keys()) |id| {
            if (self.state.nodeById(id) == null) return error.NodeMissingFromState;
            if (self.next_state.nodeById(id) == null) return error.NodeMissingFromState;
        }
        for (changes.removed_node_ids.keys()) |id| {
            if (self.state.nodeById(id) == null) return error.NodeMissingFromState;
        }
        // Validate focus lookups before the query's invariant assertions.
        if (self.state.focusId()) |id| {
            if (self.state.nodeById(id) == null) return error.NodeMissingFromState;
        }
        if (self.next_state.focusId()) |id| {
            if (self.next_state.nodeById(id) == null) return error.NodeMissingFromState;
        }
        const old_focus = self.state.focus();
        const new_focus = self.next_state.focus();
        const focus_changed = !std.meta.eql(
            if (old_focus) |node| node.id() else null,
            if (new_focus) |node| node.id() else null,
        );
        if (focus_changed) {
            if (old_focus) |node| {
                const id = node.id();
                if (!changes.updated_node_ids.contains(id) and
                    !changes.removed_node_ids.contains(id))
                {
                    if (self.next_state.nodeById(id) == null) return error.NodeMissingFromState;
                }
            }
            if (new_focus) |node| {
                const id = node.id();
                if (!changes.added_node_ids.contains(id) and
                    !changes.updated_node_ids.contains(id))
                {
                    if (self.state.nodeById(id) == null) return error.NodeMissingFromState;
                }
            }
        }

        var prepared: PreparedCommit = .{};
        errdefer prepared.deinit(self.gpa);
        try prepared.changed_nodes.ensureTotalCapacity(
            self.gpa,
            changes.added_node_ids.count() + changes.updated_node_ids.count(),
        );
        for (changes.added_node_ids.keys()) |id| {
            const source = self.next_state.nodes.getPtr(id).?;
            const unchanged = if (self.state.nodes.getPtr(id)) |committed|
                committed.data.eql(&source.data)
            else
                false;
            const copy: PreparedNode = .{
                .parent_and_index = source.parent_and_index,
                .data = if (unchanged) null else try Node.clone(self.gpa, &source.data),
            };
            prepared.changed_nodes.putAssumeCapacity(id, copy);
        }
        for (changes.updated_node_ids.keys()) |id| {
            if (prepared.changed_nodes.contains(id)) continue;
            const source = self.next_state.nodes.getPtr(id).?;
            const committed = self.state.nodes.getPtr(id).?;
            const copy: PreparedNode = .{
                .parent_and_index = source.parent_and_index,
                .data = if (committed.data.eql(&source.data))
                    null
                else
                    try Node.clone(self.gpa, &source.data),
            };
            prepared.changed_nodes.putAssumeCapacity(id, copy);
        }

        const required_registry_capacity = self.state.nodes.count() + missing_added_count;
        if (self.state.nodes.capacity() < required_registry_capacity) {
            // The private registry borrows node payloads. Only its header owns memory.
            prepared.registry = try self.state.nodes.clone(self.gpa);
            try prepared.registry.?.ensureTotalCapacity(self.gpa, required_registry_capacity);
        }
        if (!mapMappingsEql(tree_state.TreeIdMap, .{
            .committed = &self.state.subtrees,
            .working = &self.next_state.subtrees,
        })) {
            prepared.subtrees = try self.next_state.subtrees.clone(self.gpa);
        }
        if (!mapMappingsEql(tree_state.TreeIdNodeMap, .{
            .committed = &self.state.graft_parents,
            .working = &self.next_state.graft_parents,
        })) {
            prepared.graft_parents = try self.next_state.graft_parents.clone(self.gpa);
        }
        const old_index = &self.state.tree_index_map;
        const new_index = &self.next_state.tree_index_map;
        const index_changed = old_index.next != new_index.next or
            !mapMappingsEql(tree_index.TreeIdIndexMap, .{
                .committed = &old_index.id_to_index,
                .working = &new_index.id_to_index,
            }) or !mapMappingsEql(tree_index.TreeIdByIndexMap, .{
                .committed = &old_index.index_to_id,
                .working = &new_index.index_to_id,
            });
        if (index_changed) {
            prepared.tree_index_map = .empty;
            try prepared.tree_index_map.?.cloneInto(self.gpa, new_index);
        }
        return prepared;
    }

    /// Emits upstream `tree.rs:641-677` order while the committed state stays old.
    /// Every forced lookup was checked by `prepareCommit` before any slot ran.
    fn emitChanges(
        self: *const Tree,
        changes: InternalChanges,
        handler: *const TreeChangeHandler,
    ) void {
        for (changes.added_node_ids.keys()) |id| {
            const node = self.next_state.nodeById(id).?;
            if (handler.node_added) |slot| slot(handler.ptr, node);
        }
        for (changes.updated_node_ids.keys()) |id| {
            const old_node = self.state.nodeById(id).?;
            const new_node = self.next_state.nodeById(id).?;
            if (handler.node_updated) |slot| slot(handler.ptr, old_node, new_node);
        }
        const old_focus = self.state.focus();
        const new_focus = self.next_state.focus();
        const focus_changed = !std.meta.eql(
            if (old_focus) |node| node.id() else null,
            if (new_focus) |node| node.id() else null,
        );
        if (focus_changed) {
            if (old_focus) |old_node| {
                const id = old_node.id();
                if (!changes.updated_node_ids.contains(id) and
                    !changes.removed_node_ids.contains(id))
                {
                    const old_node_new_version = self.next_state.nodeById(id).?;
                    if (handler.node_updated) |slot| {
                        slot(handler.ptr, old_node, old_node_new_version);
                    }
                }
            }
            if (new_focus) |new_node| {
                const id = new_node.id();
                if (!changes.added_node_ids.contains(id) and
                    !changes.updated_node_ids.contains(id))
                {
                    const new_node_old_version = self.state.nodeById(id).?;
                    if (handler.node_updated) |slot| {
                        slot(handler.ptr, new_node_old_version, new_node);
                    }
                }
            }
            if (handler.focus_moved) |slot| slot(handler.ptr, old_focus, new_focus);
        }
        for (changes.removed_node_ids.keys()) |id| {
            const node = self.state.nodeById(id).?;
            if (handler.node_removed) |slot| slot(handler.ptr, node);
        }
    }

    /// Transfers prepared owners after callbacks. No allocation or error can follow.
    fn commitPrepared(self: *Tree, changes: InternalChanges, prepared: *PreparedCommit) void {
        if (prepared.registry) |registry| {
            // The old registry and its copy refer to the same live payloads.
            self.state.nodes.deinit(self.gpa);
            self.state.nodes = registry;
            prepared.registry = null;
        }
        for (prepared.changed_nodes.keys(), prepared.changed_nodes.values()) |id, *node_state| {
            if (node_state.data) |data| {
                const replacement: NodeState = .{
                    .parent_and_index = node_state.parent_and_index,
                    .data = data,
                };
                if (self.state.nodes.fetchPutAssumeCapacity(id, replacement)) |previous| {
                    var previous_node_state = previous.value;
                    previous_node_state.data.deinit();
                }
                node_state.data = null;
            } else {
                // A null payload requires the existing node validated during preparation.
                const committed = self.state.nodes.getPtr(id).?;
                committed.parent_and_index = node_state.parent_and_index;
            }
        }
        // The committed registry now owns these payloads, not the staging map.
        prepared.changed_nodes.clearRetainingCapacity();
        for (changes.removed_node_ids.keys()) |id| {
            const removed = self.state.nodes.fetchOrderedRemove(id).?;
            var removed_node_state = removed.value;
            removed_node_state.data.deinit();
        }

        if (self.treeInfoChanged()) self.state.info = self.next_state.info;
        self.state.root_id = self.next_state.root_id;
        self.state.focus_id = self.next_state.focus_id;
        self.state.is_host_focused = self.next_state.is_host_focused;
        if (prepared.subtrees) |subtrees| {
            self.state.subtrees.deinit(self.gpa);
            self.state.subtrees = subtrees;
            prepared.subtrees = null;
        }
        if (prepared.graft_parents) |graft_parents| {
            self.state.graft_parents.deinit(self.gpa);
            self.state.graft_parents = graft_parents;
            prepared.graft_parents = null;
        }
        if (prepared.tree_index_map) |index_map| {
            self.state.tree_index_map.deinit(self.gpa);
            self.state.tree_index_map = index_map;
            prepared.tree_index_map = null;
        }
    }

    /// Whether the committed `info` and the working `info` differ in content.
    /// Upstream's `!=` at `tree.rs:693`.
    ///
    /// The three fields are compared, so the answer is complete. The two toolkit
    /// fields are compared as bytes because `std.meta.eql` compares a slice by
    /// address and length, and two updates can carry equal text from two
    /// different buffers.
    fn treeInfoChanged(self: *const Tree) bool {
        if (!self.state.info.root.eql(self.next_state.info.root)) return true;
        if (!borrowedTextEql(self.state.info.toolkit_name, self.next_state.info.toolkit_name)) {
            return true;
        }
        return !borrowedTextEql(
            self.state.info.toolkit_version,
            self.next_state.info.toolkit_version,
        );
    }
};

/// Equal mappings need no copies, even when their insertion orders differ.
fn mapMappingsEql(comptime Map: type, options: struct {
    committed: *const Map,
    working: *const Map,
}) bool {
    if (options.committed.count() != options.working.count()) return false;
    for (options.working.keys(), options.working.values()) |key, value| {
        const previous = options.committed.get(key) orelse return false;
        if (!std.meta.eql(previous, value)) return false;
    }
    return true;
}

/// Content equality of two borrowed optional byte strings, which is what
/// upstream's `PartialEq` on `Option<String>` means at `tree.rs:693`.
fn borrowedTextEql(a: ?[]const u8, b: ?[]const u8) bool {
    const a_bytes = a orelse return b == null;
    const b_bytes = b orelse return false;
    return std.mem.eql(u8, a_bytes, b_bytes);
}

/// Recomputes the effective focus and then validates the working state.
/// Upstream `tree.rs:483-485`, the tail of `TreeState::update`.
///
/// **The order is the contract.** The validation runs after every mutation the
/// update made, and the focus is recomputed before it, because `validateGlobal`
/// checks that the focus is a key of `nodes` and the recomputed focus is what it
/// must check. A validator called before the last mutation proves nothing, so a
/// future edit that hoists either call earlier for tidiness weakens the
/// guarantee silently.
///
/// These two call sites live here and not in `tree_apply.zig` or
/// `tree_grafts.zig`: `docs/33` section 3 forbids `tree_grafts.zig` from
/// importing `tree_validate.zig`, and `tree_state.zig` sits below
/// `tree_validate.zig` and may not import it back. This file is the top of the
/// tree layer, so it calls the passes and then the validators.
fn validateWorkingState(state: *TreeState) UpdateError!void {
    state.focus_id = try tree_validate.computeEffectiveFocus(state);
    try tree_validate.validateGlobal(state);
}

// --- The tests ----------------------------------------------------------------

/// What one test's handler recorded. The four slots are plain function
/// pointers, so the state they share travels in `ptr` and nothing is captured.
const Recorder = struct {
    /// The tree the slots read through, for the reentrancy case.
    tree: *const Tree,
    added: usize = 0,
    updated: usize = 0,
    moved: usize = 0,
    removed: usize = 0,
    /// Whether the committed state already held the node that `node_added` was
    /// given. The commit runs after the slots, so the answer must be false, and
    /// an implementation that committed first would answer true.
    added_in_committed_state: bool = false,
    old_focus: ?FullNodeId = null,
    new_focus: ?FullNodeId = null,

    fn slots(self: *Recorder) TreeChangeHandler {
        return .{
            .ptr = self,
            .node_added = onNodeAdded,
            .node_updated = onNodeUpdated,
            .focus_moved = onFocusMoved,
            .node_removed = onNodeRemoved,
        };
    }
};

fn onNodeAdded(ptr: *anyopaque, node: NodeRef) void {
    const self: *Recorder = @ptrCast(@alignCast(ptr));
    self.added += 1;
    self.added_in_committed_state = self.tree.stateOf().hasNode(node.id());
}

fn onNodeUpdated(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
    _ = old;
    _ = new;
    const self: *Recorder = @ptrCast(@alignCast(ptr));
    self.updated += 1;
}

fn onFocusMoved(ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
    const self: *Recorder = @ptrCast(@alignCast(ptr));
    self.moved += 1;
    self.old_focus = if (old) |node| node.id() else null;
    self.new_focus = if (new) |node| node.id() else null;
}

fn onNodeRemoved(ptr: *anyopaque, node: NodeRef) void {
    _ = node;
    const self: *Recorder = @ptrCast(@alignCast(ptr));
    self.removed += 1;
}

/// A handler with every slot null. The context is never read, so a caller hands
/// in a real address rather than an `undefined` one.
fn silentSlots(context: *anyopaque) TreeChangeHandler {
    return .{ .ptr = context };
}

/// The first update of a tree: the root node, with `focus` on it.
fn rootUpdate(gpa: Allocator, root: NodeId, focus: NodeId) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    // `pushNode` takes the node and releases it itself if it cannot store it, so
    // there is no `errdefer` on `data` here and one would be a double free.
    try update.pushNode(gpa, root, Node.init(gpa, .group));
    update.tree = TreeInfo.init(root);
    update.focus = focus;
    return update;
}

/// An update that adds `child` and makes it a child of the root.
fn addChildUpdate(gpa: Allocator, root: NodeId, child: NodeId) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    try update.pushNode(gpa, child, Node.init(gpa, .button));
    var root_data = Node.init(gpa, .group);
    errdefer root_data.deinit();
    try schema.ids_props.setChildren(&root_data.properties, &.{child});
    try update.pushNode(gpa, root, root_data);
    update.focus = root;
    return update;
}

/// An update that takes `child` back off the root's child list, which is what
/// makes the child unreachable and therefore removed. The caller must already
/// have sent `addChildUpdate` for the same root and child.
fn removeChildUpdate(gpa: Allocator, root: NodeId) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    try update.pushNode(gpa, root, Node.init(gpa, .group));
    update.focus = root;
    return update;
}

test "init commits the root node and the focus from the first update" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    const state = tree.stateOf();
    try testing.expect(state.hasNode(.{ .local = root, .tree_index = .init(0) }));
    try testing.expectEqual(root, state.rootId().local);
    try testing.expectEqual(root, state.focusIdInTree().local);
    try testing.expect(state.isHostFocused());
}


test "init reports error.NoRootTree and releases the update it rejected" {
    const gpa = testing.allocator;
    var update: TreeUpdate = .{};
    try update.pushNode(gpa, .{ .value = 1 }, Node.init(gpa, .group));

    // The update holds one node and the leak check is live, so a rejection that
    // did not release it would be a leak rather than a silent pass.
    try testing.expectError(error.NoRootTree, Tree.init(gpa, update, true));
}

test "init reports error.NotTheRootTree and releases the update it rejected" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var subtree_update = try rootUpdate(gpa, root, root);
    subtree_update.tree_id = schema.treeIdFromBytes(@splat(0x11));

    // A subtree update is the second of the two rejections upstream raises
    // before it stores anything, and it releases the update the same way.
    try testing.expectError(error.NotTheRootTree, Tree.init(gpa, subtree_update, true));
}

test "deinit twice releases nothing the second time and leaks nothing" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);

    tree.deinit();
    // The second call runs the whole body again over the reset value. Without
    // the reset it would free the two map headers a second time, and the
    // leak-detecting allocator would report the second free against an address
    // it has already seen.
    tree.deinit();
    try testing.expectEqual(@as(usize, 0), tree.stateOf().nodes.count());
}

test "a released tree answers the empty tree for every field" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    tree.state.info.toolkit_name = "before";

    tree.deinit();

    // The reset is what a stale read sees. Without it the two fields below would
    // still hold the values `deinit` wrote around, which is the use-after-free a
    // caller hits by reading a field after the teardown.
    try testing.expect(tree.state.info.toolkit_name == null);
    try testing.expectEqual(@as(usize, 0), tree.next_state.nodes.count());
    // An allocator handle owns no memory, so keeping it in the reset value is
    // not a second owner of anything.
    try testing.expect(tree.gpa.ptr == gpa.ptr);
}

test "a reference taken before the teardown names a node the released tree does not hold" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);

    const stale = NodeRef.init(tree.stateOf(), FullNodeId.init(root, .init(0)));
    try testing.expect(stale != null);
    const stale_id = stale.?.id();
    tree.deinit();

    // The reset is what makes this a definite answer rather than a read of the
    // released map: `stateOf` returns the empty state, so `hasNode` is false
    // for every id including the one the stale reference carried. Without the
    // reset it would look that id up in a map whose metadata has been freed, and
    // the answer would be whatever the allocator left in the freed bytes.
    // The stale reference itself is not read again: its two pointers name
    // storage that is gone, and only the id it carried is still valid.
    try testing.expect(!tree.stateOf().hasNode(stale_id));
    try testing.expectEqual(root, stale_id.local);
}

test "stateOf answers the committed state and the same one on every call" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();
    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &slots);

    const committed = tree.stateOf();
    // The committed state, not the working one and not a copy: it holds both
    // nodes, and two calls name one address so a caller may hold the result
    // across the queries it runs next.
    try testing.expectEqual(@as(usize, 2), committed.nodes.count());
    try testing.expect(committed == tree.stateOf());
    try testing.expect(committed.hasNode(FullNodeId.init(child, .init(0))));
}

test "updateAndProcessChanges reports the node it added and commits it" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();

    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &slots);
    // One added node and one rewritten node: the root's own entry changed,
    // because the child list is part of its data. A port that reported only the
    // addition would leave an adapter's cache of the root stale.
    try testing.expectEqual(@as(usize, 1), recorder.added);
    try testing.expectEqual(@as(usize, 1), recorder.updated);
    try testing.expect(tree.stateOf().hasNode(FullNodeId.init(child, .init(0))));
}

test "a slot sees the tree as it stood before the update, so it may reenter" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();

    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &slots);
    // The doc comment claims a slot may reenter and sees the committed state as
    // it stood before the update. The reentrant read inside `node_added`
    // recorded the opposite of a commit that ran first, and it agreed with the
    // state after the call.
    try testing.expect(!recorder.added_in_committed_state);
    try testing.expect(tree.stateOf().hasNode(FullNodeId.init(child, .init(0))));
}

test "updateAndProcessChanges reports a removed node from the committed state" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();
    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &slots);
    try testing.expectEqual(@as(usize, 1), recorder.added);

    try tree.updateAndProcessChanges(try removeChildUpdate(gpa, root), &slots);
    try testing.expectEqual(@as(usize, 1), recorder.removed);
    // The removal was reported before the commit took the node out, so the
    // reported node was still in the committed state and the commit then
    // released it. A report that came after the commit would have found nothing
    // to report, or reported a node whose buffers were already gone.
    try testing.expect(!tree.stateOf().hasNode(FullNodeId.init(child, .init(0))));
}

test "updateHostFocusStateAndProcessChanges reports the focus it lost" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();

    try tree.updateHostFocusStateAndProcessChanges(false, &slots);
    try testing.expectEqual(@as(usize, 1), recorder.moved);
    try testing.expectEqual(FullNodeId.init(root, .init(0)), recorder.old_focus);
    // The flag turned off makes the new focus null, which is how a lost focus
    // reaches the slot, and the same flag is what `focusId` reports afterwards.
    try testing.expect(recorder.new_focus == null);
    try testing.expect(!tree.stateOf().isHostFocused());
    // The node that lost the focus was neither rewritten nor removed, so the
    // synthetic rewrite at `tree.rs:653-662` is the only way the slot learns
    // that the node it used to focus has changed.
    try testing.expectEqual(@as(usize, 1), recorder.updated);
}

test "updateHostFocusStateAndProcessChanges reports nothing when the flag is unchanged" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();

    try tree.updateHostFocusStateAndProcessChanges(true, &slots);
    // Both focus ids are the same node, so the comparison at `tree.rs:652` says
    // the focus did not move and no slot runs. A port that reported a focus
    // change here would make a platform adapter redraw for nothing.
    try testing.expectEqual(@as(usize, 0), recorder.moved);
    try testing.expectEqual(@as(usize, 0), recorder.updated);
    try testing.expect(tree.stateOf().isHostFocused());
}


test "a handler with every slot null commits the update and reports nothing" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var context: usize = 0;
    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &silentSlots(&context));
    // The doc comment claims a null slot is silence and not a refusal, so the
    // update must still be in the committed state when no slot is filled. A
    // port that treated a null slot as an error would leave the tree one update
    // behind for every caller that did not want notifications.
    try testing.expect(tree.stateOf().hasNode(FullNodeId.init(child, .init(0))));
    try testing.expectEqual(@as(usize, 2), tree.stateOf().nodes.count());
}



// Every allocation rejection is observed through the same public tree and
// callbacks as a native adapter; rebuilding the input is a logical retry.
const atomic_allocation_bound: usize = 256;

fn atomicFixture(gpa: Allocator, accepted: bool, delta: bool) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    var root = Node.init(gpa, .group);
    {
        errdefer root.deinit();
        const children = if (accepted)
            [_]NodeId{ .{ .value = 2 }, .{ .value = 3 }, .{ .value = 4 } }
        else
            [_]NodeId{ .{ .value = 2 }, .{ .value = 3 }, .{ .value = 5 } };
        try schema.ids_props.setChildren(&root.properties, &children);
        try schema.strings.setLabel(&root.properties, if (accepted) "root after" else "root before");
    }
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var button = Node.init(gpa, .button);
    {
        errdefer button.deinit();
        try schema.strings.setLabel(
            &button.properties,
            if (accepted) "rewritten button with a longer label" else "old button",
        );
    }
    try update.pushNode(gpa, .{ .value = 2 }, button);
    if (!delta) try update.pushNode(gpa, .{ .value = 3 }, Node.init(gpa, .button));
    try update.pushNode(
        gpa,
        .{ .value = if (accepted) @as(u64, 4) else 5 },
        Node.init(gpa, if (accepted) .check_box else .label),
    );
    var info = TreeInfo.init(.{ .value = 1 });
    info.toolkit_name = if (accepted) "after toolkit" else "before toolkit";
    info.toolkit_version = if (accepted) "2" else "1";
    update.tree = info;
    update.focus = .{ .value = if (accepted) @as(u64, 3) else 2 };
    return update;
}

fn expectAtomicState(expected: *const TreeState, actual: *const TreeState) !void {
    try testing.expectEqual(expected.rootId(), actual.rootId());
    try testing.expectEqual(expected.focusIdInTree(), actual.focusIdInTree());
    try testing.expectEqual(expected.focusId(), actual.focusId());
    try testing.expectEqual(expected.isHostFocused(), actual.isHostFocused());
    try testing.expectEqual(expected.info.root, actual.info.root);
    try testing.expect(borrowedTextEql(expected.info.toolkit_name, actual.info.toolkit_name));
    try testing.expect(borrowedTextEql(expected.info.toolkit_version, actual.info.toolkit_version));
    try testing.expectEqualSlices(FullNodeId, expected.nodes.keys(), actual.nodes.keys());
    for (expected.nodes.keys(), expected.nodes.values(), actual.nodes.values()) |id, old, new| {
        try testing.expectEqual(old.parent_and_index, new.parent_and_index);
        try testing.expect(old.data.eql(&new.data));
        try testing.expect(actual.hasNode(id));
        try testing.expect(actual.nodeById(id).?.data().eql(&old.data));
        const tree_id = expected.tree_index_map.getId(id.tree_index).?;
        try testing.expectEqual(
            id,
            actual.nodeByTreeLocalId(id.local, tree_id).?.id(),
        );
    }
    try testing.expectEqualSlices(schema.TreeId, expected.subtrees.keys(), actual.subtrees.keys());
    try testing.expectEqualSlices(
        tree_state.SubtreeState,
        expected.subtrees.values(),
        actual.subtrees.values(),
    );
    for (expected.subtrees.keys()) |id| {
        try testing.expectEqual(expected.subtreeRoot(id), actual.subtreeRoot(id));
    }
    try testing.expectEqualSlices(
        schema.TreeId,
        expected.graft_parents.keys(),
        actual.graft_parents.keys(),
    );
    try testing.expectEqualSlices(
        FullNodeId,
        expected.graft_parents.values(),
        actual.graft_parents.values(),
    );
    try testing.expectEqual(expected.tree_index_map.next, actual.tree_index_map.next);
    try testing.expectEqualSlices(schema.TreeId,
        expected.tree_index_map.id_to_index.keys(), actual.tree_index_map.id_to_index.keys());
    try testing.expectEqualSlices(tree_index.TreeIndex,
        expected.tree_index_map.id_to_index.values(), actual.tree_index_map.id_to_index.values());
    try testing.expectEqualSlices(tree_index.TreeIndex,
        expected.tree_index_map.index_to_id.keys(), actual.tree_index_map.index_to_id.keys());
    try testing.expectEqualSlices(schema.TreeId,
        expected.tree_index_map.index_to_id.values(), actual.tree_index_map.index_to_id.values());
}

const AtomicEvent = struct {
    kind: enum { added, updated, focus, removed },
    old_id: ?FullNodeId = null,
    new_id: ?FullNodeId = null,
    old_role: ?schema.Role = null,
    new_role: ?schema.Role = null,
    old_label: [64]u8 = @splat(0),
    new_label: [64]u8 = @splat(0),
    old_focused: bool = false,
    new_focused: bool = false,
};

const AtomicRecorder = struct {
    tree: *const Tree,
    events: [16]AtomicEvent = undefined,
    count: usize = 0,
    baseline_visible: bool = true,

    fn record(self: *AtomicRecorder, kind: @FieldType(AtomicEvent, "kind"),
        old: ?NodeRef, new: ?NodeRef) void
    {
        std.debug.assert(self.count < self.events.len);
        var event: AtomicEvent = .{ .kind = kind };
        if (old) |node| {
            event.old_id = node.id();
            event.old_role = node.data().role;
            event.old_focused = std.meta.eql(node.tree_state.focusId(), node.id());
            if (schema.strings.label(&node.data().properties)) |label| {
                std.debug.assert(label.len < event.old_label.len);
                @memcpy(event.old_label[0..label.len], label);
            }
        }
        if (new) |node| {
            event.new_id = node.id();
            event.new_role = node.data().role;
            event.new_focused = std.meta.eql(node.tree_state.focusId(), node.id());
            if (schema.strings.label(&node.data().properties)) |label| {
                std.debug.assert(label.len < event.new_label.len);
                @memcpy(event.new_label[0..label.len], label);
            }
        }
        const state = self.tree.stateOf();
        self.baseline_visible = self.baseline_visible and state.isHostFocused() and
            state.focusIdInTree().local.value == 2 and
            state.hasNode(FullNodeId.init(.{ .value = 5 }, .init(0))) and
            !state.hasNode(FullNodeId.init(.{ .value = 4 }, .init(0))) and
            std.mem.eql(u8, state.info.toolkit_name.?, "before toolkit");
        self.events[self.count] = event;
        self.count += 1;
    }

    fn added(ptr: *anyopaque, new: NodeRef) void {
        const self: *AtomicRecorder = @ptrCast(@alignCast(ptr));
        self.record(.added, null, new);
    }
    fn updated(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
        const self: *AtomicRecorder = @ptrCast(@alignCast(ptr));
        self.record(.updated, old, new);
    }
    fn focus(ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
        const self: *AtomicRecorder = @ptrCast(@alignCast(ptr));
        self.record(.focus, old, new);
    }
    fn removed(ptr: *anyopaque, old: NodeRef) void {
        const self: *AtomicRecorder = @ptrCast(@alignCast(ptr));
        self.record(.removed, old, null);
    }
    fn slots(self: *AtomicRecorder) TreeChangeHandler {
        return .{ .ptr = self, .node_added = added, .node_updated = updated,
            .focus_moved = focus, .node_removed = removed };
    }
};

fn expectAtomicEvents(recorder: *const AtomicRecorder, focus_only: bool) !void {
    try testing.expect(recorder.baseline_visible);
    if (focus_only) {
        try testing.expectEqual(@as(usize, 2), recorder.count);
        try testing.expectEqual(.updated, recorder.events[0].kind);
        try testing.expectEqual(@as(u64, 2), recorder.events[0].old_id.?.local.value);
        try testing.expect(recorder.events[0].old_focused);
        try testing.expect(!recorder.events[0].new_focused);
        try testing.expectEqual(.focus, recorder.events[1].kind);
        try testing.expectEqual(@as(u64, 2), recorder.events[1].old_id.?.local.value);
        try testing.expect(recorder.events[1].new_id == null);
        return;
    }
    try testing.expectEqual(@as(usize, 6), recorder.count);
    const kinds = [_]@FieldType(AtomicEvent, "kind"){
        .added, .updated, .updated, .updated, .focus, .removed,
    };
    const ids = [_]u64{ 4, 1, 2, 3, 3, 5 };
    for (recorder.events[0..recorder.count], kinds, ids) |event, kind, id| {
        try testing.expectEqual(kind, event.kind);
        try testing.expectEqual(id, (event.new_id orelse event.old_id.?).local.value);
    }
    try testing.expectEqual(schema.Role.check_box, recorder.events[0].new_role.?);
    try testing.expectEqualStrings("root before", std.mem.sliceTo(&recorder.events[1].old_label, 0));
    try testing.expectEqualStrings("root after", std.mem.sliceTo(&recorder.events[1].new_label, 0));
    try testing.expectEqualStrings("old button", std.mem.sliceTo(&recorder.events[2].old_label, 0));
    try testing.expectEqualStrings(
        "rewritten button with a longer label",
        std.mem.sliceTo(&recorder.events[2].new_label, 0),
    );
    try testing.expect(recorder.events[2].old_focused);
    try testing.expect(!recorder.events[2].new_focused);
    try testing.expect(!recorder.events[3].old_focused);
    try testing.expect(recorder.events[3].new_focused);
    try testing.expectEqual(@as(u64, 2), recorder.events[4].old_id.?.local.value);
    try testing.expectEqual(schema.Role.label, recorder.events[5].old_role.?);
}

test "atomic rejection fail-N preserves accepted tree callbacks and logical retry" {
    var baseline = try Tree.init(testing.allocator,
        try atomicFixture(testing.allocator, false, false), true);
    defer baseline.deinit();
    var oracle = try Tree.init(testing.allocator,
        try atomicFixture(testing.allocator, true, false), true);
    defer oracle.deinit();
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var tree = try Tree.init(gpa, try atomicFixture(gpa, false, false), true);
        defer tree.deinit();
        const update = try atomicFixture(gpa, true, true);
        var recorder: AtomicRecorder = .{ .tree = &tree };
        const slots = recorder.slots();
        failing.fail_index = failing.alloc_index + fail_index;
        if (tree.updateAndProcessChanges(update, &slots)) |_| {
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            try expectAtomicEvents(&recorder, false);
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), recorder.count);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            failing.fail_index = std.math.maxInt(usize);
            try tree.updateAndProcessChanges(try atomicFixture(gpa, true, true), &slots);
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            try expectAtomicEvents(&recorder, false);
        }
    }
    return error.AtomicAllocationBoundExhausted;
}

test "atomic rejection focus fail-N preserves host flag effective focus and callbacks" {
    var baseline = try Tree.init(testing.allocator,
        try atomicFixture(testing.allocator, false, false), true);
    defer baseline.deinit();
    var oracle = try Tree.init(testing.allocator,
        try atomicFixture(testing.allocator, false, false), false);
    defer oracle.deinit();
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var tree = try Tree.init(gpa, try atomicFixture(gpa, false, false), true);
        defer tree.deinit();
        var recorder: AtomicRecorder = .{ .tree = &tree };
        const slots = recorder.slots();
        failing.fail_index = failing.alloc_index + fail_index;
        if (tree.updateHostFocusStateAndProcessChanges(false, &slots)) |_| {
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            try expectAtomicEvents(&recorder, true);
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), recorder.count);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            failing.fail_index = std.math.maxInt(usize);
            try tree.updateHostFocusStateAndProcessChanges(false, &slots);
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            try expectAtomicEvents(&recorder, true);
        }
    }
    return error.AtomicAllocationBoundExhausted;
}

fn atomicActionFixture(
    gpa: Allocator,
    accepted: bool,
    delta: bool,
) schema.vectors.ListPushError!TreeUpdate {
    var update = try atomicFixture(gpa, accepted, delta);
    errdefer update.deinit(gpa);
    const count: usize = if (accepted) 8 else 1;
    for (0..count) |index| {
        try schema.vectors.pushCustomAction(
            &update.nodes.items[1].node.properties,
            try schema.CustomAction.init(
                gpa,
                @intCast(index + 1),
                if (accepted) "new action description" else "old action",
            ),
        );
    }
    if (accepted) {
        try schema.strings.setLabel(
            &update.nodes.items[update.nodes.items.len - 1].node.properties,
            "owned added node",
        );
    }
    return update;
}

test "atomic custom action rewrite fail-N keeps owned additions and descriptions retryable" {
    var baseline = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, false, false), true);
    defer baseline.deinit();
    var oracle = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, true, false), true);
    defer oracle.deinit();
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var tree = try Tree.init(gpa, try atomicActionFixture(gpa, false, false), true);
        defer tree.deinit();
        const update = try atomicActionFixture(gpa, true, true);
        var recorder: AtomicRecorder = .{ .tree = &tree };
        const slots = recorder.slots();
        failing.fail_index = failing.alloc_index + fail_index;
        if (tree.updateAndProcessChanges(update, &slots)) |_| {
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            try expectAtomicEvents(&recorder, false);
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), recorder.count);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            failing.fail_index = std.math.maxInt(usize);
            try tree.updateAndProcessChanges(try atomicActionFixture(gpa, true, true), &slots);
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            try expectAtomicEvents(&recorder, false);
        }
    }
    return error.AtomicAllocationBoundExhausted;
}

fn expectBorrowedUpdate(expected: *const TreeUpdate, actual: *const TreeUpdate) !void {
    try testing.expectEqual(expected.tree_id, actual.tree_id);
    try testing.expectEqual(expected.focus, actual.focus);
    try testing.expectEqualDeep(expected.tree, actual.tree);
    try testing.expectEqual(expected.nodes.items.len, actual.nodes.items.len);
    for (expected.nodes.items, actual.nodes.items) |old, new| {
        try testing.expectEqual(old.node_id, new.node_id);
        try testing.expect(old.node.eql(&new.node));
    }
}

test "borrowed initial input survives every allocation rejection and source release" {
    var source = try atomicActionFixture(testing.allocator, true, false);
    var source_live = true;
    defer if (source_live) source.deinit(testing.allocator);
    var expected = try atomicActionFixture(testing.allocator, true, false);
    defer expected.deinit(testing.allocator);
    var oracle = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, true, false), true);
    defer oracle.deinit();
    const source_nodes = source.nodes.items.ptr;
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{
            .fail_index = fail_index,
            .resize_fail_index = 0,
        });
        if (Tree.initBorrowed(failing.allocator(), &source, true)) |accepted| {
            var tree = accepted;
            defer tree.deinit();
            try expectBorrowedUpdate(&expected, &source);
            try testing.expect(source.nodes.items.ptr == source_nodes);
            source.deinit(testing.allocator);
            source_live = false;
            try expectAtomicState(oracle.stateOf(), tree.stateOf());
            return;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try expectBorrowedUpdate(&expected, &source);
            try testing.expect(source.nodes.items.ptr == source_nodes);
        }
    }
    return error.AtomicAllocationBoundExhausted;
}

test "borrowed delta fail-N preserves source baseline callbacks and retry after release" {
    var baseline = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, false, false), true);
    defer baseline.deinit();
    var oracle = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, true, false), true);
    defer oracle.deinit();
    var expected = try atomicActionFixture(testing.allocator, true, true);
    defer expected.deinit(testing.allocator);
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var tree = try Tree.init(gpa, try atomicActionFixture(gpa, false, false), true);
        defer tree.deinit();
        var source = try atomicActionFixture(testing.allocator, true, true);
        var source_live = true;
        defer if (source_live) source.deinit(testing.allocator);
        const source_nodes = source.nodes.items.ptr;
        var recorder: AtomicRecorder = .{ .tree = &tree };
        const slots = recorder.slots();
        failing.fail_index = failing.alloc_index + fail_index;
        var first_success = false;
        if (tree.updateBorrowedAndProcessChanges(&source, &slots)) |_| {
            first_success = true;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), recorder.count);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            try expectBorrowedUpdate(&expected, &source);
            try testing.expect(source.nodes.items.ptr == source_nodes);
            failing.fail_index = std.math.maxInt(usize);
            try tree.updateBorrowedAndProcessChanges(&source, &slots);
        }
        try expectBorrowedUpdate(&expected, &source);
        try testing.expect(source.nodes.items.ptr == source_nodes);
        source.deinit(testing.allocator);
        source_live = false;
        try expectAtomicState(oracle.stateOf(), tree.stateOf());
        try expectAtomicEvents(&recorder, false);
        if (first_success) return;
    }
    return error.AtomicAllocationBoundExhausted;
}

test "borrowed initialization rejects missing and nonroot tree without consuming input" {
    var source = try atomicFixture(testing.allocator, false, false);
    defer source.deinit(testing.allocator);
    var expected = try atomicFixture(testing.allocator, false, false);
    defer expected.deinit(testing.allocator);
    source.tree = null;
    expected.tree = null;
    try testing.expectError(error.NoRootTree, Tree.initBorrowed(testing.allocator, &source, true));
    try expectBorrowedUpdate(&expected, &source);
    source.tree = TreeInfo.init(.{ .value = 1 });
    expected.tree = source.tree;
    source.tree_id = schema.treeIdFromBytes(@splat(0x91));
    expected.tree_id = source.tree_id;
    try testing.expectError(error.NotTheRootTree,
        Tree.initBorrowed(testing.allocator, &source, true));
    try expectBorrowedUpdate(&expected, &source);
}

test "atomic dirty recovery fail-N rejects update and focus without contaminating retry" {
    var baseline = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, false, false), true);
    defer baseline.deinit();
    var oracle = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, true, false), true);
    defer oracle.deinit();
    var unfocused = try Tree.init(testing.allocator,
        try atomicActionFixture(testing.allocator, false, false), false);
    defer unfocused.deinit();
    inline for (.{ false, true }) |focus_only| {
        var completed = false;
        for (0..atomic_allocation_bound) |fail_index| {
            var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
            const gpa = failing.allocator();
            var tree = try Tree.init(gpa, try atomicActionFixture(gpa, false, false), true);
            defer tree.deinit();
            var recorder: AtomicRecorder = .{ .tree = &tree };
            const slots = recorder.slots();
            const rejected = try atomicActionFixture(gpa, true, true);
            failing.fail_index = failing.alloc_index;
            try testing.expectError(error.OutOfMemory,
                tree.updateAndProcessChanges(rejected, &slots));
            try testing.expectEqual(@as(usize, 0), recorder.count);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            failing.fail_index = std.math.maxInt(usize);
            const retry = if (focus_only) null else try atomicActionFixture(gpa, true, true);
            failing.fail_index = failing.alloc_index + fail_index;
            const result = if (focus_only)
                tree.updateHostFocusStateAndProcessChanges(false, &slots)
            else
                tree.updateAndProcessChanges(retry.?, &slots);
            if (result) |_| {
                if (focus_only) {
                    try expectAtomicState(unfocused.stateOf(), tree.stateOf());
                    try testing.expect(!tree.stateOf().isHostFocused());
                    try testing.expect(tree.stateOf().focusId() == null);
                    try testing.expectEqual(@as(u64, 2), tree.stateOf().focusIdInTree().local.value);
                    try expectAtomicEvents(&recorder, true);
                } else {
                    try expectAtomicState(oracle.stateOf(), tree.stateOf());
                    try expectAtomicEvents(&recorder, false);
                }
                completed = true;
                break;
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                try testing.expectEqual(@as(usize, 0), recorder.count);
                try expectAtomicState(baseline.stateOf(), tree.stateOf());
                failing.fail_index = std.math.maxInt(usize);
                try tree.updateAndProcessChanges(try atomicActionFixture(gpa, true, true), &slots);
                try expectAtomicState(oracle.stateOf(), tree.stateOf());
                try expectAtomicEvents(&recorder, false);
            }
        }
        if (!completed) return error.AtomicAllocationBoundExhausted;
    }
}

test "atomic unchanged child promotion commits its parent change and callback" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();
    var context: usize = 0;
    const silent = silentSlots(&context);
    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &silent);
    var promotion: TreeUpdate = .{};
    try promotion.pushNode(gpa, child, Node.init(gpa, .button));
    promotion.tree = TreeInfo.init(child);
    promotion.focus = child;
    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();
    try tree.updateAndProcessChanges(promotion, &slots);
    const accepted = tree.stateOf();
    try testing.expectEqual(child, accepted.rootId().local);
    try testing.expectEqual(child, accepted.focusId().?.local);
    try testing.expect(!accepted.hasNode(FullNodeId.init(root, .init(0))));
    try testing.expect(@import("node_ref/hierarchy.zig").parentId(accepted.root()) == null);
    try testing.expectEqual(@as(usize, 0), recorder.added);
    try testing.expectEqual(@as(usize, 1), recorder.updated);
    try testing.expectEqual(@as(usize, 1), recorder.moved);
    try testing.expectEqual(@as(usize, 1), recorder.removed);
}

fn atomicGraftId() schema.TreeId {
    return schema.treeIdFromBytes(@splat(0x45));
}

fn atomicGraftRoot(gpa: Allocator) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    var root = Node.init(gpa, .group);
    {
        errdefer root.deinit();
        try schema.ids_props.setChildren(&root.properties, &.{.{ .value = 2 }});
    }
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var graft = Node.init(gpa, .generic_container);
    {
        errdefer graft.deinit();
        try schema.option.setTreeId(&graft.properties, atomicGraftId());
    }
    try update.pushNode(gpa, .{ .value = 2 }, graft);
    update.tree = TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    return update;
}

fn atomicSubtree(gpa: Allocator) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    var root = Node.init(gpa, .group);
    {
        errdefer root.deinit();
        try schema.ids_props.setChildren(&root.properties, &.{.{ .value = 101 }});
        try schema.strings.setLabel(&root.properties, "subtree root");
    }
    try update.pushNode(gpa, .{ .value = 100 }, root);
    try update.pushNode(gpa, .{ .value = 101 }, Node.init(gpa, .button));
    update.tree_id = atomicGraftId();
    update.tree = TreeInfo.init(.{ .value = 100 });
    update.focus = .{ .value = 100 };
    return update;
}

test "atomic first subtree registration fail-N preserves both index directions and retry" {
    var baseline = try Tree.init(testing.allocator, try atomicGraftRoot(testing.allocator), true);
    defer baseline.deinit();
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var tree = try Tree.init(gpa, try atomicGraftRoot(gpa), true);
        defer tree.deinit();
        const update = try atomicSubtree(gpa);
        var recorder: Recorder = .{ .tree = &tree };
        const slots = recorder.slots();
        failing.fail_index = failing.alloc_index + fail_index;
        var first_success = false;
        if (tree.updateAndProcessChanges(update, &slots)) |_| {
            first_success = true;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), recorder.added);
            try testing.expectEqual(@as(usize, 0), recorder.updated);
            try testing.expectEqual(@as(usize, 0), recorder.moved);
            try testing.expectEqual(@as(usize, 0), recorder.removed);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            failing.fail_index = std.math.maxInt(usize);
            try tree.updateAndProcessChanges(try atomicSubtree(gpa), &slots);
        }
        const state = tree.stateOf();
        try testing.expectEqual(@as(usize, 2), recorder.added);
        try testing.expectEqual(@as(usize, 0), recorder.updated);
        try testing.expectEqual(@as(usize, 0), recorder.moved);
        try testing.expectEqual(@as(usize, 0), recorder.removed);
        const index = state.tree_index_map.getIndex(atomicGraftId()).?;
        try testing.expectEqual(tree_index.TreeIndex.init(1), index);
        try testing.expectEqual(atomicGraftId(), state.tree_index_map.getId(index).?);
        try testing.expectEqual(@as(u32, 2), state.tree_index_map.next);
        const root = state.nodeByTreeLocalId(.{ .value = 100 }, atomicGraftId()).?;
        try testing.expectEqual(root.id(), state.subtreeRoot(atomicGraftId()).?);
        try testing.expectEqual(
            FullNodeId.init(.{ .value = 2 }, .init(0)),
            @import("node_ref/hierarchy.zig").parentId(root).?,
        );
        try testing.expectEqualStrings("subtree root", schema.strings.label(&root.data().properties).?);
        if (first_success) return;
    }
    return error.AtomicAllocationBoundExhausted;
}

fn atomicMetadataOnlyCase(fail_index: usize) !bool {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    const gpa = failing.allocator();
    var tree = try Tree.init(gpa, try atomicGraftRoot(gpa), true);
    defer tree.deinit();
    var context: usize = 0;
    const silent = silentSlots(&context);
    try tree.updateAndProcessChanges(try atomicSubtree(gpa), &silent);
    var baseline = try Tree.init(testing.allocator, try atomicGraftRoot(testing.allocator), true);
    defer baseline.deinit();
    try baseline.updateAndProcessChanges(try atomicSubtree(testing.allocator), &silent);
    var update: TreeUpdate = .{};
    update.tree_id = atomicGraftId();
    update.tree = TreeInfo.init(.{ .value = 100 });
    update.focus = .{ .value = 101 };
    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();
    failing.fail_index = failing.alloc_index + fail_index;
    var first_success = false;
    if (tree.updateAndProcessChanges(update, &slots)) |_| {
        first_success = true;
    } else |err| {
        try testing.expectEqual(error.OutOfMemory, err);
        try testing.expectEqual([_]usize{ 0, 0, 0, 0 }, [_]usize{ recorder.added, recorder.updated, recorder.moved, recorder.removed });
        try expectAtomicState(baseline.stateOf(), tree.stateOf());
        failing.fail_index = std.math.maxInt(usize);
        try tree.updateAndProcessChanges(.{ .tree_id = atomicGraftId(), .tree = TreeInfo.init(.{ .value = 100 }), .focus = .{ .value = 101 } }, &slots);
    }
    baseline.state.subtrees.getPtr(atomicGraftId()).?.focus = .init(.{ .value = 101 }, .init(1));
    try expectAtomicState(baseline.stateOf(), tree.stateOf());
    const state = tree.stateOf();
    const root = state.nodeByTreeLocalId(.{ .value = 100 }, atomicGraftId()).?;
    try testing.expectEqual(
        FullNodeId.init(.{ .value = 2 }, .init(0)),
        @import("node_ref/hierarchy.zig").parentId(root).?,
    );
    try testing.expectEqual(
        FullNodeId.init(.{ .value = 101 }, .init(1)),
        state.subtrees.get(atomicGraftId()).?.focus,
    );
    try testing.expectEqual(@as(usize, 0), recorder.added);
    try testing.expectEqual(@as(usize, 1), recorder.updated);
    try testing.expectEqual(@as(usize, 0), recorder.moved);
    try testing.expectEqual(@as(usize, 0), recorder.removed);
    return first_success;
}

test "atomic metadata-only subtree update records the existing grafted root" {
    for (0..atomic_allocation_bound) |fail_index| {
        if (try atomicMetadataOnlyCase(fail_index)) return;
    }
    return error.AtomicAllocationBoundExhausted;
}

fn atomicRelocateGraft(gpa: Allocator) Allocator.Error!TreeUpdate {
    var update: TreeUpdate = .{};
    errdefer update.deinit(gpa);
    var root = Node.init(gpa, .group);
    {
        errdefer root.deinit();
        try schema.ids_props.setChildren(&root.properties, &.{.{ .value = 3 }});
    }
    try update.pushNode(gpa, .{ .value = 1 }, root);
    var graft = Node.init(gpa, .generic_container);
    {
        errdefer graft.deinit();
        try schema.option.setTreeId(&graft.properties, atomicGraftId());
        try schema.strings.setLabel(&graft.properties, "new graft parent");
    }
    try update.pushNode(gpa, .{ .value = 3 }, graft);
    update.focus = .{ .value = 1 };
    return update;
}

test "atomic graft relocation fail-N preserves parent maps owned nodes and retry" {
    var baseline = try Tree.init(testing.allocator, try atomicGraftRoot(testing.allocator), true);
    defer baseline.deinit();
    var context: usize = 0;
    const silent = silentSlots(&context);
    try baseline.updateAndProcessChanges(try atomicSubtree(testing.allocator), &silent);
    for (0..atomic_allocation_bound) |fail_index| {
        var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
        const gpa = failing.allocator();
        var tree = try Tree.init(gpa, try atomicGraftRoot(gpa), true);
        defer tree.deinit();
        try tree.updateAndProcessChanges(try atomicSubtree(gpa), &silent);
        const update = try atomicRelocateGraft(gpa);
        var recorder: Recorder = .{ .tree = &tree };
        const slots = recorder.slots();
        failing.fail_index = failing.alloc_index + fail_index;
        var first_success = false;
        if (tree.updateAndProcessChanges(update, &slots)) |_| {
            first_success = true;
        } else |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expectEqual(@as(usize, 0), recorder.added);
            try testing.expectEqual(@as(usize, 0), recorder.updated);
            try testing.expectEqual(@as(usize, 0), recorder.moved);
            try testing.expectEqual(@as(usize, 0), recorder.removed);
            try expectAtomicState(baseline.stateOf(), tree.stateOf());
            failing.fail_index = std.math.maxInt(usize);
            try tree.updateAndProcessChanges(try atomicRelocateGraft(gpa), &slots);
        }
        const state = tree.stateOf();
        const graft_id = FullNodeId.init(.{ .value = 3 }, .init(0));
        try testing.expectEqual(graft_id, state.graft_parents.get(atomicGraftId()).?);
        try testing.expectEqual(graft_id, @import("node_ref/hierarchy.zig").parentId(
            state.nodeByTreeLocalId(.{ .value = 100 }, atomicGraftId()).?,
        ).?);
        try testing.expect(!state.hasNode(FullNodeId.init(.{ .value = 2 }, .init(0))));
        try testing.expectEqualStrings("new graft parent",
            schema.strings.label(&state.nodeById(graft_id).?.data().properties).?);
        try testing.expectEqual(@as(usize, 1), recorder.added);
        try testing.expectEqual(@as(usize, 2), recorder.updated);
        try testing.expectEqual(@as(usize, 0), recorder.moved);
        try testing.expectEqual(@as(usize, 1), recorder.removed);
        if (first_success) return;
    }
    return error.AtomicAllocationBoundExhausted;
}
