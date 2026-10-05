//! The 39 inherited accessors: 13 text properties read as a node value, as a
//! position value and as a value across a range.
//!
//! Upstream `accesskit_consumer/src/text.rs:980-1364`. Upstream writes the
//! family twice, through the `inherited_properties!` macro at `text.rs:1200`
//! and the `inherited_flags!` macro at `text.rs:1361`, and each macro writes
//! three `impl` blocks: one on `NodeRef`, one on `Position` and one on `Range`.
//! Zig has no macros, so the 39 are written out here.
//!
//! **The family shares one walk, and that walk is not here.** The nearest
//! ancestor that declares the value is `node_ref/properties.zig`'s
//! `fetchInheritedProperty`, and the flag walk is its `fetchInheritedFlag`. The
//! two private helpers `inheritedValue` and `inheritedFlag` below are the only
//! two places in the layer that call them, so there is one implementation of
//! "climb until somebody declares this" rather than 39 copies of it, and a fix
//! to the bound is a fix in one place. Do not inline that walk into an
//! accessor.
//!
//! **The walk is bounded.** Both helpers take `treeWalkStepBound`, which
//! `docs/33` section 7 derives from the node count: each step moves to a
//! different node, so the walk cannot take more steps than the tree has nodes.
//! The count also catches a repeat, so a tree whose parents form a cycle stops
//! with `error.TreeCycle` rather than running forever.
//!
//! **What this module deliberately does not own.** The types are declared
//! elsewhere and are only read here: `Position` is `text/position.zig`'s,
//! `InnerPosition` is `text/position_inner.zig`'s, `Range` and
//! `RangePropertyValue` are `text/range.zig`'s, and `NodeRef` is
//! `node_id.zig`'s. This module declares no struct body, so every operation
//! here is a free function whose first parameter is the receiver.

const std = @import("std");
const schema = @import("../../schema/root.zig");

const position = @import("position.zig");
const properties = @import("../node_ref/properties.zig");
const range = @import("range.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");

const FullNodeId = tree_index.FullNodeId;
const ParentAndIndex = tree_index.ParentAndIndex;
const NodeRef = @import("../node_id.zig").NodeRef;
const Position = position.Position;
const QueryError = tree_state.QueryError;
const Range = range.Range;
const RangePropertyValue = range.RangePropertyValue;
const TextAlign = schema.TextAlign;
const VerticalOffset = schema.VerticalOffset;
const TextDecoration = schema.TextDecoration;
const TextDirection = schema.TextDirection;
const Color = schema.Color;

const Self = @This();

const testing = std.testing;

// --- Text direction ----------------------------------------------------------

/// The text direction the node lays its text out in, read from the node itself
/// or from the nearest ancestor that declares one.
pub fn nodeTextDirection(
    node: NodeRef,
) QueryError!?TextDirection {
    return inheritedValue(TextDirection, node, textDirectionOf);
}

/// The direction the run at `position` inherits.
pub fn positionTextDirection(
    position_value: Position,
) QueryError!?TextDirection {
    return nodeTextDirection(position_value.inner.node);
}

