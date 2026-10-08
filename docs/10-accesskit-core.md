# 10 — AccessKit core: crate map and type surface

Consumed by `docs/30-port-design.md`, which turns this map into module boundaries and
signatures, and by `docs/40-plan.md`, which orders the milestones.

## 0. Reading rules for this document

* All paths are relative to the read-only checkout `/tmp/scratch/accesskit`
  at commit `466e24e252103f4d82bd6fbab98141b551e46e0c`.
* Every claim about upstream code carries `path:line`. Line numbers are from that commit.
* Anything not observed in the source is marked `[INFERENCE]`.
* Counts of enum variants come from a script that lists the variants of one `enum` block and
  ignores doc comments. The script output is quoted where the count matters.
* The Zig side is derived, not measured. The layout rules used are stated in section 1.1
  before any size is computed, and every size must be locked by a `comptime assert` in the
  port. House rule `ozai/AGENTS.md:39-40` requires that assertion.

## 1. Crate and module inventory

### 1.1 Naming and layout rules used throughout

These rules are stated once. Every Zig name and every size later in this document is
derived from them. No Zig name appears without one of these rules.

| Rule | Statement |
|---|---|
| Z1 | A Rust `PascalCase` type keeps its spelling. Zig also uses `PascalCase` for types. |
| Z2 | A Rust `snake_case` function becomes `camelCase`. House rule `ozai/AGENTS.md:45-46`. |
| Z3 | A Rust `SCREAMING_SNAKE_CASE` associated constant becomes a module-level `camelCase` `const` named after the type, because Zig has no associated constants. |
| Z4 | A Rust struct field is already `snake_case` and keeps its spelling. |
| Z5 | A Rust enum variant `PascalCase` becomes a Zig enum field in `snake_case`. The numeric discriminant is copied unchanged, because the C header and the JSON names are built from the Rust name and the Rust order. |
| Z6 | A Rust crate becomes a Zig module file. `accesskit` becomes `accesskit.zig`, `accesskit_consumer` becomes `consumer.zig`. A Rust `mod x` becomes `x.zig`. |
| Z7 | A Rust trait method becomes a Zig struct field of function-pointer type, named by Z2. The struct is named `PascalCase` plus `Handler` or `VTable`, and it carries an explicit context pointer as its first field. |
| Z8 | A Rust `impl Into<T>` parameter becomes the target type `T` directly. `impl Trait` parameters become a concrete type chosen at the call site, never a generic. |

Layout rules, written out so that every size below follows mechanically:

| Rule | Statement |
|---|---|
| L1 | A Zig `struct` field starts at the lowest offset at or after the previous end that is a multiple of `@alignOf(field type)`. The struct alignment is the largest field alignment. The struct size is the end of the last field rounded up to the struct alignment. |
| L2 | A fieldless `enum(T)` is one `T` at offset 0. Its size is `@sizeOf(T)` and its alignment is `@alignOf(T)`. |
| L3 | A tagged union `union(E)` puts the tag `E` at offset 0, then the payload at the lowest offset that is a multiple of the largest payload alignment. The union alignment is `max(@alignOf(E), largest payload alignment)`. The size is the end of the largest payload, rounded up to the union alignment. |
| L4 | `extern struct` uses the C rules of L1, with no reordering. Field order is the declaration order. |
| L5 | `?T` is laid out as a tagged union `union(enum) { null, value: T }`. The payload niche is used only when the compiler proves one. A pointer or a slice proves one, because the null pointer is the tag. A `union(enum)` payload of the shape used in this document does not prove one in Zig 0.16.0, so `?ActionData` pays for a separate tag byte. |
| L6 | `std.array_list.Aligned(T, null)` is `{ items: []T, capacity: usize }`. That is 24 bytes at alignment 8 (`std/array_list.zig:570`). |
| L7 | `std.array_hash_map.Auto(K, V)` is `{ entries: std.MultiArrayList(Data), index_header: ?*IndexHeader, pointer_stability: std.debug.SafetyLock }` (`std/array_hash_map.zig:88-98`). `MultiArrayList` is `{ bytes: [*]u8, len: usize, capacity: usize }` (`std/multi_array_list.zig:26-28`). `SafetyLock` is one byte (`std/debug.zig:1816`). So the map is 24 + 8 + 1 rounded to alignment 8, which is 40 bytes at alignment 8. This map keeps insertion order. |
| L8 | A `packed struct` has the sum of the field sizes and the largest field alignment. It is used only where the byte layout is itself part of the contract, which here means no type at all. |

### 1.2 `accesskit` crate

`accesskit/Cargo.toml:1-29`. Version `0.25.1`. Two source files.

| File | Lines | Public declarations | What it owns |
|---|---|---|---|
| `accesskit/src/lib.rs` | 3698 | 30 public types, 3 public traits, 336 public `Node` methods, 1 `TreeInfo` constructor, 2 re-exported modules | The data schema. Every node property, every action, the tree identity types, and the three handler traits. |
| `accesskit/src/geometry.rs` | 866 | 5 public types, 46 public associated items: 38 public functions plus 8 associated constants. The figure 84 counts every function definition, including the 46 trait impl methods, so it does not match this column. 61 matches no count in the file | The 2D value types `Affine`, `Point`, `Rect`, `Size`, `Vec2` and their arithmetic. |

Line counts come from `wc -l accesskit/src/*.rs`:

```
   866 accesskit/src/geometry.rs
  3698 accesskit/src/lib.rs
```

Public module surface of `lib.rs`:

| Line | Declaration | Kind |
|---|---|---|
| `accesskit/src/lib.rs:32` | `pub use uuid::Uuid;` | re-export |
| `accesskit/src/lib.rs:35` | `pub use geometry::{Affine, Point, Rect, Size, Vec2};` | re-export |
| `accesskit/src/lib.rs:62` | `pub enum Role` | type |
| `accesskit/src/lib.rs:289` | `pub enum Action` | type |
| `accesskit/src/lib.rs:417` | `pub enum Orientation` | type |
| `accesskit/src/lib.rs:439` | `pub enum TextDirection` | type |
| `accesskit/src/lib.rs:465` | `pub enum Invalid` | type |
| `accesskit/src/lib.rs:486` | `pub enum Toggled` | type |
| `accesskit/src/lib.rs:517` | `pub enum SortDirection` | type |
| `accesskit/src/lib.rs:538` | `pub enum AriaCurrent` | type |
| `accesskit/src/lib.rs:563` | `pub enum AutoComplete` | type |
| `accesskit/src/lib.rs:584` | `pub enum Live` | type |
| `accesskit/src/lib.rs:605` | `pub enum HasPopup` | type |
| `accesskit/src/lib.rs:628` | `pub enum ListStyle` | type |
| `accesskit/src/lib.rs:653` | `pub enum TextAlign` | type |
| `accesskit/src/lib.rs:675` | `pub enum VerticalOffset` | type |
| `accesskit/src/lib.rs:695` | `pub enum TextDecorationStyle` | type |
| `accesskit/src/lib.rs:703` | `pub type NodeIdContent = u64` | type |
| `accesskit/src/lib.rs:715` | `pub struct NodeId` | type |
| `accesskit/src/lib.rs:745` | `pub struct TreeId` | type |
| `accesskit/src/lib.rs:761` | `pub struct CustomAction` | type |
| `accesskit/src/lib.rs:771` | `pub struct TextPosition` | type |
| `accesskit/src/lib.rs:784` | `pub struct TextSelection` | type |
| `accesskit/src/lib.rs:834` | `pub struct Color` | type |
| `accesskit/src/lib.rs:847` | `pub struct TextDecoration` | type |
| `accesskit/src/lib.rs:1107` | `pub struct Node` | type |
| `accesskit/src/lib.rs:3169` | `pub struct TreeInfo` | type |
| `accesskit/src/lib.rs:3179` | `pub type Tree = TreeInfo` | deprecated type alias |
| `accesskit/src/lib.rs:3208` | `pub struct TreeUpdate` | type |
| `accesskit/src/lib.rs:3271` | `pub enum ScrollUnit` | type |
| `accesskit/src/lib.rs:3291` | `pub enum ScrollHint` | type |
| `accesskit/src/lib.rs:3305` | `pub enum ActionData` | type |
| `accesskit/src/lib.rs:3328` | `pub struct ActionRequest` | type |
| `accesskit/src/lib.rs:3336` | `pub trait ActivationHandler` | trait |
| `accesskit/src/lib.rs:3362` | `pub trait ActionHandler` | trait |
| `accesskit/src/lib.rs:3376` | `pub trait DeactivationHandler` | trait |

Private types that the port must also carry, because they are the storage of `Node`:

| Line | Declaration | Role |
|---|---|---|
| `accesskit/src/lib.rs:801` | `enum Flag` | 18 bit positions inside `Node.flags` |
| `accesskit/src/lib.rs:856` | `enum PropertyValue` | the tagged union stored in `Properties.values` |
| `accesskit/src/lib.rs:893` | `enum PropertyId` | 87 real property identifiers plus `Unset` |
| `accesskit/src/lib.rs:1062` | `struct PropertyIndices` | `[u8; 87]`, maps a property identifier to a slot index |
| `accesskit/src/lib.rs:1071` | `struct Properties` | `{ indices: PropertyIndices, values: Vec<PropertyValue> }` |

### 1.3 `accesskit_consumer` crate

`accesskit_consumer/Cargo.toml:1-16`. Version `0.39.1`. It depends on `hashbrown` 0.17.1
(`accesskit_consumer/Cargo.toml:16`).

| File | Lines | Public declarations | What it owns |
|---|---|---|---|
| `accesskit_consumer/src/lib.rs` | 210 | 11 re-exports, 5 private module declarations | The module root. It re-exports `Tree`, `TreeState`, `ChangeHandler`, `FullNodeId`, `NodeRef`, `FilterResult`, `common_filter`, `common_filter_with_root_exception`, `Position`, `Range`, `RangePropertyValue`, `WeakRange`. |
| `accesskit_consumer/src/tree.rs` | 3224 | `TreeState` (13 public methods), `ChangeHandler` (4 methods), `Tree` (4 public methods, 1 private) | The stored tree and the update application algorithm. |
| `accesskit_consumer/src/node.rs` | 2120 | `FullNodeId` (3 methods), `NodeRef` (78 public methods) | The borrowed node view, the label and value resolution, the property filters, and hit testing. |
| `accesskit_consumer/src/text.rs` | 2836 | `Position` (34 methods), `Range` (12 methods), `WeakRange` (5 methods), `RangePropertyValue` (1 method) | Text positions, ranges, and the line, word, paragraph and format boundary search. |
| `accesskit_consumer/src/iterators.rs` | 1060 | 5 iterator types | Child, sibling and filtered sibling iterators. |
| `accesskit_consumer/src/filters.rs` | 421 | `FilterResult`, `common_filter`, `common_filter_with_root_exception` | The tree filter that decides which nodes reach the platform. |

Line counts come from `wc -l accesskit_consumer/src/*.rs`:

```
   421 accesskit_consumer/src/filters.rs
  1060 accesskit_consumer/src/iterators.rs
   210 accesskit_consumer/src/lib.rs
  2120 accesskit_consumer/src/node.rs
  2836 accesskit_consumer/src/text.rs
  3224 accesskit_consumer/src/tree.rs
```

### 1.4 `example_common` crate

`example_common/src/lib.rs:1-265`, `example_common/src/key.rs:24`, `example_common/src/render.rs:76`.
This crate is a reference application. The port does not ship it as a library. It is the
smallest complete example of the update protocol and of `ActionRequest` handling, so the
port uses it as the shape of its own test harness.

```
   24 example_common/src/key.rs
  265 example_common/src/lib.rs
   76 example_common/src/render.rs
```

### 1.5 Method counts in `accesskit/src/lib.rs`

`grep -n "^\s*pub fn " accesskit/src/lib.rs` returns 24 lines. Eleven of them are macro
templates inside `macro_rules!` bodies. Thirteen are literal functions: `Node::new`,
`Node::role`, `Node::set_role`, the nine action methods, and `TreeInfo::new`.

The macro families generate the rest. Counting the entries of each family invocation gives
the following. The `entries` column comes from a script that lists the `PascalCase`
identifiers in each `macro_rules!` invocation block.

| Family | Invocation at | Entries | Methods per entry | Methods |
|---|---|---|---|---|
| `flag_methods!` | `accesskit/src/lib.rs:1909` | 18 | 3 | 54 |
| `node_id_vec_property_methods!` | `accesskit/src/lib.rs:2025` | 8 | 4 | 32 |
| `node_id_property_methods!` | `accesskit/src/lib.rs:2069` | 7 | 3 | 21 |
| `string_property_methods!` | `accesskit/src/lib.rs:2097` | 21 | 3 | 63 |
| `f64_property_methods!` | `accesskit/src/lib.rs:2207` | 11 | 3 | 33 |
| `f32_property_methods!` | `accesskit/src/lib.rs:2243` | 2 | 3 | 6 |
| `usize_property_methods!` | `accesskit/src/lib.rs:2251` | 9 | 3 | 27 |
| `color_property_methods!` | `accesskit/src/lib.rs:2316` | 3 | 3 | 9 |
| `text_decoration_property_methods!` | `accesskit/src/lib.rs:2325` | 3 | 3 | 9 |
| `length_vec_property_methods!` | `accesskit/src/lib.rs:2334` | 2 | 3 | 6 |
| `coord_vec_property_methods!` | `accesskit/src/lib.rs:2387` | 2 | 3 | 6 |
| `bool_property_methods!` | `accesskit/src/lib.rs:2427` | 2 | 3 | 6 |
| `unique_enum_property_methods!` | `accesskit/src/lib.rs:2452` | 12 | 3 | 36 |
| `property_methods!` | `accesskit/src/lib.rs:2508` | 4 | 3 | 12 |
| `vec_property_methods!` | `accesskit/src/lib.rs:2679` | 1 | 4 | 4 |

The property families total 270 methods over 87 properties. Each property contributes a
getter, a setter and a clearer. The 9 list-valued properties add a pusher. The `flag_methods!`
family is separate: 18 boolean flags, each with `is_x`, `set_x` and `clear_x`.

Total public methods on `Node`: 270 property methods + 54 flag methods + 12 literal methods
is 336.

The 87 properties are the sum of the family entries over the property families only:
8 + 7 + 21 + 11 + 2 + 9 + 3 + 3 + 2 + 2 + 2 + 12 + 5 = 87. The last group of 5 is
`property_methods!` and `vec_property_methods!` covering `Transform`, `Bounds`,
`TextSelection`, `CustomActions` and `TreeId`.

### 1.6 Upstream dependencies of the two core crates

| Crate | Line | Purpose in the port |
|---|---|---|
| `enumn` 0.1.6 | `accesskit/Cargo.toml:18` | Optional. It generates `Action::n`, the integer-to-variant mapping. It is off by default. `Action::n` is hand-written when the feature is off (`accesskit/src/lib.rs:357-387`). The port writes the comptime table instead. |
| `pyo3` 0.29 | `accesskit/Cargo.toml:19` | Optional Python bindings. Not ported. The `#[cfg_attr(feature = "pyo3", ...)]` blocks are deleted. |
| `schemars` 1 | `accesskit/Cargo.toml:20` | Optional JSON Schema output for `Properties` (`accesskit/src/lib.rs:3036-3160`). Not ported unless a JSON schema artifact is required. See open question Q7. |
| `serde` 1.0 | `accesskit/Cargo.toml:21` | Optional. Drives `Serialize` and `Deserialize` for `Properties` (`accesskit/src/lib.rs:2821-3016`). Not ported unless a wire format is required. See open question Q7. |
| `serde_json` 1.0 | `accesskit/Cargo.toml:22` | Only used with `schemars`. Not ported. |
| `uuid` 1.18.1 | `accesskit/Cargo.toml:23` | Required. `TreeId` wraps `Uuid` (`accesskit/src/lib.rs:745`). See section 1.7. |
| `hashbrown` 0.17.1 | `accesskit_consumer/Cargo.toml:16` | Required. All four maps in `TreeState` and all three sets in `InternalChanges`. Replaced by `std.array_hash_map.Auto`, which also fixes iteration order. |

### 1.7 The `uuid` replacement

`TreeId` is `#[repr(transparent)] pub struct TreeId(pub Uuid)` (`accesskit/src/lib.rs:745`).
The `uuid` crate is a hard dependency (`accesskit/Cargo.toml:23`), and the lock file pins
version 1.18.1. `TreeId::ROOT` is `Uuid::nil()` (`accesskit/src/lib.rs:749`).

Zig 0.16.0 standard library has no UUID type. A search of
`/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ/lib/std`
for `Uuid` and `uuid` returns only unrelated hits: the Mach-O `LC_UUID` load command
(`std/macho.zig:67`), the GNU build id enum (`std/zig.zig:252`), and the target architecture
name filter (`std/zig/target.zig:340`). So rung 1 of the dependency ladder, the standard
library, does not cover this.

Rung 2 is a pinned Zig package. A search of the Zig package registry at
`https://zigpkg.dev/search?q=uuid` on 2026-10-04 returned 12 packages. The candidates that
match the two features the port needs, a v4 generator and the nil value, are:

| Package | Registry entry | Stated feature | Note |
|---|---|---|---|
| `alexrios/uuid` | `zigpkg.dev/packages/alexrios/uuid` version 2.0.0 | RFC 9562 UUIDs, zero allocations, all versions | The strongest match on the registry description. Zig 0.16 compatibility is unverified. |
| `dmgk/zig-uuid` | `zigpkg.dev/packages/dmgk/zig-uuid` | allocation-free v4 UUIDs | Registry entry says "Updated 2 years ago". |
| `r4gus/uuid-zig` | `zigpkg.dev/packages/r4gus/uuid-zig` version 0.6.0 | A UUID library written in Zig | Mirrored to Codeberg. |

The smallest honest version written from scratch is small enough to prefer it. The port
needs 16 bytes of storage, one nil value, and one function that writes 16 random bytes with
the RFC 9562 version 4 and variant bits set. That is `Uuid` plus `Uuid.random(io)`. Section 10
records this as a decision for the integration owner. `std.Io.random` and
`std.Io.randomSecure` exist (`std/Io.zig:2468`, `std/Io.zig:2485`), so the randomness comes
from the threaded `io` and never from a global.

## 2. The type surface, type by type

Each type below gives the Rust source, the fields with types, the invariants the upstream
code maintains, and the Zig counterpart with its fields, its alignment, and its size in
bytes computed from rules L1 to L8. Every size is a `[INFERENCE]` until a `comptime assert`
in the port confirms it.

### 2.1 Identity types

#### `NodeIdContent`

```rust
accesskit/src/lib.rs:703
pub type NodeIdContent = u64;
```

It is an alias, not a new type. Zig keeps it as a named alias for readability:
`pub const NodeIdContent = u64;`. Size 8, alignment 8.

#### `NodeId`

```rust
accesskit/src/lib.rs:703-735
pub type NodeIdContent = u64;

/// The stable identity of a [`Node`], unique within the node's tree.
///
/// Each tree (root or subtree) has its own independent ID space. The same
/// `NodeId` value can exist in different trees without conflict. When working
/// with multiple trees, the combination of `NodeId` and [`TreeId`] uniquely
/// identifies a node.
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct NodeId(pub NodeIdContent);
```

| Field | Type |
|---|---|
| `.0` | `u64` |

Invariants the code maintains:

* The value is stable for the lifetime of a node. `NodeRef::id` is compared by value
  everywhere (`accesskit_consumer/src/node.rs:397-399`).
* The value has meaning only inside one tree. `accesskit/src/lib.rs:707-710` states this,
  and `accesskit_consumer/src/tree.rs:126` enforces it by pairing every local id with a
  `TreeIndex`.
* The value may be zero. The upstream test tree uses `NodeId(0)` as its root
  (`accesskit_consumer/src/lib.rs:40`). An earlier design used a non-zero sentinel.
  Commit `3eadd48` switched to a plain unsigned 64-bit integer.
* The `Debug` form is `#` followed by the decimal value
  (`accesskit/src/lib.rs:731-735`).

Zig counterpart:

```zig
pub const NodeId = struct {
    value: u64,
};
```

Field name by rule Z4. Size 8, alignment 8, from L1 with one `u64` field. `repr(transparent)`
in Rust carries no meaning for a single-field struct, so no `packed struct` is used, per
L8.

#### `TreeId`

```rust
accesskit/src/lib.rs:737-750
/// The stable identity of a tree.
///
/// Use [`TreeId::ROOT`] for the main/root tree. For subtrees, use a random
/// UUID (version 4) to avoid collisions between independently created trees.
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(transparent)]
pub struct TreeId(pub Uuid);

impl TreeId {
    /// A reserved tree ID for the root tree. This uses a nil UUID.
    pub const ROOT: Self = Self(Uuid::nil());
}
```

| Field | Type |
|---|---|
| `.0` | `Uuid`, 16 bytes |

Invariants the code maintains:

* `TreeId::ROOT` is the nil UUID, all 16 bytes zero (`accesskit/src/lib.rs:749`).
* Every other tree id is a random version 4 UUID (`accesskit/src/lib.rs:739-740`).
* A tree id is ordered and hashable, because it is a map key in three places:
  `accesskit_consumer/src/tree.rs:19-20`, `:73`, and `:73` again for
  `graft_parents`.
* The root tree can never be a graft target. `record_graft` panics on it
  (`accesskit_consumer/src/tree.rs:187-189`).

Zig counterpart:

```zig
pub const TreeId = struct {
    bytes: [16]u8,
};

pub const treeIdRoot: TreeId = .{ .bytes = @splat(0) };
```

Field name by rule Z4 from `cbindgen`'s `bytes` name, which
`accesskit-c/include/accesskit.h:707-709` fixes as `uint8_t bytes[16]` in big-endian byte
order. Size 16, alignment 1, from L1 with one `[16]u8` field. The constant is named by rule
Z3, so it cannot collide with the `rectZero` and `sizeZero` constants that also stand at the
origin. `splat` on a 16-element array requires Zig 0.16. The fallback is
`@memset(&result.bytes, 0)`.

#### `FullNodeId`

```rust
accesskit_consumer/src/node.rs:29-52
#[derive(Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Hash, Debug)]
pub struct FullNodeId(TreeIndex, NodeId);

impl FullNodeId {
    pub(crate) fn new(local_id: NodeId, tree_index: TreeIndex) -> Self {
        Self(tree_index, local_id)
    }

    pub(crate) fn with_same_tree(&self, local_id: NodeId) -> Self {
        Self(self.0, local_id)
    }

    pub(crate) fn to_components(self) -> (NodeId, TreeIndex) {
        (self.1, self.0)
    }
}

impl From<FullNodeId> for u128 {
    fn from(id: FullNodeId) -> Self {
        let tree_index = id.0.0 as u128;
        let local_id = id.1.0 as u128;
        (local_id << 64) | tree_index
    }
}
```

| Field | Type |
|---|---|
| `.0` | `TreeIndex`, which is `u32` (`accesskit_consumer/src/tree.rs:13-15`) |
| `.1` | `NodeId`, which is `u64` |

Invariants the code maintains:

* The pair is unique across the whole application. This is the key of the main node map
  (`accesskit_consumer/src/tree.rs:68`).
* It is totally ordered, because it is a key of a `BTreeSet`-free hash map plus an
  `Ord` derive, and because `index_path` sorts by document order separately.
* The `u128` conversion packs the node id in the high 64 bits and the tree index in the
  low 64 bits (`accesskit_consumer/src/node.rs:48-50`). Any port that keeps this
  conversion must keep that bit order.

Zig counterpart:

```zig
pub const TreeIndex = enum(u32) { _ };

pub const FullNodeId = extern struct {
    tree_index: TreeIndex,
    node_id: NodeId,
};
```

Field names by rule Z4, derived from `TreeIndex` and `NodeId`. `TreeIndex` becomes a
non-exhaustive integer enum so that `@sizeOf(TreeIndex) == 4`. Size of `FullNodeId`: 16,
alignment 8, from L4, because `extern struct` needs no padding beyond the four bytes of
padding after `tree_index`. A plain `struct` gives the same numbers under L1. The port must
add `comptime assert(@sizeOf(FullNodeId) == 16);` because the padding depends on L1 and L4
agreeing.

### 2.2 Node identity and payload

#### `Node`

```rust
accesskit/src/lib.rs:1096-1113
/// A single accessible object. A complete UI is represented as a tree of these.
///
/// For brevity, and to make more of the documentation usable in bindings
/// to other languages, documentation of getter methods is written as if
/// documenting fields in a struct, and such methods are referred to
/// as properties.
#[derive(Default, PartialEq)]
pub struct Node {
    role: Role,
    actions: u32,
    child_actions: u32,
    flags: u32,
    properties: Properties,
}
```

| Rust source line | Field | Type | Meaning |
|---|---|---|---|
| `accesskit/src/lib.rs:1108` | `role` | `Role` | How a platform API interprets the node |
| `accesskit/src/lib.rs:1109` | `actions` | `u32` | Bit set of `Action` this node accepts, one bit per variant |
| `accesskit/src/lib.rs:1110` | `child_actions` | `u32` | Bit set of `Action` the direct children accept |
| `accesskit/src/lib.rs:1111` | `flags` | `u32` | Bit set of `Flag`, one bit per variant |
| `accesskit/src/lib.rs:1112` | `properties` | `Properties` | A slot vector plus an index array |

Invariants the code maintains:

* Every field is private. All access goes through the 336 generated methods.
* `role` has no unset value in the stored form. `Node::new` sets it
  (`accesskit/src/lib.rs:1826-1834`). `#[derive(Default)]` on `Node` exists only so that
  `..Default::default()` can supply the other four fields.
* `actions` and `child_actions` hold only bits defined by `Action`. `Action` has 22
  variants with indices 0 through 21, so all 22 bits fit in a `u32`
  (`accesskit/src/lib.rs:352-355`).
* `flags` holds only bits defined by `Flag`. `Flag` has 18 variants with indices 0 through
  17, so 18 bits fit in a `u32` (`accesskit/src/lib.rs:822-825`).
* `PartialEq` on `Node` is order independent for properties. This is deliberate: commit
  `05ea5c5` replaced the derived `PartialEq` on `Properties` with a hand-written one that
  compares by property id, so two nodes with the same properties compare equal whatever
  order they were set in (`accesskit/src/lib.rs:1084-1094`).
* A cleared property equals a property that was never set
  (`accesskit/src/lib.rs:1084-1094`, tested at `accesskit/src/lib.rs:3407-3414`).
* `Clone` reuses the destination string and slice buffers. This is the 0.25.0 change.
  See section 5.5.

Zig counterpart:

```zig
pub const Node = struct {
    role: Role = .unknown,
    actions: ActionMask = 0,
    child_actions: ActionMask = 0,
    flags: FlagMask = 0,
    properties: Properties = .empty,
};
```

Field names by rule Z4. `ActionMask` and `FlagMask` are aliases named by rule Z1 for the
two `u32` masks, so a reader cannot mix them up. Both are `u32`.

Size 40, alignment 4, from L1: `role` at offset 0, then `actions` at 4, `child_actions` at
8, `flags` at 12, then `properties` at 16 with size 24. `Properties` is an
`extern struct` of `indices: [87]u8` and `values: []PropertyValue`, so its alignment is 1
and its size is 24 under L4. The port must add
`comptime assert(@sizeOf(Node) == 40); comptime assert(@alignOf(Node) == 4);`.

#### `Properties`

```rust
accesskit/src/lib.rs:1070-1074, 1115-1168
#[derive(Debug, Default)]
struct Properties {
    indices: PropertyIndices,
    values: Vec<PropertyValue>,
}

impl PropertyIndices {
    fn get<'a>(&self, values: &'a [PropertyValue], id: PropertyId) -> &'a PropertyValue {
        value_at(values, self.0[id as usize])
    }
}

impl Properties {
    fn get_mut(&mut self, id: PropertyId, default: PropertyValue) -> &mut PropertyValue {
        let index = self.indices.0[id as usize] as usize;
        if index == PropertyId::Unset as usize {
            self.values.push(default);
            let index = self.values.len() - 1;
            self.indices.0[id as usize] = index as u8;
            &mut self.values[index]
        } else {
            let value = &mut self.values[index];
            if matches!(value, PropertyValue::None) {
                *value = default;
            }
            value
        }
    }

    fn set(&mut self, id: PropertyId, value: PropertyValue) {
        let index = self.indices.0[id as usize];
        if index == PropertyId::Unset as u8 {
            self.values.push(value);
            self.indices.0[id as usize] = (self.values.len() - 1) as u8;
        } else {
            self.values[index as usize] = value;
        }
    }

    fn clear(&mut self, id: PropertyId) {
        let index = self.indices.0[id as usize];
        if index != PropertyId::Unset as u8 {
            self.values[index as usize] = PropertyValue::None;
        }
    }
}
```

| Field | Type |
|---|---|
| `indices` | `PropertyIndices`, which is `[u8; 87]` (`accesskit/src/lib.rs:1060-1062`) |
| `values` | `Vec<PropertyValue>` |

Invariants the code maintains:

* `indices[id]` is `PropertyId::Unset`, which has the value 87, when the property was
  never set or was cleared. Otherwise `indices[id]` is a valid index into `values`
  (`accesskit/src/lib.rs:1122-1153`).
* `indices` and `values` are never shrunk. A cleared slot holds `PropertyValue::None`
  (`accesskit/src/lib.rs:1151`). This is what lets `get_mut` reuse the slot.
* `values.len()` is at most 87, so a slot index fits in a `u8`. The index array has 87
  entries because `PropertyId::Unset` is the 88th variant, so its value is 87
  (`accesskit/src/lib.rs:1008`, `accesskit/src/lib.rs:1062`).
* The slots are not sorted. Slot order is first-write order. Equality does not depend on
  it (`accesskit/src/lib.rs:1084-1094`).

Zig counterpart:

```zig
pub const property_id_count = 87;
pub const PropertyIndices = [property_id_count]u8;

pub const Properties = struct {
    indices: PropertyIndices = @splat(property_id_unset),
    values: std.ArrayList(PropertyValue) = .empty,
};
```

Field names by rule Z4. `@splat` needs Zig 0.16. The fallback is an explicit loop.
`PropertyValue` is a tagged union under rule L3, and its size is 48 with alignment 8, so
`std.ArrayList(PropertyValue)` is 24 bytes under L6 and `Properties` is 24 bytes with
alignment 8. `comptime assert(@sizeOf(Properties) == 24); comptime assert(@alignOf(Properties) == 8);`.

The port must also carry `deinit`. Rust frees in `Drop`. Zig has no `Drop`, so
`Properties.deinit(gpa)` and `Node.deinit(gpa)` must be called by every owner.

#### `PropertyValue`

```rust
accesskit/src/lib.rs:855-886
// The following is based on the technique described here:
// https://viruta.org/reducing-memory-consumption-in-librsvg-2.html

#[derive(Debug, PartialEq)]
enum PropertyValue {
    None,
    NodeIdVec(Vec<NodeId>),
    NodeId(NodeId),
    String(String),
    F64(f64),
    F32(f32),
    Usize(usize),
    Color(Color),
    TextDecoration(TextDecoration),
    LengthVec(Vec<u8>),
    CoordVec(Vec<f32>),
    Bool(bool),
    Invalid(Invalid),
    Toggled(Toggled),
    Live(Live),
    TextDirection(TextDirection),
    Orientation(Orientation),
    SortDirection(SortDirection),
    AriaCurrent(AriaCurrent),
    AutoComplete(AutoComplete),
    HasPopup(HasPopup),
    ListStyle(ListStyle),
    TextAlign(TextAlign),
    VerticalOffset(VerticalOffset),
    Affine(Box<Affine>),
    Rect(Rect),
    TextSelection(Box<TextSelection>),
    CustomActionVec(Vec<CustomAction>),
    TreeId(TreeId),
}
```

