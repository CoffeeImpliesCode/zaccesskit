# 32 — Layout and naming corrections, measured 2026-10-05

## 1. Scope and method

The research under `docs/` was written before any Zig existed. The first wave of
translations has measured several things the record got wrong. This file is the
dated correction record: what was wrong, what the measurement is, and which
document line carries the stale claim.

**Toolchain.** Zig **0.16.0**, selected by the `zig` shim from
`build.zig.zon:11`, which holds `.minimum_zig_version = "0.16.0"`. The `anyzig`
lines that confirm the selection are quoted at
`docs/19-geometry-and-text.md:512-513`.

**Method.** Every number below is a measurement, not a reading of a document. The
measurements come from `@sizeOf`, `@alignOf` and `@offsetOf` as they stand in the
port under `src/`, each beside the assertion that pins it, together with the
upstream Rust declaration and the checked-in C header line a layout claim must
agree with. Where a type is not written yet, this file says so and states no
number for it.

**Status of the originals.** The research documents stay exactly as written.
Nothing in `docs/10` through `docs/30` is edited by this file. This file
**supersedes** them, so a reader of the original reads the original and then this.
Section 8 lists every superseded line.

---

## 2. Layout rule L1 is false for a plain struct on Zig 0.16.0

### 2.1 The rule as written

`docs/10-accesskit-core.md:40`:

> L1 | A Zig `struct` field starts at the lowest offset at or after the previous
> end that is a multiple of `@alignOf(field type)`. The struct alignment is the
> largest field alignment. The struct size is the end of the last field rounded
> up to the struct alignment.

### 2.2 The measurement that refutes it

Zig 0.16.0 **reorders the fields of a plain `struct`** to remove padding, so a
declaration order is not an offset. The smallest worked example is a struct
declared `{ small: u8, big: u64 }`: `big` takes offset 0 and `small` takes offset
8. The field with the larger alignment moves ahead.

The in-repo instance of the same behaviour is `CustomAction`, declared
`pub const CustomAction = struct { id: i32, description: std.ArrayList(u8) }` at
`src/schema/values.zig:42` and `:53`. `description` is 24 bytes at alignment 8
and `id` is 4 bytes at alignment 4. L1 predicts `id` at offset 0 and
`description` at offset 8. The measurement is the other way round:

```text
src/schema/values.zig:311:    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CustomAction));
src/schema/values.zig:312:    try std.testing.expectEqual(@as(usize, 8), @alignOf(CustomAction));
src/schema/values.zig:313:    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CustomAction, "description"));
src/schema/values.zig:314:    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CustomAction, "id"));
```

Size 32, alignment 8, `description` at 0, `id` at 24. That is the reverse of what
L1 predicts. The module doc records the reason at `src/schema/values.zig:13-17`:
"Zig 0.16.0 reorders the fields of a plain struct to remove padding, so a
declaration order is not an offset."

### 2.3 L4 is correct, and the replacement rule

`docs/10-accesskit-core.md:43` says `extern struct` uses the C rules of L1 with
no reordering. That holds on this compiler, and this record does not change it.
Every type the C ABI names is an `extern struct`, so L4 covers the whole C seam.
`docs/31-c-abi-design.md:115` already says the same.

**The replacement rule. Any type whose byte offsets are part of a contract is an
`extern struct`. An internal type may be a plain `struct`, and its offsets are
measured with `@offsetOf`, never read from this record.**

### 2.4 The measured offsets of the affected types

