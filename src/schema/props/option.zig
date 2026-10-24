//! The four stored properties whose value may be absent: `Transform`,
//! `Bounds`, `TextSelection` and `TreeId`.
//!
//! Import route: `@import("schema/props/option.zig")`. The module publishes
//! twelve functions, a getter, a setter and a clearer for each of the four
//! properties, and names nothing else. The store these functions read and write
//! is `table.Properties`. The property domain, `table.PropertyId` and
//! `table.PropertyValue`, is also in `table.zig`. `Node` is in `node.zig`, and
//! a caller reaches this module through the store its node already holds.
//!
//! Every function takes the store as its first parameter and nothing beyond
//! the value a setter writes. The store holds the allocator it was created
//! with, so no function here names one and none can be handed an allocator the
//! store does not free through.
//!
//! Absent and zero are two states. `null` from a getter means the property is
//! not set. A stored `rect_zero`, `affine_identity` or `tree_id_root` is a value a
//! caller wrote, and it survives a read that an absent property does not. That
//! is the whole point of this module. The port drops the upstream `Unset`
//! sentinel (`docs/30-port-design.md` section 3.4), because a property that is
//! not in the store's slice is not set, so no stored value has to stand for
//! absence. `table.PropertyId` therefore declares the 87 real properties and
//! no sentinel, and `table.zig` pins that count.
//!
//! The module allocates nothing of its own. A setter hands the store the
//! payload by value and lets the store grow its own slice, so the only
//! allocation on the path is the one `Properties.set` makes and guards.
//! Upstream's `owned_type_setters` family needed an `errdefer` because it took
//! ownership of a `Box`, a `String` or a `Vec` and could fail partway holding
//! the replacement. The port deletes the two `Box` payloads, and all four
//! payloads here are inline values, so no function in this module owns a
//! temporary and none needs a guard. A string setter in `props/strings.zig`
//! and a list setter in `props/vectors.zig` still own an allocation, and both
//! still carry the guard.
//!
//! Upstream splits these four getters across two shared families,
//! `option_ref_type_getters` for `Affine` and `TextSelection` and
//! `copy_type_getters` for `Rect` and `TreeId` (`accesskit/src/lib.rs:1977`,
//! `:1988`). The port keeps the split: the two large payloads are read by
//! borrow, the two small ones by copy.
//!
//! Nothing here reads a clock, a socket or an environment variable, so no
//! function takes `io` and none blocks.
//!
//! Upstream: `accesskit/src/lib.rs:2508-2546`, the `property_methods!` block,
//! over the shared families at `accesskit/src/lib.rs:1977-2018`.

const std = @import("std");

const assert = std.debug.assert;

const testing = std.testing;

const table = @import("table.zig");

const ids = @import("../ids.zig");
const values = @import("../values.zig");
const affine_module = @import("../geometry/affine.zig");
const rect_module = @import("../geometry/rect.zig");

const Affine = affine_module.Affine;
const Rect = rect_module.Rect;
const TextSelection = values.TextSelection;
const TreeId = ids.TreeId;

const Properties = table.Properties;
const PropertyId = table.PropertyId;

/// The transform to apply to the coordinates of this node and its descendants,
/// or `null` when the property is not set.
///
/// `null` means not set, which is not the identity transform. Upstream asks
/// for `None` here on most nodes (`accesskit/src/lib.rs:2512-2514`). The
/// transforms of a node and its ancestors combine to give that node its
/// coordinate space, and the final coordinates are relative to the origin of
/// the tree container, in physical pixels, with y growing down.
///
/// Upstream returns `Option<&Affine>` over a stored `Option<Box<Affine>>`
/// (`accesskit/src/lib.rs:881`, `:1225`, `:2504-2521`). The port drops the
/// `Box` and holds the 48 bytes inline, so a read has no teardown to follow
/// and a setter costs no allocation beyond the growth of the store.
///
/// The result borrows `properties`. A setter or a clearer may move the store's
/// slice, so a caller reads again after one. Nothing owns the transform, so
/// the caller releases nothing.
pub fn transform(properties: *const Properties) ?*const Affine {
    const found = properties.get(.transform) orelse return null;
    return switch (found.*) {
        .affine => |*value| value,
        // Upstream reads `_ => None` (`accesskit/src/lib.rs:1226-1229`), so a
        // slot holding another payload reads as absent instead of faulting.
        else => null,
    };
}

