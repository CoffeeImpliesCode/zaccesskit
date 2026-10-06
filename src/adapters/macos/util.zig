//! The conversions of `AK/macos/src/util.rs` that need no AppKit object of the
//! caller, and the `NSRange` and `NSRect` they answer.
//!
//! **What this module is.** `NSRange`, `from_ns_range`, `to_ns_range` and
//! `to_ns_range_for_character`, at `AK/macos/src/util.rs:13-36`; `NSPoint`,
//! `NSSize`, `NSRect`, `to_ns_rect`, at `:57-83`; and `color_channel_to_f64` and
//! `to_color_attribute`, at `:83-85` and `:97-108`. `from_ns_point`, the sixth
//! function in that file, is not here: it goes through `NSView` and `NSWindow`
//! and `root.zig:136` and `root.zig:699` record where it went.
//!
//! **The platform is a parameter and not a global.** `to_ns_rect` makes five
//! message sends and `to_color_attribute` makes one, so each takes a table of
//! function pointers: `RectPlatform` and `ColorPlatform`. A table is a
//! parameter, so a test builds its own and hands it in, and no module holds a
//! live platform. **Nothing calls either function yet.** The four callers of
//! `to_ns_rect` and the four callers of `to_color_attribute` are bodies of the
//! `declare_class!` node at `AK/macos/src/node.rs`, which this host has no
//! `NSAccessibility` to send to, so the functions wait for it.
//!
//! **Who calls the conversions that do have callers.** `AK/macos/src/node.rs:786`,
//! `:812`, `:833`, `:844`, `:858`, `:1003`, `:1023` and `:1035`, which are the
//! bodies of `accessibilitySelectedTextRange`, `accessibilityRangeForLine:`,
//! `accessibilityRangeForPosition:`, `accessibilityAttributedStringForRange:`,
//! `accessibilityFrameForRange:` and the three index selectors. The port holds
//! those nine selectors as table rows in `attributes.zig` with no body, because
//! answering them needs an Objective-C object.
//!
//! **The units.** An `NSRange` counts UTF-16 code units, and so does
//! `text.position.toGlobalUtf16Index` and `text.query`'s
//! `textPositionFromGlobalUtf16Index`. A document of three ASCII characters
//! answers the same number under both readings, so a test that uses ASCII alone
//! cannot tell the two units apart; the test below uses an astral character for
//! exactly that reason. An `NSRect` is measured in points and a `Rect` in
//! physical pixels, which is why `toNsRect` divides by the backing scale.
//!
//! **The allocator.** `toNsRange` allocates nothing, because
//! `toGlobalUtf16Index` walks the text runs and builds no key. The other two
//! text functions build a `Range`, and the port's `range.toDegenerateRange`
//! builds two ordering keys, so both take `gpa` first where upstream takes only
//! a position. `toNsRect` and `toNsColorAttribute` allocate nothing.
//!
//! **The loop bound.** No loop is written here. Every walk is inside the
//! consumer, which bounds its own.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const Allocator = std.mem.Allocator;
const NodeRef = consumer.node_id.NodeRef;
const Position = consumer.text.position.Position;
const QueryError = consumer.tree_state.QueryError;
const Range = consumer.text.range.Range;
const testing = std.testing;

/// What the three conversions can report.
///
/// `QueryError` is the consumer's own: a walk that reached its bound, or a
/// document index the tree does not hold. `RangeOverflow` is the one tag this
/// module adds, and `std.math.add` raises it. Upstream adds the two indices with
/// `+` on a `usize`, which panics on overflow in a debug build; a port turns a
/// panic into an error and names it here.
pub const UtilError = QueryError || error{
    /// `location + length` does not fit in a `usize`, so the range names an end
    /// no document can hold.
    RangeOverflow,
};

/// `NSRange`, a location and a length in UTF-16 code units.
///
/// `Foundation` declares both fields as `NSUInteger`, and
/// `AK/macos/src/util.rs:27` builds one from a `usize` pair, so both are
/// `usize`. **Unverified**: no macOS SDK is installed on this host, so
/// `NSRange.h` was not read.
pub const NsRange = extern struct {
    /// Where the range starts, in UTF-16 code units from the start of the
    /// document.
    location: usize,
    /// How many UTF-16 code units the range names.
    length: usize,
};

