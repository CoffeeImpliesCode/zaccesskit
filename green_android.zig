comptime {
    _ = @import("src/capi/root.zig");
    _ = @import("src/adapters/android/adapter.zig");
    _ = @import("src/adapters/android/queued_events.zig");
    _ = @import("src/adapters/android/java_call.zig");
    _ = @import("src/adapters/android/classes.zig");
    _ = @import("src/adapters/android/methods.zig");
    _ = @import("src/adapters/android/injecting.zig");
    _ = @import("src/adapters/android/root.zig");
}
