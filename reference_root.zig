const std = @import("std");
const schema = @import("src/schema/root.zig");
const consumer = @import("src/consumer/root.zig");
const cgeometry = @import("src/capi/geometry.zig");
const affine = @import("src/schema/geometry/affine.zig");
extern fn accesskit_affine_mul(schema.Affine, schema.Affine) callconv(.c) schema.Affine;
extern fn accesskit_affine_inverse(schema.Affine) callconv(.c) schema.Affine;
extern fn accesskit_affine_transform_point(schema.Affine, schema.Point) callconv(.c) schema.Point;
extern fn accesskit_affine_transform_rect_bbox(schema.Affine, schema.Rect) callconv(.c) schema.Rect;
extern fn accesskit_rect_abs(?*const schema.Rect) callconv(.c) schema.Rect;
extern fn accesskit_rect_contains(?*const schema.Rect, schema.Point) callconv(.c) bool;

comptime {
    _ = cgeometry;
}

pub const geometry_body = @embedFile("test/fixtures/geometry.json");
pub const text_body = @embedFile("test/fixtures/text.json");
const fixture_count = 2;
pub const fixture_bodies: [fixture_count][]const u8 = .{ geometry_body, text_body };
const manifest_body = @embedFile("test/fixtures/manifest.json");
const source_commit = "466e24e252103f4d82bd6fbab98141b551e46e0c";
const max_fixture_cases = 16;
const max_text_runs = 8;
const max_contains_points = 8;
const max_character_indices = 16;
const max_case_name_bytes = 96;

pub const VerificationError = error{
    OutOfMemory,
    InvalidFixture,
    LengthMismatch,
    HashMismatch,
    CaseBoundExhausted,
    OutputMismatch,
};
pub const ManifestEntry = struct {
    path: []const u8,
    byte_length: usize,
    sha256: []const u8,
    case_count: usize,
};
const Manifest = struct {
    source_commit: []const u8,
    oracle_scope: []const u8,
    fixtures: [fixture_count]ManifestEntry,
};
const GeometryCase = struct {
    name: []const u8,
    source_commit: []const u8,
    source: []const u8,
    oracle_kind: []const u8,
    claim: []const u8,
    operation: enum {
        compose,
        inverse,
        @"inverse-nan",
        @"rect-envelope",
        @"rect-abs",
        @"rect-contains",
    },
    left: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    right: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    expected: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    reverse_expected: [6]f64 = .{ 1, 0, 0, 1, 0, 0 },
    point: [2]f64 = .{ 0, 0 },
    point_expected: [2]f64 = .{ 0, 0 },
    return_expected: [2]f64 = .{ 0, 0 },
    rect: [4]f64 = .{ 0, 0, 0, 0 },
    rect_expected: [4]f64 = .{ 0, 0, 0, 0 },
    points: []const [2]f64 = &.{},
    contains_expected: []const bool = &.{},
    nan_expected: [6]bool = .{false} ** 6,
};
const GeometryFixture = struct { cases: []const GeometryCase };
const Run = struct { id: u64, value: []const u8, character_lengths: []const u8 };
const TextCase = struct {
    name: []const u8,
    source_commit: []const u8,
    source: []const u8,
    oracle_kind: []const u8,
    claim: []const u8,
    operation: enum { document, character, boundary, range, selection, stale },
    encoding: enum { usv, utf16 } = .usv,
    expected_text: []const u8 = "",
    indices: []const usize = &.{},
    usv: usize = 0,
    utf16: usize = 0,
    raw_expected: [2]u64 = .{ 0, 0 },
    start: [2]u64 = .{ 0, 0 },
    end: [2]u64 = .{ 0, 0 },
    anchor_expected: [2]u64 = .{ 0, 0 },
    focus_expected: [2]u64 = .{ 0, 0 },
    removed_run: u64 = 0,
    upgrade_expected: bool = false,
};
const TextFixture = struct { runs: []const Run, cases: []const TextCase };
const VerifiedCase = struct {
    name: [max_case_name_bytes]u8 = undefined,
    name_length: usize = 0,
    fixture_index: usize,
};
const Receipt = struct { byte_length: usize, digest: [32]u8, case_count: usize };
pub const Report = struct {
    cases: [max_fixture_cases]VerifiedCase = undefined,
    case_count: usize = 0,
    fixtures: [fixture_count]Receipt = undefined,
};

