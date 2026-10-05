//! Transforms, bounding boxes and hit tests.
//!
//! Upstream `accesskit_consumer/src/node.rs:291-395`. The hierarchy queries of
//! the same `impl NodeRef` block are in `node_ref/hierarchy.zig`, from `:84` to
//! `:289`; the split is `docs/30-port-design.md` section 3.2.
//!
//! **Every operation here is a free function whose first parameter is the
//! node.** `node_id.zig` declares the `NodeRef` body, so it is the only file
//! that may carry a `NodeRef` method. A call reads `geometry.boundingBox(node)`,
//! not `node.bounding_box()`.
//!
//! **What the geometry comes from.** `Affine`, `Point`, `Rect`, `Size` and
//! `Vec2` are the `extern struct`s of `src/schema/geometry/`, measured and pinned
//! by their own `comptime` blocks: 48 bytes at alignment 8 for `Affine`, 32 for
//! `Rect` and 16 for `Point`. They are the ABI types the C header describes, so
//! this file uses them directly and declares no second set. A reader who looks
//! for a consumer-local `Rect` will not find one, and that is deliberate: two
//! structs with the same four `f64` would be two layouts to keep in step.
//! `schema.affine_identity` is the value upstream names `Affine::IDENTITY`.
//!
//! **Three decisions this file records.**
//!
//! - **The recursion in the bounding-box walk.** There is no subtree bounding
//!   box in this range. Upstream `bounding_box` at `node.rs:332-336` maps one
//!   node's own `bounds` property through that node's accumulated transform, and
//!   `transform_rect_bbox` unions the four transformed corners rather than the
//!   corners of a subtree. The subtree union is `Range::bounding_boxes` at
//!   `text.rs:740-820`, which walks and unions and belongs to `text/range.zig`.
//!   The one walk this range owns that descends a subtree is `hit_test`'s stack
//!   at `node.rs:359`, which `docs/33` section 7 lists for
//!   `node_ref/geometry.zig` under the name `treeWalkStepBound`. It needs a
//!   bound of its own because one node can sit on that stack twice, once as the
//!   frame that opens it and once as the frame that tests it, so the step count
//!   is twice the node count. The derivation is at `hitTestStepBound`. The three
//!   ancestor walks at `node.rs:299-320` take `treeWalkStepBound` unchanged, and
//!   `docs/33` section 7.1 row 9 names them.
//! - **A bounding box that unions carries its error.** `docs/33` section 8 gives
//!   `boundingBox(node) ?Rect`, and that row cannot stand, because
//!   `boundingBox` calls `transform`, which `docs/33` section 7.1 row 9 makes
//!   `QueryError!Affine`, and house rule C8 forbids discarding an error or
//!   replacing one with an `unreachable`. So `boundingBox` and
//!   `boundingBoxInCoordinateSpace` return `QueryError!?Rect` and
//!   `nodeAtPoint` returns `QueryError!?NodeRef`. The tag a caller sees is the
//!   one `transform` produces, which is `error.TreeCycle` for a parent cycle.
//! - **Where a hit test lands.** This file owns the geometry hit tests:
//!   `hit_test` at `node.rs:344-385` and `node_at_point` at `node.rs:389-395`,
//!   which is the same walk with the point dropped. The text-level hit tests at
//!   `text.rs:932-978` are `text/hit_test.zig`, a different layer with a
//!   different input, and nothing in this range reaches them.
//!
//! **`hitTest` allocates, so it takes an allocator.** Upstream builds the stack
//! with `Vec::with_capacity` at `node.rs:357`, and `docs/33` section 6 puts
//! `gpa` second on a free function whose receiver comes first. `error.OutOfMemory`
//! is already a member of `QueryError`, so one error set covers the allocation
//! and the bound.
//!
//! Nothing here takes an `io`, this file reads no clock, and every constant is
//! `const`.

const std = @import("std");

const schema = @import("../../schema/root.zig");
// The four operations on `Affine` that compose or invert are file-scope
// functions of the schema module that owns the type, and `schema/root.zig`
// re-exports only the constructors. A consumer that needed them would otherwise
// reimplement the composition, which is exactly the second set of geometry the
// module doc refuses.
const affine_mod = @import("../../schema/geometry/affine.zig");
const tree_index = @import("../tree_index.zig");
const tree_state = @import("../tree_state.zig");
const node_id = @import("../node_id.zig");
const filter_mod = @import("../filter.zig");
const hierarchy = @import("hierarchy.zig");