| Type | Declaration | `@sizeOf` | `@alignOf` | Field offsets | Evidence |
|---|---|---|---|---|---|
| `CustomAction` | plain `struct` | 32 | 8 | `description` 0, `id` 24 | `src/schema/values.zig:311-314` |
| `Point` | `extern struct` | 16 | 8 | `x` 0, `y` 8 | `geometry/point.zig:126-129` |
| `Size` | `extern struct` | 16 | 8 | `width` 0, `height` 8 | `geometry/size.zig:91-97` |
| `Vec2` | `extern struct` | 16 | 8 | `x` 0, `y` 8 | `geometry/vec2.zig:107-110` |
| `Rect` | `extern struct` | 32 | 8 | `x0` 0, `y0` 8, `x1` 16, `y1` 24 | `geometry/rect.zig:38-43` |
| `Affine` | `extern struct` | 48 | 8 | `coeffs` 0 | `geometry/affine.zig:53-56` |
| `NodeId` | `extern struct` | 8 | 8 | `value` 0 | `src/schema/ids.zig:137-139` |
| `TreeId` | `extern struct` | 16 | 1 | `bytes` 0 | `src/schema/ids.zig:143-145` |
| `Color` | `extern struct` | 4 | 1 | `red` 0, `green` 1, `blue` 2, `alpha` 3 | `values.zig:331-338` |
| `TextDecoration` | `extern struct` | 5 | 1 | `style` 0, `color` 1 | `props/colors.zig:205-208` |
| `TextPosition` | `extern struct` | 16 | 8 | `node_id` 0, `character_index` 8 | `values.zig:318-321` |
| `TextSelection` | `extern struct` | 32 | 8 | `anchor` 0, `focus` 16 | `values.zig:325-328` |

Only `CustomAction` is a plain `struct`. Every other row keeps its declaration
order. A path that starts `geometry/` or `props/` is under `src/schema/`.

The other four plain `struct` types in `docs/10`, `Node`, `TreeInfo`,
`NodeEntry` and `TreeUpdate`, are not written yet, so this record states no number
for them. Their lines are in the index at section 8.1.

---

## 3. `Color` is four `u8`, not three `f32`

### 3.1 The declarations

Rust, `accesskit/src/lib.rs:833-839`:

```rust
#[repr(C)]
pub struct Color {
    pub red: u8,
    pub green: u8,
    pub blue: u8,
    pub alpha: u8,
}
```

C header, `accesskit-c/include/accesskit.h:754-759`: `typedef struct accesskit_color`
with `uint8_t red;` at `:755`, `green` at `:756`, `blue` at `:757` and `alpha` at
`:758`, closed by `} accesskit_color;` at `:759`.

### 3.2 The measurement

```text
src/schema/values.zig:331:test "Color is 4 bytes at alignment 1" {
src/schema/values.zig:332:    try std.testing.expectEqual(@as(usize, 4), @sizeOf(Color));
src/schema/values.zig:333:    try std.testing.expectEqual(@as(usize, 1), @alignOf(Color));
src/schema/values.zig:334:    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Color, "red"));
src/schema/values.zig:335:    try std.testing.expectEqual(@as(usize, 1), @offsetOf(Color, "green"));
src/schema/values.zig:336:    try std.testing.expectEqual(@as(usize, 2), @offsetOf(Color, "blue"));
src/schema/values.zig:337:    try std.testing.expectEqual(@as(usize, 3), @offsetOf(Color, "alpha"));
```

Size 4, alignment 1, four channels at 0, 1, 2 and 3. Three `f32` would be 12 bytes
at alignment 4. The measured size settles it.

### 3.3 The documents, checked by grep

A grep of every document for `f32` returns **no line that gives `f32` for
`Color`**. The `f32` claims in the corpus belong to `CharacterPositions`,
`CharacterWidths`, `FontSize` and `FontWeight`, which are genuinely `f32`
(`docs/15-tree-semantics.md:484-485`, `:528-529`). This record states the negative
result, because the reader would otherwise assume no grep was run. The one stale
claim is a count, not a type, and its row is at section 8.2.

