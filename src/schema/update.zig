//! The tree-update payload and the action channel, from
//! `accesskit/src/lib.rs:3162-3333`.
//!
//! Four types cross this seam. `TreeUpdate` moves one tree from one state to
//! the next. `ActionRequest` asks the application to carry out one action.
//! `TreeInfo` holds the data about a tree as a whole, and `ActionData` is the
//! payload an action request may carry.
//!
//! `ActionData` exists here twice, and the second form is why this module owns
//! its own type surface.
//!
//!   * `ActionData` is the Zig core form, a `union(enum)`. The core matches on
//!     the variant, and a tag makes that cheap.
//!   * `CActionData` is the C boundary form: an `extern struct` of a `c_uint`
//!     tag and an `extern union` payload. Zig has no construct that is a
//!     `repr(C)` data-carrying enum, so the port writes the C struct itself.
//!
//! The two forms measure the same 40 bytes at alignment 8 on this host. That is
//! a coincidence and not a reason to ship one form.
//! `docs/31-c-abi-design.md` section 4.0 records the measurement and says so,
//! and no reference states a C layout for `union(enum)`. One conversion runs
//! each way, `actionDataToC` and `actionDataFromC`.
//!
//! A `C` prefix on a type name means "this is the layout the C header
//! describes". An unprefixed name is the ergonomic Zig type. Only the three
//! types that would otherwise collide with a core name carry the prefix, so
//! `schema/root.zig` can re-export every schema module flat and a consumer can
//! still tell which of two same-named things it is holding.
//!
//! Three traps live at this boundary and the `comptime` block below closes each
//! one.
//!
//!   * The C tag enum has no fixed base, so its width is an
//!     implementation-defined size. The port pins it at `c_uint` and asserts the
//!     pin.
//!   * The 17 bare C enums are `typedef uint8_t` while their enumerator names
//!     live in a separate unbased `enum`, so `sizeof(accesskit_scroll_unit)` is
//!     1 under C and `sizeof(enum accesskit_scroll_unit)` is 4. `ScrollUnit` and
//!     `ScrollHint` are one byte here, which is the `uint8_t` a C caller sees.
//!   * The offsets of a plain `struct` below were measured on Zig 0.16.0. The
//!     compiler reorders plain-struct fields to remove padding, so the
//!     declaration order is the source order and not the byte order. Every type
//!     whose offsets are a contract is an `extern struct` here, and every type
//!     that is not one is asserted against a measurement.
//!
//! One layout below is pinned and one is not, and the difference is the point.
//! `std.ArrayList(NodeEntry)` is asserted at 24 bytes under rule L6, because it
//! is this file's own storage. `NodeEntry` is not asserted: it is a `NodeId`
//! beside a `Node`, and the `Node` moves when `schema/props/table.zig` moves.
//! A pin there would be a layout that is a contract in name only, and it would
//! break on a change to a file this one does not own.
//!
//! This module applies nothing to a tree. `consumer/` owns the update
//! algorithm, and this module hands it the decoded values. It builds no C
//! header either; `src/capi/` owns that.
//!
//! Upstream: `accesskit/src/lib.rs:3162-3333`.

const std = @import("std");

const action = @import("action.zig");
const ids = @import("ids.zig");
const node = @import("node.zig");
const point = @import("geometry/point.zig");
const scroll_enums = @import("scroll_enums.zig");
const role = @import("role.zig");
const values = @import("values.zig");

const Action = action.Action;
const Node = node.Node;
const NodeId = ids.NodeId;
const TreeId = ids.TreeId;
const nodeIdFromContent = ids.nodeIdFromContent;
const tree_id_root = ids.tree_id_root;
const Point = point.Point;
const pointInit = point.pointInit;
const Role = role.Role;
const ScrollHint = scroll_enums.ScrollHint;
const ScrollUnit = scroll_enums.ScrollUnit;
const TextSelection = values.TextSelection;
const TextPosition = values.TextPosition;

const testing = std.testing;

/// The data about one accessibility tree that belongs to the tree as a whole
/// and to no single node.
///
/// `toolkit_name` and `toolkit_version` borrow. The caller keeps the bytes
/// alive, `TreeUpdate.deinit` does not release them, and a copy is independent
/// of the original and reads the same bytes.
///
/// `docs/10-accesskit-core.md:1036-1037` maps both fields to a borrowed
/// `?[]const u8`, so a caller keeps the bytes alive for as long as any
/// `TreeInfo` reads them.
///
/// Upstream: `accesskit/src/lib.rs:3162-3176`.
pub const TreeInfo = struct {
    /// The node the tree is rooted at. A consumer rejects an update whose
    /// `root` names neither a node the update adds nor a node the tree holds
    /// already.
    root: NodeId,
    /// The name of the UI toolkit in use. `null` means the toolkit is not
    /// named. The bytes are borrowed and must outlive every `TreeInfo` that
    /// reads them.
    toolkit_name: ?[]const u8,
    /// The version of the UI toolkit. `null` means the version is not known.
    /// `accesskit_consumer/src/tree.rs:560-565` reads this field only when
    /// `toolkit_name` is set. The bytes are borrowed.
    toolkit_version: ?[]const u8,

    /// A `TreeInfo` for `root` with both toolkit fields absent.
    ///
    /// This is upstream's `TreeInfo::new` at `accesskit/src/lib.rs:3183`.
    pub fn init(root: NodeId) TreeInfo {
        return .{ .root = root, .toolkit_name = null, .toolkit_version = null };
    }
};