/// The text range `ns_range` names, or `null` when the document holds no
/// position at one of its two ends.
///
/// Upstream `AK/macos/src/util.rs:13-22`. A zero length leaves the range
/// degenerate, which is upstream's `if ns_range.length > 0`, and a non-zero one
/// moves the end to the position at `location + length`.
pub fn fromNsRange(
    gpa: Allocator,
    node: NodeRef,
    ns_range: NsRange,
) UtilError!?Range {
    const position = try consumer.text.query.textPositionFromGlobalUtf16Index(
        node,
        ns_range.location,
    ) orelse return null;
    var range = try consumer.text.range.toDegenerateRange(gpa, position);
    if (ns_range.length > 0) {
        const end_index = std.math.add(usize, ns_range.location, ns_range.length) catch
            return error.RangeOverflow;
        const end = try consumer.text.query.textPositionFromGlobalUtf16Index(
            node,
            end_index,
        ) orelse return null;
        try consumer.text.range.setEnd(gpa, &range, end);
    }
    return range;
}

/// The `NSRange` `range` names, upstream `AK/macos/src/util.rs:24-28`.
///
/// The length is the difference of the two indices, which is what
/// `NSRange::from(start..end)` builds at `:27`. A range whose end precedes its
/// start cannot be built by this port, because `range.setEnd` moves the start
/// onto the end rather than inverting the two, so the length is never negative.
pub fn toNsRange(range: Range) UtilError!NsRange {
    const start = try consumer.text.position.toGlobalUtf16Index(
        consumer.text.range.start(range),
    );
    const end = try consumer.text.position.toGlobalUtf16Index(consumer.text.range.end(range));
    return .{ .location = start, .length = end - start };
}

/// The `NSRange` one character at `position` names, upstream
/// `AK/macos/src/util.rs:30-36`.
///
/// A position at the end of the document has no character after it, so the range
/// is degenerate, which is upstream's `if !pos.is_document_end()`. Every other
/// position runs the range to the end of its character, and an astral character
/// spans two UTF-16 code units, so the length is two and not one.
pub fn toNsRangeForCharacter(gpa: Allocator, position: Position) UtilError!NsRange {
    var range = try consumer.text.range.toDegenerateRange(gpa, position);
    if (!try consumer.text.position.isDocumentEnd(position)) {
        try consumer.text.range.setEnd(
            gpa,
            &range,
            try consumer.text.position.forwardToCharacterEnd(position),
        );
    }
    return toNsRange(range);
}

// --- to_ns_rect -----------------------------------------------------------------

/// `NSPoint`, the two doubles of `NSGeometry.h`.
///
/// **Unverified**: no macOS SDK is installed on this host, so `NSGeometry.h`
/// was not read. `attributes.frame_zero` is a `[4]f64` and
/// `accesskit_macos_adapter_frame` answers it for a node that is gone, so the
/// port reads an `NSRect` as four doubles in this order.
pub const NsPoint = extern struct {
    /// The horizontal coordinate.
    x: f64,
    /// The vertical coordinate.
    y: f64,
};

/// `NSSize`, the two doubles of `NSGeometry.h`. Unverified, as `NsPoint` is.
pub const NsSize = extern struct {
    /// How wide the box is.
    width: f64,
    /// How tall the box is.
    height: f64,
};

/// `NSRect`, an origin and a size. Unverified, as `NsPoint` is.
pub const NsRect = extern struct {
    /// The corner the box starts at.
    origin: NsPoint,
    /// How far the box runs from its origin.
    size: NsSize,
};

comptime {
    // The layout pin. `AK/macos/src/util.rs:60-77` fills the four members by
    // name, so a reordering here would not change a field name and would change
    // what a host writes into the struct.
    std.debug.assert(@sizeOf(NsPoint) == 16);
    std.debug.assert(@sizeOf(NsSize) == 16);
    std.debug.assert(@sizeOf(NsRect) == 32);
    std.debug.assert(@offsetOf(NsRect, "origin") == 0);
    std.debug.assert(@offsetOf(NsRect, "size") == 16);
    std.debug.assert(@offsetOf(NsRect, "size") + @sizeOf(NsSize) == @sizeOf(NsRect));
}