Checked and left alone: `docs/10-accesskit-core.md:962-968` quotes the four `u8`
fields, `docs/11-accesskit-c-abi.md:355` names all four with their lines,
`docs/15-tree-semantics.md:1386` gives the wire form `{ 0xRR, 0xGG, 0xBB, 0xAA }`,
`docs/31-c-abi-design.md:440` states "Each component is an integer in `0..=255`",
and `docs/24-rust-idiom-mapping.md:212` names `#[repr(C)]`.

---

## 4. `PropertyId` has no `Unset` sentinel in the port

`accesskit/src/lib.rs:893` opens the enum, and `accesskit/src/lib.rs:1007-1009`
closes it:

```rust
    // This MUST be last.
    Unset,
}
```

The 88th variant carries the doc comment "This MUST be last". Its discriminant is
87, and `accesskit/src/lib.rs:1062` derives the index array length from it:
`struct PropertyIndices([u8; PropertyId::Unset as usize]);`

**The port drops it.** The port's enum has **87** variants and **no sentinel**. The
pin is `propertyIdCount == 87`, spelled by the same type-prefix rule as
`actionCount` at `src/schema/action.zig:91`. The sentinel exists upstream only
because the upstream index array is a fixed 87-byte table whose "no slot" value
is 87, and with 87 tags no store call can pass an invalid id.

**What replaces it.** The port stores a **sorted slice** of
`struct { id: PropertyId, value: PropertyValue }`, and a cleared property **leaves
that slice** (`docs/30-port-design.md:249-251`, `:344`). Absence from the slice is
the absent marker, so the type system carries what the sentinel encoded. A caller
cannot write 87 into an index array, because there is no index array, and a cleared
property cannot be read back, because it is no longer there. The seven documents
that still describe the sentinel are at section 8.3.

---

## 5. Naming: conversions and representation live at file scope, behaviour lives on the value

This is now a project rule. It is not in the research record.

**The rule.** A conversion or a representation helper is a file-scope function
whose name starts with the type that produces the value. A behaviour is a method on
the value that performs it. `format` is the one placement exception, and it is a
method, because `std.Io.Writer` resolves `{f}` by calling `value.format(writer)` as
a member.

**Why a name is prefixed by its type.** Zig has no associated constants, and a
module cannot extend a type it does not own. A bare `mask`, `fromInt` or `root`
therefore sits at file scope with no namespace, and `src/root.zig:10-11` states
that everything a consumer reaches is re-exported from one module root, which is a
flat namespace. Under a flat re-export a bare name collides with the same bare name
in every other module, and the compiler cannot see the collision.

### 5.1 The fixed spellings

> **Correction, 2026-10-05, after the first gate run.** The table at 5.1 was
> written from `docs/10-accesskit-core.md` rule Z3, which says a
> `SCREAMING_SNAKE_CASE` associated constant becomes a module-level `camelCase`
> const. **`ziglint`'s Z006 says a module-level `const` is `snake_case`, and the
> gate runs `ziglint`.** The house gate is the authority on whether a change is
> acceptable, so **Z006 wins and Z3 is superseded on this point.**
>
> Every **constant** in the table below is therefore `snake_case`, keeping the
> type prefix that keeps it unambiguous under a flat re-export:
> `affine_identity`, `affine_flip_y`, `affine_flip_x`, `point_origin`,
> `rect_zero`, `size_zero`, `vec2_zero`, `tree_id_root`. The same applies to the
> twelve `*Default` constants in `props/enums.zig`, to `property_descriptors`,
> `property_value_tags_by_id` and to `action_data_tags`.
>
> Every **function** keeps `camelCase`: `action_from_int` becomes
> `action_from_int` only if `ziglint` says so, and rule Z2 governs functions
> returning values, so `actionFromInt`, `actionMask`, `nodeIdFormat` and the
> `scrollUnit*` family stand as written.
>
> **The line column is a dated snapshot** taken at 2026-10-05 before a
> whole-tree rename sweep. Treat the spelling as authoritative and the line as
> approximate; `docs/35-translation-ledger-schema.md` carries the item-by-item
> mapping.

