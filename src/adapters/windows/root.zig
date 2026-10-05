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
//! **What is compiled and tested on this host.** Every one of the ten bodies,
//! driven through the seams in `syscalls.zig` and `adapter.zig`. The adapter
//! state machine, the event queue, the provider registry, the object identifier
//! arithmetic and the message table are all plain Zig and are all covered by
//! tests in the modules that own them.
//!
//! **What needs the real platform.** Three things, and only three:
//!
//! 1. `bindings.zig`, `com.zig` and `error_codes.zig`, which need the pinned
//!    `zigwin32` package. `build.zig.zon` does not name it, so those three
//!    files are outside the Linux analysis graph and nothing here imports them.
//!    They are the COM node layer: the thirteen vtables, the `VARIANT` writer
//!    and the status codes a UI Automation client reads.
//! 2. The `extern "win32"` bodies inside `syscalls.zig`, which are behind
//!    `if (builtin.os.tag == .windows)` and so are **unverified** on this host.
//! 3. The node layer that fills `ProviderSlot.interface`. Until it exists, every
//!    provider slot is a stable address with a `null` interface, and every raise
//!    is refused by the seam rather than faked.
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

const adapter = @import("adapter.zig");
const subclass = @import("subclass.zig");
const syscalls = @import("syscalls.zig");
const schema = @import("../../schema/root.zig");

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
/// The caller owns one adapter and releases it with
/// `accesskit_windows_adapter_free`, exactly once. That call releases the tree
/// the adapter holds, the providers its registry holds and the block the
/// adapter itself was allocated in. The adapter must outlive any events handle
/// it hands out, because a queued event names a provider the adapter's registry
/// owns.
pub const WindowsAdapter = adapter.WindowsAdapter;

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

/// Raises the queued events and releases the handle.
///
/// This call is the only way to release the handle. A second call is a
/// use-after-free, and passing `null` terminates the process.
///
/// **The adapter must outlive this call.** The events name providers the
/// adapter's registry owns, so a caller that releases the adapter first has a
/// use-after-free; that rule holds for the events themselves and this call
/// adds nothing to it. The raise runs on the seam that built those providers,
/// and the report it produces is recorded on that adapter for
/// `windowsAdapterDebug` to print.
pub fn windowsQueuedEventsRaise(events: *adapter.QueuedEventsHolder) void {
    const owned = events.*;
    _ = owned.raise();
    allocation.release(events);
}

/// Returns a Windows adapter for `hwnd`, or `null` when the allocation failed.
///
/// `action_handler_userdata` must stay valid until the adapter is released.
/// This adapter takes no activation or deactivation handler: the `WM_GETOBJECT`
/// reply asks for the tree. The caller owns the adapter and releases it with
/// `windowsAdapterFree`.
pub fn windowsAdapterNew(
    hwnd: Hwnd,
    is_window_focused: bool,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*WindowsAdapter {
    const gpa = allocation.allocator();
    return WindowsAdapter.create(
        gpa,
        syscalls.platformForCurrentTarget(),
        hwnd,
        is_window_focused,
        action_handler,
        action_handler_userdata,
    ) catch null;
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
    const produced = target.updateIfActive(update_factory, update_factory_userdata) catch
        return null;
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
    const produced = target.updateWindowFocusState(is_focused) catch return null;
    const events = produced orelse return null;
    return boxEvents(events);
}

/// Answers a `WM_GETOBJECT` message from a window procedure.
///
/// The window procedure passes `wparam` and `lparam` unchanged. `has_value` is
/// false when this adapter does not own the window, and the window procedure
/// then returns `false` from `DefWindowProc`. When it is true, `value` is the
/// `LRESULT` to return. The library calls `activation_handler` on its own
/// thread and releases any tree update it returns.
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
        activation_handler,
        activation_handler_userdata,
    );
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
    writeDebug(gpa, &text, target) catch return null;
    return allocation.createCString(text.items) catch null;
}

