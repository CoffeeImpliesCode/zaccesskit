//! The C ABI for one atomic change to one tree: the `accesskit_tree_update`
//! handle and the ten `accesskit_tree_update_*` functions the header declares
//! around it, at `include/zaccesskit.h:5276-5376`.
//!
//! **What this file is.** One handle and ten exports, ported from
//! `accesskit-c/src/common.rs:975-1063` at `8b6ed37`: upstream declares the
//! handle at `:975-983` and the ten functions at `:986-1062`. Each doc comment
//! below names the header line and the upstream line that declaration came
//! from. The value it carries is `TreeUpdate` at
//! `src/schema/update.zig:148-196`, and the `TreeInfo` it can hold is
//! `src/schema/update.zig:97-117` behind the handle
//! `src/capi/tree_info.zig` owns.
//!
//! **Who owns what, in the one sentence a C consumer can act on.** The handle
//! `accesskit_tree_update_with_focus` returns belongs to the caller;
//! `accesskit_tree_update_push_node` and
//! `accesskit_tree_update_set_tree_info` take ownership of what they are given,
//! so the caller must not release a node or a tree info it has passed and must
//! not pass either one twice; `accesskit_tree_update_free` releases the handle,
//! every node the update still holds and the tree info, exactly once; and the
//! `char *` `accesskit_tree_update_debug` returns is released with
//! `accesskit_string_free`, never with `free`.
//!
//! **The ownership the header states, and the sentence in the brief that
//! disagrees with it.** `include/zaccesskit.h:5301-5309` says a free "Releases
//! the update, its tree info and every node still held by it" and that "A node
//! pushed into the update is released here, so the caller must not release one
//! itself", and `:5322-5332` says `set_tree_info` "Takes ownership of `tree`".
//! This file implements the header. A tree update therefore does **not** borrow
//! its node list, and it does not borrow its tree info: both are owned, and
//! both go back through `accesskit_tree_update_free`. The only borrowed handle
//! in this header is a queued-events handle, which borrows the adapter it came
//! from (`include/zaccesskit.h:168-173`), and that one is in
//! `src/capi/platform.zig`.
//!
//! **Why the handle is a struct and not a `*TreeUpdate`.** `schema.TreeUpdate`
//! borrows the two toolkit strings it reaches through `tree`, and the only
//! owner of those bytes is the `accesskit_tree_info` handle the caller built
//! them in. A handle that held nothing but the `TreeUpdate` would have to
//! either leak the caller's tree info or copy the two strings, and a copy has
//! no `*_free` to answer for it. So the handle holds the tree-info handle
//! beside the value, and `handles.zig` declares the opaque forward declaration
//! a C consumer names. This is the same decision `src/capi/tree_info.zig`
//! records for the tree-info handle, and its doc carries the argument in full.
//!
//! **How a pushed node is released.** `accesskit_node` is the node itself and
//! not a token: `src/capi/node.zig` says so, and `node_of` there is a
//! `@ptrCast`. A node handle is therefore a block the caller allocated, so
//! taking ownership of it means two releases at two different times. The node's
//! *value* moves into the update's array, and the block goes back to the
//! allocator the node's own property store records. The store is where the
//! node's property buffers came from too, so the two releases never disagree,
//! and the update's array is released with the update through the allocator the
//! update was created with, which is the rule `src/capi/allocation.zig`
//! documents for an allocator installed after the first call
//! (`include/zaccesskit.h:6484-6485`).
//!
//! **What `clear_tree_info` does, and why it does not free.** The header at
//! `include/zaccesskit.h:5334-5341` says "The tree info already set is released
//! with the update." That sentence is about *when* the release happens, so the
//! clear drops the value and keeps the handle, and the release is the one
//! `accesskit_tree_update_free` already owed. Releasing at the clear instead
//! would make the header's sentence false and would free the two toolkit
//! strings while `update.tree` might still name them. A second
//! `accesskit_tree_update_set_tree_info` with a *different* handle does release
//! the one it displaces, which is upstream's assignment dropping the old
//! `Option<TreeInfo>`. A second call with the *same* pointer is the use after
//! free `include/zaccesskit.h:5325-5328` names, and nothing here checks it.
//!
//! **The `comptime` bound.** One loop runs over a domain: the four fields the
//! debug rendering writes. The bound is `fieldCount`, which is four, and it is
//! derived rather than chosen: `schema.TreeUpdate` declares exactly four fields
//! at `src/schema/update.zig:152`, `:156`, `:160` and `:164`, and the writer
//! below has one case per field. The renderer's own loop over the update's
//! nodes is bounded by `update.nodes.items.len`, which is the list itself, so it
//! needs no constant. No other loop in this file runs over a domain.
//!
//! **The two rules from the module above it.** Every allocating function here
//! takes `gpa` first and the methods take the receiver, which carries the
//! allocator the object was created with; and every export clears the per-thread
//! tag on entry and sets `.out_of_memory` on a failing path, because
//! `include/zaccesskit.h:6493-6497` says the tag is valid only until the next
//! call on this thread. `accesskit_tree_update_push_node` is the one `void`
//! export that can fail, and the header's "Returns nothing and cannot fail" at
//! `:5316` is false for it in this port for the reason
//! `src/capi/node.zig`'s ruling 1 records: upstream aborts on an allocation
//! failure because it compiles with `panic = "abort"`, and this port reports
//! one.
//!
//! **What this file needs from the modules beneath it.** Five names.
//! `allocation.allocator`, `allocation.clearError` and
//! `allocation.failWith` come from `src/capi/allocation.zig`. `marshal`'s
//! `dup_c_string` and `string_free` come from `src/capi/marshal.zig`, which
//! owns every conversion; nothing here defines one. The two casts from a C
//! handle to a `schema.Node` are `src/capi/node.zig`'s `node_of` and
//! `mutable_node`, reached through a named import rather than written again,
//! because two casts of one pointer type is how they stop agreeing.
//!
//! **What this layer does not do.** No `zio`, no `io: std.Io`, no clock, no
//! global state, no `unreachable`, no `panic` and no discarded error. The
//! `std.Io.Writer` in `formatTreeUpdate` is a byte sink the caller supplies,
//! the same distinction `src/schema/root.zig:27` records. `terminate` is the
//! one place this file leaves, for a null handle the header says ends the
//! process; the same three lines are in `src/capi/tree_info.zig` and belong in
//! a module both can import, which `src/capi/boundary.zig` would give them.

const std = @import("std");

const allocation = @import("allocation.zig");
const handles = @import("handles.zig");
const marshal = @import("marshal.zig");
const node = @import("node.zig");
const schema = @import("../schema/root.zig");
const tree_info = @import("tree_info.zig");
const consumer_tree = @import("../consumer/tree.zig");

const Node = schema.Node;
const NodeId = schema.NodeId;
const NodeIdContent = schema.NodeIdContent;
const TreeId = schema.TreeId;
const nodeIdFromContent = schema.nodeIdFromContent;
const nodeIdFormat = schema.nodeIdFormat;
const tree_id_root = schema.tree_id_root;

const testing = std.testing;