28 variants. Invariants:

* Each variant matches exactly one of the 87 property ids. The mapping is written out
  three times in the source: the `PropertyId` block comments
  (`accesskit/src/lib.rs:894-1005`), the deserializer (`accesskit/src/lib.rs:2891-3001`),
  and the schemars output (`accesskit/src/lib.rs:3044-3153`).
* `None` means cleared. It is the value a getter sees for an absent property, through
  `value_at` (`accesskit/src/lib.rs:1076-1082`).
* `Affine` and `TextSelection` are boxed in Rust to keep the union small. The port does
  not need the box, because Zig unions are laid out by rule L3 anyway. See section 9.1.

Zig counterpart:

```zig
pub const PropertyValue = union(enum) {
    none,
    node_id_vec: std.ArrayList(NodeId),
    node_id: NodeId,
    string: std.ArrayList(u8),
    f64_: f64,
    f32_: f32,
    usize_: usize,
    color: Color,
    text_decoration: TextDecoration,
    length_vec: std.ArrayList(u8),
    coord_vec: std.ArrayList(f32),
    bool_: bool,
    invalid: Invalid,
    toggled: Toggled,
    live: Live,
    text_direction: TextDirection,
    orientation: Orientation,
    sort_direction: SortDirection,
    aria_current: AriaCurrent,
    auto_complete: AutoComplete,
    has_popup: HasPopup,
    list_style: ListStyle,
    text_align: TextAlign,
    vertical_offset: VerticalOffset,
    affine: Affine,
    rect: Rect,
    text_selection: TextSelection,
    custom_action_vec: std.ArrayList(CustomAction),
    tree_id: TreeId,
};
```

Field names by rule Z5, with three exceptions forced by Zig syntax. `F64` becomes `f64_`,
`F32` becomes `f32_`, and `Bool` becomes `bool_`, because each collides with the Zig
primitive keyword. `None` becomes `none`, which is not a keyword.

Size 40, alignment 8, from L3. The tag is a 28-value `enum(u8)` at offset 0 with size 1.
The largest payload alignment is 8, from `NodeId`, `f64`, `usize`, `Rect`, and `Affine`,
so the payload starts at offset 8. The largest payload is `Rect` at 32 bytes, and
`TextSelection` is also 32 bytes, so the union ends at 40, which is already a multiple of 8.
`[INFERENCE]` The port must add `comptime assert(@sizeOf(PropertyValue) == 40);`

#### `PropertyId`

```rust
accesskit/src/lib.rs:888-1009
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
enum PropertyId {
    Children,
    // ... 86 more identifiers ...
    TreeId,

    // This MUST be last.
    Unset,
}
```

87 real identifiers plus `Unset`, whose discriminant is 87. `PropertyId` is private in
upstream. The port keeps it private to the `accesskit` module, because the consumer crate
reaches properties through the generated getters.

Zig counterpart: `pub const PropertyId = enum(u8) { children, ..., tree_id, _ };`
with field names by rule Z5 and a trailing `_` field for `Unset`, because Zig allows a
non-exhaustive enum to have an unnamed last field. Size 1, alignment 1, from L2.

#### `Flag`

```rust
accesskit/src/lib.rs:796-826
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
enum Flag {
    Hidden,
    Multiselectable,
    Required,
    Visited,
    Busy,
    LiveAtomic,
    Modal,
    TouchTransparent,
    ReadOnly,
    Disabled,
    Italic,
    ClipsChildren,
    IsLineBreakingObject,
    IsPageBreakingObject,
    IsSpellingError,
    IsGrammarError,
    IsSearchMatch,
    IsSuggestion,
}

impl Flag {
    fn mask(self) -> u32 {
        1 << (self as u8)
    }
}
```

18 variants, private. Zig counterpart: `pub const Flag = enum(u8) { hidden, multiselectable,
 required, visited, busy, live_atomic, modal, touch_transparent, read_only, disabled,
 italic, clips_children, is_line_breaking_object, is_page_breaking_object, is_spelling_error,
is_grammar_error, is_search_match, is_suggestion };`. Size 1, alignment 1, from L2.


#### `Role`

```rust
accesskit/src/lib.rs:47-62
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Role {
    #[default]
    Unknown,
    TextRun,
    // ... 180 more variants, ending with Terminal at accesskit/src/lib.rs:270
}
```

182 variants. The variant list is ordered by expected usage frequency, not alphabetically,
because the serialisation formats use variable-length integers for the enum value
(`accesskit/src/lib.rs:42-46`).

Invariants:

* `Unknown` is the default and has discriminant 0 (`accesskit/src/lib.rs:63-64`).
* The order is part of the wire contract. Any reordering breaks every serialised tree.
* The list is ordered by frequency, and frequency is a guess. The port must not re-sort.

Zig counterpart: `pub const Role = enum(u8) { unknown = 0, text_run = 1, ..., terminal = 181 };`
with explicit discriminants so the comptime check can assert the last value is 181. Size 1,
alignment 1, from L2. Explicit `= n` values are required because Zig would otherwise assign
them in declaration order, which would also match, but the explicit form lets
`comptime assert(@intFromEnum(Role.terminal) == 181);` state the contract.

#### `Action`

```rust
accesskit/src/lib.rs:274-350
#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]
#[repr(u8)]
pub enum Action {
    /// Do the equivalent of a single click or tap.
    Click,
    Focus,
    Blur,
    // ... through ShowContextMenu
}

impl Action {
    fn mask(self) -> u32 {
        1 << (self as u8)
    }

    #[cfg(not(feature = "enumn"))]
    fn n(value: u8) -> Option<Self> {
        // Manually implement something similar to the enumn crate. We don't
        // want to bring this crate by default though and we can't use a
        // macro as it would break C bindings header file generation.
        match value {
            0 => Some(Action::Click),
            // ... through 21 => Some(Action::ShowContextMenu),
            _ => None,
        }
    }
}
```

22 variants, discriminant 0 through 21, confirmed by the test at
`accesskit/src/lib.rs:3482-3509`, which asserts `Action::n(22)` is `None`. The comment at
`accesskit/src/lib.rs:361` gives a second reason the port must not use a macro: a Rust
macro cannot be read by `cbindgen`, so the match is hand-written.

Zig counterpart: `pub const Action = enum(u8) { click = 0, focus = 1, blur = 2, collapse = 3,
 expand = 4, custom_action = 5, decrement = 6, increment = 7, hide_tooltip = 8,
 show_tooltip = 9, replace_selected_text = 10, scroll_down = 11, scroll_left = 12,
 scroll_right = 13, scroll_up = 14, scroll_into_view = 15, scroll_to_point = 16,
 set_scroll_offset = 17, set_text_selection = 18,
 set_sequential_focus_navigation_starting_point = 19, set_value = 20,
show_context_menu = 21 };`. Size 1, alignment 1, from L2.


`Action::n` becomes `pub fn actionFromInt(value: u8) ?Action` by rule Z2, implemented as a
`switch` over the 22 known values with `else => null`. No macro, no allocation.

#### Small property enums

Each of these is a `#[repr(u8)] pub enum` with the listed variants, a `serde` camelCase
rename, and a `pyo3` `SCREAMING_SNAKE_CASE` rename. The port keeps only the tag and the
variant list. The Zig type name is identical by rule Z1. Each Zig type is an `enum(u8)`,
so each has size 1 and alignment 1 by rule L2. Field names follow rule Z5.

| Rust type | Line | Variants | Zig type | Zig fields |
|---|---|---|---|---|
| `Orientation` | `accesskit/src/lib.rs:417` | 2 | `Orientation` | `horizontal`, `vertical` |
| `TextDirection` | `accesskit/src/lib.rs:439` | 4 | `TextDirection` | `left_to_right`, `right_to_left`, `top_to_bottom`, `bottom_to_top` |
| `Invalid` | `accesskit/src/lib.rs:465` | 3 | `Invalid` | `true_`, `grammar`, `spelling` |
| `Toggled` | `accesskit/src/lib.rs:486` | 3 | `Toggled` | `false_`, `true_`, `mixed` |
| `SortDirection` | `accesskit/src/lib.rs:517` | 3 | `SortDirection` | `ascending`, `descending`, `other` |
| `AriaCurrent` | `accesskit/src/lib.rs:538` | 7 | `AriaCurrent` | `false_`, `true_`, `page`, `step`, `location`, `date`, `time` |
| `AutoComplete` | `accesskit/src/lib.rs:563` | 3 | `AutoComplete` | `inline`, `list`, `both` |
| `Live` | `accesskit/src/lib.rs:584` | 3 | `Live` | `off`, `polite`, `assertive` |
| `HasPopup` | `accesskit/src/lib.rs:605` | 5 | `HasPopup` | `menu`, `listbox`, `tree`, `grid`, `dialog` |
| `ListStyle` | `accesskit/src/lib.rs:628` | 6 | `ListStyle` | `circle`, `disc`, `image`, `numeric`, `square`, `other` |
| `TextAlign` | `accesskit/src/lib.rs:653` | 4 | `TextAlign` | `left`, `right`, `center`, `justify` |
| `VerticalOffset` | `accesskit/src/lib.rs:675` | 2 | `VerticalOffset` | `subscript`, `superscript` |
| `TextDecorationStyle` | `accesskit/src/lib.rs:695` | 5 | `TextDecorationStyle` | `solid`, `dotted`, `dashed`, `double`, `wavy` |
| `ScrollUnit` | `accesskit/src/lib.rs:3271` | 2 | `ScrollUnit` | `item`, `page` |
| `ScrollHint` | `accesskit/src/lib.rs:3291` | 6 | `ScrollHint` | `top_left`, `bottom_right`, `top_edge`, `bottom_edge`, `left_edge`, `right_edge` |

`Invalid::True` becomes `true_` and `Toggled::False` becomes `false_`, because `true` and
`false` are Zig keywords.

`Toggled` also has `impl From<bool> for Toggled` (`accesskit/src/lib.rs:492-500`), added by
commit `d38776a`. It becomes `pub fn toggledFromBool(value: bool) Toggled` by rule Z2.

### 2.3 Payload structs

#### `CustomAction`

```rust
accesskit/src/lib.rs:752-764
/// Defines a custom action for a UI element.
///
/// For example, a list UI can allow a user to reorder items in the list by dragging the
/// items.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct CustomAction {
    pub id: i32,
    pub description: String,
}
```

| Rust source line | Field | Type | Zig field | Zig type |
|---|---|---|---|---|
| `accesskit/src/lib.rs:762` | `id` | `i32` | `id` | `i32` |
| `accesskit/src/lib.rs:763` | `description` | `String` | `description` | `std.ArrayList(u8)` |

Invariants: none beyond `Eq`, which requires `i32` and the string bytes. `id` is opaque to
the core crate. `description` is human-readable text
(`accesskit/src/lib.rs:754-755`).

Zig counterpart: a plain `struct` with the two fields in source order. Size 32, alignment
8, from L1: `id` at offset 0 with size 4, then `description` at offset 8 with size 24, so
the end is 32.

#### `ActionId`: no such upstream type

The brief asks for `ActionId`. No such type exists in either core crate at this commit. A
search of `accesskit/src/lib.rs` for `ActionId` returns nothing, and
`accesskit_consumer/src` has no such type either. Upstream carries a custom-action
identifier as a bare `i32` in two places: the declaration above, and the request payload:

```rust
accesskit/src/lib.rs:3300-3307
#[repr(C)]
pub enum ActionData {
    CustomAction(i32),
    Value(Box<str>),
```

The doc comment on `Action::CustomAction` ties the two together
(`accesskit/src/lib.rs:299-300`): the request carries an `i32`, and the node declares a
list of `CustomAction` values whose `id` fields the application matches against it. The
core crate never checks that match.

| Option | What it means |
|---|---|
| A | Keep `CustomAction.id: i32` and `ActionData.custom_action: i32`, exactly as upstream. No new surface. |
| B | Introduce `pub const ActionId = i32` as a named alias, by rule Z1. No layout change and no behaviour change, but one name for the concept. |

Recommendation: **B**. Rule `ozai/AGENTS.md:44` asks for one name per thing. The concept
"identifier of an application-defined action" currently has two spellings in the port and
none in upstream. An alias costs nothing and makes the C header readable. This is a
deliberate deviation from upstream, not a port of an upstream type.


#### `TextPosition` and `TextSelection`

```rust
accesskit/src/lib.rs:766-794
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextPosition {
    /// The node's role must be [`Role::TextRun`].
    pub node: NodeId,
    /// The index of an item in [`Node::character_lengths`], or the length
    /// of that slice if the position is at the end of the line.
    pub character_index: usize,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct TextSelection {
    /// The position where the selection started, and which does not change
    /// as the selection is expanded or contracted. If there is no selection
    /// but only a caret, this must be equal to the value of [`TextSelection::focus`].
    /// This is also known as a degenerate selection.
    pub anchor: TextPosition,
    /// The active end of the selection, which changes as the selection
    /// is expanded or contracted, or the position of the caret if there is
    /// no selection.
    pub focus: TextPosition,
}
```

| Rust source line | Type | Field | Rust type | Zig field | Zig type |
|---|---|---|---|---|---|
| `accesskit/src/lib.rs:773` | `TextPosition` | `node` | `NodeId` | `node_id` | `NodeId` |
| `accesskit/src/lib.rs:776` | `TextPosition` | `character_index` | `usize` | `character_index` | `usize` |
| `accesskit/src/lib.rs:789` | `TextSelection` | `anchor` | `TextPosition` | `anchor` | `TextPosition` |
| `accesskit/src/lib.rs:793` | `TextSelection` | `focus` | `TextPosition` | `focus` | `TextPosition` |

Invariants:

* `TextPosition.node` names a node whose role is `TextRun`
  (`accesskit/src/lib.rs:772-773`). The consumer enforces it when it upgrades a weak
  position: `accesskit_consumer/src/text.rs:24-26`.
* `TextPosition.character_index` is an index into `Node::character_lengths`, or the
  length of that slice when the position sits at the end of the line
  (`accesskit/src/lib.rs:774-776`). Enforced at `accesskit_consumer/src/text.rs:28-30`.
* A selection with no extent, only a caret, has `anchor == focus`
  (`accesskit/src/lib.rs:785-788`).

Zig counterpart: `TextPosition` is a plain `struct`, size 16, alignment 8, from L1.
`TextSelection` is a plain `struct`, size 32, alignment 8, from L1.

The port renames the field `node` to `node_id`, by rule Z4 applied to the name `NodeId`.
One name per thing, so a field of type `NodeId` is never called `node`.

#### `Color` and `TextDecoration`

```rust
accesskit/src/lib.rs:828-850
/// A color represented in 8-bit sRGB plus alpha.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct Color {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}

/// The style and color for a type of text decoration.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(C)]
pub struct TextDecoration {
    pub style: TextDecorationStyle,
    pub color: Color,
}
```

Zig counterpart:

```zig
pub const Color = extern struct {
    red: u8,
    green: u8,
    blue: u8,
    alpha: u8,
};

pub const TextDecoration = extern struct {
    style: TextDecorationStyle,
    color: Color,
};
```

Field names by rule Z4. `Color` has size 4 and alignment 1, from L4. `TextDecoration` has
size 5 and alignment 1, from L4: `style` at offset 0 with size 1, then `color` at offset 1
with size 4, so the end is 5, and 5 is already a multiple of alignment 1.

### 2.4 Tree and update types

#### `TreeInfo`

```rust
accesskit/src/lib.rs:3162-3190
/// The data associated with an accessibility tree that's global to the
/// tree and not associated with any particular node.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TreeInfo {
    /// The identifier of the tree's root node.
    pub root: NodeId,
    /// The name of the UI toolkit in use.
    pub toolkit_name: Option<String>,
    /// The version of the UI toolkit.
    pub toolkit_version: Option<String>,
}

#[deprecated(note = "Use TreeInfo instead")]
pub type Tree = TreeInfo;

impl TreeInfo {
    pub fn new(root: NodeId) -> TreeInfo {
        TreeInfo {
            root,
            toolkit_name: None,
            toolkit_version: None,
        }
    }
}
```

| Rust source line | Field | Rust type | Zig field | Zig type |
|---|---|---|---|---|
| `accesskit/src/lib.rs:3171` | `root` | `NodeId` | `root` | `NodeId` |
| `accesskit/src/lib.rs:3173` | `toolkit_name` | `Option<String>` | `toolkit_name` | `?[]const u8` |
| `accesskit/src/lib.rs:3175` | `toolkit_version` | `Option<String>` | `toolkit_version` | `?[]const u8` |

Invariants:

* `root` must name a node that the update adds or already contains.
  `validate_global` panics otherwise (`accesskit_consumer/src/tree.rs:87-89`).
* `toolkit_version` is reported only when `toolkit_name` is set.
  `accesskit_consumer/src/tree.rs:560-565` filters on `toolkit_name.is_some()`.
* `TreeInfo` has `Eq`, so both strings must be comparable byte for byte.

Zig counterpart: a plain `struct` with the three fields in source order. Size 32,
alignment 8, from L1: `root` at offset 0 with size 8, `toolkit_name` at offset 8 with
`?[]const u8` size 16 under L5, `toolkit_version` at offset 24 with size 16.

`Tree` is deleted. It is a deprecated alias for `TreeInfo`
(`accesskit/src/lib.rs:3178-3179`), and the house rule is a clean cutover with no aliases.

#### `TreeUpdate`

```rust
accesskit/src/lib.rs:3192-3258
/// A serializable representation of an atomic change to a tree.
///
/// The sender and receiver must be in sync; the update is only meant
/// to bring the tree from a specific previous state into its next state.
/// Trying to apply it to the wrong tree should immediately panic.
///
/// Note that for performance, an update should only include nodes that are
/// new or changed. AccessKit platform adapters will avoid raising extraneous
/// events for nodes that have not changed since the previous update,
/// but there is still a cost in processing these nodes and replacing
/// the previous instances.
#[derive(Clone, Debug, PartialEq)]
pub struct TreeUpdate {
    pub nodes: Vec<(NodeId, Node)>,
    pub tree: Option<TreeInfo>,
    pub tree_id: TreeId,
    pub focus: NodeId,
}
```

| Rust source line | Field | Rust type | Zig field | Zig type |
|---|---|---|---|---|
| `accesskit/src/lib.rs:3229` | `nodes` | `Vec<(NodeId, Node)>` | `nodes` | `std.ArrayList(NodeEntry)` |
| `accesskit/src/lib.rs:3235` | `tree` | `Option<TreeInfo>` | `tree` | `?TreeInfo` |
| `accesskit/src/lib.rs:3246` | `tree_id` | `TreeId` | `tree_id` | `TreeId` |
| `accesskit/src/lib.rs:3257` | `focus` | `NodeId` | `focus` | `NodeId` |

Invariants, all stated in the doc comments and all enforced by
`TreeState::update`:

* `nodes` is unordered (`accesskit/src/lib.rs:3209`). A node in the list overwrites any
  existing node with the same id (`accesskit/src/lib.rs:3211`).
* Every node in `nodes` is either the root or a child of another node
  (`accesskit/src/lib.rs:3216-3219`). Enforced by the `pending_nodes` panic at
  `accesskit_consumer/src/tree.rs:317-323`.
* To add a child, the list carries the child and an updated parent whose
  `Node::children` includes the child's id (`accesskit/src/lib.rs:3221-3223`).
* To remove a child and its descendants, the list carries the updated parent without the
  child's id, and carries neither the child nor any descendant
  (`accesskit/src/lib.rs:3225-3228`).
* `tree` may be omitted unless it changed, but it is required for the first update of a
  tree (`accesskit/src/lib.rs:3231-3234`). Enforced at
  `accesskit_consumer/src/tree.rs:141-147`.
* `tree_id` is `TreeId::ROOT` for the main tree. For a subtree, a graft node carrying that
  id must already exist in the parent tree, and the first subtree update must carry
  `tree` data (`accesskit/src/lib.rs:3242-3246`). Enforced at
  `accesskit_consumer/src/tree.rs:132-148`.
* `focus` is the node with keyboard focus, or the root when no node has focus, and it must
  be sent with every update (`accesskit/src/lib.rs:3248-3252`).
* A node with no children and no parent other than the root must be in the list.
  `pending_children` panic at `accesskit_consumer/src/tree.rs:324-330`.

Zig counterpart:

```zig
pub const NodeEntry = struct {
    node_id: NodeId,
    node: Node,
};

pub const TreeUpdate = struct {
    nodes: std.ArrayList(NodeEntry) = .empty,
    tree: ?TreeInfo = null,
    tree_id: TreeId = treeIdRoot,
    focus: NodeId = .{ .value = 0 },
};
```

`NodeEntry` replaces the Rust tuple `(NodeId, Node)`. Zig has no tuples. The name is by
rule Z1 for a new type. Size 48, alignment 8, from L1: `node_id` at offset 0 with size 8,
then `node` at offset 8 with size 40, so the end is 48.

`TreeUpdate` is a plain `struct` with the fields in source order. Size 88, alignment 8,
from L1: `nodes` at offset 0 with size 24, `tree` at offset 24 with `?TreeInfo` size 40
under L5, `tree_id` at offset 64 with size 16 and alignment 1 so it needs no padding,
`focus` at offset 80 with size 8. `comptime assert(@sizeOf(TreeUpdate) == 88);`.

#### `ActionData`

```rust
accesskit/src/lib.rs:3300-3321
#[derive(Clone, Debug, PartialEq)]
#[cfg_attr(feature = "serde", serde(rename_all = "camelCase"))]
#[repr(C)]
pub enum ActionData {
    CustomAction(i32),
    Value(Box<str>),
    NumericValue(f64),
    ScrollUnit(ScrollUnit),
    /// Optional suggestion for [`Action::ScrollIntoView`], specifying
    /// the preferred position of the target node relative to the scrollable
    /// container's viewport.
    ScrollHint(ScrollHint),
    /// Target for [`Action::ScrollToPoint`], in platform-native coordinates
    /// relative to the origin of the tree's container (e.g. window).
    ScrollToPoint(Point),
    /// Target for [`Action::SetScrollOffset`], in the coordinate space
    /// of the action's target node.
    SetScrollOffset(Point),
    SetTextSelection(TextSelection),
}
```

8 data-carrying variants. Rust `#[repr(C)]` on an enum with data gives each variant the
same storage, the largest variant. Zig `union(enum)` gives a tagged union.

Zig counterpart:

```zig
pub const ActionData = union(enum) {
    custom_action: i32,
    value: []const u8,
    numeric_value: f64,
    scroll_unit: ScrollUnit,
    scroll_hint: ScrollHint,
    scroll_to_point: Point,
    set_scroll_offset: Point,
    set_text_selection: TextSelection,
};
```

Field names by rule Z5. `Box<str>` becomes `[]const u8`, because a borrowed slice says the
same thing and needs no allocation. Size 40, alignment 8, from L3: the tag is an 8-value
`enum(u8)` at offset 0 with size 1. The largest payload alignment is 8, so the payload
starts at offset 8. The largest payload is `TextSelection` at 32 bytes. The end is 40,
which is already a multiple of 8. `comptime assert(@sizeOf(ActionData) == 40);`.

#### `ActionRequest`

```rust
accesskit/src/lib.rs:3323-3333
#[derive(Clone, Debug, PartialEq)]
pub struct ActionRequest {
    pub action: Action,
    pub target_tree: TreeId,
    pub target_node: NodeId,
    pub data: Option<ActionData>,
}
```

| Rust source line | Field | Rust type | Zig field | Zig type |
|---|---|---|---|---|
| `accesskit/src/lib.rs:3329` | `action` | `Action` | `action` | `Action` |
| `accesskit/src/lib.rs:3330` | `target_tree` | `TreeId` | `target_tree` | `TreeId` |
| `accesskit/src/lib.rs:3331` | `target_node` | `NodeId` | `target_node` | `NodeId` |
| `accesskit/src/lib.rs:3332` | `data` | `Option<ActionData>` | `data` | `?ActionData` |

Invariants:

* `target_tree` and `target_node` together name one node, per
  `accesskit/src/lib.rs:707-710`.
* `data` is required for six actions and optional for the rest. The requirement is
  documented on each variant (`accesskit/src/lib.rs:299`, `:312`, `:325`, `:330`, `:333`,
  `:336`, `:344-346`). The core crate does not check it. `docs/31-c-abi-design.md` must
  decide where the check lives.
* An unsupported action must be ignored by the handler
  (`accesskit/src/lib.rs:3363-3364`).

Zig counterpart: a plain `struct` with the four fields in source order. Size 72, alignment
8, from L1: `action` at offset 0 with size 1, `target_tree` at offset 1 with size 16 and
alignment 1, `target_node` at offset 24 with size 8, `data` at offset 32 with `?ActionData`
size 48 under L5. `comptime assert(@sizeOf(ActionRequest) == 72);`.

### 2.5 Geometry types

All five geometry types are `#[repr(C)]` in Rust, so the port uses `extern struct` under
L4 with field names by rule Z4.

#### `Affine`

```rust
accesskit/src/geometry.rs:17-22
/// A 2D affine transform. Derived from [kurbo](https://github.com/linebender/kurbo).
#[derive(Clone, Copy, Debug, PartialEq)]
#[repr(C)]
pub struct Affine([f64; 6]);
```

The six coefficients are `(a, b, c, d, e, f)` and represent the augmented matrix
`| a c e | / | b d f | / | 0 0 1 |` (`accesskit/src/geometry.rs:37-44`). The port gives
the tuple struct a named field because Zig has no tuple structs:

```zig
pub const Affine = extern struct {
    coeffs: [6]f64,
};
```

Field name `coeffs` by rule Z4 from `as_coeffs` (`accesskit/src/geometry.rs:87`). Size 48,
alignment 8, from L4. `IDENTITY`, `FLIP_Y`, and `FLIP_X` become module constants
`affineIdentity`, `affineFlipY`, and `affineFlipX` by rule Z3
(`accesskit/src/geometry.rs:26`, `:30`, `:33`).

#### `Point`

```rust
accesskit/src/geometry.rs:207-217
/// A 2D point. Derived from [kurbo](https://github.com/linebender/kurbo).
#[derive(Clone, Copy, Default, PartialEq)]
#[repr(C)]
pub struct Point {
    /// The x coordinate.
    pub x: f64,
    /// The y coordinate.
    pub y: f64,
}
```

Zig counterpart: `extern struct { x: f64, y: f64 }`. Size 16, alignment 8, from L4.
`ZERO` and `ORIGIN` both hold `(0, 0)` in Rust (`accesskit/src/geometry.rs:221`, `:224`),
so the port keeps one constant, `pointOrigin`, by rule Z6 one name per thing, and deletes
`pointZero`.

#### `Size`

```rust
accesskit/src/geometry.rs:566-576
/// A 2D size. Derived from [kurbo](https://github.com/linebender/kurbo).
#[derive(Clone, Copy, Default, PartialEq)]
#[repr(C)]
pub struct Size {
    /// The width.
    pub width: f64,
    /// The height.
    pub height: f64,
}
```

Zig counterpart: `extern struct { width: f64, height: f64 }`. Size 16, alignment 8, from
L4. The `ZERO` constant becomes `sizeZero` by rule Z3
(`accesskit/src/geometry.rs:580`).

#### `Rect`

```rust
accesskit/src/geometry.rs:332-346
/// A rectangle. Derived from [kurbo](https://github.com/linebender/kurbo).
#[derive(Clone, Copy, Default, PartialEq)]
#[repr(C)]
pub struct Rect {
    /// The minimum x coordinate (left edge).
    pub x0: f64,
    /// The minimum y coordinate (top edge in y-down spaces).
    pub y0: f64,
    /// The maximum x coordinate (right edge).
    pub x1: f64,
    /// The maximum y coordinate (bottom edge in y-down spaces).
    pub y1: f64,
}
```

Zig counterpart: `extern struct { x0: f64, y0: f64, x1: f64, y1: f64 }`. Size 32,
alignment 8, from L4. The `ZERO` constant becomes `rectZero` by rule Z3
(`accesskit/src/geometry.rs:399`).

Invariants the code maintains:

* Nothing forbids a negative width or negative height
  (`accesskit/src/geometry.rs:440`, `:448`).
* `abs` guarantees non-negative width and height (`accesskit/src/geometry.rs:493-501`).
* `from_points` and `from_origin_size` call `abs`, so they produce non-negative extents
  (`accesskit/src/geometry.rs:411-424`).
* `intersect` always returns non-negative width and height
  (`accesskit/src/geometry.rs:552-563`).
* `union` and `union_pt` are valid only when the inputs have non-negative extents
  (`accesskit/src/geometry.rs:525`, `:542`).
* `contains` is half-open: the minimum edge is inside, the maximum edge is outside
  (`accesskit/src/geometry.rs:519-521`).

#### `Vec2`

```rust
accesskit/src/geometry.rs:708-722
/// A 2D vector. Derived from [kurbo](https://github.com/linebender/kurbo).
#[derive(Clone, Copy, Default, Debug, PartialEq)]
#[repr(C)]
pub struct Vec2 {
    /// The x-coordinate.
    pub x: f64,
    /// The y-coordinate.
    pub y: f64,
}
```

Zig counterpart: `extern struct { x: f64, y: f64 }`. Size 16, alignment 8, from L4. The
`ZERO` constant becomes `vec2Zero` by rule Z3 (`accesskit/src/geometry.rs:726`).

## 3. Function by function mapping

This section lists every public function, method and trait in `accesskit/src/lib.rs`,
`accesskit/src/geometry.rs`, and the public surface of `accesskit_consumer/src`. The Zig
name comes from rule Z2 unless a rule is named. The last three columns flag where the Zig
version needs something the Rust version does not need.

Column meanings:

* `gpa` means the Zig function must take `gpa: std.mem.Allocator`. Rust hides the
  allocator in the global allocator.
* `io` means the Zig function must take `io: std.Io`.
* `!` means the Zig function must return an explicit error set.
* A dash means no change.

### 3.1 `accesskit` crate: constructors and role

| Rust symbol | `path:line` | What it does | Zig counterpart | State threaded | gpa | io | `!` |
|---|---|---|---|---|---|---|---|
| `Node::new(role)` | `accesskit/src/lib.rs:1828` | Builds a node with the given role and every other field default | `pub fn init(role: Role) Node` | none | no | no | no |
| `Node::role` | `accesskit/src/lib.rs:1858` | Returns the role | `pub fn role(self: *const Node) Role` | none | no | no | no |
| `Node::set_role` | `accesskit/src/lib.rs:1862` | Replaces the role | `pub fn setRole(self: *Node, value: Role) void` | none | no | no | no |
| `TreeInfo::new(root)` | `accesskit/src/lib.rs:3183` | Builds tree metadata with both toolkit fields unset | `pub fn init(root: NodeId) TreeInfo` | none | no | no | no |
| `TreeId::ROOT` | `accesskit/src/lib.rs:749` | The nil-UUID root tree id | `pub const treeIdRoot` | none | no | no | no |
| `Toggled::from(bool)` | `accesskit/src/lib.rs:492` | Maps `false` to `False`, `true` to `True` | `pub fn toggledFromBool(value: bool) Toggled` | none | no | no | no |
| `NodeId::from(u64)` | `accesskit/src/lib.rs:717` | Wraps a `u64` | deleted, the field is public | none | no | no | no |
| `u64::from(NodeId)` | `accesskit/src/lib.rs:724` | Unwraps a `u64` | deleted, the field is public | none | no | no | no |
| `NodeId::fmt` | `accesskit/src/lib.rs:731` | Writes `#0`, `#1` | `pub fn format(self: NodeId, writer: *std.Io.Writer) std.Io.Writer.Error!void` | none | no | no | yes |

