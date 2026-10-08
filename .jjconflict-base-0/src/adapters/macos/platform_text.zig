//! Native text selectors from pinned AccessKit macOS node.rs:755-1046.
//! NSRange indexes count UTF-16 units; consumer ranges and positions borrow the
//! leased tree, while Foundation outputs own independent +1 native references.
//! util.rs:13-36 provides the range conversions; :38-83 provides geometry.
//! The parent platform node owns Objective-C autorelease-return and error sentinels.
//!
const std = @import("std");
const builtin = @import("builtin");
const consumer = @import("../../consumer/root.zig");
const schema = @import("../../schema/root.zig");
const objc = @import("objc.zig");
const foundation = @import("foundation.zig");
const context = @import("context.zig");
const util = @import("util.zig");
const affine = @import("../../schema/geometry/affine.zig");

const testing = std.testing;
const NodeRef = consumer.node_id.NodeRef;
const text_query = consumer.text.query;
const text_range = consumer.text.range;
const position = consumer.text.position;
const motion = consumer.text.position_motion;
const inherited = consumer.text.inherited;
const NativeError = context.NativeError;

const TestLease = struct {
    gpa: std.mem.Allocator,
    tree_state: *const consumer.tree_state.TreeState,
    selected: ?schema.ActionRequest = null,
    consumed: bool = false,
    native_view: ?objc.Object = null,
    dispatch_failure: ?NativeError = null,
    guard_held: bool = true,
    guard_reacquisitions: usize = 0,
    reacquire_failure: ?NativeError = null,

    // The tree stays fixed during each query. These flags are not a native mutex or owner pin.
    fn releaseGuard(self: *TestLease) void {
        self.guard_held = false;
    }
    fn reacquireGuard(self: *TestLease) NativeError!void {
        self.guard_reacquisitions += 1;
        if (self.reacquire_failure) |failure| return failure;
        self.guard_held = true;
    }
    fn resolve(self: *TestLease, id: consumer.tree_index.FullNodeId) ?NodeRef {
        if (!self.guard_held) return null;
        return NodeRef.init(self.tree_state, id);
    }

    fn allocator(self: *TestLease) std.mem.Allocator {
        return self.gpa;
    }
    fn view(self: *TestLease) ?objc.Object {
        return self.native_view;
    }
    fn state(self: *TestLease) ?*const consumer.tree_state.TreeState {
        return if (self.guard_held) self.tree_state else null;
    }
    fn dispatch(self: *TestLease, request: schema.ActionRequest) NativeError!void {
        self.selected = request;
        self.consumed = true;
        self.guard_held = false;
        if (self.dispatch_failure) |failure| return failure;
    }
};

fn fixtureId(value: u64) consumer.tree_index.FullNodeId {
    return .init(.{ .value = value }, .init(0));
}

fn fixtureInsert(gpa: std.mem.Allocator, state: *consumer.tree_state.TreeState, value: u64, node: schema.Node) !void {
    errdefer {
        var owned = node;
        owned.deinit();
    }
    try state.nodes.put(gpa, fixtureId(value), .{
        .parent_and_index = if (value == 1) null else .{
            .parent_id = fixtureId(1),
            .index = @intCast(value - 2),
        },
        .data = node,
    });
}

fn fixture(gpa: std.mem.Allocator) !consumer.tree_state.TreeState {
    var state: consumer.tree_state.TreeState = .{
        .root_id = fixtureId(1),
        .focus_id = fixtureId(1),
    };
    errdefer state.deinit(gpa);
    _ = try state.tree_index_map.getOrCreateIndex(gpa, schema.tree_id_root);
    var root = schema.Node.init(gpa, .multiline_text_input);
    {
        errdefer root.deinit();
        try schema.ids_props.setChildren(&root.properties, &.{ .{ .value = 2 }, .{ .value = 3 } });
        try schema.option.setTextSelection(&root.properties, .{
            .anchor = .{ .node_id = .{ .value = 2 }, .character_index = 1 },
            .focus = .{ .node_id = .{ .value = 3 }, .character_index = 1 },
        });
    }
    try fixtureInsert(gpa, &state, 1, root);
    var first = schema.Node.init(gpa, .text_run);
    {
        errdefer first.deinit();
        try schema.strings.setValue(&first.properties, "a\u{1f642}\n");
        try schema.vectors.setCharacterLengths(&first.properties, &.{ 1, 4, 1 });
        try schema.vectors.setCharacterPositions(&first.properties, &.{ 0, 10, 20 });
        try schema.vectors.setCharacterWidths(&first.properties, &.{ 10, 10, 0 });
        try schema.option.setBounds(&first.properties, schema.rectInit(0, 0, 20, 10));
        try schema.enums.setTextDirection(&first.properties, .left_to_right);
        try schema.numbers.setFontSize(&first.properties, 12);
    }
    try fixtureInsert(gpa, &state, 2, first);
    var second = schema.Node.init(gpa, .text_run);
    {
        errdefer second.deinit();
        try schema.strings.setValue(&second.properties, "é\x00b");
        try schema.vectors.setCharacterLengths(&second.properties, &.{ 2, 1, 1 });
        try schema.vectors.setCharacterPositions(&second.properties, &.{ 0, 10, 20 });
        try schema.vectors.setCharacterWidths(&second.properties, &.{ 10, 10, 10 });
        try schema.option.setBounds(&second.properties, schema.rectInit(0, 20, 30, 30));
        try schema.enums.setTextDirection(&second.properties, .left_to_right);
        try schema.numbers.setFontSize(&second.properties, 18);
    }
    try fixtureInsert(gpa, &state, 3, second);
    return state;
}