const Affine = schema.Affine;
const Point = schema.Point;
const Rect = schema.Rect;
const FullNodeId = tree_index.FullNodeId;
const NodeRef = node_id.NodeRef;
const TreeState = tree_state.TreeState;
const FilterFn = filter_mod.FilterFn;
const FilterResult = filter_mod.FilterResult;
const QueryError = tree_state.QueryError;
const treeWalkStepBound = tree_state.treeWalkStepBound;

const testing = std.testing;

// --- The transforms -----------------------------------------------------------

/// The transform written on this node alone, or the identity when the node
/// writes none. Upstream `node.rs:291-295`.
///
/// Ancestor transforms are not applied. The return is a copy of six `f64`, so
/// nothing the caller does to the store changes it afterwards.
pub fn directTransform(node: NodeRef) Affine {
    const found = schema.option.transform(&node.data().properties) orelse
        return schema.affine_identity;
    return found.*;
}

/// The combined transform of this node and its ancestors, up to and including
/// the root of its tree. Upstream `node.rs:299-307`.
///
/// The composition runs from the node upward, so the root's transform is
/// applied last and the node's own is applied first. Each step moves one level
/// up, the state holds at most `node_count` nodes, and a step past
/// `treeWalkStepBound(node_count)` means a node is its own ancestor. That is
/// `error.TreeCycle`, and `docs/33` section 7.1 row 9 is this walk.
pub fn transform(node: NodeRef) QueryError!Affine {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var accumulated = directTransform(node);
    var current = node;
    var steps: usize = 0;
    while (hierarchy.parent(current)) |parent_node| {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        accumulated = affine_mod.mul(directTransform(parent_node), accumulated);
        current = parent_node;
    }
    return accumulated;
}

/// The transform of this node relative to `stop_at`, which is excluded.
/// Upstream `node.rs:309-320`.
///
/// The walk stops before it applies `stop_at`'s own transform, so the result
/// places this node in `stop_at`'s coordinate space. The bound is the one
/// `transform` takes, because the walk is the same walk with one condition
/// more. `stop_at` that is not an ancestor ends the walk at the root, which is
/// upstream's behaviour and not an error.
pub fn relativeTransform(node: NodeRef, stop_at: NodeRef) QueryError!Affine {
    const bound = treeWalkStepBound(node.tree_state.nodes.count());
    var accumulated = directTransform(node);
    var current = node;
    var steps: usize = 0;
    while (hierarchy.parent(current)) |parent_node| {
        if (std.meta.eql(parent_node.id(), stop_at.id())) return accumulated;
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        accumulated = affine_mod.mul(directTransform(parent_node), accumulated);
        current = parent_node;
    }
    return accumulated;
}

// --- The bounding boxes --------------------------------------------------------

/// The untransformed `bounds` property, or `null` when the node writes none.
/// Upstream `node.rs:322-324`.
///
/// The answer is in this node's own coordinate space, so two nodes with the
/// same property but different ancestors give two boxes in different spaces.
pub fn rawBounds(node: NodeRef) ?Rect {
    return schema.option.bounds(&node.data().properties);
}

/// Whether the node writes a `bounds` property at all. Upstream `node.rs:326-328`,
/// which is `raw_bounds().is_some()`.
pub fn hasBounds(node: NodeRef) bool {
    return rawBounds(node) != null;
}

/// The node's bounding box in the tree container's coordinate space, or `null`
/// when the node writes no `bounds`. Upstream `node.rs:330-336`.
///
/// The four corners of the raw box go through the accumulated transform and the
/// smallest box around them is the answer, so a rotated or scaled node gives a
/// box larger than its own. The returned union therefore depends on the order
/// the ancestors compose in, which is what `transform` fixes.
///
/// The error is `transform`'s, because this function calls it. `docs/33`
/// section 8 gives the row `boundingBox(node) ?Rect`, and that row cannot hold
/// without discarding that error. The module doc records the substitution.
pub fn boundingBox(node: NodeRef) QueryError!?Rect {
    const raw = rawBounds(node) orelse return null;
    return affine_mod.transformRectBbox(try transform(node), raw);
}

