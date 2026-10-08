# 30 — The design of `zaccesskit`, a pure Zig port of the AccessKit toolkit

The package publishes a native Zig module and a C library.
The contracts below separate source structure from run evidence in `docs/50-verification.md`.

**Consumes.** The 29 documents under `docs/`, `local://zaccesskit-risk-register.md`
and `local://zaccesskit-deps.md`, plus four read-only upstream checkouts at the revisions in section
1.2. **Consumed by.** `docs/31-c-abi-design.md` for the C seam, `docs/40-plan.md` for the milestone order, `docs/50-verification.md` for the evidence each milestone produces.

**Proof labels.** Source reading, exercised compilation, and runtime observation are separate evidence classes.
`docs/50-verification.md` records observed checks and their limits.
Section 12 records the implemented contracts for steps 1–4.
Older implementation sketches and module budgets remain design history, not current source or measured sizes.
---
## 1. The pin and the surface
### 1.1 The compiler line
**Zig 0.16.0.** `build.zig.zon` sets the compiler floor.
`build.zig:75-84` registers the native module with `zio`, `build_options`, and `win32` imports.
The module honors the selected target and optimization mode.

| Rung of the build ladder | What it is | State of `zaccesskit` |
|---|---|---|
| manifest floor | a declared lower bound | **present.** `build.zig.zon:11` |
| declared target | a target a build script names | **present.** `b.standardTargetOptions(.{})` at `build.zig:35` |
| configured CI | a compiler wired into a build path at that revision | **absent.** No CI configuration file exists |
| reached build | a build on a named target and mode | See `docs/50-verification.md` |
| observed run | an executed binary | See `docs/50-verification.md` |

A declared step is a declared target, not a reached build: under lazy analysis a declaration no analysed path references is never analysed, so even a green default build certifies only the paths
that build reaches.
### 1.2 The upstream revisions, at full length

| What | Repository | Revision | Version |
|---|---|---|---|
| Core crate | `github.com/AccessKit/accesskit` | `466e24e252103f4d82bd6fbab98141b551e46e0c` | `accesskit` 0.25.1, `accesskit_consumer` 0.39.1 |
| C bindings | `github.com/AccessKit/accesskit-c` | `8b6ed37c20ed4c59390e253407983333053662ba` | `accesskit-c` 0.23.1 |
| Historical D-Bus probe, not the implemented transport | `github.com/luxluth/goose`, tag `v3.3.0` | `8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1` | 3.3.0 |
| Runtime | `github.com/lalinsky/zio` | `2662fdc45997611b962b560c513c16963475a01b` | 0.18.0 |

Every `lib/std` citation in this document is `ziglang/zig` at `24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8`.

`accesskit-c/include/accesskit.h` defines the ABI. The core supplies the types the header was generated from, and the header also carries entry points the core crate does not have, so a port
cannot read the core alone. The two crates are not in skew: `accesskit-c/Cargo.toml:20` pins `accesskit = "0.25.1"`, and the core manifest lists each adapter crate on its own version line, so
the two repositories release on separate trains.

```text
Evidence: The bindings crate depends on the core crate by version, and the core manifest lists each adapter crate on its own version line. Subject:  AccessKit/accesskit-c @
8b6ed37c20ed4c59390e253407983333053662ba Source:   Cargo.toml Reads as: The dependency declaration at that revision. It establishes which core version the header was generated against, and nothing
about how upstream intends to version the header in future.
```
### 1.3 The bounded supported consumer surface
Two routes define the supported surface.
`dep.module("zaccesskit")` publishes `schema`, `consumer`, `capi`, `adapters`, `Runtime`, `version`, and `minimum_zig_version`.
The schema and consumer namespaces provide native value types, tree queries, and the update protocol.
`adapters` publishes five platform namespaces. `Runtime` is the same pinned zio runtime type used by the adapters.
There is no separate root `handlers` namespace. The handlers belong to `schema`.
Source: `src/root.zig:36-64`, `src/adapters/root.zig:6-10`.
The C route consists of the installed header and linked library.
`docs/31-c-abi-design.md` owns its symbols and ownership rules.
### 1.4 What this package publishes
The package publishes both routes through the build graph.

| Route | Published? | What a consumer asks for |
|---|---|---|
| Registered module | yes, declared | `dep.module("zaccesskit")` |
| C library, static or dynamic | yes, declared at `build.zig:86-102` | `dep.artifact("zaccesskit")`. Set `.linkage = .static` or `.dynamic` in dependency options |
| Shipped header | yes | The library installs `include/zaccesskit.h` as `zaccesskit.h` |
| Named sub-modules, build-script re-export | no | none |

`addModule` registers while its neighbour `createModule` does not. That one function name is the whole published-versus-present boundary, and a `pub` declaration is not a published API: the
supported route is the root re-export list, and a documented alternate route becomes published when documented.

```text
Evidence: Two adjacent functions create modules; `addModule` additionally registers the module by name and `createModule` does not. Subject:  ziglang/zig @ 24fdd5b7a4c1c8b5deb5b56756b9dbc8e08c86a8,
stable-0.16 Source:   lib/std/Build.zig Reads as: Two declarations. It establishes that the public/private boundary for modules is one function name apart and lives in the build graph, and
nothing about whether any package picked the wrong one.
```
### 1.5 What is not claimed
This contract does not claim native platform execution, Unix bus delivery, or Rust reference execution.
`docs/50-verification.md` records checks for the pinned source and their exact limits.
---
## 2. The architecture in one page

Three loops, kept separate. Each has its own failure vocabulary, its own allocator discipline and its own test strategy.

```mermaid
graph TD subgraph pure["Loop 1 — the pure core: src/schema and src/consumer"] update["TreeUpdate (bytes already decoded)"] --> state["TreeState.update"] state --> changes["InternalChanges"] -->
handler["TreeChangeHandler"] end subgraph seam["Loop 2 — the platform interface"] act["ActivationHandler"] --- deact["DeactivationHandler"] actreq["ActionHandler"] end subgraph
io["Loop 3 — the platform adapter: src/adapters/"] bus["bus bytes"] --> codec["D-Bus codec, pure"] --> iface["org.a11y.atspi objects"] end iface -->|TreeUpdate| state iface -->|ActionRequest| actreq
act -->|TreeUpdate| update app["application"] -.->|supplies| act app -.->|supplies| actreq app -.->|supplies| deact
```

**Loop 1, the tree and the update protocol.** Pure. It takes a decoded
`TreeUpdate`, mutates its own `TreeState`, and reports what changed through `TreeChangeHandler`. It reads no clock, no socket, no handle, no global and no environment variable. Every allocator is a
parameter and every failure returns a value from a named error set. **Loop 2, the platform interface.** The seam: four vtables and nothing else, declaring data and owning no loop. No slot
reaches a platform type. **Loop 3, the platform adapter.** Owns every byte of I/O: it opens the bus,
decodes D-Bus messages, dispatches method calls onto the exported objects, and pushes `TreeUpdate` values into loop 1. It is the only place a `std.Io` handle reaches an operating system and the only
place a `*zio.Runtime` may spawn, group or arm a timeout.
### 2.1 Where `io` enters, and where `*zio.Runtime` is allowed
The rule: **blocking entry points take explicit I/O capabilities.**
Native transport owners also receive the runtime needed for owned tasks.
The pure schema and consumer layers need neither capability.
zio implements `std.Io` rather than replacing it.
Section 12.2 records the implemented constructor and lifetime contracts.

```text
Evidence: The two platform-neutral crates contribute 8253 non-test lines against a 250-pure-line house limit; the smallest module count respecting the limit is 33, and 47 is proposed at 176 lines
per module on average. Subject:  AccessKit/accesskit @ 466e24e252103f4d82bd6fbab98141b551e46e0c Source:   accesskit/src/lib.rs; accesskit/src/geometry.rs; accesskit_consumer/src/tree.rs Reads as:
A source reading of line counts at that revision. It establishes the input to the division and nothing about the port, whose size is unmeasured. A module count derived from a limit is a budget,
not an estimate.
```

> **Record R1 — the capability parameter is `std.Io`, never `*zio.Runtime`.** **Priority.** Keep the pure core
> testable without a runtime and the runtime substitutable behind one interface. **Constraint.** zio is one
> implementation behind `std.Io`, `Runtime.fromIo` returns `null` for another backend, and a zio-specific type
> would make `std.Io.Threaded` unusable as a test backend. **Cost imposed on consumers.** One `io: std.Io`
> parameter on every entry point that can block; a consumer needing a spawn, a group or a timeout constructs a
> zio runtime separately and passes `rt.io()` rather than the runtime. **The counterchoice**, a `*zio.Runtime`
> on every library signature, genuinely wins when a module needs `spawnBlocking`, per-task cancellation counters
> and `ev.PipePoll` at nearly every call site, because the cast back to `std.Io` is then free. The port loses
> here because the pure core would then need a runtime to run a unit test, and zio's runner builds a real
> `Io.Threaded` per test with no substitution. **Grade and origin.** taste · analyst-inferred, under a
> constraint that is a source reading at the pinned commit.

| Situation | Call | Why |
|---|---|---|
| Inside a zio task | `zio.spawn` | the current executor exists |
| From `main` or a C callback thread | `rt.spawn` | `getCurrentExecutor` has no executor and panics |
| A placement that must run here | `.auto` or `.executor` | `.local` returns `error.InvalidPlacement` off a loop thread |
### 2.2 What is deliberately absent

| Absent | Why | Owner |
|---|---|---|
| A toolkit bridge, and any X11, XCB or Wayland client | No upstream adapter translates them; the application pushes window bounds and focus state itself through two calls | `docs/14` section 3 |
| The deprecated `Tree` alias | `pub type Tree = TreeInfo` carries `#[deprecated]`; the house rule is delete, not deprecate | `docs/23` section 7.6 |
| A `Uuid` dependency | the core needs 16 opaque bytes, equality and a nil constant, and never calls generation, formatting or parsing | section 4.1 |
| Serde, schemars, pyo3 generators | they exist to generate other languages; the port's only generated surface is a hand-written header | `docs/31` section 4.1 |
| Fuzzing | `-ffuzz` does not compile in Zig 0.16.0, so no fuzz gate is promised | `docs/22` section 9.7 |
| A Python binding | no target consumer is Python | `docs/17` section 3 |
| A second async runtime | The implemented transport uses the pinned zio public socket and task APIs | section 12.2 |
---
## 3. The module layout

**Accept the 47-module proposal of `docs/23-core-boundary.md` section 7.2, with
the three splits it flags in section 7.4 applied, so the count is 50.** Two directories hold 50 modules, plus the C seam and the adapters. Every budget below is a target, not a measurement.