/// The AppKit sends `toNsRect` makes, one entry per upstream message send.
///
/// The table is a parameter, so no module holds a live AppKit and a test builds
/// its own. `ptr` is the callee's own state and reaches every entry unchanged,
/// which is the shape `root.zig:117` gives the five calls of `Host`.
pub const RectPlatform = struct {
    /// The callee's own state, passed to every call unchanged.
    ptr: ?*anyopaque,
    /// `[view window]`, read at `AK/macos/src/util.rs:58` and again at `:79`.
    window_of: *const fn (?*anyopaque, ?*anyopaque) ?*anyopaque,
    /// `[window backingScaleFactor]`, at `:62`.
    backing_scale_factor: *const fn (?*anyopaque, ?*anyopaque) f64,
    /// `[view isFlipped]`, at `:66` and again at `:69`.
    is_flipped: *const fn (?*anyopaque, ?*anyopaque) bool,
    /// `[view bounds].size.height`, at `:70`. Only the height is read, and only
    /// on the branch a view that is not flipped takes.
    bounds_height: *const fn (?*anyopaque, ?*anyopaque) f64,
    /// `[view convertRect:toView:]` with the second argument `nil`, at `:78`.
    convert_rect_to_view: *const fn (?*anyopaque, ?*anyopaque, NsRect) NsRect,
    /// `[window convertRectToScreen:]`, at `:80`.
    convert_rect_to_screen: *const fn (?*anyopaque, ?*anyopaque, NsRect) NsRect,
};

/// What `toNsRect` can report.
pub const RectError = error{
    /// `[view window]` answered `nil`. Upstream writes `.unwrap()` at
    /// `AK/macos/src/util.rs:58` and `:79`, so upstream panics and the port
    /// reports the case it turns the panic into.
    NoWindow,
};

/// The `NSRect` AppKit wants for the tree rectangle `rect`, at
/// `AK/macos/src/util.rs:57-83`.
///
/// **The six steps are upstream's and the order is upstream's.** Read the
/// window, read the backing scale, build the rect in the view's own points, and
/// where the view is not flipped put the top edge at the bottom of its bounds
/// measured from `y1`, then convert the rect out of the view and into screen
/// coordinates.
///
/// **The scale divides every coordinate.** AccessKit stores physical pixels and
/// AppKit measures in points, so the port divides the two origins and the two
/// sizes exactly where upstream does. The scale is never zero for a window on a
/// display, and upstream divides without a test, so this divides without one.
///
/// **The window is read twice.** Upstream reads it at `:58` and reads it again
/// at `:79`, after the view conversion. A view that left the window between the
/// two reads answers `error.NoWindow` here, which is upstream's second
/// `.unwrap()` turned into an error rather than a panic.
pub fn toNsRect(
    platform: RectPlatform,
    view: ?*anyopaque,
    rect: schema.Rect,
) RectError!NsRect {
    const ctx = platform.ptr;
    const window = platform.window_of(ctx, view) orelse return error.NoWindow;
    const factor = platform.backing_scale_factor(ctx, window);
    const flipped = platform.is_flipped(ctx, view);
    const origin: NsPoint = .{
        .x = rect.x0 / factor,
        .y = if (flipped)
            rect.y0 / factor
        else
            platform.bounds_height(ctx, view) - rect.y1 / factor,
    };
    const local: NsRect = .{
        .origin = origin,
        .size = .{
            .width = rect.width() / factor,
            .height = rect.height() / factor,
        },
    };
    const converted = platform.convert_rect_to_view(ctx, view, local);
    const second = platform.window_of(ctx, view) orelse return error.NoWindow;
    return platform.convert_rect_to_screen(ctx, second, converted);
}

// --- to_color_attribute ---------------------------------------------------------

/// The one AppKit call `toNsColorAttribute` makes.
pub const ColorPlatform = struct {
    /// The callee's own state, passed to the call unchanged.
    ptr: ?*anyopaque,
    /// `+[NSColor colorWithSRGBRed:green:blue:alpha:]` at
    /// `AK/macos/src/util.rs:99-104`, then `[ns_color CGColor]` at `:106`, then
    /// the `Id::retain` at `:107`. Upstream writes those three steps in one
    /// body and this table writes them as one call, because the port cannot
    /// hold the intermediate `NSColor` and cannot message a `CGColor` it did
    /// not receive.
    cg_color_of: *const fn (?*anyopaque, f64, f64, f64, f64) ?*anyopaque,
};

/// What `toNsColorAttribute` can report.
pub const ColorError = error{
    /// `[ns_color CGColor]` answered `nil`. Upstream writes
    /// `Id::retain(cg_color).unwrap()` at `AK/macos/src/util.rs:107`, so
    /// upstream panics and the port reports the case.
    NoColor,
};

/// One `Color` channel as the `CGFloat` `NSColor` takes, at
/// `AK/macos/src/util.rs:83-85`.
///
/// The division is by 255 and not by 256, so 255 is exactly one and 0 is exactly
/// zero. A port that divided by 256 would answer 0.996 for an opaque channel.
fn colorChannelToF64(channel: u8) f64 {
    return @as(f64, @floatFromInt(channel)) / 255.0;
}

