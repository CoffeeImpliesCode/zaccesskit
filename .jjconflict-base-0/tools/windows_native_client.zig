//! Source-only native acceptance client. Build: zig build windows-native-client
//! -Dtarget=x86_64-windows-gnu. Run on Windows: zaccesskit-windows-native-client.exe
//! --timeout-ms 5000 --pump-rounds 20000 --fault-limit 4096.
//! No desktop activation, trust changes, or permission-dialog interaction is performed.
//! Expected JSON cases are declared below; a case is emitted only after its assertions.
const std = @import("std");
const builtin = @import("builtin");
const kit = @import("zaccesskit");
const schema = kit.schema;
const windows = kit.adapters.windows;
const sdk = @import("win32");
const uia = sdk.ui.accessibility;
const com = sdk.system.com;
const foundation = sdk.foundation;
const messages = sdk.ui.windows_and_messaging;
const user32 = sdk.user32;
const kernel32 = sdk.kernel32;
const ole32 = sdk.ole32;
const oleaut32 = sdk.oleaut32;
const Bstr = sdk.everything.BSTR;
const Bool = sdk.everything.BOOL;
const HResult = sdk.zig.HRESULT;

comptime {
    if (builtin.os.tag != .windows) @compileError("this real SDK client requires Windows");
}

const Error = std.mem.Allocator.Error || std.Io.Writer.Error || error{
    BadArguments,
    ComFailure,
    NullComResult,
    UnexpectedHresult,
    UnexpectedValue,
    WindowCreationFailed,
    WindowOperationFailed,
    EventOperationFailed,
    CommandTimeout,
    MessagePumpExhausted,
    MessageBatchExhausted,
    FaultSweepExhausted,
    MissingPrecommitOom,
    MissingPostcommitOom,
    OwnerCommandFailed,
    CallbackRingExhausted,
    CallbackAfterClose,
    CallbackPayloadTooLarge,
    UnexpectedAction,
    RuntimeReleasedEarly,
    RuntimeNotReleased,
    SubclassRefused,
    NativeUnsupported,
    ProviderOperationFailed,
    NotificationCleanupFailed,
    ThreadSpawnFailed,
    CallbackGateTimeout,
    CloseAdmissionExhausted,
};

const root_id: schema.NodeId = .{ .value = 0x101 };
const button_id: schema.NodeId = .{ .value = 0x211 };
const slider_id: schema.NodeId = .{ .value = 0x323 };
const text_id: schema.NodeId = .{ .value = 0x445 };
const run_id: schema.NodeId = .{ .value = 0x446 };
const survivor_id: schema.NodeId = .{ .value = 0x765 };
const survivor_run_id: schema.NodeId = .{ .value = 0x766 };
const list_id: schema.NodeId = .{ .value = 0x587 };
const item_id: schema.NodeId = .{ .value = 0x588 };
const custom_id: schema.NodeId = .{ .value = 0x701234567 };
const command_message = messages.WM_APP + 41;
const max_callback_records = 64;
const max_payload_bytes = 512;
const max_message_batch = 256;

pub const expected_cases = [_][]const u8{
    "static_wm_settext_previous_fallback",                "inactive_late_full_contains_every_id",
    "sdk_name_controltype_focus_properties",              "sdk_invoke_numeric_value_selection",
    "sdk_unicode_text_utf16_prefix_find_move_rectangles", "sdk_custom_target_and_nul_value",
    "native_borrowed_nul_and_sparse_custom_payload",      "invalid_update_preserves_sdk_queries",
    "precommit_oom_preserves_sdk_queries",                "postcommit_oom_accepts_sdk_baseline",
    "sdk_delta_changes_name_and_unicode",                 "removed_retained_provider_and_range_defunct",
    "closed_retained_live_provider_and_range_defunct",    "actual_qi_unsupported_and_null_output",
    "close_joins_callbacks_before_userdata_release",      "retained_com_keeps_runtime_until_final_release",
    "placeholder_selects_current_full",
};

const Options = struct {
    timeout_ms: u32 = 5000,
    pump_rounds: u32 = 20000,
    fault_limit: u32 = 4096,

    fn parse(args: []const [:0]const u8) Error!Options {
        var result: Options = .{};
        if ((args.len - 1) % 2 != 0) return error.BadArguments;
        var index: usize = 1;
        while (index < args.len) : (index += 2) {
            const number = std.fmt.parseInt(u32, args[index + 1], 10) catch
                return error.BadArguments;
            if (std.mem.eql(u8, args[index], "--timeout-ms")) {
                result.timeout_ms = number;
            } else if (std.mem.eql(u8, args[index], "--pump-rounds")) {
                result.pump_rounds = number;
            } else if (std.mem.eql(u8, args[index], "--fault-limit")) {
                result.fault_limit = number;
            } else {
                return error.BadArguments;
            }
        }
        if (result.timeout_ms == 0 or result.timeout_ms > 60000 or
            result.pump_rounds == 0 or result.pump_rounds > 1000000 or
            result.fault_limit < 2 or result.fault_limit > 65536) return error.BadArguments;
        return result;
    }
};

const Reporter = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    writer: *std.Io.Writer,

    fn record(self: *Reporter, value: anytype) std.Io.Writer.Error!void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        try std.json.Stringify.value(value, .{}, self.writer);
        try self.writer.writeByte('\n');
        try self.writer.flush();
    }

    fn passed(self: *Reporter, name: []const u8, actual: anytype) Error!void {
        try self.record(.{ .case = name, .status = "pass", .actual = actual });
    }
};

fn require(condition: bool) Error!void {
    if (!condition) return error.UnexpectedValue;
}

fn hr(value: HResult) Error!void {
    if (value.failed) return error.ComFailure;
}

fn exactHr(value: HResult, expected: u32) Error!void {
    if (@as(u32, @bitCast(value)) != expected) return error.UnexpectedHresult;
}

fn release(value: anytype) void {
    _ = value.IUnknown.Release();
}

fn clearVariant(value: *com.VARIANT) void {
    const result = oleaut32.VariantClear(value);
    if (result.failed) std.debug.panic("VariantClear failed: 0x{x}", .{@as(u32, @bitCast(result))});
}

fn destroyArray(value: *com.SAFEARRAY) void {
    const result = oleaut32.SafeArrayDestroy(value);
    if (result.failed) std.debug.panic("SafeArrayDestroy failed: 0x{x}", .{@as(u32, @bitCast(result))});
}

fn bstrBytes(value: ?Bstr) []const u16 {
    const count = oleaut32.SysStringLen(value);
    const pointer = value orelse return &.{};
    return @as([*]const u16, @ptrCast(pointer))[0..count];
}

fn expectBstr(value: ?Bstr, expected: []const u16) Error!void {
    try require(std.mem.eql(u16, bstrBytes(value), expected));
}

fn nameIs(element: *uia.IUIAutomationElement, expected: []const u16) Error!void {
    var name: ?Bstr = null;
    try hr(element.get_CurrentName(&name));
    defer oleaut32.SysFreeString(name);
    try expectBstr(name, expected);
    var property: com.VARIANT = undefined;
    oleaut32.VariantInit(&property);
    defer clearVariant(&property);
    try hr(element.GetCurrentPropertyValue(uia.UIA_NamePropertyId, &property));
    try require(property.Anonymous.Anonymous.vt == .BSTR);
    try expectBstr(property.Anonymous.Anonymous.Anonymous.bstrVal, expected);
}

fn query(comptime T: type, unknown: *com.IUnknown, iid: *const sdk.zig.Guid) Error!*T {
    var pointer: ?*anyopaque = null;
    try hr(unknown.QueryInterface(iid, @ptrCast(&pointer)));
    return @ptrCast(@alignCast(pointer orelse return error.NullComResult));
}

fn pattern(
    comptime T: type,
    element: *uia.IUIAutomationElement,
    id: uia.UIA_PATTERN_ID,
    iid: *const sdk.zig.Guid,
) Error!*T {
    var unknown: ?*com.IUnknown = null;
    try hr(element.GetCurrentPattern(id, &unknown));
    const owned = unknown orelse return error.NullComResult;
    defer _ = owned.Release();
    return query(T, owned, iid);
}

const Frame = enum { initial, late, changed, removed };

fn buttonLabel(frame: Frame) []const u8 {
    return switch (frame) {
        .initial => "Invoke initial",
        .late => "Invoke late",
        .changed => "Invoke changed",
        .removed => "Invoke removed",
    };
}

fn textValue(frame: Frame) []const u8 {
    return if (frame == .changed) "B😀ö" else "A😀é";
}

fn makeNode(
    gpa: std.mem.Allocator,
    role: schema.Role,
    label: []const u8,
    bounds: schema.Rect,
) std.mem.Allocator.Error!schema.Node {
    var node = schema.Node.init(gpa, role);
    errdefer node.deinit();
    try schema.strings.setLabel(&node.properties, label);
    try schema.option.setBounds(&node.properties, bounds);
    return node;
}

