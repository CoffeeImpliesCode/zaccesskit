//! Checks and regenerates the per-module symbol tables in
//! `docs/36-consumer-call-graph.md`.
//!
//! **The question.** That document records which module of the consumer layer
//! calls which, symbol by symbol, and says at its own line 11 that a row which
//! no longer matches its file is a stale row. Nothing checked it, so every row
//! was written by a person reading the source and a signature that changed left
//! a row naming a symbol that no longer exists. Two such rows were known when
//! this tool was written, both in `docs/36` sections 3 and 4 of the per-module
//! list, and both are in the tables for `iterators/following.zig` and
//! `iterators/preceding.zig`, which name three symbols from
//! `iterators/children.zig` where the source names one.
//!
//! **What a row is.** A symbol the file names, and the file that finally
//! declares it. Three resolutions produce it, and each has a case that must not
//! be guessed:
//!
//! - `const alias = @import("path")` binds a module. Zig resolves a bare
//!   `"sibling.zig"` against the importing file's own directory, so a target
//!   needs no `./` to name a file.
//! - `pub const X = alias.Name` re-exports. The owning module is the one behind
//!   `alias`, so `schema.Affine` resolves to `src/schema/geometry/affine.zig`
//!   and not to the file holding the re-export.
//! - `alias.Symbol` names a module only when `alias` starts the dotted chain.
//!   `node.tree_state.nodes` is three fields of a value, and no module is named
//!   by it.
//!
//! **What is not a row.** `@import("std")` is the standard library and not this
//! repository, so it never appears. `include/zaccesskit.h` is the ABI contract
//! rather than an import, so it is not scanned here either: `tools/capi_parity`
//! owns the comparison between that header and what `src/capi` exports, and two
//! tools reading one contract is how they come to disagree.
//!
//! **An unresolved name is a finding, and the run fails.** A symbol that quietly
//! stops existing makes every table smaller and the diff empty, so a broken row
//! and a clean run would look the same. The run names the symbol, the file that
//! used it and the module it was looked for in, and exits 2.
//!
//! **Usage.**
//!
//! ```
//! zig build docs-tables
//! zig build docs-tables -- --write
//! zig build docs-tables -- --doc docs/36-consumer-call-graph.md
//! ```
//!
//! Exit codes: `0` the document matches the source, `1` a table differs,
//! `2` a marker or a symbol could not be read, `3` a bad command line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const scan = @import("scan.zig");
const document = @import("document.zig");

/// The layer the document is about. A row naming a module inside it prints as a
/// path relative to this prefix.
const consumer_prefix = "src/consumer/";

/// The only directory outside the layer the document records.
///
/// `src/schema/root.zig` re-exports the whole schema through one namespace, and
/// section 4 of the document says the schema accessors are one group each rather
/// than shared operations. The geometry leaves are different: a consumer
/// reaches past `root.zig` for `mul`, `inverse` and `transformRectBbox`, and
/// each is one operation the consumer layer calls.
const recorded_outside = "src/schema/geometry/";

/// The kind of thing the run could not accept.
const Finding = struct {
    kind: Kind,
    /// The file the finding is about.
    path: []const u8,
    /// The line to look at, 0 when the finding is about the whole file.
    line: u32 = 0,
    /// A sentence naming what disagreed.
    detail: []const u8,

    const Kind = enum {
        /// A name the file used and no module on the chain declares.
        unresolved_name,
        /// A marker with no partner, or a marker for a module with no table.
        bad_marker,
        /// A source file the scanner could not read: the parser rejected it, or
        /// it holds a shape the scanner does not interpret.
        unreadable_source,
    };
};

const Exit = enum(u8) {
    /// Every marked table in the document matches the source.
    match = 0,
    /// A table differs from what the source says.
    drift = 1,
    /// A marker, a source file or a symbol could not be read.
    unreadable = 2,
    /// The command line was wrong.
    usage = 3,
};

const Options = struct {
    doc_path: []const u8 = "docs/36-consumer-call-graph.md",
    src_dir: []const u8 = "src",
    write: bool = false,
};

/// One module's symbols, grouped by the module that declares them.
const Group = struct {
    owner: []const u8,
    names: std.ArrayList([]const u8) = .empty,
};

/// Everything one run holds. The allocator lives for the whole run, so every
/// slice here borrows from it and nothing needs a per-item release.
const Run = struct {
    gpa: Allocator,
    options: Options,
    tree: scan.Tree,
    findings: std.ArrayList(Finding) = .empty,
    /// The table this run built for each marked region, keyed by its marker.
    tables: std.StringArrayHashMapUnmanaged([]const u8) = .empty,

    fn add(self: *Run, finding: Finding) !void {
        try self.findings.append(self.gpa, finding);
    }

    fn has(self: *const Run, kind: Finding.Kind) bool {
        for (self.findings.items) |finding| {
            if (finding.kind == kind) return true;
        }
        return false;
    }
};

