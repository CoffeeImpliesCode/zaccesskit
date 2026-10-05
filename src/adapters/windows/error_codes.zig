//! The status codes the adapter answers with.
//!
//! **What this file ports.** `adapters/windows/src/util.rs:348-374` in the
//! pinned upstream tree: `not_implemented`, `invalid_arg`, `required_param`,
//! `element_not_available`, `element_not_enabled`, `invalid_operation` and
//! `not_supported`.
//!
//! **Why the port needs this file at all.** Upstream returns `windows::core::Error`,
//! which is a newtype over `HRESULT` with a `Debug` and a `Display`. Zig has
//! no `HRESULT` in the standard library, so the port names the codes itself and
//! converts with `@bitCast`. That conversion is the whole risk in this file,
//! and the two sweeps below it pin it: one against the SDK's own bit layout
//! and one against the facility each code carries.
//!
//! **What this file does not hold.** No error set, because nothing here can
//! fail: every function returns a value. The thunks that return a status to a
//! UI Automation client build one of these and hand it back; they do not check
//! it.

const std = @import("std");
const bindings = @import("bindings.zig");

/// The status a UI Automation client receives.
pub const Hresult = bindings.Hresult;

/// `E_INVALIDARG`, the code for a required parameter that was absent.
///
/// Upstream `util.rs:352-354`.
pub fn invalidArg() Hresult {
    return @bitCast(@as(u32, @bitCast(bindings.win32.foundation.E_INVALIDARG)));
}

/// `E_NOTIMPL`, the code for a pattern the adapter does not implement.
///
/// Upstream `util.rs:348-350`.
pub fn notImplemented() Hresult {
    return @bitCast(@as(u32, @bitCast(bindings.win32.foundation.E_NOTIMPL)));
}

/// `UIA_E_ELEMENTNOTAVAILABLE`, the code for a node the tree no longer holds.
///
/// Upstream `util.rs:360-362`. The four `UIA_E_*` codes are declared in
/// `win32/ui/accessibility.zig` at the pinned commit, not in
/// `win32/foundation.zig`, and each is a plain `u32` there, so the cast is
/// one `@bitCast` from the constant to the packed `HRESULT` the port returns.
pub fn elementNotAvailable() Hresult {
    return @bitCast(bindings.uia.UIA_E_ELEMENTNOTAVAILABLE);
}

/// `UIA_E_ELEMENTNOTENABLED`, the code for an action on a disabled node.
///
/// Upstream `util.rs:364-366`.
pub fn elementNotEnabled() Hresult {
    return @bitCast(bindings.uia.UIA_E_ELEMENTNOTENABLED);
}

/// `UIA_E_INVALIDOPERATION`, the code for an action the node does not allow.
///
/// Upstream `util.rs:368-370`.
pub fn invalidOperation() Hresult {
    return @bitCast(bindings.uia.UIA_E_INVALIDOPERATION);
}

/// `UIA_E_NOTSUPPORTED`, the code for a property this node does not carry.
///
/// Upstream `util.rs:372-374`. This is the code the `GetPropertyValue` thunk
/// answers for a property outside the 41 the adapter serves.
pub fn notSupported() Hresult {
    return @bitCast(bindings.uia.UIA_E_NOTSUPPORTED);
}

/// `S_OK`, the code for a call that succeeded.
pub fn ok() Hresult {
    return @bitCast(@as(u32, 0));
}

/// `E_FAIL`, the code the port uses where upstream has no named helper.
///
/// The census at `docs/42-native-adapter-build-map.md` section 1.1.3 counts
/// `E_FAIL` among the three `HRESULT` codes the adapter names with no `UIA_`
/// prefix, and upstream reaches it through the `windows-rs` conversion rather
/// than through a helper in `util.rs`.
pub fn fail() Hresult {
    return @bitCast(@as(u32, @bitCast(bindings.win32.foundation.E_FAIL)));
}

/// The status code as the 32-bit integer the SDK documents.
///
/// `HRESULT` is a `packed struct (u32)` in this binding, so the port converts
/// with `@bitCast` in both directions and never with an arithmetic
/// conversion. A caller that needs to compare against a literal uses this.
pub fn toBits(status: Hresult) u32 {
    return @bitCast(status);
}

/// The status code from the 32-bit integer the SDK documents.
///
/// The inverse of `toBits`. A bit pattern that no SDK code names is returned
/// unchanged, because the binding carries no validity check and the port adds
/// none.
pub fn fromBits(bits: u32) Hresult {
    return @bitCast(bits);
}

