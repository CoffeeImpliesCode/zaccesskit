# 34 — The design record corrected by the first wave, 2026-10-05

## 1. Scope and method

The research documents under `docs/` were written before any Zig existed. The
first wave of translations then measured several things the record got wrong.
This file is the dated correction record. It says what was wrong, what the
measurement is, and which document line carries the stale claim.

**Toolchain.** Zig **0.16.0**. `build.zig.zon:11` holds
`.minimum_zig_version = "0.16.0"`, and the `anyzig` shim on `PATH` reads that
field to select the compiler. The shim confirmed the selection at run time:

```text
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
0.16.0
```

**Method.** Every number in this file is a **measurement**, not a reading of a
document. The layout numbers come from `@sizeOf`, `@alignOf`, `@offsetOf` and
`@typeInfo(T).@"struct".layout`, evaluated by the compiler. The line counts come
from counting the newlines in each file as it stands under `src/schema/`. Every
declaration quoted here was read at the line number printed beside it, in the
read-only upstream checkout at
`/tmp/scratch/accesskit/accesskit/src/` or in this repository.

**Where the run happened.** A scratch mirror at
`/tmp/scratch/DesignRecordCorrections/mirror`. The five geometry
files were copied in immediately before the run and their `md5` sums matched the
live tree. The command was `zig 0.16.0 test src/probe.zig`, run at
`2026-10-05T04:33:23+02:00`. It exited 0 with `All 77 tests passed.` Seventy
of those 77 are the geometry modules' own tests, so the run reached them and
did not pass silently.

**`zig build test` was no alternative at this revision, and that has changed.**
The paragraph read: "`zig build test` was no alternative at this revision. It roots
at `src/root.zig`, which declares `version` at `:34` and `minimum_zig_version` at
`:40` and imports no module under `src/schema/`. A green `zig build test` here
compiles two constants and two tests." The two line numbers are stale now, and the
claim about the import graph is false now.

A count over the tree on 2026-10-05 gives the correction. `src/root.zig` is 127
lines and declares five names: `schema` at `src/root.zig:36`, `consumer` at `:49`,
`capi` at `:57`, `version` at `:68` and `minimum_zig_version` at `:74`. The root
imports `src/schema/` at line 36, so the claim that it imports no module under
`src/schema/` is wrong. All 24 schema modules are in the import graph from that
root, each carries a `refAllDecls` test on its own namespace, and a green
`zig build test` therefore compiles all 24 rather than two constants.

**Status of the originals.** The design documents stay exactly as they were
written, and nothing in `docs/10` through `docs/30` is edited by this file. This
file **supersedes** them. A reader should read the original and then read this,
because the original carries the mistakes this file names.

**Relation to `docs/32`.** `docs/32-layout-and-naming-corrections.md` is the
earlier dated record. This file adds `Rect`, the accessor shape and the budgets.

---

## 2. `Rect` carries no transform

### 2.1 What upstream declares

`accesskit/src/geometry.rs:337-346` declares the struct, with `#[repr(C)]` at `:336`:

```rust
#[repr(C)]
pub struct Rect {
    pub x0: f64,
    pub y0: f64,
    pub x1: f64,
    pub y1: f64,
}
```

The four field doc comments are at `:338-345`, and they name `x0` and `y0` the
minimum coordinates and `x1` and `y1` the maximum. Four `f64` and no pointer. The
`impl Rect` block at `accesskit/src/geometry.rs:397-564` holds exactly twenty
methods, `new` at `:403` to `intersect` at `:557`, and none stores a transform.

### 2.2 Where the transform actually lives

Two places, both read at the cited line. `accesskit/src/lib.rs:881`, inside
`enum PropertyValue` at `:856-886`, reads `Affine(Box<Affine>),`, and
`accesskit/src/lib.rs:2521`, the `Transform` row of `property_methods!`, reads
`(Transform, transform, get_affine_property, Option<&Affine>, set_transform,
set_affine_property, impl Into<Box<Affine>>, clear_transform),`.

