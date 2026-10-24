//! The types that cross between the C ABI and a platform adapter.
//!
//! **Why this file exists, and why it is a leaf.** `src/capi/platform.zig`
//! imports all five adapters, because it owns the 58 declarations the header puts
//! behind its platform guards. An adapter needs the four callback types to be
//! able to *hold* a handler it was given — so the adapter would have to import
//! `platform.zig` back, and the two files would import each other. That is a
//! cycle, and a cycle at the seam where `@export` runs at `comptime` is the kind
//! that fails with an error nobody can act on.
//!
//! Shared types and owned request conversion live here. This leaf imports only
//! schema, handles, and the standard library. `platform.zig` re-exports the types,
//! and adapters import this leaf directly. Neither side imports the other.
//!
//! **What belongs here.** Types both sides must name and their request conversion
//! belong here. Adapter-only work belongs in that adapter. Other C ABI work belongs
//! in `platform.zig`. The JNI types and `COptLResult` are
//! deliberately *not* here: each is used by exactly one platform, and pulling
//! them in would make this file a second home for a definition that has one.

const schema = @import("../schema/root.zig");
const handles = @import("handles.zig");
const std = @import("std");

/// The box the Unix family passes by value. `accesskit_rect` is four `double`
/// at offsets 0, 8, 16 and 24, which is 32 bytes at alignment 8, and
/// `schema.Rect` is the same `extern struct`, so the conversion across this seam
/// is the identity and neither side writes one.
///
/// `docs/40-capi-build-map.md` section 3.2 records the measurement.
pub const CRect = schema.Rect;

/// The tree an activation handler and a tree-update factory return.
///
/// `accesskit_tree_update` is an opaque owning handle. Its representation and
/// consuming conversion belong to `tree_update.zig`, not to the native schema.
pub const CTreeUpdate = handles.accesskit_tree_update;

/// The request an action handler receives. The port's own `extern struct` form
/// of `accesskit_action_request` is already written at
/// `src/schema/update.zig:363`, and the callback passes a pointer to it.
pub const CActionRequest = schema.CActionRequest;

/// Clones a borrowed native request into an independently owned C request.
///
/// `request` stays unchanged on success and error. The caller owns the outer
/// request and its optional string, both allocated through `gpa`.
/// Release the payload with `schema.cActionRequestDeinit`, then destroy the
/// outer request through the same allocator. Foreign callers pass
/// `allocation.allocator()` and transfer the result to the C action callback.
/// `error.OutOfMemory` and `error.InteriorNul` leave no partial allocation.
pub fn createActionRequest(
    gpa: std.mem.Allocator,
    request: schema.ActionRequest,
) schema.ActionDataToCError!*schema.CActionRequest {
    const copy = try gpa.create(schema.CActionRequest);
    errdefer gpa.destroy(copy);
    copy.* = .{
        .action = request.action,
        .target_tree = request.target_tree,
        .target_node = request.target_node,
        .data = .{
            .has_value = request.data != null,
            .value = if (request.data) |data|
                try schema.actionDataToC(gpa, data)
            else
                std.mem.zeroes(schema.CActionData),
        },
    };
    return copy;
}

/// `accesskit_tree_update_factory`, at `include/zaccesskit.h:1707` and upstream
/// `src/lib.rs:1698`.
///
/// The factory builds one whole tree update and transfers it to the library,
/// which releases it after delivery. It runs on a thread of the library's own, so
/// it must assume nothing about the thread that installed it, and **it must not
/// return `null`** — a `null` return from a factory is a contract violation and
/// terminates the process.
pub const TreeUpdateFactory = *const fn (?*anyopaque) callconv(.c) ?*CTreeUpdate;