/// Stores `value` as the transform, replacing any value already stored under
/// `PropertyId.transform`.
///
/// The store allocates through the allocator it was created with. On
/// `error.OutOfMemory` it holds exactly the properties it held before the
/// call. The value is copied into the store, so the caller keeps a copy of its
/// own.
pub fn setTransform(properties: *Properties, value: Affine) std.mem.Allocator.Error!void {
    try properties.set(.transform, table.propertyValueFrom(.affine, value));
}

/// Removes the transform, so `transform` reads `null`.
///
/// A store that does not hold the property is left as it was, which is
/// upstream's `Properties::clear` (`accesskit/src/lib.rs:1148-1153`).
pub fn clearTransform(properties: *Properties) void {
    properties.clear(.transform);
}

/// The bounding box of this node in the node's own coordinate space, or `null`
/// when the property is not set.
///
/// `bounds` does not move the coordinate space of this node or of its
/// descendants. Only `transform` does. With most nodes carrying no transform,
/// that puts `bounds` in the coordinate space of the nearest ancestor that has
/// one, and in the coordinate space of the tree container when no ancestor has
/// one.
///
/// The result is a copy of the four coordinates, so it stays valid after a
/// write to the store.
pub fn bounds(properties: *const Properties) ?Rect {
    const found = properties.get(.bounds) orelse return null;
    return switch (found.*) {
        .rect => |value| value,
        else => null,
    };
}

/// Stores `value` as the bounding box, replacing any value already stored
/// under `PropertyId.bounds`.
///
/// The store allocates through the allocator it was created with. On
/// `error.OutOfMemory` it holds exactly the properties it held before the
/// call. The value is copied into the store.
pub fn setBounds(properties: *Properties, value: Rect) std.mem.Allocator.Error!void {
    try properties.set(.bounds, table.propertyValueFrom(.rect, value));
}

/// Removes the bounding box, so `bounds` reads `null`.
///
/// A store that does not hold the property is left as it was.
pub fn clearBounds(properties: *Properties) void {
    properties.clear(.bounds);
}

/// The text selection or the caret inside this node's text, or `null` when the
/// property is not set.
///
/// A selection with no extent is a caret, and it holds `anchor` equal to
/// `focus`. Upstream returns `Option<&TextSelection>` over a stored
/// `Option<Box<TextSelection>>` (`accesskit/src/lib.rs:883`, `:1225`,
/// `:2535-2536`). The port drops the `Box` and holds the value inline, so a
/// read has no teardown to follow and a setter costs no allocation beyond the
/// growth of the store.
///
/// The result borrows `properties`. A setter or a clearer may move the store's
/// slice, so a caller reads again after one.
pub fn textSelection(properties: *const Properties) ?*const TextSelection {
    const found = properties.get(.text_selection) orelse return null;
    return switch (found.*) {
        .text_selection => |*value| value,
        else => null,
    };
}

/// Removes the text selection, so `textSelection` reads `null`.
///
/// A store that does not hold the property is left as it was.
pub fn clearTextSelection(properties: *Properties) void {
    properties.clear(.text_selection);
}

/// Stores `value` as the text selection, replacing any value already stored
/// under `PropertyId.text_selection`.
///
/// The store allocates through the allocator it was created with. On
/// `error.OutOfMemory` it holds exactly the properties it held before the
/// call. The value is copied into the store.
pub fn setTextSelection(
    properties: *Properties,
    value: TextSelection,
) std.mem.Allocator.Error!void {
    try properties.set(.text_selection, table.propertyValueFrom(.text_selection, value));
}

