//! C header parser for the C ABI parity sweep.
//!
//! One pass over `include/zaccesskit.h` recovers what a C compiler sees: every
//! function declaration with its line, the platform guard that hides it on
//! another target, the type of every parameter and return, and the layout of
//! every laid-out struct. Nothing here is written for one header. The platform
//! names come from a target's predefined macros and the guards are evaluated,
//! so the same code classifies a header whose guards differ.
//!
//! `main.zig` is the only importer. This module opens no file, spawns no
//! process and imports no port code: it takes the header text and returns a
//! `Document`. Every slice in a `Document` borrows one arena the `Document`
//! owns, and `Document.deinit` releases it.
//!
//! **What it does not model.** The preprocessor is modelled only as far as a
//! conditional needs: `defined`, `!`, `&&`, `||`, parentheses, integer
//! literals, `#define`, `#undef` and the six conditional forms. An expression
//! outside that grammar is `error.UnsupportedCondition` naming the line, never
//! a condition that silently reads false. `_Generic`, `__has_include` and
//! computed macro bodies are outside the grammar, and the header uses none.
//! Attributes, `static`, function-pointer variables and function definitions
//! are outside the grammar too, and the header has none of them.
//!
//! **Layout.** Sizes come from `Abi`, not from a probe: the x86-64 System V and
//! the Microsoft x64 models differ on `long` and `wchar_t`, and both are tables
//! in this file. A field type this module cannot size leaves its record with
//! `known = false`, which the caller reports rather than guesses.
//!
//! No loop here walks a closed domain. Each one walks a slice whose length
//! comes from the file being read, so there is no comptime bound to derive. The
//! only closed tables, the builtin layouts below, are `comptime` values.

const std = @import("std");
const Allocator = std.mem.Allocator;

// ----------------------------------------------------------------- target ---

/// The platform a sweep run measures the export surface for.
///
/// The predefined set is what a compiler supplies before it reads a header, and
/// it is the set the header's guards test. `linux` therefore defines
/// `__linux__` and none of `__ANDROID__`, `_WIN32` or `__APPLE__`, which is what
/// leaves the 52 gated declarations outside the Linux set.
pub const Target = enum {
    linux,
    macos,
    ios,
    android,
    windows,

    /// The layout model a target's C compiler uses.
    pub fn abi(self: Target) Abi {
        return switch (self) {
            .linux, .macos, .ios, .android => .sysv_x86_64,
            .windows => .msvc_x64,
        };
    }

    /// The macros this target predefines, with the value each carries.
    ///
    /// `TARGET_OS_*` appear with their real values rather than as bare names,
    /// because the header gates on them by value at lines 80 to 94.
    pub fn predefined(self: Target) []const Predefined {
        return switch (self) {
            .linux => &linux_macros,
            .macos => &macos_macros,
            .ios => &ios_macros,
            .android => &android_macros,
            .windows => &windows_macros,
        };
    }
};

/// One macro a `Target` predefines, with the value it carries in `#if`.
pub const Predefined = struct {
    name: []const u8,
    value: i64,
};

const linux_macros = [_]Predefined{
    .{ .name = "__linux__", .value = 1 },
    .{ .name = "__unix__", .value = 1 },
    .{ .name = "__unix", .value = 1 },
    .{ .name = "__gnu_linux__", .value = 1 },
    .{ .name = "__ELF__", .value = 1 },
    .{ .name = "__LP64__", .value = 1 },
    .{ .name = "_LP64", .value = 1 },
};

const macos_macros = [_]Predefined{
    .{ .name = "__APPLE__", .value = 1 },
    .{ .name = "__MACH__", .value = 1 },
    .{ .name = "TARGET_OS_OSX", .value = 1 },
    .{ .name = "TARGET_OS_IOS", .value = 0 },
    .{ .name = "TARGET_OS_TV", .value = 0 },
    .{ .name = "TARGET_OS_WATCH", .value = 0 },
    .{ .name = "TARGET_OS_VISION", .value = 0 },
    .{ .name = "TARGET_OS_MACCATALYST", .value = 0 },
};

const ios_macros = [_]Predefined{
    .{ .name = "__APPLE__", .value = 1 },
    .{ .name = "__MACH__", .value = 1 },
    .{ .name = "TARGET_OS_OSX", .value = 0 },
    .{ .name = "TARGET_OS_IOS", .value = 1 },
    .{ .name = "TARGET_OS_TV", .value = 0 },
    .{ .name = "TARGET_OS_WATCH", .value = 0 },
    .{ .name = "TARGET_OS_VISION", .value = 0 },
    .{ .name = "TARGET_OS_MACCATALYST", .value = 0 },
};

const android_macros = [_]Predefined{
    .{ .name = "__linux__", .value = 1 },
    .{ .name = "__unix__", .value = 1 },
    .{ .name = "__ANDROID__", .value = 1 },
    .{ .name = "__LP64__", .value = 1 },
};

const windows_macros = [_]Predefined{
    .{ .name = "_WIN32", .value = 1 },
    .{ .name = "_WIN64", .value = 1 },
};

/// The two layout models the sweep computes with.
pub const Abi = enum {
    /// x86-64 System V: `long` and pointers are 8 bytes, `wchar_t` is 4.
    sysv_x86_64,
    /// Microsoft x64: `long` is 4 bytes, `wchar_t` is 2, pointers are 8.
    msvc_x64,
};

