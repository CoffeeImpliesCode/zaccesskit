//! Native platform adapters. Each platform owns its construction, callback,
//! update, and teardown contracts; importing this namespace does not activate one.

const std = @import("std");
const builtin = @import("builtin");

pub const atspi = @import("atspi/root.zig");
pub const windows = @import("windows/root.zig");
pub const macos = @import("macos/root.zig");
pub const android = @import("android/root.zig");
pub const ios = @import("ios/root.zig");

test "platform adapter declarations are analysed" {
    std.testing.refAllDecls(atspi);
    // Zig 0.16 only resolves `callconv(.winapi)` on x86_64.
    if (comptime builtin.cpu.arch == .x86_64) {
        std.testing.refAllDecls(windows);
    }
    std.testing.refAllDecls(macos);
    std.testing.refAllDecls(android);
    std.testing.refAllDecls(ios);
}
