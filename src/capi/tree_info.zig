//! The C ABI for one tree's own metadata: the `accesskit_tree_info` handle and
//! the eleven `accesskit_tree_info_*` functions the header declares around it.
//!
//! **What this file is.** One handle and eleven exports, ported from
//! `accesskit-c/src/common.rs:863-970` at `8b6ed37`: upstream declares the
//! handle at `:863-871` and the eleven functions at `:875-969`, and each doc
//! comment below names both the header line and the upstream line that
//! declaration came from. Two upstream helpers reach into this port:
//! `accesskit-c/src/lib.rs:206-214` is `debug_repr_from_ptr`, which is the body
//! of `accesskit_tree_info_debug`, and `accesskit-c/src/lib.rs:216-224` is
//! `string_from_c_slice`, which is the body of the two `_with_length` setters.
//! The value they carry is `TreeInfo` at `accesskit/src/lib.rs:3162-3190`.
//!
//! **Who owns what, in the one sentence a C consumer can act on.** The handle
//! `accesskit_tree_info_new` returns and every `char *` a getter here returns
//! belong to the caller; each setter copies the bytes it is given into storage
//! the library owns, so the buffer the caller passed stays the caller's and
//! outlives nothing; `accesskit_tree_info_free` releases the handle together
//! with the library's own copies of `toolkit_name` and `toolkit_version`; and so
//! `accesskit_string_free` is for a string this library returned, the caller's
//! own `free` is for a string the caller passed in, a string this library
//! returned stays valid after the handle is gone, and a string the caller passed
//! in need not.
//!
//! **Why the handle owns its strings when `TreeInfo` borrows them.** Upstream's
//! handle is a `Box<TreeInfo>` and its `toolkit_name` and `toolkit_version` are
//! `Option<String>`, so they are owned
//! (`accesskit/src/lib.rs:3173-3175`); `accesskit_tree_info_free` is
//! `drop(box_from_ptr(tree))` at `accesskit-c/src/common.rs:881-883`, and that
//! drop is what releases them. The ported `TreeInfo` is not that type: both
//! fields are a borrowed `?[]const u8` at `src/schema/update.zig:105` and `:109`
//! and the type has no allocator and no `deinit`. A handle that held a
//! `*TreeInfo` would therefore have to either leak the setters' copies or point
//! at the caller's buffer, and the second would dangle the moment the caller
//! released the buffer it still owns. `docs/40-capi-build-map.md` section 3.5
//! names `*TreeInfo` as this handle's Zig side; that row is a list of which Zig
//! type stands behind which C pointer, and it cannot carry the ownership rule,
//! so the type declared here is the handle itself and the rule is the sentence
//! above. This is a difference in representation, not in shape: a C caller never
//! sees these fields, and only the pointer crosses the boundary.
//!
//! **The getter shape, and the 105 against 104.** Nothing in this file returns a
//! struct by value, and nothing takes one by value either.
//! `accesskit_tree_info_new` returns a pointer to a heap object in both headers
//! (`include/zaccesskit.h:5149` and `accesskit-c/include/accesskit.h:2324`) and
//! the two getters return a `char *` in both, so this domain contributes **zero**
//! to the 105 declarations `docs/40-capi-build-map.md` section 1.2 counts and to
//! upstream's 104. The single declaration that makes this header return 105 where
//! upstream returns 104 is `accesskit_last_error`, whose `accesskit_error` is a
//! C enum, and `docs/31-c-abi-design.md:618-622` says so; the two marginal cases
//! that separate `docs/31`'s 103 from upstream's 104 are `custom_actions` and
//! `tree_id`, which are not here either. There is therefore no
//! by-value-against-by-pointer difference to report for this domain, and the
//! `comptime` block at the foot of this file asserts the shape so a change that
//! made one of these eleven return a value by value fails the build rather than
//! silently moving a count the header has already published.
//!
//! **Two byte-level deltas from upstream, both in what is stored rather than in
//! what is passed.** Upstream's setters run the incoming bytes through
//! `to_string_lossy` (`accesskit-c/src/common.rs:902-904` and `:222`), which
//! replaces every byte that is not valid UTF-8 with the three bytes of `U+FFFD`;
//! the header this port ships says the setters copy bytes and declares no
//! encoding step anywhere in its 6581 lines, and a value of `length` bytes can
//! come back out of a `char *` longer than `length`, which the wording at
//! `include/zaccesskit.h:5182-5188` forbids. This port therefore stores the bytes
//! it was given, which is also what `src/schema/update.zig:105` and `:109` can
//! hold. And upstream's getter is `CString::new(value.clone()).unwrap()` at `:890`
//! and `:931`, which panics on a value holding an interior NUL; the header
//! resolves the same case at `include/zaccesskit.h:5185-5187` by storing a byte
//! string up to the first NUL byte, and that is the rule implemented here, in
//! the setter, where the value can still be shortened.
//!
//! **The bound in this file.** One loop runs over a domain: the two toolkit
//! strings, enumerated by `ToolkitField`. The bound is `toolkitFieldCount`, which
//! is two, and it is derived rather than chosen: `TreeInfo` declares exactly two
//! toolkit fields, `toolkit_name` at `src/schema/update.zig:105` and
//! `toolkit_version` at `:109`, `ToolkitField` is declared here as a mirror of
//! that pair, and `toolkitFieldCount` reads its length off the type rather than
//! repeating it. Every loop over it is an `inline for` over
//! `std.enums.values(ToolkitField)`, so a third field added to `TreeInfo` and to
//! `ToolkitField` reaches `deinit` and the tests with no edit to either.
//!
//! **The allocator, and why the setters do not read the declared one.** Every
//! allocating function here takes `std.mem.Allocator` first, and every handle
//! stores the allocator it was created with; that is `docs/31-c-abi-design.md`
//! record C, and a teardown releases through the stored allocator. A setter is a
//! method, so the receiver takes the place of that parameter and a setter's copy
//! comes from `self.gpa` rather than from `allocation.allocator()`. The header
//! settles it at `include/zaccesskit.h:6469-6470`: installing an allocator after
//! the first call has no effect on allocations already made, and none of those is
//! released through the new pair. A copy taken from the declared allocator while
//! the object was made from the previous one would be released through the
//! wrong pair, so an object and every string it owns come from one allocator.
//!
//! **What this file needs from the module that owns the C channel.** Three names,
//! all in `src/capi/allocation.zig`, which `docs/30-port-design.md` section 3.3
//! gives the channel: `allocation.allocator() std.mem.Allocator`, the accessor
//! `docs/40-capi-build-map.md` section 2 shows at each allocating export;
//! `allocation.clearError() void`, which every export calls on entry because
//! `include/zaccesskit.h:6479-6480` says the tag is valid only for the call that
//! set it; and `allocation.failWith(.out_of_memory)`, the one failing tag this
//! file can record, which is `ACCESSKIT_ERROR_OUT_OF_MEMORY` at
//! `include/zaccesskit.h:1763` and the only failing member of the two-member
//! `accesskit_error` at `:1761-1764`. `marshal.zig` owns the conversions this
//! file calls: `dup_c_string`, `string_free`, `c_string_to_slice` and
//! `c_bytes_to_slice`.
//!
//! **What a `void` export does when it cannot fail.** `accesskit_tree_info_free`
//! on a null handle and a setter whose copy does not fit in memory are both
//! contract violations, and both headers end the process rather than returning a
//! status, because a `void` function has nowhere to put one
//! (`docs/31-c-abi-design.md` record B) and `docs/40-capi-build-map.md` section
//! 4.1 records that softening either would be a behaviour change against a
//! contract both headers state. Upstream reaches the same two places from Rust,
//! where `box_from_ptr` on a null pointer and the allocation failure handler both
//! abort because `accesskit-c` compiles with `panic = "abort"`.
//! `terminate` is the one place this file leaves.
//!
//! **What this layer does not do.** No `zio`, no `io: std.Io`, no clock, no
//! global state, no `unreachable`, no `panic` and no discarded error. The
//! `std.Io.Writer` in `formatTreeInfo` is a byte sink the caller supplies rather
//! than a capability the layer acquires, the same distinction
//! `src/schema/root.zig:27` records for the three `format` methods below it.