fn parse(comptime T: type, gpa: std.mem.Allocator, body: []const u8) VerificationError!std.json.Parsed(T) {
    return std.json.parseFromSlice(T, gpa, body, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidFixture,
    };
}

fn parseFixture(comptime T: type, gpa: std.mem.Allocator, body: []const u8) VerificationError!std.json.Parsed(T) {
    const parsed = try parse(T, gpa, body);
    errdefer parsed.deinit();
    if (parsed.value.cases.len > max_fixture_cases) return error.CaseBoundExhausted;
    if (parsed.value.cases.len == 0) return error.InvalidFixture;
    return parsed;
}

pub fn checkBody(entry: ManifestEntry, body: []const u8) VerificationError!void {
    if (body.len != entry.byte_length) return error.LengthMismatch;
    if (entry.sha256.len != 64) return error.InvalidFixture;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, entry.sha256)) return error.HashMismatch;
}

fn require(ok: bool) VerificationError!void {
    if (!ok) return error.OutputMismatch;
}

fn checkProvenance(case: anytype) VerificationError!void {
    if (!std.mem.eql(u8, case.source_commit, source_commit)) return error.InvalidFixture;
    if (case.name.len == 0 or case.name.len > max_case_name_bytes) return error.InvalidFixture;
    if (std.mem.indexOfScalar(u8, case.source, ':') == null) return error.InvalidFixture;
    if (std.mem.eql(u8, case.oracle_kind, "handcomputed-from-pinned-formula")) {
        if (!std.mem.startsWith(u8, case.claim, "[INFERENCE]")) return error.InvalidFixture;
    } else if (!std.mem.eql(u8, case.oracle_kind, "hand-transcribed-source-test")) {
        return error.InvalidFixture;
    }
}

fn record(report: *Report, name: []const u8, fixture_index: usize) VerificationError!void {
    if (report.case_count == max_fixture_cases) return error.CaseBoundExhausted;
    var verified: VerifiedCase = .{ .fixture_index = fixture_index };
    @memcpy(verified.name[0..name.len], name);
    verified.name_length = name.len;
    report.cases[report.case_count] = verified;
    report.case_count += 1;
}

pub fn testCaseBound(gpa: std.mem.Allocator) VerificationError!void {
    const item = "{\"name\":\"x\",\"source_commit\":\"x\",\"source\":\"x\",\"oracle_kind\":\"x\",\"claim\":\"x\",\"operation\":\"compose\"}";
    const body = "{\"cases\":[" ++ (item ++ ",") ** max_fixture_cases ++ item ++ "]}";
    const parsed = try parseFixture(GeometryFixture, gpa, body);
    defer parsed.deinit();
}

pub fn testMalformedFixture(gpa: std.mem.Allocator) VerificationError!void {
    const parsed = try parseFixture(GeometryFixture, gpa, "{\"cases\":[");
    defer parsed.deinit();
}

test {
    _ = @import("test/reference_cases.zig");
}

fn rectValue(value: [4]f64) schema.Rect {
    return .{ .x0 = value[0], .y0 = value[1], .x1 = value[2], .y1 = value[3] };
}

fn checkRect(expected: [4]f64, actual: schema.Rect) VerificationError!void {
    try require(expected[0] == actual.x0);
    try require(expected[1] == actual.y0);
    try require(expected[2] == actual.x1);
    try require(expected[3] == actual.y1);
}

fn checkPoint(expected: [2]f64, actual: schema.Point) VerificationError!void {
    try require(expected[0] == actual.x);
    try require(expected[1] == actual.y);
}

fn checkCoefficients(expected: [6]f64, actual: schema.Affine) VerificationError!void {
    for (expected, actual.coeffs) |want, got| try require(want == got);
}

fn checkNanCoefficients(
    case: GeometryCase,
    actual: schema.Affine,
    api: []const u8,
) VerificationError!void {
    for (case.nan_expected, actual.coeffs, 0..) |want, got, index| {
        if (want != std.math.isNan(got)) {
            std.debug.print(
                "FAIL fixture=test/fixtures/geometry.json case={s} api={s} " ++
                    "coefficient-index={d} expected-nan={} actual={d}\n",
                .{ case.name, api, index, want, got },
            );
            return error.OutputMismatch;
        }
    }
}