The neighbouring property row at `accesskit/src/lib.rs:2533` carries
`Option<Rect>`, and the union arm at `:882` carries a bare `Rect`.

### 2.3 The measured consequence

The probe measured `Rect` at 32 bytes, alignment 8, with `x0` at 0, `y0` at 8,
`x1` at 16 and `y1` at 24. It also measured the shape this section argues
against, a `Rect` plus one optional transform pointer:

```text
RectWithTransformPointer
  @sizeOf  40
  @alignOf 8
  layout   .auto
  @offsetOf RectWithTransformPointer.x0 0
  @offsetOf RectWithTransformPointer.y0 8
  @offsetOf RectWithTransformPointer.x1 16
  @offsetOf RectWithTransformPointer.y1 24
  @offsetOf RectWithTransformPointer.transform 32
```

One pointer turns a 32-byte box into a 40-byte box. That is 8 bytes, or one
quarter of the box, for every stored rectangle. A node holds one rectangle per
property, and a tree holds one node per accessible object.

### 2.4 The control row, and why the numbers carry

The same probe declared a throwaway plain `struct { small: u8, big: u64 }`:

```text
PlainTwo
  @sizeOf  16
  @alignOf 8
  layout   .auto
  @offsetOf PlainTwo.small 8
  @offsetOf PlainTwo.big 0
```

`big` takes offset 0 and `small` takes offset 8, so on a plain `struct` the
declaration order is not the byte order. Every geometry type reports
`layout .extern`, and `extern` is the property that fixes the declaration order
as the byte order. `docs/32` section 2 records the same refutation of rule L1
from the other direction, with `CustomAction`.

### 2.5 The scope of the drop rule

`docs/30-port-design.md:251` reads:

> The `Box<Affine>` and `Box<TextSelection>` payloads, because a pointer in a
> union payload needs a recursive teardown and costs one allocation per node
> per update.

That sentence is correct, and its scope is the **two `PropertyValue` payloads**.
It is not a statement about `Rect` and must not be read as one. The decision
about the transform belongs to the `Transform` property, and the port states it
in the module that owns it, `src/schema/props/option.zig:88-95`:

> Upstream returns `Option<&Affine>` over a stored `Option<Box<Affine>>`. The
> port drops the `Box` and holds the 48 bytes inline, so a read has no teardown
> to follow and a setter costs no allocation beyond the growth of the store.

The getter at `src/schema/props/option.zig:96` returns `?*const Affine`, the
setter is `setTransform` at `:113` and the clearer is `clearTransform` at `:121`.
The split is upstream's own rather than a port invention.
`option_ref_type_getters` at `accesskit/src/lib.rs:1977-1982` returns references,
with `get_affine_property` at `:1978` and `get_text_selection_property` at
`:1981`, while `copy_type_getters` at `:1988-1998` returns copies, with
`get_rect_property` at `:1989` and `get_tree_id_property` at `:1997`. The borrow
has no teardown because nothing owns the transform.

### 2.6 The lines in `docs/30` that carry the wrong reading

Two lines read together produce the reading. Neither states it alone, and this
record says so rather than pretending otherwise. `docs/30-port-design.md:153` is
the geometry row, and it gives `Affine`, `Point`, `Rect` (20 methods), `Size`
and `Vec2` in one row under `geometry.rs:22-866` with a 530-line budget.
`docs/30-port-design.md:251` is the `Box<Affine>` payload drop. Read beside each
other, a reader binds the dropped box to `Rect`.

Checked and left alone: `docs/30-port-design.md:185` gives the transforms to
`consumer/node_ref/geometry.zig`, beside the `NodeRef` hierarchy queries. That
row is already right and it is the row a reader needs.

---

## 3. The property accessors are free functions, not methods on `Node`

### 3.1 What the documents describe

`docs/10-accesskit-core.md:1405` titles its table "the 336 generated property
methods", `:1408` gives a "Zig method-name pattern" per property, and
`:1439-1440` says "All three take `*Node` for the mutators and `*const Node`
for the getter." `docs/10-accesskit-core.md:3834` calls them "all 336
accessors", `:3848-3850` makes them "the only supported path" and `:3951` says
"The macros generate 324 of the 336 `Node` methods." `docs/30` `:237-239` says
the same in its own words, with "3 or 4 **methods** each".

