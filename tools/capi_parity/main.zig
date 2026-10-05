//! The C ABI parity sweep: how much of `include/zaccesskit.h` is implemented.
//!
//! **The question.** The header declares 498 functions. A build for
//! `x86_64-linux` has to produce 446 of them, because 52 sit behind a
//! preprocessor guard that is off there. Every number quoted about this port
//! until now came from a shell one-liner that either concatenated a return type
//! onto the function name across a line break or ignored the guards entirely,
//! so the honest answer was unknown. This is the tool that answers it.
//!
//! **Both halves, and neither one skipped.** The header side is `header.zig`,
//! which masks comments and literals, evaluates the `#if` chain for a chosen
//! target and returns every declaration with the guard it sits behind. The Zig
//! side is `zig_source.zig`, which reads both export mechanisms — `export fn
//! NAME` and `@export(&fn, .{ .name = "NAME" })` — and the `Guard` member of the
//! `comptime` branch around the second one. An exported symbol is therefore a
//! name *and* a guard, and the per-target set is the set of sites whose guard
//! the target is inside. A tool that compared bare name sets would report the
//! 52 guarded declarations as exported on every target, which is exactly the
//! mistake this file exists to make impossible.
//!
//! **The guard logic is not re-derived.** `Guard`, `declaresOn`,
//! `declaredCountFor` and `export_records` all come from
//! `src/capi/platform.zig`, which owns the question. This tool reads *which*
//! guard a site sits behind out of the text around it, and compares that
//! reading against `export_records` independently: a site whose lexical guard
//! disagrees with its table row is a finding, not a silent pass.
//!
//! **What makes this tool able to fail.**
//!
//! - A declaration the classifier cannot read is a finding with its line, and
//!   it ends the run with exit code 2. It is never dropped, because a dropped
//!   declaration shrinks both sides at once and leaves the diff empty.
//! - An export site the scanner cannot read is the same.
//! - Every target is compared against a figure `docs/40-capi-build-map.md`
//!   section 1.1 measured. A target with no measured figure is a failure, not
//!   a pass: without it the 52 guarded declarations read as coverage.
//! - Any symbol on one side and not the other is a failure with both files and
//!   lines, and the run exits 1.
//!
//! **Usage.**
//!
//! ```
//! zig build capi-parity
//! zig build capi-parity -- --header include/zaccesskit.h --src src/capi
//! zig build capi-parity -- --target linux
//! ```
//!
//! Exit codes: `0` parity, `1` a mismatch, `2` something unreadable, `3` a bad
//! command line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const header = @import("header.zig");
const zig_source = @import("zig_source.zig");

/// `src/capi/platform.zig` owns the guard question and the record of which
/// declaration sits behind which guard. Nothing here re-derives either.
const platform = @import("zaccesskit").capi.platform;

const Exit = enum(u8) {
    /// Every declaration is exported and nothing else is.
    parity = 0,
    /// A symbol is on one side only, or a count disagrees with the measurement.
    mismatch = 1,
    /// A declaration or an export site could not be read.
    unreadable = 2,
    /// The command line was wrong.
    usage = 3,
};

/// The six guard classes the header uses, in the order
/// `docs/40-capi-build-map.md` section 1.1 lists them.
const GuardClass = enum {
    portable,
    unix,
    macos,
    apple_mobile,
    android,
    windows,

    /// The order a report prints rows in.
    const all = [_]GuardClass{ .portable, .unix, .macos, .apple_mobile, .android, .windows };

    fn of(p: header.Platform) GuardClass {
        return switch (p) {
            .portable => .portable,
            .unix => .unix,
            .macos => .macos,
            .apple_mobile => .apple_mobile,
            .android => .android,
            .windows => .windows,
        };
    }

    /// The `platform.Guard` member, or `null` for `portable`, which is not a
    /// guard: nothing hides a portable declaration.
    fn toZig(self: GuardClass) ?platform.Guard {
        return switch (self) {
            .portable => null,
            .unix => .unix,
            .macos => .macos,
            .apple_mobile => .apple_mobile,
            .android => .android,
            .windows => .windows,
        };
    }

    fn label(self: GuardClass) []const u8 {
        return switch (self) {
            .portable => "portable",
            .unix => "unix",
            .macos => "macos",
            .apple_mobile => "apple-mobile",
            .android => "android",
            .windows => "windows",
        };
    }
};