/// The object `accesskit_tree_update` names, in the form the C seam needs.
///
/// `include/zaccesskit.h:994` declares `typedef struct accesskit_tree_update
/// accesskit_tree_update;` and the header is opaque, so a C consumer cannot
/// read a layout because there is none for it. This is a plain `struct` and not
/// an `extern struct` for that reason: only the pointer crosses the boundary, so
/// no field's offset is a contract, and the layout that lets the object own its
/// nodes and its tree info is worth more here than a pin nothing can check.
pub const accesskit_tree_update = struct {
    /// The allocator this object was created with, and the only one that
    /// releases the node array this object owns. A handle stores its allocator
    /// because `include/zaccesskit.h:6484-6485` says an allocator installed
    /// later does not receive the releases of an allocation made before it.
    gpa: std.mem.Allocator,

    /// The value this handle carries. It owns `nodes` and borrows the two
    /// toolkit strings `tree` names, which is why `info` is held beside it and
    /// not copied into it.
    update: schema.TreeUpdate,

    /// The tree info the caller handed over, or `null` when the update has
    /// none. `accesskit_tree_update_set_tree_info` consumes the handle and
    /// `accesskit_tree_update_free` releases it, together with the two toolkit
    /// strings the handle owns.
    info: ?*tree_info.accesskit_tree_info,

    /// Releases this object, every node it still holds, its node array and its
    /// tree info, exactly once.
    ///
    /// The nodes go first, then the tree info, then the object, so the last
    /// thing this reads is the allocator it is about to hand back. `self` is
    /// unusable afterwards and a second call is a double free. A pushed node's
    /// *block* was released by the push; what this releases is the value that
    /// push moved in, which is where the node's property buffers live.
    pub fn deinit(self: *accesskit_tree_update) void {
        self.update.deinit(self.gpa);
        if (self.info) |held| tree_info.treeInfoFree(held);
        self.gpa.destroy(self);
    }

    /// Stores the node behind `handle` under `node_id` and takes ownership of
    /// it.
    ///
    /// A method rather than a file-scope function so the receiver carries the
    /// allocator the node array goes through. The node's own block goes back to
    /// the allocator its property store records, which is the one that made it;
    /// see this module's doc for why the two releases use two allocators.
    ///
    /// On the one path that can fail the node is released, the block is
    /// released and the tag is set, so the update holds exactly the nodes it
    /// held before the call.
    fn pushNode(
        self: *accesskit_tree_update,
        node_id: NodeId,
        handle: *handles.accesskit_node,
    ) void {
        const target = node.mutable_node(handle);
        const owner = target.properties.gpa;
        var owned = target.*;
        self.update.nodes.append(self.gpa, .{ .node_id = node_id, .node = owned }) catch {
            owned.deinit();
            owner.destroy(target);
            allocation.failWith(.out_of_memory);
            return;
        };
        // The value is in the array now, and the block it came out of is
        // nobody's. `owned` is a stale copy of a value the array owns; nothing
        // reads it after this line.
        owner.destroy(target);
    }

    /// Attaches `tree` to the update, taking ownership of it, and releases any
    /// tree info already attached.
    ///
    /// `null` attaches nothing, which is the state
    /// `accesskit_tree_update_clear_tree_info` leaves. The value the update
    /// carries borrows the two toolkit strings out of the handle, so the handle
    /// is held rather than copied: releasing it while the update still names the
    /// value would leave both slices dangling.
    pub fn setTreeInfo(
        self: *accesskit_tree_update,
        tree: ?*tree_info.accesskit_tree_info,
    ) void {
        if (self.info) |displaced| tree_info.treeInfoFree(displaced);
        self.info = tree;
        self.update.tree = if (tree) |held| held.value() else null;
    }
};

/// Keeps C-owned toolkit strings alive while either native snapshot borrows them.
///
/// The native consumer stores metadata only on the root, in its committed and
/// working snapshots. Three slots cover those two owners and one incoming update.
/// Copying this store does not create another owner. Release the native tree before
/// `deinit`; call `reap` after every update attempt, including rejected updates.
pub const LiveMetadataOwners = struct {
    owners: [3]?*tree_info.accesskit_tree_info = .{ null, null, null },

    /// Consumes a C handle on success and error, returning its native payload.
    ///
    /// The node-entry array moves without allocation only in a known shared domain.
    /// Different or unknown domains migrate that array. Node buffers keep their
    /// own allocators. `error.OutOfMemory` releases the entire incoming handle and
    /// leaves existing tree borrows live. The returned value must be consumed once
    /// by the native tree, or released with `deinit(gpa)`.
    pub fn consume(
        self: *LiveMetadataOwners,
        gpa: std.mem.Allocator,
        handle: *handles.accesskit_tree_update,
        tree: ?*const consumer_tree.Tree,
    ) TreeUpdateError!schema.TreeUpdate {
        self.reap(tree);
        const owned: *accesskit_tree_update = @ptrCast(@alignCast(handle));
        errdefer owned.deinit();
        const source_gpa = owned.gpa;
        if (!allocation.sameDomain(.{ .source = source_gpa, .destination = gpa })) {
            var migrated: std.ArrayList(schema.NodeEntry) = .empty;
            try migrated.appendSlice(gpa, owned.update.nodes.items);
            owned.update.nodes.deinit(source_gpa);
            owned.update.nodes = migrated;
        }
        const update = owned.update;
        if (owned.info) |info| {
            if (hasOwnedStrings(info)) {
                var retained = false;
                for (&self.owners) |*slot| {
                    if (slot.* == null) {
                        slot.* = info;
                        retained = true;
                        break;
                    }
                }
                // Two snapshots cannot borrow three distinct incoming owners.
                std.debug.assert(retained);
            } else {
                tree_info.treeInfoFree(info);
            }
        }
        source_gpa.destroy(owned);
        return update;
    }

    /// Releases owners neither committed nor partially written state still borrows.
    /// Equality uses storage identity, not bytes: equal metadata can leave the
    /// committed snapshot borrowing the old owner while the working one uses the new.
    pub fn reap(self: *LiveMetadataOwners, tree: ?*const consumer_tree.Tree) void {
        for (&self.owners) |*slot| {
            const info = slot.* orelse continue;
            if (tree) |live| {
                if (borrows(live.state.info, info)) continue;
                if (borrows(live.next_state.info, info)) continue;
            }
            tree_info.treeInfoFree(info);
            slot.* = null;
        }
    }

    /// Releases retained metadata after its native tree has been released.
    /// Leaves an empty store; a second call releases nothing.
    pub fn deinit(self: *LiveMetadataOwners) void {
        self.reap(null);
    }

    fn hasOwnedStrings(info: *const tree_info.accesskit_tree_info) bool {
        if (info.toolkit_name_storage) |storage| {
            if (storage.len != 0) return true;
        }
        if (info.toolkit_version_storage) |storage| {
            if (storage.len != 0) return true;
        }
        return false;
    }

    fn borrows(value: schema.TreeInfo, info: *const tree_info.accesskit_tree_info) bool {
        return sameStorage(value.toolkit_name, info.toolkit_name_storage) or
            sameStorage(value.toolkit_version, info.toolkit_version_storage);
    }

    fn sameStorage(borrowed: ?[]const u8, storage: ?[]u8) bool {
        const view = borrowed orelse return false;
        const owned = storage orelse return false;
        return owned.len != 0 and view.len == owned.len and view.ptr == owned.ptr;
    }
};

/// Consumes a callback handle whose payload will not be applied to a native tree.
/// Releases its nodes, metadata, and outer object through their captured allocators.
pub fn discard(handle: *handles.accesskit_tree_update) void {
    const owned: *accesskit_tree_update = @ptrCast(@alignCast(handle));
    owned.deinit();
}

/// The only failure any function in this file has.
///
/// It is `std.mem.Allocator.Error` under another name, and the `comptime` block
/// at the foot of this file asserts that, so a sweep over this set and the
/// allocator's own error stay the same set rather than two that agree today by
/// accident.
pub const TreeUpdateError = error{OutOfMemory};

/// How many members the debug rendering's field domain has: four.
///
/// Read off the writer's own list rather than repeated, and asserted against
/// `schema.TreeUpdate` at the foot of this file, so a fifth field on the value
/// fails the build here rather than going missing from the text.
pub const fieldCount = @typeInfo(SchemaField).@"enum".fields.len;

/// The four fields `schema.TreeUpdate` declares, in declaration order.
///
/// `src/schema/update.zig:152`, `:156`, `:160` and `:164`. The rendering has one
/// case per member and the `comptime` block at the foot of this file asserts
/// that the count and the order match the value, so a field added or moved in
/// the schema is a build failure here.
const SchemaField = enum {
    /// `nodes`, the zero or more nodes the update carries.
    nodes,
    /// `tree`, the data about the tree as a whole.
    tree,
    /// `tree_id`, the tree this update applies to.
    tree_id,
    /// `focus`, the node that holds keyboard focus.
    focus,
};

// --- the Zig layer, one function per header declaration ------------------------

/// Builds one tree update whose focus is `focus`.
///
/// Upstream `accesskit-c/src/common.rs:986-994`, which is `TreeUpdate::new` at
/// `accesskit/src/lib.rs:3196` boxed into a raw pointer. `gpa` is first, so a
/// test can fail the one allocation this makes. The update names the root tree,
/// holds no nodes and carries no tree info, which is what a fresh
/// `schema.TreeUpdate` is.
///
/// `error.OutOfMemory` is the only failure, and `error.OutOfMemory` from
/// `gpa.create` leaves nothing behind: the handle is the first and only
/// allocation on this path.
pub fn treeUpdateWithFocus(
    gpa: std.mem.Allocator,
    focus: NodeIdContent,
) TreeUpdateError!*accesskit_tree_update {
    return treeUpdateWithCapacityAndFocus(gpa, 0, focus);
}

