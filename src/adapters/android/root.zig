//! The JNI boundary surface of the Android adapter, and the thirteen C
//! entry points `src/capi/platform.zig` writes.
//!
//! Upstream is `accesskit_android` 0.9.0, 2604 lines across the eight files
//! under `AK/android/src/`, plus 70 lines of Java at
//! `AK/android/java/dev/accesskit/android/Delegate.java`.
//!
//! | Module | Upstream | Holds |
//! |---|---|---|
//! | `constants.zig` | `AK/android/src/util.rs:14-68` | the 43 Android SDK constant names |
//! | `values.zig` | the same lines | the 38 integers behind those names |
//! | `classes.zig` | throughout | the 20 class descriptors of map section 1.4.3 |
//! | `methods.zig` | the eight files | the 68 Java method names and the 27 lookups |
//! | `jni.zig` | `inject.rs:14-23`, `:99` | 13 `JNIEnv` methods, 6 handle types, 4 scalars |
//! | `jni_table.zig` | `inject.rs:14-23` | the 24 injectable JNI entry points |
//! | `java_call.zig` | throughout | the checked lookup and call helpers |
//! | `node_id_map.zig` | `util.rs:134-158` | the two-way virtual id map |
//! | `node.zig` | `node.rs:196-445` | the node fill |
//! | `platform_action.zig` | `action.rs:33` | the decoded Java action |
//! | `queued_events.zig` | `adapter.rs:91-197` | the event queue and its raise |
//! | `adapter.zig` | `adapter.rs` | the plain adapter |
//! | `injecting.zig` | `inject.rs` | the adapter that installs itself |
//!
//! **The four JNI types live here and should move.** `JniEnv`, `JObject`, `JInt`
//! and `JFloat` are declared at the bottom of this file because
//! `src/capi/platform.zig:154-165` names them in its own signatures and this
//! directory is what it imports. `jni_table.zig:95-123` declares the same four
//! types and its doc comment records the same plan. **The integration owner
//! should declare them once in `src/capi/boundary.zig`**, which is the leaf both
//! sides import, delete both copies, and have `platform.zig` reach them from
//! there. Until that happens the two are the same type by definition rather than
//! by agreement, so a change to one is a change to both.
//!
//! **The verification split, as map sections 3.1 to 3.4 state it.** Level 1 is
//! that the source type-checks and generates code for its target. Level 2 is
//! that the object links against the real system libraries. Level 3 is that the
//! adapter works against a live assistive technology. This host reaches level 1
//! for Android and no further: `zig build-exe -target aarch64-linux-android`
//! fails at `-llog` because no NDK sysroot is installed here.
//!
//! **What is compiled and tested on this host.** Every module above is compiled
//! and tested here, and the tests drive the **real** adapter body through
//! `jni_table.inertTable`, so the call sequences, the ownership rules and the
//! decisions each entry point makes are all exercised with no JVM. What cannot
//! be exercised here is the part that needs a real VM: the 24 slots resolve
//! against a real `JNINativeInterface`, `dev.accesskit.android.Delegate` has to
//! be on the classpath, and the five registered natives have to bind.
//! **Every name and descriptor in this directory is a string to the Zig
//! compiler**, so a misspelt one passes level 1 and fails at `GetMethodID` on a
//! device, which is why each is pinned by a test that asserts its exact
//! spelling.
//!
//! **What this directory deliberately does not carry.** `AK/android/src/inject.rs:88-105`
//! declares four file-scope statics. Map section 5.3.2 is explicit that a Zig
//! port threads that state instead, so no handle map and no counter appear here:
//! the counter, the map and the closure become fields of the adapter struct, and
//! the `jlong` the Java natives carry **is** the adapter pointer.
//!
//! It also does not bind `jni.h`. Map section 2.4 records that `translate-c`
//! parses a JNI header, but the run was against a desktop JDK 7 header rather
//! than the NDK header the port needs, so the declarations are rung 3 work for
//! `build.zig`. And it does not ship the Java class: map section 5.3.1 records
//! that the 70 lines of `Delegate.java` are a build input the port must carry,
//! and that both the Java file and, for the `embedded-dex` mode, a prebuilt
//! `classes.dex` need a licence and placement decision that `docs/40-plan.md`
//! M10 owns.
//!
//! **The loop bound.** Every walk over a domain is in one of the modules above
//! and each derives its own bound in its own doc comment. The two walks here are
//! over `handle_type_names` and over `entry_point_names`, whose lengths are
//! `handle_type_count` and `entry_point_count`.

const std = @import("std");

const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const schema = @import("../../schema/root.zig");

const adapter_module = @import("adapter.zig");
const classes_module = @import("classes.zig");
const constants_module = @import("constants.zig");
const injecting_module = @import("injecting.zig");
const java_call_module = @import("java_call.zig");
const jni_table_module = @import("jni_table.zig");
const jni_census = @import("jni.zig");
const methods_module = @import("methods.zig");
const node_module = @import("node.zig");
const node_id_map_module = @import("node_id_map.zig");
const platform_action_module = @import("platform_action.zig");
const queued_events_module = @import("queued_events.zig");
const values_module = @import("values.zig");

const ActionHandler = boundary.ActionHandler;
const ActivationHandler = boundary.ActivationHandler;
const CTreeUpdate = boundary.CTreeUpdate;
const TreeUpdateFactory = boundary.TreeUpdateFactory;