fn fixtureRoot(state: *const consumer.tree_state.TreeState) !NodeRef {
    return NodeRef.init(state, fixtureId(1)) orelse error.NodeMissingFromFixture;
}

fn expectRange(expected: objc.NSRange, actual: objc.NSRange) !void {
    try testing.expectEqual(expected.location, actual.location);
    try testing.expectEqual(expected.length, actual.length);
}

test "native text selectors use UTF16 counts character boundaries lines and style boundaries" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    try testing.expectEqual(@as(isize, 7), try queryImpl(28, &lease, root, {}));
    try expectRange(.{ .location = 1, .length = 4 }, try queryImpl(30, &lease, root, {}));
    try testing.expectEqual(@as(isize, 1), try queryImpl(31, &lease, root, {}));
    try expectRange(.{ .location = 0, .length = 4 }, try queryImpl(32, &lease, root, @as(isize, 0)));
    try expectRange(.{ .location = 4, .length = 3 }, try queryImpl(32, &lease, root, @as(isize, 1)));
    try testing.expectEqual(@as(isize, 1), try queryImpl(37, &lease, root, @as(isize, 5)));
    try expectRange(.{ .location = 1, .length = 2 }, try queryImpl(38, &lease, root, @as(isize, 1)));
    try expectRange(.{ .location = 7, .length = 0 }, try queryImpl(38, &lease, root, @as(isize, 7)));
    try expectRange(.{ .location = 0, .length = 4 }, try queryImpl(39, &lease, root, @as(isize, 2)));
    try expectRange(.{ .location = 4, .length = 3 }, try queryImpl(39, &lease, root, @as(isize, 5)));
}

test "native text selectors refuse invalid signed indexes and absent geometry with upstream zeros" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    inline for (.{ 32, 38, 39 }) |index| {
        try expectRange(.{ .location = 0, .length = 0 }, try queryImpl(index, &lease, root, @as(isize, -1)));
        try expectRange(.{ .location = 0, .length = 0 }, try queryImpl(index, &lease, root, @as(isize, 99)));
    }
    try testing.expectEqual(@as(isize, 0), try queryImpl(37, &lease, root, @as(isize, -1)));
    try expectRange(.{ .location = 0, .length = 0 }, try queryImpl(33, &lease, root, objc.NSPoint{ .x = 0, .y = 0 }));
    const frame = try queryImpl(36, &lease, root, objc.NSRange{ .location = 0, .length = 7 });
    try testing.expectEqual(@as(f64, 0), frame.origin.x);
    try testing.expectEqual(@as(f64, 0), frame.size.width);
    try testing.expectEqual(@as(f64, 0), frame.size.height);
}

test "native text range rejects overflow before allocation and leaves invalid selection unchanged" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    try testing.expectError(
        error.RangeOverflow,
        fromRange(testing.allocator, root, .{ .location = 1, .length = std.math.maxInt(usize) }),
    );
    try testing.expect((try fromRange(testing.allocator, root, .{ .location = 8, .length = 0 })) == null);
    try testing.expect((try fromRange(testing.allocator, root, .{ .location = 5, .length = 99 })) == null);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    try queryImpl(40, &lease, root, objc.NSRange{ .location = 8, .length = 0 });
    try testing.expect(!lease.consumed);
    try queryImpl(40, &lease, root, objc.NSRange{ .location = 1, .length = 4 });
    try testing.expect(lease.consumed);
    const request = lease.selected orelse return error.MissingSelectionRequest;
    try testing.expectEqual(schema.Action.set_text_selection, request.action);
    try testing.expectEqual(@as(u64, 1), request.target_node.value);
    const selected = request.data.?.set_text_selection;
    try testing.expectEqual(@as(u64, 2), selected.anchor.node_id.value);
    try testing.expectEqual(@as(usize, 1), selected.anchor.character_index);
    try testing.expectEqual(@as(u64, 3), selected.focus.node_id.value);
    try testing.expectEqual(@as(usize, 1), selected.focus.character_index);
}

