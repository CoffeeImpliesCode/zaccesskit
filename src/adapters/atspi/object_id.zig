//! `ObjectId`: what an AT-SPI object path names, and the three paths the port
//! exports.
//!
//! **Upstream.** `accesskit_unix/src/atspi/object_id.rs:14-16` declares the
//! three path constants, `:18-20` is `cache_path`, `:22-26` declares
//! `ObjectId`, and `:28-45` are `to_address` and `path`.
//! `docs/41-atspi-build-map.md` section 1.1
//! records the three paths and fixes their shapes: `{adapter}` is the `usize`
//! from the adapter and `{node}` is the decimal `u128` of a `FullNodeId`.
//!
//! **What is dropped and why.** Upstream `object_id.rs:47-70` carries a
//! `Serialize` impl, a `Type` impl and a `From<ObjectId> for Structure`
//! conversion. `docs/41` section 7.2 drops all three: zbus needed them to build
//! the `Embed` plug string, and this port passes the two halves to `Proxy.call`
//! as a `(ss)` body instead. A port that kept them would carry a wire format no
//! member of this adapter speaks.
//!
//! **Why this module names nothing but `FullNodeId`.** `docs/41` section 2.3
//! gives `object_id.zig` no edge, and the object-path scheme is the one piece
//! of the adapter that every other module reads, so keeping it free of a D-Bus
//! dependency is what lets a test of the paths run without one. The single
//! consumer type it names is `FullNodeId`, which `nodeSegment` reads the two
//! halves of. `toAddress` is the one function that moved the other way: it is
//! the only member that produced an `(so)` pair, it belongs to
//! `object_address.zig`, and it is `OwnedObjectAddress.initFromObjectId` there
//! now. Upstream puts both on `ObjectId` because Rust has no such constraint.

const std = @import("std");
const tree_index = @import("../../consumer/tree_index.zig");

const FullNodeId = tree_index.FullNodeId;

/// The prefix every node path carries. Upstream `object_id.rs:14`.
pub const accessible_path_prefix: [:0]const u8 = "/org/a11y/atspi/accessible/";

/// The path of the application object, which is also the desktop root this
/// adapter is embedded under. Upstream `object_id.rs:15`.
pub const root_path: [:0]const u8 = "/org/a11y/atspi/accessible/root";

/// The path the `org.a11y.atspi.Cache` interface is exported on. Upstream
/// `object_id.rs:16`.
pub const cache_path: [:0]const u8 = "/org/a11y/atspi/cache";

/// What one object path names: the cache object, the application object, or
/// one node of one adapter's tree. Upstream `object_id.rs:22-26`.
///
/// **Why there is a third variant.** Upstream has two and keeps `cache_path`
/// as a bare constant, because upstream raises the cache signals through a
/// separate function that already knows the path. This port names an object
/// in every value that carries one — an event's `PATH` header field among them
/// — so a variant that cannot name the cache object would force every reader
/// back to a bare constant, and two ways to name one object is how they drift.
pub const ObjectId = union(enum) {
    /// The application object at `root_path`. Upstream `ObjectId::Root`.
    root,
    /// The cache object at `cache_path`, which carries
    /// `org.a11y.atspi.Cache`. Upstream has no variant for this; the path is
    /// `object_id.rs:16` and this variant is what lets a value name it.
    cache,
    /// One node of one adapter. Upstream `ObjectId::Node`.
    node: Node,

    /// The `(adapter, node)` pair a node path is built from.
    ///
    /// `adapter` is the value upstream calls `adapter_id`, from
    /// `next_adapter_id` at `atspi-common/src/adapter.rs:356-358`. `node` is the
    /// consumer's `FullNodeId`, which `consumer.tree_index` owns and this module
    /// only reads.
    pub const Node = struct {
        /// The window this node belongs to. Two windows never share a path
        /// because their ids differ, per `docs/41` section 1.1.
        adapter: usize,
        /// The node inside that window.
        node: FullNodeId,
    };

    /// The object path this identifier names.
    ///
    /// `gpa` follows the receiver because this allocates: upstream
    /// `ObjectId::path` at `object_id.rs:33-44` formats a string, and a Zig
    /// free function that allocates takes the allocator first while an
    /// allocating method takes the receiver first, per `AGENTS.md` section 2.
    ///
    /// The returned slice is sentinel-terminated, which is what
    /// `object_address.fromSlices` requires of a path.
    ///
    /// **Errors.** `error.OutOfMemory` from `gpa`.
    pub fn path(self: ObjectId, gpa: std.mem.Allocator) std.mem.Allocator.Error![:0]u8 {
        return switch (self) {
            .root => gpa.dupeZ(u8, root_path),
            .cache => gpa.dupeZ(u8, cache_path),
            .node => |pair| blk: {
                const segment = nodeSegment(pair.node);
                const text = try std.fmt.allocPrintSentinel(
                    gpa,
                    "{s}{d}/{d}",
                    .{ accessible_path_prefix, pair.adapter, segment },
                    0,
                );
                break :blk text;
            },
        };
    }
};