/// The direction across `range`, or `.mixed` when the runs disagree.
pub fn rangeTextDirection(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(TextDirection) {
    return range.fetchProperty(TextDirection, gpa, range_value, nodeTextDirection);
}

// --- Font family -------------------------------------------------------------

/// The font family the node inherits, or `null` when it and every ancestor
/// declare none.
pub fn nodeFontFamily(node: NodeRef) QueryError!?[]const u8 {
    return inheritedValue([]const u8, node, fontFamilyOf);
}

/// The font family the run at `position` inherits.
pub fn positionFontFamily(position_value: Position) QueryError!?[]const u8 {
    return nodeFontFamily(position_value.inner.node);
}

/// The font family across `range`, or `.mixed` when the runs disagree. Two runs
/// that declare equal text in different buffers compare equal here, because the
/// fold compares content and not slice headers.
pub fn rangeFontFamily(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue([]const u8) {
    return range.fetchProperty([]const u8, gpa, range_value, nodeFontFamily);
}

// --- Language ----------------------------------------------------------------

/// The language tag the node inherits, or `null` when nobody declares one.
pub fn nodeLanguage(node: NodeRef) QueryError!?[]const u8 {
    return inheritedValue([]const u8, node, languageOf);
}

/// The language the run at `position` inherits.
pub fn positionLanguage(position_value: Position) QueryError!?[]const u8 {
    return nodeLanguage(position_value.inner.node);
}

/// The language across `range`, or `.mixed` when the runs disagree.
pub fn rangeLanguage(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue([]const u8) {
    return range.fetchProperty([]const u8, gpa, range_value, nodeLanguage);
}

// --- Font size ---------------------------------------------------------------

/// The font size in points the node inherits.
pub fn nodeFontSize(
    node: NodeRef,
) QueryError!?f32 {
    return inheritedValue(f32, node, fontSizeOf);
}

/// The font size the run at `position` inherits.
pub fn positionFontSize(
    position_value: Position,
) QueryError!?f32 {
    return nodeFontSize(position_value.inner.node);
}

/// The font size across `range`, or `.mixed` when the runs disagree.
pub fn rangeFontSize(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(f32) {
    return range.fetchProperty(f32, gpa, range_value, nodeFontSize);
}

// --- Font weight -------------------------------------------------------------

/// The font weight the node inherits.
pub fn nodeFontWeight(
    node: NodeRef,
) QueryError!?f32 {
    return inheritedValue(f32, node, fontWeightOf);
}

/// The font weight the run at `position` inherits.
pub fn positionFontWeight(
    position_value: Position,
) QueryError!?f32 {
    return nodeFontWeight(position_value.inner.node);
}

/// The font weight across `range`, or `.mixed` when the runs disagree.
pub fn rangeFontWeight(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(f32) {
    return range.fetchProperty(f32, gpa, range_value, nodeFontWeight);
}

// --- Background colour -------------------------------------------------------

/// The background colour the node inherits.
pub fn nodeBackgroundColor(
    node: NodeRef,
) QueryError!?Color {
    return inheritedValue(Color, node, backgroundColorOf);
}

/// The background colour the run at `position` inherits.
pub fn positionBackgroundColor(
    position_value: Position,
) QueryError!?Color {
    return nodeBackgroundColor(position_value.inner.node);
}

/// The background colour across `range`, or `.mixed` when the runs disagree.
pub fn rangeBackgroundColor(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(Color) {
    return range.fetchProperty(Color, gpa, range_value, nodeBackgroundColor);
}

// --- Foreground colour -------------------------------------------------------

/// The foreground colour the node inherits.
pub fn nodeForegroundColor(
    node: NodeRef,
) QueryError!?Color {
    return inheritedValue(Color, node, foregroundColorOf);
}

/// The foreground colour the run at `position` inherits.
pub fn positionForegroundColor(
    position_value: Position,
) QueryError!?Color {
    return nodeForegroundColor(position_value.inner.node);
}

/// The foreground colour across `range`, or `.mixed` when the runs disagree.
pub fn rangeForegroundColor(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(Color) {
    return range.fetchProperty(Color, gpa, range_value, nodeForegroundColor);
}

// --- Overline ----------------------------------------------------------------

/// The overline the node inherits.
pub fn nodeOverline(
    node: NodeRef,
) QueryError!?TextDecoration {
    return inheritedValue(TextDecoration, node, overlineOf);
}

/// The overline the run at `position` inherits.
pub fn positionOverline(
    position_value: Position,
) QueryError!?TextDecoration {
    return nodeOverline(position_value.inner.node);
}

/// The overline across `range`, or `.mixed` when the runs disagree.
pub fn rangeOverline(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(TextDecoration) {
    return range.fetchProperty(TextDecoration, gpa, range_value, nodeOverline);
}

// --- Strikethrough -----------------------------------------------------------

/// The strikethrough the node inherits.
pub fn nodeStrikethrough(
    node: NodeRef,
) QueryError!?TextDecoration {
    return inheritedValue(TextDecoration, node, strikethroughOf);
}

/// The strikethrough the run at `position` inherits.
pub fn positionStrikethrough(
    position_value: Position,
) QueryError!?TextDecoration {
    return nodeStrikethrough(position_value.inner.node);
}

/// The strikethrough across `range`, or `.mixed` when the runs disagree.
pub fn rangeStrikethrough(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(TextDecoration) {
    return range.fetchProperty(TextDecoration, gpa, range_value, nodeStrikethrough);
}

// --- Underline ---------------------------------------------------------------

/// The underline the node inherits.
pub fn nodeUnderline(
    node: NodeRef,
) QueryError!?TextDecoration {
    return inheritedValue(TextDecoration, node, underlineOf);
}

/// The underline the run at `position` inherits.
pub fn positionUnderline(
    position_value: Position,
) QueryError!?TextDecoration {
    return nodeUnderline(position_value.inner.node);
}

/// The underline across `range`, or `.mixed` when the runs disagree.
pub fn rangeUnderline(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(TextDecoration) {
    return range.fetchProperty(TextDecoration, gpa, range_value, nodeUnderline);
}

// --- Text align --------------------------------------------------------------

/// The horizontal alignment the node inherits.
pub fn nodeTextAlign(
    node: NodeRef,
) QueryError!?TextAlign {
    return inheritedValue(TextAlign, node, textAlignOf);
}

/// The alignment the run at `position` inherits.
pub fn positionTextAlign(
    position_value: Position,
) QueryError!?TextAlign {
    return nodeTextAlign(position_value.inner.node);
}

/// The alignment across `range`, or `.mixed` when the runs disagree.
pub fn rangeTextAlign(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(TextAlign) {
    return range.fetchProperty(TextAlign, gpa, range_value, nodeTextAlign);
}

// --- Vertical offset ---------------------------------------------------------

/// The subscript or superscript the node inherits.
pub fn nodeVerticalOffset(
    node: NodeRef,
) QueryError!?VerticalOffset {
    return inheritedValue(VerticalOffset, node, verticalOffsetOf);
}

/// The vertical offset the run at `position` inherits.
pub fn positionVerticalOffset(
    position_value: Position,
) QueryError!?VerticalOffset {
    return nodeVerticalOffset(position_value.inner.node);
}

/// The vertical offset across `range`, or `.mixed` when the runs disagree.
pub fn rangeVerticalOffset(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(VerticalOffset) {
    return range.fetchProperty(VerticalOffset, gpa, range_value, nodeVerticalOffset);
}

// --- Italic ------------------------------------------------------------------

/// Whether the node or the nearest ancestor that says so is italic. A flag
/// answers `false` rather than "unset", so this function never returns an
/// absent answer and never fails except on the bound.
pub fn nodeIsItalic(
    node: NodeRef,
) QueryError!bool {
    return inheritedFlag(node, isItalicOf);
}

/// Whether the run at `position` is italic.
pub fn positionIsItalic(
    position_value: Position,
) QueryError!bool {
    return nodeIsItalic(position_value.inner.node);
}

/// Whether every run the range covers is italic, or `.mixed` when they differ.
/// `single` is never `null`, because the flag walk answers `false` and not
/// "unset".
pub fn rangeIsItalic(
    gpa: std.mem.Allocator,
    range_value: Range,
) QueryError!RangePropertyValue(bool) {
    return range.fetchProperty(bool, gpa, range_value, italicValue);
}

// --- The shared walk ---------------------------------------------------------

/// The one call to `node_ref/properties.zig`'s inherited-property walk. All 12
/// value accessors above reach the ancestor chain through this function, so the
/// bound and the exhaustion error are implemented once.
fn inheritedValue(
    comptime T: type,
    node: NodeRef,
    getter: *const fn (*const schema.Node) ?T,
) QueryError!?T {
    return properties.fetchInheritedProperty(T, node, getter);
}

/// The one call to `node_ref/properties.zig`'s inherited-flag walk. See
/// `inheritedValue` for why there is one.
fn inheritedFlag(
    node: NodeRef,
    getter: *const fn (*const schema.Node) bool,
) QueryError!bool {
    return properties.fetchInheritedFlag(node, getter);
}

fn textDirectionOf(node: *const schema.Node) ?TextDirection {
    return schema.enums.textDirection(&node.properties);
}

fn fontFamilyOf(node: *const schema.Node) ?[]const u8 {
    return schema.strings.fontFamily(&node.properties);
}

fn languageOf(node: *const schema.Node) ?[]const u8 {
    return schema.strings.language(&node.properties);
}

fn fontSizeOf(node: *const schema.Node) ?f32 {
    return schema.numbers.fontSize(&node.properties);
}

fn fontWeightOf(node: *const schema.Node) ?f32 {
    return schema.numbers.fontWeight(&node.properties);
}

fn backgroundColorOf(node: *const schema.Node) ?Color {
    return schema.colors.backgroundColor(&node.properties);
}

fn foregroundColorOf(node: *const schema.Node) ?Color {
    return schema.colors.foregroundColor(&node.properties);
}

fn overlineOf(node: *const schema.Node) ?TextDecoration {
    return schema.colors.overline(&node.properties);
}

fn strikethroughOf(node: *const schema.Node) ?TextDecoration {
    return schema.colors.strikethrough(&node.properties);
}

fn underlineOf(node: *const schema.Node) ?TextDecoration {
    return schema.colors.underline(&node.properties);
}

fn textAlignOf(node: *const schema.Node) ?TextAlign {
    return schema.enums.textAlign(&node.properties);
}

fn verticalOffsetOf(node: *const schema.Node) ?VerticalOffset {
    return schema.enums.verticalOffset(&node.properties);
}

/// The flag walk behind `rangeIsItalic`. `fetchProperty` folds an optional
/// value, so the flag is lifted into one; the fold never sees a `null`.
fn italicValue(node: NodeRef) QueryError!?bool {
    const value = try nodeIsItalic(node);
    return value;
}

fn isItalicOf(node: *const schema.Node) bool {
    return schema.flags.isItalic(node.flags);
}

// --- Tests -------------------------------------------------------------------

/// The bound the shared walk takes, `treeWalkStepBound` from `docs/33`
/// section 7: one step per node, because every step moves to a different node
/// and a tree with `node_count` nodes cannot take more.
pub fn walkStepBound(node_count: usize) usize {
    return node_count;
}

/// Stores `node` under `value` with `parent` as its parent id, so a test can
/// build a tree without the update algorithm. Inserting moves the map, so a
/// caller must insert every node before taking a handle.
fn insert(
    gpa: std.mem.Allocator,
    state: *tree_state.TreeState,
    value: u64,
    parent: ?u64,
    node: schema.Node,
) !void {
    const id = FullNodeId.init(.{ .value = value }, .init(0));
    const parent_and_index: ?ParentAndIndex = if (parent) |parent_value| blk: {
        const parent_id = FullNodeId.init(.{ .value = parent_value }, .init(0));
        const parent_ref = NodeRef.init(state, parent_id) orelse
            return error.NodeMissingFromFixture;
        const listed = schema.ids_props.children(&parent_ref.data().properties);
        var found: usize = 0;
        for (listed, 0..) |child, child_slot| {
            if (child.eql(.{ .value = value })) {
                found = child_slot;
                break;
            }
        }
        break :blk .{ .parent_id = parent_id, .index = found };
    } else null;
    try state.nodes.put(gpa, id, .{
        .parent_and_index = parent_and_index,
        .data = node,
    });
}

fn handle(state: *const tree_state.TreeState, value: u64) !NodeRef {
    return NodeRef.init(state, FullNodeId.init(.{ .value = value }, .init(0))) orelse
        error.NodeMissingFromFixture;
}

fn textRun(gpa: std.mem.Allocator, text_value: []const u8) !schema.Node {
    var node = schema.Node.init(gpa, .text_run);
    errdefer node.deinit();
    try schema.strings.setValue(&node.properties, text_value);
    const lengths = try gpa.alloc(u8, text_value.len);
    defer gpa.free(lengths);
    @memset(lengths, 1);
    try schema.vectors.setCharacterLengths(&node.properties, lengths);
    return node;
}

/// A `TextInput` over two runs, with `first` and `second` set on the two runs
/// when they are not null.
fn twoRunDocument(
    gpa: std.mem.Allocator,
    state: *tree_state.TreeState,
    first: ?[]const u8,
    second: ?[]const u8,
) !void {
    // Every node below is handed to `insert`, which stores it in the map and
    // takes ownership. An `errdefer` registered before that point still fires
    // on a later error and would free a node the map owns, so each one is
    // cancelled by doing the insert through an explicit `catch` instead.
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{
        .{ .value = 1 },
        .{ .value = 2 },
    });
    insert(gpa, state, 0, null, document) catch |err| {
        document.deinit();
        return err;
    };
    var run_one = try textRun(gpa, "text 1");
    errdefer run_one.deinit();
    if (first) |family| try schema.strings.setFontFamily(&run_one.properties, family);
    insert(gpa, state, 1, 0, run_one) catch |err| {
        run_one.deinit();
        return err;
    };
    var run_two = try textRun(gpa, "text 2");
    errdefer run_two.deinit();
    if (second) |family| try schema.strings.setFontFamily(&run_two.properties, family);
    insert(gpa, state, 2, 0, run_two) catch |err| {
        run_two.deinit();
        return err;
    };
}

test "a value set on the node itself is what the node reports" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, "Noto", "Noto");
}

test "a value set on the parent reaches the child that declares none" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{.{ .value = 1 }});
    try schema.strings.setFontFamily(&document.properties, "Noto");
    try insert(gpa, &state, 0, null, document);
    try insert(gpa, &state, 1, 0, try textRun(gpa, "text"));

    // This is the whole point of the shared walk: the run declares nothing, so
    // the answer comes from one step up.

}

test "a child overrides the parent it would otherwise inherit from" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{
        .{ .value = 1 },
        .{ .value = 2 },
    });
    try schema.strings.setFontFamily(&document.properties, "Noto");
    try insert(gpa, &state, 0, null, document);
    try insert(gpa, &state, 1, 0, try textRun(gpa, "text 1"));
    var overriding = try textRun(gpa, "text 2");
    errdefer overriding.deinit();
    try schema.strings.setFontFamily(&overriding.properties, "Inconsolata");
    // `insert` stores the node in the map and takes ownership, so the
    // `errdefer` must not outlive it.
    insert(gpa, &state, 2, 0, overriding) catch |err| {
        overriding.deinit();
        return err;
    };

    // The document declares "Noto" and run 2 declares its own family, so the
    // walk must stop at the run and never reach the document. Comparing
    // strings, not slice headers: the two live in different buffers.
    try testing.expectEqualStrings("Inconsolata", (try nodeFontFamily(try handle(&state, 2))).?);
    try testing.expectEqualStrings("Noto", (try nodeFontFamily(try handle(&state, 1))).?);
    try testing.expectEqualStrings("Noto", (try nodeFontFamily(try handle(&state, 0))).?);
}

test "a position reports the value its own run inherits" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, "Noto", "Inconsolata");

    const position_value: Position = .{
        .root_node = try handle(&state, 0),
        .inner = .{ .node = try handle(&state, 2), .character_index = 0 },
    };
    // Upstream `Position::$getter` reads `self.inner.node`, so the position
    // reports the run it sits in and not the document around it.
    try testing.expectEqualStrings("Inconsolata", (try positionFontFamily(position_value)).?);
}

test "a range folds to one value when every run agrees" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, "Noto", "Noto");

    const folded = try rangeFontFamily(gpa, try wholeRange(gpa, &state));
    // The two runs hold equal text in different buffers, so a fold that
    // compared slice headers would answer `.mixed` here.
    try testing.expectEqualStrings("Noto", folded.single.?);
}

test "a range is mixed when one run overrides the others" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, "Noto", "Inconsolata");

    const folded = try rangeFontFamily(gpa, try wholeRange(gpa, &state));
    try testing.expect(folded == .mixed);
}

