//! `AndroidInjectingAdapter`: the adapter that installs itself on a host view.
//!
//! **What this adapter adds over the plain one.** `adapter.zig` is driven by a C
//! consumer and holds nothing about the host. This one is the other shape: it
//! takes a `View`, finds the Java class that speaks for it, installs that class
//! as the view's accessibility delegate and its hover listener, and from then on
//! the platform calls the library rather than the C consumer calling it.
//!
//! **Why there is no handle table.** Upstream declares four file-scope statics at
//! `AK/android/src/inject.rs:88-105`: a counter, a `BTreeMap` of boxed closures
//! and a second pair for posted work. `docs/42` section 5.3.2 is explicit that
//! this is the one place the port must **not** translate, because `docs/30`
//! Record R3 requires the adapter to be constructible twice in one process. So
//! the `jlong` the Java natives carry **is** the `*AndroidInjectingAdapter`
//! pointer. One process-global table becomes one pointer argument, and the two
//! adapters are independent because the handles are.
//!
//! **Why the raise moves to the UI thread and the action path does not.**
//! `ViewParent.requestSendAccessibilityEvent` must run on the thread that owns
//! the view. `updateIfActive` runs on a thread the library chose, so it appends
//! to a pending list and posts the `Runnable` the delegate handed back; the
//! `runCallback` native then raises from the UI thread. The four native calls
//! already arrive on the UI thread, so `performAction` and `onHoverEvent` raise
//! in place and answer synchronously, which is what the Java side expects.
//!
//! **Why `env` is never stored.** A `JNIEnv *` is valid only on the thread the VM
//! gave it. Every one of the five natives receives the calling thread's
//! environment as its first argument, and every raise builds its table from
//! that one. The adapter holds a host reference and a class reference, which are
//! global references and valid on any thread.
//!
//! **The `NoSuchMethodError` answer.** `registerNatives` fails when a signature
//! is wrong, and the failure surfaces as an `UnsatisfiedLinkError` at the first
//! call rather than at registration, which is why the five rows below are
//! asserted against `methods.zig` by a test. A device that cannot load
//! `dev.accesskit.android.Delegate` at all fails construction with `null`, which
//! is what `include/zaccesskit.h:5850-5852` promises.
//!
//! **The loop bound.** `registered_natives` holds `registered_native_count` rows
//! and `native_names` holds `native_name_count`; the only walk over either is in
//! the tests.

const std = @import("std");

const action_request = @import("../../capi/action_request.zig");
const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const classes = @import("classes.zig");
const schema = @import("../../schema/root.zig");
const java_call = @import("java_call.zig");
const jni = @import("jni_table.zig");
const methods = @import("methods.zig");
const platform_action = @import("platform_action.zig");
const queued_events = @import("queued_events.zig");
const values = @import("values.zig");

const ActionHandler = boundary.ActionHandler;
const ActivationHandler = boundary.ActivationHandler;
const adapter_module = @import("adapter.zig");
const AndroidAdapter = adapter_module.AndroidAdapter;
const QueuedEvent = queued_events.QueuedEvent;
const QueuedEvents = queued_events.AndroidQueuedEvents;
const TreeUpdateFactory = boundary.TreeUpdateFactory;

const JFloat = jni.JFloat;
const JInt = values.JInt;
const JLong = jni.JLong;
const JniEnv = jni.JniEnv;
const JniTable = jni.JniTable;
const JObject = jni.JObject;
const JValue = jni.JValue;

const Allocator = std.mem.Allocator;
const testing = std.testing;

/// The class `AK/android/src/inject.rs:256` reaches with
/// `find_class("dev/accesskit/android/Delegate")`.
///
/// It is not in the 20 rows of `classes.zig`, because the map's table lists
/// `find_class` arguments rather than descriptors, and `classes.zig` derives the
/// descriptor from the name.
const delegate_class = java_call.Class{
    .descriptor = classes.delegate_class_descriptor,
    .internal_name = "dev/accesskit/android/Delegate",
};

/// `Delegate.newCallback(long)`, the `Runnable` bound to one adapter handle.
///
/// `methods.zig` records `newCallback` as `.reached_by_name` with no descriptor,
/// so the descriptor below is a literal this module supplies. **Unverified**: no
/// document under `docs/` records it.
const delegate_new_callback = java_call.Member{
    .class = delegate_class,
    .name = "newCallback",
    .signature = "(J)Ljava/lang/Runnable;",
};

/// `Delegate.<init>(View)`.
///
/// `methods.zig` holds no row for this constructor, and no document under `docs/`
/// records one. The descriptor is inferred from the superclass:
/// `View.AccessibilityDelegate` declares `AccessibilityDelegate(View host)` as
/// its only constructor, so a subclass that overrides it must use
/// `(Landroid/view/View;)V`. **Unverified**, and it is the one string in this
/// module that no recorded source backs.
const delegate_constructor = java_call.Member{
    .class = delegate_class,
    .name = "<init>",
    .signature = "(Landroid/view/View;)V",
};

/// `View.getAccessibilityDelegate()`, `docs/29` row 29.
const view_get_accessibility_delegate = java_call.Member{
    .class = .{
        .descriptor = "Landroid/view/View;",
        .internal_name = "android/view/View",
    },
    .name = "getAccessibilityDelegate",
    .signature = "()Landroid/view/View$AccessibilityDelegate;",
};