/// `accesskit_activation_handler_callback`, at `include/zaccesskit.h:1720` and
/// upstream `src/lib.rs:1711`.
///
/// It is textually identical to `TreeUpdateFactory` and the header keeps both
/// names because upstream does. The difference is the contract, and it is the
/// one an adapter gets wrong: **a `null` return here is an ordinary answer
/// meaning "no tree", not a failure**, and the library keeps nothing. The same
/// return from a factory is a contract violation.
pub const ActivationHandler = *const fn (?*anyopaque) callconv(.c) ?*CTreeUpdate;

/// `accesskit_action_handler_callback`, at `include/zaccesskit.h:1737` and
/// upstream `src/lib.rs:1728`.
///
/// Ownership transfers to the callback. It releases the request with
/// `accesskit_action_request_free` before returning, on every path.
/// A `value` payload release also frees its string. The request borrows nothing
/// from native input. The callback must not retain this pointer past its return.
pub const ActionHandler = *const fn (*CActionRequest, ?*anyopaque) callconv(.c) void;

/// `accesskit_deactivation_handler_callback`, at
/// `include/zaccesskit.h:1748` and upstream `src/lib.rs:1739`.
///
/// It runs on the same thread as the activation handler for the same adapter,
/// and `userdata` reaches it unchanged.
pub const DeactivationHandler = *const fn (?*anyopaque) callconv(.c) void;

/// `HWND`, from `<windows.h>`, which the header includes under `_WIN32`.
///
/// The port spells it as an opaque pointer because `windows.h` is not available
/// on this target and the header's contract is the pointer, not the struct.
pub const Hwnd = ?*anyopaque;

/// `WPARAM`, the unsigned pointer-sized message field of a Win32 message.
pub const WParam = usize;

/// `LPARAM`, the signed pointer-sized message field of a Win32 message.
pub const LParam = isize;

/// `accesskit_opt_lresult`, at `include/zaccesskit.h:1573`, the one struct this
/// boundary declares that exists only under `_WIN32`.
///
/// `docs/40-capi-build-map.md` section 3.2 measured it: 16 bytes at alignment 8
/// with `value` at offset 8. `has_value` false means this adapter does not own
/// the window and the window procedure returns `false` from `DefWindowProc`;
/// `value` is then a zero the port writes, so a reader who ignores the flag
/// reads a defined zero rather than uninitialised storage.
///
/// It is here rather than in `windows/root.zig` because `platform.zig` names it
/// as the return of `accesskit_windows_adapter_handle_wm_getobject`, and a type
/// the C ABI names and an adapter returns has to have exactly one declaration.
pub const COptLResult = extern struct {
    /// `bool has_value;`. False when this adapter is not the window's owner.
    has_value: bool,
    /// `LRESULT value;`, read only when `has_value` is true. `LRESULT` is
    /// `LONG_PTR`, a signed pointer-sized integer, and it is 64 bits on every
    /// target this port claims for Windows.
    value: isize,
};

comptime {
    // The layout the header was measured to have, `docs/40` section 3.2. These
    // are the two values that cross this seam by value, so a field reordered or
    // retyped here is a C consumer reading the wrong memory rather than a
    // compile error anywhere.
    std.debug.assert(@sizeOf(CRect) == 32);
    std.debug.assert(@alignOf(CRect) == 8);
    std.debug.assert(@offsetOf(CRect, "y1") == 24);

    // The calling convention is recorded in each declaration above, as
    // `callconv(.c)`, and it is the only place it is written. Reflection reads
    // it back too: `@typeInfo` on the pointer has no `calling_convention`, but
    // its `child` is the function type, and
    // `@typeInfo(pointer.child).@"fn".@"callconv"` is the convention the
    // header declares. `src/capi/platform.zig` asserts exactly that for all
    // four types, in its test "the four callback types have the shapes the
    // header declares".

    // `ActivationHandler` and `TreeUpdateFactory` are the same shape and the
    // header keeps both names because upstream does. If they ever diverge, the
    // distinction the doc comments draw — null means "no tree" here, and is a
    // contract violation there — is no longer expressible in the types, so pin
    // it while it holds.
    if (ActivationHandler != TreeUpdateFactory) @compileError("the two factories are one shape");
}

