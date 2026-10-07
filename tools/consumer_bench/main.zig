const std = @import("std");
const kit = @import("zaccesskit");
const schema = kit.schema;
const consumer = kit.consumer;
const Tree = consumer.tree.Tree;
const NodeRef = consumer.node_id.NodeRef;
const Counter = @import("counter.zig").Counter;
const node_count_max: u32 = 65536;
const work_unit_count_max: u32 = 65536;
const argument_count_max: usize = 11;
const label_byte_count: usize = 32;
const branching_factor: u32 = 8;
const stable_description = "consumer-bench-stable-description";
const Workload = enum { snapshot, update };
const Shape = enum { balanced, wide };
const Options = struct {
    workload: Workload = .snapshot,
    shape: Shape = .balanced,
    nodes: u32 = 64,
    work_units: u32 = 256,
    update_nodes: u32 = 1,
    count_allocations: bool = false,
};
const BenchError = error{ InvalidArguments, InvalidState, CallbackMismatch, AllocationLeak };
const RunError = BenchError || consumer.tree.UpdateError;
const MainError = RunError || std.process.Args.ToSliceError || std.Io.Writer.Error;
const Result = struct {
    input_digest: u64,
    output_digest: u64,
    completed_work_units: u64,
    label_changes: u64 = 0,
    focus_moves: u64 = 0,
};

pub fn main(init: std.process.Init) MainError!void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try parseOptions(args[1..]);
    var counter: Counter = .{ .child = init.gpa };
    const gpa = if (options.count_allocations) counter.allocator() else init.gpa;
    const result = try run(gpa, options);
    if (counter.stats.live_bytes != 0) return error.AllocationLeak;
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &file_writer.interface;
    try writer.print(
        "scope=synthetic-main-semantic-core native_bus=false workload={s} shape={s} " ++
            "nodes={d} work_units={d} update_nodes={d} label_bytes={d} " ++
            "output_mode={s} input_digest={x:0>16} output_digest={x:0>16} " ++
            "completed_work_units={d} label_changes={d} focus_moves={d}\n",
        .{
            @tagName(options.workload),                                @tagName(options.shape), options.nodes,
            options.work_units,                                        options.update_nodes,    label_byte_count,
            if (options.count_allocations) "allocations" else "plain", result.input_digest,     result.output_digest,
            result.completed_work_units,                               result.label_changes,    result.focus_moves,
        },
    );
    try writer.print(
        "allocations_enabled={} successful_allocations={d} successful_resizes={d} " ++
            "successful_remaps={d} frees={d} requested_bytes={d} live_bytes={d} peak_bytes={d}\n",
        .{
            options.count_allocations, counter.stats.allocations, counter.stats.resizes,
            counter.stats.remaps,      counter.stats.frees,       counter.stats.requested_bytes,
            counter.stats.live_bytes,  counter.stats.peak_bytes,
        },
    );
    try writer.flush();
}

fn validateOptions(options: Options) BenchError!void {
    if (options.nodes == 0 or options.nodes > node_count_max) return error.InvalidArguments;
    if (options.work_units == 0 or options.work_units > work_unit_count_max)
        return error.InvalidArguments;
    if (options.update_nodes != 1 and options.update_nodes != 64) return error.InvalidArguments;
    if (options.workload == .update and options.nodes <= options.update_nodes)
        return error.InvalidArguments;
}

fn parseOptions(args: []const []const u8) BenchError!Options {
    if (args.len > argument_count_max) return error.InvalidArguments;
    var options: Options = .{};
    var seen: u8 = 0;
    var index: usize = 0;
    for (0..argument_count_max) |_| {
        if (index == args.len) {
            try validateOptions(options);
            return options;
        }
        const option = args[index];
        const slot: u3 = option_slot: {
            if (std.mem.eql(u8, option, "--workload")) break :option_slot 0;
            if (std.mem.eql(u8, option, "--shape")) break :option_slot 1;
            if (std.mem.eql(u8, option, "--nodes")) break :option_slot 2;
            if (std.mem.eql(u8, option, "--work-units")) break :option_slot 3;
            if (std.mem.eql(u8, option, "--update-nodes")) break :option_slot 4;
            if (std.mem.eql(u8, option, "--count-allocations")) break :option_slot 5;
            return error.InvalidArguments;
        };
        const mask = @as(u8, 1) << slot;
        if (seen & mask != 0) return error.InvalidArguments;
        seen |= mask;
        index += 1;
        if (slot == 5) {
            options.count_allocations = true;
            continue;
        }
        if (index == args.len) return error.InvalidArguments;
        const value = args[index];
        index += 1;
        switch (slot) {
            0 => options.workload = std.meta.stringToEnum(Workload, value) orelse
                return error.InvalidArguments,
            1 => options.shape = std.meta.stringToEnum(Shape, value) orelse
                return error.InvalidArguments,
            2 => options.nodes = try parseNumber(value),
            3 => options.work_units = try parseNumber(value),
            4 => options.update_nodes = try parseNumber(value),
            else => return error.InvalidArguments,
        }
    }
    return error.InvalidArguments;
}