```text
Evidence: `PropertyId` is declared with 88 variants whose last is a sentinel `Unset` whose doc comment reads "This MUST be last", so the real property count is 87. Public properties total 105,
being 18 flags plus 87 stored properties. `Role` carries 182 variants and `Action` carries 22, both `#[repr(u8)]`. Subject:  AccessKit/accesskit @ 466e24e252103f4d82bd6fbab98141b551e46e0c Source:
accesskit/src/lib.rs Reads as: Four enum declarations and one array length at that revision. It establishes the counts and that the ordering is wire-visible, and nothing about how the port should
lay them out; the 87-byte index array is a fact about the upstream design, not a requirement on the port.
```
### 3.1 `src/schema/` — 23 modules

| Path | Upstream range | Owns | Budget |
|---|---|---|---:|
| `schema/geometry/affine.zig`, `point.zig`, `rect.zig`, `size.zig`, `vec2.zig` | `geometry.rs:22-866` | `Affine`, `Point`, `Rect` (20 methods), `Size`, `Vec2` | 530 |
| `schema/role.zig` | `lib.rs:62-271` | `Role`, 182 tags | 240 |
| `schema/node_enums.zig`, `scroll_enums.zig` | `lib.rs:417-700`, `:3271-3298` | 13 property enums, `ScrollUnit`, `ScrollHint` | 240 |
| `schema/action.zig` | `lib.rs:289-400` | `Action`, 22 tags, mask | 90 |
| `schema/ids.zig` | `lib.rs:703-750` | `NodeId`, `NodeIdContent`, `TreeId` | 90 |
| `schema/values.zig` | `lib.rs:761-855` | `CustomAction`, `TextPosition`, `TextSelection`, `Color`, `TextDecoration` | 90 |
| `schema/props/table.zig` | `lib.rs:801-1170` | `PropertyId`, `PropertyValue`, `Properties`, `Flag`, the comptime table | 240 |
| `schema/props/flags.zig` | `lib.rs:1909-1975` | 18 flag properties | 100 |
| `schema/props/ids.zig` | `lib.rs:2025-2095` | 15 node-id properties | 190 |
| `schema/props/strings.zig` | `lib.rs:2097-2205` | 21 string properties | 240 |
| `schema/props/numbers.zig` | `lib.rs:2207-2314` | 22 number properties | 240 |
| `schema/props/colors.zig`, `vectors.zig` | `lib.rs:2316-2425`, `:2679` | 6 colour and decoration properties, 5 list properties | 230 |
| `schema/props/enums.zig`, `option.zig` | `lib.rs:2427-2546` | 14 boolean and enum properties, 4 option properties | 270 |
| `schema/node.zig` | `lib.rs:1107-1113`, `:1828-1907` | `Node` and its 11 written methods | 150 |
| `schema/handlers.zig` | `lib.rs:3335-3385` | the 3 application vtables | 120 |
| `schema/update.zig` | `lib.rs:3162-3333` | `TreeInfo`, `TreeUpdate`, `ActionData`, `ActionRequest` | 180 |

One import-direction rule: `schema/update.zig` imports `schema/node.zig` because a `TreeUpdate` carries `Node` values. `schema/node.zig` must not import `schema/update.zig`, or the two could not
be analysed independently.
### 3.2 `src/consumer/` — 27 modules, with the three splits marked

| Path | Upstream range | Owns | Budget |
|---|---|---|---:|
| `consumer/filter.zig` | `filters.rs:11-101` | `FilterResult`, the two filters | 100 |
| `consumer/iterators/children.zig` | `iterators.rs:22-77`, `:477-586` | `ChildIds`, `FilteredChildren` | 150 |
| `consumer/iterators/following.zig`, `preceding.zig`, `sibling_scan.zig` | `iterators.rs:79-475`, `:255-340` | the two following, two preceding and two filtered-sibling iterators | 360 |
| `consumer/tree_index.zig`, `tree_validate.zig` | `tree.rs:15-57`, `:86-123` | `TreeIndex`, `TreeIndexMap`, the global invariant checks | 120 |
| `consumer/tree_apply.zig` | `tree.rs:124-260` | **split 1**: the per-node pass | 200 |
| `consumer/tree_grafts.zig` | `tree.rs:261-486` | **split 1**: grafts, removal, graft resolution | 200 |
| `consumer/tree_state.zig` | `tree.rs:59-83`, `:488-576` | `TreeState`, `SubtreeState`, the queries | 200 |
| `consumer/tree.zig` | `tree.rs:578-711` | `Tree`, `TreeChangeHandler`, `process_changes` | 200 |
| `consumer/node_id.zig` | `node.rs:30-77` | `NodeRef` | 90 |
| `consumer/node_ref/hierarchy.zig`, `geometry.zig` | `node.rs:84-395` | the 10 hierarchy queries, transforms, bounding boxes, hit tests | 350 |
| `consumer/node_ref/properties.zig`, `predicates.zig` | `node.rs:397-717` | raw and inherited property reads, the predicates | 380 |
| `consumer/node_ref/strings.zig`, `set_state.zig`, `containers.zig` | `node.rs:719-1103` | `labelled_by`, `label`, `write_label`, `value`, `write_value`, the container accessors | 430 |
| `consumer/text/position_inner.zig`, `position.zig` | `text.rs:16-332` | `InnerPosition`, the biased helpers, `Position`, the index-unit conversions | 360 |
| `consumer/text/position_motion.zig` | `text.rs:333-594` | 30 movement methods | 200 |
| `consumer/text/line_walk.zig` | `text.rs:107-141` | **split 3**: the two bounded walks | 60 |
| `consumer/text/range.zig` | `text.rs:595-931` | `Range`, `RangePropertyValue` | 240 |
| `consumer/text/hit_test.zig` | `text.rs:932-978` | **split 2**: the two hit-test functions | 70 |
| `consumer/text/inherited.zig` | `text.rs:980-1364` | **split 2**: 39 inherited accessors | 200 |
| `consumer/text/query.zig` | `text.rs:1365-1650` | the string-driven queries | 240 |

| Proposed module | Upstream range | Why it is cut | Result |
|---|---|---|---|
| `tree_apply.zig` | `tree.rs:124-486`, 363 lines in one body | three separable passes, each with one invariant to state | `tree_apply.zig` + `tree_grafts.zig` |
| `text/hit_test.zig` | `text.rs:932-1364`, two functions plus a 219-line macro block | the block has nothing in common with the two functions | `text/hit_test.zig` + `text/inherited.zig` |
| `text/position_motion.zig` | `text.rs:333-594`, 262 lines | the two unbounded line walks need their own bounded body, error tag and tests | `text/position_motion.zig` + `text/line_walk.zig` |

> **Correction, 2026-10-05, after the layer was built.** The
> `consumer/node_id.zig` row above said `FullNodeId`, `NodeRef` and `NodeState`
> are all declared in that file. Only `NodeRef` is. **`FullNodeId` is in
> `consumer/tree_index.zig`**, which holds the index map keyed on it, and
> **`NodeState` is in `consumer/tree_state.zig`**, whose `nodes` map holds it.
> `node_id.zig` owns `NodeRef` and nothing else, and it is the only file in the
> layer that may declare methods on it.
>
> The reason is ownership rather than layering: a type belongs to the module
> whose data structure holds it, so no module declares a type it does not own.
> A second copy of `NodeState` would make `NodeRef.state` a pointer to a
> different type than `TreeState.nodes` holds, and `nodeById` would not
> typecheck. `docs/33-consumer-interface-contract.md` section 2 claimed both
> blocks and is corrected to match.

### 3.3 `src/capi/` and `src/adapters/`
`docs/31-c-abi-design.md` owns `src/capi/`: `capi/root.zig` holds every `export fn` and the `accesskit_last_error` slot, `capi/header_check.zig` holds the reflection sweep, and
`capi/marshal.zig` holds the conversions between the Zig types and the `extern struct` forms.

`src/adapters/<platform>/` holds one directory per platform, in a fixed order: `atspi`, `windows`, `macos`, `ios`, `android`. AT-SPI first because it is the only adapter whose protocol runs on this
host against a live accessibility bus. Windows second because `build-exe` links its real system libraries here. macOS, iOS and Android follow with `build-obj` succeeding and `build-exe` failing.
The five adapters hold 20113 upstream Rust lines, which at the same limit is 81 to 101 further modules; `docs/40-plan.md` schedules them.
### 3.4 The property table, and what replaces 27 macros
**Where the table lives.** `src/schema/props/table.zig`, and nowhere else. It is
the single home of `PropertyId`, `PropertyValue`, `Properties`, and one `comptime` array of descriptors, one row per property.

```text
Evidence: `accesskit/src/lib.rs` declares 27 `macro_rules!` definitions between lines 1170 and 1778;
23 generate node properties and 4 generate Serde and Schemars code. The consumer crate declares two more. Subject:  AccessKit/accesskit @ 466e24e252103f4d82bd6fbab98141b551e46e0c Source:
accesskit/src/lib.rs; accesskit_consumer/src/text.rs Reads as: A shape-only card. It establishes that the macros exist and where, and nothing about what each expands to; the entry counts come from
`docs/23-core-boundary.md` section 6.2.
```

Discriminant order is pinned for all three enums: upstream orders `Role` by expected usage frequency
rather than alphabetically because a variable-length integer encoding depends on it, so a port that reorders them changes the serialized numbers.

**How the macros become Zig.** Zig has no macro system, so the 27 `macro_rules!`
definitions expand once by hand into explicit named functions. The 135 entries become 328 public methods and 48 private helpers upstream.

```text
Evidence: `adapters/unix/src/context.rs` declares two file-scope statics typed `OnceLock<Arc<RwLock<AppContext>>>` and `OnceLock<Sender<Message>>`, and `get_or_init_messages`
spawns an OS thread from inside the initialiser; `adapters/unix/src/atspi/bus.rs` holds `desktop: Arc<OnceLock<ObjectRefOwned>>`. Subject:  AccessKit/accesskit @
466e24e252103f4d82bd6fbab98141b551e46e0c Source:   adapters/unix/src/context.rs; adapters/unix/src/atspi/bus.rs Reads as: Three declarations and one initialiser at that revision. It
establishes that the state is process-global and that the thread starts inside a lazy initialiser, and nothing about why upstream chose it.
```

| Macro families, grouped | Entries | Port writes | Where |
|---|---:|---|---|
| `flag_methods` | 18 | 18 one-bit accessors over a `u32` | `props/flags.zig` |
| `option_ref_type_getters`, `slice_type_getters`, `copy_type_getters`, `copy_type_setters`, `owned_type_setters` | 50 | 50 borrow, value and owning accessors, each owner guarded with `errdefer` | `props/table.zig` |
| `vec_type_methods`, `length_vec`, `coord_vec`, `vec` property methods | 7 | list push, clear, borrow, and 4 list-property accessor sets | `props/vectors.zig` |
| `node_id_vec_property_methods`, `node_id_property_methods` | 15 | 15 id properties, 3 or 4 methods each | `props/ids.zig` |
| `string_property_methods` | 21 | 21 string properties, 3 methods each | `props/strings.zig` |
| `f64`, `f32`, `usize` property methods | 22 | 22 number properties, 3 methods each | `props/numbers.zig` |
| `color`, `text_decoration` property methods | 6 | 6 colour and decoration properties | `props/colors.zig` |
| `bool`, `unique_enum` property methods | 14 | 14 boolean and enum properties | `props/enums.zig` |
| `property_methods` | 4 | 4 option properties, including `tree_id` | `props/option.zig` |

The `comptime` table does the three jobs a macro did that a function cannot: the id-to-payload-type relation, the member count, and the bound for every loop over the property domain. One `comptime`
assertion pins that every tag of `@typeInfo(PropertyId).@"enum"` appears exactly once, so a property
added without a descriptor is a compile error.

**Three things the expansion drops**, each a decision rather than a translation.
The `PropertyIndices` byte array and the `Unset` sentinel, because the port stores a sorted slice of
`struct { id: PropertyId, value: PropertyValue }` and a cleared property leaves that slice, which is
the sentinel's idea through the type system. The `Box<Affine>` and `Box<TextSelection>` payloads, because a pointer in a union payload needs a recursive teardown and costs one allocation per node
per update. And position-based equality, because upstream compared by slot position until a separate
commit fixed it once clone buffer reuse broke the slot correspondence, and a sorted slice makes the comparison structural.
### 3.5 The root re-export list

The current root declares seven names:

```zig
pub const schema = @import("schema/root.zig");
pub const consumer = @import("consumer/root.zig");
pub const capi = @import("capi/root.zig");
pub const adapters = @import("adapters/root.zig");
pub const Runtime = @import("zio").Runtime;
pub const version = @import("build_options").version;
pub const minimum_zig_version = @import("build_options").minimum_zig_version;
```

`src/root.zig` checks the compiler floor and version shape.
Its namespace tests reach the declared schema, consumer, and C ABI exports.
The pure schema and consumer layers do not start a runtime.

> **Record R2 — the root carries namespaces, not a flat index.** **Priority.** Make the path carry the
> taxonomy. **Constraint.** The public names serve platform-adapter,
> application, and C adapter authors. **Cost imposed on consumers.** A consumer writes
> `zaccesskit.schema.Role`; every reorganisation of a subtree moves a spelling; a consumer who wants the short
> spelling in a signature waits for a second path and then both paths must be documented. **The counterchoice**,
> a flat index of explicit re-exports, the shape `lib/std/std.zig` ships, with `ArrayList` as a `pub fn` factory
> rather than a re-export, genuinely wins when the name set is a container layer and the path adds nothing, and
> it is greppable with no nesting. The port loses here because the set is three families and a flat index would
> not say which family a name belongs to. **Grade and origin.** taste · analyst-inferred; both shapes ship in
> one library at the pin and neither is a house rule.

The module import table supplies `zio`, `win32`, and `build_options`.
Consumers import the registered `zaccesskit` module rather than recreate that table.
The C library uses its separate `capi_root.zig` root.
---
## 4. The pure core
### 4.1 The identity types

```zig
// schema/ids.zig