/// The platform family a guard names.
pub const Platform = enum {
    portable,
    unix,
    macos,
    apple_mobile,
    android,
    windows,

    /// The name the census table and the report print.
    pub fn label(self: Platform) []const u8 {
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

/// The platform a named macro gates, or `null` when it gates no single
/// platform.
///
/// `__APPLE__` returns `null` on purpose. It is a family marker: the header
/// uses it to wrap the `TARGET_OS_*` block, and a declaration under it also
/// sits under one specific platform macro. A declaration under only `__APPLE__`
/// is therefore `.portable` and gated, which is what it is.
pub fn platformOfMacro(name: []const u8) ?Platform {
    const table = .{
        .{ "ACCESSKIT_MACOS", Platform.macos },
        .{ "TARGET_OS_OSX", Platform.macos },
        .{ "ACCESSKIT_IOS", Platform.apple_mobile },
        .{ "TARGET_OS_MACCATALYST", Platform.apple_mobile },
        .{ "ACCESSKIT_TVOS", Platform.apple_mobile },
        .{ "TARGET_OS_TV", Platform.apple_mobile },
        .{ "ACCESSKIT_VISIONOS", Platform.apple_mobile },
        .{ "ACCESSKIT_WATCHOS", Platform.apple_mobile },
        .{ "TARGET_OS_WATCH", Platform.apple_mobile },
        .{ "TARGET_OS_VISION", Platform.apple_mobile },
        .{ "__ANDROID__", Platform.android },
        .{ "_WIN32", Platform.windows },
        .{ "__linux__", Platform.unix },
        .{ "__DragonFly__", Platform.unix },
        .{ "__FreeBSD__", Platform.unix },
        .{ "__NetBSD__", Platform.unix },
        .{ "__OpenBSD__", Platform.unix },
    };
    inline for (table) |entry| {
        if (std.mem.eql(u8, name, entry[0])) return entry[1];
    }
    return null;
}

// ----------------------------------------------------------------- tokens ---

const Token = struct {
    text: []const u8,
    line: u32,
    kind: Kind,

    const Kind = enum { ident, number, punct };
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn isPunct(t: Token, text: []const u8) bool {
    return t.kind == .punct and std.mem.eql(u8, t.text, text);
}

/// Replaces every comment and string or character literal with spaces.
///
/// The length and the line breaks are preserved, so a token's line and every
/// byte offset still point at the original file. Line continuations are left
/// alone because the directive reader needs the backslash.
fn mask(arena: Allocator, source: []const u8) Allocator.Error![]u8 {
    const out = try arena.alloc(u8, source.len);
    @memcpy(out, source);
    var i: usize = 0;
    while (i < out.len) {
        const c = out[i];
        if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
            continue;
        }
        if (c == '/' and i + 1 < out.len and out[i + 1] == '*') {
            out[i] = ' ';
            out[i + 1] = ' ';
            i += 2;
            while (i < out.len) {
                if (out[i] == '*' and i + 1 < out.len and out[i + 1] == '/') {
                    out[i] = ' ';
                    out[i + 1] = ' ';
                    i += 2;
                    break;
                }
                if (out[i] != '\n') out[i] = ' ';
                i += 1;
            }
            continue;
        }
        if (c == '"' or c == '\'') {
            const quote = c;
            out[i] = ' ';
            i += 1;
            while (i < out.len and out[i] != quote) {
                if (out[i] == '\n') break;
                if (out[i] == '\\') {
                    out[i] = ' ';
                    i += 1;
                    if (i >= out.len) break;
                }
                if (out[i] != '\n') out[i] = ' ';
                i += 1;
            }
            if (i < out.len and out[i] == quote) {
                out[i] = ' ';
                i += 1;
            }
            continue;
        }
        i += 1;
    }
    return out;
}

fn countLines(text: []const u8) u32 {
    var n: u32 = 1;
    for (text) |c| {
        if (c == '\n') n += 1;
    }
    return n;
}

/// The bytes of one 1-based line, without its terminator.
fn lineSlice(text: []const u8, line: u32) []const u8 {
    var start: usize = 0;
    var current: u32 = 1;
    while (current < line) : (current += 1) {
        const at = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return text[start..];
        start = at + 1;
    }
    const end = std.mem.indexOfScalarPos(u8, text, start, '\n') orelse text.len;
    return text[start..end];
}

/// The two-character punctuators the header needs. `||` and `&&` are the only
/// ones a `#if` condition uses; the rest keep a C declarator from being split
/// into single bytes.
const punctuator_pairs = [_][]const u8{
    "&&", "||", "==", "!=", "<=", ">=", "<<", ">>", "->",
};

fn isPunctuatorPair(a: u8, b: u8) bool {
    for (punctuator_pairs) |p| {
        if (p.len == 2 and p[0] == a and p[1] == b) return true;
    }
    return false;
}

fn tokenize(
    arena: Allocator,
    masked: []const u8,
    skip: ?[]const bool,
) Allocator.Error![]const Token {
    var out: std.ArrayList(Token) = .empty;
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
        if (skip) |lines| {
            if (lines[line - 1]) {
                i += 1;
                continue;
            }
        }
        if (isIdentStart(c)) {
            const start = i;
            while (i < masked.len and isIdentChar(masked[i])) i += 1;
            try out.append(arena, .{ .text = masked[start..i], .line = line, .kind = .ident });
            continue;
        }
        if (std.ascii.isDigit(c)) {
            const start = i;
            while (i < masked.len and
                (std.ascii.isAlphanumeric(masked[i]) or masked[i] == '.')) i += 1;
            try out.append(arena, .{ .text = masked[start..i], .line = line, .kind = .number });
            continue;
        }
        if (c == '.' and i + 2 < masked.len and masked[i + 1] == '.' and masked[i + 2] == '.') {
            try out.append(arena, .{ .text = "...", .line = line, .kind = .punct });
            i += 3;
            continue;
        }
        if (i + 1 < masked.len) {
            if (isPunctuatorPair(c, masked[i + 1])) {
                try out.append(arena, .{
                    .text = masked[i .. i + 2],
                    .line = line,
                    .kind = .punct,
                });
                i += 2;
                continue;
            }
        }
        try out.append(arena, .{ .text = masked[i .. i + 1], .line = line, .kind = .punct });
        i += 1;
    }
    return out.toOwnedSlice(arena);
}

// ------------------------------------------------------------- directives ---

const Directive = struct {
    /// Line carrying the `#`.
    start: u32,
    /// Last line of the directive, continuations included.
    end: u32,
    /// The directive name without the `#`.
    name: []const u8,
    /// Everything after the name, continuations spliced and trimmed.
    text: []const u8,
};

/// One `#if` branch: the lines it covers, the condition as written, whether the
/// branch is taken on the target, and the platform its condition names.
pub const Frame = struct {
    /// First body line, inclusive.
    first: u32,
    /// Last body line, inclusive.
    last: u32,
    condition: []const u8,
    active: bool,
    platform: Platform,
};

/// The conditional chain a declaration sits inside.
pub const Guard = struct {
    /// False when any enclosing branch is not taken on the target.
    active: bool,
    /// The platform whose macro the chain names, `.portable` when it names
    /// none.
    platform: Platform,
    /// Enclosing branches, outermost first, taken from the `Document`'s frames.
    branches: []const Frame,

    /// The line of the innermost enclosing branch, or 0 when there is none.
    pub fn line(self: Guard) u32 {
        if (self.branches.len == 0) return 0;
        return self.branches[self.branches.len - 1].first;
    }
};

/// Reads every `#` directive, splicing continuations and marking each
/// directive's lines so the tokenizer skips them.
fn scanDirectives(
    arena: Allocator,
    masked: []const u8,
    skip: []bool,
) Allocator.Error![]const Directive {
    var out: std.ArrayList(Directive) = .empty;
    const line_count = countLines(masked);
    var current: u32 = 1;
    while (current <= line_count) {
        const text = lineSlice(masked, current);
        const hash = std.mem.indexOfScalar(u8, text, '#') orelse {
            current += 1;
            continue;
        };
        if (std.mem.trimStart(u8, text[0..hash], " \t").len != 0) {
            current += 1;
            continue;
        }
        var body: std.ArrayList(u8) = .empty;
        var end: u32 = current;
        var cursor: u32 = current;
        while (true) {
            const raw = lineSlice(masked, cursor);
            const trimmed = std.mem.trim(u8, raw, " \t\r");
            const spliced = std.mem.endsWith(u8, trimmed, "\\");
            const piece = if (spliced) trimmed[0 .. trimmed.len - 1] else trimmed;
            // Only the opening line carries the `#`; a continuation line starts
            // with the rest of the condition, so it loses no leading byte.
            const after_hash = std.mem.trim(
                u8,
                if (cursor == current) piece[1..] else piece,
                " \t",
            );
            if (cursor != current) try body.append(arena, ' ');
            try body.appendSlice(arena, after_hash);
            skip[cursor - 1] = true;
            end = cursor;
            if (!spliced) break;
            cursor += 1;
            if (cursor > line_count) break;
        }
        const joined = std.mem.trim(u8, body.items, " \t");
        var name: []const u8 = "";
        var rest: []const u8 = "";
        if (joined.len != 0 and isIdentStart(joined[0])) {
            var n: usize = 0;
            while (n < joined.len and isIdentChar(joined[n])) n += 1;
            name = joined[0..n];
            rest = std.mem.trim(u8, joined[n..], " \t");
        }
        try out.append(arena, .{
            .start = current,
            .end = end,
            .name = name,
            .text = rest,
        });
        current = end + 1;
    }
    return out.toOwnedSlice(arena);
}

/// Tokenizes the text after a `#`, which is a condition or a define body.
fn tokenizeText(arena: Allocator, text: []const u8) Allocator.Error![]const Token {
    return tokenize(arena, text, null);
}

// ---------------------------------------------------- condition evaluator ---

const ConditionError = error{
    /// A `#if` condition used a form this grammar does not model.
    UnsupportedCondition,
    OutOfMemory,
};

const MacroTable = std.StringHashMapUnmanaged(i64);

const Evaluator = struct {
    tokens: []const Token,
    at: usize = 0,
    macros: *const MacroTable,

    fn peek(self: *Evaluator) ?Token {
        if (self.at < self.tokens.len) return self.tokens[self.at];
        return null;
    }

    fn defined(self: *Evaluator, name: []const u8) bool {
        return self.macros.get(name) != null;
    }

    fn parseOr(self: *Evaluator) ConditionError!bool {
        var left = try self.parseAnd();
        while (self.peek()) |t| {
            if (!isPunct(t, "||")) break;
            self.at += 1;
            const right = try self.parseAnd();
            left = left or right;
        }
        return left;
    }

    fn parseAnd(self: *Evaluator) ConditionError!bool {
        var left = try self.parseUnary();
        while (self.peek()) |t| {
            if (!isPunct(t, "&&")) break;
            self.at += 1;
            const right = try self.parseUnary();
            left = left and right;
        }
        return left;
    }

    fn parseUnary(self: *Evaluator) ConditionError!bool {
        const t = self.peek() orelse return error.UnsupportedCondition;
        if (isPunct(t, "!")) {
            self.at += 1;
            return !(try self.parseUnary());
        }
        return self.parsePrimary();
    }

    fn parsePrimary(self: *Evaluator) ConditionError!bool {
        const t = self.peek() orelse return error.UnsupportedCondition;
        if (isPunct(t, "(")) {
            self.at += 1;
            const inner = try self.parseOr();
            const close = self.peek() orelse return error.UnsupportedCondition;
            if (!isPunct(close, ")")) return error.UnsupportedCondition;
            self.at += 1;
            return inner;
        }
        if (t.kind == .number) {
            self.at += 1;
            const v = std.fmt.parseInt(i64, t.text, 0) catch 0;
            return v != 0;
        }
        if (t.kind != .ident) return error.UnsupportedCondition;
        self.at += 1;
        if (std.mem.eql(u8, t.text, "defined")) {
            const next = self.peek() orelse return error.UnsupportedCondition;
            if (isPunct(next, "(")) {
                const name = self.tokens[self.at + 1];
                const close = self.tokens[self.at + 2];
                if (name.kind != .ident or !isPunct(close, ")")) {
                    return error.UnsupportedCondition;
                }
                self.at += 3;
                return self.defined(name.text);
            }
            if (next.kind != .ident) return error.UnsupportedCondition;
            self.at += 1;
            return self.defined(next.text);
        }
        return self.macros.get(t.text) orelse 0 != 0;
    }
};

const Open = struct {
    active: bool,
    seen_true: bool,
    parent_active: bool,
};

fn allActive(stack: []const Open) bool {
    for (stack) |o| {
        if (!o.active) return false;
    }
    return true;
}

/// Walks the directive list once, tracking the conditional stack, and returns
/// one frame per branch.
fn evaluate(
    arena: Allocator,
    directives: []const Directive,
    target: Target,
) (ConditionError || Allocator.Error)![]const Frame {
    var macros: MacroTable = .empty;
    for (target.predefined()) |pre| try macros.put(arena, pre.name, pre.value);

    var frames: std.ArrayList(Frame) = .empty;
    var open: std.ArrayList(Open) = .empty;

    const pushBranch = struct {
        fn f(
            a: Allocator,
            list: *std.ArrayList(Frame),
            d: Directive,
            taken: bool,
        ) Allocator.Error!void {
            try list.append(a, .{
                .first = d.end + 1,
                .last = 0,
                .condition = d.text,
                .active = taken,
                .platform = platformOfCondition(d.text),
            });
        }
    }.f;

    for (directives) |d| {
        const parent_active = allActive(open.items);
        if (std.mem.eql(u8, d.name, "if")) {
            const tokens = try tokenizeText(arena, d.text);
            var ev: Evaluator = .{ .tokens = tokens, .macros = &macros };
            const taken = parent_active and try ev.parseOr();
            try open.append(arena, .{
                .active = taken,
                .seen_true = taken,
                .parent_active = parent_active,
            });
            try pushBranch(arena, &frames, d, taken);
            continue;
        }
        if (std.mem.eql(u8, d.name, "ifdef") or std.mem.eql(u8, d.name, "ifndef")) {
            const name = std.mem.trim(u8, d.text, " \t");
            const present = macros.get(name) != null;
            const value = if (std.mem.eql(u8, d.name, "ifdef")) present else !present;
            const taken = parent_active and value;
            try open.append(arena, .{
                .active = taken,
                .seen_true = taken,
                .parent_active = parent_active,
            });
            try pushBranch(arena, &frames, d, taken);
            continue;
        }
        if (std.mem.eql(u8, d.name, "elif")) {
            if (open.items.len == 0) return error.UnsupportedCondition;
            const top = &open.items[open.items.len - 1];
            if (!top.parent_active or top.seen_true) {
                top.active = false;
            } else {
                const tokens = try tokenizeText(arena, d.text);
                var ev: Evaluator = .{ .tokens = tokens, .macros = &macros };
                top.active = try ev.parseOr();
                top.seen_true = top.active;
            }
            try pushBranch(arena, &frames, d, top.active);
            continue;
        }
        if (std.mem.eql(u8, d.name, "else")) {
            if (open.items.len == 0) return error.UnsupportedCondition;
            const top = &open.items[open.items.len - 1];
            top.active = top.parent_active and !top.seen_true;
            top.seen_true = true;
            try pushBranch(arena, &frames, d, top.active);
            continue;
        }
        if (std.mem.eql(u8, d.name, "endif")) {
            if (open.items.len == 0) return error.UnsupportedCondition;
            _ = open.pop();
            continue;
        }
        if (!parent_active) continue;
        if (std.mem.eql(u8, d.name, "define")) {
            const tokens = try tokenizeText(arena, d.text);
            if (tokens.len == 0 or tokens[0].kind != .ident) {
                return error.UnsupportedCondition;
            }
            var value: i64 = 0;
            if (tokens.len > 1 and tokens[1].kind == .number) {
                value = std.fmt.parseInt(i64, tokens[1].text, 0) catch 0;
            }
            try macros.put(arena, tokens[0].text, value);
            continue;
        }
        if (std.mem.eql(u8, d.name, "undef")) {
            const name = std.mem.trim(u8, d.text, " \t");
            _ = macros.remove(name);
            continue;
        }
    }
    if (open.items.len != 0) return error.UnsupportedCondition;
    return frames.toOwnedSlice(arena);
}

/// The platform a condition names, `.portable` when it names none.
fn platformOfCondition(condition: []const u8) Platform {
    var i: usize = 0;
    while (i < condition.len) {
        if (isIdentStart(condition[i])) {
            const start = i;
            while (i < condition.len and isIdentChar(condition[i])) i += 1;
            const name = condition[start..i];
            if (!std.mem.eql(u8, name, "defined")) {
                if (platformOfMacro(name)) |p| return p;
            }
            continue;
        }
        i += 1;
    }
    return .portable;
}

/// Closes every branch: a branch runs until the next directive begins, and the
/// last branch of the file runs to its end.
fn closeFrames(
    arena: Allocator,
    directives: []const Directive,
    opened: []const Frame,
    line_count: u32,
) Allocator.Error![]const Frame {
    const out = try arena.alloc(Frame, opened.len);
    for (opened, 0..) |f, fi| {
        var next: ?u32 = null;
        for (directives) |d| {
            if (d.start <= f.first) continue;
            if (next == null or d.start < next.?) next = d.start;
        }
        out[fi] = .{
            .first = f.first,
            .last = if (next) |n| (if (n > 1) n - 1 else line_count) else line_count,
            .condition = f.condition,
            .active = f.active,
            .platform = f.platform,
        };
    }
    return out;
}

// ------------------------------------------------------------------ types ---

/// One C type as a declaration spells it, reduced to what the aggregate census
/// and the layout need.
pub const TypeSpec = struct {
    kind: Kind,
    /// The struct tag, the union tag, the enum tag, or the builtin or typedef
    /// name. Empty when nothing could be read.
    name: []const u8,
    /// The `*` count on the declarator, so `const char **` reports 2.
    pointers: u8,
    /// The declarator is a function pointer, which passes as a pointer.
    function_pointer: bool,
    /// The element count of an `[N]` declarator, 0 when there is no array.
    array_len: u32,
    /// The declarator text carries `const` somewhere. A `const struct X *` is a
    /// borrow and not an allocation.
    spells_const: bool,

    pub const Kind = enum { builtin, @"struct", @"union", @"enum", unknown };

    /// A `TypeSpec` for one builtin or typedef name, with no pointer and no
    /// array on the declarator.
    pub fn named(name: []const u8) TypeSpec {
        return .{
            .kind = .builtin,
            .name = name,
            .pointers = 0,
            .function_pointer = false,
            .array_len = 0,
            .spells_const = false,
        };
    }

    /// A `TypeSpec` with nothing read, which the census counts as neither an
    /// aggregate nor a scalar it can size.
    pub const none: TypeSpec = TypeSpec.named("");

    /// True for a struct or union, which is what the calling convention turns
    /// on when the declarator is not a pointer.
    pub fn isAggregate(self: TypeSpec) bool {
        return self.kind == .@"struct" or self.kind == .@"union";
    }

    /// True when a declaration returning or taking this type hands over a whole
    /// value rather than a reference to one.
    pub fn passesByValue(self: TypeSpec) bool {
        return self.pointers == 0 and self.array_len == 0 and !self.function_pointer;
    }
};

/// The type keywords and qualifiers, which can never be a parameter name.
const type_keywords = [_][]const u8{
    "void",   "char",   "short",    "int",       "long",
    "float",  "double", "signed",   "unsigned",  "_Bool",
    "bool",   "const",  "volatile", "restrict",  "_Atomic",
    "struct", "union",  "enum",     "inline",    "register",
    "static", "extern", "typedef",  "_Noreturn", "auto",
};

fn isTypeKeyword(name: []const u8) bool {
    for (type_keywords) |k| {
        if (std.mem.eql(u8, name, k)) return true;
    }
    return false;
}

fn builtinLayout(abi: Abi, name: []const u8) ?Layout {
    const one = [_][]const u8{
        "bool",          "_Bool",          "char",            "signed char", "unsigned char",
        "int8_t",        "uint8_t",        "__int8_t",        "__uint8_t",   "int_least8_t",
        "uint_least8_t", "__int_least8_t", "__uint_least8_t",
    };
    const two = [_][]const u8{
        "short",   "short int", "signed short", "unsigned short",
        "int16_t", "uint16_t",  "__int16_t",    "__uint16_t",
    };
    const four = [_][]const u8{
        "int",        "signed",  "unsigned", "unsigned int",
        "float",      "int32_t", "uint32_t", "__int32_t",
        "__uint32_t",
    };
    const eight = [_][]const u8{
        "double",             "unsigned long", "long int", "long long",
        "unsigned long long", "int64_t",       "uint64_t", "__int64_t",
        "__uint64_t",         "size_t",        "ssize_t",  "intptr_t",
        "uintptr_t",          "ptrdiff_t",     "time_t",   "clock_t",
        "LRESULT",            "WPARAM",        "LPARAM",   "HRESULT",
        "HINSTANCE",          "BOOL",
    };
    // A bare `long` is 4 bytes under Microsoft x64 and 8 everywhere else, so
    // the eight-byte table leaves it out and this one line answers for it.
    const long_size: u32 = if (abi == .msvc_x64) 4 else 8;
    for (one) |n| {
        if (std.mem.eql(u8, name, n)) return .{ .size = 1, .alignment = 1, .known = true };
    }
    for (two) |n| {
        if (std.mem.eql(u8, name, n)) return .{ .size = 2, .alignment = 2, .known = true };
    }
    for (four) |n| {
        if (std.mem.eql(u8, name, n)) return .{ .size = 4, .alignment = 4, .known = true };
    }
    for (eight) |n| {
        if (std.mem.eql(u8, name, n)) return .{ .size = 8, .alignment = 8, .known = true };
    }
    if (std.mem.eql(u8, name, "long")) {
        return .{ .size = long_size, .alignment = long_size, .known = true };
    }
    if (std.mem.eql(u8, name, "wchar_t")) {
        const w: u32 = if (abi == .msvc_x64) 2 else 4;
        return .{ .size = w, .alignment = w, .known = true };
    }
    if (std.mem.eql(u8, name, "long double")) {
        const d: u32 = if (abi == .msvc_x64) 8 else 16;
        return .{ .size = d, .alignment = d, .known = true };
    }
    return null;
}

/// A byte size and an alignment, and whether both could be computed.
pub const Layout = struct {
    size: u32,
    alignment: u32,
    known: bool,

    /// The value a record carries when one of its field types is not one this
    /// module can size.
    pub const unknown: Layout = .{ .size = 0, .alignment = 0, .known = false };
};

/// Reads a type out of the tokens of a declarator.
fn typeFromTokens(arena: Allocator, toks: []const Token) Allocator.Error!TypeSpec {
    var spec: TypeSpec = .{
        .kind = .unknown,
        .name = "",
        .pointers = 0,
        .function_pointer = false,
        .array_len = 0,
        .spells_const = false,
    };
    var i: usize = 0;
    while (i < toks.len) {
        const t = toks[i];
        if (isPunct(t, "(")) {
            spec.function_pointer = true;
            var depth: i32 = 0;
            while (i < toks.len) : (i += 1) {
                if (isPunct(toks[i], "(")) depth += 1;
                if (isPunct(toks[i], ")")) {
                    depth -= 1;
                    if (depth == 0) break;
                }
            }
            i += 1;
            continue;
        }
        if (isPunct(t, ")")) {
            i += 1;
            continue;
        }
        if (isPunct(t, "*")) {
            spec.pointers += 1;
            i += 1;
            continue;
        }
        if (isPunct(t, "[")) {
            var n: u32 = 0;
            var seen_digit = false;
            i += 1;
            while (i < toks.len and !isPunct(toks[i], "]")) {
                if (toks[i].kind == .number) {
                    n = std.fmt.parseInt(u32, toks[i].text, 0) catch n;
                    seen_digit = true;
                }
                i += 1;
            }
            if (i < toks.len) i += 1;
            spec.array_len = if (seen_digit) n else 0;
            continue;
        }
        if (isPunct(t, "...")) {
            i += 1;
            continue;
        }
        if (t.kind == .ident) {
            if (std.mem.eql(u8, t.text, "const") or std.mem.eql(u8, t.text, "volatile") or
                std.mem.eql(u8, t.text, "restrict") or std.mem.eql(u8, t.text, "_Atomic"))
            {
                spec.spells_const = true;
                i += 1;
                continue;
            }
            if (std.mem.eql(u8, t.text, "struct") or std.mem.eql(u8, t.text, "union") or
                std.mem.eql(u8, t.text, "enum"))
            {
                spec.kind = if (std.mem.eql(u8, t.text, "struct"))
                    .@"struct"
                else if (std.mem.eql(u8, t.text, "union")) .@"union" else .@"enum";
                if (i + 1 < toks.len and toks[i + 1].kind == .ident and
                    !isTypeKeyword(toks[i + 1].text))
                {
                    spec.name = toks[i + 1].text;
                    i += 2;
                    continue;
                }
                i += 1;
                continue;
            }
            if (spec.name.len == 0 and spec.kind == .unknown) {
                spec.kind = .builtin;
                spec.name = t.text;
            }
            i += 1;
            continue;
        }
        i += 1;
    }
    _ = arena;
    return spec;
}

// ------------------------------------------------- records, enums, fields ---

/// One member of a struct or union.
pub const Field = struct {
    name: []const u8,
    type: TypeSpec,
    line: u32,
    /// Set when the member is an inline anonymous struct or union. C counts it
    /// as one member carrying that aggregate's own layout.
    inline_body: ?*Record,
};

/// A laid-out `struct` or `union` with its computed layout.
pub const Record = struct {
    kind: Kind,
    /// Empty for an anonymous record, which is a member rather than a tag.
    tag: []const u8,
    line: u32,
    fields: []const Field,
    layout: Layout,
    /// The offset of each field, in field order. Empty when `layout.known` is
    /// false.
    offsets: []const u32,

    pub const Kind = enum { @"struct", @"union" };
};

/// One `enum` declaration and its variant count.
pub const EnumDef = struct {
    tag: []const u8,
    line: u32,
    variants: usize,
};

/// One `typedef`.
pub const Typedef = struct {
    name: []const u8,
    line: u32,
    kind: Kind,
    /// The aliased type, which is how a typedef of a laid-out struct resolves
    /// to that struct for the layout pass.
    underlying: ?TypeSpec,

    pub const Kind = enum {
        /// A plain alias such as `typedef uint8_t accesskit_role;`, including
        /// the alias a laid-out record ends with.
        alias,
        /// A function-pointer typedef. The header declares four.
        function_pointer,
        /// `typedef struct NAME NAME;` with no body. A C caller holds only the
        /// pointer and the library owns the object.
        opaque_handle,
    };
};

/// One exported data object, `extern const struct ... NAME;`.
pub const Object = struct {
    name: []const u8,
    type: TypeSpec,
    line: u32,
};

/// A top-level construct the classifier did not recognise.
pub const Unparsed = struct {
    line: u32,
    text: []const u8,
};

/// Everything one header read produced. Owns the arena every slice borrows.
pub const Document = struct {
    arena: std.heap.ArenaAllocator,
    target: Target,
    line_count: u32,
    functions: []const Function,
    records: []const Record,
    enums: []const EnumDef,
    typedefs: []const Typedef,
    objects: []const Object,
    unparsed: []const Unparsed,
    frames: []const Frame,
    by_tag: std.StringHashMapUnmanaged(*Record),

    /// Releases every slice in the document. The `Document` is unusable after.
    pub fn deinit(self: *Document) void {
        self.arena.deinit();
        self.* = undefined;
    }

    /// The record with `tag`, or `null` when the header never lays it out.
    pub fn record(self: *const Document, tag: []const u8) ?*Record {
        return self.by_tag.get(tag);
    }

    /// The layout of `tag`, or `Layout.unknown` when the tag is opaque or the
    /// header does not declare it.
    pub fn layoutOf(self: *const Document, tag: []const u8) Layout {
        const rec = self.record(tag) orelse return .unknown;
        return rec.layout;
    }
};

/// One function declaration with its guard.
pub const Function = struct {
    name: []const u8,
    line: u32,
    ret: TypeSpec,
    params: []const Param,
    guard: Guard,

    /// The function is declared on the target the document was read for.
    pub fn onTarget(self: Function) bool {
        return self.guard.active;
    }

    /// The name the report prints, with a class suffix for a non-portable
    /// declaration.
    pub fn qualifiedName(self: Function) []const u8 {
        return self.name;
    }
};

/// One function parameter, or the `...` of a variadic declaration.
pub const Param = struct {
    type: TypeSpec,
    name: []const u8,
    variadic: bool,
    line: u32,
};

const Slice = struct {
    first: usize,
    last: usize,
};

/// Splits `toks` on every `sep` that sits at nesting depth zero, returning the
/// ranges between separators. Empty ranges are dropped, so a trailing comma
/// does not produce a parameter.
fn splitTopLevel(
    arena: Allocator,
    toks: []const Token,
    sep: u8,
) Allocator.Error![]const Slice {
    var out: std.ArrayList(Slice) = .empty;
    var depth: i32 = 0;
    var start: usize = 0;
    for (toks, 0..) |t, i| {
        if (t.kind == .punct) {
            const c = t.text[0];
            if (c == '(' or c == '[' or c == '{') depth += 1;
            if (c == ')' or c == ']' or c == '}') depth -= 1;
        }
        if (depth == 0 and t.kind == .punct and t.text.len == 1 and t.text[0] == sep) {
            if (i > start) try out.append(arena, .{ .first = start, .last = i });
            start = i + 1;
        }
    }
    if (toks.len > start) try out.append(arena, .{ .first = start, .last = toks.len });
    return out.toOwnedSlice(arena);
}

/// The index of the token closing the bracket at `open`, or `null`.
fn matchBracket(toks: []const Token, open: usize) ?usize {
    var depth: i32 = 0;
    for (toks[open..], open..) |t, i| {
        if (t.kind != .punct) continue;
        if (t.text.len != 1) continue;
        switch (t.text[0]) {
            '(', '[', '{' => depth += 1,
            ')', ']', '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// The function declarator in a declaration, or `null` when there is none.
const FuncShape = struct {
    name: []const u8,
    /// Index of the name token.
    name_at: usize,
    /// Index of the opening parenthesis.
    open: usize,
    /// Index of the closing parenthesis.
    close: usize,
};

fn functionDeclarator(slice: []const Token) ?FuncShape {
    var depth: i32 = 0;
    for (slice, 0..) |t, i| {
        if (t.kind != .punct or !std.mem.eql(u8, t.text, "(")) continue;
        if (depth == 0) {
            if (i > 0) {
                const prev = slice[i - 1];
                if (prev.kind == .ident and !isTypeKeyword(prev.text)) {
                    const close = matchBracket(slice, i) orelse return null;
                    if (close + 1 == slice.len) {
                        return .{
                            .name = prev.text,
                            .name_at = i - 1,
                            .open = i,
                            .close = close,
                        };
                    }
                }
            }
        }
        depth += 1;
    }
    return null;
}

/// The name in `(*NAME)(` of a function-pointer typedef, or `null`.
fn functionPointerName(slice: []const Token) ?[]const u8 {
    for (slice, 0..) |t, i| {
        if (!isPunct(t, "(")) continue;
        if (i + 2 < slice.len and isPunct(slice[i + 1], "*") and
            slice[i + 2].kind == .ident)
        {
            return slice[i + 2].text;
        }
    }
    return null;
}

fn parseParams(
    arena: Allocator,
    toks: []const Token,
) Allocator.Error![]const Param {
    const parts = try splitTopLevel(arena, toks, ',');
    var out: std.ArrayList(Param) = .empty;
    for (parts) |part| {
        const chunk = toks[part.first..part.last];
        if (chunk.len == 0) continue;
        if (isPunct(chunk[0], "...") and chunk.len == 1) {
            try out.append(arena, .{
                .type = .{
                    .kind = .unknown,
                    .name = "",
                    .pointers = 0,
                    .function_pointer = false,
                    .array_len = 0,
                    .spells_const = false,
                },
                .name = "",
                .variadic = true,
                .line = chunk[0].line,
            });
            continue;
        }
        if (functionPointerName(chunk)) |pointer_name| {
            try out.append(arena, .{
                .type = try typeFromTokens(arena, chunk),
                .name = pointer_name,
                .variadic = false,
                .line = chunk[0].line,
            });
            continue;
        }
        var name: []const u8 = "";
        var type_toks = chunk;
        const last = chunk[chunk.len - 1];
        if (chunk.len > 1 and last.kind == .ident and !isTypeKeyword(last.text)) {
            const before = chunk[chunk.len - 2];
            const before_is_tag = before.kind == .ident and
                (std.mem.eql(u8, before.text, "struct") or
                    std.mem.eql(u8, before.text, "union") or
                    std.mem.eql(u8, before.text, "enum"));
            if (!before_is_tag) {
                name = last.text;
                type_toks = chunk[0 .. chunk.len - 1];
            }
        }
        try out.append(arena, .{
            .type = try typeFromTokens(arena, type_toks),
            .name = name,
            .variadic = false,
            .line = chunk[0].line,
        });
    }
    return out.toOwnedSlice(arena);
}

/// The tag in `struct TAG {`, `union TAG {` or `enum TAG {`, or an empty slice
/// when the tag is anonymous.
fn recordTag(slice: []const Token) []const u8 {
    for (slice, 0..) |t, i| {
        if (t.kind != .ident) continue;
        if (!std.mem.eql(u8, t.text, "struct") and !std.mem.eql(u8, t.text, "union") and
            !std.mem.eql(u8, t.text, "enum")) continue;
        const next = if (i + 1 < slice.len) slice[i + 1] else Token{
            .text = "",
            .line = t.line,
            .kind = .punct,
        };
        if (next.kind == .ident and !isTypeKeyword(next.text)) return next.text;
        return "";
    }
    return "";
}

fn parseFields(
    arena: Allocator,
    body: []const Token,
) Allocator.Error![]const Field {
    const parts = try splitTopLevel(arena, body, ';');
    var out: std.ArrayList(Field) = .empty;
    for (parts) |part| {
        const chunk = body[part.first..part.last];
        if (chunk.len == 0) continue;
        var nested: ?*Record = null;
        var type_toks = chunk;
        var name: []const u8 = "";
        const brace = blk: {
            for (chunk, 0..) |t, i| {
                if (isPunct(t, "{")) break :blk i;
            }
            break :blk null;
        };
        if (brace) |open| {
            const close = matchBracket(chunk, open) orelse continue;
            const rec = try parseRecord(
                arena,
                chunk[0..open],
                chunk[open + 1 .. close],
                chunk[open].line,
            );
            nested = rec;
            type_toks = chunk[0..open];
            const tail = chunk[close + 1 ..];
            if (tail.len != 0 and tail[tail.len - 1].kind == .ident) {
                name = tail[tail.len - 1].text;
            }
        } else {
            const last = chunk[chunk.len - 1];
            if (chunk.len > 1 and last.kind == .ident and !isTypeKeyword(last.text)) {
                const before = chunk[chunk.len - 2];
                const before_is_tag = before.kind == .ident and
                    (std.mem.eql(u8, before.text, "struct") or
                        std.mem.eql(u8, before.text, "union") or
                        std.mem.eql(u8, before.text, "enum"));
                if (!before_is_tag) {
                    name = last.text;
                    type_toks = chunk[0 .. chunk.len - 1];
                }
            }
        }
        try out.append(arena, .{
            .name = name,
            .type = try typeFromTokens(arena, type_toks),
            .line = chunk[0].line,
            .inline_body = nested,
        });
    }
    return out.toOwnedSlice(arena);
}

fn parseRecord(
    arena: Allocator,
    head: []const Token,
    body: []const Token,
    line: u32,
) Allocator.Error!*Record {
    const rec = try arena.create(Record);
    rec.* = .{
        .kind = .@"struct",
        .tag = recordTag(head),
        .line = line,
        .fields = &.{},
        .layout = .unknown,
        .offsets = &.{},
    };
    for (head) |t| {
        if (t.kind == .ident and std.mem.eql(u8, t.text, "union")) rec.kind = .@"union";
    }
    rec.fields = try parseFields(arena, body);
    return rec;
}

// ----------------------------------------------------------------- layout ---

const LayoutCtx = struct {
    abi: Abi,
    by_tag: *const std.StringHashMapUnmanaged(*Record),
    typedefs: []const Typedef,
    arena: Allocator,
    resolving: std.StringHashMapUnmanaged(void),

    /// The layout of `spec`, following typedef aliases to the record they name.
    fn ofType(ctx: *LayoutCtx, spec: TypeSpec) Layout {
        if (spec.function_pointer) return .{ .size = 8, .alignment = 8, .known = true };
        if (spec.pointers > 0) return .{ .size = 8, .alignment = 8, .known = true };
        switch (spec.kind) {
            .@"struct" => {
                const rec = ctx.by_tag.get(spec.name) orelse return .unknown;
                return ctx.ofRecord(rec);
            },
            .@"union" => {
                const rec = ctx.by_tag.get(spec.name) orelse return .unknown;
                return ctx.ofRecord(rec);
            },
            .@"enum" => return Layout{ .size = 4, .alignment = 4, .known = true },
            .builtin => {
                if (builtinLayout(ctx.abi, spec.name)) |l| return l;
                if (ctx.alias(spec.name)) |target| {
                    if (std.mem.eql(u8, target.name, spec.name)) return .unknown;
                    return ctx.ofType(target);
                }
                return .unknown;
            },
            .unknown => return .unknown,
        }
    }

    /// The alias `name` stands for, or `null` when it is not a typedef.
    fn alias(ctx: *LayoutCtx, name: []const u8) ?TypeSpec {
        for (ctx.typedefs) |td| {
            if (!std.mem.eql(u8, td.name, name)) continue;
            if (td.kind == .function_pointer) {
                return .{
                    .kind = .unknown,
                    .name = name,
                    .pointers = 1,
                    .function_pointer = true,
                    .array_len = 0,
                    .spells_const = false,
                };
            }
            return td.underlying;
        }
        return null;
    }

    /// The layout of a record, memoized through the resolver set so a
    /// by-value cycle is reported as unknown rather than looped over.
    fn ofRecord(ctx: *LayoutCtx, rec: *Record) Layout {
        if (rec.layout.known) return rec.layout;
        if (rec.tag.len != 0) {
            if (ctx.resolving.contains(rec.tag)) return .unknown;
            ctx.resolving.put(ctx.arena, rec.tag, {}) catch return .unknown;
        }
        const fields = rec.fields;
        const offsets = ctx.arena.alloc(u32, fields.len) catch return .unknown;
        var offset: u32 = 0;
        var max_align: u32 = 1;
        var max_size: u32 = 0;
        var known = true;
        for (fields, 0..) |f, fi| {
            // SAFETY: the branch below writes `l` before any read of it on the
            // same iteration, so no iteration reads the undefined value from
            // this line. A taken branch never skips the write.
            var l: Layout = undefined;
            if (f.inline_body) |body| {
                l = ctx.ofRecord(body);
            } else {
                l = ctx.ofType(f.type);
            }
            if (f.type.array_len != 0 and l.known and f.inline_body == null) {
                l = .{
                    .size = l.size * f.type.array_len,
                    .alignment = l.alignment,
                    .known = true,
                };
            }
            if (!l.known) known = false;
            if (l.known) {
                const aligned = alignForward(offset, l.alignment);
                offsets[fi] = if (rec.kind == .@"union") 0 else aligned;
                offset = if (rec.kind == .@"union") offset else aligned + l.size;
                if (l.size > max_size) max_size = l.size;
                if (l.alignment > max_align) max_align = l.alignment;
            } else {
                offsets[fi] = 0;
            }
        }
        if (!known) {
            if (rec.tag.len != 0) _ = ctx.resolving.remove(rec.tag);
            return .unknown;
        }
        const size = alignForward(offset, max_align);
        rec.layout = .{
            .size = if (rec.kind == .@"union") alignForward(max_size, max_align) else size,
            .alignment = max_align,
            .known = true,
        };
        rec.offsets = offsets;
        if (rec.tag.len != 0) _ = ctx.resolving.remove(rec.tag);
        return rec.layout;
    }
};

/// Rounds `value` up to a multiple of `alignment`, which is 1 or a power of
/// two.
pub fn alignForward(value: u32, alignment: u32) u32 {
    if (alignment <= 1) return value;
    const low_bits = alignment - 1;
    return (value + low_bits) & ~low_bits;
}

fn computeLayouts(
    arena: Allocator,
    records: []Record,
    by_tag: std.StringHashMapUnmanaged(*Record),
    typedefs: []const Typedef,
    abi: Abi,
) void {
    var ctx: LayoutCtx = .{
        .abi = abi,
        .by_tag = &by_tag,
        .typedefs = typedefs,
        .arena = arena,
        .resolving = .empty,
    };
    for (records) |*rec| _ = ctx.ofRecord(rec);
}

// ----------------------------------------------------------------- parser ---

const Listings = struct {
    functions: *std.ArrayList(Function),
    records: *std.ArrayList(Record),
    enums: *std.ArrayList(EnumDef),
    typedefs: *std.ArrayList(Typedef),
    objects: *std.ArrayList(Object),
    unparsed: *std.ArrayList(Unparsed),
};

/// Reads `source` as C and returns what it declares.
///
/// Allocates through `gpa` and keeps nothing after `Document.deinit`. The
/// `Document` owns an arena, so no slice in it outlives it. Errors are
/// `error.OutOfMemory` and `error.UnsupportedCondition`; the second means a
/// `#if` used a form this grammar does not model.
pub fn parse(
    gpa: Allocator,
    source: []const u8,
    target: Target,
) (ConditionError || Allocator.Error)!Document {
    var state: std.heap.ArenaAllocator = .init(gpa);
    errdefer state.deinit();
    const arena = state.allocator();

    const masked = try mask(arena, source);
    const line_count = countLines(masked);
    const skip = try arena.alloc(bool, line_count);
    @memset(skip, false);
    const directives = try scanDirectives(arena, masked, skip);
    const opened = try evaluate(arena, directives, target);
    const frames = try closeFrames(arena, directives, opened, line_count);
    const tokens = try tokenize(arena, masked, skip);

    var functions: std.ArrayList(Function) = .empty;
    var records: std.ArrayList(Record) = .empty;
    var enums: std.ArrayList(EnumDef) = .empty;
    var typedefs: std.ArrayList(Typedef) = .empty;
    var objects: std.ArrayList(Object) = .empty;
    var unparsed: std.ArrayList(Unparsed) = .empty;
    var listings: Listings = .{
        .functions = &functions,
        .records = &records,
        .enums = &enums,
        .typedefs = &typedefs,
        .objects = &objects,
        .unparsed = &unparsed,
    };

    var i: usize = 0;
    var in_extern_block = false;
    while (i < tokens.len) {
        const tok = tokens[i];
        if (isPunct(tok, ";")) {
            i += 1;
            continue;
        }
        if (in_extern_block and isPunct(tok, "}")) {
            in_extern_block = false;
            i += 1;
            continue;
        }
        if (!in_extern_block and tok.kind == .ident and std.mem.eql(u8, tok.text, "extern")) {
            if (i + 1 < tokens.len and isPunct(tokens[i + 1], "{")) {
                in_extern_block = true;
                i += 2;
                continue;
            }
        }

        const start = i;
        var paren: i32 = 0;
        var brace: i32 = 0;
        var bracket: i32 = 0;
        while (i < tokens.len) : (i += 1) {
            const t = tokens[i];
            if (t.kind != .punct or t.text.len != 1) continue;
            switch (t.text[0]) {
                '(' => paren += 1,
                ')' => paren -= 1,
                '[' => bracket += 1,
                ']' => bracket -= 1,
                '{' => brace += 1,
                '}' => brace -= 1,
                ';' => if (brace == 0) {
                    break;
                },
                else => {},
            }
        }
        const slice = tokens[start..i];
        if (i < tokens.len) i += 1;
        if (slice.len == 0) continue;
        try classify(arena, slice, frames, &listings);
    }

    var by_tag: std.StringHashMapUnmanaged(*Record) = .empty;
    for (records.items) |*rec| {
        if (rec.tag.len != 0) try by_tag.put(arena, rec.tag, rec);
    }
    const typedef_slice = try typedefs.toOwnedSlice(arena);
    computeLayouts(arena, records.items, by_tag, typedef_slice, target.abi());

    return .{
        .arena = state,
        .target = target,
        .line_count = line_count,
        .functions = try functions.toOwnedSlice(arena),
        .records = try records.toOwnedSlice(arena),
        .enums = try enums.toOwnedSlice(arena),
        .typedefs = typedef_slice,
        .objects = try objects.toOwnedSlice(arena),
        .unparsed = try unparsed.toOwnedSlice(arena),
        .frames = frames,
        .by_tag = by_tag,
    };
}

/// The chain of branches covering `line`, as a slice of the document's frames.
fn guardAt(frames: []const Frame, line: u32) Guard {
    var first: usize = frames.len;
    var past: usize = 0;
    for (frames, 0..) |f, i| {
        if (line < f.first or line > f.last) continue;
        if (i < first) first = i;
        past = i + 1;
    }
    if (first > past) return .{ .active = true, .platform = .portable, .branches = &.{} };
    const branches = frames[first..past];
    var active = true;
    var platform: Platform = .portable;
    for (branches) |b| {
        if (!b.active) active = false;
    }
    // The innermost named platform wins. `__APPLE__` names none, so a family
    // marker never masks the specific macro under it.
    var bi = branches.len;
    while (bi > 0) {
        bi -= 1;
        if (branches[bi].platform != .portable) {
            platform = branches[bi].platform;
            break;
        }
    }
    return .{ .active = active, .platform = platform, .branches = branches };
}

fn joinTokens(arena: Allocator, toks: []const Token) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (toks, 0..) |t, i| {
        if (i != 0) try out.append(arena, ' ');
        try out.appendSlice(arena, t.text);
    }
    return out.toOwnedSlice(arena);
}

fn classify(
    arena: Allocator,
    slice: []const Token,
    frames: []const Frame,
    out: *Listings,
) Allocator.Error!void {
    const line = slice[0].line;
    const guard = guardAt(frames, line);
    const is_typedef = slice[0].kind == .ident and std.mem.eql(u8, slice[0].text, "typedef");
    const body = if (is_typedef) slice[1..] else slice;

    if (is_typedef) {
        if (functionPointerName(body)) |pointer_name| {
            try out.typedefs.append(arena, .{
                .name = pointer_name,
                .line = line,
                .kind = .function_pointer,
                .underlying = null,
            });
            return;
        }
    }

    const open = blk: {
        for (body, 0..) |t, i| {
            if (isPunct(t, "{")) break :blk i;
        }
        break :blk null;
    };
    if (open) |o| {
        const close = matchBracket(body, o) orelse {
            try out.unparsed.append(arena, .{
                .line = line,
                .text = try joinTokens(arena, slice),
            });
            return;
        };
        const is_enum = blk: {
            for (body[0..o]) |t| {
                if (t.kind == .ident and std.mem.eql(u8, t.text, "enum")) break :blk true;
            }
            break :blk false;
        };
        const inner = body[o + 1 .. close];
        if (is_enum) {
            var variants: usize = 0;
            for (try splitTopLevel(arena, inner, ',')) |part| {
                if (part.last > part.first) variants += 1;
            }
            try out.enums.append(arena, .{
                .tag = recordTag(body[0..o]),
                .line = line,
                .variants = variants,
            });
            return;
        }
        const rec = try parseRecord(arena, body[0..o], inner, line);
        try out.records.append(arena, rec.*);
        // `typedef struct NAME { ... } NAME;` also names the type.
        if (is_typedef) {
            const last = body[body.len - 1];
            if (last.kind == .ident and !isTypeKeyword(last.text)) {
                try out.typedefs.append(arena, .{
                    .name = last.text,
                    .line = line,
                    .kind = .alias,
                    .underlying = .{
                        .kind = if (rec.kind == .@"union") .@"union" else .@"struct",
                        .name = rec.tag,
                        .pointers = 0,
                        .function_pointer = false,
                        .array_len = 0,
                        .spells_const = false,
                    },
                });
            }
        }
        return;
    }

    if (functionDeclarator(body)) |shape| {
        try out.functions.append(arena, .{
            .name = shape.name,
            .line = line,
            .ret = try typeFromTokens(arena, body[0..shape.name_at]),
            .params = try parseParams(arena, body[shape.open + 1 .. shape.close]),
            .guard = guard,
        });
        return;
    }

    if (is_typedef) {
        var type_toks = body;
        var name: []const u8 = "";
        const last = body[body.len - 1];
        if (body.len > 1 and last.kind == .ident and !isTypeKeyword(last.text)) {
            const before = body[body.len - 2];
            const before_is_tag = before.kind == .ident and
                (std.mem.eql(u8, before.text, "struct") or
                    std.mem.eql(u8, before.text, "union") or
                    std.mem.eql(u8, before.text, "enum"));
            if (!before_is_tag) {
                name = last.text;
                type_toks = body[0 .. body.len - 1];
            }
        }
        const underlying = try typeFromTokens(arena, type_toks);
        const kind: Typedef.Kind = if (underlying.kind == .@"struct" or
            underlying.kind == .@"union") .opaque_handle else .alias;
        try out.typedefs.append(arena, .{
            .name = if (name.len != 0)
                name
            else if (underlying.name.len != 0)
                underlying.name
            else
                "",
            .line = line,
            .kind = kind,
            .underlying = underlying,
        });
        return;
    }

    const last = slice[slice.len - 1];
    if (slice.len > 1 and last.kind == .ident and !isTypeKeyword(last.text)) {
        try out.objects.append(arena, .{
            .name = last.text,
            .type = try typeFromTokens(arena, slice[0 .. slice.len - 1]),
            .line = line,
        });
        return;
    }
    try out.unparsed.append(arena, .{
        .line = line,
        .text = try joinTokens(arena, slice),
    });
}

// ------------------------------------------------------------------ tests ---

test "mask blanks comments and literals but keeps every line break" {
    const gpa = std.testing.allocator;
    const source = "a; // one\n/* two\nthree */ b; char *c = \"str\";\n";
    const out = try mask(gpa, source);
    defer gpa.free(out);
    try std.testing.expectEqual(source.len, out.len);
    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, out, "\n"));
    try std.testing.expect(std.mem.indexOf(u8, out, "one") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "three") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "str") == null);
    try std.testing.expect(std.mem.indexOf(u8, out, "b;") != null);
}

