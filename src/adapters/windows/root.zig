//! The Windows platform adapter: the module `src/capi/platform.zig` imports,
//! and the ten `windows*` entry points the C ABI declares behind `_WIN32`.
//!
//! **What this file is.** `adapters/windows/src/lib.rs` in the pinned upstream
//! tree, which is 22 lines and re-exports `Adapter`, `QueuedEvents` and
//! `SubclassingAdapter`, plus the `platform_windows` block of
//! `accesskit-c/src/lib.rs:3057-3144`, which is the ten C declarations this
//! file implements. `platform.zig` in `src/capi/` owns the symbol names, the
//! calling convention and the guard; this file owns the bodies.
//!
//! Providers use weak Context handles and guarded leases for each tree query.
//! Final COM Release frees provider state. Adapter close joins reads and callbacks.
//! Retained providers and queued events remain safe after adapter close.
//!
//! Injected tests exercise portable ownership and provider logic.
//! Native UI Automation execution still requires a real Windows host and UIA client.
//! Cross-compilation and injected tests do not establish native event delivery.
//!
//! **Loop bounds.** No loop in this file outside a test.
//!
//! **The allocator.** Every allocating entry point below uses
//! `capi/allocation.zig`, which is the allocator the C caller installed with
//! `accesskit_set_allocator`. It is the only allocator whose memory
//! `accesskit_string_free` and `accesskit_action_request_free` release, so a
//! block from any other allocator would be a mismatched free.

const std = @import("std");

const allocation = @import("../../capi/allocation.zig");
const boundary = @import("../../capi/boundary.zig");
const c_tree_update = @import("../../capi/tree_update.zig");

const adapter = @import("adapter.zig");
const bindings_mod = @import("bindings.zig");
const com_mod = @import("com.zig");
const error_codes_mod = @import("error_codes.zig");
const subclass = @import("subclass.zig");
pub const syscalls = @import("syscalls.zig");
const window_handle_mod = @import("window_handle.zig");
const schema = @import("../../schema/root.zig");
pub const util = @import("util.zig");
pub const context = @import("context.zig");
const node = @import("node.zig");
const text_mod = @import("text.zig");

/// Constructs real node and text providers with context-injected ownership.
/// This table contains no runtime or borrowed application userdata.
pub fn nativeFactory() context.ProviderFactory {
    return .{
        .create_node = node.create,
        .create_range = text_mod.create,
        .enqueue_properties = node.enqueuePropertyChanges,
    };
}

/// Native interface types, COM object ownership, and HRESULT conversion.
pub const WindowsBoundary = struct {
    pub const bindings = bindings_mod;
    pub const com = com_mod;
    pub const error_codes = error_codes_mod;
    pub const window_handle = window_handle_mod;
};

const ActionHandler = boundary.ActionHandler;
const ActivationHandler = boundary.ActivationHandler;
const COptLResult = boundary.COptLResult;
const Hwnd = boundary.Hwnd;
const LParam = boundary.LParam;
const TreeUpdateFactory = boundary.TreeUpdateFactory;
const WParam = boundary.WParam;

/// The adapter `accesskit_windows_adapter_new` returns, which `platform.zig`
/// writes in five signatures.
///
/// The caller releases the adapter once. Close waits for reads and callbacks.
/// Do not close from an action, activation, or update callback.
/// Existing providers and event handles retain safe weak control references.
pub const WindowsAdapter = adapter.WindowsAdapter;

/// Native update disposition. A committed notification failure is not a rejected update.
pub const UpdateOutcome = adapter.UpdateOutcome;
pub const BorrowedUpdateOptions = adapter.BorrowedUpdateOptions;

/// Callback-scope native request borrow and synchronous activation snapshot loan.
pub const ActionSink = adapter.ActionSink;
pub const ActivationConsumer = adapter.ActivationConsumer;
pub const BorrowedActivationHandler = adapter.BorrowedActivationHandler;
pub const ActivationSource = adapter.ActivationSource;

/// The adapter `accesskit_windows_subclassing_adapter_new` returns, which
/// `platform.zig` writes in four signatures.
///
/// The caller owns one adapter and releases it with
/// `accesskit_windows_subclassing_adapter_free`, exactly once. That call
/// restores the window procedure it replaced, drops the window property it
/// filed itself under, and releases the inner adapter and the block this one was
/// allocated in.
pub const WindowsSubclassingAdapter = subclass.WindowsSubclassingAdapter;

