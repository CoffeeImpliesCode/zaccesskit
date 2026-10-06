//! The text-range conversions of `AK/macos/src/util.rs`, and the `NSRange` they
//! answer.
//!
//! **What this module is.** `NSRange`, `from_ns_range`, `to_ns_range` and
//! `to_ns_range_for_character`, at `AK/macos/src/util.rs:13-36`. Three of the
//! five functions upstream holds in this file need no AppKit: an `NSRange` is
//! two integers, and a text position and a text range are consumer values. The
//! other two, `from_ns_point` and `to_ns_rect`, go through `NSView` and
//! `NSWindow` and are not here; `root.zig:136` and `root.zig:699` record where
//! each of them went.
//!
//! **Who calls these.** `AK/macos/src/node.rs:786`, `:812`, `:833`, `:844`,
//! `:858`, `:1003`, `:1023` and `:1035`, which are the bodies of
//! `accessibilitySelectedTextRange`, `accessibilityRangeForLine:`,
//! `accessibilityRangeForPosition:`, `accessibilityAttributedStringForRange:`,
//! `accessibilityFrameForRange:` and the three index selectors. The port holds
//! those nine selectors as table rows in `attributes.zig` with no body, because
//! answering them needs an Objective-C object, so nothing here has a caller yet.
//!
//! **The units.** An `NSRange` counts UTF-16 code units, and so does
//! `text.position.toGlobalUtf16Index` and `text.query`'s
//! `textPositionFromGlobalUtf16Index`. A document of three ASCII characters
//! answers the same number under both readings, so a test that uses ASCII alone
//! cannot tell the two units apart; the test below uses an astral character for
//! exactly that reason.
//!
//! **The allocator.** `toNsRange` allocates nothing, because
//! `toGlobalUtf16Index` walks the text runs and builds no key. The other two
//! build a `Range`, and the port's `range.toDegenerateRange` builds two ordering
//! keys, so both take `gpa` first where upstream takes only a position.
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
            const lengths = try gpa.alloc(u8, body.len);
            defer gpa.free(lengths);
            @memset(lengths, 1);
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
    return consumer.tree.Tree.init(gpa, update, true) catch |err| switch (err) {
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
        .{ .local = 3, .role = .text_run, .children = &.{4}, .text = body },
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
        .{ .local = 2, .role = .text_input, .children = &.{3} },
        .{ .local = 3, .role = .text_run, .children = &.{4}, .text = "hello" },
        .{ .local = 4, .role = .text_run, .children = &.{5}, .text = "world" },
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