/// What `docs/40-capi-build-map.md` section 1 measured in the header, for the
/// whole file rather than for one target. The six guard counts sum to the 498
/// the header states at line 1757.
const Measured = struct {
    const portable = 440;
    const unix = 6;
    const macos = 16;
    const apple_mobile = 13;
    const android = 13;
    const windows = 10;

    /// Section 1 of the same document: the rest of the census, which a parser
    /// regression moves before it moves the function count.
    const functions = 498;
    const laid_out_structs = 40;
    const opaque_handles = 18;
    const function_pointer_typedefs = 4;
    const enums = 19;
    const enum_variants = 272;
    const data_objects = 1;

    fn of(c: GuardClass) usize {
        return switch (c) {
            .portable => portable,
            .unix => unix,
            .macos => macos,
            .apple_mobile => apple_mobile,
            .android => android,
            .windows => windows,
        };
    }
};

const TargetMeasurement = struct { target: header.Target, total: usize };

/// The per-target totals `docs/40-capi-build-map.md` section 1.1 measured.
///
/// **A target absent from this table is a failure at startup**, not a target
/// that quietly passes. The whole point of the sweep is that the expectation is
/// gated the way the header is; without a figure, the 52 guarded declarations
/// read as coverage on every platform.
const target_measurements = [_]TargetMeasurement{
    .{ .target = .linux, .total = 446 },
    .{ .target = .macos, .total = 456 },
    .{ .target = .ios, .total = 453 },
    .{ .target = .android, .total = 453 },
    .{ .target = .windows, .total = 450 },
};

/// The `platform.Platform` the header side and the Zig side agree on for each
/// sweep target.
///
/// The split needs an OS tag *and* a C ABI: `std.Target.Os.Tag` has no Android
/// member, so an Android target is `.linux` with the `.android` ABI, and that
/// ABI is the only thing keeping the Android and unix guards disjoint.
fn zigPlatform(t: header.Target) platform.Platform {
    return switch (t) {
        .linux => platform.linux_target,
        .android => platform.android_target,
        .windows => platform.windows_target,
        .macos => platform.Platform.abiNone(.macos),
        .ios => platform.Platform.abiNone(.ios),
    };
}

/// One thing the sweep could not accept.
const Finding = struct {
    kind: Kind,
    /// The symbol, for a symbol-level finding.
    symbol: []const u8 = "",
    /// Where the header declares it, 0 when it does not.
    header_line: u32 = 0,
    /// Where the Zig side exports it, null when nothing does.
    site: ?zig_source.ExportSite = null,
    /// A sentence naming what disagreed, for a count-level finding.
    detail: []const u8 = "",

    const Kind = enum {
        declared_not_exported,
        exported_not_declared,
        /// A site whose lexical guard disagrees with its `export_records` row.
        guard_disagreement,
        /// An `export_records` row with no export site behind it.
        record_without_site,
        /// An export site no `export_records` row claims.
        site_without_record,
        /// A count that disagrees with `docs/40`.
        count_disagreement,
        /// A target with no measured total in `target_measurements`.
        unmeasured_target,
        /// A declaration or a site that could not be read at all.
        unreadable,
    };
};

const Options = struct {
    header_path: []const u8 = "include/zaccesskit.h",
    source_dir: []const u8 = "src/capi",
    targets: std.ArrayList(header.Target) = .empty,
};

