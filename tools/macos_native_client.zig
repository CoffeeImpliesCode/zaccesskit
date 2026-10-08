//! One-shot actual AppKit/NSObject proof; never a RecordingHost or off-platform green.
//! Build with the package's actual macobjc SDK module and Foundation SDK shim.
//! Receipts are emitted only after comparing native getter contents and identities.
//! AX notification delivery to a separate assistive process is not claimed by this client.
const std = @import("std");
const builtin = @import("builtin");
const kit = @import("zaccesskit");
const schema = kit.schema;
const macos = kit.adapters.macos;
const objc = macos.objc;
const foundation = macos.foundation;
const Adapter = macos.NativeAdapter;
const Object = objc.Object;
const Error = macos.CreateError || macos.AttachError || macos.UpdateError ||
    macos.NotificationError || macos.CloseError || std.Io.Writer.Error || std.Thread.SpawnError ||
    error{ NativeProofFailed, CallbackOverflow, UnexpectedActionPayload, FaultBoundExceeded, InvalidArguments, MissingNativeObject };

pub fn main(init: std.process.Init) Error!void {
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &file_writer.interface;
    if (comptime builtin.os.tag != .macos) {
        try writer.writeAll("FAIL native-macos-client NativeUnsupported; no native proof\n");
        try writer.flush();
        return error.NativeUnsupported;
    } else {
        const args = init.minimal.args.toSlice(init.arena.allocator()) catch
            return error.OutOfMemory;
        if (args.len != 1) return error.InvalidArguments;
        runNative(init.gpa, writer) catch |err| {
            try writer.print("FAIL native-macos-client {s}\n", .{@errorName(err)});
            try writer.flush();
            return err;
        };
        try writer.writeAll("PASS native-macos-client actual-sdk-selectors one-shot\n");
        try writer.flush();
    }
}

fn require(condition: bool) Error!void {
    if (!condition) return error.NativeProofFailed;
}

fn nativeObject(value: ?Object) Error!Object {
    return value orelse error.MissingNativeObject;
}

fn expectClass(value: Object, name: [:0]const u8) Error!void {
    const class = objc.getClass(name) orelse return error.ObjectiveCUnavailable;
    try require(objc.send(objc.BOOL, value, "isKindOfClass:", .{class}) != 0);
}

fn expectString(value: ?Object, expected: []const u8) Error!void {
    const actual = try nativeObject(value);
    try expectClass(actual, "NSString");
    try require(std.mem.eql(u8, expected, try foundation.utf8(actual)));
}

fn expectRange(actual: objc.NSRange, expected: objc.NSRange) Error!void {
    try require(actual.location == expected.location);
    try require(actual.length == expected.length);
}

fn expectRect(actual: objc.NSRect, expected: objc.NSRect) Error!void {
    try require(@abs(actual.origin.x - expected.origin.x) < 0.001);
    try require(@abs(actual.origin.y - expected.origin.y) < 0.001);
    try require(@abs(actual.size.width - expected.size.width) < 0.001);
    try require(@abs(actual.size.height - expected.size.height) < 0.001);
}

fn arrayObjects(value: Object, expected: []const Object) Error!void {
    try expectClass(value, "NSArray");
    try require(objc.send(usize, value, "count", .{}) == expected.len);
    for (expected, 0..) |object, index| {
        try require(objc.send(?Object, value, "objectAtIndex:", .{index}) == object);
    }
}

const Selector = struct { name: [:0]const u8, kind: Kind };
const Kind = enum { object, boolean, integer, rect, argument };
const selectors = [_]Selector{
    .{ .name = "accessibilityParent", .kind = .object },
    .{ .name = "accessibilityWindow", .kind = .object },
    .{ .name = "accessibilityTopLevelUIElement", .kind = .object },
    .{ .name = "accessibilityChildren", .kind = .object },
    .{ .name = "accessibilityChildrenInNavigationOrder", .kind = .object },
    .{ .name = "accessibilitySelectedChildren", .kind = .object },
    .{ .name = "accessibilityFrame", .kind = .rect },
    .{ .name = "accessibilityRole", .kind = .object },
    .{ .name = "accessibilitySubrole", .kind = .object },
    .{ .name = "accessibilityRoleDescription", .kind = .object },
    .{ .name = "accessibilityIdentifier", .kind = .object },
    .{ .name = "accessibilityTitle", .kind = .object },
    .{ .name = "accessibilityHelp", .kind = .object },
    .{ .name = "accessibilityPlaceholderValue", .kind = .object },
    .{ .name = "accessibilityValue", .kind = .object },
    .{ .name = "setAccessibilityValue:", .kind = .argument },
    .{ .name = "accessibilityMinValue", .kind = .object },
    .{ .name = "accessibilityMaxValue", .kind = .object },
    .{ .name = "accessibilityURL", .kind = .object },
    .{ .name = "accessibilityOrientation", .kind = .integer },
    .{ .name = "isAccessibilityElement", .kind = .boolean },
    .{ .name = "isAccessibilityFocused", .kind = .boolean },
    .{ .name = "isAccessibilityEnabled", .kind = .boolean },
    .{ .name = "setAccessibilityFocused:", .kind = .argument },
    .{ .name = "accessibilityPerformPress", .kind = .argument },
    .{ .name = "accessibilityPerformIncrement", .kind = .argument },
    .{ .name = "accessibilityPerformDecrement", .kind = .argument },
    .{ .name = "accessibilityNotifiesWhenDestroyed", .kind = .boolean },
    .{ .name = "accessibilityNumberOfCharacters", .kind = .integer },
    .{ .name = "accessibilitySelectedText", .kind = .object },
    .{ .name = "accessibilitySelectedTextRange", .kind = .argument },
    .{ .name = "accessibilityInsertionPointLineNumber", .kind = .integer },
    .{ .name = "accessibilityRangeForLine:", .kind = .argument },
    .{ .name = "accessibilityRangeForPosition:", .kind = .argument },
    .{ .name = "accessibilityStringForRange:", .kind = .argument },
    .{ .name = "accessibilityAttributedStringForRange:", .kind = .argument },
    .{ .name = "accessibilityFrameForRange:", .kind = .argument },
    .{ .name = "accessibilityLineForIndex:", .kind = .argument },
    .{ .name = "accessibilityRangeForIndex:", .kind = .argument },
    .{ .name = "accessibilityStyleRangeForIndex:", .kind = .argument },
    .{ .name = "setAccessibilitySelectedTextRange:", .kind = .argument },
    .{ .name = "isAccessibilityRequired", .kind = .boolean },
    .{ .name = "isAccessibilitySelected", .kind = .boolean },
    .{ .name = "setAccessibilitySelected:", .kind = .argument },
    .{ .name = "accessibilityAttributeValue:", .kind = .argument },
    .{ .name = "accessibilityRows", .kind = .object },
    .{ .name = "accessibilitySelectedRows", .kind = .object },
    .{ .name = "accessibilityPerformPick", .kind = .argument },
    .{ .name = "accessibilityLinkedUIElements", .kind = .object },
    .{ .name = "accessibilityTabs", .kind = .object },
    .{ .name = "isAccessibilityModal", .kind = .boolean },
    .{ .name = "accessibilityActionNames", .kind = .object },
    .{ .name = "accessibilityPerformAction:", .kind = .argument },
    .{ .name = "isAccessibilitySelectorAllowed:", .kind = .argument },
};

