# 35 — The translation ledger for the settled schema modules

## 1. How to read the ledger

The port states its method as a module-by-module, function-by-function
translation. This document is the record a reviewer checks that claim against.
Every row is one upstream public item and what the port did with it.

### 1.1 The pin

| What | Repository | Revision |
|---|---|---|
| Core crate | `AccessKit/accesskit` | `466e24e252103f4d82bd6fbab98141b551e46e0c` |
| C bindings | `AccessKit/accesskit-c` | `8b6ed37c20ed4c59390e253407983333053662ba` |

Compiler line: Zig 0.16.0. `build.zig.zon:11` reads
`.minimum_zig_version = "0.16.0"`.

Upstream locations in this ledger are written `accesskit/src/lib.rs:NN` and
`accesskit/src/geometry.rs:NN`, relative to the read-only checkout. Zig
locations are `src/schema/….zig:NN`, relative to this repository. Every Zig
line in this ledger was read from the file on disk, not taken from a report.

### 1.2 The rules the rows apply

These are the naming rules from `docs/10-accesskit-core.md` section 1.1.

| Rule | Statement |
|---|---|
| Z1 | A `PascalCase` type keeps its spelling. |
| Z2 | A `snake_case` function becomes `camelCase`. |
| Z3 | A `SCREAMING_SNAKE_CASE` associated constant becomes a module-level `camelCase` `const` prefixed by the type. |
| Z4 | A struct field keeps its `snake_case` spelling. |
| Z5 | An enum variant becomes a `snake_case` field with the upstream discriminant copied unchanged. |

Two further port rules shape many rows, and both are recorded in the source
rather than in `docs/10`.

| Rule | Statement | Where the port records it |
|---|---|---|
| P1 | Zig has no associated functions for an operation that takes no `self`, so the port puts the function at file scope and prefixes it with the type name. The flat re-export in `schema/root.zig` makes a bare `fromInt` collide across modules. | `src/schema/ids.zig:9-11`, `src/schema/action.zig:7-9` |
| P2 | `renamed by rule` covers every change of spelling. The reason column names the rule. Where the rule is Z2 or Z3 the row says so. Where the rule is another one the row names that one, and says so where the source departs from Z2 or Z3 as written. | this document |

`docs/19-geometry-and-text.md:1262` asks for one `format` function per
geometry type. Zig reaches a value through `value.format(writer)` under the
`{f}` specifier, so `format` is a member where the type carries it and a
file-scope function where it does not. The row for each `format` says which.

### 1.3 What a row means

A row pairs one upstream item with what the port did. The disposition is the
whole claim of the row.

| Disposition | Meaning |
|---|---|
| `translated` | The port carries the item, and the name is unchanged. |
| `renamed by rule` | The port carries the item under another spelling. The reason column names the rule. |
| `merged` | The port carries the behaviour, but not as a separate item. Upstream had more than one name for it, or the port attaches it to another item. |
| `deleted with reason` | The port does not carry the item. The reason column says why and says where the reason is recorded in the source. |
| `added by the port` | The Zig item has no upstream counterpart. The reason column names the decision that required it. |

`added by the port` is not a defect. `deleted with reason` is not either. Both
need the reason in the row, and a row without one is an incomplete ledger.

The reason column is filled on a `translated` row too, where the placement or
the signature changed. It is blank where nothing changed.

### 1.4 Two readings that differ from the design record

The port as written departs from `docs/19-geometry-and-text.md` in two places.
The ledger records the port as written and names the departure.

| Design record says | The port does | Rows |
|---|---|---|
| `docs/19:629-637` spells the five zero and identity constants `snake_case`, for example `affine_identity` | The port uses `camelCase`, so `affineIdentity`. Rule Z3 and `AGENTS.md:61` both require `camelCase`. | `Affine::IDENTITY`, `Rect::ZERO`, `Size::ZERO`, `Vec2::ZERO` |
| `docs/19:1285` says delete `Point::ORIGIN` (`geometry.rs:224`) | The port keeps one constant, `pointOrigin`, and gives it the value of both `ZERO` and `ORIGIN`. | `Point::ZERO`, `Point::ORIGIN` |

## 2. The five geometry modules

Upstream is `accesskit/src/geometry.rs`, one file. The port splits it into five
modules. Each table below covers one module and lists every `impl` block, every
associated constant, every method and every field.

### 2.1 `src/schema/geometry/affine.zig`

Upstream range `accesskit/src/geometry.rs:22-211`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `use core::{fmt, ops::{Add, AddAssign, Div, DivAssign, Mul, MulAssign, Neg, Sub, SubAssign}}` at `:12-15` | none | `deleted with reason` | Zig has no operator overloading, so there is no trait to import. Recorded at `docs/19-geometry-and-text.md:1213-1218`. |
| `#[derive(Clone, Copy, Debug, PartialEq)]` at `:18` | `Clone`, `Copy` and `PartialEq` are structural for a two-field value type | `merged` | A Zig value type is copyable and comparable without a derive. |
| `Debug` from the derive at `:18` | none | `deleted with reason` | The port declares no `format` for `Affine`. Nothing in the port renders an `Affine`, and `docs/19-geometry-and-text.md:1262` asks for one `format` per type. The module doc records no reason for this one. |
| `#[cfg_attr(feature = "schemars", …)]` at `:19-20` | none | `deleted with reason` | The port generates no schema. Recorded at `docs/30-port-design.md` section 2.2. |
| `#[repr(C)] pub struct Affine([f64; 6])` at `:21-22` | `pub const Affine = extern struct` at `src/schema/geometry/affine.zig:44` | `translated` | `#[repr(C)]` becomes `extern struct`. Recorded at `affine.zig:3-6`. |
| the tuple field `.0` at `:22` | `coeffs: [6]f64` at `affine.zig:46` | `added by the port` | A tuple struct field has no name in Zig, and `@offsetOf(Affine, "coeffs")` needs one. The name is also what the C header comment at `affine.zig:5-6` describes. |
| `impl Affine` at `:24-147` | the 13 items below, at file scope beside the struct | `merged` | Zig has no inherent impl blocks. The port puts an operation that takes no `self` at file scope under rule P1. |
| `Affine::IDENTITY` at `:26` | `affineIdentity` at `affine.zig:63` | `renamed by rule` | Rule Z3. The port uses `camelCase`, not the `affine_identity` of `docs/19:635`. |
| `Affine::FLIP_Y` at `:30` | `affineFlipY` at `affine.zig:67` | `renamed by rule` | Rule Z3. |
| `Affine::FLIP_X` at `:33` | `affineFlipX` at `affine.zig:70` | `renamed by rule` | Rule Z3. |
| `Affine::new` at `:53` | `affineNew` at `affine.zig:76` | `renamed by rule` | Rule P1. The name is `affineNew`, and `new` alone would collide in the flat re-export. |
| `Affine::scale` at `:59` | `affineScale` at `affine.zig:82` | `renamed by rule` | Rule P1. |
| `Affine::scale_non_uniform` at `:66` | `affineScaleNonUniform(axes: ScaleAxes)` at `affine.zig:100` | `renamed by rule` | Rule P1 for the name. Rule Z8 for the signature: upstream takes `s_x: f64, s_y: f64`, and two bare `f64` cannot say which axis is which. Recorded at `affine.zig:86-92`. |
| `Affine::translate<V: Into<Vec2>>` at `:72` | `affineTranslate(p: Vec2)` at `affine.zig:105` | `renamed by rule` | Rule P1 for the name. Rule Z8 for the signature: the generic parameter becomes the target type. |
| `Affine::map_unit_square` at `:81` | `affineMapUnitSquare` at `affine.zig:117` | `renamed by rule` | Rule P1. |
| `Affine::as_coeffs` at `:87` | `coeffs` at `affine.zig:130` | `renamed by rule` | Rule P1, and the name matches the field it returns. The module doc records no reason for the drop of the `affine` prefix. |
| `Affine::determinant` at `:92` | `determinant` at `affine.zig:139` | `translated` | At file scope under rule P1. Upstream uses `recip()` in `inverse`, and the port uses `1.0 / det` at `affine.zig:153`. |
| `Affine::inverse` at `:99` | `inverse` at `affine.zig:151` | `translated` | At file scope under rule P1. |
| `Affine::transform_rect_bbox` at `:118` | `transformRectBbox` at `affine.zig:171` | `renamed by rule` | Rule Z2. |
| `Affine::is_finite` at `:128` | `isFinite` at `affine.zig:181` | `renamed by rule` | Rule Z2. |
| `Affine::is_nan` at `:139` | `isNan` at `affine.zig:193` | `renamed by rule` | Rule Z2. |
| `impl Default for Affine` at `:149-154` | none | `deleted with reason` | `affineIdentity` is the named constant and the port has no `Default`. Recorded at `docs/19-geometry-and-text.md:1261`. |
| `impl Mul<Point> for Affine` at `:156-166` | `mulPoint` at `affine.zig:208` | `renamed by rule` | Rule Z2. The name carries `Point` because the two operands are different types. Recorded at `affine.zig:203-204`. |
| `impl Mul for Affine` at `:168-182` | `mul` at `affine.zig:221` | `translated` | |
| `impl MulAssign for Affine` at `:184-189` | none | `deleted with reason` | The caller assigns the result of `mul`. Recorded for the geometry modules at `docs/19-geometry-and-text.md:1224` and `src/schema/geometry/point.zig:32-34`. `affine.zig` does not restate it. |
| `impl Mul<Affine> for f64` at `:191-205` | `scale(scalar: f64, other: Affine)` at `affine.zig:240` | `renamed by rule` | Rule P1. The file-scope name `scale` is free because `affineScale` already took the upstream `scale` name. The scalar is the first parameter, matching upstream operand order. Recorded at `affine.zig:234-236`. |
| no upstream counterpart | `pub const ScaleAxes = extern struct { x: f64, y: f64 }` at `affine.zig:93` | `added by the port` | Two bare `f64` arguments to `affineScaleNonUniform` cannot say which axis is which, and a transposed pair still looks like a valid map. Recorded at `affine.zig:86-92`. |
| no upstream counterpart | the `comptime` layout block at `affine.zig:49-59` | `added by the port` | `AGENTS.md:56` requires a `comptime assert` for every declared layout. The numbers come from `accesskit-c/include/accesskit.h:934-936`. |

### 2.2 `src/schema/geometry/point.zig`

Upstream range `accesskit/src/geometry.rs:211-336`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Default, PartialEq)]` at `:208` | structural | `merged` | A two-field value type is copyable and comparable without a derive. |
| `Default` from the derive at `:208` | none | `deleted with reason` | `pointOrigin` is the constant, and the port has no `Default`. Recorded at `point.zig:98-101`. |
| `#[repr(C)] pub struct Point` at `:211-212` | `pub const Point = extern struct` at `src/schema/geometry/point.zig:51` | `translated` | Recorded at `point.zig:13-18`. |
| field `x` at `:214` | `x` at `point.zig:53` | `translated` | Rule Z4. |
| field `y` at `:216` | `y` at `point.zig:56` | `translated` | Rule Z4. |
| `impl Point` at `:219-237` | the four items below | `merged` | Rule P1. |
| `Point::ZERO` at `:221` | `pointOrigin` at `point.zig:102` | `merged` | Both constants hold `Point::new(0., 0.)`, so the port keeps one name. Recorded at `point.zig:30-31` and `:98-101`. |
| `Point::ORIGIN` at `:224` | `pointOrigin` at `point.zig:102` | `renamed by rule` | Rule Z3. `docs/19:1285` proposes deleting this one; the port keeps it under the shared name. |
| `Point::new` at `:228` | `pointInit` at `point.zig:107` | `renamed by rule` | Rule P1, and the geometry modules use the `Init` suffix for a constructor: `pointInit`, `rectInit`, `sizeInit`, `vec2Init`. |
| `Point::to_vec2` at `:234` | `pointToVec2` at `point.zig:116` | `renamed by rule` | Rule Z2. |
| `impl From<(f64, f64)> for Point` at `:239-244` | none | `deleted with reason` | Zig has a named-field struct literal, `.{ .x = x, .y = y }`. Recorded at `point.zig:38-40`. |
| `impl From<Point> for (f64, f64)` at `:246-251` | none | `deleted with reason` | The same literal reads the same in both directions. Recorded at `point.zig:38-40`. |
| `impl Add<Vec2> for Point` at `:253-260` | `Point.addVec2` at `point.zig:61` | `renamed by rule` | Rule Z2. It stays a member because it takes `self`. |
| `impl AddAssign<Vec2> for Point` at `:262-267` | none | `deleted with reason` | A Zig caller writes `p = p.addVec2(v)`. Recorded at `point.zig:32-34`. |
| `impl Sub<Vec2> for Point` at `:269-276` | `Point.subVec2` at `point.zig:68` | `renamed by rule` | Rule Z2. |
| `impl SubAssign<Vec2> for Point` at `:278-283` | none | `deleted with reason` | The caller assigns. Recorded at `point.zig:32-34`. |
| `impl Add<(f64, f64)> for Point` at `:285-292` | none | `merged` | `pointToVec2` reads a `Point` as that vector, so `addVec2` covers the case. Recorded at `point.zig:35-37`. |
| `impl AddAssign<(f64, f64)> for Point` at `:294-299` | none | `deleted with reason` | Listed with the other assign impls at `point.zig:32-34`. |
| `impl Sub<(f64, f64)> for Point` at `:301-308` | none | `merged` | `subVec2` covers it. Recorded at `point.zig:35-37`. |
| `impl SubAssign<(f64, f64)> for Point` at `:310-315` | none | `deleted with reason` | Listed with the other assign impls at `point.zig:32-34`. |
| `impl Sub<Point> for Point` at `:317-324` | `Point.subPoint` at `point.zig:76` | `renamed by rule` | Rule Z2. This is the one subtraction that yields a vector. |
| `impl fmt::Debug for Point` at `:326-330` | `Point.format` at `point.zig:91` | `renamed by rule` | Rule Z2. It is a member because `{f}` reaches a value as `value.format(writer)`. Recorded at `point.zig:10-11` and `:82-87`. The bytes differ from upstream, because Rust `{:?}` prints `1.0` and `{d}` prints `1`. |
| no upstream counterpart | the `comptime` layout block at `point.zig:120-133` | `added by the port` | `AGENTS.md:56`. The numbers are measured in `docs/19-geometry-and-text.md` section 3.3. |

### 2.3 `src/schema/geometry/rect.zig`