test "lineSlice returns the line without its terminator" {
    try std.testing.expectEqualStrings("b", lineSlice("a\nb\nc", 2));
    try std.testing.expectEqualStrings("c", lineSlice("a\nb\nc", 3));
}

test "a Linux guard chain hides a declaration and a portable one stays" {
    const gpa = std.testing.allocator;
    const source =
        \\#ifdef __APPLE__
        \\int guarded(void);
        \\#endif
        \\int portable(void);
        \\#if defined(__ANDROID__)
        \\int android_only(void);
        \\#endif
    ;
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.functions.len);
    var active: usize = 0;
    var platforms: [3]Platform = undefined;
    for (doc.functions, 0..) |f, i| {
        platforms[i] = f.guard.platform;
        if (f.guard.active) active += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), active);
    try std.testing.expectEqual(Platform.portable, platforms[0]);
    try std.testing.expectEqual(Platform.portable, platforms[1]);
    try std.testing.expectEqual(Platform.android, platforms[2]);
}

test "an Apple target turns the macOS branch on and the Android branch off" {
    const gpa = std.testing.allocator;
    // The header derives ACCESSKIT_MACOS from TARGET_OS_OSX, so the fixture
    // gates on the same macro the header gates on.
    const source =
        \\#if TARGET_OS_OSX
        \\int macos_only(void);
        \\#endif
        \\#if defined(__ANDROID__)
        \\int android_only(void);
        \\#endif
        \\int portable(void);
    ;
    var doc = try parse(gpa, source, .macos);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 3), doc.functions.len);
    try std.testing.expect(doc.functions[0].guard.active);
    try std.testing.expectEqual(Platform.macos, doc.functions[0].guard.platform);
    try std.testing.expect(!doc.functions[1].guard.active);
    try std.testing.expectEqual(Platform.android, doc.functions[1].guard.platform);
    try std.testing.expect(doc.functions[2].guard.active);
}

