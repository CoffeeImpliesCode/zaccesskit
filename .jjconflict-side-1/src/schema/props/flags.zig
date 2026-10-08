//! The 18 boolean flags of a node, one bit each in `Node.flags`.
//!
//! A flag has no `PropertyId` and no entry in the property store, so it is
//! reachable only through the one-bit accessors below. The receiver is the mask
//! and not the store, and a caller writes `flags.isHidden(node.flags)`.
//!
//! **Where the bitmask lives.** Upstream keeps the 18 bits in the private
//! `Node.flags` field, and the `flag_methods!` macro at
//! `accesskit/src/lib.rs:1175-1185` reads `self.flags` and writes it. The port
//! keeps that same `u32` and adds no wrapper type, because upstream has none.
//! The field is the `FlagMask` alias of `u32` that
//! `docs/10-accesskit-core.md` section 2.2 records, and the C header exposes the
//! same word as `uint32_t`, so nothing converts at the boundary.
//! `schema/action.zig` makes the same choice for `ActionMask`.
//!
//! A getter takes the mask by value and a setter takes it by pointer. A flag is
//! a `Copy` scalar, so a caller holding a mask in a temporary reads it without
//! storing it first.
//!
//! **Setting a flag to false.** Upstream writes one flag with two methods:
//! `set_x` ors the bit in and `clear_x` ands the complement in. The port keeps
//! both halves in one setter, so `setX(flags, false)` is the clearing call. A
//! setter that only sets cannot express it and is a defect.
//!
//! A flag has no unset value. A node that never carried a bit and a node whose
//! bit was cleared read the same, and the call is `false` in both cases. Every
//! accessor here moves one bit of the 32 and leaves the other 31 alone.
//!
//! These are free functions on the mask because Zig declares a method only
//! inside the body of the type that owns it. `Node` lives in
//! `schema/node.zig`, so a method spelling would either give `Node` 18 thin
//! forwarders or move this module into a file it does not own.
//!
//! `Flag`, its mask helper and the property domain live in `props/table.zig`.
//! `Node` and its `flags` field live in `schema/node.zig`. This module allocates
//! nothing, does no I/O, and takes no allocator and no `io`, so a caller
//! releases nothing after any call here.

const std = @import("std");
const table = @import("table.zig");

const Flag = table.Flag;
const flagMask = table.flagMask;

/// The number of `Flag` members, which is also the bit count of a full mask and
/// the bound on every walk over the domain.
const flagCount = @typeInfo(Flag).@"enum".fields.len;

comptime {
    // Upstream declares 18 members between `lib.rs:802` and `lib.rs:819`, and a
    // member number is its bit position, so a member added or dropped moves the
    // number the C header gives every member after it.
    if (flagCount != 18) {
        @compileError("Flag must carry the 18 members of accesskit/src/lib.rs:802-819");
    }

    // The count above says nothing about the bits. A member number above 31
    // fits no bit of the `u32`, two members sharing one bit leave the union one
    // bit short, and a gap leaves a bit no member holds. Each check below names
    // the defect it catches.
    //
    // Zig already rejects two members with the same tag, so the shared-bit
    // check is what fires if `flagMask` ever stops giving each member its own
    // bit, and it names the pair where the popcount check below only says the
    // count is wrong.
    var seen: u32 = 0;
    for (std.enums.values(Flag)) |member| {
        if (@intFromEnum(member) >= 32) {
            @compileError("a Flag member number does not fit one bit of the u32 mask");
        }
        const bit = flagMask(member);
        if (seen & bit != 0) {
            @compileError("two Flag members share one bit");
        }
        seen |= bit;
    }
    if (@popCount(seen) != flagCount) {
        @compileError("Flag members must occupy 18 distinct bits of the u32 mask");
    }
    if (seen != (@as(u32, 1) << flagCount) - 1) {
        @compileError("Flag member numbers must be dense from 0; the C header numbers by position");
    }
}

/// Whether `flags` carries the bit for `flag`.
fn flagIsSet(flags: u32, flag: Flag) bool {
    return flags & flagMask(flag) != 0;
}

/// Put the bit for `flag` into `flags` when `value` is `true`, and take it out
/// when it is `false`.
fn setFlagBit(flags: *u32, flag: Flag, value: bool) void {
    if (value) {
        flags.* |= flagMask(flag);
    } else {
        flags.* &= ~flagMask(flag);
    }
}