/// One node of an update, with the identifier that names it.
///
/// Upstream writes the pair as a tuple `(NodeId, Node)` inside the `Vec` at
/// `accesskit/src/lib.rs:3229`, and Zig has no tuples. `node_id` must be the
/// same identifier the node declares in its own `NodeId` property, and a
/// consumer rejects an update where the two disagree.
pub const NodeEntry = struct {
    /// The identifier the node is stored under in the receiving tree.
    node_id: NodeId,
    /// The node itself, by value. The entry owns it.
    node: Node,
};

/// One atomic change to one tree.
///
/// The sender and the receiver must be in sync, because an update means to
/// bring the tree from one specific previous state into its next state. An
/// update applied to the wrong tree is an error the consumer reports, not a
/// state this type can detect.
///
/// `TreeUpdate` owns every `Node` in `nodes` and the array that holds them. The
/// owner calls `deinit` once, with the allocator `pushNode` was given. A copied
/// `TreeUpdate` copies the handle, not the storage, so a copy is not a second
/// owner and a second `deinit` is a double free.
///
/// `tree` borrows its two toolkit strings from `TreeInfo`, and this type never
/// releases them.
///
/// Upstream: `accesskit/src/lib.rs:3192-3258`.
pub const TreeUpdate = struct {
    /// Zero or more new or changed nodes, in any order. Each entry replaces any
    /// node the tree already holds under the same `node_id`, so an entry sets
    /// every field, including the fields that did not change.
    nodes: std.ArrayList(NodeEntry) = .empty,
    /// The data about the tree as a whole. `null` means the data is unchanged
    /// since the previous update. It must be set on the first update of a tree,
    /// and on the first update of a subtree.
    tree: ?TreeInfo = null,
    /// The tree this update applies to. `tree_id_root` is the main tree. A
    /// subtree names itself with 16 bytes no other tree uses, and a graft node
    /// carrying that identifier must already sit in the parent tree.
    tree_id: TreeId = tree_id_root,
    /// The node that holds keyboard focus while the native host holds focus.
    /// It is the root when no node in the tree holds focus. It must arrive with
    /// every update, even when the focus did not move.
    focus: NodeId = .{ .value = 0 },

    /// Stores `new_node` under `node_id` and takes ownership of it.
    ///
    /// `gpa` then owns every node this update holds, and `deinit` must be
    /// called with the same allocator. On `error.OutOfMemory` the call releases
    /// `new_node` before it returns, so the caller never holds it again. That is
    /// the upstream rule at `accesskit-c/src/common.rs:1016-1024`, where the
    /// shim drops the node it could not store.
    pub fn pushNode(
        self: *TreeUpdate,
        gpa: std.mem.Allocator,
        node_id: NodeId,
        new_node: Node,
    ) std.mem.Allocator.Error!void {
        // `new_node` is a const binding, and `deinit` takes a mutable pointer.
        var owned = new_node;
        errdefer owned.deinit();
        try self.nodes.append(gpa, .{ .node_id = node_id, .node = owned });
    }

    /// Releases every node and the array that holds them.
    ///
    /// `gpa` must be the allocator `pushNode` was given. Each node releases its
    /// own property storage through the allocator that node stored, and `gpa`
    /// releases the array. The bytes `tree` borrows are not released.
    /// `self` is unusable afterwards, and a second call is a double free.
    pub fn deinit(self: *TreeUpdate, gpa: std.mem.Allocator) void {
        for (self.nodes.items) |*entry| entry.node.deinit();
        self.nodes.deinit(gpa);
        self.* = undefined;
    }
};

/// The payload one action request carries, in the Zig core form.
///
/// This form is ergonomic and it is not the wire form. `value` is an owned
/// `[]u8` here and a raw C pointer in `ActionDataPayload`, and the two meet in
/// `actionDataToC` and `actionDataFromC` and nowhere else.
///
/// The `value` variant owns a buffer, so `actionDataDeinit` releases it. Every
/// other variant holds numbers, and a copy of one of them is independent of the
/// original.
///
/// Upstream: `accesskit/src/lib.rs:3300-3321`.
pub const ActionData = union(enum) {
    /// The `id` of the `CustomAction` this request names. The application
    /// matches it against the list the node declares.
    custom_action: i32,
    /// The text to replace a selection with, or the new text of a text field.
    /// Owned.
    value: []u8,
    /// The new value of an adjustable field, as a plain number with no unit.
    numeric_value: f64,
    /// How far one `Action.scroll_up`, `Action.scroll_down`,
    /// `Action.scroll_left` or `Action.scroll_right` scrolls.
    scroll_unit: ScrollUnit,
    /// Where `Action.scroll_into_view` puts the target node in the viewport.
    scroll_hint: ScrollHint,
    /// The point `Action.scroll_to_point` scrolls to, in the coordinate space
    /// of the tree container, which is the window on most platforms.
    scroll_to_point: Point,
    /// The point `Action.set_scroll_offset` moves the scroll origin to, in the
    /// coordinate space of the target node.
    set_scroll_offset: Point,
    /// The selection `Action.set_text_selection` sets. A selection with no
    /// extent is a caret, and it holds `anchor` equal to `focus`.
    set_text_selection: TextSelection,
};