### 3.2 Why the port does not follow upstream here

The reason Rust hangs 270 property accessors on `Node` is that a trait impl
extends a type. Zig has no operator overloading, no traits and no trait objects,
so the reason does not carry over. The corpus already says so three times:
`docs/10-accesskit-core.md:3929` gives "Rust has operator overloading", `:3936`
gives "Rust macros", and `:1740-1741` says a trait-object form becomes a struct
of function pointers. A struct with 336 methods is a Rust shape imported without
asking whether it earns its place.

### 3.3 What the port ships

One getter, one setter and one clearer per property. Each is a **free function**
whose **first parameter is the store**. `src/schema/props/colors.zig` shows the
shape for one property:

```text
src/schema/props/colors.zig:61:  pub fn colorValue(properties: *const Properties) ?Color
src/schema/props/colors.zig:77:  pub fn setColorValue(properties: *Properties, value: Color) std.mem.Allocator.Error!void
src/schema/props/colors.zig:83:  pub fn clearColorValue(properties: *Properties) void
```

The eight modules that hold those triples are the eight `props/` modules
`docs/30-port-design.md:160-165` names beside the table: `flags.zig`, `ids.zig`,
`strings.zig`, `numbers.zig`, `colors.zig`, `vectors.zig`, `enums.zig` and
`option.zig`. `props/table.zig` sits below them and owns the store and the fifty
generic accessors of `docs/30-port-design.md:235`. Seven of the eight had landed
at the snapshot in section 6. `props/vectors.zig` had not, and this record states
no count for it.

`Node` keeps its five fields, its constructor, its exactly-once `deinit` and the
eleven written methods in its upstream range. The five fields are at
`src/schema/node.zig:92-107` against `accesskit/src/lib.rs:1107-1113`, the
constructor `Node.init` at `:114` against `Node::new` at `lib.rs:1828`, and the
teardown at `:209`. There is no `Drop` upstream to translate.

The eleven written methods of `accesskit/src/lib.rs:1828-1907` run from `new`
at `:1828` to `clear_child_actions` at `:1904`, with `role` at `:1858` and
`set_role` at `:1862` between them. The port spells them `init`, `setRole`,
`supportsAction`, `addAction`, `removeAction`, `clearActions`,
`childSupportsAction`, `addChildAction`, `removeChildAction` and
`clearChildActions`.

### 3.4 The import graph, and why it stays acyclic

`src/schema/node.zig` imports `action.zig`, `ids.zig`, `role.zig` and
`props/table.zig`. Every module under `src/schema/props/` imports `table.zig`
plus a sibling below it, and **none** imports `../node.zig`. `props/` therefore
sits strictly below `node/`, and the graph has no cycle.
`docs/30-port-design.md:170` sets the same direction for the update protocol,
and the measurement agrees, because `update.zig` imports `node.zig` and
`node.zig` does not import `update.zig`.

---

## 4. The geometry family naming

### 4.1 The rule the port now uses, in full

1. The base names are `add`, `sub`, `scale`, `divide`, `negate` and `mul`.
2. A scalar multiply is `scale` and a scalar divide is `divide`, never
   `mulScalar` and never `divScalar`.
3. A two-type operation suffixes the other operand, as in `addVec2`, `subVec2`
   and `subPoint`.
4. A name that collides with a Zig keyword takes a disambiguating suffix rather
   than an escape. `union` is a keyword, so the two unions are `unionRect` and
   `unionPoint`.
5. The assign family is deleted everywhere, including the in-place multiply on
   `Affine`, and in-place composition is `a.* = a.mul(b)`. This overrides
   `docs/10-accesskit-core.md:1766` and `docs/10-accesskit-core.md:3930`.
6. A conversion between geometry types is a file-scope function prefixed by the
   producing type: `rectSize`, `rectFromPoints`, `pointToVec2`, `sizeToVec2`,
   `vec2ToPoint`, `vec2ToSize`.

