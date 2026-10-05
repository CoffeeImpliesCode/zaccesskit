//! The Zig half of the C ABI parity sweep: where every exported symbol comes from.
//!
//! Two mechanisms leave a module, and a sweep that reads only one of them
//! reports a whole family of false misses.
//!
//! - `pub export fn NAME` and `export fn NAME` name the symbol directly. Both
//!   spellings are the same symbol to a C consumer, so both are read here.
//! - `@export(&fn, .{ .name = "NAME", .linkage = .strong })` names it in a
//!   string. Every such site in `src/capi/platform.zig` sits inside a
//!   `comptime { if (Guard.<g>.declaresOn(this_platform)) { … } }` block, so it
//!   is a symbol on one target and no symbol at all on every other one. The
//!   enclosing `Guard` member is therefore part of what the site *is*, and the
//!   sweep carries it beside the symbol rather than throwing it away.
//!
//! **The guard is read lexically, not taken from a table.** `Guard.declaresOn`
//! is imported from `src/capi/platform.zig` and is the only thing that answers
//! "is this target in? ", but which guard a site sits behind is read from the
//! text around it. `main.zig` then compares that reading against the
//! `export_records` table independently, which is the only way the two can be
//! caught disagreeing.
//!
//! **Comments and literals are masked before any scan.** A doc comment that
//! quotes `export fn accesskit_node_free` is a phantom symbol if it is read, and
//! the symbol table in this file has to survive an edit that mentions one in
//! prose. Masking preserves byte offsets and line breaks, so every site keeps
//! the line it sits on in the real file and a masked string literal is still
//! readable out of the original text.
//!
//! Every shape this scanner cannot read is a `Problem` with a line, not a
//! skipped declaration. A dropped site shrinks the export set and makes the
//! parity diff smaller, which is the one failure a parity tool cannot have.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// `src/capi/platform.zig` owns the guard question. Reusing its enum keeps the
/// sweep's idea of a platform identical to the code's.
const platform = @import("zaccesskit").capi.platform;

pub const Guard = platform.Guard;

/// How a symbol leaves the module.
pub const Mechanism = enum {
    /// `export fn NAME` or `pub export fn NAME`.
    export_fn,
    /// `@export(&fn, .{ .name = "NAME", … })`.
    at_export,
};

/// One place a C symbol is exported from.
pub const ExportSite = struct {
    /// The C symbol, which is what the header declares.
    symbol: []const u8,
    /// The path the sweep was pointed at, plus the file name.
    file: []const u8,
    /// The line the mechanism starts on.
    line: u32,
    /// The guard whose `comptime` branch encloses the site. `null` is a
    /// portable export: it exists on every target.
    guard: ?Guard,
    mechanism: Mechanism,
};

/// One thing the scanner could not read, carrying the line to look at.
pub const Problem = struct {
    file: []const u8,
    line: u32,
    message: []const u8,
};

/// Everything one directory read produced. Owns the arena every slice borrows.
pub const Scan = struct {
    arena: std.heap.ArenaAllocator,
    sites: []const ExportSite,
    problems: []const Problem,

    pub fn deinit(self: *Scan) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The site exporting `symbol`, or `null`. The sweep reports duplicates
    /// itself, so the first match is the one that is named.
    pub fn find(self: *const Scan, symbol: []const u8) ?ExportSite {
        for (self.sites) |site| {
            if (std.mem.eql(u8, site.symbol, symbol)) return site;
        }
        return null;
    }
};

/// Reads every `.zig` file in `dir_path`, in name order, and returns the export
/// sites and the shapes that could not be read.
///
/// The directory is walked in name order rather than in the order the
/// filesystem hands entries back, so two runs of the same tree report the same
/// sites in the same order and a diff between runs means something changed.
pub fn scanDirectory(arena: Allocator, io: Io, dir_path: []const u8) !Scan {
    var state: std.heap.ArenaAllocator = .init(arena);
    errdefer state.deinit();
    const scratch = state.allocator();

    const dir = try Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".zig")) continue;
        try names.append(scratch, try scratch.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, lessThanName);

    var sites: std.ArrayList(ExportSite) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    for (names.items) |name| {
        const path = try std.fs.path.join(scratch, &.{ dir_path, name });
        const source = try Io.Dir.cwd().readFileAlloc(
            io,
            path,
            scratch,
            .limited(8 * 1024 * 1024),
        );
        try scanSource(scratch, path, source, &sites, &problems);
    }

    return .{
        .arena = state,
        .sites = try sites.toOwnedSlice(scratch),
        .problems = try problems.toOwnedSlice(scratch),
    };
}