| Item | Spelling | Where it stands |
|---|---|---|
| `Affine::IDENTITY` | `affineIdentity` | `geometry/affine.zig:61` |
| `Affine::FLIP_Y` | `affineFlipY` | `geometry/affine.zig:65` |
| `Affine::FLIP_X` | `affineFlipX` | `geometry/affine.zig:68` |
| `Point::ORIGIN` | `pointOrigin` | `geometry/point.zig:102` |
| `Rect::ZERO` | `rectZero` | `geometry/rect.zig:242` |
| `Size::ZERO` | `sizeZero` | `geometry/size.zig:72` |
| `Vec2::ZERO` | `vec2Zero` | `geometry/vec2.zig:82` |
| `Action::n` | `actionFromInt` | `src/schema/action.zig:118` |
| `Action::mask` | `actionMask` | `src/schema/action.zig:123` |
| `action_mask_to_action_vec` | `actionSetMembers` | `src/schema/action.zig:152` |
| `Action` domain size | `actionCount` | `src/schema/action.zig:91` |
| `TreeId::ROOT` | `treeIdRoot` | `src/schema/ids.zig:119` |
| `NodeId::fmt` | `nodeIdFormat` | `src/schema/ids.zig:84` |
| `ScrollUnit` to text | `scrollUnitToStaticStr` | `src/schema/scroll_enums.zig:47` |
| `ScrollUnit` from a byte | `scrollUnitFromInt` | `src/schema/scroll_enums.zig:59` |
| `ScrollHint` to text | `scrollHintToStaticStr` | `src/schema/scroll_enums.zig:72` |
| `ScrollHint` from a byte | `scrollHintFromInt` | `src/schema/scroll_enums.zig:88` |

The **13 small property enums** each take a `<type>FromInt` gate in
`src/schema/node_enums.zig`: `orientationFromInt:205`, `textDirectionFromInt:215`,
`invalidFromInt:227`, `toggledFromInt:238`, `sortDirectionFromInt:249`,
`ariaCurrentFromInt:260`, `autoCompleteFromInt:275`, `liveFromInt:286`,
`hasPopupFromInt:297`, `listStyleFromInt:310`, `textAlignFromInt:324`,
`verticalOffsetFromInt:336`, `textDecorationStyleFromInt:346`. The module doc
states the form at `src/schema/node_enums.zig:10`.

The geometry operators carry two more rules. The base names are `add`, `sub`,
`scale`, `divide`, `negate` and `mul`. A scalar multiply is `scale` and a scalar
divide is `divide`, never `mulScalar` and never `divScalar`. When two different
types participate, the name carries the other operand's type, as in `addVec2`,
`subVec2` and `subPoint`. A name that collides with a Zig keyword takes a
disambiguating suffix, so `Rect`'s two unions are `unionRect` and `unionPoint`. The
whole assign family is deleted, and in-place multiply is `a.* = a.mul(b)`. The
geometry conversions are file-scope and prefixed by the producing type: `rectSize`
(`geometry/rect.zig:273`), `rectFromPoints` (`:255`), `rectFromOriginSize` (`:263`),
`pointToVec2` (`geometry/point.zig:116`), `sizeToVec2` (`geometry/size.zig:86`),
`vec2ToPoint` and `vec2ToSize` (`geometry/vec2.zig:94` and `:100`). A path that
starts `geometry/` is under `src/schema/`.

### 5.2 The documents that give a different spelling

Every row was found by grep for the stale name.