const std = @import("std");

const schema = @import("../schema/root.zig");
const allocation = @import("allocation.zig");
const marshal = @import("marshal.zig");

const NodeIdContent = schema.NodeIdContent;
const TreeInfo = schema.TreeInfo;
const nodeIdFormat = schema.nodeIdFormat;
const nodeIdFromContent = schema.nodeIdFromContent;

const testing = std.testing;

/// Which of the two toolkit strings a call is about.
///
/// The members mirror the two toolkit fields on `TreeInfo`
/// (`src/schema/update.zig:105` and `:109`). Nothing else in this file can reach
/// a toolkit string, so this pair is the whole domain and `toolkitFieldCount` is
/// the bound on every loop over it.
const ToolkitField = enum {
    /// The `toolkit_name` field, at `src/schema/update.zig:105`.
    name,
    /// The `toolkit_version` field, at `src/schema/update.zig:109`.
    version,
};

/// How many members `ToolkitField` has: two, one per toolkit string on
/// `TreeInfo`. Read off the type, so a field added to both is counted here
/// without an edit to this file.
pub const toolkitFieldCount = @typeInfo(ToolkitField).@"enum".fields.len;

/// The only failure any function in this file has.
///
/// It is `std.mem.Allocator.Error` under another name, and the `comptime` block
/// at the foot of this file asserts that, so the sweep over this set and the
/// allocator's own error stay the same set rather than two sets that happen to
/// agree today.
pub const TreeInfoError = error{OutOfMemory};

/// The object `accesskit_tree_info` names, in the form the C seam needs.
///
/// `include/zaccesskit.h:994` declares `typedef struct accesskit_tree_info
/// accesskit_tree_info;` and the header is opaque, so a C caller cannot read the
/// layout because there is none for it. This is a plain `struct` and not an
/// `extern struct` for that reason: only the pointer crosses the boundary, so no
/// field's offset is a contract, and the layout that lets the object own its two
/// strings is worth more here than a pin nothing can check. Zig 0.16.0 rejects
/// fields on an `opaque` type, so the alternative is a separate wrapper with a
/// cast at every access and no gain.
pub const accesskit_tree_info = struct {
    /// The allocator the object was created with, and the only one any release
    /// on it goes through. A handle stores the allocator it was created with
    /// because `include/zaccesskit.h:6469-6470` says an allocator installed
    /// later does not receive the releases of an allocation made before it.
    gpa: std.mem.Allocator,

    /// The value this handle carries. Its two toolkit fields borrow from
    /// `toolkit_name_storage` and `toolkit_version_storage` and from nothing
    /// else, which is what lets a tree update take the value over and keep
    /// reading it after the handle is gone.
    tree: TreeInfo,

    /// The library's own copy of `toolkit_name`, or `null` when the property is
    /// unset. A set property holding an empty string stores an empty slice
    /// rather than `null`, because upstream stores `Some("")` for an empty value
    /// (`accesskit-c/src/lib.rs:217-218`) and the getter's `null` and `""` are
    /// different answers.
    toolkit_name_storage: ?[]u8,

    /// The library's own copy of `toolkit_version`, or `null` when the property
    /// is unset. Spelled as its own field rather than reached by index so that
    /// the field and the storage it backs are named together.
    toolkit_version_storage: ?[]u8,

    /// The `TreeInfo` value this handle carries, by value.
    ///
    /// Its two toolkit fields borrow from this handle's storage and from nothing
    /// else, so a caller that keeps the value must keep the handle alive for as
    /// long as it reads the strings. `accesskit_tree_update_set_tree_info` is
    /// that caller: the header consumes the handle at
    /// `include/zaccesskit.h:5307-5317`, so the update holds this handle and
    /// releases it with `accesskit_tree_update_free`, and copying the value out
    /// and releasing the handle here would leave both toolkit strings dangling.
    pub fn value(self: *const accesskit_tree_info) TreeInfo {
        return self.tree;
    }

    /// Releases this object and every string it owns, exactly once.
    ///
    /// The strings go first and the object second, so the last thing this
    /// function reads is the allocator it is about to hand back. `self` is
    /// unusable afterwards and a second call is a double free, which is
    /// `docs/31-c-abi-design.md` section 3 row 16 and `include/zaccesskit.h:5152`
    /// stating the same thing about the C function this backs. The loop is
    /// bounded by `toolkitFieldCount`.
    pub fn deinit(self: *accesskit_tree_info) void {
        inline for (std.enums.values(ToolkitField)) |which| {
            if (storage(self, which)) |displaced| self.gpa.free(displaced);
        }
        self.gpa.destroy(self);
    }

    /// Copies `text` into this object's own storage for `which`, and leaves the
    /// property alone when the copy does not fit in memory.
    ///
    /// A method rather than a file-scope function so the receiver carries the
    /// allocator: this is a later allocation on an object that already exists,
    /// and it must come from the allocator that object will be released through,
    /// which is the rule this module's doc records for the setters.
    ///
    /// The copy is taken before the value it replaces is dropped, so the one
    /// path that can fail leaves the property exactly as the caller found it
    /// rather than half written.
    fn setToolkit(
        self: *accesskit_tree_info,
        which: ToolkitField,
        text: []const u8,
    ) TreeInfoError!void {
        // A byte string is stored up to the first NUL byte, because a value
        // holding one cannot come back out of a `char *` getter without losing
        // its tail. This is the header's rule at
        // `include/zaccesskit.h:5185-5187` and it replaces upstream's
        // `CString::new(...).unwrap()` at `accesskit-c/src/common.rs:890`, which
        // panics on the same value.
        const kept = text[0..std.mem.indexOfScalar(u8, text, 0) orelse text.len];
        const copy = try self.gpa.dupe(u8, kept);
        if (store(self, which, copy)) |displaced| self.gpa.free(displaced);
    }
};