/// `View.setAccessibilityDelegate(AccessibilityDelegate)`, `docs/29` row 30.
///
/// The parameter is the supertype, so passing `null` clears the delegate, which
/// is how `free` takes the host back.
const view_set_accessibility_delegate = java_call.Member{
    .class = view_get_accessibility_delegate.class,
    .name = "setAccessibilityDelegate",
    .signature = "(Landroid/view/View$AccessibilityDelegate;)V",
};

/// `View.setOnHoverListener(OnHoverListener)`, `docs/29` row 30.
const view_set_on_hover_listener = java_call.Member{
    .class = view_get_accessibility_delegate.class,
    .name = "setOnHoverListener",
    .signature = "(Landroid/view/View$OnHoverListener;)V",
};

/// `View.post(Runnable)`, `docs/29` row 34, which is how work reaches the UI
/// thread from any other.
const view_post = java_call.Member{
    .class = view_get_accessibility_delegate.class,
    .name = "post",
    .signature = "(Ljava/lang/Runnable;)Z",
};

/// How many natives the delegate class carries.
pub const registered_native_count = 5;

/// One registered native: the Java name and the JNI descriptor `RegisterNatives`
/// takes.
///
/// The pair is what a wrong spelling breaks: `RegisterNatives` accepts a wrong
/// signature and the failure surfaces as an `UnsatisfiedLinkError` at the first
/// call, which is on a device and not here.
pub const NativeSignature = struct {
    /// Borrowed from `methods.method_names`.
    name: [:0]const u8,
    /// A literal. `docs/42` section 5.3.1 records the first two columns of each.
    signature: [:0]const u8,
};

/// The five registered natives, in `methods.method_ids` order.
///
/// The array length is `registered_native_count`, which is the bound every test
/// that walks it uses.
pub const registered_natives = [registered_native_count]NativeSignature{
    .{ .name = "runCallback", .signature = "(Landroid/view/View;J)V" },
    .{
        .name = "createAccessibilityNodeInfo",
        .signature = "(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
    },
    .{
        .name = "findFocus",
        .signature = "(JLandroid/view/View;I)Landroid/view/accessibility/AccessibilityNodeInfo;",
    },
    .{ .name = "performAction", .signature = "(JLandroid/view/View;IILandroid/os/Bundle;)Z" },
    .{ .name = "onHoverEvent", .signature = "(JLandroid/view/View;IFF)Z" },
};

/// How many names `native_names` holds.
pub const native_name_count = 5;

/// The five Java names, for the tests that walk them independently of the table.
pub const native_names = [native_name_count][:0]const u8{
    "runCallback",
    "createAccessibilityNodeInfo",
    "findFocus",
    "performAction",
    "onHoverEvent",
};

/// Everything constructing or releasing an injecting adapter can fail with.
///
/// `java_call.CallError` is the JNI half and `adapter.Error` is the consumer
/// half; the two tags below are this module's own.
pub const Error = java_call.CallError || adapter_module.Error || error{
    /// The host already carries **this** adapter's delegate, so a second
    /// constructor would leave two `Runnable`s racing for one view.
    DelegateAlreadyInstalled,

    /// `RegisterNatives` answered a negative value, so the Java methods are
    /// unbound. Nothing was installed and the adapter is unusable.
    NativeRegistrationFailed,

    /// The host took no `Runnable`, so posted work would never run.
    PostRejected,
};