| Document | Stale spelling | Corrected |
|---|---|---|
| `docs/10-accesskit-core.md:1386` | `pub fn mask(self: Action) ActionMask` | `actionMask` |
| `docs/10-accesskit-core.md:1388` | `actionsFromMask` | `actionSetMembers` |
| `docs/10-accesskit-core.md:1372` | `NodeId` carries a `format` method | `nodeIdFormat` |
| `docs/10-accesskit-core.md:1764` | `applyToPoint` | `mulPoint` |
| `docs/10-accesskit-core.md:1766` | `mulAssign` | deleted |
| `docs/10-accesskit-core.md:1767`, `:1772` | `mulScalar` on `Affine` | `scale` |
| `docs/10-accesskit-core.md:1784` | `pub fn toVec2(self: Point)` | `pointToVec2` |
| `docs/10-accesskit-core.md:1838` | `pub fn toVec2(self: Size)` | `sizeToVec2` |
| `docs/10-accesskit-core.md:1839` | `mulScalarAssign` | deleted |
| `docs/10-accesskit-core.md:1840` | `mulScalar` on `Size` | `scale` |
| `docs/10-accesskit-core.md:1843` | `div` on `Size` | `divide` |
| `docs/10-accesskit-core.md:1845`, `:1847` | `addAssign`, `subAssign` | deleted |
| `docs/10-accesskit-core.md:1851`, `:3874`, `:3878` | `Size.mulScalar` in prose | `Size.scale` |
| `docs/10-accesskit-core.md:1860-1863` | `toPoint`, `toSize`, `addAssign`, `subAssign`, `mulScalar`, `mulScalarAssign`, `mulScalarReverse`, `divScalar`, `divScalarAssign` | `vec2ToPoint`, `vec2ToSize`, the assign family deleted, `scale`, `divide`, `negate` |
| `docs/10-accesskit-core.md:3930` | `xAddAssign` | deleted |
| `docs/24-rust-idiom-mapping.md:666-667` | `addTuple`, `addSize`, `subSize`, `Size` `mulScalar` and `divScalar`, `mulAffine` | `addVec2`, `subVec2`, `subPoint` and `mulPoint` stay, `addSize` and `subSize` become `add` and `sub`, `mulScalar` and `divScalar` become `scale` and `divide`, `mulAffine` becomes `mul`, `addTuple` is deleted |
| `docs/30-port-design.md:304` | `pub const root: TreeId` inside the struct | `treeIdRoot` at file scope |
| `docs/30-port-design.md:322` | `pub fn mask`, `pub fn fromInt` on `Action` | `actionMask`, `actionFromInt` |
| `docs/30-port-design.md:328` | `@typeInfo(PropertyId)."enum")` has one `)` too many | `@typeInfo(PropertyId).@"enum".fields.len`, as at `docs/30-port-design.md:317` |
| `docs/30-port-design.md:331` | `Action.count` and `PropertyId.count` | `actionCount`, `propertyIdCount` |
| `docs/17-rust-dependency-surface.md:238` | `nil` and `fromBytes` | `treeIdRoot`, `treeIdFromBytes` |
| `docs/23-core-boundary.md:790` | a `root` constant | `treeIdRoot` |

Checked and left alone, because the document already agrees:
`docs/10-accesskit-core.md:1246-1249`, `:1266-1269`, `:1286-1288`, `:1310-1311`,
`:1342-1343`, `:1750-1752`, `:1781-1783`, `:1790`, `:1818-1819`, `:1825`, `:1849`;
`docs/30-port-design.md:317`.

---

## 6. The `Role` reorder limitation

`src/schema/role.zig:329-347` carries the `comptime` block. It asserts the tag
count, that the enum stays exhaustive, the name of the first and last tag, and
then that **every** discriminant equals its own declaration index:

```zig
    for (info.fields, 0..) |field, index| {
        std.debug.assert(field.value == index);
    }
```

The test at `src/schema/role.zig:357-363` pins three values: `unknown` is 0,
`generic_container` is 14, and `terminal` is 181.

**The limitation, stated plainly.** The index sweep is **relative**. A wholesale
reorder that renumbers the whole enum to match satisfies it, because after the
reorder every tag still sits at its own index. That change passes every
checked-in test, including the three pinned values, as long as `unknown` stays
first, `terminal` stays last, and `generic_container` lands at 14. A sweep over the
declaration cannot detect a wrong declaration.