// --- the Zig layer, one function per header declaration -------------------------

/// Allocates a tree info whose root is `root`, and hands it to the caller.
///
/// Upstream `accesskit-c/src/common.rs:875-878`, which is `TreeInfo::new` at
/// `accesskit/src/lib.rs:3183` boxed into a raw pointer. `gpa` is first, so a
/// test can fail the one allocation this makes. The two toolkit fields start
/// unset, which is what `TreeInfo.init` at `src/schema/update.zig:114` builds.
///
/// `error.OutOfMemory` is the only failure, and the `export fn` beside it turns
/// it into the `null` and the tag `include/zaccesskit.h:5141-5148` describes.
pub fn treeInfoNew(
    gpa: std.mem.Allocator,
    root: NodeIdContent,
) TreeInfoError!*accesskit_tree_info {
    const tree = try gpa.create(accesskit_tree_info);
    tree.* = .{
        .gpa = gpa,
        .tree = TreeInfo.init(nodeIdFromContent(root)),
        .toolkit_name_storage = null,
        .toolkit_version_storage = null,
    };
    return tree;
}

/// Releases the tree info and every string it owns, exactly once.
///
/// The Zig-layer name `docs/40-capi-build-map.md` section 2 gives the body of
/// `accesskit_tree_info_free` (`include/zaccesskit.h:5157`, upstream
/// `accesskit-c/src/common.rs:881-883`). It is one line over `deinit` so that
/// the map's name names a real function and the teardown itself has one
/// spelling, and it takes the receiver rather than an allocator because the
/// receiver is where the allocator is.
pub fn treeInfoFree(tree: *accesskit_tree_info) void {
    tree.deinit();
}

/// Returns a copy of the `toolkit_name` property, or `null` when it is unset.
///
/// Upstream `accesskit-c/src/common.rs:887-893`: it clones the stored `String`
/// into a fresh `CString` and hands over the raw pointer, so the result borrows
/// nothing and the handle may be released first. `null` therefore answers two
/// questions, and `include/zaccesskit.h:5160-5167` makes
/// `accesskit_last_error` the thing that tells them apart: a `null` with the tag
/// set is an allocation failure and a `null` without it is an unset property.
pub fn treeInfoGetToolkitName(
    gpa: std.mem.Allocator,
    tree: *const accesskit_tree_info,
) TreeInfoError!?[*:0]u8 {
    return toolkitCopy(gpa, tree, .name);
}

/// Returns a copy of the `toolkit_version` property, or `null` when it is unset.
///
/// Upstream `accesskit-c/src/common.rs:926-934`, the same body as
/// `treeInfoGetToolkitName` over the other field.
pub fn treeInfoGetToolkitVersion(
    gpa: std.mem.Allocator,
    tree: *const accesskit_tree_info,
) TreeInfoError!?[*:0]u8 {
    return toolkitCopy(gpa, tree, .version);
}

/// Copies the NUL-terminated `toolkit_name` into the tree info's own storage.
///
/// Upstream `accesskit-c/src/common.rs:897-905`. The bytes are copied, so nothing
/// is retained and the caller keeps the buffer; `include/zaccesskit.h:5173-5177`
/// is the header's sentence for it. The bytes are stored as they are, which is
/// this port's one stated departure from upstream's `to_string_lossy`, and the
/// reason is in this module's doc.
pub fn treeInfoSetToolkitName(
    tree: *accesskit_tree_info,
    toolkit_name: []const u8,
) TreeInfoError!void {
    return tree.setToolkit(.name, toolkit_name);
}

/// Copies the NUL-terminated `toolkit_version` into the tree info's own storage.
///
/// Upstream `accesskit-c/src/common.rs:938-946`, the same body as
/// `treeInfoSetToolkitName` over the other field.
pub fn treeInfoSetToolkitVersion(
    tree: *accesskit_tree_info,
    toolkit_version: []const u8,
) TreeInfoError!void {
    return tree.setToolkit(.version, toolkit_version);
}

/// Copies `length` bytes of `toolkit_name` into the tree info's own storage.
///
/// Upstream `accesskit-c/src/common.rs:909-916`, whose body is
/// `string_from_c_slice` at `accesskit-c/src/lib.rs:216-224`: a `length` of 0
/// stores an empty string rather than clearing the property, which is the
/// `Some("")` upstream keeps distinct from `None` at `:217-218`.
pub fn treeInfoSetToolkitNameWithLength(
    tree: *accesskit_tree_info,
    toolkit_name: []const u8,
    length: usize,
) TreeInfoError!void {
    return tree.setToolkit(.name, toolkit_name[0..length]);
}

/// Copies `length` bytes of `toolkit_version` into the tree info's own storage.
///
/// Upstream `accesskit-c/src/common.rs:950-957`, the same body as
/// `treeInfoSetToolkitNameWithLength` over the other field.
pub fn treeInfoSetToolkitVersionWithLength(
    tree: *accesskit_tree_info,
    toolkit_version: []const u8,
    length: usize,
) TreeInfoError!void {
    return tree.setToolkit(.version, toolkit_version[0..length]);
}

/// Clears `toolkit_name` and releases the copy the library holds.
///
/// Upstream `accesskit-c/src/common.rs:919-922`, which assigns `None` and lets
/// the assignment drop the `String` this port holds in storage. A getter after
/// this reports the property as unset, which is a different answer from a
/// property set to the empty string.
pub fn treeInfoClearToolkitName(tree: *accesskit_tree_info) void {
    if (store(tree, .name, null)) |displaced| tree.gpa.free(displaced);
}

