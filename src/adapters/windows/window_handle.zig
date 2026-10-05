//! The window handle the adapter is bound to.
//!
//! **What this file ports.** `adapters/windows/src/window_handle.rs:1-32` in
//! the pinned upstream tree, which is 32 lines: one `#[repr(transparent)]`
//! newtype over `HWND`, two conversions and one `static_assertions` line.
//!
//! **Why the port needs a newtype at all.** Upstream wraps `HWND` so that the
//! `unsafe impl Send` and `unsafe impl Sync` are written once. The port has no
//! `unsafe impl`, and a bare pointer is a single word that any caller may
//! invent, so the wrapper carries the two things the raw pointer cannot: the
//! width the ABI promises, and the absence of a window, spelled once.
//! `test "the handle is one opaque pointer wide"` is the width.
//!
//! **Why `raw` is optional.** `zigwin32` declares `HWND = *opaque {}`
//! (`zigwin32/win32/foundation.zig:6668`), which is not nullable: the compiler
//! rejects a zero address and a comparison with `null`. The C seam wants the
//! opposite. `src/capi/boundary.zig:84` spells the same handle as
//! `?*anyopaque`, and the C header that includes `<windows.h>` types it as
//! `HWND`, which is a bare pointer that the SDK allows to be `NULL`. So the
//! wrapper holds `?Hwnd` and the two questions that a non-optional pointer
//! cannot answer are answered by the type: `fromNullable` accepts absence, and
//! `hwnd` answers `null` rather than a zero address the binding forbids.
//!
//! **What that costs at the C seam.** Nothing in the header, and one thing in
//! Zig. The header declares one pointer and the seam type is one optional
//! pointer, so the value crossing the boundary is the same size and the same
//! address. In Zig the caller loses the ability to treat a missing window as a
//! real window, which is deliberate: a C caller that passes `NULL` now reads
//! `isNull` as `true` instead of dispatching a message to address zero.
//!
//! **Why the wrapper is not an `extern struct`.** An `extern struct` promises
//! a C layout. This type never crosses into C by value, so the promise buys
//! nothing, and the cost is that the field list is then frozen: a field whose
//! nullability is a Zig decision would be frozen as though the SDK had made
//! it. It is a plain `struct`, and the size, the alignment and the offset of
//! `raw` are asserted at compile time below, which is the part of the C layout
//! this wrapper actually relies on.
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
/// A caller may pass an absent handle. It names no window, and every method
/// that takes one must answer for it rather than dispatch through it.
/// `fromNullable` is the only constructor that accepts one.
pub const WindowHandle = struct {
    /// The platform window handle. `null` names no window.
    raw: ?bindings.Hwnd,

    /// Wraps a handle the caller already holds.
    ///
    /// No check runs. A handle that names no live window is still a handle,
    /// and the adapter answers for it at the point it would be used.
    pub fn fromHwnd(raw: bindings.Hwnd) WindowHandle {
        return .{ .raw = raw };
    }

    /// Wraps a handle that may be absent.
    ///
    /// The optional passes through unchanged, so a `null` input and a
    /// `fromHwnd` of a zero address name the same window: no window.
    pub fn fromNullable(raw: ?bindings.Hwnd) WindowHandle {
        return .{ .raw = raw };
    }

    /// The handle the platform calls take.
    ///
    /// This is the only place the wrapper is removed, and it answers the
    /// optional as it is. A caller that needs a handle it can dispatch
    /// through reads `raw` and answers for the `null` case itself, because a
    /// zero address is not a handle this binding will express.
    pub fn hwnd(self: WindowHandle) ?bindings.Hwnd {
        return self.raw;
    }

    /// Whether the handle names no window.
    pub fn isNull(self: WindowHandle) bool {
        return self.raw == null;
    }

    /// Two handles are the same window when the platform value is the same
    /// pointer. `HWND` is a pointer, so `==` is the correct comparison here
    /// and is the one exception to the `FullNodeId` rule. Two absent handles
    /// are the same window, because both name none.
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
    try std.testing.expectEqual(@as(usize, 0x1234), @intFromPtr(handle.hwnd().?));
    try std.testing.expect(handle.eql(handle));
    try std.testing.expect(!handle.eql(WindowHandle.fromHwnd(@ptrFromInt(0x5678))));
}

test "an absent handle is a handle that names no window" {
    const absent = WindowHandle.fromNullable(null);
    try std.testing.expect(absent.isNull());
    try std.testing.expect(absent.hwnd() == null);
    try std.testing.expect(absent.eql(WindowHandle.fromNullable(null)));
    try std.testing.expect(!absent.eql(WindowHandle.fromHwnd(@ptrFromInt(0x1234))));
}

test "the field is the seam's own handle type" {
    // `src/capi/boundary.zig:84` spells the handle as `?*anyopaque`, so the
    // adapter hands the seam a value without a cast. This is the assertion
    // that the two types stay the same shape.
    const absent: ?*anyopaque = WindowHandle.fromNullable(null).raw;
    try std.testing.expect(absent == null);
    const present: ?*anyopaque = WindowHandle.fromHwnd(@ptrFromInt(0x1234)).raw;
    try std.testing.expectEqual(@as(usize, 0x1234), @intFromPtr(present.?));
}