fn parseNumber(bytes: []const u8) BenchError!u32 {
    if (bytes.len == 0 or bytes.len > 5) return error.InvalidArguments;
    for (bytes) |byte| {
        if (byte < '0' or byte > '9') return error.InvalidArguments;
    }
    return std.fmt.parseInt(u32, bytes, 10) catch return error.InvalidArguments;
}

const LabelOptions = struct { id: u32, changed: bool };

fn labelBytes(options: LabelOptions) [label_byte_count]u8 {
    var bytes = [_]u8{'-'} ** label_byte_count;
    bytes[0] = if (options.changed) 'B' else 'A';
    const hexadecimal = "0123456789abcdef";
    for (0..8) |index| {
        const shift: u5 = @intCast(index * 4);
        bytes[index + 1] = hexadecimal[(options.id >> shift) & 15];
    }
    return bytes;
}

fn childIds(options: Options, ids: []const schema.NodeId, id: u32) []const schema.NodeId {
    if (options.shape == .wide) return if (id == 1) ids[1..] else ids[0..0];
    const first_index = (id - 1) * branching_factor + 1;
    if (first_index >= options.nodes) return ids[0..0];
    return ids[first_index..@min(first_index + branching_factor, options.nodes)];
}

fn makeNode(
    gpa: std.mem.Allocator,
    options: Options,
    ids: []const schema.NodeId,
    label_options: LabelOptions,
) std.mem.Allocator.Error!schema.Node {
    var node = schema.Node.init(gpa, if (label_options.id == 1) .window else .button);
    errdefer node.deinit();
    node.addAction(.focus);
    const label = labelBytes(label_options);
    try schema.strings.setLabel(&node.properties, &label);
    try schema.strings.setDescription(&node.properties, stable_description);
    const children = childIds(options, ids, label_options.id);
    if (children.len != 0) try schema.ids_props.setChildren(&node.properties, children);
    return node;
}

const UpdateOptions = struct { initial: bool, changed: bool };

fn makeUpdate(
    gpa: std.mem.Allocator,
    options: Options,
    ids: []const schema.NodeId,
    update_options: UpdateOptions,
) std.mem.Allocator.Error!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{};
    errdefer update.deinit(gpa);
    if (update_options.initial) update.tree = schema.TreeInfo.init(ids[0]);
    update.focus = ids[if (update_options.changed) 1 else 0];
    const count = if (update_options.initial) options.nodes else options.update_nodes;
    for (0..count) |index| {
        const id: u32 = @intCast(index + if (update_options.initial) @as(usize, 1) else 2);
        const node = try makeNode(gpa, options, ids, .{
            .id = id,
            .changed = update_options.changed,
        });
        // pushNode owns the node even when its array allocation fails.
        try update.pushNode(gpa, .{ .value = id }, node);
    }
    return update;
}

// FNV-1a consumes explicit little-endian integers and length-tagged byte fields.
// It does not consume padding, pointers, or map iteration order.
const Digest = struct {
    value: u64 = 14695981039346656037,

    fn number(self: *Digest, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        for (bytes) |byte| self.value = (self.value ^ byte) *% 1099511628211;
    }

    fn field(self: *Digest, bytes: []const u8) void {
        self.number(bytes.len);
        for (bytes) |byte| self.value = (self.value ^ byte) *% 1099511628211;
    }
};