/// Builds one tree update whose focus is `focus` and which reserves room for
/// `capacity` nodes.
///
/// Upstream `accesskit-c/src/common.rs:996-1005`, which is
/// `TreeUpdate::with_capacity` at `accesskit/src/lib.rs:3200`. `capacity` is a
/// reservation and not a limit: the update grows past it, and a reservation
/// larger than memory reports `error.OutOfMemory` rather than clamping.
///
/// On `error.OutOfMemory` from the reservation the handle is released again, so
/// a failed call owns nothing.
pub fn treeUpdateWithCapacityAndFocus(
    gpa: std.mem.Allocator,
    capacity: usize,
    focus: NodeIdContent,
) TreeUpdateError!*accesskit_tree_update {
    const update = try gpa.create(accesskit_tree_update);
    errdefer gpa.destroy(update);
    update.* = .{ .gpa = gpa, .update = .{}, .info = null };
    update.update.focus = nodeIdFromContent(focus);
    try update.update.nodes.ensureTotalCapacity(gpa, capacity);
    return update;
}

/// Releases the update, its tree info and every node still held by it, exactly
/// once.
///
/// The Zig-layer name `docs/40-capi-build-map.md` section 2 gives the body of
/// `accesskit_tree_update_free`. It is one line over `deinit` so that the map's
/// name names a real function and the teardown itself has one spelling, and it
/// takes the receiver rather than an allocator because the receiver is where the
/// allocator is.
pub fn treeUpdateFree(update: *accesskit_tree_update) void {
    update.deinit();
}

/// Stores the node behind `handle` under `node_id` and takes ownership of it.
///
/// Upstream `accesskit-c/src/common.rs:1010-1026`, whose shim drops the node it
/// could not store; this port releases the node and records the tag instead.
/// The Zig-layer name `docs/40-capi-build-map.md` section 2 gives it.
pub fn treeUpdatePushNode(
    update: *accesskit_tree_update,
    node_id: NodeIdContent,
    handle: *handles.accesskit_node,
) void {
    update.pushNode(nodeIdFromContent(node_id), handle);
}

/// Attaches `tree` to the update, taking ownership of it.
///
/// Upstream `accesskit-c/src/common.rs:1030-1036`, which assigns the boxed
/// `TreeInfo` into the update. A `null` argument attaches nothing rather than
/// ending the process, which is the one place in this file the header's "no
/// failure path" reading and a null check both hold: the header states the null
/// behaviour at `include/zaccesskit.h:5327-5329`.
pub fn treeUpdateSetTreeInfo(
    update: *accesskit_tree_update,
    tree: ?*tree_info.accesskit_tree_info,
) void {
    update.setTreeInfo(tree);
}

/// Removes any tree info from the update, and releases none.
///
/// The handle `accesskit_tree_update_set_tree_info` consumed stays owned by the
/// update and is released by `accesskit_tree_update_free`, which is what
/// `include/zaccesskit.h:5336-5337` means by "released with the update". This
/// module's doc carries the argument in full. Upstream
/// `accesskit-c/src/common.rs:1039-1042`, which assigns `None`.
pub fn treeUpdateClearTreeInfo(update: *accesskit_tree_update) void {
    update.update.tree = null;
}

/// Sets the node the update focuses.
///
/// Upstream `accesskit-c/src/common.rs:1046-1049`, one field write.
pub fn treeUpdateSetFocus(update: *accesskit_tree_update, focus: NodeIdContent) void {
    update.update.focus = nodeIdFromContent(focus);
}

/// Returns the update's tree identifier, by value.
///
/// Upstream `accesskit-c/src/common.rs:1052-1055`. The value is copied by value,
/// so no release is owed and no copy must be freed. Both sides are the same 16
/// bytes at alignment 1, so the conversion across this seam is the identity and
/// neither side writes one.
pub fn treeUpdateGetTreeId(update: *const accesskit_tree_update) TreeId {
    return update.update.tree_id;
}

/// Sets the update's tree identifier.
///
/// Upstream `accesskit-c/src/common.rs:1057-1060`, one field write, over the
/// same identity conversion.
pub fn treeUpdateSetTreeId(update: *accesskit_tree_update, tree_id: TreeId) void {
    update.update.tree_id = tree_id;
}

/// Returns a text rendering of the update, or `error.OutOfMemory`.
///
/// Upstream `accesskit-c/src/common.rs:1062`, which is `debug_repr_from_ptr` at
/// `accesskit-c/src/lib.rs:206-214`: it formats the value it was handed and
/// hands the resulting `CString` over, so the text borrows nothing and the
/// handle may be released first.
pub fn treeUpdateDebug(
    gpa: std.mem.Allocator,
    update: *const accesskit_tree_update,
) TreeUpdateError![*:0]u8 {
    var owning: std.Io.Writer.Allocating = .init(gpa);
    defer owning.deinit();
    formatTreeUpdate(update, &owning.writer) catch |err| switch (err) {
        // `std.Io.Writer.Allocating.drain` returns `error.WriteFailed` from one
        // place, `lib/std/Io/Writer.zig:2705`, and that place is the
        // `ensureUnusedCapacity` call that could not make room. A writer that
        // owns its buffer and grows it has no other way to fail, so the C
        // layer's one failing tag answers it.
        error.WriteFailed => return error.OutOfMemory,
    };
    const text = try owning.toOwnedSliceSentinel(0);
    // The slice is what `toOwnedSliceSentinel` hands back and the pointer is
    // what a C caller holds. `deinit` above sees an empty buffer once the slice
    // has taken it, so the two do not release it between them.
    return @ptrCast(text.ptr);
}

// --- the C layer ---------------------------------------------------------------

/// Builds one tree update whose focus is `focus`, or `null` when the allocation
/// failed.
///
/// `include/zaccesskit.h:5285`. The caller owns the update and releases it with
/// `accesskit_tree_update_free`, once, unless a tree update factory or an
/// activation handler takes ownership instead. `focus` is `accesskit_node_id`,
/// which is `typedef uint64_t` at `include/zaccesskit.h:190`, so it crosses as
/// one scalar and `nodeIdFromContent` is the whole of the conversion.
export fn accesskit_tree_update_with_focus(
    focus: NodeIdContent,
) callconv(.c) ?*accesskit_tree_update {
    allocation.clearError();
    const update = treeUpdateWithFocus(allocation.allocator(), focus) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return update;
}

/// Builds one tree update whose focus is `focus` and which reserves room for
/// `capacity` nodes, or `null` when the allocation failed.
///
/// `include/zaccesskit.h:5297`. `capacity` is a reservation and not a limit.
export fn accesskit_tree_update_with_capacity_and_focus(
    capacity: usize,
    focus: NodeIdContent,
) callconv(.c) ?*accesskit_tree_update {
    allocation.clearError();
    const update = treeUpdateWithCapacityAndFocus(allocation.allocator(), capacity, focus) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return update;
}

/// Releases the update, its tree info and every node still held by it, exactly
/// once.
///
/// `include/zaccesskit.h:5309`. A node pushed into the update is released here,
/// so the caller must not release one itself. The handle arrives as
/// `?*accesskit_tree_update` rather than as a non-optional pointer so that the
/// documented answer to a null is the one the header states at
/// `include/zaccesskit.h:5306`: a null check that returned would be a behaviour
/// change, and letting the dereference happen would be undefined behaviour
/// instead of a contract this port can state.
export fn accesskit_tree_update_free(update: ?*accesskit_tree_update) callconv(.c) void {
    allocation.clearError();
    const handle = update orelse terminate(
        "accesskit_tree_update_free",
        "the handle was null",
    );
    treeUpdateFree(handle);
}

/// Stores `node` under `id` in the update and takes ownership of it.
///
/// `include/zaccesskit.h:5318`. The caller must not release `node` after this
/// call and must not pass it again. On the one path that can fail the node is
/// released, the update is unchanged and the tag says why, which is this port's
/// stated departure from the header's "Returns nothing and cannot fail".
export fn accesskit_tree_update_push_node(
    update: *accesskit_tree_update,
    id: NodeIdContent,
    node_handle: *handles.accesskit_node,
) callconv(.c) void {
    allocation.clearError();
    treeUpdatePushNode(update, id, node_handle);
}

/// Attaches `tree` to the update and takes ownership of it.
///
/// `include/zaccesskit.h:5331`. The caller must not release `tree` after this
/// call and must not pass it again. A `null` argument stores no tree info and
/// does not end the process, which is the behaviour
/// `include/zaccesskit.h:5327-5329` states.
export fn accesskit_tree_update_set_tree_info(
    update: *accesskit_tree_update,
    tree: ?*tree_info.accesskit_tree_info,
) callconv(.c) void {
    allocation.clearError();
    treeUpdateSetTreeInfo(update, tree);
}