/// Clears `toolkit_version` and releases the copy the library holds.
///
/// Upstream `accesskit-c/src/common.rs:960-963`, the same body as
/// `treeInfoClearToolkitName` over the other field.
pub fn treeInfoClearToolkitVersion(tree: *accesskit_tree_info) void {
    if (store(tree, .version, null)) |displaced| tree.gpa.free(displaced);
}

/// Returns a text rendering of the tree info, or `error.OutOfMemory`.
///
/// Upstream `accesskit-c/src/common.rs:967-969`, which is
/// `debug_repr_from_ptr` at `accesskit-c/src/lib.rs:206-214`: it formats the
/// value it was handed and hands the resulting `CString` over, so the text
/// borrows nothing and the handle may be released first.
/// `include/zaccesskit.h:5251-5258` is the header's sentence for it, and it
pub fn treeInfoDebug(
    gpa: std.mem.Allocator,
    tree: *const accesskit_tree_info,
) TreeInfoError![*:0]u8 {
    var owning: std.Io.Writer.Allocating = .init(gpa);
    defer owning.deinit();
    formatTreeInfo(&tree.tree, &owning.writer) catch |err| switch (err) {
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

/// Returns a new tree info whose root is `root`, or `null` when the allocation
/// failed.
///
/// `include/zaccesskit.h:5149`. The caller owns the result and releases it with
/// `accesskit_tree_info_free`, once, unless ownership passes to
/// `accesskit_tree_update_set_tree_info`, and the header says so here too.
/// `root` is `accesskit_node_id`, which is `typedef uint64_t` at
/// `include/zaccesskit.h:177`, so it crosses as one scalar and
/// `nodeIdFromContent` is the whole of the conversion.
export fn accesskit_tree_info_new(root: NodeIdContent) callconv(.c) ?*accesskit_tree_info {
    allocation.clearError();
    const tree = treeInfoNew(allocation.allocator(), root) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return tree;
}

/// Releases the tree info and every string it owns, exactly once.
///
/// `include/zaccesskit.h:5157`. The handle arrives as `?*accesskit_tree_info`
/// rather than as a non-optional pointer so that the documented answer to a null
/// is the one the header states, at `include/zaccesskit.h:5154`: a null check
/// that returned would be a behaviour change, and letting the dereference happen
/// would be undefined behaviour instead of a contract this port can state.
export fn accesskit_tree_info_free(tree: ?*accesskit_tree_info) callconv(.c) void {
    allocation.clearError();
    const handle = tree orelse terminate("accesskit_tree_info_free", "the handle was null");
    treeInfoFree(handle);
}

/// Returns a copy of `toolkit_name`, or `null` when it is unset or the copy did
/// not fit in memory.
///
/// `include/zaccesskit.h:5169`. The copy is a fresh allocation from the declared
/// allocator and is released by `accesskit_string_free`, never by `free`, and
/// never by `accesskit_tree_info_free`, which does not know about it.
export fn accesskit_tree_info_get_toolkit_name(
    tree: *const accesskit_tree_info,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    const text = treeInfoGetToolkitName(allocation.allocator(), tree) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return text;
}

/// Returns a copy of `toolkit_version`, or `null` when it is unset or the copy
/// did not fit in memory.
///
/// `include/zaccesskit.h:5214`.
export fn accesskit_tree_info_get_toolkit_version(
    tree: *const accesskit_tree_info,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    const text = treeInfoGetToolkitVersion(allocation.allocator(), tree) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return text;
}

/// Copies the NUL-terminated `toolkit_name` into the tree info's own storage.
///
/// `include/zaccesskit.h:5178`. Nothing is retained: the caller keeps the buffer
/// and may release it as soon as this returns.
export fn accesskit_tree_info_set_toolkit_name(
    tree: *accesskit_tree_info,
    toolkit_name: [*c]const u8,
) callconv(.c) void {
    allocation.clearError();
    treeInfoSetToolkitName(tree, marshal.c_string_to_slice(toolkit_name)) catch
        terminate(
            "accesskit_tree_info_set_toolkit_name",
            "the copy of the toolkit name did not fit in memory",
        );
}

/// Copies `length` bytes of `toolkit_name` into the tree info's own storage.
///
/// `include/zaccesskit.h:5190`. `toolkit_name` need not be NUL-terminated, and a
/// value holding a NUL byte is stored up to it.
export fn accesskit_tree_info_set_toolkit_name_with_length(
    tree: *accesskit_tree_info,
    toolkit_name: [*c]const u8,
    length: usize,
) callconv(.c) void {
    allocation.clearError();
    treeInfoSetToolkitNameWithLength(
        tree,
        marshal.c_bytes_to_slice(toolkit_name, length),
        length,
    ) catch terminate(
        "accesskit_tree_info_set_toolkit_name_with_length",
        "the copy of the toolkit name did not fit in memory",
    );
}

/// Clears `toolkit_name` and releases the copy the library holds.
///
/// `include/zaccesskit.h:5202`. Returns nothing and cannot fail.
export fn accesskit_tree_info_clear_toolkit_name(tree: *accesskit_tree_info) callconv(.c) void {
    allocation.clearError();
    treeInfoClearToolkitName(tree);
}

/// Copies the NUL-terminated `toolkit_version` into the tree info's own storage.
///
/// `include/zaccesskit.h:5224`. Nothing is retained: the caller keeps the buffer.
export fn accesskit_tree_info_set_toolkit_version(
    tree: *accesskit_tree_info,
    toolkit_version: [*c]const u8,
) callconv(.c) void {
    allocation.clearError();
    treeInfoSetToolkitVersion(tree, marshal.c_string_to_slice(toolkit_version)) catch
        terminate(
            "accesskit_tree_info_set_toolkit_version",
            "the copy of the toolkit version did not fit in memory",
        );
}

/// Copies `length` bytes of `toolkit_version` into the tree info's own storage.
///
/// `include/zaccesskit.h:5236`. `toolkit_version` need not be NUL-terminated,
/// and a value holding a NUL byte is stored up to it.
export fn accesskit_tree_info_set_toolkit_version_with_length(
    tree: *accesskit_tree_info,
    toolkit_version: [*c]const u8,
    length: usize,
) callconv(.c) void {
    allocation.clearError();
    treeInfoSetToolkitVersionWithLength(
        tree,
        marshal.c_bytes_to_slice(toolkit_version, length),
        length,
    ) catch terminate(
        "accesskit_tree_info_set_toolkit_version_with_length",
        "the copy of the toolkit version did not fit in memory",
    );
}

/// Clears `toolkit_version` and releases the copy the library holds.
///
/// `include/zaccesskit.h:5248`. Returns nothing and cannot fail.
export fn accesskit_tree_info_clear_toolkit_version(tree: *accesskit_tree_info) callconv(.c) void {
    allocation.clearError();
    treeInfoClearToolkitVersion(tree);
}

/// Returns a text rendering of the tree info, or `null` when it could not be
/// built.
///
/// `include/zaccesskit.h:5259`. The text borrows nothing, so the handle may be
/// released first, and the caller releases the text with
/// `accesskit_string_free`.
export fn accesskit_tree_info_debug(tree: *const accesskit_tree_info) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    const text = treeInfoDebug(allocation.allocator(), tree) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
    return text;
}

// --- the shape, the one writer, and the renderer --------------------------------

/// The bytes stored for `which`, or `null` when the property is unset.
fn toolkitValue(tree: *const accesskit_tree_info, which: ToolkitField) ?[]const u8 {
    return switch (which) {
        .name => tree.tree.toolkit_name,
        .version => tree.tree.toolkit_version,
    };
}

/// The library's own copy for `which`, which `deinit` releases.
fn storage(tree: *const accesskit_tree_info, which: ToolkitField) ?[]u8 {
    return switch (which) {
        .name => tree.toolkit_name_storage,
        .version => tree.toolkit_version_storage,
    };
}

/// Points `tree` at `value` for `which` and returns the copy that value
/// displaced, so the caller releases exactly the bytes the object owned before.
///
/// This is the only writer of either half. A setter and a clearer that each
/// touched the two fields separately would leave a path on which the value and
/// the storage disagree, and the getter would then return bytes `deinit` never
/// releases.
fn store(
    tree: *accesskit_tree_info,
    which: ToolkitField,
    value: ?[]u8,
) ?[]u8 {
    return switch (which) {
        .name => blk: {
            const displaced = tree.toolkit_name_storage;
            tree.toolkit_name_storage = value;
            tree.tree.toolkit_name = value;
            break :blk displaced;
        },
        .version => blk: {
            const displaced = tree.toolkit_version_storage;
            tree.toolkit_version_storage = value;
            tree.tree.toolkit_version = value;
            break :blk displaced;
        },
    };
}

/// The copy a getter hands to the caller, or `null` when the property is unset.
fn toolkitCopy(
    gpa: std.mem.Allocator,
    tree: *const accesskit_tree_info,
    which: ToolkitField,
) TreeInfoError!?[*:0]u8 {
    const value = toolkitValue(tree, which) orelse return null;
    return try marshal.dup_c_string(gpa, value);
}

/// Writes the text `accesskit_tree_info_debug` returns.
///
/// The shape follows `Node.format` at `src/schema/node.zig:263`, which is the
/// port's own rendering convention: the type's name, then `field: value` pairs.
/// Two spellings differ from upstream's derived `Debug`, and neither changes what
/// the text carries. Upstream writes the node id through `NodeId`'s own `Debug`,
/// and this writes it through `nodeIdFormat` at `src/schema/ids.zig:84`, so an id
/// reads `#7` rather than `NodeId(7)`; and upstream writes an absent optional as
/// `None`, and this writes `null`, because `None` is a Rust spelling and this is
/// a Zig port. Upstream's derived `Debug` also escapes a value holding a quote,
/// which `writeOptionalBytes` does here for the same reason.
fn formatTreeInfo(tree: *const TreeInfo, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    try writer.writeAll("TreeInfo { root: ");
    try nodeIdFormat(tree.root, writer);
    try writer.writeAll(", toolkit_name: ");
    try writeOptionalBytes(writer, tree.toolkit_name);
    try writer.writeAll(", toolkit_version: ");
    try writeOptionalBytes(writer, tree.toolkit_version);
    try writer.writeAll(" }");
}

/// Writes `value` between quotes, or the word `null` when it is unset.
fn writeOptionalBytes(writer: *std.Io.Writer, value: ?[]const u8) std.Io.Writer.Error!void {
    const bytes = value orelse return writer.writeAll("null");
    try writer.writeByte('"');
    for (bytes) |byte| {
        if (byte == '"' or byte == '\\') try writer.writeByte('\\');
        try writer.writeByte(byte);
    }
    try writer.writeByte('"');
}

/// Whether `T` is a type a C aggregate could be spelled with, which is what the
/// by-value question is about.
fn isAggregate(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .@"struct", .@"union", .@"enum", .@"array" => true,
        else => false,
    };
}