Upstream range `accesskit/src/geometry.rs:337-570`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Default, PartialEq)]` at `:333` | structural | `merged` | A four-field value type needs no derive. |
| `Default` from the derive at `:333` | none | `deleted with reason` | `rectZero` is the constant. The rule is recorded for `Point` at `point.zig:98-101`; `rect.zig` does not restate it. |
| `#[repr(C)] pub struct Rect` at `:336-337` | `pub const Rect = extern struct` at `src/schema/geometry/rect.zig:58` | `translated` | Recorded at `rect.zig:18-24`. |
| field `x0` at `:339` | `x0` at `rect.zig:61` | `translated` | Rule Z4. |
| field `y0` at `:341` | `y0` at `rect.zig:63` | `translated` | Rule Z4. |
| field `x1` at `:343` | `x1` at `rect.zig:66` | `translated` | Rule Z4. |
| field `y1` at `:345` | `y1` at `rect.zig:68` | `translated` | Rule Z4. |
| `impl From<(Point, Point)> for Rect` at `:348-352` | `rectFromPoints` at `rect.zig:252` | `renamed by rule` | Rule P1. |
| `impl From<(Point, Size)> for Rect` at `:354-358` | `rectFromOriginSize` at `rect.zig:260` | `renamed by rule` | Rule P1. |
| `impl Add<Vec2> for Rect` at `:360-367` | `Rect.addVec2` at `rect.zig:200` | `renamed by rule` | Rule Z2. `docs/19:1238` proposes `translate`; the port names the operation for the operand type instead, beside `Point.addVec2` at `point.zig:61`. |
| `impl Sub<Vec2> for Rect` at `:369-376` | `Rect.subVec2` at `rect.zig:205` | `renamed by rule` | Rule Z2. `docs/19:1239` proposes `translateBy`; the port keeps the `Vec2` operand in the name. |
| `impl fmt::Debug for Rect` at `:378-395`, the non-alternate arm at `:388-392` | `Rect.format` at `rect.zig:212` | `renamed by rule` | Rule Z2. A member, because `{f}` reaches it as `value.format(writer)`. |
| `impl fmt::Debug for Rect` at `:378-395`, the alternate arm at `:380-386` | `Rect.formatOriginSize` at `rect.zig:227` | `added by the port` | Rust reaches the alternate arm through `f.alternate()`. Zig has no such flag, so the port exposes a second named member and reaches it with `std.fmt.alt`. Recorded at `rect.zig:221-223`. |
| `impl Rect` at `:397-564` | the 20 items below | `merged` | The constructors go to file scope under rule P1, the operations stay members. |
| `Rect::ZERO` at `:399` | `rectZero` at `rect.zig:239` | `renamed by rule` | Rule Z3. The port uses `camelCase`, not the `rect_zero` of `docs/19:629`. |
| `Rect::new` at `:403` | `rectInit` at `rect.zig:244` | `renamed by rule` | Rule P1 and the geometry `Init` suffix. |
| `Rect::from_points` at `:411` | `rectFromPoints` at `rect.zig:252` | `renamed by rule` | Rule P1. |
| `Rect::from_origin_size` at `:421` | `rectFromOriginSize` at `rect.zig:260` | `renamed by rule` | Rule P1. |
| `Rect::with_origin` at `:428` | `Rect.withOrigin` at `rect.zig:136` | `renamed by rule` | Rule Z2. |
| `Rect::with_size` at `:434` | `Rect.withSize` at `rect.zig:144` | `renamed by rule` | Rule Z2. |
| `Rect::width` at `:442` | `Rect.width` at `rect.zig:101` | `translated` | |
| `Rect::height` at `:450` | `Rect.height` at `rect.zig:106` | `translated` | |
| `Rect::min_x` at `:456` | `Rect.minX` at `rect.zig:81` | `renamed by rule` | Rule Z2. |
| `Rect::max_x` at `:462` | `Rect.maxX` at `rect.zig:86` | `renamed by rule` | Rule Z2. |
| `Rect::min_y` at `:468` | `Rect.minY` at `rect.zig:91` | `renamed by rule` | Rule Z2. |
| `Rect::max_y` at `:474` | `Rect.maxY` at `rect.zig:96` | `renamed by rule` | Rule Z2. |
| `Rect::origin` at `:483` | `Rect.topLeft` at `rect.zig:76` | `renamed by rule` | Not rule Z2. `origin` hid the difference from `minX` on an inverted box, so the port names the stored corner. Required by `docs/19:1285` and recorded at `rect.zig:70-75`. |
| `Rect::size` at `:489` | `rectSize` at `rect.zig:270` | `renamed by rule` | Rule P1, because `Node` already owns the name `size`. It is a conversion rather than an operation on the value. Recorded at `rect.zig:264-269`. |
| `Rect::abs` at `:498` | `Rect.abs` at `rect.zig:124` | `translated` | |
| `Rect::area` at `:505` | `Rect.area` at `rect.zig:112` | `translated` | |
| `Rect::is_empty` at `:513` | `Rect.isEmpty` at `rect.zig:118` | `renamed by rule` | Rule Z2. |
| `Rect::contains` at `:519` | `Rect.contains` at `rect.zig:152` | `translated` | |
| `Rect::union` at `:527` | `Rect.unionRect` at `rect.zig:162` | `renamed by rule` | Not rule Z2. The port names the operand type because `unionPoint` sits beside it, so a caller reading `union` cannot tell which one it holds. The module doc records no reason for the drop of the bare `union`. |
| `Rect::union_pt` at `:543` | `Rect.unionPoint` at `rect.zig:176` | `renamed by rule` | Rule Z2, and the same naming pair as `unionRect`. |
| `Rect::intersect` at `:557` | `Rect.intersect` at `rect.zig:191` | `translated` | |
| no upstream counterpart | `pub const NarrowError = error{ OutOfRange }` at `rect.zig:276` and `pub fn toI32Checked(value: f64) NarrowError!i32` at `rect.zig:288` | `added by the port` | Upstream narrows an `f64` to `i32` with `as` at `adapters/atspi-common/src/rect.rs:31` and `adapters/android/src/node.rs:247`, and `as` saturates. The port requires one named checked conversion with an explicit error. Recorded at `rect.zig:281-287` and required by `docs/19:1293-1297`. |
| no upstream counterpart | the `comptime` layout block at `rect.zig:34-44` | `added by the port` | `AGENTS.md:56`. The offsets are the `accesskit_rect` layout at `accesskit-c/include/accesskit.h`. |

### 2.4 `src/schema/geometry/size.zig`

Upstream range `accesskit/src/geometry.rs:571-716`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Default, PartialEq)]` at `:567` | structural | `merged` | A two-field value type needs no derive. |
| `Default` from the derive at `:567` | none | `deleted with reason` | `sizeZero` is the constant. The same decision is recorded for `Vec2` at `vec2.zig:79-82`; `size.zig` does not restate it. |
| `#[repr(C)] pub struct Size` at `:570-571` | `pub const Size = extern struct` at `src/schema/geometry/size.zig:27` | `translated` | Recorded at `size.zig:12-15`. |
| field `width` at `:573` | `width` at `size.zig:29` | `translated` | Rule Z4. |
| field `height` at `:575` | `height` at `size.zig:31` | `translated` | Rule Z4. |
| `impl Size` at `:578-594` | the three items below | `merged` | Rule P1. |
| `Size::ZERO` at `:580` | `sizeZero` at `size.zig:72` | `renamed by rule` | Rule Z3. The port uses `camelCase`, not the `size_zero` of `docs/19:631`. |
| `Size::new` at `:584` | `sizeInit` at `size.zig:79` | `renamed by rule` | Rule P1 and the geometry `Init` suffix. |
| `Size::to_vec2` at `:591` | `sizeToVec2` at `size.zig:86` | `renamed by rule` | Rule Z2. |
| `impl fmt::Debug for Size` at `:596-600` | `Size.format` at `size.zig:65` | `renamed by rule` | Rule Z2. A member, because `{f}` reaches it as `value.format(writer)`. |
| `impl MulAssign<f64> for Size` at `:602-610` | none | `deleted with reason` | The caller assigns the result of `scale`. Recorded at `docs/19:1241`. `size.zig` does not restate it. |
| `impl Mul<Size> for f64` at `:612-619` | none | `merged` | Upstream defines it as `other * self`, which is what `Size.scale` computes. Required by `docs/19:1242`. |
| `impl Mul<f64> for Size` at `:621-631` | `Size.scale` at `size.zig:45` | `renamed by rule` | Rule Z2, from `mul`. |
| `impl DivAssign<f64> for Size` at `:633-641` | none | `deleted with reason` | The caller assigns the result of `divide`. Recorded at `docs/19:1244`. |
| `impl Div<f64> for Size` at `:643-653` | `Size.divide` at `size.zig:54` | `renamed by rule` | Rule Z2. This is a true divide, and it must stay different from `Vec2.divide`, which multiplies by the reciprocal. Recorded at `size.zig:49-56` and `docs/19:1270-1272`. |
| `impl Add<Size> for Size` at `:655-664` | `Size.add` at `size.zig:35` | `renamed by rule` | Rule Z2. |
| `impl AddAssign<Size> for Size` at `:666-671` | none | `deleted with reason` | The caller assigns. Recorded at `docs/19:1246`. |
| `impl Sub<Size> for Size` at `:673-682` | `Size.sub` at `size.zig:40` | `renamed by rule` | Rule Z2. |
| `impl SubAssign<Size> for Size` at `:684-689` | none | `deleted with reason` | The caller assigns. Recorded at `docs/19:1248`. |
| `impl From<(f64, f64)> for Size` at `:691-699` | none | `deleted with reason` | Zig has a named-field struct literal. Required by `docs/19:1249`. |
| `impl From<Size> for (f64, f64)` at `:701-706` | none | `deleted with reason` | The same literal reads the same in both directions. Required by `docs/19:1249`. |
| no upstream counterpart | the layout tests at `size.zig:90-98` | `added by the port` | `AGENTS.md:56`. |

### 2.5 `src/schema/geometry/vec2.zig`

Upstream range `accesskit/src/geometry.rs:717-866`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Default, Debug, PartialEq)]` at `:713` | `Clone`, `Copy` and `PartialEq` are structural | `merged` | A two-field value type needs no derive. |
| `Default` from the derive at `:713` | none | `deleted with reason` | `vec2Zero` is the constant. Recorded at `vec2.zig:79-82`. |
| `Debug` from the derive at `:713` | none | `deleted with reason` | The port declares no `format` for `Vec2`, so nothing in the port renders one. `docs/19:1262` asks for one `format` per type. `vec2.zig` records no reason. |
| `#[repr(C)] pub struct Vec2` at `:716-717` | `pub const Vec2 = extern struct` at `src/schema/geometry/vec2.zig:37` | `translated` | |
| field `x` at `:719` | `x` at `vec2.zig:39` | `translated` | Rule Z4. |
| field `y` at `:721` | `y` at `vec2.zig:43` | `translated` | Rule Z4. |
| `impl Vec2` at `:724-745` | the four items below | `merged` | Rule P1. |
| `Vec2::ZERO` at `:726` | `vec2Zero` at `vec2.zig:82` | `renamed by rule` | Rule Z3. The port uses `camelCase`, not the `vec2_zero` of `docs/19:633`. |
| `Vec2::new` at `:730` | `vec2Init` at `vec2.zig:88` | `renamed by rule` | Rule P1 and the geometry `Init` suffix. |
| `Vec2::to_point` at `:736` | `vec2ToPoint` at `vec2.zig:94` | `renamed by rule` | Rule Z2. |
| `Vec2::to_size` at `:742` | `vec2ToSize` at `vec2.zig:100` | `renamed by rule` | Rule Z2. |
| `impl From<(f64, f64)> for Vec2` at `:747-752` | none | `deleted with reason` | Zig has a named-field struct literal. Recorded at `vec2.zig:22-24`. |
| `impl From<Vec2> for (f64, f64)` at `:754-759` | none | `deleted with reason` | The same literal reads the same in both directions. Recorded at `vec2.zig:22-24`. |
| `impl Add for Vec2` at `:761-771` | `Vec2.add` at `vec2.zig:46` | `renamed by rule` | Rule Z2. |
| `impl AddAssign for Vec2` at `:773-781` | none | `deleted with reason` | The caller assigns the result of `add`. Recorded at `vec2.zig:17-19`. |
| `impl Sub for Vec2` at `:783-793` | `Vec2.sub` at `vec2.zig:51` | `renamed by rule` | Rule Z2. |
| `impl SubAssign for Vec2` at `:795-803` | none | `deleted with reason` | The caller assigns the result of `sub`. Recorded at `vec2.zig:17-19`. |
| `impl Mul<f64> for Vec2` at `:805-815` | `Vec2.scale` at `vec2.zig:56` | `renamed by rule` | Rule Z2. |
| `impl MulAssign<f64> for Vec2` at `:817-825` | none | `deleted with reason` | The caller assigns the result of `scale`. Recorded at `vec2.zig:20-21`. |
| `impl Mul<Vec2> for f64` at `:827-834` | none | `merged` | Upstream defines it as `other * self`, which is what `Vec2.scale` computes. Recorded at `vec2.zig:22-24`. |
| `impl Div<f64> for Vec2` at `:836-847` | `Vec2.divide` at `vec2.zig:67` | `renamed by rule` | Rule Z2. The reciprocal multiply is kept, and the roundoff note is kept. Recorded at `vec2.zig:60-70` and `docs/19:1257`. |
| `impl DivAssign<f64> for Vec2` at `:849-854` | none | `deleted with reason` | The caller assigns the result of `divide`. Recorded at `vec2.zig:20-21`. |
| `impl Neg for Vec2` at `:856-866` | `Vec2.negate` at `vec2.zig:74` | `renamed by rule` | Rule Z2. |
| no upstream counterpart | the `comptime` layout block at `vec2.zig:104-111` | `added by the port` | `AGENTS.md:56`. The numbers are the `accesskit_vec2` layout. |

## 3. `Role` and `Action`

### 3.1 The two tables

`Role` carries 182 variants and `Action` carries 22. One row per variant would
run to 204 rows and would hide the rule that matters. Each table gives one row
for the type and one row per variant family.

#### `src/schema/role.zig`, upstream `accesskit/src/lib.rs:62-271`

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]` at `:47` and `#[repr(u8)]` at `:61` | `pub const Role = enum(u8)` at `src/schema/role.zig:35` | `translated` | `#[repr(u8)]` becomes `enum(u8)`, and the value type is copyable and comparable without a derive. |
| `Debug`, `Default`, `PartialOrd`, `Ord` and `Hash` from the derive at `:47`, and the `#[default]` attribute at `:63` | none | `deleted with reason` | The port declares no `format` for `Role`, no `Default` and no ordering. `Role` is an enumerable domain that `schema/props/table.zig` sweeps at compile time instead. `role.zig` records no reason for any of the five. |
| `#[cfg_attr(feature = "enumn", …)]`, `serde`, `schemars` and `pyo3` at `:48-60` | none | `deleted with reason` | The port generates no code for another language and does not carry a serializer. Recorded at `docs/30-port-design.md` section 2.2. |
| `pub enum Role` at `:62` | `pub const Role` at `role.zig:35` | `translated` | Rule Z1. |
| the ordering rule at `:42-46` | the doc comment at `role.zig:21-34` and the `comptime` sweep at `role.zig:329-347` | `merged` | Upstream states the rule in prose. The port states it and pins it: every discriminant is its declaration index. |
| variants `Unknown` to `Menu` at `:64-102`, the 31 tags of expected usage frequency | `Role.unknown` to `Role.menu` at `role.zig:38-97` | `renamed by rule` | Rule Z5, discriminants 0 to 30 unchanged. |
| variants `MultilineTextInput` to `UrlInput` at `:104-115`, the 12 text-entry roles | `Role.multiline_text_input` to `Role.url_input` at `role.zig:102-113` | `renamed by rule` | Rule Z5, discriminants 31 to 42 unchanged. |
| variant `Switch` at `:101` | `Role.switch_` at `role.zig:96` | `renamed by rule` | Rule Z5, plus a trailing underscore because `switch` is a Zig keyword. Recorded at `role.zig:92-95`. |
| variants `Abbr` to `Window` at `:117-207`, the 91 ARIA and web roles | `Role.abbr` to `Role.window` at `role.zig:116-251` | `renamed by rule` | Rule Z5, discriminants 43 to 133 unchanged. |
| variants `PdfActionableHighlight` and `PdfRoot` at `:209-210` | `Role.pdf_actionable_highlight` and `Role.pdf_root` at `role.zig:255-256` | `renamed by rule` | Rule Z5, discriminants 134 and 135. |
| variants `GraphicsDocument`, `GraphicsObject` and `GraphicsSymbol` at `:214-216` | `Role.graphics_document` to `Role.graphics_symbol` at `role.zig:261-263` | `renamed by rule` | Rule Z5, discriminants 136 to 138. |
| variants `DocAbstract` to `DocToc` at `:220-260`, the 41 `doc_*` tags | `Role.doc_abstract` to `Role.doc_toc` at `role.zig:266-318` | `renamed by rule` | Rule Z5, discriminants 139 to 179. Thirty-nine of the 41 are DPUB-ARIA roles. The other two, `DocPageFooter` and `DocPageHeader`, are Chromium PDF running roles that the DPUB-AAM role mapping does not define. Recorded at `role.zig:297-308`. |
| variant `ListGrid` at `:265` | `Role.list_grid` at `role.zig:322` | `renamed by rule` | Rule Z5, discriminant 180. |
| variant `Terminal` at `:270` | `Role.terminal` at `role.zig:326` | `renamed by rule` | Rule Z5, discriminant 181. |
| no upstream counterpart | the `comptime` block at `role.zig:329-347` | `added by the port` | `AGENTS.md:106-109` asks for a comptime sweep over every enumerable domain. The block asserts the tag count, exhaustiveness, both end tags and every discriminant against its declaration index. |