test "owned C request copies fields and every payload without retaining the source" {
    // Read the C fields directly, not through the reverse conversion recipe.
    const gpa = std.testing.allocator;
    const text = try gpa.dupe(u8, "copied native text");
    defer gpa.free(text);
    const payloads = actionRequestPayloads(text);
    try std.testing.expectEqual(@as(usize, 9), payloads.len);
    inline for (@typeInfo(schema.ActionData).@"union".field_names) |field_name| {
        var found = false;
        for (payloads) |payload| {
            if (payload) |data| {
                if (std.mem.eql(u8, @tagName(data), field_name)) found = true;
            }
        }
        try std.testing.expect(found);
    }
    for (payloads) |payload| {
        var source = actionRequestFixture(payload);
        const copy = try createActionRequest(gpa, source);
        defer gpa.destroy(copy);
        defer schema.cActionRequestDeinit(gpa, copy);
        try expectCopiedRequest(source, copy);
        source.action = .focus;
        source.target_tree = schema.tree_id_root;
        source.target_node = schema.nodeIdFromContent(0);
        source.data = null;
        try expectCopiedRequest(actionRequestFixture(payload), copy);
    }
}

test "owned C value request survives mutation and release of native source" {
    const gpa = std.testing.allocator;
    var source = actionRequestFixture(.{ .value = try gpa.dupe(u8, "native value") });
    var source_live = true;
    defer if (source_live) source.deinit(gpa);
    const copy = try createActionRequest(gpa, source);
    defer gpa.destroy(copy);
    defer schema.cActionRequestDeinit(gpa, copy);
    const copied_text = copy.data.value.payload.value.?;
    try std.testing.expect(@intFromPtr(copied_text) != @intFromPtr(source.data.?.value.ptr));
    source.data.?.value[0] = 'X';
    try std.testing.expectEqualStrings("native value", std.mem.span(copied_text));
    source.deinit(gpa);
    source_live = false;
    try std.testing.expectEqual(schema.Action.click, copy.action);
    try std.testing.expect(copy.target_tree.eql(actionRequestFixture(null).target_tree));
    try std.testing.expect(copy.target_node.eql(schema.nodeIdFromContent(0x1234)));
    try std.testing.expect(copy.data.has_value);
    try std.testing.expectEqual(@backingInt(schema.ActionDataTag.value), copy.data.value.tag);
    try std.testing.expectEqualStrings("native value", std.mem.span(copied_text));
}

test "owned C request fail-N frees partial copies and keeps every borrowed input" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        actionRequestAllocationFailures,
        .{},
    );
}

test "owned C request InteriorNul frees the outer allocation and preserves borrowed bytes" {
    const gpa = std.testing.allocator;
    var source = actionRequestFixture(.{ .value = try gpa.dupe(u8, "before\x00after") });
    defer source.deinit(gpa);
    try std.testing.expectError(error.InteriorNul, createActionRequest(gpa, source));
    try std.testing.expectEqualSlices(u8, "before\x00after", source.data.?.value);
    try std.testing.expectEqual(schema.Action.click, source.action);
    try std.testing.expect(source.target_tree.eql(actionRequestFixture(null).target_tree));
    try std.testing.expect(source.target_node.eql(schema.nodeIdFromContent(0x1234)));
}

fn actionRequestFixture(data: ?schema.ActionData) schema.ActionRequest {
    return .{
        .action = .click,
        .target_tree = .{ .bytes = .{
            0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
            0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
        } },
        .target_node = schema.nodeIdFromContent(0x1234),
        .data = data,
    };
}