fn allocationScenario(gpa: std.mem.Allocator) !void {
    var state = try fixture(gpa);
    defer state.deinit(gpa);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = gpa, .tree_state = &state };
    _ = try queryImpl(28, &lease, root, {});
    _ = try queryImpl(30, &lease, root, {});
    _ = try queryImpl(32, &lease, root, @as(isize, 1));
    _ = try queryImpl(38, &lease, root, @as(isize, 1));
    _ = try queryImpl(39, &lease, root, @as(isize, 5));
    const range = (try fromRange(gpa, root, .{ .location = 1, .length = 4 })).?;
    var bytes = try text_range.text(gpa, range);
    defer bytes.deinit(gpa);
    try testing.expectEqualStrings("\u{1f642}\né", bytes.items);
    var boxes = try text_range.boundingBoxes(gpa, range);
    defer boxes.deinit(gpa);
    try testing.expectEqual(@as(usize, 2), boxes.items.len);
    try testing.expectEqual(@as(f64, 10), boxes.items[0].x0);
    try testing.expectEqual(@as(f64, 10), boxes.items[1].x1);
    const bounds = (try boundsForRange(gpa, range)).?;
    try testing.expectEqual(@as(f64, 0), bounds.x0);
    try testing.expectEqual(@as(f64, 0), bounds.y0);
    try testing.expectEqual(@as(f64, 20), bounds.x1);
    try testing.expectEqual(@as(f64, 30), bounds.y1);
}

test "native text allocated ordering keys text and bounding boxes release at every failure" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationScenario, .{});
}

test "native text propagates inconsistent UTF16 character metadata" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const entry = state.nodes.getPtr(fixtureId(2)).?;
    try schema.vectors.setCharacterLengths(&entry.data.properties, &.{1});
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    try testing.expectError(error.IndexOutOfRange, queryImpl(38, &lease, root, @as(isize, 3)));
}

test "native text NSString preserves embedded NUL and selection Unicode" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    const selected = (try queryImpl(29, &lease, root, {})).?;
    defer objc.release(selected);
    try testing.expectEqualStrings("\u{1f642}\né", try foundation.utf8(selected));
    const value = (try queryImpl(34, &lease, root, objc.NSRange{ .location = 4, .length = 3 })).?;
    defer objc.release(value);
    try testing.expectEqualStrings("é\x00b", try foundation.utf8(value));
    try testing.expectEqual(@as(usize, 3), objc.send(usize, value, "length", .{}));
    try testing.expect((try queryImpl(34, &lease, root, objc.NSRange{ .location = 8, .length = 0 })) == null);
}

