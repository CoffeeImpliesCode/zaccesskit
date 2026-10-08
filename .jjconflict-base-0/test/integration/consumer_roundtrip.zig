//! A client command changes application state before the application publishes a tree update.
const std = @import("std");
const schema = @import("../../src/schema/root.zig");
const consumer = @import("../../src/consumer/root.zig");
const atspi = @import("../../src/adapters/atspi/node.zig");
const context_api = @import("../../src/adapters/atspi/app_context.zig");

const ApplicationError = error{ InvalidCommand, ActionQueueFull, ScenarioMismatch };
const FixtureError = std.mem.Allocator.Error;
pub const ScenarioError = ApplicationError || consumer.tree.UpdateError || atspi.NodeError;
const action_count_max = 4;
const fixture_node_count_max = 8;

// These tests use the same scenario as the standalone program. No bus or native adapter is started.
test "application roundtrip commits numeric focus Unicode selection and deletion commands" {
    try runScenario(std.testing.allocator);
}

test "application fixture updates release partial ownership under fail N" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocateFixtures, .{});
}

test "application action queue reports exhaustion and rejects invalid commands" {
    var application: Application = .{ .gpa = std.testing.allocator };
    const request: schema.ActionRequest = .{
        .action = .focus,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 3 },
        .data = null,
    };
    for (0..action_count_max) |_| Application.receive(&application, request);
    try std.testing.expectEqual(@as(usize, action_count_max), application.command_count);
    Application.receive(&application, request);
    try std.testing.expectEqual(error.ActionQueueFull, application.failure.?);
    var invalid = request;
    invalid.target_node = .{ .value = 404 };
    try std.testing.expectError(error.InvalidCommand, decodeCommand(invalid));
    invalid = request;
    invalid.action = .set_value;
    try std.testing.expectError(error.InvalidCommand, decodeCommand(invalid));
}

const Command = union(enum) {
    numeric_value: f64,
    focus,
    selection: schema.TextSelection,
    remove_button,
};

const Application = struct {
    gpa: std.mem.Allocator,
    numeric_value: f64 = 4.5,
    focus: schema.NodeId = .{ .value = 2 },
    selection: schema.TextSelection = .{
        .anchor = .{ .node_id = .{ .value = 4 }, .character_index = 0 },
        .focus = .{ .node_id = .{ .value = 4 }, .character_index = 0 },
    },
    button_present: bool = true,
    commands: [action_count_max]Command = undefined,
    requests: [action_count_max]schema.ActionRequest = undefined,
    command_count: usize = 0,
    applied_count: usize = 0,
    failure: ?ApplicationError = null,

    fn receive(pointer: ?*anyopaque, received: schema.ActionRequest) void {
        const self: *Application = @ptrCast(@alignCast(pointer orelse
            @panic("The application sink requires its application state.")));
        var request = received;
        defer request.deinit(self.gpa);
        if (self.command_count == action_count_max) {
            self.failure = error.ActionQueueFull;
            return;
        }
        const command = decodeCommand(request) catch |err| {
            self.failure = err;
            return;
        };
        // The accepted variants own no buffers. Preserve the request values for protocol assertions.
        self.requests[self.command_count] = request;
        self.commands[self.command_count] = command;
        self.command_count += 1;
    }

    fn applyPending(self: *Application, gpa: std.mem.Allocator, tree: *consumer.tree.Tree, context: *context_api.NodeContext) ScenarioError!void {
        if (self.failure) |err| return err;
        const pending_count = self.command_count - self.applied_count;
        if (pending_count > action_count_max) return error.ActionQueueFull;
        for (0..pending_count) |_| {
            const command = self.commands[self.applied_count];
            switch (command) {
                .numeric_value => |value| self.numeric_value = value,
                .focus => self.focus = .{ .value = 3 },
                .selection => |selection| self.selection = selection,
                .remove_button => self.button_present = false,
            }
            const update = try incrementalTreeUpdate(gpa, self, command);
            const handler: consumer.tree.TreeChangeHandler = .{ .ptr = self };
            try tree.updateAndProcessChanges(update, &handler);
            context.state = tree.stateOf();
            self.applied_count += 1;
        }
    }
};

