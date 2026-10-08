test "disabled accessibility consumes and acquisition releases regression roots" {
    _ = @import("src/adapters/android/queued_events.zig");
    _ = @import("src/adapters/android/java_call.zig");
}