const Allocator = std.mem.Allocator;
const testing = std.testing;

// --- the four JNI types `src/capi/platform.zig` names -----------------------
//
// Each is the spelling `jni.h` uses with the width `jni_md.h` gives on this
// target, and each is the same type `jni_table.zig` declares. **The integration
// owner moves all four to `src/capi/boundary.zig` and deletes both copies**;
// `platform.zig` reaches them from there. See the module doc.

/// `JNIEnv *`, `jni.h:197` in C mode: a pointer to the function table, so an
/// opaque pointer is the whole contract.
pub const JniEnv = jni_table_module.JniEnv;

/// `jobject`, `jni.h:101`: a pointer to an opaque Java object. `jclass`,
/// `jstring`, `jarray`, `jintArray` and `jobjectArray` are all typedefs of it,
/// so one type names the whole family.
pub const JObject = jni_table_module.JObject;

/// `jint`, `jni_md.h:33`, a C `int` and therefore 32 bits on every target the
/// port claims for Android.
pub const JInt = values_module.JInt;

/// `jfloat`, `jni.h:60`, a C `float` and therefore 32 bits.
pub const JFloat = jni_table_module.JFloat;

// --- the four handle types --------------------------------------------------

/// The action one Java action callback supplied, decoded.
///
/// The caller owns one and releases it with
/// `accesskit_android_platform_action_free`, exactly once. **The `arguments`
/// object belongs to the Java call and is not retained**, so nothing in the
/// handle points into Java.
pub const AndroidPlatformAction = platform_action_module.AndroidPlatformAction;

/// The events one adapter call produced, boxed so a C handle can name them.
///
/// `accesskit_android_queued_events_raise` is the only way to release one.
/// **The adapter must outlive every handle from it**, because the virtual ids the
/// events name live in the adapter's id map.
pub const AndroidQueuedEvents = queued_events_module.AndroidQueuedEvents;

/// The adapter `accesskit_android_adapter_new` returns.
///
/// The caller owns one and releases it with `accesskit_android_adapter_free`,
/// exactly once. That call releases the tree the adapter holds, both maps of the
/// id map and the block the adapter itself was allocated in.
pub const AndroidAdapter = adapter_module.AndroidAdapter;

/// The adapter `accesskit_android_injecting_adapter_new` returns.
///
/// The caller owns one and releases it with
/// `accesskit_android_injecting_adapter_free`, exactly once, **on the thread
/// that constructed it**: the release takes the host's delegate back through the
/// environment the constructor stored.
pub const AndroidInjectingAdapter = injecting_module.AndroidInjectingAdapter;

/// How many handle types this file declares.
pub const handle_type_count = 4;

/// The four handle types, in the order `src/capi/platform.zig` first names them.
///
/// The array length is `handle_type_count`, which is the bound every test that
/// walks it uses.
pub const handle_type_names = [handle_type_count][:0]const u8{
    "AndroidPlatformAction",
    "AndroidQueuedEvents",
    "AndroidAdapter",
    "AndroidInjectingAdapter",
};

// =============================================================================
// The thirteen declarations.
// =============================================================================

/// Builds a platform action from the Java object an Android action callback
/// supplied.
///
/// `accesskit_android_platform_action_from_java`,
/// `include/zaccesskit.h:5725-5727`, upstream `src/lib.rs:2539`.
///
/// Returns `null` when the allocation failed. The caller owns a non-null result
/// and releases it with `accesskit_android_platform_action_free`. The
/// `arguments` object belongs to the Java call and is not retained.
///
/// **A JNI lookup that fails also answers `null`**, with
/// `accesskit_last_error` left at `ACCESSKIT_ERROR_NONE`. The header's promise
/// is about the allocation, so a missing `Bundle` member must not be reported as
/// a failed one.
pub fn androidPlatformActionFromJava(
    env: JniEnv,
    action: JInt,
    arguments: JObject,
) ?*AndroidPlatformAction {
    return platform_action_module.fromJava(env, action, arguments);
}

/// Releases a platform action and everything it owns, exactly once.
///
/// `accesskit_android_platform_action_free`, `include/zaccesskit.h:5734-5736`,
/// upstream `src/lib.rs:2544`.
///
/// The node the action names is not released. Passing `null` terminates the
/// process, which is why this does not check.
pub fn androidPlatformActionFree(
    platform_action_handle: *AndroidPlatformAction,
) void {
    platform_action_module.free(platform_action_handle);
}

/// Raises the queued events on the platform and releases the handle.
///
/// `accesskit_android_queued_events_raise`,
/// `include/zaccesskit.h:5746-5750`, upstream `src/lib.rs:2552`.
///
/// This call is the only way to release the handle. A second call on the same
/// pointer is a use-after-free, and passing `null` terminates the process.
///
/// **The adapter must outlive this call**, which is the borrow rule the header
/// states and the queue's `adapter` field exists for.
pub fn androidQueuedEventsRaise(
    events: *AndroidQueuedEvents,
    env: JniEnv,
    host: JObject,
) void {
    _ = events.raise(jni_table_module.realTable(env), host);
    events.deinit();
    allocation.release(@ptrCast(@alignCast(events)));
}

