//! Reads the consumer layer and answers, for every module, which symbols of
//! which other modules it names.
//!
//! **The tokenizer is `std.zig.Ast`, not a hand-written one.** Three facts make
//! that the whole answer, and each one is a place a regex scanner goes wrong:
//!
//! - A doc comment is a token. `.doc_comment` and `.container_doc_comment`
//!   are token tags, so a doc comment that quotes `properties.role` is
//!   invisible without any masking pass. A plain `//` comment has no tag at
//!   all: the tokenizer consumes it and emits nothing.
//! - A string literal is one token. `@import("x.zig")` arrives as `.builtin`,
//!   `.l_paren`, `.string_literal`, `.r_paren`, so the path needs no offset
//!!   arithmetic against a blanked copy.
//! - A qualified name is tokens. `alias.Symbol` is `.identifier .period
//!   .identifier`, and `std.mem.indexOfNone` style scanning is not needed to
//!   tell `node.tree_state.nodes` from `tree_state.nodes`: the first is a
//!   three-link chain whose head is `node`, and only a chain whose head is a
//!   file-scope import alias names a module.
//!
//! **Three resolutions, and each has a case that must not be guessed.**
//!
//! 1. `const alias = @import("path")` binds a module. Zig resolves a bare
//!    `"sibling.zig"` against the importing file's own directory, so the target
//!    needs no `./` to be a file. A name with no file behind it is `std` or a
//!    package, and neither is a row.
//! 2. `const NAME = @import("path").Symbol` binds that symbol, not the module.
//!    The rparen's follower is what tells the two apart, so the scanner reads
//!    the token after the rparen rather than guessing from the line.
//! 3. `pub const X = alias.Name` re-exports. The owning module is the one
//!    behind `alias`, not the file holding the re-export, so `schema.Affine`
//!    resolves to `src/schema/geometry/affine.zig`. The chain is walked to a
//!    fixed depth and a name that survives it is reported, not dropped.
//!
//! **A name that resolves to nothing is a finding with both files.** The
//! alternative is the failure this tool exists to prevent: a symbol that quietly
//! stops existing leaves the table smaller and the diff empty, so a broken row
//! and a clean run look the same.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Ast = std.zig.Ast;
const TokenIndex = Ast.TokenIndex;
const NodeIndex = Ast.Node.Index;

/// The deepest re-export chain the scanner walks before it calls a name
/// unresolvable. A chain longer than this is a cycle in the namespace tree, and
/// a cycle is reported rather than followed.
pub const chain_depth_limit = 32;

/// One file, and what it says about the rest of the tree.
pub const Module = struct {
    /// The repository-relative path, which is the module's identity.
    path: []const u8,
    /// The directory holding `path`, without the trailing separator.
    dir: []const u8,
    /// File-scope `const NAME = @import("path")`, when the target is a file.
    aliases: std.StringArrayHashMapUnmanaged([]const u8) = .empty,
    /// `pub` names at file scope, plus `Type.method` for a pub method.
    pub_names: std.StringArrayHashMapUnmanaged(void) = .empty,
    /// `pub const X = alias.Name`, the re-export chain this file holds.
    reexports: std.StringArrayHashMapUnmanaged(Reexport) = .empty,
    /// Every `alias.Symbol` the file names. The list is ordered because the
    /// document sorts its rows, and two runs over one tree must agree.
    edges: std.ArrayList(Edge) = .empty,
    /// A shape the scanner read but could not interpret, carrying its line.
    problems: std.ArrayList(Problem) = .empty,

    /// The path the document prints for `target` when seen from this module,
    /// and whether the caller owns what is returned.
    ///
    /// A module in the consumer layer prints as a layer-relative path and the
    /// answer borrows out of `target`, and one outside it prints relative to
    /// this file's directory and the answer is allocated. The two cannot be
    /// released the same way, so the caller is told which it has.
    ///
    /// The error set is `relativePath`'s rather than `Allocator.Error`,
    /// because a path printed through a writer can fail to write and an
    /// over-narrow signature hides that behind a discard.
    pub fn display(
        self: *const Module,
        gpa: Allocator,
        target: []const u8,
        consumer_prefix: []const u8,
    ) (Allocator.Error || std.Io.Writer.Error)!struct { path: []const u8, owned: bool } {
        if (std.mem.startsWith(u8, target, consumer_prefix)) {
            return .{ .path = target[consumer_prefix.len..], .owned = false };
        }
        return .{ .path = try relativePath(gpa, self.dir, target), .owned = true };
    }
};