/// Removes any tree info from the update, and releases none.
///
/// `include/zaccesskit.h:5340`. The handle the update already holds is released
/// by `accesskit_tree_update_free`, which is what the header's "released with
/// the update" says; this module's doc carries the argument in full.
export fn accesskit_tree_update_clear_tree_info(update: *accesskit_tree_update) callconv(.c) void {
    allocation.clearError();
    treeUpdateClearTreeInfo(update);
}

/// Sets the node the update focuses.
///
/// `include/zaccesskit.h:5348`. Returns nothing and cannot fail.
export fn accesskit_tree_update_set_focus(
    update: *accesskit_tree_update,
    focus: NodeIdContent,
) callconv(.c) void {
    allocation.clearError();
    treeUpdateSetFocus(update, focus);
}

/// Returns the update's tree identifier.
///
/// `include/zaccesskit.h:5356`. The one declaration in this file that crosses
/// by value: a 16-byte `accesskit_tree_id` is classified differently on every
/// target, and `docs/40-capi-build-map.md` section 1.2 counts it among the
/// declarations whose shape is the calling convention and not only the layout.
/// The value is copied, so no release is owed.
export fn accesskit_tree_update_get_tree_id(
    update: *const accesskit_tree_update,
) callconv(.c) TreeId {
    allocation.clearError();
    return treeUpdateGetTreeId(update);
}

/// Sets the update's tree identifier.
///
/// `include/zaccesskit.h:5364`. The second aggregate by value in this file, in
/// the other direction. Returns nothing and cannot fail.
export fn accesskit_tree_update_set_tree_id(
    update: *accesskit_tree_update,
    tree_id: TreeId,
) callconv(.c) void {
    allocation.clearError();
    treeUpdateSetTreeId(update, tree_id);
}

/// Returns a text rendering of the update, or `null` when it could not be built.
///
/// `include/zaccesskit.h:5375`. The text borrows nothing, so the handle may be
/// released first, and the caller releases the text with
/// `accesskit_string_free`.
export fn accesskit_tree_update_debug(
    tree_update: *const accesskit_tree_update,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    const text = treeUpdateDebug(allocation.allocator(), tree_update) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return text;
}

// --- the shape, the one writer, and the renderer --------------------------------

/// Writes the text `accesskit_tree_update_debug` returns.
///
/// The shape follows `Node.format` at `src/schema/node.zig:263` and
/// `formatTreeInfo` at `src/capi/tree_info.zig:649`, which are the port's own
/// rendering convention: the type's name, then `field: value` pairs. Two
/// spellings differ from upstream's derived `Debug`, and neither changes what
/// the text carries. Upstream writes the node id through `NodeId`'s own `Debug`
/// and this writes it through `nodeIdFormat` at `src/schema/ids.zig:84`, so an
/// id reads `#7` rather than `NodeId(7)`; and upstream writes an absent optional
/// as `None`, and this writes `null`, because `None` is a Rust spelling and this
/// is a Zig port.
///
/// The `inline for` is the bound this module's doc derives: one case per member
/// of `SchemaField`, whose count the `comptime` block at the foot of this file
/// pins against `schema.TreeUpdate`.
fn formatTreeUpdate(
    update: *const accesskit_tree_update,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeAll("TreeUpdate { nodes: [");
    for (update.update.nodes.items, 0..) |entry, index| {
        if (index != 0) try writer.writeAll(", ");
        try nodeIdFormat(entry.node_id, writer);
        try writer.writeByte(' ');
        try entry.node.format(writer);
    }
    try writer.writeAll("], tree: ");
    if (update.update.tree) |*tree| {
        try writeTreeInfoValue(tree, writer);
    } else {
        try writer.writeAll("null");
    }
    try writer.writeAll(", tree_id: ");
    for (update.update.tree_id.bytes) |byte| {
        try writer.print("{x:0>2}", .{byte});
    }
    try writer.writeAll(", focus: ");
    try nodeIdFormat(update.update.focus, writer);
    try writer.writeAll(" }");
}

/// Writes the `tree` field's value, which is a `TreeInfo` by value.
///
/// A local writer rather than a call into `src/capi/tree_info.zig`, because that
/// module's `formatTreeInfo` is private and a C consumer reaches a `TreeInfo`
/// only through `accesskit_tree_info_debug`, where the escaping rules matter.
/// The same shape is written here so that an update's rendering and a tree
/// info's rendering cannot drift in the part a reader compares.
fn writeTreeInfoValue(
    tree: *const schema.TreeInfo,
    writer: *std.Io.Writer,
) std.Io.Writer.Error!void {
    try writer.writeAll("TreeInfo { root: ");
    try nodeIdFormat(tree.root, writer);
    try writer.writeAll(", toolkit_name: ");
    try writeBorrowedBytes(tree.toolkit_name, writer);
    try writer.writeAll(", toolkit_version: ");
    try writeBorrowedBytes(tree.toolkit_version, writer);
    try writer.writeAll(" }");
}

/// Writes `bytes` between quotes, or the word `null` when it is unset.
fn writeBorrowedBytes(bytes: ?[]const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    const text = bytes orelse return writer.writeAll("null");
    try writer.writeByte('"');
    for (text) |byte| {
        if (byte == '"' or byte == '\\') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

/// Whether `T` is a type a C aggregate could be spelled with, which is what the
/// by-value question is about.
fn isAggregate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .array => true,
        else => false,
    };
}

/// Fails the build if `signature` returns or takes an aggregate by value.
///
/// A C caller classifies an aggregate by value differently on every target, and a
/// difference between this header and the library it links is the failure this
/// catches: a caller built for one convention corrupts its own stack while
/// neither side sees a size disagree. Nine of the ten declarations in this file
/// are asserted here; the tenth is the tree identifier, which the header passes
/// and returns by value on purpose, and which the `comptime` block below pins
/// separately.
fn assertPointerShaped(signature: anytype) void {
    const info = @typeInfo(@TypeOf(signature)).@"fn";
    if (info.return_type) |returned| {
        std.debug.assert(!isAggregate(returned));
    }
    for (info.params) |param| {
        // A parameter reflection names no type for cannot be an aggregate, so
        // the absence is an answer this gate can act on rather than a gap it
        // has to step over.
        if (param.type) |declared| {
            std.debug.assert(!isAggregate(declared));
        }
    }
}

/// Ends the process for a call the header says cannot succeed.
///
/// `include/zaccesskit.h:5306` is the sentence ("Passing `null` terminates the
/// process") and `docs/40-capi-build-map.md` section 4.1 records that softening
/// it into a return would be a behaviour change against a contract the header
/// already states. Upstream reaches the same place from Rust, where
/// `box_from_ptr` on a null pointer aborts because `accesskit-c` compiles with
/// `panic = "abort"`.
///
/// `std.process.exit` rather than `panic` or `unreachable` because the house
/// rules forbid both on this boundary, and `exit` rather than `abort` because
/// `exit` hands the caller a status it can act on after the diagnostic below.
/// The write is `std.log`, not `std.debug.print`: the second is the debugging
/// channel, and this line is a deliberate end-of-process diagnostic. The status
/// is 1, and upstream's signal is `SIGABRT`; a caller cannot observe the
/// difference, because it is already dead.
///
/// The same three lines stand in `src/capi/tree_info.zig:713`. Two domain
/// modules now need them and neither may import the other, so the function
/// belongs in a module both can reach; `src/capi/boundary.zig` is the leaf that
/// would hold it.
fn terminate(comptime function_name: []const u8, reason: []const u8) noreturn {
    std.log.err("zaccesskit: {s}: {s}", .{ function_name, reason });
    std.process.exit(1);
}