fn checkContains(
    case: GeometryCase,
    index: usize,
    actual: bool,
    api: []const u8,
) VerificationError!void {
    const expected = case.contains_expected[index];
    if (expected != actual) {
        std.debug.print(
            "FAIL fixture=test/fixtures/geometry.json case={s} api={s} " ++
                "point-index={d} point=({d},{d}) expected={} actual={}\n",
            .{
                case.name,
                api,
                index,
                case.points[index][0],
                case.points[index][1],
                expected,
                actual,
            },
        );
        return error.OutputMismatch;
    }
}

fn verifyGeometry(case: GeometryCase) VerificationError!void {
    const left: schema.Affine = .{ .coeffs = case.left };
    const right: schema.Affine = .{ .coeffs = case.right };
    const point: schema.Point = .{ .x = case.point[0], .y = case.point[1] };
    const rect = rectValue(case.rect);
    switch (case.operation) {
        .compose => {
            try checkCoefficients(case.expected, affine.mul(left, right));
            try checkCoefficients(case.reverse_expected, affine.mul(right, left));
            try checkCoefficients(case.expected, accesskit_affine_mul(left, right));
            try checkCoefficients(case.reverse_expected, accesskit_affine_mul(right, left));
        },
        .inverse => {
            const inverse = affine.inverse(left);
            const transformed = affine.mulPoint(left, point);
            try checkCoefficients(case.expected, inverse);
            try checkPoint(case.point_expected, transformed);
            try checkPoint(case.return_expected, affine.mulPoint(inverse, transformed));
            const c_inverse = accesskit_affine_inverse(left);
            const c_point = accesskit_affine_transform_point(left, point);
            try checkCoefficients(case.expected, c_inverse);
            try checkPoint(case.point_expected, c_point);
            try checkPoint(case.return_expected, accesskit_affine_transform_point(c_inverse, c_point));
        },
        .@"inverse-nan" => {
            try checkNanCoefficients(case, affine.inverse(left), "schema");
            try checkNanCoefficients(case, accesskit_affine_inverse(left), "c");
        },
        .@"rect-envelope" => {
            try checkRect(case.rect_expected, affine.transformRectBbox(left, rect));
            try checkRect(case.rect_expected, accesskit_affine_transform_rect_bbox(left, rect));
        },
        .@"rect-abs" => {
            try checkRect(case.rect_expected, rect.abs());
            try checkRect(case.rect_expected, accesskit_rect_abs(&rect));
        },
        .@"rect-contains" => {
            if (case.points.len > max_contains_points) return error.CaseBoundExhausted;
            if (case.points.len == 0 or
                case.points.len != case.contains_expected.len) return error.InvalidFixture;
            for (case.points, 0..) |coordinates, index| {
                const probe: schema.Point = .{ .x = coordinates[0], .y = coordinates[1] };
                try checkContains(case, index, rect.contains(probe), "schema");
                try checkContains(case, index, accesskit_rect_contains(&rect, probe), "c");
            }
        },
    }
}

pub fn testWrongOutput(gpa: std.mem.Allocator) VerificationError!void {
    const parsed = try parseFixture(GeometryFixture, gpa, geometry_body);
    defer parsed.deinit();
    var altered = parsed.value.cases[0];
    altered.expected[0] += 1;
    try verifyGeometry(altered);
}

pub fn testWrongContainmentOutput(gpa: std.mem.Allocator) VerificationError!void {
    const parsed = try parseFixture(GeometryFixture, gpa, geometry_body);
    defer parsed.deinit();
    for (parsed.value.cases) |case| {
        if (case.operation != .@"rect-contains") continue;
        if (case.contains_expected.len == 0 or
            case.contains_expected.len > max_contains_points) return error.InvalidFixture;
        var expected: [max_contains_points]bool = undefined;
        @memcpy(expected[0..case.contains_expected.len], case.contains_expected);
        expected[case.contains_expected.len - 1] = !expected[case.contains_expected.len - 1];
        var altered = case;
        altered.contains_expected = expected[0..case.contains_expected.len];
        return verifyGeometry(altered);
    }
    return error.InvalidFixture;
}