/// The events one adapter call produced, boxed so a C handle can name them.
///
/// `accesskit_windows_queued_events_raise` is the only way to release one, so
/// the type is opaque to a C caller and named here because
/// `platform.zig` writes it in a signature.
pub const WindowsQueuedEvents = adapter.QueuedEventsHolder;

// =============================================================================
// The ten declarations.
// =============================================================================

/// Raises once and frees the handle only after successful resource cleanup.
/// A cleanup error retains the handle for retry without duplicate delivery.
/// Providers and the raise seam remain valid after adapter close.
pub fn windowsQueuedEventsRaise(
    events: *adapter.QueuedEventsHolder,
) @import("queued_events.zig").RaiseReport {
    const report = events.raise();
    if (report.cleanup.first_error == null) allocation.release(events);
    return report;
}

/// Creates an adapter with explicit runtime, provider, value, and action authorities.
/// Borrowed authorities must outlive their weak clients. RuntimeRelease can own runtime cleanup.
/// Action userdata must remain valid until close completes.
pub fn windowsAdapterNew(options: WindowsAdapter.Options) ?*WindowsAdapter {
    return WindowsAdapter.create(allocation.allocator(), options) catch |err| {
        allocation.failWithError(err);
        return null;
    };
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// Passing `null` terminates the process.
pub fn windowsAdapterFree(target: *WindowsAdapter) void {
    target.deinit();
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// Returns the events the answer produced, or `null` when the adapter is not
/// active. The caller owns a non-null result and must pass it to
/// `windowsQueuedEventsRaise`.
pub fn windowsAdapterUpdateIfActive(
    target: *WindowsAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*adapter.QueuedEventsHolder {
    const produced = target.updateIfActive(update_factory, update_factory_userdata) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const events = produced orelse return null;
    return boxEvents(events);
}

/// Tells the adapter whether `hwnd` holds focus, and returns the events the
/// answer produced.
///
/// Returns `null` when the adapter is not active. The caller owns a non-null
/// result and must raise it.
pub fn windowsAdapterUpdateWindowFocusState(
    target: *WindowsAdapter,
    is_focused: bool,
) ?*adapter.QueuedEventsHolder {
    const produced = target.updateWindowFocusState(is_focused) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const events = produced orelse return null;
    return boxEvents(events);
}

/// Answers a `WM_GETOBJECT` message from a window procedure.
///
/// The window procedure passes `wparam` and `lparam` unchanged. `has_value` is
/// false when this adapter does not handle the message; the window procedure
/// then passes it to DefWindowProc. When true, value is the LRESULT to return.
/// Activation runs synchronously on the calling thread under the close barrier.
/// The C source transfers ownership of any returned tree update.
pub fn windowsAdapterHandleWmGetobject(
    target: *WindowsAdapter,
    wparam: WParam,
    lparam: LParam,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
) COptLResult {
    return target.handleWmGetobject(
        wparam,
        lparam,
        .{ .c = .{
            .callback = activation_handler,
            .userdata = activation_handler_userdata,
        } },
    ) catch |err| {
        allocation.failWithError(err);
        return std.mem.zeroes(COptLResult);
    };
}

/// Returns a text rendering of the adapter, or `null` when the text could not
/// be built.
///
/// Release the result with `accesskit_string_free`, once. The text borrows
/// nothing from the adapter once the call returns.
pub fn windowsAdapterDebug(target: *const WindowsAdapter) ?[*:0]u8 {
    const gpa = allocation.allocator();
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    writeDebug(gpa, &text, target) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const owned = text.toOwnedSliceSentinel(gpa, 0) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    return owned.ptr;
}

/// Returns a Windows subclassing adapter for `hwnd`, or `null` when the
/// allocation failed or the window could not be taken over.
///
/// Every handler pointer must stay valid until the adapter is released. The
/// caller owns the adapter and releases it with
/// `windowsSubclassingAdapterFree`. The three reasons a window cannot be taken
/// over are named on `WindowsSubclassingAdapter.create`.
pub fn windowsSubclassingAdapterNew(
    io: std.Io,
    factory: context.ProviderFactory,
    automation: *const util.AutomationApi,
    hwnd: Hwnd,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*WindowsSubclassingAdapter {
    const gpa = allocation.allocator();
    return WindowsSubclassingAdapter.create(
        gpa,
        .{
            .io = io,
            .platform = syscalls.platformForCurrentTarget(),
            .factory = factory,
            .automation = automation,
            .hwnd = hwnd,
            .is_window_focused = false,
            .action_sink = .{ .c = .{
                .callback = action_handler,
                .userdata = action_handler_userdata,
            } },
        },
        syscalls.windowApiForCurrentTarget(),
        .{ .c = .{
            .callback = activation_handler,
            .userdata = activation_handler_userdata,
        } },
    ) catch |err| {
        allocation.failWithError(err);
        return null;
    };
}

/// Releases the adapter and every tree it holds, exactly once.
///
/// Passing `null` terminates the process.
pub fn windowsSubclassingAdapterFree(target: *WindowsSubclassingAdapter) void {
    target.free();
}

/// Asks `update_factory` for a tree and hands it to the adapter.
///
/// Returns the events the answer produced, or `null` when the adapter is not
/// active. The caller owns a non-null result and must pass it to
/// `windowsQueuedEventsRaise`.
pub fn windowsSubclassingAdapterUpdateIfActive(
    target: *WindowsSubclassingAdapter,
    update_factory: TreeUpdateFactory,
    update_factory_userdata: ?*anyopaque,
) ?*adapter.QueuedEventsHolder {
    const produced = target.updateIfActive(update_factory, update_factory_userdata) catch |err| {
        allocation.failWithError(err);
        return null;
    };
    const events = produced orelse return null;
    return boxEvents(events);
}

// =============================================================================
// The helpers the ten declarations share.
// =============================================================================

/// Puts one queue into a block the C caller can name.
///
/// Box allocation failure consumes the unraised queue. It does not roll back
/// a tree update that already committed.
fn boxEvents(events: adapter.QueuedEventsHolder) ?*adapter.QueuedEventsHolder {
    var owned = events;
    const block = allocation.createBytes(@sizeOf(adapter.QueuedEventsHolder)) catch |err| {
        const cleanup = owned.deinit();
        if (cleanup.first_error) |failure| {
            std.debug.panic("unraised Windows event cleanup failed: {s}", .{@errorName(failure)});
        }
        allocation.failWithError(err);
        return null;
    };
    const boxed: *adapter.QueuedEventsHolder = @ptrCast(@alignCast(block[0..1]));
    boxed.* = owned;
    return boxed;
}

/// Writes the rendering `windowsAdapterDebug` returns.
///
/// **Errors.** `error.OutOfMemory` from the two appends.
fn writeDebug(
    gpa: std.mem.Allocator,
    text: *std.ArrayList(u8),
    target: *const WindowsAdapter,
) context.ProviderError!void {
    var guard = try target.context.enter();
    defer guard.deinit();
    if (target.state == .inactive) {
        try text.appendSlice(gpa, "Inactive { hwnd: ");
        try writePointer(gpa, text, target.hwnd);
        try text.appendSlice(gpa, ", is_window_focused: ");
        try text.appendSlice(gpa, if (target.is_window_focused) "true" else "false");
        try text.appendSlice(gpa, ", action_sink: \"ActionSink\" }");
    } else {
        try text.appendSlice(gpa, if (target.state == .placeholder) "Placeholder(" else "Active(");
        try text.appendSlice(gpa, "hwnd: ");
        try writePointer(gpa, text, target.hwnd);
        try text.appendSlice(gpa, ", node_count: ");
        const count = target.registry.nodeCount();
        try text.print(gpa, "{d}", .{count});
        try text.appendSlice(gpa, ")");
    }

    const report = target.last_raise_report;
    try text.print(
        gpa,
        " last_raise: {{ raised: {d}, refused: {d}, unavailable: {d} }}",
        .{ report.raised, report.refused, report.unavailable },
    );
    try text.print(
        gpa,
        " cleanup: {{ errors: {d}, first_error: {s} }}",
        .{
            report.cleanup.error_count,
            if (report.cleanup.first_error) |failure| @errorName(failure) else "none",
        },
    );
    if (target.last_error) |failure| {
        try text.print(gpa, " last_error: {s}", .{@errorName(failure)});
    } else {
        try text.appendSlice(gpa, " last_error: none");
    }
}

/// Writes one handle as a hexadecimal number, or the word `null`.
///
/// **Errors.** `error.OutOfMemory` from the append.
fn writePointer(
    gpa: std.mem.Allocator,
    text: *std.ArrayList(u8),
    handle: Hwnd,
) std.mem.Allocator.Error!void {
    const value = handle orelse return text.appendSlice(gpa, "null");
    try text.print(gpa, "0x{x}", .{@intFromPtr(value)});
}

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn freeDebugText(text: [*:0]u8) void {
    const public_free = @extern(*const fn ([*:0]u8) callconv(.c) void,
        .{ .name = "accesskit_string_free" });
    public_free(text);
}

/// A factory that answers one whole tree, so a test can activate an adapter.
fn wholeTreeFactory(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = userdata;
    // The handle captures the allocator that owns the native update.
    const gpa = allocation.allocator();
    var update: schema.TreeUpdate = .{};
    update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window)) catch {
        update.deinit(gpa);
        return null;
    };
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const boxed = gpa.create(c_tree_update.accesskit_tree_update) catch {
        update.deinit(gpa);
        return null;
    };
    boxed.* = .{ .gpa = gpa, .update = update, .info = null };
    return @ptrCast(boxed);
}

/// A factory that answers `null`, which is a contract violation upstream.
fn nullFactory(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = userdata;
    return null;
}

/// An activation handler that answers one whole tree.
fn activateWithTree(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    return wholeTreeFactory(userdata);
}

/// An activation handler that answers `null`, which means "no tree".
fn activateWithNothing(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = userdata;
    return null;
}

/// An action handler that releases the request it is handed.
fn releaseAction(request: *boundary.CActionRequest, userdata: ?*anyopaque) callconv(.c) void {
    _ = userdata;
    const c_gpa = allocation.allocator();
    schema.cActionRequestDeinit(c_gpa, request);
    c_gpa.destroy(request);
}

const FactoryState = struct {
    gpa: std.mem.Allocator,
    /// How many trees the factory handed out, so a test can tell one call from
    /// two.
    handed_out: usize = 0,
};

const RootTestFixture = struct {
    runtime: std.Io.Threaded,
    abi: util.AutomationTestAbi,
    api: util.AutomationApi,

    fn init(self: *RootTestFixture) void {
        self.runtime = std.Io.Threaded.init(testing.allocator, .{});
        self.abi = util.AutomationTestAbi.init(testing.allocator);
        self.api = self.abi.api();
    }

    fn deinit(self: *RootTestFixture) void {
        self.runtime.deinit();
    }

    fn new(self: *RootTestFixture, hwnd: Hwnd, focused: bool) ?*WindowsAdapter {
        return windowsAdapterNew(.{
            .io = self.runtime.io(),
            .platform = adapter.testPlatform(),
            .factory = adapter.testProviderFactory(),
            .automation = &self.api,
            .hwnd = hwnd,
            .is_window_focused = focused,
            .action_sink = .{ .c = .{ .callback = &releaseAction, .userdata = null } },
        });
    }
};

const RootRejectedUpdateFactory = struct {
    const Kind = enum { valid, invalid_focus, orphan_child };

    kind: Kind = .valid,
    label: []const u8,
    calls: usize = 0,

    fn make(userdata: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
        const input: *@This() = @ptrCast(@alignCast(userdata orelse return null));
        input.calls += 1;
        const result = wholeTreeFactory(null) orelse return null;
        const boxed: *c_tree_update.accesskit_tree_update = @ptrCast(@alignCast(result));
        const properties = &boxed.update.nodes.items[0].node.properties;
        schema.strings.setLabel(properties, input.label) catch {
            boxed.update.deinit(boxed.gpa);
            boxed.gpa.destroy(boxed);
            return null;
        };
        switch (input.kind) {
            .valid => {},
            .invalid_focus => boxed.update.focus = .{ .value = 999 },
            .orphan_child => schema.ids_props.setChildren(properties, &.{.{ .value = 999 }}) catch {
                boxed.update.deinit(boxed.gpa);
                boxed.gpa.destroy(boxed);
                return null;
            },
        }
        return result;
    }
};


test "the three adapter types the C ABI names are the ones this module exposes" {
    // `platform.zig` writes `windows.WindowsAdapter`, `windows.WindowsQueuedEvents`
    // and `windows.WindowsSubclassingAdapter` in ten signatures. The three
    // names here are the ones it resolves, and the sizes below are what a C
    // handle to each would carry.
    try testing.expect(@sizeOf(WindowsAdapter) > 0);
    try testing.expect(@sizeOf(adapter.QueuedEventsHolder) > 0);
    try testing.expect(@sizeOf(WindowsSubclassingAdapter) > 0);
    try testing.expectEqual(@sizeOf(adapter.QueuedEventsHolder), @sizeOf(WindowsQueuedEvents));
    try testing.expectEqual(
        @sizeOf(subclass.WindowsSubclassingAdapter),
        @sizeOf(WindowsSubclassingAdapter),
    );
    try testing.expectEqual(@alignOf(adapter.QueuedEventsHolder), @alignOf(WindowsQueuedEvents));
}

test "a new adapter is inactive and a first update answers null" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    const built = foundation.new(@ptrFromInt(0x1000), false);
    const target = built orelse return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    try testing.expect(!target.isActive());
    const events = windowsAdapterUpdateIfActive(target, &wholeTreeFactory, &state);
    // Upstream answers `None` in the inactive state at `adapter.rs:468`.
    try testing.expectEqual(@as(?*adapter.QueuedEventsHolder, null), events);
}

test "an update on an inactive adapter leaves it inactive" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    const target = foundation.new(@ptrFromInt(0x1100), true) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const events = windowsAdapterUpdateIfActive(target, &wholeTreeFactory, &state);
    try testing.expectEqual(@as(?*adapter.QueuedEventsHolder, null), events);
    try testing.expectEqual(@as(usize, 0), state.handed_out);
    try testing.expect(!target.isActive());
}