/// One `alias.Symbol` the file names.
pub const Edge = struct {
    /// The member named after the alias.
    name: []const u8,
    /// The module the alias resolved to.
    target: []const u8,
};

/// One `pub const X = alias.Name` line.
pub const Reexport = struct {
    alias: []const u8,
    name: []const u8,
};

/// Something the scanner could not read, carrying the line to look at.
pub const Problem = struct {
    path: []const u8,
    line: u32,
    message: []const u8,
};

/// The whole tree, keyed by repository-relative path.
pub const Tree = struct {
    arena: Allocator,
    modules: std.StringArrayHashMapUnmanaged(*Module) = .empty,

    /// Every file the parser rejected. A rejected file has no `Module`, so the
    /// fact lives on the tree: one unparseable file is one finding rather than
    /// a run that stopped before reading the other hundred.
    rejected: std.ArrayList(Problem) = .empty,

    /// The module at `path`, or null when the tree does not hold it.
    pub fn get(self: *const Tree, path: []const u8) ?*Module {
        return self.modules.get(path);
    }
};

/// Reads every `.zig` file under `src_dir`, in name order.
///
/// **The order is name order, not the order the filesystem hands entries
/// back.** Two runs over one tree then report one set of facts, so a diff
/// between them means the source changed.
pub fn scanTree(gpa: Allocator, io: std.Io, src_dir: []const u8) !Tree {
    var tree: Tree = .{ .arena = gpa };

    var paths: std.ArrayList([]const u8) = .empty;
    try collectZigPaths(gpa, io, src_dir, &paths, 0);
    std.mem.sort([]const u8, paths.items, {}, lessThanPath);

    for (paths.items) |path| {
        try scanOneFile(&tree, gpa, io, path);
    }
    return tree;
}

/// Reads one file and files its module under `tree`, or files the rejection
/// when the parser will not take it.
///
/// One file per call, so the read buffer below has exactly one owner and one
/// release. The loop over the collected paths then reads as a list of files,
/// and the part that reads and parses a file is one body to check rather than
/// forty lines inside a loop.
fn scanOneFile(tree: *Tree, gpa: Allocator, io: std.Io, path: []const u8) !void {
    const raw = try std.Io.Dir.cwd().readFileAlloc(
        io,
        path,
        gpa,
        .limited(16 * 1024 * 1024),
    );
    defer gpa.free(raw);

    // `Ast.parse` takes a sentinel-terminated slice, and `readFileAlloc`
    // returns one without. The extra byte is the sentinel, so no realloc and
    // no copy of the source.
    //
    // **The sentinel buffer is not released here.** Every name a module
    // records is a `tokenSlice` pointing into it, so freeing it at the end
    // of the call leaves the tree holding slices into reclaimed memory: the
    // names come back as whatever the allocator wrote there next, and a
    // lookup for a symbol reports garbage rather than nothing. The tree
    // outlives every name it holds, so the tree's allocator keeps the source
    // for the life of the run.
    const source = try gpa.allocSentinel(u8, raw.len, 0);
    @memcpy(source, raw);

    const module = scanModule(gpa, source, path) catch |err| switch (err) {
        error.SourceDoesNotParse => {
            try tree.rejected.append(gpa, .{
                .path = path,
                .line = 0,
                .message = "the parser rejected this file",
            });
            return;
        },
        else => return err,
    };
    try tree.modules.put(gpa, path, module);
}

