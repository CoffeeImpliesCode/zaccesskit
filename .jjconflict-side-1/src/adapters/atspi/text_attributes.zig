//! The ten text attributes `Text.GetAttributeValue` answers by name, and the
//! table that names them.
//!
//! **Upstream.** `accesskit_atspi_common/src/text_attributes.rs:10-79`. The
//! table at `:68-79` is a `phf::Map` from the AT-SPI attribute name to a getter,
//! and the ten getters at `:10-66` are private functions the map names.
//! `docs/41-atspi-build-map.md` section 2.2 gives this module
//! `text_attributes.rs`.
//!
//! **A perfect hash map in Rust, an ordered table in Zig.** The map exists
//! because Rust has no constant initialiser for a hash map. A Zig table of
//! ten pairs is a `comptime` value, so the port keeps the pairs in the order the
//! reference writes them and looks a name up with a linear scan. Ten entries is
//! the whole domain, so the scan is bounded by `attribute_count` and the bound is
//! a comptime constant.
//!
//! **Every getter copies its answer.** Upstream's getters that read a borrowed
//! `&str` allocate a `String`, so a caller owns the text and releases it. The
//! getters here all return a buffer `gpa` allocated and the caller releases with
//! the same `gpa`, so the ten getters have one ownership rule rather than two.
//!
//! **Two of the ten are not properties.** `style` is the italic flag, and it
//! answers `null` when the node is not italic rather than an empty string, which
//! is upstream's `.then(|| "italic".into())` at `text_attributes.rs:27`. Every
//! other entry answers `null` only when the node declares nothing.
//!
//! **`justification` does not spell `justify`.** The reference calls the AT-SPI
//! value `fill`, at `text_attributes.rs:62`, and a client matches that string, so
//! the port writes `fill`.

const std = @import("std");

const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");

const Color = schema.Color;
const NodeRef = consumer.node_id.NodeRef;
const QueryError = consumer.tree.QueryError;
const TextAlign = schema.TextAlign;

/// The failures a text attribute read reports.
///
/// A walk of the inherited-property chain can report a cycle, and four of the
/// ten getters format a number, which allocates.
pub const AttributeError = QueryError || std.mem.Allocator.Error;

/// One named getter: it reads one attribute off one node and returns text the
/// caller owns, or `null` when the node declares none.
pub const Getter = *const fn (gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8;

/// One entry of the table: the name a client sends and the getter that answers
/// it.
pub const Entry = struct {
    /// The AT-SPI attribute name, which is what `Text.GetAttributeValue` takes
    /// as its second argument.
    name: []const u8,
    /// The getter behind that name.
    getter: Getter,
};

/// How many names the reference declares, which is `text_attributes.rs:69-78`.
pub const attribute_count: usize = 10;

/// The table, in the order `text_attributes.rs:69-78` writes it.
pub const attributes: [attribute_count]Entry = .{
    .{ .name = "family-name", .getter = familyName },
    .{ .name = "size", .getter = size },
    .{ .name = "weight", .getter = weight },
    .{ .name = "style", .getter = style },
    .{ .name = "strikethrough", .getter = strikethrough },
    .{ .name = "underline", .getter = underline },
    .{ .name = "bg-color", .getter = bgColor },
    .{ .name = "fg-color", .getter = fgColor },
    .{ .name = "language", .getter = language },
    .{ .name = "justification", .getter = justification },
};

/// The getter `name` selects, or `null` when the table holds no such name.
///
/// Upstream's `ATTRIBUTE_GETTERS.get(attribute_name)` at `node.rs:1487`, whose
/// `None` arm the caller turns into an empty string at `node.rs:1490`.
///
/// **Bound.** `attributes.len`, which is `attribute_count` and a comptime
/// constant, so the scan cannot run past the end.
///
/// **Errors.** This function does not fail.
pub fn lookup(name: []const u8) ?Getter {
    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, name)) return attribute.getter;
    }
    return null;
}

/// The name the table holds at `index`, or `null` when `index` is past it.
///
/// **Errors.** This function does not fail.
pub fn nameAt(index: usize) ?[]const u8 {
    if (index >= attributes.len) return null;
    return attributes[index].name;
}

/// `text_attributes.rs:14-16`.
fn familyName(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeFontFamily(node) orelse return null;
    const value = try gpa.dupe(u8, found);
    return value;
}

