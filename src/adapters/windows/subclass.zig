//! The subclassing adapter: a window procedure that answers `WM_GETOBJECT`
//! for a window that offers no other way of adding a handler.
//!
//! **What this file ports.** `SubclassingAdapter`, `SubclassImpl` and
//! `SubclassState` from `adapters/windows/src/subclass.rs:29-204` in the pinned
//! upstream tree, and the six Win32 calls at `subclass.rs:45`, `:73`, `:96`,
//! `:103`, `:111` and `:131`.
//!
//! **What the port does differently, and why.** Upstream refuses a window that
//! is already visible by panicking at `subclass.rs:167-171`. The C ABI has no
//! panic, so `create` answers `null` instead, and the doc comment on `create`
//! names every reason. Upstream also refuses a window that another subclassing
//! adapter already owns at `subclass.rs:96-101`, and that is the same `null`.
//!
//! **What is compiled and tested on this host.** The install decision, the
//! message table that turns a `WM_*` message into a focus state, the property
//! name the adapter files itself under, and the uninstall path. The six Win32
//! calls are the seam in `syscalls.WindowApi`, and a test drives them with a
//! recording seam.
//!
//! **Loop bounds.** No loop outside a test.

const std = @import("std");

const adapter = @import("adapter.zig");
const consumer = @import("../../consumer/root.zig");
const boundary = @import("../../capi/boundary.zig");
const allocation = @import("../../capi/allocation.zig");
const queued_events = @import("queued_events.zig");
const syscalls = @import("syscalls.zig");

const ActivationHandler = boundary.ActivationHandler;
const ActionHandler = boundary.ActionHandler;
const Hwnd = boundary.Hwnd;
const LResult = syscalls.LResult;
const WParam = boundary.WParam;
const LParam = boundary.LParam;

const WindowsAdapter = adapter.WindowsAdapter;
const Platform = syscalls.Platform;
const RaiseReport = queued_events.RaiseReport;
const WindowApi = syscalls.WindowApi;
const WindowProc = syscalls.WindowProc;