/// The node's bounding box in `other`'s coordinate space, or `null` when the node
/// writes no `bounds`. Upstream `node.rs:338-342`, `pub(crate)`.
///
/// The error is `relativeTransform`'s, for the same reason `boundingBox` carries
/// `transform`'s.
pub fn boundingBoxInCoordinateSpace(node: NodeRef, other: NodeRef) QueryError!?Rect {
    const raw = rawBounds(node) orelse return null;
    return affine_mod.transformRectBbox(try relativeTransform(node, other), raw);
}

// --- The hit tests -------------------------------------------------------------

/// One entry of the hit-test stack: the node and the point in that node's own
/// coordinate space.
///
/// The same two values sit in both frames. `visit` opens a node: it asks the
/// filter, and it queues the node's own probe and its children. `probe` asks
/// whether the node's raw box holds the point.
const HitTarget = struct {
    node: NodeRef,
    point: Point,
};

/// One entry of the hit-test stack. Upstream's `enum Frame` at `node.rs:352-355`,
/// whose second tag is `Test`. `test` is a keyword here, so the tag is `probe`.
const HitFrame = union(enum) {
    visit: HitTarget,
    probe: HitTarget,
};

/// The deepest filtered node at `point` in this node's coordinate space,
/// together with the point in that node's coordinate space, or `null` when no
/// node's box holds it. Upstream `node.rs:344-385`, `pub(crate)`.
///
/// **The order is upstream's and it is the whole behaviour.** A `visit` frame is
/// pushed before its children and the children are pushed in forward order, so
/// the stack pops them last to first, and the node's own `test` frame was pushed
/// before all of them, so it is tried only after every descendant has missed. A
/// walk over two overlapping boxes that returned the first child would be wrong.
///
/// Each child is handed the point in its own coordinate space by applying the
/// inverse of that child's direct transform, which is what lets a transformed
/// child be found at the position it appears at rather than the position it
/// stores.
///
/// `gpa` is the second parameter because the stack allocates, and
/// `docs/33` section 6 puts the allocator after the receiver.
pub fn hitTest(
    gpa: std.mem.Allocator,
    node: NodeRef,
    point: Point,
    filter: FilterFn,
) QueryError!?struct { node: NodeRef, point: Point } {
    const bound = hitTestStepBound(node.tree_state.nodes.count());
    var stack: std.ArrayList(HitFrame) = .empty;
    defer stack.deinit(gpa);
    var steps: usize = 0;
    try stack.append(gpa, .{ .visit = .{ .node = node, .point = point } });
    while (stack.pop()) |frame| {
        steps += 1;
        if (steps > bound) return error.TreeCycle;
        switch (frame) {
            .probe => |target| {
                const box = rawBounds(target.node) orelse continue;
                if (box.contains(target.point)) {
                    return .{ .node = target.node, .point = target.point };
                }
            },
            .visit => |target| {
                const verdict = try filter.call(target.node);
                if (verdict == .exclude_subtree) continue;
                if (verdict == .include) {
                    try stack.append(gpa, .{ .probe = target });
                }
                var cursor = hierarchy.children(target.node);
                while (cursor.next()) |child| {
                    // The child reads the point in its own space, so the walk
                    // descends through every transform on the way down.
                    const in_child_space = affine_mod.mulPoint(
                        affine_mod.inverse(directTransform(child)),
                        target.point,
                    );
                    try stack.append(
                        gpa,
                        .{ .visit = .{ .node = child, .point = in_child_space } },
                    );
                }
            },
        }
    }
    return null;
}

/// The deepest filtered node at `point` in this node's coordinate space, or
/// `null` when none. Upstream `node.rs:389-395`.
///
/// The same walk as `hitTest` with the point dropped, so it takes the same two
/// parameters after the receiver and reports the same errors.
pub fn nodeAtPoint(
    gpa: std.mem.Allocator,
    node: NodeRef,
    point: Point,
    filter: FilterFn,
) QueryError!?NodeRef {
    const found = try hitTest(gpa, node, point, filter) orelse return null;
    return found.node;
}