`docs/32` section 5 states rules 1 to 6. This record restates them because three
agents translated the family and each read a different document.

### 4.2 Every document line that gives a different name

Found by grep for each stale name over `docs/`. This record does not repeat the
sixteen rows that `docs/32` section 5.4 already indexes, because one index is
better than two. Those lines are `docs/10-accesskit-core.md:1764`, `:1766`,
`:1767` and `:1772`, `:1784`, `:1838`, `:1839`, `:1840`, `:1843`, `:1845`,
`:1847`, `:1851`, `:3874`, `:3878`, `:1860-1863` and `:3930`, plus
`docs/24-rust-idiom-mapping.md:666-667`. The table below holds the rest.

| Document and line | Stale name | Corrected |
|---|---|---|
| `docs/10-accesskit-core.md:1769` | `mulAffine` | `mul` and `mulPoint` |
| `docs/10-accesskit-core.md:1787` | `subPoint` returns `Point` | returns `Vec2` |
| `docs/10-accesskit-core.md:1812` | `origin` | `topLeft` |
| `docs/10-accesskit-core.md:1829` | `rectInit` can be dropped | `rectInit` stays |
| `docs/19-geometry-and-text.md:1222` | `transformPoint` | `mulPoint` |
| `docs/19-geometry-and-text.md:1234` | `sub` for `Point - Point` | `subPoint` |
| `docs/19-geometry-and-text.md:1236` | `fromPoints` | `rectFromPoints` |
| `docs/19-geometry-and-text.md:1237` | `fromOriginSize` | `rectFromOriginSize` |
| `docs/19-geometry-and-text.md:1238` | `translate` for `Rect + Vec2` | `addVec2` |
| `docs/19-geometry-and-text.md:1239` | `translateBy` for `Rect - Vec2` | `subVec2` |
| `docs/19-geometry-and-text.md:1261` | `affine_identity` | `affineIdentity` |
| `docs/19-geometry-and-text.md:635-637` | `affine_flip_y`, `affine_flip_x` | `affineFlipY`, `affineFlipX` |
| `docs/19-geometry-and-text.md:1285` | "delete `Point::ORIGIN`" | `pointOrigin` stays |

`docs/19-geometry-and-text.md:1285` is half right. Its `Rect::origin()` to
`topLeft()` rename agrees with the port, and its `delete Point::ORIGIN` does not,
because `docs/10-accesskit-core.md:1782` and `src/schema/geometry/point.zig:102`
both keep `pointOrigin`.

---

## 5. `format` is a method on every geometry type that has one

### 5.1 The compiler fact

`lib/std/Io/Writer.zig:1077`, inside `pub fn printValue` declared at `:1065`, at
the compiler this project pins:

```zig
'f' => return value.format(w),
```

`{f}` resolves by calling `value.format(w)` **as a member**. A file-scope
`format` on one geometry type and a method `format` on another is invisible
until something formats both, and the failure then reads as a writer bug.

### 5.2 What the port ships, and why it is the exception

`Point.format` is a method at `src/schema/geometry/point.zig:91`,
`Size.format` at `src/schema/geometry/size.zig:65` and `Rect.format` at
`src/schema/geometry/rect.zig:212`. `Affine` and `Vec2` carry no `format`, so
they have nothing to place. The run in section 1 exercised the resolution, and
two of its tests are `a Point prints through the {f} specifier` and `format
reports a short writer as error.WriteFailed`.

This is a deliberate exception to the file-scope rule of section 4, rule 6. A
conversion is a value another type derives, so it belongs at file scope beside
the producing type. `format` is a **behaviour the writer invokes**, so it is
placement-sensitive and only a member satisfies `lib/std/Io/Writer.zig:1077`.
`docs/19-geometry-and-text.md:1262` says "one `format` function per type", which
reads as file scope. The method is correct.

---

## 6. Budgets rebudgeted

### 6.1 The measurement