**What the declaration is today.** The order of `pub const Role` at
`src/schema/role.zig:35-327` is the **only** table of the wire values. The module
doc says so at `src/schema/role.zig:3-5` and `:27-32`. Nothing else in the tree
records which name carries which number.

**What would close it, and where it belongs.** A name-to-value table checked into the repository and compared against
the declaration at compile time: a `comptime` array of 182 `{ name, value }` pairs, checked against
`@typeInfo(Role).@"enum".fields`. A wholesale reorder then moves a value away from its name and the comparison
fails. It belongs in `src/schema/role.zig`, beside the declaration, because `role.zig` owns `Role` and therefore
owns the table that states its wire values. It does not belong in `schema/props/table.zig`, which owns the
property domain, and not in a test, because a test that reads the declaration proves nothing about it.

---

## 7. Two compiler facts worth recording

Both were found by agents compiling, and both will be rediscovered the hard way.

**The bare `assert` builtin is not in scope in a container-level `comptime` block** on Zig 0.16.0.
`std.debug.assert` is. Every container-level layout block in the port spells it out:
`src/schema/geometry/point.zig:126-132`, `geometry/rect.zig:38-43`, `geometry/vec2.zig:107-110`,
`geometry/affine.zig:53-56`. The reason is recorded in place at `geometry/point.zig:121-125`. Where a file
prefers the short name, it binds a local alias first, as `const assert = std.debug.assert;` at
`src/schema/ids.zig:21`, used at `:132-146`. The documents that already write the correct container-level
form are `docs/19-geometry-and-text.md:558-573`, `docs/31-c-abi-design.md:196-212` and
`docs/12-accesskit-adapters.md:1351`.

**`@typeInfo(T).@"enum"` has no `field_count`** on Zig 0.16.0. The `Enum` reflection type has `fields`, so the
member count is `@typeInfo(T).@"enum").fields.len`, and writing `field_count` is a compile error. The port
measures with `src/schema/action.zig:91`, `src/schema/role.zig:330`, `src/schema/node_enums.zig:387` and
`src/schema/scroll_enums.zig:106`. Every document uses the same form: `docs/15-tree-semantics.md:1282`,
`docs/18-testing-strategy.md:1086`, `docs/30-port-design.md:317`, `:328`, `:566`,
`docs/50-verification.md:429`, `:461`. No document carries the wrong form, so nothing needs correcting here.

---

## 8. The stale-claim index

Every document line this record supersedes, found by grep for the stale name and not by listing what was
remembered. The last column carries a number or a quoted line.

### 8.1 Layout, rule L1

| Document and line | Stale claim | Corrected statement | Measurement or declaration |
|---|---|---|---|
| `docs/10-accesskit-core.md:40` | L1 gives a plain `struct` offsets in declaration order | a plain `struct` is reordered; measure it or make it `extern` | `@offsetOf(CustomAction, "id") == 24`, `src/schema/values.zig:314` |
| `docs/10-accesskit-core.md:409` | "A plain `struct` gives the same numbers under L1" | size and alignment agree, offsets do not | `@offsetOf(CustomAction, "description") == 0`, `src/schema/values.zig:313` |
| `docs/10-accesskit-core.md:466-482` | `Node` is a plain `struct` with offsets 0, 4, 8, 12, 16 and alignment 4 | measure the offsets, and the alignment cannot be 4 while a field of alignment 8 is present | `src/schema/values.zig:13-17` |
| `docs/10-accesskit-core.md:872-874` | `CustomAction`: `id` at 0, `description` at 8 | `description` at 0, `id` at 24, size 32, alignment 8 | `src/schema/values.zig:311-314` |
| `docs/10-accesskit-core.md:1047-1049` | `TreeInfo` offsets 0, 8, 24 from L1 | measure the offsets | `src/schema/values.zig:13-17` |
| `docs/10-accesskit-core.md:1126-1128` | `NodeEntry` offsets 0, 8 from L1 | measure the offsets | `src/schema/values.zig:13-17` |
| `docs/10-accesskit-core.md:1130-1133` | `TreeUpdate` offsets 0, 24, 64, 80 from L1 | measure the offsets | `src/schema/values.zig:13-17` |