`NodeId::from` and `u64::from` are deleted because rule Z4 makes the `value` field public
on the Zig struct, and a public field needs no accessor. Rule Z6 applies: one name for one
thing.

`NodeId::fmt` is the Rust `Debug` implementation. The Zig replacement writes through
`std.Io.Writer`, which makes the `io` parameter implicit in the writer itself. The error
set comes from the writer, not from the port.

### 3.2 `accesskit` crate: actions

| Rust symbol | `path:line` | What it does | Zig counterpart | State threaded | gpa | io | `!` |
|---|---|---|---|---|---|---|---|
| `Action::mask` | `accesskit/src/lib.rs:353` | `1 << (self as u8)` as a `u32` | `pub fn mask(self: Action) ActionMask` | none | no | no | no |
| `Action::n` | `accesskit/src/lib.rs:358` | Integer to variant, `None` above 21 | `pub fn actionFromInt(value: u8) ?Action` | none | no | no | no |
| `action_mask_to_action_vec` | `accesskit/src/lib.rs:390` | Expands a mask into a `Vec<Action>` in variant order | `pub fn actionsFromMask(allocator: std.mem.Allocator, mask: ActionMask) std.mem.Allocator.Error!std.ArrayList(Action)` | none | **yes** | no | yes |
| `Node::supports_action` | `accesskit/src/lib.rs:1867` | Tests one bit of `actions` | `pub fn supportsAction(self: *const Node, action: Action) bool` | none | no | no | no |
| `Node::add_action` | `accesskit/src/lib.rs:1871` | Sets one bit of `actions` | `pub fn addAction(self: *Node, action: Action) void` | none | no | no | no |
| `Node::remove_action` | `accesskit/src/lib.rs:1875` | Clears one bit of `actions` | `pub fn removeAction(self: *Node, action: Action) void` | none | no | no | no |
| `Node::clear_actions` | `accesskit/src/lib.rs:1879` | Sets `actions` to 0 | `pub fn clearActions(self: *Node) void` | none | no | no | no |
| `Node::child_supports_action` | `accesskit/src/lib.rs:1886` | Tests one bit of `child_actions` | `pub fn childSupportsAction(self: *const Node, action: Action) bool` | none | no | no | no |
| `Node::add_child_action` | `accesskit/src/lib.rs:1892` | Sets one bit of `child_actions` | `pub fn addChildAction(self: *Node, action: Action) void` | none | no | no | no |
| `Node::remove_child_action` | `accesskit/src/lib.rs:1898` | Clears one bit of `child_actions` | `pub fn removeChildAction(self: *Node, action: Action) void` | none | no | no | no |
| `Node::clear_child_actions` | `accesskit/src/lib.rs:1904` | Sets `child_actions` to 0 | `pub fn clearChildActions(self: *Node) void` | none | no | no | no |

`action_mask_to_action_vec` is private in Rust and only serves the `Debug` implementation
(`accesskit/src/lib.rs:2759-2767`). The port makes it private too. It needs an allocator
because Rust's `Vec::new` grows on the heap. The Zig version returns an
`std.ArrayList(Action)` that the caller owns and must deinit. The port keeps it because the
C ABI header needs a printable action list, and `docs/31-c-abi-design.md` owns that
decision.

### 3.3 `accesskit` crate: the 336 generated property methods

These are macro generated. Each row gives the macro invocation, the property list, the
Zig method-name pattern, and the extra parameter each method needs. `N` in the pattern
stands for the property name in `snake_case`, derived from the Rust identifier by rule Z2.

#### 3.3.1 Flags: 18 properties, 54 methods

Source: `flag_methods!` at `accesskit/src/lib.rs:1909-1975`, expanding the macro at
`accesskit/src/lib.rs:1170-1220`.

| Rust source line | Rust property | Getter | Setter | Clearer | Zig triple | Extra parameter |
|---|---|---|---|---|---|---|
| `accesskit/src/lib.rs:1919` | `Hidden` | `is_hidden` | `set_hidden` | `clear_hidden` | `isHidden`, `setHidden`, `clearHidden` | none |
| `accesskit/src/lib.rs:1924` | `Multiselectable` | `is_multiselectable` | `set_multiselectable` | `clear_multiselectable` | `isMultiselectable`, `setMultiselectable`, `clearMultiselectable` | none |
| `accesskit/src/lib.rs:1929` | `Required` | `is_required` | `set_required` | `clear_required` | `isRequired`, `setRequired`, `clearRequired` | none |
| `accesskit/src/lib.rs:1931` | `Visited` | `is_visited` | `set_visited` | `clear_visited` | `isVisited`, `setVisited`, `clearVisited` | none |
| `accesskit/src/lib.rs:1936` | `Busy` | `is_busy` | `set_busy` | `clear_busy` | `isBusy`, `setBusy`, `clearBusy` | none |
| `accesskit/src/lib.rs:1941` | `LiveAtomic` | `is_live_atomic` | `set_live_atomic` | `clear_live_atomic` | `isLiveAtomic`, `setLiveAtomic`, `clearLiveAtomic` | none |
| `accesskit/src/lib.rs:1945` | `Modal` | `is_modal` | `set_modal` | `clear_modal` | `isModal`, `setModal`, `clearModal` | none |
| `accesskit/src/lib.rs:1948` | `TouchTransparent` | `is_touch_transparent` | `set_touch_transparent` | `clear_touch_transparent` | `isTouchTransparent`, `setTouchTransparent`, `clearTouchTransparent` | none |
| `accesskit/src/lib.rs:1953` | `ReadOnly` | `is_read_only` | `set_read_only` | `clear_read_only` | `isReadOnly`, `setReadOnly`, `clearReadOnly` | none |
| `accesskit/src/lib.rs:1958` | `Disabled` | `is_disabled` | `set_disabled` | `clear_disabled` | `isDisabled`, `setDisabled`, `clearDisabled` | none |
| `accesskit/src/lib.rs:1960` | `Italic` | `is_italic` | `set_italic` | `clear_italic` | `isItalic`, `setItalic`, `clearItalic` | none |
| `accesskit/src/lib.rs:1962` | `ClipsChildren` | `clips_children` | `set_clips_children` | `clear_clips_children` | `clipsChildren`, `setClipsChildren`, `clearClipsChildren` | none |
| `accesskit/src/lib.rs:1964` | `IsLineBreakingObject` | `is_line_breaking_object` | `set_is_line_breaking_object` | `clear_is_line_breaking_object` | `isLineBreakingObject`, `setLineBreakingObject`, `clearLineBreakingObject` | none |
| `accesskit/src/lib.rs:1966` | `IsPageBreakingObject` | `is_page_breaking_object` | `set_is_page_breaking_object` | `clear_is_page_breaking_object` | `isPageBreakingObject`, `setPageBreakingObject`, `clearPageBreakingObject` | none |
| `accesskit/src/lib.rs:1968` | `IsSpellingError` | `is_spelling_error` | `set_is_spelling_error` | `clear_is_spelling_error` | `isSpellingError`, `setSpellingError`, `clearSpellingError` | none |
| `accesskit/src/lib.rs:1970` | `IsGrammarError` | `is_grammar_error` | `set_is_grammar_error` | `clear_is_grammar_error` | `isGrammarError`, `setGrammarError`, `clearGrammarError` | none |
| `accesskit/src/lib.rs:1972` | `IsSearchMatch` | `is_search_match` | `set_is_search_match` | `clear_is_search_match` | `isSearchMatch`, `setSearchMatch`, `clearSearchMatch` | none |
| `accesskit/src/lib.rs:1974` | `IsSuggestion` | `is_suggestion` | `set_is_suggestion` | `clear_is_suggestion` | `isSuggestion`, `setSuggestion`, `clearSuggestion` | none |

The generated getter is `(self.flags & Flag::mask()) != 0`, the setter is
`self.flags |= Flag::mask()`, and the clearer is `self.flags &= !Flag::mask()`
(`accesskit/src/lib.rs:1176-1184`). All three take `*Node` for the mutators and
`*const Node` for the getter. None allocate, so none take `gpa`.

Note on `ClipsChildren`: Rust names the getter `clips_children`, not `is_clips_children`
(`accesskit/src/lib.rs:1962`). The port keeps `clipsChildren` because rule Z2 is a
mechanical spelling rule, and inventing a new prefix would break the one-to-one mapping
that `docs/31-c-abi-design.md` needs.

#### 3.3.2 `NodeId` lists: 8 properties, 32 methods

Source: `node_id_vec_property_methods!` at `accesskit/src/lib.rs:2025-2067`, expanding
`vec_property_methods!` at `accesskit/src/lib.rs:1319-1332`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig pusher | Zig clearer |
|---|---|---|---|---|---|
| `accesskit/src/lib.rs:2028` | `Children` | `children` | `setChildren` | `pushChild` | `clearChildren` |
| `accesskit/src/lib.rs:2033` | `Controls` | `controls` | `setControls` | `pushControlled` | `clearControls` |
| `accesskit/src/lib.rs:2042` | `Details` | `details` | `setDetails` | `pushDetail` | `clearDetails` |
| `accesskit/src/lib.rs:2048` | `DescribedBy` | `describedBy` | `setDescribedBy` | `pushDescribedBy` | `clearDescribedBy` |
| `accesskit/src/lib.rs:2053` | `FlowTo` | `flowTo` | `setFlowTo` | `pushFlowTo` | `clearFlowTo` |
| `accesskit/src/lib.rs:2057` | `LabelledBy` | `labelledBy` | `setLabelledBy` | `pushLabelledBy` | `clearLabelledBy` |
| `accesskit/src/lib.rs:2063` | `Owns` | `owns` | `setOwns` | `pushOwned` | `clearOwns` |
| `accesskit/src/lib.rs:2066` | `RadioGroup` | `radioGroup` | `setRadioGroup` | `pushToRadioGroup` | `clearRadioGroup` |

Signatures, with `N` replaced by the property name:

```zig
pub fn N(self: *const Node) []const NodeId
pub fn setN(gpa: std.mem.Allocator, self: *Node, values: []const NodeId) std.mem.Allocator.Error!void
pub fn pushN(gpa: std.mem.Allocator, self: *Node, item: NodeId) std.mem.Allocator.Error!void
pub fn clearN(self: *Node) void
```

All four take `gpa`, and the two mutators that can grow return `!`. The Rust setter takes
`impl Into<Vec<NodeId>>` (`accesskit/src/lib.rs:1323`), which rule Z8 replaces with
`[]const NodeId`. The Zig getter returns a borrowed slice into `self`, so the caller must
not hold it across a mutation.

#### 3.3.3 `NodeId` singletons: 7 properties, 21 methods

Source: `node_id_property_methods!` at `accesskit/src/lib.rs:2069-2095`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2075` | `ActiveDescendant` | `activeDescendant` | `setActiveDescendant` | `clearActiveDescendant` |
| `accesskit/src/lib.rs:2081` | `ErrorMessage` | `errorMessage` | `setErrorMessage` | `clearErrorMessage` |
| `accesskit/src/lib.rs:2084` | `InPageLinkTarget` | `inPageLinkTarget` | `setInPageLinkTarget` | `clearInPageLinkTarget` |
| `accesskit/src/lib.rs:2086` | `MemberOf` | `memberOf` | `setMemberOf` | `clearMemberOf` |
| `accesskit/src/lib.rs:2089` | `NextOnLine` | `nextOnLine` | `setNextOnLine` | `clearNextOnLine` |
| `accesskit/src/lib.rs:2092` | `PreviousOnLine` | `previousOnLine` | `setPreviousOnLine` | `clearPreviousOnLine` |
| `accesskit/src/lib.rs:2094` | `PopupFor` | `popupFor` | `setPopupFor` | `clearPopupFor` |

Signatures: the getter returns `?NodeId`, the setter takes `NodeId` and needs no `gpa`
because it replaces an existing slot or pushes `PropertyValue::NodeId`, which holds no
heap memory. The setter does need `gpa` for the push path, so it takes `gpa` and returns
`!`.

#### 3.3.4 Strings: 21 properties, 63 methods

Source: `string_property_methods!` at `accesskit/src/lib.rs:2097-2205`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2104` | `Label` | `label` | `setLabel` | `clearLabel` |
| `accesskit/src/lib.rs:2109` | `Description` | `description` | `setDescription` | `clearDescription` |
| `accesskit/src/lib.rs:2118` | `Value` | `value` | `setValue` | `clearValue` |
| `accesskit/src/lib.rs:2126` | `AccessKey` | `accessKey` | `setAccessKey` | `clearAccessKey` |
| `accesskit/src/lib.rs:2129` | `AuthorId` | `authorId` | `setAuthorId` | `clearAuthorId` |
| `accesskit/src/lib.rs:2131` | `ClassName` | `className` | `setClassName` | `clearClassName` |
| `accesskit/src/lib.rs:2134` | `FontFamily` | `fontFamily` | `setFontFamily` | `clearFontFamily` |
| `accesskit/src/lib.rs:2140` | `HtmlId` | `htmlId` | `setHtmlId` | `clearHtmlId` |
| `accesskit/src/lib.rs:2142` | `HtmlTag` | `htmlTag` | `setHtmlTag` | `clearHtmlTag` |
| `accesskit/src/lib.rs:2145` | `InnerHtml` | `innerHtml` | `setInnerHtml` | `clearInnerHtml` |
| `accesskit/src/lib.rs:2152` | `KeyboardShortcut` | `keyboardShortcut` | `setKeyboardShortcut` | `clearKeyboardShortcut` |
| `accesskit/src/lib.rs:2155` | `Language` | `language` | `setLanguage` | `clearLanguage` |
| `accesskit/src/lib.rs:2161` | `Placeholder` | `placeholder` | `setPlaceholder` | `clearPlaceholder` |
| `accesskit/src/lib.rs:2168` | `RoleDescription` | `roleDescription` | `setRoleDescription` | `clearRoleDescription` |
| `accesskit/src/lib.rs:2173` | `StateDescription` | `stateDescription` | `setStateDescription` | `clearStateDescription` |
| `accesskit/src/lib.rs:2178` | `Tooltip` | `tooltip` | `setTooltip` | `clearTooltip` |
| `accesskit/src/lib.rs:2180` | `Url` | `url` | `setUrl` | `clearUrl` |
| `accesskit/src/lib.rs:2185` | `RowIndexText` | `rowIndexText` | `setRowIndexText` | `clearRowIndexText` |
| `accesskit/src/lib.rs:2190` | `ColumnIndexText` | `columnIndexText` | `setColumnIndexText` | `clearColumnIndexText` |
| `accesskit/src/lib.rs:2197` | `BrailleLabel` | `brailleLabel` | `setBrailleLabel` | `clearBrailleLabel` |
| `accesskit/src/lib.rs:2204` | `BrailleRoleDescription` | `brailleRoleDescription` | `setBrailleRoleDescription` | `clearBrailleRoleDescription` |

Signatures:

```zig
pub fn N(self: *const Node) ?[]const u8
pub fn setN(gpa: std.mem.Allocator, self: *Node, value: []const u8) std.mem.Allocator.Error!void
pub fn clearN(self: *Node) void
```

The getter returns `?[]const u8` instead of Rust `Option<&str>`
(`accesskit/src/lib.rs:1451`). The borrowed lifetime is the receiver, so the caller must
keep the node alive. The setter takes `gpa` and returns `!` because it copies the bytes
into an `std.ArrayList(u8)` inside the union.

#### 3.3.5 `f64` scalars: 11 properties, 33 methods

Source: `f64_property_methods!` at `accesskit/src/lib.rs:2207-2241`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2209` | `ScrollX` | `scrollX` | `setScrollX` | `clearScrollX` |
| `accesskit/src/lib.rs:2211` | `ScrollXMin` | `scrollXMin` | `setScrollXMin` | `clearScrollXMin` |
| `accesskit/src/lib.rs:2213` | `ScrollXMax` | `scrollXMax` | `setScrollXMax` | `clearScrollXMax` |
| `accesskit/src/lib.rs:2215` | `ScrollY` | `scrollY` | `setScrollY` | `clearScrollY` |
| `accesskit/src/lib.rs:2217` | `ScrollYMin` | `scrollYMin` | `setScrollYMin` | `clearScrollYMin` |
| `accesskit/src/lib.rs:2219` | `ScrollYMax` | `scrollYMax` | `setScrollYMax` | `clearScrollYMax` |
| `accesskit/src/lib.rs:2224` | `NumericValue` | `numericValue` | `setNumericValue` | `clearNumericValue` |
| `accesskit/src/lib.rs:2229` | `MinNumericValue` | `minNumericValue` | `setMinNumericValue` | `clearMinNumericValue` |
| `accesskit/src/lib.rs:2234` | `MaxNumericValue` | `maxNumericValue` | `setMaxNumericValue` | `clearMaxNumericValue` |
| `accesskit/src/lib.rs:2237` | `NumericValueStep` | `numericValueStep` | `setNumericValueStep` | `clearNumericValueStep` |
| `accesskit/src/lib.rs:2240` | `NumericValueJump` | `numericValueJump` | `setNumericValueJump` | `clearNumericValueJump` |

The getter returns `?f64`, the setter takes `f64`, the clearer takes nothing. None take
`gpa`, because the payload holds no heap memory. The setter returns `!` only for the push
path into `values`, so it takes `gpa` and returns `std.mem.Allocator.Error!void`.

#### 3.3.6 `f32` scalars: 2 properties, 6 methods

Source: `f32_property_methods!` at `accesskit/src/lib.rs:2243-2249`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2245` | `FontSize` | `fontSize` | `setFontSize` | `clearFontSize` |
| `accesskit/src/lib.rs:2248` | `FontWeight` | `fontWeight` | `setFontWeight` | `clearFontWeight` |

Same shape as the `f64` family, with `?f32` and `f32`.

#### 3.3.7 `usize` scalars: 9 properties, 27 methods

Source: `usize_property_methods!` at `accesskit/src/lib.rs:2251-2314`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2256` | `RowCount` | `rowCount` | `setRowCount` | `clearRowCount` |
| `accesskit/src/lib.rs:2261` | `ColumnCount` | `columnCount` | `setColumnCount` | `clearColumnCount` |
| `accesskit/src/lib.rs:2269` | `RowIndex` | `rowIndex` | `setRowIndex` | `clearRowIndex` |
| `accesskit/src/lib.rs:2277` | `ColumnIndex` | `columnIndex` | `setColumnIndex` | `clearColumnIndex` |
| `accesskit/src/lib.rs:2282` | `RowSpan` | `rowSpan` | `setRowSpan` | `clearRowSpan` |
| `accesskit/src/lib.rs:2287` | `ColumnSpan` | `columnSpan` | `setColumnSpan` | `clearColumnSpan` |
| `accesskit/src/lib.rs:2295` | `Level` | `level` | `setLevel` | `clearLevel` |
| `accesskit/src/lib.rs:2303` | `SizeOfSet` | `sizeOfSet` | `setSizeOfSet` | `clearSizeOfSet` |
| `accesskit/src/lib.rs:2313` | `PositionInSet` | `positionInSet` | `setPositionInSet` | `clearPositionInSet` |

The getter returns `?usize`. Rust `usize` is a machine word. Zig `usize` matches.

#### 3.3.8 Colors: 3 properties, 9 methods

Source: `color_property_methods!` at `accesskit/src/lib.rs:2316-2323`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2318` | `ColorValue` | `colorValue` | `setColorValue` | `clearColorValue` |
| `accesskit/src/lib.rs:2320` | `BackgroundColor` | `backgroundColor` | `setBackgroundColor` | `clearBackgroundColor` |
| `accesskit/src/lib.rs:2322` | `ForegroundColor` | `foregroundColor` | `setForegroundColor` | `clearForegroundColor` |

The getter returns `?Color`, the setter takes `Color` by value. Both need no `gpa`.

#### 3.3.9 Text decorations: 3 properties, 9 methods

Source: `text_decoration_property_methods!` at `accesskit/src/lib.rs:2325-2332`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2327` | `Overline` | `overline` | `setOverline` | `clearOverline` |
| `accesskit/src/lib.rs:2329` | `Strikethrough` | `strikethrough` | `setStrikethrough` | `clearStrikethrough` |
| `accesskit/src/lib.rs:2331` | `Underline` | `underline` | `setUnderline` | `clearUnderline` |

The getter returns `?TextDecoration`. `TextDecoration` itself has size 5 and alignment 1,
so by L5 the optional has size 6: the tag occupies offset 0, the payload starts at offset
1 because the payload alignment is 1, the payload ends at 6, and the optional alignment is
1. `[INFERENCE]` The port asserts it.

#### 3.3.10 Length vectors: 2 properties, 6 methods

Source: `length_vec_property_methods!` at `accesskit/src/lib.rs:2334-2385`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2353` | `CharacterLengths` | `characterLengths` | `setCharacterLengths` | `clearCharacterLengths` |
| `accesskit/src/lib.rs:2384` | `WordStarts` | `wordStarts` | `setWordStarts` | `clearWordStarts` |

The getter returns `[]const u8`, not an optional, because the Rust getter is
`&[u8]` (`accesskit/src/lib.rs:1671`). An absent property reads as an empty slice through
`slice_type_getters!` (`accesskit/src/lib.rs:1235`). The setter takes `[]const u8`, needs
`gpa`, and returns `!`.

#### 3.3.11 Coordinate vectors: 2 properties, 6 methods

Source: `coord_vec_property_methods!` at `accesskit/src/lib.rs:2387-2425`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2404` | `CharacterPositions` | `characterPositions` | `setCharacterPositions` | `clearCharacterPositions` |
| `accesskit/src/lib.rs:2424` | `CharacterWidths` | `characterWidths` | `setCharacterWidths` | `clearCharacterWidths` |

The getter returns `?[]const f32`, which is different from the length-vector family. Rust
uses `Option<&[f32]>` here (`accesskit/src/lib.rs:1708`) and `&[u8]` for lengths, so an
absent coordinate list is distinguishable from an empty one. The port keeps the
distinction.

#### 3.3.12 Booleans: 2 properties, 6 methods

Source: `bool_property_methods!` at `accesskit/src/lib.rs:2427-2450`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2435` | `Expanded` | `isExpanded` | `setExpanded` | `clearExpanded` |
| `accesskit/src/lib.rs:2449` | `Selected` | `isSelected` | `setSelected` | `clearSelected` |

The getter returns `?bool`, not `bool`. The absence means "the state does not apply", which
is different from `false` (`accesskit/src/lib.rs:2428-2432`, `:2439-2447`).

#### 3.3.13 Unique enums: 12 properties, 36 methods

Source: `unique_enum_property_methods!` at `accesskit/src/lib.rs:2452-2506`. This family
writes its own accessors instead of delegating to the shared typed getters
(`accesskit/src/lib.rs:1783-1795`).

| Rust source line | Rust property | Zig getter returns | Zig setter takes | Zig clearer |
|---|---|---|---|---|
| `accesskit/src/lib.rs:2457` | `Invalid` | `?Invalid` | `Invalid` | `clearInvalid` |
| `accesskit/src/lib.rs:2467` | `Toggled` | `?Toggled` | `Toggled` | `clearToggled` |
| `accesskit/src/lib.rs:2472` | `Live` | `?Live` | `Live` | `clearLive` |
| `accesskit/src/lib.rs:2474` | `TextDirection` | `?TextDirection` | `TextDirection` | `clearTextDirection` |
| `accesskit/src/lib.rs:2479` | `Orientation` | `?Orientation` | `Orientation` | `clearOrientation` |
| `accesskit/src/lib.rs:2484` | `SortDirection` | `?SortDirection` | `SortDirection` | `clearSortDirection` |
| `accesskit/src/lib.rs:2489` | `AriaCurrent` | `?AriaCurrent` | `AriaCurrent` | `clearAriaCurrent` |
| `accesskit/src/lib.rs:2494` | `AutoComplete` | `?AutoComplete` | `AutoComplete` | `clearAutoComplete` |
| `accesskit/src/lib.rs:2499` | `HasPopup` | `?HasPopup` | `HasPopup` | `clearHasPopup` |
| `accesskit/src/lib.rs:2501` | `ListStyle` | `?ListStyle` | `ListStyle` | `clearListStyle` |
| `accesskit/src/lib.rs:2503` | `TextAlign` | `?TextAlign` | `TextAlign` | `clearTextAlign` |
| `accesskit/src/lib.rs:2505` | `VerticalOffset` | `?VerticalOffset` | `VerticalOffset` | `clearVerticalOffset` |

Getters are named after the property: `invalid`, `toggled`, `live`, `textDirection`, and so
on. None take `gpa`.

#### 3.3.14 The four standalone properties

Source: `property_methods!` at `accesskit/src/lib.rs:2508-2546`. Each row names the typed
getter and setter from the shared families at `accesskit/src/lib.rs:1977-2018`.

| Rust source line | Rust property | Rust typed getter | Rust typed setter | Zig getter | Zig setter | Zig clearer |
|---|---|---|---|---|---|---|
| `accesskit/src/lib.rs:2521` | `Transform` | `get_affine_property` | `set_affine_property` | `transform` returns `?Affine` | `setTransform(gpa, Affine) !void` | `clearTransform` |
| `accesskit/src/lib.rs:2533` | `Bounds` | `get_rect_property` | `set_rect_property` | `bounds` returns `?Rect` | `setBounds(gpa, Rect) !void` | `clearBounds` |
| `accesskit/src/lib.rs:2536` | `TextSelection` | `get_text_selection_property` | `set_text_selection_property` | `textSelection` returns `?TextSelection` | `setTextSelection(gpa, TextSelection) !void` | `clearTextSelection` |
| `accesskit/src/lib.rs:2545` | `TreeId` | `get_tree_id_property` | `set_tree_id_property` | `treeId` returns `?TreeId` | `setTreeId(gpa, TreeId) !void` | `clearTreeId` |

All four setters take `gpa` and return `!`. The Rust setters take
`impl Into<Box<Affine>>` and `impl Into<Box<TextSelection>>`
(`accesskit/src/lib.rs:2521`, `:2536`), which rule Z8 replaces with the plain type.

#### 3.3.15 Custom actions: 1 property, 4 methods

Source: `vec_property_methods!` at `accesskit/src/lib.rs:2679-2682`.

| Rust source line | Rust property | Zig getter | Zig setter | Zig pusher | Zig clearer |
|---|---|---|---|---|---|
| `accesskit/src/lib.rs:2681` | `CustomActions` | `customActions` | `setCustomActions` | `pushCustomAction` | `clearCustomActions` |

Same signature family as the `NodeId` lists, with `CustomAction` as the item type. All four
take `gpa`, and the mutators return `!`.

### 3.4 `accesskit` crate: `Node` internals

These are private in Rust. The port keeps them private to the module, except that
`Properties` and `PropertyValue` need `deinit`, which is public.

| Rust symbol | `path:line` | What it does | Zig counterpart |
|---|---|---|---|
| `value_at` | `accesskit/src/lib.rs:1076` | Maps a slot index to a value, treating `Unset` as `None` | `fn valueAt(values: []const PropertyValue, index: u8) *const PropertyValue` |
| `Properties::get` | `accesskit/src/lib.rs:1116` | Reads one property by id | `fn get(self: *const PropertyIndices, values: []const PropertyValue, id: PropertyId) *const PropertyValue` |
| `Properties::get_mut` | `accesskit/src/lib.rs:1122` | Returns a mutable slot, allocating one if needed | `fn getMut(gpa, self: *Properties, id: PropertyId, default: PropertyValue) std.mem.Allocator.Error!*PropertyValue` |
| `Properties::set` | `accesskit/src/lib.rs:1138` | Writes one property, allocating a slot if needed | `fn set(gpa, self: *Properties, id: PropertyId, value: PropertyValue) std.mem.Allocator.Error!void` |
| `Properties::clear` | `accesskit/src/lib.rs:1148` | Marks one property absent without removing the slot | `fn clear(self: *Properties, id: PropertyId) void` |
| `Properties::clone` | `accesskit/src/lib.rs:1157` | Copies the index array and the values | `fn cloneFrom(gpa, dest: *Properties, source: *const Properties) std.mem.Allocator.Error!void` |
| `Properties::clone_from` | `accesskit/src/lib.rs:1164` | Copies into an existing slot vector, reusing buffers | `fn cloneInto(gpa, dest: *Properties, source: *const Properties) std.mem.Allocator.Error!void` |
| `PropertyValue::clone` | `accesskit/src/lib.rs:1012` | Deep copy of one value | `fn cloneValue(gpa, source: PropertyValue) std.mem.Allocator.Error!PropertyValue` |
| `PropertyValue::clone_from` | `accesskit/src/lib.rs:1046` | Copy into an existing value, reusing buffers where the variant matches | `fn cloneValueInto(gpa, dest: *PropertyValue, source: PropertyValue) std.mem.Allocator.Error!void` |
| `Properties::eq` | `accesskit/src/lib.rs:1084` | Order-independent equality by property id | `pub fn eql(self: *const Properties, other: *const Properties) bool` |
| `Node::clone` | `accesskit/src/lib.rs:1837` | Copies a node | `pub fn clone(gpa, source: *const Node) std.mem.Allocator.Error!Node` |
| `Node::clone_from` | `accesskit/src/lib.rs:1847` | Copies into an existing node, reusing buffers | `pub fn cloneInto(gpa, dest: *Node, source: *const Node) std.mem.Allocator.Error!void` |
| `Node::fmt` | `accesskit/src/lib.rs:2753` | Human-readable dump of role, actions, flags and set properties | `pub fn format(self: *const Node, writer: *std.Io.Writer) std.Io.Writer.Error!void` |

`PropertyValue::clone_from` needs `gpa` because its fast path calls `clone_from` on the
slice payload, which is Rust `Vec::clone_from` (`accesskit/src/lib.rs:1048-1054`). In Zig
that becomes `ArrayList.clearRetainingCapacity()` followed by `appendSlice`. This is the
0.25.0 buffer-reuse change, covered in section 5.5.

### 3.5 `accesskit` crate: the three handler traits

| Rust symbol | `path:line` | Zig counterpart | Extra state |
|---|---|---|---|
| `ActivationHandler::request_initial_tree` | `accesskit/src/lib.rs:3358` | `pub const ActivationHandler = struct { context: ?*anyopaque, requestInitialTree: *const fn (context: ?*anyopaque) ?TreeUpdate };` | context pointer, rule Z7 |
| `ActionHandler::do_action` | `accesskit/src/lib.rs:3372` | `pub const ActionHandler = struct { context: ?*anyopaque, doAction: *const fn (context: ?*anyopaque, request: ActionRequest) void };` | context pointer, rule Z7 |
| `DeactivationHandler::deactivate_accessibility` | `accesskit/src/lib.rs:3384` | `pub const DeactivationHandler = struct { context: ?*anyopaque, deactivateAccessibility: *const fn (context: ?*anyopaque) void };` | context pointer, rule Z7 |

The trait-object form `dyn ActionHandler` becomes a struct of function pointers by rule
Z7. `?TreeUpdate` in the return position means the handler may answer later, not now.
Section 6 covers the lifetime.

### 3.6 `geometry` module

#### `Affine`

