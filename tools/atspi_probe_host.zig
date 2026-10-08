//! Mutable state and lifetime authority for the real native consumer fixture.
const std = @import("std");
const package = @import("zaccesskit");
const schema = package.schema;
const native = package.adapters.atspi;
const fixture = @import("atspi_probe_fixture.zig");
const CUpdate = package.capi.tree_update.accesskit_tree_update;

pub const edit_queue_limit = 8;
pub const edit_replacement_bytes_limit = 256;
const edit_cache_nodes_limit = 15;
pub const DrainEditError = std.mem.Allocator.Error || std.Io.Writer.Error || error{Closed};

const EditEntry = struct {
    target: u64,
    tree_index: usize,
    start_scalar: u32,
    end_scalar: u32,
    replacement: [edit_replacement_bytes_limit]u8,
    replacement_len: usize,
};

pub const Host = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    output: *std.Io.Writer,
    faults: *FaultAllocator,
    full: schema.TreeUpdate,
    model: fixture.Model = .{},
    baseline: fixture.Model = .{},
    loan_model: fixture.Model = .{},
    baseline_text: [fixture.text_bytes_limit]u8 = undefined,
    loan_text: [fixture.text_bytes_limit]u8 = undefined,
    loan_name: []const u8 = "none",
    loan_version: []const u8 = "none",
    metadata_name: []const u8 = "probe-zig",
    metadata_version: []const u8 = "1.0",
    baseline_name: []const u8 = "none",
    baseline_version: []const u8 = "none",
    c_activation: ?*CUpdate = null,
    defer_activation: bool = false,
    cache_mutex: std.Io.Mutex = .init,
    output_mutex: std.Io.Mutex = .init,
    // Lock order is edits, cache, output; output holders never acquire state locks.
    edits_mutex: std.Io.Mutex = .init,
    edit_entries: [edit_queue_limit]EditEntry = undefined,
    edit_head: usize = 0,
    edit_count: usize = 0,
    edit_queued: std.atomic.Value(u32) = .init(0),
    edit_applied: std.atomic.Value(u32) = .init(0),
    edit_rejected: std.atomic.Value(u32) = .init(0),
    edit_refused: std.atomic.Value(u32) = .init(0),
    activations: std.atomic.Value(u32) = .init(0),
    releases: std.atomic.Value(u32) = .init(0),
    c_frees: std.atomic.Value(u32) = .init(0),
    commits: std.atomic.Value(u32) = .init(0),
    rejected: std.atomic.Value(u32) = .init(0),
    actions: std.atomic.Value(u32) = .init(0),
    deactivations: std.atomic.Value(u32) = .init(0),
    late_callbacks: std.atomic.Value(u32) = .init(0),
    closed: std.atomic.Value(bool) = .init(false),
    output_failed: std.atomic.Value(bool) = .init(false),

    pub fn info(self: *Host, root: u64) schema.TreeInfo {
        return .{ .root = fixture.nodeId(root), .toolkit_name = self.metadata_name, .toolkit_version = self.metadata_version };
    }
    pub fn makeC(self: *Host, root: u64) error{OutOfMemory}!*CUpdate {
        const owner = try package.capi.tree_update.treeUpdateWithFocus(self.gpa, self.model.focus);
        errdefer package.capi.tree_update.treeUpdateFree(owner);
        owner.update = try fixture.cloneUpdate(self.gpa, &self.full, false);
        const info_owner = try package.capi.tree_info.treeInfoNew(self.gpa, root);
        package.capi.tree_update.treeUpdateSetTreeInfo(owner, info_owner);
        try package.capi.tree_info.treeInfoSetToolkitName(info_owner, self.metadata_name);
        try package.capi.tree_info.treeInfoSetToolkitVersion(info_owner, self.metadata_version);
        owner.update.tree = info_owner.tree;
        return owner;
    }
    pub fn deinit(self: *Host) void {
        self.closed.store(true, .release);
        self.edits_mutex.lockUncancelable(self.io);
        for (0..self.edit_count) |offset| {
            const entry = &self.edit_entries[(self.edit_head + offset) % edit_queue_limit];
            self.editResult(entry, "closed", "Closed") catch {
                self.output_failed.store(true, .release);
            };
            _ = self.edit_rejected.fetchAdd(1, .monotonic);
        }
        self.edit_count = 0;
        self.edit_head = 0;
        self.edits_mutex.unlock(self.io);
        if (self.c_activation) |owner| package.capi.tree_update.treeUpdateFree(owner);
        self.full.deinit(self.gpa);
    }
    fn from(context: ?*anyopaque) *Host {
        return @ptrCast(@alignCast(context.?));
    }
    pub fn line(self: *Host, bytes: []const u8) std.Io.Writer.Error!void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.output.writeAll(bytes);
        try self.output.flush();
    }
    fn admit(self: *Host) bool {
        if (!self.closed.load(.acquire)) return true;
        _ = self.late_callbacks.fetchAdd(1, .monotonic);
        return false;
    }
    pub fn activation(context: ?*anyopaque) native.CallbackError!?native.ActivationSnapshot {
        const self = from(context);
        if (!self.admit()) return error.CallbackFailed;
        self.cache_mutex.lockUncancelable(self.io);
        _ = self.activations.fetchAdd(1, .monotonic);
        if (self.defer_activation) {
            self.cache_mutex.unlock(self.io);
            return null;
        }
        self.loan_model = self.model;
        self.loan_name = self.metadata_name;
        self.loan_version = self.metadata_version;
        return .{ .update = if (self.c_activation) |owner| &owner.update else &self.full, .release_context = self, .release = release };
    }
    fn release(context: ?*anyopaque) void {
        const self = from(context);
        snapshotText(&self.loan_model, &self.loan_text);
        if (self.c_activation) |owner| {
            package.capi.tree_update.treeUpdateFree(owner);
            _ = self.c_frees.fetchAdd(1, .monotonic);
            self.c_activation = null;
        }
        _ = self.releases.fetchAdd(1, .monotonic);
        self.cache_mutex.unlock(self.io);
    }
    pub fn activationCompleted(context: ?*anyopaque, outcome: native.UpdateOutcome) void {
        const self = from(context);
        self.recordModel(outcome, true, self.loan_model, self.loan_name, self.loan_version);
    }
    pub fn deactivation(context: ?*anyopaque) void {
        const self = from(context);
        _ = self.admit();
        _ = self.deactivations.fetchAdd(1, .monotonic);
    }
    pub fn action(context: ?*anyopaque, request: *const schema.ActionRequest) native.CallbackError!void {
        const self = from(context);
        if (!self.admit()) return error.CallbackFailed;
        _ = self.actions.fetchAdd(1, .monotonic);
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        self.output.writeAll("ACTION ") catch return error.CallbackFailed;
        std.json.Stringify.value(.{ .action = @tagName(request.action), .target = request.target_node.value, .tree = std.fmt.bytesToHex(request.target_tree.bytes, .lower), .data = request.data }, .{}, self.output) catch return error.CallbackFailed;
        self.output.writeByte('\n') catch return error.CallbackFailed;
        self.output.flush() catch return error.CallbackFailed;
    }
    pub fn positionedEdit(context: ?*anyopaque, request: *const native.EditableTextRequest) native.CallbackError!bool {
        const self = from(context orelse return error.CallbackFailed);
        self.edits_mutex.lockUncancelable(self.io);
        defer self.edits_mutex.unlock(self.io);
        const refusal: ?[]const u8 = if (!self.admit()) "Closed" else if (request.target.local.value != 7 or request.target.tree_index.value() != 0)
            "UnsupportedTarget"
        else if (request.replacement_utf8.len > edit_replacement_bytes_limit)
            "PayloadLimit"
        else if (self.edit_count == edit_queue_limit) "QueueFull" else null;
        if (refusal) |reason| {
            _ = self.edit_refused.fetchAdd(1, .monotonic);
            self.editLog("EDIT ", .{
                .target = request.target.local.value,
                .tree_index = request.target.tree_index.value(),
                .start_scalar = request.start_scalar,
                .end_scalar = request.end_scalar,
                .replacement_utf8 = request.replacement_utf8,
                .accepted = false,
                .outcome = reason,
            }) catch return error.CallbackFailed;
            return false;
        }
        std.debug.assert(self.edit_count < edit_queue_limit);
        const entry = &self.edit_entries[(self.edit_head + self.edit_count) % edit_queue_limit];
        entry.target = request.target.local.value;
        entry.tree_index = request.target.tree_index.value();
        entry.start_scalar = request.start_scalar;
        entry.end_scalar = request.end_scalar;
        entry.replacement_len = request.replacement_utf8.len;
        @memcpy(entry.replacement[0..entry.replacement_len], request.replacement_utf8);
        // A failed receipt must not leave an accepted queue entry behind.
        self.editLog("EDIT ", .{
            .target = entry.target,
            .tree_index = entry.tree_index,
            .start_scalar = entry.start_scalar,
            .end_scalar = entry.end_scalar,
            .replacement_utf8 = entry.replacement[0..entry.replacement_len],
            .accepted = true,
            .outcome = "queued",
        }) catch {
            _ = self.edit_refused.fetchAdd(1, .monotonic);
            return error.CallbackFailed;
        };
        self.edit_count += 1;
        _ = self.edit_queued.fetchAdd(1, .monotonic);
        return true;
    }

    fn editLog(self: *Host, prefix: []const u8, value: anytype) std.Io.Writer.Error!void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        errdefer self.output_failed.store(true, .release);
        try self.output.writeAll(prefix);
        try std.json.Stringify.value(value, .{}, self.output);
        try self.output.writeByte('\n');
        try self.output.flush();
    }

    fn editResult(self: *Host, entry: *const EditEntry, outcome: []const u8, reason: []const u8) std.Io.Writer.Error!void {
        try self.editLog("EDIT_RESULT ", .{
            .target = entry.target,
            .tree_index = entry.tree_index,
            .start_scalar = entry.start_scalar,
            .end_scalar = entry.end_scalar,
            .replacement_utf8 = entry.replacement[0..entry.replacement_len],
            .outcome = outcome,
            .reason = reason,
        });
    }

    fn consumeEdit(self: *Host) void {
        std.debug.assert(self.edit_count > 0);
        self.edit_head = (self.edit_head + 1) % edit_queue_limit;
        self.edit_count -= 1;
    }

    /// Drains only the live source cache. Publication remains the caller's operation.
    pub fn drainEdits(self: *Host) DrainEditError!void {
        self.edits_mutex.lockUncancelable(self.io);
        defer self.edits_mutex.unlock(self.io);
        if (self.closed.load(.acquire)) return error.Closed;
        self.cache_mutex.lockUncancelable(self.io);
        defer self.cache_mutex.unlock(self.io);
        // Holding admission across this bounded batch keeps every payload pinned.
        const batch_count = self.edit_count;
        for (0..batch_count) |_| {
            const entry = &self.edit_entries[self.edit_head];
            self.applyEdit(entry) catch |err| switch (err) {
                error.OutOfMemory => {
                    try self.editResult(entry, "retry", "OutOfMemory");
                    return error.OutOfMemory;
                },
                error.InvalidUtf8, error.InvalidPosition, error.InvalidCaret, error.TextLimit, error.MissingTextNode => {
                    _ = self.edit_rejected.fetchAdd(1, .monotonic);
                    self.consumeEdit();
                    try self.editResult(entry, "rejected", @errorName(err));
                    continue;
                },
            };
            _ = self.edit_applied.fetchAdd(1, .monotonic);
            self.consumeEdit();
            try self.editResult(entry, "applied", "none");
        }
    }

    const ApplyEditError = fixture.TextError || error{ InvalidPosition, MissingTextNode };

    fn applyEdit(self: *Host, entry: *const EditEntry) ApplyEditError!void {
        std.debug.assert(self.full.nodes.items.len <= edit_cache_nodes_limit);
        var owner: ?*schema.Node = null;
        var run: ?*schema.Node = null;
        for (self.full.nodes.items) |*item| {
            switch (item.node_id.value) {
                7 => owner = &item.node,
                8 => run = &item.node,
                else => {},
            }
        }
        const old_owner = owner orelse return error.MissingTextNode;
        const old_run = run orelse return error.MissingTextNode;
        const text = schema.strings.value(&old_run.properties) orelse return error.MissingTextNode;
        if (text.len > fixture.text_bytes_limit) return error.TextLimit;
        const text_view = try std.unicode.Utf8View.init(text);
        const replacement = entry.replacement[0..entry.replacement_len];
        const replacement_view = try std.unicode.Utf8View.init(replacement);
        if (entry.start_scalar > entry.end_scalar) return error.InvalidPosition;
        var text_iterator = text_view.iterator();
        var scalar_count: u32 = 0;
        var byte_offset: usize = 0;
        var start_byte: ?usize = null;
        var end_byte: ?usize = null;
        // Valid UTF-8 consumes at least one byte per scalar plus one end-cursor step.
        const text_scalar_steps_limit = fixture.text_bytes_limit + 1;
        for (0..text_scalar_steps_limit) |_| {
            if (scalar_count == entry.start_scalar) start_byte = byte_offset;
            if (scalar_count == entry.end_scalar) end_byte = byte_offset;
            const scalar = text_iterator.nextCodepointSlice() orelse break;
            std.debug.assert(scalar_count < fixture.text_bytes_limit);
            byte_offset += scalar.len;
            scalar_count += 1;
        }
        std.debug.assert(byte_offset == text.len);
        const start = start_byte orelse return error.InvalidPosition;
        const end = end_byte orelse return error.InvalidPosition;
        const result_len = text.len - (end - start) + replacement.len;
        if (result_len > fixture.text_bytes_limit) return error.TextLimit;
        var replacement_iterator = replacement_view.iterator();
        var replacement_scalars: u32 = 0;
        var replacement_bytes: usize = 0;
        const replacement_scalar_steps_limit = edit_replacement_bytes_limit;
        for (0..replacement_scalar_steps_limit) |_| {
            const scalar = replacement_iterator.nextCodepointSlice() orelse break;
            std.debug.assert(scalar.len > 0);
            replacement_scalars += 1;
            replacement_bytes += scalar.len;
        }
        std.debug.assert(replacement_bytes == replacement.len);
        var scratch: [fixture.text_bytes_limit]u8 = undefined;
        @memcpy(scratch[0..start], text[0..start]);
        @memcpy(scratch[start..][0..replacement.len], replacement);
        @memcpy(scratch[start + replacement.len .. result_len], text[end..]);
        const caret = entry.start_scalar + replacement_scalars;
        const staged = try fixture.prepareTextNodes(self.gpa, old_owner, old_run, scratch[0..result_len], caret);
        // No fallible operation follows staging: install both nodes atomically.
        var retired_owner = old_owner.*;
        var retired_run = old_run.*;
        old_owner.* = staged.owner;
        old_run.* = staged.run;
        self.model.text8 = schema.strings.value(&old_run.properties).?;
        self.model.caret8 = caret;
        retired_owner.deinit();
        retired_run.deinit();
        // An unloaned C activation snapshot must not reactivate the stale source.
        if (self.c_activation) |c_owner| {
            package.capi.tree_update.treeUpdateFree(c_owner);
            self.c_activation = null;
            _ = self.c_frees.fetchAdd(1, .monotonic);
        }
    }

    /// Caller holds cache_mutex while replacing the full cache and rebinding.
    pub fn rebindTextModel(self: *Host) void {
        if (self.model.text8 == null) return;
        std.debug.assert(self.full.nodes.items.len <= edit_cache_nodes_limit);
        for (self.full.nodes.items) |*item| {
            if (item.node_id.value == 8) {
                self.model.text8 = schema.strings.value(&item.node.properties);
                return;
            }
        }
        std.debug.assert(false); // An override full snapshot always includes run 8.
    }

    fn snapshotText(model: *fixture.Model, buffer: *[fixture.text_bytes_limit]u8) void {
        if (model.text8) |text| {
            std.debug.assert(text.len <= buffer.len);
            if (text.ptr != buffer[0..].ptr) @memcpy(buffer[0..text.len], text);
            model.text8 = buffer[0..text.len];
        }
    }
    pub fn record(self: *Host, outcome: native.UpdateOutcome, metadata: bool) void {
        self.recordModel(outcome, metadata, self.model, self.metadata_name, self.metadata_version);
    }
    pub fn recordModel(self: *Host, outcome: native.UpdateOutcome, metadata: bool, model: ?fixture.Model, name: []const u8, version: []const u8) void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        switch (outcome) {
            .inactive => self.output.writeAll("OUTCOME inactive\n") catch {
                self.output_failed.store(true, .release);
            },
            .rejected => |err| {
                _ = self.rejected.fetchAdd(1, .monotonic);
                self.output.print("OUTCOME rejected error={s}\n", .{@errorName(err)}) catch {
                    self.output_failed.store(true, .release);
                };
            },
            .committed => |committed| {
                _ = self.commits.fetchAdd(1, .monotonic);
                if (model) |accepted_model| {
                    self.baseline = accepted_model;
                    snapshotText(&self.baseline, &self.baseline_text);
                }
                if (metadata or committed.used_full_tree) {
                    self.baseline_name = name;
                    self.baseline_version = version;
                }
                self.output.print("OUTCOME committed attachment={d} used_full={any} notification={s}\n", .{
                    committed.attachment,                                                committed.used_full_tree,
                    if (committed.notification_error) |err| @errorName(err) else "none",
                }) catch {
                    self.output_failed.store(true, .release);
                };
                fixture.digest(self.output, self.baseline, self.baseline_name, self.baseline_version) catch {
                    self.output_failed.store(true, .release);
                };
            },
        }
        self.output.flush() catch {
            self.output_failed.store(true, .release);
        };
    }
    pub fn stats(self: *Host, adapter: *native.NativeAdapter) std.Io.Writer.Error!void {
        self.output_mutex.lockUncancelable(self.io);
        defer self.output_mutex.unlock(self.io);
        try self.output.print("STATS status={s} attachment={d} activations={d} releases={d} " ++
            "commits={d} rejected={d} actions={d} deactivations={d} late_callbacks={d} c_frees={d} " ++
            "edit_queued={d} edit_applied={d} edit_rejected={d} edit_refused={d} " ++
            "activation_error={s} transport_error={s} action_error={s} dispatch_error={s} " ++
            "close_error={s} fault_fired={any}\n", .{
            @tagName(adapter.activationStatus()),                             adapter.updateTicket().attachment,
            self.activations.load(.acquire),                                  self.releases.load(.acquire),
            self.commits.load(.acquire),                                      self.rejected.load(.acquire),
            self.actions.load(.acquire),                                      self.deactivations.load(.acquire),
            self.late_callbacks.load(.acquire),                               self.c_frees.load(.acquire),
            self.edit_queued.load(.acquire),                                  self.edit_applied.load(.acquire),
            self.edit_rejected.load(.acquire),                                self.edit_refused.load(.acquire),
            if (adapter.activationError()) |err| @errorName(err) else "none", if (adapter.transportError()) |err| @errorName(err) else "none",
            if (adapter.actionError()) |err| @errorName(err) else "none",     if (adapter.dispatchError()) |err| @errorName(err) else "none",
            if (adapter.closeError()) |err| @errorName(err) else "none",      self.faults.fired.load(.acquire),
        });
        try fixture.digest(self.output, self.baseline, self.baseline_name, self.baseline_version);
        try self.output.flush();
    }
};

