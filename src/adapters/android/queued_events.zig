//! The events one update produced, and the raise that hands them to Android.
//!
//! **Why the queue exists at all.** Android has no `raise` a caller makes; the
//! adapter has to build an `AccessibilityEvent` and push it at the host's
//! `ViewParent` through `requestSendAccessibilityEvent`. `docs/42`
//! section 4.2 draws the shape every adapter shares, and its last box is
//! `QueuedEvents.raise()` outside the update: a tree update is applied under the
//! consumer half's own rules and the platform call happens after it.
//!
//! **Why a queue holds nodes and not virtual ids.** `node.zig` mints a virtual
//! id when it fills a node, and that mint can allocate. A change slot runs
//! inside `Tree.updateAndProcessChanges`, where the only failures the consumer
//! half reports are a query error and an out-of-memory, so a JNI id mint has no
//! honest failure to report there. This queue therefore stores the
//! `FullNodeId`, and `raise` resolves the virtual id through the adapter's map:
//! `error.OutOfMemory` already has a home in the fill, and a node that was never
//! filled is visible as a skip rather than as a made-up id.
//!
//! **That is what makes the borrow real.** `AndroidQueuedEvents` holds a
//! `*AndroidAdapter`, and `include/zaccesskit.h:5739-5745` promises the adapter
//! outlives every handle from it. The field is not decoration: without it the
//! queue could not resolve an id at all, because the id map is the adapter's.
//!
//! **What a raise does, in order.** One `getParent` and one `getPackageName` for
//! the whole batch, then per event one static `AccessibilityEvent.obtain`, a
//! package name, a source, a content-change type where the event carries one,
//! and the send itself. Every reference is released as soon as the send that
//! needed it is done, so a batch of any length stays inside the caller's one
//! local frame.
//!
//! **The three descriptors no document records.** `ViewParent.requestSendAccessibilityEvent`,
//! `View.getContext` and `Context.getPackageName` are in the 68 Java method
//! names but carry no pinned descriptor anywhere under `docs/`, so they are
//! literals here and a test pins each against a literal written inside that
//! test. The other five come from `methods.zig` unchanged.
//!
//! **The loop bound.** `raise` walks `self.events`, whose length is the number
//! of events the call produced, and the tests walk `raised_members` and
//! `unpinned_members`, whose lengths are `raised_member_count` and
//! `unpinned_member_count`. There is no other walk outside those tests.

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
const event_obtain = java_call.Member{
    .class = .{
        .descriptor = "Landroid/view/accessibility/AccessibilityEvent;",
        .internal_name = "android/view/accessibility/AccessibilityEvent",
    },
    .name = "obtain",
    .signature = "(I)Landroid/view/accessibility/AccessibilityEvent;",
};

/// `AccessibilityEvent.setPackageName(CharSequence)`, `docs/29` row 31.
const event_set_package_name = java_call.Member{
    .class = event_obtain.class,
    .name = "setPackageName",
    .signature = "(Ljava/lang/CharSequence;)V",
};

/// `AccessibilityEvent.setSource(View, int)`, `docs/29` row 32.
const event_set_source = java_call.Member{
    .class = event_obtain.class,
    .name = "setSource",
    .signature = "(Landroid/view/View;I)V",
};

/// `AccessibilityEvent.setContentChangeTypes(int)`, `docs/29` row 33.
const event_set_content_change_types = java_call.Member{
    .class = event_obtain.class,
    .name = "setContentChangeTypes",
    .signature = "(I)V",
};

/// `View.getParent()`, `docs/29` row 35.
const view_get_parent = java_call.Member{
    .class = .{
        .descriptor = "Landroid/view/View;",
        .internal_name = "android/view/View",
    },
    .name = "getParent",
    .signature = "()Landroid/view/ViewParent;",
};

/// `View.getContext()`.
///
/// **Unverified**: `methods.zig` records no descriptor for this row.
const view_get_context = java_call.Member{
    .class = view_get_parent.class,
    .name = "getContext",
    .signature = "()Landroid/content/Context;",
};