/// One action a platform asks the application to carry out.
///
/// The request is passed by value and owns its payload. The handler that
/// receives it calls `deinit` once, with the allocator the payload came from,
/// before it returns. A second `deinit` is a double free. `deinit` releases the
/// buffer the `value` variant owns as well, so a handler must not also call
/// `actionDataDeinit` on `data`.
///
/// Upstream's Rust side box-allocates the request and hands the raw pointer to
/// the callback, and the contract at `accesskit-c/include/accesskit.h:1116-1119`
/// says the callback frees it. `docs/11-accesskit-c-abi.md` section 4.6 records
/// that `accesskit_action_request_free` releases the string in the `value`
/// variant too, which the header does not say. This comment is where the port
/// says it, and the port's own header repeats it.
///
/// Upstream: `accesskit/src/lib.rs:3323-3333`.
pub const ActionRequest = struct {
    /// The operation to carry out. An action that requires a payload must be
    /// rejected when `data` is null, because the core never checks that the
    /// payload arrived. A handler must ignore an action it does not support.
    action: Action,
    /// The tree that owns `target_node`. This identifier and `target_node`
    /// together name one node.
    target_tree: TreeId,
    /// The node the action applies to, inside `target_tree`.
    target_node: NodeId,
    /// The payload. `null` means the action carries none.
    data: ?ActionData,

    /// Releases the buffer the `value` variant owns, and nothing else.
    ///
    /// `gpa` must be the allocator that produced the buffer. `self` is unusable
    /// afterwards, and a second call is a double free.
    pub fn deinit(self: *ActionRequest, gpa: std.mem.Allocator) void {
        if (self.data) |*payload| actionDataDeinit(gpa, payload);
        self.* = undefined;
    }
};

/// The tag that names which member of `ActionDataPayload` is live.
///
/// `accesskit-c/include/accesskit.h:1009` declares this enum with no fixed
/// base, so its width is implementation-defined. The port pins it at `c_uint`
/// and the `comptime` block below asserts the pin against the measurement in
/// `docs/31-c-abi-design.md` section 4.0. The values are wire values: the header
/// numbers the eight tags at `:1010-1022` in this order, and it lists the eight
/// payload members at `:1029-1050` in the same order, so tag `n` selects member
/// `n`.
pub const ActionDataTag = enum(c_uint) {
    /// A wire byte of 0.
    custom_action = 0,
    /// A wire byte of 1.
    value = 1,
    /// A wire byte of 2.
    numeric_value = 2,
    /// A wire byte of 3.
    scroll_unit = 3,
    /// A wire byte of 4.
    scroll_hint = 4,
    /// A wire byte of 5.
    scroll_to_point = 5,
    /// A wire byte of 6.
    set_scroll_offset = 6,
    /// A wire byte of 7.
    set_text_selection = 7,
};

/// The eight payloads of `CActionData`, all of them at offset 0.
///
/// `accesskit-c/include/accesskit.h:1027-1052` is the only anonymous union in
/// the header: one anonymous struct per tag, overlaying. `ScrollUnit` and
/// `ScrollHint` are `typedef uint8_t` under `#ifndef __cplusplus`, so a C
/// caller reads one byte for each, which is what this union reserves.
///
/// `extern union` is required and is not a preference. Zig rejects
/// `extern unions cannot contain fields of type 'TextSelection'` for a plain
/// struct member and rejects a slice member outright, so every payload below is
/// a fixed-size extern-compatible type and the one variable-length payload
/// crosses as a raw pointer.
pub const ActionDataPayload = extern union {
    /// `int32_t custom_action;` at `:1029`.
    custom_action: i32,
    /// `char *value;` at `:1032`. This is the raw C pointer and not a slice,
    /// because an `extern union` may not hold a slice. The `[*:0]` sentinel is
    /// what makes the string readable without a length field beside it, and
    /// `null` is a C `NULL`, which `actionDataFromC` rejects rather than reads.
    value: ?[*:0]const u8,
    /// `double numeric_value;` at `:1035`.
    numeric_value: f64,
    /// `accesskit_scroll_unit scroll_unit;` at `:1038`.
    scroll_unit: ScrollUnit,
    /// `accesskit_scroll_hint scroll_hint;` at `:1041`.
    scroll_hint: ScrollHint,
    /// `struct accesskit_point scroll_to_point;` at `:1044`.
    scroll_to_point: Point,
    /// `struct accesskit_point set_scroll_offset;` at `:1047`.
    set_scroll_offset: Point,
    /// `struct accesskit_text_selection set_text_selection;` at `:1050`.
    set_text_selection: TextSelection,
};

/// `struct accesskit_action_data` from `accesskit-c/include/accesskit.h:1025-1053`.
///
/// The tag field is a `c_uint` and not `ActionDataTag`, so the width the port
/// pins is the width the C enum measures on this host. The `comptime` block
/// below asserts that the two agree.
pub const CActionData = extern struct {
    /// `accesskit_action_data_Tag tag;` at `:1026`.
    tag: c_uint,
    /// The anonymous union at `:1027-1052`.
    payload: ActionDataPayload,
};

/// `struct accesskit_opt_action_data` from `accesskit-c/include/accesskit.h:1060-1063`.
///
/// `has_value` is a C `bool`, and `false` means the request carries no payload.
pub const COptActionData = extern struct {
    /// `bool has_value;` at `:1061`.
    has_value: bool,
    /// `struct accesskit_action_data value;` at `:1062`. Read it only when
    /// `has_value` is true.
    value: CActionData,
};

/// `struct accesskit_action_request` from
/// `accesskit-c/include/accesskit.h:1065-1070`.
///
/// This is the form a C handler receives. A C consumer reads it field by field,
/// and the field order below is the header's.
pub const CActionRequest = extern struct {
    /// `accesskit_action action;` at `:1066`. The header aliases this to
    /// `uint8_t` under `#ifndef __cplusplus`, so a C caller reads one byte.
    action: Action,
    /// `struct accesskit_tree_id target_tree;` at `:1067`.
    target_tree: TreeId,
    /// `accesskit_node_id target_node;` at `:1068`.
    target_node: NodeId,
    /// `struct accesskit_opt_action_data data;` at `:1069`.
    data: COptActionData,
};

