//! The C ABI's node core: the role, the two action masks and the eighteen
//! flags. Sixty-six exports, `include/zaccesskit.h` lines 1786 to 2296.
//!
//! **Why this file stops where it does.** A `schema.Node`
//! (`src/schema/node.zig:98-116`) has five fields: `role`, `actions`,
//! `child_actions`, `flags` and `properties`. This file owns every export that
//! reads or writes one of the first four, and `node_properties.zig` owns every
//! export that goes through the fifth. That is the struct's own seam, so the two
//! files cannot disagree about which side of it a declaration falls on, and a
//! reviewer reading one of them knows the other file is not being read.
//!
//! **The handle is the node.** Upstream's `node` is a zero-sized struct whose
//! only field is `_private: [u8; 0]` (`accesskit-c/src/common.rs:19-21`), and
//! `box_from_ptr` reinterprets it as a `Box<Node>`
//! (`accesskit-c/src/lib.rs:151-156`). So the C pointer IS a `*schema.Node`:
//! there is no side table, no refcount and no second owner, and every function
//! here is a `@ptrCast` off it followed by a field access. The handle type
//! itself is declared once, in `handles.zig`, because
//! three slices name it and a type declared in a leaf module and re-exported
//! upward is how a second declaration happens.
//!
//! **Where every declaration came from.** Each export's doc comment names the
//! `accesskit-c/src/common.rs` line it ports. Most of them are generated: the
//! eighteen flags come from one `flag_methods!` invocation at `:461-480`, so
//! each flag's doc comment names its own tuple line inside that invocation
//! rather than the macro's definition line, because the tuple line is what
//! carries the C name and the Rust method name together.
//!
//! **The `comptime` bound.** There is no loop over a domain anywhere in this
//! file, so no bound is derived here. The three loops that exist in the node
//! family all live in `node_properties.zig`, and each derives its bound in that
//! module's doc comment.
//!
//! **Four rulings, recorded 2026-10-05.** Each was made by the integration owner
//! after this file's first draft raised it, and each is here because a future
//! reader will otherwise "fix" it back.
//!
//! 1. **A void setter that cannot copy sets the error tag and changes nothing.**
//!    The header says "There is no failure path" on all 237 void setters
//!    (`accesskit-c/include/accesskit.h:2841-2842` is the label one), and
//!    `docs/31-c-abi-design.md:77` rule 5 says a void function either cannot
//!    fail or takes a caller precondition. Both are true upstream and neither is
//!    true here: upstream compiles with `panic = "abort"`
//!    (`docs/11-accesskit-c-abi.md:1414-1417`), so an allocation failure there
//!    aborts and has nowhere to report, while `schema.strings.setLabel` is
//!    `error{OutOfMemory}!void` (`src/schema/props/strings.zig:121`). The port
//!    clears the tag on entry and sets `.out_of_memory` on the failing path, so
//!    the property is unchanged and the caller can tell. Discarding the error
//!    instead would need `unreachable`, which `docs/31-c-abi-design.md:77`
//!    rule 6 forbids in every mode. **The header sentence is now false for 237
//!    functions; the port owns one preamble sentence correcting it, and this
//!    file implements that sentence.**
//!
//! 2. **`accesskit_node_transform` returns a pointer, and absent is null.** Its
//!    doc comment (`accesskit-c/include/accesskit.h:4911-4916`) is copy-pasted
//!    from `accesskit_node_bounds` and talks about a `has_value` flag the
//!    return type does not have. The port implements null for absent and says
//!    so at the declaration. The header fix is not this file's to make.
//!
//! 3. **The pushers keep both arms of their error set.** The ten pusher
//!    families return `vectors.ListPushError!void`, which carries
//!    `OutOfMemory` and `PropertyTagMismatch`
//!    (`src/schema/props/vectors.zig:60-70`). `PropertyTagMismatch` is
//!    documented there as unreachable through valid property-store paths.
//!    Each pusher handles both arms explicitly and maps them to
//!    `ACCESSKIT_ERROR_OUT_OF_MEMORY`.
//!
//! 4. **An out-of-range tag byte is a caller precondition, not a failure.** The
//!    header says nothing about a role byte or an action byte past the last
//!    tag, and `accesskit_error` cannot name that case. Every decode here is a
//!    checked gate that returns null, and the export leaves the node unchanged.
//!    That is the second half of `docs/31-c-abi-design.md:77` rule 5, and it is
//!    the only reading that needs no new ABI member.
//!
//! **What this layer never does.** No `zio`, no `io: std.Io`, no clock, no
//! global state, no `unreachable` and no discarded error. Nothing here
//! allocates: the twenty functions that could are the string getters in
//! `node_properties.zig`, and the ten in this file are reads and in-place
//! writes over a block the caller already owns.

