//! Events from one committed update, with copied scalar payloads and no node borrows.
//!
//! The queue borrows its adapter until release. A null node names `HOST_VIEW_ID`.
//! Other nodes resolve through the adapter's ID map, without allocation during raise.
//!
//! Raise runs on the UI thread. Each nonempty raise checks accessibility through
//! the host's current context before parent lookup, package lookup, or event creation.
//! Disabled accessibility skips the batch. Empty queues perform no JNI work.
//! A pending exception stops dispatch and leaves the raised prefix intact.
//! Every acquired local reference is released, including failed acquisitions.
//!
//! `docs/52-translation-ledger.md` rows 476 and 520 record the scroll and gate sources.
//! Dispatch is bounded by the queue length at entry. Member census loops use array lengths.

const std = @import("std");

const adapter_module = @import("adapter.zig");
const consumer = @import("../../consumer/root.zig");
const java_call = @import("java_call.zig");
const jni = @import("jni_table.zig");
const schema = @import("../../schema/root.zig");
const values = @import("values.zig");

const AndroidAdapter = adapter_module.AndroidAdapter;
const CallError = java_call.CallError;
const FullNodeId = consumer.tree_index.FullNodeId;
const JClass = jni.JClass;
const JInt = values.JInt;
const JniEnv = jni.JniEnv;
const JniTable = jni.JniTable;
const JObject = jni.JObject;
const JString = jni.JString;
const JValue = jni.JValue;

const Allocator = std.mem.Allocator;

const testing = std.testing;

/// `AccessibilityEvent.obtain(int)`, the only way an event is built.
///
/// It is static, and `raise` reaches it through `callStaticObjectChecked` rather
/// than `callObjectChecked`, which would look for an instance method.
const event_obtain: java_call.Member = .{
    .class = .{
        .descriptor = "Landroid/view/accessibility/AccessibilityEvent;",
        .internal_name = "android/view/accessibility/AccessibilityEvent",
    },
    .name = "obtain",
    .signature = "(I)Landroid/view/accessibility/AccessibilityEvent;",
};

/// `AccessibilityEvent.setPackageName(CharSequence)`, `docs/29` row 31.
const event_set_package_name: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setPackageName",
    .signature = "(Ljava/lang/CharSequence;)V",
};

/// `AccessibilityEvent.setSource(View, int)`, `docs/29` row 32.
const event_set_source: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setSource",
    .signature = "(Landroid/view/View;I)V",
};

/// `AccessibilityEvent.setContentChangeTypes(int)`, `docs/29` row 33.
const event_set_content_change_types: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setContentChangeTypes",
    .signature = "(I)V",
};

/// Scroll setters follow pinned `event.rs:270-287`. Numeric setters use `(I)V`.
const event_set_scrollable: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setScrollable",
    .signature = "(Z)V",
};
const event_set_scroll_x: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setScrollX",
    .signature = "(I)V",
};
const event_set_scroll_delta_x: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setScrollDeltaX",
    .signature = "(I)V",
};
const event_set_max_scroll_x: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setMaxScrollX",
    .signature = "(I)V",
};
const event_set_scroll_y: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setScrollY",
    .signature = "(I)V",
};
const event_set_scroll_delta_y: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setScrollDeltaY",
    .signature = "(I)V",
};
const event_set_max_scroll_y: java_call.Member = .{
    .class = event_obtain.class,
    .name = "setMaxScrollY",
    .signature = "(I)V",
};

/// `View.getParent()`, `docs/29` row 35.
const view_get_parent: java_call.Member = .{
    .class = .{
        .descriptor = "Landroid/view/View;",
        .internal_name = "android/view/View",
    },
    .name = "getParent",
    .signature = "()Landroid/view/ViewParent;",
};

/// `View.getContext()`, pinned `util.rs:209-212` and ledger row 520.
const view_get_context: java_call.Member = .{
    .class = view_get_parent.class,
    .name = "getContext",
    .signature = "()Landroid/content/Context;",
};

/// `ViewParent.requestSendAccessibilityEvent(View, AccessibilityEvent)`.
/// Pinned `event.rs:52-70` and Android's ViewParent API specify a boolean result.
const parent_request_send: java_call.Member = .{
    .class = .{
        .descriptor = "Landroid/view/ViewParent;",
        .internal_name = "android/view/ViewParent",
    },
    .name = "requestSendAccessibilityEvent",
    .signature = "(Landroid/view/View;Landroid/view/accessibility/AccessibilityEvent;)Z",
};

/// `Context.getPackageName()`, pinned `util.rs:215-224`.
const context_get_package_name: java_call.Member = .{
    .class = .{
        .descriptor = "Landroid/content/Context;",
        .internal_name = "android/content/Context",
    },
    .name = "getPackageName",
    .signature = "()Ljava/lang/String;",
};

/// Pinned `util.rs:234-239` gets the service named `"accessibility"`.
const context_get_system_service: java_call.Member = .{
    .class = context_get_package_name.class,
    .name = "getSystemService",
    .signature = "(Ljava/lang/String;)Ljava/lang/Object;",
};

/// Android documents `AccessibilityManager.isEnabled()` as `public boolean`.
/// Source: https://developer.android.com/reference/android/view/accessibility/AccessibilityManager
const manager_is_enabled: java_call.Member = .{
    .class = .{
        .descriptor = "Landroid/view/accessibility/AccessibilityManager;",
        .internal_name = "android/view/accessibility/AccessibilityManager",
    },
    .name = "isEnabled",
    .signature = "()Z",
};

/// Reachable members without a source-pinned descriptor. The census is empty.
pub const unpinned_members = [0]java_call.Member{};

/// How many rows `unpinned_members` holds.
pub const unpinned_member_count = unpinned_members.len;

/// Distinct Java members reachable across all event variants.
pub const raised_member_count = 17;

/// Members in first-call order, with alternative payload setters adjacent.
pub const raised_members = [raised_member_count]java_call.Member{
    view_get_context,
    context_get_system_service,
    manager_is_enabled,
    view_get_parent,
    context_get_package_name,
    event_obtain,
    event_set_package_name,
    event_set_source,
    event_set_content_change_types,
    event_set_scrollable,
    event_set_scroll_x,
    event_set_scroll_delta_x,
    event_set_max_scroll_x,
    event_set_scroll_y,
    event_set_scroll_delta_y,
    event_set_max_scroll_y,
    parent_request_send,
};