#### `src/schema/action.zig`, upstream `accesskit/src/lib.rs:289-400`

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]` at `:274` and `#[repr(u8)]` at `:288` | `pub const Action = enum(u8)` at `src/schema/action.zig:23` | `translated` | |
| `Debug`, `PartialOrd`, `Ord` and `Hash` from the derive at `:274` | none | `deleted with reason` | The port declares no `format` and no ordering for `Action`. A `u32` mask carries order, and `actionSetMembers` gives the members in declaration order. `action.zig` records no reason for any of the four. |
| `#[cfg_attr(feature = "enumn", …)]`, `serde`, `schemars` and `pyo3` at `:275-287` | none | `deleted with reason` | The port generates no code for another language. Recorded at `docs/30-port-design.md` section 2.2. |
| `pub enum Action` at `:289` | `pub const Action` at `action.zig:23` | `translated` | Rule Z1. |
| variants `Click` to `Increment` at `:291-305`, the 8 non-scroll actions | `Action.click` to `Action.increment` at `action.zig:26-40` | `renamed by rule` | Rule Z5, discriminants 0 to 7 unchanged. |
| variants `HideTooltip`, `ShowTooltip` and `ReplaceSelectedText` at `:307-313` | `Action.hide_tooltip` to `Action.replace_selected_text` at `action.zig:42-48` | `renamed by rule` | Rule Z5, discriminants 8 to 10. |
| variants `ScrollDown` to `ScrollUp` at `:316-322` | `Action.scroll_down` to `Action.scroll_up` at `action.zig:51-57` | `renamed by rule` | Rule Z5, discriminants 11 to 14. |
| variants `ScrollIntoView`, `ScrollToPoint`, `SetScrollOffset` and `SetTextSelection` at `:326-337` | `Action.scroll_into_view` to `Action.set_text_selection` at `action.zig:61-74` | `renamed by rule` | Rule Z5, discriminants 15 to 18. |
| variant `SetSequentialFocusNavigationStartingPoint` at `:342` | `Action.set_sequential_focus_navigation_starting_point` at `action.zig:79` | `renamed by rule` | Rule Z5, discriminant 19 unchanged. The name is the whole upstream name in `snake_case`. |
| variants `SetValue` and `ShowContextMenu` at `:347-349` | `Action.set_value` and `Action.show_context_menu` at `action.zig:84-86` | `renamed by rule` | Rule Z5, discriminants 20 and 21. |
| `impl Action { fn mask }` at `:352-355` | `pub fn actionMask(value: Action) u32` at `action.zig:123` | `renamed by rule` | Rule P1, because the operation takes no `self`. |
| `impl Action { fn n }` at `:357-387` | `pub fn actionFromInt(value: u8) ?Action` at `action.zig:118` | `renamed by rule` | Rule P1. The name says what the function does; `n` says nothing. |
| `fn action_mask_to_action_vec(mask: u32) -> Vec<Action>` at `:390-400` | `pub fn actionSetMembers(action_set: u32, out: *[actionCount]Action) []const Action` at `action.zig:152` | `renamed by rule` | Rule P1. It fills a caller buffer and returns the filled prefix, so the port never allocates. The upper bound is `actionCount` and the doc names it at `action.zig:146-151`. |
| no upstream counterpart | `pub const actionCount` at `action.zig:91` | `added by the port` | The bit count of a full mask and the bound on every walk over the domain. Recorded at `action.zig:89-90`. |
| no upstream counterpart | `pub fn actionSetContains(action_set: u32, action: Action) bool` at `action.zig:128` | `added by the port` | `action_mask_to_action_vec` inlines the test. The port needs the test on its own, because the mask arrives over the C ABI as a bare `uint32_t`. |
| no upstream counterpart | `pub fn actionSetUnion(left: u32, right: u32) u32` at `action.zig:134` | `added by the port` | Upstream has no set union over masks. The port publishes the mask as an operation a consumer performs, because the mask is the C ABI type. |
| no upstream counterpart | `pub fn actionSetDifference(left: u32, right: u32) u32` at `action.zig:140` | `added by the port` | The same reason as `actionSetUnion`. |
| no upstream counterpart | the `comptime` block at `action.zig:93-114` | `added by the port` | It pins the 22 variants, one bit per variant, and that the bits are dense. |

### 3.2 The order of the variants

| Type | Count | First variant | Last variant | The rule that pins the order |
|---|---:|---|---|---|
| `Role` | 182 | `Unknown` at `accesskit/src/lib.rs:64`, `Role.unknown` at `role.zig:38`, discriminant 0 | `Terminal` at `lib.rs:270`, `Role.terminal` at `role.zig:326`, discriminant 181 | Upstream orders by expected usage frequency, `Unknown` excepted, because a variable-length integer encoding spends fewer bytes on the roles that occur often. `lib.rs:42-46` states it. Rule Z5 copies each discriminant, and `role.zig:344-346` asserts that every discriminant equals its declaration index. |
| `Action` | 22 | `Click` at `lib.rs:291`, `Action.click` at `action.zig:26`, discriminant 0 | `ShowContextMenu` at `lib.rs:349`, `Action.show_context_menu` at `action.zig:86`, discriminant 21 | The discriminant is the bit position in the mask and the number the C header and the JSON name are built from. Upstream's own test at `lib.rs:3508` fixes the count. `action.zig:113` asserts that the union of all 22 masks is `(1 << 22) - 1`, so the bits are dense and a gap is a compile error. |

### 3.3 How to verify the order of one variant

A reader checks one variant without reading 182 lines.

```sh
grep -n '^    text_run = ' src/schema/role.zig
grep -n '^    TextRun,' /tmp/scratch/accesskit/accesskit/src/lib.rs
```

The second block builds a scratch mirror. It is superseded and a reader should
run `zig build test` instead. It is kept here because this section explains why
the mirror existed, and the explanation is the reason the recipe does not.

```sh
S=/tmp/scratch/ledger-check
rm -rf "$S" && mkdir -p "$S"
cp -r src "$S"/
cp    build.zig build.zig.zon "$S"/
cat > "$S"/root.zig <<'EOF'
const std = @import("std");
pub const target = @import("schema/role.zig");

test {
    std.testing.refAllDecls(target);
}
EOF
cd "$S" && zig test root.zig
```

The first two commands give the Zig line and the upstream line. The count of
preceding variant declarations is the same number in both files, because rule
Z5 copies each discriminant rather than renumbering the tags.

The mirror was needed when this ledger was written and is not needed now. The
sentence read: "The mirror exists because `zig build test` roots at
`src/root.zig`, and that root re-exports only the version constants today. A
green `zig build test` compiles none of `src/schema/`." Both halves are false. A
count over the tree on 2026-10-05 gives the correction: `src/root.zig` declares
three namespaces beside the two version constants, `schema` at
`src/root.zig:36`, `consumer` at `:49` and `capi` at `:57`, and all 24 modules
under `src/schema/` sit in the import graph from that root. A green
`zig build test` compiles all 24 of them. Run `zig build test` instead.

Copy `build.zig` as well as `build.zig.zon` if you keep the mirror, because the
`zig` on this host is an anyzig shim that refuses to start without a `build.zig`
to read `.minimum_zig_version` from.

`refAllDecls` forces analysis. A root that only holds a `pub const` import
compiles the import and stops, and the run prints `All 0 tests passed`. Read
the count. `role.zig` declares two tests, and a run that reports fewer has not
analysed the file. `zig test` on the file directly works too, because
`role.zig` imports nothing.

The `comptime` block at `role.zig:344-346` asserts every discriminant against
its index, so the run re-checks the whole domain and not one tag. For
`Action`, the same route works with `action.zig:175-177`, which sweeps the 22
members, and `action.zig` declares seven tests.

`src/schema/values.zig` needs the mirror. Its siblings `ids.zig` and
`node_enums.zig` sit one level above it, so a single-file root reports
`import of file outside module path`. That is a property of the tool and not a
defect in the file.

## 4. The thirteen small enums, the scroll enums, the ids and the values

### 4.1 `src/schema/node_enums.zig`

Upstream range `accesskit/src/lib.rs:417-700`. Thirteen types, one per stored
node property.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| the 13 derive and `repr(u8)` attribute sets at `:402-693` | the 13 `enum(u8)` declarations | `translated` | `#[repr(u8)]` becomes `enum(u8)`. |
| `Debug`, `PartialOrd`, `Ord` and `Hash` on all 13 | none | `deleted with reason` | The port declares no `format` and no ordering for any of the thirteen. A byte is rendered at the codec boundary and ordered by its discriminant. `node_enums.zig:12-13` records the decision to hold no tag-to-name conversion, and records no reason for the other three. |
| `serde`, `schemars` and `pyo3` attributes on all 13 | none | `deleted with reason` | The port generates no code for another language. `docs/30-port-design.md` section 2.2. |
| `pub enum Orientation` at `:417` | `Orientation` at `src/schema/node_enums.zig:21` | `translated` | Rule Z1. 2 variants, `Horizontal` at `:419` first and `Vertical` at `:421` last, discriminants 0 and 1. |
| `pub enum TextDirection` at `:439` | `TextDirection` at `node_enums.zig:32` | `translated` | Rule Z1. 4 variants, `LeftToRight` at `:440` first and `BottomToTop` at `:443` last, discriminants 0 to 3. |
| `pub enum Invalid` at `:465` | `Invalid` at `node_enums.zig:48` | `translated` | Rule Z1. 3 variants, `True` at `:466` first and `Spelling` at `:468` last, discriminants 0 to 2. `Invalid::True` becomes `Invalid.true_`, because `true` is a Zig keyword. Recorded at `node_enums.zig:49-50` and required by `docs/10-accesskit-core.md:840`. |
| `pub enum Toggled` at `:486` | `Toggled` at `node_enums.zig:63` | `translated` | Rule Z1. 3 variants, `False` at `:487` first and `Mixed` at `:489` last, discriminants 0 to 2. Both `False` and `True` take a trailing underscore. Recorded at `node_enums.zig:64-67`. |
| `impl From<bool> for Toggled` at `:492-500` | `pub fn toggledFromBool(value: bool) Toggled` at `node_enums.zig:194` | `renamed by rule` | Rule P1, because the operation takes no `self`. The port keeps the mapping and does not claim `mixed`, because no `bool` reaches it. Recorded at `node_enums.zig:192-193`. |
| `pub enum SortDirection` at `:517` | `SortDirection` at `node_enums.zig:77` | `translated` | Rule Z1. 3 variants, `Ascending` at `:518` first and `Other` at `:520` last, discriminants 0 to 2. |
| `pub enum AriaCurrent` at `:538` | `AriaCurrent` at `node_enums.zig:89` | `translated` | Rule Z1. 7 variants, `False` at `:539` first and `Time` at `:545` last, discriminants 0 to 6. |
| `pub enum AutoComplete` at `:563` | `AutoComplete` at `node_enums.zig:107` | `translated` | Rule Z1. 3 variants, `Inline` at `:564` first and `Both` at `:566` last, discriminants 0 to 2. `Inline` becomes `inline_`, because `inline` is a Zig keyword. Recorded at `node_enums.zig:108-109`. |
| `pub enum Live` at `:584` | `Live` at `node_enums.zig:121` | `translated` | Rule Z1. 3 variants, `Off` at `:585` first and `Assertive` at `:587` last, discriminants 0 to 2. |
| `pub enum HasPopup` at `:605` | `HasPopup` at `node_enums.zig:133` | `translated` | Rule Z1. 5 variants, `Menu` at `:606` first and `Dialog` at `:610` last, discriminants 0 to 4. |
| `pub enum ListStyle` at `:628` | `ListStyle` at `node_enums.zig:146` | `translated` | Rule Z1. 6 variants, `Circle` at `:629` first and `Other` at `:635` last, discriminants 0 to 5. |
| `pub enum TextAlign` at `:653` | `TextAlign` at `node_enums.zig:160` | `translated` | Rule Z1. 4 variants, `Left` at `:654` first and `Justify` at `:657` last, discriminants 0 to 3. |
| `pub enum VerticalOffset` at `:675` | `VerticalOffset` at `node_enums.zig:171` | `translated` | Rule Z1. 2 variants, `Subscript` at `:676` first and `Superscript` at `:677` last, discriminants 0 and 1. |
| `pub enum TextDecorationStyle` at `:695` | `TextDecorationStyle` at `node_enums.zig:181` | `translated` | Rule Z1. 5 variants, `Solid` at `:696` first and `Wavy` at `:700` last, discriminants 0 to 4. |
| no upstream counterpart | 13 `pub const count: usize` at `node_enums.zig:28`, `:39`, `:55`, `:71`, `:83`, `:101`, `:115`, `:127`, `:141`, `:156`, `:167`, `:176`, `:189` | `added by the port` | The tag count, so a reader does not count. Each names the upstream range it was read from. |
| no upstream counterpart | 13 `<type>FromInt(value: u8) ?<type>` at `node_enums.zig:205`, `:215`, `:227`, `:238`, `:249`, `:260`, `:275`, `:286`, `:297`, `:310`, `:324`, `:336`, `:346` | `added by the port` | The C seam and the D-Bus codec each receive one of these bytes and neither may trust it. `std.meta.intToEnum` does not check in `ReleaseFast`. Recorded at `node_enums.zig:198-201`. |
| no upstream counterpart | `const VariantCount` at `node_enums.zig:359`, `const variant_counts` at `:369`, the `comptime` sweep at `:385-415`, `fn expectTotalGate` at `:420` and its `comptime` calls at `:437-451` | `added by the port` | `AGENTS.md:106-109`. The table names each type, so a compile error names the enum that moved. |

### 4.2 `src/schema/scroll_enums.zig`

Upstream range `accesskit/src/lib.rs:3271-3298`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[repr(u8)] pub enum ScrollUnit` at `:3270-3271` | `pub const ScrollUnit = enum(u8)` at `src/schema/scroll_enums.zig:13` | `translated` | Rule Z1. 2 variants, `Item` at `:3275` first and `Page` at `:3277` last, discriminants 0 and 1. |
| `#[repr(u8)] pub enum ScrollHint` at `:3290-3291` | `pub const ScrollHint = enum(u8)` at `scroll_enums.zig:26` | `translated` | Rule Z1. 6 variants, `TopLeft` at `:3292` first and `RightEdge` at `:3297` last, discriminants 0 to 5. |
| the derive sets at `:3260-3290` | structural | `merged` | The value type is copyable and comparable without a derive. |
| no upstream counterpart | `pub fn scrollUnitToStaticStr(value: ScrollUnit) []const u8` at `scroll_enums.zig:47` | `added by the port` | The tag spelling is the wire name, and `docs/10-accesskit-core.md:837` records it. The result points into the binary image and is never released. Recorded at `scroll_enums.zig:42-46`. |
| no upstream counterpart | `pub fn scrollUnitFromInt(value: u8) ?ScrollUnit` at `scroll_enums.zig:59` | `added by the port` | The check lives here, so a byte that declares no tag is rejected instead of becoming a value the renderer cannot name. Recorded at `scroll_enums.zig:54-58`. |
| no upstream counterpart | `pub fn scrollHintToStaticStr(value: ScrollHint) []const u8` at `scroll_enums.zig:72` | `added by the port` | As `scrollUnitToStaticStr`, with the spellings at `docs/10-accesskit-core.md:838`. Recorded at `scroll_enums.zig:67-71`. |
| no upstream counterpart | `pub fn scrollHintFromInt(value: u8) ?ScrollHint` at `scroll_enums.zig:88` | `added by the port` | As `scrollUnitFromInt`. Recorded at `scroll_enums.zig:83-87`. |
| no upstream counterpart | the `comptime` block at `scroll_enums.zig:100-120` | `added by the port` | It pins every discriminant, both counts and the one-byte layout. The C header fixes the six `ScrollHint` constants at `accesskit-c/include/accesskit.h:497` in the same order. Recorded at `scroll_enums.zig:100-105`. |

### 4.3 `src/schema/ids.zig`

Upstream range `accesskit/src/lib.rs:703-750`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `pub type NodeIdContent = u64` at `:703` | `pub const NodeIdContent = u64` at `src/schema/ids.zig:31` | `translated` | An alias stays an alias, so it carries no methods. Recorded at `ids.zig:27-30`. |
| `pub struct NodeId(pub NodeIdContent)` at `:715` | `pub const NodeId = extern struct` at `ids.zig:41` | `translated` | `#[repr(transparent)]` becomes a one-field `extern struct`, and the C header declares `NodeId` as a bare `uint64_t`. |
| the public tuple field `.0` at `:715` | `value: NodeIdContent` at `ids.zig:42` | `added by the port` | A tuple struct field has no name in Zig, and `@offsetOf(NodeId, "value")` needs one. Recorded by the layout block at `ids.zig:132-139`. |
| `impl From<NodeIdContent> for NodeId` at `:717-722` | `pub fn nodeIdFromContent(content: NodeIdContent) NodeId` at `ids.zig:69` | `renamed by rule` | Rule P1. |
| `impl From<NodeId> for NodeIdContent` at `:724-729` | `pub fn nodeIdToContent(value: NodeId) NodeIdContent` at `ids.zig:75` | `renamed by rule` | Rule P1. |
| `impl fmt::Debug for NodeId` at `:731-735` | `pub fn nodeIdFormat(value: NodeId, w: *std.Io.Writer) std.Io.Writer.Error!void` at `ids.zig:84` | `renamed by rule` | Rule Z2. It is a file-scope function, not a member, so a `NodeId` does not reach `{f}` directly. Recorded at `ids.zig:9-11`. |
| the `PartialEq`, `Eq`, `PartialOrd` and `Ord` derives at `:711` | `pub fn eql` at `ids.zig:45` and `pub fn lessThan` at `ids.zig:51` | `renamed by rule` | Zig rejects `==` for a struct, so each comparison is an explicit method. Rule P1 does not apply, because each takes `self`. |
| the `Hash` derive at `:711` | `pub fn hash(self: NodeId, hasher: *std.hash.Wyhash)` at `ids.zig:62` | `renamed by rule` | Zig has no `Hash` derive. The order a consumer walks the nodes in is a property of the container, not of the key, and the doc records that at `ids.zig:56-61`. |
| `#[repr(transparent)] pub struct TreeId(pub Uuid)` at `:745` | `pub const TreeId = extern struct` at `ids.zig:93` | `translated` | |
| the public tuple field `.0` at `:745` | `bytes: [16]u8` at `ids.zig:96` | `added by the port` | The port stores the 16 bytes and gives them back. It never reads a version out of them, never reformats them and never writes them. Recorded at `ids.zig:88-92`. |
| `TreeId::ROOT` at `:749` | `pub const treeIdRoot: TreeId` at `ids.zig:119` | `renamed by rule` | Rule Z3. Recorded at `ids.zig:115-118`. |
| the `PartialEq`, `Eq`, `PartialOrd` and `Ord` derives on `TreeId` at `:741` | `pub fn eql` at `ids.zig:99` and `pub fn lessThan` at `ids.zig:105` | `renamed by rule` | As for `NodeId`. |
| the `Hash` derive on `TreeId` at `:741` | `pub fn hash(self: TreeId, hasher: *std.hash.Wyhash)` at `ids.zig:110` | `renamed by rule` | As for `NodeId`. |
| the `Debug` derive on `TreeId` at `:741` | none | `deleted with reason` | The port declares no `format` for `TreeId`. A `NodeId` has one at `ids.zig:84` because upstream gives one, and upstream gives `TreeId` a derived `Debug` that renders 16 bytes in GUID form. Nothing in the port renders a `TreeId`. `ids.zig` records no reason. |
| the `Clone` and `Copy` derives at `:711` and `:741` | structural | `merged` | A value type is copyable without a derive. |
| `serde` and `schemars` attributes at `:712-713` and `:742-743` | none | `deleted with reason` | The port carries no serializer. `docs/30-port-design.md` section 2.2. |
| `uuid::Uuid`, re-exported at `lib.rs:32`, as the payload of `TreeId` | 16 opaque bytes at `ids.zig:96` | `deleted with reason` | The port never calls generation, formatting or parsing, so it drops the parser and the version-4 generator that `Uuid` brings. Recorded at `ids.zig:13-16` and `docs/30-port-design.md` section 2.2. |
| no upstream counterpart | `pub fn treeIdFromBytes(bytes: [16]u8) TreeId` at `ids.zig:122` | `added by the port` | Upstream reaches the bytes through the public field. The flat re-export forbids a bare `fromBytes`. |
| no upstream counterpart | `pub fn treeIdToBytes(value: TreeId) [16]u8` at `ids.zig:128` | `added by the port` | The result is a copy, so it does not borrow the value. |
| no upstream counterpart | the `comptime` block at `ids.zig:132-146` | `added by the port` | `AGENTS.md:56`. The numbers come from `accesskit-c/include/accesskit.h:686` and `:708`. |