/// The directories one walk descends. A path deeper than this is not a module
/// the tool reads, so the walk stops rather than recursing without a bound.
const max_depth = 8;

/// One name the walk read, and what the filesystem says it is.
const Entry = struct {
    name: []const u8,
    kind: std.Io.File.Kind,
};

/// Appends every `.zig` file under `dir`, recursively.
///
/// **The iterator already says what an entry is, so a stat answers only the
/// one question the iterator cannot.** `entry.kind` costs no syscall, and
/// re-asking by opening each name spends a handle per file to learn what the
/// walk was handed. A filesystem that stores no directory-entry type reports
/// `DT_UNKNOWN`, which arrives as `.unknown`; that is the case a stat settles,
/// because skipping it instead loses a whole subtree without saying so, and a
/// module that was never read looks the same as a module with no rows.
fn collectZigPaths(
    gpa: Allocator,
    io: std.Io,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
    depth: usize,
) !void {
    if (depth > max_depth) return;

    const cwd = std.Io.Dir.cwd();
    const dir = try cwd.openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);

    var entries: std.ArrayList(Entry) = .empty;
    defer {
        for (entries.items) |entry| gpa.free(entry.name);
        entries.deinit(gpa);
    }

    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        var kind = entry.kind;
        if (kind == .unknown) {
            const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
            defer gpa.free(path);
            kind = (try cwd.statFile(io, path, .{})).kind;
        }
        switch (kind) {
            .file, .directory => {},
            else => continue,
        }
        try entries.append(gpa, .{ .name = try gpa.dupe(u8, entry.name), .kind = kind });
    }
    std.mem.sort(Entry, entries.items, {}, lessThanEntry);

    for (entries.items) |entry| {
        const path = try std.fs.path.join(gpa, &.{ dir_path, entry.name });
        if (entry.kind == .directory) {
            defer gpa.free(path);
            try collectZigPaths(gpa, io, path, out, depth + 1);
        } else if (std.mem.endsWith(u8, entry.name, ".zig")) {
            try out.append(gpa, path);
        } else {
            gpa.free(path);
        }
    }
}

fn lessThanEntry(_: void, a: Entry, b: Entry) bool {
    return std.mem.lessThan(u8, a.name, b.name);
}

/// Orders two paths by name. `collectZigPaths` sorts the names inside one
/// directory itself, so this orders the directories against each other and is
/// what makes two runs over one tree report one set of facts.
fn lessThanPath(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Reads one file into a `Module`.
///
/// Every slice borrows from `gpa`, which the caller owns for the life of the
/// tree, so nothing here needs a per-module release.
pub fn scanModule(gpa: Allocator, source: [:0]const u8, path: []const u8) !*Module {
    var tree = try Ast.parse(gpa, source, .zig);
    defer tree.deinit(gpa);

    if (tree.errors.len != 0) {
        return error.SourceDoesNotParse;
    }

    const module = try gpa.create(Module);
    module.* = .{
        .path = path,
        .dir = std.fs.path.dirname(path) orelse "",
    };

    try scanDecls(gpa, &tree, module);
    try scanAliases(gpa, &tree, module, path);
    try scanChains(gpa, &tree, module);

    return module;
}

/// Records the `pub` names at file scope, the re-exports, and the module aliases.
///
/// The declaration walk reads the root container rather than the token stream,
/// because a `pub fn` inside a struct body is a method and a `pub const` at file
/// scope is a name. A method is recorded as `Type.method` so a caller reading
/// `alias.Type` and a caller reading `alias.Type.method` both resolve.
fn scanDecls(gpa: Allocator, tree: *const Ast, module: *Module) !void {
    const root = tree.containerDeclRoot();
    for (root.ast.members) |member| {
        const name = declName(tree, member) orelse continue;
        switch (tree.nodeTag(member)) {
            .container_decl, .container_decl_trailing => {
                try recordPubContainer(gpa, tree, module, name, member);
            },
            else => {
                if (isPub(tree, member)) {
                    try module.pub_names.put(gpa, name, {});
                }
            },
        }
    }
}

/// Records one container declaration and, when it is `pub`, its members.
///
/// A file-scope `pub const X = alias.Name` is a re-export rather than a
/// declaration, and it is recorded as one. `pub const X = struct { ... }`
/// declares `X`, so it is recorded as a declaration and its `pub fn` members
/// with it.
fn recordPubContainer(
    gpa: Allocator,
    tree: *const Ast,
    module: *Module,
    name: []const u8,
    member: NodeIndex,
) !void {
    if (!isPub(tree, member)) return;

    const reexport = reexportTarget(tree, member);
    if (reexport) |r| {
        try module.reexports.put(gpa, name, r);
        return;
    }

    try module.pub_names.put(gpa, name, {});
    var buffer: [2]Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, member) orelse return;
    for (container.ast.members) |inner| {
        if (!isPub(tree, inner)) continue;
        const inner_name = declName(tree, inner) orelse continue;
        const qualified = try std.fmt.allocPrint(gpa, "{s}.{s}", .{ name, inner_name });
        try module.pub_names.put(gpa, qualified, {});
    }
}