fn lessThanName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Replaces every comment and string or character literal with spaces,
/// preserving the length and the line breaks so a token keeps the line and the
/// offset it has in the real file.
///
/// Three literal forms need masking in Zig rather than the two a C header
/// uses: `//` covers `///` and `//!`, `/* */` nests in Zig, and `\\` opens a
/// multiline string that runs to the next line starting with `\\`. An `@"name"`
/// escaped identifier keeps its body, because blanking it would delete an
/// identifier rather than a literal.
fn mask(arena: Allocator, source: []const u8) Allocator.Error![]u8 {
    const out = try arena.dupe(u8, source);
    var i: usize = 0;
    while (i < out.len) {
        const c = out[i];
        if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '*') {
            i = blankNestedComment(out, i);
            continue;
        }
        if (c == '\\' and i + 1 < out.len and out[i + 1] == '\\') {
            i = blankMultilineString(out, i);
            continue;
        }
        if (c == '"' or c == '\'') {
            // `@"name"` is an identifier the `@` introduces, not a string.
            const escaped_identifier = c == '"' and i > 0 and out[i - 1] == '@';
            i = blankQuoted(out, i, c, escaped_identifier);
            continue;
        }
        i += 1;
    }
    return out;
}

/// Blanks a nested block comment and returns the offset just past its `*/`.
fn blankNestedComment(out: []u8, start: usize) usize {
    var depth: u32 = 0;
    var i = start;
    while (i < out.len) : (i += 1) {
        if (out[i] == '/' and i + 1 < out.len and out[i + 1] == '*') {
            depth += 1;
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 1;
            continue;
        }
        if (out[i] == '*' and i + 1 < out.len and out[i + 1] == '/') {
            depth -= 1;
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 1;
            if (depth == 0) return i + 1;
            continue;
        }
        if (out[i] != '\n') out[i] = ' ';
    }
    return i;
}

/// Blanks a multiline string and returns the offset just past its closing
/// line's `\\`.
///
/// Returning the offset is what keeps the line after a closed multiline string
/// readable. A `mask` that resumed where it started would read the closing
/// line's `\\` as the opening of a second string and blank the rest of the
/// file with it, which is the same failure as an unreadable declaration: a
/// symbol that silently stops existing.
fn blankMultilineString(out: []u8, start: usize) usize {
    var i = start;
    out[i] = ' ';
    out[i + 1] = ' ';
    i += 2;
    while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
    while (i < out.len) {
        var probe = i;
        while (probe < out.len and (out[probe] == ' ' or out[probe] == '\t')) probe += 1;
        if (probe + 1 < out.len and out[probe] == '\\' and out[probe + 1] == '\\') {
            var blank = i;
            while (blank < probe + 2 and blank < out.len) : (blank += 1) out[blank] = ' ';
            return probe + 2;
        }
        while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        if (i < out.len) i += 1;
    }
    return i;
}

/// Blanks one quoted literal and returns the offset just past its closing
/// quote. With `keep_body` the quotes and the text between them survive, which
/// is what an `@"name"` escaped identifier needs.
fn blankQuoted(out: []u8, start: usize, quote: u8, keep_body: bool) usize {
    out[start] = if (keep_body) quote else ' ';
    var i = start + 1;
    while (i < out.len and out[i] != quote) : (i += 1) {
        if (out[i] == '\\' and i + 1 < out.len) {
            if (!keep_body) out[i] = ' ';
            i += 1;
            if (i >= out.len) return i;
        }
        if (!keep_body and out[i] != '\n') out[i] = ' ';
    }
    if (i < out.len and out[i] == quote) {
        out[i] = if (keep_body) quote else ' ';
        i += 1;
    }
    return i;
}