/// The tree this node grafts, or `null` when the property is not set.
///
/// `null` means the property is not set. It does not mean `tree_id_root`. The
/// nil UUID is a value a caller may store, and the store keeps it, so a graft
/// node carrying the nil id and a graft node carrying no id are two states.
/// This property accepts `tree_id_root` and the consumer rejects the nil id as a
/// graft target (`accesskit_consumer/src/tree.rs:187-189`), so the check
/// belongs to the consumer.
///
/// When the property is set, the node is a graft point and its child is the
/// root of the named subtree. The graft node must exist before its subtree is
/// pushed. Removing the graft node or clearing this property removes the
/// subtree, unless a new graft node arrives in the same update.
///
/// The property and the `TreeUpdate.tree_id` field were both added by commit
/// `c16eb80`, "feat!: Multiple tree support", and released in 0.23.0
/// (`accesskit/CHANGELOG.md`, 0.23.0 section). The 0.25.1 commit `1d53dae`
/// changed three schema lines and no runtime code, so no behaviour here
/// changed for 0.25.1. The port carries the property because a tree cannot be
/// grafted without it. A reader who compares this module against an
/// `accesskit.h` generated before 0.23.0 finds the property in neither the
/// header nor the C surface, and finds it here.
///
/// The result is a copy of the 16 bytes, so it stays valid after a write.
pub fn treeId(properties: *const Properties) ?TreeId {
    const found = properties.get(.tree_id) orelse return null;
    return switch (found.*) {
        .tree_id => |value| value,
        else => null,
    };
}

/// Stores `value` as the grafted tree, replacing any value already stored
/// under `PropertyId.tree_id`.
///
/// The store allocates through the allocator it was created with. On
/// `error.OutOfMemory` it holds exactly the properties it held before the
/// call. The value is copied into the store.
pub fn setTreeId(properties: *Properties, value: TreeId) std.mem.Allocator.Error!void {
    try properties.set(.tree_id, table.propertyValueFrom(.tree_id, value));
}

/// Removes the grafted tree, so `treeId` reads `null`.
///
/// A store that does not hold the property is left as it was.
pub fn clearTreeId(properties: *Properties) void {
    properties.clear(.tree_id);
}

/// The four properties this family publishes a getter, a setter and a clearer
/// for, in upstream order, from the `property_methods!` block at
/// `accesskit/src/lib.rs:2508-2546`: `Transform`, `Bounds`, `TextSelection`
/// and `TreeId`.
///
/// This is the family's whole domain in one place, so
/// `table.assertFamilyReachable` can hold it against the descriptor table. The
/// four payloads are four different types and stay one list, because the claim
/// is about properties and the payload of each row is already pinned by the
/// descriptor row this list is checked against.
pub const property_ids = [_]PropertyId{
    .transform,
    .bounds,
    .text_selection,
    .tree_id,
};

comptime {
    // The invocation carries four entries. A row added here without an upstream
    // entry changes the number of functions this module publishes, so the count
    // is the check.
    assert(property_ids.len == 4);
    table.assertFamilyReachable(.option, property_ids);
}

fn testAffine() Affine {
    // Six coefficients that are not the identity, so a read that reorders or
    // truncates the transform fails instead of looking like no transform.
    return affine_module.affineNew(.{ 2, 0, 0, 3, 4, 5 });
}

fn testRect() Rect {
    return rect_module.rectInit(0, 1, 2, 3);
}

fn testTextSelection() TextSelection {
    return .{
        .anchor = .{ .node_id = ids.nodeIdFromContent(0), .character_index = 0 },
        .focus = .{ .node_id = ids.nodeIdFromContent(0), .character_index = 2 },
    };
}

test "a transform set through the store comes back with its six coefficients" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(transform(&properties) == null);

    const expected = testAffine();
    try setTransform(&properties, expected);

    const stored = transform(&properties) orelse return error.TransformMissing;
    inline for (0..expected.coeffs.len) |index| {
        try testing.expect(stored.coeffs[index] == expected.coeffs[index]);
    }
}

test "clearing the transform reads null and not the identity" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setTransform(&properties, affine_module.affine_identity);

    const stored = transform(&properties) orelse return error.TransformMissing;
    try testing.expectEqual(@as(f64, 1), stored.coeffs[0]);
    try testing.expectEqual(@as(f64, 1), stored.coeffs[3]);

    clearTransform(&properties);

    try testing.expect(transform(&properties) == null);
}

test "setting the transform twice keeps the second value" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setTransform(&properties, affine_module.affine_flip_y);
    try setTransform(&properties, affine_module.affine_flip_x);

    const stored = transform(&properties) orelse return error.TransformMissing;
    try testing.expectEqual(@as(f64, -1), stored.coeffs[0]);
    try testing.expectEqual(@as(f64, 1), stored.coeffs[3]);
}

