//! Neutral consumer-visible cases authored from source observations, not copied host code.
//! Source attribution: nogui src/v7_host/w21_accessibility_test.zig:525-1767,
//! accessibility.zig:1952-2555, accesskit_bridge/src/lib.rs:1081-1501.
//! These tests exercise the actual consumer and decoded AT-SPI dispatcher. They do not
//! prove a live D-Bus, COM/UIA, or AppKit attachment. Host ring, model-capacity, bell,
//! mobile serialization, and private snapshot-diff cases stay with their source owner.
const std = @import("std");
const package = @import("zaccesskit");
const schema = package.schema;
const consumer = package.consumer;
const Tree = consumer.tree.Tree;
const NodeRef = consumer.node_id.NodeRef;
const FullNodeId = consumer.tree_index.FullNodeId;
const testing = std.testing;
const gpa = testing.allocator;

fn id(value: u64) schema.NodeId {
    return .{ .value = value };
}

fn fullId(value: u64) FullNodeId {
    return .init(id(value), .init(0));
}

fn resolve(tree: *const Tree, value: u64) !NodeRef {
    return NodeRef.init(tree.stateOf(), fullId(value)) orelse error.TestUnexpectedResult;
}

fn rootNode(children: []const schema.NodeId) !schema.Node {
    var node = schema.Node.init(gpa, .window);
    errdefer node.deinit();
    try schema.ids_props.setChildren(&node.properties, children);
    return node;
}

fn textNode(value: []const u8, lengths: []const u8) !schema.Node {
    var node = schema.Node.init(gpa, .text_run);
    errdefer node.deinit();
    try schema.strings.setValue(&node.properties, value);
    try schema.vectors.setCharacterLengths(&node.properties, lengths);
    return node;
}

fn fieldNode(run: u64, caret: ?usize) !schema.Node {
    var node = schema.Node.init(gpa, .text_input);
    errdefer node.deinit();
    try schema.ids_props.setChildren(&node.properties, &.{id(run)});
    node.addAction(.set_text_selection);
    node.addAction(.replace_selected_text);
    node.addAction(.set_value);
    if (caret) |offset| {
        const position: schema.TextPosition = .{
            .node_id = id(run), .character_index = offset,
        };
        try schema.option.setTextSelection(&node.properties, .{
            .anchor = position, .focus = position,
        });
    }
    return node;
}

fn textUpdate(value: []const u8, lengths: []const u8, caret: ?usize) !schema.TreeUpdate {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    try update.pushNode(gpa, id(1), try rootNode(&.{id(7)}));
    try update.pushNode(gpa, id(7), try fieldNode(9, caret));
    try update.pushNode(gpa, id(9), try textNode(value, lengths));
    update.tree = schema.TreeInfo.init(id(1));
    update.focus = id(7);
    return update;
}

fn apply(tree: *Tree, update: *const schema.TreeUpdate) !void {
    var context: u8 = 0;
    const handler: consumer.tree.TreeChangeHandler = .{ .ptr = &context };
    try tree.updateBorrowedAndProcessChanges(update, &handler);
}

fn expectDocument(tree: *const Tree, field: u64, expected: []const u8) !void {
    const range = try consumer.text.query.documentRange(gpa, try resolve(tree, field));
    var bytes = try consumer.text.range.text(gpa, range);
    defer bytes.deinit(gpa);
    try testing.expectEqualStrings(expected, bytes.items);
}

test "native-contract borrowed label remains owned after the source is released" {
    var tree = tree: {
        var update: schema.TreeUpdate = .{};
        defer update.deinit(gpa);
        var node = try rootNode(&.{});
        var node_transferred = false;
        errdefer if (!node_transferred) node.deinit();
        try schema.strings.setLabel(&node.properties, "Save ✓");
        node_transferred = true;
        try update.pushNode(gpa, id(1), node);
        update.tree = schema.TreeInfo.init(id(1));
        update.focus = id(1);
        var committed = try Tree.initBorrowed(gpa, &update, true);
        errdefer committed.deinit();
        try schema.strings.setLabel(&update.nodes.items[0].node.properties, "Overwritten");
        break :tree committed;
    };
    defer tree.deinit();
    const node = try resolve(&tree, 1);
    try testing.expectEqualStrings("Save ✓", schema.strings.label(&node.data().properties).?);
}