test "a factory that answers null is reported and the adapter stays inactive" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(@ptrFromInt(0x1200), false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    // The adapter is inactive, so the factory is never called and the contract
    // violation cannot fire here.
    try testing.expectEqual(
        @as(?*adapter.QueuedEventsHolder, null),
        windowsAdapterUpdateIfActive(target, &nullFactory, null),
    );
}

test "the focus state is recorded while the adapter is inactive" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(@ptrFromInt(0x1300), false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    try testing.expectEqual(
        @as(?*adapter.QueuedEventsHolder, null),
        windowsAdapterUpdateWindowFocusState(target, true),
    );
    // The flag is the only thing the inactive arm records, at `adapter.rs:502-506`.
    try testing.expect(target.is_window_focused);
}

test "a WM_GETOBJECT for the root builds the placeholder and answers a value" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(@ptrFromInt(0x1400), false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    // The activation handler answers `null`, which means "no tree".
    const answer = windowsAdapterHandleWmGetobject(
        target,
        0,
        syscalls.uia_root_object_id,
        &activateWithNothing,
        null,
    );
    try testing.expect(answer.has_value);
    try testing.expect(target.isActive());
    try testing.expect(target.isPlaceholder());
}

test "a WM_GETOBJECT for another object identifier answers false" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(@ptrFromInt(0x1500), false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    // `adapter.rs:544-547` passes every negative identifier that is neither
    // `UiaRootObjectId` nor `OBJID_CLIENT` to `DefWindowProc`.
    const answer = windowsAdapterHandleWmGetobject(
        target,
        0,
        -5,
        &activateWithNothing,
        null,
    );
    try testing.expect(!answer.has_value);
    try testing.expectEqual(@as(isize, 0), answer.value);
    // The adapter is still inactive: a refused message never activates.
    try testing.expect(!target.isActive());
}