const Tok = struct {
    /// Bytes in the masked copy, so a blanked literal reads as blanks.
    text: []const u8,
    /// Byte offset into the original source, which the same length and offset
    /// map onto, so a literal can be read out of it.
    start: usize,
    line: u32,
    kind: Kind,

    const Kind = enum { ident, number, punct, at_sign, quoted };
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn tokenize(
    arena: Allocator,
    source: []const u8,
    masked: []const u8,
) Allocator.Error![]const Tok {
    var out: std.ArrayList(Tok) = .empty;
    var i: usize = 0;
    var line: u32 = 1;
    while (i < masked.len) {
        const c = masked[i];
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (std.ascii.isWhitespace(c)) {
            i += 1;
            continue;
        }
        if (isIdentStart(c)) {
            const start = i;
            while (i < masked.len and isIdentChar(masked[i])) i += 1;
            try out.append(arena, .{
                .text = masked[start..i],
                .start = start,
                .line = line,
                .kind = .ident,
            });
            continue;
        }
        if (std.ascii.isDigit(c)) {
            const start = i;
            while (i < masked.len and
                (std.ascii.isAlphanumeric(masked[i]) or masked[i] == '.')) i += 1;
            try out.append(arena, .{
                .text = masked[start..i],
                .start = start,
                .line = line,
                .kind = .number,
            });
            continue;
        }
        if (c == '@') {
            try out.append(arena, .{ .text = masked[i .. i + 1], .start = i, .line = line, .kind = .at_sign });
            i += 1;
            continue;
        }
        if (c == '"' or c == '\'') {
            const start = i;
            i += 1;
            while (i < masked.len and masked[i] != c) : (i += 1) {
                if (masked[i] == '\\') i += 1;
            }
            if (i < masked.len) i += 1;
            try out.append(arena, .{
                .text = masked[start..i],
                .start = start,
                .line = line,
                .kind = .quoted,
            });
            continue;
        }
        try out.append(arena, .{
            .text = masked[i .. i + 1],
            .start = i,
            .line = line,
            .kind = .punct,
        });
        i += 1;
    }
    _ = source;
    return out.toOwnedSlice(arena);
}

/// What the next token is expected to be while an `if (Guard.x.declaresOn(…))`
/// is being recognised.
const Cond = enum { none, want_open, want_guard, want_dot, want_name };

fn report(
    problems: *std.ArrayList(Problem),
    arena: Allocator,
    file: []const u8,
    line: u32,
    message: []const u8,
) Allocator.Error!void {
    try problems.append(arena, .{
        .file = file,
        .line = line,
        .message = try arena.dupe(u8, message),
    });
}

/// Reads one Zig file and appends what it finds.
fn scanSource(
    arena: Allocator,
    file: []const u8,
    source: []const u8,
    sites: *std.ArrayList(ExportSite),
    problems: *std.ArrayList(Problem),
) Allocator.Error!void {
    const masked = try mask(arena, source);
    const toks = try tokenize(arena, source, masked);

    // The guard every open brace pushed. An empty stack is a portable export.
    var stack: std.ArrayList(?Guard) = .empty;
    var pending: ?Guard = null;
    var cond: Cond = .none;

    var i: usize = 0;
    while (i < toks.len) : (i += 1) {
        const tok = toks[i];
        switch (tok.kind) {
            .at_sign => {
                if (peekIdent(toks, i + 1)) |next| {
                    if (std.mem.eql(u8, next.text, "export")) {
                        try readAtExport(arena, file, source, toks, i, currentGuard(&stack), sites, problems);
                    }
                }
                cond = .none;
                continue;
            },
            .quoted, .number => {
                cond = .none;
                continue;
            },
            .ident => {
                const name = tok.text;
                if (std.mem.eql(u8, name, "export")) {
                    if (peekIdent(toks, i + 1)) |next| {
                        if (std.mem.eql(u8, next.text, "fn")) {
                            try readExportFn(arena, file, toks, i, currentGuard(&stack), sites, problems);
                        }
                    }
                    cond = .none;
                    continue;
                }
                if (std.mem.eql(u8, name, "if")) {
                    cond = .want_open;
                    pending = null;
                    continue;
                }
                if (std.mem.eql(u8, name, "Guard")) {
                    if (cond == .want_guard) cond = .want_dot;
                    continue;
                }
                if (cond == .want_name) {
                    if (std.meta.stringToEnum(Guard, name)) |g| {
                        pending = g;
                    } else {
                        try report(
                            problems,
                            arena,
                            file,
                            tok.line,
                            "a condition names a Guard member this sweep does not know; the guard cannot be read",
                        );
                    }
                    cond = .none;
                    continue;
                }
                cond = .none;
                continue;
            },
            .punct => {
                const c = tok.text[0];
                switch (c) {
                    '(' => if (cond == .want_open) {
                        cond = .want_guard;
                    } else {
                        cond = .none;
                    },
                    '.' => if (cond == .want_dot) {
                        cond = .want_name;
                    } else {
                        cond = .none;
                    },
                    '{' => {
                        try stack.append(arena, pending);
                        pending = null;
                        cond = .none;
                    },
                    '}' => {
                        if (stack.items.len > 0) _ = stack.pop();
                        pending = null;
                        cond = .none;
                    },
                    ';' => {
                        pending = null;
                        cond = .none;
                    },
                    else => cond = .none,
                }
                continue;
            },
        }
    }
}

fn peekIdent(toks: []const Tok, at: usize) ?Tok {
    if (at >= toks.len) return null;
    if (toks[at].kind != .ident) return null;
    return toks[at];
}

fn currentGuard(stack: *const std.ArrayList(?Guard)) ?Guard {
    if (stack.items.len == 0) return null;
    return stack.items[stack.items.len - 1];
}

fn readExportFn(
    arena: Allocator,
    file: []const u8,
    toks: []const Tok,
    at: usize,
    guard: ?Guard,
    sites: *std.ArrayList(ExportSite),
    problems: *std.ArrayList(Problem),
) Allocator.Error!void {
    const name = peekIdent(toks, at + 2) orelse {
        try report(
            problems,
            arena,
            file,
            toks[at].line,
            "`export fn` with no name; the symbol this declaration exports cannot be read",
        );
        return;
    };
    try sites.append(arena, .{
        .symbol = try arena.dupe(u8, name.text),
        .file = file,
        .line = toks[at].line,
        .guard = guard,
        .mechanism = .export_fn,
    });
}

fn readAtExport(
    arena: Allocator,
    file: []const u8,
    source: []const u8,
    toks: []const Tok,
    at: usize,
    guard: ?Guard,
    sites: *std.ArrayList(ExportSite),
    problems: *std.ArrayList(Problem),
) Allocator.Error!void {
    const open = at + 2;
    if (open >= toks.len or toks[open].kind != .punct or toks[open].text[0] != '(') {
        try report(
            problems,
            arena,
            file,
            toks[at].line,
            "`@export` with no argument list; the symbol it names cannot be read",
        );
        return;
    }
    var depth: i32 = 0;
    var end = open;
    while (end < toks.len) : (end += 1) {
        if (toks[end].kind != .punct) continue;
        switch (toks[end].text[0]) {
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) break;
            },
            else => {},
        }
    }
    if (depth != 0) {
        try report(
            problems,
            arena,
            file,
            toks[at].line,
            "`@export(` with no closing parenthesis; the symbol it names cannot be read",
        );
        return;
    }

    var symbol: ?[]const u8 = null;
    var referenced: ?[]const u8 = null;
    var k = open + 1;
    while (k < end) : (k += 1) {
        const tok = toks[k];
        if (tok.kind == .ident and std.mem.eql(u8, tok.text, "name") and k + 2 < end and
            toks[k + 1].text[0] == '=' and toks[k + 2].kind == .quoted)
        {
            const literal = toks[k + 2];
            const raw = source[literal.start..];
            const close = std.mem.indexOfScalar(u8, raw, '"') orelse continue;
            symbol = raw[1..close];
            continue;
        }
        if (referenced == null and tok.kind == .punct and tok.text[0] == '&') {
            if (peekIdent(toks, k + 1)) |next| referenced = next.text;
        }
    }

    const name = symbol orelse {
        try report(
            problems,
            arena,
            file,
            toks[at].line,
            "`@export(` with no `.name = \"…\"`; the symbol it exports cannot be read",
        );
        return;
    };
    if (name.len == 0 or !isIdentStart(name[0])) {
        try report(
            problems,
            arena,
            file,
            toks[at].line,
            "`@export(` names a symbol that is not an identifier; the header cannot declare it",
        );
        return;
    }
    if (referenced) |fn_name| {
        if (!std.mem.eql(u8, fn_name, name)) {
            try report(
                problems,
                arena,
                file,
                toks[at].line,
                "`@export(` names a symbol its Zig function does not carry; the C ABI name and the Zig name disagree",
            );
            return;
        }
    }
    try sites.append(arena, .{
        .symbol = try arena.dupe(u8, name),
        .file = file,
        .line = toks[at].line,
        .guard = guard,
        .mechanism = .at_export,
    });
}