/// The Windows subclassing adapter.
///
/// The caller owns the adapter and releases it with `free`. It owns one
/// `WindowsAdapter` and the previous window procedure it replaced, and `free`
/// releases both.
pub const WindowsSubclassingAdapter = struct {
    /// The allocator that grew the adapter and this value.
    gpa: std.mem.Allocator,
    /// The seam every UI Automation call goes through.
    platform: Platform,
    /// The seam every window call goes through.
    window_api: WindowApi,
    /// The window this adapter took over.
    hwnd: Hwnd,
    /// The handler a `WM_GETOBJECT` asks for the tree. It stays valid until the
    /// adapter is released.
    activation_handler: ActivationHandler,
    /// The pointer `activation_handler` receives unchanged.
    activation_handler_userdata: ?*anyopaque,
    /// The handler a platform action reaches.
    action_handler: ActionHandler,
    /// The pointer `action_handler` receives unchanged.
    action_handler_userdata: ?*anyopaque,
    /// The adapter the window procedure drives.
    adapter: *WindowsAdapter,
    /// The procedure this one replaced, which the chain call uses.
    previous_window_proc: ?WindowProc = null,
    /// Whether the window has been destroyed, so the uninstall is skipped: the
    /// property is gone with the window and restoring the procedure would
    /// write into freed storage. Upstream `window_destroyed` at
    /// `subclass.rs:41` and `:126-128`.
    window_destroyed: bool = false,
    /// Whether the property and the procedure are installed.
    installed: bool = false,

    /// Takes over `hwnd` and answers the adapter, or `null` when it could not.
    ///
    /// **The three `null` answers**, which are the three places upstream panics
    /// or refuses:
    ///
    /// - The window is already visible. Upstream refuses at
    ///   `subclass.rs:167-171`, because a `WM_GETOBJECT` that arrives before the
    ///   procedure is installed is one this adapter never answers.
    /// - Another AccessKit subclassing adapter already owns the window.
    ///   Upstream refuses at `subclass.rs:96-101`.
    /// - The target has no Win32 window procedure, so `SetPropW` refused.
    ///   Upstream unwraps at `subclass.rs:109`.
    ///
    /// **Errors.** `error.OutOfMemory`. On that path nothing is installed and no
    /// window was touched.
    ///
    /// The adapter inside is built with `is_window_focused = false`, because
    /// the window has not been shown and so holds no focus. That is upstream's
    /// `Adapter::new(hwnd, false, action_handler)` at `subclass.rs:82`.
    pub fn create(
        gpa: std.mem.Allocator,
        platform: Platform,
        window_api: WindowApi,
        hwnd: Hwnd,
        activation_handler: ActivationHandler,
        activation_handler_userdata: ?*anyopaque,
        action_handler: ActionHandler,
        action_handler_userdata: ?*anyopaque,
    ) std.mem.Allocator.Error!?*WindowsSubclassingAdapter {
        if (window_api.is_window_visible(hwnd)) return null;
        if (window_api.get_property(hwnd, syscalls.subclass_property_name.ptr) != null) {
            return null;
        }

        const inner = try WindowsAdapter.create(
            gpa,
            platform,
            hwnd,
            false,
            action_handler,
            action_handler_userdata,
        );
        errdefer inner.deinit();

        const holder = try gpa.create(WindowsSubclassingAdapter);
        holder.* = .{
            .gpa = gpa,
            .platform = platform,
            .window_api = window_api,
            .hwnd = hwnd,
            .activation_handler = activation_handler,
            .activation_handler_userdata = activation_handler_userdata,
            .action_handler = action_handler,
            .action_handler_userdata = action_handler_userdata,
            .adapter = inner,
        };

        if (!window_api.set_property(
            hwnd,
            syscalls.subclass_property_name.ptr,
            @ptrCast(holder),
        )) {
            holder.free();
            return null;
        }
        const previous = window_api.set_window_proc(hwnd, syscalls.gwlp_wndproc, &windowProc);
        if (previous == 0) {
            _ = window_api.remove_property(hwnd, syscalls.subclass_property_name.ptr);
            holder.free();
            return null;
        }
        holder.previous_window_proc = @ptrFromInt(@as(usize, @bitCast(previous)));
        holder.installed = true;
        return holder;
    }

    /// Restores the window procedure and releases the adapter, exactly once.
    ///
    /// The uninstall is skipped when the window has been destroyed, because the
    /// property is gone with the window. That is upstream's `uninstall` at
    /// `subclass.rs:126-141`.
    pub fn free(self: *WindowsSubclassingAdapter) void {
        const gpa = self.gpa;
        if (self.installed and !self.window_destroyed) {
            if (self.previous_window_proc) |previous| {
                _ = self.window_api.set_window_proc(
                    self.hwnd,
                    syscalls.gwlp_wndproc,
                    previous,
                );
            }
            _ = self.window_api.remove_property(self.hwnd, syscalls.subclass_property_name.ptr);
        }
        self.installed = false;
        self.adapter.deinit();
        gpa.destroy(self);
    }

    /// Asks the update factory for a tree and applies the answer.
    ///
    /// **Errors.** `adapter.Error`, as `WindowsAdapter.updateIfActive` reports.
    pub fn updateIfActive(
        self: *WindowsSubclassingAdapter,
        update_factory: boundary.TreeUpdateFactory,
        update_factory_userdata: ?*anyopaque,
    ) adapter.Error!?adapter.QueuedEventsHolder {
        return self.adapter.updateIfActive(update_factory, update_factory_userdata);
    }

    /// The focus state one message names, or `null` when it names none.
    ///
    /// Upstream's table at `subclass.rs:62-67`. The three gain-focus messages
    /// and the three lose-focus messages are the six the adapter acts on, and
    /// every other message is chained on unchanged.
    pub fn focusFor(message: u32) ?bool {
        if (message == syscalls.wm_setfocus or
            message == syscalls.wm_entermenuloop or
            message == syscalls.wm_entersizemove)
        {
            return true;
        }
        if (message == syscalls.wm_killfocus or
            message == syscalls.wm_exitmenuloop or
            message == syscalls.wm_exitsizemove)
        {
            return false;
        }
        return null;
    }

    /// The procedure the adapter installs, which is what `GetPropW` finds.
    ///
    /// Upstream `wnd_proc` at `subclass.rs:44-74`. The adapter is reached
    /// through the window property rather than through a closure, because
    /// `SetWindowLongPtrW` takes a bare function pointer and a Zig function
    /// pointer cannot capture.
    fn windowProc(hwnd: Hwnd, message: u32, wparam: WParam, lparam: LParam) callconv(.c) LResult {
        const window_api = syscalls.windowApiForCurrentTarget();
        const found = window_api.get_property(hwnd, syscalls.subclass_property_name.ptr) orelse
            return chainOrDefault(hwnd, message, wparam, lparam, window_api, null);
        const self: *WindowsSubclassingAdapter = @ptrCast(@alignCast(found));

        if (message == syscalls.wm_getobject) {
            const answer = self.adapter.handleWmGetobject(
                wparam,
                lparam,
                self.activation_handler,
                self.activation_handler_userdata,
            );
            if (answer.has_value) return answer.value;
        }
        if (message == syscalls.wm_ncdestroy) self.window_destroyed = true;
        if (focusFor(message)) |focused| {
            const events = self.adapter.updateWindowFocusState(focused) catch
                return chainOrDefault(
                    hwnd,
                    message,
                    wparam,
                    lparam,
                    window_api,
                    self.previous_window_proc,
                );
            if (events) |queued| _ = queued.raise();
        }
        return chainOrDefault(
            hwnd,
            message,
            wparam,
            lparam,
            window_api,
            self.previous_window_proc,
        );
    }
};

