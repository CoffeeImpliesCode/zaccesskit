//! The types that cross between the C ABI and a platform adapter.
//!
//! **Why this file exists, and why it is a leaf.** `src/capi/platform.zig`
//! imports all five adapters, because it owns the 58 declarations the header puts
//! behind its platform guards. An adapter needs the four callback types to be
//! able to *hold* a handler it was given — so the adapter would have to import
//! `platform.zig` back, and the two files would import each other. That is a
//! cycle, and a cycle at the seam where `@export` runs at `comptime` is the kind
//! that fails with an error nobody can act on.
//!
//! So the shared types live here, in a file that imports only schema and handles.
//! `platform.zig` imports this and re-exports every name, which keeps every
//! existing reference in that file working, and every adapter imports this
//! directly. **Neither side ever imports the other.**
//!
//! **What belongs here.** Only a type both sides must name. Anything one adapter
//! uses alone belongs in that adapter, and anything the C ABI uses without an
//! adapter belongs in `platform.zig`. The JNI types and `COptLResult` are
//! deliberately *not* here: each is used by exactly one platform, and pulling
//! them in would make this file a second home for a definition that has one.

const schema = @import("../schema/root.zig");
const handles = @import("handles.zig");
const std = @import("std");

/// The box the Unix family passes by value. `accesskit_rect` is four `double`
/// at offsets 0, 8, 16 and 24, which is 32 bytes at alignment 8, and
/// `schema.Rect` is the same `extern struct`, so the conversion across this seam
/// is the identity and neither side writes one.
///
/// `docs/40-capi-build-map.md` section 3.2 records the measurement.
pub const CRect = schema.Rect;

/// The tree an activation handler and a tree-update factory return.
///
/// `accesskit_tree_update` is an opaque owning handle. Its representation and
/// consuming conversion belong to `tree_update.zig`, not to the native schema.
pub const CTreeUpdate = handles.accesskit_tree_update;

/// The request an action handler receives. The port's own `extern struct` form
/// of `accesskit_action_request` is already written at
/// `src/schema/update.zig:363`, and the callback passes a pointer to it.
pub const CActionRequest = schema.CActionRequest;

/// `accesskit_tree_update_factory`, at `include/zaccesskit.h:1707` and upstream
/// `src/lib.rs:1698`.
///
/// The factory builds one whole tree update and transfers it to the library,
/// which releases it after delivery. It runs on a thread of the library's own, so
/// it must assume nothing about the thread that installed it, and **it must not
/// return `null`** — a `null` return from a factory is a contract violation and
/// terminates the process.
pub const TreeUpdateFactory = *const fn (?*anyopaque) callconv(.c) ?*CTreeUpdate;

/// `accesskit_activation_handler_callback`, at `include/zaccesskit.h:1720` and
/// upstream `src/lib.rs:1711`.
///
/// It is textually identical to `TreeUpdateFactory` and the header keeps both
/// names because upstream does. The difference is the contract, and it is the
/// one an adapter gets wrong: **a `null` return here is an ordinary answer
/// meaning "no tree", not a failure**, and the library keeps nothing. The same
/// return from a factory is a contract violation.
pub const ActivationHandler = *const fn (?*anyopaque) callconv(.c) ?*CTreeUpdate;

/// `accesskit_action_handler_callback`, at `include/zaccesskit.h:1737` and
/// upstream `src/lib.rs:1728`.
///
/// The request arrives by transfer: **the callback owns it and releases it with
/// `accesskit_action_request_free` before returning, on every path out.** For a
/// `value` payload that release also frees the string inside it. An adapter that
/// stores the pointer and releases later has a double free.
pub const ActionHandler = *const fn (*CActionRequest, ?*anyopaque) callconv(.c) void;

/// `accesskit_deactivation_handler_callback`, at
/// `include/zaccesskit.h:1748` and upstream `src/lib.rs:1739`.
///
/// It runs on the same thread as the activation handler for the same adapter,
/// and `userdata` reaches it unchanged.
pub const DeactivationHandler = *const fn (?*anyopaque) callconv(.c) void;

/// `HWND`, from `<windows.h>`, which the header includes under `_WIN32`.
///
/// The port spells it as an opaque pointer because `windows.h` is not available
/// on this target and the header's contract is the pointer, not the struct.
pub const Hwnd = ?*anyopaque;

/// `WPARAM`, the unsigned pointer-sized message field of a Win32 message.
pub const WParam = usize;

/// `LPARAM`, the signed pointer-sized message field of a Win32 message.
pub const LParam = isize;

/// `accesskit_opt_lresult`, at `include/zaccesskit.h:1573`, the one struct this
/// boundary declares that exists only under `_WIN32`.
///
/// `docs/40-capi-build-map.md` section 3.2 measured it: 16 bytes at alignment 8
/// with `value` at offset 8. `has_value` false means this adapter does not own
/// the window and the window procedure returns `false` from `DefWindowProc`;
/// `value` is then a zero the port writes, so a reader who ignores the flag
/// reads a defined zero rather than uninitialised storage.
///
/// It is here rather than in `windows/root.zig` because `platform.zig` names it
/// as the return of `accesskit_windows_adapter_handle_wm_getobject`, and a type
/// the C ABI names and an adapter returns has to have exactly one declaration.
pub const COptLResult = extern struct {
    /// `bool has_value;`. False when this adapter is not the window's owner.
    has_value: bool,
    /// `LRESULT value;`, read only when `has_value` is true. `LRESULT` is
    /// `LONG_PTR`, a signed pointer-sized integer, and it is 64 bits on every
    /// target this port claims for Windows.
    value: isize,
};

comptime {
    // The layout the header was measured to have, `docs/40` section 3.2. These
    // are the two values that cross this seam by value, so a field reordered or
    // retyped here is a C consumer reading the wrong memory rather than a
    // compile error anywhere.
    std.debug.assert(@sizeOf(CRect) == 32);
    std.debug.assert(@alignOf(CRect) == 8);
    std.debug.assert(@offsetOf(CRect, "y1") == 24);

    // The calling convention is recorded in each declaration above, as
    // `callconv(.c)`, and it is the only place it is written. Reflection reads
    // it back too: `@typeInfo` on the pointer has no `calling_convention`, but
    // its `child` is the function type, and
    // `@typeInfo(pointer.child).@"fn".calling_convention` is the convention the
    // header declares. `src/capi/platform.zig` asserts exactly that for all
    // four types, in its test "the four callback types have the shapes the
    // header declares".

    // `ActivationHandler` and `TreeUpdateFactory` are the same shape and the
    // header keeps both names because upstream does. If they ever diverge, the
    // distinction the doc comments draw — null means "no tree" here, and is a
    // contract violation there — is no longer expressible in the types, so pin
    // it while it holds.
    if (ActivationHandler != TreeUpdateFactory) @compileError("the two factories are one shape");
}