/// The decimal value the `{node}` segment of a path carries.
///
/// Upstream writes `u128::from(*node)` at `object_id.rs:40`, which widens the
/// single counter its `FullNodeId` wraps. This port's `FullNodeId` holds two
/// halves, a `u64` local id and a `u32` tree index, so there is no single
/// counter to widen and the port composes them instead:
///
///     (tree_index << 64) | local
///
/// The composition is injective, which is the property the path needs: two
/// distinct `FullNodeId` values never produce the same segment, so two distinct
/// nodes never share an object path. A composition that dropped either half
/// would collide every node of one grafted subtree with the node of the same
/// local id in another, and `docs/41` section 1.1 depends on distinct paths.
///
/// **The width is part of what this function promises.** The two halves fill
/// 96 of the 128 bits and the top 32 are always zero, because a `u32` sits
/// above a `u64` and nothing else. Upstream writes a `u128`, this returns a
/// `u128`, and `path` renders it with `"{d}"`, so a composition that shifted
/// the tree index further up would widen the segment to 97 bits and print a
/// different path for every node, and one that shifted it less would drop the
/// top bit of the local id and collide two nodes. Neither failure shows at the
/// one- and two-digit magnitudes the paths above carry, so the tests below pin
/// both ends of the width: the two halves tile it with no gap and no overlap,
/// and the widest node this module can name fills exactly 96 bits.
///
/// **This is not `FullNodeId.toU128`.** `consumer.tree_index` has a second
/// composition of the same two halves at `tree_index.zig:153`, which puts the
/// local id in the high half and the tree number in the low one. That one
/// mirrors upstream's `impl From<FullNodeId> for u128` at `node.rs:46-52` and
/// writes into a platform handle. Here the tree number is the high half
/// because a path segment that grew a new high half would read every path the
/// port has ever sent as a different node. The two disagree bit for bit and
/// neither can stand in for the other.
///
/// **Errors.** This function does not fail.
pub fn nodeSegment(node: FullNodeId) u128 {
    const high: u128 = node.tree_index.value();
    const low: u128 = node.local.value;
    return (high << 64) | low;
}

/// Builds a `FullNodeId` from a local id and a tree number, for the tests
/// below. The tree number is named `number` rather than `tree_index` because a
/// parameter may not shadow the module the `FullNodeId` type came from.
fn testNode(local: u64, number: u32) FullNodeId {
    return FullNodeId.init(.{ .value = local }, .init(number));
}

/// The largest local id a `FullNodeId` carries, and the largest tree number
/// `TreeIndex` carries. The two together are the widest segment this module can
/// compose, so every test that needs the far end of the width names them
/// instead of writing the same limit again.
const widest_local: u64 = std.math.maxInt(u64);
const widest_tree: u32 = std.math.maxInt(u32);