/// `text_attributes.rs:18-20`. A size of `12.0` reads back as `12`.
fn size(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeFontSize(node) orelse return null;
    const value = try std.fmt.allocPrint(gpa, "{d}", .{found});
    return value;
}

/// `text_attributes.rs:22-24`. A weight of `400.0` reads back as `400`.
fn weight(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeFontWeight(node) orelse return null;
    const value = try std.fmt.allocPrint(gpa, "{d}", .{found});
    return value;
}

/// `text_attributes.rs:26-28`. A node that is not italic answers `null`, which
/// is what makes this entry absent rather than empty.
fn style(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    if (!try consumer.text.inherited.nodeIsItalic(node)) return null;
    const value = try gpa.dupe(u8, "italic");
    return value;
}

/// `text_attributes.rs:30-32`. A node that declares a strikethrough answers
/// `true` whatever the decoration is, because the reference writes the same
/// string for all of them.
fn strikethrough(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    if (try consumer.text.inherited.nodeStrikethrough(node) == null) return null;
    const value = try gpa.dupe(u8, "true");
    return value;
}

/// `text_attributes.rs:34-42`. A double decoration reads back as `double` and
/// every other decoration as `single`, which is the reference's wildcard arm.
fn underline(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeUnderline(node) orelse return null;
    const value = try gpa.dupe(u8, switch (found.style) {
        .double => "double",
        .solid, .dotted, .dashed, .wavy => "single",
    });
    return value;
}

/// `text_attributes.rs:10-12` and `:44-46`. Three channels and no alpha, which
/// is what the reference's `format!("{},{},{}")` writes.
fn colorToString(gpa: std.mem.Allocator, color: Color) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa, "{d},{d},{d}", .{ color.red, color.green, color.blue });
}

/// `text_attributes.rs:44-46`.
fn bgColor(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeBackgroundColor(node) orelse return null;
    const value = try colorToString(gpa, found);
    return value;
}

/// `text_attributes.rs:48-50`.
fn fgColor(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeForegroundColor(node) orelse return null;
    const value = try colorToString(gpa, found);
    return value;
}

/// `text_attributes.rs:52-54`.
fn language(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeLanguage(node) orelse return null;
    const value = try gpa.dupe(u8, found);
    return value;
}

/// `text_attributes.rs:56-66`. `justify` reads back as `fill`, which is the
/// name the reference gives the AT-SPI value.
fn justification(gpa: std.mem.Allocator, node: NodeRef) AttributeError!?[]u8 {
    const found = try consumer.text.inherited.nodeTextAlign(node) orelse return null;
    const value = try gpa.dupe(u8, switch (found) {
        .left => "left",
        .center => "center",
        .right => "right",
        .justify => "fill",
    });
    return value;
}

const testing = std.testing;

comptime {
    // The table is the domain. A getter added without a name, or a name added
    // without a getter, fails the build here rather than at a client.
    for (attributes) |attribute| {
        if (attribute.name.len == 0) @compileError("a text attribute needs a name");
        // `Entry.getter` is a non-optional function pointer, so a table cannot
        // hold a name with no getter: the type makes that a build error on its
        // own. What it can hold is the wrong function, so the check that stays
        // is that every name resolves back to the getter filed under it,
        // which `lookup` is the only way to ask.
        const found = lookup(attribute.name);
        if (found == null or found.? != attribute.getter) {
            @compileError("a text attribute name does not reach its own getter");
        }
    }
    // `attributes.len` is `attribute_count` by construction, and this names the
    // ten of `text_attributes.rs:69-78` so a dropped entry is a build error.
    if (attributes.len != attribute_count) @compileError("the table lost an entry");
}

/// Stores `node` under `value` so a test can build a tree without the update
/// algorithm. `consumer/text/query.zig:434`.
fn insert(
    gpa: std.mem.Allocator,
    state: *consumer.tree_state.TreeState,
    value: u64,
    node: schema.Node,
) !void {
    const id = consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0));
    try state.nodes.put(gpa, id, .{ .parent_and_index = null, .data = node });
}

/// The handle to the node stored under `value`.
fn handle(state: *const consumer.tree_state.TreeState, value: u64) !NodeRef {
    return NodeRef.init(
        state,
        consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0)),
    ) orelse error.NodeMissingFromFixture;
}