/// The identifier of one node inside one tree.
pub const NodeId = extern struct { value: u64, pub fn format(self: NodeId, w: *std.Io.Writer) std.Io.Writer.Error!void { try w.print("#{d}", .{self.value}); } };

/// A 128-bit identifier for a tree, in the byte order the C header and the D-Bus
/// wire use. The port owns these bytes; it never parses or generates them.
pub const TreeId = extern struct { bytes: [16]u8,
    /// The all-zero identifier. This is the root tree.
pub const root: TreeId = .{ .bytes = @splat(0) }; };

/// A node id namespaced by its tree. Borrows nothing; it is two scalars.
pub const FullNodeId = struct { local: NodeId, tree_index: u32, };
```

`extern struct` on `NodeId` and `TreeId` is required, not cosmetic: both cross the C boundary, a plain `struct` is free to reorder, and `packed struct` drops the padding the C side computes.
### 4.2 The three count-bearing enums

```zig
// schema/role.zig — 182 tags, discriminant 0 through 181. Order is wire-visible.
pub const Role = enum(u8) { unknown = 0, text_run = 1,
    // ... 180 more tags, in upstream order, each with its upstream doc text
terminal = 181, pub const count = @typeInfo(Role).@"enum".fields.len; };

// schema/action.zig — 22 tags, one bit each in a u32 mask.
pub const Action = enum(u8) { click = 0,
    // ... 21 more tags
show_context_menu = 21, pub fn mask(self: Action) u32 { return @as(u32, 1) << @intFromEnum(self); } pub fn fromInt(value: u8) ?Action { return std.meta.intToEnum(Action, value); } };

// schema/props/table.zig — 87 tags. Upstream declares an 88th sentinel whose doc
// comment reads "This MUST be last"; the port has no sentinel and no `Unset`.
pub const PropertyId = enum(u8) { children = 0,
    // ... 85 more tags
custom_actions = 86, pub const count = @typeInfo(PropertyId).@"enum".fields.len; };
```

The 18 flags are a separate `u32` bit set with no `PropertyId`, reachable only through one-bit accessors. Comptime assertions pin `Action.count <= 32` and `PropertyId.count == 87`.
### 4.3 The property store, and node reuse

```zig
// schema/props/table.zig
pub const Property = struct { id: PropertyId, value: PropertyValue, };
/// The properties of one node.
///
/// `Properties` owns every buffer `items` grows and stores the allocator that
/// grows them. The stored allocator must stay valid for the life of the value
/// and must be the allocator that released the memory this value last held, or
/// `deinit` is a mismatched free.
///
/// `items` is sorted by `@intFromEnum(id)` and never holds a cleared value.
/// Copying a `Properties` copies the handle, not the storage, so a copy is not
/// a second owner and must not be `deinit`'d separately.
pub const Properties = struct { gpa: std.mem.Allocator, items: std.ArrayList(Property), pub fn init(gpa: std.mem.Allocator) Properties { return .{ .gpa = gpa, .items = .empty }; }
    /// Releases every property value and the backing array. The value is
    /// unusable afterwards; a second call is a double free.
pub fn deinit(self: *Properties) void { ... }
    /// The value for `id`, or null when unset. Borrows nothing.
pub fn get(self: Properties, id: PropertyId) ?PropertyValue { ... }
    /// Takes ownership of any buffer inside `value`. On `error.OutOfMemory`
    /// nothing is written and the caller still owns `value`. Setting a property
    /// that was previously cleared starts a new entry.
pub fn set(self: *Properties, id: PropertyId, value: PropertyValue) error{OutOfMemory}!void { ... }
    /// Removes `id`. A no-op when the property is not set.
pub fn clear(self: *Properties, id: PropertyId) void { ... }
    /// Structural equality over `(id, value)` pairs in id order, independent of
    /// allocation history.
pub fn eql(a: Properties, b: Properties) bool { ... }
    /// Copies `source` into `out`, reusing `out`'s existing buffers when the value
    /// shapes match. This is the hot path: `Tree` folds one state into the other
    /// node by node on every update.
pub fn cloneInto(self: Properties, gpa: std.mem.Allocator, out: *Properties) error{OutOfMemory}!void
{ ... } };
```

**Node reuse, as the rule a reader implements.** Upstream needs `clone_from`
because a Rust `Vec` may reallocate; Zig needs `cloneInto` for the same reason and must use it on the same path. `Node` gets `cloneInto(self: Node, gpa: std.mem.Allocator, out:
*Node) error{OutOfMemory}!void` forwarding to `Properties.cloneInto`, and
`PropertyValue` gets one fast path per payload shape so a string or list keeps its buffer when the tag matches. `process_changes` folds `next_state` into `state` with `cloneInto` for every updated
and added node and `remove` for every removed node, and never replaces the whole map. Upstream's own
words for why updates stay small: "there is still a cost in processing these nodes and replacing the
previous instances".
### 4.4 The update protocol, as pseudocode
Not Zig. A reader implements it directly. This is the whole of `consumer/tree_apply.zig` and `consumer/tree_grafts.zig`.

```text
applyUpdate(gpa: std.mem.Allocator, state: *TreeState, update: TreeUpdate, changes: ?*InternalChanges) UpdateError!void
  # I1 exactly one node per tree has parent_and_index == null, and it is the root
  # I2 every id named in some children slice has a NodeState
  # I3 every non-root TreeId is in graft_parents once, and its subtree root's
  #    parent is that graft node at index 0
  # I4 state.focus is a key of state.nodes

tree_index = state.tree_index_map.getOrCreate(update.tree_id) mapId(local: NodeId) FullNodeId = FullNodeId{ .local = local, .tree_index = tree_index }

  # ---- step 1: subtree preconditions --------------------------------------------