/// Fails the build if `signature` returns or takes an aggregate by value.
///
/// A C caller classifies an aggregate by value differently on every target, and a
/// difference between this header and the library it links is the failure this
/// catches: a caller built for one convention corrupts its own stack while
/// neither side sees a size disagree. `docs/31-c-abi-design.md` section 5 row
/// 258 says the same of the opaque handle, that identity and alignment are all
/// there is to compare when no layout exists.
fn assertPointerShaped(signature: anytype) void {
    const info = @typeInfo(@TypeOf(signature)).@"fn";
    if (info.return_type) |returned| {
        std.debug.assert(!isAggregate(returned));
    }
    for (info.params) |param| {
        std.debug.assert(!isAggregate(param.type.?));
    }
}

/// Ends the process for a call both headers say cannot succeed.
///
/// `include/zaccesskit.h:5162` is the first sentence ("Passing `null` terminates
/// the process") and `:5183-5184` the second ("There is no failure path"), and
/// `docs/40-capi-build-map.md` section 4.1 records that softening either into a
/// return would be a behaviour change against a contract both headers already
/// state. Upstream reaches the same two places from Rust, where `box_from_ptr` on
/// a null pointer and the allocation failure handler both abort because
/// `accesskit-c` compiles with `panic = "abort"`
/// (`docs/11-accesskit-c-abi.md:1421`).
///
/// `std.process.exit` rather than `panic` or `unreachable` because the house
/// rules forbid both on this boundary, and `exit` rather than `abort` because
/// `exit` flushes the diagnostic below before the process leaves. The status is
/// 1, and upstream's signal is `SIGABRT`; a caller cannot observe the
/// difference, because it is already dead.
fn terminate(comptime function_name: []const u8, reason: []const u8) noreturn {
    std.debug.print("zaccesskit: {s}: {s}\n", .{ function_name, reason });
    std.process.exit(1);
}