/// The `CGColor` a node answers a colour attribute with, at
/// `AK/macos/src/util.rs:97-108`.
///
/// **The four channels are converted in upstream's order** and each by the same
/// division, so the alpha channel is scaled the way the colour channels are
/// and not kept as a byte. Upstream keeps a `CGColor` it received from AppKit
/// and retains it, so the caller must not release the answer; this returns the
/// same borrowed pointer and says nothing about releasing it.
pub fn toNsColorAttribute(
    platform: ColorPlatform,
    color: schema.Color,
) ColorError!*anyopaque {
    const object = platform.cg_color_of(
        platform.ptr,
        colorChannelToF64(color.red),
        colorChannelToF64(color.green),
        colorChannelToF64(color.blue),
        colorChannelToF64(color.alpha),
    ) orelse return error.NoColor;
    return object;
}

// --- tests ----------------------------------------------------------------------

/// One node of the fixture document the tests walk.
const Spec = struct {
    /// The identifier inside the root tree.
    local: u64,
    /// The role the node declares.
    role: schema.Role = .text_input,
    /// The children of the node, in order.
    children: []const u64 = &.{},
    /// The text of a run, or none for a node that holds no text.
    text: ?[]const u8 = null,
};

/// The UTF-8 byte length of every character in `body`, one entry per character.
///
/// `character_lengths` counts characters and carries each one's byte length, so
/// a four-byte astral character is a four and not a one. A fixture that fills
/// the list with ones would model every astral character as four characters.
fn utf8Lengths(gpa: Allocator, body: []const u8) ![]u8 {
    var view = std.unicode.Utf8View.init(body) catch |err| return err;
    var lengths: std.ArrayList(u8) = .empty;
    errdefer lengths.deinit(gpa);
    var iterator = view.iterator();
    while (iterator.nextCodepointSlice()) |slice| {
        try lengths.append(gpa, @intCast(slice.len));
    }
    return lengths.toOwnedSlice(gpa);
}

/// Builds the document `specs` describes, rooted at `root_local`.
///
/// `Tree.init` takes the update by value and releases it whatever it answers, so
/// the binding is spent and there is no `deinit` for the update.
fn buildTree(gpa: Allocator, root_local: u64, specs: []const Spec) !consumer.tree.Tree {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    for (specs) |spec| {
        var node = schema.Node.init(gpa, spec.role);
        if (spec.text) |body| {
            try schema.strings.setValue(&node.properties, body);
            const lengths = try utf8Lengths(gpa, body);
            defer gpa.free(lengths);
            try schema.vectors.setCharacterLengths(&node.properties, lengths);
        }
        const child_ids = try gpa.alloc(schema.NodeId, spec.children.len);
        defer gpa.free(child_ids);
        for (spec.children, 0..) |child, slot| child_ids[slot] = .{ .value = child };
        try schema.ids_props.setChildren(&node.properties, child_ids);
        try update.pushNode(gpa, .{ .value = spec.local }, node);
    }
    update.tree = schema.TreeInfo.init(.{ .value = root_local });
    update.focus = .{ .value = root_local };
    const built = consumer.tree.Tree.init(gpa, update, true);
    // `Tree.init` released the update on every path, so the binding is emptied
    // before the `errdefer` above can run a second release over freed memory.
    update = .{};
    return built catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.TreeRejectedTheUpdate,
    };
}

/// The node `local` in `tree`, or an error rather than a trap.
fn nodeOf(tree: *const consumer.tree.Tree, local: u64) !NodeRef {
    const state = tree.stateOf();
    return state.nodeById(state.rootId().withSameTree(.{ .value = local })) orelse
        error.MissingNode;
}

/// A window over one `TextInput` whose single run holds `body`.
fn documentWithBody(gpa: Allocator, body: []const u8) !consumer.tree.Tree {
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .text_input, .children = &.{3}, .text = "" },
        .{ .local = 3, .role = .text_run, .text = body },
    };
    return buildTree(gpa, 1, &specs);
}