comptime {
    std.debug.assert(selectors.len == 54);
}

fn selectorAllowed(comptime name: []const u8, id: u64) bool {
    inline for (.{ "accessibilityNumberOfCharacters", "accessibilitySelectedText", "accessibilitySelectedTextRange", "accessibilityInsertionPointLineNumber", "accessibilityRangeForLine:", "accessibilityRangeForPosition:", "accessibilityStringForRange:", "accessibilityAttributedStringForRange:", "accessibilityFrameForRange:", "accessibilityLineForIndex:", "accessibilityRangeForIndex:", "accessibilityStyleRangeForIndex:", "setAccessibilitySelectedTextRange:" }) |text_selector| {
        if (comptime std.mem.eql(u8, name, text_selector)) return id == 4;
    }
    if (comptime std.mem.eql(u8, name, "setAccessibilityFocused:"))
        return id == 2 or id == 3 or id == 4 or id == 8 or id == 9;
    if (comptime std.mem.eql(u8, name, "accessibilityPerformPress"))
        return id == 2 or id == 8 or id == 9 or id == 10;
    if (comptime std.mem.eql(u8, name, "accessibilityPerformIncrement") or
        std.mem.eql(u8, name, "accessibilityPerformDecrement")) return id == 3;
    if (comptime std.mem.eql(u8, name, "setAccessibilityValue:")) return id == 3 or id == 4;
    if (comptime std.mem.eql(u8, name, "isAccessibilitySelected") or
        std.mem.eql(u8, name, "setAccessibilitySelected:") or
        std.mem.eql(u8, name, "accessibilityPerformPick")) return id == 8 or id == 9;
    if (comptime std.mem.eql(u8, name, "accessibilityRows") or
        std.mem.eql(u8, name, "accessibilitySelectedRows")) return id == 7;
    if (comptime std.mem.eql(u8, name, "accessibilityTabs") or
        std.mem.eql(u8, name, "isAccessibilityModal") or
        std.mem.eql(u8, name, "accessibilityURL")) return false;
    if (comptime std.mem.eql(u8, name, "accessibilityAttributeValue:")) return id == 10;
    return true;
}

fn verifySelectors(writer: *std.Io.Writer, object: Object, id: u64) Error!void {
    try expectClass(object, "NSAccessibilityElement");
    inline for (selectors) |entry| {
        const selector = objc.sel(entry.name);
        try require(objc.send(objc.BOOL, object, "respondsToSelector:", .{selector}) != 0);
        const allowed = objc.send(objc.BOOL, object, "isAccessibilitySelectorAllowed:", .{selector}) != 0;
        try require(allowed == selectorAllowed(entry.name, id));
        try writer.print("selector node={d} name={s} allowed={}\n", .{ id, entry.name, allowed });
        switch (entry.kind) {
            .object => {
                if (objc.send(?Object, object, entry.name, .{})) |value| {
                    try expectClass(value, "NSObject");
                    try writer.print("getter node={d} name={s} object=0x{x}\n", .{ id, entry.name, @intFromPtr(value) });
                } else try writer.print("getter node={d} name={s} nil\n", .{ id, entry.name });
            },
            .boolean => try writer.print("getter node={d} name={s} bool={d}\n", .{ id, entry.name, objc.send(objc.BOOL, object, entry.name, .{}) }),
            .integer => try writer.print("getter node={d} name={s} integer={d}\n", .{ id, entry.name, objc.send(isize, object, entry.name, .{}) }),
            .rect => {
                const rect = objc.send(objc.NSRect, object, entry.name, .{});
                try writer.print("getter node={d} name={s} rect={d},{d},{d},{d}\n", .{
                    id,              entry.name,       rect.origin.x, rect.origin.y,
                    rect.size.width, rect.size.height,
                });
            },
            .argument => {},
        }
    }
}

const Frame = struct {
    full: schema.TreeUpdate,

    fn init(gpa: std.mem.Allocator, changed: bool, removed: bool) Error!Frame {
        var full: schema.TreeUpdate = .{
            .tree = schema.TreeInfo.init(.{ .value = 0 }),
            .focus = .{ .value = 2 },
        };
        errdefer full.deinit(gpa);
        for (1..12) |number| {
            const id: u64 = @intCast(number);
            if (removed and id == 2) continue;
            var node = schema.Node.init(gpa, switch (id) {
                1 => .window,
                2, 10, 11 => .button,
                3 => .slider,
                4 => .multiline_text_input,
                5, 6 => .text_run,
                7 => .list_box,
                8, 9 => .list_box_option,
                // The fixture loop admits only IDs 1 through 11, all covered above.
                else => unreachable,
            });
            {
                errdefer node.deinit();
                var name_buffer: [32]u8 = undefined;
                // IDs are at most 11, so "node-{d}" needs at most 7 bytes in this 32-byte buffer.
                const identifier = std.fmt.bufPrint(&name_buffer, "node-{d}", .{id}) catch
                    unreachable;
                try schema.strings.setAuthorId(&node.properties, identifier);
                switch (id) {
                    1 => {
                        try schema.ids_props.setChildren(&node.properties, if (removed)
                            &.{ .{ .value = 3 }, .{ .value = 4 }, .{ .value = 7 }, .{ .value = 10 }, .{ .value = 11 } }
                        else
                            &.{ .{ .value = 2 }, .{ .value = 3 }, .{ .value = 4 }, .{ .value = 7 }, .{ .value = 10 }, .{ .value = 11 } });
                        try schema.strings.setLabel(&node.properties, "Native Unicode 窓");
                    },
                    2 => {
                        node.addAction(.click);
                        node.addAction(.focus);
                        try schema.strings.setLabel(&node.properties, if (changed) "Changed 🙂\x00button" else "Invoke 🙂\x00button");
                        try schema.strings.setDescription(&node.properties, "Exact button help");
                        try schema.option.setBounds(&node.properties, schema.rectInit(20, 20, 100, 50));
                    },
                    3 => {
                        inline for (.{ .focus, .increment, .decrement, .set_value }) |action|
                            node.addAction(action);
                        try schema.strings.setLabel(&node.properties, "Zero slider");
                        try schema.numbers.setNumericValue(&node.properties, 0);
                        try schema.numbers.setMinNumericValue(&node.properties, 0);
                        try schema.numbers.setMaxNumericValue(&node.properties, 10);
                        try schema.enums.setOrientation(&node.properties, .horizontal);
                    },
                    4 => {
                        node.addAction(.focus);
                        node.addAction(.set_value);
                        node.addAction(.set_text_selection);
                        try schema.strings.setLabel(&node.properties, "Unicode editor");
                        try schema.strings.setPlaceholder(&node.properties, "空欄");
                        try schema.ids_props.setChildren(&node.properties, &.{ .{ .value = 5 }, .{ .value = 6 } });
                        try schema.option.setTextSelection(&node.properties, if (changed)
                            .{ .anchor = .{ .node_id = .{ .value = 5 }, .character_index = 2 }, .focus = .{ .node_id = .{ .value = 5 }, .character_index = 2 } }
                        else
                            .{ .anchor = .{ .node_id = .{ .value = 5 }, .character_index = 1 }, .focus = .{ .node_id = .{ .value = 6 }, .character_index = 1 } });
                    },
                    5, 6 => {
                        try schema.strings.setValue(&node.properties, if (id == 5) "a🙂\n" else "é\x00b");
                        try schema.vectors.setCharacterLengths(&node.properties, if (id == 5) &.{ 1, 4, 1 } else &.{ 2, 1, 1 });
                        try schema.vectors.setCharacterPositions(&node.properties, &.{ 0, 10, 20 });
                        try schema.vectors.setCharacterWidths(&node.properties, if (id == 5) &.{ 10, 10, 0 } else &.{ 10, 10, 10 });
                        try schema.option.setBounds(&node.properties, if (id == 5)
                            schema.rectInit(120, 20, 140, 30)
                        else
                            schema.rectInit(120, 40, 150, 50));
                        try schema.enums.setTextDirection(&node.properties, .left_to_right);
                        try schema.numbers.setFontSize(&node.properties, if (id == 5) 12 else 18);
                    },
                    7 => {
                        try schema.strings.setLabel(&node.properties, "Selected list");
                        try schema.ids_props.setChildren(&node.properties, &.{ .{ .value = 8 }, .{ .value = 9 } });
                    },
                    8, 9 => {
                        node.addAction(.click);
                        node.addAction(.focus);
                        try schema.enums.setSelected(&node.properties, id == 8);
                        try schema.strings.setLabel(&node.properties, if (id == 8) "Chosen 零" else "Unchosen 一");
                    },
                    10 => {
                        node.addAction(.click);
                        try schema.strings.setLabel(&node.properties, if (changed)
                            "Changed custom 窓\x00tail"
                        else
                            "Custom fields");
                        try schema.enums.setLive(&node.properties, .polite);
                        try schema.strings.setRoleDescription(&node.properties, "Fixture control");
                        try schema.strings.setBrailleLabel(&node.properties, "点\x00字");
                        try schema.strings.setBrailleRoleDescription(&node.properties, "Braille role");
                        try schema.strings.setHtmlId(&node.properties, "dom-fixture");
                    },
                    11 => {},
                    // The fixture loop admits only IDs 1 through 11, all covered above.
                    else => unreachable,
                }
            }
            try full.pushNode(gpa, .{ .value = if (id == 1) 0 else id }, node);
        }
        if (removed) full.focus = .{ .value = 4 };
        return .{ .full = full };
    }

    fn delta(self: *Frame, entries: []schema.NodeEntry) schema.TreeUpdate {
        return .{ .nodes = .{ .items = entries, .capacity = 0 }, .focus = self.full.focus };
    }

    fn deinit(self: *Frame, gpa: std.mem.Allocator) void {
        self.full.deinit(gpa);
    }
};