/// The failures `actionDataToC` reports.
pub const ActionDataToCError = error{
    /// `gpa` could not supply the buffer for the `value` variant. Nothing was
    /// allocated and the caller owns nothing.
    OutOfMemory,
    /// The `value` bytes hold a 0 byte. A C string ends at its first 0 byte,
    /// so no `char *` spells the rest of the text.
    /// `docs/11-accesskit-c-abi.md` section 5.3 records the upstream conversion
    /// as one of the four sites that refuse a string with an interior 0 byte,
    /// at `accesskit-c/src/common.rs:1098`.
    InteriorNul,
};

/// The failures `actionDataFromC` reports.
pub const ActionDataFromCError = error{
    /// `tag` holds a number no member of `ActionDataTag` declares. The port
    /// pins the tag width, and a wider producer can write a number the pin does
    /// not cover.
    UnknownTag,
    /// `payload.value` was null while `tag` was the `value` tag. Upstream
    /// aborts on a null argument in the same place, at
    /// `accesskit-c/src/lib.rs:115`.
    NullValuePointer,
    /// `gpa` could not supply the buffer for the `value` variant. The call
    /// allocates nothing on that path and `value` keeps its own buffer.
    OutOfMemory,
};

/// Copies `data` into the C boundary form.
///
/// `gpa` then owns the `char *` the `value` variant produces, and the caller
/// releases it with `cActionDataDeinit`. The other seven variants copy no
/// memory, so the result owns nothing and there is nothing to release.
pub fn actionDataToC(
    gpa: std.mem.Allocator,
    data: ActionData,
) ActionDataToCError!CActionData {
    return switch (data) {
        .custom_action => |id| cActionDataNew(.custom_action, .{ .custom_action = id }),
        .value => |text| cActionDataNew(.value, .{ .value = try valueToCString(gpa, text) }),
        .numeric_value => |number| cActionDataNew(.numeric_value, .{ .numeric_value = number }),
        .scroll_unit => |unit| cActionDataNew(.scroll_unit, .{ .scroll_unit = unit }),
        .scroll_hint => |hint| cActionDataNew(.scroll_hint, .{ .scroll_hint = hint }),
        .scroll_to_point => |target| cActionDataNew(
            .scroll_to_point,
            .{ .scroll_to_point = target },
        ),
        .set_scroll_offset => |target| cActionDataNew(
            .set_scroll_offset,
            .{ .set_scroll_offset = target },
        ),
        .set_text_selection => |selection| cActionDataNew(
            .set_text_selection,
            .{ .set_text_selection = selection },
        ),
    };
}

/// Copies `value` into the Zig core form.
///
/// The result owns a fresh copy of `payload.value` for the `value` variant, and
/// owns nothing for the other seven. `value` is unchanged and keeps its own
/// buffer, so the caller must still release it with `cActionDataDeinit`. This
/// is upstream's `From<action_data> for ActionData`, which also copies.
pub fn actionDataFromC(
    gpa: std.mem.Allocator,
    value: CActionData,
) ActionDataFromCError!ActionData {
    return switch (value.tag) {
        @backingInt(ActionDataTag.custom_action) => .{
            .custom_action = value.payload.custom_action,
        },
        @backingInt(ActionDataTag.value) => blk: {
            const pointer = value.payload.value orelse return error.NullValuePointer;
            break :blk ActionData{ .value = try gpa.dupe(u8, std.mem.span(pointer)) };
        },
        @backingInt(ActionDataTag.numeric_value) => .{
            .numeric_value = value.payload.numeric_value,
        },
        @backingInt(ActionDataTag.scroll_unit) => .{
            .scroll_unit = value.payload.scroll_unit,
        },
        @backingInt(ActionDataTag.scroll_hint) => .{
            .scroll_hint = value.payload.scroll_hint,
        },
        @backingInt(ActionDataTag.scroll_to_point) => .{
            .scroll_to_point = value.payload.scroll_to_point,
        },
        @backingInt(ActionDataTag.set_scroll_offset) => .{
            .set_scroll_offset = value.payload.set_scroll_offset,
        },
        @backingInt(ActionDataTag.set_text_selection) => .{
            .set_text_selection = value.payload.set_text_selection,
        },
        else => error.UnknownTag,
    };
}

/// Releases the buffer the `value` variant owns, and nothing else.
///
/// `gpa` must be the allocator that produced the buffer. `data` is unusable
/// afterwards, and a second call is a double free. The other seven variants
/// hold no buffer, so that is the whole teardown.
pub fn actionDataDeinit(gpa: std.mem.Allocator, data: *ActionData) void {
    switch (data.*) {
        .value => |text| gpa.free(text),
        else => {},
    }
    // SAFETY: the switch above released the one buffer this union owns, and no
    // statement after this line reads `data`. A caller that reads it anyway gets
    // a trap in Debug rather than the freed slice, which is the state the doc
    // comment above promises.
    data.* = undefined;
}

/// Releases the `char *` the `value` tag of `value` owns, and nothing else.
///
/// This is the release half of `accesskit_action_request_free` for a bare
/// `accesskit_action_data`. `gpa` must be the allocator that produced the
/// string. `value` is unusable afterwards, and a second call is a double free.
pub fn cActionDataDeinit(gpa: std.mem.Allocator, value: *CActionData) void {
    if (value.tag == @backingInt(ActionDataTag.value)) {
        if (value.payload.value) |pointer| gpa.free(std.mem.span(pointer));
    }
    // SAFETY: the branch above released the one allocation this union owns, the
    // `char *` the `value` tag carries, and nothing after this line reads
    // `value`. A second call through this pointer double frees rather than
    // releases.
    value.* = undefined;
}