test "a WM_GETOBJECT with a tree from the activation handler answers the root" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    const target = foundation.new(@ptrFromInt(0x1600), false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const answer = windowsAdapterHandleWmGetobject(
        target,
        0,
        syscalls.objid_client,
        &activateWithTree,
        &state,
    );
    try testing.expect(answer.has_value);
    try testing.expect(target.isActive());
    try testing.expect(!target.isPlaceholder());
    try testing.expectEqual(@as(usize, 1), target.registry.nodeCount());
}

test "an update after activation reaches the active arm and answers events" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    // The window holds focus, so the tree has a focus to announce and the
    // placeholder arm queues the one focus event of `adapter.rs:470-480`.
    const target = foundation.new(@ptrFromInt(0x1700), true) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    _ = windowsAdapterHandleWmGetobject(
        target,
        0,
        syscalls.objid_client,
        &activateWithNothing,
        null,
    );

    // The placeholder arm builds the real tree from the factory and queues the
    // focus event, which is `adapter.rs:470-480`.
    const events = windowsAdapterUpdateIfActive(target, &wholeTreeFactory, &state) orelse
        return error.NoEvents;
    try testing.expect(!target.isPlaceholder());
    try testing.expectEqual(@as(usize, 1), events.len());

    // Raising releases the handle, and the refusal is recorded rather than lost.
    _ = windowsQueuedEventsRaise(events);
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.total());
}