test "native-contract values distinguish absent empty numeric zero and selected false" {
    var update: schema.TreeUpdate = .{};
    defer update.deinit(gpa);
    try update.pushNode(gpa, id(1), try rootNode(&.{ id(2), id(3), id(4) }));
    try update.pushNode(gpa, id(2), schema.Node.init(gpa, .button));
    var empty = schema.Node.init(gpa, .text_input);
    var empty_transferred = false;
    errdefer if (!empty_transferred) empty.deinit();
    try schema.strings.setValue(&empty.properties, "");
    empty_transferred = true;
    try update.pushNode(gpa, id(3), empty);
    var zero = schema.Node.init(gpa, .list_item);
    var zero_transferred = false;
    errdefer if (!zero_transferred) zero.deinit();
    try schema.numbers.setNumericValue(&zero.properties, 0);
    try schema.enums.setSelected(&zero.properties, false);
    try schema.numbers.setPositionInSet(&zero.properties, 1);
    try schema.numbers.setSizeOfSet(&zero.properties, 2);
    zero_transferred = true;
    try update.pushNode(gpa, id(4), zero);
    update.tree = schema.TreeInfo.init(id(1));
    update.focus = id(3);
    var tree = try Tree.initBorrowed(gpa, &update, true);
    defer tree.deinit();
    const absent = try resolve(&tree, 2);
    const cleared = try resolve(&tree, 3);
    const row = try resolve(&tree, 4);
    try testing.expect(schema.strings.value(&absent.data().properties) == null);
    try testing.expectEqualStrings("", schema.strings.value(&cleared.data().properties).?);
    try testing.expect(consumer.node_ref.properties.numericValue(absent) == null);
    try testing.expectEqual(@as(?f64, 0), consumer.node_ref.properties.numericValue(row));
    try testing.expect(consumer.node_ref.properties.isSelected(absent) == null);
    try testing.expectEqual(@as(?bool, false), consumer.node_ref.properties.isSelected(row));
    try testing.expectEqual(@as(?usize, 1), consumer.node_ref.predicates.positionInSet(row));
    try testing.expectEqual(@as(?usize, 2), consumer.node_ref.predicates.sizeOfSet(row));
}

test "native-contract sparse action masks and signed custom identities survive the loan" {
    var update: schema.TreeUpdate = .{};
    defer update.deinit(gpa);
    var node = try rootNode(&.{});
    var node_transferred = false;
    errdefer if (!node_transferred) node.deinit();
    inline for (.{ .click, .custom_action, .replace_selected_text, .set_text_selection,
        .set_value }) |action| node.addAction(action);
    var first = try schema.CustomAction.init(gpa, -17, "Move before");
    defer first.deinit(gpa);
    var second = try schema.CustomAction.init(gpa, 2147483647, "Move after");
    defer second.deinit(gpa);
    try schema.vectors.setCustomActions(&node.properties, &.{ first, second });
    node_transferred = true;
    try update.pushNode(gpa, id(71), node);
    update.tree = schema.TreeInfo.init(id(71));
    update.focus = id(71);
    var tree = try Tree.initBorrowed(gpa, &update, true);
    defer tree.deinit();
    const published = (try resolve(&tree, 71)).data();
    try testing.expectEqual(@as(u32, (1 << 0) | (1 << 5) | (1 << 10) |
        (1 << 18) | (1 << 20)), published.actions);
    try testing.expect(!published.supportsAction(.increment));
    const actions = schema.vectors.customActions(&published.properties);
    try testing.expectEqual(@as(usize, 2), actions.len);
    try testing.expectEqual(@as(i32, -17), actions[0].id);
    try testing.expectEqualStrings("Move before", actions[0].description.items);
    try testing.expectEqual(@as(i32, 2147483647), actions[1].id);
    try testing.expectEqualStrings("Move after", actions[1].description.items);
    try testing.expect(schema.actionFromInt(99) == null);
}