const Captured = struct {
    action: schema.Action,
    tree: schema.TreeId,
    target: schema.NodeId,
    payload: union(enum) {
        none,
        value: struct { bytes: [256]u8, count: usize },
        number: f64,
        selection: schema.TextSelection,
    },
};

const Host = struct {
    full: *const schema.TreeUpdate,
    activation_count: usize = 0,
    supplier_count: usize = 0,
    action_count: usize = 0,
    actions: [16]Captured = undefined,
    callback_error: ?Error = null,
    barrier: ?*CallbackBarrier = null,

    fn activation(raw: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(raw.?));
        self.activation_count += 1;
    }

    fn supply(raw: ?*anyopaque) *const schema.TreeUpdate {
        const self: *Host = @ptrCast(@alignCast(raw.?));
        self.supplier_count += 1;
        return self.full;
    }

    fn action(raw: ?*anyopaque, borrowed: *const schema.ActionRequest) void {
        const self: *Host = @ptrCast(@alignCast(raw.?));
        if (self.action_count == self.actions.len) {
            self.callback_error = error.CallbackOverflow;
            return;
        }
        var copy: Captured = .{
            .action = borrowed.action,
            .tree = borrowed.target_tree,
            .target = borrowed.target_node,
            .payload = .none,
        };
        if (borrowed.data) |data| switch (data) {
            .value => |bytes| {
                if (bytes.len > 256) {
                    self.callback_error = error.CallbackOverflow;
                    return;
                }
                copy.payload = .{ .value = .{ .bytes = undefined, .count = bytes.len } };
                @memcpy(copy.payload.value.bytes[0..bytes.len], bytes);
            },
            .numeric_value => |number| copy.payload = .{ .number = number },
            .set_text_selection => |selection| copy.payload = .{ .selection = selection },
            else => {
                self.callback_error = error.UnexpectedActionPayload;
                return;
            },
        };
        self.actions[self.action_count] = copy;
        self.action_count += 1;
        if (self.barrier) |barrier| {
            barrier.mutex.lockUncancelable(barrier.io);
            defer barrier.mutex.unlock(barrier.io);
            barrier.entered = true;
            barrier.changed.broadcast(barrier.io);
            while (!barrier.release_callback)
                barrier.changed.waitUncancelable(barrier.io, &barrier.mutex);
        }
    }
};