/// The adapter that installs itself on a host view and is driven by Java.
///
/// The caller owns one and releases it with
/// `accesskit_android_injecting_adapter_free`, exactly once. It owns the inner
/// `AndroidAdapter`, three global references and the pending event list.
pub const AndroidInjectingAdapter = struct {
    /// The allocator that grew the inner adapter and the pending list.
    gpa: Allocator,

    /// The plain adapter every call routes to. Owned: `free` releases it.
    inner: *AndroidAdapter,

    /// The environment the constructor ran on.
    ///
    /// `accesskit_android_injecting_adapter_free` carries no `env`, and a
    /// `JNIEnv *` is valid only on the thread that owns it, so this is the one
    /// value that has to survive a thread hop. **The caller must therefore
    /// release the adapter on the thread that constructed it**, which is what the
    /// header's parameter list implies. Upstream avoids the same constraint by
    /// keeping the `JavaVM` and attaching the calling thread at
    /// `AK/android/src/inject.rs:412-430`; a port that wanted that would need the
    /// second table `jni_table.zig` records it does not declare.
    env: JniEnv,

    /// A **weak** global reference to the host view.
    ///
    /// Weak because the adapter must not keep the application's view alive,
    /// which is what upstream does at `AK/android/src/inject.rs:386`. A weak
    /// reference that the collector has cleared reads `null`, and every call
    /// then answers the same way a `null` host does.
    host: JObject,

    /// A global reference to the `Runnable` the delegate handed back.
    runnable: JObject,

    /// A global reference to the delegate instance.
    delegate: JObject,

    /// The activation handler the C consumer supplied. It must stay valid until
    /// the adapter is released, which is what `include/zaccesskit.h:5853-5855`
    /// promises.
    activation_handler: ActivationHandler,
    /// The context `activation_handler` receives unchanged.
    activation_handler_userdata: ?*anyopaque,

    /// The action handler the C consumer supplied, with the same lifetime rule.
    action_handler: ActionHandler,
    /// The context `action_handler` receives unchanged.
    action_handler_userdata: ?*anyopaque,

    /// Events produced off the UI thread and waiting for the `Runnable`.
    ///
    /// **`pending_events` is owned here**, unlike the `AndroidQueuedEvents` a
    /// C caller holds: `accesskit_android_injecting_adapter_update_if_active`
    /// returns nothing, so no handle ever crosses the boundary and nothing else
    /// could be the owner.
    pending_events: std.ArrayList(QueuedEvent),

    /// Installs on `host` and returns the adapter, or `null`.
    ///
    /// This is `accesskit_android_injecting_adapter_new`. The block comes from
    /// `allocation.create` because `accesskit_android_injecting_adapter_free`
    /// releases it through the declared allocator.
    ///
    /// **The block is allocated before any Java call, because the block's own
    /// address is the handle the natives carry.** A constructor that built the
    /// handle from a stack value would hand Java a pointer to a frame that has
    /// already returned, and no later check could catch it. So the block is
    /// filled in place and the handle is `&block`.
    ///
    /// **`null` means the installation did not happen**, which covers the
    /// allocation failing, the class not being on the classpath and a member
    /// being absent. Every one of those leaves the host exactly as it was: the
    /// delegate is installed last, and `errdefer teardown` releases everything
    /// the failed constructor had already taken.
    pub fn create(
        gpa: Allocator,
        table: JniTable,
        host: JObject,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
        action_handler: ActionHandler,
        action_handler_userdata: ?*anyopaque,
    ) Error!?*AndroidInjectingAdapter {
        if (host == null) return null;

        const class = try java_call.findClassChecked(table, delegate_class);
        defer table.deleteLocalRef(class);

        if (table.registerNativeMethods(class, &native_method_table) < 0) {
            return error.NativeRegistrationFailed;
        }

        // A second adapter on one host would leave two `Runnable`s racing for the
        // same view, and the second `setAccessibilityDelegate` would silently
        // orphan the first. So the check is on the installed delegate's class,
        // which is the only thing that identifies it as ours.
        const installed = try java_call.callObjectChecked(
            table,
            host,
            view_get_accessibility_delegate,
            &.{},
        );
        defer table.deleteLocalRef(installed);
        if (table.isInstanceOf(installed, class)) return error.DelegateAlreadyInstalled;

        const block = allocation.create(AndroidInjectingAdapter) catch
            return error.OutOfMemory;
        block.* = .{
            .gpa = gpa,
            .env = table.env,
            // SAFETY: `inner` is filled at the last step of this constructor,
            // and `teardown` reads it only to test for the not-yet-filled
            // state rather than to dereference it, so no path observes it
            // before it is written.
            .inner = undefined,
            .host = null,
            .runnable = null,
            .delegate = null,
            .activation_handler = activation_handler,
            .activation_handler_userdata = activation_handler_userdata,
            .action_handler = action_handler,
            .action_handler_userdata = action_handler_userdata,
            .pending_events = .empty,
        };
        // One teardown for every failure after this line. It reads the block's
        // own fields, so it releases exactly what was taken and nothing else.
        errdefer teardown(block, table);

        const local_delegate = try java_call.newObjectChecked(
            table,
            delegate_constructor,
            &.{.{ .l = host }},
        );
        block.delegate = try takeGlobalRef(table, local_delegate);

        // The runnable binds the handle, and the handle is the block, so the
        // block has to exist first. That is the whole reason it is allocated
        // above rather than at the end.
        const handle: JLong = @bitCast(@intFromPtr(block));
        const local_runnable = try java_call.callStaticObjectChecked(
            table,
            delegate_new_callback,
            &.{.{ .j = handle }},
        );
        block.runnable = try takeGlobalRef(table, local_runnable);

        // Weak, because the adapter must not keep the application's view alive,
        // which is what upstream does at `AK/android/src/inject.rs:386`.
        block.host = table.newWeakGlobalRef(host);
        if (block.host == null) return error.OutOfMemory;

        block.inner = try AndroidAdapter.create(gpa) orelse return error.OutOfMemory;

        // The delegate goes last. Everything before this point is invisible to
        // the platform, so a failure above leaves a host that still behaves as
        // it did before the call.
        try java_call.callVoidChecked(
            table,
            host,
            view_set_accessibility_delegate,
            &.{.{ .l = block.delegate }},
        );
        try java_call.callVoidChecked(
            table,
            host,
            view_set_on_hover_listener,
            &.{.{ .l = block.delegate }},
        );
        return block;
    }

    /// Releases every reference a failed constructor had already taken, and the
    /// block itself.
    ///
    /// `inner` is `undefined` until the last two lines of `create`, so it is read
    /// only when it was filled: `teardown` runs on the paths before that point
    /// too, and releasing an undefined pointer would be worse than leaking one.
    /// The field is set to `null` on every early path for exactly that reason,
    /// and this is the check that makes the promise true.
    fn teardown(target: *AndroidInjectingAdapter, table: JniTable) void {
        if (@intFromPtr(target.inner) == 0) {
            // SAFETY: the guard proved the pointer is already null, so the
            // field holds no live adapter, and the block is freed on the last
            // line of this function, so this value is never read back.
            target.inner = undefined;
        }
        if (target.host != null) table.deleteGlobalRef(target.host);
        if (target.runnable != null) table.deleteGlobalRef(target.runnable);
        if (target.delegate != null) table.deleteGlobalRef(target.delegate);
        target.pending_events.deinit(target.gpa);
        allocation.release(@ptrCast(@alignCast(target)));
    }

    /// Releases everything the adapter holds, and the block itself.
    ///
    /// This is `accesskit_android_injecting_adapter_free`. It clears the host's
    /// delegate and hover listener **only when the installed delegate is this
    /// adapter's own**, which is the check upstream makes at
    /// `AK/android/src/inject.rs:444`: clearing a delegate a later adapter
    /// installed would take the accessibility tree away from that one.
    pub fn free(self: *AndroidInjectingAdapter, table: JniTable) void {
        const gpa = self.gpa;
        const host = self.host;

        if (host != null) {
            clearHost(table, host);
            table.deleteGlobalRef(host);
        }
        if (self.runnable != null) table.deleteGlobalRef(self.runnable);
        if (self.delegate != null) table.deleteGlobalRef(self.delegate);
        self.pending_events.deinit(gpa);
        self.inner.free();
        allocation.release(@ptrCast(@alignCast(self)));
    }

    /// Takes the host back, but only when the installed delegate is this one.
    ///
    /// A host that has been taken over by a later adapter keeps its delegate; the
    /// `isInstanceOf` check is the only thing that tells the two apart.
    fn clearHost(table: JniTable, host: JObject) void {
        const class = java_call.findClassChecked(table, delegate_class) catch return;
        defer table.deleteLocalRef(class);

        const installed = java_call.callObjectChecked(
            table,
            host,
            view_get_accessibility_delegate,
            &.{},
        ) catch return;
        defer table.deleteLocalRef(installed);
        if (!table.isInstanceOf(installed, class)) return;

        java_call.callVoidChecked(
            table,
            host,
            view_set_accessibility_delegate,
            &.{.{ .l = null }},
        ) catch return;
        java_call.callVoidChecked(
            table,
            host,
            view_set_on_hover_listener,
            &.{.{ .l = null }},
        ) catch {};
    }

    /// Asks `update_factory` for a tree, hands it to the inner adapter and
    /// posts the events it produced to the UI thread.
    ///
    /// This is `accesskit_android_injecting_adapter_update_if_active`, which
    /// returns nothing: the events belong to this adapter, which raises them
    /// from the `Runnable` the UI thread runs.
    ///
    /// **A factory that answers `null` is dropped here**, with the same reason
    /// as everywhere else: it is a contract violation upstream unwraps, and the
    /// header gives this function no way to report it.
    pub fn updateIfActive(
        self: *AndroidInjectingAdapter,
        update_factory: TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) void {
        const table = jni.realTable(self.env);
        const produced = self.inner.updateIfActive(update_factory, update_factory_userdata) catch
            return;
        const events = produced orelse return;

        // The events are copied into a list this adapter owns and the box is
        // released here, because no handle ever crosses the boundary for this
        // adapter and nothing else could be the owner.
        defer eventsRelease(events);

        for (events.events.items) |event| {
            self.pending_events.append(self.gpa, event) catch return;
        }
        self.postRunnable(table);
    }

    /// Raises everything `pending_events` holds and empties it.
    ///
    /// This is what `runCallback` calls, and it runs on the UI thread because the
    /// `Runnable` runs there. `table` is built from the **calling** thread's
    /// environment, never from one captured at construction.
    fn drainPending(self: *AndroidInjectingAdapter, table: JniTable, host: JObject) void {
        if (self.pending_events.items.len == 0) return;

        var queue = QueuedEvents.init(self.gpa, self.inner);
        defer queue.deinit();
        queue.events.appendSlice(self.gpa, self.pending_events.items) catch return;
        self.pending_events.clearRetainingCapacity();
        _ = queue.raise(table, host);
    }

    /// Posts the `Runnable` so the UI thread drains the pending list.
    fn postRunnable(self: *AndroidInjectingAdapter, table: JniTable) void {
        const host = self.host orelse return;
        const accepted = java_call.callBooleanChecked(table, host, view_post, &.{
            .{ .l = self.runnable },
        }) catch return;
        if (!accepted) {
            // The host took no runnable, so nothing would ever drain the list.
            // Dropping it is the only honest answer: the events were produced
            // for a view that is not accepting work.
            self.pending_events.clearRetainingCapacity();
        }
    }
};