fn makeFixtureNode(gpa: std.mem.Allocator, id: schema.NodeId, frame: Frame) std.mem.Allocator.Error!schema.Node {
    const role: schema.Role = switch (id.value) {
        root_id.value => .window,
        button_id.value => .button,
        slider_id.value => .slider,
        text_id.value, survivor_id.value => .text_input,
        run_id.value, survivor_run_id.value => .text_run,
        list_id.value => .list_box,
        item_id.value => .list_item,
        custom_id.value => .unknown,
        else => unreachable, // Only the fixed fixture ID table calls this builder.
    };
    var node = schema.Node.init(gpa, role);
    errdefer node.deinit();
    const properties = &node.properties;
    switch (id.value) {
        root_id.value => {
            try schema.strings.setLabel(properties, "Native UIA proof");
            try schema.option.setBounds(properties, schema.rectInit(0, 0, 400, 240));
            try schema.ids_props.setChildren(properties, if (frame == .removed)
                &.{ slider_id, list_id, custom_id, survivor_id }
            else
                &.{ button_id, slider_id, text_id, list_id, custom_id, survivor_id });
        },
        button_id.value => {
            try schema.strings.setLabel(properties, buttonLabel(frame));
            try schema.option.setBounds(properties, schema.rectInit(10, 10, 90, 30));
            node.addAction(.click);
            node.addAction(.focus);
        },
        slider_id.value => {
            try schema.strings.setLabel(properties, "Level");
            try schema.option.setBounds(properties, schema.rectInit(10, 40, 110, 60));
            node.addAction(.set_value);
            node.addAction(.focus);
            try schema.numbers.setNumericValue(properties, if (frame == .changed) 37 else 25);
            try schema.numbers.setMinNumericValue(properties, 0);
            try schema.numbers.setMaxNumericValue(properties, 100);
            try schema.numbers.setNumericValueStep(properties, 1);
        },
        text_id.value, survivor_id.value => {
            const surviving = id.eql(survivor_id);
            const child_id = if (surviving) survivor_run_id else run_id;
            try schema.strings.setLabel(properties, if (surviving) "Surviving input" else "Unicode input");
            try schema.option.setBounds(properties, if (surviving)
                schema.rectInit(120, 80, 220, 100)
            else
                schema.rectInit(10, 80, 100, 100));
            node.addAction(.set_value);
            node.addAction(.set_text_selection);
            node.addAction(.focus);
            try schema.strings.setValue(properties, if (surviving) "Live Ω" else textValue(frame));
            try schema.ids_props.setChildren(properties, &.{child_id});
            try schema.option.setTextSelection(properties, .{
                .anchor = .{ .node_id = child_id, .character_index = 1 },
                .focus = .{ .node_id = child_id, .character_index = 2 },
            });
        },
        run_id.value, survivor_run_id.value => {
            const surviving = id.eql(survivor_run_id);
            try schema.option.setBounds(properties, if (surviving)
                schema.rectInit(120, 80, 188, 100)
            else
                schema.rectInit(10, 80, 48, 100));
            try schema.strings.setValue(properties, if (surviving) "Live Ω" else textValue(frame));
            try schema.vectors.setCharacterLengths(properties, if (surviving)
                &.{ 1, 1, 1, 1, 1, 2 }
            else
                &.{ 1, 4, 2 });
            try schema.vectors.setCharacterPositions(properties, if (surviving)
                &.{ 0, 10, 20, 30, 40, 50 }
            else
                &.{ 0, 10, 28 });
            try schema.vectors.setCharacterWidths(properties, if (surviving)
                &.{ 10, 10, 10, 10, 10, 18 }
            else
                &.{ 10, 18, 10 });
            try schema.enums.setTextDirection(properties, .left_to_right);
        },
        list_id.value => {
            try schema.strings.setLabel(properties, "Choices");
            try schema.option.setBounds(properties, schema.rectInit(10, 120, 100, 160));
            try schema.ids_props.setChildren(properties, &.{item_id});
        },
        item_id.value => {
            try schema.strings.setLabel(properties, "Selected choice");
            try schema.option.setBounds(properties, schema.rectInit(10, 120, 100, 140));
            node.addAction(.click);
            try schema.enums.setSelected(properties, true);
        },
        custom_id.value => {
            try schema.strings.setLabel(properties, "Sparse custom target");
            try schema.option.setBounds(properties, schema.rectInit(120, 120, 220, 140));
            node.addAction(.click);
            node.addAction(.custom_action);
            try schema.strings.setValue(properties, "left\x00right");
            var first = try schema.CustomAction.init(gpa, -7, "Negative custom action");
            defer first.deinit(gpa);
            var second = try schema.CustomAction.init(gpa, 4099, "Sparse custom action");
            defer second.deinit(gpa);
            try schema.vectors.setCustomActions(properties, &.{ first, second });
        },
        else => unreachable, // The same fixed ID table determines the role above.
    }
    return node;
}

fn makeSnapshot(gpa: std.mem.Allocator, frame: Frame, full: bool) std.mem.Allocator.Error!schema.TreeUpdate {
    var update: schema.TreeUpdate = .{ .focus = if (frame == .removed) slider_id else text_id };
    errdefer update.deinit(gpa);
    if (full) update.tree = schema.TreeInfo.init(root_id);
    const all = [_]schema.NodeId{
        root_id,     button_id,       slider_id, text_id, run_id, list_id, item_id, custom_id,
        survivor_id, survivor_run_id,
    };
    const ids: []const schema.NodeId = if (full) &all else switch (frame) {
        .initial, .late => &.{button_id},
        .changed => &.{ button_id, slider_id, text_id, run_id },
        .removed => &.{root_id},
    };
    for (ids) |id| {
        if (frame == .removed and
            (id.eql(button_id) or id.eql(text_id) or id.eql(run_id))) continue;
        try update.pushNode(gpa, id, try makeFixtureNode(gpa, id, frame));
    }
    return update;
}

const Cached = struct {
    full: [4]schema.TreeUpdate,
    delta: [4]schema.TreeUpdate,
    invalid: schema.TreeUpdate,

    fn init(gpa: std.mem.Allocator) std.mem.Allocator.Error!Cached {
        var result: Cached = undefined;
        var count: usize = 0;
        errdefer for (0..count) |index| {
            result.full[index].deinit(gpa);
            result.delta[index].deinit(gpa);
        };
        for (std.enums.values(Frame), 0..) |frame, index| {
            result.full[index] = try makeSnapshot(gpa, frame, true);
            errdefer result.full[index].deinit(gpa);
            result.delta[index] = try makeSnapshot(gpa, frame, false);
            count += 1;
        }
        result.invalid = .{ .focus = text_id };
        errdefer result.invalid.deinit(gpa);
        var invalid = try makeNode(gpa, .window, "Invalid", schema.rectInit(0, 0, 400, 240));
        schema.ids_props.setChildren(&invalid.properties, &.{.{ .value = 0xdeadbeef }}) catch |err| {
            invalid.deinit();
            return err;
        };
        try result.invalid.pushNode(gpa, root_id, invalid);
        return result;
    }

    fn deinit(self: *Cached, gpa: std.mem.Allocator) void {
        for (&self.full) |*update| update.deinit(gpa);
        for (&self.delta) |*update| update.deinit(gpa);
        self.invalid.deinit(gpa);
        self.* = undefined;
    }
};

// Only allocator failure is injected. HWND, COM, UIA and Automation value APIs stay real.
const FaultAllocator = struct {
    inner: std.mem.Allocator,
    remaining: std.atomic.Value(i64) = .init(-1),
    failed: std.atomic.Value(bool) = .init(false),
    live_allocations: std.atomic.Value(usize) = .init(0),

    fn allocator(self: *FaultAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn arm(self: *FaultAllocator, offset: u32) void {
        self.failed.store(false, .release);
        self.remaining.store(offset, .release);
    }
    fn disarm(self: *FaultAllocator) void {
        self.remaining.store(-1, .release);
    }
    fn refuses(self: *FaultAllocator) bool {
        const count = self.remaining.load(.acquire);
        if (count < 0) return false;
        if (self.remaining.fetchSub(1, .acq_rel) == 0) {
            self.failed.store(true, .release);
            return true;
        }
        return false;
    }
    fn alloc(context: *anyopaque, length: usize, alignment: std.mem.Alignment, address: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(context));
        if (self.refuses()) return null;
        const memory = self.inner.rawAlloc(length, alignment, address) orelse return null;
        _ = self.live_allocations.fetchAdd(1, .acq_rel);
        return memory;
    }
    fn resize(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) bool {
        const self: *FaultAllocator = @ptrCast(@alignCast(context));
        if (length > memory.len and self.refuses()) return false;
        return self.inner.rawResize(memory, alignment, length, address);
    }
    fn remap(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, length: usize, address: usize) ?[*]u8 {
        const self: *FaultAllocator = @ptrCast(@alignCast(context));
        if (length > memory.len and self.refuses()) return null;
        return self.inner.rawRemap(memory, alignment, length, address);
    }
    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, address: usize) void {
        const self: *FaultAllocator = @ptrCast(@alignCast(context));
        self.inner.rawFree(memory, alignment, address);
        if (self.live_allocations.fetchSub(1, .acq_rel) == 0)
            std.debug.panic("native provider allocation accounting underflow", .{});
    }
};

const Runtime = struct {
    gpa: std.mem.Allocator,
    threaded: std.Io.Threaded,
    released: *std.atomic.Value(u32),

    fn relinquish(userdata: ?*anyopaque) void {
        const self: *Runtime = @ptrCast(@alignCast(userdata.?));
        const gpa = self.gpa;
        const counter = self.released;
        self.threaded.deinit();
        gpa.destroy(self);
        _ = counter.fetchAdd(1, .acq_rel);
    }
};

const Command = enum(u32) {
    late,
    publish,
    invalid,
    fault,
    retain,
    native_payloads,
    restore,
    missing_previous_fallback,
    close,
};
const Disposition = enum { inactive, rejected, committed };
const Reply = struct {
    disposition: Disposition = .inactive,
    used_full: bool = false,
    failure: ?Error = null,
    notification_error: bool = false,
    exact_error: [96]u8 = @splat(0),
    exact_error_len: usize = 0,
    allocator_failed: bool = false,
};
const ActionRecord = struct {
    request: schema.ActionRequest,
    bytes: [max_payload_bytes]u8 = undefined,
};