fn decodeCommand(request: schema.ActionRequest) ApplicationError!Command {
    if (!std.meta.eql(request.target_tree, schema.tree_id_root)) return error.InvalidCommand;
    switch (request.action) {
        .set_value => {
            if (request.target_node.value != 2) return error.InvalidCommand;
            const data = request.data orelse return error.InvalidCommand;
            if (data != .numeric_value) return error.InvalidCommand;
            if (!std.math.isFinite(data.numeric_value)) return error.InvalidCommand;
            if (data.numeric_value < 0 or data.numeric_value > 10) return error.InvalidCommand;
            return .{ .numeric_value = data.numeric_value };
        },
        .focus => {
            if (request.target_node.value != 3 or request.data != null) return error.InvalidCommand;
            return .focus;
        },
        .set_text_selection => {
            if (request.target_node.value != 3) return error.InvalidCommand;
            const data = request.data orelse return error.InvalidCommand;
            if (data != .set_text_selection) return error.InvalidCommand;
            const selection = data.set_text_selection;
            const endpoints = [_]schema.TextPosition{ selection.anchor, selection.focus };
            const endpoint_count_max = endpoints.len;
            for (endpoints[0..endpoint_count_max]) |position| {
                if (position.node_id.value != 4 and position.node_id.value != 5)
                    return error.InvalidCommand;
                if (position.character_index > 2) return error.InvalidCommand;
            }
            return .{ .selection = selection };
        },
        .click => {
            if (request.target_node.value != 6 or request.data != null) return error.InvalidCommand;
            return .remove_button;
        },
        else => return error.InvalidCommand,
    }
}

fn makeNode(gpa: std.mem.Allocator, application: *const Application, index: usize) FixtureError!schema.Node {
    const roles = [_]schema.Role{
        .window,   .generic_container, .spin_button, .text_input,
        .text_run, .text_run,          .button,      .image,
    };
    std.debug.assert(index < fixture_node_count_max);
    var node = schema.Node.init(gpa, roles[index]);
    errdefer node.deinit();
    switch (index) {
        0 => {
            const children: []const schema.NodeId = if (application.button_present)
                &.{ .{ .value = 1 }, .{ .value = 3 }, .{ .value = 6 }, .{ .value = 7 } }
            else
                &.{ .{ .value = 1 }, .{ .value = 3 }, .{ .value = 7 } };
            try schema.ids_props.setChildren(&node.properties, children);
            try schema.option.setTransform(&node.properties, schema.affineScale(2));
        },
        1 => {
            try schema.ids_props.setChildren(&node.properties, &.{.{ .value = 2 }});
            try schema.option.setTransform(&node.properties, schema.affineTranslate(.{ .x = 5, .y = 7 }));
        },
        2 => {
            try schema.numbers.setNumericValue(&node.properties, application.numeric_value);
            try schema.numbers.setMinNumericValue(&node.properties, 0);
            try schema.numbers.setMaxNumericValue(&node.properties, 10);
            try schema.option.setBounds(&node.properties, schema.rectInit(1, 2, 11, 12));
            node.addAction(.set_value);
            node.addAction(.focus);
        },
        3 => {
            try schema.ids_props.setChildren(&node.properties, &.{ .{ .value = 4 }, .{ .value = 5 } });
            try schema.option.setTextSelection(&node.properties, application.selection);
            node.addAction(.set_text_selection);
            node.addAction(.focus);
        },
        4, 5 => {
            try schema.strings.setValue(&node.properties, if (index == 4) "A😀" else "éB");
            try schema.vectors.setCharacterLengths(&node.properties, if (index == 4) &.{ 1, 4 } else &.{ 2, 1 });
            try schema.enums.setTextDirection(&node.properties, .left_to_right);
        },
        6 => {
            try schema.strings.setLabel(&node.properties, "Remove this button");
            node.addAction(.click);
        },
        7 => try schema.strings.setLabel(&node.properties, "Survivor"),
        else => unreachable, // The index assertion covers the complete role table.
    }
    return node;
}

