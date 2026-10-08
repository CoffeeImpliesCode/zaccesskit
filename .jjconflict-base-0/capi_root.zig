//! The C library root stays above `src/` so every relative import remains in the package.
const capi = @import("src/capi/root.zig");

// Export-bearing modules must be analysed outside the test runner too.
comptime {
    _ = capi;
    _ = capi.node;
    _ = capi.node_properties;
    _ = capi.geometry;
    _ = capi.tree_info;
    _ = capi.action_request;
    _ = capi.platform;
    _ = capi.tree_update;
}