fn validateState(
    tree: *const Tree,
    options: Options,
    ids: []const schema.NodeId,
    changed: bool,
) BenchError!u64 {
    const state = tree.stateOf();
    if (state.rootId().local.value != 1 or @intFromEnum(state.rootId().tree_index) != 0)
        return error.InvalidState;
    if (state.nodes.count() != options.nodes) return error.InvalidState;
    const focus = state.focusId() orelse return error.InvalidState;
    if (focus.local.value != (if (changed) @as(u64, 2) else 1))
        return error.InvalidState;
    if (@intFromEnum(focus.tree_index) != 0) return error.InvalidState;
    var digest: Digest = .{};
    digest.field("zaccesskit-consumer-state-v1");
    digest.number(options.nodes);
    digest.number(state.rootId().local.value);
    digest.number(focus.local.value);
    for (0..options.nodes) |index| {
        const id: u32 = @intCast(index + 1);
        const node = state.nodeByTreeLocalId(ids[index], schema.tree_id_root) orelse
            return error.InvalidState;
        const data = node.data();
        const expected_label = labelBytes(.{
            .id = id,
            .changed = changed and id > 1 and id <= options.update_nodes + 1,
        });
        const label = schema.strings.label(&data.properties) orelse return error.InvalidState;
        if (!std.mem.eql(u8, label, &expected_label)) return error.InvalidState;
        const description = schema.strings.description(&data.properties) orelse
            return error.InvalidState;
        if (!std.mem.eql(u8, description, stable_description)) return error.InvalidState;
        const expected_role: schema.Role = if (id == 1) .window else .button;
        if (data.role != expected_role) return error.InvalidState;
        if (data.actions != schema.actionMask(.focus)) return error.InvalidState;
        if (data.child_actions != 0 or data.flags != 0) return error.InvalidState;
        const children = schema.ids_props.children(&data.properties);
        const expected_children = childIds(options, ids, id);
        if (children.len != expected_children.len) return error.InvalidState;
        if (data.properties.count() != (if (children.len == 0) @as(usize, 2) else 3))
            return error.InvalidState;
        digest.number(id);
        digest.number(@intFromEnum(data.role));
        digest.number(data.actions);
        digest.number(data.child_actions);
        digest.number(data.flags);
        digest.field(label);
        digest.field(description);
        digest.number(children.len);
        for (children, expected_children) |child, expected| {
            if (child.value != expected.value) return error.InvalidState;
            digest.number(child.value);
        }
        if (id == 1) {
            if (node.state.parent_and_index != null) return error.InvalidState;
            digest.number(0);
            digest.number(0);
        } else {
            const parent = node.state.parent_and_index orelse return error.InvalidState;
            const expected_parent = if (options.shape == .wide) 1 else @divFloor(id - 2, branching_factor) + 1;
            const expected_index = if (options.shape == .wide) id - 2 else (id - 2) % branching_factor;
            if (parent.parent_id.local.value != expected_parent) return error.InvalidState;
            if (@intFromEnum(parent.parent_id.tree_index) != 0) return error.InvalidState;
            if (parent.index != expected_index) return error.InvalidState;
            digest.number(parent.parent_id.local.value);
            digest.number(parent.index);
        }
    }
    return digest.value;
}