comptime {
    // The error set this file declares is the allocator's, and the sweep names
    // its only member, which is the rule `AGENTS.md` section 3 states for every
    // error set in this repository.
    std.debug.assert(TreeInfoError == std.mem.Allocator.Error);
    std.debug.assert(@typeInfo(TreeInfoError).error_set.?.len == 1);
    std.debug.assert(std.mem.eql(
        u8,
        @errorName(@as(TreeInfoError, error.OutOfMemory)),
        "OutOfMemory",
    ));

    // The two-member domain this file's one loop runs over.
    std.debug.assert(toolkitFieldCount == 2);

    // The shape claim this module's doc makes, asserted rather than asserted
    // to. Eleven signatures, one per header declaration in
    // `docs/40-capi-build-map.md` section 2, and every one of them crosses as a
    // pointer or a scalar. A return type changed to a struct would fail here
    // rather than move a count the header has published.
    for (.{
        accesskit_tree_info_new,
        accesskit_tree_info_free,
        accesskit_tree_info_get_toolkit_name,
        accesskit_tree_info_set_toolkit_name,
        accesskit_tree_info_set_toolkit_name_with_length,
        accesskit_tree_info_clear_toolkit_name,
        accesskit_tree_info_get_toolkit_version,
        accesskit_tree_info_set_toolkit_version,
        accesskit_tree_info_set_toolkit_version_with_length,
        accesskit_tree_info_clear_toolkit_version,
        accesskit_tree_info_debug,
    }) |exported| {
        assertPointerShaped(exported);
    }
}

// --- tests ---------------------------------------------------------------------

/// A compile-time literal as the `[*:0]const u8` a header's `const char *`
/// parameter is.
fn cText(comptime text: [:0]const u8) [*:0]const u8 {
    return text.ptr;
}

/// A compile-time literal as the `[*:c]const u8` a header's `const char *`
/// parameter is when the length is passed separately and the value need not be
/// NUL-terminated.
fn cBytes(comptime text: []const u8) [*c]const u8 {
    return text.ptr;
}

/// A C string a getter returned as the slice `expectEqualStrings` compares, and
/// as the `[*:0]const u8` `std.mem.span` takes. A many-pointer does not coerce
/// to a slice, so every read of a returned string goes through here.
fn span(value: [*c]const u8) []const u8 {
    return std.mem.span(value);
}

/// Releases a string a getter returned, which is what
/// `accesskit_string_free` does on the C side.
fn releaseCString(gpa: std.mem.Allocator, value: [*c]const u8) void {
    marshal.string_free(gpa, @constCast(@ptrCast(value)));
}

/// The only failure `CountingAllocator.expectOneReleaseEach` reports.
const ReleaseCountError = error{NotOneRelease};

/// An allocator that records how many times each pointer went back to it.
///
/// `std.testing.allocator` already traps a double free, which is a failure, but a
/// trap says only that one happened and not how many times a pointer was
/// released. The property `accesskit_tree_info_free` has to hold is a count: the
/// object and each string it owns are released once and once only. This counts
/// them, and a test below proves the counter can see a second release, because a
/// counting test against a counter that counted nothing would also pass.
const CountingAllocator = struct {
    /// The allocator the counting forwards to, which is what catches a release
    /// of a pointer it never handed out.
    inner: std.mem.Allocator,
    /// How many times each released pointer went back, keyed by address.
    released: std.AutoHashMapUnmanaged(usize, usize) = .empty,

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
    /// once, returns how many distinct pointers that was, and releases the
    /// counter.
    fn expectOneReleaseEach(self: *CountingAllocator) ReleaseCountError!usize {
        var iterator = self.released.iterator();
        while (iterator.next()) |entry| {
            if (entry.value_ptr.* != 1) {
                std.debug.print(
                    "pointer 0x{x} was released {d} times\n",
                    .{ entry.key_ptr.*, entry.value_ptr.* },
                );
                return error.NotOneRelease;
            }
        }
        const distinct = self.released.count();
        self.release();
        return distinct;
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
    /// to add. No path in this file remaps, and `std.testing.allocator` behind
    /// this allocator still sees the growth.
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

test "the new tree info carries the root it was given and no toolkit string" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 42);
    defer treeInfoFree(tree);

    try testing.expectEqual(@as(NodeIdContent, 42), tree.tree.root.value);
    try testing.expectEqual(@as(?[]const u8, null), toolkitValue(tree, .name));
    try testing.expectEqual(@as(?[]const u8, null), toolkitValue(tree, .version));
    try testing.expectEqual(@as(?[]u8, null), storage(tree, .name));
    try testing.expectEqual(@as(?[]u8, null), storage(tree, .version));
}

test "the new tree info is the only allocation a call that fails makes" {
    // The header says nothing is allocated on the failure path
    // (`include/zaccesskit.h:5147`), and the failing allocator is what proves
    // it: the handle is the first allocation, so a failure at index 0 leaves
    // nothing behind and the testing allocator's leak check says so.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, treeInfoNew(failing.allocator(), 1));
}

test "a getter answers null for a property that was never set" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    try testing.expectEqual(@as(?[*:0]u8, null), try treeInfoGetToolkitName(gpa, tree));
    try testing.expectEqual(@as(?[*:0]u8, null), try treeInfoGetToolkitVersion(gpa, tree));
}

test "a getter returns the value the setter stored, on both fields" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    try treeInfoSetToolkitName(tree, "gtk");
    try treeInfoSetToolkitVersion(tree, "3.24.38");

    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    defer releaseCString(gpa, name);
    const version = (try treeInfoGetToolkitVersion(gpa, tree)).?;
    defer releaseCString(gpa, version);

    try testing.expectEqualStrings("gtk", span(name));
    try testing.expectEqualStrings("3.24.38", span(version));
}

test "a getter's copy outlives the tree info it came from" {
    // The header states it at `include/zaccesskit.h:5134-5136` for the node
    // debug function, and the same construction is upstream's at
    // `accesskit-c/src/common.rs:890`. A getter that returned a view into the
    // handle's storage would leave this reading freed memory.
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    try treeInfoSetToolkitName(tree, "gtk");

    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    defer releaseCString(gpa, name);
    treeInfoFree(tree);

    try testing.expectEqualStrings("gtk", span(name));
}

test "a setter copies, so the buffer the caller passed is still the caller's" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    // A buffer the library did not allocate, which is the only way to tell a
    // copy from a retained pointer: overwriting it after the setter returns must
    // leave the stored value alone.
    var caller_buffer = "gtk".*;
    try treeInfoSetToolkitName(tree, caller_buffer[0..]);
    @memset(caller_buffer[0..], 'x');

    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    defer releaseCString(gpa, name);
    try testing.expectEqualStrings("gtk", span(name));
}