/// The map entry for `value`, which is where a fixture writes.
fn mapEntry(state: *consumer.tree_state.TreeState, value: u64) !*consumer.tree_state.NodeState {
    return state.nodes.getPtr(consumer.tree_index.FullNodeId.init(.{ .value = value }, .init(0))) orelse
        error.NodeMissingFromFixture;
}

/// A one-node tree whose node is `role`, which is what every inherited property
/// walk reads.
fn oneNode(gpa: std.mem.Allocator, state: *consumer.tree_state.TreeState, role: schema.Role) !void {
    try insert(gpa, state, 0, schema.Node.init(gpa, role));
    state.root_id = consumer.tree_index.FullNodeId.init(.{ .value = 0 }, .init(0));
    state.focus_id = state.root_id;
    state.is_host_focused = false;
}

/// Reads one attribute off the one node and releases what it returns.
fn readOf(node: NodeRef, name: []const u8) !?[]u8 {
    const getter = lookup(name) orelse return error.NoSuchAttribute;
    return getter(testing.allocator, node);
}

test "every name the reference declares is in the table" {
    // The ten names of `text_attributes.rs:69-78`, in order. A table that lost
    // one or spelled one differently fails here.
    try testing.expectEqualStrings("family-name", attributes[0].name);
    try testing.expectEqualStrings("size", attributes[1].name);
    try testing.expectEqualStrings("weight", attributes[2].name);
    try testing.expectEqualStrings("style", attributes[3].name);
    try testing.expectEqualStrings("strikethrough", attributes[4].name);
    try testing.expectEqualStrings("underline", attributes[5].name);
    try testing.expectEqualStrings("bg-color", attributes[6].name);
    try testing.expectEqualStrings("fg-color", attributes[7].name);
    try testing.expectEqualStrings("language", attributes[8].name);
    try testing.expectEqualStrings("justification", attributes[9].name);
}

test "a lookup finds every name and refuses one that is not there" {
    for (attributes) |attribute| {
        try testing.expectEqual(attribute.getter, lookup(attribute.name).?);
        try testing.expectEqualStrings(attribute.name, nameAt(tableIndex(attribute.name)).?);
    }
    // `node.rs:1487-1490` answers an unknown name with `None`, which the caller
    // turns into an empty string.
    try testing.expectEqual(@as(?Getter, null), lookup("line-spacing"));
    try testing.expectEqual(@as(?[]const u8, null), nameAt(attribute_count));
}

test "a node that declares nothing answers null for every name" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node = try handle(&state, 0);

    for (attributes) |attribute| {
        if (std.mem.eql(u8, attribute.name, "style")) continue;
        const found = try attribute.getter(gpa, node);
        try testing.expectEqual(@as(?[]u8, null), found);
    }
}

test "the font attributes read the three stored values" {
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node_state = try mapEntry(&state, 0);
    try schema.strings.setFontFamily(&node_state.data.properties, "Noto");
    try schema.numbers.setFontSize(&node_state.data.properties, 12.0);
    try schema.numbers.setFontWeight(&node_state.data.properties, 700.0);
    try schema.strings.setLanguage(&node_state.data.properties, "en");
    const node = try handle(&state, 0);

    const family = (try readOf(node, "family-name")) orelse return error.TestExpectedEqual;
    defer gpa.free(family);
    try testing.expectEqualStrings("Noto", family);

    const size_text = (try readOf(node, "size")) orelse return error.TestExpectedEqual;
    defer gpa.free(size_text);
    // Rust's `12.0f32.to_string()` is `12`, and this is the same number.
    try testing.expectEqualStrings("12", size_text);

    const weight_text = (try readOf(node, "weight")) orelse return error.TestExpectedEqual;
    defer gpa.free(weight_text);
    try testing.expectEqualStrings("700", weight_text);

    const tag = (try readOf(node, "language")) orelse return error.TestExpectedEqual;
    defer gpa.free(tag);
    try testing.expectEqualStrings("en", tag);
}