/// One changed scroll axis in Android integer units. Copies own no resources.
/// `max = null` omits the maximum setter, while zero remains a present maximum.
pub const ScrollDimension = struct {
    current: JInt,
    delta: JInt,
    max: ?JInt,
};

/// Independent event payloads copied by value. A null node names the host view.
/// An absent scroll axis omits its setters. Payloads retain no node references.
pub const QueuedEvent = union(enum) {
    simple_event: struct { event_type: JInt, node: ?FullNodeId },
    content_changed: struct { node: ?FullNodeId, content_change_types: JInt },
    scrolled: struct { node: ?FullNodeId, x: ?ScrollDimension, y: ?ScrollDimension },

    /// An event with no additional payload.
    pub fn simple(event_type: JInt, node: ?FullNodeId) QueuedEvent {
        return .{ .simple_event = .{ .event_type = event_type, .node = node } };
    }

    /// A content-change event with its exact flags, including zero.
    pub fn contentChanged(node: ?FullNodeId, content_change_types: JInt) QueuedEvent {
        return .{ .content_changed = .{
            .node = node,
            .content_change_types = content_change_types,
        } };
    }

    /// The node named by any variant, or null for the host view.
    pub fn nodeId(self: QueuedEvent) ?FullNodeId {
        return switch (self) {
            inline else => |payload| payload.node,
        };
    }

    /// The Android event type selected by the payload.
    pub fn eventType(self: QueuedEvent) JInt {
        return switch (self) {
            .simple_event => |payload| payload.event_type,
            .content_changed => values.EVENT_WINDOW_CONTENT_CHANGED,
            .scrolled => values.EVENT_VIEW_SCROLLED,
        };
    }
};

/// Counts for the entire batch, with the first exact failure beside the raised prefix.
pub const RaiseReport = struct {
    /// How many events Android took.
    raised: usize = 0,
    /// Events skipped for disabled accessibility, absent IDs, or refused parent sends.
    skipped: usize = 0,
    /// How many were not sent because a lookup failed or a call threw.
    failed: usize = 0,
    /// The first checked-call failure, or null when no JNI operation failed.
    failure: ?CallError = null,

    /// How many events the report accounts for in total.
    pub fn total(self: RaiseReport) usize {
        return self.raised + self.skipped + self.failed;
    }
};