const std = @import("std");
const allocation = @import("allocation.zig");
const handles = @import("handles.zig");
const schema = @import("../schema/root.zig");

const Node = schema.Node;
const Role = schema.Role;

/// The number of tags `Role` declares.
///
/// `src/schema/role.zig:329-347` already asserts at compile time that every
/// discriminant is its declaration index, which is what makes the range check
/// in `role_from_c` sufficient. This constant only reads the count, so it
/// cannot drift from that assertion without the assertion failing first.
const role_tag_count = @typeInfo(Role).@"enum".fields.len;

/// Clears the per-thread failure tag, which every export does on entry.
///
/// `accesskit-c/include/accesskit.h:6476-6484` requires it: "Every function
/// clears the tag on entry and sets it on the failing path, so the tag is valid
/// only until the next call on this thread." Without this a getter that answers
/// "absent" would inherit the tag of an earlier failing call and the C caller
/// could not tell the two apart, which is the whole reason the port added the
/// slot. It is one thread-local store and nothing else.
fn enter() void {
    allocation.clearError();
}

/// The node behind a read-only C handle.
///
/// Upstream's handle is a `*Node` already (`accesskit-c/src/common.rs:19-21`
/// with `accesskit-c/src/lib.rs:151-156`), so this is a reinterpretation and
/// nothing else. The `@alignCast` is a real check: `accesskit_node` is opaque
/// and carries alignment 1, while `Node` carries 8, so a handle that is not
/// node-aligned traps here rather than faulting on the first field read.
///
/// Passing a null handle is a caller defect that the header does not describe,
/// so this does not answer for it.
pub fn node_of(handle: *const handles.accesskit_node) *const Node {
    return @ptrCast(@alignCast(handle));
}

/// The node behind a writable C handle.
///
/// Same reinterpretation as `node_of`, and the same alignment check. Writing
/// through the result touches the block the caller owns and never reallocates
/// it, because the block IS the node.
pub fn mutable_node(handle: *handles.accesskit_node) *Node {
    return @ptrCast(@alignCast(handle));
}

/// The role byte `value` names, or `null` when it names no role.
///
/// `docs/31-c-abi-design.md:77` rule 5 and `ruling 4` in this module's doc:
/// `accesskit_node_set_role` takes a caller precondition here, and a byte that
/// names no role leaves the node's role unchanged.
///
/// `schema/role.zig` is the one enum in the port with no `<type>FromInt` gate,
/// because the other seventeen gates live in `node_enums.zig` and
/// `action.zig` and `role.zig` predates them. This is the boundary's decode,
/// and it does not open-code the 182 tags: the range check below is sound
/// because `role.zig:344-346` asserts at compile time that every discriminant
/// equals its declaration index. That is why this is a compare and not the
/// `switch` the other gates are written as
/// (`src/schema/node_enums.zig:203-208`).
///
/// The slot module is this function's proper home, because
/// `accesskit_node_new` takes a role too and its owner must not open-code a
/// second decode. It is `pub` here so that owner can import it today.
pub fn role_from_c(value: u8) ?Role {
    if (value >= role_tag_count) return null;
    return @enumFromInt(value);
}

/// The `hidden` property, read through `is_hidden`.
///
/// Upstream `accesskit-c/src/common.rs:462`, the `is_hidden` tuple of the
/// `flag_methods!` invocation at `:461-480`, expanded by the macro at `:41-57`.
/// The macro body is `node.$getter()` on a `&Node`
/// (`accesskit-c/src/common.rs:45-48`), and `schema.Node` reaches the same mask
/// through `props.flags.isHidden` (`src/schema/props/flags.zig:105`).
///
/// A `false` result is the answer and never a failure, so the tag stays
/// `.none` (`accesskit-c/include/accesskit.h:1867-1872`). The eighteen flags
/// have no unset value, which is why these eighteen getters are a bare `bool`
/// while `expanded` and `selected` are an `accesskit_opt_bool`.
pub export fn accesskit_node_is_hidden(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isHidden(node_of(node).flags);
}

/// Sets the `hidden` property to `true`. Upstream `common.rs:462`.
pub export fn accesskit_node_set_hidden(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setHidden(&mutable_node(node).flags, true);
}

/// Clears the `hidden` property. Upstream `common.rs:462`, via `clearer!` at `:29-39`.
///
/// A flag has no third state: `false` is what the getter already answered, so
/// clearing writes `false` and the getter cannot tell a cleared flag from one
/// that was never set. That is upstream's shape, not a shortcut here.
pub export fn accesskit_node_clear_hidden(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setHidden(&mutable_node(node).flags, false);
}

/// The `multiselectable` property. Upstream `common.rs:463`.
pub export fn accesskit_node_is_multiselectable(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isMultiselectable(node_of(node).flags);
}