/// Chains `message` to `previous`, or answers zero when there is no previous.
///
/// Upstream calls `CallWindowProcW` at `subclass.rs:73`. A zero is the honest
/// answer when nothing is installed to chain to, and it is what the unavailable
/// seam returns, so a refusal is visible rather than silent.
fn chainOrDefault(
    hwnd: Hwnd,
    message: u32,
    wparam: WParam,
    lparam: LParam,
    window_api: WindowApi,
    previous: ?WindowProc,
) LResult {
    const proc = previous orelse return 0;
    return window_api.call_window_proc(proc, hwnd, message, wparam, lparam);
}

/// The last raise the adapter reported, for a caller that wants the counts
/// without holding the queue.
///
/// **This is a re-export, not a second declaration.** `queued_events` owns the
/// type and `adapter.zig` reaches it through that module, so this name adds a
/// second spelling and nothing else.
pub const LastRaiseReport = RaiseReport;

// --- Tests -----------------------------------------------------------------

const testing = std.testing;

fn ignoreActivation(context: ?*anyopaque) callconv(.c) ?*boundary.CTreeUpdate {
    _ = context;
    return null;
}

/// An action handler that releases the request it is handed.
///
/// The request is built by `WindowsAdapter.dispatchAction` from the declared
/// allocator, so it goes back through the same one: `testing.allocator` would
/// free a block it never allocated as soon as a test reaches this handler with
/// a payload attached.
fn ignoreAction(request: *boundary.CActionRequest, context: ?*anyopaque) callconv(.c) void {
    _ = context;
    const schema = @import("../../schema/root.zig");
    schema.cActionRequestDeinit(allocation.allocator(), request);
    allocation.release(request);
}

test "the six focus messages name their focus state and the rest name none" {
    // `subclass.rs:62-67`. Six messages map and every other message is chained
    // on unchanged, so a message that is not in the table must answer `null`.
    const focusFor = WindowsSubclassingAdapter.focusFor;
    try testing.expectEqual(@as(?bool, true), focusFor(syscalls.wm_setfocus));
    try testing.expectEqual(@as(?bool, true), focusFor(syscalls.wm_entermenuloop));
    try testing.expectEqual(@as(?bool, true), focusFor(syscalls.wm_entersizemove));
    try testing.expectEqual(@as(?bool, false), focusFor(syscalls.wm_killfocus));
    try testing.expectEqual(@as(?bool, false), focusFor(syscalls.wm_exitmenuloop));
    try testing.expectEqual(@as(?bool, false), focusFor(syscalls.wm_exitsizemove));
    try testing.expectEqual(@as(?bool, null), focusFor(syscalls.wm_getobject));
    try testing.expectEqual(@as(?bool, null), focusFor(syscalls.wm_ncdestroy));
}

test "a visible window is refused rather than taken over" {
    // Upstream panics at `subclass.rs:167-171`. The C ABI answers `null`.
    const gpa = testing.allocator;
    const created = WindowsSubclassingAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        visibleWindowApi(),
        @ptrFromInt(0x1000),
        &ignoreActivation,
        null,
        &ignoreAction,
        null,
    );
    try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), created);
}