const Host = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    reporter: *Reporter,
    options: Options,
    hwnd: foundation.HWND,
    reply_event: foundation.HANDLE,
    done_event: foundation.HANDLE,
    cache: *Cached,
    allocator_gate: *FaultAllocator,
    subclass: ?*windows.WindowsSubclassingAdapter = null,
    current: Frame = .initial,
    placeholder: bool,
    window_destroyed: bool = false,
    activation_calls: std.atomic.Value(u32) = .init(0),
    userdata_live: std.atomic.Value(bool) = .init(true),
    runtime_releases: std.atomic.Value(u32) = .init(0),
    selection_action_checked: bool = false,
    cancelled: std.atomic.Value(bool) = .init(false),
    callback_lock: std.Io.Mutex = .init,
    callback_error: ?Error = null,
    pending_events: ?windows.WindowsQueuedEvents = null,
    action_count: usize = 0,
    records: [max_callback_records]ActionRecord = undefined,
    reply: Reply = .{},
    client_error: ?Error = null,
    raw_button: ?*uia.IRawElementProviderSimple = null,
    raw_text: ?*uia.IRawElementProviderSimple = null,
    raw_range: ?*uia.ITextRangeProvider = null,
    raw_survivor: ?*uia.IRawElementProviderSimple = null,
    raw_survivor_range: ?*uia.ITextRangeProvider = null,
    callback_started_event: foundation.HANDLE,
    callback_release_event: foundation.HANDLE,
    close_started_event: foundation.HANDLE,
    callback_block_armed: std.atomic.Value(bool) = .init(false),
    callback_finished: std.atomic.Value(bool) = .init(false),
    close_barrier_observed: std.atomic.Value(bool) = .init(false),
    blocking_error: ?Error = null,
    close_observer_error: ?Error = null,
    lifecycle_weak: ?windows.context.WeakContext = null,

    fn activation(consumer: windows.ActivationConsumer, consumer_data: ?*anyopaque, userdata: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(userdata.?));
        _ = self.activation_calls.fetchAdd(1, .acq_rel);
        // This callback only loans the current prebuilt full view. No native call or allocation.
        consumer(if (self.placeholder) null else &self.cache.full[@intFromEnum(self.current)], consumer_data);
    }

    fn action(request: *const schema.ActionRequest, userdata: ?*anyopaque) void {
        const self: *Host = @ptrCast(@alignCast(userdata.?));
        self.callback_lock.lockUncancelable(self.io);
        defer self.callback_lock.unlock(self.io);
        if (!self.userdata_live.load(.acquire)) {
            self.callback_error = error.CallbackAfterClose;
            return;
        }
        if (self.action_count == max_callback_records) {
            self.callback_error = error.CallbackRingExhausted;
            return;
        }
        const index = self.action_count;
        const record = &self.records[index];
        record.request = request.*;
        if (request.data) |data| {
            if (data == .value) {
                if (data.value.len > max_payload_bytes) {
                    self.callback_error = error.CallbackPayloadTooLarge;
                    return;
                }
                @memcpy(record.bytes[0..data.value.len], data.value);
                record.request.data = .{ .value = record.bytes[0..data.value.len] };
            }
        }
        self.action_count += 1;
        // The emitted request points only at this bounded host-owned record, never at the borrow.
        self.reporter.record(.{ .event = "native_action", .order = index, .request = record.request }) catch |err| {
            self.callback_error = err;
        };
        if (self.callback_block_armed.swap(false, .acq_rel)) {
            if (kernel32.SetEvent(self.callback_started_event) == 0) {
                self.callback_error = error.EventOperationFailed;
                return;
            }
            const wait = kernel32.WaitForSingleObject(self.callback_release_event, self.options.timeout_ms);
            if (@intFromEnum(wait) != 0) self.callback_error = error.CallbackGateTimeout;
            self.callback_finished.store(true, .release);
        }
    }

    fn rememberError(self: *Host, err: anytype) void {
        const bytes = @errorName(err);
        const count = @min(bytes.len, self.reply.exact_error.len);
        @memcpy(self.reply.exact_error[0..count], bytes[0..count]);
        self.reply.exact_error_len = count;
    }

    fn publish(self: *Host, delta: *const schema.TreeUpdate, full: *const schema.TreeUpdate, frame: Frame) Error!void {
        const owner = (self.subclass orelse return error.OwnerCommandFailed).adapter;
        const outcome = owner.updateIfActiveBorrowedChecked(.{ .delta = delta, .current_full = full });
        self.allocator_gate.disarm();
        self.reply.allocator_failed = self.allocator_gate.failed.load(.acquire);
        switch (outcome) {
            .inactive => self.reply.disposition = .inactive,
            .rejected => |err| {
                self.reply.disposition = .rejected;
                self.rememberError(err);
            },
            .committed => |committed| {
                // Advance the host baseline before handling any postcommit notification failure.
                self.current = frame;
                self.reply.disposition = .committed;
                self.reply.used_full = committed.used_full_tree;
                if (committed.notification_error) |err| {
                    self.reply.notification_error = true;
                    self.rememberError(err);
                }
                if (committed.events) |events| {
                    if (self.pending_events != null)
                        std.debug.panic("overwriting retained native event ownership", .{});
                    self.pending_events = events;
                    const pending = &self.pending_events.?;
                    const report = pending.raise();
                    if (report.cleanup.first_error != null) return error.NotificationCleanupFailed;
                    self.pending_events = null;
                }
            },
        }
    }

    fn cleanupPending(self: *Host) void {
        if (self.pending_events) |*pending| {
            const report = pending.deinit();
            if (report.first_error) |err| {
                // Terminate with the retained holder/allocator/runtime still alive on hard failure.
                std.debug.panic("retained native event cleanup failed: {s}", .{@errorName(err)});
            }
            self.pending_events = null;
        }
    }
    fn finishOwner(self: *Host) void {
        if (self.subclass) |owner| {
            owner.free();
            self.subclass = null;
            self.userdata_live.store(false, .release);
        }
        if (!self.window_destroyed) {
            if (user32.DestroyWindow(self.hwnd) == 0)
                std.debug.panic("DestroyWindow failed during joined owner cleanup", .{});
            self.window_destroyed = true;
        }
        self.cleanupPending();
        if (self.runtime_releases.load(.acquire) != 1)
            std.debug.panic("{s}: external native authority remains live", .{@errorName(error.RuntimeNotReleased)});
        // Final COM wrapper storage is freed after RuntimeRelease, using this same allocator.
        if (self.allocator_gate.live_allocations.load(.acquire) != 0)
            std.debug.panic("NativeAllocatorNotReleased: final native wrapper storage remains live", .{});
    }

    fn retainProviders(self: *Host) Error!void {
        const owner = (self.subclass orelse return error.OwnerCommandFailed).adapter;
        var weak = owner.context.weak();
        defer weak.deinit();
        var lease = weak.lease() catch return error.ProviderOperationFailed;
        defer lease.deinit();
        const FullNodeId = kit.consumer.tree_index.FullNodeId;
        self.raw_button = lease.provider(FullNodeId.init(button_id, .init(0))) catch
            return error.ProviderOperationFailed;
        self.raw_text = lease.provider(FullNodeId.init(text_id, .init(0))) catch
            return error.ProviderOperationFailed;
        self.raw_survivor = lease.provider(FullNodeId.init(survivor_id, .init(0))) catch
            return error.ProviderOperationFailed;
        self.lifecycle_weak = owner.context.weak();
    }

    fn execute(self: *Host, command: Command, argument: u32) Error!void {
        self.reply = .{};
        const changed: usize = @intFromEnum(Frame.changed);
        switch (command) {
            .late => {
                self.current = .late;
                const late: usize = @intFromEnum(Frame.late);
                try self.publish(&self.cache.delta[late], &self.cache.full[late], .late);
            },
            .restore => {
                const late: usize = @intFromEnum(Frame.late);
                try self.publish(&self.cache.full[late], &self.cache.full[late], .late);
            },
            .missing_previous_fallback => {
                const owner = self.subclass orelse return error.OwnerCommandFailed;
                const previous = owner.previous_window_proc;
                owner.previous_window_proc = null;
                defer owner.previous_window_proc = previous;
                const title = std.unicode.utf8ToUtf16LeStringLiteral("Missing previous fallback 😀");
                const result = user32.SendMessageW(self.hwnd, messages.WM_SETTEXT, 0, @intCast(@intFromPtr(title)));
                try require(result != 0);
            },
            .publish => {
                const frame: Frame = if (argument == @intFromEnum(Frame.removed)) .removed else .changed;
                const index: usize = @intFromEnum(frame);
                try self.publish(&self.cache.delta[index], &self.cache.full[index], frame);
            },
            .invalid => try self.publish(&self.cache.invalid, &self.cache.full[changed], .changed),
            .fault => {
                self.allocator_gate.arm(argument);
                try self.publish(&self.cache.delta[changed], &self.cache.full[changed], .changed);
            },
            .retain => try self.retainProviders(),
            .native_payloads => {
                const owner = (self.subclass orelse return error.OwnerCommandFailed).adapter;
                const payload = try self.allocator_gate.allocator().dupe(u8, "x\x00y😀");
                owner.dispatchAction(.{
                    .action = .set_value,
                    .target_tree = schema.tree_id_root,
                    .target_node = text_id,
                    .data = .{ .value = payload },
                }) catch
                    return error.ProviderOperationFailed;
                owner.dispatchAction(.{
                    .action = .custom_action,
                    .target_tree = schema.tree_id_root,
                    .target_node = custom_id,
                    .data = .{ .custom_action = -7 },
                }) catch
                    return error.ProviderOperationFailed;
            },
            .close => {
                const owner = self.subclass orelse return error.OwnerCommandFailed;
                if (kernel32.SetEvent(self.close_started_event) == 0) return error.EventOperationFailed;
                owner.free();
                self.subclass = null;
                self.userdata_live.store(false, .release);
                if (user32.DestroyWindow(self.hwnd) == 0) return error.WindowOperationFailed;
                self.window_destroyed = true;
            },
        }
    }

    fn send(self: *Host, command: Command, argument: u32) Error!Reply {
        if (self.cancelled.load(.acquire)) return error.MessagePumpExhausted;
        if (user32.PostMessageW(self.hwnd, command_message, @intFromEnum(command), argument) == 0)
            return error.WindowOperationFailed;
        const waited = kernel32.WaitForSingleObject(self.reply_event, self.options.timeout_ms);
        if (@intFromEnum(waited) != 0)
            std.debug.panic(
                "{s}: owner command has not acknowledged result ownership",
                .{@errorName(if (@intFromEnum(waited) == 258)
                    error.CommandTimeout
                else
                    error.EventOperationFailed)},
            );
        if (self.cancelled.load(.acquire)) return error.MessagePumpExhausted;
        if (self.reply.failure) |err| return err;
        return self.reply;
    }

    fn clientMain(self: *Host) void {
        self.client() catch |err| {
            self.client_error = err;
        };
        if (kernel32.SetEvent(self.done_event) == 0)
            std.debug.panic("client completion SetEvent failed", .{});
    }

    fn find(
        self: *Host,
        automation: *uia.IUIAutomation,
        root: *uia.IUIAutomationElement,
        label: [:0]const u16,
    ) Error!*uia.IUIAutomationElement {
        _ = self;
        var value: com.VARIANT = undefined;
        oleaut32.VariantInit(&value);
        defer clearVariant(&value);
        value.Anonymous.Anonymous.vt = .BSTR;
        value.Anonymous.Anonymous.Anonymous.bstrVal =
            oleaut32.SysAllocStringLen(label.ptr, @intCast(label.len)) orelse
            return error.OutOfMemory;
        var condition: ?*uia.IUIAutomationCondition = null;
        try hr(automation.CreatePropertyCondition(uia.UIA_NamePropertyId, value, &condition));
        const owned_condition = condition orelse return error.NullComResult;
        defer release(owned_condition);
        var found: ?*uia.IUIAutomationElement = null;
        try hr(root.FindFirst(.Descendants, owned_condition, &found));
        return found orelse return error.NullComResult;
    }

    fn client(self: *Host) Error!void {
        try hr(ole32.CoInitializeEx(null, com.COINIT_MULTITHREADED));
        defer ole32.CoUninitialize();
        defer {
            if (self.raw_range) |value| release(value);
            if (self.raw_survivor_range) |value| release(value);
            if (self.raw_survivor) |value| release(value);
            self.raw_survivor_range = null;
            self.raw_survivor = null;
            if (self.raw_text) |value| release(value);
            if (self.raw_button) |value| release(value);
            if (self.lifecycle_weak) |*weak| weak.deinit();
            self.lifecycle_weak = null;
            self.raw_range = null;
            self.raw_text = null;
            self.raw_button = null;
        }
        var automation_pointer: *anyopaque = undefined;
        try hr(ole32.CoCreateInstance(
            uia.CLSID_CUIAutomation8,
            null,
            com.CLSCTX_INPROC_SERVER,
            uia.IID_IUIAutomation2,
            &automation_pointer,
        ));
        const automation2: *uia.IUIAutomation2 = @ptrCast(@alignCast(automation_pointer));
        defer release(automation2);
        try hr(automation2.put_ConnectionTimeout(self.options.timeout_ms));
        try hr(automation2.put_TransactionTimeout(self.options.timeout_ms));
        try hr(automation2.put_AutoSetFocus(0));
        const automation = &automation2.IUIAutomation;
        try self.checkWindowFallback();
        if (!self.placeholder) {
            const late = try self.send(.late, 0);
            try require(late.disposition == .inactive);
        }
        var element: ?*uia.IUIAutomationElement = null;
        // This is the independent OS client path into the actual HWND's WM_GETOBJECT.
        try hr(automation.ElementFromHandle(self.hwnd, &element));
        const root = element orelse return error.NullComResult;
        defer release(root);
        if (self.placeholder) {
            const published = try self.send(.publish, 0);
            try require(published.disposition == .committed);
            try require(published.used_full);
            try self.checkFull(automation, root, .changed);
            try self.reporter.passed("placeholder_selects_current_full", .{
                .used_full_tree = published.used_full,
                .all_exposed_sparse_ids_observed = true,
                .internal_text_run_content_observed = true,
            });
            const closed = try self.send(.close, 0);
            _ = closed;
            return;
        }
        try self.checkFull(automation, root, .late);
        try self.reporter.passed("inactive_late_full_contains_every_id", .{
            .root_schema_id = root_id.value,
            .root_identity_from_hwnd = true,
            .button = button_id.value,
            .slider = slider_id.value,
            .text = text_id.value,
            .internal_run_schema_id = run_id.value,
            .list = list_id.value,
            .item = item_id.value,
            .custom = custom_id.value,
            .surviving_text = survivor_id.value,
            .internal_surviving_run_schema_id = survivor_run_id.value,
            .activation_calls = self.activation_calls.load(.acquire),
        });
        const button = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Invoke late"));
        defer release(button);
        const slider = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Level"));
        defer release(slider);
        const text = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Unicode input"));
        defer release(text);
        const custom = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Sparse custom target"));
        defer release(custom);
        try self.checkProperties(button, text);
        try self.checkActions(automation, root, button, slider, text, custom);
        const text_pattern = try pattern(
            uia.IUIAutomationTextPattern,
            text,
            uia.UIA_TextPatternId,
            uia.IID_IUIAutomationTextPattern,
        );
        defer release(text_pattern);
        var range_pointer: ?*uia.IUIAutomationTextRange = null;
        try hr(text_pattern.get_DocumentRange(&range_pointer));
        const document = range_pointer orelse return error.NullComResult;
        defer release(document);
        try self.checkText(document, text_pattern);
        const retained = try self.send(.retain, 0);
        _ = retained;
        try self.prepareRawRange();
        try self.checkQueryInterface();
        const invalid = try self.send(.invalid, 0);
        try require(invalid.disposition == .rejected);
        try self.checkFull(automation, root, .late);
        try self.reporter.passed("invalid_update_preserves_sdk_queries", .{
            .error_tag = invalid.exact_error[0..invalid.exact_error_len],
            .name = "Invoke late",
        });
        try self.checkFaults(automation, root);
        try self.checkFull(automation, root, .changed);
        try nameIs(button, std.unicode.utf8ToUtf16LeStringLiteral("Invoke changed"));
        try self.checkTextValue(text, std.unicode.utf8ToUtf16LeStringLiteral("B😀ö"));
        try self.reporter.passed("sdk_delta_changes_name_and_unicode", .{
            .name = "Invoke changed",
            .utf16 = &[_]u16{ 0x42, 0xd83d, 0xde00, 0xf6 },
        });
        try self.removeAndClose(automation, root, document);
    }

    fn checkWindowFallback(self: *Host) Error!void {
        const title = std.unicode.utf8ToUtf16LeStringLiteral("Static fallback changed 😀");
        var result: usize = 0;
        if (user32.SendMessageTimeoutW(
            self.hwnd,
            messages.WM_SETTEXT,
            0,
            @intCast(@intFromPtr(title)),
            messages.SMTO_ABORTIFHUNG,
            self.options.timeout_ms,
            &result,
        ) == 0) return error.WindowOperationFailed;
        try require(result != 0);
        var buffer: [128:0]u16 = @splat(0);
        const count = user32.GetWindowTextW(self.hwnd, &buffer, buffer.len);
        try require(count > 0);
        try require(std.mem.eql(u16, buffer[0..@intCast(count)], title));
        const missing = try self.send(.missing_previous_fallback, 0);
        _ = missing;
        const missing_count = user32.GetWindowTextW(self.hwnd, &buffer, buffer.len);
        try require(missing_count > 0);
        try require(std.mem.eql(
            u16,
            buffer[0..@intCast(missing_count)],
            std.unicode.utf8ToUtf16LeStringLiteral("Missing previous fallback 😀"),
        ));
        try self.reporter.passed("static_wm_settext_previous_fallback", .{
            .title_utf16 = buffer[0..@intCast(missing_count)],
            .wm_settext_result = result,
            .previous_window_proc_temporarily_missing = true,
            .fallback = "actual_DefWindowProcW",
        });
    }

    fn checkSdkIdentity(self: *Host, element: *uia.IUIAutomationElement, id: schema.NodeId) Error!void {
        var pointer: ?*com.SAFEARRAY = null;
        try hr(element.GetRuntimeId(&pointer));
        const array = pointer orelse return error.NullComResult;
        defer destroyArray(array);
        try require(oleaut32.SafeArrayGetDim(array) == 1);
        var kind: com.VARENUM = .EMPTY;
        try hr(oleaut32.SafeArrayGetVartype(array, &kind));
        try require(kind == .I4);
        var lower: i32 = 0;
        var upper: i32 = -1;
        try hr(oleaut32.SafeArrayGetLBound(array, 1, &lower));
        try hr(oleaut32.SafeArrayGetUBound(array, 1, &upper));
        try require(upper - lower + 1 >= 4);
        var tail: [4]i32 = undefined;
        for (&tail, 0..) |*word, index| {
            var position = upper - 3 + @as(i32, @intCast(index));
            try hr(oleaut32.SafeArrayGetElement(array, &position, word));
        }
        const expected = [_]i32{
            @bitCast(@as(u32, @truncate(id.value >> 32))),
            @bitCast(@as(u32, @truncate(id.value))),
            0,
            0,
        };
        try require(std.mem.eql(i32, &tail, &expected));
        try self.reporter.record(.{
            .event = "sdk_runtime_id",
            .node = id.value,
            .actual_suffix = tail,
            .hwnd_prefix_composed_by_uia = true,
        });
    }

    fn checkFull(
        self: *Host,
        automation: *uia.IUIAutomation,
        root: *uia.IUIAutomationElement,
        frame: Frame,
    ) Error!void {
        const button_name: [:0]const u16 = switch (frame) {
            .initial => std.unicode.utf8ToUtf16LeStringLiteral("Invoke initial"),
            .late => std.unicode.utf8ToUtf16LeStringLiteral("Invoke late"),
            .changed => std.unicode.utf8ToUtf16LeStringLiteral("Invoke changed"),
            .removed => std.unicode.utf8ToUtf16LeStringLiteral("Invoke removed"),
        };
        const names = [_][:0]const u16{
            button_name,
            std.unicode.utf8ToUtf16LeStringLiteral("Level"),
            std.unicode.utf8ToUtf16LeStringLiteral("Unicode input"),
            std.unicode.utf8ToUtf16LeStringLiteral("Choices"),
            std.unicode.utf8ToUtf16LeStringLiteral("Selected choice"),
            std.unicode.utf8ToUtf16LeStringLiteral("Sparse custom target"),
            std.unicode.utf8ToUtf16LeStringLiteral("Surviving input"),
        };
        const ids = [_]schema.NodeId{
            button_id, slider_id, text_id, list_id, item_id, custom_id, survivor_id,
        };
        for (names, ids) |name, id| {
            const found = try self.find(automation, root, name);
            defer release(found);
            try nameIs(found, name);
            try self.checkSdkIdentity(found, id);
        }
        try nameIs(root, std.unicode.utf8ToUtf16LeStringLiteral("Native UIA proof"));
        const slider = try self.find(automation, root, names[1]);
        defer release(slider);
        const numeric = try pattern(
            uia.IUIAutomationRangeValuePattern,
            slider,
            uia.UIA_RangeValuePatternId,
            uia.IID_IUIAutomationRangeValuePattern,
        );
        defer release(numeric);
        var actual_numeric: f64 = 0;
        try hr(numeric.get_CurrentValue(&actual_numeric));
        try require(actual_numeric == if (frame == .changed) @as(f64, 37) else 25);
        const text = try self.find(automation, root, names[2]);
        defer release(text);
        const text_pattern = try pattern(
            uia.IUIAutomationTextPattern,
            text,
            uia.UIA_TextPatternId,
            uia.IID_IUIAutomationTextPattern,
        );
        defer release(text_pattern);
        var range: ?*uia.IUIAutomationTextRange = null;
        try hr(text_pattern.get_DocumentRange(&range));
        const owned = range orelse return error.NullComResult;
        defer release(owned);
        var value: ?Bstr = null;
        try hr(owned.GetText(-1, &value));
        defer oleaut32.SysFreeString(value);
        try expectBstr(value, if (frame == .changed)
            std.unicode.utf8ToUtf16LeStringLiteral("B😀ö")
        else
            std.unicode.utf8ToUtf16LeStringLiteral("A😀é"));
    }

    fn checkProperties(self: *Host, button: *uia.IUIAutomationElement, text: *uia.IUIAutomationElement) Error!void {
        var control_type: uia.UIA_CONTROLTYPE_ID = undefined;
        try hr(button.get_CurrentControlType(&control_type));
        try require(control_type == uia.UIA_ButtonControlTypeId);
        var focused: Bool = 0;
        try hr(text.get_CurrentHasKeyboardFocus(&focused));
        try require(focused != 0);
        var value: com.VARIANT = undefined;
        oleaut32.VariantInit(&value);
        defer clearVariant(&value);
        try hr(button.GetCurrentPropertyValue(uia.UIA_ControlTypePropertyId, &value));
        try require(value.Anonymous.Anonymous.vt == .I4);
        try require(value.Anonymous.Anonymous.Anonymous.lVal == @intFromEnum(uia.UIA_ButtonControlTypeId));
        try self.reporter.passed("sdk_name_controltype_focus_properties", .{
            .button_control_type = @intFromEnum(control_type),
            .text_has_keyboard_focus = focused,
        });
    }

    fn checkActions(
        self: *Host,
        automation: *uia.IUIAutomation,
        root: *uia.IUIAutomationElement,
        button: *uia.IUIAutomationElement,
        slider: *uia.IUIAutomationElement,
        text: *uia.IUIAutomationElement,
        custom: *uia.IUIAutomationElement,
    ) Error!void {
        const invoke = try pattern(
            uia.IUIAutomationInvokePattern,
            button,
            uia.UIA_InvokePatternId,
            uia.IID_IUIAutomationInvokePattern,
        );
        defer release(invoke);
        try hr(invoke.Invoke());
        try hr(button.SetFocus());
        const numeric = try pattern(
            uia.IUIAutomationRangeValuePattern,
            slider,
            uia.UIA_RangeValuePatternId,
            uia.IID_IUIAutomationRangeValuePattern,
        );
        defer release(numeric);
        var value: f64 = 0;
        var minimum: f64 = 0;
        var maximum: f64 = 0;
        try hr(numeric.get_CurrentValue(&value));
        try hr(numeric.get_CurrentMinimum(&minimum));
        try hr(numeric.get_CurrentMaximum(&maximum));
        try require(value == 25);
        try require(minimum == 0);
        try require(maximum == 100);
        try hr(numeric.SetValue(37));
        const value_pattern = try pattern(
            uia.IUIAutomationValuePattern,
            text,
            uia.UIA_ValuePatternId,
            uia.IID_IUIAutomationValuePattern,
        );
        defer release(value_pattern);
        const replacement = std.unicode.utf8ToUtf16LeStringLiteral("B😀ö");
        const replacement_bstr = oleaut32.SysAllocStringLen(replacement, replacement.len) orelse
            return error.OutOfMemory;
        defer oleaut32.SysFreeString(replacement_bstr);
        try hr(value_pattern.SetValue(replacement_bstr));
        const item = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Selected choice"));
        defer release(item);
        const selection = try pattern(
            uia.IUIAutomationSelectionItemPattern,
            item,
            uia.UIA_SelectionItemPatternId,
            uia.IID_IUIAutomationSelectionItemPattern,
        );
        defer release(selection);
        var selected: Bool = 0;
        try hr(selection.get_CurrentIsSelected(&selected));
        try require(selected != 0);
        try hr(selection.Select());
        // Select of the already-selected item is a no-op; removal requests a real click.
        try hr(selection.RemoveFromSelection());
        const list = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Choices"));
        defer release(list);
        const list_selection = try pattern(
            uia.IUIAutomationSelectionPattern,
            list,
            uia.UIA_SelectionPatternId,
            uia.IID_IUIAutomationSelectionPattern,
        );
        defer release(list_selection);
        var selected_array: ?*uia.IUIAutomationElementArray = null;
        try hr(list_selection.GetCurrentSelection(&selected_array));
        const selected_elements = selected_array orelse return error.NullComResult;
        defer release(selected_elements);
        var length: i32 = 0;
        try hr(selected_elements.get_Length(&length));
        try require(length == 1);
        var selected_element: ?*uia.IUIAutomationElement = null;
        try hr(selected_elements.GetElement(0, &selected_element));
        const selected_item = selected_element orelse return error.NullComResult;
        defer release(selected_item);
        try nameIs(selected_item, std.unicode.utf8ToUtf16LeStringLiteral("Selected choice"));
        const custom_invoke = try pattern(
            uia.IUIAutomationInvokePattern,
            custom,
            uia.UIA_InvokePatternId,
            uia.IID_IUIAutomationInvokePattern,
        );
        defer release(custom_invoke);
        try hr(custom_invoke.Invoke());
        try self.checkTextValue(custom, std.unicode.utf8ToUtf16LeStringLiteral("left\x00right"));
        try self.reporter.passed("sdk_custom_target_and_nul_value", .{
            .target = custom_id.value,
            .value_utf16 = &[_]u16{ 108, 101, 102, 116, 0, 114, 105, 103, 104 },
            .custom_id_pattern_available = false,
        });
        const native = try self.send(.native_payloads, 0);
        _ = native;
        try self.checkActionRecords();
        try self.reporter.passed("sdk_invoke_numeric_value_selection", .{
            .numeric_value = value,
            .minimum = minimum,
            .maximum = maximum,
            .selected_name = "Selected choice",
            .selected = selected,
        });
    }

    fn checkTextValue(self: *Host, element: *uia.IUIAutomationElement, expected: []const u16) Error!void {
        _ = self;
        const value_pattern = try pattern(
            uia.IUIAutomationValuePattern,
            element,
            uia.UIA_ValuePatternId,
            uia.IID_IUIAutomationValuePattern,
        );
        defer release(value_pattern);
        var value: ?Bstr = null;
        try hr(value_pattern.get_CurrentValue(&value));
        defer oleaut32.SysFreeString(value);
        try expectBstr(value, expected);
    }

    fn checkActionRecords(self: *Host) Error!void {
        self.callback_lock.lockUncancelable(self.io);
        defer self.callback_lock.unlock(self.io);
        if (self.callback_error) |err| return err;
        const base_count: usize = if (self.selection_action_checked) 9 else 8;
        const expected_count = base_count + @as(usize, @intFromBool(self.callback_finished.load(.acquire)));
        try require(self.action_count == expected_count);
        const actions = [_]schema.Action{
            .click, .focus, .set_value, .set_value, .click, .click, .set_value, .custom_action,
        };
        const targets = [_]schema.NodeId{
            button_id, button_id, slider_id, text_id, item_id, custom_id, text_id, custom_id,
        };
        for (actions, targets, 0..) |expected, target, index| {
            const actual = self.records[index].request;
            if (actual.action != expected or !actual.target_node.eql(target) or
                !actual.target_tree.eql(schema.tree_id_root)) return error.UnexpectedAction;
            if (expected == .click or expected == .focus) try require(actual.data == null);
        }
        if (self.selection_action_checked) {
            const selection = self.records[8].request;
            try require(selection.action == .set_text_selection);
            try require(selection.target_node.eql(text_id));
            try require(selection.target_tree.eql(schema.tree_id_root));
            try require(selection.data != null);
            try require(selection.data.? == .set_text_selection);
            const positions = selection.data.?.set_text_selection;
            try require(positions.anchor.node_id.eql(run_id));
            try require(positions.focus.node_id.eql(run_id));
            try require(positions.anchor.character_index == 1);
            try require(positions.focus.character_index == 2);
        }
        if (self.callback_finished.load(.acquire)) {
            const blocked = self.records[base_count].request;
            try require(blocked.action == .click);
            try require(blocked.target_node.eql(custom_id));
            try require(blocked.target_tree.eql(schema.tree_id_root));
            try require(blocked.data == null);
        }
        try require(self.records[2].request.data.?.numeric_value == 37);
        try require(std.mem.eql(u8, self.records[3].request.data.?.value, "B😀ö"));
        try require(std.mem.eql(u8, self.records[6].request.data.?.value, "x\x00y😀"));
        try require(self.records[7].request.data.?.custom_action == -7);
        try self.reporter.passed("native_borrowed_nul_and_sparse_custom_payload", .{
            .value_bytes = self.records[6].request.data.?.value,
            .custom_action = self.records[7].request.data.?.custom_action,
            .route = "native_dispatch_not_uia_string_parameter",
            .order = actions,
        });
    }

    fn checkText(
        self: *Host,
        document: *uia.IUIAutomationTextRange,
        text_pattern: *uia.IUIAutomationTextPattern,
    ) Error!void {
        var all: ?Bstr = null;
        try hr(document.GetText(-1, &all));
        defer oleaut32.SysFreeString(all);
        try expectBstr(all, std.unicode.utf8ToUtf16LeStringLiteral("A😀é"));
        var prefix: ?Bstr = null;
        try hr(document.GetText(3, &prefix));
        defer oleaut32.SysFreeString(prefix);
        try expectBstr(prefix, std.unicode.utf8ToUtf16LeStringLiteral("A😀"));
        var unsplit_prefix: ?Bstr = null;
        try hr(document.GetText(2, &unsplit_prefix));
        defer oleaut32.SysFreeString(unsplit_prefix);
        try expectBstr(unsplit_prefix, std.unicode.utf8ToUtf16LeStringLiteral("A"));
        const needle = std.unicode.utf8ToUtf16LeStringLiteral("😀");
        const needle_bstr = oleaut32.SysAllocStringLen(needle, needle.len) orelse
            return error.OutOfMemory;
        defer oleaut32.SysFreeString(needle_bstr);
        var found: ?*uia.IUIAutomationTextRange = null;
        const find_text_result = document.FindText(needle_bstr, 0, 0, &found);
        try exactHr(find_text_result, 0);
        try require(found == null);
        var read_only: com.VARIANT = undefined;
        oleaut32.VariantInit(&read_only);
        read_only.Anonymous.Anonymous.vt = .BOOL;
        read_only.Anonymous.Anonymous.Anonymous.boolVal = 0;
        var attribute_found: ?*uia.IUIAutomationTextRange = null;
        const find_attribute_result = document.FindAttribute(
            uia.UIA_IsReadOnlyAttributeId,
            read_only,
            0,
            &attribute_found,
        );
        try exactHr(find_attribute_result, 0);
        try require(attribute_found == null);
        var attribute: com.VARIANT = undefined;
        oleaut32.VariantInit(&attribute);
        defer clearVariant(&attribute);
        try hr(document.GetAttributeValue(uia.UIA_IsReadOnlyAttributeId, &attribute));
        try require(attribute.Anonymous.Anonymous.vt == .BOOL);
        try require(attribute.Anonymous.Anonymous.Anonymous.boolVal == 0);
        var clone_pointer: ?*uia.IUIAutomationTextRange = null;
        try hr(document.Clone(&clone_pointer));
        const clone = clone_pointer orelse return error.NullComResult;
        defer release(clone);
        var moved: i32 = 0;
        try hr(clone.MoveEndpointByUnit(.Start, .Character, 1, &moved));
        try require(moved == 1);
        var moved_text: ?Bstr = null;
        try hr(clone.GetText(-1, &moved_text));
        defer oleaut32.SysFreeString(moved_text);
        try expectBstr(moved_text, std.unicode.utf8ToUtf16LeStringLiteral("😀é"));
        try hr(clone.MoveEndpointByUnit(.End, .Character, -1, &moved));
        try require(moved == -1);
        var emoji: ?Bstr = null;
        try hr(clone.GetText(-1, &emoji));
        defer oleaut32.SysFreeString(emoji);
        try expectBstr(emoji, needle);
        var rectangles_pointer: ?*com.SAFEARRAY = null;
        try hr(clone.GetBoundingRectangles(&rectangles_pointer));
        const rectangles = rectangles_pointer orelse return error.NullComResult;
        defer destroyArray(rectangles);
        var lower: i32 = 0;
        var upper: i32 = -1;
        try hr(oleaut32.SafeArrayGetLBound(rectangles, 1, &lower));
        try hr(oleaut32.SafeArrayGetUBound(rectangles, 1, &upper));
        try require(upper - lower + 1 == 4);
        var rect: [4]f64 = undefined;
        for (&rect, 0..) |*value, index| {
            var array_index = lower + @as(i32, @intCast(index));
            try hr(oleaut32.SafeArrayGetElement(rectangles, &array_index, value));
        }
        var origin: foundation.POINT = .{ .x = 0, .y = 0 };
        if (user32.ClientToScreen(self.hwnd, &origin) == 0) return error.WindowOperationFailed;
        try require(rect[0] == @as(f64, @floatFromInt(origin.x)) + 20);
        try require(rect[1] == @as(f64, @floatFromInt(origin.y)) + 80);
        try require(rect[2] == 18);
        try require(rect[3] == 20);
        var selection_pointer: ?*uia.IUIAutomationTextRangeArray = null;
        try hr(text_pattern.GetSelection(&selection_pointer));
        const selections = selection_pointer orelse return error.NullComResult;
        defer release(selections);
        var selection_count: i32 = 0;
        try hr(selections.get_Length(&selection_count));
        try require(selection_count == 1);
        var selected_pointer: ?*uia.IUIAutomationTextRange = null;
        try hr(selections.GetElement(0, &selected_pointer));
        const selected_range = selected_pointer orelse return error.NullComResult;
        defer release(selected_range);
        var selected_text: ?Bstr = null;
        try hr(selected_range.GetText(-1, &selected_text));
        defer oleaut32.SysFreeString(selected_text);
        try expectBstr(selected_text, needle);
        var same_selection: Bool = 0;
        try hr(clone.Compare(selected_range, &same_selection));
        try require(same_selection != 0);
        try hr(clone.Select());
        self.selection_action_checked = true;
        try self.checkActionRecords();
        try self.reporter.passed("sdk_unicode_text_utf16_prefix_find_move_rectangles", .{
            .all_utf16 = bstrBytes(all),
            .prefix_utf16 = bstrBytes(prefix),
            .find_text_hresult = @as(u32, @bitCast(find_text_result)),
            .find_text_is_null = found == null,
            .find_attribute_hresult = @as(u32, @bitCast(find_attribute_result)),
            .find_attribute_is_null = attribute_found == null,
            .is_read_only = false,
            .unsplit_prefix_utf16 = bstrBytes(unsplit_prefix),
            .emoji_utf16 = bstrBytes(emoji),
            .selection_utf16 = bstrBytes(selected_text),
            .same_scalar_selection = same_selection,
            .moved_end = moved,
            .moved_start_utf16 = bstrBytes(moved_text),
            .rectangles = rect,
        });
    }

    fn rawDocument(provider: *uia.IRawElementProviderSimple) Error!*uia.ITextRangeProvider {
        var unknown: ?*com.IUnknown = null;
        try hr(provider.GetPatternProvider(uia.UIA_TextPatternId, &unknown));
        const owned = unknown orelse return error.NullComResult;
        defer _ = owned.Release();
        const text_provider = try query(uia.ITextProvider, owned, uia.IID_ITextProvider);
        defer release(text_provider);
        var range: ?*uia.ITextRangeProvider = null;
        try hr(text_provider.get_DocumentRange(&range));
        return range orelse return error.NullComResult;
    }

    fn prepareRawRange(self: *Host) Error!void {
        self.raw_range = try rawDocument(self.raw_text.?);
        self.raw_survivor_range = try rawDocument(self.raw_survivor.?);
    }

    fn checkQueryInterface(self: *Host) Error!void {
        const provider = self.raw_button.?;
        var pointer: ?*anyopaque = @ptrFromInt(1);
        const unsupported = provider.IUnknown.QueryInterface(uia.IID_IUIAutomationElement, @ptrCast(&pointer));
        try exactHr(unsupported, @bitCast(foundation.E_NOINTERFACE));
        try require(pointer == null);
        // The binding marks ppv non-null. The actual SDK COM ABI accepts this negative case.
        const NullableQuery = *const fn (
            *const com.IUnknown,
            *const sdk.zig.Guid,
            ?*?*anyopaque,
        ) callconv(.winapi) HResult;
        const actual_query: NullableQuery = @ptrCast(provider.IUnknown.vtable.QueryInterface);
        const null_output = actual_query(&provider.IUnknown, com.IID_IUnknown, null);
        try exactHr(null_output, @bitCast(foundation.E_POINTER));
        var identity: ?*anyopaque = null;
        try hr(provider.IUnknown.QueryInterface(com.IID_IUnknown, @ptrCast(&identity)));
        const actual: *com.IUnknown = @ptrCast(@alignCast(identity orelse return error.NullComResult));
        defer _ = actual.Release();
        try require(@intFromPtr(actual) == @intFromPtr(provider));
        try self.reporter.passed("actual_qi_unsupported_and_null_output", .{
            .unsupported_hresult = @as(u32, @bitCast(unsupported)),
            .output_is_null = pointer == null,
            .null_output_hresult = @as(u32, @bitCast(null_output)),
            .same_iunknown_identity = true,
        });
    }

    fn checkFaults(self: *Host, automation: *uia.IUIAutomation, root: *uia.IUIAutomationElement) Error!void {
        var precommit_seen = false;
        var postcommit_seen = false;
        for (0..self.options.fault_limit) |index| {
            const result = try self.send(.fault, @intCast(index));
            switch (result.disposition) {
                .inactive => return error.OwnerCommandFailed,
                .rejected => {
                    try require(result.allocator_failed);
                    try require(std.mem.eql(u8, result.exact_error[0..result.exact_error_len], "OutOfMemory"));
                    try self.checkFull(automation, root, .late);
                    precommit_seen = true;
                    try self.reporter.passed("precommit_oom_preserves_sdk_queries", .{
                        .allocation_offset = index,
                        .error_tag = "OutOfMemory",
                        .name = "Invoke late",
                    });
                },
                .committed => {
                    try require(!result.used_full);
                    try self.checkFull(automation, root, .changed);
                    if (result.notification_error) {
                        try require(result.allocator_failed);
                        try require(std.mem.eql(u8, result.exact_error[0..result.exact_error_len], "OutOfMemory"));
                        postcommit_seen = true;
                        try self.reporter.passed("postcommit_oom_accepts_sdk_baseline", .{
                            .allocation_offset = index,
                            .error_tag = "OutOfMemory",
                            .name = "Invoke changed",
                            .baseline_advanced_before_notifications = true,
                        });
                    }
                    if (postcommit_seen) {
                        if (!precommit_seen) return error.MissingPrecommitOom;
                        return;
                    }
                    if (!result.allocator_failed) return error.MissingPostcommitOom;
                    const restored = try self.send(.restore, 0);
                    try require(restored.disposition == .committed);
                    try require(!restored.used_full);
                    try self.checkFull(automation, root, .late);
                },
            }
        }
        return error.FaultSweepExhausted;
    }

    fn blockingInvoke(self: *Host, invoke: *uia.IUIAutomationInvokePattern) void {
        hr(ole32.CoInitializeEx(null, com.COINIT_MULTITHREADED)) catch |err| {
            self.blocking_error = err;
            return;
        };
        defer ole32.CoUninitialize();
        hr(invoke.Invoke()) catch |err| {
            self.blocking_error = err;
        };
    }

    fn observeCloseAdmission(self: *Host, weak: *windows.context.WeakContext) Error!void {
        const started = kernel32.WaitForSingleObject(self.close_started_event, self.options.timeout_ms);
        if (@intFromEnum(started) != 0) return error.CallbackGateTimeout;
        for (0..self.options.pump_rounds) |_| {
            var lease = weak.lease() catch |err| {
                if (err != error.ElementNotAvailable) return error.ProviderOperationFailed;
                try require(!self.callback_finished.load(.acquire));
                try require(self.userdata_live.load(.acquire));
                if (self.runtime_releases.load(.acquire) != 0) return error.RuntimeReleasedEarly;
                self.close_barrier_observed.store(true, .release);
                return;
            };
            lease.deinit();
            const yielded = kernel32.WaitForSingleObject(self.callback_release_event, 1);
            if (@intFromEnum(yielded) != 258) return error.EventOperationFailed;
        }
        return error.CloseAdmissionExhausted;
    }

    fn releaseBlockedCallback(self: *Host) void {
        defer if (kernel32.SetEvent(self.callback_release_event) == 0)
            std.debug.panic("callback release SetEvent failed", .{});
        var weak = self.lifecycle_weak.?;
        self.lifecycle_weak = null;
        defer weak.deinit();
        self.observeCloseAdmission(&weak) catch |err| {
            self.close_observer_error = err;
        };
    }

    fn closeWhileSdkCallbackActive(self: *Host, invoke: *uia.IUIAutomationInvokePattern) Error!void {
        self.callback_block_armed.store(true, .release);
        const blocker = std.Thread.spawn(.{}, Host.blockingInvoke, .{ self, invoke }) catch
            return error.ThreadSpawnFailed;
        var blocker_joined = false;
        defer if (!blocker_joined) blocker.join();
        errdefer if (kernel32.SetEvent(self.callback_release_event) == 0)
            std.debug.panic("error cleanup SetEvent failed", .{});
        const started = kernel32.WaitForSingleObject(self.callback_started_event, self.options.timeout_ms);
        if (@intFromEnum(started) != 0) return error.CallbackGateTimeout;
        const observer = std.Thread.spawn(.{}, Host.releaseBlockedCallback, .{self}) catch
            return error.ThreadSpawnFailed;
        var observer_joined = false;
        defer if (!observer_joined) observer.join();
        const closed = try self.send(.close, 0);
        _ = closed;
        blocker.join();
        blocker_joined = true;
        observer.join();
        observer_joined = true;
        if (self.blocking_error) |err| return err;
        if (self.close_observer_error) |err| return err;
        try require(self.close_barrier_observed.load(.acquire));
        try require(self.callback_finished.load(.acquire));
    }

    fn removeAndClose(
        self: *Host,
        automation: *uia.IUIAutomation,
        root: *uia.IUIAutomationElement,
        document: *uia.IUIAutomationTextRange,
    ) Error!void {
        const custom = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Sparse custom target"));
        defer release(custom);
        const invoke = try pattern(
            uia.IUIAutomationInvokePattern,
            custom,
            uia.UIA_InvokePatternId,
            uia.IID_IUIAutomationInvokePattern,
        );
        defer release(invoke);
        // A separate owner command publishes this prebuilt removal under the same checked API.
        const removed_index: usize = @intFromEnum(Frame.removed);
        // Stage removal through the posted command's argument rather than mutating on client thread.
        const removed = try self.send(.publish, @intCast(removed_index));
        try require(removed.disposition == .committed);
        try require(!removed.used_full);
        var property: com.VARIANT = undefined;
        oleaut32.VariantInit(&property);
        defer clearVariant(&property);
        const node_hresult = self.raw_button.?.GetPropertyValue(uia.UIA_NamePropertyId, &property);
        try exactHr(node_hresult, uia.UIA_E_ELEMENTNOTAVAILABLE);
        var text: ?Bstr = null;
        const raw_range_hresult = self.raw_range.?.GetText(-1, &text);
        defer oleaut32.SysFreeString(text);
        try exactHr(raw_range_hresult, uia.UIA_E_ELEMENTNOTAVAILABLE);
        try require(text == null);
        var client_text: ?Bstr = null;
        const client_range_hresult = document.GetText(-1, &client_text);
        defer oleaut32.SysFreeString(client_text);
        try exactHr(client_range_hresult, uia.UIA_E_ELEMENTNOTAVAILABLE);
        try self.reporter.passed("removed_retained_provider_and_range_defunct", .{
            .node_hresult = @as(u32, @bitCast(node_hresult)),
            .raw_range_hresult = @as(u32, @bitCast(raw_range_hresult)),
            .sdk_range_hresult = @as(u32, @bitCast(client_range_hresult)),
        });
        const survivor = try self.find(automation, root, std.unicode.utf8ToUtf16LeStringLiteral("Surviving input"));
        defer release(survivor);
        const survivor_pattern = try pattern(
            uia.IUIAutomationTextPattern,
            survivor,
            uia.UIA_TextPatternId,
            uia.IID_IUIAutomationTextPattern,
        );
        defer release(survivor_pattern);
        var survivor_range_pointer: ?*uia.IUIAutomationTextRange = null;
        try hr(survivor_pattern.get_DocumentRange(&survivor_range_pointer));
        const survivor_range = survivor_range_pointer orelse return error.NullComResult;
        defer release(survivor_range);
        var before_close: ?Bstr = null;
        try hr(survivor_range.GetText(-1, &before_close));
        defer oleaut32.SysFreeString(before_close);
        try expectBstr(before_close, std.unicode.utf8ToUtf16LeStringLiteral("Live Ω"));
        try hr(self.raw_survivor.?.GetPropertyValue(uia.UIA_NamePropertyId, &property));
        try require(property.Anonymous.Anonymous.vt == .BSTR);
        try expectBstr(
            property.Anonymous.Anonymous.Anonymous.bstrVal,
            std.unicode.utf8ToUtf16LeStringLiteral("Surviving input"),
        );
        clearVariant(&property);
        var raw_before_close: ?Bstr = null;
        try hr(self.raw_survivor_range.?.GetText(-1, &raw_before_close));
        defer oleaut32.SysFreeString(raw_before_close);
        try expectBstr(raw_before_close, std.unicode.utf8ToUtf16LeStringLiteral("Live Ω"));
        try self.closeWhileSdkCallbackActive(invoke);
        if (self.runtime_releases.load(.acquire) != 0) return error.RuntimeReleasedEarly;
        try require(!self.userdata_live.load(.acquire));
        const after_close = self.raw_survivor.?.GetPropertyValue(uia.UIA_NamePropertyId, &property);
        try exactHr(after_close, uia.UIA_E_ELEMENTNOTAVAILABLE);
        var raw_after_close: ?Bstr = null;
        const closed_raw_range = self.raw_survivor_range.?.GetText(-1, &raw_after_close);
        defer oleaut32.SysFreeString(raw_after_close);
        try exactHr(closed_raw_range, uia.UIA_E_ELEMENTNOTAVAILABLE);
        try require(raw_after_close == null);
        var sdk_after_close: ?Bstr = null;
        const closed_sdk_range = survivor_range.GetText(-1, &sdk_after_close);
        defer oleaut32.SysFreeString(sdk_after_close);
        try exactHr(closed_sdk_range, uia.UIA_E_ELEMENTNOTAVAILABLE);
        try require(sdk_after_close == null);
        try self.reporter.passed("closed_retained_live_provider_and_range_defunct", .{
            .before_close_utf16 = bstrBytes(before_close),
            .before_close_raw_utf16 = bstrBytes(raw_before_close),
            .provider_hresult = @as(u32, @bitCast(after_close)),
            .raw_range_hresult = @as(u32, @bitCast(closed_raw_range)),
            .sdk_range_hresult = @as(u32, @bitCast(closed_sdk_range)),
        });
        try self.checkActionRecords();
        try self.reporter.passed("close_joins_callbacks_before_userdata_release", .{
            .userdata_live = self.userdata_live.load(.acquire),
            .callbacks_copied = self.action_count,
            .close_admission_refused_while_callback_alive = self.close_barrier_observed.load(.acquire),
            .blocked_sdk_callback_finished = self.callback_finished.load(.acquire),
            .after_close_hresult = @as(u32, @bitCast(after_close)),
        });
        // The owner thread checks final runtime release only after the worker releases every SDK ref.
    }
};