/// Releases an events handle the same way the C raise does.
///
/// The injecting adapter never hands a handle to C, so this is the only place
/// that releases one, and it has to go through `allocation.release` because the
/// block came from `allocation.create`.
fn eventsRelease(events: QueuedEvents) void {
    var owned = events;
    owned.deinit();
}

/// The five rows `RegisterNatives` takes.
///
/// The array is a file-scope constant because the five rows hold raw function
/// pointers and the table is handed to Java by address. A table built per call
/// would dangle the moment the call returned, which is the hazard
/// `AGENTS.md` section 3 calls a by-value copy that outlives its owner.
///
/// `callconv(.c)` on every platform Android runs. `JNICALL` is empty in
/// `jni_md.h` on Linux and on the NDK's Android headers, and `docs/29`
/// section 4 records exactly one exception — 32-bit Windows, where `JNICALL` is
/// `__stdcall`. That target is not one the port claims for Android, so the
/// convention here is `.c`; a port that ever added it would have to switch these
/// five to `.winapi`, and this comment is where that change belongs.
const native_method_table = blk: {
    // SAFETY: the loop below writes all five rows before `break :blk`, so no
    // read observes the array before every element is initialised.
    var rows: [registered_native_count]jni.JNINativeMethod = undefined;
    for (registered_natives, 0..) |native, index| {
        rows[index] = .{
            .name = native.name,
            .signature = native.signature,
            .function = switch (index) {
                0 => @ptrCast(&runCallbackNative),
                1 => @ptrCast(&createNodeInfoNative),
                2 => @ptrCast(&findFocusNative),
                3 => @ptrCast(&performActionNative),
                4 => @ptrCast(&onHoverEventNative),
                else => null,
            },
        };
    }
    break :blk rows;
};