/// The step bound for the hit-test stack. One step pops one frame. Every node is
/// pushed at most once as a `visit` frame, because a node has one parent and a
/// parent's `visit` frame is popped once, and at most once as a `test` frame,
/// because the node's own `visit` frame is the only thing that pushes one. The
/// state holds at most `node_count` nodes, so the stack holds at most
/// `2 * node_count` frames and the pops cannot exceed the pushes. The sum is
/// `2 * treeWalkStepBound(node_count)`.
///
/// The plain `treeWalkStepBound` would be short by one on a star of `n`
/// included children, because that walk pops the root's `visit` frame, then each
/// child's `visit` frame, then the root's `test` frame: `n + 2` pops against
/// `n + 1` nodes.
pub fn hitTestStepBound(node_count: usize) usize {
    return 2 * treeWalkStepBound(node_count);
}

comptime {
    // The derivation above, pinned where a plain node bound would differ from
    // this one. A star of two included children pops four frames over three
    // nodes, so `treeWalkStepBound(3)` is one short.
    std.debug.assert(hitTestStepBound(0) == 0);
    std.debug.assert(hitTestStepBound(3) == 6);
    std.debug.assert(treeWalkStepBound(3) == 3);
    std.debug.assert(hitTestStepBound(65_536) == 131_072);
}

// --- The tests ----------------------------------------------------------------

/// A state one test builds a node at a time, so one `deinit` releases every node
/// and a test cannot leak one by forgetting it.
const Fixture = struct {
    gpa: std.mem.Allocator,
    state: TreeState = .{},

    /// Releases the map and every node's property buffers.
    fn deinit(self: *Fixture) void {
        self.state.deinit(self.gpa);
        // SAFETY: `state.deinit` released every buffer the fixture owned, and
        // no statement after it reads `self`.
        self.* = undefined;
    }

    /// Stores one node and returns its id. `parent` is `null` for a root.
    fn add(self: *Fixture, local: u64, parent: ?FullNodeId) !FullNodeId {
        const id = FullNodeId.init(.{ .value = local }, .init(0));
        try self.state.nodes.put(self.gpa, id, .{
            .parent_and_index = if (parent) |p| .{ .parent_id = p, .index = 0 } else null,
            .data = schema.Node.init(self.gpa, .group),
        });
        return id;
    }

    /// Writes the local ids `locals` as the node's `children` property.
    fn setChildren(self: *Fixture, id: FullNodeId, locals: []const u64) !void {
        const list = try self.gpa.alloc(schema.NodeId, locals.len);
        defer self.gpa.free(list);
        for (locals, list) |local, *slot| slot.* = .{ .value = local };
        try schema.ids_props.setChildren(&self.state.nodes.getPtr(id).?.data.properties, list);
    }

    fn setTransform(self: *Fixture, id: FullNodeId, value: Affine) !void {
        try schema.option.setTransform(&self.state.nodes.getPtr(id).?.data.properties, value);
    }

    /// Writes the box `rect` as the node's `bounds` property.
    fn setBounds(self: *Fixture, id: FullNodeId, box: Rect) !void {
        try schema.option.setBounds(&self.state.nodes.getPtr(id).?.data.properties, box);
    }

    fn ref(self: *Fixture, id: FullNodeId) !NodeRef {
        return NodeRef.init(&self.state, id) orelse error.NodeMissingFromState;
    }
};

fn includeAll(_: ?*anyopaque, _: NodeRef) QueryError!FilterResult {
    return .include;
}

fn includeNothing(_: ?*anyopaque, _: NodeRef) QueryError!FilterResult {
    return .exclude_subtree;
}

fn includeAllFilter() FilterFn {
    return .{ .context = null, .filter = includeAll };
}

fn excludeAllFilter() FilterFn {
    return .{ .context = null, .filter = includeNothing };
}

fn boxOf(x0: f64, y0: f64, x1: f64, y1: f64) Rect {
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1 };
}

fn ptOf(x: f64, y: f64) Point {
    return .{ .x = x, .y = y };
}

/// The three nodes a transform test writes onto.
const Levels = struct { root: NodeRef, middle: NodeRef, leaf: NodeRef };

/// A three-node chain: `root`, `middle` and `leaf`, each hanging from the one
/// before. A test writes the properties it needs.
fn threeLevels(fixture: *Fixture) !Levels {
    const root_id = try fixture.add(0, null);
    const middle_id = try fixture.add(1, root_id);
    const leaf_id = try fixture.add(2, middle_id);
    return .{
        .root = try fixture.ref(root_id),
        .middle = try fixture.ref(middle_id),
        .leaf = try fixture.ref(leaf_id),
    };
}

