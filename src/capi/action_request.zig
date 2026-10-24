//! The C ABI's action side: the custom actions a node declares, the request
//! that carries one action from a platform to the application, and the one C
//! function pointer an application installs to receive it.
//!
//! **Who owns what.** Three values cross this boundary and each has exactly
//! one owner.
//!
//! - The **node list** is `CCustomActions`, the `{length, values}` pair that
//!   `accesskit_node_custom_actions` returns. The library owns the array and
//!   every action in it. A C caller owns the pointer to the struct, and
//!   releases all three with `accesskit_custom_actions_free`, once.
//! - The **argument list** is the payload union inside `CActionData`. No
//!   caller ever owns it and no caller releases it. Seven of the eight
//!   members are numbers copied by value and own nothing. The eighth,
//!   `value`, is the one `char *` the payload carries, and it belongs to the
//!   request that encloses it.
//! - The **action data** is `CActionData`, reached through
//!   `CActionRequest.data`. The library allocates it with the request, and the
//!   callback owns both from the moment the callback receives the request.
//!
//! **What each `*_free` releases.** `accesskit_custom_action_free` releases
//! one action and the `description` buffer it owns.
//! `accesskit_custom_actions_free` releases every action in the list, the
//! `values` array, and the outer struct. `accesskit_action_request_free`
//! releases the request and, when `data.has_value` is true and
//! `data.value.tag` is `ACCESSKIT_ACTION_DATA_VALUE`, the `char *` at
//! `data.value.value` as well. A `char *` this library returned from a getter
//! is released with `accesskit_string_free`, which `src/capi/root.zig` owns.
//! Library memory is never released with `free`.
//!
//! **What this module does not do.** It does not build an action request and
//! it does not read a platform event. `src/adapters/<platform>/` owns the side
//! that turns a platform event into a request, and `src/capi/allocation.zig`
//! owns the declared allocator and the per-thread error tag the two
//! allocating exports below use.
//!
//! **The failure shape.** Two of the nine exports here can fail, and both fail
//! only when the declared allocator cannot supply memory:
//! `accesskit_custom_action_new` returns `null`, and
//! `accesskit_custom_action_description` returns `null`. On both paths the tag
//! is `ACCESSKIT_ERROR_OUT_OF_MEMORY` and `accesskit_last_error` is the only
//! signal that separates the failure from an ordinary answer. The header
//! names `accesskit_last_error` at `include/zaccesskit.h:4995` and `:5029`
//! without saying that it is the only signal.
//!
//! **The one place the header is not clean C.** `accesskit_action_data` at
//! `include/zaccesskit.h:1621-1649` builds its payload from an anonymous union
//! of eight anonymous structs. That is the C11 anonymous-struct extension, so
//! the header parses clean as C11 and warns under `-Wpedantic` as C99 and as
//! C++17. The port keeps the union exactly as the header declares it, because
//! that layout is the contract. `docs/40-capi-build-map.md` section 3.3 owns
//! the measurement and section 7.1 owns the warning counts.
//!
//! **Loop bounds.** No export loops over a domain. Every loop in this file
//! runs inside a test and its bound is a count taken from `@typeInfo`: the
//! payload union declares eight members and `ActionDataTag` declares eight
//! tags, so each sweep is bounded at eight and a ninth is a compile error
//! rather than a silent gap.
//!
//! Upstream: `accesskit-c/src/common.rs:689-798` for the custom actions,
//! `accesskit-c/src/common.rs:1069-1131` for the payload and the request, and
//! `accesskit-c/src/common.rs:1166-1197` for the callback.

const std = @import("std");
const schema = @import("../schema/root.zig");
const allocation = @import("allocation.zig");
const marshal = @import("marshal.zig");

const testing = std.testing;

const ActionDataTag = schema.ActionDataTag;
const ActionDataPayload = schema.ActionDataPayload;
const CActionData = schema.CActionData;
const CActionRequest = schema.CActionRequest;
const CustomAction = schema.CustomAction;
const CCustomActions = marshal.CCustomActions;
const CustomActionHandle = marshal.CustomActionHandle;
const boundary = @import("boundary.zig");

