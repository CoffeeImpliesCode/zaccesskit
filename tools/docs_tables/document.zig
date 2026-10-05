//! Rewrites the generated tables inside `docs/36-consumer-call-graph.md` and
//! tells a reader which tables a tool wrote.
//!
//! **A generated table must be visible as one.** A reader cannot tell a table a
//! person wrote from a table a tool wrote by looking at the rows, and the two
//! carry different weight: a written one carries a judgement, a generated one
//! carries a measurement. So every table this tool owns sits between a pair of
//! named markers, the markers are visible in the raw file, and the section that
//! introduces the tables says which they are. A reader who distrusts the tool
//! deletes a marker pair and writes the table by hand, and the next run leaves it
//! alone.
//!
//! **Check by default, write only on request.** A plain run compares and exits
//! non-zero on a difference. Rewriting a document on a plain run is how a tool
//! destroys a human's edit without asking, and a generator nobody trusts is a
//! generator nobody runs. `--write` is the only path that touches the file.
//!
//! **A marker without its partner is a finding, not a silent pass.** An unclosed
//! region would make the next run compare the wrong bytes, so the run stops with
//! the line to look at.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The marker that opens a generated table for one module.
pub const begin_prefix = "<!-- docs-tables:begin ";

/// The marker that closes it.
pub const end_prefix = "<!-- docs-tables:end ";

/// What closes an HTML comment. It is comment syntax rather than part of the
/// module name the marker carries, so the parser drops it and the document
/// keeps writing a marker that is a real comment.
pub const comment_end = "-->";

/// One generated region: the module it names and the bytes between the markers.
pub const Region = struct {
    /// The module path the markers carry, with the comment terminator removed.
    /// `tree_index.zig` is what a reader sees in the marker line; the bytes
    /// after it belong to the comment, not to the key.
    key: []const u8,
    /// The bytes between the opening marker's newline and the closing marker's
    /// line start. It always ends in a newline when the table is well formed.
    body: []const u8,
    /// The line the opening marker is on, 1-based, for a finding.
    line: u32,
    /// The byte the opening marker starts at.
    at: usize,
    /// The byte the body starts at, which is the opening marker's line end.
    /// A rewrite replaces from here rather than from `at`, so the marker that
    /// named the table survives the write that fills it.
    body_at: usize,
    /// The byte the closing marker's line starts at.
    end_at: usize,
};

/// Something about the markers the run could not accept.
pub const Problem = struct {
    line: u32,
    message: []const u8,
};

/// The report one run produces about the document.
pub const Report = struct {
    gpa: Allocator,
    /// The regions the markers define, in document order.
    regions: []const Region = &.{},
    /// A marker without its partner.
    problems: std.ArrayList(Problem) = .empty,

    pub fn deinit(self: *Report) void {
        const gpa = self.gpa;
        self.problems.deinit(gpa);
        // SAFETY: the line above released the only list this report owns, and
        // the reset is what a stale read sees. `regions` is a slice the caller
        // owns, so the reset drops the borrow rather than releasing anything.
        self.* = .{ .gpa = gpa };
    }

    /// The region for `key`, or null when the document has no marker pair for
    /// it.
    pub fn find(self: *const Report, key: []const u8) ?Region {
        for (self.regions) |region| {
            if (std.mem.eql(u8, region.key, key)) return region;
        }
        return null;
    }
};