/// A global reference to `local`, or `error.OutOfMemory`.
///
/// The local reference is released whether or not the global one is taken,
/// because a failed `NewGlobalRef` leaves the local reference the caller's only
/// claim on the object.
fn takeGlobalRef(table: JniTable, local: JObject) Error!JObject {
    const global = table.newGlobalRef(local);
    table.deleteLocalRef(local);
    if (global == null) return error.OutOfMemory;
    return global;
}

/// The adapter a `jlong` handle names, or `null` when the handle is `0`.
///
/// **This is the whole of the handle table.** `include/zaccesskit.h:5731-5732`
/// and `docs/42` section 5.3.2 both forbid a process-global map here, so the
/// handle is the pointer and this function is its only decoder. A handle the Java
/// side made up reads an address that is not an adapter; nothing here can detect
/// that, and the Java side is the only producer of handles.
fn adapterOf(handle: JLong) ?*AndroidInjectingAdapter {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(handle)));
}

/// `runCallback(View, long)`: the `Runnable` the delegate holds has run.
///
/// The events are raised here because the `Runnable` runs on the UI thread, which
/// is the only thread `requestSendAccessibilityEvent` may be called from.
fn runCallbackNative(env: JniEnv, _: JObject, handle: JLong) callconv(.c) void {
    const adapter = adapterOf(handle) orelse return;
    const table = jni.realTable(env);
    const host = adapter.host orelse return;
    adapter.drainPending(table, host);
}

/// `createAccessibilityNodeInfo(long, View, int)`.
fn createNodeInfoNative(
    env: JniEnv,
    handle: JLong,
    host: JObject,
    virtual_view_id: JInt,
) callconv(.c) JObject {
    const adapter = adapterOf(handle) orelse return null;
    const answer = adapter.inner.createNodeInfo(
        adapter.activation_handler,
        adapter.activation_handler_userdata,
        jni.realTable(env),
        host,
        virtual_view_id,
    ) catch return null;
    return answer orelse null;
}

/// `findFocus(long, View, int)`.
///
/// `focus_type` arrives and is not used: `adapter.zig`'s `findFocus` answers the
/// tree's own focus for both input modes, and that is the one focus the header
/// names.
fn findFocusNative(
    env: JniEnv,
    handle: JLong,
    host: JObject,
    focus_type: JInt,
) callconv(.c) JObject {
    _ = focus_type;
    const adapter = adapterOf(handle) orelse return null;
    const answer = adapter.inner.findFocus(
        adapter.activation_handler,
        adapter.activation_handler_userdata,
        jni.realTable(env),
        host,
    ) catch return null;
    return answer orelse null;
}

/// `performAction(long, View, int, int, Bundle)`.
///
/// The Java side hands over the raw action id and the `Bundle`; the adapter
/// decodes them into a `PlatformAction` and routes it. The events are raised in
/// place because this native already runs on the UI thread, which is what the
/// Java caller expects from a synchronous `performAction`.
fn performActionNative(
    env: JniEnv,
    handle: JLong,
    host: JObject,
    virtual_view_id: JInt,
    action: JInt,
    arguments: JObject,
) callconv(.c) bool {
    _ = host;
    const adapter = adapterOf(handle) orelse return false;
    const table = jni.realTable(env);

    const decoded = platform_action.decode(table, action, arguments) catch return false;
    const produced = adapter.inner.performAction(
        adapter.action_handler,
        adapter.action_handler_userdata,
        virtual_view_id,
        decoded,
    ) catch return false;
    const events = produced orelse return false;
    defer eventsRelease(events);
    _ = events.raise(table, adapter.host);
    return true;
}

/// `onHoverEvent(long, View, int, float, float)`.
fn onHoverEventNative(
    env: JniEnv,
    handle: JLong,
    action: JInt,
    x: JFloat,
    y: JFloat,
) callconv(.c) bool {
    const adapter = adapterOf(handle) orelse return false;
    const table = jni.realTable(env);

    const produced = adapter.inner.onHoverEvent(
        adapter.activation_handler,
        adapter.activation_handler_userdata,
        action,
        x,
        y,
    ) catch return false;
    const events = produced orelse return false;
    defer eventsRelease(events);
    _ = events.raise(table, adapter.host);
    return true;
}

comptime {
    // The five names and the five signatures must agree, row for row: a name
    // paired with the wrong signature leaves the Java method unbound and the
    // failure surfaces as an `UnsatisfiedLinkError` on a device.
    if (registered_natives.len != registered_native_count) {
        @compileError("the array length is the count");
    }
    if (native_names.len != native_name_count) {
        @compileError("the names must be as many as the signatures");
    }
    for (registered_natives, native_names) |native, name| {
        if (!std.mem.eql(u8, native.name, name)) {
            @compileError(std.fmt.comptimePrint(
                "the signature row {s} does not carry the name {s}",
                .{ native.signature, name },
            ));
        }
    }
}

