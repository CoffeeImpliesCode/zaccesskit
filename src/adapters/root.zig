//! Native platform adapters. Each platform owns its construction, callback,
//! update, and teardown contracts; importing this namespace does not activate one.

const std = @import("std");

pub const atspi = @import("atspi/root.zig");
pub const windows = @import("windows/root.zig");
pub const macos = @import("macos/root.zig");
pub const android = @import("android/root.zig");
pub const ios = @import("ios/root.zig");

test "platform adapter declarations are analysed" {
    std.testing.refAllDecls(atspi);
    std.testing.refAllDecls(windows);
    std.testing.refAllDecls(macos);
    std.testing.refAllDecls(android);
    std.testing.refAllDecls(ios);
}
