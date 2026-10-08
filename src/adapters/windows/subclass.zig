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
//! **Test boundaries.** Portable tests drive installation, focus messages,
//! property naming and uninstall through the injected `WindowApi`. The
//! Windows-only text test uses an actual hidden SDK window and native readback;
//! it requires a native Windows runtime.
//!
//! **Loop bounds.** No loop outside a test.

const std = @import("std");
const builtin = @import("builtin");

const adapter = @import("adapter.zig");
const consumer = @import("../../consumer/root.zig");
const boundary = @import("../../capi/boundary.zig");
const allocation = @import("../../capi/allocation.zig");
const queued_events = @import("queued_events.zig");
const syscalls = @import("syscalls.zig");
const schema = @import("../../schema/root.zig");
const util = @import("util.zig");
const context_mod = @import("context.zig");
const bindings = @import("bindings.zig");

const ActivationSource = adapter.ActivationSource;
const Hwnd = boundary.Hwnd;
const LResult = syscalls.LResult;
const WParam = boundary.WParam;
const LParam = boundary.LParam;

const WindowsAdapter = adapter.WindowsAdapter;
const RaiseReport = queued_events.RaiseReport;
const WindowApi = syscalls.WindowApi;
const WindowProc = syscalls.WindowProc;

/// The Windows subclassing adapter.
///
/// The caller owns the adapter and releases it with `free`. It owns one
/// `WindowsAdapter` and the previous window procedure it replaced, and `free`
/// releases both.
/// Install and free on the window's owning thread, serialized with its procedure.
/// Do not close from a callback or while holding a context lease on this thread.
pub const WindowsSubclassingAdapter = struct {
    /// The allocator that grew the adapter and this value.
    gpa: std.mem.Allocator,
    /// The seam every window call goes through.
    window_api: WindowApi,
    /// The window this adapter took over.
    hwnd: Hwnd,
    /// Activation transfers a C handle or borrows a synchronous native full view.
    /// Its callback and userdata remain valid until adapter close completes.
    activation_source: ActivationSource,
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
    /// **Errors.** `context.ProviderError`, including allocation and owner admission.
    /// Every failure uninstalls any attachment and leaves runtime authority caller-owned.
    ///
    /// The adapter inside is built with `is_window_focused = false`, because
    /// the window has not been shown and so holds no focus. That is upstream's
    /// `Adapter::new(hwnd, false, action_handler)` at `subclass.rs:82`.
    /// This call transfers `options.runtime_release` only on successful non-null return.
    /// The runtime hook must not free the provider allocator.
    /// Installation must run on the owning window thread before the window is shown.
    pub fn create(
        gpa: std.mem.Allocator,
        options: WindowsAdapter.Options,
        window_api: WindowApi,
        activation_source: ActivationSource,
    ) context_mod.ProviderError!?*WindowsSubclassingAdapter {
        const hwnd = options.hwnd;
        if (window_api.is_window_visible(hwnd)) {
            return null;
        }
        if (window_api.get_property(hwnd, syscalls.subclass_property_name.ptr) != null) {
            return null;
        }

        var foundation_options = options;
        foundation_options.is_window_focused = false;
        foundation_options.runtime_release = null;
        const inner = try WindowsAdapter.create(gpa, foundation_options);

        const holder = gpa.create(WindowsSubclassingAdapter) catch |err| {
            inner.deinit();
            return err;
        };
        holder.* = .{
            .gpa = gpa,
            .window_api = window_api,
            .hwnd = hwnd,
            .activation_source = activation_source,
            .adapter = inner,
        };
        errdefer holder.free();

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
        // The hook cannot move to the inner owner before outer attachment commits.
        // Pin admission is the final fallible step; no native call runs under its tree guard.
        var guard = try inner.context.enter();
        defer guard.deinit();
        if (options.runtime_release) |authority| guard.control.setRuntimeRelease(authority);
        return holder;
    }

    /// Restores the window procedure and releases the adapter, exactly once.
    ///
    /// The uninstall is skipped when the window has been destroyed, because the
    /// property is gone with the window. That is upstream's `uninstall` at
    /// `subclass.rs:126-141`.
    /// Run on the owning window thread, not inside an activation/action callback or lease.
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
    fn windowProc(
        hwnd: Hwnd,
        message: u32,
        wparam: WParam,
        lparam: LParam,
    ) callconv(syscalls.window_proc_callconv) LResult {
        const window_api = syscalls.windowApiForCurrentTarget();
        const found = window_api.get_property(hwnd, syscalls.subclass_property_name.ptr) orelse
            return chainOrDefault(
                hwnd,
                message,
                wparam,
                lparam,
                window_api,
                null,
                syscalls.nativeAutomationApi(),
            );
        const self: *WindowsSubclassingAdapter = @ptrCast(@alignCast(found));

        if (message == syscalls.wm_getobject) {
            const answer = self.adapter.handleWmGetobject(
                wparam,
                lparam,
                self.activation_source,
            ) catch |err| {
                allocation.failWithError(err);
                return chainOrDefault(
                    hwnd,
                    message,
                    wparam,
                    lparam,
                    window_api,
                    self.previous_window_proc,
                    self.adapter.context.automation,
                );
            };
            if (answer.has_value) return answer.value;
        }
        if (message == syscalls.wm_ncdestroy) self.window_destroyed = true;
        if (focusFor(message)) |focused| {
            const events = self.adapter.updateWindowFocusState(focused) catch |err| {
                allocation.failWithError(err);
                return chainOrDefault(
                    hwnd,
                    message,
                    wparam,
                    lparam,
                    window_api,
                    self.previous_window_proc,
                    self.adapter.context.automation,
                );
            };
            if (events) |value| {
                var queued = value;
                const report = queued.raise();
                // Native raises must not retain or lock these automatic focus values.
                // This local queue has no caller that can keep it for a cleanup retry.
                if (report.cleanup.first_error) |err| {
                    std.debug.panic("native subclass focus cleanup failed: {s}", .{@errorName(err)});
                }
            }
        }
        return chainOrDefault(
            hwnd,
            message,
            wparam,
            lparam,
            window_api,
            self.previous_window_proc,
            self.adapter.context.automation,
        );
    }
};