test "native attributed text preserves all upstream style attributes and UTF16 run extents" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const props = &state.nodes.getPtr(fixtureId(2)).?.data.properties;
    const red: schema.Color = .{ .red = 255, .green = 0, .blue = 0, .alpha = 255 };
    try schema.colors.setBackgroundColor(props, red);
    try schema.colors.setForegroundColor(props, red);
    try schema.strings.setFontFamily(props, "Test Family");
    try schema.numbers.setFontWeight(props, 700);
    schema.flags.setItalic(&state.nodes.getPtr(fixtureId(2)).?.data.flags, true);
    try schema.colors.setUnderline(props, .{ .style = .dotted, .color = red });
    try schema.colors.setStrikethrough(props, .{ .style = .solid, .color = red });
    try schema.strings.setLanguage(props, "en");
    try schema.enums.setTextAlign(props, .justify);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    const value = (try queryImpl(35, &lease, root, objc.NSRange{ .location = 1, .length = 6 })).?;
    defer objc.release(value);
    const value_string = objc.send(?objc.Object, value, "string", .{}).?;
    try testing.expectEqualStrings("\u{1f642}\né\x00b", try foundation.utf8(value_string));
    var effective: objc.NSRange = undefined;
    const attrs = objc.send(?objc.Object, value, "attributesAtIndex:effectiveRange:", .{ @as(usize, 0), &effective }).?;
    try expectRange(.{ .location = 0, .length = 3 }, effective);
    inline for (.{
        "AXBackgroundColor",
        "AXForegroundColor",
        "AXFont",
        "AXUnderline",
        "AXUnderlineColor",
        "AXStrikethrough",
        "AXStrikethroughColor",
        "AXLanguage",
        "AXTextAlignment",
    }) |key_bytes| {
        const key = try foundation.string(key_bytes);
        defer objc.release(key);
        try testing.expect(objc.send(?objc.Object, attrs, "objectForKey:", .{key}) != null);
    }
    const font_key = try foundation.string("AXFont");
    defer objc.release(font_key);
    const font = objc.send(?objc.Object, attrs, "objectForKey:", .{font_key}).?;
    const bold_key = try foundation.string("AXFontBold");
    defer objc.release(bold_key);
    const bold = objc.send(?objc.Object, font, "objectForKey:", .{bold_key}).?;
    try testing.expectEqual(@as(u8, 1), objc.send(u8, bold, "boolValue", .{}));
    const later_attrs = objc.send(?objc.Object, value, "attributesAtIndex:effectiveRange:", .{
        @as(usize, 3), &effective,
    }).?;
    const later_font = objc.send(?objc.Object, later_attrs, "objectForKey:", .{font_key}).?;
    try testing.expect(objc.send(?objc.Object, later_font, "objectForKey:", .{bold_key}) == null);
    inline for (.{ "AXFontItalic", "AXFontFamily", "AXFontSize" }) |key_bytes| {
        const key = try foundation.string(key_bytes);
        defer objc.release(key);
        const item = objc.send(?objc.Object, font, "objectForKey:", .{key}).?;
        if (comptime std.mem.eql(u8, key_bytes, "AXFontItalic")) {
            try testing.expectEqual(@as(u8, 1), objc.send(u8, item, "boolValue", .{}));
        } else if (comptime std.mem.eql(u8, key_bytes, "AXFontFamily")) {
            try testing.expectEqualStrings("Test Family", try foundation.utf8(item));
        } else {
            try testing.expectEqual(@as(f64, 12), objc.send(f64, item, "doubleValue", .{}));
        }
    }
}

/// The Objective-C result shape for selector metadata indexes 28 through 40.
pub fn Result(comptime index: usize) type {
    return switch (index) {
        28, 31, 37 => isize,
        29, 34, 35 => ?objc.Object,
        30, 32, 33, 38, 39 => objc.NSRange,
        36 => objc.NSRect,
        40 => void,
        else => @compileError("not a native text selector"),
    };
}

/// Borrows the node through its live tree lease. Object results are +1 references
/// the caller must release or autorelease-return. Selector 40 dispatch consumes
/// the lease and request on every dispatch path; deferred lease cleanup is safe.
/// RangeOverflow names overflowing NSRange endpoints or NSInteger results.
pub fn query(
    comptime index: usize,
    lease: *context.ContextLease,
    node: NodeRef,
    argument: anytype,
) NativeError!Result(index) {
    return queryImpl(index, lease, node, argument);
}

const empty_range: objc.NSRange = .{ .location = 0, .length = 0 };
const empty_rect: objc.NSRect = .{
    .origin = .{ .x = 0, .y = 0 },
    .size = .{ .width = 0, .height = 0 },
};

fn signedIndex(value: usize) NativeError!isize {
    return std.math.cast(isize, value) orelse error.RangeOverflow;
}

fn fromRange(gpa: std.mem.Allocator, node: NodeRef, value: objc.NSRange) NativeError!?text_range.Range {
    // Validate the endpoint before a position/range can allocate ordering keys.
    const end_index = std.math.add(usize, value.location, value.length) catch
        return error.RangeOverflow;
    const start = try text_query.textPositionFromGlobalUtf16Index(node, value.location) orelse return null;
    if (value.length == 0) {
        const range = try text_range.toDegenerateRange(gpa, start);
        return range;
    }
    const end = try text_query.textPositionFromGlobalUtf16Index(node, end_index) orelse return null;
    const range = try text_range.init(gpa, node, start.inner, end.inner);
    return range;
}