/// The events one adapter call produced, boxed so a C handle can name them.
///
/// `accesskit_android_queued_events_raise` is the only way to release one, so
/// the type is opaque to a C caller. **The adapter must outlive every handle
/// from it**, which is what the `adapter` field is for: the virtual ids the
/// events name live in the adapter's `node_id_map`.
pub const AndroidQueuedEvents = struct {
    /// The allocator that grew the array. It is the C ABI's declared one,
    /// because the block itself comes from `allocation.create`.
    gpa: Allocator,

    /// The adapter that minted this queue. **Borrowed, never owned.** It must
    /// outlive this value and every call on it.
    adapter: *AndroidAdapter,

    /// The events, in the order they are sent.
    events: std.ArrayList(QueuedEvent),

    /// An empty queue. Nothing is allocated, so this call cannot fail.
    pub fn init(gpa: Allocator, adapter: *AndroidAdapter) AndroidQueuedEvents {
        return .{ .gpa = gpa, .adapter = adapter, .events = .empty };
    }

    /// Releases the array and leaves the value empty.
    ///
    /// This does not release the block the value was allocated in; the raise
    /// does that, because the raise is the only call the C surface offers.
    ///
    /// The last line is the reset: `self.*` is one whole `AndroidQueuedEvents`
    /// with every field at the value `init` gives it. That is the Z030 shape,
    /// and the rule reads an assignment to `self.*` as a plain write rather
    /// than as a reset, so this comment says why the assignment is there. The
    /// test `deinit leaves the queue empty and a second deinit releases
    /// nothing` is what holds the promise, and it fails under `undefined`,
    /// because the second call reads `self.gpa` out of undefined memory.
    pub fn deinit(self: *AndroidQueuedEvents) void {
        const gpa = self.gpa;
        const adapter = self.adapter;
        self.events.deinit(gpa);
        // SAFETY: the line above released the only buffer this value owned, and
        // the reset is what a stale read sees. The allocator owns no memory and
        // the adapter is borrowed, so neither has anything to invalidate.
        self.* = .{ .gpa = gpa, .adapter = adapter, .events = .empty };
    }

    /// Adds one event at the end of the queue.
    ///
    /// `error.OutOfMemory` leaves the queue unchanged.
    pub fn append(self: *AndroidQueuedEvents, event: QueuedEvent) Allocator.Error!void {
        try self.events.append(self.gpa, event);
    }

    /// How many events the queue carries.
    pub fn len(self: *const AndroidQueuedEvents) usize {
        return self.events.items.len;
    }

    /// Sends events on the UI thread without consuming the queue.
    ///
    /// Empty queues perform no JNI calls. Disabled accessibility skips every event.
    /// Gate or preamble failure fails the whole batch. A pending exception stops
    /// further dispatch and counts its unsent remainder as failed.
    /// Other event failures retain the first exact tag and allow later events.
    /// Every local reference is released. No manager or enabled result is cached.
    pub fn raise(self: *const AndroidQueuedEvents, table: JniTable, host: JObject) RaiseReport {
        var report: RaiseReport = .{};
        const event_count = self.events.items.len;
        if (event_count == 0) return report;
        if (table.exceptionCheck()) {
            report.failure = error.JavaException;
            report.failed = event_count;
            return report;
        }
        const enabled = accessibilityEnabled(table, host) catch |err| {
            report.failure = err;
            report.failed = event_count;
            return report;
        };
        if (!enabled) {
            report.skipped = event_count;
            return report;
        }
        const parent = java_call.callObjectChecked(table, host, view_get_parent, &.{}) catch |err| {
            report.failure = err;
            report.failed = event_count;
            return report;
        };
        defer table.deleteLocalRef(parent);

        const package = packageNameOf(table, host) catch |err| {
            report.failure = err;
            report.failed = event_count;
            return report;
        };
        defer table.deleteLocalRef(package);

        for (self.events.items[0..event_count], 0..) |event, index| {
            const virtual_id = self.virtualIdOf(event) orelse {
                report.skipped += 1;
                continue;
            };
            const sent = sendOne(table, host, parent, package, virtual_id, event) catch |err| {
                if (report.failure == null) report.failure = err;
                if (err == error.JavaException) {
                    report.failed += event_count - index;
                    break;
                }
                report.failed += 1;
                continue;
            };
            if (sent) report.raised += 1 else report.skipped += 1;
        }
        return report;
    }

    /// The virtual view id `event` names, or `null` when the queue cannot name
    /// one.
    ///
    /// A `null` node means the host view, which Android names
    /// `values.HOST_VIEW_ID`. A node the adapter has never filled has no virtual
    /// id, and that is a skip rather than a failure: the platform asked about a
    /// node the tree does not expose, and sending an event with a made-up id
    /// would name a different node.
    fn virtualIdOf(self: *const AndroidQueuedEvents, event: QueuedEvent) ?JInt {
        const node = event.nodeId() orelse return values.HOST_VIEW_ID;
        return self.adapter.idMap().getJavaId(node);
    }

    /// One current-context manager lookup for this nonempty raise.
    fn accessibilityEnabled(table: JniTable, host: JObject) CallError!bool {
        const context = try java_call.callObjectChecked(table, host, view_get_context, &.{});
        defer table.deleteLocalRef(context);
        const service_name = table.newString("accessibility");
        defer if (service_name != null) table.deleteLocalRef(service_name);
        if (table.exceptionCheck()) return error.JavaException;
        if (service_name == null) return error.OutOfMemory;
        const manager = try java_call.callObjectChecked(
            table,
            context,
            context_get_system_service,
            &.{.{ .l = service_name }},
        );
        defer table.deleteLocalRef(manager);
        return java_call.callBooleanChecked(table, manager, manager_is_enabled, &.{});
    }

    /// The host's package name, or the failure the lookup produced.
    ///
    /// Two calls and two released references per raise rather than per event,
    /// because every event in one batch carries the same package name.
    fn packageNameOf(table: JniTable, host: JObject) CallError!JString {
        const context = try java_call.callObjectChecked(table, host, view_get_context, &.{});
        defer table.deleteLocalRef(context);
        return java_call.callObjectChecked(table, context, context_get_package_name, &.{});
    }

    /// Builds one event, fills it and sends it, releasing what it built.
    fn sendOne(
        table: JniTable,
        host: JObject,
        parent: JObject,
        package: JString,
        virtual_id: JInt,
        event: QueuedEvent,
    ) CallError!bool {
        const object = try java_call.callStaticObjectChecked(
            table,
            event_obtain,
            &.{.{ .i = event.eventType() }},
        );
        // Cleanup is permitted while the exception remains pending.
        defer table.deleteLocalRef(object);

        try java_call.callVoidChecked(
            table,
            object,
            event_set_package_name,
            &.{.{ .l = package }},
        );
        try java_call.callVoidChecked(
            table,
            object,
            event_set_source,
            &.{ .{ .l = host }, .{ .i = virtual_id } },
        );
        switch (event) {
            .simple_event => {},
            .content_changed => |payload| try java_call.callVoidChecked(
                table,
                object,
                event_set_content_change_types,
                &.{.{ .i = payload.content_change_types }},
            ),
            .scrolled => |payload| {
                try java_call.callVoidChecked(
                    table,
                    object,
                    event_set_scrollable,
                    &.{.{ .z = 1 }},
                );
                if (payload.x) |axis| {
                    try java_call.callVoidChecked(
                        table,
                        object,
                        event_set_scroll_x,
                        &.{.{ .i = axis.current }},
                    );
                    try java_call.callVoidChecked(
                        table,
                        object,
                        event_set_scroll_delta_x,
                        &.{.{ .i = axis.delta }},
                    );
                    if (axis.max) |max| try java_call.callVoidChecked(
                        table,
                        object,
                        event_set_max_scroll_x,
                        &.{.{ .i = max }},
                    );
                }
                if (payload.y) |axis| {
                    try java_call.callVoidChecked(
                        table,
                        object,
                        event_set_scroll_y,
                        &.{.{ .i = axis.current }},
                    );
                    try java_call.callVoidChecked(
                        table,
                        object,
                        event_set_scroll_delta_y,
                        &.{.{ .i = axis.delta }},
                    );
                    if (axis.max) |max| try java_call.callVoidChecked(
                        table,
                        object,
                        event_set_max_scroll_y,
                        &.{.{ .i = max }},
                    );
                }
            },
        }
        return java_call.callBooleanChecked(
            table,
            parent,
            parent_request_send,
            &.{ .{ .l = host }, .{ .l = object } },
        );
    }
};

comptime {
    // Every row carries a descriptor, because `GetMethodID` takes three strings
    // and a missing one is a `null` on a device.
    for (raised_members) |member| {
        if (member.signature.len == 0) @compileError("a member must carry a descriptor");
        if (member.class.descriptor.len == 0) @compileError("a member must name its class");
    }
    // The recorder names each call from its method ID, so names must be distinct.
    for (raised_members, 0..) |member, index| {
        for (raised_members[index + 1 ..], 0..) |other, offset| {
            if (std.mem.eql(u8, member.name, other.name)) {
                @compileError(std.fmt.comptimePrint(
                    "two raised members share the name {s}",
                    .{member.name},
                ));
            }
            _ = offset;
        }
    }
    // The unpinned rows must remain a subset of the reachable member census.
    for (unpinned_members) |member| {
        var found = false;
        for (raised_members) |raised| {
            if (std.mem.eql(u8, member.name, raised.name)) found = true;
        }
        if (!found) @compileError("an unpinned row must be one the raise reaches");
    }
    if (unpinned_member_count != 0) @compileError("all raised members have pinned descriptors");
}

// --- Tests --------------------------------------------------------------------

/// The first fabricated handle, so a fabricated handle is never the JNI null.
const handle_base = 0x4000;

/// A fabricated node id. A raise resolves it through the adapter's id map.
fn fixtureNode(value: u64) FullNodeId {
    return FullNodeId.init(.{ .value = value }, .init(0));
}