/// Reads the markers out of `source` and returns the regions between them.
pub fn parse(gpa: Allocator, source: []const u8) !Report {
    var report: Report = .{ .gpa = gpa, .regions = &.{} };
    var regions: std.ArrayList(Region) = .empty;
    errdefer regions.deinit(gpa);

    var cursor: usize = 0;
    while (std.mem.findPos(u8, source, cursor, begin_prefix)) |begin_at| {
        const after_begin = begin_at + begin_prefix.len;
        const key_end = std.mem.findScalarPos(u8, source, after_begin, '\n') orelse {
            try report.problems.append(gpa, .{
                .line = lineOf(source, begin_at),
                .message = "a begin marker has no newline after it",
            });
            break;
        };
        const key = markerKey(source[after_begin..key_end]);

        const body_start = key_end + 1;
        const end_at = findEndMarker(source, body_start, key) orelse {
            try report.problems.append(gpa, .{
                .line = lineOf(source, begin_at),
                .message = "a begin marker has no matching end marker",
            });
            break;
        };

        try regions.append(gpa, .{
            .key = key,
            .body = source[body_start..end_at],
            .line = lineOf(source, begin_at),
            .at = begin_at,
            .body_at = body_start,
            .end_at = end_at,
        });
        cursor = end_at + endMarkerLineLen(source, end_at);
    }

    report.regions = try regions.toOwnedSlice(gpa);
    return report;
}

/// The byte the closing marker for `key` starts at, or null when there is none.
fn findEndMarker(source: []const u8, from: usize, key: []const u8) ?usize {
    var cursor = from;
    while (std.mem.findPos(u8, source, cursor, end_prefix)) |at| {
        const after = at + end_prefix.len;
        const line_end = std.mem.findScalarPos(u8, source, after, '\n') orelse source.len;
        if (std.mem.eql(u8, markerKey(source[after..line_end]), key)) return lineStart(source, at);
        cursor = at + end_prefix.len;
    }
    return null;
}

/// The module path a marker line carries.
///
/// The prefix ends at the space before the name, and the name ends at the
/// comment terminator. A marker written `<!-- docs-tables:begin a.zig -->`
/// therefore names `a.zig`, and a line with no terminator names everything
/// after the prefix, which a later lookup reports rather than hides.
pub fn markerKey(line: []const u8) []const u8 {
    const trimmed = std.mem.trimEnd(u8, line, " \t\r");
    const without_end = if (std.mem.endsWith(u8, trimmed, comment_end))
        trimmed[0 .. trimmed.len - comment_end.len]
    else
        trimmed;
    return std.mem.trimEnd(u8, without_end, " \t\r");
}

/// The length of the closing marker line at `at`, its newline included.
fn endMarkerLineLen(source: []const u8, at: usize) usize {
    const newline = std.mem.indexOfScalarPos(u8, source, at, '\n') orelse source.len;
    return newline + 1 - at;
}

fn lineStart(source: []const u8, at: usize) usize {
    var start = at;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    return start;
}

fn lineOf(source: []const u8, at: usize) u32 {
    var line: u32 = 1;
    for (source[0..at]) |byte| {
        if (byte == '\n') line += 1;
    }
    return line;
}

/// Builds `source` with each region's body replaced.
///
/// `bodies` is one entry per region in document order. A null entry leaves that
/// region alone, which is the whole escape hatch: a person who deletes the
/// generated rows and writes their own keeps them, because the run was given
/// nothing to put back.
///
/// Returns null when nothing differs, so a caller can skip the write and leave
/// the file's modification time alone.
pub fn rewrite(
    gpa: Allocator,
    source: []const u8,
    regions: []const Region,
    bodies: []const ?[]const u8,
) !?[]u8 {
    if (regions.len != bodies.len) return error.BodyCountMismatch;

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;

    var cursor: usize = 0;
    for (regions, bodies) |region, body| {
        if (body) |text| {
            // The opening marker is part of the region but not part of the
            // body, so it is copied across rather than replaced. Replacing
            // from `region.at` drops the marker that named the table, and the
            // next run then reads no region at all and passes on a document
            // that has lost every table.
            try w.writeAll(source[cursor..region.body_at]);
            try w.writeAll(text);
            cursor = region.end_at;
        }
    }
    try w.writeAll(source[cursor..]);

    if (std.mem.eql(u8, out.written(), source)) {
        out.deinit();
        return null;
    }
    // `toOwnedSlice` answers `![]u8` and this function answers `!?[]u8`. A
    // plain `[]u8` coerces to `?[]u8`, but that coercion cannot happen inside
    // the payload of an error union, so the `try` comes first.
    const owned = try out.toOwnedSlice();
    return owned;
}