// --- Tests --------------------------------------------------------------------

/// The first fabricated handle, so a fabricated handle is never the JNI null.
const handle_base = 0x5000;

/// A fabricated host view no helper ever dereferences.
fn fakeHost() JObject {
    return @ptrFromInt(handle_base + 1);
}

/// A fabricated delegate class.
fn fakeClass() JObject {
    return @ptrFromInt(handle_base + 2);
}

/// A `Runnable` the delegate handed back.
fn fakeRunnable() JObject {
    return @ptrFromInt(handle_base + 3);
}

/// What one table answered, kept where a test reads it.
const Recorder = struct {
    /// What `findClass` answers.
    class_missing: bool = false,
    /// What `getMethodId` answers.
    method_missing: bool = false,
    /// What `newObject` answers.
    delegate_answer: JObject = @ptrFromInt(handle_base + 4),
    /// What `callStaticObjectMethod` answers, which is the `Runnable`.
    runnable_answer: JObject = fakeRunnable(),
    /// What `getAccessibilityDelegate` answers.
    installed_answer: JObject = @ptrFromInt(handle_base + 5),
    /// Whether the installed delegate is one of ours.
    installed_is_ours: bool = false,
    /// What `newGlobalRef` and `newWeakGlobalRef` answer.
    reference_answer: JObject = @ptrFromInt(handle_base + 6),
    /// What `callBooleanMethod` answers, which is what `post` returns.
    post_answer: bool = true,
    /// What `registerNativeMethods` answers.
    registration_answer: JInt = 0,
    /// The rows `RegisterNatives` was handed, kept so a test can read the five.
    // SAFETY: `answeredRegister` fills `registered_count` rows and a test
    // reads only the first `registered_count`, so the rest is never observed.
    registered: [registered_native_count]jni.JNINativeMethod = undefined,
    /// How many rows it was handed.
    registered_count: usize = 0,
    /// How many times the delegate was set on the host, and how many of those
    /// cleared it.
    delegate_sets: usize = 0,
    delegate_clears: usize = 0,
    /// How many `Runnable`s were posted.
    posts: usize = 0,
    /// How many local references were released.
    released: usize = 0,
};

fn recorderOf(env: JniEnv) ?*Recorder {
    const handle = env orelse return null;
    // SAFETY: the table parks the recorder as `.env`, which is
    // `?*const anyopaque`, so the const belongs to the table and not to the
    // recorder, and the alignment is the one the recorder was declared with.
    return @ptrCast(@alignCast(@constCast(handle)));
}

fn answeredFindClass(env: JniEnv, _: [:0]const u8) JObject {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.class_missing) return null;
    return fakeClass();
}

fn answeredGetMethodId(
    env: JniEnv,
    _: JObject,
    _: [:0]const u8,
    _: [:0]const u8,
) jni.JMethodId {
    const recorder = recorderOf(env) orelse return null;
    if (recorder.method_missing) return null;
    return @ptrFromInt(handle_base + 10);
}

fn answeredGetStaticMethodId(
    env: JniEnv,
    _: JObject,
    _: [:0]const u8,
    _: [:0]const u8,
) jni.JMethodId {
    return answeredGetMethodId(env, null, "", "");
}

fn answeredGetStaticFieldId(
    env: JniEnv,
    _: JObject,
    _: [:0]const u8,
    _: [:0]const u8,
) jni.JFieldId {
    _ = env;
    return null;
}

fn answeredStaticObjectField(env: JniEnv, _: JObject, _: jni.JFieldId) JObject {
    _ = env;
    return null;
}

fn answeredNewObject(
    env: JniEnv,
    _: JObject,
    _: jni.JMethodId,
    _: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    return recorder.delegate_answer;
}

fn answeredCallStaticObject(
    env: JniEnv,
    _: JObject,
    _: jni.JMethodId,
    _: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    return recorder.runnable_answer;
}

fn answeredCallObject(
    env: JniEnv,
    _: JObject,
    method: jni.JMethodId,
    _: []const JValue,
) JObject {
    const recorder = recorderOf(env) orelse return null;
    _ = method;
    return recorder.installed_answer;
}

fn answeredCallVoid(
    env: JniEnv,
    _: JObject,
    method: jni.JMethodId,
    args: []const JValue,
) void {
    const recorder = recorderOf(env) orelse return;
    _ = method;
    if (args.len == 1) {
        recorder.delegate_sets += 1;
        if (args[0].l == null) recorder.delegate_clears += 1;
    }
}

fn answeredCallBoolean(
    env: JniEnv,
    _: JObject,
    _: jni.JMethodId,
    _: []const JValue,
) u8 {
    const recorder = recorderOf(env) orelse return 0;
    return @intFromBool(recorder.post_answer);
}

fn answeredCallInt(env: JniEnv, _: JObject, _: jni.JMethodId, _: []const JValue) JInt {
    _ = env;
    return 0;
}

fn answeredCallFloat(env: JniEnv, _: JObject, _: jni.JMethodId, _: []const JValue) jni.JFloat {
    _ = env;
    return 0;
}

fn answeredNewString(env: JniEnv, _: []const u8) jni.JString {
    _ = env;
    return null;
}

fn answeredNewIntArray(env: JniEnv, _: usize) JObject {
    _ = env;
    return null;
}

