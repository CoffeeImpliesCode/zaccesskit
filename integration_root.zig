//! Package-root entry point for pure application integration tests and the standalone scenario.
const std = @import("std");

pub const schema = @import("src/schema/root.zig");
pub const consumer = @import("src/consumer/root.zig");
pub const atspi_node = @import("src/adapters/atspi/node.zig");
pub const atspi_context = @import("src/adapters/atspi/app_context.zig");
pub const application = @import("test/integration/consumer_roundtrip.zig");

pub fn main(init: std.process.Init) application.ScenarioError!void {
    try application.runScenario(init.gpa);
}

test {
    _ = application;
}