fn queryImpl(comptime index: usize, lease: anytype, node: NodeRef, argument: anytype) NativeError!Result(index) {
    const gpa = lease.allocator();
    if (!try text_query.supportsTextRanges(node)) {
        return switch (index) {
            28, 31, 37 => 0,
            29, 34, 35 => null,
            30, 32, 33, 38, 39 => empty_range,
            36 => empty_rect,
            40 => {},
            else => @compileError("not a native text selector"),
        };
    }
    switch (index) {
        28 => {
            const end = try text_query.documentEnd(node);
            return signedIndex(try position.toGlobalUtf16Index(end));
        },
        29 => {
            const range = try text_query.textSelection(gpa, node) orelse return null;
            return try stringForRange(gpa, range);
        },
        30 => {
            const range = try text_query.textSelection(gpa, node) orelse return empty_range;
            return try util.toNsRange(range);
        },
        31 => {
            const focus = text_query.textSelectionFocus(node) orelse return 0;
            return signedIndex(try position.toLineIndex(focus));
        },
        32 => {
            if (argument < 0) return empty_range;
            const range = try text_query.lineRangeFromIndex(gpa, node, @intCast(argument)) orelse return empty_range;
            return try util.toNsRange(range);
        },
        33 => {
            const view = lease.view() orelse return empty_range;
            const id = node.id();
            lease.releaseGuard();
            const container_point = try foundation.fromScreenPoint(view, argument);
            try lease.reacquireGuard();
            const fresh = lease.resolve(id) orelse return error.NoSuchNode;
            if (!try text_query.supportsTextRanges(fresh)) return empty_range;
            const transform = try consumer.node_ref.geometry.transform(fresh);
            const local_point = affine.mulPoint(affine.inverse(transform), container_point);
            const at = try text_query.textPositionAtPoint(gpa, fresh, local_point);
            return try util.toNsRangeForCharacter(gpa, at);
        },
        34 => {
            const range = try fromRange(gpa, node, argument) orelse return null;
            return try stringForRange(gpa, range);
        },
        35 => {
            const range = try fromRange(gpa, node, argument) orelse return null;
            return try attributedForRange(gpa, range);
        },
        36 => {
            const view = lease.view() orelse return empty_rect;
            const range = try fromRange(gpa, node, argument) orelse return empty_rect;
            const rect = try boundsForRange(gpa, range) orelse return empty_rect;
            lease.releaseGuard();
            return try foundation.toScreenRect(view, rect);
        },
        37 => {
            if (argument < 0) return 0;
            const at = try text_query.textPositionFromGlobalUtf16Index(node, @intCast(argument)) orelse return 0;
            return signedIndex(try position.toLineIndex(at));
        },
        38 => {
            if (argument < 0) return empty_range;
            const at = try text_query.textPositionFromGlobalUtf16Index(node, @intCast(argument)) orelse
                return empty_range;
            return try util.toNsRangeForCharacter(gpa, at);
        },
        39 => {
            if (argument < 0) return empty_range;
            const at = try text_query.textPositionFromGlobalUtf16Index(node, @intCast(argument)) orelse
                return empty_range;
            const start = if (try position.isFormatStart(at)) at else try motion.backwardToFormatStart(at);
            var range = try text_range.toDegenerateRange(gpa, start);
            try text_range.setEnd(gpa, &range, try motion.forwardToFormatEnd(at));
            return try util.toNsRange(range);
        },
        40 => {
            const range = try fromRange(gpa, node, argument) orelse return;
            const state = lease.state() orelse return;
            const located = state.locateNode(node.id()) orelse return;
            try lease.dispatch(.{
                .action = .set_text_selection,
                .target_tree = located.tree_id,
                .target_node = located.local_id,
                .data = .{ .set_text_selection = text_range.toTextSelection(range) },
            });
        },
        else => @compileError("not a native text selector"),
    }
}

fn stringForRange(gpa: std.mem.Allocator, range: text_range.Range) NativeError!objc.Object {
    var bytes = try text_range.text(gpa, range);
    defer bytes.deinit(gpa);
    return foundation.string(bytes.items);
}

fn boundsForRange(gpa: std.mem.Allocator, range: text_range.Range) NativeError!?schema.Rect {
    var boxes = try text_range.boundingBoxes(gpa, range);
    defer boxes.deinit(gpa);
    if (boxes.items.len == 0) return null;
    var rect = boxes.items[0];
    for (boxes.items[1..]) |box| rect = rect.unionRect(box);
    return rect;
}