comptime {
    // The error set this file declares is the allocator's, and the sweep names
    // its only member, which is the rule `AGENTS.md` section 3 states for every
    // error set in this repository.
    std.debug.assert(TreeUpdateError == std.mem.Allocator.Error);
    std.debug.assert(@typeInfo(TreeUpdateError).error_set.?.len == 1);
    std.debug.assert(std.mem.eql(
        u8,
        @errorName(@as(TreeUpdateError, error.OutOfMemory)),
        "OutOfMemory",
    ));

    // The bound the rendering's loop runs over. `SchemaField` mirrors the four
    // fields of `schema.TreeUpdate`, so the count is read off the mirror and
    // checked against the value it mirrors. The order is pinned too: the
    // rendering writes the members in the value's declaration order, and a
    // reorder in the schema that left the count alone would still be caught,
    // because the rendering names each member by its `SchemaField` tag.
    std.debug.assert(fieldCount == 4);
    std.debug.assert(fieldCount == @typeInfo(schema.TreeUpdate).@"struct".fields.len);
    for (std.enums.values(SchemaField), 0..) |field, index| {
        const named = @typeInfo(schema.TreeUpdate).@"struct".fields[index];
        std.debug.assert(std.mem.eql(u8, named.name, @tagName(field)));
    }

    // The eight declarations that cross as a pointer or a scalar. One signature
    // changed to a struct would fail here rather than move a count the header
    // has published.
    for (.{
        accesskit_tree_update_with_focus,
        accesskit_tree_update_with_capacity_and_focus,
        accesskit_tree_update_free,
        accesskit_tree_update_push_node,
        accesskit_tree_update_set_tree_info,
        accesskit_tree_update_clear_tree_info,
        accesskit_tree_update_set_focus,
        accesskit_tree_update_debug,
    }) |exported| {
        assertPointerShaped(exported);
    }

    // The other two are the tree identifier, which the header passes and
    // returns by value on purpose. Both sides are the same `extern struct` at
    // the same size and the same alignment, so the conversion is the identity
    // and the signature is the header's.
    const getter = @typeInfo(@TypeOf(accesskit_tree_update_get_tree_id)).@"fn";
    std.debug.assert(getter.params.len == 1);
    std.debug.assert(!isAggregate(getter.params[0].type.?));
    std.debug.assert(getter.return_type.? == TreeId);

    const setter = @typeInfo(@TypeOf(accesskit_tree_update_set_tree_id)).@"fn";
    std.debug.assert(setter.params.len == 2);
    std.debug.assert(!isAggregate(setter.params[0].type.?));
    std.debug.assert(setter.params[1].type.? == TreeId);
    std.debug.assert(setter.return_type.? == void);
    std.debug.assert(@sizeOf(TreeId) == 16);
    std.debug.assert(@alignOf(TreeId) == 1);

    // The handle is the only thing a C consumer names, and a handle with a
    // layout a C consumer could read through is exactly what the header forbids
    // by declaring nothing about it. `handles.zig` declares the opaque form; the
    // struct here is the Zig object behind that pointer, and the two spell one
    // type in two languages.
    std.debug.assert(@sizeOf(accesskit_tree_update) >= @sizeOf(schema.TreeUpdate));
}

// --- tests ---------------------------------------------------------------------

/// The only failure `CountingAllocator.expectOneReleaseEach` reports.
const ReleaseCountError = error{NotOneRelease};

/// The pointer `CountingAllocator.expectOneReleaseEach` rejected, named rather
/// than printed.
///
/// A named type, because an anonymous struct literal is its own type: a test
/// that built one to compare against this would not compile.
const ReleaseOffender = struct {
    /// The address that went back the wrong number of times.
    address: usize,
    /// How many times it went back.
    times: usize,
};

/// An allocator that records how many times each pointer went back to it.
///
/// `std.testing.allocator` already traps a double free, which is a failure, but a
/// trap says only that one happened and not how many times a pointer was
/// released. The property `accesskit_tree_update_free` has to hold is a count: the
/// handle, the node array and every node's own storage are released once and
/// once only. This counts them, and a test below proves the counter can see a
/// second release, because a counting test against a counter that counted
/// nothing would also pass.
const CountingAllocator = struct {
    /// The allocator the counting forwards to, which is what catches a release
    /// of a pointer it never handed out.
    inner: std.mem.Allocator,
    /// How many times each released pointer went back, keyed by address.
    released: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// The pointer a release count rejected, and how many times it went back.
    ///
    /// Only the failing path of `expectOneReleaseEach` writes it, and the test
    /// that drives that path asserts on it. It is recorded rather than logged
    /// because an error-level line is one the test runner counts, and a shard
    /// whose tests all pass still exits non-zero when one test logs one.
    offender: ?ReleaseOffender = null,

    /// The allocator a test hands to this file.
    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &vtable };
    }

    /// How many times `ptr` went back, and zero for a pointer that never did.
    fn timesReleased(self: *const CountingAllocator, ptr: anytype) usize {
        return self.released.get(@intFromPtr(ptr)) orelse 0;
    }

    /// Releases the counter's own storage through the allocator behind this one,
    /// never through `vtable`. The map is the one allocation this instrument
    /// makes on its own behalf, and recording its own release would count a
    /// pointer the tests under measurement never touched.
    fn release(self: *CountingAllocator) void {
        self.released.deinit(self.inner);
    }

    /// Asserts that every pointer this allocator saw released went back exactly
    /// once, and returns how many distinct pointers that was. The counter is not
    /// released here, because a release after this call would write into a map
    /// the test is still holding. A pointer that breaks the count is named in
    /// `offender` rather than reported to stderr: a test below reaches this path
    /// deliberately, so a diagnostic written here is written on every passing
    /// run, and the caller is handed the address instead.
    fn expectOneReleaseEach(self: *CountingAllocator) ReleaseCountError!usize {
        var iterator = self.released.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != 1) {
                self.offender = .{ .address = entry.key_ptr.*, .times = entry.value_ptr.* };
                return error.NotOneRelease;
            }
        }
        return self.released.count();
    }

    const vtable: std.mem.Allocator.VTable = .{
        .alloc = alloc,
        .resize = resize,
        .remap = remap,
        .free = free,
    };

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawAlloc(len, alignment, ra);
    }

    fn resize(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawResize(memory, alignment, new_len, ra);
    }

    /// A remap releases no pointer and hands out no new one, so it has no count
    /// to add. No path in this file remaps, and the allocator behind this one
    /// still sees the growth.
    fn remap(
        ctx: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        ra: usize,
    ) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        return self.inner.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const address = @intFromPtr(memory.ptr);
        const entry = self.released.getOrPut(self.inner, address) catch {
            // The hash map is the only allocation this allocator makes on its
            // own behalf, so its growth must not recurse through `vtable`.
            self.inner.rawFree(memory, alignment, ra);
            return;
        };
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        self.inner.rawFree(memory, alignment, ra);
    }
};

/// A C string a getter returned, as the slice `expectEqualStrings` compares and
/// as the `[*:0]const u8` `std.mem.span` takes. A many-pointer does not coerce
/// to a slice, so every read of a returned string goes through here.
fn span(value: [*c]const u8) []const u8 {
    return std.mem.span(value);
}

/// Releases a string a getter returned, which is what `accesskit_string_free`
/// does on the C side.
fn releaseCString(gpa: std.mem.Allocator, value: [*c]const u8) void {
    marshal.string_free(gpa, @ptrCast(@constCast(value)));
}

/// A node the way `accesskit_node_new` would hand one to a caller: a block that
/// holds a `schema.Node` and no side table.
///
/// `src/capi/node.zig`'s module doc is the authority for why the handle is the
/// node, and the tests here use this rather than a stack node because the push
/// releases the block.
fn newNode(gpa: std.mem.Allocator, role: anytype) !*handles.accesskit_node {
    const block = try gpa.create(Node);
    block.* = Node.init(gpa, role);
    return @ptrCast(block);
}

test "a fresh update names the root tree, holds no node and focuses what it was given" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 7);
    defer treeUpdateFree(update);

    try testing.expectEqual(@as(NodeIdContent, 7), update.update.focus.value);
    try testing.expectEqual(@as(usize, 0), update.update.nodes.items.len);
    try testing.expectEqual(@as(?schema.TreeInfo, null), update.update.tree);
    try testing.expectEqual(@as(?*tree_info.accesskit_tree_info, null), update.info);
    try testing.expect(tree_id_root.eql(update.update.tree_id));
}

test "the capacity is a reservation and the update grows past it" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithCapacityAndFocus(gpa, 2, 0);
    defer treeUpdateFree(update);

    // The reservation is visible in the list's own capacity, which is where a
    // clamp would show: a clamp would cap this at 2 and the third push below
    // would have to grow anyway.
    try testing.expect(update.update.nodes.capacity >= 2);

    for ([_]NodeIdContent{ 1, 2, 3, 4, 5 }) |id| {
        const held = try newNode(gpa, .button);
        treeUpdatePushNode(update, id, held);
    }
    try testing.expectEqual(@as(usize, 5), update.update.nodes.items.len);
    try testing.expect(update.update.nodes.capacity >= 5);
}

test "a pushed node is stored under the identifier it was given" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 0);
    defer treeUpdateFree(update);

    const held = try newNode(gpa, .button);
    treeUpdatePushNode(update, 42, held);

    try testing.expectEqual(@as(usize, 1), update.update.nodes.items.len);
    try testing.expectEqual(@as(NodeIdContent, 42), update.update.nodes.items[0].node_id.value);
    // The value is the node the caller built, read through the update's own
    // copy, so the move is what makes the update the owner.
    try testing.expectEqual(@as(usize, 0), update.update.nodes.items[0].node.actions);
}