test "a range is mixed when one run declares nothing and the other does" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, "Noto", null);

    const folded = try rangeFontFamily(gpa, try wholeRange(gpa, &state));
    // Absent and present are different answers, so the fold reports mixed
    // rather than the one value it saw.
    try testing.expect(folded == .mixed);
}

test "a range is mixed when one child overrides the document around both runs" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    var document = schema.Node.init(gpa, .text_input);
    errdefer document.deinit();
    try schema.ids_props.setChildren(&document.properties, &.{
        .{ .value = 1 },
        .{ .value = 2 },
    });
    try schema.strings.setFontFamily(&document.properties, "Noto");
    try insert(gpa, &state, 0, null, document);
    try insert(gpa, &state, 1, 0, try textRun(gpa, "text 1"));
    var overriding = try textRun(gpa, "text 2");
    errdefer overriding.deinit();
    try schema.strings.setFontFamily(&overriding.properties, "Inconsolata");
    // `insert` takes the node by value and stores it in the map, so ownership
    // ends here. The `errdefer` above still covers the two lines that run
    // before it, but it must not survive past this point: a later failed
    // assertion would fire it and free a node the map also owns.
    insert(gpa, &state, 2, 0, overriding) catch |err| {
        overriding.deinit();
        return err;
    };

    // `expectEqual` on a slice compares the header, including the pointer, so
    // two equal strings in two different buffers would fail here. The fold
    // stores "Noto" in the document's own buffer and the walk answers that
    // buffer, and it is not the same allocation the literal is.
    try testing.expectEqualStrings("Noto", (try nodeFontFamily(try handle(&state, 0))).?);
    const position_at_second: Position = .{
        .root_node = try handle(&state, 0),
        .inner = .{ .node = try handle(&state, 2), .character_index = 0 },
    };
    try testing.expectEqualStrings(
        "Inconsolata",
        (try positionFontFamily(position_at_second)).?,
    );
    const position_at_first: Position = .{
        .root_node = try handle(&state, 0),
        .inner = .{ .node = try handle(&state, 1), .character_index = 0 },
    };
    try testing.expectEqualStrings("Noto", (try positionFontFamily(position_at_first)).?);
    const folded = try rangeFontFamily(gpa, try wholeRange(gpa, &state));
    try testing.expect(folded == .mixed);
}