/// Sets `multiselectable` to `true`. Upstream `common.rs:463`.
pub export fn accesskit_node_set_multiselectable(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setMultiselectable(&mutable_node(node).flags, true);
}

/// Clears `multiselectable`. Upstream `common.rs:463`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_multiselectable(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setMultiselectable(&mutable_node(node).flags, false);
}

/// The `required` property. Upstream `common.rs:464`.
pub export fn accesskit_node_is_required(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isRequired(node_of(node).flags);
}

/// Sets `required` to `true`. Upstream `common.rs:464`.
pub export fn accesskit_node_set_required(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setRequired(&mutable_node(node).flags, true);
}

/// Clears `required`. Upstream `common.rs:464`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_required(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setRequired(&mutable_node(node).flags, false);
}

/// The `visited` property. Upstream `common.rs:465`.
pub export fn accesskit_node_is_visited(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isVisited(node_of(node).flags);
}

/// Sets `visited` to `true`. Upstream `common.rs:465`.
pub export fn accesskit_node_set_visited(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setVisited(&mutable_node(node).flags, true);
}

/// Clears `visited`. Upstream `common.rs:465`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_visited(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setVisited(&mutable_node(node).flags, false);
}

/// The `busy` property. Upstream `common.rs:466`.
pub export fn accesskit_node_is_busy(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isBusy(node_of(node).flags);
}

/// Sets `busy` to `true`. Upstream `common.rs:466`.
pub export fn accesskit_node_set_busy(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setBusy(&mutable_node(node).flags, true);
}

/// Clears `busy`. Upstream `common.rs:466`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_busy(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setBusy(&mutable_node(node).flags, false);
}

/// The `live_atomic` property. Upstream `common.rs:467`.
pub export fn accesskit_node_is_live_atomic(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isLiveAtomic(node_of(node).flags);
}

/// Sets `live_atomic` to `true`. Upstream `common.rs:467`.
pub export fn accesskit_node_set_live_atomic(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setLiveAtomic(&mutable_node(node).flags, true);
}

/// Clears `live_atomic`. Upstream `common.rs:467`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_live_atomic(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setLiveAtomic(&mutable_node(node).flags, false);
}

/// The `modal` property. Upstream `common.rs:468`.
pub export fn accesskit_node_is_modal(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isModal(node_of(node).flags);
}

/// Sets `modal` to `true`. Upstream `common.rs:468`.
pub export fn accesskit_node_set_modal(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setModal(&mutable_node(node).flags, true);
}

/// Clears `modal`. Upstream `common.rs:468`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_modal(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setModal(&mutable_node(node).flags, false);
}

/// The `touch_transparent` property. Upstream `common.rs:469`.
pub export fn accesskit_node_is_touch_transparent(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isTouchTransparent(node_of(node).flags);
}

/// Sets `touch_transparent` to `true`. Upstream `common.rs:469`.
pub export fn accesskit_node_set_touch_transparent(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setTouchTransparent(&mutable_node(node).flags, true);
}

/// Clears `touch_transparent`. Upstream `common.rs:469`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_touch_transparent(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setTouchTransparent(&mutable_node(node).flags, false);
}

/// The `read_only` property. Upstream `common.rs:470`.
pub export fn accesskit_node_is_read_only(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isReadOnly(node_of(node).flags);
}

/// Sets `read_only` to `true`. Upstream `common.rs:470`.
pub export fn accesskit_node_set_read_only(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setReadOnly(&mutable_node(node).flags, true);
}

/// Clears `read_only`. Upstream `common.rs:470`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_read_only(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setReadOnly(&mutable_node(node).flags, false);
}

/// The `disabled` property. Upstream `common.rs:471`.
pub export fn accesskit_node_is_disabled(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isDisabled(node_of(node).flags);
}

/// Sets `disabled` to `true`. Upstream `common.rs:471`.
pub export fn accesskit_node_set_disabled(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setDisabled(&mutable_node(node).flags, true);
}

/// Clears `disabled`. Upstream `common.rs:471`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_disabled(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setDisabled(&mutable_node(node).flags, false);
}

/// The `italic` property. Upstream `common.rs:472`.
pub export fn accesskit_node_is_italic(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isItalic(node_of(node).flags);
}

/// Sets `italic` to `true`. Upstream `common.rs:472`.
pub export fn accesskit_node_set_italic(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setItalic(&mutable_node(node).flags, true);
}

/// Clears `italic`. Upstream `common.rs:472`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_italic(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setItalic(&mutable_node(node).flags, false);
}

/// The `clips_children` property.
///
/// Upstream `common.rs:473`. The C name has no `is_` and the Rust method is
/// `clips_children` rather than `is_clips_children`
/// (`accesskit-c/src/common.rs:473`), which is why this one does not follow the
/// `is_*` spelling of the seventeen around it.
pub export fn accesskit_node_clips_children(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.clipsChildren(node_of(node).flags);
}