test "a Linux chain that excludes Android is off there and still reads as unix" {
    const gpa = std.testing.allocator;
    // The shape `include/zaccesskit.h:1022` and `:6263` use. `__ANDROID__`
    // defines `__linux__`, so the exclusion has to be spelled for the block to
    // be off on Android at all, and the scanner has to keep naming the branch
    // unix rather than android for the class column to stay the unix row.
    const source =
        \\#if (defined(__linux__) || defined(__OpenBSD__)) && !defined(__ANDROID__)
        \\int unix_only(void);
        \\#endif
    ;
    var linux = try parse(gpa, source, .linux);
    defer linux.deinit();
    try std.testing.expectEqual(@as(usize, 1), linux.functions.len);
    try std.testing.expect(linux.functions[0].guard.active);
    try std.testing.expectEqual(Platform.unix, linux.functions[0].guard.platform);

    var android = try parse(gpa, source, .android);
    defer android.deinit();
    try std.testing.expectEqual(@as(usize, 1), android.functions.len);
    try std.testing.expect(!android.functions[0].guard.active);
    try std.testing.expectEqual(Platform.unix, android.functions[0].guard.platform);
}

test "a struct return and a struct parameter are seen as aggregates" {
    const gpa = std.testing.allocator;
    const source =
        \\struct pair { int a; int b; };
        \\struct pair make(struct pair p, int n);
        \\int take(struct pair p, const struct pair *q, int r);
    ;
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.functions.len);
    try std.testing.expect(doc.functions[0].ret.isAggregate());
    try std.testing.expectEqualStrings("pair", doc.functions[0].ret.name);
    try std.testing.expect(doc.functions[0].params[0].type.isAggregate());
    try std.testing.expect(doc.functions[0].params[0].type.passesByValue());
    try std.testing.expect(doc.functions[0].params[1].type.passesByValue());
    try std.testing.expectEqualStrings("n", doc.functions[0].params[1].name);
    try std.testing.expect(!doc.functions[1].ret.isAggregate());
    try std.testing.expectEqual(@as(u8, 1), doc.functions[1].params[1].type.pointers);
}