/// Whether this node and its descendants are excluded from the tree presented
/// to assistive technologies and from hit testing.
///
/// ARIA `aria-hidden` covers the assistive-technology half only, and one bit
/// carries both halves, so a consumer cannot ask for one without the other.
pub fn isHidden(flags: u32) bool {
    return flagIsSet(flags, .hidden);
}

/// Exclude this node and its descendants from the tree presented to assistive
/// technologies and from hit testing. `value = false` ends the exclusion.
pub fn setHidden(flags: *u32, value: bool) void {
    setFlagBit(flags, .hidden, value);
}

/// Whether users may select more than one selectable descendant.
///
/// The descendants are at any depth, not only the direct children, and the bit
/// says that more than one is allowed rather than which ones.
pub fn isMultiselectable(flags: u32) bool {
    return flagIsSet(flags, .multiselectable);
}

/// Let users select more than one selectable descendant. `value = false` leaves
/// a single selection.
pub fn setMultiselectable(flags: *u32, value: bool) void {
    setFlagBit(flags, .multiselectable, value);
}

/// Whether user input or selection is required on this node.
///
/// This is the ARIA `aria-required` state, and it constrains the value the node
/// holds rather than the control that holds it.
pub fn isRequired(flags: u32) bool {
    return flagIsSet(flags, .required);
}

/// Require user input or selection on this node. `value = false` lifts the
/// requirement.
pub fn setRequired(flags: *u32, value: bool) void {
    setFlagBit(flags, .required, value);
}

/// Whether this node represents a link that has been visited.
///
/// No ARIA equivalent covers it. The bit is what the platform recorded when the
/// user followed the link, and nothing in the tree recomputes it.
pub fn isVisited(flags: u32) bool {
    return flagIsSet(flags, .visited);
}

/// Record that this node represents a link the user has followed.
/// `value = false` records that the link has not been followed.
pub fn setVisited(flags: *u32, value: bool) void {
    setFlagBit(flags, .visited, value);
}

/// Whether this node is being modified and updates should be withheld until it
/// is ready.
///
/// This is the ARIA `aria-busy` state. The platform withholds the updates while
/// the bit stands and sends them when the bit comes down.
pub fn isBusy(flags: u32) bool {
    return flagIsSet(flags, .busy);
}

/// Withhold updates to this node until it is ready. `value = false` ends the
/// busy state and the withholding that goes with it.
pub fn setBusy(flags: *u32, value: bool) void {
    setFlagBit(flags, .busy, value);
}

/// Whether updates to this live region should be presented as a whole.
///
/// This is the ARIA `aria-atomic` state. It means nothing unless the node also
/// carries the `live` property that makes it a live region.
pub fn isLiveAtomic(flags: u32) bool {
    return flagIsSet(flags, .live_atomic);
}

/// Present updates to this live region as a whole. `value = false` presents
/// them as they arrive.
pub fn setLiveAtomic(flags: *u32, value: bool) void {
    setFlagBit(flags, .live_atomic, value);
}

/// Whether this dialog is modal.
///
/// This is the ARIA `aria-modal` state. It describes how the dialog behaves and
/// says nothing about whether the dialog is open.
pub fn isModal(flags: u32) bool {
    return flagIsSet(flags, .modal);
}

/// Mark this dialog as modal. `value = false` makes it non-modal.
pub fn setModal(flags: *u32, value: bool) void {
    setFlagBit(flags, .modal, value);
}

/// Whether touches pass through this node when a screen reader is in touch
/// exploration mode, as they normally do on a virtual keyboard.
///
/// The pass-through applies to that mode only. A touch outside exploration mode
/// reaches the node as usual.
pub fn isTouchTransparent(flags: u32) bool {
    return flagIsSet(flags, .touch_transparent);
}

/// Let touches pass through this node in touch exploration mode. `value = false`
/// delivers touches to the node.
pub fn setTouchTransparent(flags: *u32, value: bool) void {
    setFlagBit(flags, .touch_transparent, value);
}

/// Whether this text widget permits focus and selection but not editing.
///
/// This is the ARIA `aria-readonly` state. The node stays in the focus order and
/// keeps its selection, which is what a `disabled` node does not.
pub fn isReadOnly(flags: u32) bool {
    return flagIsSet(flags, .read_only);
}

/// Permit focus and selection on this text widget but refuse editing.
/// `value = false` permits editing.
pub fn setReadOnly(flags: *u32, value: bool) void {
    setFlagBit(flags, .read_only, value);
}

