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
/// **Errors.** This function does not fail.
pub fn nodeSegment(node: FullNodeId) u128 {
    const high: u128 = @as(u128, node.tree_index.value());
    const low: u128 = @as(u128, node.local.value);
    return (high << 64) | low;
}

/// Builds a `FullNodeId` from a local id and a tree number, for the tests
/// below. The tree number is named `number` rather than `tree_index` because a
/// parameter may not shadow the module the `FullNodeId` type came from.
fn testNode(local: u64, number: u32) FullNodeId {
    return FullNodeId.init(.{ .value = local }, .init(number));
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

    const id = ObjectId{ .node = .{ .adapter = 3, .node = testNode(42, 0) } };
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