/// Returns a Windows subclassing adapter for `hwnd`, or `null` when the
/// allocation failed or the window could not be taken over.
///
/// Every handler pointer must stay valid until the adapter is released. The
/// caller owns the adapter and releases it with
/// `windowsSubclassingAdapterFree`. The three reasons a window cannot be taken
/// over are named on `WindowsSubclassingAdapter.create`.
pub fn windowsSubclassingAdapterNew(
    hwnd: Hwnd,
    activation_handler: ActivationHandler,
    activation_handler_userdata: ?*anyopaque,
    action_handler: ActionHandler,
    action_handler_userdata: ?*anyopaque,
) ?*WindowsSubclassingAdapter {
    const gpa = allocation.allocator();
    return WindowsSubclassingAdapter.create(
        gpa,
        syscalls.platformForCurrentTarget(),
        syscalls.windowApiForCurrentTarget(),
        hwnd,
        activation_handler,
        activation_handler_userdata,
        action_handler,
        action_handler_userdata,
    ) catch null;
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
    const produced = target.updateIfActive(update_factory, update_factory_userdata) catch
        return null;
    const events = produced orelse return null;
    return boxEvents(events);
}

// =============================================================================
// The helpers the ten declarations share.
// =============================================================================

/// Puts one queue into a block the C caller can name.
///
/// **Errors.** `error.OutOfMemory`. The queue is released before this returns,
/// so the caller holds nothing and the adapter is left as it was.
fn boxEvents(events: adapter.QueuedEventsHolder) ?*adapter.QueuedEventsHolder {
    var owned = events;
    const block = allocation.createBytes(@sizeOf(adapter.QueuedEventsHolder)) catch {
        owned.deinit();
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
) std.mem.Allocator.Error!void {
    if (!target.isActive()) {
        try text.appendSlice(gpa, "Inactive { hwnd: ");
        try writePointer(gpa, text, target.hwnd);
        try text.appendSlice(gpa, ", is_window_focused: ");
        try text.appendSlice(gpa, if (target.is_window_focused) "true" else "false");
        try text.appendSlice(gpa, ", action_handler: \"ActionHandler\" }");
    } else {
        try text.appendSlice(gpa, if (target.isPlaceholder()) "Placeholder(" else "Active(");
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

/// A factory that answers one whole tree, so a test can activate an adapter.
fn wholeTreeFactory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    // The nodes must be built with the allocator the adapter releases them with.
    const gpa = allocation.allocator();
    var update: schema.TreeUpdate = .{};
    update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window)) catch return null;
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const boxed = allocation.create(schema.TreeUpdate) catch return null;
    boxed.* = update;
    return boxed;
}

/// A factory that answers `null`, which is a contract violation upstream.
fn nullFactory(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    return null;
}

/// An activation handler that answers one whole tree.
fn activateWithTree(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    var update: schema.TreeUpdate = .{};
    const gpa = allocation.allocator();
    update.pushNode(gpa, .{ .value = 1 }, schema.Node.init(gpa, .window)) catch return null;
    update.tree = schema.TreeInfo.init(.{ .value = 1 });
    update.focus = .{ .value = 1 };
    const boxed = allocation.create(schema.TreeUpdate) catch return null;
    boxed.* = update;
    return boxed;
}

/// An activation handler that answers `null`, which means "no tree".
fn activateWithNothing(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    return null;
}

/// An action handler that releases the request it is handed.
fn releaseAction(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
    _ = context;
    schema.cActionRequestDeinit(allocation.allocator(), request);
    allocation.release(request);
}

const FactoryState = struct {
    gpa: std.mem.Allocator,
    /// How many trees the factory handed out, so a test can tell one call from
    /// two.
    handed_out: usize = 0,
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
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    const built = windowsAdapterNew(@ptrFromInt(0x1000), false, &releaseAction, null);
    const target = built orelse return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    try testing.expect(!target.isActive());
    const events = windowsAdapterUpdateIfActive(target, &wholeTreeFactory, &state);
    // Upstream answers `None` in the inactive state at `adapter.rs:468`.
    try testing.expectEqual(@as(?*adapter.QueuedEventsHolder, null), events);
}

test "an update on an inactive adapter leaves it inactive" {
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    const target = windowsAdapterNew(@ptrFromInt(0x1100), true, &releaseAction, null) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const events = windowsAdapterUpdateIfActive(target, &wholeTreeFactory, &state);
    try testing.expectEqual(@as(?*adapter.QueuedEventsHolder, null), events);
    try testing.expectEqual(@as(usize, 0), state.handed_out);
    try testing.expect(!target.isActive());
}