/// Releases the payload of `request`, and nothing else.
///
/// This is `accesskit_action_request_free`
/// (`accesskit-c/include/accesskit.h:2412`). It releases the `char *` the
/// `value` tag of the payload owns, because upstream's `Drop` at
/// `accesskit-c/src/common.rs:1084-1090` releases that string with the union.
/// `gpa` must be the allocator that produced the string. `request` is unusable
/// afterwards, and a second call is a double free.
pub fn cActionRequestDeinit(gpa: std.mem.Allocator, request: *CActionRequest) void {
    if (request.data.has_value) cActionDataDeinit(gpa, &request.data.value);
    // SAFETY: `cActionDataDeinit` released the only buffer the payload owns, and
    // the scalars beside it own nothing. Nothing after this line reads
    // `request`, so a second call cannot reach a freed pointer.
    request.* = undefined;
}

/// The `char *` for `text`, with one 0 byte appended.
///
/// `gpa` owns the result, and the caller releases it with `gpa.free` through
/// `cActionDataDeinit`.
fn valueToCString(gpa: std.mem.Allocator, text: []const u8) ActionDataToCError![*:0]const u8 {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InteriorNul;
    const buffer = try gpa.allocSentinel(u8, text.len, 0);
    @memcpy(buffer[0..text.len], text);
    return buffer.ptr;
}

/// The C form carrying `tag` and `payload`.
///
/// `cActionDataDeinit` is the matching release. This is the only place the port
/// writes a `c_uint` where `ActionDataTag` says the value, so the conversion
/// between the two runs in exactly one place.
fn cActionDataNew(tag: ActionDataTag, payload: ActionDataPayload) CActionData {
    return .{ .tag = @backingInt(tag), .payload = payload };
}

comptime {
    // `docs/31-c-abi-design.md` section 4.0 measured the five C forms below on
    // x86-64 Linux at Zig 0.16.0 in Debug, with two independent probes: one
    // compiling the real `accesskit-c/include/accesskit.h` and one reading the
    // candidate Zig types. Both reported the numbers pinned here. The same
    // section records that `union(enum)` also measures 40 bytes at alignment 8,
    // and calls that a coincidence, which is why the C form below is declared
    // rather than assumed. A container-level `comptime` block has no bare
    // `assert` on Zig 0.16.0, so these go through `std.debug.assert`.

    // The tag enum has no fixed base in C, so the port pins the width. This is
    // the number most likely to move on another target.
    std.debug.assert(@sizeOf(ActionDataTag) == 4);
    std.debug.assert(@alignOf(ActionDataTag) == 4);
    // The struct field is a `c_uint`, and the enum has to stand in for it.
    std.debug.assert(@sizeOf(ActionDataTag) == @sizeOf(c_uint));
    std.debug.assert(@alignOf(ActionDataTag) == @alignOf(c_uint));

    // The payload covers the largest member, `set_text_selection` at 32 bytes,
    // and the strictest alignment, which is 8.
    std.debug.assert(@sizeOf(ActionDataPayload) == 32);
    std.debug.assert(@alignOf(ActionDataPayload) == 8);

    // Tag first, payload second. The 4 bytes between them are the padding that
    // puts the payload on its own 8-byte boundary.
    std.debug.assert(@offsetOf(CActionData, "tag") == 0);
    std.debug.assert(@offsetOf(CActionData, "payload") == 8);
    std.debug.assert(@sizeOf(CActionData) == 40);
    std.debug.assert(@alignOf(CActionData) == 8);

    // The enclosing optional. `bool` is one byte in C, and the value starts on
    // the next 8-byte boundary.
    std.debug.assert(@offsetOf(COptActionData, "has_value") == 0);
    std.debug.assert(@offsetOf(COptActionData, "value") == 8);
    std.debug.assert(@sizeOf(COptActionData) == 48);
    std.debug.assert(@alignOf(COptActionData) == 8);

    // The request. `Action` is one byte, `TreeId` is 16 bytes at alignment 1,
    // and both of them leave the payload on offset 32.
    std.debug.assert(@offsetOf(CActionRequest, "action") == 0);
    std.debug.assert(@offsetOf(CActionRequest, "target_tree") == 1);
    std.debug.assert(@offsetOf(CActionRequest, "target_node") == 24);
    std.debug.assert(@offsetOf(CActionRequest, "data") == 32);
    std.debug.assert(@sizeOf(CActionRequest) == 80);
    std.debug.assert(@alignOf(CActionRequest) == 8);

    // An array of four carries no tail padding, which is the check that would
    // fail first if the struct grew a byte.
    std.debug.assert(@sizeOf([4]CActionData) == 160);

    // Tag n selects member n, because the header numbers the tags at
    // `:1010-1022` and lists the members at `:1029-1050` in the same order.
    // This is a check over a domain, so it names the index that broke.
    const tag_fields = @typeInfo(ActionDataTag).@"enum";
    const member_fields = @typeInfo(ActionDataPayload).@"union";
    if (tag_fields.field_names.len != member_fields.field_names.len) @compileError(std.fmt.comptimePrint(
        "ActionDataTag has {d} tags and ActionDataPayload has {d} members",
        .{ tag_fields.field_names.len, member_fields.field_names.len },
    ));
    for (tag_fields.field_names, tag_fields.field_values, member_fields.field_names, 0..) |tag_name, tag_value, member_name, index| {
        if (tag_value != index) @compileError(std.fmt.comptimePrint(
            "ActionDataTag.{s} is {d}, so it is not tag {d}",
            .{ tag_name, tag_value, index },
        ));
        if (!std.mem.eql(u8, tag_name, member_name)) @compileError(std.fmt.comptimePrint(
            "ActionDataTag.{s} does not select ActionDataPayload.{s}",
            .{ tag_name, member_name },
        ));
    }

    // The Zig core form, measured on Zig 0.16.0 and not read from
    // `docs/10-accesskit-core.md`, which predicts these numbers by a rule for
    // `extern struct` layout and applies it to a plain struct. `ActionData` is a
    // tagged union, so rule L3 does govern it and the number is a compiler
    // contract rather than a coincidence.
    std.debug.assert(@sizeOf(ActionData) == 40);
    std.debug.assert(@alignOf(ActionData) == 8);
    // `Toolkit_name` is a 16-byte optional slice and `root` is 8 bytes, so the
    // measured total is 40. The research record says 32.
    std.debug.assert(@sizeOf(TreeInfo) == 40);
    std.debug.assert(@alignOf(TreeInfo) == 8);
    // `data` is a 48-byte optional payload and the three other fields are 1, 16
    // and 8 bytes. The compiler moves `target_node` ahead of `action` because
    // it can, so the declaration order is not the byte order.
    std.debug.assert(@sizeOf(ActionRequest) == 80);
    std.debug.assert(@alignOf(ActionRequest) == 8);
    std.debug.assert(@offsetOf(ActionRequest, "target_node") == 0);
    std.debug.assert(@offsetOf(ActionRequest, "data") == 8);
    std.debug.assert(@offsetOf(ActionRequest, "action") == 56);
    std.debug.assert(@offsetOf(ActionRequest, "target_tree") == 57);

    // `actionDataSample` and `expectActionDataEqual` name the eight tags by
    // their spelling, so the round-trip test below pairs each field with both.
    // The sweep that pairs them is the one that fails when a tag is missing.
    for (@typeInfo(ActionData).@"union".field_names) |field_name| {
        if (!isSampledActionDataTag(field_name)) @compileError(std.fmt.comptimePrint(
            "ActionData gained the variant '{s}' and no sample or check names it",
            .{field_name},
        ));
    }
}