| Rust symbol | `path:line` | What it does | Zig counterpart | gpa | `!` |
|---|---|---|---|---|---|
| `Affine::IDENTITY` | `accesskit/src/geometry.rs:26` | Unit scale | `pub const affineIdentity` | no | no |
| `Affine::FLIP_Y` | `accesskit/src/geometry.rs:30` | Mirror on the y axis | `pub const affineFlipY` | no | no |
| `Affine::FLIP_X` | `accesskit/src/geometry.rs:33` | Mirror on the x axis | `pub const affineFlipX` | no | no |
| `Affine::new` | `accesskit/src/geometry.rs:53` | Wraps six coefficients | `pub fn affineNew(c: [6]f64) Affine` | no | no |
| `Affine::scale` | `accesskit/src/geometry.rs:59` | Uniform scale | `pub fn affineScale(s: f64) Affine` | no | no |
| `Affine::scale_non_uniform` | `accesskit/src/geometry.rs:66` | Per-axis scale | `pub fn affineScaleNonUniform(s_x: f64, s_y: f64) Affine` | no | no |
| `Affine::translate` | `accesskit/src/geometry.rs:72` | Translation | `pub fn affineTranslate(p: Vec2) Affine` | no | no |
| `Affine::map_unit_square` | `accesskit/src/geometry.rs:81` | Unit square to a rectangle | `pub fn affineMapUnitSquare(rect: Rect) Affine` | no | no |
| `Affine::as_coeffs` | `accesskit/src/geometry.rs:87` | Reads the six coefficients | `pub fn coeffs(self: Affine) [6]f64` | no | no |
| `Affine::determinant` | `accesskit/src/geometry.rs:92` | `a*d - c*b` | `pub fn determinant(self: Affine) f64` | no | no |
| `Affine::inverse` | `accesskit/src/geometry.rs:99` | Inverse, NaN when singular | `pub fn inverse(self: Affine) Affine` | no | no |
| `Affine::transform_rect_bbox` | `accesskit/src/geometry.rs:118` | Bounding box of a transformed rectangle | `pub fn transformRectBbox(self: Affine, rect: Rect) Rect` | no | no |
| `Affine::is_finite` | `accesskit/src/geometry.rs:128` | All six coefficients finite | `pub fn isFinite(self: Affine) bool` | no | no |
| `Affine::is_nan` | `accesskit/src/geometry.rs:139` | Any coefficient is NaN | `pub fn isNan(self: Affine) bool` | no | no |
| `impl Mul<Point> for Affine` | `accesskit/src/geometry.rs:156` | Applies the transform to a point | `pub fn applyToPoint(self: Affine, other: Point) Point` | no | no |
| `impl Mul for Affine` | `accesskit/src/geometry.rs:168` | Composes two transforms | `pub fn mul(self: Affine, other: Affine) Affine` | no | no |
| `impl MulAssign for Affine` | `accesskit/src/geometry.rs:184` | In-place composition | `pub fn mulAssign(self: *Affine, other: Affine) void` | no | no |
| `impl Mul<Affine> for f64` | `accesskit/src/geometry.rs:191` | Scales a transform | `pub fn mulScalar(self: f64, other: Affine) Affine` | no | no |

Rule Z2 would name the multiplication operator `mulAffine` or `mul`. Because
`Affine * Point` and `Affine * Affine` and `f64 * Affine` all come from the same Rust
operator, the port gives each a distinct verb name. `applyToPoint`, `mul`, and
`mulScalar` are three names for three things, which rule Z6 requires.

`Affine::translate` takes `impl Into<Vec2>` in Rust (`accesskit/src/geometry.rs:72`).
Rule Z8 replaces it with `Vec2`, so `Point` and `Size` no longer convert silently.

#### `Point`

| Rust symbol | `path:line` | What it does | Zig counterpart |
|---|---|---|---|
| `Point::ZERO` | `accesskit/src/geometry.rs:221` | `(0, 0)` | deleted, same as `pointOrigin` |
| `Point::ORIGIN` | `accesskit/src/geometry.rs:224` | `(0, 0)` | `pub const pointOrigin` |
| `Point::new` | `accesskit/src/geometry.rs:228` | Builds a point | `pub fn pointInit(x: f64, y: f64) Point` |
| `Point::to_vec2` | `accesskit/src/geometry.rs:234` | Reinterprets as a vector | `pub fn toVec2(self: Point) Vec2` |
| `impl Add<Vec2> for Point` | `accesskit/src/geometry.rs:253` | Translation | `pub fn addVec2(self: Point, other: Vec2) Point` |
| `impl Sub<Vec2> for Point` | `accesskit/src/geometry.rs:269` | Opposite translation | `pub fn subVec2(self: Point, other: Vec2) Point` |
| `impl Sub<Point> for Point` | `accesskit/src/geometry.rs:317` | Difference | `pub fn subPoint(self: Point, other: Point) Point` |
| `impl From<(f64,f64)>` | `accesskit/src/geometry.rs:239` | Tuple conversion | deleted, no tuples in Zig |
| `impl Into<(f64,f64)>` | `accesskit/src/geometry.rs:246` | Tuple conversion | deleted, no tuples in Zig |
| `impl fmt::Debug` | `accesskit/src/geometry.rs:326` | Prints `Point { x: 1.0, y: 2.0 }` | `pub fn format(self: Point, writer: *std.Io.Writer) std.Io.Writer.Error!void` |

The four `AddAssign`, `SubAssign`, and `Add<(f64,f64)>` variants at
`accesskit/src/geometry.rs:262`, `:285`, `:294`, `:308` are deleted. The port has one
`addVec2` and one `subVec2`, and the caller assigns the result.

#### `Rect`

| Rust symbol | `path:line` | What it does | Zig counterpart |
|---|---|---|---|
| `Rect::ZERO` | `accesskit/src/geometry.rs:399` | Empty rectangle at the origin | `pub const rectZero` |
| `Rect::new` | `accesskit/src/geometry.rs:403` | From min and max coordinates | `pub fn rectInit(x0: f64, y0: f64, x1: f64, y1: f64) Rect` |
| `Rect::from_points` | `accesskit/src/geometry.rs:411` | From two points, absolute extents | `pub fn rectFromPoints(p0: Point, p1: Point) Rect` |
| `Rect::from_origin_size` | `accesskit/src/geometry.rs:421` | From origin and size | `pub fn rectFromOriginSize(origin: Point, size: Size) Rect` |
| `Rect::with_origin` | `accesskit/src/geometry.rs:428` | Same size, new origin | `pub fn withOrigin(self: Rect, origin: Point) Rect` |
| `Rect::with_size` | `accesskit/src/geometry.rs:434` | Same origin, new size | `pub fn withSize(self: Rect, size: Size) Rect` |
| `Rect::width` | `accesskit/src/geometry.rs:442` | `x1 - x0` | `pub fn width(self: Rect) f64` |
| `Rect::height` | `accesskit/src/geometry.rs:450` | `y1 - y0` | `pub fn height(self: Rect) f64` |
| `Rect::min_x` | `accesskit/src/geometry.rs:456` | Smaller x | `pub fn minX(self: Rect) f64` |
| `Rect::max_x` | `accesskit/src/geometry.rs:462` | Larger x | `pub fn maxX(self: Rect) f64` |
| `Rect::min_y` | `accesskit/src/geometry.rs:468` | Smaller y | `pub fn minY(self: Rect) f64` |
| `Rect::max_y` | `accesskit/src/geometry.rs:474` | Larger y | `pub fn maxY(self: Rect) f64` |
| `Rect::origin` | `accesskit/src/geometry.rs:483` | `(x0, y0)` | `pub fn origin(self: Rect) Point` |
| `Rect::size` | `accesskit/src/geometry.rs:489` | Width and height | `pub fn rectSize(self: Rect) Size` |
| `Rect::abs` | `accesskit/src/geometry.rs:498` | Non-negative extents | `pub fn abs(self: Rect) Rect` |
| `Rect::area` | `accesskit/src/geometry.rs:505` | Width times height | `pub fn area(self: Rect) f64` |
| `Rect::is_empty` | `accesskit/src/geometry.rs:513` | Area is exactly zero | `pub fn isEmpty(self: Rect) bool` |
| `Rect::contains` | `accesskit/src/geometry.rs:519` | Half-open containment test | `pub fn contains(self: Rect, point: Point) bool` |
| `Rect::union` | `accesskit/src/geometry.rs:527` | Smallest enclosing rectangle | `pub fn unionRect(self: Rect, other: Rect) Rect` |
| `Rect::union_pt` | `accesskit/src/geometry.rs:543` | Enclosing rectangle with one point | `pub fn unionPoint(self: Rect, pt: Point) Rect` |
| `Rect::intersect` | `accesskit/src/geometry.rs:557` | Intersection, clamped to non-negative | `pub fn intersect(self: Rect, other: Rect) Rect` |
| `impl From<(Point,Point)>` | `accesskit/src/geometry.rs:348` | Tuple conversion | deleted |
| `impl From<(Point,Size)>` | `accesskit/src/geometry.rs:354` | Tuple conversion | deleted |
| `impl Add<Vec2> for Rect` | `accesskit/src/geometry.rs:360` | Translation | `pub fn addVec2(self: Rect, v: Vec2) Rect` |
| `impl Sub<Vec2> for Rect` | `accesskit/src/geometry.rs:369` | Opposite translation | `pub fn subVec2(self: Rect, v: Vec2) Rect` |
| `impl fmt::Debug` | `accesskit/src/geometry.rs:378` | Prints both forms | `pub fn format(self: Rect, writer: *std.Io.Writer) std.Io.Writer.Error!void` |

`Rect::size` becomes `rectSize`, because `Node` already has a `size` method for the rect
property and two names for one concept breaks rule Z6. The port can also drop
`Rect::rectInit` in favour of a struct literal, since Zig has named-field literals.
`docs/30-port-design.md` decides.

#### `Size`

| Rust symbol | `path:line` | What it does | Zig counterpart |
|---|---|---|---|
| `Size::ZERO` | `accesskit/src/geometry.rs:580` | Zero size | `pub const sizeZero` |
| `Size::new` | `accesskit/src/geometry.rs:584` | Builds a size | `pub fn sizeInit(width: f64, height: f64) Size` |
| `Size::to_vec2` | `accesskit/src/geometry.rs:591` | Reinterprets as a vector | `pub fn toVec2(self: Size) Vec2` |
| `impl MulAssign<f64>` | `accesskit/src/geometry.rs:602` | Scales in place | `pub fn mulScalarAssign(self: *Size, scalar: f64) void` |
| `impl Mul<Size> for f64` | `accesskit/src/geometry.rs:612` | Scales | `pub fn mulScalar(self: f64, other: Size) Size` |
| `impl Mul<f64> for Size` | `accesskit/src/geometry.rs:621` | Scales | `pub fn mul(self: Size, scalar: f64) Size` |
| `impl DivAssign<f64>` | `accesskit/src/geometry.rs:633` | Divides in place | `pub fn divScalarAssign(self: *Size, scalar: f64) void` |
| `impl Div<f64> for Size` | `accesskit/src/geometry.rs:643` | Divides | `pub fn div(self: Size, scalar: f64) Size` |
| `impl Add<Size> for Size` | `accesskit/src/geometry.rs:655` | Component-wise add | `pub fn add(self: Size, other: Size) Size` |
| `impl AddAssign<Size>` | `accesskit/src/geometry.rs:666` | In-place add | `pub fn addAssign(self: *Size, other: Size) void` |
| `impl Sub<Size> for Size` | `accesskit/src/geometry.rs:673` | Component-wise subtract | `pub fn sub(self: Size, other: Size) Size` |
| `impl SubAssign<Size>` | `accesskit/src/geometry.rs:684` | In-place subtract | `pub fn subAssign(self: *Size, other: Size) void` |
| `impl From<(f64,f64)>` | `accesskit/src/geometry.rs:691` | Tuple conversion | deleted |
| `impl fmt::Debug` | `accesskit/src/geometry.rs:596` | Prints `1.0W×2.0H` | `pub fn format(self: Size, writer: *std.Io.Writer) std.Io.Writer.Error!void` |

Rust has both `f64 * Size` and `Size * f64`. The port keeps only `Size.mulScalar`, because
the two forms differ only in argument order and the callers in the codebase always write
the same order. `[INFERENCE]` `docs/30-port-design.md` must confirm no caller needs the
other order.

#### `Vec2`

`Vec2` has the same operator set as `Size` at `accesskit/src/geometry.rs:708-866`, plus
`Neg` at `:856`. The Zig counterparts follow the same naming:
`vec2Zero` for `ZERO` at `:726`, `vec2Init` for `new` at `:730`, `toPoint` for `to_point`
at `:736`, `toSize` for `to_size` at `:742`, `add`, `addAssign`, `sub`, `subAssign`,
`mulScalar`, `mulScalarAssign`, `mulScalarReverse` for `Mul<Vec2> for f64` at `:827`,
`divScalar`, `divScalarAssign`, and `negate` for `Neg` at `:856`. The two tuple conversions
at `:747` and `:754` are deleted.

### 3.7 `accesskit_consumer`: `tree.rs`

#### `TreeState`

| Rust symbol | `path:line` | What it does | Zig counterpart | Extra parameter |
|---|---|---|---|---|
| `TreeState::validate_global` | `accesskit_consumer/src/tree.rs:86` | Panics unless root and focus exist | `fn validateGlobal(self: *const TreeState) UpdateError!void` | error set |
| `TreeState::compute_effective_focus` | `accesskit_consumer/src/tree.rs:101` | Follows the graft chain from `TreeId::ROOT` | `fn computeEffectiveFocus(self: *const TreeState) UpdateError!FullNodeId` | error set |
| `TreeState::update` | `accesskit_consumer/src/tree.rs:124` | The whole update application algorithm | `pub fn update(self: *TreeState, update: TreeUpdate, changes: ?*InternalChanges) UpdateError!void` | error set |
| `TreeState::has_node` | `accesskit_consumer/src/tree.rs:488` | Membership test | `pub fn hasNode(self: *const TreeState, id: FullNodeId) bool` | none |
| `TreeState::node_by_id` | `accesskit_consumer/src/tree.rs:492` | Borrows one node | `pub fn nodeById(self: *const TreeState, id: FullNodeId) ?NodeRef` | none |
| `TreeState::node_by_tree_local_id` | `accesskit_consumer/src/tree.rs:500` | Looks up by local id and tree id | `pub fn nodeByTreeLocalId(self: *const TreeState, local_node_id: NodeId, tree_id: TreeId) ?NodeRef` | none |
| `TreeState::root_id` | `accesskit_consumer/src/tree.rs:509` | Root node id | `pub fn rootId(self: *const TreeState) FullNodeId` | none |
| `TreeState::root` | `accesskit_consumer/src/tree.rs:513` | Borrows the root node | `pub fn root(self: *const TreeState) NodeRef` | none |
| `TreeState::subtree_root` | `accesskit_consumer/src/tree.rs:518` | Root of a subtree, if it exists | `pub fn subtreeRoot(self: *const TreeState, tree_id: TreeId) ?FullNodeId` | none |
| `TreeState::is_host_focused` | `accesskit_consumer/src/tree.rs:522` | Host window focus flag | `pub fn isHostFocused(self: *const TreeState) bool` | none |
| `TreeState::focus_id_in_tree` | `accesskit_consumer/src/tree.rs:526` | Focus id ignoring host focus | `pub fn focusIdInTree(self: *const TreeState) FullNodeId` | none |
| `TreeState::focus_in_tree` | `accesskit_consumer/src/tree.rs:530` | Focus node ignoring host focus | `pub fn focusInTree(self: *const TreeState) NodeRef` | none |
| `TreeState::focus_id` | `accesskit_consumer/src/tree.rs:534` | Focus id, or null when the host is unfocused | `pub fn focusId(self: *const TreeState) ?FullNodeId` | none |
| `TreeState::focus` | `accesskit_consumer/src/tree.rs:538` | Focus node, resolved through `active_descendant` | `pub fn focus(self: *const TreeState) ?NodeRef` | none |
| `TreeState::active_dialog` | `accesskit_consumer/src/tree.rs:545` | Nearest dialog ancestor of the focus | `pub fn activeDialog(self: *const TreeState) ?NodeRef` | none |
| `TreeState::toolkit_name` | `accesskit_consumer/src/tree.rs:556` | Toolkit name, or `AccessKit` | `pub fn toolkitName(self: *const TreeState) []const u8` | none |
| `TreeState::toolkit_version` | `accesskit_consumer/src/tree.rs:560` | Toolkit version, only when the name is set | `pub fn toolkitVersion(self: *const TreeState) ?[]const u8` | none |
| `TreeState::locate_node` | `accesskit_consumer/src/tree.rs:567` | Splits a `FullNodeId` into local id and tree id | `pub fn locateNode(self: *const TreeState, node_id: FullNodeId) ?struct { local_id: NodeId, tree_id: TreeId }` | none |

Five public `Tree` operations return `UpdateError`.
They are `init`, `initBorrowed`, `updateAndProcessChanges`, `updateBorrowedAndProcessChanges`, and `updateHostFocusStateAndProcessChanges`.
The contract lists the owned calls and `UpdateError` (`docs/33-consumer-interface-contract.md:256,264,266,537`). The Zig definitions are `src/consumer/tree.zig:290-311,413-435,462-476` at owner revision `f3be8aa12fb1d210d1a4cf33139dfa25d517e7de`.
The Rust paths are pinned to AccessKit revision `466e24e252103f4d82bd6fbab98141b551e46e0c`: `accesskit_consumer/src/tree.rs:592-618,620-628,630-638`. Borrowed Zig calls reuse the constructor and update algorithms.

#### `ChangeHandler` and `Tree`

| Rust symbol | `path:line` | What it does | Zig counterpart |
|---|---|---|---|
| `ChangeHandler::node_added` | `accesskit_consumer/src/tree.rs:579` | A node entered the tree | `nodeAdded: *const fn (context: ?*anyopaque, node: NodeRef) void` |
| `ChangeHandler::node_updated` | `accesskit_consumer/src/tree.rs:580` | A node's data changed | `nodeUpdated: *const fn (context: ?*anyopaque, old_node: NodeRef, new_node: NodeRef) void` |
| `ChangeHandler::focus_moved` | `accesskit_consumer/src/tree.rs:581` | The focused node changed | `focusMoved: *const fn (context: ?*anyopaque, old_node: ?NodeRef, new_node: ?NodeRef) void` |
| `ChangeHandler::node_removed` | `accesskit_consumer/src/tree.rs:582` | A node left the tree | `nodeRemoved: *const fn (context: ?*anyopaque, node: NodeRef) void` |
| `Tree::new` | `accesskit_consumer/src/tree.rs:592` | Builds from the first full update | `pub fn init(gpa: std.mem.Allocator, initial_state: TreeUpdate, is_host_focused: bool) std.mem.Allocator.Error!Tree` |
| `Tree::update_and_process_changes` | `accesskit_consumer/src/tree.rs:620` | Applies an update and calls the handler | `pub fn updateAndProcessChanges(self: *Tree, update: TreeUpdate, handler: *ChangeHandler) UpdateError!void` |
| `Tree::update_host_focus_state_and_process_changes` | `accesskit_consumer/src/tree.rs:630` | Sets the host focus flag and calls the handler | `pub fn updateHostFocusStateAndProcessChanges(self: *Tree, is_host_focused: bool, handler: *ChangeHandler) UpdateError!void` |
| `Tree::process_changes` | `accesskit_consumer/src/tree.rs:640` | Emits the change callbacks, then commits | `fn processChanges(self: *Tree, changes: InternalChanges, handler: *ChangeHandler) void` |
| `Tree::state` | `accesskit_consumer/src/tree.rs:708` | Borrows the committed state | `pub fn state(self: *const Tree) *const TreeState` |

`Tree::new` takes `gpa` because it builds three hash maps and a cloned tree state. Rust
gets the allocator from the global. `Tree::new` also panics twice in Rust
(`accesskit_consumer/src/tree.rs:593-600`). Both become
`error.InitialUpdateMissingTreeData` and `error.InitialUpdateForSubtree`, in `UpdateError`.

`Tree::state` returns a borrow in Rust. Zig returns `*const TreeState`, which is the same
thing.

#### `TreeIndexMap` and the nested helpers

| Rust symbol | `path:line` | What it does | Zig counterpart | Extra parameter |
|---|---|---|---|---|
| `TreeIndexMap::get_or_create_index` | `accesskit_consumer/src/tree.rs:41` | Assigns the next sequential index to a tree id | `fn getOrCreateIndex(gpa, self: *TreeIndexMap, id: TreeId) std.mem.Allocator.Error!TreeIndex` | `gpa`, `!` |
| `TreeIndexMap::get_index` | `accesskit_consumer/src/tree.rs:50` | Reads the index for a tree id | `fn getIndex(self: *const TreeIndexMap, id: TreeId) ?TreeIndex` | none |
| `TreeIndexMap::get_id` | `accesskit_consumer/src/tree.rs:54` | Reads the tree id for an index | `fn getId(self: *const TreeIndexMap, index: TreeIndex) ?TreeId` | none |
| `record_graft` | `accesskit_consumer/src/tree.rs:182` | Records a graft node, rejecting duplicates | `fn recordGraft(pending_grafts: *TreeIdMap, subtree_id: TreeId, graft_node_id: FullNodeId) UpdateError!void` | error set |
| `add_node` | `accesskit_consumer/src/tree.rs:201` | Inserts one node and records the change | `fn addNode(gpa, nodes: *NodeMap, pending_grafts: *TreeIdMap, changes: ?*InternalChanges, parent_and_index: ?ParentAndIndex, id: FullNodeId, data: Node) std.mem.Allocator.Error!UpdateError!void` | `gpa`, `!` |
| `traverse_unreachable` | `accesskit_consumer/src/tree.rs:354` | Removes a node and its unreferenced descendants | `fn traverseUnreachable(gpa, nodes: *NodeMap, grafts_to_remove: *TreeIdSet, changes: ?*InternalChanges, seen_child_ids: *const TreeIdSet, new_tree_root: ?FullNodeId, root: FullNodeId) std.mem.Allocator.Error!void` | `gpa`, `!` |
| `traverse_subtree` | `accesskit_consumer/src/tree.rs:395` | Removes a whole subtree and queues nested subtrees | `fn traverseSubtree(gpa, nodes: *NodeMap, subtrees_to_remove: *std.ArrayList(TreeId), subtrees_queued: *TreeIdSet, changes: ?*InternalChanges, root: FullNodeId) std.mem.Allocator.Error!void` | `gpa`, `!` |
| `ShortNodeList` | `accesskit_consumer/src/tree.rs:713` | Prints at most ten ids in a panic message | `fn formatShortNodeList(writer: *std.Io.Writer, items: anytype) std.Io.Writer.Error!void` | none |

Both traversals use an explicit stack, `vec![root]`, then `stack.pop()`
(`accesskit_consumer/src/tree.rs:362-363`, `:402-403`). The port keeps that. The stack is
heap, so it takes `gpa`. See section 8.6 for the fixed-upper-bound rule and its conflict
with this loop.

### 3.8 `accesskit_consumer`: `node.rs`

| Rust symbol | `path:line` | What it does | Zig counterpart | Extra parameter |
|---|---|---|---|---|
| `FullNodeId::new` | `accesskit_consumer/src/node.rs:33` | Pairs a local id with a tree index | `pub fn init(local_id: NodeId, tree_index: TreeIndex) FullNodeId` | none |
| `FullNodeId::with_same_tree` | `accesskit_consumer/src/node.rs:37` | Replaces the local id, keeps the tree | `pub fn withSameTree(self: FullNodeId, local_id: NodeId) FullNodeId` | none |
| `FullNodeId::to_components` | `accesskit_consumer/src/node.rs:41` | Splits into local id and tree index | `pub fn toComponents(self: FullNodeId) struct { local_id: NodeId, tree_index: TreeIndex }` | none |
| `NodeRef::data` | `accesskit_consumer/src/node.rs:85` | Borrows the raw node | `pub fn data(self: NodeRef) *const Node` | none |
| `NodeRef::is_focused` | `accesskit_consumer/src/node.rs:89` | Focus, following the active descendant chain | `pub fn isFocused(self: NodeRef) bool` | none |
| `NodeRef::is_focused_in_tree` | `accesskit_consumer/src/node.rs:107` | Equals the tree focus id | `pub fn isFocusedInTree(self: NodeRef) bool` | none |
| `NodeRef::is_focusable` | `accesskit_consumer/src/node.rs:111` | Supports focus, or already focused | `pub fn isFocusable(self: NodeRef, parent_filter: FilterFn) bool` | filter |
| `NodeRef::is_root` | `accesskit_consumer/src/node.rs:115` | Equals the root id | `pub fn isRoot(self: NodeRef) bool` | none |
| `NodeRef::is_graft` | `accesskit_consumer/src/node.rs:122` | Has a `tree_id` property | `pub fn isGraft(self: NodeRef) bool` | none |
| `NodeRef::parent_id` | `accesskit_consumer/src/node.rs:126` | Parent node id | `pub fn parentId(self: NodeRef) ?FullNodeId` | none |
| `NodeRef::parent` | `accesskit_consumer/src/node.rs:133` | Parent node | `pub fn parent(self: NodeRef) ?NodeRef` | none |
| `NodeRef::filtered_parent` | `accesskit_consumer/src/node.rs:138` | Nearest ancestor the filter includes | `pub fn filteredParent(self: NodeRef, filter: FilterFn) ?NodeRef` | filter |
| `NodeRef::parent_and_index` | `accesskit_consumer/src/node.rs:151` | Parent and child index | `pub fn parentAndIndex(self: NodeRef) ?struct { parent: NodeRef, index: usize }` | none |
| `NodeRef::child_ids` | `accesskit_consumer/src/node.rs:168` | Iterates child ids | `pub fn childIds(self: NodeRef) ChildIdsIterator` | none |
| `NodeRef::children` | `accesskit_consumer/src/node.rs:181` | Iterates child nodes | `pub fn children(self: NodeRef) ChildrenIterator` | none |
| `NodeRef::filtered_children` | `accesskit_consumer/src/node.rs:189` | Iterates children the filter includes | `pub fn filteredChildren(self: NodeRef, filter: FilterFn) FilteredChildrenIterator` | filter |
| `NodeRef::following_sibling_ids` | `accesskit_consumer/src/node.rs:196` | Iterates later sibling ids | `pub fn followingSiblingIds(self: NodeRef) FollowingSiblingsIterator` | none |
| `NodeRef::following_siblings` | `accesskit_consumer/src/node.rs:202` | Iterates later siblings | `pub fn followingSiblings(self: NodeRef) FollowingSiblingsIterator` | none |
| `NodeRef::preceding_sibling_ids` | `accesskit_consumer/src/node.rs:217` | Iterates earlier sibling ids | `pub fn precedingSiblingIds(self: NodeRef) PrecedingSiblingsIterator` | none |
| `NodeRef::preceding_siblings` | `accesskit_consumer/src/node.rs:223` | Iterates earlier siblings | `pub fn precedingSiblings(self: NodeRef) PrecedingSiblingsIterator` | none |
| `NodeRef::deepest_first_child` | `accesskit_consumer/src/node.rs:238` | First-child chain to the leaf | `pub fn deepestFirstChild(self: NodeRef) ?NodeRef` | none |
| `NodeRef::deepest_last_child` | `accesskit_consumer/src/node.rs:257` | Last-child chain to the leaf | `pub fn deepestLastChild(self: NodeRef) ?NodeRef` | none |
| `NodeRef::is_descendant_of` | `accesskit_consumer/src/node.rs:276` | Walks up to test ancestry | `pub fn isDescendantOf(self: NodeRef, ancestor: NodeRef) bool` | none |
| `NodeRef::direct_transform` | `accesskit_consumer/src/node.rs:291` | This node's own transform | `pub fn directTransform(self: NodeRef) Affine` | none |
| `NodeRef::transform` | `accesskit_consumer/src/node.rs:299` | Composed transform up to the tree root | `pub fn transform(self: NodeRef) Affine` | none |
| `NodeRef::relative_transform` | `accesskit_consumer/src/node.rs:309` | Composed transform up to a given ancestor | `pub fn relativeTransform(self: NodeRef, stop_at: NodeRef) Affine` | none |
| `NodeRef::raw_bounds` | `accesskit_consumer/src/node.rs:322` | The `bounds` property, untransformed | `pub fn rawBounds(self: NodeRef) ?Rect` | none |
| `NodeRef::has_bounds` | `accesskit_consumer/src/node.rs:326` | Whether `bounds` is set | `pub fn hasBounds(self: NodeRef) bool` | none |
| `NodeRef::bounding_box` | `accesskit_consumer/src/node.rs:332` | Bounds after the composed transform | `pub fn boundingBox(self: NodeRef) ?Rect` | none |
| `NodeRef::hit_test` | `accesskit_consumer/src/node.rs:344` | Deepest node at a point | `pub fn hitTest(self: NodeRef, point: Point, filter: FilterFn) ?NodeRef` | filter |
| `NodeRef::node_at_point` | `accesskit_consumer/src/node.rs:389` | Shallowest node at a point | `pub fn nodeAtPoint(self: NodeRef, point: Point, filter: FilterFn) ?NodeRef` | filter |
| `NodeRef::id` | `accesskit_consumer/src/node.rs:397` | The node id | `pub fn id(self: NodeRef) FullNodeId` | none |
| `NodeRef::locate` | `accesskit_consumer/src/node.rs:401` | Local id and tree id | `pub fn locate(self: NodeRef) struct { local_id: NodeId, tree_id: TreeId }` | none |
| `NodeRef::role` | `accesskit_consumer/src/node.rs:405` | The role | `pub fn role(self: NodeRef) Role` | none |
| `NodeRef::fetch_inherited_property` | `accesskit_consumer/src/node.rs:534` | Walks up until a property is set | `pub fn fetchInheritedProperty(self: NodeRef, getter: InheritedGetter) ?T` | none |
| `NodeRef::fetch_inherited_flag` | `accesskit_consumer/src/node.rs:548` | Walks up until a flag is set | `pub fn fetchInheritedFlag(self: NodeRef, getter: InheritedFlagGetter) bool` | none |
| `NodeRef::labelled_by` | `accesskit_consumer/src/node.rs:719` | Labelling nodes, explicit or from descendants | `pub fn labelledBy(self: NodeRef) LabelledByIterator` | none |
| `NodeRef::label` | `accesskit_consumer/src/node.rs:748` | The computed label, allocated | `pub fn label(gpa, self: NodeRef) std.mem.Allocator.Error!?std.ArrayList(u8)` | `gpa`, `!` |
| `NodeRef::write_label` | `accesskit_consumer/src/node.rs:775` | The computed label, streamed | `pub fn writeLabel(self: NodeRef, writer: *std.Io.Writer) std.Io.Writer.Error!bool` | none |
| `NodeRef::description` | `accesskit_consumer/src/node.rs:796` | The description property, allocated | `pub fn description(gpa, self: NodeRef) std.mem.Allocator.Error!?std.ArrayList(u8)` | `gpa`, `!` |
| `NodeRef::value` | `accesskit_consumer/src/node.rs:840` | The computed value, allocated | `pub fn value(gpa, self: NodeRef) std.mem.Allocator.Error!?std.ArrayList(u8)` | `gpa`, `!` |
| `NodeRef::write_value` | `accesskit_consumer/src/node.rs:845` | The computed value, streamed | `pub fn writeValue(self: NodeRef, writer: *std.Io.Writer) std.Io.Writer.Error!bool` | none |
| `NodeRef::index_path` | `accesskit_consumer/src/node.rs:997` | Child indices from the root, allocated | `pub fn indexPath(gpa, self: NodeRef) std.mem.Allocator.Error!std.ArrayList(usize)` | `gpa`, `!` |
| `NodeRef::relative_index_path` | `accesskit_consumer/src/node.rs:1001` | Child indices from an ancestor, allocated | `pub fn relativeIndexPath(gpa, self: NodeRef, ancestor_id: FullNodeId) std.mem.Allocator.Error!std.ArrayList(usize)` | `gpa`, `!` |
| `NodeRef::text_runs` | `accesskit_consumer/src/text.rs:1381` | Descendant `TextRun` nodes | `pub fn textRuns(self: NodeRef) FilteredChildrenIterator` | none |
| `NodeRef::supports_text_ranges` | `accesskit_consumer/src/text.rs:1402` | Role allows text and at least one run exists | `pub fn supportsTextRanges(self: NodeRef) bool` | none |
| `NodeRef::document_start` | `accesskit_consumer/src/text.rs:1416` | First position in the document | `pub fn documentStart(self: NodeRef) Position` | none |
| `NodeRef::document_end` | `accesskit_consumer/src/text.rs:1431` | Last position in the document | `pub fn documentEnd(self: NodeRef) Position` | none |
| `NodeRef::document_range` | `accesskit_consumer/src/text.rs:1438` | The whole document as a range | `pub fn documentRange(self: NodeRef) Range` | none |
| `NodeRef::text_selection` | `accesskit_consumer/src/text.rs:1448` | The selection as a range | `pub fn textSelection(self: NodeRef) ?Range` | none |
| `NodeRef::text_selection_anchor` | `accesskit_consumer/src/text.rs:1459` | The selection anchor | `pub fn textSelectionAnchor(self: NodeRef) ?Position` | none |
| `NodeRef::text_selection_focus` | `accesskit_consumer/src/text.rs:1471` | The selection focus | `pub fn textSelectionFocus(self: NodeRef) ?Position` | none |
| `NodeRef::text_position_at_point` | `accesskit_consumer/src/text.rs:1485` | The position nearest a point | `pub fn textPositionAtPoint(self: NodeRef, point: Point) Position` | none |
| `NodeRef::line_range_from_index` | `accesskit_consumer/src/text.rs:1548` | The range of line number `line_index` | `pub fn lineRangeFromIndex(self: NodeRef, line_index: usize) ?Range` | none |
| `NodeRef::text_position_from_global_usv_index` | `accesskit_consumer/src/text.rs:1571` | Position for a Unicode scalar index | `pub fn textPositionFromGlobalUsvIndex(self: NodeRef, index: usize) ?Position` | none |
| `NodeRef::text_position_from_global_utf16_index` | `accesskit_consumer/src/text.rs:1610` | Position for a UTF-16 code unit index | `pub fn textPositionFromGlobalUtf16Index(self: NodeRef, index: usize) ?Position` | none |