/// Whether this control or group of controls is unavailable for interaction.
///
/// This is the ARIA `aria-disabled` state. A control that carries it takes no
/// focus and no input, so a group of them is skipped whole.
pub fn isDisabled(flags: u32) bool {
    return flagIsSet(flags, .disabled);
}

/// Make this control or group of controls unavailable for interaction.
/// `value = false` makes it available again.
pub fn setDisabled(flags: *u32, value: bool) void {
    setFlagBit(flags, .disabled, value);
}

/// Whether this node's text is italic.
///
/// The style belongs to the text and not to the role, so one role carries this
/// bit in one tree and not in another.
pub fn isItalic(flags: u32) bool {
    return flagIsSet(flags, .italic);
}

/// Draw this node's text in italics. `value = false` draws it upright.
pub fn setItalic(flags: *u32, value: bool) void {
    setFlagBit(flags, .italic, value);
}

/// Whether this node clips child content outside its bounds.
///
/// Clipping is a paint decision. The children stay in the tree and stay
/// reachable, and only the part of them that falls outside the bounds is not
/// drawn.
pub fn clipsChildren(flags: u32) bool {
    return flagIsSet(flags, .clips_children);
}

/// Cut off child content that falls outside this node's bounds. `value = false`
/// lets the content draw past the bounds.
pub fn setClipsChildren(flags: *u32, value: bool) void {
    setFlagBit(flags, .clips_children, value);
}

/// Whether this node causes a hard line break.
///
/// The break is hard, so the text after it starts a new line rather than being
/// filled onto the same one as ordinary wrapping does.
pub fn isLineBreakingObject(flags: u32) bool {
    return flagIsSet(flags, .is_line_breaking_object);
}

/// Force a hard line break after this node. `value = false` lets the text wrap
/// normally.
pub fn setLineBreakingObject(flags: *u32, value: bool) void {
    setFlagBit(flags, .is_line_breaking_object, value);
}

/// Whether this node causes a page break.
///
/// The text after the break moves to the next page, so this flag is about
/// pagination and not about line breaking.
pub fn isPageBreakingObject(flags: u32) bool {
    return flagIsSet(flags, .is_page_breaking_object);
}

/// Force a page break after this node. `value = false` lets the text flow across
/// the page boundary.
pub fn setPageBreakingObject(flags: *u32, value: bool) void {
    setFlagBit(flags, .is_page_breaking_object, value);
}

/// Whether this node's text is marked as a spelling error.
///
/// The mark is a separate bit from `isGrammarError`, so a checker reports the
/// two independently and one run of text can be one and not the other.
pub fn isSpellingError(flags: u32) bool {
    return flagIsSet(flags, .is_spelling_error);
}

/// Mark this node's text as a spelling error. `value = false` withdraws the
/// mark.
pub fn setSpellingError(flags: *u32, value: bool) void {
    setFlagBit(flags, .is_spelling_error, value);
}

/// Whether this node's text is marked as a grammar error.
///
/// A separate bit from `isSpellingError`, because the two checks fail on
/// different text and a run of text can fail one and pass the other.
pub fn isGrammarError(flags: u32) bool {
    return flagIsSet(flags, .is_grammar_error);
}

/// Mark this node's text as a grammar error. `value = false` withdraws the mark.
pub fn setGrammarError(flags: *u32, value: bool) void {
    setFlagBit(flags, .is_grammar_error, value);
}

/// Whether this node represents text matching the current search.
///
/// The bit records membership and not the query, so two marked nodes may match
/// different text.
pub fn isSearchMatch(flags: u32) bool {
    return flagIsSet(flags, .is_search_match);
}

/// Mark this node as part of the current search result. `value = false` takes
/// it out of the result.
pub fn setSearchMatch(flags: *u32, value: bool) void {
    setFlagBit(flags, .is_search_match, value);
}

/// Whether this node's text is a suggested replacement.
///
/// One bit carries no alternatives, so a value with several suggestions sends
/// one node per suggestion and each of them carries this bit.
pub fn isSuggestion(flags: u32) bool {
    return flagIsSet(flags, .is_suggestion);
}

/// Mark this node's text as a replacement the platform proposes. `value = false`
/// withdraws the proposal.
pub fn setSuggestion(flags: *u32, value: bool) void {
    setFlagBit(flags, .is_suggestion, value);
}