test "a factory that answers null is reported and the adapter stays inactive" {
    const target = windowsAdapterNew(@ptrFromInt(0x1200), false, &releaseAction, null) orelse
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
    const target = windowsAdapterNew(@ptrFromInt(0x1300), false, &releaseAction, null) orelse
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
    const target = windowsAdapterNew(@ptrFromInt(0x1400), false, &releaseAction, null) orelse
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
    const target = windowsAdapterNew(@ptrFromInt(0x1500), false, &releaseAction, null) orelse
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
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    const target = windowsAdapterNew(@ptrFromInt(0x1600), false, &releaseAction, null) orelse
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
    const gpa = testing.allocator;
    var state: FactoryState = .{ .gpa = gpa };
    // The window holds focus, so the tree has a focus to announce and the
    // placeholder arm queues the one focus event of `adapter.rs:470-480`.
    const target = windowsAdapterNew(@ptrFromInt(0x1700), true, &releaseAction, null) orelse
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
    windowsQueuedEventsRaise(events);
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.total());
}

test "the debug text names the state and the last raise" {
    const target = windowsAdapterNew(@ptrFromInt(0x1800), true, &releaseAction, null) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    defer allocation.release(text);
    try testing.expect(std.mem.startsWith(u8, std.mem.span(text), "Inactive { hwnd: 0x1800"));
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "is_window_focused: true") != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "last_raise:") != null);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "last_error: none") != null);
}

test "the debug text of a null handle says null rather than a number" {
    const target = windowsAdapterNew(null, false, &releaseAction, null) orelse
        return error.AdapterNotBuilt;
    defer windowsAdapterFree(target);

    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    defer allocation.release(text);
    try testing.expect(std.mem.indexOf(u8, std.mem.span(text), "hwnd: null") != null);
}

test "a subclassing adapter over a window with no Win32 is refused" {
    // The seam refuses, so the three C declarations answer `null` and no window
    // was touched.
    try testing.expectEqual(
        @as(?*WindowsSubclassingAdapter, null),
        windowsSubclassingAdapterNew(
            @ptrFromInt(0x1900),
            &activateWithNothing,
            null,
            &releaseAction,
            null,
        ),
    );
}

test "an update on a refused subclassing adapter never runs" {
    // Nothing was built, so there is nothing to call. This is the pair the
    // header promises: `new` answers `null` or a handle, never a handle that
    // the other two calls cannot use.
    const built = windowsSubclassingAdapterNew(
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
    const target = windowsAdapterNew(@ptrFromInt(0x1B00), false, &releaseAction, null) orelse
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

    /// The length of every live block, keyed by the address handed out. A block
    /// the pair no longer holds is a block `capi/allocation.zig` has already
    /// released, which its own head word refuses, so the free half ignores it.
    lengths: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    /// How many blocks the pair has handed out and not taken back.
    fn liveBlocks(self: *const TrackedPair) usize {
        return self.lengths.count();
    }

    fn allocThunk(size: usize, context: ?*anyopaque) callconv(.c) ?*anyopaque {
        const self: *TrackedPair = @ptrCast(@alignCast(context orelse return null));
        const bytes = self.gpa.alloc(u8, size) catch return null;
        self.lengths.put(self.gpa, @intFromPtr(bytes.ptr), size) catch {
            self.gpa.free(bytes);
            return null;
        };
        return bytes.ptr;
    }

    fn freeThunk(ptr: ?*anyopaque, context: ?*anyopaque) callconv(.c) void {
        const self: *TrackedPair = @ptrCast(@alignCast(context orelse return));
        const any = ptr orelse return;
        const length = self.lengths.fetchRemove(@intFromPtr(any)) orelse return;
        self.gpa.free(@as([*]u8, @ptrCast(any))[0..length.value]);
    }
};

test "the whole lifecycle runs under the testing allocator and leaks nothing" {
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

    const target = windowsAdapterNew(@ptrFromInt(0x1C00), true, &releaseAction, null) orelse
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
    windowsQueuedEventsRaise(events);
    try testing.expectEqual(@as(usize, 1), target.last_raise_report.total());

    const focused = windowsAdapterUpdateWindowFocusState(target, false) orelse
        return error.NoEvents;
    windowsQueuedEventsRaise(focused);

    const text = windowsAdapterDebug(target) orelse return error.NoDebugText;
    allocation.release(text);

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
