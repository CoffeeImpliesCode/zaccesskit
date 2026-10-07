//! The consumer half of the port: a materialized accessibility tree, the
//! queries over it, and the tree-update protocol that keeps it current.
//!
//! **What this namespace is.** `accesskit_consumer` holds a `Tree` whose
//! `TreeState` an `ActionRequest` handler mutates in place, and answers queries
//! against that state: what a node's label is, where it sits, which text run a
//! character index falls in. This namespace re-implements all of it in Zig,
//! module by module and function by function, with no Rust and no wrapper.
//!
//! **How it is layered.** Four groups, and the order is a constraint rather
//! than a preference. `iterators/` sits lowest and knows nothing about nodes
//! beyond an identifier. `tree_index.zig`, `tree_state.zig` and `node_id.zig`
//! sit above it and own the storage. `node_ref/` and `text/` sit above those and
//! answer queries. `tree.zig`, `tree_apply.zig`, `tree_grafts.zig` and
//! `tree_validate.zig` sit at the top and own the update protocol.
//!
//! **Why this namespace sits below the package root rather than in it.** A
//! consumer names these types in a signature next to the schema types, and the
//! schema types are already one namespace down for the same reason; flattening
//! both would produce a root with five hundred names in it.
//!
//! **What is not here.** No runtime, no clock, no environment and no socket.
//! Every operation that can block takes `io: std.Io`; none of these do, so none
//! of them can. `docs/36-consumer-call-graph.md` records the import table and
//! the owner of every symbol, `docs/33-consumer-interface-contract.md` records
//! the interface this namespace was written against, and
//! `docs/10-accesskit-core.md` is the upstream surface being ported.

const std = @import("std");

// Every module in this namespace is imported at file scope, and the namespace
// blocks below bind each import to the name a caller writes. Both halves are
// needed: a caller writes `consumer.text.range`, and
// `docs/36-consumer-call-graph.md` records the import table of this namespace.

// --- iterators/ ------------------------------------------------------------
// The lowest layer. Each cursor answers "which nodes come next", bounded by a
// step count derived in its own module doc, so a cyclic tree stops with a tag.

const iterators_children = @import("iterators/children.zig");
const iterators_following = @import("iterators/following.zig");
const iterators_preceding = @import("iterators/preceding.zig");
const iterators_sibling_scan = @import("iterators/sibling_scan.zig");

/// The iterators over children and siblings, both filtered and unfiltered.
pub const iterators = struct {
    /// Child identifiers, children, and the filtered child cursors.
    pub const children = iterators_children;
    /// Forward sibling cursors, and the shape a filtered cursor is declared in.
    pub const following = iterators_following;
    /// Backward sibling cursors.
    pub const preceding = iterators_preceding;
    /// The single step both sibling directions share.
    pub const sibling_scan = iterators_sibling_scan;
};

// --- storage ---------------------------------------------------------------
// What the iterators walk. `node_id.zig` owns the struct bodies, so it is the
// only file in this namespace that may declare a method.

/// The identifier types, and the struct bodies a consumer passes by value.
pub const node_id = @import("node_id.zig");
/// The index from an identifier to the node's position in the store.
pub const tree_index = @import("tree_index.zig");
/// The node store: the nodes, their fields, their roles and their relations.
pub const tree_state = @import("tree_state.zig");
/// The whole-tree consistency check over a state.
pub const tree_validate = @import("tree_validate.zig");

// --- update protocol -------------------------------------------------------

/// The materialized tree, and the queries that drive its creation.
pub const tree = @import("tree.zig");
/// Applying a `TreeUpdate` to a state.
pub const tree_apply = @import("tree_apply.zig");
/// Splicing one tree's nodes into another without disturbing the rest.
pub const tree_grafts = @import("tree_grafts.zig");

// --- queries ---------------------------------------------------------------

/// Whether a node is included, and by how much. Decided once per walk.
pub const filter = @import("filter.zig");

const node_ref_predicates = @import("node_ref/predicates.zig");
const node_ref_geometry = @import("node_ref/geometry.zig");
const node_ref_hierarchy = @import("node_ref/hierarchy.zig");
const node_ref_strings = @import("node_ref/strings.zig");
const node_ref_set_state = @import("node_ref/set_state.zig");
const node_ref_properties = @import("node_ref/properties.zig");
const node_ref_containers = @import("node_ref/containers.zig");

/// The queries over a node: its role, its geometry, its labels, its values.
pub const node_ref = struct {
    /// Role predicates and the predicates that read several nodes.
    pub const predicates = node_ref_predicates;
    /// Position, size, and the geometric transforms between them.
    pub const geometry = node_ref_geometry;
    /// Bounds, hit testing, and the bounding box of a subtree.
    pub const hierarchy = node_ref_hierarchy;
    /// Label, description, URL, placeholder and the value accessors.
    pub const strings = node_ref_strings;
    /// Setting a property, and setting a flag.
    pub const set_state = node_ref_set_state;
    /// Reading a raw or inherited property off a node.
    pub const properties = node_ref_properties;
    /// Item-likeness, container-ness, index paths and selection containers.
    pub const containers = node_ref_containers;
};

const text_position_inner = @import("text/position_inner.zig");
const text_position = @import("text/position.zig");
const text_position_motion = @import("text/position_motion.zig");
const text_line_walk = @import("text/line_walk.zig");
const text_range = @import("text/range.zig");
const text_hit_test = @import("text/hit_test.zig");
const text_inherited = @import("text/inherited.zig");
const text_query = @import("text/query.zig");

/// The text layer: positions, ranges, and the queries that produce them.
pub const text = struct {
    /// The character index inside a run, and the slot searches over a run list.
    pub const position_inner = text_position_inner;
    /// A position in the document, and the predicates that describe one.
    pub const position = text_position;
    /// The movement methods, which are the bulk of the text API.
    pub const position_motion = text_position_motion;
    /// The bounded line walks the movements share.
    pub const line_walk = text_line_walk;
    /// A range over the document, and the property fold over the runs in it.
    pub const range = text_range;
    /// The character index at a point, and the two filters the cursors need.
    pub const hit_test = text_hit_test;
    /// The thirty-nine inherited text accessors, which share one walk.
    pub const inherited = text_inherited;
    /// Selection, focus, and the string-driven entry points.
    pub const query = text_query;
};

test "every module in this namespace is reachable and analysed" {
    // A `pub const` that nothing references is a re-export the compiler may skip
    // entirely, so a green run would report zero tests and prove nothing about
    // the modules underneath. `refAllDecls` over the namespaces forces the
    // whole subtree to be analysed, which is what this test is for.
    std.testing.refAllDecls(iterators);
    std.testing.refAllDecls(node_ref);
    std.testing.refAllDecls(text);
    std.testing.refAllDecls(tree);
    std.testing.refAllDecls(tree_apply);
    std.testing.refAllDecls(tree_grafts);
    std.testing.refAllDecls(tree_validate);
    std.testing.refAllDecls(filter);
    std.testing.refAllDecls(tree_index);
    std.testing.refAllDecls(tree_state);
}