test "a zero length leaves the range degenerate and a length names an end" {
    // `AK/macos/src/util.rs:15-20`. A zero length skips the second lookup, which
    // is the branch the `if ns_range.length > 0` guard takes.
    const gpa = testing.allocator;
    var tree = try documentWithBody(gpa, "hello");
    defer tree.deinit();
    const root = try nodeOf(&tree, 1);

    const caret = (try fromNsRange(gpa, root, .{ .location = 2, .length = 0 })).?;
    try testing.expect(try consumer.text.range.isDegenerate(gpa, caret));
    try testing.expectEqual(@as(usize, 2), caret.start.character_index);

    const two = (try fromNsRange(gpa, root, .{ .location = 2, .length = 2 })).?;
    try testing.expect(!try consumer.text.range.isDegenerate(gpa, two));
    const round_trip = try toNsRange(two);
    try testing.expectEqual(NsRange{ .location = 2, .length = 2 }, round_trip);
}

test "a document index past the end names no range" {
    // Both `?` in `AK/macos/src/util.rs:14` and `:18` answer `None` here. A
    // length that runs past the end must not fall back to the end of the
    // document, which is why this asks for six units over five characters.
    const gpa = testing.allocator;
    var tree = try documentWithBody(gpa, "hello");
    defer tree.deinit();
    const root = try nodeOf(&tree, 1);

    try testing.expectEqual(@as(?Range, null), try fromNsRange(gpa, root, .{
        .location = 99,
        .length = 0,
    }));
    try testing.expectEqual(@as(?Range, null), try fromNsRange(gpa, root, .{
        .location = 2,
        .length = 99,
    }));
    // The whole document is inside it, so the last index alone still answers.
    try testing.expect((try fromNsRange(gpa, root, .{
        .location = 0,
        .length = 5,
    })) != null);
}

test "a range that cannot name its end reports RangeOverflow" {
    // Upstream adds the two indices with `+` on a `usize` at
    // `AK/macos/src/util.rs:18` and panics on overflow in a debug build. The
    // port reports `error.RangeOverflow`, and this reaches it with a start index
    // the document holds and a length no document can hold.
    const gpa = testing.allocator;
    var tree = try documentWithBody(gpa, "hello");
    defer tree.deinit();
    const root = try nodeOf(&tree, 1);

    try testing.expectError(
        error.RangeOverflow,
        fromNsRange(gpa, root, .{ .location = 1, .length = std.math.maxInt(usize) }),
    );
}

test "a character is measured in UTF-16 code units and not in characters" {
    // `to_ns_range_for_character` at `AK/macos/src/util.rs:30-36` runs the range
    // to `forward_to_character_end`, and an astral character is two code units
    // long. A test over ASCII answers one for both units and proves nothing.
    const gpa = testing.allocator;
    var tree = try documentWithBody(gpa, "a\xF0\x9F\x98\x80" ++ "b");
    defer tree.deinit();
    const root = try nodeOf(&tree, 1);

    // The astral character sits between index 1 and index 3.
    const at_astral = (try consumer.text.query.textPositionFromGlobalUtf16Index(root, 1)).?;
    const astral = try toNsRangeForCharacter(gpa, at_astral);
    try testing.expectEqual(NsRange{ .location = 1, .length = 2 }, astral);

    // The ASCII character before it is one unit long.
    const at_ascii = (try consumer.text.query.textPositionFromGlobalUtf16Index(root, 0)).?;
    const ascii = try toNsRangeForCharacter(gpa, at_ascii);
    try testing.expectEqual(NsRange{ .location = 0, .length = 1 }, ascii);

    // The document end has no character after it, so it is degenerate.
    const at_end = (try consumer.text.query.textPositionFromGlobalUtf16Index(root, 4)).?;
    const end_range = try toNsRangeForCharacter(gpa, at_end);
    try testing.expectEqual(NsRange{ .location = 4, .length = 0 }, end_range);
}

test "a range over two runs names its own two ends" {
    // `to_ns_range` at `AK/macos/src/util.rs:24-28` counts from the start of the
    // document, so a range inside the second run starts at the length of the
    // first one.
    const gpa = testing.allocator;
    const specs = [_]Spec{
        .{ .local = 1, .role = .window, .children = &.{2} },
        .{ .local = 2, .role = .text_input, .children = &.{ 3, 4 } },
        .{ .local = 3, .role = .text_run, .text = "hello" },
        .{ .local = 4, .role = .text_run, .text = "world" },
    };
    var tree = try buildTree(gpa, 1, &specs);
    defer tree.deinit();
    const root = try nodeOf(&tree, 1);

    const second_run = try fromNsRange(gpa, root, .{ .location = 7, .length = 3 });
    try testing.expectEqual(NsRange{ .location = 7, .length = 3 }, try toNsRange(second_run.?));
}