// Exactly nine outer attributes and four font attributes are possible upstream.
// Extra owners are dictionary keys and NSColors backing borrowed CGColors.
const Style = struct {
    attributes: [9]foundation.Attribute = undefined,
    attribute_count: usize = 0,
    owners: [20]objc.Object = undefined,
    owner_count: usize = 0,

    fn deinit(self: *Style) void {
        for (self.owners[0..self.owner_count]) |object| objc.release(object);
        self.* = .{};
    }

    fn own(self: *Style, object: objc.Object) objc.Object {
        std.debug.assert(self.owner_count < self.owners.len);
        self.owners[self.owner_count] = object;
        self.owner_count += 1;
        return object;
    }

    fn put(self: *Style, key: objc.Object, value: objc.Object) NativeError!void {
        std.debug.assert(self.attribute_count < self.attributes.len);
        self.attributes[self.attribute_count] = .{
            .key = try foundation.utf8(key),
            .value = value,
        };
        self.attribute_count += 1;
    }

    fn color(self: *Style, value: schema.Color) NativeError!objc.Object {
        const owner = self.own(try foundation.color(
            @as(f64, @floatFromInt(value.red)) / 255.0,
            @as(f64, @floatFromInt(value.green)) / 255.0,
            @as(f64, @floatFromInt(value.blue)) / 255.0,
            @as(f64, @floatFromInt(value.alpha)) / 255.0,
        ));
        // NSDictionary retains CGColor before this NSColor owner is released.
        return foundation.cgColor(owner);
    }

    fn init(node: NodeRef) NativeError!Style {
        if (builtin.os.tag != .macos) return error.NativeUnsupported;
        var result: Style = .{};
        errdefer result.deinit();
        if (try inherited.nodeBackgroundColor(node)) |value| {
            try result.put(try foundation.accessibilityTextConstant(.background_color), try result.color(value));
        }
        if (try inherited.nodeForegroundColor(node)) |value| {
            try result.put(try foundation.accessibilityTextConstant(.foreground_color), try result.color(value));
        }
        var keys: [4]objc.Object = undefined;
        var values: [4]objc.Object = undefined;
        var count: usize = 0;
        if (try inherited.nodeFontFamily(node)) |value| {
            keys[count] = try foundation.accessibilityTextConstant(.font_family);
            values[count] = result.own(try foundation.string(value));
            count += 1;
        }
        if (try inherited.nodeFontSize(node)) |value| {
            keys[count] = try foundation.accessibilityTextConstant(.font_size);
            values[count] = result.own(try foundation.number(@floatCast(value)));
            count += 1;
        }
        if (try inherited.nodeFontWeight(node)) |value| {
            if (value >= 700.0) {
                keys[count] = result.own(try foundation.string("AXFontBold"));
                values[count] = result.own(try foundation.boolean(true));
                count += 1;
            }
        }
        if (try inherited.nodeIsItalic(node)) {
            keys[count] = result.own(try foundation.string("AXFontItalic"));
            values[count] = result.own(try foundation.boolean(true));
            count += 1;
        }
        if (count != 0) {
            const font = result.own(try foundation.dictionary(keys[0..count], values[0..count]));
            try result.put(try foundation.accessibilityTextConstant(.font), font);
        }
        if (try inherited.nodeUnderline(node)) |value| {
            const enabled = result.own(try foundation.boolean(true));
            try result.put(try foundation.accessibilityTextConstant(.underline), enabled);
            try result.put(try foundation.accessibilityTextConstant(.underline_color), try result.color(value.color));
        }
        if (try inherited.nodeStrikethrough(node)) |value| {
            const enabled = result.own(try foundation.boolean(true));
            try result.put(try foundation.accessibilityTextConstant(.strikethrough), enabled);
            try result.put(
                try foundation.accessibilityTextConstant(.strikethrough_color),
                try result.color(value.color),
            );
        }
        if (try inherited.nodeLanguage(node)) |value| {
            try result.put(
                try foundation.accessibilityTextConstant(.language),
                result.own(try foundation.string(value)),
            );
        }
        if (try inherited.nodeTextAlign(node)) |value| {
            const alignment: f64 = switch (value) {
                .left => 0,
                .right => 1,
                .center => 2,
                .justify => 3,
            };
            try result.put(
                try foundation.accessibilityTextConstant(.text_alignment),
                result.own(try foundation.number(alignment)),
            );
        }
        return result;
    }
};

const StyledPart = struct {
    range: objc.NSRange,
    style: Style,
};

const AttributedBuilder = struct {
    gpa: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,
    parts: std.ArrayList(StyledPart) = .empty,
    utf16_length: usize = 0,
    failure: ?NativeError = null,

    fn deinit(self: *AttributedBuilder) void {
        for (self.parts.items) |*part| part.style.deinit();
        self.parts.deinit(self.gpa);
        self.bytes.deinit(self.gpa);
        self.* = .{ .gpa = self.gpa };
    }

    fn append(self: *AttributedBuilder, node: NodeRef, bytes: []const u8) NativeError!void {
        var style = try Style.init(node);
        errdefer style.deinit();
        const utf16_count = try utf16Length(bytes);
        const end = std.math.add(usize, self.utf16_length, utf16_count) catch
            return error.RangeOverflow;
        try self.bytes.appendSlice(self.gpa, bytes);
        try self.parts.append(self.gpa, .{
            .range = .{ .location = self.utf16_length, .length = utf16_count },
            .style = style,
        });
        self.utf16_length = end;
    }

    fn visit(raw: ?*anyopaque, node: NodeRef, bytes: []const u8) bool {
        const self: *AttributedBuilder = @ptrCast(@alignCast(raw.?));
        self.append(node, bytes) catch |err| {
            self.failure = err;
            return false;
        };
        return true;
    }
};