/// The `alias.Name` an `X = alias.Name` declaration names, or null.
fn reexportTarget(tree: *const Ast, member: NodeIndex) ?Reexport {
    const decl = tree.fullVarDecl(member) orelse return null;
    const init = decl.ast.init_node.unwrap() orelse return null;
    if (tree.nodeTag(init) != .field_access) return null;
    const lhs, const rhs = tree.nodeData(init).node_and_token;
    if (tree.nodeTag(lhs) != .identifier) return null;
    return .{
        .alias = tree.tokenSlice(tree.nodeMainToken(lhs)),
        .name = tree.tokenSlice(rhs),
    };
}

/// The declared name of a member node, or null when the node declares none.
fn declName(tree: *const Ast, member: NodeIndex) ?[]const u8 {
    switch (tree.nodeTag(member)) {
        .container_decl, .container_decl_trailing => {
            // The name follows the keyword: `const X = struct {`.
            const token = tree.nodeMainToken(member);
            var probe = token + 1;
            while (tree.tokenTag(probe) == .doc_comment) probe += 1;
            if (tree.tokenTag(probe) != .identifier) return null;
            return tree.tokenSlice(probe);
        },
        else => {
            // A `const` or `var` declaration is its own member node whose main
            // token is the keyword, and a `fn` proto's main token is `fn`, so
            // neither names itself. Reading the main token as the name returns
            // `const` or `fn` for every declaration in the file, and a file
            // whose every name is the same string declares nothing.
            if (tree.fullVarDecl(member)) |decl| return varDeclName(tree, decl);
            var buffer: [1]Ast.Node.Index = undefined;
            if (tree.fullFnProto(&buffer, member)) |proto| {
                const name = proto.name_token orelse return null;
                return tree.tokenSlice(name);
            }
            const token = tree.nodeMainToken(member);
            if (tree.tokenTag(token) != .identifier) return null;
            return tree.tokenSlice(token);
        },
    }
}

fn isPub(tree: *const Ast, member: NodeIndex) bool {
    if (tree.fullVarDecl(member)) |decl| {
        if (decl.visib_token) |token| return tree.tokenTag(token) == .keyword_pub;
        return false;
    }
    var buffer: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buffer, member)) |proto| {
        if (proto.visib_token) |token| return tree.tokenTag(token) == .keyword_pub;
        return false;
    }
    // A container declaration has no visibility token of its own; the `pub`
    // sits before the `const` that owns it.
    const first = tree.firstToken(member);
    var back = first;
    while (back > 0 and isTrivia(tree, back - 1)) back -= 1;
    if (back == 0) return false;
    return tree.tokenTag(back - 1) == .keyword_pub;
}