`FilterFn` is `*const fn (node: NodeRef) FilterResult`. Rust passes
`&impl Fn(&NodeRef) -> FilterResult` (`accesskit_consumer/src/node.rs:111`). The port uses
a plain function pointer, which removes the generic and the closure environment. The
filters that need per-call state take it through a `context: ?*anyopaque` field in a
`FilterContext` struct. `[INFERENCE]` `docs/30-port-design.md` must confirm no filter needs
captured state. The two call sites at `accesskit_consumer/src/filters.rs:65` and
`:76-81` pass plain functions, so the port can start there.

`fetch_inherited_property` takes a function pointer in Rust
(`getter: fn(&'a Node) -> Option<T>`). The port makes it a generic on `T` with a comptime
function-pointer type, so the return stays `?T` with no boxing. Zig generics are
monomorphised, so this costs nothing at run time.

The remaining 78 `NodeRef` methods in `node.rs` are one-line forwards to `Node`
properties. They are listed as one group rather than 78 rows, because each maps to a
section 3.3 accessor with no extra parameter:

* `role_description` at `:409`, `has_role_description` at `:413`, `has_braille_label` at
  `:437`, `has_braille_role_description` at `:445`, `has_html_id` at `:989`,
  `is_empty_text_input` at `:821` private.
* `is_live_atomic` at `:417`, `is_busy` at `:421`, `is_hidden` at `:457`,
  `is_disabled` at `:465`, `is_read_only` at `:469`, `is_multiselectable` at `:625`,
  `is_modal` at `:603`, `clips_children` at `:506`, `is_touch_transparent` at `:916`,
  `is_required` at `:902`. Each Zig name is the camelCase form by rule Z2.
* `level` at `:461`, `toggled` at `:482`, `numeric_value` at `:486`,
  `min_numeric_value` at `:490`, `max_numeric_value` at `:494`,
  `numeric_value_step` at `:498`, `numeric_value_jump` at `:502`, `scroll_x` at `:510`,
  `scroll_x_min` at `:514`, `scroll_x_max` at `:518`, `scroll_y` at `:522`,
  `scroll_y_min` at `:526`, `scroll_y_max` at `:530`, `size_of_set` at `:643`,
  `position_in_set` at `:648`, `sort_direction` at `:653`.
* `braille_label` at `:433`, `braille_role_description` at `:441`,
  `column_index_text` at `:425`, `row_index_text` at `:429`, `aria_current` at `:449`,
  `has_popup` at `:453`, `author_id` at `:981`, `class_name` at `:993`, `html_id` at
  `:985`, `url` at `:806`, `placeholder` at `:834`, `raw_value` at `:977`,
  `raw_text_selection` at `:973`.
* Derived predicates that combine several properties: `is_text_input` at `:562`,
  `is_multiline` at `:583`, `orientation` at `:587`, `is_dialog` at `:599`,
  `is_selectable` at `:620`, `supports_toggle` at `:657`,
  `supports_expand_collapse` at `:661`, `is_invocable` at `:670`,
  `is_clickable` at `:616`, `is_item_like` at `:920`,
  `is_container_with_selectable_children` at `:938`, `supports_increment` at `:701`,
  `supports_decrement` at `:705`, `label_comes_from_value` at `:744`,
  `has_label` at `:753`, `has_value` at `:857`, `has_description` at `:802`,
  `supports_url` at `:810`, `is_read_only_supported` at `:861`,
  `should_have_read_only_state_by_default` at `:881`, `is_read_only_or_disabled` at
  `:478`, `live` at `:906`, `is_selected` at `:912`, `supports_action` at `:687`.

The derived predicates take no extra parameter. `supports_action`, `is_invocable`,
`is_clickable`, `is_focusable`, `size_of_set_from_container`, `selection_container`,
`items`, `is_focusable`, and `supports_increment` all take a `FilterFn`, because
`supports_action` recurses through `parent()` and consults the filter at
`accesskit_consumer/src/node.rs:687-699`.

### 3.9 `accesskit_consumer`: `text.rs`

| Rust symbol | `path:line` | What it does | Zig counterpart | Extra parameter |
|---|---|---|---|---|
| `Position::to_raw` | `accesskit_consumer/src/text.rs:167` | Drops the borrow | `pub fn toRaw(self: Position) WeakPosition` | none |
| `Position::inner_node` | `accesskit_consumer/src/text.rs:171` | The `TextRun` node | `pub fn innerNode(self: *const Position) *const NodeRef` | none |
| `Position::is_format_start` | `accesskit_consumer/src/text.rs:175` | At the document start, or at a style change | `pub fn isFormatStart(self: Position) bool` | none |
| `Position::is_word_start` | `accesskit_consumer/src/text.rs:188` | At the paragraph start, or on a word boundary | `pub fn isWordStart(self: Position) bool` | none |
| `Position::is_line_start` | `accesskit_consumer/src/text.rs:199` | Start of a line | `pub fn isLineStart(self: Position) bool` | none |
| `Position::is_line_end` | `accesskit_consumer/src/text.rs:203` | End of a line | `pub fn isLineEnd(self: Position) bool` | none |
| `Position::is_paragraph_start` | `accesskit_consumer/src/text.rs:207` | Start of a paragraph | `pub fn isParagraphStart(self: Position) bool` | none |
| `Position::is_paragraph_end` | `accesskit_consumer/src/text.rs:213` | End of a paragraph | `pub fn isParagraphEnd(self: Position) bool` | none |
| `Position::is_paragraph_separator` | `accesskit_consumer/src/text.rs:217` | Between two paragraphs | `pub fn isParagraphSeparator(self: Position) bool` | none |
| `Position::is_page_start` | `accesskit_consumer/src/text.rs:225` | Document start | `pub fn isPageStart(self: Position) bool` | none |
| `Position::is_document_start` | `accesskit_consumer/src/text.rs:229` | First position | `pub fn isDocumentStart(self: Position) bool` | none |
| `Position::is_document_end` | `accesskit_consumer/src/text.rs:233` | Last position | `pub fn isDocumentEnd(self: Position) bool` | none |
| `Position::to_degenerate_range` | `accesskit_consumer/src/text.rs:237` | Zero-length range | `pub fn toDegenerateRange(self: Position) Range` | none |
| `Position::to_global_usv_index` | `accesskit_consumer/src/text.rs:241` | Index over the whole document in code points | `pub fn toGlobalUsvIndex(self: Position) usize` | none |
| `Position::to_global_utf16_index` | `accesskit_consumer/src/text.rs:259` | Index over the whole document in UTF-16 units | `pub fn toGlobalUtf16Index(self: Position) usize` | none |
| `Position::to_line_index` | `accesskit_consumer/src/text.rs:281` | Zero-based line number | `pub fn toLineIndex(self: Position) usize` | none |
| `Position::biased_to_start` | `accesskit_consumer/src/text.rs:294` | Moves a run-end to the next run's start | `pub fn biasedToStart(self: Position) Position` | none |
| `Position::biased_to_end` | `accesskit_consumer/src/text.rs:301` | Moves a run-start to the previous run's end | `pub fn biasedToEnd(self: Position) Position` | none |
| `Position::forward_to_character_start` | `accesskit_consumer/src/text.rs:308` | Next character boundary | `pub fn forwardToCharacterStart(self: Position) Position` | none |
| `Position::forward_to_character_end` | `accesskit_consumer/src/text.rs:319` | End of the current character | `pub fn forwardToCharacterEnd(self: Position) Position` | none |
| `Position::backward_to_character_start` | `accesskit_consumer/src/text.rs:331` | Start of the current character | `pub fn backwardToCharacterStart(self: Position) Position` | none |
| `Position::forward_to_format_start` | `accesskit_consumer/src/text.rs:343` | Next text-attribute change | `pub fn forwardToFormatStart(self: Position) Position` | none |
| `Position::forward_to_format_end` | `accesskit_consumer/src/text.rs:358` | End of the current format run | `pub fn forwardToFormatEnd(self: Position) Position` | none |
| `Position::backward_to_format_start` | `accesskit_consumer/src/text.rs:362` | Start of the current format run | `pub fn backwardToFormatStart(self: Position) Position` | none |
| `Position::forward_to_word_start` | `accesskit_consumer/src/text.rs:390` | Next word start | `pub fn forwardToWordStart(self: Position) Position` | none |
| `Position::forward_to_word_end` | `accesskit_consumer/src/text.rs:434` | End of the current word | `pub fn forwardToWordEnd(self: Position) Position` | none |
| `Position::backward_to_word_start` | `accesskit_consumer/src/text.rs:438` | Start of the current word | `pub fn backwardToWordStart(self: Position) Position` | none |
| `Position::forward_to_line_start` | `accesskit_consumer/src/text.rs:493` | Next line start | `pub fn forwardToLineStart(self: Position) Position` | none |
| `Position::forward_to_line_end` | `accesskit_consumer/src/text.rs:500` | End of the current line | `pub fn forwardToLineEnd(self: Position) Position` | none |
| `Position::backward_to_line_start` | `accesskit_consumer/src/text.rs:508` | Start of the current line | `pub fn backwardToLineStart(self: Position) Position` | none |
| `Position::forward_to_paragraph_start` | `accesskit_consumer/src/text.rs:516` | Next paragraph start | `pub fn forwardToParagraphStart(self: Position) Position` | none |
| `Position::forward_to_paragraph_end` | `accesskit_consumer/src/text.rs:532` | Next paragraph end | `pub fn forwardToParagraphEnd(self: Position) Position` | none |
| `Position::backward_to_paragraph_start` | `accesskit_consumer/src/text.rs:543` | Start of the current paragraph | `pub fn backwardToParagraphStart(self: Position) Position` | none |
| `Position::forward_to_page_start` | `accesskit_consumer/src/text.rs:554` | Document end | `pub fn forwardToPageStart(self: Position) Position` | none |
| `Position::forward_to_page_end` | `accesskit_consumer/src/text.rs:558` | Document end | `pub fn forwardToPageEnd(self: Position) Position` | none |
| `Position::backward_to_page_start` | `accesskit_consumer/src/text.rs:562` | Document start | `pub fn backwardToPageStart(self: Position) Position` | none |
| `Position::document_end` | `accesskit_consumer/src/text.rs:566` | Document end | `pub fn documentEnd(self: Position) Position` | none |
| `Position::document_start` | `accesskit_consumer/src/text.rs:570` | Document start | `pub fn documentStart(self: Position) Position` | none |
| `Range::node` | `accesskit_consumer/src/text.rs:627` | The node the range is measured against | `pub fn node(self: *const Range) *const NodeRef` | none |
| `Range::start` | `accesskit_consumer/src/text.rs:631` | The start position | `pub fn start(self: Range) Position` | none |
| `Range::end` | `accesskit_consumer/src/text.rs:638` | The end position | `pub fn end(self: Range) Position` | none |
| `Range::is_degenerate` | `accesskit_consumer/src/text.rs:645` | Start equals end | `pub fn isDegenerate(self: Range) bool` | none |
| `Range::traverse_text` | `accesskit_consumer/src/text.rs:680` | Visits every node and text slice in the range | `pub fn traverseText(self: Range, context: ?*anyopaque, visit: *const fn (context: ?*anyopaque, node: NodeRef, text: []const u8) bool) bool` | context, rule Z7 |
| `Range::write_text` | `accesskit_consumer/src/text.rs:719` | Streams the text of the range | `pub fn writeText(self: Range, writer: *std.Io.Writer) std.Io.Writer.Error!void` | none |
| `Range::text` | `accesskit_consumer/src/text.rs:727` | The text of the range, allocated | `pub fn text(gpa, self: Range) std.mem.Allocator.Error!std.ArrayList(u8)` | `gpa`, `!` |
| `Range::bounding_boxes` | `accesskit_consumer/src/text.rs:740` | One rectangle per text run, allocated | `pub fn boundingBoxes(gpa, self: Range) std.mem.Allocator.Error!std.ArrayList(Rect)` | `gpa`, `!` |
| `Range::set_start` | `accesskit_consumer/src/text.rs:848` | Moves the start | `pub fn setStart(self: *Range, pos: Position) void` | none |
| `Range::set_end` | `accesskit_consumer/src/text.rs:859` | Moves the end | `pub fn setEnd(self: *Range, pos: Position) void` | none |
| `Range::to_text_selection` | `accesskit_consumer/src/text.rs:870` | Converts to the core type | `pub fn toTextSelection(self: Range) TextSelection` | none |
| `Range::downgrade` | `accesskit_consumer/src/text.rs:877` | Drops the borrow, keeps comparable indices | `pub fn downgrade(self: Range) WeakRange` | none |
| `RangePropertyValue::map` | `accesskit_consumer/src/text.rs:601` | Maps the single value | `pub fn map(self: RangePropertyValue(?T), f: *const fn (T) U) RangePropertyValue(?U)` | none |
| `WeakRange::node_id` | `accesskit_consumer/src/text.rs:906` | The node id | `pub fn nodeId(self: WeakRange) FullNodeId` | none |
| `WeakRange::start_comparable` | `accesskit_consumer/src/text.rs:910` | Precomputed start ordering key | `pub fn startComparable(self: WeakRange) ComparablePath` | none |
| `WeakRange::end_comparable` | `accesskit_consumer/src/text.rs:914` | Precomputed end ordering key | `pub fn endComparable(self: WeakRange) ComparablePath` | none |
| `WeakRange::upgrade_node` | `accesskit_consumer/src/text.rs:918` | Recovers the node if it still supports ranges | `pub fn upgradeNode(self: WeakRange, tree_state: *const TreeState) ?NodeRef` | none |
| `WeakRange::upgrade` | `accesskit_consumer/src/text.rs:924` | Recovers the range if both endpoints survive | `pub fn upgrade(self: WeakRange, tree_state: *const TreeState) ?Range` | none |
| `InnerPosition::upgrade` | `accesskit_consumer/src/text.rs:22` | Recovers a position, validating role and index | `fn upgrade(tree_state: *const TreeState, weak: WeakPosition, node_id: FullNodeId) ?InnerPosition` | none |
| `InnerPosition::clamped_upgrade` | `accesskit_consumer/src/text.rs:37` | Recovers a position, clamping the index | `fn clampedUpgrade(tree_state: *const TreeState, weak: WeakPosition, node_id: FullNodeId) ?InnerPosition` | none |
| `InnerPosition::downgrade` | `accesskit_consumer/src/text.rs:143` | Drops the borrow | `fn downgrade(self: InnerPosition) WeakPosition` | none |
| `InnerPosition::comparable` | `accesskit_consumer/src/text.rs:107` | Index path plus character index, allocated | `fn comparable(gpa, self: InnerPosition, root_node: NodeRef) std.mem.Allocator.Error!ComparablePath` | `gpa`, `!` |
| `text_node_filter` | `accesskit_consumer/src/text.rs:932` | Includes only the root and `TextRun` nodes | `fn textNodeFilter(root_id: FullNodeId, node: NodeRef) FilterResult` | none |
| `character_index_at_point` | `accesskit_consumer/src/text.rs:940` | Character index for a point inside a run | `fn characterIndexAtPoint(node: NodeRef, point: Point) usize` | none |

`WeakRange.start_comparable` and `end_comparable` return `&(Vec<usize>, usize)` in Rust
(`accesskit_consumer/src/text.rs:910-916`). The port returns a `ComparablePath`, a struct
of `[]const usize` and `usize`, because Zig has no tuples. `InnerPosition::comparable`
needs `gpa` because `relative_index_path` allocates
(`accesskit_consumer/src/node.rs:1001-1010`).

`traverse_text` takes a Rust closure `F: FnMut(&NodeRef, &str) -> Option<T>`
(`accesskit_consumer/src/text.rs:680-683`). Rule Z7 replaces it with a context pointer and
a plain function pointer returning `bool`. The `Option<T>` return becomes `bool`, where
`false` means stop, so no generic is needed.

### 3.10 `accesskit_consumer`: `filters.rs` and `iterators.rs`

| Rust symbol | `path:line` | What it does | Zig counterpart | Extra parameter |
|---|---|---|---|---|
| `FilterResult` | `accesskit_consumer/src/filters.rs:11` | Three-way filter outcome | `pub const FilterResult = enum { include, exclude_node, exclude_subtree };` | none |
| `common_filter_base` | `accesskit_consumer/src/filters.rs:17` | Focus, hidden, graft and generic-container rules | `fn commonFilterBase(node: NodeRef) ?FilterResult` | none |
| `common_filter_without_parent_checks` | `accesskit_consumer/src/filters.rs:39` | The base rules with a default | `fn commonFilterWithoutParentChecks(node: NodeRef) FilterResult` | none |
| `is_first_sibling_in_parent_bbox` | `accesskit_consumer/src/filters.rs:43` | Whether the first visible sibling is in the box | `fn isFirstSiblingInParentBbox(siblings: SiblingIterator, parent_bbox: Rect) bool` | none |
| `common_filter` | `accesskit_consumer/src/filters.rs:54` | The full filter, recursive on the parent | `pub fn commonFilter(node: NodeRef) FilterResult` | none |
| `common_filter_with_root_exception` | `accesskit_consumer/src/filters.rs:94` | The same, but always includes the root | `pub fn commonFilterWithRootException(node: NodeRef) FilterResult` | none |
| `ChildIds` | `accesskit_consumer/src/iterators.rs:22` | Child id iterator, handling graft nodes | `pub const ChildIdsIterator = struct { ... };` | none |
| `FollowingSiblings` | `accesskit_consumer/src/iterators.rs:79` | Later sibling ids | `pub const FollowingSiblingsIterator = struct { ... };` | none |
| `PrecedingSiblings` | `accesskit_consumer/src/iterators.rs:170` | Earlier sibling ids | `pub const PrecedingSiblingsIterator = struct { ... };` | none |
| `FollowingFilteredSiblings` | `accesskit_consumer/src/iterators.rs:341` | Later siblings the filter includes | `pub const FollowingFilteredSiblingsIterator = struct { ... };` | `gpa` for the filter list |
| `PrecedingFilteredSiblings` | `accesskit_consumer/src/iterators.rs:409` | Earlier siblings the filter includes | `pub const PrecedingFilteredSiblingsIterator = struct { ... };` | `gpa` for the filter list |
| `FilteredChildren` | `accesskit_consumer/src/iterators.rs:477` | Children the filter includes | `pub const FilteredChildrenIterator = struct { ... };` | `gpa` for the filter list |
| `LabelledBy` | `accesskit_consumer/src/iterators.rs:537` | Labelling nodes, explicit or from descendants | `pub const LabelledByIterator = union(enum) { ... };` | none |
| `next_filtered_sibling` | `accesskit_consumer/src/iterators.rs:255` | Walks to the next included sibling | `fn nextFilteredSibling(gpa, node: ?NodeRef, filter: FilterFn) std.mem.Allocator.Error!?NodeRef` | `gpa`, `!` |

`FilterResult` has 3 variants, so L2 gives size 1 and alignment 1 with an `enum(u2)`.

The five filtered iterators all call `NodeRef::parent()` and walk the sibling list. They
do not allocate in the unfiltered case. `[INFERENCE]` The filtered cases appear not to
allocate either, because `FilteredChildren` holds a back pointer rather than a buffer
(`accesskit_consumer/src/iterators.rs:477-482`). `docs/30-port-design.md` should confirm no
`gpa` is needed, in which case the `gpa` column above becomes a dash for all five.

### 3.11 Summary of new parameters

The table counts how many functions need a parameter the Rust version does not have.

| New parameter | Count | Upstream evidence | Why Rust does not need it |
|---|---|---|---|
| `gpa: std.mem.Allocator` | 44 | `accesskit/src/lib.rs:1073`, `:858`, `:860`, `:866-867` | Rust takes the allocator from a thread-local global through `Vec`, `String` and `Box` |
| `io: std.Io` | 0 in the core crates | `accesskit/src/lib.rs:13-18`, `accesskit_consumer/src/lib.rs:6-9` | Neither core crate reads the clock, the environment, or a socket. Only `TreeId` generation needs entropy, and that is new code, see Q1. |
| explicit error set | 6 public functions | `accesskit_consumer/src/tree.rs:88`, `:317`, `:594` and 12 more, listed in section 4.6 | Rust panics on out-of-memory and on a malformed update |
| `context: ?*anyopaque` | 5 function-pointer fields | `accesskit_consumer/src/text.rs:680`, `accesskit_consumer/src/node.rs:111`, `accesskit_consumer/src/filters.rs:17`, `adapters/unix/src/adapter.rs:196` | Rust closures capture state, Zig function pointers do not |

The six functions that return an explicit error set: `Tree::init`,
`TreeState.update`, `Tree.updateAndProcessChanges`,
`Tree.updateHostFocusStateAndProcessChanges`, `TreeState.validateGlobal`, and
`TreeState.computeEffectiveFocus`. Section 4.6 lists every error variant.

## 4. The update protocol

This is the core algorithm. The pseudocode below follows
`accesskit_consumer/src/tree.rs:124-486` line by line. Each step names the source line or
lines it comes from, so a reviewer can check it against the source.

### 4.1 The state the algorithm mutates

```rust
accesskit_consumer/src/tree.rs:66-83
#[derive(Clone, Debug)]
pub struct TreeState {
    pub(crate) nodes: HashMap<FullNodeId, NodeState>,
    pub(crate) info: TreeInfo,
    pub(crate) root: FullNodeId,
    pub(crate) focus: FullNodeId,
    is_host_focused: bool,
    pub(crate) subtrees: HashMap<TreeId, SubtreeState>,
    pub(crate) graft_parents: HashMap<TreeId, FullNodeId>,
    tree_index_map: TreeIndexMap,
}

#[derive(Default)]
struct InternalChanges {
    added_node_ids: HashSet<FullNodeId>,
    updated_node_ids: HashSet<FullNodeId>,
    removed_node_ids: HashSet<FullNodeId>,
}
```

Zig counterpart:

```zig
pub const NodeMap = std.array_hash_map.Auto(FullNodeId, NodeState);
pub const TreeIdMap = std.array_hash_map.Auto(TreeId, SubtreeState);
pub const TreeIdNodeMap = std.array_hash_map.Auto(TreeId, FullNodeId);
pub const TreeIndexMapPair = std.array_hash_map.Auto(TreeIndex, TreeId);
pub const NodeIdSet = std.array_hash_map.Auto(FullNodeId, void);
pub const TreeIdSet = std.array_hash_map.Auto(TreeId, void);

pub const TreeState = struct {
    nodes: NodeMap = .empty,
    info: TreeInfo = .{},
    root: FullNodeId = .{ .tree_index = undefined, .node_id = .{ .value = 0 } },
    focus: FullNodeId = ...,
    is_host_focused: bool = false,
    subtrees: TreeIdMap = .empty,
    graft_parents: TreeIdNodeMap = .empty,
    tree_index_map: TreeIndexMap = .empty,
};
```

`std.array_hash_map.Auto` is the replacement for `hashbrown::HashMap`. Rule L7 gives it
40 bytes at alignment 8. Two reasons for the replacement, both required by the house rules:

1. It stores no `Allocator` field, so the allocator stays a parameter. This is rule
   `ozai/AGENTS.md:33-34`.
2. It preserves insertion order, where `hashbrown` does not. `process_changes` iterates
   `added_node_ids` and `updated_node_ids` in map order
   (`accesskit_consumer/src/tree.rs:641`, `:645`). With `hashbrown` the callback order is
   not reproducible. With `Auto` it is. This satisfies the determinism rule at
   `ozai/AGENTS.md:85-88`.

### 4.2 Production: how the application builds a `TreeUpdate`

The core crate has no producer. The producer is the application, through
`ActivationHandler::request_initial_tree` (`accesskit/src/lib.rs:3358`) and through
whatever function the platform adapter exposes for later updates. The smallest complete
producer is `example_common`:

```rust
example_common/src/lib.rs:137-174
pub fn build_tree_update(&mut self) -> TreeUpdate {
    if self.adapter_has_tree {
        self.build_update_for_dirty_nodes()
    } else {
        self.build_full_tree()
    }
}

fn build_full_tree(&mut self) -> TreeUpdate {
    self.adapter_has_tree = true;
    self.dirty_nodes.clear();
    let mut ids = vec![WINDOW_ID, BUTTON_1_ID, BUTTON_2_ID];
    if self.announcement.is_some() {
        ids.push(ANNOUNCEMENT_ID);
    }
    TreeUpdate {
        nodes: ids
            .into_iter()
            .map(|id| (id, self.build_node(id)))
            .collect(),
        tree: Some(TreeInfo::new(WINDOW_ID)),
        tree_id: TreeId::ROOT,
        focus: self.focus,
    }
}

fn build_update_for_dirty_nodes(&mut self) -> TreeUpdate {
    let ids = take(&mut self.dirty_nodes);
    TreeUpdate {
        nodes: ids
            .into_iter()
            .map(|id| (id, self.build_node(id)))
            .collect(),
        tree: None,
        tree_id: TreeId::ROOT,
        focus: self.focus,
    }
}
```

The producer keeps a `BTreeSet<NodeId>` of dirty nodes
(`example_common/src/lib.rs:81`) and a `bool` recording whether the adapter already has a
tree (`example_common/src/lib.rs:80`). The first update is a full tree with `tree` set.
Later updates carry only the dirty nodes with `tree: None`. `focus` is sent every time.

Zig counterpart for `UiState`:

```zig
pub const UiState = struct {
    gpa: std.mem.Allocator,
    focus: NodeId,
    announcement: ?[]const u8,
    pending_announcement: ?struct { text: []const u8, queued_at: std.Io.Timestamp },
    viewport: ?Viewport,
    adapter_has_tree: bool,
    dirty_nodes: std.ArrayList(NodeId),
};
```

Two changes from the Rust original:

* `BTreeSet` becomes `std.ArrayList(NodeId)` with a linear scan, because at most a handful
  of nodes are dirty and the set must stay sorted for `take`. `[INFERENCE]` A port author
  must confirm the dirty-node count stays small. If it does not, this becomes
  `std.ArrayHashMapAuto` plus a sort at `take` time.
* `Instant::now()` (`example_common/src/lib.rs:207`) becomes `io.now()`, which is where
  the port gets its first explicit `io` parameter. See Q2.

### 4.3 Consumption: `Tree::new`

```rust
accesskit_consumer/src/tree.rs:591-618
impl Tree {
    pub fn new(mut initial_state: TreeUpdate, is_host_focused: bool) -> Self {
        let Some(tree) = initial_state.tree.take() else {
            panic!(
                "Tried to initialize the accessibility tree without a root tree. \
                 TreeUpdate::tree must be Some."
            );
        };
        if initial_state.tree_id != TreeId::ROOT {
            panic!("Cannot initialize with a subtree. TreeUpdate::tree_id must be TreeId::ROOT.");
        }
        let mut tree_index_map = TreeIndexMap::default();
        let tree_index = tree_index_map.get_or_create_index(initial_state.tree_id);
        let mut state = TreeState {
            nodes: HashMap::new(),
            root: FullNodeId::new(tree.root, tree_index),
            info: tree,
            focus: FullNodeId::new(initial_state.focus, tree_index),
            is_host_focused,
            subtrees: HashMap::new(),
            graft_parents: HashMap::new(),
            tree_index_map,
        };
        state.update(initial_state, None);
        Self {
            next_state: state.clone(),
            state,
        }
    }
}
```

Pseudocode, in source order:

```
fn treeInit(gpa, initial_state, is_host_focused) -> Tree or UpdateError:
    # line 593: take() replaces initial_state.tree with None
    if initial_state.tree == null:
        # line 594-596
        return error.InitialUpdateMissingTreeData
    tree = initial_state.tree.?;

    # line 598-600
    if !std.mem.eql(u8, initial_state.tree_id.bytes[0..], treeIdRoot.bytes[0..]):
        return error.InitialUpdateForSubtree

    # line 601-602
    var tree_index_map: TreeIndexMap = .empty;
    tree_index = tree_index_map.getOrCreateIndex(gpa, initial_state.tree_id) catch |err|
        return err

    # line 603-612
    var state: TreeState = .{
        .nodes = .empty,
        .root = FullNodeId.init(tree.root, tree_index),
        .info = tree,
        .focus = FullNodeId.init(initial_state.focus, tree_index),
        .is_host_focused = is_host_focused,
        .subtrees = .empty,
        .graft_parents = .empty,
        .tree_index_map = tree_index_map,
    };

    # line 613
    try state.update(initial_state, null);

    # line 614-617
    return .{ .next_state = try state.clone(gpa), .state = state };
```

Invariants after step 1 of the call:

* `initial_state.tree` is taken, so the caller's update no longer carries it.
* `tree_index` for `TreeId::ROOT` is always 0, because `next` starts at 0
  (`accesskit_consumer/src/tree.rs:21`, `:43-44`).
* `state.root` and `state.focus` are both in the root tree's index.
* `next_state` and `state` are equal at construction. Every later update writes only
  `next_state` (`accesskit_consumer/src/tree.rs:626`).

### 4.4 The update algorithm, line by line

The pseudocode below is `TreeState::update`, `accesskit_consumer/src/tree.rs:124-486`.
Line numbers refer to that file.