test "a node that is not italic has no style and a node that is has one" {
    // `text_attributes.rs:27`. This is the only entry whose absence means false
    // rather than unset.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node = try handle(&state, 0);

    try testing.expectEqual(@as(?[]u8, null), try readOf(node, "style"));

    const node_state = try mapEntry(&state, 0);
    // `setItalic` at `schema/props/flags.zig:251` writes the node's own flag
    // word through a pointer and answers `void`, so there is no `try` either.
    schema.flags.setItalic(&node_state.data.flags, true);
    const italic = (try readOf(node, "style")) orelse return error.TestExpectedEqual;
    defer gpa.free(italic);
    try testing.expectEqualStrings("italic", italic);
}

test "the colours read three channels and no alpha" {
    // `text_attributes.rs:11` formats three channels, so an alpha of zero still
    // reads back as the same three numbers.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node_state = try mapEntry(&state, 0);
    try schema.colors.setBackgroundColor(
        &node_state.data.properties,
        .{ .red = 1, .green = 2, .blue = 3, .alpha = 0 },
    );
    try schema.colors.setForegroundColor(
        &node_state.data.properties,
        .{ .red = 255, .green = 0, .blue = 0, .alpha = 255 },
    );
    const node = try handle(&state, 0);

    const behind = (try readOf(node, "bg-color")) orelse return error.TestExpectedEqual;
    defer gpa.free(behind);
    try testing.expectEqualStrings("1,2,3", behind);

    const in_front = (try readOf(node, "fg-color")) orelse return error.TestExpectedEqual;
    defer gpa.free(in_front);
    try testing.expectEqualStrings("255,0,0", in_front);
}

test "an underline reads as double and every other decoration as single" {
    // `text_attributes.rs:36-40`. The wildcard arm is the whole of the
    // difference, so one decoration from each side is what this needs.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node_state = try mapEntry(&state, 0);
    const node = try handle(&state, 0);

    try schema.colors.setUnderline(
        &node_state.data.properties,
        .{ .style = .double, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 } },
    );
    const doubled = (try readOf(node, "underline")) orelse return error.TestExpectedEqual;
    defer gpa.free(doubled);
    try testing.expectEqualStrings("double", doubled);

    try schema.colors.setUnderline(
        &node_state.data.properties,
        .{ .style = .wavy, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 } },
    );
    const waved = (try readOf(node, "underline")) orelse return error.TestExpectedEqual;
    defer gpa.free(waved);
    try testing.expectEqualStrings("single", waved);
}

test "a strikethrough reads as true whatever its decoration is" {
    // `text_attributes.rs:31`. The getter ignores the decoration, so a dotted
    // strikethrough reads the same as a solid one.
    const gpa = testing.allocator;
    var state: consumer.tree_state.TreeState = .{};
    defer state.deinit(gpa);
    try oneNode(gpa, &state, .text_run);
    const node_state = try mapEntry(&state, 0);
    try schema.colors.setStrikethrough(
        &node_state.data.properties,
        .{ .style = .dotted, .color = .{ .red = 0, .green = 0, .blue = 0, .alpha = 255 } },
    );
    const node = try handle(&state, 0);

    const answer = (try readOf(node, "strikethrough")) orelse return error.TestExpectedEqual;
    defer gpa.free(answer);
    try testing.expectEqualStrings("true", answer);
}

test "the four alignments read as the four names the reference writes" {
    // `text_attributes.rs:58-64`. `justify` reads as `fill`, and a port that
    // wrote `justify` would fail every client that matches the string.
    const gpa = testing.allocator;
    const wanted = [_]struct { alignment: TextAlign, text: []const u8 }{
        .{ .alignment = .left, .text = "left" },
        .{ .alignment = .center, .text = "center" },
        .{ .alignment = .right, .text = "right" },
        .{ .alignment = .justify, .text = "fill" },
    };

    for (wanted) |one| {
        var state: consumer.tree_state.TreeState = .{};
        defer state.deinit(gpa);
        try oneNode(gpa, &state, .text_run);
        const node_state = try mapEntry(&state, 0);
        try schema.enums.setTextAlign(&node_state.data.properties, one.alignment);
        const node = try handle(&state, 0);

        const answer = (try readOf(node, "justification")) orelse return error.TestExpectedEqual;
        defer gpa.free(answer);
        try testing.expectEqualStrings(one.text, answer);
    }
}

/// The index of `name` in the table, for the lookup test.
fn tableIndex(name: []const u8) usize {
    for (attributes, 0..) |attribute, index| {
        if (std.mem.eql(u8, attribute.name, name)) return index;
    }
    return attributes.len;
}