/// Chains through the previous procedure, or uses the real native default procedure.
///
/// Only an unavailable off-Windows authority has no procedure to call.
fn chainOrDefault(
    hwnd: Hwnd,
    message: u32,
    wparam: WParam,
    lparam: LParam,
    window_api: WindowApi,
    previous: ?WindowProc,
    automation: ?*const util.AutomationApi,
) LResult {
    if (previous) |proc| {
        return window_api.call_window_proc(proc, hwnd, message, wparam, lparam);
    }
    const api = automation orelse return 0;
    return api.def_window_proc(api.context, @ptrCast(hwnd.?), message, wparam, lparam);
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
    const gpa = allocation.allocator();
    schema.cActionRequestDeinit(gpa, request);
    gpa.destroy(request);
}

const SubclassTestFixture = struct {
    runtime: std.Io.Threaded,
    abi: util.AutomationTestAbi,
    automation: util.AutomationApi,

    fn init(self: *SubclassTestFixture, gpa: std.mem.Allocator) void {
        self.runtime = std.Io.Threaded.init(gpa, .{});
        self.abi = util.AutomationTestAbi.init(gpa);
        self.automation = self.abi.api();
    }

    fn deinit(self: *SubclassTestFixture) void {
        self.runtime.deinit();
        self.* = undefined;
    }

    fn foundationOptions(self: *SubclassTestFixture, hwnd: Hwnd) WindowsAdapter.Options {
        return .{
            .io = self.runtime.io(),
            .platform = adapter.testPlatform(),
            .factory = adapter.testProviderFactory(),
            .automation = &self.automation,
            .hwnd = hwnd,
            .is_window_focused = false,
            .action_sink = .{ .c = .{ .callback = &ignoreAction, .userdata = null } },
        };
    }
};

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
    var foundation: SubclassTestFixture = undefined;
    foundation.init(gpa);
    defer foundation.deinit();
    const created = try WindowsSubclassingAdapter.create(
        gpa,
        foundation.foundationOptions(@ptrFromInt(0x1000)),
        visibleWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
    );
    try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), created);
}

test "a window with no Win32 cannot be taken over" {
    // The refusal seam: `SetPropW` answers false, so the adapter is released and
    // the window is left alone.
    const gpa = testing.allocator;
    var foundation: SubclassTestFixture = undefined;
    foundation.init(gpa);
    defer foundation.deinit();
    const created = try WindowsSubclassingAdapter.create(
        gpa,
        foundation.foundationOptions(@ptrFromInt(0x2000)),
        syscalls.unavailableWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
    );
    try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), created);
}

test "a window another adapter already owns is refused" {
    const gpa = testing.allocator;
    var foundation: SubclassTestFixture = undefined;
    foundation.init(gpa);
    defer foundation.deinit();
    const created = try WindowsSubclassingAdapter.create(
        gpa,
        foundation.foundationOptions(@ptrFromInt(0x3000)),
        alreadyOwnedWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
    );
    try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), created);
}