```
fn update(self: *TreeState, update: TreeUpdate, changes: ?*InternalChanges)
        TreeError || Allocator.Error!void:
    # 125: assign this tree an index, creating one on first use
    tree_index = self.tree_index_map.getOrCreateIndex(gpa, update.tree_id) catch |e|
        return e
    # 126: a closure that lifts a tree-local NodeId into a FullNodeId
    # Zig has no closures, so mapId becomes a two-argument function:
    #   fn mapId(local_id: NodeId, tree_index: TreeIndex) FullNodeId

    # 128-129
    var unreachable: NodeIdSet = .empty;
    var seen_child_ids: NodeIdSet = .empty;

    tree_id = update.tree_id
    # 132-148: subtree preconditions
    if !std.mem.eql(u8, tree_id.bytes[0..], treeIdRoot.bytes[0..]):
        subtree_exists = self.subtrees.contains(tree_id)
        # 134-140
        if update.tree != null and !self.graft_parents.contains(tree_id):
            return error.NoGraftNodeForSubtree
        # 141-147
        if !subtree_exists and update.tree == null:
            return error.SubtreeUpdateWithoutTreeData

    # 150-166: new root handling
    new_tree_root: ?FullNodeId = null
    if update.tree != null:
        tree = update.tree.?
        new_root = mapId(tree.root, tree_index)
        if eqlTreeId(tree_id, treeIdRoot):
            # 153-155
            if !eqlNodeId(tree.root, self.info.root):
                unreachable.put(self.root)
            # 156-157
            self.root = new_root
            self.info = tree
        # 158-162
        else if self.subtrees.get(tree_id)) |subtree|:
            if !eqlFullNodeId(subtree.root, new_root):
                unreachable.put(subtree.root)
        new_tree_root = new_root

    # 168-175: the node id that counts as the root for reparenting tests
    root: NodeId = if new_tree_root) |r| r.node_id else
        self.subtrees.get(tree_id) orelse return self.info.root

    # 177-180
    var pending_nodes: NodeMap = .empty;
    var pending_children: std.array_hash_map.Auto(FullNodeId, ParentAndIndex) = .empty;
    var pending_grafts: TreeIdNodeMap = .empty;
    var grafts_to_remove: TreeIdSet = .empty;

    # 182-199: recordGraft, a nested fn in Rust, module-level in Zig
    #   panics on TreeId::ROOT and on a duplicate subtree id

    # 201-227: addNode, also a nested fn
    #   209-218: if data.treeId() != null:
    #              210-216: if data.children() is not empty, return error
    #              217:     recordGraft(pending_grafts, subtree_id, id)
    #   219-223: nodes.insert(id, .{ .parent_and_index, .data })
    #   224-226: if changes != null: changes.added_node_ids.insert(id)

    # 229-315: the main loop over update.nodes
    for (update.nodes.items) |entry|:
        local_node_id = entry.node_id
        node_data = entry.node
        node_id = mapId(local_node_id, tree_index)
        # 231
        _ = unreachable.remove(node_id)

        # 233-259: adopt the children this update introduces
        for (node_data.children(), 0..) |child_id, child_index|:
            mapped_child_id = mapId(child_id, tree_index)
            # 235-237
            if seen_child_ids.contains(mapped_child_id):
                return error.DuplicateChild
            seen_child_ids.put(mapped_child_id)
            # 238
            _ = unreachable.remove(mapped_child_id)
            parent_and_index = ParentAndIndex{ .parent_id = node_id, .index = child_index }
            # 240-246: an existing node whose parent changed is updated, not replaced
            if self.nodes.getPtr(mapped_child_id)) |child_state|:
                if child_state.parent_and_index == null or
                   !eqlParentAndIndex(child_state.parent_and_index.?, parent_and_index):
                    child_state.parent_and_index = parent_and_index
                    if changes != null:
                        changes.updated_node_ids.insert(mapped_child_id)
            # 247-255: a node this update already carried, now given a parent
            else if pending_nodes.fetchRemove(mapped_child_id)) |child_data|:
                addNode(gpa, self.nodes, pending_grafts, changes,
                        parent_and_index, mapped_child_id, child_data)
            # 256-258: a parent reference with no node data yet
            else:
                pending_children.put(mapped_child_id, parent_and_index)

        # 261-314: place the node itself
        if self.nodes.getPtr(node_id)) |node_state|:
            # 262-264
            if eqlNodeId(local_node_id, root):
                node_state.parent_and_index = null
            # 265-270: children the update no longer lists become unreachable
            for (node_state.data.children()) |child_id|:
                mapped_existing_child_id = mapId(child_id, tree_index)
                if !seen_child_ids.contains(mapped_existing_child_id):
                    unreachable.put(mapped_existing_child_id)
            # 271-293
            if !nodeEql(&node_state.data, &node_data):
                # 272-278
                if node_data.treeId() != null and node_data.children().len != 0:
                    return error.GraftNodeHasChildren
                # 279-288: a changed tree_id removes the old graft and records the new
                old_tree_id = node_state.data.treeId()
                new_tree_id = node_data.treeId()
                if !eqlOptionalTreeId(old_tree_id, new_tree_id):
                    if old_tree_id != null:
                        grafts_to_remove.put(old_tree_id.?)
                    if new_tree_id != null:
                        try recordGraft(pending_grafts, new_tree_id.?, node_id)
                # 289-292
                node_state.data = node_data
                if changes != null:
                    changes.updated_node_ids.insert(node_id)
        # 294-302: the node was a pending child, so it enters now with its parent
        else if pending_children.fetchRemove(node_id)) |parent_and_index|:
            addNode(gpa, self.nodes, pending_grafts, changes,
                    parent_and_index, node_id, node_data)
        # 303-311: the node is the root
        else if eqlNodeId(local_node_id, root):
            addNode(gpa, self.nodes, pending_grafts, changes, null, node_id, node_data)
        # 312-314: a parent reference arrived first, so the data waits
        else:
            try pending_nodes.put(node_id, node_data)

    # 317-323
    if pending_nodes.count() != 0:
        return error.OrphanNodesWithoutParent
    # 324-330
    if pending_children.count() != 0:
        return error.UnknownChildIds

    # 332-351: record the focus for this tree
    tree_focus = mapId(update.focus, tree_index)
    if new_tree_root) |new_root|:
        self.subtrees.put(tree_id, .{
            .root = new_root,
            .focus = tree_focus,
        })
    else if self.subtrees.getPtr(tree_id)) |subtree|:
        subtree.focus = tree_focus
    else if eqlTreeId(tree_id, treeIdRoot):
        self.subtrees.put(tree_id, .{
            .root = self.root,
            .focus = tree_focus,
        })

    # 353-393: remove unreachable nodes
    for (unreachable.keys()) |id|:
        traverseUnreachable(gpa, self.nodes, grafts_to_remove, changes,
                           seen_child_ids, new_tree_root, id)

    # 422-445: remove whole subtrees whose graft is gone
    var subtrees_queued: TreeIdSet = grafts_to_remove
    var subtrees_to_remove: std.ArrayList(TreeId) =
        listFromSet(gpa, subtrees_queued) catch |e| return e
    var i: usize = 0
    while i < subtrees_to_remove.items.len:          # 425
        subtree_id = subtrees_to_remove.items[i]
        i += 1
        # 429-431
        if self.graft_parents.fetchRemove(subtree_id) == null:
            continue
        # 433-435
        if pending_grafts.contains(subtree_id):
            continue
        # 436-444
        if self.subtrees.fetchRemove(subtree_id)) |subtree|:
            traverseSubtree(gpa, self.nodes, subtrees_to_remove, subtrees_queued,
                            changes, subtree.root)

    # 447-468: attach the new grafts
    for (pending_grafts.keys(), pending_grafts.values()) |subtree_id, node_id|:
        # 448-455
        if self.graft_parents.get(subtree_id)) |existing_graft|:
            return error.DuplicateGraftParent
        self.graft_parents.put(subtree_id, node_id)
        # 457-467: the subtree root becomes child 0 of the graft node
        if self.subtrees.get(subtree_id)) |subtree|:
            subtree_root_id = subtree.root
            if self.nodes.getPtr(subtree_root_id)) |root_state|:
                root_state.parent_and_index = .{
                    .parent_id = node_id,
                    .index = 0,
                }
                if changes != null:
                    if !changes.?.added_node_ids.contains(subtree_root_id):
                        changes.?.updated_node_ids.insert(subtree_root_id)

    # 470-481: the root of the tree this update targeted
    if (new_tree_root) |new_root_id|:
        if self.graft_parents.get(tree_id)) |graft_node_id|:
            if self.nodes.getPtr(new_root_id)) |root_state|:
                root_state.parent_and_index = .{
                    .parent_id = graft_node_id,
                    .index = 0,
                }
                if changes != null:
                    if !changes.?.added_node_ids.contains(new_root_id):
                        changes.?.updated_node_ids.insert(new_root_id)

    # 483
    self.focus = try self.computeEffectiveFocus()
    # 485
    try self.validateGlobal()
```

### 4.5 Invariants that hold at each step

The table gives the invariant after each block and the source line that establishes it.

| After step | Source line | Invariant |
|---|---|---|
| Precondition checks | `:132-148` | If `tree_id` is not `ROOT`, a graft node for it already exists in the parent tree, and a subtree's first update carries `tree`. |
| New root handling | `:150-166` | `self.info` and `self.root` change only for `TreeId::ROOT`. For a subtree, the stored `subtrees` entry is left alone except through `unreachable`. |
| Root for reparenting | `:168-175` | `root` is the tree-local `NodeId` of the new root if there is one, else the stored subtree root, else `info.root`. |
| Pending maps created | `:177-180` | All four are empty. `pending_nodes` holds node data with no parent yet. `pending_children` holds a parent reference with no data yet. `pending_grafts` holds graft claims for this update only. `grafts_to_remove` holds grafts this update invalidated. |
| Child adoption | `:233-259` | Every child id in the update is in `seen_child_ids` after the first pass. No id appears twice across the whole update. An existing child whose `parent_and_index` changes is recorded as updated, never reinserted. |
| Existing node branch | `:261-264` | The root node has `parent_and_index == null`. |
| Existing node branch | `:265-270` | A child that the old data listed and the new data does not list is in `unreachable`. It is not removed here. The removal happens at `:353-393`. |
| Existing node branch | `:271` | Data is compared with `Properties::eql`, which compares by property id, not by slot order (`accesskit/src/lib.rs:1084-1094`). So a node that only changed slot order is not an update. |
| Existing node branch | `:279-288` | A graft claim is recorded only when `tree_id` actually changed. An unchanged `tree_id` never re-records the graft, so a repeated graft claim from two nodes cannot happen through this path. |
| Node placement | `:294-314` | After the loop, every node is in `self.nodes`, `pending_nodes`, or was consumed. The panic at `:317-323` proves that `pending_nodes` is empty. |
| Dangling child check | `:324-330` | Every child id referenced anywhere in the update names a node in `self.nodes` or in this update. |
| Focus recording | `:332-351` | Exactly one `subtrees` entry is written per update. |
| Unreachable removal | `:353-393` | A node is removed only if it is not in `seen_child_ids` and is not the new root. The stack walk removes descendants that share the removed node's tree index (`:371-373`). |
| Subtree removal | `:422-445` | A subtree is removed only if its graft parent was removed, it is not re-grafted in this update, and a `subtrees` entry exists. The `subtrees_to_remove` list grows while it is being walked, so nested subtrees are handled in one pass. |
| Graft attachment | `:447-468` | Each subtree has at most one graft parent. The subtree root becomes child index 0 of the graft node. |
| Root attachment | `:470-481` | When this update introduced a tree root and a graft for that tree exists, the root is reparented under the graft at index 0. |
| Focus recompute | `:483` | `self.focus` is the effective focus: the root tree focus, followed through every graft chain until a non-graft node. |
| Final validation | `:485` | Both `self.root` and `self.focus` exist in `self.nodes`. |

### 4.6 Error variants replacing the nine panics

Rust panics inside `update` and its helpers. House rule `ozai/AGENTS.md:34-37` requires
explicit error sets, so each panic becomes one variant.

| Panic site | Message summary | Zig error variant |
|---|---|---|
| `accesskit_consumer/src/tree.rs:88` | Root id is not in the node list | `error.RootMissing` |
| `accesskit_consumer/src/tree.rs:91-95` | Focused id is not in the node list | `error.FocusMissing` |
| `accesskit_consumer/src/tree.rs:111-118` | Focus is on a graft node whose subtree does not exist | `error.FocusOnGraftWithoutSubtree` |
| `accesskit_consumer/src/tree.rs:135-139` | Cannot push a subtree with no graft node | `error.NoGraftNodeForSubtree` |
| `accesskit_consumer/src/tree.rs:142-146` | First subtree update must carry tree data | `error.SubtreeUpdateWithoutTreeData` |
| `accesskit_consumer/src/tree.rs:188` | Cannot graft the root tree | `error.GraftRootTree` |
| `accesskit_consumer/src/tree.rs:191-196` | Subtree already has a graft parent | `error.DuplicateGraftParent` |
| `accesskit_consumer/src/tree.rs:211-215` | Graft node has both `tree_id` and children | `error.GraftNodeHasChildren` |
| `accesskit_consumer/src/tree.rs:273-277` | Same, on the update path | `error.GraftNodeHasChildren` |
| `accesskit_consumer/src/tree.rs:236` | Update includes a duplicate child id | `error.DuplicateChild` |
| `accesskit_consumer/src/tree.rs:318-322` | Nodes in the update are neither in the tree nor children of another node | `error.OrphanNodesWithoutParent` |
| `accesskit_consumer/src/tree.rs:325-329` | Child ids name no known node | `error.UnknownChildIds` |
| `accesskit_consumer/src/tree.rs:449-454` | Subtree already has a graft parent | `error.DuplicateGraftParent` |
| `accesskit_consumer/src/tree.rs:594-596` | `TreeUpdate.tree` is `None` at construction | `error.InitialUpdateMissingTreeData` |
| `accesskit_consumer/src/tree.rs:599` | `TreeUpdate.tree_id` is not `ROOT` at construction | `error.InitialUpdateForSubtree` |

The set is:

```zig
pub const UpdateError = error{
    RootMissing,
    FocusMissing,
    FocusOnGraftWithoutSubtree,
    NoGraftNodeForSubtree,
    SubtreeUpdateWithoutTreeData,
    GraftRootTree,
    DuplicateGraftParent,
    GraftNodeHasChildren,
    DuplicateChild,
    OrphanNodesWithoutParent,
    UnknownChildIds,
    InitialUpdateMissingTreeData,
    InitialUpdateForSubtree,
};
```

13 variants. Nine of them are reachable only from a buggy application. The house rule
`ozai/AGENTS.md:37` asks whether each `if` needs an `else`. The port must answer this per
variant: the four that indicate a protocol violation stay as errors, because an
application can send them. The two that indicate a torn adapter state become `unreachable`
after a comptime-reachable check.

The two traversal helpers panic through `.unwrap()` on the node map
(`accesskit_consumer/src/tree.rs:367`) and `.unwrap_or_else` on the subtree map
(`:436`). The port keeps the `unreachable`, because both are unreachable when the
invariant above holds.

### 4.7 Change emission: `process_changes`

```rust
accesskit_consumer/src/tree.rs:640-706
fn process_changes(&mut self, changes: InternalChanges, handler: &mut impl ChangeHandler) {
    for id in &changes.added_node_ids {
        let node = self.next_state.node_by_id(*id).unwrap();
        handler.node_added(&node);
    }
    for id in &changes.updated_node_ids {
        let old_node = self.state.node_by_id(*id).unwrap();
        let new_node = self.next_state.node_by_id(*id).unwrap();
        handler.node_updated(&old_node, &new_node);
    }
    let old_focus = self.state.focus();
    let new_focus = self.next_state.focus();
    if old_focus.as_ref().map(|n| n.id()) != new_focus.as_ref().map(|n| n.id()) {
        if let Some(old_node) = &old_focus {
            let id = old_node.id();
            if !changes.updated_node_ids.contains(&id)
                && !changes.removed_node_ids.contains(&id)
            {
                if let Some(old_node_new_version) = self.next_state.node_by_id(id) {
                    handler.node_updated(old_node, &old_node_new_version);
                }
            }
        }
        if let Some(new_node) = &new_focus {
            let id = new_node.id();
            if !changes.added_node_ids.contains(&id) && !changes.updated_node_ids.contains(&id)
            {
                if let Some(new_node_old_version) = self.state.node_by_id(id) {
                    handler.node_updated(&new_node_old_version, new_node);
                }
            }
        }
        handler.focus_moved(old_focus.as_ref(), new_focus.as_ref());
    }
    for id in &changes.removed_node_ids {
        let node = self.state.node_by_id(*id).unwrap();
        handler.node_removed(&node);
    }
    for id in changes.added_node_ids {
        self.state
            .nodes
            .insert(id, self.next_state.nodes.get(&id).unwrap().clone());
    }
    for id in changes.updated_node_ids {
        self.state
            .nodes
            .get_mut(&id)
            .unwrap()
            .clone_from(self.next_state.nodes.get(&id).unwrap());
    }
    for id in changes.removed_node_ids {
        self.state.nodes.remove(&id);
    }
    if self.state.info != self.next_state.info {
        self.state.info.clone_from(&self.next_state.info);
    }
    self.state.root = self.next_state.root;
    self.state.focus = self.next_state.focus;
    self.state.is_host_focused = self.next_state.is_host_focused;
    self.state.subtrees.clone_from(&self.next_state.subtrees);
    self.state
        .graft_parents
        .clone_from(&self.next_state.graft_parents);
    self.state
        .tree_index_map
        .clone_from(&self.next_state.tree_index_map);
}
```

Pseudocode, in source order:

```
fn processChanges(self: *Tree, changes: InternalChanges, handler: *const ChangeHandler) void:
    # 641-644: additions, newest state
    for (changes.added_node_ids.keys()) |id|:
        node = self.next_state.nodeById(id).?
        handler.nodeAdded(handler.context, node)

    # 645-649: updates, both states
    for (changes.updated_node_ids.keys()) |id|:
        old_node = self.state.nodeById(id).?
        new_node = self.next_state.nodeById(id).?
        handler.nodeUpdated(handler.context, old_node, new_node)

    # 650-673: focus change, with the two synthetic updates
    old_focus = self.state.focus()
    new_focus = self.next_state.focus()
    if !eqlOptionalFullNodeId(oldFocusId(old_focus), newFocusId(new_focus)):
        # 653-662
        if (old_focus) |old_node|:
            id = old_node.id()
            if !changes.updated_node_ids.contains(id) and
               !changes.removed_node_ids.contains(id):
                if (self.next_state.nodeById(id)) |old_node_new_version|:
                    handler.nodeUpdated(handler.context, old_node, old_node_new_version)
        # 663-671
        if (new_focus) |new_node|:
            id = new_node.id()
            if !changes.added_node_ids.contains(id) and
               !changes.updated_node_ids.contains(id):
                if (self.state.nodeById(id)) |new_node_old_version|:
                    handler.nodeUpdated(handler.context, new_node_old_version, new_node)
        handler.focusMoved(handler.context, old_focus, new_focus)

    # 674-677: removals, committed state
    for (changes.removed_node_ids.keys()) |id|:
        node = self.state.nodeById(id).?
        handler.nodeRemoved(handler.context, node)

    # 678-692: commit
    # 678-682: additions are cloned, so state keeps its own buffers
    for (changes.added_node_ids.keys()) |id|:
        try state.nodes.put(gpa, id, self.next_state.nodes.get(id).?.data.clone(gpa))
    # 683-689: updates clone INTO state, so state's buffers are reused
    for (changes.updated_node_ids.keys()) |id|:
        state.nodes.getPtr(id).?.data.cloneInto(gpa, self.next_state.nodes.get(id).?.data)
    # 690-692
    for (changes.removed_node_ids.keys()) |id|:
        _ = state.nodes.fetchRemove(id)

    # 693-705: commit the scalars and the maps
    if !treeInfoEql(&state.info, &next_state.info):
        state.info.cloneInto(gpa, &next_state.info)
    state.root = next_state.root
    state.focus = next_state.focus
    state.is_host_focused = next_state.is_host_focused
    state.subtrees.cloneFrom(gpa, &next_state.subtrees)
    state.graft_parents.cloneFrom(gpa, &next_state.graft_parents)
    state.tree_index_map.cloneFrom(gpa, &next_state.tree_index_map)
```

Invariants the port must preserve:

* Every `handler` callback runs before any commit. The handler reads a consistent
  `next_state` and a consistent `state`.
* The added, updated, and removed passes run in that order, then focus, then removals.
  Reordering changes what a platform adapter sees.
* The two synthetic `node_updated` calls at `:659` and `:668` exist so a platform adapter
  sees the old and new focus nodes as changed, even when the update did not change them.
  The port must keep both.
* The commit at `:678-689` uses `clone` for additions and `clone_from` for updates. This
  asymmetry is deliberate. A clone allocates fresh buffers for a node that `state` did not
  have. A `clone_from` reuses `state`'s existing buffers. Section 5.5 covers why.

### 4.8 Node reuse

Upstream has no explicit reuse protocol. Reuse is implicit and follows from the commit
loop. Three rules govern it:

1. A node is updated by id. `self.nodes.get_mut(&node_id)` at
   `accesskit_consumer/src/tree.rs:261` reuses the existing `NodeState`, so the `Node`'s
   slot vector and its heap payloads survive.
2. A node is removed by id. Removing the id from the parent's `children` list makes the
   node unreachable, and the traversal at `:383-392` removes it and its descendants.
3. A node is re-added by id. `add_node` at `:219-223` overwrites the map entry with a
   fresh `Node`, so any previous buffers for that id are dropped.

The port therefore needs no reuse flag, no generation counter, and no free list. A Zig
`Node` is a plain value with the same slot-vector design, so the same three rules hold.
The one difference is that Zig has no `Drop`, so rule 3 needs an explicit
`node.deinit(gpa)` before the overwrite in `addNode`.

### 4.9 The `tree_id` property added in 0.23.0 and fixed in 0.25.1

`tree_id` is a node property, not a `TreeUpdate` field, for graft nodes. Both exist:

* `TreeUpdate.tree_id` selects which tree the update applies to
  (`accesskit/src/lib.rs:3237-3246`). It was added by commit `c16eb80`, "feat!: Multiple
  tree support", released in 0.23.0 (`accesskit/CHANGELOG.md` 0.23.0 section).
* `Node.tree_id` names the subtree a graft node points at
  (`accesskit/src/lib.rs:2538-2545`). It is `PropertyId::TreeId` at
  `accesskit/src/lib.rs:1005` and the generated getter `tree_id` at
  `accesskit/src/lib.rs:2545`.

The 0.25.1 change, commit `1d53dae` "fix: Add tree_id node property to the JSON schema",
touched three lines. The diff adds `TreeId { TreeId }` to the schemars property list at
`accesskit/src/lib.rs:3153`. It changed no runtime behaviour. The port therefore has no
runtime work for 0.25.1, only the schema artifact if Q7 decides one is needed.

The graft rules that matter:

* A graft node has a `tree_id` property and no children
  (`accesskit_consumer/src/tree.rs:209-218`).
* A graft node must exist in the parent tree before the first update for its subtree
  (`accesskit_consumer/src/tree.rs:134-140`).
* Removing a graft node removes the subtree, unless the same update provides a new graft
  node (`accesskit/src/lib.rs:2543-2544`).
* `TreeId::ROOT` can never be a graft target
  (`accesskit_consumer/src/tree.rs:187-189`).
* Each subtree has at most one graft parent. Two claims in one update panic at
  `accesskit_consumer/src/tree.rs:190-197`. A claim that conflicts with an existing
  parent panics at `:449-454`.

### 4.10 What "reuse property buffers when cloning nodes" changed