test "directTransform answers the identity for a node that writes no transform" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const id = try fixture.add(0, null);
    const node = try fixture.ref(id);

    // An all-zero `Affine` is a map that sends every point to the origin, so a
    // port that defaulted to it would collapse every box to a point.
    try testing.expectEqual(schema.affine_identity, directTransform(node));

    const scale = schema.affineScale(3.0);
    try fixture.setTransform(id, scale);
    try testing.expectEqual(scale, directTransform(node));
}

test "transform composes from the node upward so the root applies last" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const levels = try threeLevels(&fixture);
    try fixture.setTransform(levels.root.id(), schema.affineScale(2.0));
    try fixture.setTransform(levels.middle.id(), schema.affineTranslate(.{ .x = 5, .y = 0 }));
    try fixture.setTransform(levels.leaf.id(), schema.affineTranslate(.{ .x = 1, .y = 0 }));

    // Scale, then translate by five, then translate by one: the leaf's own
    // transform applies first and the root's scale applies last. Composing the
    // other way round gives twenty for the translation, and this test is the
    // one that separates the two.
    try testing.expectEqual(
        ptOf(12.0, 0.0),
        affine_mod.mulPoint(try transform(levels.leaf), ptOf(0.0, 0.0)),
    );

    // The middle node's own translation is the inner one and the root's scale
    // is the outer one, so five becomes ten. A port that composed the other way
    // round would answer five here.
    try testing.expectEqual(
        ptOf(10.0, 0.0),
        affine_mod.mulPoint(try transform(levels.middle), ptOf(0.0, 0.0)),
    );

    // A root has no parent, so its accumulated transform is its own.
    try testing.expectEqual(schema.affineScale(2.0), try transform(levels.root));
}

test "relativeTransform stops before the node it is told to stop at" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const levels = try threeLevels(&fixture);
    try fixture.setTransform(levels.root.id(), schema.affineScale(2.0));
    try fixture.setTransform(levels.middle.id(), schema.affineTranslate(.{ .x = 5, .y = 0 }));
    try fixture.setTransform(levels.leaf.id(), schema.affineTranslate(.{ .x = 1, .y = 0 }));

    // Up to the root but not including it, so the scale is absent.
    try testing.expectEqual(
        ptOf(6.0, 0.0),
        affine_mod.mulPoint(try relativeTransform(levels.leaf, levels.root), ptOf(0.0, 0.0)),
    );
    // Up to the middle, so only the leaf's own transform is left.
    try testing.expectEqual(
        ptOf(1.0, 0.0),
        affine_mod.mulPoint(try relativeTransform(levels.leaf, levels.middle), ptOf(0.0, 0.0)),
    );
    // A stop node that is not an ancestor ends the walk at the root, which is
    // the same answer `transform` gives.
    try testing.expectEqual(
        ptOf(12.0, 0.0),
        affine_mod.mulPoint(try relativeTransform(levels.leaf, levels.leaf), ptOf(0.0, 0.0)),
    );
}

test "rawBounds and hasBounds read the node's own box and nothing else" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const levels = try threeLevels(&fixture);
    try testing.expect(rawBounds(levels.leaf) == null);
    try testing.expect(!hasBounds(levels.leaf));

    // A parent's box must not answer for a child that writes none.
    try fixture.setBounds(levels.root.id(), boxOf(0, 0, 10, 10));
    try testing.expect(rawBounds(levels.leaf) == null);
    try testing.expect(hasBounds(levels.root));

    const own = boxOf(1, 2, 3, 4);
    try fixture.setBounds(levels.leaf.id(), own);
    try testing.expectEqual(own, rawBounds(levels.leaf).?);
    try testing.expect(hasBounds(levels.leaf));
}

test "boundingBox over a subtree with a transformed child follows the transform" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root scales by two and the child translates by ten. The child writes
    // a 4 by 4 box at the origin of its own space.
    const levels = try threeLevels(&fixture);
    try fixture.setTransform(levels.root.id(), schema.affineTranslate(.{ .x = 10, .y = 0 }));
    try fixture.setTransform(levels.leaf.id(), schema.affineScale(2.0));
    try fixture.setBounds(levels.leaf.id(), boxOf(0, 0, 4, 4));

    // The child's own scale applies first and the root's translation second, so
    // the box is 8 wide and starts at x = 10. Reading the raw corners gives
    // (0, 0, 4, 4) and reversing the composition gives x = 20, so this one
    // assertion rules out both errors.
    const box = (try boundingBox(levels.leaf)) orelse return error.NoBounds;
    try testing.expectEqual(boxOf(10.0, 0.0, 18.0, 8.0), box);
    try testing.expectEqual(boxOf(0.0, 0.0, 4.0, 4.0), rawBounds(levels.leaf).?);

    // The root writes no bounds, so its box is null even though its child has
    // one. Upstream does not union, and this pins that.
    try testing.expect((try boundingBox(levels.root)) == null);
}