### 4.4 `src/schema/values.zig`

Upstream range `accesskit/src/lib.rs:761-855`.

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `pub struct CustomAction` at `:761` | `pub const CustomAction = struct` at `src/schema/values.zig:47` | `translated` | Rule Z1. It is the one plain struct in this module, because an `extern struct` cannot hold the slice inside `description`. Recorded at `values.zig:43-46`. |
| field `id: i32` at `:762` | `id: i32` at `values.zig:58` | `translated` | Rule Z4. |
| field `description: String` at `:763` | `description: std.ArrayList(u8)` at `values.zig:60` | `renamed by rule` | Rule Z4 keeps the spelling. The payload type changes, because Zig has no owned string, and `init` and `deinit` carry the allocator as a parameter. Recorded at `values.zig:4-6` and `:38-46`. |
| no upstream counterpart | `pub const InitError = error{ OutOfMemory }` at `values.zig:50`, `pub fn init` at `:68` and `pub fn deinit` at `:80` | `added by the port` | `AGENTS.md:280-282`: a lifetime becomes a parameter. Zig has no `Drop`, so the owner calls `deinit` once with the allocator `init` was given. Recorded at `values.zig:38-46`. |
| the `PartialEq` and `Eq` derives at `:756` | `pub fn eql(self: CustomAction, other: CustomAction) bool` at `values.zig:92` | `renamed by rule` | Zig rejects `==` for a struct. The comparison reads the description bytes, not the slice pointer, so it agrees with upstream's derived `Eq`. Recorded at `values.zig:85-91` and `:9-11`. |
| the `Debug` derive on `CustomAction` at `:756` | none | `deleted with reason` | The port declares no `format` for `CustomAction`. Nothing in the port renders one. `values.zig` records no reason. |
| `pub struct TextPosition` at `:771` | `pub const TextPosition = extern struct` at `values.zig:110` | `translated` | `extern struct`, because `accesskit_text_position` declares the node id first and the index second, and `ActionData` carries the value in an `extern union`. Recorded at `values.zig:106-109`. |
| field `node: NodeId` at `:773` | `node_id: NodeId` at `values.zig:113` | `renamed by rule` | The module records this as rule Z4 at `values.zig:111-112`. Rule Z4 as written, at `docs/10-accesskit-core.md:30`, keeps the spelling, so this row records a deliberate departure from Z4 and not Z4 itself. |
| field `character_index: usize` at `:776` | `character_index: usize` at `values.zig:115` | `translated` | Rule Z4. |
| the `PartialEq` and `Eq` derives on `TextPosition` at `:766` | `pub fn eql` at `values.zig:122` | `renamed by rule` | Zig rejects `==` for a struct. |
| the `Debug` derive on `TextPosition` at `:766` | none | `deleted with reason` | The port declares no `format`. `values.zig` records no reason. |
| no upstream counterpart | `pub fn compare(self: TextPosition, other: TextPosition) ?std.math.Order` at `values.zig:138` | `added by the port` | Upstream orders the borrowed position type it exposes to adapters at `accesskit_consumer/src/text.rs:583-592`, and reports two positions in different text runs the same way. The port needs the same order inside its store, so it adds the method. Recorded at `values.zig:127-137`. |
| `pub struct TextSelection` at `:784` | `pub const TextSelection = extern struct` at `values.zig:155` | `translated` | `extern struct`, because `accesskit_text_selection` declares an anchor followed by a focus. Recorded at `values.zig:151-154`. |
| field `anchor: TextPosition` at `:789` | `anchor: TextPosition` at `values.zig:159` | `translated` | Rule Z4. |
| field `focus: TextPosition` at `:793` | `focus: TextPosition` at `values.zig:163` | `translated` | Rule Z4. |
| the `PartialEq` and `Eq` derives on `TextSelection` at `:779` | `pub fn eql` at `values.zig:165` | `renamed by rule` | Zig rejects `==` for a struct. |
| the `Debug` derive on `TextSelection` at `:779` | none | `deleted with reason` | The port declares no `format`. `values.zig` records no reason. |
| no upstream counterpart | `pub fn compare(self: TextSelection, other: TextSelection) ?std.math.Order` at `values.zig:177` | `added by the port` | Orders by `anchor` first and `focus` second, and takes the `null` from `TextPosition.compare`. Recorded at `values.zig:170-176`. |
| `#[repr(C)] pub struct Color` at `:833-834` | `pub const Color = extern struct` at `values.zig:190` | `translated` | Recorded at `values.zig:186-189`. |
| field `red: u8` at `:835` | `red` at `values.zig:191` | `translated` | Rule Z4. |
| field `green: u8` at `:836` | `green` at `values.zig:192` | `translated` | Rule Z4. |
| field `blue: u8` at `:837` | `blue` at `values.zig:193` | `translated` | Rule Z4. |
| field `alpha: u8` at `:838` | `alpha` at `values.zig:195` | `translated` | Rule Z4. |
| the `PartialEq` and `Eq` derives on `Color` at `:829` | `pub fn eql(self: Color, other: Color) bool` at `values.zig:198` | `renamed by rule` | Zig rejects `==` for a struct. |
| the `Debug` derive on `Color` at `:829` | none | `deleted with reason` | The port declares no `format`. `values.zig` records no reason. |
| `#[repr(C)] pub struct TextDecoration` at `:846-847` | `pub const TextDecoration = extern struct` at `values.zig:212` | `translated` | Recorded at `values.zig:208-211`. |
| field `style: TextDecorationStyle` at `:848` | `style: TextDecorationStyle` at `values.zig:215` | `translated` | Rule Z4. |
| field `color: Color` at `:849` | `color: Color` at `values.zig:217` | `translated` | Rule Z4. |
| the `PartialEq` and `Eq` derives on `TextDecoration` at `:842` | `pub fn eql(self: TextDecoration, other: TextDecoration) bool` at `values.zig:220` | `renamed by rule` | Zig rejects `==` for a struct. |
| the `Debug` derive on `TextDecoration` at `:842` | none | `deleted with reason` | The port declares no `format`. `values.zig` records no reason. |
| the `Clone` derives on all five at `:756`, `:766`, `:779`, `:829`, `:842` | structural | `merged` | A value type is copyable without a derive. |
| `serde` attributes on all five at `:757-760`, `:767-770`, `:780-783`, `:830-832`, `:843-845` | none | `deleted with reason` | The port carries no serializer. `docs/30-port-design.md` section 2.2. |
| no upstream counterpart | the layout tests at `values.zig:323-362` | `added by the port` | `AGENTS.md:56`. The offsets of the four `extern struct` types are the C header offsets. The offsets of `CustomAction` are measured, because Zig 0.16.0 reorders the fields of a plain struct to remove padding. Recorded at `values.zig:16-19`. |

### 4.5 One upstream item inside the range that belongs elsewhere

`enum Flag` at `accesskit/src/lib.rs:801-826` and its `mask` method at `:822-826`
fall inside the `values.zig` range, so section 4.4 has no row for them. Their
rows are in section 5.1, which is where the port keeps them.

## 5. `src/schema/props/table.zig`

Upstream is `accesskit/src/lib.rs`, in five places: `enum Flag` at `:796-826`,
`enum PropertyValue` at `:855-886` with its hand-written `Clone` at `:1011-1058`,
`enum PropertyId` at `:888-1009`, the store at `:1060-1168`, and the `serde` and
`schemars` writers at `:2793-3160`. The two items this ledger previously routed
out of range, `Flag` and `PropertyValue`, are rowed here. The file is 2404 lines,
31 of them tests.

### 5.1 `Flag` and the one-bit mask

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]` at `:796` and `#[repr(u8)]` at `:800` | `pub const Flag = enum(u8)` at `src/schema/props/table.zig:129` | `translated` | `#[repr(u8)]` becomes `enum(u8)`, and a value type is copyable and comparable without a derive. |
| `Debug`, `PartialOrd`, `Ord` and `Hash` from that derive | none | `deleted with reason` | The port declares no `format` for `Flag`, no ordering and no digest. A flag reaches a writer through `@tagName` at `node.zig:290`, and `flagSetMembers` gives the members in declaration order. `table.zig` records no reason for the four. |
| `#[cfg_attr(feature = "serde", …)]`, `schemars` and `enumn` at `:797-799` | none | `deleted with reason` | The port generates no code for another language. Recorded at `docs/30-port-design.md` section 2.2. |
| `enum Flag` at `:801` | `Flag` at `table.zig:129` | `translated` | Rule Z1. |
| the 18 variants `Hidden` to `IsSuggestion` at `:802-819` | `Flag.hidden` to `Flag.is_suggestion` at `table.zig:130-147` | `renamed by rule` | Rule Z5, discriminants 0 to 17 unchanged. The discriminant is the bit position, recorded at `table.zig:123-128`. |
| `impl Flag { fn mask }` at `:822-826` | `pub fn flagMask(flag: Flag) u32` at `table.zig:166` | `renamed by rule` | Rule P1, because the operation takes no `self`. Recorded at `table.zig:161-165`. |
| no upstream counterpart | `pub const count: usize = 18` at `table.zig:150`, `pub const flagCount` at `:159`, and the `comptime` block at `:153-156` | `added by the port` | `AGENTS.md:57-58` asks for a named bound on every loop and `:106-109` asks for a comptime sweep. The block pins the 18 tags and that the last discriminant is 17. |
| no upstream counterpart | `flagSetContains` at `:171`, `flagSetUnion` at `:177` and `flagSetDifference` at `:182` | `added by the port` | `flag_methods!` at `:1170` inlines the mask test and the two mask writes. The port publishes the three because the mask is the C ABI type, the same reason `action.zig` carries its own three. |
| no upstream counterpart | `flagSetMembers(flag_set: u32, out: *[flagCount]Flag)` at `:191` | `added by the port` | It is upstream `action_mask_to_action_vec` at `:390-400` applied to the flag mask, which upstream never wrote. It fills a caller buffer bounded by `flagCount`, so the port never allocates. |

### 5.2 `PropertyId`

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Hash)]` at `:888` and `#[repr(u8)]` at `:892` | `pub const PropertyId = enum(u8)` at `table.zig:210` | `translated` | `#[repr(u8)]` becomes `enum(u8)`, and a value type is copyable and comparable without a derive. |
| `#[cfg_attr(feature = "serde", …)]`, `schemars` and `enumn::N` at `:889-891` | none | `deleted with reason` | The port generates no code for another language and carries no serializer. Recorded at `docs/30-port-design.md` section 2.2. |
| `Debug`, `PartialOrd`, `Ord` and `Hash` from that derive | none | `deleted with reason` | The port renders a property id through `@tagName` at `node.zig:318` and orders the store by `@intFromEnum`, so it declares no `format`, no ordering and no digest. `table.zig` records no reason for the four. |
| `enum PropertyId` at `:893` | `PropertyId` at `table.zig:210` | `translated` | Rule Z1. |
| the 87 variants at `:895-1005` in 13 families | `PropertyId` at `table.zig:212-322`, in the same 13 families | `renamed by rule` | Rule Z5, discriminants unchanged. Section 5.3 gives one row per property. |
| variant `Unset` at `:1007-1008` | none | `deleted with reason` | A sorted slice needs no "no slot" byte, so absence is a `null` from `Properties.get`. Recorded at `table.zig:45-51`. |
| no upstream counterpart | `pub const propertyIdTagCount` at `table.zig:326` and `pub fn propertyIdFromInt` at `:332` | `added by the port` | The C seam and the D-Bus codec each receive one property byte and neither may trust it. The same reason the thirteen `node_enums.zig` gates exist. Recorded at `table.zig:325` and `:328-331`. |

### 5.3 `PropertyId`: one row per property

`PropertyId` carries 87 properties and no sentinel. One row per property runs to
87 rows and would hide the rule that matters, so the disposition table above
gives one row for the type and one per family, and the table below gives one row
per property with both `path:line` values. Rule Z5 copies each discriminant, so
the count of preceding variant declarations is the same number in both files.

| Upstream family comment | Upstream variants | Zig tags | Payload tags | Properties | Discriminants |
|---|---|---|---|---:|---|
| `// NodeIdVec` at `accesskit/src/lib.rs:894` | `Children` at `:895` to `RadioGroup` at `:902` | `children` at `table.zig:212` to `radio_group` at `:219` | `node_id_vec` | 8 | 0 to 7 |
| `// NodeId` at `accesskit/src/lib.rs:904` | `ActiveDescendant` at `:905` to `PopupFor` at `:911` | `active_descendant` at `table.zig:222` to `popup_for` at `:228` | `node_id` | 7 | 8 to 14 |
| `// String` at `accesskit/src/lib.rs:913` | `Label` at `:914` to `BrailleRoleDescription` at `:934` | `label` at `table.zig:231` to `braille_role_description` at `:251` | `string` | 21 | 15 to 35 |
| `// f64` at `accesskit/src/lib.rs:936` | `ScrollX` at `:937` to `NumericValueJump` at `:947` | `scroll_x` at `table.zig:254` to `numeric_value_jump` at `:264` | `f64_` | 11 | 36 to 46 |
| `// f32` at `accesskit/src/lib.rs:949` | `FontSize` at `:950` to `FontWeight` at `:951` | `font_size` at `table.zig:267` to `font_weight` at `:268` | `f32_` | 2 | 47 to 48 |
| `// usize` at `accesskit/src/lib.rs:953` | `RowCount` at `:954` to `PositionInSet` at `:962` | `row_count` at `table.zig:271` to `position_in_set` at `:279` | `usize_` | 9 | 49 to 57 |
| `// Color` at `accesskit/src/lib.rs:964` | `ColorValue` at `:965` to `ForegroundColor` at `:967` | `color_value` at `table.zig:282` to `foreground_color` at `:284` | `color` | 3 | 58 to 60 |
| `// TextDecoration` at `accesskit/src/lib.rs:969` | `Overline` at `:970` to `Underline` at `:972` | `overline` at `table.zig:287` to `underline` at `:289` | `text_decoration` | 3 | 61 to 63 |
| `// LengthVec` at `accesskit/src/lib.rs:974` | `CharacterLengths` at `:975` to `WordStarts` at `:976` | `character_lengths` at `table.zig:292` to `word_starts` at `:293` | `length_vec` | 2 | 64 to 65 |
| `// CoordVec` at `accesskit/src/lib.rs:978` | `CharacterPositions` at `:979` to `CharacterWidths` at `:980` | `character_positions` at `table.zig:296` to `character_widths` at `:297` | `coord_vec` | 2 | 66 to 67 |
| `// bool` at `accesskit/src/lib.rs:982` | `Expanded` at `:983` to `Selected` at `:984` | `expanded` at `table.zig:300` to `selected` at `:301` | `bool_` | 2 | 68 to 69 |
| `// Unique enums` at `accesskit/src/lib.rs:986` | `Invalid` at `:987` to `VerticalOffset` at `:998` | `invalid` at `table.zig:304` to `vertical_offset` at `:315` | `invalid`, `toggled`, `live`, `text_direction`, `orientation`, `sort_direction`, `aria_current`, `auto_complete`, `has_popup`, `list_style`, `text_align`, `vertical_offset` | 12 | 70 to 81 |
| `// Other` at `accesskit/src/lib.rs:1000` | `Transform` at `:1001` to `TreeId` at `:1005` | `transform` at `table.zig:318` to `tree_id` at `:322` | `affine`, `rect`, `text_selection`, `custom_action_vec`, `tree_id` | 5 | 82 to 86 |