if update.tree_id != TreeId.root { if (update.tree != null and !state.graft_parents.has(update.tree_id))
return error.SubtreeWithoutGraft;      # was panic, tree.rs:135 if (update.tree == null and !state.subtrees.has(update.tree_id))
return error.SubtreeDoesNotExist;       # was panic, tree.rs:142 }

  # ---- step 2: the tree root moves. The previous root of the affected tree, if
  # it changed, lands in `unreachable` and is removed in step 5.
new_tree_root: ?FullNodeId = null if (update.tree) |tree| {
new_tree_root = mapId(tree.root) if (update.tree_id == TreeId.root) {
if (tree.root != state.info.root) unreachable.put(state.root) state.root = new_tree_root.?
state.info = tree } else if (state.subtrees.get(update.tree_id)) |subtree| {
if (subtree.root != new_tree_root.?) unreachable.put(subtree.root) }
} root = new_tree_root orelse state.subtrees.get(update.tree_id).?.root orelse state.info.root

pending_nodes:    AutoHashMap(FullNodeId, Node)          = .empty pending_children: AutoHashMap(FullNodeId, ParentAndIndex) = .empty
pending_grafts:   AutoHashMap(TreeId, FullNodeId)          = .empty grafts_to_remove: AutoHashMap(TreeId, void)               = .empty

  # ---- step 3: the per-node pass. After each iteration every node in state.nodes
  # has a correct parent, every node in the update is placed or still pending, and
  # no child id repeats. The pass may run in any order; upstream iterates a hash
  # map and so does the port.
for (update.nodes) |local_id, node_data| { node_id = mapId(local_id)
unreachable.remove(node_id) for (node_data.children(), 0..) |child_id, child_index| {
mapped = mapId(child_id) if (!seen_child_ids.insert(mapped))
return error.DuplicateChild;         # was panic, tree.rs:236 unreachable.remove(mapped)
pai = ParentAndIndex{ .parent = node_id, .index = child_index } if (state.nodes.getPtr(mapped)) |slot| {
if (!slot.parent_and_index.eql(pai)) { slot.parent_and_index = pai
changes.?.updated.put(mapped) }
          } else if (pending_nodes.fetchSwapRemove(mapped)) |entry| {
              # The child's own data arrived before its parent's reference.
addNode(state, &pending_grafts, changes, pai, mapped, entry.value) } else {
pending_children.put(mapped, pai) }
} if (state.nodes.getPtr(node_id)) |slot| {
if (local_id.eql(root)) slot.parent_and_index = null for (slot.data.children()) |existing_child| {
              # A child no longer named here is unreachable unless named here too.
mapped_existing = mapId(existing_child) if (!seen_child_ids.contains(mapped_existing)) unreachable.put(mapped_existing)
} if (!slot.data.eql(node_data)) {
if (node_data.treeId() != null and node_data.children().len != 0) return error.GraftWithChildren;  # was panic, tree.rs:273
old_tree, new_tree = slot.data.treeId(), node_data.treeId() if (!old_tree.eql(new_tree)) {
if (old_tree) |t| grafts_to_remove.put(t, {}) if (new_tree) |t| recordGraft(&pending_grafts, t, node_id)
              }
              # THE REUSE LINE: overwritten in place, so every buffer is kept.
slot.data = try node_data.cloneInto(state.gpa, &slot.data) changes.?.updated.put(node_id)
} } else if (pending_children.fetchSwapRemove(node_id)) |pai| {
addNode(state, &pending_grafts, changes, pai, node_id, node_data) } else if (local_id.eql(root)) {
addNode(state, &pending_grafts, changes, null, node_id, node_data) } else {
pending_nodes.put(node_id, node_data) }
  }

  # ---- step 4: nothing left dangling. Both maps empty means every node in the
  # update is either already in state.nodes or was a child of a node in it (I2).
if (pending_nodes.count() != 0) return error.OrphanNode     # was panic, tree.rs:318 if (pending_children.count() != 0) return error.OrphanChild  # was panic, tree.rs:325

  # ---- step 5: record focus, then remove the unreachable -------------------------
tree_focus = mapId(update.focus) if (new_tree_root) |nr| {
state.subtrees.put(update.tree_id, SubtreeState{ .root = nr, .focus = tree_focus }) } else if (state.subtrees.getPtr(update.tree_id)) |subtree| {
subtree.focus = tree_focus } else if (update.tree_id == TreeId.root) {
state.subtrees.put(update.tree_id, SubtreeState{ .root = state.root, .focus = tree_focus }) }
if (unreachable.count() != 0) { for (unreachable.keys()) |id| {
          # Stack, not recursion. Bounded by node_count, which is finite.
stack.push(id) while (stack.popOrNull()) |current| {
changes.?.removed.put(current) entry = state.nodes.fetchSwapRemove(current) orelse
return error.NodeMissingFromState if (entry.value.data.treeId()) |t| grafts_to_remove.put(t, {})
for (entry.value.data.children()) |child| { child_full = FullNodeId{ .local = child, .tree_index = current.tree_index }
if (!seen_child_ids.contains(child_full) and !eql(child_full, new_tree_root)) stack.push(child_full)
} }
  }

  # ---- step 6: drop subtrees whose graft went away. The list grows while it is
  # walked, bounded by state.subtrees.count(). See section 4.6.
subtrees_to_remove: ArrayList(TreeId) = .empty for (grafts_to_remove.keys()) |t| subtrees_to_remove.append(t)
cursor = 0 while (cursor < subtrees_to_remove.items.len) : (cursor += 1) {
subtree_id = subtrees_to_remove.items[cursor] if (state.graft_parents.fetchSwapRemove(subtree_id) == null) continue
if (pending_grafts.contains(subtree_id)) continue if (state.subtrees.fetchSwapRemove(subtree_id)) |subtree| {
stack.push(subtree.root) while (stack.popOrNull()) |current| {
node = state.nodes.fetchSwapRemove(current) orelse continue changes.?.removed.put(current)
if (node.data.treeId()) |nested| if (!queued.contains(nested)) { queued.put(nested, {})
subtrees_to_remove.append(nested) }
for (node.data.children()) |child| stack.push(withSameTree(child, current))
} }
  }

  # ---- step 7: install the new graft parents. After this step I3 holds again.
for (pending_grafts) |subtree_id, node_id| { if (state.graft_parents.contains(subtree_id))
return error.DuplicateGraftParent   # was panic, tree.rs:449 state.graft_parents.put(subtree_id, node_id)
if (state.subtrees.get(subtree_id)) |subtree| { if (state.nodes.getPtr(subtree.root)) |slot| {
slot.parent_and_index = ParentAndIndex{ .parent = node_id, .index = 0 } if (!changes.?.added.contains(subtree.root)) changes.?.updated.put(subtree.root)
} }
} if (new_tree_root) |nr| {
if (state.graft_parents.get(update.tree_id)) |graft_node| { if (state.nodes.getPtr(nr)) |slot| {
slot.parent_and_index = ParentAndIndex{ .parent = graft_node, .index = 0 } if (!changes.?.added.contains(nr)) changes.?.updated.put(nr)
} }
  }

  # ---- step 8: recompute effective focus, then validate. I1 to I4 hold on exit.
state.focus = try computeEffectiveFocus(state) try validateGlobal(state)   # I4
```
**The helpers, with their own invariants.**

```text
recordGraft(pending_grafts, subtree_id, graft_node_id) UpdateError!void
    # At most one graft parent per subtree_id, and never an entry for the root.
if (subtree_id == TreeId.root) return error.CannotGraftTheRootTree  # panic, tree.rs:188 if (pending_grafts.contains(subtree_id)) return error.DuplicateGraftParent  # panic, :191
pending_grafts.put(subtree_id, graft_node_id)

addNode(state, pending_grafts, changes, parent_and_index, id, data) UpdateError!void
    # On return, state.nodes[id] exists and id is in changes.added.
if (data.treeId()) |subtree_id| {
        # A graft node's only child comes from its subtree, never its own list.
if (data.children().len != 0) return error.GraftWithChildren   # panic, tree.rs:211 try recordGraft(pending_grafts, subtree_id, id) } state.nodes.put(id, NodeState{ .parent_and_index =
parent_and_index, .data = data }) changes.?.added.put(id)

computeEffectiveFocus(state) UpdateError!FullNodeId
    # Follows the graft chain until it reaches a node with no tree_id. Each step
    # consumes one distinct subtree, so the bound is the subtree count.
root_subtree = state.subtrees.get(TreeId.root) orelse return state.focus current = root_subtree.focus steps = 0 while (state.nodes.get(current)) |node_state| { subtree_id =
node_state.data.treeId() orelse break subtree = state.subtrees.get(subtree_id) orelse return error.GraftWithoutSubtree        # was panic, tree.rs:112 current = subtree.focus steps += 1 if
(steps > state.subtrees.count() + 1) return error.GraftChainTooLong } return current

validateGlobal(state) UpdateError!void
    # I1 and I4 hold after this. I2 and I3 are established by the steps above and
    # are checked by the fixture suite, because a per-update full traversal costs
    # O(n) on an O(k) operation.
if (!state.nodes.contains(state.root))  return error.RootNotInTree   # panic, :88 if (!state.nodes.contains(state.focus)) return error.FocusNotInTree  # panic, :91
```

**One deviation, and it is deliberate.** Upstream's `add_node` inserts
unconditionally, overwriting an existing entry if the update names a node twice. The port keeps that
behaviour, because a duplicate is caught at step 4 instead: the second occurrence cannot be reached as a fresh child, so it stays in `pending_nodes` and step 4 returns `error.OrphanNode`. No new check
is added and no valid update is refused.
### 4.5 The error set, and the full panic and unwrap map

```zig
// consumer/tree.zig

/// Failures of `Tree.init`, `Tree.update` and the change-handler fold. The first
/// fifteen tags are conditions a platform can send; `OutOfMemory` is the only tag
/// a caller can cause directly.
pub const UpdateError = error{ NoRootTree,             // `Tree.init` given an update whose `tree` is absent. tree.rs:594 NotTheRootTree,         // `Tree.init` given a subtree update. tree.rs:599
RootNotInTree,          // the root has no NodeState. tree.rs:88 FocusNotInTree,         // the recorded focus has no NodeState. tree.rs:91 GraftWithoutSubtree,    // focus on a graft node with no
registered subtree. :112 SubtreeWithoutGraft,    // subtree pushed with no graft node. :135 SubtreeDoesNotExist,    // subtree updated before its first tree data. :142 CannotGraftTheRootTree,
// an update grafts the root tree. :188 DuplicateGraftParent,   // two graft parents, or a second
one at commit. :191, :449 GraftWithChildren,      // tree_id and a non-empty children list. :211, :273 DuplicateChild,         // one node names the same child twice. :236 OrphanNode,             //
a node is neither present nor a child in the update. :318 OrphanChild,            // a child id is neither present nor a node in the update. :325 NodeMissingFromState,   // an internal removal found
no node. :367 GraftChainTooLong,      // the bound from section 4.6; no upstream counterpart OutOfMemory, };

/// Failures of the text-position queries that walk the tree.
pub const QueryError = error{ InvalidPosition,     // text.rs:256, :278 IndexOutOfRange,     // text.rs:1600, :1639 LineChainCycle,      // the replacement for an unbounded line walk
WrongPropertyKind,   // upstream drops this value silently in get_mut NoSuchNode, OutOfMemory, };
```

**Every upstream `panic!` is mapped above.** 19 sites outside test code: 15 in
`tree.rs`, 4 in `text.rs`, every one of them named in a tag comment. Nine of them collapse onto four
tags, because four conditions are genuinely one condition.

**Every upstream `.unwrap()`, by class.** 51 calls outside test code: 28 in
`text.rs`, 11 in `tree.rs`, 10 in `node.rs`, 2 in `iterators.rs`.

| Class | Where | Count | Treatment |
|---|---|---:|---|
| An invariant the same function just established | `tree.rs:367`, `:514`, `:531`, `:642`, `:646`, `:647`, `:675`, `:681`, `:687`, `:688` | 10 | the checked lookup returns `error.NodeMissingFromState`, so the failure is a value and not an abort |
| An index into a node's own property or character slice | `text.rs:72`, `:244`, `:943` and 25 more in `text.rs` | 28 | the function gains `error{IndexOutOfRange}!`. The index is caller-supplied, so this is promised validation returned in every optimize mode, not a precondition |
| A hierarchy lookup that can legitimately fail | `node.rs:135`, `:402` and 8 more in `node.rs` | 10 | the function returns `?NodeRef`. A caller that cannot accept absence adds a branch, which is the point |
| An iterator's next element | `iterators.rs` | 2 | the iterator gains `next() ?T`; no consumer unwraps it |

`PropertyValue` keeps an explicit `none` tag rather than a Zig optional, because upstream needs the distinction: a cleared property keeps its index and a never-set property does not, and collapsing
the two loses the answer to "was this ever set".
### 4.6 What replaces the 21 unbounded loops
The consumer crate has 21 `while` loops outside test code. Most are bounded by a comptime domain. Three walk user data with no limit.

| Upstream loop | What it walks | Bound in the port |
|---|---|---|
| `tree.rs:640-706`, `process_changes` | three hash sets whose size grows with the tree | the byte decoder rejects a `TreeUpdate` before this loop, so the sets are bounded by `max_nodes_per_update = 65_536` enforced in the decoder, not in `tree.zig` |
| `text.rs:117`, `line_start` | the `previous_on_line` chain | a cycle is the only non-termination and a cycle must repeat a node, so the bound is `state.node_count()` captured once at entry |
| `text.rs:131`, `line_end` | the `next_on_line` chain | same |

Both line walks return `error.LineChainCycle` when the bound is hit. The graft chain walk in `computeEffectiveFocus` is bounded by `state.subtrees.count() + 1` and returns
`error.GraftChainTooLong`. The remaining 18 loops are bounded by `@typeInfo(...).@"enum".fields.len`
or by `items.len` and need no constant; every loop over the property domain takes its bound from the
comptime member count, so adding a property cannot silently unbound a loop.
---
## 5. The action channel
### 5.1 The path, from platform to application
One direction only. Six steps, and step 3 is the one that changes.

1. **Decode.** The adapter resolves the object path to a `FullNodeId` and looks the node up. The `NodeRef` borrows the `Tree` and owns nothing. 2. **Drop the tree lock before the callback.** A
handler may make its own outbound D-Bus call, and that call parks, so a tree lock held across a park
deadlocks the one executor. 3. **Copy the payload.** An `ActionRequest` owns its `ActionData`, and the string variant owns a heap buffer. The adapter builds it in its own allocator and hands the
handler a borrow valid for the call. 4. **Call the handler**, through the one `do_action` slot. 5.
**Release.** The adapter frees the request's buffers after the handler returns, never before and
never from inside the handler. 6. **Reply.** The D-Bus method return is sent after the handler returns.

| Resource | Supplied by | Freed by | Freed when |
|---|---|---|---|
| the `Tree` | the adapter, at construction | `Tree.deinit` | once, at adapter teardown |
| the `NodeRef` | the tree | nobody: it is a borrow | never |
| the `ActionRequest` payload | the adapter's allocator | the adapter | before the method reply |
| the handler context | the application | the application | it must outlive every call |
| the bus socket | the explicit native transport owner | owned connection close | once, after transport tasks join |

**Cancellation, three named obligations.** A D-Bus method call is a request, not
a cancellation. A queued action is cancellable only before the handler starts, because once `do_action` is entered the application owns it and no cancellation exists; a handler that blocks
does not block the bus, because `do_action` returns immediately after enqueuing when the application
configured a queued handler; and task cancellation reaches the adapter, not the handler, because `error.Canceled` is delivered at the next cancellation point inside a task, so a parked task's
queued payloads are released by that task's own `errdefer` and the application handler is never entered. A request is not a join, a join is not a disposal, and only the disposal has an owner.
### 5.2 The rule that replaces the two `OnceLock` statics

```text
Evidence: `adapters/unix/src/context.rs` declares two file-scope statics typed `OnceLock<Arc<RwLock<AppContext>>>` and `OnceLock<Sender<Message>>`, and `get_or_init_messages`
spawns an OS thread from inside the initialiser; `adapters/unix/src/atspi/bus.rs` holds `desktop: Arc<OnceLock<ObjectRefOwned>>`. Subject:  AccessKit/accesskit @
466e24e252103f4d82bd6fbab98141b551e46e0c Source: adapters/unix/src/context.rs; adapters/unix/src/atspi/bus.rs Reads as: Three declarations and one initialiser at that revision. It
establishes that the state is process-global and that the thread starts inside a lazy initialiser, and nothing about why upstream chose it.
```

**The rule: the adapter state is an explicit parameter of every adapter entry
point, and there is no file-scope mutable variable anywhere under `src/`.**

| Upstream global | What it becomes | Owner |
|---|---|---|
| `APP_CONTEXT` | a `*AdapterContext` field on the `Adapter` the application built | the application, from `Adapter.init` |
| `MESSAGES` | a `zio.Channel(Message)` field on the same `Adapter` | the application, from `Adapter.init` |
| `desktop` | a `?DesktopRef` field, written once during activation | the adapter, during `activate` |
| the thread `get_or_init` spawns | a zio task the adapter spawns from `activate`, held as a `JoinHandle` | the adapter, cancelled by `deinit` |

Four consequences: `Adapter.init` is where the runtime, the allocator and the bus connection arrive;
two `Adapter` values are two independent adapters, where upstream's statics make the second reuse the first's bus thread; a test builds an adapter, drives one message and deinits it, with no
process-global reset because there is no process-global state; and the check is mechanical, because the gate's AST stage rejects a file-scope `var` under `src/`.

> **Record R3 — the adapter state is a parameter, never a process global.** **Priority.** Make the adapter
> constructible twice in one process and testable without a live bus. **Constraint.** `Runtime.deinit` asserts
> every task has settled, so an adapter that detaches a thread outlives the runtime that must join it. **Cost
> imposed on consumers.** A consumer constructs a runtime and an `Adapter` with it, keeps both alive, and calls
> `Adapter.deinit` before `Runtime.deinit` in that order; two adapters cost two bus connections. **The
> counterchoice**, a declared process-wide singleton with a documented override, the shape the standard library
> ships for its single-threaded backend, genuinely wins when exactly one instance per process is a real
> constraint, such as a platform that registers one global accessibility object. The port loses here because the
> adapter holds a bus connection and a task, and a global holding both has a shutdown order that nothing checks.
> **Grade and origin.** taste · analyst-inferred, under a constraint that is a source reading at the pin.
---
## 6. The platform interface
### 6.1 The seam, as four vtables
Four and nothing more. Three point inward from the adapter to the application and one points outward
from the consumer to the adapter. Each is a struct of function pointers plus one context pointer, and each slot below carries the doc comment the caller needs.

```zig
// schema/handlers.zig — the three the application implements.
pub const ActivationHandler = struct { ptr: *anyopaque,
    /// Returns null when the application has no tree to expose. The returned value
    /// is owned by the adapter and must not be freed or reused for a second
    /// activation. `null` is not a failure: the adapter stays inactive. Runs on
    /// the adapter's dispatch thread and must not call back into it.
request_initial_tree: *const fn (ptr: *anyopaque) ?*const TreeUpdate, }; pub const ActionHandler = struct { ptr: *anyopaque,
    /// `request` and everything it borrows are valid only for this call, and the
    /// adapter releases the request's buffers after it returns. Runs on the
    /// adapter's dispatch thread; must not call `Adapter.deinit` and must not park
    /// a task on the bus it is answering from.
do_action: *const fn (ptr: *anyopaque, request: ActionRequest) void, }; pub const DeactivationHandler = struct { ptr: *anyopaque,
    /// Called once per deactivation. The adapter holds no tree afterwards.
deactivate_accessibility: *const fn (ptr: *anyopaque) void, };
// consumer/tree.zig — the one the adapter implements.
/// Receives what one tree update changed. Every slot has a default and a default is
/// silent, so each default is named: all four drop the call. `null` selects it.
pub const TreeChangeHandler = struct { ptr: *anyopaque, node_added: ?*const fn (ptr: *anyopaque, node: NodeRef) void = null, node_updated: ?*const fn (ptr: *anyopaque, old: NodeRef, new: NodeRef)
void = null,
    /// `null` means focus was lost. Both refs borrow the two tree states and are
    /// valid only for this call.
focus_moved: ?*const fn (ptr: *anyopaque, old: ?NodeRef, new: ?NodeRef) void = null,
    /// The node is valid only for this call.
node_removed: ?*const fn (ptr: *anyopaque, node: NodeRef) void = null, };
```

> **Record R4 — three required slots, four defaulted slots.** **Priority.** Let a consumer that wants one change
> kind write `.{ .focus_moved = myFn }` and get a working handler, and make a missing required slot a build
> error rather than a silent no-op. **Constraint.** Adding a slot to a vtable whose members have no defaults is
> source-breaking for every implementor, while a defaulted field keeps every existing `.{}` call site compiling;
> the two guarantees do not generalise to each other. **Cost imposed on consumers.** A consumer wanting every
> change supplies four pointers and one context; a consumer wanting one supplies one and four nulls and compiles
> unchanged when a fifth kind appears; a consumer of the application-side vtables always supplies all three,
> because a missing one does not compile. **The counterchoice**, a required slot for every kind, genuinely wins
> when every adapter wants every change and silence is never correct, because the type system then refuses an
> incomplete handler. The port loses here because two upstream implementors are explicitly no-op handlers, so a
> required slot would force boilerplate that says nothing. **Grade and origin.** taste · analyst-inferred, under
> the constraint that the two no-op implementors exist. The source-breaking property of a defaultless slot is a
> language fact, not a judgment.
### 6.2 Which side owns what, and what never crosses

| The adapter owns | The application owns | Never crosses |
|---|---|---|
| the bus connection and socket | the window bounds and focus state it pushes in | any AT-SPI interface name |
| every exported object and its path | the tree the adapter stores | any D-Bus message type |
| the `Tree` and its two states | the `ActionRequest` payload, for the call | any platform handle |
| the handler contexts, borrowed | the handler implementation | the allocator, which both name |
| the zio runtime, borrowed | the lifetime of its own handler state | the event loop |
### 6.3 The 17 boundary rules and their checks
`docs/23-core-boundary.md` section 8 states 17 rules: A1 to A4, B1 to B4, C1 to C8 and D1. They are not restated; what follows is the check each one gets, because a rule without a check is a comment.

| Rules | Check | Rung |
|---|---|---|
| A1 to A3 | one `binding-check` step comparing each adapter's import block against the two allow lists | reached build |
| A4 | one comptime assertion per adapter that the struct has exactly one `Tree` field | comptime |
| B1 to B3 | the `ast-check` gate stage greps `src/schema` and `src/consumer` for `std.os`, `std.posix`, `std.c`, `std.Io`, `zio`, `@import("builtin")` and any adapter package name | source reading, then gate |
| B4 | one `zlint` pattern per allocating function | review |
| C1, C4, C6, C7 | comptime assertions: no `anytype` field in a core type; no time or environment entry point; exactly four vtable declarations; every consumer loop bound a named constant | comptime |
| C2, C3, C8 | `ast-check` rejects the toolkit name, `std.heap`, `page_allocator`, `panic`, `unreachable`, `catch unreachable` and `catch continue` under `src/schema` and `src/consumer` | gate |
| C5 | `schema/node.zig` declares `TreeInfo` and no `Tree` alias; a grep confirms | source reading |
| D1 | one `b.addTest` whose module graph contains no adapter package, cross-built for `powerpc64-linux` | reached build plus cross run |

D1 is the one that is not a grep. That cross row is the only one that catches an endianness defect in the tree serialisation, the action-channel marshalling and the C ABI structs at once, because all
three are byte layouts and none is otherwise exercised off the host byte order.
---
## 7. The runtime and I/O
### 7.1 Where the runtime is allowed

| Place | Takes | Why |
|---|---|---|
| `src/schema/**`, `src/consumer/**` | nothing | 0 class S items upstream: no I/O, no clock, no allocator global |
| `src/capi/**` | nothing | a C function runs on the caller's thread and returns before it returns |
| `adapters/atspi/bus.zig` | `io: std.Io` and one `*zio.Runtime` | opens a socket and spawns the bus task |
| `adapters/atspi/pump.zig` | `io: std.Io` and `rt: *zio.Runtime` | parks a task on a descriptor and needs a timeout |
| `adapters/atspi/dispatch.zig` | `io: std.Io` | decodes bytes and calls the exported objects |

**No bare `!` in any public signature.** zio has four inferred error sets in
`net.zig`; the port wraps each call in a `catch` into a declared set.
### 7.2 Historical Goose proposal, superseded by section 12.2

This subsection preserves the original proposal and probe evidence.
The implemented transport uses public zio sockets and a port-owned D-Bus codec.
It does not use, patch, or vendor Goose.
The proposed re-export, nonblocking reset, and fetched-tree patch below are not current build behavior.
**1, the zio-backed `std.Io`.** goose is written against `std.Io`, so the adapter
passes `zio.fromRuntime(rt, .blocking)`. Three re-export lines are missing from zio's root module today, and adding `src/io.zig` as a second module fails with `file exists in modules 'zio_io' and
'zio'`. The port opens an upstream pull request for the re-exports and, if it is refused, adds a three-line local wrapper.
**It does not patch zio's source.**

**2, the `O_NONBLOCK` reset, four lines.** This defect decides the whole D-Bus
shape.

```text
Evidence: goose's `SocketReader.recvWithIovecs` calls a raw `recvmsg` and folds `EAGAIN` into `error.ReadFailed`; goose opens its socket through `std.Io`, and the probe measured the descriptor
flags as 0x802 with `O_NONBLOCK` set for a zio-backed `std.Io` against 0x2 for the default one. Clearing the flag after connect made the same run complete end to end. Subject:  luxluth/goose @
8c6ee3a984a3b314bb921e3f8f6428a51a6d93e1, tag v3.3.0 Source:   src/connection.zig Reads as: A source
reading plus a runtime observation recorded in `docs/26-goose-live-bus-probe.md` section 7, run on this host against Zig 0.16.0 on the live accessibility bus. It establishes that the four lines fixed
that run, and nothing about another platform or a future goose release.
```
The block, placed immediately after goose's connect:

```zig
{ const fl = std.posix.system.fcntl(socket.socket.handle, std.posix.F.GETFL, @as(usize, 0)); const mask = @as(@TypeOf(fl), 1 << 11); // 04000 octal, O_NONBLOCK on Linux const cleared: usize =
@intCast(fl & ~mask); _ = std.posix.system.fcntl(socket.socket.handle, std.posix.F.SETFL, cleared); }
```

**3, `dispatch()` rather than `serve()`.** goose's `.poll` backend starts no
thread, `.threaded` starts two, and `serve` refuses `.poll` with `error.InvalidBackend`. The port opens with `.poll`, watches the one descriptor goose exposes through `getFd()`, and calls
`dispatch()` itself once it is readable.
**One event loop runs in the process, and it is zio's.** `hasDataToRead` calls
`std.posix.poll` with a zero timeout and `dispatch` reads raw, so neither can await; both run inside
a task already woken by the descriptor watch.

**4, the two-step bus discovery.** goose has no `initFromAddress` and no
`org.a11y.Bus` step, so the port owns all five: open a `.Session` connection; call `org.a11y.Bus` at
`/org/a11y/bus` member `GetAddress`; decode the reply as a `GStr`; put it into the `Environ.Map` under `AT_SPI_BUS_ADDRESS`; close the session connection and open the `.Accessibility` one. Step 4
is not optional: goose's hard-coded fallback builds the socket name `bus_0` while a systemd `at-spi-bus-launcher` host serves `bus`, so with the variable removed the connect fails with
`error.FileNotFound`. The adapter also widens goose's `SocketIterator`, which parses `unix:path=` only, to accept `unix:abstract=` and `unix:tmpdir=`.
**5, `methodCall` returns errors as values.** The call does not surface a D-Bus
error as a Zig error, so the adapter checks `message.header.message_type` and maps the error name through its own set; a collapsed name would make `UnknownObject`, `InvalidArgs` and `NotSupported`
indistinguishable.
**6, roughly 630 lines the port owns.** A budget from the gap list; the port does
not exist, so this is not a measurement.

| What the port writes | Budget | Why goose cannot supply it |
|---|---:|---|
| the object register and remove path | 250 | `registerObject` takes a comptime type and a fixed path and appends; no remove exists anywhere in the file. The adapter registers ten interfaces per node and removes them when a subtree dies, so this is the hot path |
| the typed error set and its mapping | 150 | goose has `sendError(msg, name, text)` and no taxonomy; 92 sites across 12 upstream interface files need one |
| typed client proxies for the socket and bus interfaces | 100 | goose's generic proxy has no typed wrapper for either |
| a runtime-computed signal member name | 60 | goose binds signal names to struct fields at comptime; the adapter picks the name from a match on the event kind |
| the `SocketIterator` widening | 40 | goose parses `unix:path=` only |
| the `BusProxy` fallback | 30 | goose has no `GetAddress` step at all |
| **Total** | **630** | |
goose keeps the connection, the SASL `EXTERNAL` handshake, the message codec, alignment and endianness, fd passing over `SCM_RIGHTS`, match rules, signal dispatch and the introspection XML
reader.
### 7.3 Historical fetched-tree patch proposal, not implemented

> **Record R5 — the fix is a build-time patch on the fetched tree, with an upstream pull request opened in
> parallel.** **Priority.** Make an unpatched goose impossible to link, so the failure cannot appear as
> `error.ReadFailed` on a socket that is working. **Constraint.** The build must fetch goose by URL and hash and
> compile it from a clean tree; a vendored copy would put 6412 lines of third-party Zig in this repository and
> make the licence record a maintenance obligation rather than an audit. **Cost imposed on consumers.** A
> consumer that adds `zaccesskit` gets the fix with no action; a consumer that adds goose directly gets the same
> failure, so the symptom is recorded in the README; a reviewer reading `build.zig` sees a patch step and must
> follow it. **The counterchoice**, a vendored copy, genuinely wins when the patch cannot be a mechanical
> rewrite, when the package manager cannot fetch, or when a licence audit forbids executing third-party build
> steps. The port loses here because the patch is four lines at one known location in one file at one pinned
> hash, and a vendored copy turns every future release into a merge instead of a re-pin. An upstream pull
> request alone genuinely wins if it merges quickly; the port cannot depend on a merge it does not control, so
> the pull request opens and the patch ships regardless. **Grade and origin.** taste · analyst-inferred; the
> defect is a source reading plus the quoted runtime observation, and the routing is this document's judgment.

Three checks keep an unpatched tree unbuildable: the patch step asserts the target file is byte-identical to the pinned hash before rewriting it and fails the build with a named message
otherwise; it asserts the four lines are present afterwards; and `docs/50-verification.md` records that with the patch absent the failure is `error.ReadFailed` during the SASL handshake, which reads
as a network fault and is not one.
---
## 8. Time and determinism

**The rule: nothing under `src/` reads a clock.** Every function that needs "now"
takes a `Timestamp`. No module calls `zio.now`, `Timestamp.now` or `Clock.now`, and none reads an environment variable or the working directory. The gate greps for all three. Time enters at four
places and nowhere else: three timeouts in `bus.zig`, `pump.zig` and the AT-SPI cache refresh, each from a named constant, and a test that supplies two `Timestamp` values and asserts their difference.
`zio.now()` returns the event loop's cached timestamp rather than a fresh read, so even where the port could use it a test could not pin it. A test controls time by not reading it.

```zig
// A D-Bus method reply that must arrive within 200 ms of the request.
test "method reply arrives inside the deadline" { var harness = try Harness.init(std.testing.allocator); defer harness.deinit(); const sent_at: zio.Timestamp = .{
.value = 1_000 };     // lifted by the test try harness.callMethod("GetChildren"); const received_at: zio.Timestamp = .{ .value = 1_150 }; // lifted by the test try
std.testing.expect(received_at.durationTo(sent_at).toMilliseconds() <= 200); }
```

| A zio test can | A zio test cannot |
|---|---|
| control the allocator identity and every allocation index, through `std.testing.allocator` and `checkAllAllocationFailures` | make `now` return a chosen value: zio has no clock interface to swap |
| fix the bytes a reader yields and how it splits them, through `std.testing.Reader` | replace the `Io` inside a zio test: the runner builds a real `Io.Threaded` per test |
| set the executor count, the blocking pool and the scheduling discipline through build options | fix the interleaving of N tasks under the default work-stealing scheduler, so such a test asserts on the set of events, not their order |

> **Record R6 — time is a parameter and zio is not patched.** **Priority.** Make every decision reproducible
> from a committed fixture, with no recorded output and no wall clock in a test. **Constraint.** zio 0.18.0 has
> no virtual clock and no injectable `Io`, so a test that needed elapsed time controlled would have to wait for
> it. **Cost imposed on consumers.** A consumer building a deadline passes a value rather than reading one, so a
> consumer that wants "now" holds the clock itself; an application needing elapsed time reads the clock in its
> own `main` and passes the result down. **The counterchoice**, adding an injectable `Io` and a virtual clock to
> zio upstream, genuinely wins when many projects on one runtime all need deterministic time, because the
> capability belongs in the runtime rather than in each consumer, and it would close the gap against the house
> rule that a deterministic `Io` swap makes simulation possible. The port loses here because an upstream change
> to a runtime another project uses cannot be made unilaterally, and the port's need is small: nothing in the
> tree or the protocol is a function of elapsed time, so a virtual clock would be a seam with one user. **Grade
> and origin.** taste · analyst-inferred; the absence of an injection point is a source reading plus
> `docs/18-testing-strategy.md` section 3.2, and the choice not to pursue an upstream change is this document's
> judgment.

Three determinism rules come with it, each checkable by a gate stage: **bytes as data**, so the update decoder, the property codec and the ABI marshaller each take a byte slice and return a value;
**state as a parameter**, so every state machine is a function from a decoded message and a state
value to a new state value plus an action list; and
**bounded loops everywhere**, so every loop over a message queue or event batch has a
fixed iteration cap and hitting the cap is an error, not a `continue`.
---
## 9. The C boundary

One page, cross-referenced rather than repeated. `docs/31-c-abi-design.md` owns the exported surface, its ownership contract, the header artefact and the verification for both. It holds 18
enums and 270 variants, 40 laid-out structs, 18 opaque structs, 4 function-pointer typedefs and 1 exported data object.

| Question | Owner | What this document adds |
|---|---|---|
| Which 496 declarations are exported, and under which prefix | `docs/31` records A and D | nothing |
| Where the allocator lives at a boundary with no room for one | `docs/31` record C | `capi/marshal.zig` threads it from the Zig caller |
| How a Zig error becomes a C `null` | `docs/31` record B and `accesskit_last_error` | the `UpdateError` set from section 4.5 is what the marshaller maps |
| The Zig layout the C route sits on | **this document**, sections 3 and 6 | the four vtables are the only Zig seam the C functions reach |

**Risk 1, the data-carrying `repr(C)` enum.** The header holds 18 enums and 270
variants. Seventeen are bare tags aliased to `uint8_t`. The eighteenth, `accesskit_action_data_Tag`,
has no alias, has 8 variants, and heads the only anonymous union in the header. Zig has no honest form for a data-carrying `repr(C)` enum, so the port splits it in two: an `extern struct` with a tag
field and an `extern union` payload. The tag width is pinned rather than inherited, because a C enum
with no fixed base has an implementation-defined size, and eleven `comptime` assertions carry the pin. The port converts variant by variant at the seam and never lets the Zig `union(enum)` reach an
exported signature.

**Risk 2, the aggregate passing convention.** 103 exported functions return a
struct by value and 42 accept one; nine of the returning functions return a 48-byte `accesskit_affine`, which is past the register budget for an aggregate return on the x86-64 System V
convention, so the result travels through a hidden pointer and every named argument shifts.
**Nothing in the language reference and nothing in this checkout settles how Zig 0.16.0 lowers a
48-byte aggregate return or argument.** That gap is open, not closed. The port ships the `extern struct` forms now and names the hand-written C shim for the nine return sites and seven affine
parameter sites as the fallback, gated on the check `docs/31` defines; it does not build the shim until that check fails.

Four differences from the Zig side: flat functions and a `void *` context pointer, where the four vtables arrive as the header's four function-pointer typedefs; sentinels rather than optionals,
where `null` covers both "unset" and "could not allocate" and a thread-local `accesskit_last_error` tag separates them, cleared on entry and set on the failing path; no allocator parameter, because
upstream's signatures have no room for one; and a hand-written header checked by a reflection sweep,
because `-femit-h` is broken on Zig 0.16.0, the zero-Rust rule forbids cbindgen, and `Step.Compile.installHeader` installs a checked-in file.
---
## 10. Cost imposed on consumers
### 10.1 A Zig consumer

| Holds | Pays | Must know |
|---|---|---|
| an allocator for every type that owns a buffer | one `deinit` per owned value, in order, exactly once | a copy of `Properties` copies the handle, not the storage, so a copy is not a second owner |
| an explicit `std.Io` capability and any required runtime authority | one parameter on each blocking entry point | runtime authority must outlive retained providers and queues. Section 12 defines success-only transfer |
| the path spelling for every published name | a longer path than `zaccesskit.Role` | only the root list is a supported route; a `pub` declaration no consumer imports is not published |
| a `NodeRef` borrow tied to one `TreeState` | the tree must outlive the ref | a ref into the next state is invalid once `Tree.update` returns |
| nothing to release for the three application vtables | the handler state must outlive the adapter | a missing required slot is a compile error; a `null` defaulted slot is a silent no-op |

Four duties a Zig consumer acquires that upstream does not have: a `deinit` for every owned value, an allocator on every allocating entry point, a typed error set on every entry point that can fail,
and a check on the returned error where upstream panicked.
### 10.2 A C consumer

| Holds | Pays | Must know |
|---|---|---|
| nothing for a returned aggregate | nothing to free for a by-value struct | a by-value aggregate borrows nothing; a small struct with an interior pointer does, and the header says which is which |
| the node alive while reading a returned array | one `*_free` per owned object | 12 getters return a struct whose pointer borrows from the node, and no free function exists because the caller does not own them |
| an `accesskit_last_error` tag | one call after a `null` or `false` return | the tag is valid only until the next call on the same thread |
| the platform's own object lifetimes | the platform's rules | the 5 object-returning platform accessors do not transfer ownership |

Three duties a C consumer acquires that upstream does not spell: read `accesskit_last_error` after a
`null`; keep the node alive while reading a borrowed array; and free an `accesskit_action_request` exactly once before its callback returns, which also releases the string inside it.
### 10.3 What both pay
The compiler line, Zig 0.16.0 and no other, on both routes. Two new exported names on the C route only, one artefact and one enum, both optional. One licence obligation: the port is a derived work
of code under Apache-2.0, MIT and the Chromium BSD-3-Clause, so it ships in source and in binary form with the notices, and `docs/21-licensing.md` owns the wording. And no backwards-compatibility
promise with upstream's header: the port reproduces the pinned header and does not promise that a future upstream header matches it.
---
## 11. What is unknown

Six items. Each is a question a reader cannot settle from this corpus, and each names the thing that
would settle it.

| # | The unknown | What would settle it |
|---|---|---|
| 1 | Whether Zig 0.16.0 lowers a 48-byte aggregate return and a 48-byte aggregate argument the way the C convention does. Nothing in the language reference and nothing in this checkout settles it, and the installed toolchain ships `lib/` and the `zig` binary but not the compiler's `src/`. | The exercised compilation `docs/31` calls check 5, run on one x86-64 target and on `powerpc64-linux`. Record E names the shim fallback if it fails |
| 2 | The per-platform module count and schedule. The five adapters hold 20113 upstream Rust lines, which at the 250-line limit is 81 to 101 modules, and this document does not fix the number. | `docs/40-plan.md` scheduling the adapters against its own milestones |
| 3 | The historical zio `fromRuntime` re-export question no longer controls this transport | The implemented route uses public zio socket and task APIs without that re-export |
| 4 | Later Goose fixes are not evaluated here and do not control the implemented transport | A separate future dependency decision and new source/runtime evidence |
| 5 | Whether the macOS, iOS and Android adapters link against real system libraries on a host that has the SDKs. This host builds objects for those targets and cannot link executables, and there is no Wine. | A host with the SDKs, or the SDK-less `build-obj` results those three already produce |
| 6 | What `zig-cov` will report for the port. The house gate measures line coverage only, and no threshold is promised here. | The first `zig-gate` run over the port, recorded in `docs/50-verification.md` |

Compilation is not an open design question.
`docs/50-verification.md` records the builds that reached source paths and the runs that checked behavior.

## 12. Implemented contracts for steps 1–4

The upstream pins in section 1.2 remain unchanged.
`docs/52-translation-ledger.md` records item dispositions and immutable source revisions.
The mappings below describe source. `docs/50-verification.md` section 11 separates portable, cross-build, and native evidence.

### 12.1 Publication, transactions, and callback ownership

The public native route is `zaccesskit.adapters.<platform>`.
The platform namespaces are `atspi`, `windows`, `macos`, `ios`, and `android`.
`zaccesskit.runtime` exposes the same zio dependency type, not a second runtime.
The C route remains the installed header and linked artifact.
Source: `src/root.zig:60-64`, `src/adapters/root.zig:6-10`.

Checked publication distinguishes `inactive`, `rejected`, and `committed`.
Rejection preserves the committed tree, focus, metadata, graft maps, callback log, and host baseline.
A committed result can carry a notification error without becoming a rejected transaction.
The caller advances its baseline after commit, before it reports notification errors.
The current-full supplier provides the same-frame full snapshot when activation requires one.
It does not reconstruct a tree from a stale prepared delta.
Borrowed input remains caller-owned. Owned input follows the API's consuming contract.

| Behavior | Pinned upstream source | Zig source |
|---|---|---|
| Windows checked publication and current-full selection | `adapters/windows/src/adapter.rs:463-494,529-624` | `src/adapters/windows/adapter.zig:67-87,149-180` |
| Linux checked native publication | `adapters/atspi-common/src/adapter.rs:419-478,518-578`, `adapters/unix/src/adapter.rs:196-219` | `src/adapters/atspi/adapter.zig:36-75,295-342` |
| Mac checked and prepared publication | `adapters/macos/src/adapter.rs:89,114,151,223,248,275` | `src/adapters/macos/native.zig:118,237-261,434-547,618` at `7d9c2a344db4ea28d79c5864f9ba5773de25bbd3` |
| C owning action payload and public release | `accesskit-c/src/common.rs:1084-1090,1128-1131` | `src/schema/update.zig:495-520`, `src/capi/action_request.zig:312-316` |
| Core constructor, owned and borrowed | `accesskit_consumer/src/tree.rs:592-618` | `src/consumer/tree.zig:290-315` |
| Core update, owned and borrowed | `accesskit_consumer/src/tree.rs:620-628` | `src/consumer/tree.zig:413-438` |
| Failure-atomic preparation, callback emission, and commit | `accesskit_consumer/src/tree.rs:640-706` | `src/consumer/tree.zig:481-658` |
| Dirty recovery and focus retry | `accesskit_consumer/src/tree.rs:630-637` | `src/consumer/tree.zig:438-462,1528-1587` |
| Parent-only promotion and graft-root slot preflight | `accesskit_consumer/src/tree.rs:229-315,461-481` | `src/consumer/tree_apply.zig:208,283`, `src/consumer/tree_grafts.zig:244,480` |
| Custom action description rollback and transfer | `accesskit/src/lib.rs:1012,1046` | `src/schema/props/table.zig:678,866` |

The native checked outcome and current-full supplier shapes are port additions.
They preserve explicit rejection and post-commit reporting rather than reproducing Rust signatures.
The detailed core transaction, graft, and retry rows remain in the translation ledger.

The C callback owns its transferred action request.
It frees the request exactly once before callback return.
The request owns its copied string payload independently of the source tree.
Activation and tree-factory callbacks transfer each nonnull owning C update to the library.
The shared conversion consumes that handle on success and error.
Source: `accesskit-c/src/common.rs:1098,1134,1171,1233`,
`src/capi/boundary.zig:52-71`, `src/schema/update.zig:375-385,526-530`.

The installed C allocator requires at least eight-byte alignment.
The port supplies higher native alignment without changing that callback API.
It stores the original pointer before the aligned payload and returns that pointer to the same captured free callback.
Resize and remap do not alter a live aligned block.
This alignment adapter is a port-only addition at `src/capi/allocation.zig:440-510`.
The C diagnostics add `operation_failed` and a static exact error name.
They preserve `none` and `out_of_memory`.
Source: `src/capi/allocation.zig:69-81,214-288`, `include/zaccesskit.h:1780-1784,6508-6516`.

### 12.2 Explicit I/O and success-only runtime authority

Native adapters take explicit I/O capabilities.
The pure schema and consumer operations need no I/O parameter.
There is no global runtime.

`RuntimeRelease` transfers only at the final successful constructor return.
A failed constructor leaves the runtime lease caller-owned and never invokes its release hook.
The outer Windows subclass constructor gives its inner constructor no release hook.
It arms the retained authority only after outer attachment succeeds.
Source: `adapters/windows/src/subclass.rs:82-171`,
`src/adapters/windows/subclass.zig:95-148`,
`src/adapters/windows/adapter.zig:149-180`,
`src/adapters/windows/context.zig:57-60,392-401`.

Close rejects new admission and joins admitted callbacks before it releases owner state.
Weak provider handles can outlive adapter close.
The final weak release ends retained runtime authority.
The provider allocator must remain independently valid through all cleanup, including cleanup after the runtime-release hook.
An allocator owned by that released runtime cannot satisfy this contract.
Source: `adapters/windows/src/context.rs:19-97`,
`src/adapters/windows/context.zig:297-401`, `src/adapters/windows/com.zig:217-225`.

Mac creation uses the same success-only rule.
Mac queries hold an admitted owner pin, but release the tree guard before native calls and action callbacks.
Close joins pins and clears the owner before provider resources disappear.
The placeholder-to-current-full epoch has only the transition `0` to `1`.
It does not invent generic per-ID generations.
Source: `src/adapters/macos/context.zig:46-74,122-185`,
`src/adapters/macos/native.zig:118-144,300-345` at the Mac revision above.

Linux takes `gpa`, `io`, and `*Runtime` explicitly.
Its reader, writer, bounded queues, completion receipts, and close barrier belong to one transport owner.
Enqueue success does not mean a tree update committed.
The owner settles accepted work and joins transport tasks before runtime destruction.
The upstream comparison is `adapters/unix/src/context.rs:33-76,169-313`,
`adapters/unix/src/atspi/bus.rs:39-103`, and `adapters/unix/src/executor.rs:34-87`.
The explicit runtime, bounded pump, and join barrier are port extensions, not copied Rust API shapes.
Source: `src/adapters/atspi/adapter.zig:175-178,361-397`,
`src/adapters/atspi/pump.zig:106-151,186-220,250-294,484-510`.
The C wrapper owns its environment, I/O provider, runtime, and native adapter.
It destroys the native adapter before those authorities.
Source: `src/adapters/atspi/root.zig:100-180,285-316`.

### 12.3 Native Windows and Mac providers

Windows now has actual COM node and text range providers, owning queued events, and native Automation values.
Providers keep weak context handles, not live `NodeRef`, `Range`, or adapter pointers.
Final COM release destroys provider state exactly once.
Registry removal releases registry ownership before later fallible notification work.
Queues own old and new values and transfer event ownership only after append succeeds.
Source: `adapters/windows/src/node.rs:743-825`, `adapters/windows/src/text.rs:209-221`,
`src/adapters/windows/elements.zig:130`, `src/adapters/windows/queued_events.zig:76,133`,
`src/adapters/windows/change_handler.zig:358-423`, `src/adapters/windows/root.zig:48`.
The item ledger maps every provider interface and text operation.
No Linux portable check establishes real UI Automation execution.

Mac installs all 54 node selectors and the four view selectors from the pinned upstream tables.
The text provider handles the thirteen text selectors and UTF-16 index conversions.
Native objects resolve through a leased context rather than a retained tree borrow.
View attachment is reversible and per-instance.
Attachment does not patch the window class implicitly.
Explicit focus forwarding applies only to the caller's registered custom NSWindow class.
Source: `adapters/macos/src/node.rs:412-1234`, `adapters/macos/src/subclass.rs:179-191`,
`src/adapters/macos/attributes.zig:187-249,272-277`,
`src/adapters/macos/platform_node.zig:43-83,343`,
`src/adapters/macos/platform_text.zig:315-342,498,609-620` at the Mac revision above.

The selected SDK's representable Objective-C runtime declarations come from `translate-c`.
Only four polymorphic message-dispatch symbols need typed ABI casts.
The AppKit seam has sixteen hidden SDK-compiled bodies.
They comprise two notification forwards, three announcement getters, and eleven style-key getters.
The named rung-four reason is Objective-C interfaces and opaque NSString declarations that `translate-c` cannot represent.
The shim returns real SDK constants without copies or fabricated keys.
Source: `src/adapters/macos/runtime.h`,
`src/adapters/macos/foundation.m:33-108`, `src/adapters/macos/foundation.h:14-24`.
SDK declaration provenance is Apple header blob `d46725739a34f180d2d7913e0ca96a50c783a72d`:
`NSAccessibilityConstants.h:130-142,187-189,571-575`.
This source mapping is not a Mac SDK compilation or runtime receipt.

### 12.4 Twelve AT-SPI interfaces and positioned edits

The Linux source implements all twelve pinned interfaces.
`docs/52-translation-ledger.md` maps each interface's methods, properties, and common-node counterparts.
The object register exports mandatory and computed optional interfaces.
Missing objects use `UnknownObject`. A valid missing interface uses `UnknownInterface`.
Image and Text multiple outputs use flattened D-Bus signatures, not an extra enclosing structure.
Upstream paths in this table are relative to `adapters/unix/src/atspi/interfaces/`.
Zig paths are relative to `src/adapters/atspi/interfaces/`.

| Interface | Pinned upstream source | Zig source |
|---|---|---|
| Accessible | `accessible.rs:33-145,166-245` | `accessible.zig:18-38,40-171` |
| Action | `action.rs:21-50` | `action.zig:9-19,21-61` |
| Application | `application.rs:13-38` | `application.zig:13-18,25-43` |
| Cache | `cache.rs:31-112` | `cache.zig:15-19,21-97` |
| Component | `component.rs:27-76` | `component.zig:10-19,21-71` |
| Document | `document.rs:29-60` | `document.zig:10-21,23-55` |
| EditableText | `editable_text.rs:27-52` | `editable_text.zig:12-21,23-86` |
| Hyperlink | `hyperlink.rs:26-63` | `hyperlink.zig:9-18,20-54` |
| Image | `image.rs:22-50` | `image.zig:10-18,20-56` |
| Selection | `selection.rs:26-82` | `selection.zig:9-20,22-61` |
| Text | `text.rs:27-159` | `text.zig:15-38,42-153` |
| Value | `value.rs:23-49` | `value.zig:9-15,21-44` |

The wire domains use AT-SPI numeric values, not schema ordinals.
Roles, states, layers, and relations carry complete domain sweeps and literal-value fixtures.
Their authority is `atspi-common` 0.13.0 source, not live captured bytes.
Source: `atspi-common/src/role.rs:337-467`, `state.rs:18-221,372-376,478-508`,
`relation_type.rs:6-121`, `lib.rs:128-150`,
`src/adapters/atspi/wire.zig:283-321,343-524,610-652,706-754`.

The SENDER field accepts a valid unique name or exactly `org.freedesktop.DBus`.
This reserved driver identity is not permission for arbitrary well-known senders.
Upstream: `zbus_names` 4.3.4 `src/unique_name.rs:31-39`
([source](https://docs.rs/crate/zbus_names/4.3.4/source/src/unique_name.rs#L31-L39)),
and D-Bus 0.43 [header fields](https://dbus.freedesktop.org/doc/dbus-specification.html#message-protocol-header-fields)
and [message-bus identity](https://dbus.freedesktop.org/doc/dbus-specification.html#message-bus).
Zig: `src/adapters/atspi/dbus.zig:535-539,888-897,1400,1431,1450`,
snapshot `c6ac4e75eb6c3596a430e9f0f9088aee8576c56a`.
The captured Hello packet and independent registry registration are narrow observations.
They do not prove the remaining real provider matrix.

The optional immutable `Callbacks.editable_text` slot accepts a half-open Unicode-scalar replacement range.
`replacement_utf8` is a length-delimited borrow valid through the synchronous callback.
The host copies accepted bytes once into its existing ordered FIFO.
The native adapter adds no second text copy or command queue.
A null slot preserves pinned `InsertText` and `DeleteText` `NotSupported` behavior after signature validation.
`SetTextContents` stays on the ordinary action channel. Copy, cut, and paste stay unsupported.
Source: `adapters/unix/src/atspi/interfaces/editable_text.rs:27-52`,
`src/adapters/atspi/objects.zig:29-44,78-79`,
`src/adapters/atspi/interfaces/editable_text.zig:31-77`.

The enabled slot rejects negative scalar offsets, reversed ranges, and split UTF-8 byte prefixes.
It does not use stale published character counts as an upper bound.
The live host model validates each accepted edit when it drains its FIFO.
False maps to `Failed` with `CallbackFailed`. Exact callback errors, including `OutOfMemory`, remain named.
The callback runs on the owned pump lane without a tree guard.
Close stops admission and joins it before userdata release.
Source: `src/adapters/atspi/dispatch.zig:43-45,73-77,1211-1486`,
`src/adapters/atspi/adapter.zig:756-768`.
This callback is a port extension, not a changed standard schema or C action payload.

### 12.5 Mobile errors and recorded geometry

Mobile C action producers use the shared owning conversion.
The callback receives an independent request in the configured C allocator domain.
`OutOfMemory` and `InteriorNul` remain distinct.
The exact-error diagnostic is a port addition, not an upstream mobile error API.

| Behavior | Pinned upstream source | Zig source |
|---|---|---|
| Android action producer | `adapters/android/src/adapter.rs:805` | `src/adapters/android/adapter.zig:636-644` |
| iOS action producer | `adapters/ios/src/context.rs:92-94` | `src/adapters/ios/root.zig:1068,1088-1092` |
| Android null-factory refusal | `adapters/android/src/adapter.rs:554` | `src/adapters/android/root.zig:244-501,864-870` |
| iOS activation and update refusals | `adapters/ios/src/adapter.rs:128-188,398-436` | `src/adapters/ios/root.zig:565-628,1275-1306,1351-1362` |
| iOS raw public debug CString | `adapters/ios/src/adapter.rs:327-333` | `src/adapters/ios/root.zig:751-760,1675-1693` |
| C request payload and outer release | `accesskit-c/src/common.rs:1166-1197` | `src/adapters/android/adapter.zig:914-915,987-989`, `src/adapters/ios/root.zig:2608-2610` |

Only exact `OutOfMemory` maps to `out_of_memory`.
Other finite failures map to `operation_failed` with their original static error names.
Ordinary `NoWindow` and `NoCoordinateSpace` absence remains unchanged.
The first event-slot error keeps diagnostic authority over later failures.
Source: `src/adapters/ios/root.zig:1104-1117,1856-1859`,
`src/capi/allocation.zig:239-288`.

Android scrolled payloads preserve independent axes and optional maxima by value.
The zero-maximum failure exposed a sorted-property merge defect.
The correction preserves sorted unique property order and owning payload cleanup.
Source: `accesskit/src/lib.rs:1164-1167`, `src/schema/props/table.zig:1512-1563`,
table-only snapshot `e8cd20cbd2b07ab3b96bf0ce97c0c3db3aa1e14a`.
Focused and full-table checks passed. The full Android safety-mode results remain pending.
The queue-OOM fixture also needed correction to reach the intended post-commit refusal.
`docs/52-translation-ledger.md` maps the source.
`docs/50-verification.md` section 11 records actual receipts without claiming JNI execution.

The recorded geometry inventory now adds far-edge exclusion, empty-origin containment, and the all-zero affine inverse.
Source: `accesskit/src/geometry.rs:519-521,99-113`,
`test/fixtures/geometry.json:7-9`, `reference_root.zig:194-209,260-280`,
`test/c_consumer/consumer.c:1791-1810,1867-1876`.
These are hand-recorded source fixtures, not executed Rust or native platform evidence.
No speedup claim follows from their addition or the synthetic profiles.