test "the debug text names the state and the last raise" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(@ptrFromInt(0x1800), true) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    defer freeDebugText(text);
    try testing.expect(std.mem.startsWith(u8, std.mem.span(text), "Inactive { hwnd: 0x1800"));
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "is_window_focused: true") != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "last_raise:") != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "last_error: none") != null);
}

test "the debug text of a null handle says null rather than a number" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(null, false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    defer freeDebugText(text);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "hwnd: null") != null);
}

test "Windows debug C string is owned by the configured public string destructor" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    var pair: TrackedPair = .{ .gpa = testing.allocator };
    defer pair.lengths.deinit(pair.gpa);
    defer allocation.installAllocator(null, null, null);
    allocation.installAllocator(&TrackedPair.allocThunk, &TrackedPair.freeThunk, &pair);

    const target = foundation.new(@ptrFromInt(0x1800), true) orelse
        return error.AdapterNotBuilt;
    var target_live = true;
    defer if (target_live) windowsAdapterFree(target);
    const live_before = pair.liveBlocks();
    const rendered = windowsAdapterDebug(target) orelse return error.NoDebugText;
    // Assertion failures must still release a live raw string exactly once.
    defer if (pair.lengths.contains(@intFromPtr(rendered))) freeDebugText(rendered);
    const output_base = pair.last_allocation orelse return error.OutputWasNotAllocated;
    const saved = try testing.allocator.dupe(u8, std.mem.span(rendered));
    defer testing.allocator.free(saved);
    try testing.expectEqual(live_before + 1, pair.liveBlocks());
    try testing.expectEqual(output_base, @intFromPtr(rendered));

    windowsAdapterFree(target);
    target_live = false;
    try testing.expectEqual(@as(usize, 1), pair.liveBlocks());
    try testing.expectEqualStrings(saved, std.mem.span(rendered));

    const frees_before = pair.recognized_frees;
    freeDebugText(rendered);
    try testing.expectEqual(@as(usize, 0), pair.unrecognized_frees);
    try testing.expectEqual(@as(?usize, output_base), pair.last_free);
    try testing.expectEqual(frees_before + 1, pair.recognized_frees);
    try testing.expect(!pair.lengths.contains(output_base));
    try testing.expectEqual(@as(usize, 0), pair.liveBlocks());
}