test "the created adapter is not active and reports its window" {
    const gpa = testing.allocator;
    var foundation: SubclassTestFixture = undefined;
    foundation.init(gpa);
    defer foundation.deinit();
    const owner = try WindowsSubclassingAdapter.create(
        gpa,
        foundation.foundationOptions(@ptrFromInt(0x4000)),
        acceptingWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
    );
    const holder = owner orelse return error.Refused;
    defer holder.free();

    try testing.expect(holder.installed);
    try testing.expect(!holder.adapter.isActive());
    try testing.expect(!holder.adapter.isPlaceholder());
    var guard = try holder.adapter.context.enter();
    defer guard.deinit();
    try testing.expectEqual(@as(?*consumer.tree.Tree, null), holder.adapter.tree());
    try testing.expectEqual(@as(usize, 0x4000), @intFromPtr(holder.hwnd.?));
}

test "free restores the procedure and drops the property" {
    const gpa = testing.allocator;
    var foundation: SubclassTestFixture = undefined;
    foundation.init(gpa);
    defer foundation.deinit();
    const owner = try WindowsSubclassingAdapter.create(
        gpa,
        foundation.foundationOptions(@ptrFromInt(0x5000)),
        acceptingWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
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
    var foundation: SubclassTestFixture = undefined;
    foundation.init(gpa);
    defer foundation.deinit();
    const owner = try WindowsSubclassingAdapter.create(
        gpa,
        foundation.foundationOptions(@ptrFromInt(0x6000)),
        acceptingWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
    );
    const holder = owner orelse return error.Refused;
    holder.window_destroyed = true;

    // The property is gone with the window, so the uninstall is skipped and the
    // release reaches only the memory.
    holder.free();
}

test "the unavailable off-Windows chain has no native procedure" {
    if (comptime builtin.os.tag == .windows) return error.SkipZigTest;
    const answer = chainOrDefault(
        @ptrFromInt(0x7000),
        syscalls.wm_getobject,
        0,
        0,
        syscalls.unavailableWindowApi(),
        null,
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
            return @intCast(@intFromPtr(&acceptingWindowApi));
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

const CallerRuntime = struct {
    gpa: std.mem.Allocator,
    runtime: std.Io.Threaded,
    released: *bool,

    fn create(gpa: std.mem.Allocator, released: *bool) std.mem.Allocator.Error!*CallerRuntime {
        const self = try gpa.create(CallerRuntime);
        self.* = .{
            .gpa = gpa,
            .runtime = std.Io.Threaded.init(gpa, .{}),
            .released = released,
        };
        return self;
    }

    fn release(userdata: ?*anyopaque) void {
        const self: *CallerRuntime = @ptrCast(@alignCast(userdata.?));
        const gpa = self.gpa;
        self.runtime.deinit();
        self.released.* = true;
        gpa.destroy(self);
    }

    fn options(self: *CallerRuntime, automation: *const util.AutomationApi) WindowsAdapter.Options {
        return .{
            .io = self.runtime.io(),
            .platform = adapter.testPlatform(),
            .factory = adapter.testProviderFactory(),
            .automation = automation,
            .hwnd = @ptrFromInt(0x3456),
            .is_window_focused = false,
            .action_sink = .{ .c = .{ .callback = &ignoreAction, .userdata = null } },
            .runtime_release = .{ .userdata = self, .release = release },
        };
    }

    fn statCurrentDirectory(io: std.Io) std.Io.Dir.StatFileError!std.Io.File.Kind {
        return (try std.Io.Dir.cwd().statFile(io, ".", .{})).kind;
    }

    fn useRuntime(self: *CallerRuntime) !void {
        const io = self.runtime.io();
        var future = try std.Io.concurrent(io, statCurrentDirectory, .{io});
        const kind = try future.await(io);
        try testing.expectEqual(std.Io.File.Kind.directory, kind);
    }
};

fn procedureRefusingWindowApi() WindowApi {
    var api = acceptingWindowApi();
    api.set_window_proc = struct {
        fn call(hwnd: Hwnd, index: i32, procedure: WindowProc) LResult {
            _ = hwnd;
            _ = index;
            _ = procedure;
            return 0;
        }
    }.call;
    return api;
}

test "subclass refusals leave the caller runtime reusable for a later successful attachment" {
    // Cover both pre-construction refusals and both fallible attachment steps.
    inline for (.{
        visibleWindowApi,
        alreadyOwnedWindowApi,
        syscalls.unavailableWindowApi,
        procedureRefusingWindowApi,
    }) |make_window_api| {
        const gpa = testing.allocator;
        var released = false;
        const runtime = try CallerRuntime.create(gpa, &released);
        defer if (!released) CallerRuntime.release(runtime);
        var abi = util.AutomationTestAbi.init(gpa);
        const automation = abi.api();
        const refused = try WindowsSubclassingAdapter.create(
            gpa,
            runtime.options(&automation),
            make_window_api(),
            .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
        );
        defer if (refused) |owner| owner.free();
        try testing.expectEqual(@as(?*WindowsSubclassingAdapter, null), refused);
        try testing.expect(!released);
        try runtime.useRuntime();

        const accepted = (try WindowsSubclassingAdapter.create(
            gpa,
            runtime.options(&automation),
            acceptingWindowApi(),
            .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
        )) orelse return error.UnexpectedRefusal;
        accepted.free();
        try testing.expect(released);
    }
}

test "each subclass constructor allocation failure preserves caller runtime ownership" {
    const allocation_failure_bound = 64;
    var failures: usize = 0;
    var completed = false;
    for (0..allocation_failure_bound) |fail_index| {
        const gpa = testing.allocator;
        var released = false;
        const runtime = try CallerRuntime.create(gpa, &released);
        defer if (!released) CallerRuntime.release(runtime);
        var abi = util.AutomationTestAbi.init(gpa);
        const automation = abi.api();
        var failing = testing.FailingAllocator.init(gpa, .{ .fail_index = fail_index });
        const result = WindowsSubclassingAdapter.create(
            failing.allocator(),
            runtime.options(&automation),
            acceptingWindowApi(),
            .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
        ) catch |err| {
            try testing.expectEqual(error.OutOfMemory, err);
            try testing.expect(failing.has_induced_failure);
            failures += 1;
            try testing.expect(!released);
            try runtime.useRuntime();
            continue;
        };
        const accepted = result orelse return error.UnexpectedRefusal;
        var accepted_live = true;
        defer if (accepted_live) accepted.free();
        try testing.expect(!failing.has_induced_failure);
        accepted_live = false;
        accepted.free();
        try testing.expect(released);
        completed = true;
        break;
    }
    try testing.expect(failures != 0);
    try testing.expect(completed);
}

test "successful subclass runtime transfer survives close until the final weak handle" {
    const gpa = testing.allocator;
    var released = false;
    const runtime = try CallerRuntime.create(gpa, &released);
    defer if (!released) CallerRuntime.release(runtime);
    var abi = util.AutomationTestAbi.init(gpa);
    const automation = abi.api();
    const accepted = (try WindowsSubclassingAdapter.create(
        gpa,
        runtime.options(&automation),
        acceptingWindowApi(),
        .{ .c = .{ .callback = &ignoreActivation, .userdata = null } },
    )) orelse return error.UnexpectedRefusal;
    var weak = accepted.adapter.context.weak();
    var weak_live = true;
    defer if (weak_live) weak.deinit();
    accepted.free();
    try testing.expect(!released);
    try runtime.useRuntime();
    weak_live = false;
    weak.deinit();
    try testing.expect(released);
}

test "a missing previous procedure updates actual native window text" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const user32 = bindings.win32.user32;
    const kernel32 = bindings.win32.kernel32;
    const wm = bindings.wm;
    const class_name: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("STATIC");
    const wanted: [:0]const u16 = std.unicode.utf8ToUtf16LeStringLiteral("AccessKit default procedure");
    const instance = kernel32.GetModuleHandleW(null) orelse return error.GetModuleHandleFailed;
    const native_hwnd = user32.CreateWindowExW(
        .{},
        class_name.ptr,
        null,
        wm.WS_OVERLAPPED,
        wm.CW_USEDEFAULT,
        wm.CW_USEDEFAULT,
        1,
        1,
        null,
        null,
        instance,
        null,
    ) orelse return error.CreateWindowFailed;
    defer {
        if (user32.DestroyWindow(native_hwnd) == 0) {
            @panic("Native window text test could not destroy its window");
        }
    }
    const answer = WindowsSubclassingAdapter.windowProc(
        @ptrCast(native_hwnd),
        wm.WM_SETTEXT,
        0,
        @bitCast(@intFromPtr(wanted.ptr)),
    );
    try testing.expectEqual(@as(LResult, 1), answer);
    var observed = std.mem.zeroes([64:0]u16);
    const copied = user32.GetWindowTextW(native_hwnd, &observed, @intCast(observed.len));
    try testing.expectEqual(@as(i32, @intCast(wanted.len)), copied);
    try testing.expectEqualSlices(u16, wanted, observed[0..@intCast(copied)]);
}