const Handler = struct {
    label_changes: u64 = 0,
    focus_moves: u64 = 0,
    failure: ?BenchError = null,
    expected_changed: bool = false,
    update_nodes: u32,

    fn slots(self: *Handler) consumer.tree.TreeChangeHandler {
        return .{
            .ptr = self,
            .node_added = unexpectedNode,
            .node_removed = unexpectedNode,
            .node_updated = changedNode,
            .focus_moved = movedFocus,
        };
    }

    fn unexpectedNode(ptr: *anyopaque, node: NodeRef) void {
        const self: *Handler = @ptrCast(@alignCast(ptr));
        _ = node;
        self.failure = error.CallbackMismatch;
    }

    fn changedNode(ptr: *anyopaque, old: NodeRef, new: NodeRef) void {
        const self: *Handler = @ptrCast(@alignCast(ptr));
        if (old.id().local.value != new.id().local.value) {
            self.failure = error.CallbackMismatch;
            return;
        }
        const old_label = schema.strings.label(&old.data().properties) orelse {
            self.failure = error.CallbackMismatch;
            return;
        };
        const new_label = schema.strings.label(&new.data().properties) orelse {
            self.failure = error.CallbackMismatch;
            return;
        };
        // Focus moves also report unchanged nodes. They are not property rewrites.
        if (std.mem.eql(u8, old_label, new_label)) return;
        const id = new.id().local.value;
        if (id <= 1 or id > self.update_nodes + 1) {
            self.failure = error.CallbackMismatch;
            return;
        }
        const expected_new = labelBytes(.{ .id = @intCast(id), .changed = self.expected_changed });
        const expected_old = labelBytes(.{ .id = @intCast(id), .changed = !self.expected_changed });
        if (!std.mem.eql(u8, new_label, &expected_new) or
            !std.mem.eql(u8, old_label, &expected_old))
        {
            self.failure = error.CallbackMismatch;
            return;
        }
        self.label_changes += 1;
    }

    fn movedFocus(ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void {
        const self: *Handler = @ptrCast(@alignCast(ptr));
        const previous = old orelse {
            self.failure = error.CallbackMismatch;
            return;
        };
        const next = new orelse {
            self.failure = error.CallbackMismatch;
            return;
        };
        const expected_next: u64 = if (self.expected_changed) 2 else 1;
        const expected_previous: u64 = if (self.expected_changed) 1 else 2;
        if (previous.id().local.value != expected_previous or next.id().local.value != expected_next) {
            self.failure = error.CallbackMismatch;
            return;
        }
        self.focus_moves += 1;
    }
};

fn run(gpa: std.mem.Allocator, options: Options) RunError!Result {
    try validateOptions(options);
    const ids = try gpa.alloc(schema.NodeId, options.nodes);
    defer gpa.free(ids);
    for (ids, 0..) |*id, index| id.* = .{ .value = index + 1 };
    var input_digest: Digest = .{};
    input_digest.field("zaccesskit-consumer-input-v1");
    input_digest.field(@tagName(options.workload));
    input_digest.field(@tagName(options.shape));
    input_digest.number(options.nodes);
    input_digest.number(options.work_units);
    input_digest.number(options.update_nodes);
    input_digest.number(label_byte_count);
    var output_digest: Digest = .{};
    var result: Result = .{
        .input_digest = 0,
        .output_digest = 0,
        .completed_work_units = 0,
    };
    switch (options.workload) {
        .snapshot => {
            for (0..options.work_units) |_| {
                const update = try makeUpdate(gpa, options, ids, .{
                    .initial = true,
                    .changed = false,
                });
                var tree = try Tree.init(gpa, update, true);
                defer tree.deinit();
                const digest = try validateState(&tree, options, ids, false);
                if (result.completed_work_units == 0) input_digest.number(digest);
                output_digest.number(digest);
                result.completed_work_units += 1;
            }
        },
        .update => {
            const initial = try makeUpdate(gpa, options, ids, .{
                .initial = true,
                .changed = false,
            });
            var tree = try Tree.init(gpa, initial, true);
            defer tree.deinit();
            input_digest.number(try validateState(&tree, options, ids, false));
            var handler: Handler = .{ .update_nodes = options.update_nodes };
            const slots = handler.slots();
            for (0..options.work_units) |index| {
                const changed = index % 2 == 0;
                handler.expected_changed = changed;
                const update = try makeUpdate(gpa, options, ids, .{
                    .initial = false,
                    .changed = changed,
                });
                const previous_changes = handler.label_changes;
                const previous_moves = handler.focus_moves;
                try tree.updateAndProcessChanges(update, &slots);
                if (handler.failure) |failure| return failure;
                if (handler.label_changes - previous_changes != options.update_nodes)
                    return error.CallbackMismatch;
                if (handler.focus_moves - previous_moves != 1) return error.CallbackMismatch;
                result.completed_work_units += 1;
            }
            output_digest.number(try validateState(&tree, options, ids, options.work_units % 2 == 1));
            result.label_changes = handler.label_changes;
            result.focus_moves = handler.focus_moves;
        },
    }
    result.input_digest = input_digest.value;
    output_digest.number(result.completed_work_units);
    output_digest.number(result.label_changes);
    output_digest.number(result.focus_moves);
    result.output_digest = output_digest.value;
    return result;
}

// These tests use the published tree rather than a workload simulator.
test "snapshot digest agrees across repetitions and allocation counting" {
    const options: Options = .{ .nodes = 64, .work_units = 2 };
    const first = try run(std.testing.allocator, options);
    const second = try run(std.testing.allocator, options);
    try std.testing.expectEqual(first.output_digest, second.output_digest);
    try std.testing.expectEqual(@as(u64, 2), first.completed_work_units);
    var counter: Counter = .{ .child = std.testing.allocator };
    const counted = try run(counter.allocator(), options);
    try std.testing.expectEqual(first.output_digest, counted.output_digest);
    try std.testing.expect(counter.stats.allocations > 0);
    try std.testing.expectEqual(@as(u64, 0), counter.stats.live_bytes);
}

test "real alternating updates report changed nodes for both shapes and sparsities" {
    for ([_]Shape{ .balanced, .wide }) |shape| {
        for ([_]u32{ 1, 64 }) |update_nodes| {
            const result = try run(std.testing.allocator, .{
                .workload = .update,
                .shape = shape,
                .nodes = 65,
                .work_units = 256,
                .update_nodes = update_nodes,
            });
            try std.testing.expectEqual(@as(u64, 256), result.completed_work_units);
            try std.testing.expectEqual(@as(u64, 256 * update_nodes), result.label_changes);
            try std.testing.expectEqual(@as(u64, 256), result.focus_moves);
        }
    }
}

test "CLI validates limits and rejects duplicate unknown or incomplete options" {
    const options = try parseOptions(&.{ "--nodes", "65536", "--work-units", "256" });
    try std.testing.expectEqual(@as(u32, 65536), options.nodes);
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{ "--nodes", "0" }));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{ "--nodes", "65537" }));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{"--nodes"}));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{ "--nodes", "64", "--nodes", "65" }));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{"--unknown"}));
    try std.testing.expectError(error.InvalidArguments, parseOptions(&.{ "--update-nodes", "2" }));
}

