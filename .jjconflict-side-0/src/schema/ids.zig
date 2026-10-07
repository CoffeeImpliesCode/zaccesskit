//! Identity types: one node inside one tree, and the tree itself.
//!
//! `NodeId` is one unsigned 64-bit integer the tree hands out. `TreeId` is 16
//! opaque bytes. Both cross the C ABI as plain aggregates, so both are
//! `extern struct` and both carry a comptime size assertion taken from the
//! header.
//!
//! A type holds its own behaviour: `eql`, `lessThan` and `hash` compare and
//! digest the value. Every conversion and every rendering of a value is a
//! module-level function prefixed by its type name, so the flat re-export in
//! `schema/root.zig` cannot give two schema modules the same function.
//!
//! This module does not parse, format or generate tree identifiers. Upstream
//! wraps `uuid::Uuid`, which brings a parser and a version-4 generator that
//! nothing in the port calls. A caller that needs a fresh identifier writes the
//! 16 bytes itself.
//!
//! Upstream: `accesskit/src/lib.rs:703-750`.

const std = @import("std");
const assert = std.debug.assert;

const testing = std.testing;

/// The content of a `NodeId`: one unsigned 64-bit integer.
///
/// Upstream declares `pub type NodeIdContent = u64;` (`accesskit/src/lib.rs:703`),
/// an alias and not a new type, so the port keeps the alias. An alias carries
/// no methods, which is why every operation on it lives on `NodeId` or at file
/// scope.
pub const NodeIdContent = u64;

/// The identity of one node inside one tree.
///
/// Every tree has its own identifier space, so one value names a node in two
/// trees without a conflict. The pair of a `NodeId` and a `TreeId` names one
/// node in one tree.
///
/// The value owns nothing and a copy is independent. Zero is a valid content,
/// and upstream uses it as a test root.
pub const NodeId = extern struct {
    value: NodeIdContent,

    /// True when both ids carry the same content.
    pub fn eql(self: NodeId, other: NodeId) bool {
        return self.value == other.value;
    }

    /// True when `self` carries the smaller content. No value is less than
    /// itself.
    pub fn lessThan(self: NodeId, other: NodeId) bool {
        return std.math.order(self.value, other.value) == .lt;
    }

    /// Feeds `self` to `hasher`.
    ///
    /// The port keys nodes in `std.array_hash_map.Auto`, which keeps insertion
    /// order, so the order a consumer walks the nodes in is a function of the
    /// update. Upstream keys them in `hashbrown`, which reseeds per process, so
    /// the same update reaches the change handler in a different order on every
    /// run. The order is a property of the container, not of the key.
    pub fn hash(self: NodeId, hasher: *std.hash.Wyhash) void {
        std.hash.autoHash(hasher, self);
    }
};

/// The id whose content is `content`. Upstream's `From<NodeIdContent>` for
/// `NodeId` (`lib.rs:717`).
pub fn nodeIdFromContent(content: NodeIdContent) NodeId {
    return .{ .value = content };
}

/// The content of `value`. Upstream's `From<NodeId>` for `NodeIdContent`
/// (`lib.rs:724`).
pub fn nodeIdToContent(value: NodeId) NodeIdContent {
    return value.value;
}

/// Writes `#` followed by the decimal content of `value`, which is upstream's
/// `Debug` form (`lib.rs:731`).
///
/// Writes nothing beyond those bytes and returns no error other than
/// `error.WriteFailed` from `w`.
pub fn nodeIdFormat(value: NodeId, w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print("#{d}", .{value.value});
}

/// The identity of one tree.
///
/// The port stores the 16 bytes and gives them back. It never reads a version
/// out of them, never reformats them and never writes them. The root tree is
/// `tree_id_root`.
pub const TreeId = extern struct {
    /// The identifier, in the big-endian byte order the C header declares
    /// (`accesskit-c/include/accesskit.h:703-708`).
    bytes: [16]u8,

    /// True when both ids hold the same 16 bytes.
    pub fn eql(self: TreeId, other: TreeId) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }

    /// True when `self` holds the smaller byte sequence, most significant byte
    /// first. No value is less than itself.
    pub fn lessThan(self: TreeId, other: TreeId) bool {
        return std.mem.order(u8, &self.bytes, &other.bytes) == .lt;
    }

    /// Feeds `self` to `hasher`.
    pub fn hash(self: TreeId, hasher: *std.hash.Wyhash) void {
        std.hash.autoHash(hasher, self);
    }
};

/// The all-zero identifier, which is the root tree. Rule Z3 puts a
/// `SCREAMING_SNAKE_CASE` constant at file scope under a name that carries the
/// type, and the house linter's Z006 spells a module-level constant in
/// `snake_case`, so the `TreeId` prefix is written `tree_id`. That prefix keeps
/// the name clear of `affine_identity`, `point_origin`, `rect_zero`, `size_zero`
/// and `vec2_zero`, which also stand at the origin.
pub const tree_id_root: TreeId = .{ .bytes = @splat(0) };

/// The tree whose bytes are `bytes`.
pub fn treeIdFromBytes(bytes: [16]u8) TreeId {
    return .{ .bytes = bytes };
}

/// The bytes of `value`, in the order it stores them. The result is a copy, so
/// it does not borrow `value`.
pub fn treeIdToBytes(value: TreeId) [16]u8 {
    return value.bytes;
}