/// The two-column table one module's rows print.
///
/// `rows` is one string per declaring module, already formatted as
/// `` `A`, `B` | `path` ``. The header is part of the body, so a reader sees the
/// column names without reading the tool.
pub fn table(gpa: Allocator, rows: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    try out.writer.writeAll("| Symbol | Declared in |\n|---|---|\n");
    for (rows) |row| try out.writer.print("| {s} |\n", .{row});
    return out.toOwnedSlice();
}

const testing = std.testing;

test "a marker pair is one region, and the body is what is between it" {
    const source =
        \\# Title
        \\
        \\<!-- docs-tables:begin tree_index.zig -->
        \\| Symbol | Declared in |
        \\|---|---|
        \\<!-- docs-tables:end tree_index.zig -->
        \\
        \\After.
        \\
    ;
    const report = try parse(testing.allocator, source);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.regions.len);
    try testing.expectEqualStrings("tree_index.zig", report.regions[0].key);
    try testing.expectEqualStrings(
        "| Symbol | Declared in |\n|---|---|\n",
        report.regions[0].body,
    );
    try testing.expectEqual(@as(usize, 0), report.problems.items.len);
}

test "a begin marker with no partner is a finding, not a clean run" {
    // The alternative is a region that runs to the end of the file, so the next
    // run compares the whole document against a table.
    const source =
        \\<!-- docs-tables:begin tree_index.zig -->
        \\| Symbol | Declared in |
    ;
    const report = try parse(testing.allocator, source);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 0), report.regions.len);
    try testing.expectEqual(@as(usize, 1), report.problems.items.len);
}

test "an end marker for another key does not close this one" {
    const source =
        \\<!-- docs-tables:begin a.zig -->
        \\one
        \\<!-- docs-tables:end b.zig -->
        \\two
        \\<!-- docs-tables:end a.zig -->
        \\
    ;
    const report = try parse(testing.allocator, source);
    defer report.deinit();
    try testing.expectEqual(@as(usize, 1), report.regions.len);
    try testing.expectEqualStrings("one\ntwo\n", report.regions[0].body);
}

test "rewrite replaces one region and leaves the rest of the file alone" {
    const source =
        \\# Title
        \\
        \\<!-- docs-tables:begin a.zig -->
        \\old
        \\<!-- docs-tables:end a.zig -->
        \\
        \\<!-- docs-tables:begin b.zig -->
        \\kept
        \\<!-- docs-tables:end b.zig -->
        \\
        \\Tail.
        \\
    ;
    const report = try parse(testing.allocator, source);
    defer report.deinit();

    const bodies = [_]?[]const u8{ "new\n", null };
    const out = (try rewrite(testing.allocator, source, report.regions, &bodies)).?;
    try testing.expectEqualStrings(
        \\# Title
        \\
        \\<!-- docs-tables:begin a.zig -->
        \\new
        \\<!-- docs-tables:end a.zig -->
        \\
        \\<!-- docs-tables:begin b.zig -->
        \\kept
        \\<!-- docs-tables:end b.zig -->
        \\
        \\Tail.
        \\
    ,
        out,
    );
}

test "rewrite returns null when the document already says this" {
    // A null return is what keeps a passing run from touching the file's
    // modification time for nothing.
    const source =
        \\<!-- docs-tables:begin a.zig -->
        \\same
        \\<!-- docs-tables:end a.zig -->
        \\
    ;
    const report = try parse(testing.allocator, source);
    defer report.deinit();
    const bodies = [_]?[]const u8{"same\n"};
    try testing.expectEqual(
        @as(?[]u8, null),
        try rewrite(testing.allocator, source, report.regions, &bodies),
    );
}

test "table prints the header even when it has no rows" {
    const out = try table(testing.allocator, &.{});
    try testing.expectEqualStrings("| Symbol | Declared in |\n|---|---|\n", out);
}