test "a function-pointer typedef is not a function declaration" {
    const gpa = std.testing.allocator;
    const source =
        \\struct update;
        \\typedef struct update *(*accesskit_factory)(void *userdata);
        \\typedef void (*accesskit_handler)(void *userdata, int code);
    ;
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 0), doc.functions.len);
    try std.testing.expectEqual(@as(usize, 2), doc.typedefs.len);
    try std.testing.expectEqual(Typedef.Kind.function_pointer, doc.typedefs[0].kind);
    try std.testing.expectEqualStrings("accesskit_factory", doc.typedefs[0].name);
}

test "an opaque handle is a typedef with no body" {
    const gpa = std.testing.allocator;
    const source =
        \\typedef struct accesskit_node accesskit_node;
        \\typedef struct accesskit_rect { double x; double y; } accesskit_rect;
    ;
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 2), doc.typedefs.len);
    try std.testing.expectEqual(Typedef.Kind.opaque_handle, doc.typedefs[0].kind);
    try std.testing.expectEqualStrings("accesskit_node", doc.typedefs[0].name);
    try std.testing.expectEqual(@as(usize, 1), doc.records.len);
    try std.testing.expectEqualStrings("accesskit_rect", doc.records[0].tag);
    try std.testing.expect(doc.records[0].layout.known);
    try std.testing.expectEqual(@as(u32, 16), doc.records[0].layout.size);
    try std.testing.expectEqual(@as(u32, 8), doc.records[0].layout.alignment);
    try std.testing.expectEqual(@as(u32, 0), doc.records[0].offsets[0]);
    try std.testing.expectEqual(@as(u32, 8), doc.records[0].offsets[1]);
}