/// A fabricated host view no helper ever dereferences.
fn fakeHost() JObject {
    return @ptrFromInt(handle_base + 4);
}

/// The row of `raised_members` that `name` names, or `raised_member_count`.
fn memberRowOf(name: [:0]const u8) usize {
    for (raised_members, 0..) |member, index| {
        if (std.mem.eql(u8, member.name, name)) return index;
    }
    return raised_member_count;
}

/// What one table answered, kept where a test reads it.
///
/// The recorder owns no memory and returns no error, so a test drives the whole
/// raise with no failing allocator in the middle of a recorded call.
const Recorder = struct {
    /// What `findClass` answers.
    class_missing: bool = false,
    /// What `getMethodId` answers.
    method_missing: bool = false,
    /// How many member calls may succeed before one leaves an exception
    /// pending. `raise` counts them, so a test can make the Nth call throw.
    calls_before_throw: usize = std.math.maxInt(usize),
    /// How many member calls arrived.
    calls: usize = 0,
    /// What `callObjectMethod` and `callStaticObjectMethod` answer.
    object_answer: JObject = @ptrFromInt(handle_base + 1),
    /// How many sends arrived, which is one per raised event.
    sends: usize = 0,
    /// The source virtual id of the last send, so a test can see which id went.
    last_source_id: JInt = 0,
    /// The event type of the last `obtain`, so a test can see which type went.
    last_event_type: JInt = 0,
    /// The content change types of the last `setContentChangeTypes`, or `-1`
    /// when that call never arrived.
    last_content_change_types: JInt = -1,
    /// How many local references were released.
    released: usize = 0,
    /// How many member lookups arrived, which is how a test sees that no member
    /// is resolved twice inside one raise.
    lookups: usize = 0,
    /// Gate and send responses are independent.
    enabled: bool = true,
    refuse_send: bool = false,
    /// Gate calls are counted separately from delivery.
    gate_calls: usize = 0,
    fault: Fault = .none,
    fault_name: []const u8 = "",
    fault_once: bool = false,
    fault_used: bool = false,
    pending_exception: bool = false,
    acquired: usize = 0,
    work_after_exception: usize = 0,
    service_strings: usize = 0,
    exception_checks: usize = 0,
    trace: [128]struct { row: usize, first: JInt = 0 } = undefined,
    trace_len: usize = 0,
    send_args_valid: bool = true,
    live_refs: [128]JObject = @splat(null),
    last_event_object: JObject = null,

    fn acquire(self: *Recorder) JObject {
        std.debug.assert(self.acquired < self.live_refs.len);
        const object: JObject = @ptrFromInt(handle_base + 100 + self.acquired);
        self.live_refs[self.acquired] = object;
        self.acquired += 1;
        return object;
    }

    fn release(self: *Recorder, object: JObject) void {
        std.debug.assert(object != null);
        for (self.live_refs[0..self.acquired]) |*live| {
            if (live.* == object) {
                live.* = null;
                self.released += 1;
                return;
            }
        }
        @panic("released an unowned or already released local reference");
    }

    const Fault = enum {
        none,
        missing_class,
        missing_method,
        null_result,
        throw_class,
        throw_method,
        throw_call,
        string_oom,
        string_throw,
    };

    fn work(self: *Recorder) void {
        if (self.pending_exception or throwing(self)) self.work_after_exception += 1;
    }

    fn record(self: *Recorder, method: jni.JMethodId, args: []const JValue) void {
        self.work();
        const row = memberRowOfMethod(method);
        std.debug.assert(self.trace_len < self.trace.len);
        const name = raised_members[row].name;
        const numeric = std.mem.startsWith(u8, name, "setScroll") or
            std.mem.startsWith(u8, name, "setMax");
        if (numeric) std.debug.assert(args.len == 1);
        self.trace[self.trace_len] = .{
            .row = row,
            .first = if (args.len == 1 and std.mem.eql(u8, name, "setScrollable"))
                @intCast(args[0].z)
            else if (args.len == 1 and numeric) args[0].i else 0,
        };
        self.trace_len += 1;
        self.calls += 1;
        if (self.fault == .throw_call and std.mem.eql(u8, self.fault_name, name))
            self.pending_exception = true;
    }
};

fn recorderOf(env: JniEnv) ?*Recorder {
    const handle = env orelse return null;
    // SAFETY: the table parks the recorder as `.env`, which is
    // `?*const anyopaque`, so the const belongs to the table and not to the
    // recorder, and the alignment is the one the recorder was declared with.
    return @ptrCast(@alignCast(@constCast(handle)));
}

/// Whether the recorder has passed its throw point.
fn throwing(recorder: *const Recorder) bool {
    return recorder.calls >= recorder.calls_before_throw;
}

fn answeredFindClass(env: JniEnv, name: [:0]const u8) JClass {
    const recorder = recorderOf(env) orelse return null;
    recorder.work();
    const selected = std.mem.eql(u8, recorder.fault_name, name);
    if (recorder.class_missing or selected and recorder.fault == .missing_class) return null;
    const object = recorder.acquire();
    if (selected and recorder.fault == .throw_class) recorder.pending_exception = true;
    return object;
}

fn answeredGetMethodId(
    env: JniEnv,
    _: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) jni.JMethodId {
    const recorder = recorderOf(env) orelse return null;
    recorder.work();
    const selected = std.mem.eql(u8, recorder.fault_name, name);
    if (selected and recorder.fault == .throw_method) recorder.pending_exception = true;
    if (selected and recorder.fault == .missing_method and
        (!recorder.fault_once or !recorder.fault_used))
    {
        recorder.fault_used = true;
        return null;
    }
    if (recorder.method_missing) return null;
    recorder.lookups += 1;
    const row = memberRowOf(name);
    if (row == raised_member_count) return null;
    const methods = @import("methods.zig");
    if (methods.findById(raised_members[row].class.descriptor, name, signature) == null)
        return null;
    return @ptrFromInt(handle_base + 10 + row);
}

fn answeredGetStaticMethodId(
    env: JniEnv,
    _: JClass,
    name: [:0]const u8,
    signature: [:0]const u8,
) jni.JMethodId {
    return answeredGetMethodId(env, null, name, signature);
}