pub fn testWrongNanOutput(gpa: std.mem.Allocator) VerificationError!void {
    const parsed = try parseFixture(GeometryFixture, gpa, geometry_body);
    defer parsed.deinit();
    for (parsed.value.cases) |case| {
        if (case.operation != .@"inverse-nan") continue;
        var altered = case;
        altered.nan_expected[5] = !altered.nan_expected[5];
        return verifyGeometry(altered);
    }
    return error.InvalidFixture;
}

const query = consumer.text.query;
const position = consumer.text.position;
const ranges = consumer.text.range;

fn productionError(err: anytype) VerificationError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.OutputMismatch,
    };
}

fn makeContainer(
    gpa: std.mem.Allocator,
    role: schema.Role,
    children: []const schema.NodeId,
    selection: ?schema.TextSelection,
) VerificationError!schema.Node {
    var node = schema.Node.init(gpa, role);
    errdefer node.deinit();
    try schema.ids_props.setChildren(&node.properties, children);
    if (selection) |value| try schema.option.setTextSelection(&node.properties, value);
    return node;
}

fn makeRun(gpa: std.mem.Allocator, spec: Run) VerificationError!schema.Node {
    var node = schema.Node.init(gpa, .text_run);
    errdefer node.deinit();
    try schema.strings.setValue(&node.properties, spec.value);
    try schema.vectors.setCharacterLengths(&node.properties, spec.character_lengths);
    return node;
}

fn buildTree(
    gpa: std.mem.Allocator,
    fixture: TextFixture,
    selection: ?schema.TextSelection,
) VerificationError!consumer.tree.Tree {
    if (fixture.runs.len != max_text_runs) return error.InvalidFixture;
    var children: [max_text_runs]schema.NodeId = undefined;
    for (fixture.runs, &children) |run, *child| {
        child.* = .{ .value = run.id };
    }
    var update: schema.TreeUpdate = .{};
    var transferred = false;
    defer if (!transferred) update.deinit(gpa);
    const root = try makeContainer(gpa, .window, &.{.{ .value = 1 }}, null);
    try update.pushNode(gpa, .{ .value = 0 }, root);
    const document = try makeContainer(gpa, .multiline_text_input, &children, selection);
    try update.pushNode(gpa, .{ .value = 1 }, document);
    for (fixture.runs) |run| {
        const node = try makeRun(gpa, run);
        try update.pushNode(gpa, .{ .value = run.id }, node);
    }
    update.tree = schema.TreeInfo.init(.{ .value = 0 });
    update.focus = .{ .value = 1 };
    transferred = true;
    return consumer.tree.Tree.init(gpa, update, true) catch |err| return productionError(err);
}

fn weakPosition(value: [2]u64) schema.TextPosition {
    return .{ .node_id = .{ .value = value[0] }, .character_index = @intCast(value[1]) };
}

fn checkRawPosition(expected: [2]u64, actual: position.Position) VerificationError!void {
    const raw = position.toRaw(actual);
    try require(raw.node_id.value == expected[0]);
    try require(raw.character_index == expected[1]);
}

fn exactText(
    gpa: std.mem.Allocator,
    expected: []const u8,
    actual: ranges.Range,
) VerificationError!void {
    var text = ranges.text(gpa, actual) catch |err| return productionError(err);
    defer text.deinit(gpa);
    try require(std.mem.eql(u8, expected, text.items));
}

fn exactRange(
    gpa: std.mem.Allocator,
    tree: *const consumer.tree.Tree,
    case: TextCase,
) VerificationError!ranges.Range {
    const state = tree.stateOf();
    const node = state.nodeByTreeLocalId(.{ .value = 1 }, schema.tree_id_root) orelse
        return error.OutputMismatch;
    const first = state.nodeByTreeLocalId(.{ .value = case.start[0] }, schema.tree_id_root) orelse
        return error.OutputMismatch;
    const last = state.nodeByTreeLocalId(.{ .value = case.end[0] }, schema.tree_id_root) orelse
        return error.OutputMismatch;
    return ranges.init(
        gpa,
        node,
        .{ .node = first, .character_index = @intCast(case.start[1]) },
        .{ .node = last, .character_index = @intCast(case.end[1]) },
    ) catch |err| return productionError(err);
}