test "an enum counts its variants and the alias after it resolves to a byte" {
    const gpa = std.testing.allocator;
    const source =
        \\typedef uint8_t accesskit_role;
        \\enum accesskit_toggled { ACCESSKIT_TOGGLED_FALSE, ACCESSKIT_TOGGLED_TRUE, };
        \\typedef uint8_t accesskit_toggled;
    ;
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.enums.len);
    try std.testing.expectEqual(@as(usize, 2), doc.enums[0].variants);
    try std.testing.expectEqualStrings("accesskit_toggled", doc.enums[0].tag);
    const alias: LayoutCtx = .{
        .abi = .sysv_x86_64,
        .by_tag = &doc.by_tag,
        .typedefs = doc.typedefs,
        .arena = gpa,
        .resolving = .empty,
    };
    var ctx = alias;
    const l = ctx.ofType(TypeSpec.named("accesskit_toggled"));
    try std.testing.expectEqual(@as(u32, 1), l.size);
}

test "a record that holds itself by value is reported unknown, not looped over" {
    const gpa = std.testing.allocator;
    const source = "struct loop { struct loop inner; int x; };";
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.records.len);
    try std.testing.expect(!doc.records[0].layout.known);
}

test "an extern C block does not hide the declarations inside it" {
    const gpa = std.testing.allocator;
    const source =
        \\#ifdef __cplusplus
        \\extern "C" {
        \\#endif
        \\extern const int ROOT;
        \\int visible(void);
        \\#ifdef __cplusplus
        \\}
        \\#endif
    ;
    var doc = try parse(gpa, source, .linux);
    defer doc.deinit();
    try std.testing.expectEqual(@as(usize, 1), doc.functions.len);
    try std.testing.expectEqualStrings("visible", doc.functions[0].name);
    try std.testing.expectEqual(@as(usize, 1), doc.objects.len);
    try std.testing.expectEqualStrings("ROOT", doc.objects[0].name);
    try std.testing.expectEqual(@as(usize, 0), doc.unparsed.len);
}
