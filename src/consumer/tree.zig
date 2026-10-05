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
//! This module does not apply an update. `applyUpdate` in `tree_apply.zig` owns
//! that algorithm and it needs the state `Tree` owns, so the two cannot be one
//! file. It performs no I/O, reads no clock and holds no global state, so no
//! function here takes `io: std.Io` and nothing here names `zio`.
//!
//! ## This file orchestrates: it calls the passes, and it calls the validators
//! last
//!
//! One update runs in this order, and every step is one module's function:
//!
//! 1. `applyUpdate` in `tree_apply.zig` and the removal and graft passes in
//!    `tree_grafts.zig` write the working state.
//! 2. `validateWorkingState` below recomputes the effective focus and then
//!    validates, because a validator called before the last mutation proves
//!    nothing.
//! 3. `processChanges` reports the change to the handler and commits it.
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
//! `TreeChangeHandler`, together with what a `null` slot does instead. The two
//! update methods below are the only callers, and both run every slot before
//! the commit, which is what makes the lifetime sentence true.
//!
//! ## Recorded deviations from `docs/33`, each with its reason
//!
//! 1. **`processChanges` returns `UpdateError!void` where
//!    `docs/10-accesskit-core.md` line 1906 writes `void`.** Rule C8 bans
//!    `unreachable`, and the six `.unwrap()` sites at `tree.rs:643`, `:647`,
//!    `:675`, `:681`, `:687` and `:691` are each either a lookup the invariants
//!    make impossible or a `Node.cloneInto` that can fail. A tag is the only
//!    answer rule C8 leaves, and `error.NodeMissingFromState` is the tag
//!    section 5 already gives the same unwrap at `tree.rs:367`.
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
//!    path where `applyUpdate` fails would release the same three sets twice.
//!    One owner, on every path, is the caller.
//! 5. **`TreeInfo` is compared by bytes.** Upstream compares the two values
//!    with `PartialEq` at `tree.rs:693`, which compares `Option<String>` by
//!    content. `std.meta.eql` compares a slice by address and length, so two
//!    independent borrows of equal bytes would compare as different and the
//!    comparison is written out here instead.
//! 6. **`#[derive(Debug)]` at `tree.rs:585` is deleted.** It exists for a Rust
//!    caller that prints a `Tree` in a panic message. Nothing in the port
//!    formats a `Tree`, and no `format` method reaches this layer, so the derive
//!    would have no call site.
//! 7. **`initial_update` and `update` are transferred, not borrowed.** Both are
//!    `TreeUpdate` values taken by value, and both are consumed by
//!    `applyUpdate`, which deep-copies each node into the state it writes and
//!    releases the update itself. A caller must therefore not call `deinit` on
//!    either binding, and a second call with the same binding is a use of a spent
//!    value. The two rejections `init` raises on its own, at `tree.rs:594` and
//!    `:599`, happen before `applyUpdate` takes the update, so `init` releases
//!    it there with `TreeUpdate.deinit` and nowhere else. That is one teardown
//!    path for one type, not two.
//! 8. **`subtrees` and `graft_parents` are replaced through the container's own
//!    `clone`.** Section 2 declares `TreeState.cloneInto` and
//!    `TreeIndexMap.cloneInto` and no single-map clone, while the three commits
//!    at `tree.rs:699-705` name three different maps. The missing declaration is
//!    not a gap the port left: `cloneInto` is the whole-map operation with one
//!    caller, upstream reaches for `HashMap::clone` inline at each of those
//!    three lines, and so upstream has no per-map operation either. The port made
//!    the absence visible by having a declared whole-map clone beside three
//!    undeclared ones. A reader comparing section 2 with this file should read
//!    the missing declaration as one that never existed rather than one that was
//!    forgotten. Both maps hold only plain values, so the copy is the entries and
//!    no entry needs releasing.
//!
//! ## A port addition, for the additions register
//!
//! `processChanges` uses `std.array_hash_map.Auto.clone` on `subtrees` and
//! `graft_parents`, with the old map released only after the copy exists. Neither
//! operation exists upstream, so a register of what this port added names it.
//! Declaring a single-map clone in `tree_state.zig` instead would mean touching
//! a landed, green file for two call sites, and the type being copied already
//! has the operation, so the port addition stays here.

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