/// Everything one run needs, so no function has to reach for a global to name
/// the file it read.
const Sweep = struct {
    arena: Allocator,
    options: Options,
    scan: zig_source.Scan,
    docs: std.ArrayList(header.Document) = .empty,
    findings: std.ArrayList(Finding) = .empty,

    fn add(self: *Sweep, finding: Finding) !void {
        try self.findings.append(self.arena, finding);
    }

    fn hasKind(self: *const Sweep, kind: Finding.Kind) bool {
        for (self.findings.items) |f| {
            if (f.kind == kind) return true;
        }
        return false;
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    const options = parseArgs(arena, init.minimal.args) catch |err| switch (err) {
        error.Help => return @intFromEnum(Exit.parity),
        else => {
            var buf: [4096]u8 = undefined;
            var stderr = Io.File.stderr().writer(io, &buf);
            try usage(&stderr.interface);
            try stderr.interface.flush();
            return @intFromEnum(Exit.usage);
        },
    };

    var report: Io.Writer.Allocating = .init(arena);
    const w = &report.writer;

    var sweep: Sweep = .{
        .arena = arena,
        .options = options,
        .scan = try zig_source.scanDirectory(arena, io, options.source_dir),
    };
    defer sweep.scan.deinit();

    // The header is read once per target because a `#if` branch is evaluated
    // against one target's predefined macros, and the declaration set is what
    // that evaluation produces.
    for (options.targets.items) |t| {
        const source = try Io.Dir.cwd().readFileAlloc(
            io,
            options.header_path,
            arena,
            .limited(16 * 1024 * 1024),
        );
        try sweep.docs.append(arena, try header.parse(arena, source, t));
    }
    defer for (sweep.docs.items) |*doc| doc.deinit();

    try reportCensus(w, &sweep);
    try reportRecordCheck(w, &sweep);
    try reportUnreadable(w, &sweep);
    for (sweep.docs.items, options.targets.items) |*doc, t| {
        try reportTarget(w, &sweep, t, doc);
    }
    try reportSummary(w, &sweep);

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    try stdout.interface.writeAll(report.written());
    try stdout.interface.flush();

    if (sweep.hasKind(.unreadable)) return @intFromEnum(Exit.unreadable);
    if (sweep.findings.items.len != 0) return @intFromEnum(Exit.mismatch);
    return @intFromEnum(Exit.parity);
}

fn usage(w: *Io.Writer) !void {
    try w.writeAll(
        \\usage: capi-parity [options]
        \\
        \\  --header PATH    the C header to read           (default include/zaccesskit.h)
        \\  --src PATH       the directory of C-ABI sources (default src/capi)
        \\  --target NAME    linux|macos|ios|android|windows, repeatable;
        \\                   default is every target docs/40 measured
        \\  -h, --help       this text
        \\
        \\exit: 0 parity, 1 mismatch, 2 unreadable declaration, 3 bad command line
        \\
    );
}

fn parseArgs(arena: Allocator, args: std.process.Args) !Options {
    var options: Options = .{};
    var it = std.process.Args.iterate(args);
    // `std.process.Args` hands back the whole vector, argv zero included.
    _ = it.skip();
    while (it.next()) |raw| {
        const arg: []const u8 = raw;
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) return error.Help;
        if (std.mem.eql(u8, arg, "--header")) {
            options.header_path = it.next() orelse return error.MissingValue;
            continue;
        }
        if (std.mem.eql(u8, arg, "--src")) {
            options.source_dir = it.next() orelse return error.MissingValue;
            continue;
        }
        if (std.mem.eql(u8, arg, "--target")) {
            const name = it.next() orelse return error.MissingValue;
            const t = parseTarget(name) orelse return error.UnknownTarget;
            try options.targets.append(arena, t);
            continue;
        }
        return error.UnknownFlag;
    }
    if (options.targets.items.len == 0) {
        for (target_measurements) |m| try options.targets.append(arena, m.target);
    }
    return options;
}

fn parseTarget(name: []const u8) ?header.Target {
    inline for (@typeInfo(header.Target).@"enum".fields) |f| {
        if (std.mem.eql(u8, name, f.name)) return @enumFromInt(f.value);
    }
    return null;
}