| Discriminant | Upstream variant | Zig tag | Payload tag | Descriptor row |
|---:|---|---|---|---|
| 0 | `Children` at `accesskit/src/lib.rs:895` | `PropertyId.children` at `table.zig:212` | `node_id_vec` | `table.zig:918` |
| 1 | `Controls` at `accesskit/src/lib.rs:896` | `PropertyId.controls` at `table.zig:213` | `node_id_vec` | `table.zig:919` |
| 2 | `Details` at `accesskit/src/lib.rs:897` | `PropertyId.details` at `table.zig:214` | `node_id_vec` | `table.zig:920` |
| 3 | `DescribedBy` at `accesskit/src/lib.rs:898` | `PropertyId.described_by` at `table.zig:215` | `node_id_vec` | `table.zig:921` |
| 4 | `FlowTo` at `accesskit/src/lib.rs:899` | `PropertyId.flow_to` at `table.zig:216` | `node_id_vec` | `table.zig:922` |
| 5 | `LabelledBy` at `accesskit/src/lib.rs:900` | `PropertyId.labelled_by` at `table.zig:217` | `node_id_vec` | `table.zig:923` |
| 6 | `Owns` at `accesskit/src/lib.rs:901` | `PropertyId.owns` at `table.zig:218` | `node_id_vec` | `table.zig:924` |
| 7 | `RadioGroup` at `accesskit/src/lib.rs:902` | `PropertyId.radio_group` at `table.zig:219` | `node_id_vec` | `table.zig:925` |
| 8 | `ActiveDescendant` at `accesskit/src/lib.rs:905` | `PropertyId.active_descendant` at `table.zig:222` | `node_id` | `table.zig:928` |
| 9 | `ErrorMessage` at `accesskit/src/lib.rs:906` | `PropertyId.error_message` at `table.zig:223` | `node_id` | `table.zig:929` |
| 10 | `InPageLinkTarget` at `accesskit/src/lib.rs:907` | `PropertyId.in_page_link_target` at `table.zig:224` | `node_id` | `table.zig:930` |
| 11 | `MemberOf` at `accesskit/src/lib.rs:908` | `PropertyId.member_of` at `table.zig:225` | `node_id` | `table.zig:931` |
| 12 | `NextOnLine` at `accesskit/src/lib.rs:909` | `PropertyId.next_on_line` at `table.zig:226` | `node_id` | `table.zig:932` |
| 13 | `PreviousOnLine` at `accesskit/src/lib.rs:910` | `PropertyId.previous_on_line` at `table.zig:227` | `node_id` | `table.zig:933` |
| 14 | `PopupFor` at `accesskit/src/lib.rs:911` | `PropertyId.popup_for` at `table.zig:228` | `node_id` | `table.zig:934` |
| 15 | `Label` at `accesskit/src/lib.rs:914` | `PropertyId.label` at `table.zig:231` | `string` | `table.zig:937` |
| 16 | `Description` at `accesskit/src/lib.rs:915` | `PropertyId.description` at `table.zig:232` | `string` | `table.zig:938` |
| 17 | `Value` at `accesskit/src/lib.rs:916` | `PropertyId.value` at `table.zig:233` | `string` | `table.zig:939` |
| 18 | `AccessKey` at `accesskit/src/lib.rs:917` | `PropertyId.access_key` at `table.zig:234` | `string` | `table.zig:940` |
| 19 | `AuthorId` at `accesskit/src/lib.rs:918` | `PropertyId.author_id` at `table.zig:235` | `string` | `table.zig:941` |
| 20 | `ClassName` at `accesskit/src/lib.rs:919` | `PropertyId.class_name` at `table.zig:236` | `string` | `table.zig:942` |
| 21 | `FontFamily` at `accesskit/src/lib.rs:920` | `PropertyId.font_family` at `table.zig:237` | `string` | `table.zig:943` |
| 22 | `HtmlId` at `accesskit/src/lib.rs:921` | `PropertyId.html_id` at `table.zig:238` | `string` | `table.zig:944` |
| 23 | `HtmlTag` at `accesskit/src/lib.rs:922` | `PropertyId.html_tag` at `table.zig:239` | `string` | `table.zig:945` |
| 24 | `InnerHtml` at `accesskit/src/lib.rs:923` | `PropertyId.inner_html` at `table.zig:240` | `string` | `table.zig:946` |
| 25 | `KeyboardShortcut` at `accesskit/src/lib.rs:924` | `PropertyId.keyboard_shortcut` at `table.zig:241` | `string` | `table.zig:947` |
| 26 | `Language` at `accesskit/src/lib.rs:925` | `PropertyId.language` at `table.zig:242` | `string` | `table.zig:948` |
| 27 | `Placeholder` at `accesskit/src/lib.rs:926` | `PropertyId.placeholder` at `table.zig:243` | `string` | `table.zig:949` |
| 28 | `RoleDescription` at `accesskit/src/lib.rs:927` | `PropertyId.role_description` at `table.zig:244` | `string` | `table.zig:950` |
| 29 | `StateDescription` at `accesskit/src/lib.rs:928` | `PropertyId.state_description` at `table.zig:245` | `string` | `table.zig:951` |
| 30 | `Tooltip` at `accesskit/src/lib.rs:929` | `PropertyId.tooltip` at `table.zig:246` | `string` | `table.zig:952` |
| 31 | `Url` at `accesskit/src/lib.rs:930` | `PropertyId.url` at `table.zig:247` | `string` | `table.zig:953` |
| 32 | `RowIndexText` at `accesskit/src/lib.rs:931` | `PropertyId.row_index_text` at `table.zig:248` | `string` | `table.zig:954` |
| 33 | `ColumnIndexText` at `accesskit/src/lib.rs:932` | `PropertyId.column_index_text` at `table.zig:249` | `string` | `table.zig:955` |
| 34 | `BrailleLabel` at `accesskit/src/lib.rs:933` | `PropertyId.braille_label` at `table.zig:250` | `string` | `table.zig:956` |
| 35 | `BrailleRoleDescription` at `accesskit/src/lib.rs:934` | `PropertyId.braille_role_description` at `table.zig:251` | `string` | `table.zig:957` |
| 36 | `ScrollX` at `accesskit/src/lib.rs:937` | `PropertyId.scroll_x` at `table.zig:254` | `f64_` | `table.zig:960` |
| 37 | `ScrollXMin` at `accesskit/src/lib.rs:938` | `PropertyId.scroll_x_min` at `table.zig:255` | `f64_` | `table.zig:961` |
| 38 | `ScrollXMax` at `accesskit/src/lib.rs:939` | `PropertyId.scroll_x_max` at `table.zig:256` | `f64_` | `table.zig:962` |
| 39 | `ScrollY` at `accesskit/src/lib.rs:940` | `PropertyId.scroll_y` at `table.zig:257` | `f64_` | `table.zig:963` |
| 40 | `ScrollYMin` at `accesskit/src/lib.rs:941` | `PropertyId.scroll_y_min` at `table.zig:258` | `f64_` | `table.zig:964` |
| 41 | `ScrollYMax` at `accesskit/src/lib.rs:942` | `PropertyId.scroll_y_max` at `table.zig:259` | `f64_` | `table.zig:965` |
| 42 | `NumericValue` at `accesskit/src/lib.rs:943` | `PropertyId.numeric_value` at `table.zig:260` | `f64_` | `table.zig:966` |
| 43 | `MinNumericValue` at `accesskit/src/lib.rs:944` | `PropertyId.min_numeric_value` at `table.zig:261` | `f64_` | `table.zig:967` |
| 44 | `MaxNumericValue` at `accesskit/src/lib.rs:945` | `PropertyId.max_numeric_value` at `table.zig:262` | `f64_` | `table.zig:968` |
| 45 | `NumericValueStep` at `accesskit/src/lib.rs:946` | `PropertyId.numeric_value_step` at `table.zig:263` | `f64_` | `table.zig:969` |
| 46 | `NumericValueJump` at `accesskit/src/lib.rs:947` | `PropertyId.numeric_value_jump` at `table.zig:264` | `f64_` | `table.zig:970` |
| 47 | `FontSize` at `accesskit/src/lib.rs:950` | `PropertyId.font_size` at `table.zig:267` | `f32_` | `table.zig:973` |
| 48 | `FontWeight` at `accesskit/src/lib.rs:951` | `PropertyId.font_weight` at `table.zig:268` | `f32_` | `table.zig:974` |
| 49 | `RowCount` at `accesskit/src/lib.rs:954` | `PropertyId.row_count` at `table.zig:271` | `usize_` | `table.zig:977` |
| 50 | `ColumnCount` at `accesskit/src/lib.rs:955` | `PropertyId.column_count` at `table.zig:272` | `usize_` | `table.zig:978` |
| 51 | `RowIndex` at `accesskit/src/lib.rs:956` | `PropertyId.row_index` at `table.zig:273` | `usize_` | `table.zig:979` |
| 52 | `ColumnIndex` at `accesskit/src/lib.rs:957` | `PropertyId.column_index` at `table.zig:274` | `usize_` | `table.zig:980` |
| 53 | `RowSpan` at `accesskit/src/lib.rs:958` | `PropertyId.row_span` at `table.zig:275` | `usize_` | `table.zig:981` |
| 54 | `ColumnSpan` at `accesskit/src/lib.rs:959` | `PropertyId.column_span` at `table.zig:276` | `usize_` | `table.zig:982` |
| 55 | `Level` at `accesskit/src/lib.rs:960` | `PropertyId.level` at `table.zig:277` | `usize_` | `table.zig:983` |
| 56 | `SizeOfSet` at `accesskit/src/lib.rs:961` | `PropertyId.size_of_set` at `table.zig:278` | `usize_` | `table.zig:984` |
| 57 | `PositionInSet` at `accesskit/src/lib.rs:962` | `PropertyId.position_in_set` at `table.zig:279` | `usize_` | `table.zig:985` |
| 58 | `ColorValue` at `accesskit/src/lib.rs:965` | `PropertyId.color_value` at `table.zig:282` | `color` | `table.zig:988` |
| 59 | `BackgroundColor` at `accesskit/src/lib.rs:966` | `PropertyId.background_color` at `table.zig:283` | `color` | `table.zig:989` |
| 60 | `ForegroundColor` at `accesskit/src/lib.rs:967` | `PropertyId.foreground_color` at `table.zig:284` | `color` | `table.zig:990` |
| 61 | `Overline` at `accesskit/src/lib.rs:970` | `PropertyId.overline` at `table.zig:287` | `text_decoration` | `table.zig:993` |
| 62 | `Strikethrough` at `accesskit/src/lib.rs:971` | `PropertyId.strikethrough` at `table.zig:288` | `text_decoration` | `table.zig:994` |
| 63 | `Underline` at `accesskit/src/lib.rs:972` | `PropertyId.underline` at `table.zig:289` | `text_decoration` | `table.zig:995` |
| 64 | `CharacterLengths` at `accesskit/src/lib.rs:975` | `PropertyId.character_lengths` at `table.zig:292` | `length_vec` | `table.zig:998` |
| 65 | `WordStarts` at `accesskit/src/lib.rs:976` | `PropertyId.word_starts` at `table.zig:293` | `length_vec` | `table.zig:999` |
| 66 | `CharacterPositions` at `accesskit/src/lib.rs:979` | `PropertyId.character_positions` at `table.zig:296` | `coord_vec` | `table.zig:1002` |
| 67 | `CharacterWidths` at `accesskit/src/lib.rs:980` | `PropertyId.character_widths` at `table.zig:297` | `coord_vec` | `table.zig:1003` |
| 68 | `Expanded` at `accesskit/src/lib.rs:983` | `PropertyId.expanded` at `table.zig:300` | `bool_` | `table.zig:1006` |
| 69 | `Selected` at `accesskit/src/lib.rs:984` | `PropertyId.selected` at `table.zig:301` | `bool_` | `table.zig:1007` |
| 70 | `Invalid` at `accesskit/src/lib.rs:987` | `PropertyId.invalid` at `table.zig:304` | `invalid` | `table.zig:1010` |
| 71 | `Toggled` at `accesskit/src/lib.rs:988` | `PropertyId.toggled` at `table.zig:305` | `toggled` | `table.zig:1011` |
| 72 | `Live` at `accesskit/src/lib.rs:989` | `PropertyId.live` at `table.zig:306` | `live` | `table.zig:1012` |
| 73 | `TextDirection` at `accesskit/src/lib.rs:990` | `PropertyId.text_direction` at `table.zig:307` | `text_direction` | `table.zig:1013` |
| 74 | `Orientation` at `accesskit/src/lib.rs:991` | `PropertyId.orientation` at `table.zig:308` | `orientation` | `table.zig:1014` |
| 75 | `SortDirection` at `accesskit/src/lib.rs:992` | `PropertyId.sort_direction` at `table.zig:309` | `sort_direction` | `table.zig:1015` |
| 76 | `AriaCurrent` at `accesskit/src/lib.rs:993` | `PropertyId.aria_current` at `table.zig:310` | `aria_current` | `table.zig:1016` |
| 77 | `AutoComplete` at `accesskit/src/lib.rs:994` | `PropertyId.auto_complete` at `table.zig:311` | `auto_complete` | `table.zig:1017` |
| 78 | `HasPopup` at `accesskit/src/lib.rs:995` | `PropertyId.has_popup` at `table.zig:312` | `has_popup` | `table.zig:1018` |
| 79 | `ListStyle` at `accesskit/src/lib.rs:996` | `PropertyId.list_style` at `table.zig:313` | `list_style` | `table.zig:1019` |
| 80 | `TextAlign` at `accesskit/src/lib.rs:997` | `PropertyId.text_align` at `table.zig:314` | `text_align` | `table.zig:1020` |
| 81 | `VerticalOffset` at `accesskit/src/lib.rs:998` | `PropertyId.vertical_offset` at `table.zig:315` | `vertical_offset` | `table.zig:1021` |
| 82 | `Transform` at `accesskit/src/lib.rs:1001` | `PropertyId.transform` at `table.zig:318` | `affine` | `table.zig:1024` |
| 83 | `Bounds` at `accesskit/src/lib.rs:1002` | `PropertyId.bounds` at `table.zig:319` | `rect` | `table.zig:1025` |
| 84 | `TextSelection` at `accesskit/src/lib.rs:1003` | `PropertyId.text_selection` at `table.zig:320` | `text_selection` | `table.zig:1026` |
| 85 | `CustomActions` at `accesskit/src/lib.rs:1004` | `PropertyId.custom_actions` at `table.zig:321` | `custom_action_vec` | `table.zig:1027` |
| 86 | `TreeId` at `accesskit/src/lib.rs:1005` | `PropertyId.tree_id` at `table.zig:322` | `tree_id` | `table.zig:1028` |

The rule that pins the order is the one at `lib.rs:892` plus rule Z5: the enum is
`#[repr(u8)]`, the discriminants are copied unchanged, and `table.zig:1629-1639`
turns that into a compile error by refusing any descriptor row whose position is
not its discriminant. Upstream's own count of 88 including `Unset` is at
`lib.rs:1007-1008` and `:1062`.

### 5.4 `PropertyValue`

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| `#[derive(Debug, PartialEq)]` at `:855` | `PropertyValue` at `table.zig:349` | `translated` | A data-carrying enum becomes `union(enum)`, per `docs/24-rust-idiom-mapping.md` §2.2 row for `union(enum)`. |
| `Debug` from that derive | `pub fn format(self: PropertyValue, writer: *std.Io.Writer)` at `table.zig:486` | `translated` | It is the upstream `fmt::Debug` impl. It is a member because `{f}` does not reach a union on Zig 0.16.0, recorded at `table.zig:479-485`. |
| `PartialEq` from that derive | `pub fn eql(self: PropertyValue, other: PropertyValue) bool` at `table.zig:444` | `translated` | Zig rejects `==` for a union. Owned payloads compare by their bytes, never by their addresses, recorded at `table.zig:437-443`. |
| `enum PropertyValue` at `:856-886` | `PropertyValue` at `table.zig:349-535` | `translated` | |
| the 29 arms at `:857-885` | the 29 fields at `table.zig:352-380` | `renamed by rule` | Rule Z5 for the tag names, with three forced exceptions: `F64` becomes `f64_`, `F32` becomes `f32_` and `Bool` becomes `bool_`, because each collides with a Zig primitive keyword. Recorded at `table.zig:337-343`. |
| arm `Affine(Box<Affine>)` at `:881` | `affine: Affine` at `table.zig:376` | `translated` | The indirection is deleted and the value is held inline. Recorded at `table.zig:52-57`. |
| arm `TextSelection(Box<TextSelection>)` at `:883` | `text_selection: TextSelection` at `table.zig:378` | `translated` | The same reason. |
| arm `None` at `:857` | `none` at `table.zig:352` | `merged` | Upstream writes `None` over a slot to mark absence. The port never stores it: a cleared property leaves the slice, recorded at `table.zig:4-5` and `:350-351`. |
| `impl Clone for PropertyValue { fn clone }` at `:1012-1044` | `pub fn propertyValueClone(gpa, source)` at `table.zig:622` | `renamed by rule` | Rule P1, because a copy has no `self`. The `gpa` parameter is `AGENTS.md:99`, recorded at `table.zig:613-621`. |
| `fn clone_from` at `:1046-1057` | `pub fn propertyValueCloneInto(gpa, dest, source)` at `table.zig:678` | `renamed by rule` | Rule P1. It is the buffer-reuse half, recorded at `table.zig:661-669`. |
| no upstream counterpart | `pub const PropertyValueTag` at `table.zig:538`, `pub fn getTag` at `:388`, `pub fn deinit` at `:399` | `added by the port` | A Zig union names no tag type of its own, and it has no `Drop`. Reading the tag through a member keeps every switch over the payload domain exhaustive, recorded at `table.zig:382-387`. |
| no upstream counterpart | `PropertyValuePayloadType` at `table.zig:558`, `propertyValueTagCount` at `:596` and `propertyValueFrom` at `:605` | `added by the port` | `propertyValueFrom` reads its payload type out of `PropertyValuePayloadType`, so a caller that pairs a payload with the wrong tag is a compile error. Recorded at `table.zig:553-557` and `:592-595`. |
| no upstream counterpart | the `comptime` layout block at `table.zig:540-551` | `added by the port` | `AGENTS.md:56`. `PropertyValue` is 56 bytes at alignment 8, where `docs/10-accesskit-core.md:670` predicts 40 by naming `Rect` the largest payload. It is not: upstream boxes `Affine` and this port does not. |
| no upstream counterpart | the private helpers `sameOwnedBuffer` at `table.zig:791`, `sameListBuffer` at `:831`, `deinitActions` at `:839`, `eqlNodeIds` at `:844`, `eqlActions` at `:852`, `cloneList` at `:860` and `cloneActions` at `:871` | `added by the port` | Zig has no `Drop`, no `PartialEq` and no `clone_from` for these payload types, so each behaviour the derives and the `Clone` impl gave upstream is a named private function. |