fn closeHandle(handle: foundation.HANDLE) void {
    if (kernel32.CloseHandle(handle) == 0) std.debug.panic("CloseHandle failed", .{});
}

fn ownerPump(host: *Host) Error!void {
    const wait_handles = [_]?foundation.HANDLE{host.done_event};
    for (0..host.options.pump_rounds) |_| {
        const wait = user32.MsgWaitForMultipleObjectsEx(
            1,
            &wait_handles,
            10,
            messages.QS_ALLINPUT,
            messages.MWMO_INPUTAVAILABLE,
        );
        if (wait == 0) return;
        if (wait != 1 and wait != 258) return error.EventOperationFailed;
        var message: messages.MSG = undefined;
        var batch: usize = 0;
        while (batch < max_message_batch and
            user32.PeekMessageW(&message, null, 0, 0, messages.PM_REMOVE) != 0) : (batch += 1)
        {
            if (message.message == command_message and message.hwnd == host.hwnd) {
                const command = std.enums.fromInt(Command, message.wParam) orelse
                    return error.OwnerCommandFailed;
                if (!host.cancelled.load(.acquire)) {
                    host.execute(command, @intCast(message.lParam)) catch |err| {
                        host.allocator_gate.disarm();
                        host.reply.failure = err;
                    };
                }
                if (kernel32.SetEvent(host.reply_event) == 0) return error.EventOperationFailed;
            } else {
                _ = user32.TranslateMessage(&message);
                _ = user32.DispatchMessageW(&message);
            }
        }
        if (batch == max_message_batch) return error.MessageBatchExhausted;
    }
    return error.MessagePumpExhausted;
}