test "a subclassing adapter over a window with no Win32 is refused" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    // The seam refuses, so the three C declarations answer `null` and no window
    // was touched.
    try testing.expectEqual(
        @as(?*WindowsSubclassingAdapter, null),
        windowsSubclassingAdapterNew(
            foundation.runtime.io(),
            adapter.testProviderFactory(),
            &foundation.api,
            @ptrFromInt(0x1900),
            &activateWithNothing,
            null,
            &releaseAction,
            null,
        ),
    );
}

test "an update on a refused subclassing adapter never runs" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    // Nothing was built, so there is nothing to call. This is the pair the
    // header promises: `new` answers `null` or a handle, never a handle that
    // the other two calls cannot use.
    const built = windowsSubclassingAdapterNew(
        foundation.runtime.io(),
        adapter.testProviderFactory(),
        &foundation.api,
        @ptrFromInt(0x1A00),
        &activateWithNothing,
        null,
        &releaseAction,
        null,
    );
    if (built) |holder| {
        defer windowsSubclassingAdapterFree(holder);
        return error.AdapterWasBuilt;
    }
}

test "an action request reaches the installed handler and the handler owns it" {
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(@ptrFromInt(0x1B00), false) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    // The handler releases the request with the same allocator the adapter used,
    // so this is one allocation and one release.
    target.dispatchAction(.{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 7 },
        .data = null,
    }) catch return error.ActionDispatchFailed;
}

/// The declared allocator one test installs, over `std.testing.allocator`.
///
/// `accesskit_set_allocator` hands the library a free half that receives a
/// pointer and nothing else, so this records the length the alloc half was
/// asked for under the address it returned and takes it back on the free half.
/// That is what lets the ten C entry points run under the per-test leak check.
const TrackedPair = struct {
    /// The allocator every block of the pair comes from.
    gpa: std.mem.Allocator,

    /// The length of every live block, keyed by its allocation base address.
    /// The free half removes the record when it releases a block.
    lengths: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    last_allocation: ?usize = null,
    last_free: ?usize = null,
    recognized_frees: usize = 0,
    unrecognized_frees: usize = 0,

    /// How many blocks the pair has handed out and not taken back.
    fn liveBlocks(self: *const TrackedPair) usize {
        return self.lengths.count();
    }

    fn allocThunk(size: usize, userdata: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *TrackedPair = @ptrCast(@alignCast(userdata orelse return null));
        const bytes = self.gpa.alloc(u8, size) catch return null;
        self.lengths.put(self.gpa, @intFromPtr(bytes.ptr), size) catch {
            self.gpa.free(bytes);
            return null;
        };
        self.last_allocation = @intFromPtr(bytes.ptr);
        return bytes.ptr;
    }

    fn freeThunk(ptr: ?*anyopaque, userdata: ?*anyopaque) callconv(.c) void {
        const self: *TrackedPair = @ptrCast(@alignCast(userdata orelse return));
        const any = ptr orelse return;
        const address = @intFromPtr(any);
        self.last_free = address;
        const length = self.lengths.fetchRemove(address) orelse {
            self.unrecognized_frees += 1;
            return;
        };
        self.recognized_frees += 1;
        self.gpa.free(@as([*]u8, @ptrCast(any))[0..length.value]);
    }
};