/// True when every byte of `tail` is one a D-Bus object path element may hold,
/// which is `[A-Za-z0-9_]`, or the `/` that separates two of them. The
/// elements are the only part of a node path whose length grows with the
/// width, and the bus rejects an element holding anything else.
fn tailIsLegalPath(tail: []const u8) bool {
    for (tail) |byte| {
        const allowed = switch (byte) {
            'a'...'z', 'A'...'Z', '0'...'9', '_', '/' => true,
            else => false,
        };
        if (!allowed) return false;
    }
    return true;
}

test "the three path constants are the ones the registry knows" {
    // `docs/41` section 6.2 measured this tree from the live bus.
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", root_path);
    try std.testing.expectEqualStrings("/org/a11y/atspi/cache", cache_path);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/", accessible_path_prefix);
}

test "the root identifier names the root path" {
    const gpa = std.testing.allocator;

    // The identifier is bound first. Zig 0.16.0 resolves a container-level
    // function on a tagged union through the *payload* of the active field, and
    // `root` carries no payload, so `ObjectId.root.path(gpa)` does not resolve
    // while `path` on a named value does.
    const root: ObjectId = .root;
    const path = try root.path(gpa);
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/root", path);
}

test "the cache identifier names the cache path" {
    const gpa = std.testing.allocator;

    // The cache object is the third path this port exports, and a value that
    // cannot name it would send every cache signal on the root path instead,
    // where a client looks for `org.a11y.atspi.Accessible`.
    const cache: ObjectId = .cache;
    const path = try cache.path(gpa);
    defer gpa.free(path);
    try std.testing.expectEqualStrings(cache_path, path);

    const root: ObjectId = .root;
    const root_text = try root.path(gpa);
    defer gpa.free(root_text);
    try std.testing.expect(!std.mem.eql(u8, root_text, path));
}

test "a node path is the prefix, the adapter and the node segment, in that order" {
    const gpa = std.testing.allocator;

    const id: ObjectId = .{ .node = .{ .adapter = 3, .node = testNode(42, 0) } };
    const path = try id.path(gpa);
    defer gpa.free(path);

    try std.testing.expectEqualStrings("/org/a11y/atspi/accessible/3/42", path);
}