const CallbackBarrier = struct {
    io: std.Io,
    target: Object,
    mutex: std.Io.Mutex = .init,
    changed: std.Io.Condition = .init,
    entered: bool = false,
    start_close: bool = false,
    release_callback: bool = false,
    observed_defunct: bool = false,
    press_succeeded: bool = false,
    actor_finished: bool = false,

    fn invoke(self: *CallbackBarrier) void {
        const result = objc.send(objc.BOOL, self.target, "accessibilityPerformPress", .{});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.press_succeeded = result != 0;
        self.actor_finished = true;
        self.changed.broadcast(self.io);
    }

    fn releaseWhenNativeDefunct(self: *CallbackBarrier) void {
        self.mutex.lockUncancelable(self.io);
        while (!self.start_close) self.changed.waitUncancelable(self.io, &self.mutex);
        self.mutex.unlock(self.io);
        var observed_defunct = false;
        const query_bound = 1_000_000;
        for (0..query_bound) |_| {
            if (objc.send(objc.BOOL, self.target, "isAccessibilityElement", .{}) == 0) {
                observed_defunct = true;
                break;
            }
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.observed_defunct = observed_defunct;
        self.release_callback = true;
        self.changed.broadcast(self.io);
    }
};

fn closeJoiningCallback(adapter: *Adapter, host: *Host, target: Object) Error!bool {
    const held_target = objc.retain(target);
    defer objc.release(held_target);
    var barrier: CallbackBarrier = .{ .io = adapter.io, .target = target };
    host.barrier = &barrier;
    defer host.barrier = null;
    const releaser = std.Thread.spawn(.{}, CallbackBarrier.releaseWhenNativeDefunct, .{&barrier}) catch |err| return err;
    var releaser_joined = false;
    defer if (!releaser_joined) releaser.join();
    const actor = std.Thread.spawn(.{}, CallbackBarrier.invoke, .{&barrier}) catch |err| {
        barrier.mutex.lockUncancelable(barrier.io);
        barrier.start_close = true;
        barrier.mutex.unlock(barrier.io);
        barrier.changed.broadcast(barrier.io);
        return err;
    };
    var actor_joined = false;
    defer if (!actor_joined) actor.join();
    barrier.mutex.lockUncancelable(barrier.io);
    while (!barrier.entered and !barrier.actor_finished)
        barrier.changed.waitUncancelable(barrier.io, &barrier.mutex);
    const entered = barrier.entered;
    barrier.start_close = true;
    barrier.changed.broadcast(barrier.io);
    barrier.mutex.unlock(barrier.io);
    if (!entered) return error.NativeProofFailed;
    try adapter.close();
    // Close has joined the handler pin; joining the SDK call also joins its epilogue.
    actor.join();
    actor_joined = true;
    releaser.join();
    releaser_joined = true;
    return barrier.observed_defunct and barrier.press_succeeded;
}

const Authority = struct {
    threaded: std.Io.Threaded,
    releases: usize = 0,

    fn release(raw: ?*anyopaque) void {
        const self: *Authority = @ptrCast(@alignCast(raw.?));
        std.debug.assert(self.releases == 0);
        self.threaded.deinit();
        self.releases += 1;
    }
};

fn flipped(_: Object, _: objc.Sel) callconv(.c) objc.BOOL {
    return 1;
}

fn subclass(name: [:0]const u8, parent_name: [:0]const u8, flip: bool) Error!objc.Class {
    const parent = objc.getClass(parent_name) orelse return error.ObjectiveCUnavailable;
    if (objc.getClass(name)) |class| return class;
    const class = objc.objc_allocateClassPair(parent, name.ptr, 0) orelse
        return error.ClassRegistrationFailed;
    errdefer objc.objc_disposeClassPair(class);
    if (flip) {
        const method = objc.class_getInstanceMethod(parent, objc.sel("isFlipped")) orelse
            return error.ObjectiveCUnavailable;
        const encoding = objc.method_getTypeEncoding(method) orelse
            return error.ObjectiveCUnavailable;
        if (objc.class_addMethod(class, objc.sel("isFlipped"), @ptrCast(&flipped), encoding) == 0)
            return error.MethodRegistrationFailed;
    }
    objc.objc_registerClassPair(class);
    return class;
}

fn allocate(class: objc.Class) Error!Object {
    return nativeObject(objc.send(?Object, class, "alloc", .{}));
}

fn find(view: Object, id: u64) Error!Object {
    var name_buffer: [32]u8 = undefined;
    // Any u64 needs at most 20 decimal digits, so "node-" plus the ID fits in 25 of 32 bytes.
    const identifier = std.fmt.bufPrint(&name_buffer, "node-{d}", .{id}) catch unreachable;
    var pending: [32]Object = undefined;
    pending[0] = view;
    var next: usize = 0;
    var count: usize = 1;
    for (0..pending.len) |_| {
        if (next == count) break;
        const current = pending[next];
        next += 1;
        if (objc.send(objc.BOOL, current, "respondsToSelector:", .{objc.sel("accessibilityIdentifier")}) != 0) {
            if (objc.send(?Object, current, "accessibilityIdentifier", .{})) |value| {
                if (std.mem.eql(u8, identifier, try foundation.utf8(value))) return current;
            }
        }
        if (objc.send(?Object, current, "accessibilityChildren", .{})) |children| {
            try expectClass(children, "NSArray");
            const child_count = objc.send(usize, children, "count", .{});
            if (child_count > pending.len - count) return error.NativeProofFailed;
            for (0..child_count) |index| {
                pending[count] = try nativeObject(objc.send(?Object, children, "objectAtIndex:", .{index}));
                count += 1;
            }
        }
    }
    return error.MissingNativeObject;
}

fn committed(outcome: macos.UpdateOutcome, used_full: bool) Error!void {
    switch (outcome) {
        .inactive => return error.NativeProofFailed,
        .rejected => |err| return err,
        .committed => |value| {
            try require(value.used_full_tree == used_full);
            if (value.notification_error) |err| return err;
        },
    }
}

fn prepared(outcome: macos.PreparedUpdateOutcome, used_full: bool) Error!?*macos.NativeNotifications {
    switch (outcome) {
        .inactive => return error.NativeProofFailed,
        .rejected => |err| return err,
        .committed => |value| {
            errdefer if (value.events) |queue| queue.deinit();
            try require(value.used_full_tree == used_full);
            if (value.notification_error) |err| return err;
            return value.events;
        },
    }
}

fn verifyText(writer: *std.Io.Writer, text: Object, caret: bool) Error!void {
    const document: objc.NSRange = .{ .location = 0, .length = 7 };
    try require(objc.send(isize, text, "accessibilityNumberOfCharacters", .{}) == 7);
    try expectString(objc.send(?Object, text, "accessibilityValue", .{}), "a🙂\né\x00b");
    try expectRange(objc.send(objc.NSRange, text, "accessibilitySelectedTextRange", .{}), if (caret) .{ .location = 3, .length = 0 } else .{ .location = 1, .length = 4 });
    try expectString(objc.send(?Object, text, "accessibilitySelectedText", .{}), if (caret) "" else "🙂\né");
    try expectString(objc.send(?Object, text, "accessibilityStringForRange:", .{document}), "a🙂\né\x00b");
    try expectString(objc.send(?Object, text, "accessibilityStringForRange:", .{objc.NSRange{ .location = 4, .length = 3 }}), "é\x00b");
    try expectRange(objc.send(objc.NSRange, text, "accessibilityRangeForIndex:", .{@as(isize, 2)}), .{ .location = 1, .length = 2 });
    try expectRange(objc.send(objc.NSRange, text, "accessibilityStyleRangeForIndex:", .{@as(isize, 4)}), .{ .location = 4, .length = 3 });
    try expectRange(objc.send(objc.NSRange, text, "accessibilityRangeForLine:", .{@as(isize, 0)}), .{ .location = 0, .length = 4 });
    try require(objc.send(isize, text, "accessibilityLineForIndex:", .{@as(isize, 4)}) == 1);
    try require(objc.send(isize, text, "accessibilityInsertionPointLineNumber", .{}) ==
        @as(isize, if (caret) 0 else 1));
    const attributed = try nativeObject(objc.send(?Object, text, "accessibilityAttributedStringForRange:", .{document}));
    try expectClass(attributed, "NSAttributedString");
    try expectString(objc.send(?Object, attributed, "string", .{}), "a🙂\né\x00b");
    try require(objc.send(usize, attributed, "length", .{}) == 7);
    // Read the SDK-produced dictionary rather than the provider's pure style model.
    var effective: objc.NSRange = undefined;
    const style = try nativeObject(objc.send(?Object, attributed, "attributesAtIndex:effectiveRange:", .{ @as(usize, 0), &effective }));
    try expectClass(style, "NSDictionary");
    try expectRange(effective, .{ .location = 0, .length = 4 });
    const keys = try nativeObject(objc.send(?Object, style, "allKeys", .{}));
    const count = objc.send(usize, keys, "count", .{});
    try require(count == 1);
    const sdk_font_key = try foundation.accessibilityTextConstant(.font);
    const sdk_font_size_key = try foundation.accessibilityTextConstant(.font_size);
    var saw_font_size = false;
    for (0..count) |index| {
        const key = try nativeObject(objc.send(?Object, keys, "objectAtIndex:", .{index}));
        try require(objc.send(objc.BOOL, key, "isEqualToString:", .{sdk_font_key}) != 0);
        const value = try nativeObject(objc.send(?Object, style, "objectForKey:", .{key}));
        if (objc.send(objc.BOOL, value, "isKindOfClass:", .{objc.getClass("NSDictionary").?}) != 0) {
            const font_keys = try nativeObject(objc.send(?Object, value, "allKeys", .{}));
            const font_count = objc.send(usize, font_keys, "count", .{});
            try require(font_count == 1);
            for (0..font_count) |font_index| {
                const font_key = try nativeObject(objc.send(?Object, font_keys, "objectAtIndex:", .{font_index}));
                const font_value = try nativeObject(objc.send(?Object, value, "objectForKey:", .{font_key}));
                if (objc.send(objc.BOOL, font_value, "isKindOfClass:", .{objc.getClass("NSNumber").?}) != 0) {
                    try require(objc.send(f64, font_value, "doubleValue", .{}) == 12);
                    try require(objc.send(objc.BOOL, font_key, "isEqualToString:", .{sdk_font_size_key}) != 0);
                    saw_font_size = true;
                    try writer.print("attributed outer_key={s} font_key={s} numeric=12 " ++
                        "inline-attachment=absent\n", .{
                        try foundation.utf8(key), try foundation.utf8(font_key),
                    });
                }
            }
        }
    }
    try require(saw_font_size);
    try writer.print("text caret={} UTF16=7 bytes_hex={x} selection={d},{d} unchanged_runs=5,6\n", .{ caret, "a🙂\né\x00b", @as(usize, if (caret) 3 else 1), @as(usize, if (caret) 0 else 4) });
}

fn verifyFields(writer: *std.Io.Writer, view: Object, window: Object) Error!void {
    const button = try find(view, 2);
    const slider = try find(view, 3);
    const text = try find(view, 4);
    const list = try find(view, 7);
    const chosen = try find(view, 8);
    const unchosen = try find(view, 9);
    const custom = try find(view, 10);
    const sparse = try find(view, 11);
    try expectString(objc.send(?Object, button, "accessibilityTitle", .{}), "Invoke 🙂\x00button");
    try expectString(objc.send(?Object, button, "accessibilityHelp", .{}), "Exact button help");
    try expectString(objc.send(?Object, button, "accessibilityRole", .{}), "AXButton");
    try require(objc.send(?Object, button, "accessibilityWindow", .{}) == window);
    try require(objc.send(?Object, button, "accessibilityTopLevelUIElement", .{}) == window);
    try expectString(objc.send(?Object, text, "accessibilityPlaceholderValue", .{}), "空欄");
    const zero = try nativeObject(objc.send(?Object, slider, "accessibilityValue", .{}));
    try expectClass(zero, "NSNumber");
    try require(objc.send(f64, zero, "doubleValue", .{}) == 0);
    const minimum = try nativeObject(objc.send(?Object, slider, "accessibilityMinValue", .{}));
    const maximum = try nativeObject(objc.send(?Object, slider, "accessibilityMaxValue", .{}));
    try expectClass(minimum, "NSNumber");
    try expectClass(maximum, "NSNumber");
    try require(objc.send(f64, minimum, "doubleValue", .{}) == 0);
    try require(objc.send(f64, maximum, "doubleValue", .{}) == 10);
    try arrayObjects(try nativeObject(objc.send(?Object, list, "accessibilityChildren", .{})), &.{ chosen, unchosen });
    try arrayObjects(try nativeObject(objc.send(?Object, list, "accessibilityChildrenInNavigationOrder", .{})), &.{ chosen, unchosen });
    try arrayObjects(try nativeObject(objc.send(?Object, list, "accessibilitySelectedChildren", .{})), &.{chosen});
    try arrayObjects(try nativeObject(objc.send(?Object, list, "accessibilityRows", .{})), &.{ chosen, unchosen });
    try arrayObjects(try nativeObject(objc.send(?Object, list, "accessibilitySelectedRows", .{})), &.{chosen});
    try require(objc.send(objc.BOOL, chosen, "isAccessibilitySelected", .{}) == 1);
    try require(objc.send(objc.BOOL, unchosen, "isAccessibilitySelected", .{}) == 0);
    try expectString(objc.send(?Object, custom, "accessibilityRoleDescription", .{}), "Fixture control");
    inline for (.{ .{ "AXBrailleLabel", "点\x00字" }, .{ "AXBrailleRoleDescription", "Braille role" }, .{ "AXDOMIdentifier", "dom-fixture" } }) |attribute| {
        const key = try foundation.string(attribute[0]);
        defer objc.release(key);
        try expectString(objc.send(?Object, custom, "accessibilityAttributeValue:", .{key}), attribute[1]);
        try require(objc.send(?Object, sparse, "accessibilityAttributeValue:", .{key}) == null);
    }
    try require(objc.send(?Object, sparse, "accessibilityValue", .{}) == null);
    try require(objc.send(?Object, sparse, "accessibilityMinValue", .{}) == null);
    try require(objc.send(?Object, sparse, "accessibilityMaxValue", .{}) == null);
    try require(objc.send(?Object, sparse, "accessibilityTitle", .{}) == null);
    try require(objc.send(?Object, sparse, "accessibilitySubrole", .{}) == null);
    try writer.writeAll("fields NSString=NUL-preserving NSNumber=0 NSArray=8,9 selected=8 " ++
        "sparse=nil braille=present-and-absent\n");
    try verifyText(writer, text, false);
}

fn verifyGeometry(writer: *std.Io.Writer, view: Object, window: Object) Error!void {
    const factor = objc.send(f64, window, "backingScaleFactor", .{});
    try require(factor > 0);
    try require(objc.send(objc.BOOL, view, "isFlipped", .{}) != 0);
    const local: objc.NSRect = .{
        .origin = .{ .x = 20 / factor, .y = 20 / factor },
        .size = .{ .width = 80 / factor, .height = 30 / factor },
    };
    const in_window = objc.send(objc.NSRect, view, "convertRect:toView:", .{ local, @as(?Object, null) });
    const expected = objc.send(objc.NSRect, window, "convertRectToScreen:", .{in_window});
    const button = try find(view, 2);
    const actual = objc.send(objc.NSRect, button, "accessibilityFrame", .{});
    try expectRect(actual, expected);
    const value = try foundation.valueRect(actual);
    defer objc.release(value);
    try expectClass(value, "NSValue");
    try expectRect(objc.send(objc.NSRect, value, "rectValue", .{}), expected);
    const point: objc.NSPoint = .{
        .x = expected.origin.x + expected.size.width / 2,
        .y = expected.origin.y + expected.size.height / 2,
    };
    try require(objc.send(?Object, view, "accessibilityHitTest:", .{point}) == button);
    try require(objc.send(?Object, view, "accessibilityFocusedUIElement", .{}) == button);
    try require(objc.send(?Object, window, "accessibilityFocusedUIElement", .{}) == button);
    const text = try find(view, 4);
    const character_local: objc.NSRect = .{
        .origin = .{ .x = 120 / factor, .y = 20 / factor },
        .size = .{ .width = 10 / factor, .height = 10 / factor },
    };
    const character_window = objc.send(objc.NSRect, view, "convertRect:toView:", .{ character_local, @as(?Object, null) });
    const character_screen = objc.send(objc.NSRect, window, "convertRectToScreen:", .{character_window});
    try expectRect(objc.send(objc.NSRect, text, "accessibilityFrameForRange:", .{objc.NSRange{ .location = 0, .length = 1 }}), character_screen);
    try expectRange(objc.send(objc.NSRange, text, "accessibilityRangeForPosition:", .{objc.NSPoint{
        .x = character_screen.origin.x + character_screen.size.width / 4,
        .y = character_screen.origin.y + character_screen.size.height / 2,
    }}), .{ .location = 0, .length = 1 });
    try writer.print("geometry flipped=true scale={d} NSValue.rect={d},{d},{d},{d} " ++
        "focus-window=contentView=node-2 hit=node-2\n", .{
        factor,              expected.origin.x,    expected.origin.y,
        expected.size.width, expected.size.height,
    });
}

fn verifyActions(writer: *std.Io.Writer, host: *Host, view: Object, adapter: *Adapter, failing: *std.testing.FailingAllocator) Error!void {
    const button = try find(view, 2);
    const slider = try find(view, 3);
    const text = try find(view, 4);
    const chosen = try find(view, 8);
    try require(objc.send(objc.BOOL, button, "accessibilityPerformPress", .{}) != 0);
    try require(objc.send(objc.BOOL, slider, "accessibilityPerformIncrement", .{}) != 0);
    try require(objc.send(objc.BOOL, slider, "accessibilityPerformDecrement", .{}) != 0);
    const zero = try foundation.number(0);
    defer objc.release(zero);
    objc.send(void, slider, "setAccessibilityValue:", .{zero});
    const embedded = try foundation.string("set🙂\x00tail");
    defer objc.release(embedded);
    const before_failure = host.action_count;
    failing.fail_index = failing.alloc_index;
    defer failing.fail_index = std.math.maxInt(usize);
    objc.send(void, text, "setAccessibilityValue:", .{embedded});
    try require(host.action_count == before_failure);
    try require(adapter.context.takeSelectorError() == error.OutOfMemory);
    try require(adapter.context.takeSelectorError() == null);
    failing.fail_index = std.math.maxInt(usize);
    objc.send(void, text, "setAccessibilityValue:", .{embedded});
    try require(host.action_count == before_failure + 1);
    try require(adapter.context.takeSelectorError() == null);
    try writer.writeAll("selector setAccessibilityValue: OutOfMemory exact no-action consumed retry=ok\n");
    objc.send(void, text, "setAccessibilitySelectedTextRange:", .{objc.NSRange{ .location = 1, .length = 4 }});
    objc.send(void, button, "setAccessibilityFocused:", .{@as(objc.BOOL, 1)});
    try require(objc.send(objc.BOOL, chosen, "accessibilityPerformPick", .{}) != 0);
    if (host.callback_error) |err| return err;
    try require(host.action_count == 8);
    const expected_actions = [_]schema.Action{
        .click,              .increment, .decrement, .set_value, .set_value,
        .set_text_selection, .focus,     .click,
    };
    const expected_targets = [_]u64{ 2, 3, 3, 3, 4, 4, 2, 8 };
    for (host.actions[0..host.action_count], 0..) |capture, index| {
        try require(capture.action == expected_actions[index]);
        try require(capture.target.value == expected_targets[index]);
        try require(std.mem.eql(u8, &capture.tree.bytes, &schema.tree_id_root.bytes));
        try writer.print("action order={d} tag={s} target={d}", .{
            index, @tagName(capture.action), capture.target.value,
        });
        switch (capture.payload) {
            .none => {
                try require(index != 3 and index != 4 and index != 5);
                try writer.writeAll(" payload=none\n");
            },
            .number => |number| {
                try require(index == 3);
                try require(number == 0);
                try writer.print(" numeric={d}\n", .{number});
            },
            .value => |value| {
                try require(index == 4);
                try require(std.mem.eql(u8, value.bytes[0..value.count], "set🙂\x00tail"));
                try writer.print(" value_len={d} value_hex={x}\n", .{ value.count, value.bytes[0..value.count] });
            },
            .selection => |selection| {
                try require(index == 5);
                try require(selection.anchor.node_id.value == 5);
                try require(selection.anchor.character_index == 1);
                try require(selection.focus.node_id.value == 6);
                try require(selection.focus.character_index == 1);
                try writer.print(" anchor={d}:{d} focus={d}:{d}\n", .{
                    selection.anchor.node_id.value, selection.anchor.character_index,
                    selection.focus.node_id.value,  selection.focus.character_index,
                });
            },
        }
    }
}

fn expectDefunct(object: Object) Error!void {
    try require(objc.send(?Object, object, "accessibilityIdentifier", .{}) == null);
    try require(objc.send(?Object, object, "accessibilityTitle", .{}) == null);
    try require(objc.send(?Object, object, "accessibilityValue", .{}) == null);
    try require(objc.send(?Object, object, "accessibilityChildren", .{}) == null);
    try require(objc.send(objc.BOOL, object, "isAccessibilityElement", .{}) == 0);
    try expectRect(objc.send(objc.NSRect, object, "accessibilityFrame", .{}), .{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 0, .height = 0 } });
    try expectRange(objc.send(objc.NSRange, object, "accessibilitySelectedTextRange", .{}), .{ .location = 0, .length = 0 });
    try require(objc.send(isize, object, "accessibilityNumberOfCharacters", .{}) == 0);
    try expectString(objc.send(?Object, object, "accessibilityRole", .{}), "AXUnknown");
}