test "boundingBoxInCoordinateSpace places the box in the named node's space" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const levels = try threeLevels(&fixture);
    try fixture.setTransform(levels.root.id(), schema.affineScale(2.0));
    try fixture.setTransform(levels.leaf.id(), schema.affineTranslate(.{ .x = 1, .y = 0 }));
    try fixture.setBounds(levels.leaf.id(), boxOf(0, 0, 4, 4));

    // In the container's space the root's scale has moved the far edge to 10.
    try testing.expectEqual(boxOf(2.0, 0.0, 10.0, 8.0), (try boundingBox(levels.leaf)).?);
    // In the middle's space the root's scale is absent.
    try testing.expectEqual(
        boxOf(1.0, 0.0, 5.0, 4.0),
        (try boundingBoxInCoordinateSpace(levels.leaf, levels.middle)).?,
    );
}

test "a hit test on a box edge takes the near edge and refuses the far one" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root_id = try fixture.add(0, null);
    const child_id = try fixture.add(1, root_id);
    try fixture.setChildren(root_id, &.{1});
    try fixture.setBounds(child_id, boxOf(0, 0, 10, 10));
    const root = try fixture.ref(root_id);

    // `Rect.contains` takes `>=` on the near edges and `<` on the far ones, so
    // a port that used `<=` on the far edge reports a hit one pixel outside the
    // box. Each of the four edges is one of those two cases.
    const near_corner = try nodeAtPoint(gpa, root, ptOf(0, 0), includeAllFilter());
    try testing.expectEqual(child_id, (near_corner orelse return error.NoHit).id());

    const near_edge = try nodeAtPoint(gpa, root, ptOf(10, 5), includeAllFilter());
    try testing.expect(near_edge == null);

    const far_corner = try nodeAtPoint(gpa, root, ptOf(10, 10), includeAllFilter());
    try testing.expect(far_corner == null);

    const near_y = try nodeAtPoint(gpa, root, ptOf(5, 0), includeAllFilter());
    try testing.expectEqual(child_id, (near_y orelse return error.NoHit).id());

    const far_y = try nodeAtPoint(gpa, root, ptOf(5, 10), includeAllFilter());
    try testing.expect(far_y == null);

    // One unit inside the far edge is a hit, so the four cases above are about
    // the edge and not about a box that never matches.
    const inside = try nodeAtPoint(gpa, root, ptOf(9.999, 9.999), includeAllFilter());
    try testing.expectEqual(child_id, (inside orelse return error.NoHit).id());
}

test "a hit test finds a child before the parent's own box and searches last to first" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The root's own box covers both children, so a walk that tested the node
    // before its descendants would answer with the root.
    const root_id = try fixture.add(0, null);
    const first_id = try fixture.add(1, root_id);
    const last_id = try fixture.add(2, root_id);
    try fixture.setChildren(root_id, &.{ 1, 2 });
    try fixture.setBounds(root_id, boxOf(0, 0, 100, 100));
    try fixture.setBounds(first_id, boxOf(0, 0, 10, 10));
    try fixture.setBounds(last_id, boxOf(0, 0, 10, 10));
    const root = try fixture.ref(root_id);

    // The children are pushed in forward order and popped last to first, so the
    // later sibling wins when both boxes hold the point.
    const found = try hitTest(gpa, root, ptOf(5, 5), includeAllFilter()) orelse
        return error.NoHit;
    try testing.expectEqual(last_id, found.node.id());
    // The point comes back in the node's own space, which is the same here
    // because no transform sits between them.
    try testing.expectEqual(ptOf(5, 5), found.point);

    // With the parent's box alone, the walk falls through to the root.
    try fixture.setBounds(last_id, boxOf(50, 50, 60, 60));
    try fixture.setBounds(first_id, boxOf(50, 50, 60, 60));
    const alone = try nodeAtPoint(gpa, root, ptOf(5, 5), includeAllFilter());
    try testing.expectEqual(root_id, (alone orelse return error.NoHit).id());
}