/// Sets `clips_children` to `true`. Upstream `common.rs:473`.
pub export fn accesskit_node_set_clips_children(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setClipsChildren(&mutable_node(node).flags, true);
}

/// Clears `clips_children`. Upstream `common.rs:473`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_clips_children(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setClipsChildren(&mutable_node(node).flags, false);
}

/// The `is_line_breaking_object` property. Upstream `common.rs:474`.
///
/// The property is named `is_line_breaking_object` in the port's property store
/// and its flag is the same word, so the setter's C name carries the `is_` where
/// the other seventeen setters do not (`common.rs:474`,
/// `accesskit-c/include/accesskit.h:2165`).
pub export fn accesskit_node_is_line_breaking_object(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isLineBreakingObject(node_of(node).flags);
}

/// Sets `is_line_breaking_object` to `true`. Upstream `common.rs:474`.
pub export fn accesskit_node_set_is_line_breaking_object(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setLineBreakingObject(&mutable_node(node).flags, true);
}

/// Clears `is_line_breaking_object`. Upstream `common.rs:474`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_is_line_breaking_object(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setLineBreakingObject(&mutable_node(node).flags, false);
}

/// The `is_page_breaking_object` property. Upstream `common.rs:475`.
pub export fn accesskit_node_is_page_breaking_object(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isPageBreakingObject(node_of(node).flags);
}

/// Sets `is_page_breaking_object` to `true`. Upstream `common.rs:475`.
pub export fn accesskit_node_set_is_page_breaking_object(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setPageBreakingObject(&mutable_node(node).flags, true);
}

/// Clears `is_page_breaking_object`. Upstream `common.rs:475`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_is_page_breaking_object(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setPageBreakingObject(&mutable_node(node).flags, false);
}

/// The `is_spelling_error` property. Upstream `common.rs:476`.
pub export fn accesskit_node_is_spelling_error(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isSpellingError(node_of(node).flags);
}

/// Sets `is_spelling_error` to `true`. Upstream `common.rs:476`.
pub export fn accesskit_node_set_is_spelling_error(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setSpellingError(&mutable_node(node).flags, true);
}

/// Clears `is_spelling_error`. Upstream `common.rs:476`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_is_spelling_error(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setSpellingError(&mutable_node(node).flags, false);
}

/// The `is_grammar_error` property. Upstream `common.rs:477`.
pub export fn accesskit_node_is_grammar_error(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isGrammarError(node_of(node).flags);
}

/// Sets `is_grammar_error` to `true`. Upstream `common.rs:477`.
pub export fn accesskit_node_set_is_grammar_error(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setGrammarError(&mutable_node(node).flags, true);
}

/// Clears `is_grammar_error`. Upstream `common.rs:477`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_is_grammar_error(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setGrammarError(&mutable_node(node).flags, false);
}

/// The `is_search_match` property. Upstream `common.rs:478`.
pub export fn accesskit_node_is_search_match(
    node: *const handles.accesskit_node,
) callconv(.c) bool {
    enter();
    return schema.flags.isSearchMatch(node_of(node).flags);
}

/// Sets `is_search_match` to `true`. Upstream `common.rs:478`.
pub export fn accesskit_node_set_is_search_match(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setSearchMatch(&mutable_node(node).flags, true);
}

/// Clears `is_search_match`. Upstream `common.rs:478`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_is_search_match(
    node: *handles.accesskit_node,
) callconv(.c) void {
    enter();
    schema.flags.setSearchMatch(&mutable_node(node).flags, false);
}

/// The `is_suggestion` property. Upstream `common.rs:479`.
pub export fn accesskit_node_is_suggestion(node: *const handles.accesskit_node) callconv(.c) bool {
    enter();
    return schema.flags.isSuggestion(node_of(node).flags);
}

/// Sets `is_suggestion` to `true`. Upstream `common.rs:479`.
pub export fn accesskit_node_set_is_suggestion(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setSuggestion(&mutable_node(node).flags, true);
}

/// Clears `is_suggestion`. Upstream `common.rs:479`, via `clearer!` at `:29-39`.
pub export fn accesskit_node_clear_is_suggestion(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    schema.flags.setSuggestion(&mutable_node(node).flags, false);
}

/// The node's role.
///
/// Upstream `accesskit-c/src/common.rs:391`, a `property_getters!` invocation
/// expanded by the macro at `:106-114` to `node.role().into()`.
///
/// `accesskit-c/include/accesskit.h:1780-1785` states that a node always has a
/// role because `accesskit_node_new` takes it and nothing clears it, so there is
/// no sentinel here and none is needed: this is one of the few getters whose
/// result carries no absence, because the thing it reads has no absent state.
/// The port's `Node.role` is a field rather than a method
/// (`src/schema/node.zig:51-53`, `:99-101`), so the read is the field.
pub export fn accesskit_node_role(node: *const handles.accesskit_node) callconv(.c) u8 {
    enter();
    return @intFromEnum(node_of(node).role);
}