test "the whole lifecycle runs under the testing allocator and leaks nothing" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    // Every block the C ABI hands out goes through `capi/allocation.zig`,
    // which uses the C allocator until a test installs a pair. Installing this
    // one puts the ten entry points under the per-test leak check, so a tree,
    // a provider, an events box or a debug string this directory loses is
    // reported as a leak rather than passing quietly. The ten entry points are
    // exercised here rather than one at a time because the lifecycle is where
    // an ownership mistake shows: a box that is raised twice, a tree that is
    // released twice and an events box that outlives its adapter all need more
    // than one call to appear.
    var pair: TrackedPair = .{ .gpa = testing.allocator };
    defer pair.lengths.deinit(pair.gpa);
    defer allocation.installAllocator(null, null, null);
    allocation.installAllocator(&TrackedPair.allocThunk, &TrackedPair.freeThunk, &pair);

    const target = foundation.new(@ptrFromInt(0x1C00), true) orelse
        return error.AdapterNotBuilt;

    // The inactive arm of `accesskit_windows_adapter_update_if_active` builds
    // nothing at all, so nothing is handed back and the adapter stays inactive.
    try testing.expect(windowsAdapterUpdateIfActive(target, &wholeTreeFactory, null) == null);
    try testing.expect(!target.isActive());

    // The activation handler answers no tree, so the placeholder is built, and
    // the first update through the C call replaces it with the real tree.
    const answered = windowsAdapterHandleWmGetobject(
        target,
        0,
        syscalls.uia_root_object_id,
        &activateWithNothing,
        null,
    );
    try testing.expect(answered.has_value);
    try testing.expect(target.isPlaceholder());

    const events = windowsAdapterUpdateIfActive(target, &wholeTreeFactory, null) orelse
        return error.NoEvents;
    try testing.expect(!target.isPlaceholder());
    _ = windowsQueuedEventsRaise(events);
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.total());

    const focused = windowsAdapterUpdateWindowFocusState(target, false) orelse
        return error.NoEvents;
    _ = windowsQueuedEventsRaise(focused);

    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    freeDebugText(text);

    target.dispatchAction(.{
        .action = .click,
        .target_tree = schema.tree_id_root,
        .target_node = .{ .value = 7 },
        .data = null,
    }) catch return error.ActionDispatchFailed;

    windowsAdapterFree(target);

    // The pair holds nothing, so every block the library took came back through
    // the pair and not through a free it did not own.
    try testing.expectEqual(@as(usize, 0), pair.liveBlocks());
}

test "the COM boundary and provider namespaces are reached and analysed" {
    // Zig analyses lazily. Force every native foundation namespace into the
    // test graph, including providers reached only through injected factories.
    testing.refAllDecls(WindowsBoundary);
    testing.refAllDecls(WindowsBoundary.com);
    testing.refAllDecls(WindowsBoundary.error_codes);
    testing.refAllDecls(WindowsBoundary.window_handle);
    testing.refAllDecls(WindowsBoundary.bindings);
    testing.refAllDecls(util);
    testing.refAllDecls(context);
    testing.refAllDecls(syscalls);
    testing.refAllDecls(node);
    testing.refAllDecls(text_mod);
}