fn actionRequestPayloads(text: []u8) [9]?schema.ActionData {
    return .{
        null,
        .{ .custom_action = -71 },
        .{ .value = text },
        .{ .numeric_value = -13.75 },
        .{ .scroll_unit = .page },
        .{ .scroll_hint = .bottom_edge },
        .{ .scroll_to_point = .{ .x = 1.25, .y = -9.5 } },
        .{ .set_scroll_offset = .{ .x = -0.5, .y = 7.25 } },
        .{ .set_text_selection = .{
            .anchor = .{ .node_id = schema.nodeIdFromContent(0x22), .character_index = 3 },
            .focus = .{ .node_id = schema.nodeIdFromContent(0x33), .character_index = 17 },
        } },
    };
}

fn expectCopiedRequest(source: schema.ActionRequest, copy: *const schema.CActionRequest) !void {
    try std.testing.expectEqual(source.action, copy.action);
    try std.testing.expectEqualSlices(u8, &source.target_tree.bytes, &copy.target_tree.bytes);
    try std.testing.expect(source.target_node.eql(copy.target_node));
    try std.testing.expectEqual(source.data != null, copy.data.has_value);
    const data = source.data orelse return;
    const tag = std.meta.stringToEnum(schema.ActionDataTag, @tagName(data)).?;
    try std.testing.expectEqual(@backingInt(tag), copy.data.value.tag);
    const payload = copy.data.value.payload;
    switch (data) {
        .custom_action => |id| try std.testing.expectEqual(id, payload.custom_action),
        .value => |text| {
            try std.testing.expectEqualStrings(text, std.mem.span(payload.value.?));
            try std.testing.expect(@intFromPtr(text.ptr) != @intFromPtr(payload.value.?));
        },
        .numeric_value => |number| try std.testing.expectEqual(number, payload.numeric_value),
        .scroll_unit => |unit| try std.testing.expectEqual(unit, payload.scroll_unit),
        .scroll_hint => |hint| try std.testing.expectEqual(hint, payload.scroll_hint),
        .scroll_to_point => |point| {
            try std.testing.expectEqual(point.x, payload.scroll_to_point.x);
            try std.testing.expectEqual(point.y, payload.scroll_to_point.y);
        },
        .set_scroll_offset => |point| {
            try std.testing.expectEqual(point.x, payload.set_scroll_offset.x);
            try std.testing.expectEqual(point.y, payload.set_scroll_offset.y);
        },
        .set_text_selection => |selection| {
            try std.testing.expect(selection.anchor.node_id.eql(
                payload.set_text_selection.anchor.node_id,
            ));
            try std.testing.expectEqual(
                selection.anchor.character_index,
                payload.set_text_selection.anchor.character_index,
            );
            try std.testing.expect(selection.focus.node_id.eql(
                payload.set_text_selection.focus.node_id,
            ));
            try std.testing.expectEqual(
                selection.focus.character_index,
                payload.set_text_selection.focus.character_index,
            );
        },
    }
}

fn actionRequestAllocationFailures(gpa: std.mem.Allocator) !void {
    const source_gpa = std.testing.allocator;
    const text = try source_gpa.dupe(u8, "borrowed after allocation failure");
    defer source_gpa.free(text);
    for (actionRequestPayloads(text)) |payload| {
        const source = actionRequestFixture(payload);
        const copy = createActionRequest(gpa, source) catch |err| {
            try std.testing.expectEqualStrings("borrowed after allocation failure", text);
            try std.testing.expectEqual(schema.Action.click, source.action);
            try std.testing.expect(source.target_tree.eql(actionRequestFixture(null).target_tree));
            try std.testing.expect(source.target_node.eql(schema.nodeIdFromContent(0x1234)));
            try std.testing.expectEqual(payload != null, source.data != null);
            if (payload) |data| {
                try std.testing.expectEqual(
                    std.meta.activeTag(data),
                    std.meta.activeTag(source.data.?),
                );
            }
            return err;
        };
        defer gpa.destroy(copy);
        defer schema.cActionRequestDeinit(gpa, copy);
        try expectCopiedRequest(source, copy);
    }
}