/// True for a doc comment token.
///
/// A plain `//` comment is not a token. The tokenizer reaches its own
/// `line_comment` state, consumes the line and resumes at `start` without
/// ever setting a tag, so no such token reaches this switch.
fn isTrivia(tree: *const Ast, token: TokenIndex) bool {
    return switch (tree.tokenTag(token)) {
        .container_doc_comment, .doc_comment => true,
        else => false,
    };
}

/// Records every file-scope `const NAME = @import("path")`.
///
/// **The token after the rparen decides what the line binds.** `@import("p")`
/// alone is a module alias; `@import("p").Symbol` binds that symbol, and the
/// qualified reference is recorded by `scanChains` instead. A target with no
/// file behind it is `std` or a package, and neither is recorded.
fn scanAliases(gpa: Allocator, tree: *const Ast, module: *Module, path: []const u8) !void {
    const root = tree.containerDeclRoot();
    for (root.ast.members) |member| {
        const decl = tree.fullVarDecl(member) orelse continue;
        const init = decl.ast.init_node.unwrap() orelse continue;
        const target = importPath(tree, init) orelse continue;

        // `@import("p").Symbol` binds that symbol, not the module, and the
        // qualified reference behind the rparen is what names it.
        const last = tree.lastToken(init);
        if (tree.tokenTag(last + 1) == .period) {
            const member_token = last + 2;
            if (tree.tokenTag(member_token) != .identifier) {
                try module.problems.append(gpa, .{
                    .path = path,
                    .line = @intCast(tree.tokenLocation(0, member_token).line + 1),
                    .message = "@import(...).<not a name>",
                });
                continue;
            }
            const target_path = resolveImport(gpa, path, target) orelse continue;
            try module.edges.append(gpa, .{
                .name = tree.tokenSlice(member_token),
                .target = target_path,
            });
            continue;
        }

        const target_path = resolveImport(gpa, path, target) orelse continue;
        const name = varDeclName(tree, decl) orelse continue;
        try module.aliases.put(gpa, name, target_path);
    }
}

/// The name a `const` or `var` declaration binds.
///
/// `mut_token` is the `const` or `var` keyword rather than the name, and the
/// name is the identifier after it. Keying a module alias by the keyword makes
/// every alias in one file collide on the single key `const`, so a file with
/// twenty imports keeps one of them and no qualified name ever resolves.
fn varDeclName(tree: *const Ast, decl: Ast.full.VarDecl) ?[]const u8 {
    var token = decl.ast.mut_token + 1;
    while (tree.tokenTag(token) == .doc_comment) token += 1;
    if (tree.tokenTag(token) != .identifier) return null;
    return tree.tokenSlice(token);
}

/// The literal path of an `@import("...")` call, or null.
///
/// **The callee is the node's own token and the path is its only parameter.**
/// `Ast.builtinCallParams` hands back the arguments of a builtin call and no
/// callee, so `@import("p")` arrives as one parameter holding the string
/// literal, and the `@import` itself is the node's main token. A caller that
/// expects the callee among the parameters sees a call it cannot read, and
/// every import in the tree is dropped rather than reported.
fn importPath(tree: *const Ast, node: NodeIndex) ?[]const u8 {
    var buffer: [2]Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buffer, node) orelse return null;
    if (params.len != 1) return null;
    if (!std.mem.eql(u8, tree.tokenSlice(tree.nodeMainToken(node)), "@import")) return null;
    if (tree.nodeTag(params[0]) != .string_literal) return null;
    return unquote(tree.tokenSlice(tree.nodeMainToken(params[0])));
}

/// The bytes between a string literal's quotes, or null when it has an escape
/// this tool does not unescape. A path with an escape is not a path this
/// repository uses, so the null is a finding rather than a guess.
fn unquote(literal: []const u8) ?[]const u8 {
    if (literal.len < 2) return null;
    if (literal[0] != '"') return null;
    if (literal[literal.len - 1] != '"') return null;
    const body = literal[1 .. literal.len - 1];
    for (body) |byte| {
        if (byte == '\\') return null;
    }
    return body;
}