Checked and left alone: `docs/10-accesskit-core.md:297` and `:344-345` cite L1 for
a single-field type, where no reorder is possible, and `:480-481` and `:997-999`
cite L4 for an `extern struct`, where L4 holds.

### 8.2 `Color`

| Document and line | Stale claim | Corrected statement | Measurement or declaration |
|---|---|---|---|
| `docs/25-r2z-oracle-and-promotion.md:291` | `accesskit_color` is "three `uint8_t`" | four `u8`, size 4, alignment 1 | `accesskit-c/include/accesskit.h:754-759`; `src/schema/values.zig:331-338` |

No document says `f32` for `Color`. The negative grep result is at section 3.3.

### 8.3 `PropertyId`

| Document and line | Stale claim | Corrected statement | Measurement or declaration |
|---|---|---|---|
| `docs/10-accesskit-core.md:691-693` | the enum ends in a trailing `_` field "for `Unset`" | 87 tags, no sentinel, exhaustive | `docs/30-port-design.md:324-328` |
| `docs/10-accesskit-core.md:1713` | `valueAt` maps an index "treating `Unset` as `None`" | there is no index and no `Unset` | `docs/30-port-design.md:344` |
| `docs/10-accesskit-core.md:3662` | 88 values including `Unset` | 87 | `accesskit/src/lib.rs:1007-1009` |
| `docs/10-accesskit-core.md:4007` | a fixture proves "`Unset == 87`" | `propertyIdCount == 87` over 87 name-to-value pairs | `docs/30-port-design.md:331` |
| `docs/24-rust-idiom-mapping.md:786-790` | declare `Unset = <count>` and write `indices: [PropertyId.count]u8` | no tag, no index array, a sorted slice instead | `accesskit/src/lib.rs:1062` for the upstream array |
| `docs/50-verification.md:231` | "`PropertyId` has 87 and `Unset == 87`" | `propertyIdCount == 87` | `accesskit/src/lib.rs:1007-1009` |
| `docs/50-verification.md:429` | the same, in the role and property table row | the same | `accesskit/src/lib.rs:1007-1009` |

Checked and left alone, because they describe upstream: `docs/10-accesskit-core.md:112`,
`:543-550`, `:682-687`; `docs/15-tree-semantics.md:349-353`, `:1070`, `:1076-1077`;
`docs/23-core-boundary.md:618`, `:853`; `docs/30-port-design.md:144-147`.

### 8.4 Naming

The 22 rows are at section 5.2, each with the stale spelling, the corrected spelling, and the `src/` line that carries it.

### 8.5 Compiler facts

| Document and line | Stale claim | Corrected statement | Measurement or declaration |
|---|---|---|---|
| `docs/10-accesskit-core.md:15`, `:240`, `:410`, `:482`, `:569`, `:670`, `:763`, `:1133`, `:1183`, `:1219`, `:4053` | the port must add `comptime assert(...)` | in a container-level `comptime` block the form is `std.debug.assert(...)`, or a local alias | `src/schema/geometry/point.zig:121-132`; `src/schema/ids.zig:21`, `:132-146` |
| `docs/24-rust-idiom-mapping.md:389`, `:788` | the same spelling | the same | the same |

### 8.6 The `Role` reorder limitation

No document carries a stale claim. `docs/10-accesskit-core.md:760-763` and `docs/40-plan.md:108` describe the same `comptime` sweep the port
carries, and that sweep carries the limitation recorded at section 6.