/// Replaces the role.
///
/// Upstream `accesskit-c/src/common.rs:394`, a hand-written `impl node` block
/// whose body is `node.set_role(value)`. The port's equivalent is
/// `schema.Node.setRole` (`src/schema/node.zig:135-137`), which writes the
/// field and allocates nothing.
///
/// `value` is a role byte. A byte that names no role is a caller precondition
/// this function does not check for (`ruling 4` in this module's doc): the
/// node's role is left unchanged and the tag stays `.none`.
pub export fn accesskit_node_set_role(node: *handles.accesskit_node, value: u8) callconv(.c) void {
    enter();
    const role = role_from_c(value) orelse return;
    mutable_node(node).setRole(role);
}

/// Whether `action` is in the set this node supports.
///
/// Upstream `accesskit-c/src/common.rs:402`, an `impl node` block whose body is
/// `node.supports_action(action)` (`accesskit-c/src/common.rs:403-404`). The
/// port reaches the same mask through `schema.Node.supportsAction`
/// (`src/schema/node.zig:140-142`).
///
/// `accesskit-c/include/accesskit.h:1796-1801` states that a `false` result is
/// the answer and never a failure. An `action` byte that names no action also
/// answers `false`, which is honest: no such action is in the set.
pub export fn accesskit_node_supports_action(
    node: *const handles.accesskit_node,
    action: u8,
) callconv(.c) bool {
    enter();
    const wanted = schema.actionFromInt(action) orelse return false;
    return node_of(node).supportsAction(wanted);
}

/// Records that the node accepts `action` from now on.
///
/// Upstream `accesskit-c/src/common.rs:408`. Adding an action the node already
/// accepts changes nothing, because the port's mask is a `u32` and the union is
/// idempotent (`src/schema/node.zig:146-148`).
///
/// An `action` byte that names no action is a caller precondition and changes
/// nothing (`ruling 4`).
pub export fn accesskit_node_add_action(
    node: *handles.accesskit_node,
    action: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.actionFromInt(action) orelse return;
    mutable_node(node).addAction(wanted);
}

/// Withdraws `action` from the node.
///
/// Upstream `accesskit-c/src/common.rs:414`. Removing an action the node never
/// accepted changes nothing (`src/schema/node.zig:152-154`). An `action` byte
/// that names no action changes nothing (`ruling 4`).
pub export fn accesskit_node_remove_action(
    node: *handles.accesskit_node,
    action: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.actionFromInt(action) orelse return;
    mutable_node(node).removeAction(wanted);
}

/// Records that the node accepts no action at all. Upstream `common.rs:420`.
pub export fn accesskit_node_clear_actions(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    mutable_node(node).clearActions();
}

/// Whether `action` is in the set this node's direct children support.
///
/// Upstream `accesskit-c/src/common.rs:428`, whose body is
/// `node.child_supports_action(action)` (`accesskit-c/src/common.rs:432-433`).
/// The doc comment there, carried to
/// `accesskit-c/include/accesskit.h:1831-1835`, says the set is the one in the
/// FILTERED tree, and `src/schema/node.zig:106-108` records the same on the
/// field. This reads the node's own `child_actions` mask and never walks a
/// child, because the node holds the set rather than the children.
pub export fn accesskit_node_child_supports_action(
    node: *const handles.accesskit_node,
    action: u8,
) callconv(.c) bool {
    enter();
    const wanted = schema.actionFromInt(action) orelse return false;
    return node_of(node).childSupportsAction(wanted);
}

/// Records that the node's direct children accept `action`.
///
/// Upstream `accesskit-c/src/common.rs:439`, body `node.add_child_action(action)`
/// (`accesskit-c/src/common.rs:440-441`). An `action` byte that names no action
/// changes nothing (`ruling 4`).
pub export fn accesskit_node_add_child_action(
    node: *handles.accesskit_node,
    action: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.actionFromInt(action) orelse return;
    mutable_node(node).addChildAction(wanted);
}

/// Withdraws `action` from the node's direct children.
///
/// Upstream `accesskit-c/src/common.rs:447`. Removing one the children never
/// accepted changes nothing (`src/schema/node.zig:174-179`). An `action` byte
/// that names no action changes nothing (`ruling 4`).
pub export fn accesskit_node_remove_child_action(
    node: *handles.accesskit_node,
    action: u8,
) callconv(.c) void {
    enter();
    const wanted = schema.actionFromInt(action) orelse return;
    mutable_node(node).removeChildAction(wanted);
}