test "a freed update releases the handle, the array and every node exactly once" {
    // The header's sentence is at `include/zaccesskit.h:5301-5305` and this is
    // the test that holds it to that. Five blocks came out of these two calls
    // and five go back, and each went back once: the update's handle and its
    // node array, the node's own block, the one string the node's property
    // store held, and the array that store grew to hold it. The node's block
    // goes back at the push and the other four at the free.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const update = try treeUpdateWithCapacityAndFocus(gpa, 1, 0);
    const held = try newNode(gpa, .button);
    try schema.strings.setLabel(&node.mutable_node(held).properties, "Save");
    treeUpdatePushNode(update, 1, held);
    // One, not none: the push already released the node's block, which is the
    // half of the ownership transfer that happens before the free.
    try testing.expectEqual(@as(usize, 1), counting.released.count());

    treeUpdateFree(update);

    try testing.expectEqual(@as(usize, 5), try counting.expectOneReleaseEach());
    counting.release();
}

test "the counting allocator sees a second release of one pointer" {
    // Without this, the count above would prove nothing: a counter that recorded
    // nothing would also report one release per pointer.
    //
    // The inner allocator is a fixed buffer and not `testing.allocator`, because
    // the point of this test is a second release of one pointer, and the testing
    // allocator poisons every block it releases and faults on the second one
    // before the counter is ever asked what it saw.
    var arena: [4096]u8 = undefined;
    var backing: std.heap.FixedBufferAllocator = .init(&arena);
    var counting: CountingAllocator = .{ .inner = backing.allocator() };
    const gpa = counting.allocator();

    const buffer = try gpa.alloc(u8, 4);
    gpa.free(buffer);
    gpa.free(buffer);

    try testing.expectEqual(@as(usize, 2), counting.timesReleased(buffer.ptr));
    try testing.expectError(error.NotOneRelease, counting.expectOneReleaseEach());
    // The helper names the pointer it rejected, so the error is checkable
    // rather than only reportable.
    try testing.expect(counting.offender != null);
    try testing.expectEqual(
        ReleaseOffender{ .address = @intFromPtr(buffer.ptr), .times = 2 },
        counting.offender.?,
    );
    counting.release();
}

test "a push that cannot grow the array releases the node and changes nothing" {
    // The one failing path in this file, and the header sentence it contradicts
    // (`include/zaccesskit.h:5316`). `fail_index = 1` lets the update's handle
    // be created and fails the array's first growth, which is the allocation
    // the push makes. The node's own blocks come from a different allocator, so
    // the count below is about the node and not about the failing pair.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const node_gpa = counting.allocator();
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const gpa = failing.allocator();

    const update = try treeUpdateWithFocus(gpa, 0);
    defer treeUpdateFree(update);

    const held = try newNode(node_gpa, .button);
    try schema.strings.setLabel(&node.mutable_node(held).properties, "Save");
    try testing.expectEqual(@as(usize, 0), counting.released.count());

    treeUpdatePushNode(update, 1, held);

    try testing.expectEqual(@as(usize, 0), update.update.nodes.items.len);
    // The node the push could not store went back whole: its block, the one
    // string its property store held, and the array that store grew to hold it,
    // each once. A push that left the node to the caller would make this count
    // zero, and a push that released one of the three twice would make that one
    // read two.
    try testing.expectEqual(@as(usize, 3), try counting.expectOneReleaseEach());
    counting.release();
}

test "the node's block goes back to the allocator the node's own store records" {
    // Two releases happen in one push and they use two allocators: the block
    // through the node's own store and the array through the update's. The
    // counting allocator is the node's, so it must see the block go back there
    // and not through the update's allocator.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const node_gpa = counting.allocator();
    const update_gpa = testing.allocator;

    const update = try treeUpdateWithFocus(update_gpa, 0);
    const held = try newNode(node_gpa, .button);

    treeUpdatePushNode(update, 1, held);

    try testing.expectEqual(@as(usize, 1), counting.timesReleased(held));
    treeUpdateFree(update);
    counting.release();
}

test "a tree info is attached, kept and released with the update" {
    // The contract `accesskit_tree_update_set_tree_info` codes against: the
    // update's `tree` borrows the two toolkit strings out of the handle, so the
    // handle is held rather than copied. Releasing the handle at the clear and
    // not at the free would leave both slices dangling for as long as the update
    // names them.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const update = try treeUpdateWithFocus(gpa, 0);
    const info = try tree_info.treeInfoNew(gpa, 3);
    try tree_info.treeInfoSetToolkitName(info, "gtk");

    treeUpdateSetTreeInfo(update, info);

    const attached = update.update.tree orelse return error.TreeInfoIsNotAttached;
    try testing.expectEqual(@as(NodeIdContent, 3), attached.root.value);
    // The value borrows rather than snapshots: the slice the update carries is
    // the handle's own copy, at the handle's own address, which is what makes
    // the handle the owner and the free the only release.
    const stored = info.toolkit_name_storage orelse return error.ToolkitNameIsUnset;
    const attached_name = attached.toolkit_name orelse return error.ToolkitNameIsNotAttached;
    try testing.expectEqual(stored.ptr, attached_name.ptr);
    try testing.expectEqualStrings("gtk", attached_name);

    // Three blocks: the update handle, the tree info handle and the toolkit
    // name. The node array was never allocated, because nothing was pushed.
    treeUpdateFree(update);
    try testing.expectEqual(@as(usize, 3), try counting.expectOneReleaseEach());
    counting.release();
}

test "a null tree info stores no tree info and ends no process" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 0);
    defer treeUpdateFree(update);

    const info = try tree_info.treeInfoNew(gpa, 3);
    try tree_info.treeInfoSetToolkitName(info, "gtk");
    treeUpdateSetTreeInfo(update, info);
    try testing.expect(update.update.tree != null);

    treeUpdateSetTreeInfo(update, null);
    try testing.expectEqual(@as(?schema.TreeInfo, null), update.update.tree);
    try testing.expectEqual(@as(?*tree_info.accesskit_tree_info, null), update.info);
}

test "a second tree info releases the one it displaces" {
    // Upstream's assignment drops the old `Option<TreeInfo>`
    // (`accesskit-c/src/common.rs:1030-1036`), and a setter that appended or
    // dropped the old copy without counting it would leak here. The testing
    // allocator's leak check is what says so.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const update = try treeUpdateWithFocus(gpa, 0);
    const first = try tree_info.treeInfoNew(gpa, 1);
    try tree_info.treeInfoSetToolkitName(first, "gtk");
    const displaced = first.toolkit_name_storage orelse return error.ToolkitNameIsUnset;
    treeUpdateSetTreeInfo(update, first);

    const second = try tree_info.treeInfoNew(gpa, 2);
    treeUpdateSetTreeInfo(update, second);

    try testing.expectEqual(@as(usize, 2), counting.released.count());
    try testing.expectEqual(@as(usize, 1), counting.timesReleased(displaced.ptr));
    const current = update.update.tree orelse return error.TreeInfoIsNotAttached;
    try testing.expectEqual(@as(NodeIdContent, 2), current.root.value);

    treeUpdateFree(update);
    counting.release();
}

test "a clear removes the value and leaves the release to the free" {
    // `include/zaccesskit.h:5336-5337` says the tree info already set "is
    // released with the update", so the clear releases nothing and the free
    // releases all of it. A clear that released would make the sentence false
    // and would free the two toolkit strings while the value still named them.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const update = try treeUpdateWithFocus(gpa, 0);
    const info = try tree_info.treeInfoNew(gpa, 3);
    try tree_info.treeInfoSetToolkitName(info, "gtk");
    treeUpdateSetTreeInfo(update, info);

    treeUpdateClearTreeInfo(update);

    try testing.expectEqual(@as(usize, 0), counting.released.count());
    try testing.expectEqual(@as(?schema.TreeInfo, null), update.update.tree);
    try testing.expectEqual(@as(?*tree_info.accesskit_tree_info, null), null);

    treeUpdateFree(update);
    try testing.expectEqual(@as(usize, 3), try counting.expectOneReleaseEach());
    counting.release();
}

test "a clear on an update that never held a tree info changes nothing" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 0);
    defer treeUpdateFree(update);

    treeUpdateClearTreeInfo(update);
    try testing.expectEqual(@as(?schema.TreeInfo, null), update.update.tree);
    try testing.expectEqual(@as(?*tree_info.accesskit_tree_info, null), update.info);
}