fn utf16Length(bytes: []const u8) NativeError!usize {
    const view = std.unicode.Utf8View.init(bytes) catch return error.InvalidUtf8;
    var iterator = view.iterator();
    var length: usize = 0;
    while (iterator.nextCodepoint()) |codepoint| {
        length = std.math.add(usize, length, if (codepoint > 0xffff) 2 else 1) catch
            return error.RangeOverflow;
    }
    return length;
}

fn attributedForRange(gpa: std.mem.Allocator, range: text_range.Range) NativeError!objc.Object {
    var builder: AttributedBuilder = .{ .gpa = gpa };
    defer builder.deinit();
    const complete = try text_range.traverseText(gpa, range, @ptrCast(&builder), AttributedBuilder.visit);
    if (builder.failure) |failure| return failure;
    std.debug.assert(complete);
    const runs = try gpa.alloc(foundation.AttributeRun, builder.parts.items.len);
    defer gpa.free(runs);
    for (builder.parts.items, runs) |*part, *run| {
        run.* = .{
            .range = part.range,
            .attributes = part.style.attributes[0..part.style.attribute_count],
        };
    }
    return foundation.attributedString(builder.bytes.items, runs);
}

test "native text unsupported nodes return exact nil zero and no selection action" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    state.nodes.getPtr(fixtureId(1)).?.data.role = .button;
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    inline for (.{ 28, 31 }) |index| {
        try testing.expectEqual(@as(isize, 0), try queryImpl(index, &lease, root, {}));
    }
    try testing.expectEqual(@as(isize, 0), try queryImpl(37, &lease, root, @as(isize, 0)));
    try testing.expect((try queryImpl(29, &lease, root, {})) == null);
    inline for (.{ 34, 35 }) |index| {
        try testing.expect((try queryImpl(index, &lease, root, empty_range)) == null);
    }
    try expectRange(empty_range, try queryImpl(30, &lease, root, {}));
    inline for (.{ 32, 38, 39 }) |index| {
        try expectRange(empty_range, try queryImpl(index, &lease, root, @as(isize, 0)));
    }
    try expectRange(empty_range, try queryImpl(33, &lease, root, objc.NSPoint{ .x = 0, .y = 0 }));
    try testing.expectEqualDeep(empty_rect, try queryImpl(36, &lease, root, empty_range));
    try queryImpl(40, &lease, root, empty_range);
    try testing.expect(!lease.consumed);
}

test "native text NSNotFound unsigned location refuses range and UTF16 malformed bytes error" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    try testing.expect((try fromRange(testing.allocator, root, .{
        .location = std.math.maxInt(usize),
        .length = 0,
    })) == null);
    try testing.expectError(error.RangeOverflow, signedIndex(std.math.maxInt(usize)));
    try testing.expectEqual(@as(usize, 5), try utf16Length("a\u{1f642}é\x00"));
    try testing.expectError(error.InvalidUtf8, utf16Length("\xff"));
}

fn attributedAllocationScenario(gpa: std.mem.Allocator) !void {
    var state = try fixture(gpa);
    defer state.deinit(gpa);
    const props = &state.nodes.getPtr(fixtureId(2)).?.data.properties;
    try schema.strings.setFontFamily(props, "Serif");
    try schema.numbers.setFontWeight(props, 700);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = gpa, .tree_state = &state };
    const selected = (try queryImpl(29, &lease, root, {})).?;
    defer objc.release(selected);
    try testing.expectEqualStrings("\u{1f642}\né", try foundation.utf8(selected));
    const attributed = (try queryImpl(35, &lease, root, objc.NSRange{ .location = 1, .length = 6 })).?;
    defer objc.release(attributed);
    const value = objc.send(?objc.Object, attributed, "string", .{}).?;
    try testing.expectEqualStrings("\u{1f642}\né\x00b", try foundation.utf8(value));
}

test "native text NSString and styled part allocation failures release all owned buffers" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    try testing.checkAllAllocationFailures(testing.allocator, attributedAllocationScenario, .{});
}