Commit `97194ad`, released in 0.25.0 as a breaking change
(`accesskit/CHANGELOG.md`: "⚠ BREAKING CHANGES — Reuse property buffers when cloning
nodes"), changed one thing and nothing else. The diff is 170 insertions and 40 deletions in
`accesskit/src/lib.rs`. It did three things.

**One: it replaced derived `Clone` with hand-written `Clone`.** Before the commit,
`PropertyValue`, `Properties`, and `Node` all had `#[derive(Clone)]`. After, all three have
a hand-written `impl Clone` with both `clone` and `clone_from`
(`accesskit/src/lib.rs:1011-1058`, `:1156-1168`, `:1836-1854`).

**Two: it changed the payload types so buffers can be reused.** The diff replaces
`Box<str>` with `String` in `CustomAction.description`
(`accesskit/src/lib.rs:763`) and in `PropertyValue::String`
(`accesskit/src/lib.rs:860`), and replaces `LengthSlice(Box<[u8]>)` and
`CoordSlice(Box<[f32]>)` with `LengthVec(Vec<u8>)` and `CoordVec(Vec<f32>)`
(`accesskit/src/lib.rs:866-867`). A `Box<[T]>` has one fixed allocation and no spare
capacity. A `Vec<T>` has spare capacity, so `Vec::clone_from` can copy into the existing
allocation when it is large enough. The diff comment cites the technique:
`https://viruta.org/reducing-memory-consumption-in-librsvg-2.html`
(`accesskit/src/lib.rs:852-853`).

**Three: it added the fast-path `clone_from` match.**

```rust
accesskit/src/lib.rs:1046-1057
fn clone_from(&mut self, source: &Self) {
    match (self, source) {
        (Self::NodeIdVec(dest), Self::NodeIdVec(source)) => dest.clone_from(source),
        (Self::String(dest), Self::String(source)) => dest.clone_from(source),
        (Self::LengthVec(dest), Self::LengthVec(source)) => dest.clone_from(source),
        (Self::CoordVec(dest), Self::CoordVec(source)) => dest.clone_from(source),
        (Self::CustomActionVec(dest), Self::CustomActionVec(source)) => dest.clone_from(source),
        (Self::Affine(dest), Self::Affine(source)) => dest.clone_from(source),
        (Self::TextSelection(dest), Self::TextSelection(source)) => dest.clone_from(source),
        (dest, source) => *dest = source.clone(),
    }
}
```

The seven arms are the seven variants with heap or copyable payloads that benefit. The
eightth arm handles every other variant, including a variant mismatch, which must
reallocate.

The two tests that lock the behaviour are at `accesskit/src/lib.rs:3435-3447` and
`:3449-3461`. The first asserts that `clone_from` reuses the destination string buffer by
pointer identity. The second asserts the same for the length-vector buffer.

Zig counterpart:

```zig
pub fn cloneInto(gpa: std.mem.Allocator, dest: *PropertyValue, source: PropertyValue) std.mem.Allocator.Error!void {
    switch (dest.*, source) {
        .node_id_vec => |*dest_list| node_id_vec => {
            dest_list.clearRetainingCapacity();
            try dest_list.appendSlice(gpa, node_id_vec.items);
        },
        .string => |*dest_list| string => {
            dest_list.clearRetainingCapacity();
            try dest_list.appendSlice(gpa, string.items);
        },
        .length_vec => |*dest_list| length_vec => {
            dest_list.clearRetainingCapacity();
            try dest_list.appendSlice(gpa, length_vec.items);
        },
        .coord_vec => |*dest_list| coord_vec => {
            dest_list.clearRetainingCapacity();
            try dest_list.appendSlice(gpa, coord_vec.items);
        },
        .custom_action_vec => |*dest_list| custom_action_vec => {
            dest_list.clearRetainingCapacity();
            try dest_list.appendSlice(gpa, custom_action_vec.items);
        },
        else => dest.* = try source.cloneValue(gpa),
    }
}
```

This is a Zig switch on a tuple of two unions, with capture-by-reference-pointer
payloads, which is how Zig expresses the Rust `match (self, source)`. The `else` arm
handles both a variant mismatch and the six payload-free variants. This keeps the Rust
semantics exactly, including the reallocation on mismatch.

The consequence for the port: `Properties.cloneInto` and `Node.cloneInto` must both take
`gpa` and return `Allocator.Error`. That is the 44th entry in the `gpa` column of section
3.11.

### 4.11 `compute_effective_focus` and the graft chain

```rust
accesskit_consumer/src/tree.rs:98-122
/// Computes the effective focus by following the graft chain from ROOT.
/// If ROOT's focus is on a graft node, follows through to that subtree's focus,
/// and continues recursively until reaching a non-graft node.
fn compute_effective_focus(&self) -> FullNodeId {
    let Some(root_subtree) = self.subtrees.get(&TreeId::ROOT) else {
        return self.focus;
    };

    let mut current_focus = root_subtree.focus;
    while let Some(node_state) = self.nodes.get(&current_focus) {
        let Some(subtree_id) = node_state.data.tree_id() else {
            break;
        };
        let subtree = self.subtrees.get(&subtree_id).unwrap_or_else(|| {
            panic!(
                "Focus is on graft node {:?} but subtree {:?} does not exist. \
                 Graft nodes cannot be focused without their subtree.",
                current_focus.to_components().0,
                subtree_id
            );
        });
        current_focus = subtree.focus;
    }
    current_focus
}
```

Pseudocode:

```
fn computeEffectiveFocus(self: *const TreeState) UpdateError!FullNodeId:
    # 102-104
    root_subtree = self.subtrees.get(treeIdRoot) orelse return self.focus
    # 106
    current_focus = root_subtree.focus
    # 107-120
    while (self.nodes.get(current_focus)) |node_state|:
        subtree_id = node_state.data.treeId() orelse break
        subtree = self.subtrees.get(subtree_id.?) orelse
            return error.FocusOnGraftWithoutSubtree
        current_focus = subtree.focus
    # 121
    return current_focus
```

This is a `while` with no explicit bound. The chain is finite because every step moves
into a different subtree, and the `subtrees` map has one entry per subtree. A cycle would
require a graft whose `tree_id` points at an ancestor subtree, which
`compute_effective_focus` itself cannot create because `record_graft` rejects a second
claim. See section 8.6 for whether the house bound rule forces a counter here.

### 4.12 The validation step

```rust
accesskit_consumer/src/tree.rs:85-96
impl TreeState {
    fn validate_global(&self) {
        if !self.nodes.contains_key(&self.root) {
            panic!("Root ID {:?} is not in the node list", self.info.root);
        }
        if !self.nodes.contains_key(&self.focus) {
            panic!(
                "Focused ID {:?} is not in the node list",
                self.focus.to_components().0
            );
        }
    }
}
```

```
fn validateGlobal(self: *const TreeState) UpdateError!void:
    if !self.nodes.contains(self.root):
        return error.RootMissing
    if !self.nodes.contains(self.focus):
        return error.FocusMissing
```

This runs at the end of every `update`, at `accesskit_consumer/src/tree.rs:485`. It is the
cheapest check that catches a torn application, and the port keeps it as the last step.

## 5. The action channel

### 5.1 The three traits

```rust
accesskit/src/lib.rs:3335-3385
/// Handles activation of the application's accessibility implementation.
pub trait ActivationHandler {
    /// Requests a [`TreeUpdate`] with a full tree. If the application
    /// can generate the tree synchronously within this method call,
    /// it should do so and return the [`TreeUpdate`]. Otherwise,
    /// it must send the update to the platform adapter asynchronously,
    /// no later than the next display refresh, even if a frame would not
    /// normally be rendered due to user input or other activity.
    /// The application should not return or send a placeholder [`TreeUpdate`];
    /// the platform adapter will provide one if necessary until the real
    /// tree is sent.
    ///
    /// The primary purpose of this method is to allow the application
    /// to lazily initialize its accessibility implementation. However,
    /// this method may be called consecutively without any call to
    /// [`DeactivationHandler::deactivate_accessibility`]; this typically happens
    /// if the platform adapter merely forwards tree updates to assistive
    /// technologies without maintaining any state. A call to this method
    /// must always generate a [`TreeUpdate`] with a full tree, even if
    /// the application normally sends incremental updates.
    ///
    /// The thread on which this method is called is platform-dependent.
    /// Refer to the platform adapter documentation for more details.
    fn request_initial_tree(&mut self) -> Option<TreeUpdate>;
}

/// Handles requests from assistive technologies or other clients.
pub trait ActionHandler {
    /// Perform the requested action. If the requested action is not supported,
    /// this method must do nothing.
    ///
    /// The thread on which this method is called is platform-dependent.
    /// Refer to the platform adapter documentation for more details.
    ///
    /// This method may queue the request and handle it asynchronously.
    /// This behavior is preferred over blocking, e.g. when dispatching
    /// the request to another thread.
    fn do_action(&mut self, request: ActionRequest);
}

/// Handles deactivation of the application's accessibility implementation.
pub trait DeactivationHandler {
    /// Deactivate the application's accessibility implementation and drop any
    /// associated data that can be reconstructed later. After this method
    /// is called, if an accessibility tree is needed again, the platform
    /// adapter will call [`ActivationHandler::request_initial_tree`] again.
    ///
    /// The thread on which this method is called is platform-dependent.
    /// Refer to the platform adapter documentation for more details.
    fn deactivate_accessibility(&mut self);
}
```

Three facts in these doc comments drive the whole design:

1. The calling thread is platform dependent, in all three cases
   (`accesskit/src/lib.rs:3356-3357`, `:3366-3367`, `:3382-3383`).
2. `request_initial_tree` may be called consecutively with no deactivation between calls
   (`accesskit/src/lib.rs:3349-3352`). Each call must return a full tree.
3. `do_action` is expected to queue rather than block (`accesskit/src/lib.rs:3369-3371`).

### 5.2 The exact upstream mechanism

The core crate owns no channel. The channel is built by each adapter. The clearest
statement of the mechanism is in the shared adapter context, which all the AT-SPI
adapters use:

```rust
adapters/atspi-common/src/context.rs:13-33
/// This is an implementation detail of `accesskit_unix`, required for robust
/// state transitions with minimal overhead.
pub trait ActionHandlerNoMut {
    fn do_action(&self, request: ActionRequest);
}

/// This is an implementation detail of `accesskit_unix`, required for robust
/// state transitions with minimal overhead.
pub struct ActionHandlerWrapper<H: ActionHandler + Send>(Mutex<H>);

impl<H: 'static + ActionHandler + Send> ActionHandlerWrapper<H> {
    pub fn new(inner: H) -> Self {
        Self(Mutex::new(inner))
    }
}

impl<H: ActionHandler + Send> ActionHandlerNoMut for ActionHandlerWrapper<H> {
    fn do_action(&self, request: ActionRequest) {
        self.0.lock().unwrap().do_action(request)
    }
}
```

And the adapter holds it as a trait object behind an `Arc`:

```rust
adapters/atspi-common/src/context.rs:35-40
pub(crate) struct Context {
    pub(crate) app_context: Arc<RwLock<AppContext>>,
    pub(crate) tree: RwLock<Tree>,
    pub(crate) action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>,
    pub(crate) root_window_bounds: RwLock<WindowBounds>,
}
```

And the platform adapter constructor takes the three handlers by value and boxes them:

```rust
adapters/unix/src/adapter.rs:134-143
        activation_handler: impl 'static + ActivationHandler + Send,
        action_handler: impl 'static + ActionHandler + Send,
        deactivation_handler: impl 'static + DeactivationHandler + Send,
    ) -> Self {
        let id = next_adapter_id();
        ...
            action_handler: Arc::new(ActionHandlerWrapper::new(action_handler)),
```

So the upstream mechanism is:

| Stage | Construct | Source |
|---|---|---|
| Handler storage | `Mutex<H>` | `adapters/atspi-common/src/context.rs:21` |
| Handler accessor | `fn(&self, request)` on a trait object | `adapters/atspi-common/src/context.rs:15-17` |
| Shared ownership | `Arc<dyn ActionHandlerNoMut + Send + Sync>` | `adapters/atspi-common/src/context.rs:38` |
| Tree storage | `RwLock<Tree>` | `adapters/atspi-common/src/context.rs:37` |
| Activation call | `entry.activation_handler.request_initial_tree()` | `adapters/unix/src/context.rs:91` |
| Deactivation call | `entry.deactivation_handler.deactivate_accessibility()` | `adapters/unix/src/context.rs:128`, `:137` |
| `Mutex` unwrap on poison | `self.0.lock().unwrap()` | `adapters/atspi-common/src/context.rs:31` |

The `ActionHandlerNoMut` trait exists because the `ActionHandler` trait takes
`&mut self` (`accesskit/src/lib.rs:3372`) and a `Mutex` guard cannot outlive the borrow of
the mutex. The wrapper converts the `&mut self` call into an `&self` call by locking.

### 5.3 Ownership and lifetime of one request

Trace one `ActionRequest` from the platform to the application.

1. The platform library delivers a request. For AT-SPI this is the `Action` interface
   call `do_action(index)`, at `adapters/unix/src/atspi/interfaces/action.rs:48-50`.
2. The adapter builds an `ActionRequest { action, target_tree, target_node, data }`. All
   four fields are by value (`accesskit/src/lib.rs:3328-3333`). The struct is 72 bytes in
   Zig, section 2.4.
3. The adapter calls `Context::do_action`, which forwards to the trait object
   (`adapters/atspi-common/src/context.rs:76-78`).
4. `ActionHandlerWrapper::do_action` takes the mutex and calls the application handler
   (`adapters/atspi-common/src/context.rs:30-32`).
5. The application handler either acts now or queues the request
   (`accesskit/src/lib.rs:3369-3371`).

Ownership facts the port must reproduce:

* The request is owned by value at every step. It has no lifetime parameter in Rust, and
  `data: Option<ActionData>` holds an owned `Box<str>` for the `Value` variant
  (`accesskit/src/lib.rs:3307`). So `ActionRequest` in Zig holds an owned `[]u8` for that
  variant, not a borrowed `[]const u8`, or the request would not be self-contained.
* The mutex guard does not outlive the call. `do_action` returns `void`
  (`accesskit/src/lib.rs:3372`), so no borrow escapes.
* There is no acknowledgement. `do_action` returns nothing. An unsupported action is
  silently dropped (`accesskit/src/lib.rs:3363-3364`).

The port therefore needs an owned `ActionData.value`. The mapping in section 2.4 said
`[]const u8`. That is correct for a borrowed ActionData, but an ActionRequest crossing a
thread boundary needs an owned buffer. See Q3.

### 5.4 Cancellation

There is no cancellation in upstream. Each mechanism is:

| Question | Upstream answer | Source |
|---|---|---|
| Can a request be cancelled once sent? | No | `do_action` returns `void`, `accesskit/src/lib.rs:3372` |
| Is there a timeout? | No | No timeout appears in `accesskit/src/lib.rs:3336`, `:3362`, or `:3376` |
| What if the handler blocks? | The platform thread blocks on the mutex | `adapters/atspi-common/src/context.rs:31` |
| What if the handler panics? | The mutex poisons, and the next `.lock().unwrap()` panics | `adapters/atspi-common/src/context.rs:31` |
| Can a queued request be dropped? | Yes, the application chooses | `accesskit/src/lib.rs:3369-3371` says queueing is the application choice |
| What if the tree changes while a request is in flight? | Undefined. The doc says the sender and receiver must be in sync | `accesskit/src/lib.rs:3194-3196` |

### 5.5 The Zig design

The Zig design must satisfy the house rule that `io` is threaded explicitly and never
global (`ozai/AGENTS.md:59-63`). A `std.Thread.Mutex` is not cancellable and does not take
`io`. `std.Io.RwLock` is available and does take `io`:

```
std/Io/RwLock.zig:28  pub fn tryLock(rl: *RwLock, io: Io) bool
std/Io/RwLock.zig:42  pub fn lockUncancelable(rl: *RwLock, io: Io) void
std/Io/RwLock.zig:51  pub fn lock(rl: *RwLock, io: Io) Io.Cancelable!void
std/Io/RwLock.zig:70  pub fn unlock(rl: *RwLock, io: Io) void
std/Io/RwLock.zig:75  pub fn tryLockShared(rl: *RwLock, io: Io) bool
std/Io/RwLock.zig:97  pub fn lockSharedUncancelable(rl: *RwLock, io: Io) void
std/Io/RwLock.zig:115 pub fn lockShared(rl: *RwLock, io: Io) Io.Cancelable!void
std/Io/RwLock.zig:133 pub fn unlockShared(rl: *RwLock, io: Io) void
```

The port design, with `io` on every lock operation:

```zig
pub const AdapterContext = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    tree: std.Io.RwLock(Tree) = .{},
    action_handler: ActionHandler,
    activation_handler: ActivationHandler,
    deactivation_handler: DeactivationHandler,
    root_window_bounds: std.Io.RwLock(WindowBounds) = .{},
};
```

Every call site then reads:

```zig
pub fn doAction(ctx: *AdapterContext, request: ActionRequest) void {
    ctx.action_handler.doAction(ctx.action_handler.context, request);
}
```

The `Mutex<H>` wrapper of `adapters/atspi-common/src/context.rs:21` disappears. The
handler now holds its own lock, because the handler knows its own threading needs. This
removes the upstream `ActionHandlerNoMut` indirection entirely, which exists only to work
around the Rust `&mut self` signature. Rule Z7 already replaced `&mut self` with a plain
function pointer, so the workaround has nothing left to work around.

Consequences the port must accept:

* There is no poisoned-mutex path, because `std.Io.RwLock` does not poison. The
  `.lock().unwrap()` at `adapters/atspi-common/src/context.rs:31` disappears with it.
* A blocking handler is now the application's own problem. The port cannot enforce
  queueing, because queueing needs a channel and the handler owns that choice.
* Cancellation becomes possible where upstream had none: `lock` and `lockShared` return
  `Io.Cancelable!void`, so an adapter that awaits a lock can be cancelled. This is a
  capability the port gains, not one it must use.

## 6. Concurrency and threading

### 6.1 What upstream assumes

The two core crates assume nothing about threads. Both are `no_std` plus `alloc`, and
neither imports a threading primitive.

Evidence that `accesskit` has no threading:

```
accesskit/src/lib.rs:11   #![cfg_attr(not(any(feature = "pyo3", feature = "schemars")), no_std)]
accesskit/src/lib.rs:13   extern crate alloc;
accesskit/src/lib.rs:17   use alloc::{borrow::ToOwned, boxed::Box, string::String, vec::Vec};
accesskit/src/lib.rs:18   use core::fmt;
accesskit/src/lib.rs:32   pub use uuid::Uuid;
accesskit/src/lib.rs:34   mod geometry;
```

That is the whole import block outside the feature-gated `serde`, `schemars`, and `pyo3`
branches at `accesskit/src/lib.rs:15-30`. No `std::sync`, no `Arc`, no `Mutex`, no thread.

Evidence that `accesskit_consumer` has no threading:

```
accesskit_consumer/src/lib.rs:6    #![no_std]
accesskit_consumer/src/lib.rs:8    extern crate alloc;
accesskit_consumer/src/lib.rs:6    use accesskit::{Node, NodeId, TreeId, TreeInfo, TreeUpdate, Vec2};
accesskit_consumer/src/lib.rs:7    use alloc::{vec, vec::Vec};
accesskit_consumer/src/lib.rs:8    use core::fmt;
accesskit_consumer/src/lib.rs:9    use hashbrown::{HashMap, HashSet};
accesskit_consumer/src/tree.rs:11  use crate::node::{FullNodeId, NodeRef, NodeState, ParentAndIndex};
```

So the concurrency contract of both crates is: **single-threaded, reentrant-free, and
owned entirely by the caller.** The caller decides whether the `Tree` is behind a lock.

### 6.2 Where the concurrency primitives live upstream

Every mutex, `RwLock`, and `Arc` in the workspace lives in the adapters, not in the core.
The list is short.

| Construct | Type | Source | Purpose |
|---|---|---|---|
| `ActionHandlerWrapper<H>` | `Mutex<H>` | `adapters/atspi-common/src/context.rs:21` | Serialises `do_action` against the application handler |
| `Context.tree` | `RwLock<Tree>` | `adapters/atspi-common/src/context.rs:37` | Guards the stored tree |
| `Context.app_context` | `Arc<RwLock<AppContext>>` | `adapters/atspi-common/src/context.rs:36` | Guards the list of live adapters |
| `Context.root_window_bounds` | `RwLock<WindowBounds>` | `adapters/atspi-common/src/context.rs:39` | Guards window geometry |
| `Context.action_handler` | `Arc<dyn ActionHandlerNoMut + Send + Sync>` | `adapters/atspi-common/src/context.rs:38` | Shares the handler across adapter threads |
| `AdapterState` | enum with an `Arc<RwLock<Self>>` | `adapters/unix/src/adapter.rs:81-92` | Holds the handler plus the tree |
| `AppContext.adapters` | `Vec<(usize, Arc<Context>)>` | `adapters/atspi-common/src/context.rs:95` | The set of live adapters |

The design intent is stated in the commit that introduced it. Commit `5df52e5`, "refactor!:
Move thread synchronization into platform adapters, drop parking_lot (#212)". It deleted
`parking_lot` from four crates and moved every lock into the adapter layer. The stat for
that commit shows the deletions in `consumer/Cargo.toml` and in each
`platforms/*/Cargo.toml`, alongside the code changes in `platforms/*/context.rs`. The
message is one line: "Move thread synchronization into platform adapters, drop
parking_lot".

That decision is the single most important fact for the port. It means the core crates
have no threading contract to reproduce, and the port must not invent one.

### 6.3 What runs where

| Work | Thread | Upstream evidence | Port consequence |
|---|---|---|---|
| Building a `Node` and a `TreeUpdate` | The application main thread | `example_common/src/lib.rs:137-143`, where `build_tree_update` takes `&mut self` | The port keeps this on the application task. |
| `request_initial_tree` | Platform dependent | `accesskit/src/lib.rs:3356-3357` | The port cannot pick a thread. It must document that the caller chooses. |
| Applying a `TreeUpdate` | The platform adapter's thread | `adapters/unix/src/context.rs:91-93` calls `request_initial_tree` then builds the adapter | The port applies the update on whichever task holds the tree lock. |
| `do_action` | Platform dependent | `accesskit/src/lib.rs:3366-3367` | Same. The application handler decides whether to hop. |
| `deactivate_accessibility` | Platform dependent | `accesskit/src/lib.rs:3382-3383` | Same. |
| `TreeState::update` | Wherever the adapter runs | `accesskit_consumer/src/tree.rs:124` takes `&mut self`, so the caller must have exclusive access | The port takes `*Tree`, so the borrow checker is replaced by the type system. |
| The AT-SPI event loop | A D-Bus main loop, one per application | `adapters/atspi-common/src/context.rs:36` holds `Arc<RwLock<AppContext>>`, and `adapters/unix/src/lib.rs` runs the loop | This is adapter territory, see `docs/12-accesskit-adapters.md`. |

### 6.4 The queue question

`do_action` is documented as expected to queue (`accesskit/src/lib.rs:3369-3371`), but the
core crate provides no queue, no channel type, and no sender. Every queue in the workspace
belongs to an adapter or to the example application.

| Queue | Owner | Source |
|---|---|---|
| D-Bus method-call dispatch queue | The AT-SPI adapter, owned by the D-Bus library | `adapters/unix/src/atspi/` |
| `winit` internal async tasks | The winit adapter, which "internally spawns asynchronous tasks on an executor" | `adapters/winit/src/lib.rs:9` |
| `pending_announcement: Option<(&'static str, Instant)>` | The example application | `example_common/src/lib.rs:78` |
| `dirty_nodes: BTreeSet<NodeId>` | The example application | `example_common/src/lib.rs:81` |

The `winit` adapter documents that its API is blocking while its internals are
asynchronous, in one line at `adapters/winit/src/lib.rs:9`: "While this crate's API is
purely blocking, it internally spawns asynchronous tasks on an executor."

### 6.5 What the port must do

The port keeps the upstream split: the core crates stay single-threaded with no locks, and
the adapters own all concurrency. This satisfies the house rule that `io` is threaded
explicitly (`ozai/AGENTS.md:59-63`) because the core crates never touch `io` at all.

Three concrete changes:

1. **No `Mutex` in the core.** Neither `accesskit.zig` nor `consumer.zig` imports a lock.
   A reviewer must be able to confirm this by grep.
2. **`io` appears in the adapter only.** `AdapterContext` in section 5.5 carries `io` and
   `gpa`. Every lock operation in the adapter takes `io`.
3. **The handler is a struct of function pointers, not a trait object.** Rule Z7. The
   handler carries its own `context: ?*anyopaque`, and the application owns whatever
   synchronisation it needs. This deletes the `ActionHandlerNoMut` workaround.

### 6.6 Reentrancy and aliasing

Two aliasing facts the port must not lose:

* `NodeRef<'a>` borrows `&'a TreeState` and `&'a NodeState`
  (`accesskit_consumer/src/node.rs:78-82`). Its methods walk the tree, so it must not
  outlive the state. In Zig, `NodeRef` holds two raw pointers. The port must document the
  borrow, and `docs/30-port-design.md` must decide whether to use a comptime-checked
  lifetime idiom or an arena that pins the state.
* `NodeRef::is_focused` at `accesskit_consumer/src/node.rs:89-105` walks the
  `active_descendant` chain with a recursive closure that calls `node_by_id`. The port
  must give that walk a fixed iteration count, because a cycle in the
  `active_descendant` relation would otherwise loop forever. See section 8.6.

### 6.7 The adapter-side state machine

The unix adapter is the reference for what a port adapter must reproduce. Its state is
one enum behind one lock.

```rust
adapters/unix/src/adapter.rs:80-92
pub(crate) enum AdapterState {
    Inactive {
        is_window_focused: bool,
        root_window_bounds: WindowBounds,
        action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>,
    },
    Pending {
        is_window_focused: bool,
        root_window_bounds: WindowBounds,
        action_handler: Arc<dyn ActionHandlerNoMut + Send + Sync>,
    },
    Active(AdapterImpl),
}
```

```rust
adapters/unix/src/context.rs:76-81
struct AdapterEntry {
    id: usize,
    activation_handler: Box<dyn ActivationHandler>,
    deactivation_handler: Box<dyn DeactivationHandler>,
    state: Arc<Mutex<AdapterState>>,
}
```

The unix adapter uses `Mutex`, not `RwLock`, for the adapter state
(`adapters/unix/src/context.rs:80`). The `RwLock<Tree>` in
`adapters/atspi-common/src/context.rs:37` is a second, finer lock held by the shared
adapter implementation. Two locks, two layers.

The transition happens in one place:

```rust
adapters/unix/src/context.rs:83-101
fn activate_adapter(entry: &mut AdapterEntry) {
    let mut state = entry.state.lock().unwrap();
    if let AdapterState::Inactive {
        is_window_focused,
        root_window_bounds,
        action_handler,
    } = &*state
    {
        *state = match entry.activation_handler.request_initial_tree() {
            Some(initial_state) => {
                let r#impl = AdapterImpl::with_wrapped_action_handler(
                    entry.id,
                    get_or_init_app_context(),
                    Callback::new(),
                    initial_state,
                    *is_window_focused,
                    *root_window_bounds,
                    Arc::clone(action_handler),
                );
```

Three observations the port must honour:

* The adapter calls `request_initial_tree` while holding the state lock
  (`adapters/unix/src/context.rs:84` then `:91`). So the application handler runs with the
  adapter locked. A handler that calls back into the adapter would deadlock. The port
  keeps the same order and documents the hazard, because changing the order changes the
  deadlock surface.
* The three-state enum has `Inactive`, `Pending`, and `Active`. `Pending` exists for the
  case where `request_initial_tree` returned `None`, so the adapter is registered but has
  no tree. The port keeps all three states.
* Updates reach the tree through `update_if_active`, which takes `impl FnOnce() ->
  TreeUpdate` (`adapters/unix/src/adapter.rs:196`) and calls it while holding the lock
  (`adapters/unix/src/adapter.rs:197`). The Zig counterpart takes a context pointer and a
  function pointer by rule Z7, and the `FnOnce` becomes a single call.

The unix adapter also has an explicit message channel:

```
adapters/unix/src/adapter.rs:159-164
    pub(crate) fn send_message(&self, message: Message) {
        #[cfg(not(feature = "tokio"))]
        let _ = self.messages.try_send(message);
        #[cfg(feature = "tokio")]
        let _ = self.messages.send(message);
    }
```

The channel is `async_channel::Sender` or `tokio::sync::mpsc::UnboundedSender` depending on
the feature (`adapters/unix/src/context.rs:9`, `:20`). This is the queue the
`AccesskitAdapters` document owns. The core port needs no channel.

## 7. House-rule fit

The binding rules come from `~/ozai/AGENTS.md` section 2. Each
row gives the rule, whether upstream satisfies it, the specific upstream construct that
forces the answer, and what the port must do.

### 7.1 `io: std.Io` threaded explicitly, never global

Rule: `ozai/AGENTS.md:59-63`.

| Question | Answer |
|---|---|
| Does upstream satisfy it? | Yes, vacuously. |
| Forcing construct | `accesskit/src/lib.rs:11` makes the crate `no_std` when neither `pyo3` nor `schemars` is enabled, and the only imports are `core`, `alloc`, and `uuid` (`accesskit/src/lib.rs:13-18`, `:32`). There is no global state to thread, because there is no global state at all. |
| What the port must do | Keep it that way. Neither `accesskit.zig` nor `consumer.zig` takes `io`, because no function in either crate performs I/O. The first `io` parameter appears in the adapter context (section 5.5) and in the port's new `TreeId` generator (Q1). |
| Risk | A port author may add a "convenience" `log` or `now` call to the core crates. That would be the first global. Reject it. |

### 7.2 Network logic is pure over decoded input

Rule: `ozai/AGENTS.md:64-68`.

| Question | Answer |
|---|---|
| Does upstream satisfy it? | Yes, for everything in the two core crates. |
| Forcing construct | `TreeState::update` (`accesskit_consumer/src/tree.rs:124`) is a pure function of its `TreeUpdate` argument and its `&mut self` state. It opens no socket, reads no clock, and takes no allocator. The same holds for every `Node` accessor and every geometry function. |
| What the port must do | Keep `update` pure over decoded input. `gpa` is an input, not an I/O operation. Add a `Smith`-style fuzz target at the `TreeUpdate` decoder boundary once a decoder exists (Q7). |
| Gap | Upstream has no decoder. `serde` is a feature-gated dependency (`accesskit/Cargo.toml:21`) and is off by default, so the crate ships with no wire format. The port must not invent one without a decision. See Q7. |

### 7.3 State is a parameter, not a capture

Rule: `ozai/AGENTS.md:69-70`.

| Question | Answer |
|---|---|
| Does upstream satisfy it? | Mostly. It fights in three places. |
| Forcing construct 1 | `TreeState::update` takes `&mut self` and an owned `TreeUpdate` (`accesskit_consumer/src/tree.rs:124`). That is state as a parameter, and the port keeps it as `*TreeState`. |
| Forcing construct 2 | `common_filter` is recursive and calls itself through a function pointer: `if common_filter(&parent) == FilterResult::ExcludeSubtree` at `accesskit_consumer/src/filters.rs:60`. The parent is a value parameter, so this is fine. |
| Forcing construct 3 | `NodeRef::is_focusable` takes `parent_filter: &impl Fn(&NodeRef) -> FilterResult` (`accesskit_consumer/src/node.rs:111`). In Rust an `impl Fn` can capture. In Zig a plain function pointer cannot, so the port forces `FilterFn = *const fn (NodeRef) FilterResult` with no capture. This is stricter than upstream and satisfies the rule. |
| What the port must do | Use `*const fn` for every filter. Where a filter needs per-call state, add an explicit `context: ?*anyopaque` parameter. `text_node_filter` at `accesskit_consumer/src/text.rs:932` is the model: it takes `root_id: FullNodeId` as a value, so a closure is unnecessary. |

### 7.4 Allocators are parameters, never global

Rule: `ozai/AGENTS.md:33-34`.

| Question | Answer |
|---|---|
| Does upstream satisfy it? | No. |
| Forcing construct | Every owned payload uses a Rust collection that takes its allocator from a thread-local global: `Vec<PropertyValue>` at `accesskit/src/lib.rs:1073`, `String` at `:860`, `std.ArrayList`'s equivalent in `TreeState.nodes` at `accesskit_consumer/src/tree.rs:68`. Rust hides the allocator entirely, so there is nothing to thread. |
| What the port must do | Thread `gpa` through 44 functions, listed in section 3.11. Three structural choices make this possible without a wrapper. First, `std.array_hash_map.Auto` stores no allocator, unlike `std.AutoHashMap` (`std/array_hash_map.zig:56-60` states the design). Second, `std.array_list.Aligned(T, null)` is the unmanaged list (`std/array_list.zig:570`). Third, `Node` and `TreeState` are plain structs, so their `deinit(gpa)` is explicit rather than a `Drop` impl. |
| Cost | Every mutator that can grow returns `std.mem.Allocator.Error`. The port has 44 such functions. This is the price of the rule, and it is correct. |

### 7.5 Explicit error sets, no `anyerror`

Rule: `ozai/AGENTS.md:34-35` and `:75-78`.

| Question | Answer |
|---|---|
| Does upstream satisfy it? | No. |
| Forcing construct 1 | Out-of-memory aborts the process in Rust. `Vec::push` at `accesskit/src/lib.rs:1125` cannot return an error. |
| Forcing construct 2 | Nine `panic!` calls inside `TreeState::update` and its helpers, listed in section 4.6. `panic!` is not an error value, so a caller cannot handle a malformed update. |
| Forcing construct 3 | `unwrap()` at `accesskit_consumer/src/tree.rs:367` and `.unwrap_or_else` at `:436`. |
| What the port must do | Define `UpdateError` with 13 variants (section 4.6) and `std.mem.Allocator.Error` for every allocation. Return `UpdateError!void` from the six functions in section 3.11. Replace `unwrap()` with `unreachable` where the invariant makes it impossible, and state why in a comment, per `ozai/AGENTS.md:47-49`. |
| Comptime sweep | House rule `ozai/AGENTS.md:78-81` asks for an `inline for` over `@typeInfo(UpdateError)`. The port should write one test that constructs a `TreeUpdate` violating each of the 13 rules and asserts the exact error. Section 4.6 gives the inputs. |

### 7.6 Loops have fixed upper bounds

Rule: `ozai/AGENTS.md:42-43`.

This is the rule upstream fights hardest. Four loops have no bound.

| Loop | Source | Bound in upstream | Why it terminates | What the port must do |
|---|---|---|---|---|
| `compute_effective_focus` | `accesskit_consumer/src/tree.rs:107-120` | none | Each step moves to a different subtree, and each subtree has one graft parent | Add a counter bounded by `subtrees.count() + 1`. Exceeding it is `unreachable`, with a comment naming the invariant. |
| `traverse_unreachable` | `accesskit_consumer/src/tree.rs:362-380` | none | The stack holds nodes to remove, and each node is removed once | Bound the loop by `nodes.count()`. Each iteration removes one entry, so the bound is exact. |
| `traverse_subtree` | `accesskit_consumer/src/tree.rs:402-419` | none | Same | Same bound. |
| `subtree removal loop` | `accesskit_consumer/src/tree.rs:425-445` | none | The list grows while it is walked, but each subtree is queued once (`subtrees_queued`) | Bound by `subtrees_to_remove.items.len`, re-read each iteration, because the list grows. |
| `NodeRef::is_focused` walk | `accesskit_consumer/src/node.rs:90-105` | none | The `active_descendant` chain is assumed acyclic | Add a counter bounded by `nodes.count()`. A cycle is an application bug, so exceeding the bound is an explicit error, not `unreachable`. |
| `NodeRef::deepest_first_child` | `accesskit_consumer/src/node.rs:238-244` | none | The tree is acyclic | Bound by `nodes.count()`. |
| `NodeRef::deepest_last_child` | `accesskit_consumer/src/node.rs:257-263` | none | Same | Same bound. |
| `NodeRef::is_descendant_of` | `accesskit_consumer/src/node.rs:276-289` | none | Same | Same bound. |
| `RelativeTransform` and `transform` | `accesskit_consumer/src/node.rs:299-307`, `:309-320` | none | Same | Same bound. |
| `Position` movement | `accesskit_consumer/src/text.rs:516-552` | none | The text run list is finite | Bound by the run count, which requires counting runs first, or use a decrementing `usize` set to the remaining run count. |
| `main node loop` | `accesskit_consumer/src/tree.rs:229` | none | `update.nodes` is finite | The bound is `nodes.items.len`, which is a comptime-known length of the input. No counter needed. |
| `children` loop | `accesskit_consumer/src/tree.rs:233`, `:265` | none | `children()` is finite | Bounded by the slice length. |

Rule `ozai/AGENTS.md:47-49` also asks to assert the positive and negative space at
boundaries. Each bound above gets a paired assertion: the walk must terminate before the
bound, and a walk that hits the bound must fail loudly.

### 7.7 No backwards compatibility

Rule: `ozai/AGENTS.md:52-53`.

Upstream carries four deprecated items. All four are deleted in the port.

| Deprecated item | Source | Port action |
|---|---|---|
| `pub type Tree = TreeInfo` | `accesskit/src/lib.rs:3178-3179` | Delete. One name, `TreeInfo`, from rule Z6. |
| `Node::supports_url` and friends | `accesskit_consumer/src/node.rs:810` | Keep, renamed. Not deprecated. |
| `enumn` feature | `accesskit/Cargo.toml:26` | Delete. The port writes the comptime table. |
| `pyo3`, `schemars`, `serde` features | `accesskit/Cargo.toml:27-29` | Delete unless Q7 says a serialiser is needed. |

Upstream also carries `Action::n` as a hand-written duplicate of the `enumn` output
(`accesskit/src/lib.rs:357-387`), with a comment saying a macro "would break C bindings
header file generation". The port has no `cbindgen`, so the comment's reason does not
apply. The port uses one `switch` that the comptime exhaustiveness sweep can cover, per
`ozai/AGENTS.md:78-81`.

### 7.8 Unreachable is a claim

Rule: `ozai/AGENTS.md:82-84`.

| Upstream site | Source | Port treatment |
|---|---|---|
| `nodes.remove(&id).unwrap()` | `accesskit_consumer/src/tree.rs:367` | `unreachable`, comment: "the caller put this id in `unreachable`, so it is present" |
| `node_by_id(*id).unwrap()` in `process_changes` | `accesskit_consumer/src/tree.rs:642`, `:646-647`, `:675` | `unreachable`, comment naming the change-set invariant |
| `root()` unwrap | `accesskit_consumer/src/tree.rs:514` | `unreachable`, comment: "`validate_global` ran at the end of the last update" |
| `focus_in_tree()` unwrap | `accesskit_consumer/src/tree.rs:531` | `unreachable`, same reason |
| `subtree` unwrap in `compute_effective_focus` | `accesskit_consumer/src/tree.rs:111` | An explicit `error.FocusOnGraftWithoutSubtree`, because an application can cause it |
| `graft child` unwrap in `child_ids` | `accesskit_consumer/src/node.rs:161-166` | `unreachable` plus a comment, or a documented empty iterator |

Every `unreachable` needs a comment saying why the case is impossible. Every case that an
application can reach needs an error variant instead. Section 4.6 splits the 15 panic sites
into those two groups.

### 7.9 Determinism

Rule: `ozai/AGENTS.md:85-88`.

| Source of nondeterminism | Upstream | Port |
|---|---|---|
| Map iteration order | `hashbrown::HashMap` has a randomized hasher seed per process, so `process_changes` callback order varies run to run (`accesskit_consumer/src/tree.rs:641`, `:645`, `:674`) | `std.array_hash_map.Auto` preserves insertion order, so the callback order is a function of the update. This is a fix, not a port defect. |
| Random tree ids | `Uuid::new_v4` in the doc comment at `accesskit/src/lib.rs:739-740` | The `TreeId` generator takes `io`, so a test injects a deterministic `io`. See Q1. |
| Wall clock | Not read by either core crate. The import blocks at `accesskit/src/lib.rs:13-18` and `accesskit_consumer/src/lib.rs:6-9` contain no time type. | The example reads `Instant::now()` at `example_common/src/lib.rs:207`. The port reads `io.now()` with an injected `io`. |
| Hash function | `hashbrown`'s default hasher, selected at `accesskit_consumer/Cargo.toml:16` | `std.array_hash_map.Auto` uses `std.hash.autoHash` (`std/array_hash_map.zig:15`), which is deterministic for a fixed Zig version. |

The port gains real determinism where upstream had none. That is the intended outcome of
the rule.

### 7.10 Comptime exhaustiveness

Rule: `ozai/AGENTS.md:78-81`.

| Domain | Exhaustiveness sweep the port should write |
|---|---|
| `Role` | 182 values. `inline for` over `std.enums.values(Role)` asserting `@intFromEnum` equals the index. |
| `Action` | 22 values, plus a sweep proving `actionFromInt(22)` is `null`. Upstream writes this test by hand at `accesskit/src/lib.rs:3482-3509`. |
| `PropertyId` | 88 values including `Unset`. A sweep proving each has a getter, a setter, and a clearer. |
| `UpdateError` | 13 values, one malformed `TreeUpdate` each. Section 4.6 gives the inputs. |
| `FilterResult` | 3 values, in the filter. |
| `ActionData` | 8 variants, one `ActionRequest` each. |

The Zig enum's own exhaustiveness checking covers the `switch` sites for free. The sweeps
above cover the value ranges, which no compiler check covers.

## 8. Open questions

Each question states what the source does not settle, the evidence that leaves it open,
the options, and a recommendation. `docs/30-port-design.md` must answer every one.

### Q1: Who owns `TreeId` generation, and how does it get randomness?

Open because upstream has no generator function. `TreeId` is `#[repr(transparent)] pub
struct TreeId(pub Uuid)` (`accesskit/src/lib.rs:745`) and the only constructor is
`TreeId::ROOT` (`accesskit/src/lib.rs:749`). The doc comment tells the application to "use
a random UUID (version 4)" (`accesskit/src/lib.rs:739-740`), but the crate provides no
function that does it. The application calls `Uuid::new_v4()` itself, through the re-export
at `accesskit/src/lib.rs:32`.

Options:

| Option | What it means | Cost |
|---|---|---|
| A | Pin a Zig UUID package. `alexrios/uuid` 2.0.0 is the strongest match found (section 1.7). | One dependency. Zig 0.16 compatibility unverified. |
| B | Write `TreeId` and `TreeId.random(io)` in the port. 16 bytes, one nil constant, one function that writes 16 bytes and sets the version 4 and variant bits. | About 40 lines. No dependency. |
| C | Have the application supply the 16 bytes. | The application must not get this wrong, and the port cannot test it. |

Recommendation: **B**, then **A** only if a package proves itself. The smallest honest
version is small enough that a dependency is not justified. Whatever is chosen, the
generator takes `io: std.Io` and returns `error{EntropyUnavailable}!TreeId` if it uses
`std.Io.randomSecure` (`std/Io.zig:2485`), so a test injects a deterministic `io` per rule
`ozai/AGENTS.md:85-88`.

### Q2: Does the port need the example application, and does it need a clock?

Open because `example_common` is the only complete producer, and it reads the clock:
`self.pending_announcement = Some((text, Instant::now()));` at
`example_common/src/lib.rs:207`, then compares against `ANNOUNCEMENT_DELAY`
(`example_common/src/lib.rs:68`, `:231-234`).

Options:

| Option | What it means |
|---|---|
| A | Port `example_common` as a test harness inside the repository. Then the port needs `io.now()`, which is an `io` parameter on `UiState` methods. |
| B | Do not port `example_common`. Write a smaller producer directly in the test suite, driven by explicit inputs, with no clock at all. |
| C | Port `example_common` as a separate binary outside the packaged paths in `build.zig.zon`. |

Recommendation: **B**. The live-region delay exists to make a demo readable, not to test
the protocol. A test that needs a delay can inject a fake timestamp. This keeps the core
crates clock-free, which rule `ozai/AGENTS.md:61-63` requires: "Logic never reads
clock/env/cwd".

### Q3: Is `ActionData.value` owned or borrowed?

Open because the two uses pull in opposite directions.

* In the core type, `ActionData` is a plain enum
  (`accesskit/src/lib.rs:3305-3321`) with `Value(Box<str>)` at `:3307`. That is owned.
* In an `ActionRequest` crossing a thread boundary, it must stay owned, because
  `do_action` returns `void` (`accesskit/src/lib.rs:3372`) and the adapter may hold the
  request in a queue after the call returns.
* In a `Node` property slot, `PropertyValue` holds an owned `String`
  (`accesskit/src/lib.rs:860`), also owned.

Section 2.4 mapped `ActionData.value` to `[]const u8`, which is borrowed. That is right for
a `PropertyValue` payload borrowed from the node and wrong for a queued request.

Recommendation: two distinct types. `ActionData` holds `[]u8` owned, because it is the
type that crosses the channel. Any borrowed use goes through a separate
`actionDataRef(&const ActionData) ActionDataRef` function that returns borrowed views. One
name per thing, per rule `ozai/AGENTS.md:44`. The cost is an owned copy in the borrowed
path, which the house performance rule at `ozai/AGENTS.md:91-93` forbids on a hot path.
`docs/30-port-design.md` must measure before choosing.

### Q4: How does the port handle `NodeRef` borrows?

Open because `NodeRef<'a>` borrows two things at once:
`pub tree_state: &'a TreeState`, `pub(crate) state: &'a NodeState`
(`accesskit_consumer/src/node.rs:78-82`). The Rust lifetime ties both to one borrow of
the tree, which makes 78 methods safe by construction.

Options:

| Option | What it means | Cost |
|---|---|---|
| A | Two raw pointers in `NodeRef`, plus a documented contract. | Fastest. Unsafe contract that a reviewer must police. |
| B | An arena that pins the tree, with `NodeRef` holding a slot index. | One allocation. Slower. Removes the aliasing risk. |
| C | `NodeRef` holds `*const TreeState` plus a `FullNodeId`, and looks up the node each call. | One hash lookup per method call. Slower, simplest contract. |

Recommendation: **A**, with `comptime` assertions on sizes and a `docs/30-port-design.md`
decision to state that `NodeRef` must not outlive the `Tree`. The upstream code never
mutates a `Tree` while a `NodeRef` is alive, so the contract is easy to state and easy to
check by reading. The measurement in Q3 settles whether C is needed on any hot path.

### Q5: What replaces the recursive filters and walks?

Open because `common_filter` recurses on the parent
(`accesskit_consumer/src/filters.rs:60`), and `is_focusable` calls
`supports_action` which walks parents (`accesskit_consumer/src/node.rs:687-699`).
Recursion depth is the node depth, which an application controls.

Options:

| Option | What it means |
|---|---|
| A | Keep recursion and add a depth counter that returns `unreachable` past a fixed bound. |
| B | Convert to an explicit stack bounded by `nodes.count()`. |
| C | Precompute the filter result per node at update time. |

Recommendation: **A** for the filters, because the depth is normally under 50 and the
recursion reads better. Add a `max_filter_depth` comptime constant and assert on it.
Option C is attractive because it moves work off the platform thread, but it changes the
cost profile of every update, and no measurement exists yet.

### Q6: Do the two core crates stay one module or split?

Open because house rule `ozai/AGENTS.md:200-201` caps a module at 250 pure lines and
requires a split by responsibility. Both upstream files are far past that:

| Rust file | Lines | Zig file | Pure lines after removing doc comments |
|---|---|---|---|
| `accesskit/src/lib.rs` | 3698 | `accesskit.zig` | about 1400, of which 340 is enum variant lists |
| `accesskit/src/geometry.rs` | 866 | `geometry.zig` | about 500 |
| `accesskit_consumer/src/tree.rs` | 3224 | `consumer/tree.zig` | about 1100 |
| `accesskit_consumer/src/node.rs` | 2120 | `consumer/node.zig` | about 800 |
| `accesskit_consumer/src/text.rs` | 2836 | `consumer/text.zig` | about 1000 |
| `accesskit_consumer/src/iterators.rs` | 1060 | `consumer/iterators.zig` | about 400 |
| `accesskit_consumer/src/filters.rs` | 421 | `consumer/filters.zig` | about 150 |

`accesskit.zig` at 1400 pure lines is 5.6 times the cap. The split must be by
responsibility, not by length. The natural seams are the ones the upstream file already
has: enums, geometry, node property storage, tree types, handler traits.

Recommendation: split by the seams listed above, with each file holding one responsibility
and one public entry point. `docs/30-port-design.md` owns the final module list. Do not
create a `utils.zig`. The house rule forbids it at `ozai/AGENTS.md:200-201`.

### Q7: Does the port need a serialiser at all?

Open because both `serde` and `schemars` are optional and off by default
(`accesskit/Cargo.toml:28-29`), so the shipped crate has no wire format. The 0.25.1 release
added one thing, and it was a schema line, at `accesskit/src/lib.rs:3153`.

Options:

| Option | What it means |
|---|---|
| A | No serialiser. The C header is the only external contract. This matches the default upstream build. |
| B | Add a compact binary codec for the C boundary. New design work with no upstream reference. |
| C | Add a JSON codec matching the `schemars` output. Large, and the schema is upstream's, not the port's. |

Recommendation: **A**. The C ABI document owns the boundary, and a hand-written header
cannot use a Rust serialiser anyway. If a codec is needed later, it is new work with new
tests, not a port.

### Q8: Which platform adapter is the first milestone?

Open because the adapter set is large and the threading model is the only thing that
differs between them (`ARCHITECTURE.md:52`: "the main difference between platform APIs
is the threading model"). The unix AT-SPI path needs D-Bus. The winit path needs a window
system loop.

Recommendation: start with the headless core, prove the update protocol with a fake
platform, then add one adapter. `docs/40-plan.md` owns the order.

### Q9: Should `Node` keep the private-field shape?

Open because `Node`'s five fields are private
(`accesskit/src/lib.rs:1107-1113`) and all 336 accessors are generated. In Zig a private
field is only private within one file. If the split in Q6 puts `Node` in its own file and
`PropertyValue` in another, `Properties.values` becomes reachable.

Options:

| Option | What it means |
|---|---|
| A | Keep `Node` and the property storage in the same file, so privacy holds. One file, over the line cap. |
| B | Split, and accept that `PropertyValue` is reachable from outside. Add a `docs/ARCHITECTURE.md` note. |
| C | Split, and make the fields `pub` with a naming convention that marks them internal. |

Recommendation: **B**. Zig has no module-private. The house rule at
`ozai/AGENTS.md:200-201` beats upstream's privacy, because the port must be navigable. The
`docs/30-port-design.md` file must state that direct field access is forbidden and the 336
accessors are the only supported path, and a `zlint` rule should reject a direct
`properties.values` reference outside the property module.

### Q10: What is the fixed upper bound for each unbounded loop?

Open because upstream has nine unbounded loops (section 7.6) and no count that is tight.

Recommendation: derive each bound from a quantity the caller already has, and assert it.

| Loop | Bound | Assertion |
|---|---|---|
| `compute_effective_focus` | `subtrees.count() + 1` | `unreachable` past the bound, comment names the single-graft-per-subtree invariant |
| `traverse_unreachable` | `nodes.count()` | `unreachable`, comment names the one-removal-per-iteration fact |
| `traverse_subtree` | `nodes.count()` | same |
| `subtree removal` | re-read `subtrees_to_remove.items.len` each iteration | same |
| `is_focused` walk | `nodes.count()` | `error.ActiveDescendantCycle` |
| `deepest_first_child` | `nodes.count()` | `error.TreeCycle` |
| `deepest_last_child` | `nodes.count()` | `error.TreeCycle` |
| `is_descendant_of` | `nodes.count()` | `error.TreeCycle` |
| `transform` walks | `nodes.count()` | `error.TreeCycle` |
| `Position` movements | count of text runs | `unreachable`, comment names the finite run list |

Five of these become reachable errors an application can trigger, so they join
`UpdateError` or a new `WalkError`. `docs/30-port-design.md` owns the final set.

### Q11: Does `Size.mulScalar` need the reversed operand order?

Open because Rust defines both `f64 * Size` (`accesskit/src/geometry.rs:612`) and
`Size * f64` (`accesskit/src/geometry.rs:621`). Section 3.6 proposes keeping only
`Size.mulScalar`. No call site in the two core crates was checked for the reversed order.
`[INFERENCE]` The adapters were not searched for this document, because the brief scoped it
to the core crates. `docs/12-accesskit-adapters.md` must confirm.

### Q12: Do the filtered iterators allocate?

Open because section 3.10 flagged `gpa` for the five filtered iterators. The struct
definitions suggest they do not: `FilteredChildren` holds a `back: Option<NodeRef>` and a
`done: bool` rather than a buffer (`accesskit_consumer/src/iterators.rs:477-482`). The
filter body was not read past the declaration list, so this stays an inference.
`docs/30-port-design.md` should settle it by reading `accesskit_consumer/src/iterators.rs`
in full before fixing the signatures.

### Q13: Is `deinit` part of every public type's contract, or is it an arena?

Open because Zig has no `Drop`. The port must free `Properties.values`, every
`std.ArrayList` inside a `PropertyValue`, every `Node`, every `TreeState` map, and every
`TreeUpdate`. The alternative is one arena per `Tree`.

| Option | What it means | Cost |
|---|---|---|
| A | Explicit `deinit(gpa)` on `Node`, `Properties`, `PropertyValue`, `TreeUpdate`, `TreeState`, `Tree`. | Every call site must remember. The failing-allocator test at `ozai/AGENTS.md:73-75` proves each `errdefer`. |
| B | One arena per `Tree`, freed once. | The 0.25.0 buffer-reuse change (section 4.10) survives, because `ArrayList` capacity is per-object. But a single leaked property frees the whole tree. |

Recommendation: **A**, because the house rule asks for fail-N injection
(`ozai/AGENTS.md:73-75`), and an arena makes per-object leak detection impossible. The cost
is real, and the port must test it.

## 9. Rust-toolchain removal

The finished project must build with no Rust compiler, no `cargo`, no `rustc`, and no Rust
build tooling. The repository must contain no `Cargo.toml`, no `Cargo.lock`, no
`build.rs`, no `cbindgen`, and no `rust-toolchain` file. This section lists every upstream
construct that exists only because of Rust, states that it is removable, and gives the
Zig replacement. Every row is checked in the two core crates and `example_common`, which
is the scope of this document. `docs/11-accesskit-c-abi.md` covers the header generator and
`docs/12-accesskit-adapters.md` covers the adapters.

### 9.1 Rust-only constructs and their Zig replacements

| Upstream construct | Source | Why it exists in Rust | Removable | Zig replacement |
|---|---|---|---|---|
| `impl From<NodeIdContent> for NodeId` | `accesskit/src/lib.rs:717-722` | Rust has no implicit conversion between a newtype and its field | yes | Public field `value: u64` on the struct (rule Z4) |
| `impl From<NodeId> for NodeIdContent` | `accesskit/src/lib.rs:724-729` | Same | yes | Public field, no accessor |
| `impl From<bool> for Toggled` | `accesskit/src/lib.rs:492-500` | Rust has no `From<bool>` for an enum | yes | `pub fn toggledFromBool(value: bool) Toggled` |
| `impl From<(f64,f64)> for Point` | `accesskit/src/geometry.rs:239-251` | Rust tuples | yes | Deleted. Zig has no tuples. Callers pass two `f64` values. |
| `impl From<(f64,f64)> for Size` | `accesskit/src/geometry.rs:691-706` | Same | yes | Deleted |
| `impl From<(f64,f64)> for Vec2` | `accesskit/src/geometry.rs:747-759` | Same | yes | Deleted |
| `impl From<(Point,Point)> for Rect` | `accesskit/src/geometry.rs:348-352` | Same | yes | `rectFromPoints(p0, p1)` already exists at `:411` |
| `impl From<(Point,Size)> for Rect` | `accesskit/src/geometry.rs:354-358` | Same | yes | `rectFromOriginSize(origin, size)` already exists at `:421` |
| `impl From<FullNodeId> for u128` | `accesskit_consumer/src/node.rs:46-52` | Rust has no way to reinterpret a struct as an integer | yes | `pub fn toU128(self: FullNodeId) u128` with the same bit order |
| `impl Add/Sub/Mul/Div` operator traits | `accesskit/src/geometry.rs:253-325`, `:602-689`, `:761-866` | Rust has operator overloading | yes | Named methods by rule Z2. See section 3.6. |
| `impl MulAssign` and `DivAssign` | `accesskit/src/geometry.rs:262`, `:269`, `:294`, `:310`, `:602`, `:633`, `:666`, `:684`, `:771`, `:795`, `:817`, `:849` | Rust compound-assignment traits | yes | `xAddAssign(self: *T, ...)`, one method per trait |
| `impl Neg for Vec2` | `accesskit/src/geometry.rs:856-866` | Rust unary negation | yes | `pub fn negate(self: Vec2) Vec2` |
| `#[derive(Clone)]` on `PropertyValue`, `Properties`, `Node` | `accesskit/src/lib.rs:855`, `:1070`, `:1102` | Rust derive macros | partly | Deleted. The hand-written `clone` and `cloneFrom` from commit `97194ad` replace them (section 4.10). |
| `#[derive(Serialize, Deserialize)]` | `accesskit/src/lib.rs:1103`, `:3204`, `:3324`, and every `#[cfg_attr(feature = "serde", ...)]` at `:49`, `:276`, `:404`, `:712`, `:757`, `:830`, `:843` | The `serde` derive macro | yes | Deleted. Q7 recommends no serialiser. |
| `#[derive(JsonSchema)]` | `accesskit/src/lib.rs:1104`, `:3036-3160` | The `schemars` derive macro | yes | Deleted. Q7. |
| `#[cfg_attr(feature = "pyo3", pyclass(...))]` | `accesskit/src/lib.rs:52-60` and 20 more sites | Python bindings | yes | Deleted |
| `macro_rules! flag_methods` and 14 other property macros | `accesskit/src/lib.rs:1170`, `:1222`, `:1235`, `:1248`, `:1261`, `:1271`, `:1281`, `:1299`, `:1319`, `:1334`, `:1347`, `:1400`, `:1412`, `:1447`, `:1482`, `:1517`, `:1552`, `:1587`, `:1622`, `:1667`, `:1704`, `:1743`, `:1778`, `:2794`, `:2806`, `:3019`, `:3029` | Rust macros | yes | Comptime-generic functions or a `switch` over `PropertyId`. See 9.2. |
| `Box<Affine>` and `Box<TextSelection>` in `PropertyValue` | `accesskit/src/lib.rs:881`, `:883` | Rust heap indirection to shrink an enum | yes | Plain `Affine` and `TextSelection` payloads. L3 sizes the union from the largest payload, so the box buys nothing. |
| `Vec<T>` and `String` payloads | `accesskit/src/lib.rs:858`, `:860`, `:866-867`, `:1073` | Owned growable buffers, allocator from a global | yes | `std.array_list.Aligned(T, null)`, which stores no allocator (`std/array_list.zig:570`) |
| `HashMap` and `HashSet` | `accesskit_consumer/src/tree.rs:9` and every use | `hashbrown`, allocator from a global, no insertion order | yes | `std.array_hash_map.Auto`, no allocator, insertion order (`std/array_hash_map.zig:88-98`) |
| `NodeRef<'a>` with a lifetime | `accesskit_consumer/src/node.rs:78-82` | Rust borrow checker | yes | `*const TreeState` plus `*const NodeState`. See Q4. |
| `Option<T>` | `accesskit/src/lib.rs:3235`, `:3332`, `accesskit_consumer/src/node.rs:89` | Rust absence marker | yes | `?T` |
| `panic!` | 15 sites, the first at `accesskit_consumer/src/tree.rs:88`, listed in section 4.6 | Rust abort | yes | `UpdateError` variants |
| `unwrap()` and `unwrap_or_else` | `accesskit_consumer/src/tree.rs:367`, `:404`, `:436`, `:514`, `:531`, `:643`, `:647`, `:675`, `:681`, `:687`, `:691` | Rust panic on a violated invariant | yes | `unreachable` with a why-comment, or an error variant where an application can cause it |
| `unsafe` | none in either core crate, confirmed by the import blocks at `accesskit/src/lib.rs:13-18` and `accesskit_consumer/src/lib.rs:6-9` | none | n/a | The port may use it for Q4 |
| `#[repr(C)]`, `#[repr(u8)]`, `#[repr(transparent)]` | `accesskit/src/lib.rs:61`, `:288`, `:416`, `:714`, `:744`, `:833`, `:846`, `:800`, `:892`, `:3270`, `:3290`, `:3304`. `accesskit/src/geometry.rs:21`, `:211`, `:336`, `:570`, `:716` | Rust layout control for the C ABI | partly | `extern struct` for L4, explicit `enum(u8)` for L2. `repr(transparent)` carries no meaning for a single-field struct, so L8 applies and no `packed struct` is used. |
| `#[deprecated]` | `accesskit/src/lib.rs:3178` | Rust deprecation | yes | Deleted |
| `no_std` attribute | `accesskit/src/lib.rs:11`, `accesskit_consumer/src/lib.rs:6` | Rust feature | n/a | Not needed. Zig has no `std` dependency unless imported. |

### 9.2 What replaces the 26 `macro_rules!` macros

The macros generate 324 of the 336 `Node` methods. Zig has `comptime`, which is a better
fit, because a generated function is type-checked once per instantiation rather than
expanded textually.

| Macro | Source | Zig replacement |
|---|---|---|
| `flag_methods!` | `accesskit/src/lib.rs:1170-1220` | 18 explicit functions per flag would be 54 functions. Better: one `pub fn setFlag(self: *Node, flag: Flag) void`, one `clearFlag`, one `isFlagSet`, plus 54 thin wrappers only if the C ABI needs them. |
| `property_methods!` and the 12 family macros | `accesskit/src/lib.rs:1222-1824` | One generic function per value shape. `pub fn getProperty(comptime T: type, self: *const Node, id: PropertyId) ?T`, plus `setProperty`, `clearProperty`, `pushProperty`. Then 270 one-line wrappers, or expose the generic and let callers pass the comptime tag. |
| `serialize_property!`, `deserialize_property!` | `accesskit/src/lib.rs:2794-2818` | Deleted with `serde` |
| `add_schema_property!`, `add_properties_to_schema!` | `accesskit/src/lib.rs:3019-3033` | Deleted with `schemars` |

The decision between 270 wrappers and one generic call is a real fork, and
`docs/30-port-design.md` owns it. The C ABI wants 270 named functions. The pure Zig API is
better served by the generic. Recommendation: expose the generic as the primary API and
generate the wrappers only for the functions `docs/31-c-abi-design.md` names, so the
checked-in header has a fixed, small, reviewable list.

### 9.3 Upstream build steps the port replaces

| Upstream build input | Source | Port replacement |
|---|---|---|
| `accesskit/Cargo.toml` | `accesskit/Cargo.toml:1` | `build.zig.zon`. The only planned dependency is `zio`, already pinned at commit `2662fdc45997611b962b560c513c16963475a01b`. |
| `accesskit_consumer/Cargo.toml` | `accesskit_consumer/Cargo.toml:1` | None. Both crates are one Zig module each, or several, per Q6. |
| `enumn` derive | `accesskit/Cargo.toml:26` | A comptime table. `actionFromInt` is a `switch`. A comptime sweep covers all 22 values per `ozai/AGENTS.md:78-81`. |
| `serde` derive | `accesskit/Cargo.toml:28` | Deleted, Q7. |
| `schemars` derive | `accesskit/Cargo.toml:29` | Deleted, Q7. |
| `pyo3` module | `accesskit/Cargo.toml:27` | Deleted |
| `uuid` crate | `accesskit/Cargo.toml:23` | A Zig package or 40 lines of Zig, Q1 |
| `hashbrown` crate | `accesskit_consumer/Cargo.toml:16` | `std.array_hash_map.Auto` |
| `Cargo.lock` | `Cargo.lock` at the repository root, pinned by `accesskit/Cargo.toml:23` for `uuid` | None. `build.zig.zon` hashes each dependency at the commit, which is the same guarantee with no Rust toolchain. |

### 9.4 No Rust toolchain in the verification story

House rule `ozai/AGENTS.md:89-91` says a wire-compatibility claim is a golden-vector test
carrying bytes captured from the reference implementation. The constraint for this project
removes the ability to generate those vectors with `cargo`.

The port therefore uses a recorded fixture:

1. A fixture file is checked into the repository, under a path listed in `build.zig.zon`.
2. Each fixture carries a `TreeUpdate`, a `TreeId`, and a `Node` tree in a documented
   encoding, plus the expected resulting `TreeState` change set.
3. The fixture's provenance is recorded in a header comment: the upstream commit
   `466e24e252103f4d82bd6fbab98141b551e46e0c`, the file and line each value came from, and
   the date it was recorded.
4. A Zig test decodes each fixture, applies it, and compares the change set. No Rust runs.
5. A second test mutates each fixture and asserts the port detects the mutation, per
   `ozai/AGENTS.md:88`. A fixture that cannot detect a mutation is not evidence.

The fixtures this document names, all traceable to a path and line in the read-only
checkout:

| Fixture | Source | What it locks |
|---|---|---|
| `role_order` | `accesskit/src/lib.rs:63-271` | All 182 `Role` discriminants, in order |
| `action_order` | `accesskit/src/lib.rs:290-350` plus the test at `:3482-3509` | All 22 `Action` discriminants, and that 22 is null |
| `property_id_order` | `accesskit/src/lib.rs:894-1008` | All 87 property ids and `Unset == 87` |
| `flag_order` | `accesskit/src/lib.rs:802-820` | All 18 `Flag` positions |
| `node_property_equal` | the test at `accesskit/src/lib.rs:3392-3405` | Two nodes with the same properties compare equal whatever order they were set in |
| `node_property_cleared` | the test at `accesskit/src/lib.rs:3407-3414` | A cleared property equals one never set |
| `node_clone_from_buffer` | the tests at `accesskit/src/lib.rs:3435-3461` | `cloneInto` reuses the destination buffer, by pointer identity |
| `update_full_tree` | `accesskit_consumer/src/lib.rs:58-192` | A full first update produces the expected node set |
| `update_add_child` | `accesskit/src/lib.rs:3221-3223` | Adding a child with an updated parent |
| `update_remove_child` | `accesskit/src/lib.rs:3225-3228` | Removing a child and its descendants by updating the parent only |
| `update_graft` | `accesskit/src/lib.rs:2538-2545` and the panic at `accesskit_consumer/src/tree.rs:134-140` | A graft node must precede its subtree |

No fixture requires `cargo`. Every value was read from a source file at a named line, which
is stronger provenance than a captured byte stream, because a reviewer can check it without
running anything.

### 9.5 The Zig-first dependency ladder for this document

The ladder is: Zig standard library, then a pinned Zig package, then a Zig `translate-c`
binding to a system C library, then a hand-written C shim. Every dependency of the two core
crates gets a rung.

| Dependency | Upstream source | Rung | Justification |
|---|---|---|---|
| Hash map, insertion ordered | `hashbrown`, `accesskit_consumer/Cargo.toml:16` | **1** | `std.array_hash_map.Auto` exists, stores no allocator, and preserves insertion order (`std/array_hash_map.zig:44-60`). A higher rung is not needed. |
| Growable byte list | `Vec`, `accesskit/src/lib.rs:858` | **1** | `std.array_list.Aligned(T, null)` exists and stores no allocator (`std/array_list.zig:570`). |
| Slice and optional | Rust primitives, used at `accesskit/src/lib.rs:1073` | **1** | Zig builtins |
| Lock | `Mutex` and `RwLock` at `adapters/atspi-common/src/context.rs:21` and `:36-39` | **1** | `std.Io.RwLock` exists and takes `io` (`std/Io/RwLock.zig:28-133`) |
| Randomness | `Uuid::new_v4` implied at `accesskit/src/lib.rs:739-740` | **1** | `std.Io.random` and `std.Io.randomSecure` exist (`std/Io.zig:2468`, `:2485`). Only the UUID bit layout needs writing, which is Q1. |
| Integer to enum | `enumn`, `accesskit/Cargo.toml:26` | **1** | A Zig `switch`. No package needed. |
| Serialisation | `serde`, `accesskit/Cargo.toml:21` | not reached | Q7 recommends none. |
| UUID | `uuid`, `accesskit/Cargo.toml:23` | **2** or hand-written | No standard library type. 12 candidate packages found on `zigpkg.dev` (section 1.7). Recommendation is to write it, which is rung 1 plus 40 lines. |

No C library appears in the two core crates. The core crates are platform independent, so
there is no rung 3 or rung 4 dependency here at all. The C dependencies live in the
adapters, which `docs/12-accesskit-adapters.md` covers.

## 10. Summary for the port design

The facts a port author needs from this document, collected.

| Area | Fact | Section |
|---|---|---|
| Size | 4564 lines of Rust across two core crates, of which about 70 percent is doc comment | 1.2 |
| Size | 9871 lines of Rust in `accesskit_consumer` | 1.3 |
| Public surface | 30 public types, 3 traits, 336 `Node` methods, 60 geometry functions | 1.2, 1.5, 2.5 |
| Properties | 87 properties, each with a getter, a setter, and a clearer. 9 add a pusher | 1.5 |
| Flags | 18 flags, each with three methods | 1.5 |
| Layout | 13 types have a fixed size that a `comptime assert` must lock | 2 |
| Threads | Neither core crate has a lock, a thread, or an `io`. All concurrency is in the adapters | 6.1, 6.2 |
| Update | One function, `TreeState::update`, 362 lines, nine panics, two maps, four sets | 4.4, 4.6 |
| Reuse | Implicit, by node id. No reuse flag, no generation counter | 4.8 |
| Action channel | A mutex around a handler, inside an `Arc` trait object, in the adapter. The core owns none of it | 5.2 |
| Buffers | Commit `97194ad` made `cloneFrom` reuse the destination. This is why `Properties.cloneInto` takes `gpa` and returns `!` | 4.10 |
| Loops | Nine unbounded loops upstream. Every one needs a derived bound and a paired assertion | 7.6, Q10 |
| House rules | The core crates satisfy `io` threading vacuously and fight allocators, error sets, loop bounds, and determinism | 7 |
| Rust removal | 40 Rust-only constructs, all removable. 26 `macro_rules!` macros become comptime generics | 9.1, 9.2 |
| Verification | 11 recorded fixtures, none needing `cargo` | 9.4 |
| C dependencies | None in the core crates | 9.5 |

The next document, `docs/30-port-design.md`, turns this map into module boundaries, the
exact Zig signatures, the fixture format, and the answers to Q1 through Q13.