fn initialTreeUpdate(gpa: std.mem.Allocator, application: *const Application) FixtureError!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    for (0..fixture_node_count_max) |index| {
        const node = try makeNode(gpa, application, index);
        // pushNode consumes node on both paths.
        try update.pushNode(gpa, .{ .value = @intCast(index) }, node);
    }
    update.tree = schema.TreeInfo.init(.{ .value = 0 });
    update.focus = application.focus;
    return update;
}

fn incrementalTreeUpdate(gpa: std.mem.Allocator, application: *const Application, command: Command) FixtureError!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    update.focus = application.focus;
    const index: ?usize = switch (command) {
        .numeric_value => 2,
        .focus => null,
        .selection => 3,
        .remove_button => 0,
    };
    if (index) |value| {
        const node = try makeNode(gpa, application, value);
        try update.pushNode(gpa, .{ .value = @intCast(value) }, node);
    }
    return update;
}

fn allocateFixtures(gpa: std.mem.Allocator) FixtureError!void {
    var application: Application = .{ .gpa = gpa };
    var initial = try initialTreeUpdate(gpa, &application);
    defer initial.deinit(gpa);
    const commands = [_]Command{
        .{ .numeric_value = 7.25 },              .focus,
        .{ .selection = application.selection }, .remove_button,
    };
    application.button_present = false;
    for (commands[0..action_count_max]) |command| {
        var incremental = try incrementalTreeUpdate(gpa, &application, command);
        incremental.deinit(gpa);
    }
}

fn require(condition: bool) ApplicationError!void {
    if (!condition) return error.ScenarioMismatch;
}