/// Hands `request` to `callback` and passes `userdata` through unchanged.
///
/// `callback` is `boundary.ActionHandler`, the one declaration of
/// `accesskit_action_handler_callback` in this package. This is the only place
/// in the port that calls one, and it exists so the declaration has a single
/// call site a test can drive: a calling convention that nothing calls is a
/// declaration that compiles and then corrupts an adapter's stack.
///
/// The C declaration is `include/zaccesskit.h:1737-1739`, upstream
/// `accesskit-c/src/common.rs:1166-1172`:
///
/// ```c
/// typedef void (*accesskit_action_handler_callback)(
///     struct accesskit_action_request *request, void *userdata);
/// ```
///
/// `callback` runs on the calling thread and returns before this call
/// returns, so `request` is live for the whole call and is the callee's to
/// release. It is never `null`, and the library owns it until the call
/// starts. Ownership moves to the callee, which must release it with
/// `accesskit_action_request_free` before it returns, on every path out of the
/// callback; a callee that keeps the pointer has a use-after-free, and one
/// that releases it twice has a double free. A callee that keeps the contents
/// must copy them first, because the request is unusable once the callback
/// returns.
///
/// `userdata` is the context pointer a platform adapter constructor received,
/// passed through unchanged, and it stays valid until the adapter is released.
///
/// The library calls this on the platform's own thread. The header states a
/// thread for Linux, iOS, tvOS and the Windows subclassing adapter
/// (`include/zaccesskit.h:1732-1734`) and states nothing for macOS, Android
/// and the plain Windows adapter, so a callee may not assume a thread in
/// either case. The callee may reenter the library from this call, and may not
/// assume the callback is not already running on the calling thread. Upstream
/// unwraps the `Option` at `accesskit-c/src/common.rs:1186`, so a null
/// callback aborts the process and never reaches an application.
///
/// This function allocates nothing and cannot fail. Upstream
/// `accesskit-c/src/common.rs:1193-1196` box-allocates the request and hands
/// over the raw pointer.
pub fn callActionHandler(
    callback: boundary.ActionHandler,
    request: *CActionRequest,
    userdata: ?*anyopaque,
) void {
    callback(request, userdata);
}

/// Returns a new custom action carrying `id` and an empty description, or
/// `null` when the declared allocator cannot supply it.
///
/// The caller owns the action and releases it with
/// `accesskit_custom_action_free`, once, unless ownership passes to
/// `accesskit_node_push_custom_action`. Nothing is allocated on the failure
/// path.
///
/// A `null` return means `ACCESSKIT_ERROR_OUT_OF_MEMORY` and nothing else, so
/// `accesskit_last_error` carries nothing this call did not already say. Read
/// it immediately, before any other call on this thread.
///
/// Upstream `accesskit-c/src/common.rs:699-707` builds
/// `CustomAction { id, description: String::new() }` and returns a box. The
/// empty description is upstream's, so this header's "or `null` when the
/// property is unset" at `include/zaccesskit.h:5024` is unreachable here: the
/// property is always set, and `accesskit_custom_action_description` returns a
/// pointer to one 0 byte.
export fn accesskit_custom_action_new(id: c_int) callconv(.c) ?CustomActionHandle {
    allocation.clearError();
    return customActionCreate(allocation.allocator(), id, "") catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
}

/// Releases the action and the `description` buffer it owns, exactly once.
///
/// The declared allocator that created the action is not released. The action
/// is unusable after this call, and a second call on the same pointer is a
/// double free.
///
/// The header states that passing `null` terminates the process
/// (`include/zaccesskit.h:5004`). The parameter is a non-optional pointer for
/// the same reason `cActionRequestDeinit` is one, so a C caller that passes
/// `null` dereferences it and the process ends, as the header says.
export fn accesskit_custom_action_free(action: CustomActionHandle) callconv(.c) void {
    const gpa = allocation.allocator();
    action.deinit(gpa);
    gpa.destroy(action);
}

/// Returns the custom action's identifier.
///
/// The value is copied by value, so no release is owed and no copy must be
/// freed. Allocates nothing and cannot fail.
///
/// Upstream `accesskit-c/src/common.rs:714-718` reads the field.
export fn accesskit_custom_action_id(action: *const CustomAction) callconv(.c) c_int {
    return action.id;
}

/// Sets the custom action's identifier.
///
/// The buffer the action owns is untouched and the action stays usable. The
/// caller keeps ownership of everything it passed earlier, and nothing is
/// retained. Returns nothing and cannot fail.
///
/// Upstream `accesskit-c/src/common.rs:720-724` writes the field.
export fn accesskit_custom_action_set_id(
    action: CustomActionHandle,
    id: c_int,
) callconv(.c) void {
    action.id = id;
}