test "workload rejects invalid direct options before allocating" {
    try std.testing.expectError(error.InvalidArguments, run(std.testing.allocator, .{ .nodes = 0 }));
    try std.testing.expectError(error.InvalidArguments, run(std.testing.allocator, .{
        .workload = .update,
        .nodes = 64,
        .update_nodes = 64,
    }));
}

test "snapshot and update release each failed allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exerciseFailurePaths, .{});
}

fn exerciseFailurePaths(gpa: std.mem.Allocator) !void {
    _ = try run(gpa, .{ .nodes = 9, .work_units = 1 });
    _ = try run(gpa, .{ .workload = .update, .nodes = 9, .work_units = 2 });
}

test "counter tracks successful resizing and exact release" {
    var storage: [512]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var counter: Counter = .{ .child = fixed.allocator() };
    const gpa = counter.allocator();
    var bytes = try gpa.alloc(u8, 32);
    try std.testing.expect(gpa.resize(bytes, 64));
    bytes = bytes.ptr[0..64];
    try std.testing.expectEqual(@as(u64, 64), counter.stats.live_bytes);
    try std.testing.expectEqual(@as(u64, 64), counter.stats.peak_bytes);
    try std.testing.expectEqual(@as(u64, 1), counter.stats.resizes);
    gpa.free(bytes);
    try std.testing.expectEqual(@as(u64, 1), counter.stats.frees);
    try std.testing.expectEqual(@as(u64, 0), counter.stats.live_bytes);
}

test "canonical oracle rejects changed labels and matches identical semantic shapes" {
    const options: Options = .{ .nodes = 9, .work_units = 1 };
    var ids: [9]schema.NodeId = undefined;
    for (&ids, 0..) |*id, index| id.* = .{ .value = index + 1 };
    var balanced = try Tree.init(
        std.testing.allocator,
        try makeUpdate(std.testing.allocator, options, &ids, .{
            .initial = true,
            .changed = false,
        }),
        true,
    );
    defer balanced.deinit();
    const digest = try validateState(&balanced, options, &ids, false);
    var wide_options = options;
    wide_options.shape = .wide;
    // Nine nodes have identical edges in an eight-ary and a star tree.
    try std.testing.expectEqual(digest, try validateState(&balanced, wide_options, &ids, false));
    const root = balanced.state.nodes.getPtr(balanced.state.rootId()) orelse
        return error.InvalidState;
    try schema.strings.setLabel(&root.data.properties, "wrong");
    try std.testing.expectError(error.InvalidState, validateState(&balanced, options, &ids, false));
}

test "counted update frees its tree and canonical result ignores instrumentation" {
    var counter: Counter = .{ .child = std.testing.allocator };
    const options: Options = .{
        .workload = .update,
        .shape = .wide,
        .nodes = 65,
        .work_units = 3,
        .update_nodes = 64,
    };
    const plain = try run(std.testing.allocator, options);
    const counted = try run(counter.allocator(), options);
    try std.testing.expectEqual(plain.input_digest, counted.input_digest);
    try std.testing.expectEqual(plain.output_digest, counted.output_digest);
    try std.testing.expectEqual(@as(u64, 192), counted.label_changes);
    try std.testing.expectEqual(@as(u64, 3), counted.focus_moves);
    try std.testing.expectEqual(@as(u64, 0), counter.stats.live_bytes);
}