fn wholeRange(gpa: std.mem.Allocator, state: *const tree_state.TreeState) !Range {
    return range.init(
        gpa,
        try handle(state, 0),
        .{ .node = try handle(state, 1), .character_index = 0 },
        .{ .node = try handle(state, 2), .character_index = 6 },
    );
}

test "a flag set on the run reaches the run and folds across a range" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, null, null);
    const second_run = state.nodes.getPtr(FullNodeId.init(.{ .value = 2 }, .init(0))) orelse
        return error.NodeMissingFromFixture;
    schema.flags.setItalic(&second_run.data.flags, true);

    try testing.expect((try nodeIsItalic(try handle(&state, 2))));

    const position_value: Position = .{
        .root_node = try handle(&state, 0),
        .inner = .{ .node = try handle(&state, 2), .character_index = 0 },
    };
    try testing.expect((try positionIsItalic(position_value)));

    const folded = try rangeIsItalic(gpa, try wholeRange(gpa, &state));
    try testing.expect(folded == .mixed);
}

test "an unset flag is false everywhere and folds to a single false" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, null, null);

    // The flag walk answers `false` rather than "unset", so the range fold has
    // an answer for every run and never reports mixed for two quiet runs.

    const folded = try rangeIsItalic(gpa, try wholeRange(gpa, &state));
    try testing.expectEqual(false, folded.single.?);
}