/// A range over one document, used by the test that checks the round trip.
fn rangeOver(
    gpa: Allocator,
    node: NodeRef,
    first: usize,
    last: usize,
) !Range {
    const start = (try consumer.text.query.textPositionFromGlobalUtf16Index(node, first)).?;
    var range = try consumer.text.range.toDegenerateRange(gpa, start);
    const end = (try consumer.text.query.textPositionFromGlobalUtf16Index(node, last)).?;
    try consumer.text.range.setEnd(gpa, &range, end);
    return range;
}

test "a range built by hand and read back names the same two indices" {
    const gpa = testing.allocator;
    var tree = try documentWithBody(gpa, "hello");
    defer tree.deinit();
    const root = try nodeOf(&tree, 1);
    const round_trip = try toNsRange(try rangeOver(gpa, root, 1, 4));
    try testing.expectEqual(NsRange{ .location = 1, .length = 3 }, round_trip);
}

// --- the rect and colour tests ----------------------------------------------------

/// How far `convert_rect_to_view` moves every rect it is handed.
///
/// A recorder that answered its input would let a port that skipped the send
/// pass, and a recorder that moved nothing would let a port that handed the
/// first send's answer to the second pass. Two different offsets tell the two
/// sends apart in one answer.
const view_conversion_offset: NsPoint = .{ .x = 7, .y = 0 };

/// How far `convert_rect_to_screen` moves every rect it is handed.
const screen_conversion_offset: NsPoint = .{ .x = 0, .y = 1000 };

/// The rect a recorder starts with, which is four zeros and nothing else.
const empty_ns_rect: NsRect = .{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 0, .height = 0 },
};

/// A `RectPlatform` that records the calls instead of reaching AppKit.
///
/// It is a complete implementation of the table, not a stub: every send is
/// accepted, applied and left visible, which is what makes the coordinate
/// arithmetic testable on a host with no macOS. **What it cannot do is reach a
/// window**, because there is none to reach.
const RectHost = struct {
    /// The window `window_of` answers, and `null` for a view that is in none.
    window: ?*anyopaque,
    /// The backing scale `backing_scale_factor` answers.
    backing_scale: f64,
    /// What `is_flipped` answers.
    flipped: bool,
    /// What `bounds_height` answers.
    height: f64,
    /// How many times `window_of` answered a window.
    window_reads: usize = 0,
    /// How many times `bounds_height` was read, which is the flipped branch.
    height_reads: usize = 0,
    /// How many times `convert_rect_to_view` ran.
    view_conversions: usize = 0,
    /// How many times `convert_rect_to_screen` ran.
    screen_conversions: usize = 0,
    /// The rect the view conversion received, and the only one it can have
    /// received.
    view_rect: NsRect = empty_ns_rect,
    /// The rect the screen conversion received.
    screen_rect: NsRect = empty_ns_rect,
    /// When set, `window_of` answers `null` from the second read on, which is
    /// the state a view that left its window between the two reads is in.
    window_leaves_after_first_read: bool = false,

    /// The table this recorder is reached through.
    fn platform(self: *RectHost) RectPlatform {
        return .{
            .ptr = self,
            .window_of = windowOf,
            .backing_scale_factor = backingScaleFactor,
            .is_flipped = isFlipped,
            .bounds_height = boundsHeight,
            .convert_rect_to_view = convertRectToView,
            .convert_rect_to_screen = convertRectToScreen,
        };
    }

    fn windowOf(context: ?*anyopaque, _: ?*anyopaque) ?*anyopaque {
        const self: *RectHost = @ptrCast(@alignCast(context orelse return null));
        self.window_reads += 1;
        if (self.window_leaves_after_first_read and self.window_reads > 1) return null;
        return self.window;
    }

    fn backingScaleFactor(context: ?*anyopaque, _: ?*anyopaque) f64 {
        const self: *RectHost = @ptrCast(@alignCast(context orelse return 1));
        return self.backing_scale;
    }

    fn isFlipped(context: ?*anyopaque, _: ?*anyopaque) bool {
        const self: *RectHost = @ptrCast(@alignCast(context orelse return false));
        return self.flipped;
    }

    fn boundsHeight(context: ?*anyopaque, _: ?*anyopaque) f64 {
        const self: *RectHost = @ptrCast(@alignCast(context orelse return 0));
        self.height_reads += 1;
        return self.height;
    }

    fn convertRectToView(context: ?*anyopaque, _: ?*anyopaque, rect: NsRect) NsRect {
        const self: *RectHost = @ptrCast(@alignCast(context orelse return rect));
        self.view_conversions += 1;
        self.view_rect = rect;
        return .{
            .origin = .{
                .x = rect.origin.x + view_conversion_offset.x,
                .y = rect.origin.y + view_conversion_offset.y,
            },
            .size = rect.size,
        };
    }

    fn convertRectToScreen(context: ?*anyopaque, _: ?*anyopaque, rect: NsRect) NsRect {
        const self: *RectHost = @ptrCast(@alignCast(context orelse return rect));
        self.screen_conversions += 1;
        self.screen_rect = rect;
        return .{
            .origin = .{
                .x = rect.origin.x + screen_conversion_offset.x,
                .y = rect.origin.y + screen_conversion_offset.y,
            },
            .size = rect.size,
        };
    }
};