fn answeredGetStaticFieldId(
    env: JniEnv,
    _: JClass,
    _: [:0]const u8,
    _: [:0]const u8,
) jni.JFieldId {
    _ = env;
    return null;
}

fn answeredStaticObjectField(env: JniEnv, _: JClass, _: jni.JFieldId) JObject {
    _ = env;
    return null;
}

/// One member call that answers a reference.
///
/// `static_only` is the static variant of the same slot; the raise reaches
/// `AccessibilityEvent.obtain` through it and nothing else.
fn answeredCall(
    env: JniEnv,
    method: jni.JMethodId,
    args: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    recorder.record(method, args);
    const row = memberRowOfMethod(method);
    if (recorder.fault == .null_result and
        std.mem.eql(u8, recorder.fault_name, raised_members[row].name)) return null;
    if (throwing(recorder) and !recorder.pending_exception) return null;
    const object = if (recorder.object_answer != null) recorder.acquire() else null;
    if (memberRowOfMethod(method) == memberRowOf(event_obtain.name) and args.len == 1) {
        recorder.last_event_type = args[0].i;
        recorder.last_event_object = object;
    }
    return object;
}

fn answeredCallObject(
    env: JniEnv,
    _: JObject,
    method: jni.JMethodId,
    args: []const JValue,
) JObject {
    return answeredCall(env, method, args);
}

fn answeredCallStaticObject(
    env: JniEnv,
    _: JClass,
    method: jni.JMethodId,
    args: []const JValue,
) JObject {
    return answeredCall(env, method, args);
}

/// The row of `raised_members` that the method id `method` carries.
fn memberRowOfMethod(method: jni.JMethodId) usize {
    if (method == null) return raised_member_count;
    const address = @intFromPtr(method.?);
    if (address < handle_base + 10) return raised_member_count;
    const row = address - (handle_base + 10);
    if (row >= raised_member_count) return raised_member_count;
    return row;
}

/// One member call that discards its result: a setter or the send.
fn answeredCallVoid(
    env: JniEnv,
    _: JObject,
    method: jni.JMethodId,
    args: []const JValue,
) void {
    const recorder = recorderOf(env) orelse return;
    recorder.record(method, args);
    if (throwing(recorder)) return;
    switch (memberRowOfMethod(method)) {
        member_row_event_set_source => {
            recorder.last_source_id = args[1].i;
        },
        member_row_event_set_content_change_types => {
            recorder.last_content_change_types = args[0].i;
        },
        else => {},
    }
}

/// The row of `event_set_source` in `raised_members`.
const member_row_event_set_source = memberRowOf(event_set_source.name);

/// The row of `event_set_content_change_types` in `raised_members`.
const member_row_event_set_content_change_types = memberRowOf(event_set_content_change_types.name);

fn answeredCallInt(env: JniEnv, _: JObject, _: jni.JMethodId, _: []const JValue) JInt {
    _ = env;
    return 0;
}

fn answeredCallFloat(env: JniEnv, _: JObject, _: jni.JMethodId, _: []const JValue) jni.JFloat {
    _ = env;
    return 0;
}

fn answeredCallBoolean(
    env: JniEnv,
    _: JObject,
    method: jni.JMethodId,
    args: []const JValue,
) u8 {
    const recorder = recorderOf(env) orelse return 0;
    recorder.record(method, args);
    if (throwing(recorder)) return 0;
    const row = memberRowOfMethod(method);
    if (row == memberRowOf("isEnabled")) {
        recorder.gate_calls += 1;
        return @intFromBool(recorder.enabled);
    }
    if (row == memberRowOf(parent_request_send.name)) {
        recorder.sends += 1;
        recorder.send_args_valid = args.len == 2;
        if (args.len == 2) {
            recorder.send_args_valid = args[0].l == fakeHost() and
                args[1].l == recorder.last_event_object;
        }
        return @intFromBool(!recorder.refuse_send);
    }
    return 0;
}

fn answeredNewString(env: JniEnv, text: []const u8) JString {
    const recorder = recorderOf(env) orelse return null;
    recorder.work();
    if (!std.mem.eql(u8, text, "accessibility")) return null;
    recorder.service_strings += 1;
    if (recorder.fault == .string_oom) return null;
    const object = recorder.acquire();
    if (recorder.fault == .string_throw) recorder.pending_exception = true;
    return object;
}

fn answeredNewObject(
    env: JniEnv,
    _: JClass,
    _: jni.JMethodId,
    _: []const JValue,
) JObject {
    _ = env;
    return @ptrFromInt(handle_base + 6);
}

fn answeredNewIntArray(env: JniEnv, _: usize) JObject {
    _ = env;
    return @ptrFromInt(handle_base + 7);
}

fn answeredDeleteLocalRef(env: JniEnv, object: JObject) void {
    const recorder = recorderOf(env) orelse return;
    recorder.release(object);
}

fn answeredExceptionCheck(env: JniEnv) bool {
    const recorder = recorderOf(env) orelse return false;
    recorder.exception_checks += 1;
    return recorder.pending_exception or throwing(recorder);
}

fn answeredBoolFalse(env: JniEnv, _: JObject, _: JClass) bool {
    _ = env;
    return false;
}

fn answeredIntZero(env: JniEnv, _: JInt) JInt {
    _ = env;
    return 0;
}

fn answeredReferenceBack(env: JniEnv, answer: JObject) JObject {
    _ = env;
    return answer;
}

fn answeredRegister(env: JniEnv, _: JClass, _: []const jni.JNINativeMethod) JInt {
    _ = env;
    return 0;
}

/// The table that answers from `recorder`, with every other slot inert.
fn recordingTable(recorder: *Recorder) JniTable {
    var table = jni.inertTable(@ptrCast(recorder));
    table.findClassFn = answeredFindClass;
    table.getMethodIdFn = answeredGetMethodId;
    table.getStaticMethodIdFn = answeredGetStaticMethodId;
    table.getStaticFieldIdFn = answeredGetStaticFieldId;
    table.getStaticObjectFieldFn = answeredStaticObjectField;
    table.callObjectMethodFn = answeredCallObject;
    table.callStaticObjectMethodFn = answeredCallStaticObject;
    table.callVoidMethodFn = answeredCallVoid;
    table.callIntMethodFn = answeredCallInt;
    table.callFloatMethodFn = answeredCallFloat;
    table.callBooleanMethodFn = answeredCallBoolean;
    table.newStringFn = answeredNewString;
    table.newObjectFn = answeredNewObject;
    table.newIntArrayFn = answeredNewIntArray;
    table.deleteLocalRefFn = answeredDeleteLocalRef;
    table.isInstanceOfFn = answeredBoolFalse;
    table.exceptionCheckFn = answeredExceptionCheck;
    table.pushLocalFrameFn = answeredIntZero;
    table.popLocalFrameFn = answeredReferenceBack;
    table.registerNativeMethodsFn = answeredRegister;
    return table;
}

