const std = @import("std");
const reference = @import("../reference_root.zig");

test "all pinned-source geometry and consumer text cases match actual outputs" {
    const report = try reference.runVerification(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 12), report.case_count);
}

test "fixture loader rejects corrupt and truncated raw bytes before parsing" {
    const bodies = [2][]const u8{ reference.geometry_body, reference.text_body };
    for (bodies, 0..) |body, fixture_index| {
        const entry = try reference.fixtureManifest(std.testing.allocator, fixture_index);
        const corrupted = try std.testing.allocator.dupe(u8, body);
        defer std.testing.allocator.free(corrupted);
        corrupted[0] ^= 1;
        try std.testing.expectError(error.HashMismatch, reference.checkBody(entry, corrupted));
        try std.testing.expectError(error.LengthMismatch, reference.checkBody(entry, body[0 .. body.len - 1]));
    }
}

test "fixture parsing releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, verifyAllocationFailures, .{});
}

fn verifyAllocationFailures(gpa: std.mem.Allocator) !void {
    _ = try reference.runVerification(gpa);
}

test "fixture parsing rejects a case count beyond the named bound" {
    try std.testing.expectError(error.CaseBoundExhausted, reference.testCaseBound(std.testing.allocator));
}

test "fixture parser reports malformed JSON within its closed error set" {
    try std.testing.expectError(error.InvalidFixture, reference.testMalformedFixture(std.testing.allocator));
}

test "wrong expected geometry output is not an oracle echo" {
    try std.testing.expectError(error.OutputMismatch, reference.testWrongOutput(std.testing.allocator));
}