/// The repository-relative path a relative import names, or null when no file
/// is there.
///
/// A target with no `./` is still resolved against the importing file's own
/// directory, because that is what Zig does. A target outside the tree is null,
/// and the caller records nothing for it.
fn resolveImport(gpa: Allocator, importer: []const u8, target: []const u8) ?[]const u8 {
    if (target.len == 0) return null;
    if (std.fs.path.isAbsolute(target)) return null;
    const dir = std.fs.path.dirname(importer) orelse "";
    return std.fs.path.resolvePosix(gpa, &.{ dir, target }) catch null;
}

/// The path `to` written the way a file in `from_dir` writes it.
///
/// `std.fs.path.relative` wants an environment map for its working directory,
/// and this tool has none: it is handed two repository-relative paths and a
/// shared root, so it counts the components itself.
pub fn relativePath(gpa: Allocator, from_dir: []const u8, to: []const u8) ![]const u8 {
    var from_parts: std.ArrayList([]const u8) = .empty;
    defer from_parts.deinit(gpa);
    var it = std.mem.tokenizeScalar(u8, from_dir, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        try from_parts.append(gpa, part);
    }

    var to_parts: std.ArrayList([]const u8) = .empty;
    defer to_parts.deinit(gpa);
    it = std.mem.tokenizeScalar(u8, to, '/');
    while (it.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".")) continue;
        try to_parts.append(gpa, part);
    }

    var shared: usize = 0;
    while (shared < from_parts.items.len and
        shared < to_parts.items.len and
        std.mem.eql(u8, from_parts.items[shared], to_parts.items[shared])) : (shared += 1)
    {}

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    for (from_parts.items[shared..]) |_| try out.writer.writeAll("../");
    for (to_parts.items[shared..], shared..) |part, index| {
        if (index != shared) try out.writer.writeByte('/');
        try out.writer.writeAll(part);
    }
    const written = out.written();
    if (written.len == 0) return gpa.dupe(u8, ".");
    return gpa.dupe(u8, written);
}

/// Records every `alias.Symbol` the file names.
///
/// **Only a chain whose head is a file-scope alias names a module.** A head
/// that follows `)`, `]` or a period is a field of a value, so
/// `node.tree_state.nodes` records nothing while `tree_state.TreeState` records
/// the type. The token before the head is what tells them apart, and the
/// tokenizer already knows which of those bytes is which token.
fn scanChains(gpa: Allocator, tree: *const Ast, module: *Module) !void {
    const tokens = tree.tokens.items(.tag);
    var chain: std.ArrayList([]const u8) = .empty;
    // A head that follows a value names a field of that value, so its chain
    // names no module however much of it looks like an alias.
    var names_a_value = false;
    var index: TokenIndex = 0;
    while (index < tokens.len) : (index += 1) {
        if (tokens[index] != .identifier) continue;

        const is_head = index == 0 or !continuesChain(tree, index);
        if (is_head) {
            if (chain.items.len >= 2 and !names_a_value) {
                try recordChain(gpa, module, chain.items);
            }
            chain.clearRetainingCapacity();
            names_a_value = followsValue(tree, index);
        }
        try chain.append(gpa, tree.tokenSlice(index));
    }
    if (chain.items.len >= 2 and !names_a_value) try recordChain(gpa, module, chain.items);
}

/// True when the identifier at `token` is reached from a value rather than
/// from a name, which is what makes it a field rather than a module.
///
/// `one.id().tree_index.value()` puts `tree_index` after the rparen of a call,
/// so it reads a field of what the call returned even though `tree_index` is
/// an alias elsewhere in the same file. The chain is well formed and its head
/// is a real alias, so nothing but the token before the head tells the two
/// apart.
fn followsValue(tree: *const Ast, token: TokenIndex) bool {
    if (token < 2) return false;
    if (tree.tokenTag(token - 1) != .period) return false;
    return switch (tree.tokenTag(token - 2)) {
        .r_paren, .r_bracket, .period => true,
        else => false,
    };
}