/// A tree holding one node, so an id can be minted for it.
const OneNodeTree = struct {
    state: consumer.tree_state.TreeState,

    /// Builds the state and the adapter, both released by `deinit`.
    fn init(gpa: Allocator) !OneNodeTree {
        var state: consumer.tree_state.TreeState = .{};
        errdefer state.deinit(gpa);
        const id = fixtureNode(1);
        try state.nodes.put(gpa, id, .{
            .parent_and_index = null,
            .data = schema.Node.init(gpa, .button),
        });
        state.root_id = id;
        return .{ .state = state };
    }

    /// Releases the state and leaves the fixture empty.
    ///
    /// `self.*` is one whole `OneNodeTree` with `state` at `.{}`, which is the
    /// Z030 shape: the rule reads an assignment to `self.*` as a plain write
    /// rather than as the reset it is.
    fn deinit(self: *OneNodeTree, gpa: Allocator) void {
        self.state.deinit(gpa);
        // SAFETY: the line above released every buffer the state owned, and the
        // reset is what a stale read sees. The allocator owns no memory, so it
        // is not a field and has nothing to invalidate.
        self.* = .{ .state = .{} };
    }

    /// The handle to the one node.
    fn node(self: *OneNodeTree) !consumer.node_id.NodeRef {
        return consumer.node_id.NodeRef.init(&self.state, self.state.root_id) orelse
            error.NodeMissingFromState;
    }
};

test "an empty queue sends nothing and answers an empty report" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    const report = queue.raise(table, fakeHost());
    try testing.expectEqual(@as(usize, 0), report.total());
    try testing.expectEqual(@as(usize, 0), recorder.calls);
    recorder.pending_exception = true;
    try testing.expectEqual(@as(usize, 0), queue.raise(table, null).total());
    try testing.expectEqual(@as(usize, 0), recorder.acquired);
    try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
    try testing.expectEqual(@as(usize, 0), recorder.exception_checks);
    try testing.expectEqual(@as(?CallError, null), report.failure);
}

test "one event about the host view is sent with the host sentinel id" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    const report = queue.raise(table, fakeHost());

    try testing.expectEqual(@as(usize, 1), report.raised);
    try testing.expectEqual(@as(usize, 1), recorder.sends);
    try testing.expectEqual(values.HOST_VIEW_ID, recorder.last_source_id);
    try testing.expectEqual(values.EVENT_WINDOW_CONTENT_CHANGED, recorder.last_event_type);
    try testing.expectEqual(
        values.CONTENT_CHANGE_TYPE_SUBTREE,
        recorder.last_content_change_types,
    );
}

test "an event about a node carries the virtual id the map minted" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    const minted = try target.idMap().getOrCreateJavaId(try fixture.node());
    try queue.append(.simple(values.EVENT_VIEW_CLICKED, fixture.state.root_id));
    const report = queue.raise(table, fakeHost());

    try testing.expectEqual(@as(usize, 1), report.raised);
    try testing.expectEqual(minted, recorder.last_source_id);
    // A simple event carries no content change types, so the setter is skipped
    // rather than sent with a zero Android would read as "no change".
    try testing.expectEqual(@as(JInt, -1), recorder.last_content_change_types);
}

test "an event about a node the fill never named is skipped, not sent" {
    // This is the case the node-holding design exists for. An id map that has
    // never minted an id for the node has nothing to send, and inventing one
    // would name a different node to the platform.
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.simple(values.EVENT_VIEW_CLICKED, fixture.state.root_id));
    const report = queue.raise(table, fakeHost());

    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 1), report.skipped);
    try testing.expectEqual(@as(usize, 0), recorder.sends);
}

test "a null host sends nothing and counts every event as failed" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    const report = queue.raise(table, null);

    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(@as(usize, 0), recorder.calls);
}

test "a host with no parent fails every event and calls nothing else" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{ .fault = .null_result, .fault_name = "getParent" };
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    const report = queue.raise(table, fakeHost());

    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(@as(usize, 0), recorder.sends);
}

test "a batch sends every event and releases every reference it took" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    _ = try target.idMap().getOrCreateJavaId(try fixture.node());

    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    try queue.append(.simple(values.EVENT_VIEW_CLICKED, fixture.state.root_id));
    try queue.append(.simple(values.EVENT_VIEW_ACCESSIBILITY_FOCUSED, null));
    try testing.expectEqual(@as(usize, 3), queue.len());

    const report = queue.raise(table, fakeHost());
    try testing.expectEqual(@as(usize, 3), report.raised);
    try testing.expectEqual(@as(usize, 3), recorder.sends);

    // Gate context/string/manager and parent/package context/package are batch scoped.
    const batch_scoped_releases = 6;
    const expected = recorder.lookups + batch_scoped_releases + queue.len();
    try testing.expectEqual(expected, recorder.released);
    try testing.expectEqual(recorder.acquired, recorder.released);
}

test "a member the device does not carry fails the batch and calls nothing else" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{ .method_missing = true };
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    const report = queue.raise(table, fakeHost());

    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(@as(usize, 0), recorder.sends);
}

test "a class the device does not carry fails the batch" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var recorder: Recorder = .{ .class_missing = true };
    const table = recordingTable(&recorder);
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();

    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    try testing.expectEqual(@as(usize, 1), queue.raise(table, fakeHost()).failed);
}

test "deinit leaves the queue empty and a second deinit releases nothing" {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();

    var queue = AndroidQueuedEvents.init(gpa, &target);
    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    try testing.expectEqual(@as(usize, 1), queue.len());

    queue.deinit();
    try testing.expectEqual(@as(usize, 0), queue.len());
    queue.deinit();
    try testing.expectEqual(@as(usize, 0), queue.len());
}