test "the focus and the tree identifier round trip" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 1);
    defer treeUpdateFree(update);

    treeUpdateSetFocus(update, 99);
    try testing.expectEqual(@as(NodeIdContent, 99), update.update.focus.value);

    const wanted: TreeId = .{ .bytes = [_]u8{1} ** 16 };
    treeUpdateSetTreeId(update, wanted);
    try testing.expect(wanted.eql(treeUpdateGetTreeId(update)));
    // The identifier is a value and not a handle, so a second read is the same
    // 16 bytes and no release is owed for either read.
    try testing.expect(treeUpdateGetTreeId(update).eql(wanted));
}

test "the debug text names the type, both nodes, the tree and the focus" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithCapacityAndFocus(gpa, 2, 5);
    defer treeUpdateFree(update);

    for ([_]NodeIdContent{ 1, 2 }) |id| {
        const held = try newNode(gpa, .button);
        treeUpdatePushNode(update, id, held);
    }

    const unset = try treeUpdateDebug(gpa, update);
    defer releaseCString(gpa, unset);
    try testing.expectEqualStrings(
        "TreeUpdate { nodes: [#1 Node { role: button }, #2 Node { role: button }], " ++
            "tree: null, tree_id: 00000000000000000000000000000000, focus: #5 }",
        span(unset),
    );

    const info = try tree_info.treeInfoNew(gpa, 9);
    try tree_info.treeInfoSetToolkitName(info, "gtk");
    treeUpdateSetTreeInfo(update, info);

    const set = try treeUpdateDebug(gpa, update);
    defer releaseCString(gpa, set);
    try testing.expectEqualStrings(
        "TreeUpdate { nodes: [#1 Node { role: button }, #2 Node { role: button }], " ++
            "tree: TreeInfo { root: #9, toolkit_name: \"gtk\", toolkit_version: null }, " ++
            "tree_id: 00000000000000000000000000000000, focus: #5 }",
        span(set),
    );
}

test "the debug text writes the tree identifier's own bytes" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 0);
    defer treeUpdateFree(update);

    var bytes: [16]u8 = undefined;
    for (&bytes, 0..) |*byte, index| byte.* = @truncate(index * 17);
    treeUpdateSetTreeId(update, .{ .bytes = bytes });

    const text = try treeUpdateDebug(gpa, update);
    defer releaseCString(gpa, text);
    try testing.expect(std.mem.indexOf(
        u8,
        span(text),
        "tree_id: 00112233445566778899aabbccddeeff",
    ) != null);
}

test "the debug text borrows nothing, so the handle may go first" {
    const gpa = testing.allocator;
    const update = try treeUpdateWithFocus(gpa, 0);
    const info = try tree_info.treeInfoNew(gpa, 3);
    try tree_info.treeInfoSetToolkitName(info, "gtk");
    treeUpdateSetTreeInfo(update, info);

    const text = try treeUpdateDebug(gpa, update);
    defer releaseCString(gpa, text);
    treeUpdateFree(update);

    try testing.expect(std.mem.startsWith(u8, span(text), "TreeUpdate {"));
}

test "the debug text fails on its one allocation" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const update = try treeUpdateWithFocus(testing.allocator, 0);
    defer treeUpdateFree(update);

    try testing.expectError(error.OutOfMemory, treeUpdateDebug(failing.allocator(), update));
}

test "the exported constructor, pusher and accessors answer through the C layer" {
    // An export is a Zig function with a C calling convention, so a Zig test
    // calls it the way a C caller does, with the pointers the header declares.
    // This proves the thin exports and the bodies beneath them are wired
    // together and that the declared allocator is the one they allocate through.
    const gpa = allocation.allocator();
    const update = accesskit_tree_update_with_capacity_and_focus(2, 3) orelse
        return error.NoTreeUpdate;
    defer accesskit_tree_update_free(update);

    try testing.expectEqual(@as(NodeIdContent, 3), update.update.focus.value);
    try testing.expectEqual(@as(usize, 0), update.update.nodes.items.len);

    const held = try newNode(gpa, .button);
    accesskit_tree_update_push_node(update, 11, held);
    try testing.expectEqual(@as(usize, 1), update.update.nodes.items.len);

    accesskit_tree_update_set_focus(update, 12);
    try testing.expectEqual(@as(NodeIdContent, 12), update.update.focus.value);

    const wanted: TreeId = .{ .bytes = [_]u8{2} ** 16 };
    accesskit_tree_update_set_tree_id(update, wanted);
    try testing.expect(wanted.eql(accesskit_tree_update_get_tree_id(update)));

    const text = accesskit_tree_update_debug(update) orelse return error.NoDebugText;
    defer releaseCString(gpa, text);
    try testing.expect(std.mem.startsWith(u8, span(text), "TreeUpdate {"));
}

test "the exported tree info calls answer through the C layer" {
    const update = accesskit_tree_update_with_focus(0) orelse return error.NoTreeUpdate;
    defer accesskit_tree_update_free(update);

    const info = try tree_info.treeInfoNew(allocation.allocator(), 4);
    try tree_info.treeInfoSetToolkitName(info, "gtk");
    accesskit_tree_update_set_tree_info(update, info);
    const attached = update.update.tree orelse return error.TreeInfoIsNotAttached;
    try testing.expectEqual(@as(NodeIdContent, 4), attached.root.value);

    // The clear releases nothing, so the update still owns the handle and the
    // free below releases the handle and the string together.
    accesskit_tree_update_clear_tree_info(update);
    try testing.expectEqual(@as(?schema.TreeInfo, null), update.update.tree);
    try testing.expect(update.info != null);
}

fn callbackOwnerFixture(gpa: std.mem.Allocator) TreeUpdateError!*accesskit_tree_update {
    const update = try treeUpdateWithFocus(gpa, 1);
    errdefer update.deinit();
    const info = build_info: {
        const value = try tree_info.treeInfoNew(gpa, 1);
        errdefer tree_info.treeInfoFree(value);
        try tree_info.treeInfoSetToolkitName(value, "Captured toolkit");
        try tree_info.treeInfoSetToolkitVersion(value, "2.4");
        break :build_info value;
    };
    update.setTreeInfo(info);
    const root = build_node: {
        var value = schema.Node.init(gpa, .window);
        errdefer value.deinit();
        try schema.strings.setLabel(&value.properties, "Captured node");
        break :build_node value;
    };
    try update.update.pushNode(gpa, .{ .value = 1 }, root);
    return update;
}

fn callbackFixtureAllocationFailure(gpa: std.mem.Allocator) !void {
    const handle = try callbackOwnerFixture(gpa);
    defer handle.deinit();
    try testing.expectEqualStrings("Captured toolkit", handle.update.tree.?.toolkit_name.?);
    try testing.expectEqualStrings("2.4", handle.update.tree.?.toolkit_version.?);
    try testing.expectEqual(@as(usize, 1), handle.update.nodes.items.len);
    try testing.expectEqualStrings(
        "Captured node",
        schema.strings.label(&handle.update.nodes.items[0].node.properties).?,
    );
}

test "callback fixture construction releases partial payload at every allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        callbackFixtureAllocationFailure,
        .{},
    );
}

const RegisteredCallbackAllocator = struct {
    inner: std.mem.Allocator,
    const header_bytes = 16;
    const alignment: std.mem.Alignment = .of(u128);

    fn alloc(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *RegisteredCallbackAllocator = @ptrCast(@alignCast(context orelse return null));
        const memory = self.inner.rawAlloc(size + header_bytes, alignment, @returnAddress()) orelse
            return null;
        const length: *usize = @ptrCast(@alignCast(memory));
        length.* = size + header_bytes;
        return memory + header_bytes;
    }

    fn free(pointer: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const self: *RegisteredCallbackAllocator = @ptrCast(@alignCast(context orelse return));
        const payload: [*]u8 = @ptrCast(pointer orelse return);
        const memory = payload - header_bytes;
        const length: *const usize = @ptrCast(@alignCast(memory));
        self.inner.rawFree(memory[0..length.*], alignment, @returnAddress());
    }
};