/// True when the identifier at `token` continues the chain before it, which is
/// when the only tokens between the two are periods.
fn continuesChain(tree: *const Ast, token: TokenIndex) bool {
    var probe = token;
    var saw_period = false;
    while (probe > 0) {
        probe -= 1;
        switch (tree.tokenTag(probe)) {
            .period => saw_period = true,
            .identifier => return saw_period,
            else => return false,
        }
    }
    return false;
}

/// Records the `alias.Symbol` a completed chain names, when the head is a module.
fn recordChain(gpa: Allocator, module: *Module, chain: []const []const u8) !void {
    const target = module.aliases.get(chain[0]) orelse return;
    try module.edges.append(gpa, .{ .name = chain[1], .target = target });
}

/// The module that finally declares `name`, following every re-export on the
/// way, or null when no file on the chain declares it.
///
/// **A re-export is not an owner.** `pub const Affine = affine_mod.Affine` in
/// `schema/root.zig` names a declaration `schema/geometry/affine.zig` owns, so
/// the answer is that file and not the one holding the re-export.
pub fn ownerOf(tree: *const Tree, path: []const u8, name: []const u8, depth: usize) ?[]const u8 {
    if (depth > chain_depth_limit) return null;
    const module = tree.get(path) orelse return null;

    if (module.pub_names.contains(name)) return path;
    const reexport = module.reexports.get(name) orelse return null;
    const target = module.aliases.get(reexport.alias) orelse return null;
    return ownerOf(tree, target, reexport.name, depth + 1);
}

const testing = std.testing;

/// Scans one source string and returns the module, with everything it holds
/// borrowed from `gpa`. The path is the module's identity and is what the
/// import resolution resolves against.
fn scanForTest(
    gpa: Allocator,
    source: [:0]const u8,
    path: []const u8,
) !*Module {
    return scanModule(gpa, source, path);
}

test "a doc comment that quotes a qualified name is not a reference" {
    // The comment is the whole point. A masking pass that forgets `///` turns
    // this file into a caller of `properties.role`, and the row it invents is
    // the one a reader cannot check.
    const source =
        \\const properties = @import("properties.zig");
        \\const node_id = @import("node_id.zig");
        \\//! This layer calls `properties.role` and `node_id.NodeRef` nowhere.
        \\/// Nor `properties.clipsChildren` here.
        \\/// nor `properties . role` with a space.
        \\const nothing = 1;
    ;
    const module = try scanForTest(testing.allocator, source, "src/consumer/x.zig");
    try testing.expectEqual(@as(usize, 0), module.edges.items.len);
}

test "a chain whose head is not an alias names no module" {
    // `tree_state` is an alias, but the chain below starts at `node`, so the
    // `tree_state.nodes` in the middle is a field of a value.
    const source =
        \\const tree_state = @import("tree_state.zig");
        \\pub fn read(node: anytype) void {
        \\    _ = node.tree_state.nodes.count();
        \\    _ = tree_state.TreeState;
        \\}
    ;
    const module = try scanForTest(testing.allocator, source, "src/consumer/x.zig");
    try testing.expectEqual(@as(usize, 1), module.edges.items.len);
    try testing.expectEqualStrings("TreeState", module.edges.items[0].name);
    try testing.expectEqualStrings("src/consumer/tree_state.zig", module.edges.items[0].target);
}

test "a field after a call is not a module reference" {
    // `one.id()` ends in a rparen, so the identifier after the period names a
    // field of the value the call returned.
    const source =
        \\const tree_index = @import("tree_index.zig");
        \\pub fn read(one: anytype) u32 {
        \\    return one.id().tree_index.value();
        \\}
    ;
    const module = try scanForTest(testing.allocator, source, "src/consumer/x.zig");
    try testing.expectEqual(@as(usize, 0), module.edges.items.len);
}

