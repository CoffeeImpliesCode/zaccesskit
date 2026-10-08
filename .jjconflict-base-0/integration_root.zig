//! Package-root entry point for pure application integration tests and the standalone scenario.
const std = @import("std");

pub const application = @import("test/integration/consumer_roundtrip.zig");

pub fn main(init: std.process.Init) application.ScenarioError!void {
    try application.runScenario(init.gpa);
}

test {
    _ = application;
}
