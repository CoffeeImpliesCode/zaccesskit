//! The window handle the adapter is bound to.
//!
//! **What this file ports.** `adapters/windows/src/window_handle.rs:1-32` in
//! the pinned upstream tree, which is 32 lines: one `#[repr(transparent)]`
//! newtype over `HWND`, two conversions and one `static_assertions` line.
//!
//! **Why the port needs a newtype at all.** Upstream wraps `HWND` so that the
//! `unsafe impl Send` and `unsafe impl Sync` are written once. The port has no
//! `unsafe impl`, and a bare `*opaque` is a single word that any caller may
//! invent, so the wrapper carries the two things the raw pointer cannot: the
//! width the ABI promises, and the conversion in both directions spelled once.
//! `test "the handle is one opaque pointer wide"` is that width.
//!
//! **What this file does not do.** It does not check that the handle names a
//! live window. `IsWindowVisible` answers that, it lives in `syscalls.zig`,
//! and it needs a real window.

const std = @import("std");
const bindings = @import("bindings.zig");

/// The window the adapter is bound to.
///
/// The value is one opaque pointer wide and holds nothing else. Upstream
/// declares it `#[repr(transparent)]` over `HWND`; the port declares the same
/// single field, so the two layouts agree.
///
/// A caller may pass a null handle. It names no window, and every method that
/// takes one must answer for it rather than dereference it. `fromNullable`
/// is the only constructor that accepts one.
///
/// Upstream declares this type `Send` and `Sync` with two `unsafe impl`
/// lines (`window_handle.rs:12-13`). A pointer into no address space is not
/// shared state, so the port needs no such declaration and makes none.
pub const WindowHandle = extern struct {
    /// The platform window handle. `null` names no window.
    raw: bindings.Hwnd,

    /// Wraps a handle the caller already holds.
    ///
    /// No check runs. A handle that names no live window is still a handle,
    /// and the adapter answers for it at the point it would be used.
    pub fn fromHwnd(raw: bindings.Hwnd) WindowHandle {
        return .{ .raw = raw };
    }

    /// Wraps a handle that may be absent.
    ///
    /// A `null` input becomes a handle whose `raw` is `null`, which is the
    /// same value `fromHwnd(null)` produces.
    pub fn fromNullable(raw: ?bindings.Hwnd) WindowHandle {
        return .{ .raw = raw orelse @ptrFromInt(0) };
    }

    /// The handle the platform calls take.
    ///
    /// This is the only place the wrapper is removed. A caller that needs a
    /// nullable handle uses `raw` and may compare it against `null`.
    pub fn hwnd(self: WindowHandle) bindings.Hwnd {
        return self.raw;
    }

    /// Whether the handle names no window.
    pub fn isNull(self: WindowHandle) bool {
        return self.raw == null;
    }

    /// Two handles are the same window when the platform value is the same
    /// pointer. `HWND` is a pointer, so `==` is the correct comparison here
    /// and is the one exception to the `FullNodeId` rule.
    pub fn eql(self: WindowHandle, other: WindowHandle) bool {
        return self.raw == other.raw;
    }
};

/// The platform window handle type, re-exported because a caller that hands a
/// `HWND` to the adapter needs the name.
pub const Hwnd = bindings.Hwnd;

// --- Tests -----------------------------------------------------------------

test "the handle is one opaque pointer wide" {
    try std.testing.expectEqual(@sizeOf(usize), @sizeOf(WindowHandle));
    try std.testing.expectEqual(@alignOf(usize), @alignOf(WindowHandle));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(WindowHandle, "raw"));
}

test "the wrapper round-trips through the platform type" {
    const handle = WindowHandle.fromHwnd(@ptrFromInt(0x1234));
    try std.testing.expect(!handle.isNull());
    try std.testing.expectEqual(@as(usize, 0x1234), @intFromPtr(handle.hwnd()));
    try std.testing.expect(handle.eql(handle));
    try std.testing.expect(!handle.eql(WindowHandle.fromHwnd(@ptrFromInt(0x5678))));
}

test "an absent handle is a handle that names no window" {
    const absent = WindowHandle.fromNullable(null);
    try std.testing.expect(absent.isNull());
    try std.testing.expectEqual(@as(usize, 0), @intFromPtr(absent.hwnd()));
    try std.testing.expect(absent.eql(WindowHandle.fromHwnd(@ptrFromInt(0))));
}