test "native-contract relations preserve authored order while child reorder keeps identities" {
    var initial: schema.TreeUpdate = .{};
    defer initial.deinit(gpa);
    try initial.pushNode(gpa, id(1), try rootNode(&.{ id(2), id(3) }));
    var button = schema.Node.init(gpa, .button);
    var button_transferred = false;
    errdefer if (!button_transferred) button.deinit();
    try schema.strings.setLabel(&button.properties, "Target");
    try schema.ids_props.setControls(&button.properties, &.{ id(3), id(1) });
    try schema.ids_props.setDescribedBy(&button.properties, &.{ id(3), id(1) });
    try schema.ids_props.setDetails(&button.properties, &.{ id(1), id(3) });
    button_transferred = true;
    try initial.pushNode(gpa, id(2), button);
    try initial.pushNode(gpa, id(3), schema.Node.init(gpa, .label));
    initial.tree = schema.TreeInfo.init(id(1));
    initial.focus = id(2);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    var delta: schema.TreeUpdate = .{ .focus = id(2) };
    defer delta.deinit(gpa);
    try delta.pushNode(gpa, id(1), try rootNode(&.{ id(3), id(2) }));
    try apply(&tree, &delta);
    const target = try resolve(&tree, 2);
    try testing.expectEqual(fullId(2), target.id());
    try testing.expectEqualStrings("Target", schema.strings.label(&target.data().properties).?);
    try testing.expectEqualSlices(schema.NodeId, &.{ id(3), id(1) },
        schema.ids_props.controls(&target.data().properties));
    try testing.expectEqualSlices(schema.NodeId, &.{ id(3), id(1) },
        schema.ids_props.describedBy(&target.data().properties));
    try testing.expectEqualSlices(schema.NodeId, &.{ id(1), id(3) },
        schema.ids_props.details(&target.data().properties));
    const placement = consumer.node_ref.hierarchy.parentAndIndex(target).?;
    try testing.expectEqual(fullId(1), placement.parent.id());
    try testing.expectEqual(@as(usize, 1), placement.index);
}

test "native-contract focus is carried by TreeUpdate and a dropped target becomes unavailable" {
    var initial = try textUpdate("abc", &.{ 1, 1, 1 }, 1);
    defer initial.deinit(gpa);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    try testing.expectEqual(fullId(7), tree.stateOf().focusIdInTree());
    var focus: schema.TreeUpdate = .{ .focus = id(9) };
    defer focus.deinit(gpa);
    try apply(&tree, &focus);
    try testing.expectEqual(fullId(9), tree.stateOf().focusIdInTree());
    var removed: schema.TreeUpdate = .{ .focus = id(1) };
    defer removed.deinit(gpa);
    try removed.pushNode(gpa, id(1), try rootNode(&.{}));
    try apply(&tree, &removed);
    try testing.expect(NodeRef.init(tree.stateOf(), fullId(7)) == null);
    try testing.expect(NodeRef.init(tree.stateOf(), fullId(9)) == null);
    try testing.expectEqual(fullId(1), tree.stateOf().focusIdInTree());
}

test "native-contract live Unicode table and child run selection are updated together" {
    var initial = try textUpdate("Aé😀éZ", &.{ 1, 2, 4, 3, 1 }, 3);
    defer initial.deinit(gpa);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    try expectDocument(&tree, 7, "Aé😀éZ");
    const field = try resolve(&tree, 7);
    const position = (try consumer.text.query.textPositionFromGlobalUsvIndex(field, 5)).?;
    try testing.expectEqual(id(9), position.inner.node.id().local);
    try testing.expectEqual(@as(usize, 4), position.inner.character_index);
    try testing.expectEqual(@as(usize, 5),
        try consumer.text.position.toGlobalUsvIndex(position));
    try testing.expectEqual(@as(usize, 6),
        try consumer.text.position.toGlobalUtf16Index(position));
    const selection = (try consumer.text.query.textSelection(gpa, field)).?;
    try testing.expectEqual(fullId(9), selection.start.node.id());
    try testing.expectEqual(@as(usize, 3), selection.start.character_index);
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    try delta.pushNode(gpa, id(7), try fieldNode(9, 2));
    try delta.pushNode(gpa, id(9), try textNode("✓é", &.{ 3, 2 }));
    try apply(&tree, &delta);
    try expectDocument(&tree, 7, "✓é");
    const live = try resolve(&tree, 7);
    const end = try consumer.text.query.documentEnd(live);
    try testing.expectEqual(@as(usize, 2), end.inner.character_index);
    try testing.expectEqual(@as(usize, 2), try consumer.text.position.toGlobalUsvIndex(end));
    try testing.expect((try consumer.text.query.textPositionFromGlobalUsvIndex(live, 3)) == null);
    const caret = (try consumer.text.query.textSelection(gpa, live)).?;
    try testing.expectEqual(@as(usize, 2), caret.start.character_index);
    try testing.expect(try consumer.text.range.isDegenerate(gpa, caret));
}

