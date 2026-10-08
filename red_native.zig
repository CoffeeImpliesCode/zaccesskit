test "C rejected inactive delta C debug string uses the installed raw allocator" {
    const std = @import("std");
    std.testing.refAllDecls(@import("src/capi/root.zig"));
    _ = @import("src/adapters/atspi/root.zig");
}
