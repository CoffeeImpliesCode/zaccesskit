test "failure name and owned C request roots" {
    _ = @import("src/capi/allocation.zig");
    _ = @import("src/capi/boundary.zig");
    _ = @import("src/capi/action_request.zig");
}