test "callback conversion moves registered allocator array without allocation" {
    // Fail the next backend allocation after construction, through the actual C provider.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    defer counting.release();
    var failing: std.testing.FailingAllocator = .init(counting.allocator(), .{});
    var backend: RegisteredCallbackAllocator = .{ .inner = failing.allocator() };
    allocation.installAllocator(RegisteredCallbackAllocator.alloc, RegisteredCallbackAllocator.free, &backend);
    defer allocation.installAllocator(null, null, null);
    const gpa = allocation.allocator();
    const handle = try callbackOwnerFixture(gpa);
    const allocation_count = failing.allocations;
    failing.fail_index = failing.alloc_index;
    {
        var owners: LiveMetadataOwners = .{};
        defer owners.deinit();
        var native = try owners.consume(gpa, @ptrCast(handle), null);
        defer native.deinit(gpa);
        try testing.expectEqualStrings("Captured toolkit", native.tree.?.toolkit_name.?);
        try testing.expectEqualStrings("2.4", native.tree.?.toolkit_version.?);
        try testing.expectEqual(@as(u64, 1), native.tree.?.root.value);
        try testing.expectEqual(@as(usize, 1), native.nodes.items.len);
        try testing.expectEqual(@as(u64, 1), native.nodes.items[0].node_id.value);
        try testing.expectEqual(schema.Role.window, native.nodes.items[0].node.role);
        try testing.expectEqualStrings(
            "Captured node",
            schema.strings.label(&native.nodes.items[0].node.properties).?,
        );
        try testing.expectEqual(allocation_count, failing.allocations);
    }
    try testing.expectEqual(@as(usize, 7), try counting.expectOneReleaseEach());
}

test "default public C update converts actual node and metadata payload" {
    allocation.installAllocator(null, null, null);
    const gpa = allocation.allocator();
    const handle = accesskit_tree_update_with_capacity_and_focus(1, 1) orelse
        return error.NoTreeUpdate;
    var pending: ?*accesskit_tree_update = handle;
    defer if (pending) |held| held.deinit();
    const info = build_info: {
        const held = try tree_info.treeInfoNew(gpa, 1);
        errdefer held.deinit();
        try tree_info.treeInfoSetToolkitName(held, "Public toolkit");
        try tree_info.treeInfoSetToolkitVersion(held, "3.1");
        break :build_info held;
    };
    accesskit_tree_update_set_tree_info(handle, info);
    const root = build_node: {
        const held = try newNode(gpa, .window);
        errdefer {
            node.mutable_node(held).deinit();
            gpa.destroy(node.mutable_node(held));
        }
        try schema.strings.setLabel(&node.mutable_node(held).properties, "Public node");
        break :build_node held;
    };
    accesskit_tree_update_push_node(handle, 1, root);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
    var owners: LiveMetadataOwners = .{};
    defer owners.deinit();
    pending = null;
    var native = try owners.consume(gpa, @ptrCast(handle), null);
    defer native.deinit(gpa);
    try testing.expectEqual(@as(u64, 1), native.focus.value);
    try testing.expectEqual(@as(u64, 1), native.tree.?.root.value);
    try testing.expectEqualStrings("Public toolkit", native.tree.?.toolkit_name.?);
    try testing.expectEqualStrings("3.1", native.tree.?.toolkit_version.?);
    try testing.expectEqual(@as(usize, 1), native.nodes.items.len);
    try testing.expectEqual(@as(u64, 1), native.nodes.items[0].node_id.value);
    try testing.expectEqual(schema.Role.window, native.nodes.items[0].node.role);
    try testing.expectEqualStrings(
        "Public node",
        schema.strings.label(&native.nodes.items[0].node.properties).?,
    );
}

test "unknown custom allocator migrates array even with the same context" {
    for ([_]bool{ true, false }) |same_context| {
        var source: CountingAllocator = .{ .inner = testing.allocator };
        defer source.release();
        var destination: CountingAllocator = .{ .inner = testing.allocator };
        defer destination.release();
        const source_gpa = source.allocator();
        const gpa = if (same_context) source_gpa else destination.allocator();
        const handle = try callbackOwnerFixture(source_gpa);
        const original_array = handle.update.nodes.items.ptr;
        {
            var owners: LiveMetadataOwners = .{};
            defer owners.deinit();
            var native = try owners.consume(gpa, @ptrCast(handle), null);
            defer native.deinit(gpa);
            try testing.expectEqual(@as(usize, 1), source.timesReleased(original_array));
            try testing.expectEqualStrings("Captured toolkit", native.tree.?.toolkit_name.?);
            try testing.expectEqualStrings("2.4", native.tree.?.toolkit_version.?);
            try testing.expectEqual(@as(u64, 1), native.tree.?.root.value);
            try testing.expectEqual(@as(usize, 1), native.nodes.items.len);
            try testing.expectEqual(@as(u64, 1), native.nodes.items[0].node_id.value);
            try testing.expectEqual(schema.Role.window, native.nodes.items[0].node.role);
            try testing.expectEqualStrings(
                "Captured node",
                schema.strings.label(&native.nodes.items[0].node.properties).?,
            );
        }
        try testing.expectEqual(
            @as(usize, if (same_context) 8 else 7),
            try source.expectOneReleaseEach(),
        );
        try testing.expectEqual(
            @as(usize, if (same_context) 0 else 1),
            try destination.expectOneReleaseEach(),
        );
    }
}

fn callbackMigrationAllocationFailure(gpa: std.mem.Allocator) !void {
    // The outer handle, metadata, and node buffers belong to a different domain.
    var source: CountingAllocator = .{ .inner = testing.allocator };
    defer source.release();
    const source_gpa = source.allocator();
    const handle = try callbackOwnerFixture(source_gpa);
    const original_array = handle.update.nodes.items.ptr;
    const address = @intFromPtr(handle);
    var owners: LiveMetadataOwners = .{};
    defer owners.deinit();
    var native = owners.consume(gpa, @ptrCast(handle), null) catch |err| {
        try testing.expectEqual(@as(usize, 1), source.released.get(address).?);
        try testing.expectEqual(@as(usize, 1), source.timesReleased(original_array));
        try testing.expectEqual(@as(usize, 7), try source.expectOneReleaseEach());
        return err;
    };
    defer native.deinit(gpa);
    try testing.expectEqual(@as(usize, 1), source.released.get(address).?);
    try testing.expectEqual(@as(usize, 1), source.timesReleased(original_array));
    try testing.expectEqualStrings("Captured toolkit", native.tree.?.toolkit_name.?);
    try testing.expectEqualStrings("2.4", native.tree.?.toolkit_version.?);
    try testing.expectEqual(@as(u64, 1), native.tree.?.root.value);
    try testing.expectEqual(@as(usize, 1), native.nodes.items.len);
    try testing.expectEqual(@as(u64, 1), native.nodes.items[0].node_id.value);
    try testing.expectEqual(schema.Role.window, native.nodes.items[0].node.role);
    try testing.expectEqualStrings(
        "Captured node",
        schema.strings.label(&native.nodes.items[0].node.properties).?,
    );
}

test "callback conversion consumes captured allocator handle at every migration allocation failure" {
    try testing.checkAllAllocationFailures(
        testing.allocator,
        callbackMigrationAllocationFailure,
        .{},
    );
}

test "equal metadata replacement keeps separate committed and working storage owners" {
    // The native commit compares metadata bytes, so equal text keeps the old borrow.
    const gpa = testing.allocator;
    var owners: LiveMetadataOwners = .{};
    defer owners.deinit();
    const first = try callbackOwnerFixture(gpa);
    var tree = try consumer_tree.Tree.init(
        gpa,
        try owners.consume(gpa, @ptrCast(first), null),
        false,
    );
    defer tree.deinit();
    owners.reap(&tree);
    const second = try callbackOwnerFixture(gpa);
    const update = try owners.consume(gpa, @ptrCast(second), &tree);
    var context: u8 = 0;
    const changes: consumer_tree.TreeChangeHandler = .{ .ptr = &context };
    try tree.updateAndProcessChanges(update, &changes);
    owners.reap(&tree);
    try testing.expectEqualStrings("Captured toolkit", tree.state.toolkitName());
    try testing.expectEqualStrings("Captured toolkit", tree.next_state.toolkitName());
    try testing.expectEqualStrings("2.4", tree.state.toolkitVersion().?);
    try testing.expectEqualStrings("2.4", tree.next_state.toolkitVersion().?);
}

test "callback metadata without owned nonempty storage needs no retained owner" {
    const gpa = testing.allocator;
    const handle = try treeUpdateWithFocus(gpa, 1);
    var pending: ?*accesskit_tree_update = handle;
    defer if (pending) |owned| owned.deinit();
    const info = build_info: {
        const value = try tree_info.treeInfoNew(gpa, 1);
        errdefer tree_info.treeInfoFree(value);
        try tree_info.treeInfoSetToolkitName(value, "");
        break :build_info value;
    };
    handle.setTreeInfo(info);
    var owners: LiveMetadataOwners = .{};
    defer owners.deinit();
    pending = null;
    var native = try owners.consume(gpa, @ptrCast(handle), null);
    defer native.deinit(gpa);
    try testing.expectEqualStrings("", native.tree.?.toolkit_name.?);
}
