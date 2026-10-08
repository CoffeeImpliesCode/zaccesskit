const std = @import("std");
const reference = @import("../reference_root.zig");

test "all pinned-source geometry and consumer text cases match actual outputs" {
    const report = try reference.runVerification(std.testing.allocator, reference.fixture_bodies);
    try std.testing.expectEqual(@as(usize, 15), report.case_count);
}

test "verification rejects malformed corrupt raw bytes before parsing" {
    for (reference.fixture_bodies, 0..) |body, fixture_index| {
        const corrupted = try std.testing.allocator.dupe(u8, body);
        defer std.testing.allocator.free(corrupted);
        corrupted[0] = 0xff;
        var bodies = reference.fixture_bodies;
        bodies[fixture_index] = corrupted;
        try std.testing.expectError(
            error.HashMismatch,
            reference.runVerification(std.testing.allocator, bodies),
        );
    }
}

test "verification rejects malformed truncated raw bytes before parsing" {
    for (reference.fixture_bodies, 0..) |body, fixture_index| {
        const closing_brace = std.mem.lastIndexOfScalar(u8, body, '}').?;
        var bodies = reference.fixture_bodies;
        bodies[fixture_index] = body[0..closing_brace];
        try std.testing.expectError(
            error.LengthMismatch,
            reference.runVerification(std.testing.allocator, bodies),
        );
    }
}

test "complete verification releases every partial allocation" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, verifyAllocationFailures, .{});
}

fn verifyAllocationFailures(gpa: std.mem.Allocator) reference.VerificationError!void {
    _ = try reference.runVerification(gpa, reference.fixture_bodies);
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

test "wrong expected far-edge containment is not an oracle echo" {
    try std.testing.expectError(
        error.OutputMismatch,
        reference.testWrongContainmentOutput(std.testing.allocator),
    );
}

test "wrong expected final singular inverse coefficient is not an oracle echo" {
    try std.testing.expectError(
        error.OutputMismatch,
        reference.testWrongNanOutput(std.testing.allocator),
    );
}