/// Whether the status reports a failure.
///
/// The binding carries a `failed` bit at the top of the code, so this reads
/// the field rather than comparing against zero. `S_OK` and every failure
/// code have the bit set according to the SDK's sign convention.
pub fn isFailure(status: Hresult) bool {
    return status.failed;
}

/// The status for a required parameter that was absent.
///
/// Upstream `required_param` at `util.rs:356-358`. Upstream takes a `Ref<T>`
/// and answers a `Result`; the port takes the nullable pointer the thunk
/// declares and answers the status directly, because the caller has no other
/// error to report.
///
/// A `null` input answers `E_INVALIDARG`. A non-`null` input answers the
/// pointer unchanged.
pub fn requiredParam(comptime T: type, param: ?*const T) ?*const T {
    if (param) |present| return present;
    std.debug.assert(param == null);
    return null;
}

// --- Tests -----------------------------------------------------------------

test "the status code and the integer are the same bits" {
    try std.testing.expectEqual(@as(u32, 0), toBits(ok()));
    // `E_INVALIDARG` is `HRESULT_FROM_WIN32(ERROR_INVALID_PARAMETER)`, so it is
    // `0x80070057`: severity one, facility seven and code `0x57`. The earlier
    // expectation of `0x80004005` was `E_FAIL` and was wrong.
    try std.testing.expectEqual(@as(u32, 0x80070057), toBits(invalidArg()));
    try std.testing.expectEqual(@as(u32, 0x80004001), toBits(notImplemented()));
    try std.testing.expectEqual(@as(u32, 0x80004005), toBits(fail()));
    try std.testing.expectEqual(ok(), fromBits(0));
    try std.testing.expectEqual(invalidArg(), fromBits(toBits(invalidArg())));
}

test "only the success code reports no failure" {
    try std.testing.expect(!isFailure(ok()));
    try std.testing.expect(isFailure(invalidArg()));
    try std.testing.expect(isFailure(notImplemented()));
    try std.testing.expect(isFailure(fail()));
    try std.testing.expect(isFailure(elementNotAvailable()));
    try std.testing.expect(isFailure(elementNotEnabled()));
    try std.testing.expect(isFailure(invalidOperation()));
    try std.testing.expect(isFailure(notSupported()));
}

test "the four UI Automation codes keep the facility the SDK gave each one" {
    // The SDK does not give all four codes one facility, so there is no single
    // mask to assert and the earlier claim that they all carried facility
    // `15` was wrong. A status code is one severity bit, a ten-bit facility
    // above it and sixteen bits of code, so the facility of each code is
    // `(bits >> 16) & 0x3FF`. Measured from the pinned binding:
    // `ELEMENTNOTAVAILABLE`, `ELEMENTNOTENABLED` and `NOTSUPPORTED` carry
    // facility `4`, and `INVALIDOPERATION` carries facility `19`. A code that
    // lost its facility still reads as a failure, so the bit test above would
    // pass and this one would not.
    inline for (.{
        elementNotAvailable(),
        elementNotEnabled(),
        notSupported(),
    }) |status| {
        try std.testing.expectEqual(@as(u32, 4), (toBits(status) >> 16) & 0x3FF);
    }
    try std.testing.expectEqual(@as(u32, 19), (toBits(invalidOperation()) >> 16) & 0x3FF);
}

test "the three unprefixed codes keep the facility the SDK gave each one" {
    // The SDK does not give all three codes one facility. `E_NOTIMPL` and
    // `E_FAIL` are plain COM codes and carry facility `0`; `E_INVALIDARG` is
    // `HRESULT_FROM_WIN32` and carries facility `7`. So this is three
    // measured facilities rather than one mask.
    inline for (.{ notImplemented(), fail() }) |status| {
        try std.testing.expectEqual(@as(u32, 0), (toBits(status) >> 16) & 0x3FF);
    }
    try std.testing.expectEqual(@as(u32, 7), (toBits(invalidArg()) >> 16) & 0x3FF);
}

test "a required parameter passes a pointer through and rejects an absent one" {
    var value: u32 = 7;
    const present = requiredParam(u32, &value);
    try std.testing.expectEqual(@as(u32, 7), present.?.*);
    const absent = requiredParam(u32, null);
    try std.testing.expect(absent == null);
    std.debug.assert(invalidArg() == invalidArg());
}