/// Returns an Android adapter, or `null` when the allocation failed.
///
/// `accesskit_android_adapter_new`, `include/zaccesskit.h:5759`, upstream
/// `src/lib.rs:2557`.
///
/// This adapter takes no handler at construction: the activation and action
/// handlers arrive on the calls that need them. The caller owns a non-null
/// result and releases it with `accesskit_android_adapter_free`, and calls
/// `accesskit_last_error` after a `null` return.
pub fn androidAdapterNew() ?*AndroidAdapter {
    const gpa = allocation.allocator();
    return AndroidAdapter.create(gpa) catch |err| {
        noteAllocationFailure(err);
        return null;
    };
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_android_adapter_free`, `include/zaccesskit.h:5767-5768`, upstream
/// `src/lib.rs:2561`.
///
/// A tree update already handed to the adapter was released by the library.
/// Passing `null` terminates the process.
pub fn androidAdapterFree(adapter: *AndroidAdapter) void {
    adapter.free();
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// `accesskit_android_adapter_update_if_active`,
/// `include/zaccesskit.h:5779-5783`, upstream `src/lib.rs:2570`.
///
/// Returns the events the answer produced, or `null` when the adapter is not
/// active. The caller owns a non-null result and must pass it to
/// `accesskit_android_queued_events_raise`, which also releases it.
///
/// **`null` carries three meanings and the header admits only one.** An inactive
/// adapter builds nothing and raises nothing. A factory that answered `null` is a
/// contract violation upstream unwraps at `adapter.rs:554`, and a tree the
/// consumer half rejected is an ordinary failure of a well-formed call. The
/// header has no way to say which, so all three answer `null` and the
/// distinction lives in `AndroidAdapter.last_error`, which this call clears at
/// its start and fills on either failure.
pub fn androidAdapterUpdateIfActive(
    adapter: *AndroidAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*AndroidQueuedEvents {
    const produced = adapter.updateIfActive(update_factory, update_factory_userdata) catch |err| {
        adapter.last_error = err;
        noteAllocationFailure(err);
        return null;
    };
    const events = produced orelse return null;
    return boxEvents(events);
}

/// Returns the `AccessibilityNodeInfo` for `virtual_view_id`, or `null` when
/// there is no such node.
///
/// `accesskit_android_adapter_create_accessibility_node_info`,
/// `include/zaccesskit.h:5792-5799`, upstream `src/lib.rs:2577`.
///
/// Ownership of the JNI local reference does not transfer; it belongs to the call
/// this was made from. `activation_handler` is supplied on this call and the
/// library drops it when the call returns.
///
/// **A `null` activation answer is ordinary and means "no tree"**, so it answers
/// `null` here rather than calling the handler again.
pub fn androidAdapterCreateAccessibilityNodeInfo(
    adapter: *AndroidAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    env: JniEnv,
    host: JObject,
    virtual_view_id: JInt,
) JObject {
    const answer = adapter.createNodeInfo(
        activation_handler,
        activation_handler_userdata,
        jni_table_module.realTable(env),
        host,
        virtual_view_id,
    ) catch |err| {
        adapter.last_error = err;
        noteAllocationFailure(err);
        return null;
    };
    return answer orelse null;
}

/// Returns the `AccessibilityNodeInfo` the focus belongs to, or `null` when the
/// tree has no focus.
///
/// `accesskit_android_adapter_find_focus`, `include/zaccesskit.h:5808-5815`,
/// upstream `src/lib.rs:2585`.
///
/// Ownership of the JNI local reference does not transfer. The activation
/// handler is supplied on this call and dropped when it returns.
///
/// `focus_type` is passed and not used: the tree has one focus and the header
/// names one, so both input modes answer the same node.
pub fn androidAdapterFindFocus(
    adapter: *AndroidAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    env: JniEnv,
    host: JObject,
    focus_type: JInt,
) JObject {
    _ = focus_type;
    const answer = adapter.findFocus(
        activation_handler,
        activation_handler_userdata,
        jni_table_module.realTable(env),
        host,
    ) catch |err| {
        adapter.last_error = err;
        noteAllocationFailure(err);
        return null;
    };
    return answer orelse null;
}

/// Hands `action` to the application and returns the events the answer
/// produced.
///
/// `accesskit_android_adapter_perform_action`,
/// `include/zaccesskit.h:5825-5831`, upstream `src/lib.rs:2598`.
///
/// Returns `null` when the adapter is not active. The caller owns a non-null
/// result and must pass it to `accesskit_android_queued_events_raise`.
///
/// **An active adapter always answers a queue**, even an empty one. Every
/// action's effect arrives as a tree update, which reaches
/// `accesskit_android_adapter_update_if_active`, so this call has nothing of its
/// own to raise.
pub fn androidAdapterPerformAction(
    adapter: *AndroidAdapter,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
    virtual_view_id: JInt,
    action: *const AndroidPlatformAction,
) ?*AndroidQueuedEvents {
    const produced = adapter.performAction(
        action_handler,
        action_handler_userdata,
        virtual_view_id,
        action.decoded().*,
    ) catch |err| {
        adapter.last_error = err;
        noteAllocationFailure(err);
        return null;
    };
    const events = produced orelse return null;
    return boxEvents(events);
}

/// Delivers a hover at the logical pixel `(x, y)` to the application.
///
/// `accesskit_android_adapter_on_hover_event`,
/// `include/zaccesskit.h:5840-5847`, upstream `src/lib.rs:2611`.
///
/// Returns the events the answer produced, or `null` when the adapter is not
/// active. The caller owns a non-null result.
pub fn androidAdapterOnHoverEvent(
    adapter: *AndroidAdapter,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action: JInt,
    x: JFloat,
    y: JFloat,
) ?*AndroidQueuedEvents {
    const produced = adapter.onHoverEvent(
        activation_handler,
        activation_handler_userdata,
        action,
        x,
        y,
    ) catch |err| {
        adapter.last_error = err;
        noteAllocationFailure(err);
        return null;
    };
    const events = produced orelse return null;
    return boxEvents(events);
}

/// Returns an injecting Android adapter bound to `host`, or `null` when the
/// installation did not happen.
///
/// `accesskit_android_injecting_adapter_new`,
/// `include/zaccesskit.h:5857-5862`, upstream `src/lib.rs:2619`.
///
/// `host` and both handler userdata pointers must stay valid until the adapter
/// is released. The caller owns the adapter and releases it with
/// `accesskit_android_injecting_adapter_free`.
///
/// **`null` covers an allocation that failed, a `Delegate` class the application
/// does not ship, a native registration the VM refused, and a host that already
/// carries this adapter's delegate.** All four leave the host exactly as it was.
pub fn androidInjectingAdapterNew(
    env: JniEnv,
    host: JObject,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*AndroidInjectingAdapter {
    const gpa = allocation.allocator();
    return AndroidInjectingAdapter.create(
        gpa,
        jni_table_module.realTable(env),
        host,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    ) catch |err| {
        noteAllocationFailure(err);
        return null;
    };
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// `accesskit_android_injecting_adapter_free`,
/// `include/zaccesskit.h:5869-5870`, upstream `src/lib.rs:2628`.
///
/// Passing `null` terminates the process.
///
/// **This must run on the thread that constructed the adapter.** The release
/// takes the host's delegate back through the environment the constructor
/// stored, and a `JNIEnv *` is valid only on its own thread.
pub fn androidInjectingAdapterFree(adapter: *AndroidInjectingAdapter) void {
    adapter.free(jni_table_module.realTable(adapter.env));
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// `accesskit_android_injecting_adapter_update_if_active`,
/// `include/zaccesskit.h:5882-5886`, upstream `src/lib.rs:2633`.
///
/// This adapter returns nothing, so there are no queued events to raise: the
/// injecting adapter delivers the tree to its own host and raises what it
/// produced from the `Runnable` the UI thread runs.
pub fn androidInjectingAdapterUpdateIfActive(
    adapter: *AndroidInjectingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) void {
    adapter.updateIfActive(update_factory, update_factory_userdata);
}

/// Moves an events value into a block a C handle can name, or releases it.
///
/// The block comes from `allocation.create` because
/// `accesskit_android_queued_events_raise` releases it through the declared
/// allocator. A failed `create` releases the value it was handed instead, so
/// neither outcome leaks the array.
///
/// `error.OutOfMemory` is reported to `accesskit_last_error` here, because this
/// is the last point where the C caller can still read it.
fn boxEvents(events: AndroidQueuedEvents) ?*AndroidQueuedEvents {
    const block = allocation.create(AndroidQueuedEvents) catch {
        var owned = events;
        owned.deinit();
        allocation.failWith(.out_of_memory);
        return null;
    };
    block.* = events;
    return block;
}

/// Records `ACCESSKIT_ERROR_OUT_OF_MEMORY` when the failure really was one.
///
/// `include/zaccesskit.h:5766-5767` promises `null` only for a failed
/// allocation, so every other failure leaves the slot clear. A JNI lookup that
/// fails and a tree the consumer half rejected are both ordinary answers to this
/// surface, and reporting them as a failed allocation would tell a C consumer to
/// retry something that cannot succeed.
fn noteAllocationFailure(err: anyerror) void {
    if (err == error.OutOfMemory) allocation.failWith(.out_of_memory);
}

/// How many declarations this file owns, which is the figure
/// `src/capi/platform.zig` counts for the `.android` guard.
pub const entry_point_count = 13;

/// The thirteen C symbols this file owns, in `export_records` order.
///
/// The array length is `entry_point_count`, which is the bound every test that
/// walks it uses. The names are the C symbols rather than the Zig ones, because
/// `src/capi/platform.zig:759-772` is what has to agree with them.
pub const entry_point_names = [entry_point_count][:0]const u8{
    "accesskit_android_platform_action_from_java",
    "accesskit_android_platform_action_free",
    "accesskit_android_queued_events_raise",
    "accesskit_android_adapter_new",
    "accesskit_android_adapter_free",
    "accesskit_android_adapter_update_if_active",
    "accesskit_android_adapter_create_accessibility_node_info",
    "accesskit_android_adapter_find_focus",
    "accesskit_android_adapter_perform_action",
    "accesskit_android_adapter_on_hover_event",
    "accesskit_android_injecting_adapter_new",
    "accesskit_android_injecting_adapter_free",
    "accesskit_android_injecting_adapter_update_if_active",
};

/// Every module of the boundary, re-exported so a caller reaches one namespace.
pub const modules = struct {
    /// The 20 Java class descriptors.
    pub const classes = classes_module;
    /// The 43 Android SDK constant names.
    pub const constants = constants_module;
    /// The `JNIEnv` and `JavaVM` entry points, handle types and scalars.
    pub const jni = jni_census;
    /// The 68 Java method names and the 27 lookups.
    pub const methods = methods_module;
    /// The 24 injectable JNI entry points.
    pub const jni_table = jni_table_module;
    /// The checked lookup and call helpers.
    pub const java_call = java_call_module;
    /// The two-way virtual id map.
    pub const node_id_map = node_id_map_module;
    /// The node fill.
    pub const node = node_module;
    /// The 38 integers behind the constant names.
    pub const values = values_module;
    /// The decoded Java action.
    pub const platform_action = platform_action_module;
    /// The event queue and its raise.
    pub const queued_events = queued_events_module;
    /// The plain adapter.
    pub const adapter = adapter_module;
    /// The adapter that installs itself.
    pub const injecting = injecting_module;
};

comptime {
    // Map section 1.4.5 totals.
    if (constants_module.constant_count != 43) {
        @compileError("the map gives 43 integer constants");
    }
    if (methods_module.method_name_count != 68) @compileError("the map gives 68 method names");
    if (classes_module.descriptor_count != 20) {
        @compileError("the map's table lists 20 descriptors");
    }
    if (jni_census.jni_env_method_count != 13) {
        @compileError("the map gives 13 JNIEnv entry points");
    }
    if (jni_census.handle_type_count + jni_census.scalar_type_count != 10) {
        @compileError("the map gives 10 handle and scalar types");
    }
    if (methods_module.method_name_count - methods_module.pinned_signature_count !=
        methods_module.unpinned_name_count)
    {
        @compileError("the unpinned count must be 68 minus 22");
    }

    // The two figures the census above does not cover. `src/capi/platform.zig`
    // asserts the same 13 and the same 13 symbols, so a name changed on one side
    // and not the other is a link error the C consumer sees rather than a test.
    if (entry_point_count != 13) @compileError("the header declares 13 android functions");
    if (entry_point_names.len != entry_point_count) {
        @compileError("the array length is the count");
    }
    if (handle_type_count != 4) @compileError("the four handle types are four");

    // Every handle type has exactly one declaration, because `platform.zig`
    // writes four of them in its signatures and a duplicate would be two shapes
    // for one type.
    if (AndroidPlatformAction != platform_action_module.AndroidPlatformAction) {
        @compileError("the platform action alias must name the declaration");
    }
    if (AndroidQueuedEvents != queued_events_module.AndroidQueuedEvents) {
        @compileError("the queued events alias must name the declaration");
    }
    if (AndroidAdapter != adapter_module.AndroidAdapter) {
        @compileError("the adapter alias must name the declaration");
    }
    if (AndroidInjectingAdapter != injecting_module.AndroidInjectingAdapter) {
        @compileError("the injecting adapter alias must name the declaration");
    }

    // The two JNI failure tags are declared once in `node.zig`'s `FillError` and
    // once in `platform_action.zig`'s `DecodeError`. They carry the same names,
    // and a module that catches one and misses the other is a module that
    // mishandles a failed lookup, so the two sets are compared here where both
    // are visible.
    const DecodeErrors = @typeInfo(platform_action_module.DecodeError).error_set.?;
    const FillErrors = @typeInfo(node_module.FillError).error_set.?;
    for (DecodeErrors) |tag| {
        var found = false;
        for (FillErrors) |other| {
            if (std.mem.eql(u8, tag.name, other.name)) found = true;
        }
        if (!found) {
            @compileError(std.fmt.comptimePrint(
                "the decode tag {s} is not in FillError",
                .{tag.name},
            ));
        }
    }
}

// --- Tests --------------------------------------------------------------------

/// What one handler call observed, reached through `userdata`.
///
/// One struct serves both the activation handler and the tree-update factory,
/// because both take the same one pointer and both have to be counted. The C
/// callback types take one `?*anyopaque` and nothing else, so a counter has to
/// travel through it; a closure would capture it, and `AGENTS.md` section 3
/// requires state to be a parameter rather than a capture.
///
/// **The update is built the way the C ABI builds one**: the block comes from
/// `allocation.create` and the nodes inside it come from `gpa`. A real factory
/// is `accesskit_tree_update_new` followed by `accesskit_tree_update_set_*`, and
/// the adapter releases the block through `allocation.release`, which refuses a
/// block this library never returned.
const Probe = struct {
    /// The allocator a built update is allocated from.
    gpa: Allocator,
    /// How many times the handler was called.
    calls: usize = 0,
    /// The update the handler answers, or `null` for the ordinary "no tree".
    answer: ?*CTreeUpdate = null,
    /// Whether a call builds a one-node update instead of answering `answer`.
    build_root: bool = false,

    /// Counts this call and answers `answer`, building a root update when asked.
    fn take(self: *Probe) ?*CTreeUpdate {
        self.calls += 1;
        if (self.answer) |answer| return answer;
        if (!self.build_root) return null;
        const update = allocation.create(CTreeUpdate) catch return null;
        var owned: CTreeUpdate = .{
            .nodes = .empty,
            .tree = schema.TreeInfo.init(.{ .value = 1 }),
            .tree_id = schema.tree_id_root,
            .focus = .{ .value = 1 },
        };
        owned.pushNode(self.gpa, .{ .value = 1 }, schema.Node.init(self.gpa, .button)) catch {
            allocation.release(update);
            return null;
        };
        update.* = owned;
        return update;
    }
};

/// An activation handler that counts itself and answers through its probe.
fn probedActivation(userdata: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    const probe: *Probe = @ptrCast(@alignCast(userdata orelse return null));
    return probe.take();
}

/// A tree-update factory that counts itself and answers through its probe.
fn probedFactory(userdata: ?*anyopaque) callconv(.c) ?*CTreeUpdate {
    const probe: *Probe = @ptrCast(@alignCast(userdata orelse return null));
    return probe.take();
}

/// An action handler that does nothing.
///
/// It does **not** release the request it is handed. `boundary.ActionHandler`
/// requires every handler to release it with `accesskit_action_request_free`
/// before returning, and that rule is stated on the type. No test below reaches
/// a path that dispatches one, so there is nothing to release; a test that did
/// would have to call `schema.cActionRequestDeinit` here, and this comment is
/// what makes that change obvious.
fn unusedAction(_: *boundary.CActionRequest, _: ?*anyopaque) callconv(.c) void {}

/// An adapter with a one-node tree, plus the probe that put it there.
const ActiveAdapter = struct {
    /// The adapter itself, released by `deinit`.
    adapter: *AndroidAdapter,
    /// The probe the activation and factory calls reach.
    probe: Probe,

    /// Builds an adapter and activates it.
    ///
    /// **Activation goes through the activation handler, not through
    /// `update_if_active`.** The latter only applies an update to an adapter that
    /// already holds a tree, which is what `docs/42` section 4.2 draws, so a
    /// first activation has to arrive on a node info request. The node info the
    /// request then builds is `null` here, because there is no VM behind the
    /// inert environment, and that is the honest answer.
    fn init(gpa: Allocator) !ActiveAdapter {
        const adapter = try AndroidAdapter.create(gpa) orelse return error.NoAdapterBuilt;
        var probe: Probe = .{ .gpa = gpa, .build_root = true };
        _ = androidAdapterCreateAccessibilityNodeInfo(
            adapter,
            probedActivation,
            &probe,
            null,
            null,
            values_module.HOST_VIEW_ID,
        );
        if (!adapter.isActive()) return error.AdapterDidNotActivate;
        return .{ .adapter = adapter, .probe = probe };
    }

    fn deinit(self: *ActiveAdapter) void {
        androidAdapterFree(self.adapter);
        // SAFETY: the line above released every resource this fixture owns, and
        // the reset is what a stale read sees. The allocator owns no memory and
        // the probe owns none either, so neither has anything to invalidate.
        self.* = undefined;
    }
};

test "every module of the boundary is reachable" {
    testing.refAllDecls(modules.classes);
    testing.refAllDecls(modules.constants);
    testing.refAllDecls(modules.methods);
    testing.refAllDecls(modules.jni);
    testing.refAllDecls(modules.jni_table);
    testing.refAllDecls(modules.java_call);
    testing.refAllDecls(modules.node_id_map);
    testing.refAllDecls(modules.node);
    testing.refAllDecls(modules.values);
    testing.refAllDecls(modules.platform_action);
    testing.refAllDecls(modules.queued_events);
    testing.refAllDecls(modules.adapter);
    testing.refAllDecls(modules.injecting);
}

test "the census holds the figures the map measured" {
    try testing.expectEqual(@as(usize, 43), constants_module.constant_count);
    try testing.expectEqual(@as(usize, 68), methods_module.method_name_count);
    try testing.expectEqual(@as(usize, 20), classes_module.descriptor_count);
    try testing.expectEqual(@as(usize, 19), classes_module.map_descriptor_count);
    try testing.expectEqual(@as(usize, 13), jni_census.jni_env_method_count);
    try testing.expectEqual(@as(usize, 5), registeredNativeCount());
}

test "22 of the 68 method names have a lookup row and 46 do not" {
    // The walk is over the 68 rows of `methods_module.method_names`, so the bound
    // is `methods_module.method_name_count`.
    var covered: usize = 0;
    for (methods_module.method_names) |name| {
        if (methods_module.findByName(name) != null) covered += 1;
    }
    try testing.expectEqual(methods_module.pinned_name_count, covered);
    try testing.expectEqual(@as(usize, 22), covered);
    try testing.expectEqual(
        methods_module.unpinned_name_count,
        methods_module.method_name_count - covered,
    );
}

test "the thirteen C symbols are the ones the header declares" {
    // The expected list is a literal in this test on purpose: reading it out of
    // `entry_point_names` would compare the table with itself. The walk is over
    // the thirteen rows, so `entry_point_count` is the bound.
    const expected = [_][]const u8{
        "accesskit_android_platform_action_from_java",
        "accesskit_android_platform_action_free",
        "accesskit_android_queued_events_raise",
        "accesskit_android_adapter_new",
        "accesskit_android_adapter_free",
        "accesskit_android_adapter_update_if_active",
        "accesskit_android_adapter_create_accessibility_node_info",
        "accesskit_android_adapter_find_focus",
        "accesskit_android_adapter_perform_action",
        "accesskit_android_adapter_on_hover_event",
        "accesskit_android_injecting_adapter_new",
        "accesskit_android_injecting_adapter_free",
        "accesskit_android_injecting_adapter_update_if_active",
    };
    try testing.expectEqual(expected.len, entry_point_names.len);
    for (entry_point_names, expected) |actual, want| {
        try testing.expectEqualStrings(want, actual);
        try testing.expect(std.mem.startsWith(u8, want, "accesskit_android_"));
    }
}

test "the four handle types are the four platform.zig writes" {
    // The walk is over the four rows, so `handle_type_count` is the bound.
    try testing.expectEqual(@as(usize, 4), handle_type_names.len);
    try testing.expectEqualStrings("AndroidPlatformAction", handle_type_names[0]);
    try testing.expectEqualStrings("AndroidQueuedEvents", handle_type_names[1]);
    try testing.expectEqualStrings("AndroidAdapter", handle_type_names[2]);
    try testing.expectEqualStrings("AndroidInjectingAdapter", handle_type_names[3]);
}

test "the four JNI types are the ones platform.zig names" {
    // `src/capi/platform.zig:154-165` declares these four for the same purpose.
    // They are the same types `jni_table.zig` declares, and that is the point of
    // the assertion: a second declaration is a second thing to keep in step.
    try testing.expectEqual(jni_table_module.JniEnv, JniEnv);
    try testing.expectEqual(jni_table_module.JObject, JObject);
    try testing.expectEqual(jni_table_module.JInt, JInt);
    try testing.expectEqual(jni_table_module.JFloat, JFloat);
}

test "a new adapter is inactive and its id map is empty" {
    allocation.clearError();
    const adapter = androidAdapterNew() orelse return error.NoAdapterBuilt;
    defer androidAdapterFree(adapter);

    try testing.expect(!adapter.isActive());
    try testing.expectEqual(@as(usize, 0), adapter.idMap().count());
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "an update on an inactive adapter builds nothing and answers null" {
    // `docs/42` section 4.2 records that the factory exists so a deferred
    // application does not build a tree the adapter would discard, so the
    // factory is not even reached.
    const gpa = allocation.allocator();
    allocation.clearError();
    const adapter = androidAdapterNew() orelse return error.NoAdapterBuilt;
    defer androidAdapterFree(adapter);

    var probe: Probe = .{ .gpa = gpa };
    const events = androidAdapterUpdateIfActive(adapter, probedFactory, &probe);
    try testing.expect(events == null);
    try testing.expectEqual(@as(usize, 0), probe.calls);
    try testing.expect(!adapter.isActive());
}

test "a factory that answers null is a contract violation, not an inactive tree" {
    // The two are the same Zig type and different contracts, so the difference
    // has to be visible: the factory is reached, and the adapter records the
    // failure rather than reporting "not active".
    const gpa = allocation.allocator();
    allocation.clearError();
    var active = try ActiveAdapter.init(gpa);
    defer active.deinit();

    var probe: Probe = .{ .gpa = gpa };
    try testing.expect(androidAdapterUpdateIfActive(
        active.adapter,
        probedFactory,
        &probe,
    ) == null);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(adapter_module.Error.NullTreeUpdate, active.adapter.last_error.?);
    // The header promises `null` for an inactive adapter, and this is not one.
    try testing.expect(active.adapter.isActive());
    // A contract violation is not an allocation failure, so the slot stays clear
    // and a C consumer is not told to retry something that cannot succeed.
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "an update that raises nothing still answers a releasable handle" {
    const gpa = allocation.allocator();
    allocation.clearError();
    var active = try ActiveAdapter.init(gpa);
    defer active.deinit();

    // The first update produced the activation events; a second one against the
    // same tree commits with nothing to report and still answers a handle.
    const events = androidAdapterUpdateIfActive(
        active.adapter,
        probedFactory,
        &active.probe,
    ) orelse return error.NoEventsRaised;
    androidQueuedEventsRaise(events, null, null);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "an action on an inactive adapter answers null and raises nothing" {
    allocation.clearError();
    const adapter = androidAdapterNew() orelse return error.NoAdapterBuilt;
    defer androidAdapterFree(adapter);

    const action = androidPlatformActionFromJava(null, values_module.ACTION_CLICK, null) orelse
        return error.NoActionBuilt;
    defer androidPlatformActionFree(action);

    const events = androidAdapterPerformAction(adapter, unusedAction, null, 0, action);
    try testing.expect(events == null);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "an action on an active adapter with no such node answers an empty queue" {
    // An id the map never minted is not an inactive adapter, so the answer is a
    // handle rather than `null`, and that handle raises nothing.
    const gpa = allocation.allocator();
    allocation.clearError();
    var active = try ActiveAdapter.init(gpa);
    defer active.deinit();

    const action = androidPlatformActionFromJava(null, values_module.ACTION_CLICK, null) orelse
        return error.NoActionBuilt;
    defer androidPlatformActionFree(action);

    const events = androidAdapterPerformAction(
        active.adapter,
        unusedAction,
        null,
        99,
        action,
    ) orelse return error.NoQueueBuilt;
    androidQueuedEventsRaise(events, null, null);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "an action on the tree root reaches the application" {
    // The root is what `values_module.HOST_VIEW_ID` names, so this is the one
    // virtual id a caller can use before the fill has minted any.
    const gpa = allocation.allocator();
    var active = try ActiveAdapter.init(gpa);
    defer active.deinit();

    // The id is minted for the root, and the request that reaches the handler
    // names the same node the tree holds.
    const tree = active.adapter.treeOf() orelse return error.NoTree;
    _ = try active.adapter.idMap().getOrCreateJavaId(tree.stateOf().root());

    const action = androidPlatformActionFromJava(null, values_module.ACTION_CLICK, null) orelse
        return error.NoActionBuilt;
    defer androidPlatformActionFree(action);

    const events = androidAdapterPerformAction(
        active.adapter,
        unusedAction,
        null,
        values_module.HOST_VIEW_ID,
        action,
    ) orelse return error.NoQueueBuilt;
    androidQueuedEventsRaise(events, null, null);
}

test "a hover on an inactive adapter answers null" {
    allocation.clearError();
    const adapter = androidAdapterNew() orelse return error.NoAdapterBuilt;
    defer androidAdapterFree(adapter);

    const events = androidAdapterOnHoverEvent(
        adapter,
        probedActivation,
        null,
        values_module.MOTION_ACTION_HOVER_ENTER,
        1,
        2,
    );
    try testing.expect(events == null);
}

test "a hover on an active adapter answers a releasable handle" {
    const gpa = allocation.allocator();
    var active = try ActiveAdapter.init(gpa);
    defer active.deinit();

    const events = androidAdapterOnHoverEvent(
        active.adapter,
        probedActivation,
        null,
        values_module.MOTION_ACTION_HOVER_EXIT,
        1,
        2,
    ) orelse return error.NoQueueBuilt;
    androidQueuedEventsRaise(events, null, null);
}

test "a node info request on an inactive adapter answers null for no tree" {
    // A `null` activation answer is ordinary and means "no tree", so this is not
    // a failure and the error slot stays clear.
    allocation.clearError();
    const adapter = androidAdapterNew() orelse return error.NoAdapterBuilt;
    defer androidAdapterFree(adapter);

    var probe: Probe = .{ .gpa = allocation.allocator() };
    const info = androidAdapterCreateAccessibilityNodeInfo(
        adapter,
        probedActivation,
        &probe,
        null,
        null,
        values_module.HOST_VIEW_ID,
    );
    try testing.expect(info == null);
    try testing.expectEqual(@as(usize, 1), probe.calls);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
    try testing.expect(adapter.last_error == null);
}

test "the activation handler is asked once and a null answer is not retried" {
    const adapter = androidAdapterNew() orelse return error.NoAdapterBuilt;
    defer androidAdapterFree(adapter);

    var probe: Probe = .{ .gpa = allocation.allocator() };
    _ = androidAdapterCreateAccessibilityNodeInfo(
        adapter,
        probedActivation,
        &probe,
        null,
        null,
        values_module.HOST_VIEW_ID,
    );
    _ = androidAdapterCreateAccessibilityNodeInfo(
        adapter,
        probedActivation,
        &probe,
        null,
        null,
        values_module.HOST_VIEW_ID,
    );
    _ = androidAdapterFindFocus(
        adapter,
        probedActivation,
        &probe,
        null,
        null,
        values_module.FOCUS_INPUT,
    );
    // Upstream calls `request_initial_tree` once per adapter.
    try testing.expectEqual(@as(usize, 1), probe.calls);
}

test "a find-focus on an active tree answers for the focused node" {
    const gpa = allocation.allocator();
    var active = try ActiveAdapter.init(gpa);
    defer active.deinit();

    // The fixture tree focuses its root, so the id has to exist before the fill
    // can ask for the node info. An unattached environment answers no node info,
    // which is the honest result with no VM behind it.
    const info = androidAdapterFindFocus(
        active.adapter,
        probedActivation,
        null,
        null,
        null,
        values_module.FOCUS_ACCESSIBILITY,
    );
    try testing.expect(info == null);
    try testing.expect(active.adapter.isActive());
}

test "a platform action over an unattached environment answers the simple form" {
    allocation.clearError();
    const action = androidPlatformActionFromJava(null, values_module.ACTION_FOCUS, null) orelse
        return error.NoActionBuilt;
    defer androidPlatformActionFree(action);
    try testing.expectEqual(@as(JInt, values_module.ACTION_FOCUS), action.decoded().simple);
    try testing.expectEqual(allocation.Tag.none, allocation.lastError());
}

test "every failure an adapter call can report is named" {
    // The walk is over the tags of `adapter.Error`, so the error set's own length
    // is the bound. A tag added without a decision behind it is the finding.
    const Errors = @typeInfo(adapter_module.Error).error_set.?;
    var seen_null_update = false;
    var seen_tree_rejected = false;
    var seen_queue_failure = false;
    for (Errors) |tag| {
        if (std.mem.eql(u8, tag.name, "NullTreeUpdate")) seen_null_update = true;
        if (std.mem.eql(u8, tag.name, "TreeRejected")) seen_tree_rejected = true;
        if (std.mem.eql(u8, tag.name, "TreeEventQueueFailed")) seen_queue_failure = true;
    }
    try testing.expect(seen_null_update);
    try testing.expect(seen_tree_rejected);
    try testing.expect(seen_queue_failure);
}

test "the five injecting natives agree with what methods.zig records" {
    // `injecting.zig` owns this table; the check lives here because this is the
    // file the C symbols are declared in.
    try testing.expectEqual(
        injecting_module.registered_native_count,
        methods_module.method_id_count - (methods_module.method_id_count - 5),
    );
    try testing.expectEqual(@as(usize, 5), registeredNativeCount());
}

/// How many of the 27 lookup rows are registered native methods. The walk is
/// over the 27 rows, so the bound is `methods_module.method_id_count`.
fn registeredNativeCount() usize {
    var total: usize = 0;
    for (methods_module.method_ids) |row| {
        if (row.kind == .registered_native) total += 1;
    }
    return total;
}