/// Executes the real consumer scenario without a test runner, runtime, bus, or clock.
/// The caller supplies the allocator and retains no borrowed tree state after this call.
pub fn runScenario(gpa: std.mem.Allocator) ScenarioError!void {
    var application: Application = .{ .gpa = gpa };
    var tree = try consumer.tree.Tree.init(gpa, try initialTreeUpdate(gpa, &application), true);
    defer tree.deinit();
    var app = try context_api.AppContext.init(gpa, "Roundtrip application");
    defer app.deinit();
    var context: context_api.NodeContext = .{
        .state = tree.stateOf(),
        .app = &app,
        .bounds = .init(schema.rectInit(100, 200, 500, 600), schema.rectInit(105, 210, 495, 595)),
        .sink = .{ .context = &application, .raise = Application.receive },
        .gpa = gpa,
    };
    try app.pushAdapter(7, &context);
    const window = atspi.PlatformRoot.init(&app).childAtIndex(0) orelse
        return error.ScenarioMismatch;
    const root_id = window.nodeId();
    const numeric = window.relative(root_id.withSameTree(.{ .value = 2 }));
    const text = window.relative(root_id.withSameTree(.{ .value = 3 }));
    const removable = window.relative(root_id.withSameTree(.{ .value = 6 }));
    const survivor = window.relative(root_id.withSameTree(.{ .value = 7 }));
    const survivor_id = survivor.nodeId();
    try require(try numeric.currentValue() == 4.5);
    try checkGeometryAndChildren(window, numeric, true);
    var initial_text = try text.text(0, 4);
    defer initial_text.deinit(gpa);
    try require(std.mem.eql(u8, initial_text.items, "A😀éB"));

    try numeric.setCurrentValue(7.25);
    try require(application.numeric_value == 4.5);
    try require(try numeric.currentValue() == 4.5);
    try application.applyPending(gpa, &tree, &context);
    try require(application.numeric_value == 7.25);
    try require(try numeric.currentValue() == 7.25);
    try require(application.requests[0].action == .set_value);
    try require(application.requests[0].data.?.numeric_value == 7.25);

    try require(try text.grabFocus());
    try application.applyPending(gpa, &tree, &context);
    try require(std.meta.eql(tree.stateOf().focusIdInTree(), text.nodeId()));
    try require(std.meta.eql(tree.stateOf().focusId().?, text.nodeId()));
    const handler: consumer.tree.TreeChangeHandler = .{ .ptr = &application };
    try tree.updateHostFocusStateAndProcessChanges(false, &handler);
    context.state = tree.stateOf();
    try require(std.meta.eql(tree.stateOf().focusIdInTree(), text.nodeId()));
    try require(tree.stateOf().focusId() == null);
    try tree.updateHostFocusStateAndProcessChanges(true, &handler);
    context.state = tree.stateOf();
    try require(std.meta.eql(tree.stateOf().focusId().?, text.nodeId()));

    try require(try text.addSelection(1, 3));
    const requested = application.requests[2].data.?.set_text_selection;
    try require(requested.anchor.node_id.value == 4);
    try require(requested.anchor.character_index == 1);
    try require(requested.focus.node_id.value == 5);
    try require(requested.focus.character_index == 1);
    try application.applyPending(gpa, &tree, &context);
    try require(std.meta.eql(application.selection, requested));
    const text_ref = tree.stateOf().nodeById(text.nodeId()) orelse return error.ScenarioMismatch;
    const stored = schema.option.textSelection(&text_ref.data().properties) orelse
        return error.ScenarioMismatch;
    try require(std.meta.eql(stored.*, requested));
    const offsets = try text.selection(0);
    try require(offsets.start_offset == 1 and offsets.end_offset == 3);
    var selected_text = try text.text(offsets.start_offset, offsets.end_offset);
    defer selected_text.deinit(gpa);
    try require(std.mem.eql(u8, selected_text.items, "😀é"));

    try require(try removable.doAction(0));
    try application.applyPending(gpa, &tree, &context);
    try require(!application.button_present);
    if (removable.resolve()) |_| {
        return error.ScenarioMismatch;
    } else |err| {
        if (err != error.Defunct) return err;
    }
    try require(std.meta.eql(survivor.nodeId(), survivor_id));
    try require(survivor.eql(window.relative(survivor_id)));
    var survivor_name = try survivor.name(gpa);
    defer survivor_name.deinit(gpa);
    try require(std.mem.eql(u8, survivor_name.items, "Survivor"));
    try checkGeometryAndChildren(window, numeric, false);
    try require(application.command_count == action_count_max);
    try require(application.applied_count == action_count_max);
}

fn checkGeometryAndChildren(window: atspi.PlatformNode, numeric: atspi.PlatformNode, button_present: bool) ScenarioError!void {
    const screen = try numeric.extents(.screen);
    try require(screen.x == 117 and screen.y == 228);
    try require(screen.width == 20 and screen.height == 20);
    const local = try numeric.extents(.window);
    try require(local.x == 12 and local.y == 18);
    try require(local.width == 20 and local.height == 20);
    try require(std.meta.eql((try window.childAtIndex(0)).?, numeric.nodeId()));
    try require(std.meta.eql((try window.childAtIndex(1)).?, window.nodeId().withSameTree(.{ .value = 3 })));
    const third: u64 = if (button_present) 6 else 7;
    try require(std.meta.eql((try window.childAtIndex(2)).?, window.nodeId().withSameTree(.{ .value = third })));
    if (button_present) {
        try require(std.meta.eql((try window.childAtIndex(3)).?, window.nodeId().withSameTree(.{ .value = 7 })));
        try require(try window.childAtIndex(4) == null);
    } else {
        try require(try window.childAtIndex(3) == null);
    }
}