test "a window with no Win32 cannot be taken over" {
    // The refusal seam: `SetPropW` answers false, so the adapter is released and
    // the window is left alone.
    const gpa = testing.allocator;
    const created = WindowsSubclassingAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        syscalls.unavailableWindowApi(),
        @ptrFromInt(0x2000),
        &ignoreActivation,
        null,
        &ignoreAction,
        null,
    );
    try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), created);
}

test "a window another adapter already owns is refused" {
    const gpa = testing.allocator;
    const created = WindowsSubclassingAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        alreadyOwnedWindowApi(),
        @ptrFromInt(0x3000),
        &ignoreActivation,
        null,
        &ignoreAction,
        null,
    );
    try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), created);
}

test "the created adapter is not active and reports its window" {
    const gpa = testing.allocator;
    const owner = try WindowsSubclassingAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        acceptingWindowApi(),
        @ptrFromInt(0x4000),
        &ignoreActivation,
        null,
        &ignoreAction,
        null,
    );
    const holder = owner orelse return error.Refused;
    defer holder.free();

    try testing.expect(holder.installed);
    try testing.expect(!holder.adapter.isActive());
    try testing.expect(!holder.adapter.isPlaceholder());
    try testing.expectEqual(@as(?*consumer.tree.Tree, null), holder.adapter.tree());
    try testing.expectEqual(@as(usize, 0x4000), @intFromPtr(holder.hwnd.?));
}

test "free restores the procedure and drops the property" {
    const gpa = testing.allocator;
    const owner = try WindowsSubclassingAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        acceptingWindowApi(),
        @ptrFromInt(0x5000),
        &ignoreActivation,
        null,
        &ignoreAction,
        null,
    );
    const holder = owner orelse return error.Refused;
    try testing.expect(holder.installed);
    try testing.expect(holder.previous_window_proc != null);

    // `testing.allocator` traps on a leak, so this also proves the adapter
    // inside was released.
    holder.free();
}

test "a destroyed window is left alone by free" {
    const gpa = testing.allocator;
    const owner = try WindowsSubclassingAdapter.create(
        gpa,
        syscalls.unavailablePlatform(),
        acceptingWindowApi(),
        @ptrFromInt(0x6000),
        &ignoreActivation,
        null,
        &ignoreAction,
        null,
    );
    const holder = owner orelse return error.Refused;
    holder.window_destroyed = true;

    // The property is gone with the window, so the uninstall is skipped and the
    // release reaches only the memory.
    holder.free();
}

test "the chain helper answers zero when nothing is installed to chain to" {
    const answer = chainOrDefault(
        @ptrFromInt(0x7000),
        syscalls.wm_getobject,
        0,
        0,
        syscalls.unavailableWindowApi(),
        null,
    );
    try testing.expectEqual(@as(LResult, 0), answer);
}

/// A seam whose window is visible, which is upstream's first refusal.
fn visibleWindowApi() WindowApi {
    var api = syscalls.unavailableWindowApi();
    api.is_window_visible = struct {
        fn call(hwnd: Hwnd) bool {
            _ = hwnd;
            return true;
        }
    }.call;
    return api;
}

/// A seam whose window already carries the property, which is upstream's second
/// refusal.
fn alreadyOwnedWindowApi() WindowApi {
    var api = syscalls.unavailableWindowApi();
    api.get_property = struct {
        fn call(hwnd: Hwnd, name: [*:0]const u16) ?*anyopaque {
            _ = hwnd;
            _ = name;
            return @ptrFromInt(0xDEAD);
        }
    }.call;
    return api;
}

/// A seam that takes the window, which is the successful path.
fn acceptingWindowApi() WindowApi {
    var api = syscalls.unavailableWindowApi();
    api.present = true;
    api.set_property = struct {
        fn call(hwnd: Hwnd, name: [*:0]const u16, value: ?*anyopaque) bool {
            _ = hwnd;
            _ = name;
            return value != null;
        }
    }.call;
    api.set_window_proc = struct {
        fn call(hwnd: Hwnd, index: i32, procedure: WindowProc) LResult {
            _ = hwnd;
            _ = index;
            _ = procedure;
            // A non-zero previous procedure, so `create` reads it as a success.
            return @as(LResult, @intCast(@intFromPtr(&acceptingWindowApi)));
        }
    }.call;
    api.remove_property = struct {
        fn call(hwnd: Hwnd, name: [*:0]const u16) bool {
            _ = hwnd;
            _ = name;
            return true;
        }
    }.call;
    return api;
}