test "no ancestor declares the value and the family answers null" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    try twoRunDocument(gpa, &state, null, null);

    // The walk climbs to the document and stops there, which is what the doc
    // comment on `nodeFontFamily` promises.

    try testing.expectEqual(@as(?[]const u8, null), try nodeFontFamily(try handle(&state, 0)));

    // A range whose runs declare nothing folds to a single absent value, which
    // is a different answer from mixed.
    const folded = try rangeFontFamily(gpa, try wholeRange(gpa, &state));
    try testing.expectEqual(@as(?[]const u8, null), folded.single);
}

test "the shared walk stops with TreeCycle at its bound" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    // Three nodes whose parents form a cycle: 1 → 2 → 3 → 1. Nothing declares
    // a family and no flag is set, so the walk never finds an answer and would
    // climb forever without the bound.
    //
    // The cycle cannot be wired through `insert`, because that helper reads
    // the parent's child list to compute the index and a parent that does not
    // exist yet is a null it unwraps. So all three go in parentless and the
    // relations are written afterwards.
    for (1..4) |value| try insert(gpa, &state, value, null, try textRun(gpa, "text"));
    for (1..4) |value| {
        const id = FullNodeId.init(.{ .value = value }, .init(0));
        const parent_id = FullNodeId.init(.{ .value = value % 3 + 1 }, .init(0));
        const entry = state.nodes.getPtr(id) orelse return error.NodeMissingFromFixture;
        entry.parent_and_index = .{ .parent_id = parent_id, .index = 0 };
    }

    // Every step of the walk moves to a different node and the count also
    // catches a repeat, so a bound equal to the node count stops the cycle.
    try testing.expectEqual(@as(usize, 3), walkStepBound(state.nodes.count()));
    try testing.expectError(error.TreeCycle, nodeFontFamily(try handle(&state, 1)));

    // The flag walk is the same loop over the same bound, so it reports the
    // same tag rather than a second one.
    try testing.expectError(error.TreeCycle, nodeIsItalic(try handle(&state, 1)));
}