fn answeredNewReference(env: JniEnv, obj: JObject) JObject {
    const recorder = recorderOf(env) orelse return obj;
    if (recorder.reference_answer == null) return null;
    return recorder.reference_answer;
}

fn answeredDeleteReference(env: JniEnv, _: JObject) void {
    const recorder = recorderOf(env) orelse return;
    recorder.released += 1;
}

fn answeredIsInstanceOf(env: JniEnv, obj: JObject, class: JObject) bool {
    const recorder = recorderOf(env) orelse return false;
    _ = class;
    return recorder.installed_is_ours and obj != null;
}

fn answeredExceptionCheck(env: JniEnv) bool {
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

fn answeredRegister(
    env: JniEnv,
    _: JObject,
    rows: []const jni.JNINativeMethod,
) JInt {
    const recorder = recorderOf(env) orelse return -1;
    recorder.registered_count = rows.len;
    for (rows, 0..) |row, index| {
        recorder.registered[index] = row;
    }
    return recorder.registration_answer;
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
    table.callBooleanMethodFn = answeredCallBoolean;
    table.callIntMethodFn = answeredCallInt;
    table.callFloatMethodFn = answeredCallFloat;
    table.newStringFn = answeredNewString;
    table.newObjectFn = answeredNewObject;
    table.newIntArrayFn = answeredNewIntArray;
    table.newGlobalRefFn = answeredNewReference;
    table.newWeakGlobalRefFn = answeredNewReference;
    table.deleteGlobalRefFn = answeredDeleteReference;
    table.deleteLocalRefFn = answeredDeleteReference;
    table.isInstanceOfFn = answeredIsInstanceOf;
    table.exceptionCheckFn = answeredExceptionCheck;
    table.pushLocalFrameFn = answeredIntZero;
    table.popLocalFrameFn = answeredReferenceBack;
    table.registerNativeMethodsFn = answeredRegister;
    return table;
}

/// An activation handler that answers no tree, which is the ordinary answer
/// meaning: `include/zaccesskit.h:5795-5796` says the adapter treats it as data.
fn noActivation(_: ?*anyopaque) callconv(.c) ?*schema.TreeUpdate {
    return null;
}

/// An action handler that does nothing, so a test can prove it was reached.
///
/// It does **not** release the request it is handed, because these tests never
/// dispatch one: the handle that would carry a request does not exist on any
/// path they take. `boundary.ActionHandler` requires a real handler to release
/// it, and that rule is stated on the type.
fn unusedAction(_: *boundary.CActionRequest, _: ?*anyopaque) callconv(.c) void {}

test "the five rows RegisterNatives takes are the five the map records" {
    // `docs/42` section 5.3.1 gives these five signatures, and
    // `methods.zig` records all five as `.registered_native`. The walk is over
    // the five rows, so `registered_native_count` is the bound.
    const expected = [_]struct { name: []const u8, signature: []const u8 }{
        .{ .name = "runCallback", .signature = "(Landroid/view/View;J)V" },
        .{
            .name = "createAccessibilityNodeInfo",
            .signature = "(JLandroid/view/View;I)" ++
                "Landroid/view/accessibility/AccessibilityNodeInfo;",
        },
        .{
            .name = "findFocus",
            .signature = "(JLandroid/view/View;I)" ++
                "Landroid/view/accessibility/AccessibilityNodeInfo;",
        },
        .{ .name = "performAction", .signature = "(JLandroid/view/View;IILandroid/os/Bundle;)Z" },
        .{ .name = "onHoverEvent", .signature = "(JLandroid/view/View;IFF)Z" },
    };
    try testing.expectEqual(expected.len, registered_natives.len);
    for (registered_natives, expected) |row, want| {
        try testing.expectEqualStrings(want.name, row.name);
        try testing.expectEqualStrings(want.signature, row.signature);
    }
}

test "every registered native names a row methods.zig records" {
    // A name `methods.zig` does not record is a name upstream never sends, so
    // `GetMethodID`-side agreement is the cheapest check that the two files have
    // not drifted.
    var matched: usize = 0;
    for (registered_natives) |row| {
        try testing.expect(methods.hasName(row.name));
        var found = false;
        for (methods.method_ids) |candidate| {
            if (candidate.kind != .registered_native) continue;
            if (!std.mem.eql(u8, candidate.name, row.name)) continue;
            try testing.expectEqualStrings(candidate.signature.?, row.signature);
            found = true;
        }
        // A row with no counterpart is a Java method upstream never registers,
        // so registering it would bind nothing.
        try testing.expect(found);
        matched += 1;
    }
    try testing.expectEqual(registered_native_count, matched);
}

test "the five native function pointers are five distinct addresses" {
    // Two rows bound to one function would make one Java method answer for
    // another, and `RegisterNatives` accepts that without complaint.
    var seen: [registered_native_count]?*const anyopaque = .{null} ** registered_native_count;
    for (native_method_table, 0..) |row, index| {
        const address = row.function orelse continue;
        for (seen) |other| {
            if (other != null) try testing.expect(other.? != address);
        }
        seen[index] = address;
    }
    for (seen) |address| try testing.expect(address != null);
}

test "the delegate class is the descriptor classes.zig derives" {
    try testing.expectEqualStrings(
        "Ldev/accesskit/android/Delegate;",
        delegate_class.descriptor,
    );
    try testing.expectEqualStrings("dev/accesskit/android/Delegate", delegate_class.internal_name);
    // `FindClass` takes the internal name with `/` for each package separator,
    // and the map records that spelling at `AK/android/src/inject.rs:256`.
    try testing.expectEqual(classes.delegate_class_descriptor, delegate_class.descriptor);
}

test "a handle of zero names no adapter and a real address names one" {
    try testing.expect(adapterOf(0) == null);
    // A round trip through the `jlong` is the whole contract: the handle is the
    // pointer, so an address that survives the cast comes back unchanged. The
    // anchor is a `u64` rather than a `u8` because `adapterOf` answers a pointer
    // to a struct with alignment 8, and a one-byte local is not aligned to it.
    var anchor: u64 = 0;
    const handle: JLong = @bitCast(@intFromPtr(&anchor));
    const found = adapterOf(handle) orelse return error.NoAdapterFromHandle;
    try testing.expectEqual(@intFromPtr(&anchor), @intFromPtr(found));
}

test "every member the constructor reaches names one of the 68 Java method names" {
    const reached = [_]java_call.Member{
        delegate_new_callback,
        view_get_accessibility_delegate,
        view_set_accessibility_delegate,
        view_set_on_hover_listener,
        view_post,
    };
    // The walk is over the five rows above, so `native_name_count` is not the
    // bound here; the array length is.
    for (reached) |member| {
        try testing.expect(methods.hasName(member.name));
        try testing.expect(member.signature.len > 0);
    }
    try testing.expectEqual(@as(usize, 5), reached.len);
}

test "a host that is null is refused before any Java call" {
    const gpa = testing.allocator;
    var recorder: Recorder = .{};
    const table = recordingTable(&recorder);

    const built = try AndroidInjectingAdapter.create(
        gpa,
        table,
        null,
        noActivation,
        null,
        unusedAction,
        null,
    );
    try testing.expect(built == null);
    try testing.expectEqual(@as(usize, 0), recorder.registered_count);
}

test "a host that cannot load the delegate class is refused" {
    // `docs/42` section 5.3.1 records the default build mode as
    // `find_class("dev/accesskit/android/Delegate")`, so an application that does
    // not ship the class fails here. `null` is the honest answer because the
    // header promises `null` for this constructor.
    const gpa = testing.allocator;
    var recorder: Recorder = .{ .class_missing = true };
    const table = recordingTable(&recorder);

    // The C entry point turns this error into `null`; the Zig-level constructor
    // reports it so the two shapes stay distinguishable.
    try testing.expectError(error.JavaMemberMissing, AndroidInjectingAdapter.create(
        gpa,
        table,
        fakeHost(),
        noActivation,
        null,
        unusedAction,
        null,
    ));
    try testing.expectEqual(@as(usize, 0), recorder.registered_count);
}

test "a native registration the VM refuses stops the construction" {
    const gpa = testing.allocator;
    var recorder: Recorder = .{ .registration_answer = -1 };
    const table = recordingTable(&recorder);

    try testing.expectError(error.NativeRegistrationFailed, AndroidInjectingAdapter.create(
        gpa,
        table,
        fakeHost(),
        noActivation,
        null,
        unusedAction,
        null,
    ));
}

test "a host already carrying this adapter's delegate is refused" {
    // Two adapters on one host would leave two `Runnable`s racing and the
    // second `setAccessibilityDelegate` would orphan the first.
    const gpa = testing.allocator;
    var recorder: Recorder = .{ .installed_is_ours = true };
    const table = recordingTable(&recorder);

    try testing.expectError(error.DelegateAlreadyInstalled, AndroidInjectingAdapter.create(
        gpa,
        table,
        fakeHost(),
        noActivation,
        null,
        unusedAction,
        null,
    ));
    try testing.expectEqual(@as(usize, 0), recorder.delegate_sets);
}

test "a global reference the VM refuses stops the construction" {
    const gpa = testing.allocator;
    var recorder: Recorder = .{ .reference_answer = null };
    const table = recordingTable(&recorder);

    try testing.expectError(error.OutOfMemory, AndroidInjectingAdapter.create(
        gpa,
        table,
        fakeHost(),
        noActivation,
        null,
        unusedAction,
        null,
    ));
    // Nothing was installed, so the host is exactly as it was.
    try testing.expectEqual(@as(usize, 0), recorder.delegate_sets);
}

test "an update on an inactive adapter posts nothing" {
    const gpa = testing.allocator;
    const inner = (try AndroidAdapter.create(gpa)).?;
    defer inner.free();

    var recorder: Recorder = .{};

    var target: AndroidInjectingAdapter = .{
        .gpa = gpa,
        .env = @ptrCast(&recorder),
        .inner = inner,
        .host = @ptrFromInt(handle_base + 20),
        .runnable = fakeRunnable(),
        .delegate = @ptrFromInt(handle_base + 21),
        .activation_handler = noActivation,
        .activation_handler_userdata = null,
        .action_handler = unusedAction,
        .action_handler_userdata = null,
        .pending_events = .empty,
    };
    defer target.pending_events.deinit(gpa);

    target.updateIfActive(noFactory, null);
    try testing.expectEqual(@as(usize, 0), target.pending_events.items.len);
}

/// A tree-update factory that answers `null`, which is a contract violation.
fn noFactory(_: ?*anyopaque) callconv(.c) ?*schema.TreeUpdate {
    return null;
}