/// The header's whole-file census, against what `docs/40-capi-build-map.md`
/// section 1 measured. This is the check that a declaration was not quietly
/// dropped: a dropped declaration moves one of these rows.
fn reportCensus(w: *Io.Writer, sweep: *Sweep) !void {
    const doc = &sweep.docs.items[0];
    try w.print("capi-parity\n  header  {s}\n  sources {s}\n\n", .{
        sweep.options.header_path,
        sweep.options.source_dir,
    });

    var declared_by_guard = [_]usize{0} ** GuardClass.all.len;
    for (doc.functions) |f| {
        declared_by_guard[@intFromEnum(GuardClass.of(f.guard.platform))] += 1;
    }

    var variants: usize = 0;
    for (doc.enums) |e| variants += e.variants;
    var opaque_count: usize = 0;
    var function_pointers: usize = 0;
    for (doc.typedefs) |td| {
        switch (td.kind) {
            .opaque_handle => opaque_count += 1,
            .function_pointer => function_pointers += 1,
            .alias => {},
        }
    }

    var export_fn: usize = 0;
    var at_export: usize = 0;
    for (sweep.scan.sites) |s| {
        switch (s.mechanism) {
            .export_fn => export_fn += 1,
            .at_export => at_export += 1,
        }
    }

    try w.writeAll("header census                             measured\n");
    try censusRow(sweep, w, "function declarations", doc.functions.len, Measured.functions);
    try censusRow(sweep, w, "laid-out structs", doc.records.len, Measured.laid_out_structs);
    try censusRow(sweep, w, "opaque handles", opaque_count, Measured.opaque_handles);
    try censusRow(
        sweep,
        w,
        "function-pointer typedefs",
        function_pointers,
        Measured.function_pointer_typedefs,
    );
    try censusRow(sweep, w, "enum declarations", doc.enums.len, Measured.enums);
    try censusRow(sweep, w, "enum variants", variants, Measured.enum_variants);
    try censusRow(sweep, w, "exported data objects", doc.objects.len, Measured.data_objects);

    try w.writeAll("declared by guard\n");
    var total: usize = 0;
    for (GuardClass.all, 0..) |c, i| {
        try w.print("  {s:<14}{d:>6}{d:>12}{s:>10}\n", .{
            c.label(),
            declared_by_guard[i],
            Measured.of(c),
            if (declared_by_guard[i] == Measured.of(c)) "" else "  MISMATCH",
        });
        total += declared_by_guard[i];
    }
    try w.print("  {s:<14}{d:>6}{d:>12}\n\n", .{ "total", total, Measured.functions });
    if (total != Measured.functions) {
        try sweep.add(.{
            .kind = .count_disagreement,
            .detail = try std.fmt.allocPrint(
                sweep.arena,
                "header declares {d} functions, docs/40 measured {d}",
                .{ total, Measured.functions },
            ),
        });
    }

    try w.writeAll("export sites                                count\n");
    try w.print("  {s:<38}{d:>6}\n", .{ "export fn", export_fn });
    try w.print("  {s:<38}{d:>6}\n", .{ "@export under a comptime guard", at_export });
    try w.print("  {s:<38}{d:>6}\n", .{ "total sites", sweep.scan.sites.len });
    try w.print("  {s:<38}{d:>6}\n", .{
        "platform.export_records rows",
        platform.export_record_count,
    });
    try w.print("  {s:<38}{d:>6}\n\n", .{
        "unreadable export sites",
        sweep.scan.problems.len,
    });
}

fn censusRow(sweep: *Sweep, w: *Io.Writer, label: []const u8, got: usize, want: usize) !void {
    const ok = got == want;
    try w.print("  {s:<38}{d:>6}{d:>12}{s:>10}\n", .{
        label,
        got,
        want,
        if (ok) "" else "  MISMATCH",
    });
    if (!ok) {
        try sweep.add(.{
            .kind = .count_disagreement,
            .detail = try std.fmt.allocPrint(
                sweep.arena,
                "{s}: measured {d}, docs/40 measured {d}",
                .{ label, got, want },
            ),
        });
    }
}