pub const Factory = struct {
    host: *Host,
    forced_full: bool,
    fail_next: bool,
    c_owner: ?*CUpdate = null,
    included_metadata: bool = false,
    missing_full_child: bool = false,

    pub fn get(context: ?*anyopaque, gpa: std.mem.Allocator, current: native.UpdateContext) native.CallbackError!?native.FactoryUpdate {
        const self: *Factory = @ptrCast(@alignCast(context.?));
        self.included_metadata = self.forced_full or current.requires_full_tree;
        self.host.cache_mutex.lockUncancelable(self.host.io);
        defer self.host.cache_mutex.unlock(self.host.io);
        const source = if (self.c_owner) |owner| &owner.update else &self.host.full;
        var update = try fixture.cloneUpdate(gpa, source, self.included_metadata);
        if (self.missing_full_child) {
            for (update.nodes.items, 0..) |entry, index| {
                if (entry.node_id.value == 5) {
                    var removed = update.nodes.orderedRemove(index);
                    removed.node.deinit();
                    break;
                }
            }
        }
        // The first native core allocation follows this owned-lane factory without I/O.
        if (self.fail_next) self.host.faults.arm();
        return .{ .update = update, .kind = if (self.included_metadata) .full else .delta };
    }
};

pub const FaultAllocator = struct {
    backing: std.mem.Allocator,
    armed: std.atomic.Value(bool) = .init(false),
    fired: std.atomic.Value(bool) = .init(false),

    pub fn allocator(self: *FaultAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn arm(self: *FaultAllocator) void {
        self.fired.store(false, .release);
        self.armed.store(true, .release);
    }
    pub fn disarm(self: *FaultAllocator) void {
        self.armed.store(false, .release);
    }
    fn refuse(self: *FaultAllocator) bool {
        if (!self.armed.swap(false, .acq_rel)) return false;
        self.fired.store(true, .release);
        return true;
    }
    fn from(context: *anyopaque) *FaultAllocator {
        return @ptrCast(@alignCast(context));
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self = from(context);
        if (self.refuse()) return null;
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        return from(context).backing.rawResize(memory, alignment, new_len, ret_addr);
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        return from(context).backing.rawRemap(memory, alignment, new_len, ret_addr);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        from(context).backing.rawFree(memory, alignment, ret_addr);
    }
};