#### The 29 arms

| Upstream arm | Zig field |
|---|---|
| `None` at `accesskit/src/lib.rs:857` | `PropertyValue.none` at `table.zig:352` |
| `NodeIdVec(Vec<NodeId>)` at `accesskit/src/lib.rs:858` | `PropertyValue.node_id_vec: std.ArrayList(NodeId)` at `table.zig:353` |
| `NodeId(NodeId)` at `accesskit/src/lib.rs:859` | `PropertyValue.node_id: NodeId` at `table.zig:354` |
| `String(String)` at `accesskit/src/lib.rs:860` | `PropertyValue.string: std.ArrayList(u8)` at `table.zig:355` |
| `F64(f64)` at `accesskit/src/lib.rs:861` | `PropertyValue.f64_: f64` at `table.zig:356` |
| `F32(f32)` at `accesskit/src/lib.rs:862` | `PropertyValue.f32_: f32` at `table.zig:357` |
| `Usize(usize)` at `accesskit/src/lib.rs:863` | `PropertyValue.usize_: usize` at `table.zig:358` |
| `Color(Color)` at `accesskit/src/lib.rs:864` | `PropertyValue.color: Color` at `table.zig:359` |
| `TextDecoration(TextDecoration)` at `accesskit/src/lib.rs:865` | `PropertyValue.text_decoration: TextDecoration` at `table.zig:360` |
| `LengthVec(Vec<u8>)` at `accesskit/src/lib.rs:866` | `PropertyValue.length_vec: std.ArrayList(u8)` at `table.zig:361` |
| `CoordVec(Vec<f32>)` at `accesskit/src/lib.rs:867` | `PropertyValue.coord_vec: std.ArrayList(f32)` at `table.zig:362` |
| `Bool(bool)` at `accesskit/src/lib.rs:868` | `PropertyValue.bool_: bool` at `table.zig:363` |
| `Invalid(Invalid)` at `accesskit/src/lib.rs:869` | `PropertyValue.invalid: Invalid` at `table.zig:364` |
| `Toggled(Toggled)` at `accesskit/src/lib.rs:870` | `PropertyValue.toggled: Toggled` at `table.zig:365` |
| `Live(Live)` at `accesskit/src/lib.rs:871` | `PropertyValue.live: Live` at `table.zig:366` |
| `TextDirection(TextDirection)` at `accesskit/src/lib.rs:872` | `PropertyValue.text_direction: TextDirection` at `table.zig:367` |
| `Orientation(Orientation)` at `accesskit/src/lib.rs:873` | `PropertyValue.orientation: Orientation` at `table.zig:368` |
| `SortDirection(SortDirection)` at `accesskit/src/lib.rs:874` | `PropertyValue.sort_direction: SortDirection` at `table.zig:369` |
| `AriaCurrent(AriaCurrent)` at `accesskit/src/lib.rs:875` | `PropertyValue.aria_current: AriaCurrent` at `table.zig:370` |
| `AutoComplete(AutoComplete)` at `accesskit/src/lib.rs:876` | `PropertyValue.auto_complete: AutoComplete` at `table.zig:371` |
| `HasPopup(HasPopup)` at `accesskit/src/lib.rs:877` | `PropertyValue.has_popup: HasPopup` at `table.zig:372` |
| `ListStyle(ListStyle)` at `accesskit/src/lib.rs:878` | `PropertyValue.list_style: ListStyle` at `table.zig:373` |
| `TextAlign(TextAlign)` at `accesskit/src/lib.rs:879` | `PropertyValue.text_align: TextAlign` at `table.zig:374` |
| `VerticalOffset(VerticalOffset)` at `accesskit/src/lib.rs:880` | `PropertyValue.vertical_offset: VerticalOffset` at `table.zig:375` |
| `Affine(Box<Affine>)` at `accesskit/src/lib.rs:881` | `PropertyValue.affine: Affine` at `table.zig:376` |
| `Rect(Rect)` at `accesskit/src/lib.rs:882` | `PropertyValue.rect: Rect` at `table.zig:377` |
| `TextSelection(Box<TextSelection>)` at `accesskit/src/lib.rs:883` | `PropertyValue.text_selection: TextSelection` at `table.zig:378` |
| `CustomActionVec(Vec<CustomAction>)` at `accesskit/src/lib.rs:884` | `PropertyValue.custom_action_vec: std.ArrayList(CustomAction)` at `table.zig:379` |
| `TreeId(TreeId)` at `accesskit/src/lib.rs:885` | `PropertyValue.tree_id: TreeId` at `table.zig:380` |

### 5.5 The descriptor table and the store

| Upstream item | Zig item | Disposition | Reason |
|---|---|---|---|
| the id-to-payload relation, written three times upstream: in the `PropertyId` block comments at `:894-1005`, in the deserializer at `:2891-3001` and in the schemars output at `:3044-3153` | `pub const property_descriptors` at `table.zig:916-1029` | `merged` | One `comptime` table is the single home of the relation, recorded at `table.zig:905-912`. A row holds a `type`, so the array is `comptime` data. |
| the 23 `macro_rules!` definitions at `:1170-1778` | the same table, read through `propertyDescriptor`, `propertyValueTagOf` and `PropertyPayloadType` | `merged` | Each macro named the payload type beside the property id. The port keeps the relation once and lets the eight accessor modules read it. `table.zig:26` and `:908` say 27 macros at that range; the range holds 23 and the file holds 27, four of them the `serde` and `schemars` writers. `docs/40-plan.md:504-508` records the discrepancy as open. |
| `struct PropertyIndices([u8; 87])` at `:1060-1062` and `impl Default for PropertyIndices` at `:1064-1068` | none | `deleted with reason` | The store holds a sorted slice of id and value pairs, so the slot array and the sentinel byte that indexed it are both gone. Recorded at `table.zig:45-51`. |
| `fn value_at` at `:1076-1082` | none | `deleted with reason` | It maps a slot index to a value, and there is no slot index. The port's binary search is `insertionIndex` at `table.zig:1557`. |
| `impl PartialEq for Properties` at `:1084-1094` | `pub fn Properties.eql(a, b)` at `table.zig:1478` | `translated` | Zig rejects `==` for a struct. The comparison is structural rather than positional: the same ids with the same payloads, whatever order either store was written in. Recorded at `table.zig:1469-1477` and `:58-63`. |
| `impl PropertyIndices { fn get }` at `:1115-1119` | `Properties.find` at `table.zig:1381` and `Properties.get` at `:1394` | `merged` | One upstream read becomes a binary search that yields a position and a value. Recorded at `table.zig:1376-1380` and `:1388-1393`. |
| `struct Properties` at `:1071-1074` | `pub const Properties = struct` at `table.zig:1346` | `translated` | Two upstream fields become two others: `gpa: std.mem.Allocator` at `:1349` and `items: std.ArrayList(Property)` at `:1352`, the second a sorted slice of id and value pairs. |
| field `indices: PropertyIndices` at `:1072` | none | `deleted with reason` | The same reason as the struct. |
| field `values: Vec<PropertyValue>` at `:1073` | `items: std.ArrayList(Property)` at `table.zig:1352` | `renamed by rule` | Rule Z4 keeps the `snake_case` spelling and the port takes a different name because the slice holds pairs, not bare values. Recorded at `table.zig:1350-1351`. |
| `Default` from the derive at `:1070` | `pub fn init(gpa: std.mem.Allocator)` at `table.zig:1356` | `translated` | There is no `Default`, because a default store would have to name an allocator. Recorded at `table.zig:1354-1355`. |
| `Debug` from that derive | none | `deleted with reason` | The port declares no `format` for the store. `Node.format` writes each entry through `PropertyValue.format` at `node.zig:313-321`. `table.zig` records no reason. |
| `Properties::get_mut` at `:1122-1136` | `pub fn getOrInsert` at `table.zig:1415` | `renamed by rule` | The name says what the call does: it inserts when the store holds none. Recorded at `table.zig:1399-1405`. |
| `Properties::set` at `:1138-1146` | `pub fn set` at `table.zig:1440` | `translated` | The name is unchanged and the signature is not: the port takes ownership of `value` and can fail, recorded at `table.zig:1429-1439`. |
| `Properties::clear` at `:1148-1153` | `pub fn clear` at `table.zig:1463` | `translated` | Upstream writes `PropertyValue::None` over the slot. The port removes the entry and releases the value, recorded at `table.zig:1454-1462`. |
| `Properties::clone` at `:1157-1162` | `pub fn clone(self, gpa)` at `table.zig:1492` | `translated` | Rule P1 for the allocator parameter: a store carries the allocator it was created with, so a copy is bound to the allocator it is given. Recorded at `table.zig:1487-1491`. |
| `Properties::clone_from` at `:1164-1167` | `pub fn cloneInto(self, out)` at `table.zig:1515` | `translated` | It is the 0.25.0 buffer-reuse change, recorded at `table.zig:1499-1514`. |
| no upstream counterpart | `Property` at `table.zig:886` with `deinit` at `:891`, `PropertyDescriptor` at `:899`, `propertyDescriptorCount` at `:1033`, `propertyIdCount` at `:1037`, `property_value_tags_by_id` at `:1042`, `propertyDescriptor` at `:1050`, `propertyValueTagOf` at `:1055`, `property_counts_by_tag` at `:1068` and `PropertyPayloadType` at `:1078` | `added by the port` | Upstream holds an id array beside a value array and never pairs them, so the pair and the row are port items. `propertyIdCount` is also the `comptime` bound every walk over the property domain uses, recorded at `table.zig:1035-1036`. |
| no upstream counterpart | `Properties.deinit` at `table.zig:1365`, `count` at `:1372` and the private `insertionIndex` at `:1557` | `added by the port` | Zig has no `Drop`. `count` and `insertionIndex` exist because the store is a slice and a caller may want a position; recorded at `table.zig:1360-1364`, `:1371` and `:1556`. |

### 5.6 The two run-time projections and the exhaustiveness sweep

`property_descriptors` holds a `type`, so it is `comptime` only. Two arrays are
derived from it for the readers that run at run time, and a third is derived from
the second.

| Zig item | What it is | Where the row's reason is recorded |
|---|---|---|
| `property_value_tags_by_id` at `table.zig:1042-1046` | The run-time projection: one tag per property, indexed by discriminant. | `table.zig:1039-1041` |
| `property_counts_by_tag` at `table.zig:1068-1072` | The second projection: how many descriptor rows carry each tag, so a family can count its own rows instead of sweeping all 87. | `table.zig:1059-1067` |
| the `comptime` block at `table.zig:1577-1655` | Four checks over the table: the tag count equals the row count, every discriminant appears exactly once, a row's declared payload is the payload its tag carries, and the rows stay in `PropertyId` order. Then the three domain asserts and one call to `assertTagsPartitioned()`. | `table.zig:1578-1654` |

A property added without a row, a row written twice, a row whose payload
disagrees with its tag, and a row out of order are each a compile error. That is
the compile-time property the 23 upstream `macro_rules!` definitions at
`lib.rs:1170-1778` gave the Rust type checker, and it is the whole reason the
descriptor table exists.

### 5.7 The family partition

Seven accessor modules under `src/schema/props/` each publish a getter, a setter
and a clearer for the properties they own. `table.zig` holds the relation that
makes "every property has an accessor" a build-time fact.

| Zig item | What it is | Where the row's reason is recorded |
|---|---|---|
| `pub const Family` at `table.zig:1129-1137` | The seven owning families. `flags.zig` is absent on purpose: the 18 flags are not `PropertyId` tags and carry no `PropertyValue` variant. | `table.zig:1124-1128` |
| `familyCount` at `table.zig:1141` | The `comptime` bound on the sweeps that walk the families. | `table.zig:1139-1140` |
| `familyTags` at `table.zig:1151-1175` | The payload tags one family owns. The 28 tags across the seven arms plus `PropertyValueTag.none` are the whole tag domain, which `propertyValueTagCount()` pins at 29. | `table.zig:1143-1150` |
| `family_by_tag` at `table.zig:1184-1198` | The reverse lookup, built once so both halves of the claim read a table instead of each sweeping seven lists. | `table.zig:1177-1183` |
| `assertFamilyReachable` at `table.zig:1226-1307` | Three claims about one family: no id twice, every claimed id carries a tag that family owns, and every row carrying such a tag is claimed. Called once per family from the family module: `colors.zig:272`, `enums.zig:685`, `ids.zig:111`, `numbers.zig:121`, `option.zig:262`, `strings.zig:81` and `vectors.zig:114`. | `table.zig:1209-1225` and the section comment at `:1082-1122` |
| `assertTagsPartitioned` at `table.zig:1314-1331` | The fourth claim: every descriptor row's tag is owned by exactly one family. Called once, from `table.zig:1649`. | `table.zig:1309-1313` |
| the private `declaresId` at `table.zig:1202-1207` | The membership test claim 2 uses on the path where the count check has already failed. | `table.zig:1200-1201` |

Claims 1 and 2 make each family a complete statement about its own tags, so
claim 3 turns seven local statements into a partition of the whole domain. A new
descriptor row on an existing tag fails its owner; a new row on a new tag fails
because no family owns that tag. Either way a row with no accessor behind it is a
compile error, which is what the block in section 5.6 could not say.

The table names one gap and does not close it: the C surface in
`src/capi/node_properties.zig` is an independent copy that pins 87 and 294 from
`export_names`, never from `propertyIdCount`. Recorded at `table.zig:1113-1122`.

### 5.8 How to verify one property, one arm and one flag

```sh
grep -n '^    braille_label = ' src/schema/props/table.zig
grep -n '^    BrailleLabel,' /tmp/scratch/accesskit/accesskit/src/lib.rs
```

The two commands give the Zig line and the upstream line. The count of preceding
variant declarations is the same number in both files, because rule Z5 copies each
discriminant rather than renumbering the tags. Run `zig build test` for the
domain itself: section 3.3 records that the root reaches every module under
`src/schema/`, and `table.zig` is one of them through `src/schema/root.zig:141`.
Read the count. `table.zig` declares 31 tests, and a run that reports fewer has
not analysed the file.

A single-file root does not work for this module, for the reason section 3.3
gives for `values.zig`: `table.zig` imports `../ids.zig`, `../node_enums.zig`,
`../values.zig` and the two geometry modules, all one level above it, so
`zig test src/schema/props/table.zig` reports `import of file outside module
path`. That is a property of the tool and not a defect in the file.

The `comptime` block at `table.zig:1577-1655` re-checks the whole domain on every
build, and the seven `assertFamilyReachable` calls in the accessor modules run in
the same evaluation, so one `zig build test` proves all 87 rows, both projections
and the family partition at once.

## 6. The deletions register

One row per upstream item the port does not carry. The two lists below were
reconciled: the first column was read off the module doc comments, and the
second column was found by comparing the upstream `impl` blocks against the
Zig declarations.