/// The `export_records` table in `src/capi/platform.zig` against the code, read
/// independently. The table is a claim about which guard each declaration sits
/// behind; the scanner read the same fact from the text. Comparing them means
/// neither can be wrong alone.
fn reportRecordCheck(w: *Io.Writer, sweep: *Sweep) !void {
    try w.writeAll("platform.export_records cross-check\n");
    var matched: usize = 0;
    var disagreements: usize = 0;
    var without_site: usize = 0;
    var without_record: usize = 0;

    for (platform.export_records) |record| {
        const site = sweep.scan.find(record.symbol);
        if (site == null) {
            without_site += 1;
            try w.print(
                "  {s}: table row says guard {s} at include/zaccesskit.h:{d}; no export site\n",
                .{ record.symbol, @tagName(record.guard), record.header_line },
            );
            try sweep.add(.{
                .kind = .record_without_site,
                .symbol = record.symbol,
                .header_line = record.header_line,
            });
            continue;
        }
        const found = site.?;
        matched += 1;
        if (!std.meta.eql(found.guard, record.guard)) {
            disagreements += 1;
            try w.print(
                "  {s}: table row says guard {s}; the site at {s}:{d} is behind {s}\n",
                .{
                    record.symbol,
                    @tagName(record.guard),
                    found.file,
                    found.line,
                    if (found.guard) |g| @tagName(g) else "no guard",
                },
            );
            try sweep.add(.{
                .kind = .guard_disagreement,
                .symbol = record.symbol,
                .header_line = record.header_line,
                .site = found,
            });
        }
    }

    // Only a guarded site is expected to have a row. `export_records` holds
    // the 58 declarations behind a guard and nothing else, so a portable site
    // with no row is the table being correct rather than a defect.
    for (sweep.scan.sites) |s| {
        if (s.guard == null) continue;
        if (recordFor(s.symbol) != null) continue;
        without_record += 1;
        try w.print(
            "  {s}: exported at {s}:{d} behind {s}; export_records has no row for it\n",
            .{
                s.symbol,
                s.file,
                s.line,
                if (s.guard) |g| @tagName(g) else "no guard",
            },
        );
        try sweep.add(.{
            .kind = .site_without_record,
            .symbol = s.symbol,
            .site = s,
        });
    }

    try w.print("  rows matched {d}, guard disagreements {d}," ++
        " rows without a site {d}, sites without a row {d}\n\n", .{
        matched,
        disagreements,
        without_site,
        without_record,
    });
}

fn recordFor(symbol: []const u8) ?platform.ExportRecord {
    for (platform.export_records) |record| {
        if (std.mem.eql(u8, record.symbol, symbol)) return record;
    }
    return null;
}

/// Every construct neither side could read. These end the run: a dropped
/// declaration shrinks both sides at once, which is the one failure that leaves
/// a parity diff looking empty.
fn reportUnreadable(w: *Io.Writer, sweep: *Sweep) !void {
    var total: usize = 0;
    for (sweep.docs.items) |*doc| {
        for (doc.unparsed) |u| {
            total += 1;
            try w.print("  {s}:{d}  the classifier could not read this declaration\n    {s}\n", .{
                sweep.options.header_path,
                u.line,
                u.text,
            });
            try sweep.add(.{
                .kind = .unreadable,
                .header_line = u.line,
                .detail = "the classifier could not read this top-level declaration",
            });
        }
    }
    for (sweep.scan.problems) |p| {
        total += 1;
        try w.print("  {s}:{d}  {s}\n", .{ p.file, p.line, p.message });
        try sweep.add(.{
            .kind = .unreadable,
            .symbol = p.file,
            .detail = p.message,
        });
    }
    try w.print("unreadable declarations and export sites: {d}\n\n", .{total});
}