Snapshot of `2026-10-05T04:35:18`, counted from the files as they stand under
`src/schema/`. The targets are the budget column of `docs/30-port-design.md`
section 3.1. Nine agents were still writing, so these figures move. The rows are
ordered by overage.

| Budget row in `docs/30` section 3.1 | Target | Measured | Over | Files |
|---|---:|---:|---:|---|
| `props/enums.zig` + `props/option.zig` | 270 | 1382 | +1112 | 946 + 436 |
| five `geometry/` modules | 530 | 1581 | +1051 | 458 + 239 + 481 + 175 + 228 |
| `schema/update.zig` | 180 | 953 | +773 | 953 |
| `props/ids.zig` | 190 | 746 | +556 | 746 |
| `node_enums.zig` + `scroll_enums.zig` | 240 | 748 | +508 | 562 + 186 |
| `props/numbers.zig` | 240 | 743 | +503 | 743 |
| `props/strings.zig` | 240 | 662 | +422 | 662 |
| `schema/values.zig` | 90 | 469 | +379 | 469 |
| `props/flags.zig` | 100 | 437 | +337 | 437 |
| `props/colors.zig` + `props/vectors.zig` | 230 | 516 | +286 | 516, `vectors.zig` absent |
| `schema/handlers.zig` | 120 | 363 | +243 | 363 |
| `schema/node.zig` | 150 | 364 | +214 | 364 |
| `schema/ids.zig` | 90 | 278 | +188 | 278 |
| `schema/action.zig` | 90 | 259 | +169 | 259 |
| `schema/role.zig` | 240 | 362 | +122 | 362 |
| `props/table.zig` | 240 | 0 | not written | not written |
| **Total** | **3240** | **9863** | **+6623** | |

### 6.2 What the overage is

The overage is not padding. It is two things the house rules require and the
targets did not price. First, a **doc comment on every public item**:
`skill://zig-api-design` section 3 makes that a requirement for every supported
module, type and method, and a 22-tag enum with a comment on every tag is mostly
comment. Second, a **test per variant and per property**: `AGENTS.md` section 3
asks for a comptime sweep, and `props/numbers.zig` spends 743 lines on 22
properties, so each property carries a getter, a setter and a clearer test.

The targets were estimates made before the files existed, and
`docs/30-port-design.md:141` says so: "Every budget below is a target, not a
measurement." A target that is wrong by a factor of five on the two largest rows
is not a defect in the files. Reissue the budget column from the counts above,
and do not cut the doc comments or the per-property tests to reach a number that
was guessed. The furthest over are `props/enums.zig` and `props/option.zig` at
+1112, the five geometry modules at +1051, and `schema/update.zig` at +773.

---

## 7. The measurement table

**Toolchain.** Zig 0.16.0, selected through the `anyzig` shim from
`build.zig.zon:11`. **Method.** One `zig 0.16.0 test src/probe.zig` run in the
scratch mirror of section 1, at `2026-10-05T04:33:23+02:00`, exit 0.
**Provenance.** Every row below is **measured by compiling**. No row is read
from a document.

| Type | Kind | `@sizeOf` | `@alignOf` | Offsets that matter | Provenance |
|---|---|---:|---:|---|---|
| `Affine` | `extern struct` | 48 | 8 | `coeffs` 0 | measured |
| `Point` | `extern struct` | 16 | 8 | `x` 0, `y` 8 | measured |
| `Size` | `extern struct` | 16 | 8 | `width` 0, `height` 8 | measured |
| `Rect` | `extern struct` | 32 | 8 | `x0` 0, `y0` 8, `x1` 16, `y1` 24 | measured |
| `Vec2` | `extern struct` | 16 | 8 | `x` 0, `y` 8 | measured |
| `PlainTwo`, control | plain `struct` | 16 | 8 | `small` 8, `big` 0 | measured |
| `RectWithTransformPointer` | plain `struct` | 40 | 8 | `transform` 32, corners 0/8/16/24 | measured |

The layout column is the load-bearing one. `extern` means the declaration order
is the byte order. `auto` means the compiler chose, and the control row shows it
choosing against the declaration. A row whose numbers came from a document
would not tell the two apart.