test "a freed tree info releases the object and both owned strings exactly once" {
    // The header's sentence is at `include/zaccesskit.h:5152` and this is the
    // test that holds it to that: three allocations came from this object and
    // three go back, and each of the three went back once. A fourth release
    // would make the count four, and a release of the same pointer twice would
    // make one of the three read two.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const tree = try treeInfoNew(gpa, 1);
    try treeInfoSetToolkitName(tree, "gtk");
    try treeInfoSetToolkitVersion(tree, "3.24.38");
    try testing.expectEqual(@as(usize, 0), counting.released.count());

    treeInfoFree(tree);

    try testing.expectEqual(@as(usize, 3), try counting.expectOneReleaseEach());
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
    counting.release();
}

test "a second set releases the first copy once and keeps the second" {
    // A setter that appended, or that dropped the old copy without counting it,
    // would leak here and the testing allocator's leak check is what says so.
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const tree = try treeInfoNew(gpa, 1);
    try treeInfoSetToolkitName(tree, "gtk");
    // The copy the second set displaces, so the count below is asked about the
    // bytes that were released and not about the ones the handle still holds.
    const displaced = storage(tree, .name).?;
    try treeInfoSetToolkitName(tree, "gtk4");

    try testing.expectEqual(@as(usize, 1), counting.released.count());
    try testing.expectEqual(@as(usize, 1), counting.timesReleased(displaced.ptr));

    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    try testing.expectEqualStrings("gtk4", span(name));

    // Every pointer goes back before the counter is released, because the
    // counter owns the map this allocator records into and a release after
    // `expectOneReleaseEach` would write into a map that is already gone.
    treeInfoFree(tree);
    releaseCString(gpa, name);
    try testing.expectEqual(@as(usize, 4), try counting.expectOneReleaseEach());
}

test "a clear releases the copy and reports the property as unset" {
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const tree = try treeInfoNew(gpa, 1);
    try treeInfoSetToolkitName(tree, "gtk");
    treeInfoClearToolkitName(tree);

    try testing.expectEqual(@as(usize, 1), counting.released.count());
    try testing.expectEqual(@as(?[]const u8, null), toolkitValue(tree, .name));
    try testing.expectEqual(@as(?[]u8, null), storage(tree, .name));
    try testing.expectEqual(@as(?[*:0]u8, null), try treeInfoGetToolkitName(gpa, tree));

    treeInfoFree(tree);
    // Two now, not one: the cleared copy went back at the clear above and the
    // object itself goes back here.
    try testing.expectEqual(@as(usize, 2), counting.released.count());
    counting.release();
}

test "clearing a property that was never set releases nothing" {
    var counting: CountingAllocator = .{ .inner = testing.allocator };
    const gpa = counting.allocator();

    const tree = try treeInfoNew(gpa, 1);

    treeInfoClearToolkitName(tree);
    treeInfoClearToolkitVersion(tree);
    try testing.expectEqual(@as(usize, 0), counting.released.count());

    // The handle is released before the counter, for the reason the test above
    // states.
    treeInfoFree(tree);
    counting.release();
}

test "an empty value is a set property, not an unset one" {
    // Upstream stores `Some("")` for an empty value
    // (`accesskit-c/src/lib.rs:217-218`), so the getter's `null` and its `""` are
    // different answers and collapsing them would lose that.
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    try treeInfoSetToolkitName(tree, "");
    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    defer releaseCString(gpa, name);
    try testing.expectEqualStrings("", span(name));
    try testing.expect(toolkitValue(tree, .name) != null);
}

test "a value is stored up to the first NUL byte" {
    // The header's rule at `include/zaccesskit.h:5185-5187`, and the case
    // upstream panics on at `accesskit-c/src/common.rs:890`. Storing the tail
    // would produce a value whose getter cannot spell it.
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    try treeInfoSetToolkitNameWithLength(tree, "ab\x00cd", 5);

    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    defer releaseCString(gpa, name);
    try testing.expectEqualStrings("ab", span(name));
}

test "the with-length setter takes bytes a NUL-terminated one could not spell" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    // A length shorter than the buffer, and a buffer with no NUL in it: the
    // setter reads `length` bytes and stops there.
    try treeInfoSetToolkitVersionWithLength(tree, "3.24.38-longer", 6);

    const version = (try treeInfoGetToolkitVersion(gpa, tree)).?;
    defer releaseCString(gpa, version);
    try testing.expectEqualStrings("3.24.3", span(version));
}

test "bytes that are not valid UTF-8 come back as the bytes that went in" {
    // This is the delta this module's doc records: upstream replaces them with
    // the three bytes of `U+FFFD` (`accesskit-c/src/common.rs:902-904`), and the
    // header copies bytes.
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    const raw = [_]u8{ 0xff, 0xfe, 'g', 't', 'k' };
    try treeInfoSetToolkitName(tree, &raw);

    const name = (try treeInfoGetToolkitName(gpa, tree)).?;
    defer releaseCString(gpa, name);
    try testing.expectEqualSlices(u8, &raw, span(name));
}

test "a getter fails on its one allocation and leaves the property owned" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const tree = try treeInfoNew(testing.allocator, 1);
    defer treeInfoFree(tree);
    try treeInfoSetToolkitName(tree, "gtk");

    try testing.expectError(
        error.OutOfMemory,
        treeInfoGetToolkitName(failing.allocator(), tree),
    );
    // The property is still the object's, and the next getter reads it.
    try testing.expectEqualStrings("gtk", toolkitValue(tree, .name).?);
}

test "a setter allocates through the handle, and fails there and nowhere else" {
    // The second half of this module's allocator rule: a setter's copy comes
    // from the allocator the object was created with, so the failure arrives
    // through the handle rather than through a parameter. `fail_index = 1` lets
    // the handle be created and fails the copy, which is the only allocation a
    // setter makes.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 1 });
    const tree = try treeInfoNew(failing.allocator(), 1);
    defer treeInfoFree(tree);

    try testing.expectError(error.OutOfMemory, treeInfoSetToolkitName(tree, "gtk"));
    // The failed set dropped nothing and stored nothing, so the property is
    // exactly as the caller found it.
    try testing.expectEqual(@as(?[]const u8, null), toolkitValue(tree, .name));
    try testing.expectEqual(@as(?[]u8, null), storage(tree, .name));
}