test "native-contract changing the text run owner invalidates the old run and moves caret" {
    var initial = try textUpdate("old", &.{ 1, 1, 1 }, null);
    defer initial.deinit(gpa);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    try testing.expect(!consumer.text.query.hasTextSelection(try resolve(&tree, 7)));
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    try delta.pushNode(gpa, id(7), try fieldNode(19, 0));
    try delta.pushNode(gpa, id(19), try textNode("", &.{}));
    try apply(&tree, &delta);
    try testing.expect(NodeRef.init(tree.stateOf(), fullId(9)) == null);
    try expectDocument(&tree, 7, "");
    const field = try resolve(&tree, 7);
    try testing.expect(consumer.text.query.hasTextSelection(field));
    const caret = (try consumer.text.query.textSelection(gpa, field)).?;
    try testing.expectEqual(fullId(19), caret.start.node.id());
    try testing.expectEqual(@as(usize, 0), caret.start.character_index);
    try testing.expect(try consumer.text.range.isDegenerate(gpa, caret));
}

const Changes = struct {
    updated: [8]schema.NodeId = undefined,
    updated_count: usize = 0,
    overflow: bool = false,

    fn handler(self: *Changes) consumer.tree.TreeChangeHandler {
        return .{ .ptr = self, .node_updated = changed };
    }

    fn changed(pointer: *anyopaque, old: NodeRef, new: NodeRef) void {
        const self: *Changes = @ptrCast(@alignCast(pointer));
        if (self.updated_count == self.updated.len) {
            self.overflow = true;
            return;
        }
        std.debug.assert(std.meta.eql(old.id(), new.id()));
        self.updated[self.updated_count] = new.id().local;
        self.updated_count += 1;
    }
};

test "native-contract equal resubmission is quiet and changed text excludes an unchanged sibling" {
    var initial = try textUpdate("old", &.{ 1, 1, 1 }, 1);
    defer initial.deinit(gpa);
    try schema.ids_props.setChildren(&initial.nodes.items[0].node.properties,
        &.{ id(7), id(31) });
    var sibling = schema.Node.init(gpa, .button);
    var sibling_transferred = false;
    errdefer if (!sibling_transferred) sibling.deinit();
    try schema.strings.setLabel(&sibling.properties, "Unchanged sibling");
    sibling_transferred = true;
    try initial.pushNode(gpa, id(31), sibling);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    var changes: Changes = .{};
    const handler = changes.handler();
    try tree.updateBorrowedAndProcessChanges(&initial, &handler);
    try testing.expectEqual(@as(usize, 0), changes.updated_count);
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    try delta.pushNode(gpa, id(9), try textNode("new", &.{ 1, 1, 1 }));
    try tree.updateBorrowedAndProcessChanges(&delta, &handler);
    try testing.expect(!changes.overflow);
    try testing.expectEqualSlices(schema.NodeId, &.{id(9)},
        changes.updated[0..changes.updated_count]);
    try expectDocument(&tree, 7, "new");
    try testing.expectEqualStrings("Unchanged sibling",
        schema.strings.label(&(try resolve(&tree, 31)).data().properties).?);
}

test "native-contract modal hidden and disabled changes remain authored live properties" {
    var initial = try textUpdate("live", &.{ 1, 1, 1, 1 }, null);
    defer initial.deinit(gpa);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    try testing.expect(!consumer.node_ref.properties.isDisabled(try resolve(&tree, 7)));
    try testing.expect(!try consumer.node_ref.properties.isHidden(try resolve(&tree, 9)));
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    var field = try fieldNode(9, null);
    schema.flags.setDisabled(&field.flags, true);
    schema.flags.setHidden(&field.flags, true);
    schema.flags.setReadOnly(&field.flags, true);
    try delta.pushNode(gpa, id(7), field);
    var root = try rootNode(&.{id(7)});
    schema.flags.setModal(&root.flags, true);
    try delta.pushNode(gpa, id(1), root);
    try apply(&tree, &delta);
    const published_field = try resolve(&tree, 7);
    try testing.expect(consumer.node_ref.properties.isDisabled(published_field));
    try testing.expect(try consumer.node_ref.properties.isHidden(try resolve(&tree, 9)));
    try testing.expect(consumer.node_ref.predicates.isReadOnly(published_field));
    try testing.expect(schema.flags.isModal((try resolve(&tree, 1)).data().flags));
    var enabled: schema.TreeUpdate = .{ .focus = id(7) };
    defer enabled.deinit(gpa);
    try enabled.pushNode(gpa, id(7), try fieldNode(9, null));
    try apply(&tree, &enabled);
    try testing.expect(!consumer.node_ref.properties.isDisabled(try resolve(&tree, 7)));
    try testing.expect(!try consumer.node_ref.properties.isHidden(try resolve(&tree, 9)));
}