fn verifyText(gpa: std.mem.Allocator, fixture: TextFixture, case: TextCase) VerificationError!void {
    if (case.indices.len > max_character_indices) return error.CaseBoundExhausted;
    const selected: ?schema.TextSelection = if (case.operation == .selection)
        .{ .anchor = weakPosition(case.start), .focus = weakPosition(case.end) }
    else
        null;
    var tree = try buildTree(gpa, fixture, selected);
    defer tree.deinit();
    const node = tree.stateOf().nodeByTreeLocalId(.{ .value = 1 }, schema.tree_id_root) orelse
        return error.OutputMismatch;
    try require(query.supportsTextRanges(node) catch return error.OutputMismatch);
    switch (case.operation) {
        .document => {
            const whole = query.documentRange(gpa, node) catch |err| return productionError(err);
            try exactText(gpa, case.expected_text, whole);
            const start: position.Position = .{ .root_node = node, .inner = whole.start };
            const end: position.Position = .{ .root_node = node, .inner = whole.end };
            try require((position.toGlobalUsvIndex(start) catch return error.OutputMismatch) == 0);
            try require((position.toGlobalUtf16Index(start) catch return error.OutputMismatch) == 0);
            try require((position.toGlobalUsvIndex(end) catch return error.OutputMismatch) == case.usv);
            try require((position.toGlobalUtf16Index(end) catch return error.OutputMismatch) == case.utf16);
        },
        .character => {
            if (case.indices.len == 0) return error.InvalidFixture;
            for (case.indices) |index| {
                const found = (if (case.encoding == .usv)
                    query.textPositionFromGlobalUsvIndex(node, index)
                else
                    query.textPositionFromGlobalUtf16Index(node, index)) catch return error.OutputMismatch;
                const start = found orelse return error.OutputMismatch;
                try checkRawPosition(case.raw_expected, start);
                try require((position.toGlobalUsvIndex(start) catch
                    return error.OutputMismatch) == case.usv);
                try require((position.toGlobalUtf16Index(start) catch
                    return error.OutputMismatch) == case.utf16);
                const end = position.forwardToCharacterEnd(start) catch return error.OutputMismatch;
                const character = ranges.init(gpa, node, start.inner, end.inner) catch |err|
                    return productionError(err);
                try exactText(gpa, case.expected_text, character);
            }
        },
        .boundary => {
            const usv_end = (query.textPositionFromGlobalUsvIndex(node, case.usv) catch
                return error.OutputMismatch) orelse return error.OutputMismatch;
            const utf16_end = (query.textPositionFromGlobalUtf16Index(node, case.utf16) catch
                return error.OutputMismatch) orelse return error.OutputMismatch;
            try require(position.isDocumentEnd(usv_end) catch return error.OutputMismatch);
            try require(position.isDocumentEnd(utf16_end) catch return error.OutputMismatch);
            try require((query.textPositionFromGlobalUsvIndex(node, case.usv + 1) catch
                return error.OutputMismatch) == null);
            try require((query.textPositionFromGlobalUtf16Index(node, case.utf16 + 1) catch
                return error.OutputMismatch) == null);
        },
        .range => try exactText(gpa, case.expected_text, try exactRange(gpa, &tree, case)),
        .selection => {
            const selection = (query.textSelection(gpa, node) catch |err| return productionError(err)) orelse
                return error.OutputMismatch;
            try exactText(gpa, case.expected_text, selection);
            try checkRawPosition(case.anchor_expected, query.textSelectionAnchor(node) orelse
                return error.OutputMismatch);
            try checkRawPosition(case.focus_expected, query.textSelectionFocus(node) orelse
                return error.OutputMismatch);
        },
        .stale => {
            const original = try exactRange(gpa, &tree, case);
            try exactText(gpa, case.expected_text, original);
            var weak = ranges.downgrade(gpa, original) catch |err| return productionError(err);
            defer weak.deinit();
            try require((query.upgrade(weak, tree.stateOf()) catch return error.OutputMismatch) != null);
            var children: [max_text_runs]schema.NodeId = undefined;
            var child_count: usize = 0;
            for (fixture.runs) |run| {
                if (run.id == case.removed_run) continue;
                children[child_count] = .{ .value = run.id };
                child_count += 1;
            }
            var update: schema.TreeUpdate = .{};
            var transferred = false;
            defer if (!transferred) update.deinit(gpa);
            const document = try makeContainer(
                gpa,
                .multiline_text_input,
                children[0..child_count],
                null,
            );
            try update.pushNode(gpa, .{ .value = 1 }, document);
            update.focus = .{ .value = 1 };
            var context: u8 = 0;
            const handler: consumer.tree.TreeChangeHandler = .{ .ptr = &context };
            transferred = true;
            tree.updateAndProcessChanges(update, &handler) catch |err| return productionError(err);
            const committed = tree.stateOf();
            try require(committed.nodeByTreeLocalId(
                .{ .value = case.removed_run },
                schema.tree_id_root,
            ) == null);
            const upgraded = query.upgrade(weak, committed) catch return error.OutputMismatch;
            try require((upgraded != null) == case.upgrade_expected);
        },
    }
}