test "failed property cleanup retains the C event handle and reports its exact error" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    const target = foundation.new(null, false) orelse return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);
    var holder = adapter.QueuedEventsHolder.init(target);
    var holder_live = true;
    defer if (holder_live) {
        foundation.abi.clear_failure = 0;
        const cleanup = holder.deinit();
        if (cleanup.first_error != null) @panic("unexpected fresh event cleanup failure");
    };
    var guard = try target.context.enter();
    defer guard.deinit();
    const slot = try target.registry.placeholderSlot(target.platform);
    const property = try holder.queue.beginProperty(slot, .name);
    property.old = try util.VariantOwner.fromUtf8(&foundation.api, "old");
    property.new = try util.VariantOwner.fromUtf8(&foundation.api, "new");
    guard.deinit();
    holder_live = false;
    const events = boxEvents(holder) orelse return error.EventsNotBoxed;
    var box_live = true;
    defer if (box_live) {
        foundation.abi.clear_failure = 0;
        const cleanup = events.deinit();
        if (cleanup.first_error != null) @panic("unexpected event cleanup retry failure");
        allocation.release(events);
    };
    foundation.abi.clear_failure = 0x8002000d;
    const failed = windowsQueuedEventsRaise(events);
    try testing.expectEqual(@as(?util.AutomationError, error.ArrayLocked), failed.cleanup.first_error);
    try testing.expectEqual(@as(usize, 2), failed.cleanup.error_count);
    try testing.expectEqual(@as(u32, 2), foundation.abi.live_strings);
    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    defer freeDebugText(text);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "ArrayLocked") != null);
    foundation.abi.clear_failure = 0;
    const retried = windowsQueuedEventsRaise(events);
    if (retried.cleanup.first_error == null) box_live = false;
    try testing.expectEqual(@as(?util.AutomationError, null), retried.cleanup.first_error);
    try testing.expectEqual(@as(usize, 0), retried.total());
    try testing.expectEqual(@as(u32, 0), foundation.abi.live_strings);
    try testing.expectEqual(@as(u32, 2), foundation.abi.string_frees);
}

test "C Windows rejected updates preserve exact diagnostics and the committed named tree" {
    if (comptime !bindings_mod.winapi_resolves) return error.SkipZigTest;
    var foundation: RootTestFixture = undefined;
    foundation.init();
    defer foundation.deinit();
    var pair: TrackedPair = .{ .gpa = testing.allocator };
    defer pair.lengths.deinit(pair.gpa);
    defer allocation.installAllocator(null, null, null);
    allocation.installAllocator(&TrackedPair.allocThunk, &TrackedPair.freeThunk, &pair);

    const target = foundation.new(@ptrFromInt(0x2100), false) orelse
        return error.AdapterNotBuilt;
    var target_live = true;
    defer if (target_live) windowsAdapterFree(target);
    var initial: RootRejectedUpdateFactory = .{ .label = "committed root" };
    const activated = windowsAdapterHandleWmGetobject(target, 0, syscalls.uia_root_object_id,
        &RootRejectedUpdateFactory.make, &initial);
    try testing.expect(activated.has_value);
    try testing.expect(target.isActive());
    try testing.expect(!target.isPlaceholder());
    try testing.expectEqual(@as(usize, 1), initial.calls);
    const committed_id = committed: {
        var guard = try target.context.enter();
        defer guard.deinit();
        const state = guard.owner.tree().?.stateOf();
        try testing.expectEqualStrings("committed root",
            schema.strings.label(&state.root().data().properties) orelse
                return error.CommittedRootHasNoName);
        break :committed state.rootId();
    };

    const cases = [_]struct {
        kind: RootRejectedUpdateFactory.Kind,
        exact_name: []const u8,
    }{
        .{ .kind = .invalid_focus, .exact_name = "FocusNotInTree" },
        .{ .kind = .orphan_child, .exact_name = "OrphanChild" },
    };
    for (cases) |case| {
        var rejected: RootRejectedUpdateFactory = .{
            .kind = case.kind,
            .label = "must not replace committed root",
        };
        allocation.clearError();
        try testing.expect(windowsAdapterUpdateIfActive(target,
            &RootRejectedUpdateFactory.make, &rejected) == null);
        try testing.expectEqual(@as(usize, 1), rejected.calls);
        try testing.expectEqual(allocation.Tag.operation_failed, allocation.lastError());
        try testing.expectEqualStrings(case.exact_name,
            std.mem.span(allocation.lastErrorName() orelse return error.ExactFailureNameMissing));

        var guard = try target.context.enter();
        defer guard.deinit();
        const state = guard.owner.tree().?.stateOf();
        try testing.expectEqual(committed_id, state.rootId());
        try testing.expectEqualStrings("committed root",
            schema.strings.label(&state.root().data().properties) orelse
                return error.CommittedRootHasNoName);
    }
    windowsAdapterFree(target);
    target_live = false;
    try testing.expectEqual(@as(usize, 0), pair.liveBlocks());
    try testing.expectEqual(@as(usize, 0), pair.unrecognized_frees);
}