/// Returns a copy of the `description` property, or `null` when the copy does
/// not fit in memory.
///
/// Release the result with `accesskit_string_free`, once, and never pass it
/// to `free`. The copy borrows nothing from the action, so the action may be
/// released first.
///
/// A description holding an interior 0 byte comes back cut at the first one.
/// `accesskit_custom_action_set_description_with_length` accepts such a value,
/// and the header states the rule at `include/zaccesskit.h:5050-5053`: "A byte
/// string is stored up to the first NUL byte, because a value holding one
/// cannot come back out of a `char *` getter without losing its tail." So a
/// caller that writes an interior 0 byte reads the bytes before it, and a
/// caller that needs the tail must not write one.
///
/// A `null` return carries one meaning here, `ACCESSKIT_ERROR_OUT_OF_MEMORY`.
/// Upstream allows a second, because `accesskit-c/src/common.rs:732` aborts on
/// an interior 0 byte, and this port does not abort at all.
///
/// Upstream `accesskit-c/src/common.rs:726-733`.
export fn accesskit_custom_action_description(
    action: *const CustomAction,
) callconv(.c) ?[*:0]u8 {
    allocation.clearError();
    return marshal.dup_c_string(allocation.allocator(), action.description.items) catch {
        allocation.failWith(.out_of_memory);
        return null;
    };
}