/// Builds the table body for one module.
///
/// **A module with no rows still gets a table.** A missing table and an empty
/// one look the same to a reader, and only the first is a defect, so the table
/// carries its own header row and no data rows.
fn tableFor(run: *Run, module: *const scan.Module) ![]const u8 {
    var groups: std.ArrayList(Group) = .empty;
    for (module.edges.items) |edge| {
        const owner = scan.ownerOf(&run.tree, edge.target, edge.name, 0) orelse {
            // A target outside the scanned tree is `std` or a package, and
            // neither is a row. A target inside it that declares no such name is
            // a finding, because a dropped symbol is the failure this tool
            // exists to prevent.
            if (run.tree.get(edge.target) != null) {
                try run.add(.{
                    .kind = .unresolved_name,
                    .path = module.path,
                    .detail = edge.name,
                });
            }
            continue;
        };
        if (!isRecorded(owner)) continue;
        if (std.mem.eql(u8, owner, module.path)) continue;

        const group = try groupFor(run.gpa, &groups, owner);
        if (!containsName(group.names.items, edge.name)) {
            try group.names.append(run.gpa, edge.name);
        }
    }

    // Rows are ordered by owning module and then by symbol, so two runs over one
    // tree print the same table and a diff between them means the source moved.
    std.mem.sort(Group, groups.items, {}, lessThanOwner);
    for (groups.items) |*group| {
        std.mem.sort([]const u8, group.names.items, {}, lessThanBytes);
    }

    const rows = try run.gpa.alloc([]const u8, groups.items.len);
    for (groups.items, rows) |group, *row| {
        row.* = try formatRow(run.gpa, module, group);
    }
    return document.table(run.gpa, rows);
}

fn isRecorded(owner: []const u8) bool {
    return std.mem.startsWith(u8, owner, consumer_prefix) or
        std.mem.startsWith(u8, owner, recorded_outside);
}

fn groupFor(
    gpa: Allocator,
    groups: *std.ArrayList(Group),
    owner: []const u8,
) !*Group {
    for (groups.items) |*candidate| {
        if (std.mem.eql(u8, candidate.owner, owner)) return candidate;
    }
    try groups.append(gpa, .{ .owner = owner });
    return &groups.items[groups.items.len - 1];
}

/// One row: the symbols the group names, and where the document prints the
/// module that declares them.
///
/// **The path prints the way the document writes it, not the way the tree
/// keys it.** A module inside the layer prints layer-relative and a module
/// outside it prints the way the importing file wrote it, which is
/// `Module.display`. Printing the tree's own key instead puts
/// `src/consumer/node_id.zig` beside a heading that reads `node_id.zig`, and a
/// reader cannot tell which of the two the document means.
///
/// `display` reports whether it allocated, and only an allocated path is
/// released here.
fn formatRow(gpa: Allocator, module: *const scan.Module, group: Group) ![]const u8 {
    var out: Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    for (group.names.items, 0..) |name, index| {
        if (index != 0) try out.writer.writeAll(", ");
        try out.writer.print("`{s}`", .{name});
    }

    const shown = try module.display(gpa, group.owner, consumer_prefix);
    defer if (shown.owned) gpa.free(shown.path);

    return std.fmt.allocPrint(gpa, "{s} | `{s}`", .{ out.written(), shown.path });
}