| Upstream item | Line | Dropped by | Reason | Where the reason is recorded |
|---|---|---|---|---|
| `use core::{fmt, ops::{…}}` | `geometry.rs:12-15` | `affine.zig` | Zig has no operator overloading. | `docs/19-geometry-and-text.md:1213-1218` |
| `#[cfg_attr(feature = "schemars"/"serde", …)]` on all geometry types | `geometry.rs:19-20`, `:209-210`, `:334-335`, `:568-569`, `:714-715` | all five geometry modules | The port generates no schema and carries no serializer. | `docs/30-port-design.md` section 2.2 |
| `Default` from the derive on `Point` | `geometry.rs:208` | `point.zig` | `pointOrigin` is the constant. | `point.zig:98-101` |
| `Default` from the derive on `Rect` | `geometry.rs:333` | `rect.zig` | `rectZero` is the constant. | recorded for `Point` at `point.zig:98-101`; `rect.zig` does not restate it |
| `Default` from the derive on `Size` | `geometry.rs:567` | `size.zig` | `sizeZero` is the constant. | recorded for `Vec2` at `vec2.zig:79-82`; `size.zig` does not restate it |
| `Default` from the derive on `Vec2` | `geometry.rs:713` | `vec2.zig` | `vec2Zero` is the constant. | `vec2.zig:79-82` |
| `Default` from the derive on `Role`, and `#[default]` on `Unknown` | `lib.rs:47`, `:63` | `role.zig` | The port has no `Default`. | not recorded in `role.zig` |
| `impl Default for Affine` | `geometry.rs:149-154` | `affine.zig` | `affineIdentity` is the named constant. | `docs/19-geometry-and-text.md:1261` |
| `Debug` from the derive on `Affine` | `geometry.rs:18` | `affine.zig` | The port declares no `format` for `Affine`. | not recorded in `affine.zig` |
| `Debug` from the derive on `Vec2` | `geometry.rs:713` | `vec2.zig` | The port declares no `format` for `Vec2`. | not recorded in `vec2.zig` |
| `Debug` from the derive on `Role` | `lib.rs:47` | `role.zig` | The port declares no `format` for `Role`. | not recorded in `role.zig` |
| `Debug` from the derive on `Action` | `lib.rs:274` | `action.zig` | The port declares no `format` for `Action`. | not recorded in `action.zig` |
| `Debug` from the derive on `TreeId` | `lib.rs:741` | `ids.zig` | The port declares no `format` for `TreeId`. | not recorded in `ids.zig` |
| `Debug` from the derive on all five types in `values.zig` | `lib.rs:756`, `:766`, `:779`, `:829`, `:842` | `values.zig` | The port declares no `format` for any of them. | not recorded in `values.zig` |
| `Debug` on all thirteen property enums | `lib.rs:402-693` | `node_enums.zig` | The port holds no tag-to-name conversion for them. | `node_enums.zig:12-13` |
| `Hash` from the derive on `Role`, `Action` and the thirteen enums | `lib.rs:47`, `:274`, `:402-693` | `role.zig`, `action.zig`, `node_enums.zig` | None of the three is a hash-map key. The port keys nodes on `NodeId`, which carries its own `hash`. | `ids.zig:55-64` for the method the port does carry |
| `PartialOrd` and `Ord` from the derive on `Role`, `Action` and the thirteen enums | `lib.rs:47`, `:274`, `:402-693` | the same three modules | A wire tag is ordered by its discriminant, and the port walks the domain in declaration order. | `action.zig:144-151` for the one place the port states a walk order |
| `serde`, `schemars` and `pyo3` attributes on `Role`, `Action` and the thirteen enums | `lib.rs:48-60`, `:275-287`, `:402-693` | the same three modules | The port generates no code for another language. | `docs/30-port-design.md` section 2.2 |
| `serde` and `schemars` attributes on `NodeId`, `TreeId` and the five `values.zig` types | `lib.rs:712-713`, `:742-743`, `:757-760` and four more | `ids.zig`, `values.zig` | The port carries no serializer. | `docs/30-port-design.md` section 2.2 |
| `uuid::Uuid` as the payload of `TreeId` | `lib.rs:32`, `:745` | `ids.zig` | The port never generates, parses or formats a tree identifier. | `ids.zig:13-16` |
| `From<(f64, f64)> for Point` and `From<Point> for (f64, f64)` | `geometry.rs:239-251` | `point.zig` | Zig has a named-field struct literal. | `point.zig:38-40` |
| the four `Point` assign impls | `geometry.rs:262`, `:278`, `:294`, `:310` | `point.zig` | A Zig caller assigns the result of the value-returning method. | `point.zig:32-34` |
| `Add<(f64, f64)> for Point` and `Sub<(f64, f64)> for Point` | `geometry.rs:285-292`, `:301-308` | `point.zig` | `pointToVec2` reads a `Point` as that vector, so the `Vec2` methods cover them. | `point.zig:35-37` |
| `From<(f64, f64)> for Size` and `From<Size> for (f64, f64)` | `geometry.rs:691-706` | `size.zig` | Zig has a named-field struct literal. | `docs/19:1249` |
| the four `Size` assign impls | `geometry.rs:602`, `:633`, `:666`, `:684` | `size.zig` | A Zig caller assigns the result. | `docs/19:1241`, `:1244`, `:1246`, `:1248` |
| `Mul<Size> for f64` | `geometry.rs:612-619` | `size.zig` | Upstream defines it as `other * self`, which `Size.scale` computes. | `docs/19:1242` |
| `From<(f64, f64)> for Vec2` and `From<Vec2> for (f64, f64)` | `geometry.rs:747-759` | `vec2.zig` | Zig has a named-field struct literal. | `vec2.zig:22-24` |
| the four `Vec2` assign impls | `geometry.rs:773`, `:795`, `:817`, `:849` | `vec2.zig` | A Zig caller assigns the result. | `vec2.zig:17-21` |
| `Mul<Vec2> for f64` | `geometry.rs:827-834` | `vec2.zig` | Upstream defines it as `other * self`, which `Vec2.scale` computes. | `vec2.zig:22-24` |
| `MulAssign for Affine` | `geometry.rs:184-189` | `affine.zig` | A Zig caller assigns the result of `mul`. | `docs/19:1224`, restated for the geometry modules at `point.zig:32-34` |
| `Debug`, `PartialOrd`, `Ord` and `Hash` from the derive on `Flag` | `lib.rs:796` | `table.zig` | The port declares no `format` for `Flag`, no ordering and no digest. A flag reaches a writer through `@tagName` at `node.zig:290`. | not recorded in `table.zig` |
| `serde`, `schemars` and `enumn::N` attributes on `Flag` | `lib.rs:797-799` | `table.zig` | The port generates no code for another language. | `docs/30-port-design.md` section 2.2 |
| `Debug`, `PartialOrd`, `Ord` and `Hash` from the derive on `PropertyId` | `lib.rs:888` | `table.zig` | The port renders a property id through `@tagName` at `node.zig:318` and orders the store by `@intFromEnum`, so it declares no `format`, no ordering and no digest. | not recorded in `table.zig` |
| `serde`, `schemars` and `enumn::N` attributes on `PropertyId` | `lib.rs:889-891` | `table.zig` | The port generates no code for another language. | `docs/30-port-design.md` section 2.2 |
| variant `Unset` | `lib.rs:1007-1008` | `table.zig` | A sorted slice needs no "no slot" byte, so absence is a `null` from `Properties.get`, and with 87 tags `PropertyId` cannot hold 87. | `table.zig:45-51` |
| the `Box` in `Affine(Box<Affine>)` and `TextSelection(Box<TextSelection>)` | `lib.rs:881`, `:883` | `table.zig` | A pointer payload needs a recursive teardown and costs one allocation per node per update for a type the union holds inline. | `table.zig:52-57` |
| `struct PropertyIndices` and `impl Default for PropertyIndices` | `lib.rs:1060-1068` | `table.zig` | The store holds a sorted slice of id and value pairs, so the slot array and the sentinel byte that indexed it are both gone. | `table.zig:45-51` |
| `fn value_at` | `lib.rs:1076-1082` | `table.zig` | It maps a slot index to a value, and the port has no slot index. | `table.zig:45-51` |
| the slot-position comparison in `impl PartialEq for Properties` | `lib.rs:1084-1094` | `table.zig` | A sorted slice makes the comparison structural, and the 0.25.0 change that reuses property buffers on clone broke the slot correspondence upstream compared through. | `table.zig:58-63` |
| `Debug` from the derive on `Properties` | `lib.rs:1070` | `table.zig` | The port declares no `format` for the store. `Node.format` writes each entry through `PropertyValue.format` at `node.zig:313-321`. | not recorded in `table.zig` |
| `Default` from the derive on `Properties` | `lib.rs:1070` | `table.zig` | A default store would have to name an allocator, so the port spells the constructor `init(gpa)`. | `table.zig:1354-1355` |
| `impl Serialize for Properties`, `PropertiesVisitor`, `impl Deserialize for Properties`, `impl JsonSchema for Properties`, and the four `macro_rules!` at `:2794`, `:2806`, `:3019` and `:3029` | `lib.rs:2793-3160` | `table.zig` | The port carries no serializer and generates no schema. | `docs/30-port-design.md` section 2.2 |

Twelve rows above record no reason in the dropping module's own doc comment.
That is a finding, not a gap in the register: the deletion is real and the ledger
states it. Closing it means adding the reason to the module doc comment, not to
this document.

## 7. The additions register

One row per Zig item with no upstream counterpart. The reason column names the
decision that required it.

| Zig item | Purpose | The decision that required it |
|---|---|---|
| `Point.format`, `Size.format`, `Rect.format` as members at `src/schema/geometry/point.zig:91`, `size.zig:65`, `rect.zig:212` | They are the upstream `fmt::Debug` impls. | Zig reaches a value through `value.format(writer)` under the `{f}` specifier, so a type nested in another printable value only formats if `format` is a member. Recorded at `point.zig:10-11` and `:82-87`. |
| `Rect.formatOriginSize` at `rect.zig:227` | It is the alternate arm of the upstream `fmt::Debug` for `Rect` at `geometry.rs:380-386`. | Rust reaches that arm through `f.alternate()`. Zig has no alternate flag, so the port exposes a second named member and reaches it with `std.fmt.alt`. Recorded at `rect.zig:221-223`. |
| `nodeIdFormat` at `src/schema/ids.zig:84` | It is the upstream `fmt::Debug` for `NodeId` at `lib.rs:731-735`. | It sits at file scope because the flat re-export in `schema/root.zig` makes a bare `format` ambiguous between modules. Recorded at `ids.zig:9-11`. |
| `nodeIdFromContent`, `nodeIdToContent`, `treeIdFromBytes`, `treeIdToBytes` at `ids.zig:69`, `:75`, `:122`, `:128` | The four conversions in and out of the two identity types. | Rule P1. Upstream writes them as `From` impls, which Zig has not. |
| `NodeId.eql`, `NodeId.lessThan`, `NodeId.hash`, `TreeId.eql`, `TreeId.lessThan`, `TreeId.hash` at `ids.zig:45`, `:51`, `:62`, `:99`, `:105`, `:110` | The equality, ordering and digest that four derives gave upstream. | Zig rejects `==` for a struct and has no `Hash` derive. Each method takes `self`, so each stays a member. |
| `NarrowError` and `toI32Checked` at `rect.zig:276` and `:288` | One named checked conversion from `f64` to `i32`. | Upstream narrows with `as` at `adapters/atspi-common/src/rect.rs:31` and `adapters/android/src/node.rs:247`, and `as` saturates, so a copy would publish a wrong rectangle on a large display. Required by `docs/19:1293-1297`. Recorded at `rect.zig:281-287`. |
| `ScaleAxes` at `affine.zig:93` | The two per-axis scale factors `affineScaleNonUniform` takes. | Two bare `f64` arguments cannot say which axis is which, and a transposed pair still looks like a valid map. Recorded at `affine.zig:86-92`. |
| `actionCount` at `action.zig:91` | The bit count of a full mask and the bound on every walk over the domain. | `AGENTS.md:57-58` asks for a named bound on every loop. Recorded at `action.zig:89-90`. |
| `actionSetContains`, `actionSetUnion`, `actionSetDifference` at `action.zig:128`, `:134`, `:140` | Set operations on the `u32` mask. | The mask is the C ABI type, so a consumer needs the set operations without reaching for `std.meta`. |
| `actionSetMembers` at `action.zig:152` | It is upstream `action_mask_to_action_vec` at `lib.rs:390-400`. | It fills a caller buffer and returns the filled prefix, so the port never allocates. The bound is `actionCount` and the doc names it at `action.zig:146-151`. |
| the 13 `pub const count: usize` at `src/schema/node_enums.zig:28`, `:39`, `:55`, `:71`, `:83`, `:101`, `:115`, `:127`, `:141`, `:156`, `:167`, `:176`, `:189` | The tag count of each of the thirteen types. | A reader must not count variants to learn the bound of a loop. |
| the 13 `<type>FromInt` gates at `node_enums.zig:205`, `:215`, `:227`, `:238`, `:249`, `:260`, `:275`, `:286`, `:297`, `:310`, `:324`, `:336`, `:346` | Each turns one wire byte into one tag or rejects it. | The C seam and the D-Bus codec each receive one of these bytes and neither may trust it. `std.meta.intToEnum` does not check in `ReleaseFast`. Recorded at `node_enums.zig:198-201`. |
| `VariantCount` and `variant_counts` at `node_enums.zig:359` and `:369`, and the `comptime` sweep at `:385-415` and `:437-451` | They pin each tag count, each one-byte layout and each discriminant against its index. | `AGENTS.md:106-109` asks for a comptime sweep over every enumerable domain. The table names each type, so a compile error names the enum that moved. |
| `scrollUnitToStaticStr`, `scrollUnitFromInt`, `scrollHintToStaticStr`, `scrollHintFromInt` at `src/schema/scroll_enums.zig:47`, `:59`, `:72`, `:88` | The tag spelling and the checked byte-to-tag conversion for the two scroll enums. | `docs/10-accesskit-core.md:837-838` records the wire spellings, and upstream declares no conversion. Recorded at `scroll_enums.zig:42-46` and `:54-58`. |
| `CustomAction.InitError`, `CustomAction.init` and `CustomAction.deinit` at `src/schema/values.zig:50`, `:68`, `:80` | The allocation and the release of the owned description. | `AGENTS.md:280-282`: a lifetime becomes a parameter. Zig has no `Drop`. The allocator is a parameter at both ends and the module stores none. Recorded at `values.zig:4-6`. |
| `TextPosition.compare` and `TextSelection.compare` at `values.zig:138` and `:177` | A total order that reports `null` for two positions in different text runs. | The port stores a sorted slice, so it needs an order for the key. Upstream reports the same case the same way for the borrowed type it exposes to adapters, at `accesskit_consumer/src/text.rs:583-592`. Recorded at `values.zig:127-137` and `:170-176`. |
| the `eql` methods on all five `values.zig` types at `values.zig:92`, `:122`, `:165`, `:198`, `:220` | The equality that four derives gave upstream. | Zig rejects `==` for a struct. Recorded at `values.zig:9-11`. |
| `extern struct` on `TextPosition` and `TextSelection` at `values.zig:110` and `:155` | The field order is a contract, because `accesskit_text_position` and `accesskit_text_selection` declare it and `ActionData` carries the value in an `extern union`. | A plain `struct` lets the compiler reorder its fields, and an `extern union` cannot hold a plain struct at all. Recorded at `values.zig:106-109` and `:151-154`. |
| `extern struct` on `NodeId` and `TreeId` at `ids.zig:41` and `:93` | One scalar for `NodeId` and 16 bytes with no padding for `TreeId`. | `accesskit-c/include/accesskit.h:686` and `:708` declare both, and only `extern` pins the field order. Recorded at `ids.zig:132-146`. |
| the `coeffs` field on `Affine` at `affine.zig:46`, and `value` and `bytes` on `NodeId` and `TreeId` at `ids.zig:42` and `:96` | Named fields where upstream has a tuple struct with no field name. | `@offsetOf` and `@sizeOf` assertions need a name to name. Recorded in the layout blocks at `affine.zig:49-59` and `ids.zig:132-146`. |
| `Flag.count` at `table.zig:150`, `flagCount` at `:159` and the `comptime` block at `:153-156` | The 18 flag count and the bound on every walk over the flag domain, pinned at compile time. | `AGENTS.md:57-58` asks for a named bound on every loop and `:106-109` asks for a comptime sweep over every enumerable domain. Recorded at `table.zig:149`, `:158` and `:153-156`. |
| `flagSetContains` at `table.zig:171`, `flagSetUnion` at `:177` and `flagSetDifference` at `:182` | Set operations on the `u32` flag mask. | `flag_methods!` at `lib.rs:1170` inlines the mask test and the two mask writes. The mask is the C ABI type, so a consumer needs the three without reaching for `std.meta`, the same reason `action.zig` carries its own. |
| `flagSetMembers(flag_set, out)` at `table.zig:191` | It is upstream `action_mask_to_action_vec` at `lib.rs:390-400` applied to the flag mask, which upstream never wrote. | It fills a caller buffer and returns the filled prefix, so the port never allocates. The bound is `flagCount` and the doc names it at `table.zig:186-190`. |
| `propertyIdTagCount` at `table.zig:326` and `propertyIdFromInt` at `:332` | The tag count and the checked byte-to-tag gate for one property. | The C seam and the D-Bus codec each receive one of these bytes and neither may trust it, the same reason the thirteen `node_enums.zig` gates exist. Recorded at `table.zig:325` and `:328-331`. |
| `PropertyValueTag` at `table.zig:538`, `PropertyValue.getTag` at `:388` and `PropertyValue.deinit` at `:399` | The tag type of the payload union, a checked tag reader and one release. | A Zig union names no tag type of its own, and it has no `Drop`. Reading the tag through a member keeps every switch over the payload domain exhaustive. Recorded at `table.zig:537`, `:382-387` and `:392-398`. |
| `PropertyValuePayloadType` at `table.zig:558`, `propertyValueTagCount` at `:596` and `propertyValueFrom` at `:605` | The payload type of a tag, the size of the tag domain, and a constructor that reads one from the other. | `propertyValueFrom` pairs a payload with a tag at compile time, so a caller that pairs them wrongly is a compile error. Recorded at `table.zig:553-557` and `:592-604`. |
| the `comptime` layout block at `table.zig:540-551` | `@sizeOf(PropertyValue)` is 56 at alignment 8 and the tag type is one byte. | `AGENTS.md:56`. `docs/10-accesskit-core.md:670` predicts 40 by naming `Rect` the largest payload; it is not, because upstream boxes `Affine` and this port does not. Recorded at `table.zig:532-539`. |
| the private helpers `sameOwnedBuffer` at `table.zig:791`, `sameListBuffer` at `:831`, `deinitActions` at `:839`, `eqlNodeIds` at `:844`, `eqlActions` at `:852`, `cloneList` at `:860` and `cloneActions` at `:871` | The release, the equality and the clone each owned payload needs. | Zig has no `Drop`, no derived `PartialEq` and no `clone_from` for these types, so each behaviour upstream's derives and `impl Clone` gave is a named private function. |
| `Property` at `table.zig:886` with `deinit` at `:891`, `PropertyDescriptor` at `:899`, `property_descriptors` at `:916`, `propertyDescriptorCount` at `:1033`, `propertyIdCount` at `:1037`, `property_value_tags_by_id` at `:1042`, `propertyDescriptor` at `:1050`, `propertyValueTagOf` at `:1055`, `property_counts_by_tag` at `:1068` and `PropertyPayloadType` at `:1078` | The one home of the id-to-payload relation, plus the two run-time projections derived from it and the `comptime` bound every walk over the property domain uses. | Upstream wrote that relation three times, in the `PropertyId` block comments, the deserializer and the schemars output, and held an id array beside a value array, never a pair. `propertyIdCount` is also the loop bound `AGENTS.md:57-58` asks for. Recorded at `table.zig:905-915`, `:1031-1041`, `:1048-1057` and `:1059-1077`. |
| `Properties.deinit` at `table.zig:1365`, `Properties.count` at `:1372` and the private `insertionIndex` at `:1557` | One release for the store, its size, and the binary search that finds a property's position. | Zig has no `Drop`. `count` and `insertionIndex` exist because the store is a slice, so a caller may want a position rather than a value. Recorded at `table.zig:1360-1364`, `:1371` and `:1556`. |
| `Family` at `table.zig:1129`, `familyCount` at `:1141`, `familyTags` at `:1151`, `family_by_tag` at `:1184`, the private `declaresId` at `:1202`, `assertFamilyReachable` at `:1226` and `assertTagsPartitioned` at `:1314` | The partition of the payload tags across the seven accessor families, and the four compile-time claims that make "every property has an accessor" a build-time fact. | Each descriptor row names an id and a payload type and nothing else, so every check over the table alone passes for a property with a row and no getter. Only the owning family knows which properties it publishes accessors for, so the per-family half of the claim lives in the family module. Recorded at `table.zig:1082-1122`, `:1124-1150`, `:1177-1183` and `:1209-1225`. |