test "the package-name descriptor matches pinned util.rs" {
    try testing.expectEqualStrings("()Ljava/lang/String;", context_get_package_name.signature);
}

test "disabled accessibility consumes no delivery work and skips the whole queue" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{ .enabled = false };
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
    try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));

    // Disabled accessibility must stop before parent/package lookup or event creation.
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try testing.expectEqual(@as(usize, 0), recorder.sends);
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 2), report.skipped);
    try testing.expectEqual(@as(usize, 0), report.failed);
    try testing.expectEqual(@as(usize, 3), recorder.calls);
    try testing.expectEqual(@as(usize, 1), recorder.gate_calls);
    try testing.expectEqual(recorder.acquired, recorder.released);
    try testing.expectEqual(@as(?CallError, null), report.failure);
}

test "a refused parent send is skipped rather than reported as raised" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{ .enabled = true, .refuse_send = true };
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 1), report.skipped);
    try testing.expectEqual(@as(usize, 0), report.failed);
}

test "one enabled gate is shared by every event in a nonempty raise" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{ .enabled = true };
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
    try queue.append(.simple(values.EVENT_VIEW_SELECTED, null));
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try testing.expectEqual(@as(usize, 2), report.raised);
    try testing.expectEqual(@as(usize, 1), recorder.gate_calls);
    try testing.expectEqual(@as(usize, 1), recorder.service_strings);
    try testing.expect(recorder.send_args_valid);
    try testing.expectEqual(recorder.acquired, recorder.released);
}

fn expectFailure(report: RaiseReport, expected: CallError) !void {
    try testing.expectEqual(@as(?CallError, expected), report.failure);
}

test "gate acquisition failures preserve exact tags and release nonnull exception results" {
    const cases = [_]struct { fault: Recorder.Fault, name: []const u8, failure: CallError }{
        .{ .fault = .missing_class, .name = "android/view/View", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_class, .name = "android/view/View", .failure = error.JavaException },
        .{ .fault = .missing_method, .name = "getContext", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_method, .name = "getContext", .failure = error.JavaException },
        .{ .fault = .null_result, .name = "getContext", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_call, .name = "getContext", .failure = error.JavaException },
        .{ .fault = .string_oom, .name = "", .failure = error.OutOfMemory },
        .{ .fault = .string_throw, .name = "", .failure = error.JavaException },
        .{ .fault = .missing_class, .name = "android/content/Context", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_class, .name = "android/content/Context", .failure = error.JavaException },
        .{ .fault = .missing_method, .name = "getSystemService", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_method, .name = "getSystemService", .failure = error.JavaException },
        .{ .fault = .null_result, .name = "getSystemService", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_call, .name = "getSystemService", .failure = error.JavaException },
        .{ .fault = .missing_class, .name = "android/view/accessibility/AccessibilityManager", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_class, .name = "android/view/accessibility/AccessibilityManager", .failure = error.JavaException },
        .{ .fault = .missing_method, .name = "isEnabled", .failure = error.JavaMemberMissing },
        .{ .fault = .throw_method, .name = "isEnabled", .failure = error.JavaException },
        .{ .fault = .throw_call, .name = "isEnabled", .failure = error.JavaException },
    };
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    for (cases) |case| {
        var recorder: Recorder = .{ .enabled = true, .fault = case.fault, .fault_name = case.name };
        var queue = AndroidQueuedEvents.init(gpa, &target);
        defer queue.deinit();
        try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
        try queue.append(.simple(values.EVENT_VIEW_SELECTED, null));
        const report = queue.raise(recordingTable(&recorder), fakeHost());
        try expectFailure(report, case.failure);
        try testing.expectEqual(@as(usize, 2), report.failed);
        try testing.expectEqual(@as(usize, 0), report.raised);
        try testing.expectEqual(@as(usize, 0), recorder.sends);
        try testing.expectEqual(recorder.acquired, recorder.released);
        try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
    }
}

test "a pending exception stops delivery and retains the raised prefix" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{ .enabled = true, .calls_before_throw = 11 };
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    for (0..3) |_| try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try expectFailure(report, error.JavaException);
    try testing.expectEqual(@as(usize, 1), report.raised);
    try testing.expectEqual(@as(usize, 2), report.failed);
    try testing.expectEqual(@as(usize, 11), recorder.calls);
    try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
    try testing.expectEqual(recorder.acquired, recorder.released);
}

test "a preexisting exception prevents every noncleanup JNI operation" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{ .enabled = true, .pending_exception = true };
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try expectFailure(report, error.JavaException);
    try testing.expectEqual(@as(usize, 1), report.failed);
    try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
    try testing.expectEqual(@as(usize, 0), recorder.acquired);
}

test "preamble and delivery failures retain exact tags and clean every reference" {
    const names = [_][]const u8{
        "getParent", "getPackageName",        "obtain",                        "setPackageName",
        "setSource", "setContentChangeTypes", "requestSendAccessibilityEvent",
    };
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    for (names) |name| {
        for ([_]Recorder.Fault{ .missing_method, .throw_call, .null_result }) |fault| {
            if (fault == .null_result and
                !std.mem.eql(u8, name, "getParent") and
                !std.mem.eql(u8, name, "getPackageName") and
                !std.mem.eql(u8, name, "obtain")) continue;
            var recorder: Recorder = .{ .enabled = true, .fault = fault, .fault_name = name };
            var queue = AndroidQueuedEvents.init(gpa, &target);
            defer queue.deinit();
            try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
            try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));
            const report = queue.raise(recordingTable(&recorder), fakeHost());
            try expectFailure(report, if (fault == .throw_call) error.JavaException else error.JavaMemberMissing);
            try testing.expectEqual(@as(usize, 2), report.failed);
            try testing.expectEqual(@as(usize, 0), report.raised);
            try testing.expectEqual(recorder.acquired, recorder.released);
            try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
        }
    }
}

test "scroll axes maxima and root or virtual node IDs reach Android in upstream order" {
    try expectScrollDelivery();
}