fn containsName(names: []const []const u8, name: []const u8) bool {
    for (names) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

fn lessThanOwner(_: void, a: Group, b: Group) bool {
    return std.mem.lessThan(u8, a.owner, b.owner);
}

fn lessThanBytes(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();
    const io = init.io;

    const options = parseArgs(init.minimal.args) catch |err| switch (err) {
        error.Help => {
            var buffer: [4096]u8 = undefined;
            var out = Io.File.stdout().writer(io, &buffer);
            try usage(&out.interface);
            try out.interface.flush();
            return @intFromEnum(Exit.match);
        },
        else => {
            var buffer: [4096]u8 = undefined;
            var err_writer = Io.File.stderr().writer(io, &buffer);
            try usage(&err_writer.interface);
            try err_writer.interface.flush();
            return @intFromEnum(Exit.usage);
        },
    };

    var stdout_buffer: [64 * 1024]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &stdout_buffer);
    const w = &stdout.interface;

    var run: Run = .{
        .gpa = gpa,
        .options = options,
        .tree = scan.scanTree(gpa, io, options.src_dir) catch |err| {
            try w.print("cannot read {s}: {t}\n", .{ options.src_dir, err });
            try w.flush();
            return @intFromEnum(Exit.unreadable);
        },
    };

    // A shape the scanner read but could not interpret is a finding, not a
    // silent pass. `Module.problems` and `Tree.rejected` are the two places the
    // scanner records a file it could not make sense of, and a finding is the
    // only thing that reaches the exit code.
    for (run.tree.modules.values()) |module| {
        for (module.problems.items) |problem| {
            try run.add(.{
                .kind = .unreadable_source,
                .path = problem.path,
                .line = problem.line,
                .detail = problem.message,
            });
        }
    }
    for (run.tree.rejected.items) |problem| {
        try run.add(.{
            .kind = .unreadable_source,
            .path = problem.path,
            .line = problem.line,
            .detail = problem.message,
        });
    }

    const source = Io.Dir.cwd().readFileAlloc(
        io,
        options.doc_path,
        gpa,
        .limited(4 * 1024 * 1024),
    ) catch |err| {
        try w.print("cannot read {s}: {t}\n", .{ options.doc_path, err });
        try w.flush();
        return @intFromEnum(Exit.unreadable);
    };

    var doc_report = try document.parse(gpa, source);
    defer doc_report.deinit();
    for (doc_report.problems.items) |problem| {
        try run.add(.{
            .kind = .bad_marker,
            .path = options.doc_path,
            .line = problem.line,
            .detail = problem.message,
        });
    }

    for (doc_report.regions) |region| {
        // A marker names its module relative to the layer, so `tree_index.zig`
        // means `src/consumer/tree_index.zig`. The tree is keyed by the full
        // path, so the prefix is applied here rather than written into every
        // marker in the document.
        // `++` is comptime-only, and `region.key` is a run-time slice, so the
        // join goes through the allocator.
        const full = try std.mem.concat(gpa, u8, &.{ consumer_prefix, region.key });
        defer gpa.free(full);
        const module = run.tree.get(full) orelse {
            try run.add(.{
                .kind = .bad_marker,
                .path = options.doc_path,
                .line = region.line,
                .detail = "a marker names a module the tree does not hold",
            });
            continue;
        };
        try run.tables.put(gpa, region.key, try tableFor(&run, module));
    }

    const bodies = try gpa.alloc(?[]const u8, doc_report.regions.len);
    var drifting: usize = 0;
    for (doc_report.regions, bodies) |region, *slot| {
        const body = run.tables.get(region.key);
        slot.* = body;
        if (body == null) continue;
        if (std.mem.eql(u8, body.?, region.body)) continue;
        drifting += 1;
        try w.print("drift {s}:{d} {s}\n", .{ options.doc_path, region.line, region.key });
    }

    const rewritten = try document.rewrite(gpa, source, doc_report.regions, bodies);
    if (options.write and rewritten != null) {
        try Io.Dir.cwd().writeFile(io, .{
            .sub_path = options.doc_path,
            .data = rewritten.?,
        });
    }

    for (run.findings.items) |finding| {
        try w.print("finding {s}: {s}", .{ @tagName(finding.kind), finding.path });
        if (finding.line != 0) try w.print(":{d}", .{finding.line});
        try w.print(": {s}\n", .{finding.detail});
    }

    try w.print(
        "{d} module(s) scanned, {d} table(s) compared, {d} finding(s)\n",
        .{ run.tree.modules.count(), doc_report.regions.len, run.findings.items.len },
    );
    if (rewritten) |text| {
        const verb = if (options.write) "written" else "differs";
        try w.print("{s} {s}, {d} byte(s)\n", .{ options.doc_path, verb, text.len });
    } else {
        try w.print("{s} matches the source\n", .{options.doc_path});
    }
    try w.flush();

    if (run.has(.unreadable_source) or run.has(.bad_marker) or run.has(.unresolved_name)) {
        return @intFromEnum(Exit.unreadable);
    }
    // A run that wrote the tables has left the document matching the source, so
    // it is a pass. A run that only reported the difference is not.
    if (drifting != 0 and !options.write) return @intFromEnum(Exit.drift);
    return @intFromEnum(Exit.match);
}

fn usage(w: *Io.Writer) !void {
    try w.writeAll(
        \\usage: docs-tables [--write] [--doc PATH] [--src DIR]
        \\
        \\  --write    rewrite the marked tables in the document
        \\  --doc      the document to check (docs/36-consumer-call-graph.md)
        \\  --src      the source tree to scan (src)
        \\  --help     print this text
        \\
        \\
    );
}

/// Reads the command line out of `args`.
///
/// **The vector is iterated, not materialized.** `std.process.Args` is the
/// whole argv including a zero that is not a flag, so the iterator skips it
/// explicitly. On a platform whose argv outlives the process there is nothing
/// to free and nothing to allocate, so this function takes no allocator and
/// `Options` borrows straight from the vector.
fn parseArgs(args: std.process.Args) !Options {
    var options: Options = .{};
    var it = std.process.Args.iterate(args);
    // `std.process.Args` hands back the whole vector, argv zero included.
    _ = it.skip();
    while (it.next()) |raw| {
        const arg: []const u8 = raw;
        if (std.mem.eql(u8, arg, "--write")) {
            options.write = true;
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            return error.Help;
        } else if (std.mem.eql(u8, arg, "--doc")) {
            options.doc_path = it.next() orelse return error.MissingValue;
        } else if (std.mem.eql(u8, arg, "--src")) {
            options.src_dir = it.next() orelse return error.MissingValue;
        } else {
            return error.UnknownArgument;
        }
    }
    return options;
}