/// Copies the NUL-terminated string `description` into the action's
/// `description`.
///
/// The bytes are stored up to the first 0 byte, because a value holding one
/// cannot come back out of a `char *` getter without losing its tail. That
/// rule is the header's, stated at `include/zaccesskit.h:5051-5052` and
/// `marshal.c_bytes_to_slice` is where it is applied. A `[*:0]` string has no
/// interior 0 byte, so this declaration never has bytes to drop.
///
/// Nothing is retained, so the caller keeps its buffer and may release it as
/// soon as the call returns. The bytes are copied verbatim. Upstream decodes
/// them lossily (`accesskit-c/src/common.rs:741-744`), which replaces invalid
/// UTF-8 with U+FFFD; this header says "copies", so the copy is exact.
///
/// The header states that there is no failure path, which holds for
/// upstream's `String` and not for a Zig allocation. When the copy cannot be
/// allocated the property keeps its previous value and the tag becomes
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY`. That is the only defined behaviour
/// available: the function returns nothing and this module does not abort.
///
/// Upstream `accesskit-c/src/common.rs:735-745`.
export fn accesskit_custom_action_set_description(
    action: CustomActionHandle,
    description: [*:0]const u8,
) callconv(.c) void {
    setDescription(allocation.allocator(), action, marshal.c_string_to_slice(description)) catch {
        allocation.failWith(.out_of_memory);
    };
}

/// Copies `length` bytes from `description` into the action's `description`.
/// `description` need not be NUL-terminated.
///
/// The bytes are stored up to the first 0 byte inside those `length` bytes,
/// for the reason `accesskit_custom_action_set_description` gives. Nothing is
/// retained, so the caller keeps its buffer. The bytes are copied verbatim.
///
/// The failure behaviour is the one `accesskit_custom_action_set_description`
/// states: the property keeps its previous value and the tag becomes
/// `ACCESSKIT_ERROR_OUT_OF_MEMORY`.
///
/// Upstream `accesskit-c/src/common.rs:747-756`, which stores all `length`
/// bytes through `string_from_c_slice` at
/// `accesskit-c/src/lib.rs:216-224`.
export fn accesskit_custom_action_set_description_with_length(
    action: CustomActionHandle,
    description: [*c]const u8,
    length: usize,
) callconv(.c) void {
    const stored = marshal.c_bytes_to_slice(description, length);
    setDescription(allocation.allocator(), action, stored) catch {
        allocation.failWith(.out_of_memory);
    };
}

/// Releases the list, every action in it, and the outer struct, exactly once.
///
/// Every action in `values[0..length]` goes with the list, so the caller must
/// not release one itself after this call. The header states that passing
/// `null` terminates the process (`include/zaccesskit.h:5066`); the parameter
/// is a non-optional pointer, so a C caller that passes `null` dereferences
/// it.
///
/// Upstream `accesskit-c/src/common.rs:771-781`.
export fn accesskit_custom_actions_free(value: *CCustomActions) callconv(.c) void {
    marshal.custom_actions_deinit(allocation.allocator(), value);
}

/// Releases the request and everything it owns, exactly once.
///
/// When `request.data.has_value` is true and `request.data.value.tag` is
/// `ACCESSKIT_ACTION_DATA_VALUE`, this also releases the `char *` at
/// `request.data.value.value`. Do not release that string separately. The
/// seven other payload members hold numbers and own nothing.
///
/// The header states that passing `null` terminates the process
/// (`include/zaccesskit.h:5369`); the parameter is a non-optional pointer for
/// the reason `accesskit_custom_action_free` states.
///
/// The request and its optional string must both come from `allocation.allocator()`.
/// Native input storage stays with its original owner. `boundary.createActionRequest`
/// makes the independent copy that this free releases.
///
/// Upstream `accesskit-c/src/common.rs:1128-1131` drops the box, and that box's
/// payload releases its `char *` through `Drop` at
/// `accesskit-c/src/common.rs:1084-1090`. Upstream's header does not say the
/// string goes with the request; `include/zaccesskit.h:5366-5368` does.
export fn accesskit_action_request_free(request: *CActionRequest) callconv(.c) void {
    const gpa = allocation.allocator();
    schema.cActionRequestDeinit(gpa, request);
    gpa.destroy(request);
}

/// Allocates one custom action handle carrying `id` and `description`.
///
/// `gpa` owns the handle and the description buffer, and the matching release
/// is `accesskit_custom_action_free`. An empty `description` reserves no
/// bytes, so one allocation is the whole cost and a non-empty one adds exactly
/// one more. `error.OutOfMemory` on either leaves nothing behind, because both
/// releases are registered before the call that can fail.
///
/// `description` is stored as given. The byte form the header promises is the
/// caller's to produce, through `marshal.c_bytes_to_slice`.
///
/// The handle is untagged, because `marshal.custom_actions_deinit` releases
/// the handles it walks with `gpa.destroy`, and a tagged and an untagged
/// handle for one C type would make one of the two release paths wrong.
fn customActionCreate(
    gpa: std.mem.Allocator,
    id: c_int,
    description: []const u8,
) CustomAction.InitError!*CustomAction {
    const handle = try gpa.create(CustomAction);
    errdefer gpa.destroy(handle);
    handle.* = try CustomAction.init(gpa, id, description);
    errdefer handle.deinit(gpa);
    return handle;
}

/// Releases a handle `customActionCreate` built, through `gpa`.
///
/// This is the Zig half of `accesskit_custom_action_free` and it exists so a
/// test can give back both halves with one `defer`. Releasing only the
/// description would leave the handle itself allocated, and the leak checker
/// would fail the test that made the handle.
fn releaseCustomAction(gpa: std.mem.Allocator, action: *CustomAction) void {
    action.deinit(gpa);
    gpa.destroy(action);
}

/// Copies the action behind `handle` into storage obtained from `gpa`.
///
/// `handle` is untouched and keeps its own buffer, so the caller keeps
/// releasing it through `accesskit_custom_action_free` or through the list it
/// came from. That is the copy `accesskit_node_set_custom_actions` makes, which
/// the header states at `include/zaccesskit.h:5099` takes ownership of nothing,
/// and upstream's shim clones each element the same way at
/// `accesskit-c/src/common.rs:823`.
///
/// `accesskit_node_push_custom_action` is the other half and is **not** this
/// call: `include/zaccesskit.h:5108` says it takes ownership of the handle, so
/// that one moves the value out through `marshal.actionFromHandle` and releases
/// the block rather than copying it.
///
/// Returns `error.OutOfMemory` when `gpa` cannot supply the description
/// bytes. The call then holds no allocation and the caller owns nothing new,
/// so a caller that has to unwind releases only what it already had.
///
/// `gpa` is first because this is a free function
/// (`AGENTS.md:99`), and the handle is last because it is borrowed.
pub fn customActionClone(
    gpa: std.mem.Allocator,
    handle: *const CustomAction,
) CustomAction.InitError!CustomAction {
    return CustomAction.init(gpa, handle.id, handle.description.items);
}

/// Replaces `action`'s description with `stored`, through `gpa`.
///
/// `stored` is the form the header promises to keep: the bytes before the
/// first 0 byte, which both setters above produce through `marshal` before
/// this call sees them. On `error.OutOfMemory` the previous description stays
/// and nothing is half written, because the replacement is built before the
/// old buffer is released.
///
/// `gpa` comes first because this allocates, and `AGENTS.md` gives every
/// allocating function its allocator as the first parameter. The receiver
/// follows it because the action is what is being written.
fn setDescription(
    gpa: std.mem.Allocator,
    action: *CustomAction,
    stored: []const u8,
) CustomAction.InitError!void {
    // `init` allocates from `gpa` and returns only on success, so `stored`
    // cannot alias the buffer this call is about to release.
    const fresh = try CustomAction.init(gpa, action.id, stored);
    action.deinit(gpa);
    action.* = fresh;
}

comptime {
    // The eight payload members are the anonymous-struct extension the header
    // uses eight times (`include/zaccesskit.h:1623-1648`), and they overlay:
    // every one of them sits at offset 0 of the union. This is the check
    // `src/schema/update.zig` does not make. That module pins the union's
    // size and the tag-to-member pairing, and not where each member lands.
    if (@typeInfo(ActionDataPayload).@"union".field_names.len != 8) @compileError(
        "the header declares eight payload members at include/zaccesskit.h:1623-1648",
    );
    // `@offsetOf` takes a struct and Zig 0.16.0 has no reflection over a union
    // member's offset, so the overlay is pinned through the union's own size
    // and alignment instead. Every member of an `extern union` sits at offset
    // 0; the only way that stops being true is a member given a private
    // offset, and that makes the union larger than its widest member. So the
    // invariant is: the union is exactly the widest member, at that member's
    // alignment. The widest is `set_text_selection` at 32 bytes, and
    // `src/schema/update.zig:562-563` already pins the same two numbers, so a
    // disagreement between the two modules is a compile error in one of them.
    if (@sizeOf(ActionDataPayload) != @sizeOf(schema.TextSelection)) @compileError(
        "the payload union must be exactly its widest member, " ++
            "or a member sits at a non-zero offset",
    );
    if (@alignOf(ActionDataPayload) != @alignOf(schema.TextSelection)) @compileError(
        "the payload union must carry the strictest alignment among its members",
    );
    // Tag `n` selects member `n`, because the header numbers the eight tags at
    // `include/zaccesskit.h:1594-1605` and lists the eight payload members at
    // `:1624-1647` in the same order. The `comptime` loop is what lets a ninth
    // tag pair itself with an eighth member instead of failing here.
    const tag_fields = @typeInfo(ActionDataTag).@"enum";
    const member_fields = @typeInfo(ActionDataPayload).@"union";
    for (tag_fields.field_names, tag_fields.field_values, member_fields.field_names, 0..) |tag_name, tag_value, member_name, index| {
        if (tag_value != index) @compileError("ActionDataTag is out of order");
        if (!std.mem.eql(u8, tag_name, member_name)) @compileError(
            "ActionDataTag names a member the payload union does not declare",
        );
    }
    // The tag enum is a C enum with no fixed base, so the port pins its width
    // at `c_uint`. This is the number most likely to move on another target.
    if (@sizeOf(ActionDataTag) != @sizeOf(c_uint)) @compileError(
        "ActionDataTag must be the width of c_uint, which the port pins",
    );
}

test "the callback runs through the declared type and sees both arguments" {
    var seen: SeenRequest = .{};
    var request: CActionRequest = .{
        .action = .replace_selected_text,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 42 },
        .data = .{
            .has_value = true,
            .value = .{
                .tag = @backingInt(ActionDataTag.numeric_value),
                .payload = .{ .numeric_value = 3.5 },
            },
        },
    };

    const handler: boundary.ActionHandler = &recordRequest;
    callActionHandler(handler, &request, &seen);

    try testing.expectEqual(@as(usize, 1), seen.calls);
    try testing.expectEqual(schema.Action.replace_selected_text, seen.action);
    try testing.expectEqual(@as(u64, 42), seen.target_node.value);
    try testing.expectEqual(@as(c_uint, @backingInt(ActionDataTag.numeric_value)), seen.tag);
    try testing.expectEqual(@as(f64, 3.5), seen.numeric_value);
    try testing.expectEqual(@as(*SeenRequest, &seen), seen.self);
}

test "the callback type is the header's declaration, not a near match" {
    // The header writes `struct accesskit_action_request *request, void *userdata`
    // with a `void` return. A wrong calling convention, a swapped argument
    // order or a missing `const` on the pointer compiles and then corrupts the
    // adapter's stack, so each coercion below checks one end of that claim and
    // a mismatch is a compile error rather than a test failure.
    const handler: boundary.ActionHandler = &recordRequest;
    const spelled: *const fn (*CActionRequest, ?*anyopaque) callconv(.c) void = handler;
    const again: boundary.ActionHandler = spelled;

    try testing.expectEqual(handler, again);
    try testing.expectEqual(@sizeOf(usize), @sizeOf(boundary.ActionHandler));
}

test "the payload union overlays, so a tag read picks up the member it names" {
    // Three writes that differ in type and in width, so a member that moved to
    // its own offset would read the wrong bytes for at least one of them.
    var data: CActionData = undefined;
    data.tag = @backingInt(ActionDataTag.custom_action);
    data.payload.custom_action = 7;
    try testing.expectEqual(@as(i32, 7), data.payload.custom_action);

    data.tag = @backingInt(ActionDataTag.numeric_value);
    data.payload.numeric_value = 1.5;
    try testing.expectEqual(@as(f64, 1.5), data.payload.numeric_value);

    // The widest member, at 32 bytes, is the one a struct-shaped payload would
    // push past the union.
    const selection = zeroSelection();
    data.tag = @backingInt(ActionDataTag.set_text_selection);
    data.payload.set_text_selection = selection;
    try testing.expect(data.payload.set_text_selection.eql(selection));
    try testing.expectEqual(@as(usize, 32), @sizeOf(schema.TextSelection));
    try testing.expectEqual(@as(usize, 32), @sizeOf(ActionDataPayload));

    // Two members read through the other's tag, and both are one byte, so the
    // check holds on any endianness. This is the only empirical proof that the
    // eight overlay rather than merely that the union is the right size: a
    // union with a private offset per member would still be 32 bytes.
    const as_unit = schema.ScrollUnit;
    const as_hint = schema.ScrollHint;
    // Both directions use a value the two enumerations share, because a cross
    // read of a number one of them does not declare is itself a trap.
    data.payload.scroll_unit = .page;
    const unit_bits = @backingInt(data.payload.scroll_unit);
    try testing.expectEqual(as_hint.bottom_right, @as(as_hint, @fromBackingInt(@intCast(unit_bits))));
    data.payload.scroll_hint = .top_left;
    const hint_bits = @backingInt(data.payload.scroll_hint);
    try testing.expectEqual(as_unit.item, @as(as_unit, @fromBackingInt(@intCast(hint_bits))));
}

test "every tag names its own payload member and no ninth one appears" {
    // The bound is the count itself, so a ninth member is the `comptime` error
    // above rather than a silent gap here. `inline for` is what makes `tag`
    // comptime-known: `@typeInfo` gives back a struct field that requires
    // comptime, so a plain `for` cannot read `tag.value`.
    const members = @typeInfo(ActionDataPayload).@"union";
    const tags = @typeInfo(ActionDataTag).@"enum";
    try testing.expectEqual(members.field_names.len, tags.field_names.len);

    inline for (tags.field_names, tags.field_values, members.field_names, 0..) |tag_name, tag_value, member_name, index| {
        try testing.expectEqualStrings(tag_name, member_name);
        try testing.expectEqual(index, tag_value);
    }
}

test "the request free releases the string the value payload carries" {
    var request: CActionRequest = .{
        .action = .replace_selected_text,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 1 },
        .data = .{ .has_value = true, .value = undefined },
    };
    // `actionDataToC` allocates the string through the leak-detecting
    // allocator, and a leak there is a leak here: the teardown runs against
    // the same one.
    // `ActionData.value` is `[]u8`, so the text is a mutable array rather
    // than a string literal.
    var text: [5]u8 = "typed".*;
    request.data.value = try schema.actionDataToC(testing.allocator, .{ .value = &text });

    schema.cActionRequestDeinit(testing.allocator, &request);

    // The request is `undefined` afterward, so the assertion that matters is
    // the one the leak check makes at the end of this test.
    try testing.expectEqual(@as(usize, 80), @sizeOf(CActionRequest));
}

test "a request with a number payload frees nothing and stays readable" {
    // Seven of the eight payload members own nothing, so the teardown must
    // leave the rest of the request readable.
    var request: CActionRequest = .{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 9 },
        .data = .{
            .has_value = true,
            .value = .{
                .tag = @backingInt(ActionDataTag.custom_action),
                .payload = .{ .custom_action = 3 },
            },
        },
    };

    schema.cActionRequestDeinit(testing.allocator, &request);

    try testing.expectEqual(@as(usize, 32), @offsetOf(CActionRequest, "data"));
    // `docs/40-capi-build-map.md` section 3.2 lists `accesskit_action_request`
    // with a payload offset of 1 and says in so many words that the column is a
    // documentation artefact: `target_tree` is a `uint8_t[16]` at alignment 1
    // and lands on offset 1. The node id follows it, at 24.
    try testing.expectEqual(@as(usize, 24), @offsetOf(CActionRequest, "target_node"));
}

test "the constructor allocates one handle and leaks nothing when it fails" {
    // `customActionCreate` makes one allocation for the handle and none for
    // the empty description, so index 1 is the first one that succeeds.
    // Raising the bound would let a second allocation go unnoticed, and
    // lowering it to 0 would stop covering `error.OutOfMemory`.
    const first_success_index: usize = 1;

    var fail_index: usize = 0;
    while (fail_index <= first_success_index) : (fail_index += 1) {
        var failing: std.testing.FailingAllocator = .init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const outcome = customActionCreate(failing.allocator(), 5, "");
        if (fail_index == 0) {
            try testing.expectError(error.OutOfMemory, outcome);
            continue;
        }
        const action = try outcome;
        defer releaseCustomAction(testing.allocator, action);
        try testing.expectEqual(@as(i32, 5), action.id);
        try testing.expectEqual(@as(usize, 0), action.description.items.len);
    }
}

test "every refused description copy leaves the previous one in place" {
    // `setDescription` makes one allocation for a non-empty description, so
    // index 1 is the first one that succeeds.
    const first_success_index: usize = 1;

    var fail_index: usize = 0;
    while (fail_index <= first_success_index) : (fail_index += 1) {
        const action = try customActionCreate(testing.allocator, 1, "");
        defer releaseCustomAction(testing.allocator, action);
        try setDescription(testing.allocator, action, "first");

        var failing: std.testing.FailingAllocator = .init(
            testing.allocator,
            .{ .fail_index = fail_index },
        );
        const outcome = setDescription(failing.allocator(), action, "second");
        if (fail_index == 0) {
            try testing.expectError(error.OutOfMemory, outcome);
            try testing.expectEqualStrings("first", action.description.items);
            continue;
        }
        try outcome;
        try testing.expectEqualStrings("second", action.description.items);
    }
}

test "the setters store at most the bytes before the first 0 byte" {
    // `include/zaccesskit.h:5051-5052` states the rule and upstream does not
    // keep it: `accesskit-c/src/common.rs:755` stores every byte and the getter
    // then aborts at `:732`. The divergence is deliberate, so it is checked
    // here through the conversion both setters share.
    const action = try customActionCreate(testing.allocator, 1, "");
    defer releaseCustomAction(testing.allocator, action);

    try setDescription(testing.allocator, action, marshal.c_bytes_to_slice("keep\x00drop", 9));
    try testing.expectEqualStrings("keep", action.description.items);

    try setDescription(testing.allocator, action, marshal.c_bytes_to_slice("keep", 4));
    try testing.expectEqualStrings("keep", action.description.items);

    try setDescription(testing.allocator, action, "");
    try testing.expectEqualStrings("", action.description.items);
}

test "the two exports that can fail balance through the declared allocator" {
    // Every allocation a C caller receives and every one it releases has to
    // come from the same allocator, and this is the only test that drives the
    // real `export fn` bodies instead of the gpa-taking helpers. The declared
    // allocator is the C one, so this test checks pairing and not for leaks;
    // the leak checks above run against `std.testing.allocator`.
    const action = accesskit_custom_action_new(11) orelse return error.NewReturnedNull;
    defer accesskit_custom_action_free(action);

    accesskit_custom_action_set_description(action, "drag");
    try testing.expectEqual(@as(c_int, 11), accesskit_custom_action_id(action));

    const text = accesskit_custom_action_description(action) orelse
        return error.NewReturnedNull;
    try testing.expectEqualStrings("drag", std.mem.span(text));
    marshal.string_free(allocation.allocator(), text);

    accesskit_custom_action_set_id(action, 12);
    try testing.expectEqual(@as(c_int, 12), accesskit_custom_action_id(action));

    // The interior-0-byte round trip, through the two exports that can carry
    // one. The `_with_length` setter takes it and the getter cuts it, which is
    // what `include/zaccesskit.h:5050-5053` states. Reading it back whole is
    // the behaviour a C consumer must not rely on.
    accesskit_custom_action_set_description_with_length(action, "keep\x00drop", 9);
    const cut = accesskit_custom_action_description(action) orelse
        return error.NewReturnedNull;
    try testing.expectEqualStrings("keep", std.mem.span(cut));
    marshal.string_free(allocation.allocator(), cut);
}

test "the list free walks the actions, the array and the outer struct" {
    // `accesskit_custom_actions_free` is the one export that reaches through a
    // caller-supplied length, so it is driven with a list this test builds
    // through the same allocator the export reads. A release path that walked
    // one element too many, or not far enough, faults here rather than in an
    // adapter.
    const gpa = allocation.allocator();
    const length: usize = 2;
    const list = try gpa.create(CCustomActions);
    errdefer gpa.destroy(list);
    const slots = try gpa.alloc(?*CustomAction, length);
    errdefer gpa.free(slots);
    // The slots above `written` stay uninitialised on a refusal, and
    // `custom_actions_deinit` unwraps every slot, so the unwind counts what
    // was written rather than what was allocated.
    var written: usize = 0;
    errdefer {
        var index: usize = 0;
        while (index < written) : (index += 1) {
            // A slot below `written` holds the action this loop built and a
            // slot above it was never assigned, so the capture is the question
            // and the unwrap would have been the answer.
            if (slots[index]) |held| {
                held.deinit(gpa);
                gpa.destroy(held);
            }
        }
    }
    while (written < length) : (written += 1) {
        slots[written] = try customActionCreate(gpa, @intCast(written), "drag");
    }
    list.* = .{ .length = length, .values = @ptrCast(slots.ptr) };

    accesskit_custom_actions_free(list);
}

test "the public request free releases an independent copy through the installed C domain" {
    // A separate source allocator must not become the callback's release domain.
    const Domain = struct {
        blocks: [2]?[]align(16) u8 = .{ null, null },

        const Self = @This();

        fn alloc(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
            const self: *Self = @ptrCast(@alignCast(context.?));
            for (&self.blocks) |*block| {
                if (block.* == null) {
                    const bytes = std.testing.allocator.alignedAlloc(u8, .@"16", size) catch
                        return null;
                    block.* = bytes;
                    return bytes.ptr;
                }
            }
            return null;
        }

        fn free(pointer: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(context.?));
            for (&self.blocks) |*block| {
                if (block.*) |bytes| {
                    if (@intFromPtr(bytes.ptr) == @intFromPtr(pointer.?)) {
                        std.testing.allocator.free(bytes);
                        block.* = null;
                        return;
                    }
                }
            }
            @panic("Request released outside its installed C allocator domain");
        }
    };
    const Capture = struct {
        calls: usize = 0,
        action: schema.Action = .click,
        target_tree: schema.TreeId = schema.tree_id_root,
        target_node: schema.NodeId = schema.nodeIdFromContent(0),
        text: [5]u8 = undefined,
        has_text: bool = false,

        const Self = @This();

        fn receive(owned: *CActionRequest, context: ?*anyopaque) callconv(.c) void {
            defer accesskit_action_request_free(owned);
            const self: *Self = @ptrCast(@alignCast(context.?));
            self.calls += 1;
            self.action = owned.action;
            self.target_tree = owned.target_tree;
            self.target_node = owned.target_node;
            if (!owned.data.has_value) return;
            if (owned.data.value.tag != @backingInt(schema.ActionDataTag.value)) return;
            const pointer = owned.data.value.payload.value orelse return;
            const text = std.mem.span(pointer);
            if (text.len != self.text.len) return;
            @memcpy(&self.text, text);
            self.has_text = true;
        }
    };
    var domain: Domain = .{};
    allocation.installAllocator(Domain.alloc, Domain.free, &domain);
    defer allocation.installAllocator(null, null, null);
    var source: schema.ActionRequest = .{
        .action = .replace_selected_text,
        .target_tree = schema.tree_id_root,
        .target_node = schema.nodeIdFromContent(3),
        .data = .{ .value = try std.testing.allocator.dupe(u8, "typed") },
    };
    var source_live = true;
    defer if (source_live) source.deinit(std.testing.allocator);
    const request = try boundary.createActionRequest(allocation.allocator(), source);
    try std.testing.expect(@intFromPtr(source.data.?.value.ptr) !=
        @intFromPtr(request.data.value.payload.value.?));
    source.deinit(std.testing.allocator);
    source_live = false;

    var seen: Capture = .{};
    callActionHandler(&Capture.receive, request, &seen);
    try testing.expectEqual(@as(usize, 1), seen.calls);
    try testing.expect(seen.has_text);
    try testing.expectEqualStrings("typed", &seen.text);
    try testing.expectEqual(schema.Action.replace_selected_text, seen.action);
    try testing.expect(seen.target_tree.eql(schema.tree_id_root));
    try testing.expect(seen.target_node.eql(schema.nodeIdFromContent(3)));
    for (domain.blocks) |block| try std.testing.expect(block == null);
}

/// What one callback call observed, reached through `userdata`.
const SeenRequest = struct {
    calls: usize = 0,
    self: ?*SeenRequest = null,
    action: schema.Action = .click,
    target_node: schema.NodeId = .{ .value = 0 },
    tag: c_uint = 0,
    numeric_value: f64 = 0,
    text: ?[*:0]const u8 = null,
};

/// The callback body the two callback tests install.
///
/// It runs on the calling thread inside `callActionHandler` and only reads the
/// request. A real application releases the request here; these tests do not,
/// because the request the first one passes is a stack value. It reads two of
/// the eight payload members and no others, because reading a member the tag
/// does not name is the undefined behaviour `include/zaccesskit.h:1611-1613`
/// warns about.
fn recordRequest(request: *CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
    const seen: *SeenRequest = @ptrCast(@alignCast(userdata orelse return));
    seen.calls += 1;
    seen.self = seen;
    seen.action = request.action;
    seen.target_node = request.target_node;
    if (!request.data.has_value) return;
    seen.tag = request.data.value.tag;
    if (request.data.value.tag == @backingInt(ActionDataTag.value)) {
        seen.text = request.data.value.payload.value;
    }
    if (request.data.value.tag == @backingInt(ActionDataTag.numeric_value)) {
        seen.numeric_value = request.data.value.payload.numeric_value;
    }
}

/// A `TextSelection` at offset zero of the root run, which is the one value
/// every field of it can be compared against.
fn zeroSelection() schema.TextSelection {
    const root = schema.nodeIdFromContent(0);
    return .{
        .anchor = .{ .node_id = root, .character_index = 0 },
        .focus = .{ .node_id = root, .character_index = 0 },
    };
}