// ------------------------------------------------------------------ tests ---

test "mask blanks comments, literals and multiline strings, and keeps offsets" {
    const gpa = std.testing.allocator;
    const source =
        \\const a = "text"; // export fn phantom
        \\/// doc: export fn also_phantom
        \\/* export fn third_phantom */
        \\const b =
        \\    \\line one export fn fourth_phantom
        \\    \\
        ;
    const out = try mask(gpa, source);
    defer gpa.free(out);
    try std.testing.expectEqual(source.len, out.len);
    for ([_][]const u8{
        "text",
        "export",
        "phantom",
        "also_phantom",
        "third_phantom",
        "fourth_phantom",
        "line",
    }) |word| {
        try std.testing.expect(std.mem.indexOf(u8, out, word) == null);
    }
    try std.testing.expectEqual(@as(usize, 7), std.mem.count(u8, out, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "const") != null);
}

test "mask keeps an escaped identifier and blanks a nested block comment" {
    const gpa = std.testing.allocator;
    const source =
        \\const @"odd name" = 1; /* a /* b */ export fn gone */ const @"other" = 2;
    ;
    const out = try mask(gpa, source);
    defer gpa.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "gone") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "odd name") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "other") != null);
}

test "an export fn and an @export each carry the guard around them" {
    const gpa = std.testing.allocator;
    const source =
        \\export fn accesskit_node_free(node: ?*anyopaque) callconv(.c) void {}
        \\comptime {
        \\    if (Guard.windows.declaresOn(this_platform)) {
        \\        @export(
        \\            &accesskit_windows_adapter_new,
        \\            .{ .name = "accesskit_windows_adapter_new", .linkage = .strong },
        \\        );
        \\    }
        \\}
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sites: std.ArrayList(ExportSite) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    try scanSource(arena.allocator(), "sample.zig", source, &sites, &problems);
    try std.testing.expectEqual(@as(usize, 0), problems.items.len);
    try std.testing.expectEqual(@as(usize, 2), sites.items.len);
    try std.testing.expectEqualStrings("accesskit_node_free", sites.items[0].symbol);
    try std.testing.expect(sites.items[0].guard == null);
    try std.testing.expectEqual(Mechanism.export_fn, sites.items[0].mechanism);
    try std.testing.expectEqualStrings("accesskit_windows_adapter_new", sites.items[1].symbol);
    try std.testing.expectEqual(Guard.windows, sites.items[1].guard.?);
    try std.testing.expectEqual(Mechanism.at_export, sites.items[1].mechanism);
}