/// The tree rectangle both rect tests convert.
///
/// `AK/macos/src/util.rs:57-83` reads `x0`, `y0`, `x1` and `y1`, and the two
/// sizes are `x1 - x0` and `y1 - y0`, so a box of 20 by 20 at (10, 20) is the
/// smallest one where the flipped and unflipped origins differ by more than the
/// division.
const test_rect: schema.Rect = .{ .x0 = 10, .y0 = 20, .x1 = 30, .y1 = 40 };

/// A byte the tests hand out as the address of a view or a window.
///
/// The port never dereferences either address: every table entry takes it and
/// one of the recorders answers from its own state, so a byte with a stable
/// address is all an `?*anyopaque` needs.
fn opaqueFromByte(byte: *u8) *anyopaque {
    return @ptrCast(byte);
}

test "a flipped view divides by the backing scale and keeps the top edge" {
    // `AK/macos/src/util.rs:63-71`. A scale of two turns (10, 20, 30, 40) into
    // an origin of (5, 10) and a size of (10, 10), and the flipped branch reads
    // `y0` and not `y1`, so the bounds height is never read.
    var view_byte: u8 = 0;
    var window_byte: u8 = 0;
    var host = RectHost{
        .window = opaqueFromByte(&window_byte),
        .backing_scale = 2,
        .flipped = true,
        .height = 300,
    };

    const answered = try toNsRect(host.platform(), opaqueFromByte(&view_byte), test_rect);

    const local: NsRect = .{
        .origin = .{ .x = 5, .y = 10 },
        .size = .{ .width = 10, .height = 10 },
    };
    try testing.expectEqual(local, host.view_rect);
    // The view conversion ran once and its answer is what the screen conversion
    // received, which is the chain of `:78` feeding `:80`.
    try testing.expectEqual(@as(usize, 1), host.view_conversions);
    try testing.expectEqual(@as(usize, 1), host.screen_conversions);
    try testing.expectEqual(
        NsRect{
            .origin = .{ .x = local.origin.x + 7, .y = local.origin.y },
            .size = local.size,
        },
        host.screen_rect,
    );
    try testing.expectEqual(
        NsRect{
            .origin = .{
                .x = local.origin.x + view_conversion_offset.x + screen_conversion_offset.x,
                .y = local.origin.y + view_conversion_offset.y + screen_conversion_offset.y,
            },
            .size = local.size,
        },
        answered,
    );
    // The flipped branch is the one that does not read the bounds.
    try testing.expectEqual(@as(usize, 0), host.height_reads);
}

test "a view that is not flipped measures the top edge from the bottom" {
    // `AK/macos/src/util.rs:69-71`: the unflipped arm is
    // `view_bounds.size.height - rect.y1 / factor`, so with a scale of one and
    // bounds 300 tall the top edge is 300 - 40 = 260 and not 20.
    var view_byte: u8 = 0;
    var window_byte: u8 = 0;
    var host = RectHost{
        .window = opaqueFromByte(&window_byte),
        .backing_scale = 1,
        .flipped = false,
        .height = 300,
    };

    _ = try toNsRect(host.platform(), opaqueFromByte(&view_byte), test_rect);

    try testing.expectEqual(
        NsRect{
            .origin = .{ .x = 10, .y = 260 },
            .size = .{ .width = 20, .height = 20 },
        },
        host.view_rect,
    );
    try testing.expectEqual(@as(usize, 1), host.height_reads);
}