test "two windows never share a path, because the adapter is in it" {
    const gpa = std.testing.allocator;

    const node = testNode(42, 0);
    const first = try (ObjectId{ .node = .{ .adapter = 0, .node = node } }).path(gpa);
    defer gpa.free(first);
    const second = try (ObjectId{ .node = .{ .adapter = 1, .node = node } }).path(gpa);
    defer gpa.free(second);

    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "the node segment separates two trees that share a local id" {
    // This is the case a composition that widened only the local id would get
    // wrong: two grafted subtrees both hold local id 7.
    const in_root = testNode(7, 0);
    const in_graft = testNode(7, 1);

    try std.testing.expect(nodeSegment(in_root) != nodeSegment(in_graft));

    const gpa = std.testing.allocator;
    const first = try (ObjectId{ .node = .{ .adapter = 0, .node = in_root } }).path(gpa);
    defer gpa.free(first);
    const second = try (ObjectId{ .node = .{ .adapter = 0, .node = in_graft } }).path(gpa);
    defer gpa.free(second);
    try std.testing.expect(!std.mem.eql(u8, first, second));
}

test "the local half lands in the low 64 bits, bit for bit" {
    // Every value here names a bit the composition has to leave where it found
    // it. A shift applied to the low half drops the bit it names, a mask over
    // it drops every bit the mask clears, and a tree index placed inside the
    // low 64 overwrites the local id rather than sitting above it. All three
    // still compose a `u128`, so only the width can tell them apart.
    const probe = [_]u64{ 0, 1, 1 << 32, 1 << 63, widest_local };
    inline for (probe) |value| {
        const expected: u128 = value;
        try std.testing.expectEqual(expected, nodeSegment(testNode(value, 0)));
    }
}

test "the tree index is shifted by exactly 64, and the width is a u128" {
    // The declared width is a contract rather than an inference. A narrower
    // return type could not carry a tree index above a full local id, and
    // `path` renders this value with `"{d}"` into an object path, so the type
    // that holds the whole composition is the type that has to be right.
    comptime {
        const carries_u128: *const fn (FullNodeId) u128 = nodeSegment;
        _ = carries_u128;
    }

    const probe = [_]u32{ 0, 1, 1 << 31, widest_tree };
    inline for (probe) |number| {
        const expected: u128 = @as(u128, number) << 64;
        try std.testing.expectEqual(expected, nodeSegment(testNode(0, number)));
    }
}

test "the widest node fills exactly 96 bits, and the top 32 stay zero" {
    // Each corner is checked on its own so a failure names the half that moved.
    const widest = nodeSegment(testNode(widest_local, widest_tree));
    const low_only = nodeSegment(testNode(widest_local, 0));
    const high_only = nodeSegment(testNode(0, widest_tree));

    // 2^96 - 1, which is `maxInt(u128) >> 32`: the two halves have 96 bits
    // between them and use every one, and the width holds 32 more that no
    // `FullNodeId` can reach.
    const full: u128 = (@as(u128, widest_tree) << 64) | widest_local;
    try std.testing.expectEqual(full, widest);
    try std.testing.expectEqual(std.math.maxInt(u128) >> 32, widest);
    try std.testing.expectEqual(@as(u128, widest_local), low_only);
    try std.testing.expectEqual(@as(u128, widest_tree) << 64, high_only);

    // A shift of 65 also composes an injective value that still fits a `u128`,
    // and it changes no low-half probe above. Only the bound from above tells
    // 96 from 97, so it is the one assertion here that a wider shift cannot
    // survive.
    try std.testing.expect(widest < (@as(u128, 1) << 96));
}

test "the two halves tile the width with no gap and no overlap" {
    // The last local id of one tree and the first local id of the next are
    // adjacent: 2^64 - 1 and 2^64. A shift of 63 would put the tree index's
    // bit 0 on the local id's bit 63, and these two values would then be one
    // node under two names.
    const last_of_one = nodeSegment(testNode(widest_local, 0));
    const first_of_next = nodeSegment(testNode(0, 1));
    try std.testing.expectEqual(last_of_one + 1, first_of_next);

    // The pair a shift of 63 collides, named so the reason survives: the local
    // id that supplies bit 63, and the tree number that supplies it instead.
    const from_local = nodeSegment(testNode(1 << 63, 0));
    const from_tree = nodeSegment(testNode(0, 1));
    try std.testing.expect(from_local != from_tree);
}

test "the widest path prints the decimal the two halves compose" {
    const gpa = std.testing.allocator;

    // Nothing else in the file prints more than two digits, so nothing else
    // reads the width. The adapter and the segment both print at their full
    // magnitude here, and the string is the length the D-Bus specification's
    // 255-byte object-path limit has to leave room for.
    const id: ObjectId = .{ .node = .{
        .adapter = std.math.maxInt(usize),
        .node = testNode(widest_local, widest_tree),
    } };
    const path = try id.path(gpa);
    defer gpa.free(path);

    // The two halves print as the two decimal numbers they are: the adapter at
    // 20 digits of `u64`, the segment at 29 digits of 96.
    const adapter_text = "18446744073709551615";
    const segment_text = "79228162514264337593543950335";
    const wanted = accessible_path_prefix ++ adapter_text ++ "/" ++ segment_text;
    try std.testing.expectEqualStrings(wanted, path);

    // 27 of prefix, 20 of adapter, one separator and 29 of segment. The two
    // digit counts are the widths a `u64` and a filled `u128` print at, and
    // 77 is the longest path this adapter can name.
    try std.testing.expectEqual(accessible_path_prefix.len + 20 + 1 + 29, path.len);
    try std.testing.expect(path.len < 255);

    // The two elements have to stay decimal to be legal path elements at all,
    // and the width is what makes their length grow, so the far end is where a
    // change of format would show.
    const tail = path[accessible_path_prefix.len..];
    try std.testing.expect(tailIsLegalPath(tail));
    try std.testing.expectEqualStrings(adapter_text ++ "/" ++ segment_text, tail);
}