/// Records that the node's direct children accept no action. Upstream `common.rs:455`.
pub export fn accesskit_node_clear_child_actions(node: *handles.accesskit_node) callconv(.c) void {
    enter();
    mutable_node(node).clearChildActions();
}
// --- The header's return conventions -------------------------------------------
//
// Every test here builds a real `Node` and holds it as a C caller would: a
// `*accesskit_node` pointing at a `Node`. Nothing asserts on a field through a
// side channel where the return value will do, because the C consumer's
// contract is the return value and nothing else.

/// A node as the C caller holds one, plus the ownership to release it.
const Fixture = struct {
    handle: *handles.accesskit_node,

    /// Builds a node with `role` and nothing else, the way `accesskit_node_new`
    /// does, so a test starts from the state a C caller would see.
    fn init(gpa: std.mem.Allocator, role: Role) !Fixture {
        const block = try gpa.create(Node);
        block.* = Node.init(gpa, role);
        return .{ .handle = @ptrCast(block) };
    }

    /// Releases the node and the block, which is what `accesskit_node_free`
    /// does. Kept apart from the handle cast so that a leak in a test is a leak
    /// in the test rather than in the code under it.
    fn deinit(self: Fixture, gpa: std.mem.Allocator) void {
        const block: *Node = @ptrCast(@alignCast(self.handle));
        block.deinit();
        gpa.destroy(block);
    }
};

test "a node built with no flags answers false from all eighteen getters" {
    // The eighteen flags have no unset state, so there is no sentinel to check
    // and `false` is the answer rather than the absence of one. This proves the
    // getters read the mask; the next test proves each reads ITS bit, which
    // this one cannot, because a getter wired to a neighbour's bit also answers
    // false on a node with nothing set.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    try std.testing.expect(!accesskit_node_is_hidden(fixture.handle));
    try std.testing.expect(!accesskit_node_is_multiselectable(fixture.handle));
    try std.testing.expect(!accesskit_node_is_required(fixture.handle));
    try std.testing.expect(!accesskit_node_is_visited(fixture.handle));
    try std.testing.expect(!accesskit_node_is_busy(fixture.handle));
    try std.testing.expect(!accesskit_node_is_live_atomic(fixture.handle));
    try std.testing.expect(!accesskit_node_is_modal(fixture.handle));
    try std.testing.expect(!accesskit_node_is_touch_transparent(fixture.handle));
    try std.testing.expect(!accesskit_node_is_read_only(fixture.handle));
    try std.testing.expect(!accesskit_node_is_disabled(fixture.handle));
    try std.testing.expect(!accesskit_node_is_italic(fixture.handle));
    try std.testing.expect(!accesskit_node_clips_children(fixture.handle));
    try std.testing.expect(!accesskit_node_is_line_breaking_object(fixture.handle));
    try std.testing.expect(!accesskit_node_is_page_breaking_object(fixture.handle));
    try std.testing.expect(!accesskit_node_is_spelling_error(fixture.handle));
    try std.testing.expect(!accesskit_node_is_grammar_error(fixture.handle));
    try std.testing.expect(!accesskit_node_is_search_match(fixture.handle));
    try std.testing.expect(!accesskit_node_is_suggestion(fixture.handle));
}

test "each flag setter turns on exactly its own flag" {
    // One setter and one getter per flag, walked as a table, because this is
    // the only shape that reads a SET flag back: a setter writing the wrong bit,
    // or two flags sharing a bit, passes the all-false test above and fails
    // here. The loop is bounded by the table's own length, which is where the
    // bound comes from.
    const Setter = *const fn (*handles.accesskit_node) callconv(.c) void;
    const Getter = *const fn (*const handles.accesskit_node) callconv(.c) bool;
    const rows = [_]struct { set: Setter, get: Getter }{
        .{ .set = accesskit_node_set_hidden, .get = accesskit_node_is_hidden },
        .{
            .set = accesskit_node_set_multiselectable,
            .get = accesskit_node_is_multiselectable,
        },
        .{ .set = accesskit_node_set_required, .get = accesskit_node_is_required },
        .{ .set = accesskit_node_set_visited, .get = accesskit_node_is_visited },
        .{ .set = accesskit_node_set_busy, .get = accesskit_node_is_busy },
        .{ .set = accesskit_node_set_live_atomic, .get = accesskit_node_is_live_atomic },
        .{ .set = accesskit_node_set_modal, .get = accesskit_node_is_modal },
        .{
            .set = accesskit_node_set_touch_transparent,
            .get = accesskit_node_is_touch_transparent,
        },
        .{ .set = accesskit_node_set_read_only, .get = accesskit_node_is_read_only },
        .{ .set = accesskit_node_set_disabled, .get = accesskit_node_is_disabled },
        .{ .set = accesskit_node_set_italic, .get = accesskit_node_is_italic },
        .{ .set = accesskit_node_set_clips_children, .get = accesskit_node_clips_children },
        .{
            .set = accesskit_node_set_is_line_breaking_object,
            .get = accesskit_node_is_line_breaking_object,
        },
        .{
            .set = accesskit_node_set_is_page_breaking_object,
            .get = accesskit_node_is_page_breaking_object,
        },
        .{ .set = accesskit_node_set_is_spelling_error, .get = accesskit_node_is_spelling_error },
        .{ .set = accesskit_node_set_is_grammar_error, .get = accesskit_node_is_grammar_error },
        .{ .set = accesskit_node_set_is_search_match, .get = accesskit_node_is_search_match },
        .{ .set = accesskit_node_set_is_suggestion, .get = accesskit_node_is_suggestion },
    };
    // Eighteen is a count, so a row added without raising it fails here rather
    // than being walked silently.
    try std.testing.expectEqual(@as(usize, 18), rows.len);

    const gpa = std.testing.allocator;
    for (rows) |row| {
        const fixture = try Fixture.init(gpa, .button);
        defer fixture.deinit(gpa);

        try std.testing.expect(!row.get(fixture.handle));
        row.set(fixture.handle);
        try std.testing.expect(row.get(fixture.handle));
    }
}