fn runScenario(init: std.process.Init, reporter: *Reporter, options: Options, placeholder: bool) !void {
    var cache = try Cached.init(init.gpa);
    defer cache.deinit(init.gpa);
    var gate: FaultAllocator = .{ .inner = init.gpa };
    const static_class = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const title = std.unicode.utf8ToUtf16LeStringLiteral("Native UIA hidden proof");
    const hwnd = user32.CreateWindowExW(
        .{},
        static_class,
        title,
        .{ .POPUP = 1 },
        100,
        100,
        400,
        240,
        null,
        null,
        null,
        null,
    ) orelse return error.WindowCreationFailed;
    var window_destroyed = false;
    defer if (!window_destroyed and user32.DestroyWindow(hwnd) == 0)
        std.debug.panic("DestroyWindow failed", .{});
    const reply_event = kernel32.CreateEventW(null, 0, 0, null) orelse return error.EventOperationFailed;
    defer closeHandle(reply_event);
    const done_event = kernel32.CreateEventW(null, 1, 0, null) orelse return error.EventOperationFailed;
    defer closeHandle(done_event);
    const callback_started = kernel32.CreateEventW(null, 1, 0, null) orelse return error.EventOperationFailed;
    defer closeHandle(callback_started);
    const callback_release = kernel32.CreateEventW(null, 1, 0, null) orelse return error.EventOperationFailed;
    defer closeHandle(callback_release);
    const close_started = kernel32.CreateEventW(null, 1, 0, null) orelse return error.EventOperationFailed;
    defer closeHandle(close_started);
    var host: Host = .{
        .io = init.io,
        .gpa = init.gpa,
        .reporter = reporter,
        .options = options,
        .hwnd = hwnd,
        .reply_event = reply_event,
        .done_event = done_event,
        .cache = &cache,
        .allocator_gate = &gate,
        .placeholder = placeholder,
        .callback_started_event = callback_started,
        .callback_release_event = callback_release,
        .close_started_event = close_started,
    };
    defer window_destroyed = host.window_destroyed;
    defer host.cleanupPending();
    const automation_api = windows.syscalls.nativeAutomationApi() orelse return error.NativeUnsupported;
    const runtime = try init.gpa.create(Runtime);
    runtime.* = .{
        .gpa = init.gpa,
        .threaded = std.Io.Threaded.init(init.gpa, .{}),
        .released = &host.runtime_releases,
    };
    var runtime_caller_owned = true;
    defer if (runtime_caller_owned) Runtime.relinquish(runtime);
    // The outer subclass constructor takes the authority only on final success.
    host.subclass = try windows.WindowsSubclassingAdapter.create(gate.allocator(), .{
        .io = runtime.threaded.io(),
        .platform = windows.syscalls.platformForCurrentTarget(),
        .factory = windows.nativeFactory(),
        .automation = automation_api,
        .hwnd = @ptrCast(hwnd),
        .is_window_focused = true,
        .action_sink = .{ .native = .{ .callback = Host.action, .userdata = &host } },
        .runtime_release = .{ .userdata = runtime, .release = Runtime.relinquish },
    }, windows.syscalls.windowApiForCurrentTarget(), .{
        .native = .{ .callback = Host.activation, .userdata = &host },
    });
    if (host.subclass == null) return error.SubclassRefused;
    runtime_caller_owned = false;
    defer host.finishOwner();
    const client = try std.Thread.spawn(.{}, Host.clientMain, .{&host});
    ownerPump(&host) catch |err| {
        host.cancelled.store(true, .release);
        if (kernel32.SetEvent(reply_event) == 0)
            std.debug.panic("cancellation SetEvent failed with a live SDK worker", .{});
        // Continue servicing any in-flight real COM call while cancellation unwinds the worker.
        ownerPump(&host) catch |cleanup_error| {
            std.log.err(
                "bounded UIA cleanup failed: {s}; original: {s}",
                .{ @errorName(cleanup_error), @errorName(err) },
            );
            std.process.exit(1);
        };
        client.join();
        return err;
    };
    client.join();
    host.finishOwner();
    if (host.client_error) |err| return err;
    if (host.callback_error) |err| return err;
    try reporter.passed("retained_com_keeps_runtime_until_final_release", .{
        .runtime_releases = host.runtime_releases.load(.acquire),
        .native_allocations_remaining = host.allocator_gate.live_allocations.load(.acquire),
        .owner_closed_before_window_destroy = true,
        .placeholder_scenario = placeholder,
    });
}

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const options = try Options.parse(args);
    var output_buffer: [8192]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &output_buffer);
    var reporter: Reporter = .{ .io = init.io, .writer = &output.interface };
    try reporter.record(.{
        .program = "windows_native_client",
        .proof = "real_windows_sdk_only",
        .expected_cases = expected_cases,
        .timeout_ms = options.timeout_ms,
        .pump_rounds = options.pump_rounds,
        .fault_limit = options.fault_limit,
    });
    try runScenario(init, &reporter, options, false);
    try runScenario(init, &reporter, options, true);
    try reporter.record(.{ .status = "pass", .native_execution = true });
}