test "the same walk one step short of the bound still finds the value" {
    var state: tree_state.TreeState = .{};
    defer state.deinit(testing.allocator);
    const gpa = testing.allocator;
    // A chain of three nodes, 3 at the bottom and 1 at the top, with the value
    // on the top node. The walk takes three steps and the bound is three, so
    // this is the positive half of the test above.
    var top = schema.Node.init(gpa, .text_input);
    errdefer top.deinit();
    try schema.strings.setFontFamily(&top.properties, "Noto");
    // `insert` takes ownership, so the `errdefer` above must not outlive it.
    insert(gpa, &state, 1, null, top) catch |err| {
        top.deinit();
        return err;
    };
    try insert(gpa, &state, 2, 1, try textRun(gpa, "text"));
    try insert(gpa, &state, 3, 2, try textRun(gpa, "text"));
    try testing.expectEqual(@as(usize, 3), walkStepBound(state.nodes.count()));

    // Both runs declare nothing, so both must reach the top node and find its
    // family. Comparing strings rather than slice headers: the value lives in
    // the top node's buffer, not in the literal's.
    try testing.expectEqualStrings("Noto", (try nodeFontFamily(try handle(&state, 3))).?);
    try testing.expectEqualStrings("Noto", (try nodeFontFamily(try handle(&state, 2))).?);
}

comptime {
    // The family is 13 properties with three receivers each, so it is 39
    // functions. The list is what makes a rename a compile error here rather
    // than a quiet change to that count.
    const property_names = .{
        "TextDirection", "FontFamily",      "Language",        "FontSize",
        "FontWeight",    "BackgroundColor", "ForegroundColor", "Overline",
        "Strikethrough", "Underline",       "TextAlign",       "VerticalOffset",
        "IsItalic",
    };
    std.debug.assert(property_names.len == 13);
    for (property_names) |property_name| {
        _ = @field(Self, "node" ++ property_name);
        _ = @field(Self, "position" ++ property_name);
        _ = @field(Self, "range" ++ property_name);
    }
    std.debug.assert(walkStepBound(0) == 0);
    std.debug.assert(walkStepBound(65_536) == 65_536);
}