/// One target: what the header declares, what the Zig side exports, what
/// `docs/40` measured for it, and the symbol-level diff.
fn reportTarget(w: *Io.Writer, sweep: *Sweep, t: header.Target, doc: *const header.Document) !void {
    const zp = zigPlatform(t);
    const expected = expectedTotal(t);
    try w.print("target {s}  (os={s}, abi={s})\n", .{
        @tagName(t),
        @tagName(zp.os_tag),
        @tagName(zp.abi),
    });
    try w.print("  {s:<14}{s:>9}{s:>10}{s:>10}{s:>10}\n", .{
        "guard", "declared", "exported", "docs/40", "table",
    });

    // The portable column is the one `platform.declaredCountFor` cannot
    // answer: `portable` is not a guard, so its count is the number of sites
    // that sit behind none, read here rather than asked of the table.
    var portable_sites: usize = 0;
    for (sweep.scan.sites) |s| {
        if (s.guard == null) portable_sites += 1;
    }

    var declared_total: usize = 0;
    var exported_total: usize = 0;
    var measured_total: usize = 0;
    var table_total: usize = 0;
    for (GuardClass.all) |c| {
        var declared: usize = 0;
        for (doc.functions) |f| {
            if (!f.guard.active) continue;
            if (GuardClass.of(f.guard.platform) != c) continue;
            declared += 1;
        }
        var exported: usize = 0;
        for (sweep.scan.sites) |s| {
            if (!siteOn(s, zp)) continue;
            if (classOf(s) != c) continue;
            exported += 1;
        }
        const in_target: bool = if (c.toZig()) |g| g.declaresOn(zp) else true;
        // `docs/40` counts a guarded class on the target it gates, and zero on
        // every other; the portable class is 440 everywhere.
        const documented: usize = if (in_target) Measured.of(c) else 0;
        const table: usize = if (c.toZig()) |g|
            platform.declaredCountFor(zp, g)
        else
            portable_sites;
        declared_total += declared;
        exported_total += exported;
        measured_total += documented;
        table_total += table;
        try w.print("  {s:<14}{d:>9}{d:>10}{d:>10}{d:>10}\n", .{
            c.label(),
            declared,
            exported,
            documented,
            table,
        });
    }
    try w.print("  {s:<14}{d:>9}{d:>10}{d:>10}{d:>10}\n", .{
        "total",
        declared_total,
        exported_total,
        measured_total,
        table_total,
    });

    if (expected == null) {
        try w.print("  docs/40 measured no total for this target\n", .{});
        try sweep.add(.{
            .kind = .unmeasured_target,
            .detail = try detail(sweep, "no measured total for target {s}", .{
                @tagName(t),
            }),
        });
    } else {
        try w.print("  docs/40 measured {d} for this target{s}\n", .{
            expected.?,
            if (declared_total == expected.? and exported_total == expected.? and
                measured_total == expected.?)
                ""
            else
                "   MISMATCH",
        });
        if (declared_total != expected.?) {
            try sweep.add(.{
                .kind = .count_disagreement,
                .detail = try detail(
                    sweep,
                    "{s}: header declares {d}, docs/40 measured {d}",
                    .{ @tagName(t), declared_total, expected.? },
                ),
            });
        }
        if (exported_total != expected.?) {
            try sweep.add(.{
                .kind = .count_disagreement,
                .detail = try detail(
                    sweep,
                    "{s}: Zig exports {d}, docs/40 measured {d}",
                    .{ @tagName(t), exported_total, expected.? },
                ),
            });
        }
        if (measured_total != expected.?) {
            try sweep.add(.{
                .kind = .count_disagreement,
                .detail = try detail(
                    sweep,
                    "{s}: the per-guard docs/40 split sums to {d}, " ++
                        "its own per-target total is {d}",
                    .{ @tagName(t), measured_total, expected.? },
                ),
            });
        }
    }
    try w.writeAll("\n");

    try compareTarget(w, sweep, t, doc, zp);
}

/// The one place a finding's sentence is built, so the call sites stay short
/// and every sentence borrows the sweep's arena rather than a fresh one.
fn detail(sweep: *Sweep, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.allocPrint(sweep.arena, fmt, args);
}

fn expectedTotal(t: header.Target) ?usize {
    for (target_measurements) |m| {
        if (m.target == t) return m.total;
    }
    return null;
}

fn siteOn(s: zig_source.ExportSite, zp: platform.Platform) bool {
    const g = s.guard orelse return true;
    return g.declaresOn(zp);
}

fn classOf(s: zig_source.ExportSite) GuardClass {
    const g = s.guard orelse return .portable;
    return switch (g) {
        .unix => .unix,
        .macos => .macos,
        .apple_mobile => .apple_mobile,
        .android => .android,
        .windows => .windows,
    };
}