comptime {
    // `typedef uint64_t accesskit_node_id;` at `accesskit-c/include/accesskit.h:686`,
    // so `NodeId` is a bare integer to the C caller and must stay one scalar wide.
    assert(@sizeOf(NodeIdContent) == 8);
    assert(@alignOf(NodeIdContent) == 8);
    assert(@sizeOf(NodeId) == 8);
    assert(@alignOf(NodeId) == 8);
    assert(@offsetOf(NodeId, "value") == 0);

    // `uint8_t bytes[16];` at `accesskit-c/include/accesskit.h:708`, an array of
    // bytes and nothing else, so the struct must add no padding and no alignment.
    assert(@sizeOf(TreeId) == 16);
    assert(@alignOf(TreeId) == 1);
    assert(@offsetOf(TreeId, "bytes") == 0);
}

test "NodeId content survives the conversion both ways" {
    const content: NodeIdContent = 0x0123_4567_89ab_cdef;
    const id = nodeIdFromContent(content);

    try testing.expect(nodeIdToContent(id) == content);
    try testing.expect(nodeIdFromContent(nodeIdToContent(id)).eql(id));
}

test "NodeId equality is by content" {
    const one = nodeIdFromContent(1);
    const two = nodeIdFromContent(2);

    try testing.expect(one.eql(one));
    try testing.expect(one.eql(nodeIdFromContent(1)));
    try testing.expect(!one.eql(two));
    try testing.expect(!two.eql(one));
}

test "NodeId orders by unsigned content" {
    const low = nodeIdFromContent(0);
    const high = nodeIdFromContent(std.math.maxInt(NodeIdContent));

    try testing.expect(low.lessThan(high));
    try testing.expect(!high.lessThan(low));
    try testing.expect(!low.lessThan(low));
}

test "equal ids digest equal and the content reaches the hasher" {
    var first = std.hash.Wyhash.init(0);
    nodeIdFromContent(1).hash(&first);
    var second = std.hash.Wyhash.init(0);
    nodeIdFromContent(1).hash(&second);

    try testing.expectEqual(first.final(), second.final());

    var other = std.hash.Wyhash.init(0);
    nodeIdFromContent(2).hash(&other);

    try testing.expect(first.final() != other.final());
}

test "NodeId formats as hash then decimal content" {
    var small_buffer: [4]u8 = undefined;
    var small_writer = std.Io.Writer.fixed(&small_buffer);
    try nodeIdFormat(nodeIdFromContent(0), &small_writer);
    try testing.expectEqualStrings("#0", small_writer.buffered());

    // The widest content must not lose digits to a narrower field or format.
    var wide_buffer: [24]u8 = undefined;
    var wide_writer = std.Io.Writer.fixed(&wide_buffer);
    const widest = nodeIdFromContent(std.math.maxInt(NodeIdContent));
    try nodeIdFormat(widest, &wide_writer);
    try testing.expectEqualStrings("#18446744073709551615", wide_writer.buffered());
}

test "tree_id_root is sixteen zero bytes" {
    const root = tree_id_root;
    const zero_bytes = [_]u8{0} ** @sizeOf(TreeId);

    try testing.expectEqualSlices(u8, &zero_bytes, &root.bytes);
    try testing.expect(root.eql(treeIdFromBytes(zero_bytes)));
}

test "TreeId is exactly the sixteen bytes the header declares" {
    try testing.expectEqual(@as(usize, 16), @sizeOf(TreeId));
    try testing.expectEqual(@as(u8, 1), @alignOf(TreeId));
}

test "every byte of a TreeId is significant" {
    const byte_count = tree_id_root.bytes.len;
    for (0..byte_count) |index| {
        var bytes = [_]u8{0} ** byte_count;
        bytes[index] = 1;
        const id = treeIdFromBytes(bytes);

        try testing.expect(!id.eql(tree_id_root));
        try testing.expect(!tree_id_root.eql(id));
    }
}

test "TreeId bytes round trip in both directions" {
    // The two halves differ, so a swap of the halves fails.
    const bytes: [16]u8 = .{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
    };
    const id = treeIdFromBytes(bytes);

    const written = treeIdToBytes(id);
    try testing.expectEqualSlices(u8, &bytes, &written);

    const read_back = treeIdFromBytes(treeIdToBytes(id));
    try testing.expect(read_back.eql(id));
}

test "TreeId byte order is preserved, not reversed" {
    const bytes: [16]u8 = .{
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
    };
    const written = treeIdToBytes(treeIdFromBytes(bytes));

    try testing.expectEqual(@as(u8, 0x01), written[7]);
}

test "TreeId orders by its bytes, most significant first" {
    const low = treeIdFromBytes([_]u8{0} ** 16);
    const high = treeIdFromBytes(.{ 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 });

    try testing.expect(low.lessThan(high));
    try testing.expect(!high.lessThan(low));
    try testing.expect(!low.lessThan(tree_id_root));
}

test "equal TreeIds digest equal and the bytes reach the hasher" {
    const bytes: [16]u8 = .{0xaa} ** 16;

    var first = std.hash.Wyhash.init(0);
    treeIdFromBytes(bytes).hash(&first);
    var second = std.hash.Wyhash.init(0);
    treeIdFromBytes(bytes).hash(&second);

    try testing.expectEqual(first.final(), second.final());

    var other_bytes = bytes;
    other_bytes[15] = 0xab;
    var other = std.hash.Wyhash.init(0);
    treeIdFromBytes(other_bytes).hash(&other);

    try testing.expect(first.final() != other.final());
}