const atspi = package.adapters.atspi;

// Only callbacks are observed here. The real dispatcher resolves registered paths,
// decodes arguments, obtains live consumer nodes, and constructs owned actions.
const DispatchFixture = struct {
    tree: Tree,
    app: atspi.app_context.AppContext,
    node_context: atspi.app_context.NodeContext,
    register: atspi.objects.Register,
    last_action: ?schema.ActionRequest,
    action_count: usize,

    fn init(self: *DispatchFixture) !void {
        var initial = try textUpdate("Aé😀éZ", &.{ 1, 2, 4, 3, 1 }, 3);
        defer initial.deinit(gpa);
        self.tree = try Tree.initBorrowed(gpa, &initial, true);
        errdefer self.tree.deinit();
        self.app = try atspi.app_context.AppContext.init(gpa, "Neutral contract");
        errdefer self.app.deinit();
        self.last_action = null;
        self.action_count = 0;
        self.node_context = .{
            .state = self.tree.stateOf(),
            .app = &self.app,
            .bounds = .empty,
            .sink = .{ .context = self, .raise = receive },
            .gpa = gpa,
        };
        try self.app.pushAdapter(17, &self.node_context);
        self.register = atspi.objects.Register.init(gpa, &self.app);
        errdefer self.register.deinit();
        self.register.bus_name = ":1.42";
        self.register.sink = .{ .context = self, .raise = receiveChecked };
        try self.register.sync();
    }

    fn deinit(self: *DispatchFixture) void {
        if (self.last_action) |*request| request.deinit(gpa);
        self.register.deinit();
        self.app.deinit();
        self.tree.deinit();
    }

    fn receive(pointer: ?*anyopaque, request: schema.ActionRequest) void {
        const self: *DispatchFixture = @ptrCast(@alignCast(pointer.?));
        if (self.last_action) |*previous| previous.deinit(gpa);
        self.last_action = request;
        self.action_count += 1;
    }

    fn receiveChecked(
        pointer: ?*anyopaque,
        request: schema.ActionRequest,
    ) atspi.objects.ActionDeliveryError!void {
        receive(pointer, request);
    }

    fn call(
        self: *DispatchFixture,
        target: u64,
        interface_name: []const u8,
        member: []const u8,
        signature: []const u8,
        args: []const atspi.dbus.Value,
    ) !atspi.dbus.OwnedReply {
        var arena = std.heap.ArenaAllocator.init(gpa);
        defer arena.deinit();
        var context: atspi.interfaces.Context = .{
            .arena = arena.allocator(),
            .app = &self.app,
            .node = self.node_context.platformNode(17, fullId(1)),
            .bus_name = self.register.bus_name,
        };
        const reference = try context.nodeObject(fullId(target));
        return atspi.dispatch.handle(gpa, &self.register, .{
            .kind = .method_call,
            .serial = 1,
            .path = reference.structure[1].object_path,
            .interface = interface_name,
            .member = member,
            .signature = signature,
            .body = args,
        });
    }

    fn update(self: *DispatchFixture, delta: *const schema.TreeUpdate) !void {
        try apply(&self.tree, delta);
        self.node_context.state = self.tree.stateOf();
        try self.register.sync();
    }
};

fn expectSuccess(reply: atspi.dbus.OwnedReply, signature: []const u8) !void {
    try testing.expect(reply.error_name == null);
    try testing.expectEqualStrings(signature, reply.body.signature);
}