fn expectScrollDelivery() !void {
    const gpa = testing.allocator;
    var fixture = try OneNodeTree.init(gpa);
    defer fixture.deinit(gpa);
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    const minted = try target.idMap().getOrCreateJavaId(try fixture.node());
    for (0..16) |mask| {
        for ([_]?FullNodeId{ null, fixture.state.root_id }) |node| {
            var recorder: Recorder = .{ .enabled = true };
            var queue = AndroidQueuedEvents.init(gpa, &target);
            defer queue.deinit();
            const event: QueuedEvent = .{ .scrolled = .{
                .node = node,
                .x = if (mask & 1 != 0) .{
                    .current = 0,
                    .delta = -3,
                    .max = if (mask & 4 != 0) 0 else null,
                } else null,
                .y = if (mask & 2 != 0) .{
                    .current = 17,
                    .delta = 5,
                    .max = if (mask & 8 != 0) 200 else null,
                } else null,
            } };
            try queue.append(event);
            const report = queue.raise(recordingTable(&recorder), fakeHost());
            try testing.expectEqual(@as(usize, 1), report.raised);
            try testing.expectEqual(values.EVENT_VIEW_SCROLLED, recorder.last_event_type);
            try testing.expectEqual(if (node == null) values.HOST_VIEW_ID else minted, recorder.last_source_id);
            try testing.expect(recorder.send_args_valid);
            var expected_names: [7][]const u8 = undefined;
            var expected_values: [7]JInt = undefined;
            var count: usize = 1;
            expected_names[0] = "setScrollable";
            expected_values[0] = 1;
            if (mask & 1 != 0) {
                expected_names[count] = "setScrollX";
                expected_values[count] = 0;
                count += 1;
                expected_names[count] = "setScrollDeltaX";
                expected_values[count] = -3;
                count += 1;
                if (mask & 4 != 0) {
                    expected_names[count] = "setMaxScrollX";
                    expected_values[count] = 0;
                    count += 1;
                }
            }
            if (mask & 2 != 0) {
                expected_names[count] = "setScrollY";
                expected_values[count] = 17;
                count += 1;
                expected_names[count] = "setScrollDeltaY";
                expected_values[count] = 5;
                count += 1;
                if (mask & 8 != 0) {
                    expected_names[count] = "setMaxScrollY";
                    expected_values[count] = 200;
                    count += 1;
                }
            }
            var checked: usize = 0;
            for (recorder.trace[0..recorder.trace_len]) |call| {
                const name = raised_members[call.row].name;
                if (!std.mem.startsWith(u8, name, "setScroll") and
                    !std.mem.startsWith(u8, name, "setMax")) continue;
                try testing.expect(checked < count);
                try testing.expectEqualStrings(expected_names[checked], name);
                try testing.expectEqual(expected_values[checked], call.first);
                checked += 1;
            }
            try testing.expectEqual(count, checked);
            try testing.expectEqual(recorder.acquired, recorder.released);
        }
    }
}

test "every scroll setter exception stops later events and releases the event object" {
    try expectScrollSetterFailures();
}

fn expectScrollSetterFailures() !void {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    for ([_][]const u8{
        "setScrollable", "setScrollX",      "setScrollDeltaX", "setMaxScrollX",
        "setScrollY",    "setScrollDeltaY", "setMaxScrollY",
    }) |name| {
        var recorder: Recorder = .{
            .enabled = true,
            .fault = .throw_call,
            .fault_name = name,
        };
        var queue = AndroidQueuedEvents.init(gpa, &target);
        defer queue.deinit();
        const event: QueuedEvent = .{ .scrolled = .{
            .node = null,
            .x = .{ .current = 1, .delta = 2, .max = 3 },
            .y = .{ .current = 4, .delta = 5, .max = 6 },
        } };
        try queue.append(event);
        try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
        const report = queue.raise(recordingTable(&recorder), fakeHost());
        try expectFailure(report, error.JavaException);
        try testing.expectEqual(@as(usize, 2), report.failed);
        try testing.expectEqual(@as(usize, 0), report.raised);
        try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
        try testing.expectEqual(recorder.acquired, recorder.released);
    }
}

test "later exceptions stop dispatch without replacing the first exact failure" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{
        .fault = .missing_method,
        .fault_name = "setSource",
        .fault_once = true,
        .calls_before_throw = 9,
    };
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    for (0..3) |_| try queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try expectFailure(report, error.JavaMemberMissing);
    try testing.expectEqual(@as(usize, 3), report.failed);
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 9), recorder.calls);
    try testing.expectEqual(@as(usize, 0), recorder.work_after_exception);
    try testing.expectEqual(recorder.acquired, recorder.released);
}

test "enabled state is read again for each independent raise" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{};
    var enabled_queue = AndroidQueuedEvents.init(gpa, &target);
    defer enabled_queue.deinit();
    var disabled_queue = AndroidQueuedEvents.init(gpa, &target);
    defer disabled_queue.deinit();
    try enabled_queue.append(.simple(values.EVENT_VIEW_CLICKED, null));
    try disabled_queue.append(.simple(values.EVENT_VIEW_SELECTED, null));
    try testing.expectEqual(@as(usize, 1), enabled_queue.raise(recordingTable(&recorder), fakeHost()).raised);
    recorder.enabled = false;
    const report = disabled_queue.raise(recordingTable(&recorder), fakeHost());
    try testing.expectEqual(@as(usize, 1), report.skipped);
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 2), recorder.gate_calls);
    try testing.expectEqual(@as(usize, 2), recorder.service_strings);
    try testing.expectEqual(recorder.acquired, recorder.released);
}

test "zero content flags remain a content payload instead of a simple event" {
    const gpa = testing.allocator;
    var target = try AndroidAdapter.init(gpa);
    defer target.deinit();
    var recorder: Recorder = .{};
    var queue = AndroidQueuedEvents.init(gpa, &target);
    defer queue.deinit();
    try queue.append(.contentChanged(null, 0));
    const report = queue.raise(recordingTable(&recorder), fakeHost());
    try testing.expectEqual(@as(usize, 1), report.raised);
    try testing.expectEqual(values.EVENT_WINDOW_CONTENT_CHANGED, recorder.last_event_type);
    try testing.expectEqual(@as(JInt, 0), recorder.last_content_change_types);
    try testing.expectEqual(recorder.acquired, recorder.released);
}