/// `ViewParent.requestSendAccessibilityEvent(AccessibilityEvent)`.
///
/// `methods.zig` records this row as `.reached_by_name` with no descriptor, so
/// the descriptor below is a literal this module supplies. **Unverified**.
const parent_request_send = java_call.Member{
    .class = .{
        .descriptor = "Landroid/view/ViewParent;",
        .internal_name = "android/view/ViewParent",
    },
    .name = "requestSendAccessibilityEvent",
    .signature = "(Landroid/view/accessibility/AccessibilityEvent;)V",
};

/// `Context.getPackageName()`.
///
/// **Unverified**: `methods.zig` records no descriptor for this row.
const context_get_package_name = java_call.Member{
    .class = .{
        .descriptor = "Landroid/content/Context;",
        .internal_name = "android/content/Context",
    },
    .name = "getPackageName",
    .signature = "()Ljava/lang/String;",
};

/// The three members a raise reaches that `methods.zig` pins no descriptor for.
///
/// The array length is the bound every test that walks it uses.
pub const unpinned_members = [3]java_call.Member{
    parent_request_send,
    view_get_context,
    context_get_package_name,
};

/// How many rows `unpinned_members` holds.
pub const unpinned_member_count = unpinned_members.len;

/// How many Java members one raise reaches.
pub const raised_member_count = 8;

/// Every Java member one raise reaches, in the order `raise` first calls each.
///
/// The array length is `raised_member_count`, which is the bound every test that
/// walks it uses. **The eight names are distinct**, which is what lets the
/// recorder below name a call from its method id alone.
pub const raised_members = [raised_member_count]java_call.Member{
    event_obtain,
    event_set_package_name,
    event_set_source,
    event_set_content_change_types,
    view_get_parent,
    view_get_context,
    context_get_package_name,
    parent_request_send,
};

/// One event the queue carries, as the node it names rather than a virtual id.
///
/// `node` is `null` for an event about the host view itself, which is what
/// `values.HOST_VIEW_ID` names; `raise` sends it with that id.
/// `content_change_types` is `0` for every event that is not a content change,
/// and Android ignores the call for those, so the queue carries no flag beside
/// it.
pub const QueuedEvent = struct {
    /// One of the twelve `EVENT_*` ids.
    event_type: JInt,
    /// The node the event is about, or `null` for the host view.
    node: ?FullNodeId,
    /// The content change types, for `EVENT_WINDOW_CONTENT_CHANGED` only.
    content_change_types: JInt,

    /// An event about one node and nothing else.
    pub fn simple(event_type: JInt, node: ?FullNodeId) QueuedEvent {
        return .{ .event_type = event_type, .node = node, .content_change_types = 0 };
    }

    /// A subtree content change, which is the only event this port emits for a
    /// node appearing, changing or leaving the tree. Upstream's own comment at
    /// `AK/android/src/adapter.rs:197` reads `// TODO: other events?`, and
    /// `docs/42` section 4.4 records that this is the whole of it.
    pub fn contentChanged(node: ?FullNodeId, content_change_types: JInt) QueuedEvent {
        return .{
            .event_type = values.EVENT_WINDOW_CONTENT_CHANGED,
            .node = node,
            .content_change_types = content_change_types,
        };
    }
};