test "native-contract dispatch reads updated Unicode rather than the previous frame" {
    var fixture: DispatchFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var old_reply = try fixture.call(7, atspi.wire.interface_text, "GetText", "ii",
        &.{ .{ .int32 = 3 }, .{ .int32 = 5 } });
    defer old_reply.body.deinit();
    try expectSuccess(old_reply, "s");
    try testing.expectEqualStrings("é", old_reply.body.values[0].string);
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    try delta.pushNode(gpa, id(7), try fieldNode(9, 1));
    try delta.pushNode(gpa, id(9), try textNode("é✓", &.{ 2, 3 }));
    try fixture.update(&delta);
    var live_reply = try fixture.call(7, atspi.wire.interface_text, "GetText", "ii",
        &.{ .{ .int32 = 0 }, .{ .int32 = -1 } });
    defer live_reply.body.deinit();
    try expectSuccess(live_reply, "s");
    try testing.expectEqualStrings("é✓", live_reply.body.values[0].string);
    var count = try fixture.call(7, "org.freedesktop.DBus.Properties", "Get", "ss",
        &.{ .{ .string = atspi.wire.interface_text }, .{ .string = "CharacterCount" } });
    defer count.body.deinit();
    try expectSuccess(count, "v");
    try testing.expectEqual(@as(i32, 2), count.body.values[0].variant.value.int32);
    // Previously returned owned replies cannot alias the updated tree's text.
    try testing.expectEqualStrings("é", old_reply.body.values[0].string);
}

test "native-contract dispatch selection names the child run and rejects an unaddressable index" {
    var fixture: DispatchFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var selection = try fixture.call(7, atspi.wire.interface_text, "AddSelection", "ii",
        &.{ .{ .int32 = 1 }, .{ .int32 = 5 } });
    defer selection.body.deinit();
    try expectSuccess(selection, "b");
    try testing.expect(selection.body.values[0].boolean);
    const request = fixture.last_action.?;
    try testing.expectEqual(schema.Action.set_text_selection, request.action);
    try testing.expectEqual(schema.tree_id_root, request.target_tree);
    try testing.expectEqual(id(7), request.target_node);
    const endpoints = request.data.?.set_text_selection;
    try testing.expectEqual(id(9), endpoints.anchor.node_id);
    try testing.expectEqual(id(9), endpoints.focus.node_id);
    try testing.expectEqual(@as(usize, 1), endpoints.anchor.character_index);
    try testing.expectEqual(@as(usize, 4), endpoints.focus.character_index);
    var invalid = try fixture.call(7, atspi.wire.interface_text, "SetCaretOffset", "i",
        &.{.{ .int32 = 7 }});
    defer invalid.body.deinit();
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.InvalidArgs",
        invalid.error_name.?);
    try testing.expectEqual(@as(usize, 1), fixture.action_count);
}

test "native-contract dispatch owns source action text and read only withdrawal blocks editing" {
    var fixture: DispatchFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var source = [_]u8{ 0xc3, 0xa9, '!' };
    var accepted = try fixture.call(7, atspi.wire.interface_editable_text,
        "SetTextContents", "s", &.{.{ .string = &source }});
    defer accepted.body.deinit();
    try expectSuccess(accepted, "b");
    try testing.expect(accepted.body.values[0].boolean);
    source[2] = '?';
    const request = fixture.last_action.?;
    try testing.expectEqual(schema.Action.set_value, request.action);
    try testing.expectEqual(id(7), request.target_node);
    try testing.expectEqual(schema.tree_id_root, request.target_tree);
    try testing.expectEqualStrings("é!", request.data.?.value);
    // Dispatch requests an edit. It does not claim the application applied it.
    try expectDocument(&fixture.tree, 7, "Aé😀éZ");
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    var field = try fieldNode(9, null);
    schema.flags.setReadOnly(&field.flags, true);
    field.removeAction(.set_value);
    field.removeAction(.replace_selected_text);
    try delta.pushNode(gpa, id(7), field);
    try fixture.update(&delta);
    var refused = try fixture.call(7, atspi.wire.interface_editable_text,
        "SetTextContents", "s", &.{.{ .string = "Must not apply" }});
    defer refused.body.deinit();
    try expectSuccess(refused, "b");
    try testing.expect(!refused.body.values[0].boolean);
    try testing.expectEqual(@as(usize, 1), fixture.action_count);
    try expectDocument(&fixture.tree, 7, "Aé😀éZ");
}