test "a cleared flag answers false again" {
    // The clearers are the third of each triple and the only names a C caller
    // cannot reach with `set_x(false)`. They write `false` into the same bit, so
    // a cleared flag and one that was never set are indistinguishable, which is
    // upstream's shape (`src/schema/props/flags.zig` has no third state) and is
    // what this asserts.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_set_hidden(fixture.handle);
    try std.testing.expect(accesskit_node_is_hidden(fixture.handle));
    accesskit_node_clear_hidden(fixture.handle);
    try std.testing.expect(!accesskit_node_is_hidden(fixture.handle));

    accesskit_node_set_is_line_breaking_object(fixture.handle);
    try std.testing.expect(accesskit_node_is_line_breaking_object(fixture.handle));
    accesskit_node_clear_is_line_breaking_object(fixture.handle);
    try std.testing.expect(!accesskit_node_is_line_breaking_object(fixture.handle));
}

test "the role round-trips through its wire byte" {
    // The C side is a bare `uint8_t` (`accesskit-c/include/accesskit.h:674`) and
    // the Zig side an 182-tag enum, so the getter must produce a byte the
    // setter's gate accepts and the setter must produce the byte the getter
    // hands back. `button` is tag 18 and `terminal` is the last at 181, so this
    // covers an interior tag and the top of the range at once.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    try std.testing.expectEqual(@as(u8, 18), accesskit_node_role(fixture.handle));
    accesskit_node_set_role(fixture.handle, 181);
    try std.testing.expectEqual(@as(u8, 181), accesskit_node_role(fixture.handle));
    try std.testing.expectEqual(Role.terminal, node_of(fixture.handle).role);
}

test "a role byte past the last tag leaves the role unchanged" {
    // `ruling 4`: the header says nothing about an out-of-range byte and
    // `accesskit_error` cannot name that case, so this is a caller precondition
    // and the node is left alone. The assertion is on what the getter returns
    // afterwards, because that is all a C caller can see.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_set_role(fixture.handle, 200);
    try std.testing.expectEqual(@as(u8, 18), accesskit_node_role(fixture.handle));
    // 182 is the first byte past the last tag, so this is the boundary itself.
    accesskit_node_set_role(fixture.handle, 182);
    try std.testing.expectEqual(@as(u8, 18), accesskit_node_role(fixture.handle));
    // 255 is the widest byte the C type can carry.
    accesskit_node_set_role(fixture.handle, 255);
    try std.testing.expectEqual(@as(u8, 18), accesskit_node_role(fixture.handle));
}

test "an action byte past the last tag answers false and changes nothing" {
    // The same precondition, answering `false` rather than a tag, because
    // `accesskit-c/include/accesskit.h:1796-1801` says a `false` result is the
    // answer and never a failure. No such action is in any set, so `false` is
    // honest rather than a sentinel standing in for a failure.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    try std.testing.expect(!accesskit_node_supports_action(fixture.handle, 200));
    accesskit_node_add_action(fixture.handle, 200);
    try std.testing.expect(!accesskit_node_supports_action(fixture.handle, 200));
    accesskit_node_remove_action(fixture.handle, 255);
    accesskit_node_add_child_action(fixture.handle, 200);
    try std.testing.expect(!accesskit_node_child_supports_action(fixture.handle, 200));
    accesskit_node_remove_child_action(fixture.handle, 255);
}