fn verifyFaults(gpa: std.mem.Allocator, writer: *std.Io.Writer, adapter: *Adapter, host: *Host, view: Object, failing: *std.testing.FailingAllocator, original: *Frame, changed: *Frame) Error!void {
    host.full = &original.full;
    try committed(adapter.updateIfActiveBorrowedChecked(&original.full, .{ .context = host, .get = Host.supply }), false);
    const old_button = try find(view, 2);
    var invalid = try Frame.init(gpa, true, false);
    defer invalid.deinit(gpa);
    try schema.ids_props.setChildren(&invalid.full.nodes.items[0].node.properties, &.{ .{ .value = 2 }, .{ .value = 2 }, .{ .value = 3 }, .{ .value = 4 }, .{ .value = 7 }, .{ .value = 10 }, .{ .value = 11 } });
    host.full = &invalid.full;
    switch (adapter.updateIfActiveBorrowedChecked(&invalid.full, .{ .context = host, .get = Host.supply })) {
        .rejected => |err| try require(err == error.DuplicateChild),
        .committed, .inactive => return error.NativeProofFailed,
    }
    try require(try find(view, 2) == old_button);
    try expectString(objc.send(?Object, old_button, "accessibilityTitle", .{}), "Invoke 🙂\x00button");
    try verifyText(writer, try find(view, 4), false);
    try writer.writeAll("rejection DuplicateChild old-native-identity-and-text=unchanged\n");
    var rejected_count: usize = 0;
    var postcommit_failure = false;
    const bound = 2048;
    for (0..bound) |index| {
        host.full = &original.full;
        try committed(adapter.updateIfActiveBorrowedChecked(&original.full, .{ .context = host, .get = Host.supply }), false);
        host.full = &changed.full;
        var entries = [_]schema.NodeEntry{
            changed.full.nodes.items[1], changed.full.nodes.items[3],
            changed.full.nodes.items[9],
        };
        const delta = changed.delta(&entries);
        failing.fail_index = failing.alloc_index + index;
        const outcome = adapter.prepareUpdateIfActiveBorrowedChecked(&delta, .{ .context = host, .get = Host.supply });
        failing.fail_index = std.math.maxInt(usize);
        switch (outcome) {
            .inactive => return error.NativeProofFailed,
            .rejected => |err| {
                try require(err == error.OutOfMemory);
                rejected_count += 1;
                host.full = &original.full;
                try require(try find(view, 2) == old_button);
                try expectString(objc.send(?Object, old_button, "accessibilityTitle", .{}), "Invoke 🙂\x00button");
                try expectRange(objc.send(objc.NSRange, try find(view, 4), "accessibilitySelectedTextRange", .{}), .{ .location = 1, .length = 4 });
            },
            .committed => |accepted| {
                // Accepted bookkeeping precedes inspection of notification failure.
                host.full = &changed.full;
                defer if (accepted.events) |queue| queue.deinit();
                try require(!accepted.used_full_tree);
                try expectString(objc.send(?Object, old_button, "accessibilityTitle", .{}), "Changed 🙂\x00button");
                try expectRange(objc.send(objc.NSRange, try find(view, 4), "accessibilitySelectedTextRange", .{}), .{ .location = 3, .length = 0 });
                if (accepted.notification_error) |err| {
                    try require(err == error.OutOfMemory);
                    postcommit_failure = true;
                    try writer.print("postcommit OutOfMemory fail_offset={d} " ++
                        "accepted-native-label-and-caret baseline=current-full\n", .{index});
                    break;
                }
            },
        }
    }
    try require(rejected_count != 0);
    if (!postcommit_failure) return error.FaultBoundExceeded;
    try writer.print("precommit OOM cases={d} old-getters=unchanged retry=accepted\n", .{rejected_count});
    host.full = &original.full;
    try committed(adapter.updateIfActiveBorrowedChecked(&original.full, .{ .context = host, .get = Host.supply }), false);
}