test "a guard name the sweep does not know is a problem, not a portable site" {
    const gpa = std.testing.allocator;
    const source =
        \\comptime {
        \\    if (Guard.freebsd_only.declaresOn(this_platform)) {
        \\        @export(&f, .{ .name = "accesskit_freebsd_thing" });
        \\    }
        \\}
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sites: std.ArrayList(ExportSite) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    try scanSource(arena.allocator(), "sample.zig", source, &sites, &problems);
    try std.testing.expectEqual(@as(usize, 0), sites.items.len);
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
}

test "an @export with no readable name is a problem, not a skipped site" {
    const gpa = std.testing.allocator;
    const source = "comptime { @export(&f, .{ .linkage = .strong }); }";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sites: std.ArrayList(ExportSite) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    try scanSource(arena.allocator(), "sample.zig", source, &sites, &problems);
    try std.testing.expectEqual(@as(usize, 0), sites.items.len);
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
}

test "an @export whose name disagrees with its function is a problem" {
    const gpa = std.testing.allocator;
    const source =
        \\comptime {
        \\    if (Guard.unix.declaresOn(this_platform)) {
        \\        @export(&accesskit_unix_adapter_new, .{ .name = "accesskit_unix_adapter_new_typo" });
        \\    }
        \\}
    ;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sites: std.ArrayList(ExportSite) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    try scanSource(arena.allocator(), "sample.zig", source, &sites, &problems);
    try std.testing.expectEqual(@as(usize, 0), sites.items.len);
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
}

test "an export fn with no name is a problem, not a skipped declaration" {
    const gpa = std.testing.allocator;
    const source = "pub export fn () callconv(.c) void {}";
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var sites: std.ArrayList(ExportSite) = .empty;
    var problems: std.ArrayList(Problem) = .empty;
    try scanSource(arena.allocator(), "sample.zig", source, &sites, &problems);
    try std.testing.expectEqual(@as(usize, 0), sites.items.len);
    try std.testing.expectEqual(@as(usize, 1), problems.items.len);
}