test "native-contract a removed dispatch target cannot deliver an action to its old identity" {
    var fixture: DispatchFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var removed: schema.TreeUpdate = .{ .focus = id(1) };
    defer removed.deinit(gpa);
    try removed.pushNode(gpa, id(1), try rootNode(&.{}));
    try fixture.update(&removed);
    var refused = try fixture.call(7, atspi.wire.interface_editable_text,
        "SetTextContents", "s", &.{.{ .string = "Stale target" }});
    defer refused.body.deinit();
    try testing.expectEqualStrings("org.freedesktop.DBus.Error.UnknownObject",
        refused.error_name.?);
    try testing.expectEqual(@as(usize, 0), fixture.action_count);
    try testing.expect(fixture.last_action == null);
}

test "native-contract every emitted source role reaches an exact live AT SPI role" {
    const RoleCase = struct { source: schema.Role, expected: atspi.wire.Role };
    const cases = [_]RoleCase{
        .{ .source = .text_run, .expected = .static },
        .{ .source = .label, .expected = .label },
        .{ .source = .image, .expected = .image },
        .{ .source = .list_item, .expected = .list_item },
        .{ .source = .generic_container, .expected = .section },
        .{ .source = .check_box, .expected = .check_box },
        .{ .source = .radio_button, .expected = .radio_button },
        .{ .source = .text_input, .expected = .entry },
        .{ .source = .button, .expected = .button },
        .{ .source = .list, .expected = .list },
        .{ .source = .switch_, .expected = .toggle_button },
        .{ .source = .multiline_text_input, .expected = .entry },
        .{ .source = .search_input, .expected = .entry },
        .{ .source = .dialog, .expected = .dialog },
        .{ .source = .group, .expected = .panel },
        .{ .source = .list_box, .expected = .list_box },
        .{ .source = .progress_indicator, .expected = .progress_bar },
        .{ .source = .radio_group, .expected = .panel },
        .{ .source = .scroll_view, .expected = .panel },
        .{ .source = .slider, .expected = .slider },
        .{ .source = .spin_button, .expected = .spin_button },
        .{ .source = .tab, .expected = .page_tab },
        .{ .source = .tab_list, .expected = .page_tab_list },
        .{ .source = .tab_panel, .expected = .scroll_pane },
        .{ .source = .toolbar, .expected = .tool_bar },
        .{ .source = .tooltip, .expected = .tool_tip },
        .{ .source = .window, .expected = .frame },
    };
    var fixture: DispatchFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    for (cases) |case| {
        var delta: schema.TreeUpdate = .{ .focus = id(7) };
        defer delta.deinit(gpa);
        try delta.pushNode(gpa, id(7), schema.Node.init(gpa, case.source));
        try fixture.update(&delta);
        try testing.expectEqual(case.source,
            consumer.node_ref.properties.role(try resolve(&fixture.tree, 7)));
        var reply = try fixture.call(7, atspi.wire.interface_accessible, "GetRole", "", &.{});
        defer reply.body.deinit();
        try expectSuccess(reply, "u");
        try testing.expectEqual(@as(u32, @intFromEnum(case.expected)), reply.body.values[0].uint32);
    }
}

test "native-contract borrowed initialization failure leaves the source available for retry" {
    var initial = try textUpdate("retry é", &.{ 1, 1, 1, 1, 1, 1, 2 }, 7);
    defer initial.deinit(gpa);
    try testing.checkAllAllocationFailures(gpa, borrowAtEveryAllocation, .{&initial});
    try testing.expectEqual(@as(usize, 3), initial.nodes.items.len);
    try testing.expectEqualStrings("retry é",
        schema.strings.value(&initial.nodes.items[2].node.properties).?);
    var retry = try Tree.initBorrowed(gpa, &initial, true);
    defer retry.deinit();
    try expectDocument(&retry, 7, "retry é");
}

fn borrowAtEveryAllocation(
    failing_gpa: std.mem.Allocator,
    initial: *const schema.TreeUpdate,
) consumer.tree.UpdateError!void {
    // The loan remains caller-owned on success and on each allocation refusal.
    defer std.debug.assert(initial.nodes.items.len == 3);
    var tree = try Tree.initBorrowed(failing_gpa, initial, true);
    defer tree.deinit();
}