/// What one raise did, so a caller can tell "no events" from "every event
/// failed".
///
/// A raise never fails. `requestSendAccessibilityEvent` returns nothing and
/// Android reports no failure, so a lookup that answers `null` or a call that
/// throws is the only signal there is, and these three counts are where it goes.
pub const RaiseReport = struct {
    /// How many events Android took.
    raised: usize = 0,
    /// How many were not sent because their node has no virtual id, which means
    /// the fill never named the node.
    skipped: usize = 0,
    /// How many were not sent because a lookup failed or a call threw.
    failed: usize = 0,

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

    /// Sends every event through `host` and reports what happened.
    ///
    /// `host` is the view whose parent receives the events, and it is the same
    /// object the caller passed to the entry point that built the queue. A
    /// `null` `host` sends nothing, because a detached host has no parent to
    /// receive anything.
    ///
    /// **The call never fails.** A lookup that answers `null` or a call that
    /// throws stops that one event and is counted in the report, and the
    /// remaining events are still attempted, because one event the platform
    /// cannot take must not silently swallow the rest of an update.
    ///
    /// Every local reference is released before the next one is taken, so a
    /// batch of any length runs inside the caller's one local frame.
    pub fn raise(self: *const AndroidQueuedEvents, table: JniTable, host: JObject) RaiseReport {
        var report: RaiseReport = .{};
        if (host == null) {
            report.failed += self.events.items.len;
            return report;
        }
        if (self.events.items.len == 0) return report;

        const parent = java_call.callObjectChecked(table, host, view_get_parent, &.{}) catch {
            report.failed += self.events.items.len;
            return report;
        };
        defer table.deleteLocalRef(parent);

        const package = packageNameOf(table, host) catch {
            report.failed += self.events.items.len;
            return report;
        };
        defer table.deleteLocalRef(package);

        for (self.events.items) |event| {
            const virtual_id = self.virtualIdOf(event) orelse {
                report.skipped += 1;
                continue;
            };
            sendOne(table, host, parent, package, virtual_id, event) catch {
                report.failed += 1;
                continue;
            };
            report.raised += 1;
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
        const node = event.node orelse return values.HOST_VIEW_ID;
        return self.adapter.idMap().getJavaId(node);
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
    ) CallError!void {
        const object = try java_call.callStaticObjectChecked(
            table,
            event_obtain,
            &.{.{ .i = event.event_type }},
        );
        // The object is released on every path out, including the three failures
        // below, so a raise that stops halfway holds nothing.
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
        if (event.content_change_types != 0) {
            try java_call.callVoidChecked(
                table,
                object,
                event_set_content_change_types,
                &.{.{ .i = event.content_change_types }},
            );
        }
        try java_call.callVoidChecked(
            table,
            parent,
            parent_request_send,
            &.{.{ .l = object }},
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
    // The recorder below names a call from its method id alone, so the eight
    // names have to be distinct. A duplicate here would make two different calls
    // indistinguishable in every test that drives a raise.
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
    // The three unverified rows are a subset of the eight the raise reaches, so
    // a change to one table without the other is a compile error.
    for (unpinned_members) |member| {
        var found = false;
        for (raised_members) |raised| {
            if (std.mem.eql(u8, member.name, raised.name)) found = true;
        }
        if (!found) @compileError("an unpinned row must be one the raise reaches");
    }
    if (unpinned_member_count != 3) @compileError("the map gives three reached-by-name rows");
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

fn answeredFindClass(env: JniEnv, _: [:0]const u8) JClass {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.class_missing) return null;
    return @ptrFromInt(handle_base + 2);
}

fn answeredGetMethodId(
    env: JniEnv,
    _: JClass,
    name: [:0]const u8,
    _: [:0]const u8,
) jni.JMethodId {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.method_missing) return null;
    recorder.lookups += 1;
    const row = memberRowOf(name);
    if (row == raised_member_count) return null;
    return @ptrFromInt(handle_base + 10 + row);
}

fn answeredGetStaticMethodId(
    env: JniEnv,
    _: JClass,
    name: [:0]const u8,
    _: [:0]const u8,
) jni.JMethodId {
    return answeredGetMethodId(env, null, name, "");
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
    recorder.calls += 1;
    if (throwing(recorder)) return null;
    if (memberRowOfMethod(method) == memberRowOf(event_obtain.name) and args.len == 1) {
        recorder.last_event_type = args[0].i;
    }
    return recorder.object_answer;
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
    recorder.calls += 1;
    if (throwing(recorder)) return;
    switch (memberRowOfMethod(method)) {
        member_row_event_set_source => {
            recorder.last_source_id = args[1].i;
        },
        member_row_event_set_content_change_types => {
            recorder.last_content_change_types = args[0].i;
        },
        member_row_parent_request_send => recorder.sends += 1,
        else => {},
    }
}

/// The row of `event_set_source` in `raised_members`.
const member_row_event_set_source = 2;

/// The row of `event_set_content_change_types` in `raised_members`.
const member_row_event_set_content_change_types = 3;

/// The row of `parent_request_send` in `raised_members`.
const member_row_parent_request_send = 7;

comptime {
    // The three rows the recorder names by hand. A row moved in
    // `raised_members` without these moving is a recorder that watches the
    // wrong call, which is worse than no recorder at all.
    if (member_row_event_set_source != memberRowOf(event_set_source.name)) {
        @compileError("the setSource row moved");
    }
    if (member_row_event_set_content_change_types !=
        memberRowOf(event_set_content_change_types.name))
    {
        @compileError("the setContentChangeTypes row moved");
    }
    if (member_row_parent_request_send != memberRowOf(parent_request_send.name)) {
        @compileError("the requestSendAccessibilityEvent row moved");
    }
}

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
    _: jni.JMethodId,
    _: []const JValue,
) u8 {
    _ = env;
    return 0;
}

fn answeredNewString(env: JniEnv, _: []const u8) JString {
    _ = env;
    return @ptrFromInt(handle_base + 5);
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

fn answeredDeleteLocalRef(env: JniEnv, _: JObject) void {
    const recorder = recorderOf(env) orelse return;
    recorder.released += 1;
}

fn answeredExceptionCheck(env: JniEnv) bool {
    const recorder = recorderOf(env) orelse return false;
    return throwing(recorder);
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

    fn deinit(self: *OneNodeTree, gpa: Allocator) void {
        self.state.deinit(gpa);
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

    var recorder: Recorder = .{ .calls_before_throw = 0 };
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

    // **Every reference the raise took is released, and the count says so
    // exactly.** Each member lookup resolves a class and releases it before
    // answering, so the releases are the lookups; the batch adds the parent,
    // the context and the package name; and each event adds its own object.
    // One release more than that is a leak and one fewer is a double free, and
    // this assertion is the one that sees either.
    const batch_scoped_releases = 3;
    const expected = recorder.lookups + batch_scoped_releases + queue.len();
    try testing.expectEqual(expected, recorder.released);
}

test "one event that throws does not stop the rest of the batch" {
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
    try queue.append(.contentChanged(null, values.CONTENT_CHANGE_TYPE_SUBTREE));

    // Two calls for the batch preamble, then the first event's own obtain.
    recorder.calls_before_throw = 3;
    const report = queue.raise(table, fakeHost());

    // Every call from the throw point on throws, so both events fail and the
    // report accounts for both rather than losing one.
    try testing.expectEqual(@as(usize, 0), report.raised);
    try testing.expectEqual(@as(usize, 2), report.failed);
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

test "the three unverified descriptors are the ones Android declares" {
    // The expected rows are literals in this test on purpose: reading them out
    // of `unpinned_members` would compare the table with itself. The walk is
    // over the three rows, so `unpinned_member_count` is the bound.
    const expected = [_][2][]const u8{
        .{ "requestSendAccessibilityEvent", "(Landroid/view/accessibility/AccessibilityEvent;)V" },
        .{ "getContext", "()Landroid/content/Context;" },
        .{ "getPackageName", "()Ljava/lang/String;" },
    };
    try testing.expectEqual(expected.len, unpinned_members.len);
    for (unpinned_members, expected) |member, row| {
        try testing.expectEqualStrings(row[0], member.name);
        try testing.expectEqualStrings(row[1], member.signature);
    }
}

test "every member the raise reaches names one of the 68 Java method names" {
    const methods = @import("methods.zig");
    // The walk is over the eight rows, so `raised_member_count` is the bound.
    var checked: usize = 0;
    for (raised_members) |member| {
        try testing.expect(methods.hasName(member.name));
        try testing.expect(member.class.descriptor.len > 2);
        checked += 1;
    }
    try testing.expectEqual(@as(usize, 8), checked);
}

test "every class the raise reaches is one classes.zig names" {
    const classes = @import("classes.zig");
    // The walk is over the eight rows, so `raised_member_count` is the bound.
    for (raised_members) |member| {
        try testing.expect(classes.find(member.class.descriptor) != null);
        try testing.expect(std.mem.endsWith(u8, member.class.descriptor, ";"));
        try testing.expect(!std.mem.startsWith(u8, member.class.internal_name, "L"));
    }
}

test "one raise of one content change resolves each of the eight members once" {
    // A raise that resolved a member twice would do twice the work inside a
    // platform call, and the duplicate is invisible in the report. Counting the
    // lookups that arrived is what makes it visible.
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

    try testing.expectEqual(@as(usize, 1), queue.raise(table, fakeHost()).raised);
    try testing.expectEqual(raised_member_count, recorder.lookups);
}