test "the debug text names the type, the root and both toolkit fields" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 7);
    defer treeInfoFree(tree);

    const unset = try treeInfoDebug(gpa, tree);
    defer releaseCString(gpa, unset);
    try testing.expectEqualStrings(
        "TreeInfo { root: #7, toolkit_name: null, toolkit_version: null }",
        span(unset),
    );

    try treeInfoSetToolkitName(tree, "gtk");
    try treeInfoSetToolkitVersion(tree, "3.24.38");

    const set = try treeInfoDebug(gpa, tree);
    defer releaseCString(gpa, set);
    try testing.expectEqualStrings(
        "TreeInfo { root: #7, toolkit_name: \"gtk\", toolkit_version: \"3.24.38\" }",
        span(set),
    );
}

test "the debug text escapes a value holding a quote" {
    // Upstream's derived `Debug` escapes it, and an unescaped quote would make
    // the field boundary unreadable.
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    defer treeInfoFree(tree);

    try treeInfoSetToolkitName(tree, "a\"b");
    const text = try treeInfoDebug(gpa, tree);
    defer releaseCString(gpa, text);
    try testing.expectEqualStrings(
        "TreeInfo { root: #1, toolkit_name: \"a\\\"b\", toolkit_version: null }",
        span(text),
    );
}

test "the debug text borrows nothing, so the handle may go first" {
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 1);
    try treeInfoSetToolkitName(tree, "gtk");

    const text = try treeInfoDebug(gpa, tree);
    defer releaseCString(gpa, text);
    treeInfoFree(tree);

    try testing.expect(std.mem.startsWith(u8, span(text), "TreeInfo {"));
}

test "the debug text fails on its one allocation" {
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const tree = try treeInfoNew(testing.allocator, 1);
    defer treeInfoFree(tree);

    try testing.expectError(error.OutOfMemory, treeInfoDebug(failing.allocator(), tree));
}

test "both toolkit fields answer the same way, member by member" {
    // The comptime sweep the module doc's bound claims: every loop over
    // `ToolkitField` in this file reaches both members, and a third member added
    // to the type reaches them with no edit here.
    inline for (std.enums.values(ToolkitField)) |which| {
        const gpa = testing.allocator;
        const tree = try treeInfoNew(gpa, 3);
        defer treeInfoFree(tree);

        try testing.expectEqual(@as(?[]const u8, null), toolkitValue(tree, which));
        try tree.setToolkit(which, "gtk");
        try testing.expectEqualStrings("gtk", toolkitValue(tree, which).?);

        const text = try treeInfoDebug(gpa, tree);
        defer releaseCString(gpa, text);
        try testing.expect(std.mem.indexOf(u8, span(text), "\"gtk\"") != null);

        if (store(tree, which, null)) |displaced| tree.gpa.free(displaced);
        try testing.expectEqual(@as(?[]const u8, null), toolkitValue(tree, which));
    }
}

test "the exported constructor, setters and getters answer through the C layer" {
    // An export is a Zig function with a C calling convention, so a Zig test
    // calls it the way a C caller does, with the pointers the header declares.
    // This proves the thin export and the body beneath it are wired together
    // and that the declared allocator is the one the body allocates through.
    const gpa = allocation.allocator();
    const tree = accesskit_tree_info_new(5) orelse return error.NoTreeInfo;
    defer accesskit_tree_info_free(tree);

    try testing.expectEqual(@as(NodeIdContent, 5), tree.tree.root.value);

    accesskit_tree_info_set_toolkit_name(tree, cText("gtk"));
    accesskit_tree_info_set_toolkit_version(tree, cText("3.24.38"));

    const name = accesskit_tree_info_get_toolkit_name(tree) orelse
        return error.NoToolkitName;
    defer releaseCString(gpa, name);
    try testing.expectEqualStrings("gtk", span(name));

    const version = accesskit_tree_info_get_toolkit_version(tree) orelse
        return error.NoToolkitVersion;
    defer releaseCString(gpa, version);
    try testing.expectEqualStrings("3.24.38", span(version));

    const text = accesskit_tree_info_debug(tree) orelse return error.NoDebugText;
    defer releaseCString(gpa, text);
    try testing.expect(std.mem.startsWith(u8, span(text), "TreeInfo {"));

    accesskit_tree_info_clear_toolkit_name(tree);
    accesskit_tree_info_clear_toolkit_version(tree);
    try testing.expectEqual(@as(?[*:0]u8, null), accesskit_tree_info_get_toolkit_name(tree));
    try testing.expectEqual(
        @as(?[*:0]u8, null),
        accesskit_tree_info_get_toolkit_version(tree),
    );
}

test "the exported with-length setters read the length they are given" {
    const gpa = allocation.allocator();
    const tree = accesskit_tree_info_new(1) orelse return error.NoTreeInfo;
    defer accesskit_tree_info_free(tree);

    accesskit_tree_info_set_toolkit_name_with_length(tree, cBytes("gtk4"), 3);
    accesskit_tree_info_set_toolkit_version_with_length(tree, cBytes("3.24.38"), 6);

    const name = accesskit_tree_info_get_toolkit_name(tree) orelse
        return error.NoToolkitName;
    defer releaseCString(gpa, name);
    try testing.expectEqualStrings("gtk", span(name));

    const version = accesskit_tree_info_get_toolkit_version(tree) orelse
        return error.NoToolkitVersion;
    defer releaseCString(gpa, version);
    try testing.expectEqualStrings("3.24.3", span(version));
}

test "the value out of the handle borrows the handle's own two strings" {
    // The contract `accesskit_tree_update_set_tree_info` codes against: the
    // value reads the handle's storage, so a caller that keeps the value keeps
    // the handle, and releasing the handle first would leave both slices
    // dangling.
    const gpa = testing.allocator;
    const tree = try treeInfoNew(gpa, 9);
    defer treeInfoFree(tree);
    try treeInfoSetToolkitName(tree, "gtk");

    const borrowed = tree.value();
    try testing.expectEqualStrings("gtk", borrowed.toolkit_name.?);
    try testing.expectEqual(@as(NodeIdContent, 9), borrowed.root.value);

    // The value borrows rather than snapshots: both spellings carry the same
    // address, which is what makes releasing the handle first leave this value
    // dangling. `value` hands the struct back by value, so a later set writes
    // the handle's own field and leaves this copy holding the header it was
    // given. Reading the bytes through it after that set would be a read of
    // memory the second set already released.
    try testing.expectEqual(
        storage(tree, .name).?.ptr,
        borrowed.toolkit_name.?.ptr,
    );
}