test "a hit test hands each child the point in the child's own space" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // The child writes a box at the origin of its own space and translates by
    // ten, so it is found at ten and not at zero.
    const root_id = try fixture.add(0, null);
    const child_id = try fixture.add(1, root_id);
    try fixture.setChildren(root_id, &.{1});
    try fixture.setTransform(child_id, schema.affineTranslate(.{ .x = 10, .y = 20 }));
    try fixture.setBounds(child_id, boxOf(0, 0, 5, 5));
    const root = try fixture.ref(root_id);

    const inside = try hitTest(gpa, root, ptOf(12, 22), includeAllFilter()) orelse
        return error.NoHit;
    try testing.expectEqual(child_id, inside.node.id());
    // The point comes back inverse-transformed, which is what a caller needs
    // to place a caret inside the node it found.
    try testing.expectEqual(ptOf(2, 2), inside.point);

    // The untransformed position misses, so a walk that skipped the inverse
    // would find the box at the wrong place.
    try testing.expect((try nodeAtPoint(gpa, root, ptOf(2, 2), includeAllFilter())) == null);
}

test "a filter that excludes a subtree prunes the whole walk below it" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const root_id = try fixture.add(0, null);
    const closed_id = try fixture.add(1, root_id);
    const buried_id = try fixture.add(2, closed_id);
    try fixture.setChildren(root_id, &.{1});
    try fixture.setChildren(closed_id, &.{2});
    try fixture.setBounds(buried_id, boxOf(0, 0, 10, 10));
    const root = try fixture.ref(root_id);

    try testing.expectEqual(
        buried_id,
        (try nodeAtPoint(gpa, root, ptOf(5, 5), includeAllFilter()) orelse return error.NoHit).id(),
    );
    try testing.expect((try nodeAtPoint(gpa, root, ptOf(5, 5), excludeAllFilter())) == null);

    // A node with no `bounds` is never a hit, and the root itself has none.
    try testing.expect((try nodeAtPoint(gpa, root, ptOf(500, 500), includeAllFilter())) == null);
}

test "a hit test over a child cycle reaches the bound and reports TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    // Two nodes that list each other, neither with a box. Without the bound the
    // stack grows until the allocator gives out instead of answering.
    const first_id = try fixture.add(0, null);
    const second_id = try fixture.add(1, null);
    try fixture.setChildren(first_id, &.{1});
    try fixture.setChildren(second_id, &.{1});
    const first = try fixture.ref(first_id);

    try testing.expectError(
        error.TreeCycle,
        hitTest(gpa, first, ptOf(0, 0), includeAllFilter()),
    );
    try testing.expectError(
        error.TreeCycle,
        nodeAtPoint(gpa, first, ptOf(0, 0), includeAllFilter()),
    );

    // The positive half, one step short of the bound: break the cycle and the
    // same walk answers.
    try fixture.setChildren(second_id, &.{});
    try testing.expect((try nodeAtPoint(gpa, first, ptOf(0, 0), includeAllFilter())) == null);
}

test "an ancestor cycle makes the two transform walks report TreeCycle" {
    const gpa = testing.allocator;
    var fixture: Fixture = .{ .gpa = gpa };
    defer fixture.deinit();

    const first_id = try fixture.add(0, null);
    const second_id = try fixture.add(1, first_id);
    const outside_id = try fixture.add(2, null);
    fixture.state.nodes.getPtr(first_id).?.parent_and_index = .{
        .parent_id = second_id,
        .index = 0,
    };
    fixture.state.nodes.getPtr(second_id).?.parent_and_index = .{
        .parent_id = first_id,
        .index = 0,
    };
    const first = try fixture.ref(first_id);

    // The parent chain never reaches the root, so only the bound ends these two.
    try testing.expectError(error.TreeCycle, transform(first));
    // A stop node that is on the chain would end the walk at once, so the walk
    // that reaches the bound is the one given a node the chain never holds.
    try testing.expectError(error.TreeCycle, relativeTransform(first, try fixture.ref(outside_id)));

    // The positive half: the chain reaches the root and both answer.
    fixture.state.nodes.getPtr(second_id).?.parent_and_index = null;
    try testing.expectEqual(schema.affine_identity, try transform(first));
}