## 8. The invariants that survive the translation

A symbol map says the names were carried. This table says the behaviour was
carried. One row per upstream invariant, with the upstream line that
establishes it and the Zig line that asserts it.

| Invariant | Upstream | Zig assertion |
|---|---|---|
| `Affine` is 48 bytes at alignment 8 with `coeffs` at offset 0, because the C type is `struct { double _0[6]; }` | `geometry.rs:21-22` | `affine.zig:53-56`, and the test at `affine.zig:252-257` |
| `Affine::inverse` produces NaN when the determinant is zero, and reports no error | `geometry.rs:98` | `affine.zig:318-324` |
| `(A * B) * v == A * (B * v)`, so `mul` composes so the right operand applies first | `geometry.rs:50-51` | `affine.zig:331-340` and the round trip at `:357-373` |
| `transform_rect_bbox` returns a rectangle with a non-negative width and height | `geometry.rs:117` | `affine.zig:402-414` |
| `transform_rect_bbox` is the transformed rectangle itself when the map is axis-aligned | `geometry.rs:114-115` | `affine.zig:388-400` |
| `is_finite` and `is_nan` are different questions: an infinite coefficient is finite-false and nan-false | `geometry.rs:126-146` | `affine.zig:446-459` |
| `Point` is 16 bytes at alignment 8, `x` at 0 and `y` at 8 | `geometry.rs:211-212` | `point.zig:126-129`, and the test at `:135-140` |
| `Point::ZERO` and `Point::ORIGIN` hold the same value | `geometry.rs:221`, `:224` | `point.zig:153-157` |
| `Rect` is 32 bytes at alignment 8 with the four coordinates at 0, 8, 16 and 24 | `geometry.rs:336-337` | `rect.zig:38-43`, and the test at `:296-306` |
| Nothing forbids a negative width or height, so `width` and `size` report one on an inverted box | `geometry.rs:440`, `:448` | `rect.zig:330-343` |
| `from_points` and `from_origin_size` return a rectangle with a non-negative width and height, whichever order the two points arrive in | `geometry.rs:409`, `:419` | `rect.zig:345-357` and `:436-441` |
| `abs` keeps the extents and orders the corners | `geometry.rs:493-497` | `rect.zig:330-343` |
| `is_empty` is true only for a zero area, and a negative area is not emptiness | `geometry.rs:509-511` | `rect.zig:330-343` |
| `contains` excludes both far edges, so a zero-area box claims no point, not even a point on its own stored corner | `geometry.rs:517-521` | `rect.zig:319-328` |
| `union_pt` includes the perimeter of a zero-area rectangle, so a succession of calls over a series of points encloses every one | `geometry.rs:536-542` | `rect.zig:319-328` and `:403-414` |
| `intersect` always returns a non-negative width and height, and two boxes touching along an edge intersect to a zero-area box on that edge | `geometry.rs:552-563` | `rect.zig:359-366` and `:381-391` |
| `Size` is 16 bytes at alignment 8 with `width` at 0 and `height` at 8 | `geometry.rs:570-571` | `size.zig:90-98` |
| `Vec2::div` multiplies by the reciprocal, so it differs by one unit in the last place from a true divide | `geometry.rs:839-841` | `vec2.zig:175-195`, and the contrast with `Size.divide` at `size.zig:140-150` |
| `Vec2` is 16 bytes at alignment 8 with `x` at 0 and `y` at 8 | `geometry.rs:716-717` | `vec2.zig:107-110` |
| `Role` is ordered by expected usage frequency, because a variable-length integer encoding spends fewer bytes on the roles that occur often | `lib.rs:42-46` | `role.zig:344-346` pins every discriminant to its index, and `:357-362` pins three anchors |
| `Action` has 22 variants and the mask gives each one bit | `lib.rs:289-350`, and the count at `lib.rs:3508` | `action.zig:97-108`, and the test at `:163-169` |
| The `Action` mask bits are dense, so the C header numbers the members by position with no gap | `lib.rs:362-386` | `action.zig:113` |
| `Action::n` stops at the first discriminant that names no variant, so a stray high bit in a mask does not become a member | `lib.rs:385` | `action.zig:241-252` |
| `action_mask_to_action_vec` pushes the members in ascending discriminant order | `lib.rs:390-400` | `action.zig:225-239` |
| Each of the thirteen property enums is one byte and its discriminants are its declaration indices | `lib.rs:402-693` | `node_enums.zig:385-415`, and the thirteen tests at `:470-562` |
| Each `<type>FromInt` gate answers every byte the port writes and refuses the byte past the last tag | the gate is an addition, so no upstream line | `node_enums.zig:437-451` |
| `Toggled` from a `bool` never reaches `Mixed`, because the `bool` domain is two values and the tag domain is three | `lib.rs:492-500` | `node_enums.zig:192-196` and `:494-497` |
| `ScrollUnit` and `ScrollHint` are one byte and their discriminants are their declaration indices, which the C header constants fix in the same order | `lib.rs:3270-3271`, `:3290-3291` | `scroll_enums.zig:106-119` |
| `NodeId` is one unsigned 64-bit scalar, because the C type is a `uint64_t` | `lib.rs:715`, and `accesskit-c/include/accesskit.h:686` | `ids.zig:135-139` |
| `TreeId` is 16 bytes at alignment 1 with `bytes` at offset 0, so the struct adds no padding | `lib.rs:745`, and `accesskit-c/include/accesskit.h:708` | `ids.zig:143-145` |
| `NodeId` prints as `#` followed by the decimal content, and the widest content loses no digit | `lib.rs:731-735` | `ids.zig:189-201` |
| Every byte of a `TreeId` is significant | `lib.rs:741` | `ids.zig:216-226` |
| `TextPosition` is 16 bytes at alignment 8 with the node id first, because `accesskit_text_position` declares it that way | `lib.rs:771-773` | `values.zig:334-339` |
| `TextSelection` is 32 bytes at alignment 8 with the anchor first, because `accesskit_text_selection` declares it that way | `lib.rs:784-789` | `values.zig:341-346` |
| A selection with no extent is a caret, and then `anchor` equals `focus` | `lib.rs:785-788` | `values.zig:444-454` |
| Two positions in different text runs are not ordered, whatever their indices say | `accesskit_consumer/src/text.rs:583-592`, as cited at `values.zig:133` | `values.zig:398-408` and `:422-432` |
| A backwards selection is ordered, not rejected | `lib.rs:790-793` | `values.zig:434-442` |
| `CustomAction` equality compares the description bytes, not the buffer address | `lib.rs:756` | `values.zig:279-303` |
| `Color` is four bytes and `TextDecoration` is five, both at alignment 1 | `lib.rs:833`, `:846` | `values.zig:348-362` |
| A failing `CustomAction.init` copies nothing and leaves no allocation to release | `lib.rs:763` | `values.zig:235-244` and `:246-264` |
| `PropertyId` carries 87 discriminants and no sentinel, so the byte 87 names no property | `lib.rs:1007-1008` and `:1062` | `table.zig:1641-1642`, and the tests at `:1744-1752` and `:1754-1760` |
| Every descriptor row names a tag its owning family publishes accessors for, so a row with no getter is a compile error | no upstream line: the 23 `macro_rules!` at `lib.rs:1170-1778` generated the accessors and had no separate reachability claim | `assertTagsPartitioned` at `table.zig:1314-1331` and `assertFamilyReachable` at `:1226-1307`, called once per family from the seven `props/` modules and once from `table.zig:1649` |
| A cleared property is absent rather than a placeholder, so it compares equal to one that was never set | `lib.rs:3407-3414` | `Properties.clear` at `table.zig:1463-1467`, and the tests at `:1904-1918` and `:1920-1932` |
| Two stores holding the same properties compare equal whatever order either was written in | `lib.rs:3392-3405` | `Properties.eql` at `table.zig:1478-1485`, and the tests at `:1934-1963` and `:1965-1998` |
| A clone reuses the destination's buffers and drops what the source no longer holds | `lib.rs:3436-3461` | `Properties.cloneInto` at `table.zig:1515-1554`, and the tests at `:2139-2160` and `:2162-2190` |
| A failed write leaves the store exactly as it was and hands the value back to the caller | no upstream line: Rust allocates through a thread-local global and aborts rather than returning | `table.zig:1413-1414` and `:1436-1439`, and the tests at `:2021-2046`, `:2048-2071` and `:2073-2115` |
| `PropertyValue` equality reads payload bytes and never buffer addresses, and a NaN payload compares unequal to itself as the derived `PartialEq` did | `lib.rs:855` | `PropertyValue.eql` at `table.zig:444-477`, and the tests at `:2278-2296` and `:2313-2317` |
| `getOrInsert` appends in place, so a list pusher is amortised O(1) rather than quadratic | `lib.rs:1122-1136` | `Properties.getOrInsert` at `table.zig:1415-1427`, and the test at `:2000-2019` |
| `PropertyValue` is 56 bytes at alignment 8 with a 29-value one-byte tag, where `docs/10-accesskit-core.md:670` predicts 40 by naming `Rect` the largest payload | `lib.rs:856-886`, boxed at `:881` and `:883` | `table.zig:540-551`, and the test at `:1820-1829` |
| Each of the 18 flag bit positions is one bit, the positions are dense, and the discriminant is the bit position | `lib.rs:802-819` and `:823` | `flagMask` at `table.zig:166-168`, and the tests at `:2346-2365` and `:2367-2379` |
| An owned payload is released exactly once, whether the store is released normally, twice, or a value is cloned into itself | no upstream line: Rust frees in `Drop` | `PropertyValue.deinit` at `table.zig:399-435` and `deinitActions` at `:839-842`, and the tests at `:2139-2160`, `:2218-2252` and `:2254-2276` |

## 9. What this ledger does not cover

This section read: "The property modules under `src/schema/props/` and three schema
modules are still being written." All twelve are written. A count over the tree on
2026-10-05 gives each one, and every one sits in the import graph from
`src/root.zig`, so the `test` step analyses all twelve.

| Module | Lines | `test "` declarations |
|---|---:|---:|
| `src/schema/props/table.zig` | 2404 | 31 |
| `src/schema/props/numbers.zig` | 799 | 29 |
| `src/schema/props/ids.zig` | 756 | 23 |
| `src/schema/props/enums.zig` | 962 | 20 |
| `src/schema/update.zig` | 1022 | 19 |
| `src/schema/props/colors.zig` | 550 | 16 |
| `src/schema/props/vectors.zig` | 813 | 15 |
| `src/schema/handlers.zig` | 367 | 11 |
| `src/schema/props/option.zig` | 455 | 11 |
| `src/schema/node.zig` | 550 | 9 |
| `src/schema/props/flags.zig` | 456 | 5 |
| `src/schema/props/strings.zig` | 750 | 4 |

Eleven of the twelve modules in the table above carry no row in this document,
and nothing in this document is evidence about them. What is missing is rows, not
files. `src/schema/props/table.zig` is rowed in section 5. What each of the other
eleven still needs before it can be ledgered is below.

| Module | What it owns upstream | What it still needs before it can be ledgered |
|---|---|---|
| `src/schema/props/flags.zig` | the 18 flag properties at `lib.rs:802-819` and their 18 one-bit accessors | One row per flag, one row per accessor, and the bit-position rule. |
| `src/schema/props/ids.zig` | the 15 node-id properties | One row per property, per accessor, and the borrow and invalidation statement on each returned reference. |
| `src/schema/props/strings.zig` | the 21 string properties | One row per property, the owner rule for every allocation, and the `errdefer` on each setter that owns an allocation. |
| `src/schema/props/numbers.zig` | the 22 number properties | One row per property and per accessor, and the `f32` to `f64` widening on each read. |
| `src/schema/props/colors.zig`, `src/schema/props/vectors.zig` | the 6 colour and decoration properties and the 5 list properties | One row per property, and the owner rule for every list. |
| `src/schema/props/enums.zig`, `src/schema/props/option.zig` | the 14 boolean and enum properties and the 4 option properties | One row per property, and the borrow rule for the two option payloads that return a pointer. |
| `src/schema/node.zig` | `Node` at `lib.rs:1107` and its 11 written methods | One row per method, and the geometry and text queries it forwards. |
| `src/schema/update.zig` | `TreeInfo` at `lib.rs:3169`, the deprecated `Tree` alias at `:3179`, `TreeUpdate` at `:3208`, `ActionData` at `:3305`, `ActionRequest` at `:3328` | One row per type and per field, and the deletion row for the `Tree` alias, which `docs/23-core-boundary.md` section 7.6 already requires. |
| `src/schema/handlers.zig` | the three application traits at `lib.rs:3336`, `:3362` and `:3376` | One row per trait method, and the conversion of each borrowed argument into a named pointer. |

One item sits at the edge of this ledger and is named here rather than rowed,
so no reader thinks it was missed.

| Item | Where it sits | Why it has no row |
|---|---|---|
| `pub use uuid::Uuid` at `lib.rs:32` and `pub use geometry::{…}` at `lib.rs:35` | above the first in-scope range | The five geometry types are rowed under their own modules. The `Uuid` re-export is rowed in section 6 as dropped. |

## 10. Reconciliation

Four counts close this ledger, and each is a count of rows in this document.

| Check | Number |
|---|---:|
| Rows in the deletions register, section 6 | 42 |
| Rows in section 6 whose reason the dropping module does not record in its own doc comment | 12 |
| Rows in the additions register, section 7 | 31 |
| Rows in the invariants table, section 8 | 51 |

Those twelve rows are the one open item this ledger finds. They fall in nine
module doc comments: `affine.zig`, `vec2.zig`, `rect.zig`, `size.zig`,
`role.zig`, `action.zig`, `ids.zig`, `values.zig` and `props/table.zig`. Closing
them means one line in each doc comment. It does not mean a new row here.