**Cross-check against the record.** `docs/19-geometry-and-text.md:514-518` and
`:528-531` publish the same five sizes, the same five alignments and the same
`Rect` and `Affine` offsets from an independent probe, and the two runs agree.
An agreement with a document is not what makes a measurement trustworthy.

---

## 8. The stale-claim index

Every document line this record supersedes, with the corrected statement and the
measurement or the quoted declaration beside it. Found by grep, not from memory.

### 8.1 `Rect` and the transform

| Document and line | Stale claim | Corrected | Evidence |
|---|---|---|---|
| `docs/30-port-design.md:153` with `:251` | `Rect` carries the transform the `Box<Affine>` rule drops | `Rect` is four `f64` and no pointer. The drop rule is about the `PropertyValue` payloads | `geometry.rs:337-346`, `lib.rs:881`, `:2521`, measured 32 against 40 |
| `docs/30-port-design.md:251` as a geometry rule | the `Box<Affine>` drop is a geometry decision | it is a property-payload decision, stated at `props/option.zig:88-95` | `lib.rs:882` carries a bare `Rect`, `:2533` carries `Option<Rect>` |

Checked and left alone: `docs/30-port-design.md:153` is right that `Rect` has
twenty upstream methods, and `:185` is right that the composed transforms belong
to `consumer/node_ref/geometry.zig`.

### 8.2 The accessor shape

| Document and line | Stale claim | Corrected | Evidence |
|---|---|---|---|
| `docs/10-accesskit-core.md:1405` | "the 336 generated property methods" | 105 properties, three free functions each, in eight `props/` modules | `props/colors.zig:61`, `:77`, `:83` |
| `docs/10-accesskit-core.md:1408` | the pattern is a "Zig method-name pattern" | it is a free-function name whose first parameter is the store | `props/colors.zig:61` |
| `docs/10-accesskit-core.md:1439-1440` | the mutators take `*Node`, the getter `*const Node` | the first parameter is `*Properties` or `*const Properties` | `props/colors.zig:61`, `:77` |
| `docs/10-accesskit-core.md:3834`, `:3848-3850` | 336 accessors on `Node` are the only supported path | the accessors are free functions, and `Node` keeps its five fields | `node.zig:92-107`, `lib.rs:1107-1113` |
| `docs/10-accesskit-core.md:3951` | 324 of the 336 `Node` methods come from the macros | `Node` carries fifteen methods, eleven from the written upstream range | `lib.rs:1828-1907` |
| `docs/30-port-design.md:237-239` | "3 or 4 methods each", "3 methods each" | one free function per operation | `props/colors.zig:61`, `:77`, `:83` |

Checked and left alone: `docs/30-port-design.md:166` already says `Node` and its
11 written methods, and the measurement confirms the count.

### 8.3 Naming and `format`

The naming rows are the table in section 4.2. Two of them carry a source beyond
the spelling. `docs/10-accesskit-core.md:1787` gives `subPoint` the result
`Point`, and `accesskit/src/geometry.rs:318` reads `type Output = Vec2;`, which
`src/schema/geometry/point.zig:76` matches.
`docs/10-accesskit-core.md:1829` offers to drop `rectInit`, and
`src/schema/geometry/rect.zig:244` keeps it.

`docs/19-geometry-and-text.md:1262` says "one `format` function per type" and
`docs/19-geometry-and-text.md:1285` says "delete `Point::ORIGIN`". The first is
a method per `lib/std/Io/Writer.zig:1077`. The second is wrong, because
`src/schema/geometry/point.zig:102` keeps `pointOrigin` and
`docs/10-accesskit-core.md:1782` already says so.

### 8.4 Budgets

No document line is superseded by section 6, because a budget is an estimate and
not a claim about the code. `docs/30-port-design.md:141` already says the
budgets are targets. The corrected numbers belong in that column at integration.

Also checked and left alone, because they are right: `docs/10-accesskit-core.md:1318-1323`
states the `Rect` invariants, and the port keeps each one.