fn inspectQueue(writer: *std.Io.Writer, queue: *macos.NativeNotifications, destroyed: Object) Error!void {
    var saw_destroyed = false;
    var saw_announcement = false;
    try require(queue.items.items.len <= 64);
    for (queue.items.items, 0..) |event, index| switch (event) {
        .notification => |notification| {
            try expectClass(notification.target, "NSAccessibilityElement");
            try writer.print("queued order={d} target=0x{x} literal={s}\n", .{ index, @intFromPtr(notification.target), notification.name });
            if (std.mem.eql(u8, notification.name, "AXUIElementDestroyed")) {
                if (notification.target == destroyed) saw_destroyed = true;
            }
        },
        .announcement => |announcement| {
            try require(std.mem.eql(u8, announcement.text, "Changed custom 窓\x00tail"));
            saw_announcement = true;
            try writer.print("queued order={d} announcement_len={d} announcement_hex={x} priority={d}\n", .{ index, announcement.text.len, announcement.text, announcement.priority });
        },
    };
    try require(saw_destroyed);
    try require(saw_announcement);
}

fn runNative(gpa: std.mem.Allocator, writer: *std.Io.Writer) Error!void {
    var cleanup_error: ?macos.CloseError = null;
    runNativeOwned(gpa, writer, &cleanup_error) catch |err| {
        // A close failure must survive cleanup and reach main's owned failure writer.
        return cleanup_error orelse err;
    };
}