test "a view in no window reports NoWindow and converts nothing" {
    // Upstream writes `.unwrap()` at `AK/macos/src/util.rs:58`, which panics.
    // The port names the case, and neither conversion may run: a rect measured
    // against no window is not a rect the caller can use.
    var view_byte: u8 = 0;
    var host = RectHost{
        .window = null,
        .backing_scale = 2,
        .flipped = true,
        .height = 300,
    };

    try testing.expectError(
        error.NoWindow,
        toNsRect(host.platform(), opaqueFromByte(&view_byte), test_rect),
    );
    try testing.expectEqual(@as(usize, 1), host.window_reads);
    try testing.expectEqual(@as(usize, 0), host.view_conversions);
    try testing.expectEqual(@as(usize, 0), host.screen_conversions);
}

test "a view that leaves its window between the two reads reports NoWindow" {
    // Upstream reads the window at `AK/macos/src/util.rs:58` and reads it again
    // at `:79`, after the view conversion. The second read is what this drives
    // to nothing, and the first conversion must already have run because the
    // send happens between the two reads.
    var view_byte: u8 = 0;
    var window_byte: u8 = 0;
    var host = RectHost{
        .window = opaqueFromByte(&window_byte),
        .backing_scale = 2,
        .flipped = true,
        .height = 300,
        .window_leaves_after_first_read = true,
    };

    try testing.expectError(
        error.NoWindow,
        toNsRect(host.platform(), opaqueFromByte(&view_byte), test_rect),
    );
    try testing.expectEqual(@as(usize, 2), host.window_reads);
    try testing.expectEqual(@as(usize, 1), host.view_conversions);
    try testing.expectEqual(@as(usize, 0), host.screen_conversions);
}

/// The four channels a `ColorPlatform` received, in the order upstream passes
/// them.
const ColorChannels = struct {
    /// The red channel.
    red: f64,
    /// The green channel.
    green: f64,
    /// The blue channel.
    blue: f64,
    /// The alpha channel.
    alpha: f64,
};

/// A `ColorPlatform` that records the channels instead of reaching AppKit.
const ColorHost = struct {
    /// The channels the last call carried, and the four zeros before any call.
    channels: ColorChannels = .{ .red = 0, .green = 0, .blue = 0, .alpha = 0 },
    /// How many times the call ran.
    calls: usize = 0,
    /// The answer the call gives, and `null` for "AppKit has no such colour".
    answer: ?*anyopaque,

    /// The table this recorder is reached through.
    fn platform(self: *ColorHost) ColorPlatform {
        return .{ .ptr = self, .cg_color_of = cgColorOf };
    }

    fn cgColorOf(
        context: ?*anyopaque,
        red: f64,
        green: f64,
        blue: f64,
        alpha: f64,
    ) ?*anyopaque {
        const self: *ColorHost = @ptrCast(@alignCast(context orelse return null));
        self.calls += 1;
        self.channels = .{ .red = red, .green = green, .blue = blue, .alpha = alpha };
        return self.answer;
    }
};

test "every channel is divided by 255 in the order upstream passes them" {
    // `AK/macos/src/util.rs:83-85` and `:99-104`. The four channels go red,
    // green, blue, alpha, and each is `channel as f64 / 255.0`, so 255 is one,
    // 0 is zero and 51 is 0.2.
    var color_byte: u8 = 0;
    var host = ColorHost{ .answer = opaqueFromByte(&color_byte) };

    const answered = try toNsColorAttribute(host.platform(), .{
        .red = 255,
        .green = 128,
        .blue = 0,
        .alpha = 51,
    });

    try testing.expectEqual(@as(usize, 1), host.calls);
    try testing.expectEqual(
        ColorChannels{
            .red = 255.0 / 255.0,
            .green = 128.0 / 255.0,
            .blue = 0.0 / 255.0,
            .alpha = 51.0 / 255.0,
        },
        host.channels,
    );
    // The pointer AppKit handed back is the pointer the caller keeps: upstream
    // retains the `CGColor` and hands the same address over.
    try testing.expectEqual(opaqueFromByte(&color_byte), answered);
}

test "a platform with no colour reports NoColor" {
    // Upstream writes `Id::retain(cg_color).unwrap()` at
    // `AK/macos/src/util.rs:107`, which panics on a nil `CGColor`. The port
    // names the case instead.
    var host = ColorHost{ .answer = null };
    try testing.expectError(error.NoColor, toNsColorAttribute(host.platform(), .{
        .red = 1,
        .green = 2,
        .blue = 3,
        .alpha = 4,
    }));
    // The call still ran, so the channels were converted before the answer was
    // known to be nothing.
    try testing.expectEqual(@as(usize, 1), host.calls);
}