/// One flag paired with the two accessors that read and write it. The table
/// exists so a comptime sweep and a test can reach all 18 without naming one.
const Accessor = struct {
    flag: Flag,
    get: *const fn (u32) bool,
    set: *const fn (*u32, bool) void,
};

const accessors = [_]Accessor{
    .{ .flag = .hidden, .get = isHidden, .set = setHidden },
    .{ .flag = .multiselectable, .get = isMultiselectable, .set = setMultiselectable },
    .{ .flag = .required, .get = isRequired, .set = setRequired },
    .{ .flag = .visited, .get = isVisited, .set = setVisited },
    .{ .flag = .busy, .get = isBusy, .set = setBusy },
    .{ .flag = .live_atomic, .get = isLiveAtomic, .set = setLiveAtomic },
    .{ .flag = .modal, .get = isModal, .set = setModal },
    .{ .flag = .touch_transparent, .get = isTouchTransparent, .set = setTouchTransparent },
    .{ .flag = .read_only, .get = isReadOnly, .set = setReadOnly },
    .{ .flag = .disabled, .get = isDisabled, .set = setDisabled },
    .{ .flag = .italic, .get = isItalic, .set = setItalic },
    .{ .flag = .clips_children, .get = clipsChildren, .set = setClipsChildren },
    .{
        .flag = .is_line_breaking_object,
        .get = isLineBreakingObject,
        .set = setLineBreakingObject,
    },
    .{
        .flag = .is_page_breaking_object,
        .get = isPageBreakingObject,
        .set = setPageBreakingObject,
    },
    .{ .flag = .is_spelling_error, .get = isSpellingError, .set = setSpellingError },
    .{ .flag = .is_grammar_error, .get = isGrammarError, .set = setGrammarError },
    .{ .flag = .is_search_match, .get = isSearchMatch, .set = setSearchMatch },
    .{ .flag = .is_suggestion, .get = isSuggestion, .set = setSuggestion },
};

const Reading = struct {
    flag: Flag,
    is_set: bool,
};

fn expectFlag(flag: Flag, expected: bool, actual: bool) !void {
    try std.testing.expectEqual(
        Reading{ .flag = flag, .is_set = expected },
        Reading{ .flag = flag, .is_set = actual },
    );
}

test "the accessor table names all 18 flags once" {
    try std.testing.expectEqual(@as(usize, 18), accessors.len);
    try std.testing.expectEqual(flagCount, accessors.len);
}

test "every flag reads false on a mask that was never written" {
    const flags: u32 = 0;
    for (accessors) |accessor| {
        try expectFlag(accessor.flag, false, accessor.get(flags));
    }
}

test "every flag sets and clears its own bit on a fresh mask" {
    for (accessors) |accessor| {
        var flags: u32 = 0;
        accessor.set(&flags, true);
        try expectFlag(accessor.flag, true, accessor.get(flags));
        // One flag set leaves one bit, so a setter that writes a neighbour
        // fails here.
        try std.testing.expectEqual(@as(u32, 1), @popCount(flags));

        accessor.set(&flags, false);
        try expectFlag(accessor.flag, false, accessor.get(flags));
        // A setter that only sets leaves the bit up, so the popcount fails here.
        try std.testing.expectEqual(@as(u32, 0), flags);
    }
}

test "the 18 accessors fill 18 bits of one mask and clear one without the rest" {
    var flags: u32 = 0;
    for (accessors) |accessor| accessor.set(&flags, true);
    try std.testing.expectEqual(@as(u32, 0x0003_ffff), flags);
    for (accessors) |accessor| {
        try expectFlag(accessor.flag, true, accessor.get(flags));
    }

    // Two accessors that address one bit would have left 17 set here, and two
    // flags that share a name in the table would have cleared one another's.
    accessors[0].set(&flags, false);
    try expectFlag(accessors[0].flag, false, accessors[0].get(flags));
    try std.testing.expectEqual(@as(u32, 0x0003_fffe), flags);
    for (accessors[1..]) |accessor| {
        try expectFlag(accessor.flag, true, accessor.get(flags));
    }
}

test "a getter reads only its own bit" {
    // The mask carries every bit except the one under test, so a getter that
    // tested the whole mask or a wrong bit reports true.
    for (accessors) |accessor| {
        var flags: u32 = 0x0003_ffff;
        flags &= ~flagMask(accessor.flag);
        try expectFlag(accessor.flag, false, accessor.get(flags));
    }
}