test "native-contract zero is a valid child run identity for an explicitly empty caret" {
    var initial: schema.TreeUpdate = .{ .focus = id(7) };
    defer initial.deinit(gpa);
    try initial.pushNode(gpa, id(1), try rootNode(&.{id(7)}));
    try initial.pushNode(gpa, id(7), try fieldNode(0, 0));
    try initial.pushNode(gpa, id(0), try textNode("", &.{}));
    initial.tree = schema.TreeInfo.init(id(1));
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    const field = try resolve(&tree, 7);
    try testing.expect(consumer.text.query.hasTextSelection(field));
    const selection = (try consumer.text.query.textSelection(gpa, field)).?;
    try testing.expectEqual(fullId(0), selection.start.node.id());
    try testing.expectEqual(fullId(0), selection.end.node.id());
    try testing.expectEqual(@as(usize, 0), selection.start.character_index);
    try testing.expectEqual(@as(usize, 0), selection.end.character_index);
    try expectDocument(&tree, 7, "");
}

test "native-contract dispatch actions keep the target identity across reorder and sibling repaint" {
    var fixture: DispatchFixture = undefined;
    try fixture.init();
    defer fixture.deinit();
    var reordered: schema.TreeUpdate = .{ .focus = id(7) };
    defer reordered.deinit(gpa);
    try reordered.pushNode(gpa, id(1), try rootNode(&.{ id(31), id(7) }));
    try reordered.pushNode(gpa, id(31), schema.Node.init(gpa, .button));
    try fixture.update(&reordered);
    var action = try fixture.call(7, atspi.wire.interface_editable_text,
        "SetTextContents", "s", &.{.{ .string = "After reorder" }});
    defer action.body.deinit();
    try expectSuccess(action, "b");
    try testing.expectEqual(id(7), fixture.last_action.?.target_node);
    try testing.expectEqualStrings("After reorder", fixture.last_action.?.data.?.value);
    var repaint: schema.TreeUpdate = .{ .focus = id(7) };
    defer repaint.deinit(gpa);
    var sibling = schema.Node.init(gpa, .button);
    var sibling_transferred = false;
    errdefer if (!sibling_transferred) sibling.deinit();
    try schema.strings.setLabel(&sibling.properties, "Repainted unrelated sibling");
    sibling_transferred = true;
    try repaint.pushNode(gpa, id(31), sibling);
    try fixture.update(&repaint);
    // An already-delivered owned request remains independent of that publication.
    try testing.expectEqual(id(7), fixture.last_action.?.target_node);
    try testing.expectEqualStrings("After reorder", fixture.last_action.?.data.?.value);
    var after_repaint = try fixture.call(7, atspi.wire.interface_editable_text,
        "SetTextContents", "s", &.{.{ .string = "After repaint" }});
    defer after_repaint.body.deinit();
    try expectSuccess(after_repaint, "b");
    try testing.expectEqual(id(7), fixture.last_action.?.target_node);
    try testing.expectEqualStrings("After repaint", fixture.last_action.?.data.?.value);
    try testing.expectEqual(@as(usize, 2), fixture.action_count);
    try expectDocument(&fixture.tree, 7, "Aé😀éZ");
}

test "native-contract an appearing caret changes the field without resending its unchanged run" {
    var initial = try textUpdate("same", &.{ 1, 1, 1, 1 }, null);
    defer initial.deinit(gpa);
    var tree = try Tree.initBorrowed(gpa, &initial, true);
    defer tree.deinit();
    try testing.expect(!consumer.text.query.hasTextSelection(try resolve(&tree, 7)));
    var delta: schema.TreeUpdate = .{ .focus = id(7) };
    defer delta.deinit(gpa);
    try delta.pushNode(gpa, id(7), try fieldNode(9, 0));
    var changes: Changes = .{};
    const handler = changes.handler();
    try tree.updateBorrowedAndProcessChanges(&delta, &handler);
    try testing.expect(!changes.overflow);
    try testing.expectEqualSlices(schema.NodeId, &.{id(7)},
        changes.updated[0..changes.updated_count]);
    const selection = (try consumer.text.query.textSelection(gpa, try resolve(&tree, 7))).?;
    try testing.expectEqual(fullId(9), selection.start.node.id());
    try testing.expectEqual(@as(usize, 0), selection.start.character_index);
    try testing.expect(try consumer.text.range.isDegenerate(gpa, selection));
    try expectDocument(&tree, 7, "same");
}

test "native-contract attaching a caller-owned custom window preserves its focus implementation" {
    if (comptime @import("builtin").os.tag != .macos) return error.SkipZigTest;
    var runtime = std.Io.Threaded.init(gpa, .{});
    defer runtime.deinit();
    try @import("native_mac_window_fixture.zig").checkAttachPreservesWindowClass(
        gpa, runtime.io(),
    );
}