/// The symbol-level diff for one target: declared and not exported, exported
/// and not declared, and a name declared twice.
fn compareTarget(
    w: *Io.Writer,
    sweep: *Sweep,
    t: header.Target,
    doc: *const header.Document,
    zp: platform.Platform,
) !void {
    var declared: std.StringHashMapUnmanaged(u32) = .empty;
    var exported: std.StringHashMapUnmanaged(zig_source.ExportSite) = .empty;

    for (doc.functions) |f| {
        if (!f.guard.active) continue;
        if (declared.contains(f.name)) {
            try w.print("  {s}: declared twice, at {s}:{d} and {s}:{d}\n", .{
                f.name,
                sweep.options.header_path,
                declared.get(f.name).?,
                sweep.options.header_path,
                f.line,
            });
            try sweep.add(.{
                .kind = .count_disagreement,
                .symbol = f.name,
                .header_line = f.line,
                .detail = "the header declares this function more than once",
            });
            continue;
        }
        try declared.put(sweep.arena, f.name, f.line);
    }
    for (sweep.scan.sites) |s| {
        if (!siteOn(s, zp)) continue;
        try exported.put(sweep.arena, s.symbol, s);
    }

    var missing: usize = 0;
    for (doc.functions) |f| {
        if (!f.guard.active) continue;
        if (exported.contains(f.name)) continue;
        missing += 1;
        try w.print("  declared, not exported: {s} at {s}:{d}\n", .{
            f.name,
            sweep.options.header_path,
            f.line,
        });
        try sweep.add(.{
            .kind = .declared_not_exported,
            .symbol = f.name,
            .header_line = f.line,
        });
    }

    var extra: usize = 0;
    for (sweep.scan.sites) |s| {
        if (!siteOn(s, zp)) continue;
        if (declared.contains(s.symbol)) continue;
        extra += 1;
        try w.print("  exported, not declared: {s} at {s}:{d}\n", .{ s.symbol, s.file, s.line });
        try sweep.add(.{
            .kind = .exported_not_declared,
            .symbol = s.symbol,
            .site = s,
        });
    }

    if (missing == 0 and extra == 0) {
        try w.print("  {s}: the declared set and the exported set are identical ({d} symbols)\n", .{
            @tagName(t),
            declared.count(),
        });
    }
    try w.writeAll("\n");
}

fn reportSummary(w: *Io.Writer, sweep: *Sweep) !void {
    try w.print("summary\n", .{});
    if (sweep.findings.items.len == 0) {
        try w.writeAll("  no mismatches and nothing unreadable\n");
    } else {
        try reportFindings(w, sweep);
    }
    try w.writeAll("\n");
    try w.print("verdict: {s}\n", .{
        if (sweep.hasKind(.unreadable))
            "NOT PARITY - something could not be read, so the comparison is not evidence"
        else if (sweep.findings.items.len != 0)
            "NOT IN PARITY - the two sides disagree"
        else
            "IN PARITY - every declaration this target sees is exported, and nothing else is",
    });
}

fn reportFindings(w: *Io.Writer, sweep: *Sweep) !void {
    var kinds = std.EnumArray(Finding.Kind, usize).initFill(0);
    for (sweep.findings.items) |f| kinds.set(f.kind, kinds.get(f.kind) + 1);
    for (std.enums.values(Finding.Kind)) |kind| {
        const n = kinds.get(kind);
        if (n == 0) continue;
        try w.print("  {d:>5}  {s}\n", .{ n, @tagName(kind) });
    }
    try w.writeAll(
        "\n  symbol" ++
            "                                     header" ++
            "            zig                     kind\n",
    );
    for (sweep.findings.items) |f| {
        const header_at = if (f.header_line == 0) "-" else try std.fmt.allocPrint(
            sweep.arena,
            "{s}:{d}",
            .{ sweep.options.header_path, f.header_line },
        );
        const site_at = if (f.site) |s|
            try std.fmt.allocPrint(sweep.arena, "{s}:{d}", .{ s.file, s.line })
        else
            "-";
        try w.print("  {s:<44}{s:<18}{s:<24}{s}\n", .{
            f.symbol,
            header_at,
            site_at,
            @tagName(f.kind),
        });
        if (f.detail.len != 0) try w.print("      {s}\n", .{f.detail});
    }
    try w.writeAll("\n");
}