test "the five C forms keep the layouts docs/31 measured" {
    try testing.expectEqual(@as(usize, 4), @sizeOf(ActionDataTag));
    try testing.expectEqual(@as(usize, 4), @alignOf(ActionDataTag));
    try testing.expectEqual(@sizeOf(c_uint), @sizeOf(ActionDataTag));
    try testing.expectEqual(@alignOf(c_uint), @alignOf(ActionDataTag));

    try testing.expectEqual(@as(usize, 32), @sizeOf(ActionDataPayload));
    try testing.expectEqual(@as(usize, 8), @alignOf(ActionDataPayload));

    try testing.expectEqual(@as(usize, 0), @offsetOf(CActionData, "tag"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(CActionData, "payload"));
    try testing.expectEqual(@as(usize, 40), @sizeOf(CActionData));
    try testing.expectEqual(@as(usize, 8), @alignOf(CActionData));

    try testing.expectEqual(@as(usize, 0), @offsetOf(COptActionData, "has_value"));
    try testing.expectEqual(@as(usize, 8), @offsetOf(COptActionData, "value"));
    try testing.expectEqual(@as(usize, 48), @sizeOf(COptActionData));
    try testing.expectEqual(@as(usize, 8), @alignOf(COptActionData));

    try testing.expectEqual(@as(usize, 32), @offsetOf(CActionRequest, "data"));
    try testing.expectEqual(@as(usize, 80), @sizeOf(CActionRequest));
    try testing.expectEqual(@as(usize, 8), @alignOf(CActionRequest));

    try testing.expectEqual(@as(usize, 160), @sizeOf([4]CActionData));
}

test "four C forms in an array keep four independent elements" {
    // A byte of padding inside one element shows up in this total and nowhere
    // else, because an array pads each element to the size of that element.
    var four: [4]CActionData = undefined;
    for (&four, 0..) |*slot, index| {
        slot.* = .{
            .tag = @intCast(index),
            .payload = .{ .custom_action = @intCast(index * 7) },
        };
    }

    try testing.expectEqual(@as(usize, 160), @sizeOf([4]CActionData));
    // Four tags and four numbers that differ, so an array that laid every
    // element over one buffer would fail on the second element.
    for (four, 0..) |slot, index| {
        try testing.expectEqual(@as(u32, @intCast(index)), slot.tag);
        try testing.expectEqual(@as(i32, @intCast(index * 7)), slot.payload.custom_action);
    }
}

test "TreeInfo.init names the root and leaves both toolkit fields absent" {
    const root = nodeIdFromContent(7);
    const info = TreeInfo.init(root);

    try testing.expect(info.root.eql(root));
    try testing.expectEqual(@as(?[]const u8, null), info.toolkit_name);
    try testing.expectEqual(@as(?[]const u8, null), info.toolkit_version);
}

test "a fresh TreeUpdate targets the root tree with no nodes and no focus" {
    const update: TreeUpdate = .{};

    try testing.expectEqual(@as(usize, 0), update.nodes.items.len);
    try testing.expectEqual(@as(?TreeInfo, null), update.tree);
    try testing.expect(update.tree_id.eql(tree_id_root));
    try testing.expect(update.focus.eql(nodeIdFromContent(0)));
}

test "TreeUpdate stores every node under the identifier it was given" {
    const gpa = testing.allocator;
    var update: TreeUpdate = .{};
    defer update.deinit(gpa);

    const roles = [_]Role{ .window, .button, .label };
    for (roles, 0..) |node_role, index| {
        const id = nodeIdFromContent(@intCast(index + 1));
        try update.pushNode(gpa, id, Node.init(gpa, node_role));

        const entry = update.nodes.items[index];
        try testing.expect(entry.node_id.eql(id));
        try testing.expectEqual(node_role, entry.node.role);
    }

    try testing.expectEqual(@as(usize, 3), update.nodes.items.len);
}

test "TreeUpdate.deinit releases the array it grew" {
    // `Node.init` allocates nothing, so the buffer the list grows is the only
    // allocation this type owns. Forgetting `nodes.deinit` fails here.
    const gpa = testing.allocator;
    var update: TreeUpdate = .{};

    try update.pushNode(gpa, nodeIdFromContent(1), Node.init(gpa, .window));
    try update.pushNode(gpa, nodeIdFromContent(2), Node.init(gpa, .button));
    update.deinit(gpa);
}

test "pushNode releases the node it could not store" {
    // The array has not grown yet, so the first allocation it asks for is the
    // failure the failing allocator returns.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    var update: TreeUpdate = .{};
    defer update.deinit(testing.allocator);

    try testing.expectError(
        error.OutOfMemory,
        update.pushNode(failing.allocator(), nodeIdFromContent(1), Node.init(
            failing.allocator(),
            .window,
        )),
    );
    try testing.expectEqual(@as(usize, 0), update.nodes.items.len);
}

test "every ActionData variant survives a round trip through the C form" {
    const gpa = testing.allocator;
    inline for (@typeInfo(ActionData).@"union".field_names) |field_name| {
        var source = try actionDataSample(field_name, gpa);
        defer actionDataDeinit(gpa, &source);

        var boundary = try actionDataToC(gpa, source);
        defer cActionDataDeinit(gpa, &boundary);

        var read_back = try actionDataFromC(gpa, boundary);
        defer actionDataDeinit(gpa, &read_back);

        // The tag decides which field `expectActionDataEqual` may read, so it
        // is checked before that call and not after it.
        try testing.expectEqual(std.meta.activeTag(source), std.meta.activeTag(read_back));
        try expectActionDataEqual(field_name, source, read_back);
    }
}

/// The tag spellings `actionDataSample` and `expectActionDataEqual` name.
const action_data_tags = [_][]const u8{
    "custom_action",
    "value",
    "numeric_value",
    "scroll_unit",
    "scroll_hint",
    "scroll_to_point",
    "set_scroll_offset",
    "set_text_selection",
};

/// True when `name` is a tag `actionDataSample` and `expectActionDataEqual`
/// both name.
fn isSampledActionDataTag(comptime name: []const u8) bool {
    for (action_data_tags) |known| {
        if (std.mem.eql(u8, known, name)) return true;
    }
    return false;
}

test "the C tag reads the payload member the header pairs it with" {
    const gpa = testing.allocator;
    // `scroll_unit` and `scroll_hint` are both one byte, so a tag that reads
    // the wrong member would pass on a value of zero. The two bytes differ.
    const boundary: CActionData = .{
        .tag = @backingInt(ActionDataTag.scroll_hint),
        .payload = .{ .scroll_hint = .bottom_edge },
    };

    const read_back = try actionDataFromC(gpa, boundary);
    switch (read_back) {
        .scroll_hint => |hint| try testing.expectEqual(ScrollHint.bottom_edge, hint),
        else => return error.TestExpectedEqual,
    }
}

test "a tag no member declares is rejected instead of read" {
    const gpa = testing.allocator;
    const boundary: CActionData = .{
        .tag = @backingInt(ActionDataTag.set_text_selection) + 1,
        // The payload is never read, so the union carries the cheapest member.
        .payload = .{ .custom_action = 0 },
    };

    try testing.expectError(error.UnknownTag, actionDataFromC(gpa, boundary));
}

test "a null char pointer under the value tag is rejected, not read" {
    const gpa = testing.allocator;
    const boundary: CActionData = .{
        .tag = @backingInt(ActionDataTag.value),
        .payload = .{ .value = null },
    };

    try testing.expectError(error.NullValuePointer, actionDataFromC(gpa, boundary));
}

test "a value holding a 0 byte cannot become a C string" {
    const gpa = testing.allocator;
    // The text after the 0 byte is the part a `char *` cannot spell.
    const text = try gpa.dupe(u8, "ab\x00cd");
    defer gpa.free(text);

    try testing.expectError(
        error.InteriorNul,
        actionDataToC(gpa, .{ .value = text }),
    );
}

test "an empty value becomes a C string of length zero" {
    const gpa = testing.allocator;
    const text = try gpa.dupe(u8, "");
    defer gpa.free(text);

    var boundary = try actionDataToC(gpa, .{ .value = text });
    defer cActionDataDeinit(gpa, &boundary);

    try testing.expectEqual(@as(u32, @backingInt(ActionDataTag.value)), boundary.tag);
    const pointer = boundary.payload.value orelse return error.ValuePointerAbsent;
    try testing.expectEqual(@as(usize, 0), std.mem.span(pointer).len);
}

test "actionDataToC releases nothing when it fails" {
    // One allocation serves the whole conversion, so failing index 0 is the
    // only failure `actionDataToC` has.
    var failing: std.testing.FailingAllocator = .init(testing.allocator, .{ .fail_index = 0 });
    const text = try testing.allocator.dupe(u8, "typed");

    try testing.expectError(
        error.OutOfMemory,
        actionDataToC(failing.allocator(), .{ .value = text }),
    );
    testing.allocator.free(text);
}

test "actionDataFromC fails on its one allocation and leaves the C value owned" {
    const gpa = testing.allocator;
    const text = try gpa.dupe(u8, "typed");
    defer gpa.free(text);

    var boundary = try actionDataToC(gpa, .{ .value = text });
    defer cActionDataDeinit(gpa, &boundary);

    var failing: std.testing.FailingAllocator = .init(gpa, .{ .fail_index = 0 });
    try testing.expectError(
        error.OutOfMemory,
        actionDataFromC(failing.allocator(), boundary),
    );

    // The C string is still the caller's, so it survives the failed conversion.
    try testing.expectEqualStrings("typed", std.mem.span(boundary.payload.value.?));
}

test "ActionRequest.deinit releases the buffer in its payload" {
    const gpa = testing.allocator;
    var request: ActionRequest = .{
        .action = .replace_selected_text,
        .target_tree = tree_id_root,
        .target_node = nodeIdFromContent(3),
        .data = .{ .value = try gpa.dupe(u8, "replacement") },
    };

    // Reading the payload proves the buffer is live, and the leak check at the
    // end of this test proves `deinit` released it.
    try testing.expectEqualStrings("replacement", request.data.?.value);
    request.deinit(gpa);
}

test "ActionRequest.deinit on a request with no payload releases nothing" {
    const gpa = testing.allocator;
    var request: ActionRequest = .{
        .action = .click,
        .target_tree = tree_id_root,
        .target_node = nodeIdFromContent(4),
        .data = null,
    };

    request.deinit(gpa);
}

test "cActionRequestDeinit releases the char pointer the value tag owns" {
    const gpa = testing.allocator;
    var request: CActionRequest = .{
        .action = .replace_selected_text,
        .target_tree = tree_id_root,
        .target_node = nodeIdFromContent(5),
        .data = .{
            .has_value = true,
            .value = .{
                .tag = @backingInt(ActionDataTag.value),
                .payload = .{ .value = try valueToCString(gpa, "replacement") },
            },
        },
    };

    try testing.expectEqualStrings(
        "replacement",
        std.mem.span(request.data.value.payload.value.?),
    );
    cActionRequestDeinit(gpa, &request);
}

test "cActionRequestDeinit skips a request whose optional carries no value" {
    const gpa = testing.allocator;
    // `has_value` is false, so the payload holds a stale pointer that must not
    // be read and must not be freed. A free here is a double free on the next
    // allocation the allocator hands out.
    var request: CActionRequest = .{
        .action = .click,
        .target_tree = tree_id_root,
        .target_node = nodeIdFromContent(6),
        .data = .{ .has_value = false, .value = .{
            .tag = @backingInt(ActionDataTag.custom_action),
            .payload = .{ .custom_action = 0 },
        } },
    };

    cActionRequestDeinit(gpa, &request);
}

/// One `ActionData` for the tag `tag_name`.
///
/// `tag_name` is one of the eight tag spellings `ActionData` declares. The
/// `comptime` block above pins the count, so a ninth variant stops the build
/// here rather than producing a sample no check can name.
fn actionDataSample(
    comptime tag_name: []const u8,
    gpa: std.mem.Allocator,
) ActionDataSampleError!ActionData {
    if (std.mem.eql(u8, tag_name, "custom_action")) return .{ .custom_action = -7 };
    if (std.mem.eql(u8, tag_name, "value")) return .{ .value = try gpa.dupe(u8, "typed") };
    if (std.mem.eql(u8, tag_name, "numeric_value")) return .{ .numeric_value = 12.5 };
    if (std.mem.eql(u8, tag_name, "scroll_unit")) return .{ .scroll_unit = .page };
    if (std.mem.eql(u8, tag_name, "scroll_hint")) return .{ .scroll_hint = .bottom_edge };
    if (std.mem.eql(u8, tag_name, "scroll_to_point")) {
        return .{ .scroll_to_point = pointInit(1.5, -2.5) };
    }
    if (std.mem.eql(u8, tag_name, "set_scroll_offset")) {
        return .{ .set_scroll_offset = pointInit(-3.25, 4.75) };
    }
    if (std.mem.eql(u8, tag_name, "set_text_selection")) {
        return .{ .set_text_selection = sampleSelection() };
    }
    return error.UnknownTag;
}

/// One selection with a caret at one character of one text run.
fn sampleSelection() TextSelection {
    const run = nodeIdFromContent(9);
    return .{
        .anchor = TextPosition{ .node_id = run, .character_index = 2 },
        .focus = TextPosition{ .node_id = run, .character_index = 5 },
    };
}

/// The failures `actionDataSample` reports to a test.
const ActionDataSampleError = std.mem.Allocator.Error || error{UnknownTag};

/// Checks the one field `tag_name` names, so a failure names the field.
///
/// The caller checks the tag first, so the access on `read_back` is the one
/// that tag selects.
fn expectActionDataEqual(
    comptime tag_name: []const u8,
    expected: ActionData,
    read_back: ActionData,
) !void {
    if (std.mem.eql(u8, tag_name, "custom_action")) {
        try testing.expectEqual(expected.custom_action, read_back.custom_action);
    } else if (std.mem.eql(u8, tag_name, "value")) {
        try testing.expectEqualStrings(expected.value, read_back.value);
    } else if (std.mem.eql(u8, tag_name, "numeric_value")) {
        try testing.expectEqual(expected.numeric_value, read_back.numeric_value);
    } else if (std.mem.eql(u8, tag_name, "scroll_unit")) {
        try testing.expectEqual(expected.scroll_unit, read_back.scroll_unit);
    } else if (std.mem.eql(u8, tag_name, "scroll_hint")) {
        try testing.expectEqual(expected.scroll_hint, read_back.scroll_hint);
    } else if (std.mem.eql(u8, tag_name, "scroll_to_point")) {
        try testing.expectEqual(expected.scroll_to_point, read_back.scroll_to_point);
    } else if (std.mem.eql(u8, tag_name, "set_scroll_offset")) {
        try testing.expectEqual(expected.set_scroll_offset, read_back.set_scroll_offset);
    } else if (std.mem.eql(u8, tag_name, "set_text_selection")) {
        try testing.expect(expected.set_text_selection.eql(read_back.set_text_selection));
    } else {
        return error.TestExpectedEqual;
    }
}