fn runNativeOwned(
    gpa: std.mem.Allocator,
    writer: *std.Io.Writer,
    cleanup_error: *?macos.CloseError,
) Error!void {
    var authority: Authority = .{ .threaded = .init(gpa, .{}) };
    var transferred = false;
    defer if (!transferred) authority.threaded.deinit();
    var failing: std.testing.FailingAllocator = .init(gpa, .{ .resize_fail_index = 0 });
    const adapter_gpa = failing.allocator();
    var pool = try objc.AutoreleasePool.init();
    var pool_live = true;
    defer if (pool_live) pool.deinit();
    try require(foundation.isMainThread());
    const application_class = objc.getClass("NSApplication") orelse
        return error.ObjectiveCUnavailable;
    const application = try nativeObject(objc.send(?Object, application_class, "sharedApplication", .{}));
    objc.send(void, application, "finishLaunching", .{});
    const window_class = try subclass("ZAccessKitSelectorClientWindow", "NSWindow", false);
    try macos.patch.installFocusForwarderForClass(gpa, window_class);
    const view_class = try subclass("ZAccessKitSelectorClientFlippedView", "NSView", true);
    const window = try nativeObject(objc.send(?Object, try allocate(window_class), "init", .{}));
    var held_window: ?Object = window;
    defer if (held_window) |object| objc.release(object);
    objc.send(void, window, "setReleasedWhenClosed:", .{@as(objc.BOOL, 0)});
    objc.send(void, window, "setFrame:display:", .{
        objc.NSRect{ .origin = .{ .x = 100, .y = 100 }, .size = .{ .width = 400, .height = 300 } }, @as(objc.BOOL, 0),
    });
    const view = try nativeObject(objc.send(?Object, try allocate(view_class), "initWithFrame:", .{objc.NSRect{ .origin = .{ .x = 0, .y = 0 }, .size = .{ .width = 400, .height = 300 } }}));
    var held_view: ?Object = view;
    defer if (held_view) |object| objc.release(object);
    objc.send(void, window, "setContentView:", .{view});
    objc.send(void, window, "orderOut:", .{@as(?Object, null)});
    try require(objc.send(objc.BOOL, window, "isVisible", .{}) == 0);
    var original = try Frame.init(gpa, false, false);
    defer original.deinit(gpa);
    var changed = try Frame.init(gpa, true, false);
    defer changed.deinit(gpa);
    var removed = try Frame.init(gpa, true, true);
    defer removed.deinit(gpa);
    const host = try gpa.create(Host);
    var host_live = true;
    defer if (host_live) gpa.destroy(host);
    host.* = .{ .full = &original.full };
    const adapter = try Adapter.create(adapter_gpa, authority.threaded.io(), .{
        .action_handler = Host.action,
        .userdata = host,
        .activation_sink = .{ .native = .{ .callback = Host.activation, .userdata = host } },
        .runtime_release = .{ .userdata = &authority, .release = Authority.release },
    });
    transferred = true;
    var adapter_live = true;
    var adapter_closed = false;
    defer if (adapter_live) {
        if (!adapter_closed) adapter.close() catch |err| {
            cleanup_error.* = err;
        };
        adapter.deinit();
    };
    try adapter.attach(.{ .window = window }, true);
    try require(objc.object_getClass(view) != view_class);
    inline for (.{ "superclass", "accessibilityChildren", "accessibilityFocusedUIElement", "accessibilityHitTest:" }) |selector| {
        try require(objc.send(objc.BOOL, view, "respondsToSelector:", .{objc.sel(selector)}) != 0);
    }
    try require(objc.send(?objc.Class, view, "superclass", .{}) ==
        objc.class_getSuperclass(view_class));
    const inactive_delta = original.delta(original.full.nodes.items[2..3]);
    switch (adapter.updateIfActiveBorrowedChecked(&inactive_delta, .{ .context = host, .get = Host.supply })) {
        .inactive => {},
        .committed, .rejected => return error.NativeProofFailed,
    }
    try require(host.supplier_count == 0);
    const placeholder = objc.retain(try nativeObject(objc.send(?Object, view, "accessibilityHitTest:", .{objc.NSPoint{ .x = 100, .y = 100 }})));
    var held_placeholder: ?Object = placeholder;
    defer if (held_placeholder) |object| objc.release(object);
    try require(host.activation_count == 1);
    try require(adapter.isActive());
    failing.fail_index = failing.alloc_index;
    const initial_failure = adapter.updateIfActiveBorrowedChecked(&inactive_delta, .{ .context = host, .get = Host.supply });
    failing.fail_index = std.math.maxInt(usize);
    switch (initial_failure) {
        .rejected => |err| try require(err == error.OutOfMemory),
        .committed, .inactive => return error.NativeProofFailed,
    }
    try require(host.activation_count == 1);
    try committed(adapter.updateIfActiveBorrowedChecked(&inactive_delta, .{ .context = host, .get = Host.supply }), true);
    try require(host.supplier_count == 2);
    const published_root = try nativeObject(objc.send(?Object, view, "accessibilityHitTest:", .{objc.NSPoint{ .x = -10000, .y = -10000 }}));
    try require(published_root != placeholder);
    try expectString(objc.send(?Object, published_root, "accessibilityIdentifier", .{}), "node-1");
    try expectDefunct(placeholder);
    try writer.writeAll("activation full=root0,button2,slider3,text4,runs5,6,list7,items8,9," ++
        "custom10,sparse11 inactive-supplier=0 OOM-retry-full=true " ++
        "same-id-placeholder=permanently-defunct-and-distinct\n");
    inline for (.{ 2, 3, 4, 7, 8, 9, 10, 11 }) |id|
        try verifySelectors(writer, try find(view, id), id);
    try verifyFields(writer, view, window);
    try verifyGeometry(writer, view, window);
    try verifyActions(writer, host, view, adapter, &failing);
    var changed_entries = [_]schema.NodeEntry{
        changed.full.nodes.items[1], changed.full.nodes.items[3],
        changed.full.nodes.items[9],
    };
    const active_delta = changed.delta(&changed_entries);
    host.full = &changed.full;
    const supplier_before_delta = host.supplier_count;
    try committed(adapter.updateIfActiveBorrowedChecked(&active_delta, .{ .context = host, .get = Host.supply }), false);
    try require(host.supplier_count == supplier_before_delta);
    try verifyText(writer, try find(view, 4), true);
    try verifyFaults(gpa, writer, adapter, host, view, &failing, &original, &changed);
    const old_button = objc.retain(try find(view, 2));
    var held_button: ?Object = old_button;
    defer if (held_button) |object| objc.release(object);
    host.full = &removed.full;
    var removal_entries = [_]schema.NodeEntry{
        removed.full.nodes.items[0], removed.full.nodes.items[2],
        removed.full.nodes.items[8],
    };
    const removal = removed.delta(&removal_entries);
    const queue = (try prepared(adapter.prepareUpdateIfActiveBorrowedChecked(&removal, .{ .context = host, .get = Host.supply }), false)) orelse
        return error.NativeProofFailed;
    var held_queue: ?*macos.NativeNotifications = queue;
    defer if (held_queue) |owned| owned.deinit();
    try expectDefunct(old_button);
    try require(adapter.context.takeSelectorError() == null);
    try inspectQueue(writer, queue, old_button);
    try schema.strings.setLabel(&removed.full.nodes.items[8].node.properties, "Producer storage changed after queue preparation");
    try inspectQueue(writer, queue, old_button);
    host.full = &original.full;
    try committed(adapter.updateIfActiveBorrowedChecked(&original.full, .{ .context = host, .get = Host.supply }), false);
    const new_button = try find(view, 2);
    try require(new_button != old_button);
    try expectString(objc.send(?Object, new_button, "accessibilityTitle", .{}), "Invoke 🙂\x00button");
    try inspectQueue(writer, queue, old_button);
    try queue.raise();
    try require(try find(view, 2) == new_button);
    try expectString(objc.send(?Object, new_button, "accessibilityTitle", .{}), "Invoke 🙂\x00button");
    try writer.writeAll("active-ID-reuse old=defunct-while-removed new-object=distinct " ++
        "late-old-target-post=current-native-map-unchanged\n");
    const joined = closeJoiningCallback(adapter, host, new_button) catch |err| {
        adapter_closed = !adapter.isActive();
        return err;
    };
    adapter_closed = true;
    try require(joined);
    const selector_context = adapter.context;
    adapter.deinit();
    adapter_live = false;
    // Callback userdata is deliberately gone before retained native SDK queries.
    const actions_before_closed_queries = host.action_count;
    try require(actions_before_closed_queries == 9);
    try require(host.actions[8].action == .click);
    try require(host.actions[8].target.value == 2);
    try writer.writeAll("action order=8 tag=click target=2 payload=none " ++
        "close=joined-parked-native-callback-before-userdata-free\n");
    gpa.destroy(host);
    host_live = false;
    try require(objc.object_getClass(view) == view_class);
    try require(authority.releases == 0);
    try expectDefunct(new_button);
    try expectDefunct(old_button);
    try expectDefunct(placeholder);
    try require(objc.send(objc.BOOL, new_button, "accessibilityPerformPress", .{}) == 0);
    const closed_value = try foundation.string("must-not-touch-freed-userdata");
    defer objc.release(closed_value);
    objc.send(void, new_button, "setAccessibilityValue:", .{closed_value});
    try require(selector_context.takeSelectorError() == null);
    try writer.print("closed SDK actions return defunct callback-count-before-close={d}\n", .{actions_before_closed_queries});
    try inspectQueue(writer, queue, old_button);
    try queue.raise();
    queue.deinit();
    held_queue = null;
    try writer.writeAll("close userdata=freed retained-queries=defunct " ++
        "view-isa=restored queue-post=actual-AppKit-returned old-target=preserved\n");
    objc.release(placeholder);
    held_placeholder = null;
    objc.send(void, window, "close", .{});
    objc.release(view);
    held_view = null;
    objc.release(window);
    held_window = null;
    pool.deinit();
    pool_live = false;
    try require(authority.releases == 0);
    objc.release(old_button);
    held_button = null;
    try require(authority.releases == 1);
    try writer.writeAll("runtime authority release=1 after-final-ObjC-release Io=alive-after-close\n");
}