pub fn runVerification(
    gpa: std.mem.Allocator,
    bodies: [fixture_count][]const u8,
) VerificationError!Report {
    const manifest = try parse(Manifest, gpa, manifest_body);
    defer manifest.deinit();
    if (!std.mem.eql(u8, manifest.value.source_commit, source_commit)) return error.InvalidFixture;
    var report: Report = .{};
    for (manifest.value.fixtures, bodies, 0..) |entry, body, index| {
        const expected_path = if (index == 0) "test/fixtures/geometry.json" else "test/fixtures/text.json";
        if (!std.mem.eql(u8, entry.path, expected_path)) return error.InvalidFixture;
        try checkBody(entry, body);
        if (entry.case_count > max_fixture_cases) return error.CaseBoundExhausted;
        report.fixtures[index] = .{
            .byte_length = body.len,
            .digest = undefined,
            .case_count = entry.case_count,
        };
        std.crypto.hash.sha2.Sha256.hash(body, &report.fixtures[index].digest, .{});
    }
    const geometry = try parseFixture(GeometryFixture, gpa, bodies[0]);
    defer geometry.deinit();
    const text = try parseFixture(TextFixture, gpa, bodies[1]);
    defer text.deinit();
    if (geometry.value.cases.len != report.fixtures[0].case_count or
        text.value.cases.len != report.fixtures[1].case_count) return error.InvalidFixture;
    for (geometry.value.cases) |case| {
        try checkProvenance(case);
        try verifyGeometry(case);
        try record(&report, case.name, 0);
    }
    for (text.value.cases) |case| {
        try checkProvenance(case);
        try verifyText(gpa, text.value, case);
        try record(&report, case.name, 1);
    }
    return report;
}

const MainError = VerificationError || std.Io.Writer.Error;

pub fn main(init: std.process.Init) MainError!void {
    const report = try runVerification(init.gpa, fixture_bodies);
    var buffer: [4096]u8 = undefined;
    var file_writer = std.Io.File.stdout().writer(init.io, &buffer);
    const writer = &file_writer.interface;
    const paths: [fixture_count][]const u8 = .{
        "test/fixtures/geometry.json",
        "test/fixtures/text.json",
    };
    for (report.fixtures, paths) |receipt, path| {
        const hex = std.fmt.bytesToHex(receipt.digest, .lower);
        try writer.print(
            "PASS fixture={s} bytes={d} sha256={s} cases={d}\n",
            .{ path, receipt.byte_length, hex, receipt.case_count },
        );
    }
    for (report.cases[0..report.case_count]) |case| {
        try writer.print(
            "PASS fixture={s} case={s} actual-output=exact\n",
            .{ paths[case.fixture_index], case.name[0..case.name_length] },
        );
    }
    try writer.print(
        "PASS source-derived-cases={d} reference-runtime=not-executed " ++
            "wire-parity=not-claimed\n",
        .{report.case_count},
    );
    try writer.flush();
}