test "a bounds set through the store comes back as the four coordinates given" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(bounds(&properties) == null);

    const expected = testRect();
    try setBounds(&properties, expected);

    const stored = bounds(&properties) orelse return error.BoundsMissing;
    try testing.expectEqual(expected.x0, stored.x0);
    try testing.expectEqual(expected.y0, stored.y0);
    try testing.expectEqual(expected.x1, stored.x1);
    try testing.expectEqual(expected.y1, stored.y1);
}

test "clearing the bounds reads null and not an empty box" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setBounds(&properties, rect_module.rect_zero);

    const stored = bounds(&properties) orelse return error.BoundsMissing;
    try testing.expectEqual(@as(f64, 0), stored.x1);
    try testing.expectEqual(@as(f64, 0), stored.y1);

    clearBounds(&properties);

    try testing.expect(bounds(&properties) == null);
}

test "a text selection set through the store keeps its anchor and its focus" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(textSelection(&properties) == null);

    const expected = testTextSelection();
    try setTextSelection(&properties, expected);

    const stored = textSelection(&properties) orelse return error.TextSelectionMissing;
    try testing.expectEqual(expected.anchor.character_index, stored.anchor.character_index);
    try testing.expectEqual(expected.focus.character_index, stored.focus.character_index);
    try testing.expect(stored.anchor.node_id.eql(stored.focus.node_id));
}

test "clearing the text selection reads null and not a caret at offset zero" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setTextSelection(&properties, testTextSelection());

    const stored = textSelection(&properties) orelse return error.TextSelectionMissing;
    try testing.expectEqual(@as(usize, 2), stored.focus.character_index);

    clearTextSelection(&properties);

    try testing.expect(textSelection(&properties) == null);
}

test "a tree id set through the store comes back as the sixteen bytes given" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try testing.expect(treeId(&properties) == null);

    const expected = ids.treeIdFromBytes(.{
        0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef,
        0xfe, 0xdc, 0xba, 0x98, 0x76, 0x54, 0x32, 0x10,
    });
    try setTreeId(&properties, expected);

    const stored = treeId(&properties) orelse return error.TreeIdMissing;
    try testing.expect(stored.eql(expected));
}

test "sixteen zero bytes are a stored tree id and not an absent one" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setTreeId(&properties, ids.tree_id_root);

    // The nil id is a value the store keeps, and it is not the root tree the
    // consumer acts on. `null` is the only report of an absent property.
    const stored = treeId(&properties) orelse return error.TreeIdMissing;
    try testing.expect(stored.eql(ids.tree_id_root));
    try testing.expect(!stored.eql(ids.treeIdFromBytes(@splat(1))));

    clearTreeId(&properties);

    try testing.expect(treeId(&properties) == null);
}

test "clearing a tree id that was never set leaves the other properties alone" {
    var properties: Properties = .init(testing.allocator);
    defer properties.deinit();

    try setBounds(&properties, testRect());
    clearTreeId(&properties);

    try testing.expect(treeId(&properties) == null);
    const stored = bounds(&properties) orelse return error.BoundsMissing;
    try testing.expectEqual(@as(f64, 3), stored.y1);
}

fn storeEveryOptionProperty(gpa: std.mem.Allocator) std.mem.Allocator.Error!void {
    var properties: Properties = .init(gpa);
    defer properties.deinit();

    setTransform(&properties, testAffine()) catch |err| {
        // A setter that writes before it can fail leaves behind a value the
        // caller never received.
        assert(transform(&properties) == null);
        return err;
    };
    setBounds(&properties, testRect()) catch |err| {
        assert(bounds(&properties) == null);
        return err;
    };
    setTextSelection(&properties, testTextSelection()) catch |err| {
        assert(textSelection(&properties) == null);
        return err;
    };
    setTreeId(&properties, ids.tree_id_root) catch |err| {
        assert(treeId(&properties) == null);
        return err;
    };
}

test "a setter that runs out of memory leaves the store as it was" {
    try testing.checkAllAllocationFailures(testing.allocator, storeEveryOptionProperty, .{});
}