test "an inline import names the symbol, and does not bind the module" {
    // `@import("p").Symbol` is not an alias, so a later `Symbol.member` is a
    // method on the symbol and not a member of `p`.
    const source =
        \\const NodeRef = @import("node_id.zig").NodeRef;
        \\const tree_index = @import("tree_index.zig");
        \\pub fn read(node: NodeRef) void {
        \\    _ = NodeRef.init;
        \\    _ = tree_index.FullNodeId;
        \\}
    ;
    const module = try scanForTest(testing.allocator, source, "src/consumer/x.zig");
    try testing.expectEqual(@as(usize, 2), module.edges.items.len);
    try testing.expectEqualStrings("NodeRef", module.edges.items[0].name);
    try testing.expectEqualStrings("src/consumer/node_id.zig", module.edges.items[0].target);
    try testing.expectEqualStrings("FullNodeId", module.edges.items[1].name);
}

test "a sibling import without a dot names a file" {
    // Zig resolves a bare `"tree_index.zig"` against the importing file's own
    // directory. A scanner that requires a leading `./` records nothing, and an
    // empty table looks the same as a table with no rows.
    const source =
        \\const tree_index = @import("tree_index.zig");
        \\const NodeId = tree_index.FullNodeId;
    ;
    const module = try scanForTest(testing.allocator, source, "src/consumer/x.zig");
    try testing.expectEqual(@as(usize, 1), module.edges.items.len);
    try testing.expectEqualStrings("src/consumer/tree_index.zig", module.edges.items[0].target);
}

test "a pub method is recorded under its type" {
    const source =
        \\pub const Handle = struct {
        \\    pub fn get(self: Handle) void {}
        \\    fn hidden(self: Handle) void {}
        \\};
        \\pub fn free() void {}
        \\fn private() void {}
    ;
    const module = try scanForTest(testing.allocator, source, "src/consumer/x.zig");
    try testing.expect(module.pub_names.contains("Handle"));
    try testing.expect(module.pub_names.contains("Handle.get"));
    try testing.expect(module.pub_names.contains("free"));
    try testing.expect(!module.pub_names.contains("Handle.hidden"));
    try testing.expect(!module.pub_names.contains("private"));
}

test "a re-export resolves to the module behind the alias" {
    const leaf =
        \\pub const Affine = struct { x: f64 };
    ;
    const root =
        \\const affine_mod = @import("geometry/affine.zig");
        \\pub const Affine = affine_mod.Affine;
    ;
    const user =
        \\const schema = @import("../schema/root.zig");
        \\const Affine = schema.Affine;
    ;

    const gpa = testing.allocator;
    var tree: Tree = .{ .arena = gpa };
    const leaf_module = try scanForTest(gpa, leaf, "src/schema/geometry/affine.zig");
    try tree.modules.put(gpa, leaf_module.path, leaf_module);
    const root_module = try scanForTest(gpa, root, "src/schema/root.zig");
    try tree.modules.put(gpa, root_module.path, root_module);
    const user_module = try scanForTest(gpa, user, "src/consumer/node_ref/geometry.zig");
    try tree.modules.put(gpa, user_module.path, user_module);

    // The edge names the re-exporting module, and the owner is the leaf.
    try testing.expectEqual(@as(usize, 1), user_module.edges.items.len);
    try testing.expectEqualStrings(
        "src/schema/geometry/affine.zig",
        ownerOf(&tree, user_module.edges.items[0].target, "Affine", 0).?,
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        ownerOf(&tree, "src/schema/root.zig", "Shape", 0),
    );
}

test "relativePath writes a path the way the importing file wrote it" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings(
        "../../schema/geometry/affine.zig",
        try relativePath(gpa, "src/consumer/node_ref", "src/schema/geometry/affine.zig"),
    );
    try testing.expectEqualStrings(
        "../tree_index.zig",
        try relativePath(gpa, "src/consumer/node_ref", "src/consumer/tree_index.zig"),
    );
    try testing.expectEqualStrings(
        "hit_test.zig",
        try relativePath(gpa, "src/consumer/text", "src/consumer/text/hit_test.zig"),
    );
}