test "an action the node accepts is not one its children accept" {
    // The two masks are separate fields (`src/schema/node.zig:103-108`), and a
    // getter that reached the wrong one would answer every test above correctly
    // and this one wrongly. `click` is the first action, so the pair is the
    // simplest case that still separates the two masks.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_add_action(fixture.handle, 0);
    try std.testing.expect(accesskit_node_supports_action(fixture.handle, 0));
    try std.testing.expect(!accesskit_node_child_supports_action(fixture.handle, 0));

    accesskit_node_add_child_action(fixture.handle, 0);
    try std.testing.expect(accesskit_node_child_supports_action(fixture.handle, 0));
}

test "clearing one action set leaves the other alone" {
    // The same separation from the other direction: a `clear_actions` that
    // zeroed both masks passes every test that sets only one and fails this.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_add_action(fixture.handle, 0);
    accesskit_node_add_child_action(fixture.handle, 0);
    accesskit_node_clear_actions(fixture.handle);
    try std.testing.expect(!accesskit_node_supports_action(fixture.handle, 0));
    try std.testing.expect(accesskit_node_child_supports_action(fixture.handle, 0));

    accesskit_node_add_action(fixture.handle, 0);
    accesskit_node_clear_child_actions(fixture.handle);
    try std.testing.expect(accesskit_node_supports_action(fixture.handle, 0));
    try std.testing.expect(!accesskit_node_child_supports_action(fixture.handle, 0));
}

test "removing an action the node never accepted changes nothing" {
    // Upstream's mask operations are idempotent in both directions
    // (`src/schema/node.zig:152-154`, `:174-179`), so this asserts the port kept
    // that rather than an error or a trap.
    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    accesskit_node_remove_action(fixture.handle, 0);
    accesskit_node_remove_child_action(fixture.handle, 0);
    try std.testing.expect(!accesskit_node_supports_action(fixture.handle, 0));
    try std.testing.expect(!accesskit_node_child_supports_action(fixture.handle, 0));
}

test "every export clears the failure tag on entry" {
    // The load-bearing part of the C contract, and the reason
    // `accesskit-c/include/accesskit.h:6476-6484` can say the tag is valid only
    // until the next call. A stale `.out_of_memory` left by an earlier call must
    // not survive into a call that answered normally, or a C caller reading the
    // slot after an ordinary "absent" or "false" would be told the call failed.
    // The tag is poisoned by hand rather than by an induced allocation failure,
    // because a getter that answers "no" must clear the slot even when no
    // allocator is involved at all.
    allocation.failWith(.out_of_memory);

    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    try std.testing.expect(!accesskit_node_is_hidden(fixture.handle));
    try std.testing.expect(allocation.lastError() == .none);

    accesskit_node_set_hidden(fixture.handle);
    try std.testing.expect(allocation.lastError() == .none);

    try std.testing.expectEqual(@as(u8, 18), accesskit_node_role(fixture.handle));
    try std.testing.expect(allocation.lastError() == .none);

    try std.testing.expect(!accesskit_node_supports_action(fixture.handle, 0));
    try std.testing.expect(allocation.lastError() == .none);

    // A call that answered a caller-precondition violation is not a failure
    // either, so it clears the slot the same way.
    accesskit_node_set_role(fixture.handle, 200);
    try std.testing.expect(allocation.lastError() == .none);
}

test "the failure tag survives only until the next call" {
    // The other half of the same contract, which the header words as "Read it
    // immediately after the call that failed and before making another call"
    // (`accesskit-c/include/accesskit.h:6480-6481`). Two calls in a row must not
    // report one tag twice, so a C caller that polls the slot after a null
    // cannot mistake an older failure for the current one.
    allocation.failWith(.out_of_memory);
    try std.testing.expect(allocation.lastError() == .out_of_memory);

    const gpa = std.testing.allocator;
    const fixture = try Fixture.init(gpa, .button);
    defer fixture.deinit(gpa);

    try std.testing.expect(!accesskit_node_is_busy(fixture.handle));
    try std.testing.expect(allocation.lastError() == .none);
}

test "the role gate accepts every tag and rejects every byte past the last" {
    // The comptime sweep `AGENTS.md:107-109` asks for at an enumerable domain,
    // rather than the sampled checks the two role tests above are. Every
    // declared tag goes in and every byte at or past the count is rejected. The
    // bound is the tag count, read from the type rather than written down.
    const fields = @typeInfo(Role).@"enum".fields;
    const every = std.enums.values(Role);
    inline for (fields, 0..) |_, index| {
        const wire: u8 = @intCast(index);
        try std.testing.expectEqual(every[index], role_from_c(wire).?);
    }
    var byte: usize = fields.len;
    while (byte < 256) : (byte += 1) {
        try std.testing.expect(role_from_c(@intCast(byte)) == null);
    }
}