test "native text bounds propagates transform cycles and owns no leaked geometry list" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    const range = (try fromRange(testing.allocator, root, .{ .location = 1, .length = 4 })).?;
    state.nodes.getPtr(fixtureId(1)).?.parent_and_index = .{
        .parent_id = fixtureId(1),
        .index = 0,
    };
    try testing.expectError(error.TreeCycle, boundsForRange(testing.allocator, range));
}

test "native text frame and position use real view screen conversion and inverse node transform" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var pool = try objc.AutoreleasePool.init();
    defer pool.deinit();
    const application_class = objc.getClass("NSApplication") orelse return error.ObjectiveCUnavailable;
    const application = objc.send(?objc.Object, @ptrCast(application_class), "sharedApplication", .{}) orelse
        return error.NativeObjectCreationFailed;
    _ = application;
    const window_class = objc.getClass("NSWindow") orelse return error.ObjectiveCUnavailable;
    const allocated = objc.send(?objc.Object, @ptrCast(window_class), "alloc", .{}) orelse
        return error.NativeObjectCreationFailed;
    const window = objc.send(?objc.Object, allocated, "initWithContentRect:styleMask:backing:defer:", .{
        objc.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 400, .height = 400 } },
        @as(usize, 0),
        @as(usize, 2),
        @as(u8, 0),
    }) orelse return error.NativeObjectCreationFailed;
    defer objc.release(window);
    const view = objc.send(?objc.Object, window, "contentView", .{}) orelse return error.InvalidView;
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    try schema.option.setTransform(
        &state.nodes.getPtr(fixtureId(1)).?.data.properties,
        schema.affineTranslate(.{ .x = 100, .y = 200 }),
    );
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{
        .gpa = testing.allocator,
        .tree_state = &state,
        .native_view = view,
    };
    const expected = try foundation.toScreenRect(view, schema.rectInit(100, 200, 130, 230));
    const actual = try queryImpl(36, &lease, root, objc.NSRange{ .location = 0, .length = 7 });
    try testing.expectEqualDeep(expected, actual);
    try testing.expect(!lease.guard_held);
    const screen = try foundation.toScreenRect(view, schema.rectInit(114, 204, 116, 206));
    const point: objc.NSPoint = .{
        .x = screen.origin.x + screen.size.width / 2.0,
        .y = screen.origin.y + screen.size.height / 2.0,
    };
    try expectRange(.{ .location = 1, .length = 2 }, try queryImpl(33, &lease, root, point));
    try testing.expectEqual(@as(usize, 1), lease.guard_reacquisitions);
    try testing.expect(lease.guard_held);
    try testing.expectEqualDeep(
        empty_rect,
        try queryImpl(36, &lease, root, objc.NSRange{ .location = 8, .length = 0 }),
    );
    lease.reacquire_failure = error.Closed;
    try testing.expectError(error.Closed, queryImpl(33, &lease, root, point));
    try testing.expectEqual(@as(usize, 2), lease.guard_reacquisitions);
    try testing.expect(!lease.guard_held);
}

test "native text absent selection gives nil zero range and caret line" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    schema.option.clearTextSelection(&state.nodes.getPtr(fixtureId(1)).?.data.properties);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    try testing.expect((try queryImpl(29, &lease, root, {})) == null);
    try expectRange(empty_range, try queryImpl(30, &lease, root, {}));
    try testing.expectEqual(@as(isize, 0), try queryImpl(31, &lease, root, {}));
}

test "native text selection dispatch failure consumes lease and propagates named error" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{
        .gpa = testing.allocator,
        .tree_state = &state,
        .dispatch_failure = error.Closed,
    };
    try testing.expectError(error.Closed, queryImpl(40, &lease, root, objc.NSRange{ .location = 1, .length = 4 }));
    try testing.expect(lease.consumed);
    try testing.expectEqual(schema.Action.set_text_selection, lease.selected.?.action);
}

test "native text object result retains Unicode after query autorelease pool drains" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    var lease: TestLease = .{ .gpa = testing.allocator, .tree_state = &state };
    const value = block: {
        var pool = try objc.AutoreleasePool.init();
        defer pool.deinit();
        break :block (try queryImpl(34, &lease, root, objc.NSRange{ .location = 4, .length = 3 })).?;
    };
    defer objc.release(value);
    try testing.expectEqualStrings("é\x00b", try foundation.utf8(value));
}

test "native text character count never allocates ordering keys" {
    var state = try fixture(testing.allocator);
    defer state.deinit(testing.allocator);
    const root = try fixtureRoot(&state);
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var lease: TestLease = .{ .gpa = failing.allocator(), .tree_state = &state };
    try testing.expectEqual(@as(isize, 7), try queryImpl(28, &lease, root, {}));
}