/// Failures of `Tree.init`, `Tree.updateAndProcessChanges`,
/// `Tree.updateHostFocusStateAndProcessChanges` and `processChanges`. Declared
/// in `tree_state.zig` and re-exported here because `Tree` is the first module
/// an application calls; that file holds the tag list and says what each tag
/// leaves behind.
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
///   `processChanges` commits as soon as the last slot returns, which moves and
///   releases both maps. A callee that needs the node afterwards copies what it
///   wants out of `node.data()` before it returns.
/// - **Which thread it runs on.** The thread that called
///   `updateAndProcessChanges`, inside that call and before it returns. This
///   layer starts no thread and holds no lock.
/// - **Whether the callee may reenter.** It may read the same `Tree` through
///   `stateOf` and through the queries, and it sees the committed state as it
///   stood before this update, because the commit runs after the slots. It must
///   not call `updateAndProcessChanges`,
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

    /// The working tree that `applyUpdate` writes. It holds its own copy of
    /// every node, so growing or freeing it never touches the buffers `state`
    /// reads.
    next_state: TreeState,

    /// Builds the tree from the first update, which must carry the whole root
    /// tree. Upstream `tree.rs:592-618`.
    ///
    /// `initial_update.tree` must be set, or the call returns
    /// `error.NoRootTree` from the panic at `tree.rs:594`, and
    /// `initial_update.tree_id` must be `schema.tree_id_root`, or the call
    /// returns `error.NotTheRootTree` from the panic at `tree.rs:599`.
    ///
    /// `initial_update` is transferred to the call on every path. That is the
    /// contract: a transfer makes the hazard impossible rather than leaving it to
    /// a caller to remember, so a caller must not call `deinit` on the binding
    /// afterwards and a second call with the same binding is a use of a spent
    /// value. On success the update's nodes are in the returned tree. On the two
    /// rejections above, and on every error below, the value's own
    /// `TreeUpdate.deinit` runs inside `init` on whatever it still holds, and the
    /// same binding is spent either way. There is no path on which the caller
    /// still owns something, so there is no path on which a caller can double
    /// free. The returned tree owns the update's nodes, and the caller owns the
    /// tree.
    ///
    /// On any error nothing survives: `init` releases every node it took and
    /// every map it built, so a caller retries with a corrected update and
    /// never sees a half-built tree.
    pub fn init(
        gpa: Allocator,
        initial_update: TreeUpdate,
        is_host_focused: bool,
    ) UpdateError!Tree {
        // `TreeUpdate.deinit` takes `*TreeUpdate` and a by-value parameter is a
        // const binding, so the release needs a mutable local. It copies the
        // handle and not the array, so it still frees the caller's allocation.
        // A rejection added below must release the update the same way.
        var owned_update = initial_update;

        const info = owned_update.tree orelse {
            owned_update.deinit(gpa);
            return error.NoRootTree;
        };
        if (!owned_update.tree_id.eql(tree_id_root)) {
            owned_update.deinit(gpa);
            return error.NotTheRootTree;
        }

        // Registered before the first allocation, so every path that returns an
        // error releases whatever `state` already holds.
        var state: TreeState = .{};
        errdefer state.deinit(gpa);

        // `owned_update` is released on exactly three paths: the two rejections
        // above, and `applyUpdate` below, which takes it. This `try` used to be a
        // fourth exit that released only `state` through the `errdefer` above
        // and dropped the update on the floor, so every node in it and the
        // update's own array leaked whenever `getOrCreateIndex` failed.
        //
        // A fail-N sweep over `init`'s seven allocations confirmed it: the first
        // two, which are `getOrCreateIndex`'s own two map inserts, leaked, and
        // indices from the third onward did not, because those fail inside
        // `applyUpdate`, which does release.
        const assigned_index = state.tree_index_map.getOrCreateIndex(
            gpa,
            owned_update.tree_id,
        ) catch |err| {
            owned_update.deinit(gpa);
            return err;
        };
        state.root_id = .{ .local = info.root, .tree_index = assigned_index };
        state.info = info;
        state.focus_id = .{ .local = owned_update.focus, .tree_index = assigned_index };
        state.is_host_focused = is_host_focused;

        // `applyUpdate` takes the update and releases it, success or error, so
        // there is no release of `owned_update` past this line.
        try tree_apply.applyUpdate(gpa, &state, owned_update, null);
        try validateWorkingState(&state);

        // Upstream clones the state at `tree.rs:613` so the working state is a
        // second owner rather than a second handle to the same nodes.
        var next_state: TreeState = .{};
        errdefer next_state.deinit(gpa);
        try next_state.cloneInto(&state, gpa);

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
        self.* = .{ .gpa = gpa, .state = .{}, .next_state = .{} };
    }

    /// The committed state, which is what an application reads. Upstream
    /// `tree.rs:708-710`.
    ///
    /// The borrow ends at the next call that commits, which is
    /// `updateAndProcessChanges` or `updateHostFocusStateAndProcessChanges`,
    /// and at `deinit`. A `NodeRef` taken from the result shares the same borrow.
    pub fn stateOf(self: *const Tree) *const TreeState {
        return &self.state;
    }

    /// Applies `update` to the working state and then commits it, reporting
    /// what changed. Upstream `tree.rs:620-628`.
    ///
    /// `update` is transferred to the call and released by `applyUpdate`, so a
    /// caller must not call `deinit` on it. The committed state is written only
    /// by `processChanges`, and only after every slot has run, so a slot sees
    /// the tree as it stood before this update.
    ///
    /// On `error.OutOfMemory` inside the commit, the nodes the commit already
    /// copied stay in the committed state and the rest of the commit did not
    /// happen, so the state is a mixture of the two updates. On any other
    /// `UpdateError` the committed state still holds the last update that
    /// succeeded, the working state is partly written, and a caller may retry
    /// with a corrected update.
    pub fn updateAndProcessChanges(
        self: *Tree,
        update: TreeUpdate,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        var changes: InternalChanges = .{};
        defer changes.deinit(self.gpa);
        try tree_apply.applyUpdate(self.gpa, &self.next_state, update, &changes);
        try validateWorkingState(&self.next_state);
        try self.processChanges(changes, handler);
    }

    /// Records the host focus flag on the working state, then commits. Upstream
    /// `tree.rs:630-638`.
    ///
    /// The only change a slot sees is `focus_moved`, because the flag decides
    /// whether `TreeState.focus` reports a focus at all: turning the flag off
    /// makes the new focus `null` and turning it on makes the old one `null`.
    /// `handler` follows the four obligations on `TreeChangeHandler`.
    ///
    /// An empty change set names no node, so no pass walks one and
    /// `error.NodeMissingFromState` is not reachable here. The three map copies
    /// the commit makes are the only fallible work, which makes
    /// `error.OutOfMemory` the one tag a caller has to handle.
    pub fn updateHostFocusStateAndProcessChanges(
        self: *Tree,
        is_host_focused: bool,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        self.next_state.is_host_focused = is_host_focused;
        var changes: InternalChanges = .{};
        defer changes.deinit(self.gpa);
        try self.processChanges(changes, handler);
    }

    /// Reports `changes` to `handler` and then folds the working state into the
    /// committed one. Upstream `tree.rs:640-706`.
    ///
    /// The order is the contract, because a platform adapter reads it: added,
    /// then updated, then the focus move with its two synthetic updates, then
    /// removed, and only then the commit. Reordering those passes changes what
    /// the adapter sees.
    ///
    /// **The bound on every loop below.** Each pass walks one of the three sets
    /// in `changes`, so the set's own length is the bound and the loop test is
    /// the iterator's exhaustion. The sets do not change while they are walked,
    /// so the bound holds for the whole pass. `docs/33` section 7 row 4 records
    /// the same form for a walk over a collection that does change, and there
    /// the bound is re-read at each iteration instead.
    ///
    /// `changes` is borrowed. This function reads its three sets and never
    /// releases them, because the caller holds the one owner and a release here
    /// would pair with the caller's and release them twice.
    ///
    /// Every `NodeRef` a slot receives ends when this call returns, because the
    /// commit below moves and releases the maps they point into.
    ///
    /// `error.NodeMissingFromState` when a set names a node that neither state
    /// holds, which I1 to I4 make impossible after a successful `applyUpdate`.
    /// It is a tag and not an `unreachable` because rule C8 bans `unreachable`.
    /// `error.OutOfMemory` from the commit, and then the committed state holds
    /// the additions the commit already copied.
    ///
    /// **The order of the three map commits is the invariant.** Each one builds
    /// the copy first and releases the committed map only once the copy exists.
    /// Released first, a failed clone leaves the committed map holding nothing
    /// and the update's subtree facts lost. Released second, a failed clone
    /// leaves the destination exactly as the caller passed it, so a caller may
    /// retry with the same tree. `TreeIndexMap.cloneInto` states the same rule
    /// for the third map, so the three behave alike on `error.OutOfMemory`.
    fn processChanges(
        self: *Tree,
        changes: InternalChanges,
        handler: *const TreeChangeHandler,
    ) UpdateError!void {
        // `tree.rs:641-644`: every added node, read from the state that is about
        // to be committed.
        var added_ids = changes.added_node_ids.iterator();
        while (added_ids.next()) |entry| {
            const node = self.next_state.nodeById(entry.key_ptr.*) orelse
                return error.NodeMissingFromState;
            if (handler.node_added) |slot| slot(handler.ptr, node);
        }

        // `tree.rs:645-649`: every rewritten node, as the committed version and
        // as the working version.
        var updated_ids = changes.updated_node_ids.iterator();
        while (updated_ids.next()) |entry| {
            const id = entry.key_ptr.*;
            const old_node = self.state.nodeById(id) orelse
                return error.NodeMissingFromState;
            const new_node = self.next_state.nodeById(id) orelse
                return error.NodeMissingFromState;
            if (handler.node_updated) |slot| slot(handler.ptr, old_node, new_node);
        }

        const old_focus = self.state.focus();
        const new_focus = self.next_state.focus();

        // Upstream compares the two ids at `tree.rs:652` and not the two
        // references, because a `NodeRef` is two pointers and the same node has
        // a different pair in each state.
        const focus_changed = !std.meta.eql(
            if (old_focus) |node| node.id() else null,
            if (new_focus) |node| node.id() else null,
        );
        if (focus_changed) {
            // `tree.rs:653-662`. A node that lost the focus but was neither
            // rewritten nor removed still changed, so the adapter is told it was
            // rewritten.
            if (old_focus) |old_node| {
                const id = old_node.id();
                const rewritten = !changes.updated_node_ids.contains(id) and
                    !changes.removed_node_ids.contains(id);
                if (rewritten) {
                    if (self.next_state.nodeById(id)) |old_node_new_version| {
                        if (handler.node_updated) |slot| {
                            slot(handler.ptr, old_node, old_node_new_version);
                        }
                    }
                }
            }
            // `tree.rs:663-671`. The same for a node that gained the focus.
            if (new_focus) |new_node| {
                const id = new_node.id();
                const reported = !changes.added_node_ids.contains(id) and
                    !changes.updated_node_ids.contains(id);
                if (reported) {
                    if (self.state.nodeById(id)) |new_node_old_version| {
                        if (handler.node_updated) |slot| {
                            slot(handler.ptr, new_node_old_version, new_node);
                        }
                    }
                }
            }
            if (handler.focus_moved) |slot| slot(handler.ptr, old_focus, new_focus);
        }

        // `tree.rs:674-677`: every removed node, read from the committed state
        // before the commit takes it out.
        var removed_ids = changes.removed_node_ids.iterator();
        while (removed_ids.next()) |entry| {
            const node = self.state.nodeById(entry.key_ptr.*) orelse
                return error.NodeMissingFromState;
            if (handler.node_removed) |slot| slot(handler.ptr, node);
        }

        // --- The commit. `tree.rs:678-705`.

        // An added node is deep-copied, so the committed state keeps buffers of
        // its own and releasing one state never releases the other's.
        var added_commit = changes.added_node_ids.iterator();
        while (added_commit.next()) |entry| {
            const id = entry.key_ptr.*;
            const added_node_state = self.next_state.nodes.get(id) orelse
                return error.NodeMissingFromState;
            var added: NodeState = .{
                .parent_and_index = added_node_state.parent_and_index,
                .data = try Node.clone(self.gpa, &added_node_state.data),
            };
            // Registered after the clone, so a failed insert releases the copy
            // and a successful one hands it to the map.
            errdefer added.data.deinit();
            // Upstream's `insert` at `tree.rs:678-682` drops whatever the key
            // held, so a key the committed state already carries releases its
            // old node here. An added id is not in the committed state on a
            // state that satisfies I1 to I4, so the null arm is the ordinary
            // one and this arm is a leak guard rather than the usual path.
            if (try self.state.nodes.fetchPut(self.gpa, id, added)) |previous| {
                var previous_node_state = previous.value;
                previous_node_state.data.deinit();
            }
        }

        // A rewritten node is cloned into the committed node, so the committed
        // store reuses its buffers and keeps them across the update.
        var updated_commit = changes.updated_node_ids.iterator();
        while (updated_commit.next()) |entry| {
            const id = entry.key_ptr.*;
            const committed_node_state = self.state.nodes.getPtr(id) orelse
                return error.NodeMissingFromState;
            const rewritten_node_state = self.next_state.nodes.get(id) orelse
                return error.NodeMissingFromState;
            // Upstream's `clone_from` at `tree.rs:683-689` clones the whole
            // entry, so the parent and the index move with the data.
            committed_node_state.parent_and_index = rewritten_node_state.parent_and_index;
            try Node.cloneInto(rewritten_node_state.data, &committed_node_state.data);
        }

        // A removed node leaves the committed state, and Rust's `remove` at
        // `tree.rs:690-692` drops the entry at the end of the statement, so the
        // port has to say so: the entry carries a property store that owns
        // buffers. The ordered form is used because the map keeps insertion
        // order and the port does not scramble the survivors.
        var removed_commit = changes.removed_node_ids.iterator();
        while (removed_commit.next()) |entry| {
            const removed = self.state.nodes.fetchOrderedRemove(entry.key_ptr.*) orelse
                return error.NodeMissingFromState;
            var removed_node_state = removed.value;
            removed_node_state.data.deinit();
        }

        // `tree.rs:693-695`. `TreeInfo` is three plain fields and two of them
        // borrow, so the copy is a field copy: nothing allocates and nothing
        // needs releasing.
        if (self.treeInfoChanged()) self.state.info = self.next_state.info;

        // `tree.rs:696-698`.
        self.state.root_id = self.next_state.root_id;
        self.state.focus_id = self.next_state.focus_id;
        self.state.is_host_focused = self.next_state.is_host_focused;

        // `tree.rs:699-705`. Each map is copied whole and the old one is
        // released only once the copy exists, so `error.OutOfMemory` leaves the
        // committed map as it was.
        const subtrees = try self.next_state.subtrees.clone(self.gpa);
        self.state.subtrees.deinit(self.gpa);
        self.state.subtrees = subtrees;

        const graft_parents = try self.next_state.graft_parents.clone(self.gpa);
        self.state.graft_parents.deinit(self.gpa);
        self.state.graft_parents = graft_parents;

        try self.state.tree_index_map.cloneInto(&self.next_state.tree_index_map, self.gpa);
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

test "init seeds the working state as a second owner, not a second handle" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    const id = FullNodeId.init(root, .init(0));
    // The two states agree on content and hold separate buffers. A working state
    // that shared the committed state's node would carry the label written
    // below into both, and a release of one would free what the other reads.
    try testing.expectEqual(schema.Role.group, tree.state.nodes.get(id).?.data.role);
    try testing.expectEqual(schema.Role.group, tree.next_state.nodes.get(id).?.data.role);
    try schema.strings.setLabel(
        &tree.state.nodes.getPtr(id).?.data.properties,
        "committed only",
    );
    try testing.expectEqualStrings(
        "committed only",
        schema.strings.label(&tree.state.nodes.get(id).?.data.properties).?,
    );
    // The leak check at the end of this test is the second half of the claim:
    // two owners of one buffer would free it twice.
    try testing.expect(
        schema.strings.label(&tree.next_state.nodes.get(id).?.data.properties) == null,
    );
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

test "processChanges commits what it is handed a second time" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    const child: NodeId = .{ .value = 2 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var recorder: Recorder = .{ .tree = &tree };
    const slots = recorder.slots();
    try tree.updateAndProcessChanges(try addChildUpdate(gpa, root, child), &slots);

    // A second commit over the same change set reports the node again and finds
    // the key already in the committed map, which is the arm that releases the
    // old node instead of leaking it. The leak check at the end of this test is
    // what proves the release happened.
    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    try changes.added_node_ids.put(gpa, FullNodeId.init(child, .init(0)), {});
    try tree.processChanges(changes, &slots);
    try testing.expectEqual(@as(usize, 2), recorder.added);
    try testing.expectEqual(@as(usize, 2), tree.stateOf().nodes.count());
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

test "processChanges reports error.NodeMissingFromState rather than reading a missing node" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    var changes: InternalChanges = .{};
    defer changes.deinit(gpa);
    // The set names a node neither state holds, which I1 to I4 rule out after a
    // successful update. Upstream's `.unwrap()` at `tree.rs:643` aborts there,
    // and rule C8 bans the `unreachable` that would replace the tag, so the
    // call reports it and commits nothing.
    try changes.added_node_ids.put(gpa, FullNodeId.init(.{ .value = 77 }, .init(0)), {});
    var context: usize = 0;
    try testing.expectError(
        error.NodeMissingFromState,
        tree.processChanges(changes, &silentSlots(&context)),
    );
}

test "the info comparison is by bytes and not by address" {
    const gpa = testing.allocator;
    const root: NodeId = .{ .value = 1 };
    var tree = try Tree.init(gpa, try rootUpdate(gpa, root, root), true);
    defer tree.deinit();

    // Two buffers with equal text and different addresses. An address comparison
    // would call them different and copy the working one over the committed
    // one; a byte comparison leaves the committed bytes where they were, which
    // is what the pointer identity below shows. Both copies are freed by the
    // tree teardown, so neither is a leak either way.
    var working_storage = "toolkit-one".*;
    tree.state.info.toolkit_name = "toolkit-one";
    tree.next_state.info.toolkit_name = working_storage[0..];

    var context: usize = 0;
    try tree.processChanges(.{}, &silentSlots(&context));

    try testing.expectEqualStrings("toolkit-one", tree.stateOf().info.toolkit_name.?);
    try testing.expect(tree.stateOf().info.toolkit_name.?.ptr == @as([*]const u8, "toolkit-one"));
}
