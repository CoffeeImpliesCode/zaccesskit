# 19. Geometry and text

Consumed by `docs/30-port-design.md` (the port design picks the Zig shapes), by
`docs/31-c-abi-design.md` (the C declarations to reproduce), and by
`docs/50-verification.md` (the test vectors in section 7).

All paths are relative to these read-only trees.

| Tree | Commit | Version |
|---|---|---|
| `/tmp/scratch/accesskit` | `466e24e252103f4d82bd6fbab98141b551e46e0c` | core crate 0.25.1 |
| `/tmp/scratch/accesskit-c` | `8b6ed37c20ed4c59390e253407983333053662ba` | 0.23.1 |

Toolchain used for the layout numbers in sections 2 and 3: Zig `0.16.0`, read
from the anyzig shim in the probe log quoted below, and `cc (SUSE Linux) 15.3.0`.

## 1. The geometry types

The whole core geometry module is `accesskit/src/geometry.rs`, 867 lines. It is
derived from kurbo (`accesskit/src/geometry.rs:6-10`). The module is declared and
re-exported at `accesskit/src/lib.rs:34-35`:

```rust
mod geometry;
pub use geometry::{Affine, Point, Rect, Size, Vec2};
```

Every type is `#[repr(C)]` and every field is `f64`. There is no `f32`, no
integer coordinate, and no optional coordinate anywhere in the module.

### 1.1 `Affine`

| Item | Path | Fields or result | Semantics |
|---|---|---|---|
| type | `accesskit/src/geometry.rs:21-22` | one tuple field `[f64; 6]` | 2D affine transform, coefficients in the order `a b c d e f` |
| `IDENTITY` | `accesskit/src/geometry.rs:26` | `Affine([1,0,0,1,0,0])` | built from `scale(1.0)` |
| `FLIP_Y` | `accesskit/src/geometry.rs:30` | `Affine([1,0,0,-1,0,0])` | converts y-up to y-down |
| `FLIP_X` | `accesskit/src/geometry.rs:33` | `Affine([-1,0,0,1,0,0])` | mirror on x |
| `new(c)` | `accesskit/src/geometry.rs:53` | `Affine(c)` | raw coefficients |
| `scale(s)` | `accesskit/src/geometry.rs:59` | `[s,0,0,s,0,0]` | uniform scale |
| `scale_non_uniform(s_x, s_y)` | `accesskit/src/geometry.rs:66` | `[s_x,0,0,s_y,0,0]` | per-axis scale |
| `translate(p)` | `accesskit/src/geometry.rs:72` | `[1,0,0,1,p.x,p.y]` | translation, takes anything convertible to `Vec2` |
| `map_unit_square(rect)` | `accesskit/src/geometry.rs:81` | `[w,0,0,h,x0,y0]` | maps the unit square onto `rect` |
| `as_coeffs()` | `accesskit/src/geometry.rs:87` | `[f64; 6]` | coefficient read-back |
| `determinant()` | `accesskit/src/geometry.rs:92` | `c0*c3 - c1*c2` | linear part determinant |
| `inverse()` | `accesskit/src/geometry.rs:99` | 6 coefficients | analytic inverse. Returns NaN when the determinant is 0, stated at `accesskit/src/geometry.rs:98` |
| `transform_rect_bbox(rect)` | `accesskit/src/geometry.rs:118` | `Rect` | bounding box of the four transformed corners, always non-negative width and height (`accesskit/src/geometry.rs:117`) |
| `is_finite()` | `accesskit/src/geometry.rs:128` | `bool` | all six coefficients finite |
| `is_nan()` | `accesskit/src/geometry.rs:139` | `bool` | any coefficient NaN |
| `Default::default()` | `accesskit/src/geometry.rs:149-152` | `IDENTITY` | note this differs from the other types |
| `Affine * Point` | `accesskit/src/geometry.rs:156-165` | `Point` | `x' = c0*x + c2*y + c4`, `y' = c1*x + c3*y + c5` |
| `Affine * Affine` | `accesskit/src/geometry.rs:168-182` | `Affine` | matrix product in the transposed convention |
| `Affine *= Affine` | `accesskit/src/geometry.rs:184-189` | in place | `*self = self.mul(other)` |
| `f64 * Affine` | `accesskit/src/geometry.rs:191-205` | `Affine` | scales every coefficient |

The matrix convention is documented in the source at
`accesskit/src/geometry.rs:37-48`:

```text
| a c e |
| b d f |
| 0 0 1 |
```

The source states that this is transposed against PostScript and Direct2D, and
that `(A * B) * v == A * (B * v)`. A port must keep this order. Reordering to
the Direct2D order changes the meaning of every wire transform.

### 1.2 `Point`

| Item | Path | Fields or result | Semantics |
|---|---|---|---|
| type | `accesskit/src/geometry.rs:211-217` | `x: f64`, `y: f64` | a position |
| `ZERO` | `accesskit/src/geometry.rs:221` | `(0, 0)` | |
| `ORIGIN` | `accesskit/src/geometry.rs:224` | `(0, 0)` | duplicate of `ZERO`, same value |
| `new(x, y)` | `accesskit/src/geometry.rs:228` | `Point` | `const fn` |
| `to_vec2()` | `accesskit/src/geometry.rs:234` | `Vec2` | reinterpretation |
| `From<(f64,f64)>` | `accesskit/src/geometry.rs:239-244` | `Point` | tuple in |
| `From<Point> for (f64,f64)` | `accesskit/src/geometry.rs:246-251` | tuple out | tuple out |
| `Point + Vec2` | `accesskit/src/geometry.rs:253-260` | `Point` | translate |
| `Point += Vec2` | `accesskit/src/geometry.rs:262-267` | in place | |
| `Point - Vec2` | `accesskit/src/geometry.rs:269-276` | `Point` | translate back |
| `Point -= Vec2` | `accesskit/src/geometry.rs:278-283` | in place | |
| `Point + (f64,f64)` | `accesskit/src/geometry.rs:285-292` | `Point` | tuple variant of the same |
| `Point += (f64,f64)` | `accesskit/src/geometry.rs:294-299` | in place | |
| `Point - (f64,f64)` | `accesskit/src/geometry.rs:301-308` | `Point` | |
| `Point -= (f64,f64)` | `accesskit/src/geometry.rs:310-315` | in place | |
| `Point - Point` | `accesskit/src/geometry.rs:317-324` | `Vec2` | difference, the only subtraction that yields a vector |
| `fmt::Debug` | `accesskit/src/geometry.rs:326-330` | `({x:?}, {y:?})` | `derive(Debug)` is not used on this type |

### 1.3 `Rect`

| Item | Path | Fields or result | Semantics |
|---|---|---|---|
| type | `accesskit/src/geometry.rs:336-346` | `x0: f64`, `y0: f64`, `x1: f64`, `y1: f64` | min/max corner form, not origin/size form |
| `From<(Point,Point)>` | `accesskit/src/geometry.rs:348-352` | `Rect` | delegates to `from_points` |
| `From<(Point,Size)>` | `accesskit/src/geometry.rs:354-358` | `Rect` | delegates to `from_origin_size` |
| `Rect + Vec2` | `accesskit/src/geometry.rs:360-367` | `Rect` | all four corners move together |
| `Rect - Vec2` | `accesskit/src/geometry.rs:369-376` | `Rect` | |
| `fmt::Debug` | `accesskit/src/geometry.rs:378-395` | two formats | `{alternate}` prints origin plus size |
| `ZERO` | `accesskit/src/geometry.rs:399` | `(0,0,0,0)` | zero area at the origin |
| `new(x0,y0,x1,y1)` | `accesskit/src/geometry.rs:403` | `Rect` | stores the arguments as given. It does **not** sort them |
| `from_points(p0,p1)` | `accesskit/src/geometry.rs:411` | `Rect` | calls `.abs()`, so the result is ordered |
| `from_origin_size(o,s)` | `accesskit/src/geometry.rs:421` | `Rect` | `from_points(o, o + s)`, calls `.abs()` |
| `with_origin(o)` | `accesskit/src/geometry.rs:428` | `Rect` | keeps size |
| `with_size(s)` | `accesskit/src/geometry.rs:434` | `Rect` | keeps origin |
| `width()` | `accesskit/src/geometry.rs:442` | `x1 - x0` | may be negative, stated at `accesskit/src/geometry.rs:440` |
| `height()` | `accesskit/src/geometry.rs:450` | `y1 - y0` | may be negative, stated at `accesskit/src/geometry.rs:448` |
| `min_x()` | `accesskit/src/geometry.rs:456` | `min(x0, x1)` | |
| `max_x()` | `accesskit/src/geometry.rs:462` | `max(x0, x1)` | |
| `min_y()` | `accesskit/src/geometry.rs:468` | `min(y0, y1)` | |
| `max_y()` | `accesskit/src/geometry.rs:474` | `max(y0, y1)` | |
| `origin()` | `accesskit/src/geometry.rs:483` | `Point(x0, y0)` | returns the stored `x0`, not the minimum. On an inverted rect this is the larger corner |
| `size()` | `accesskit/src/geometry.rs:489` | `Size(width(), height())` | may be negative on an inverted rect |
| `abs()` | `accesskit/src/geometry.rs:498` | `Rect` | orders the corners, same extents |
| `area()` | `accesskit/src/geometry.rs:505` | `w * h` | sign follows the inversion |
| `is_empty()` | `accesskit/src/geometry.rs:513` | `area() == 0.0` | a negative area is **not** empty, stated at `accesskit/src/geometry.rs:511` |
| `contains(p)` | `accesskit/src/geometry.rs:519` | `bool` | see the edge rule below |
| `union(other)` | `accesskit/src/geometry.rs:527` | `Rect` | per-axis min/max. Valid only for non-negative width and height, stated at `accesskit/src/geometry.rs:525` |
| `union_pt(pt)` | `accesskit/src/geometry.rs:543` | `Rect` | same, with one point. Includes the perimeter of zero-area rects, stated at `accesskit/src/geometry.rs:539-541` |
| `intersect(other)` | `accesskit/src/geometry.rs:557` | `Rect` | clamps `x1 = max(x1, x0)` and `y1 = max(y1, y0)`, so the result always has non-negative width and height |

### 1.4 `Size`

| Item | Path | Fields or result | Semantics |
|---|---|---|---|
| type | `accesskit/src/geometry.rs:570-576` | `width: f64`, `height: f64` | an extent, never a position |
| `ZERO` | `accesskit/src/geometry.rs:580` | `(0, 0)` | |
| `new(w,h)` | `accesskit/src/geometry.rs:584` | `Size` | `const fn` |
| `to_vec2()` | `accesskit/src/geometry.rs:591` | `Vec2` | width maps to x, height maps to y |
| `fmt::Debug` | `accesskit/src/geometry.rs:596-600` | `{w:?}W×{h:?}H` | |
| `Size *= f64` | `accesskit/src/geometry.rs:602` | in place | |
| `f64 * Size` | `accesskit/src/geometry.rs:612` | `Size` | `other * self`, so it delegates to `Mul<f64>` |
| `Size * f64` | `accesskit/src/geometry.rs:621` | `Size` | per-axis multiply |
| `Size /= f64` | `accesskit/src/geometry.rs:633` | in place | true division, per axis |
| `Size / f64` | `accesskit/src/geometry.rs:643` | `Size` | true division, per axis |
| `Size + Size` | `accesskit/src/geometry.rs:655` | `Size` | |
| `Size += Size` | `accesskit/src/geometry.rs:666` | in place | |
| `Size - Size` | `accesskit/src/geometry.rs:673` | `Size` | |
| `Size -= Size` | `accesskit/src/geometry.rs:684` | in place | |
| `From<(f64,f64)>` | `accesskit/src/geometry.rs:691` | `Size` | |
| `From<Size> for (f64,f64)` | `accesskit/src/geometry.rs:701` | tuple | |

Note the asymmetry: `Size / f64` divides (`accesskit/src/geometry.rs:643`), but
`Vec2 / f64` multiplies by the reciprocal (`accesskit/src/geometry.rs:836`, with
the note at `accesskit/src/geometry.rs:839-841` that this has different roundoff
behaviour). A Zig port must not merge these two.

### 1.5 `Vec2`

| Item | Path | Fields or result | Semantics |
|---|---|---|---|
| type | `accesskit/src/geometry.rs:716-722` | `x: f64`, `y: f64` | a translation or a difference |
| `ZERO` | `accesskit/src/geometry.rs:726` | `(0, 0)` | |
| `new(x,y)` | `accesskit/src/geometry.rs:730` | `Vec2` | `const fn` |
| `to_point()` | `accesskit/src/geometry.rs:736` | `Point` | reinterpretation |
| `to_size()` | `accesskit/src/geometry.rs:742` | `Size` | reinterpretation |
| `From<(f64,f64)>` | `accesskit/src/geometry.rs:747` | `Vec2` | |
| `From<Vec2> for (f64,f64)` | `accesskit/src/geometry.rs:754` | tuple | |
| `Vec2 + Vec2` | `accesskit/src/geometry.rs:761` | `Vec2` | |
| `Vec2 += Vec2` | `accesskit/src/geometry.rs:773` | in place | |
| `Vec2 - Vec2` | `accesskit/src/geometry.rs:783` | `Vec2` | |
| `Vec2 -= Vec2` | `accesskit/src/geometry.rs:795` | in place | |
| `Vec2 * f64` | `accesskit/src/geometry.rs:805` | `Vec2` | |
| `Vec2 *= f64` | `accesskit/src/geometry.rs:817` | in place | |
| `f64 * Vec2` | `accesskit/src/geometry.rs:827` | `Vec2` | `other * self` |
| `Vec2 / f64` | `accesskit/src/geometry.rs:836` | `Vec2` | multiply by `1/f64`, not a divide |
| `Vec2 /= f64` | `accesskit/src/geometry.rs:849` | in place | `mul_assign(other.recip())` |
| `-Vec2` | `accesskit/src/geometry.rs:856` | `Vec2` | |

### 1.6 The coordinate convention

| Property | Value | Evidence |
|---|---|---|
| Origin | top left of the tree container, for example the window | `accesskit/src/lib.rs:2516-2518` |
| Units | physical pixels, not logical points | `accesskit/src/lib.rs:2516-2518` |
| Y axis | top-down, so y grows downward | `accesskit/src/lib.rs:2518` |
| X axis | grows right | implied by `x0` being the "left edge" at `accesskit/src/geometry.rs:338` |
| Far edge | exclusive | `accesskit/src/geometry.rs:519-521` uses `>= x0`, `< x1`, `>= y0`, `< y1` |

The exact text at `accesskit/src/lib.rs:2516-2518` is: "AccessKit expects the
final transformed coordinates to be relative to the origin of the tree's container
(e.g. window), in physical pixels, with the y coordinate being top-down."

The far edge is **exclusive** for `contains`. This matters for the `union_pt`
contract at `accesskit/src/geometry.rs:539-541`, where a succession of `union_pt`
calls must enclose every point, and it matters for hit testing where two
adjacent boxes must not both claim a point on their shared edge.

Three traps a port must reproduce exactly:

1. `Rect.new` does not sort (`accesskit/src/geometry.rs:403`). Only
   `from_points` and `from_origin_size` sort, through `abs()`
   (`accesskit/src/geometry.rs:411`, `:421`, `:498`).
2. `origin()` returns the stored `x0` (`accesskit/src/geometry.rs:483`), not
   `min_x()` (`accesskit/src/geometry.rs:456`). On an inverted rect they differ.
3. `is_empty()` is `area() == 0.0` (`accesskit/src/geometry.rs:513`), so an
   inverted rect with area 3000 is not empty. Section 7 locks this.

### 1.7 How the properties use these types

| Property | Path | Type |
|---|---|---|
| `Transform` | `accesskit/src/lib.rs:2509-2521` | `Option<&Affine>`, plus `set_transform`, `clear_transform` |
| `Bounds` | `accesskit/src/lib.rs:2523-2533` | `Option<Rect>`, plus `set_bounds`, `clear_bounds` |
| `CharacterPositions` | `accesskit/src/lib.rs:2404` | `Vec<f32>`, offset of each character |
| `CharacterWidths` | `accesskit/src/lib.rs:2424` | `Vec<f32>`, advance width of each character |
| `CharacterLengths` | `accesskit/src/lib.rs:2353` | `Vec<u8>`, UTF-8 byte length per character |
| `WordStarts` | `accesskit/src/lib.rs:2384` | `Vec<u8>` |
| `TextDirection` | `accesskit/src/lib.rs:2474` | enum at `accesskit/src/lib.rs:439-442`. `clear_text_direction` writes `RightToLeft` |
| `TextSelection` | `accesskit/src/lib.rs:2536` | `Option<&TextSelection>` |
| `ActionData::ScrollToPoint` | `accesskit/src/lib.rs:3316` | `Point` in container coordinates |
| `ActionData::SetScrollOffset` | `accesskit/src/lib.rs:3319` | `Point` in the target node's own space |

Note that `CharacterPositions` and `CharacterWidths` are `f32`, not `f64`, even
though the enclosing `Rect` is `f64`. `accesskit_consumer` widens them at
`accesskit_consumer/src/text.rs:789-790`.

## 2. The ABI form

`accesskit-c/include/accesskit.h` is 3154 lines and is generated by `cbindgen`
from the Rust types. The geometry block sits at lines 930 to 1102.

| C type | Header lines | Rust source |
|---|---|---|
| `accesskit_affine` | `accesskit-c/include/accesskit.h:934-936` | `accesskit/src/geometry.rs:21-22` |
| `accesskit_rect` | `accesskit-c/include/accesskit.h:941-958` | `accesskit/src/geometry.rs:336-346` |
| `accesskit_opt_rect` | `accesskit-c/include/accesskit.h:965-968` | no Rust source, a cbindgen optional wrapper |
| `accesskit_point` | `accesskit-c/include/accesskit.h:998-1007` | `accesskit/src/geometry.rs:211-217` |
| `accesskit_vec2` | `accesskit-c/include/accesskit.h:1079-1088` | `accesskit/src/geometry.rs:716-722` |
| `accesskit_size` | `accesskit-c/include/accesskit.h:1093-1102` | `accesskit/src/geometry.rs:570-576` |

The declarations, verbatim:

```c
typedef struct accesskit_affine {
  double _0[6];
} accesskit_affine;                                              /* :934-936 */

typedef struct accesskit_rect {
  double x0;                                                      /* :945 */
  double y0;                                                      /* :949 */
  double x1;                                                      /* :953 */
  double y1;                                                      /* :957 */
} accesskit_rect;                                                /* :958 */

typedef struct accesskit_opt_rect {
  bool has_value;                                                 /* :966 */
  struct accesskit_rect value;                                    /* :967 */
} accesskit_opt_rect;                                            /* :968 */

typedef struct accesskit_point { double x; double y; } accesskit_point;   /* :998-1007 */
typedef struct accesskit_vec2  { double x; double y; } accesskit_vec2;    /* :1079-1088 */
typedef struct accesskit_size  { double width; double height; } accesskit_size; /* :1093-1102 */
```

### 2.1 No encoding and no tagged union in the geometry ABI

The geometry ABI carries no text and no encoding. Every field is `double`, and
the only non-floating field in the whole block is the `bool has_value` flag at
`accesskit-c/include/accesskit.h:966`. A grep of `accesskit-c/src/geometry.rs`
for `u16`, `char16`, `WCHAR`, `union`, `VARIANT` and `tag` returns no type
definition. The only hits are the function names `accesskit_rect_union`
(`accesskit-c/src/geometry.rs:168`) and `accesskit_rect_union_pt`
(`accesskit-c/src/geometry.rs:177`).

So no UTF-16 conversion exists on this ABI, and no `VARIANT` style tagged union
exists here either. Both questions matter because the Windows text adapter does
use a tagged union. Section 3.4 covers that case, and it does not reach the
geometry types.

Two cbindgen effects to note. The Rust tuple struct field `.0` becomes the
identifier `_0` (`accesskit-c/include/accesskit.h:935`), so the affine
coefficients are reached by the index only. The four doc comments in the Rust
source survive into the header, for example `accesskit-c/include/accesskit.h:942-944`
carries "The minimum x coordinate (left edge).".

The Rust side of the same ABI is `accesskit-c/src/geometry.rs`, 247 lines. It
exports 46 `#[unsafe(no_mangle)] pub extern "C"` functions:

| Rust symbol | `accesskit-c/src/geometry.rs` | Header |
|---|---|---|
| `accesskit_affine_identity` | `:9` | `:2414` |
| `accesskit_affine_flip_y` | `:14` | `:2416` |
| `accesskit_affine_flip_x` | `:19` | `:2418` |
| `accesskit_affine_scale` | `:24` | `:2420` |
| `accesskit_affine_scale_non_uniform` | `:29` | `:2422-2423` |
| `accesskit_affine_translate` | `:34` | `:2425` |
| `accesskit_affine_map_unit_square` | `:39` | `:2427-2428` |
| `accesskit_affine_determinant` | `:44` | `:2430` |
| `accesskit_affine_inverse` | `:49` | `:2432-2433` |
| `accesskit_affine_transform_rect_bbox` | `:54` | `:2435-2436` |
| `accesskit_affine_is_finite` | `:59` | `:2438` |
| `accesskit_affine_is_nan` | `:68` | `:2440` |
| `accesskit_affine_mul` | `:77` | `:2442-2443` |
| `accesskit_affine_transform_point` | `:82` | `:2445-2446` |
| `accesskit_point_to_vec2` | `:87` | `:2448` |
| `accesskit_point_add_vec2` | `:92` | `:2450-2451` |
| `accesskit_point_sub_vec2` | `:97` | `:2453-2454` |
| `accesskit_point_sub_point` | `:102` | `:2456-2457` |
| `accesskit_rect_new` | `:107` | `:2459-2460` |
| `accesskit_rect_from_points` | `:112` | `:2462-2463` |
| `accesskit_rect_from_origin_size` | `:117` | `:2465-2466` |
| `accesskit_rect_with_origin` | `:122` | `:2468-2469` |
| `accesskit_rect_with_size` | `:127` | `:2471-2472` |
| `accesskit_rect_getter_methods!` macro | `:131-156` | `:2474-2494` |
| `accesskit_rect_contains` | `:159` | `:2496-2497` |
| `accesskit_rect_union` | `:168` | `:2499-2500` |
| `accesskit_rect_union_pt` | `:177` | `:2502-2503` |
| `accesskit_rect_intersect` | `:186` | `:2505-2506` |
| `accesskit_rect_translate` | `:195` | `:2508-2509` |
| `accesskit_size_to_vec2` | `:200` | `:2511` |
| `accesskit_size_scale` | `:205` | `:2513-2514` |
| `accesskit_size_add` | `:210` | `:2516-2517` |
| `accesskit_size_sub` | `:215` | `:2519-2520` |
| `accesskit_vec2_to_point` | `:220` | `:2522` |
| `accesskit_vec2_to_size` | `:225` | `:2524` |
| `accesskit_vec2_add` | `:230` | `:2526-2527` |
| `accesskit_vec2_sub` | `:235` | `:2529-2530` |
| `accesskit_vec2_scale` | `:240` | `:2532-2533` |
| `accesskit_vec2_neg` | `:245` | `:2535` |

The `rect_getter_methods!` macro at `accesskit-c/src/geometry.rs:131-142` expands
to eleven functions from the table at `accesskit-c/src/geometry.rs:144-156`:
`width`, `height`, `min_x`, `max_x`, `min_y`, `max_y`, `origin`, `size`, `abs`,
`area`, `is_empty`. Each takes `*const Rect` and returns a default when the
pointer is null.

The null-pointer tolerance is an ABI rule, not a convenience. Every function that
takes a pointer checks for null and returns a typed default, for example
`accesskit-c/src/geometry.rs:59-65` returns `false` for both `is_finite` and
`is_nan`. A Zig port must reproduce the same defaults, and it must document them,
or a C caller that passes null gets different numbers than a C caller that does
not.

### 2.2 Size and alignment, and how the numbers were computed

The C side was compiled and run. The probe repeated the five struct definitions
from the header, printed `sizeof` and `_Alignof`, and carried six
`_Static_assert` lines so the build fails if any number below is wrong. Every
probe in this document ran under `/tmp/scratch/GeometryAndText/`.
That tree was removed after the run. Each probe is named where it appears, and
its command and its full output are recorded next to it, so a reader can rebuild
it from this document.

```
$ cc -std=c11 -O0 -Wall -Wextra -o cheader_probe cheader_probe.c
$ ./cheader_probe
accesskit_affine size=48 align= 8
accesskit_rect   size=32 align= 8
accesskit_point  size=16 align= 8
accesskit_vec2   size=16 align= 8
accesskit_size   size=16 align= 8
accesskit_opt_rect size=40 align= 8
accesskit_rect[4] size=128 align= 8
accesskit_affine[4] size=192 align= 8
accesskit_opt_rect[4] size=160 align= 8
double           size= 8 align= 8
bool             size= 1 align= 1
  offsetof(accesskit_rect, x0) = 0
  offsetof(accesskit_rect, y0) = 8
  offsetof(accesskit_rect, x1) = 16
  offsetof(accesskit_rect, y1) = 24
  offsetof(accesskit_affine, _0) = 0
  offsetof(accesskit_opt_rect, has_value) = 0
  offsetof(accesskit_opt_rect, value) = 8
$ cc --version | head -1
cc (SUSE Linux) 15.3.0
```

The working is the standard Itanium C ABI:

| Type | Derivation | Size | Align |
|---|---|---|---|
| `double` | IEEE-754 binary64 | 8 | 8 |
| `accesskit_point` | 2 fields, 8 bytes each, offsets 0 and 8. End at 16, which divides by 8, so no tail pad | 16 | 8 |
| `accesskit_vec2` | identical shape | 16 | 8 |
| `accesskit_size` | identical shape | 16 | 8 |
| `accesskit_rect` | 4 fields at offsets 0, 8, 16, 24. End at 32, divides by 8, no tail pad | 32 | 8 |
| `accesskit_affine` | `double[6]`, 6 × 8 = 48, offset 0 | 48 | 8 |
| `accesskit_opt_rect` | `bool` at 0 (1 byte, align 1). `accesskit_rect` needs align 8, so it starts at 8, not 1. End at 8 + 32 = 40. 40 divides by 8, no tail pad | 40 | 8 |

The array rows confirm there is no tail padding: `[4]` of `accesskit_rect` is
128 = 4 × 32, `[4]` of `accesskit_affine` is 192 = 4 × 48, and `[4]` of
`accesskit_opt_rect` is 160 = 4 × 40.

### 2.3 Is the C form layout compatible with the Rust form

Yes, on this target, and for a stated reason rather than by luck.

1. Every Rust geometry type carries `#[repr(C)`, at
   `accesskit/src/geometry.rs:21`, `:211`, `:336`, `:570` and `:716`. `repr(C)`
   pins field order, and Rust's C layout for `f64` is the same 8-byte,
   8-aligned object that C uses.
2. cbindgen copies the field order verbatim, as the header excerpt in section 2
   shows.
3. The computed offsets above match what `#[repr(C)]` on all-`f64` structs must
   produce: 0, 8, 16, 24.

The only difference is the name of the affine payload: `_0[6]` in C against an
unnamed tuple field in Rust. Names do not affect layout.

One ABI detail is not layout: `accesskit-c/src/geometry.rs:34`,
`:39`, `:44`, `:49`, `:54`, `:77`, `:82`, `:87`, `:107`, `:112`, `:117`, `:122`,
`:127`, `:195`, `:200`, `:205`, `:210`, `:215`, `:220`, `:225`, `:230`, `:235`,
`:240` and `:245` return small structs by value. On the SysV x86-64 ABI a
16-byte struct of two SSE doubles returns in `XMM0`, `accesskit_rect` in
`XMM0` and `XMM1`, and `accesskit_affine` in memory. `[INFERENCE]` I did not
verify the register assignment, because no C compiler call site was exercised.
A Zig `extern fn` returning `extern struct` by value uses the same classifier,
so no wrapper is needed. A Zig `callconv(.C)` function returning a plain `struct`
would not.

## 3. The Zig form

### 3.1 The proposed declarations

```zig
pub const Point = extern struct {
    x: f64,
    y: f64,
};

pub const Size = extern struct {
    width: f64,
    height: f64,
};

pub const Rect = extern struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
};

pub const Vec2 = extern struct {
    x: f64,
    y: f64,
};

pub const Affine = extern struct {
    coeffs: [6]f64,
};
```

Field names are `snake_case`: `x0`, `y0`, `x1`, `y1`, `width`, `height`, `x`,
`y`, `coeffs`. `x0` is a legal Zig identifier because a name may start with a
letter and then carry digits.

The Rust name `Affine([f64; 6])` has no field name. The port must give it one.
`coeffs` matches `as_coeffs` at `accesskit/src/geometry.rs:87`. The C name `_0`
is not usable in Zig as a public field name because it reads as "unused".

Type names are `PascalCase`, per the house naming rule in
`~/ozai/AGENTS.md` section 1. Zig 0.16.0 accepts a
capitalised type declaration. The probe compiled `pub const Rect = extern struct {...}`
and ran, output at section 3.4.

### 3.2 Why `extern struct` and not `packed struct` or a plain `struct`

| Choice | Verdict | Reason |
|---|---|---|
| `packed struct` | rejected | it does not compile for `Affine`, and it raises the alignment of the other four to 16 |
| plain `struct` | rejected for these five | it produces the right numbers here by luck of the field type, and it is free to reorder, which would break the ABI and the `f64` array casts |
| `extern struct` | required | it pins field order and padding to the C rules, and it is what a C caller and a `callconv(.C)` signature must agree on |

`packed struct` cannot hold the affine payload. Observed compile error from
Zig 0.16.0, probe at
`/tmp/scratch/GeometryAndText/layout.zig`:

```
layout.zig:16:45: error: packed structs cannot contain fields of type '[6]f64'
pub const PackedAffine = packed struct { c: [6]f64 };
                                            ^~~~~
layout.zig:16:45: note: type does not have a bit-packed representation
```

`packed struct` is also wrong on alignment. The same probe measured
`PackedPoint(packed): size=16 align=16` and `PackedRect(packed): size=32
align=16`. An alignment of 16 is larger than any C consumer expects and would
change the stride of `[4]Rect` from 128 to 128 bytes but force 16-byte
boundaries on every element. It is not what the header promises.

A plain `struct` differs from `extern struct` as soon as the fields are not all
`f64`. Probe output from the same run:

```
layout test: C size=12 align=4 | P size=8 align=4 | K size=8 align=8
```

where `C` is `extern struct { a: u8, b: u32, c: u8 }`, `P` is the same as a
plain `struct`, and `K` is the same as a `packed struct`. The plain form drops
the trailing byte and the following padding. For all-`f64` structs this
difference cannot appear, because no reordering saves space. That is the whole
reason plain `struct` is wrong: the safety depends on the field types staying
`f64` forever, and nothing enforces that.

`Point`, `Size`, `Vec2`, and `Rect` also appear inside other structures that
cross the ABI, for example `accesskit_c/src/lib.rs` property setters such as
`accesskit_node_set_bounds` at `accesskit-c/include/accesskit.h:2249-2250` take
`struct accesskit_rect` by value. A plain `struct` field inside an `extern
struct` is a compile error in Zig, so mixing the two kinds would not compile at
all. Using `extern struct` everywhere removes that class of mistake.

### 3.3 Size and alignment of the Zig form, with the working

Measured with Zig 0.16.0 using `@sizeOf`, `@alignOf` and `@offsetOf`. Probe at
`/tmp/scratch/GeometryAndText/layout.zig`.

```
$ zig run layout.zig
anyzig: .minimum_zig_version '0.16.0' pulled from '.../GeometryAndText/build.zig.zon'
anyzig: zig '0.16.0' already exists at '/tmp/cache/zig/p/N-V-__8AAFFSVRWqblwBIcA-Yqv-u7sbjsJoww8K0mWaHbmJ'
ZigPoint(extern): size=16 align=8
ZigSize(extern): size=16 align=8
ZigRect(extern): size=32 align=8
ZigVec2(extern): size=16 align=8
ZigAffine(extern): size=48 align=8
COptRect(extern): size=40 align=8
PlainPoint(struct): size=16 align=8
PlainRect(struct): size=32 align=8
PlainAffine(struct): size=48 align=8
PackedPoint(packed): size=16 align=16
PackedRect(packed): size=32 align=16
f64: size=8 align=8
bool: size=1 align=1
array [6]f64: size=48 align=8
Point offsets x=0 y=8
Rect offsets x0=0 y0=8 x1=16 y1=24
OptRect offsets has_value=0 value=8
Affine offsets c=0 c[3]=24
[1]Rect size=32 stride check @sizeOf(ZigRect)=32
[1]Affine size=48
[1]OptRect size=40
```

The arithmetic, field by field:

| Zig type | Field placement | End offset | Tail pad needed | Size | Align |
|---|---|---|---|---|---|
| `f64` | measured directly | | | 8 | 8 |
| `[6]f64` | 6 elements, stride 8, measured | 48 | none, 48 mod 8 = 0 | 48 | 8 |
| `Point` | `x` at 0, `y` at 8, measured | 16 | none, 16 mod 8 = 0 | 16 | 8 |
| `Size` | `width` at 0, `height` at 8 | 16 | none | 16 | 8 |
| `Vec2` | `x` at 0, `y` at 8 | 16 | none | 16 | 8 |
| `Rect` | `x0` at 0, `y0` at 8, `x1` at 16, `y1` at 24, measured | 32 | none, 32 mod 8 = 0 | 32 | 8 |
| `Affine` | `coeffs` at 0, so `coeffs[3]` at 24, measured | 48 | none | 48 | 8 |
| optional `Rect` | flag at 0 (1 byte, align 1), payload needs align 8 so it moves to 8, measured | 8 + 32 = 40 | none, 40 mod 8 = 0 | 40 | 8 |

Every Zig number equals the C number from section 2.1. The `[1]` rows prove
there is no hidden tail padding, because a one-element array has size equal to
the element stride only when the element size already satisfies the alignment.

The port must pin these at compile time. The house rules ask for comptime
relationship assertions, so the geometry module should carry:

```zig
comptime {
    std.debug.assert(@sizeOf(Point) == 16);
    std.debug.assert(@alignOf(Point) == 8);
    std.debug.assert(@sizeOf(Size) == 16);
    std.debug.assert(@alignOf(Size) == 8);
    std.debug.assert(@sizeOf(Vec2) == 16);
    std.debug.assert(@alignOf(Vec2) == 8);
    std.debug.assert(@sizeOf(Rect) == 32);
    std.debug.assert(@alignOf(Rect) == 8);
    std.debug.assert(@offsetOf(Rect, "x0") == 0);
    std.debug.assert(@offsetOf(Rect, "y1") == 24);
    std.debug.assert(@sizeOf(Affine) == 48);
    std.debug.assert(@alignOf(Affine) == 8);
    std.debug.assert(@sizeOf(OptionalRect) == 40);
    std.debug.assert(@alignOf(OptionalRect) == 8);
    std.debug.assert(@offsetOf(OptionalRect, "value") == 8);
}
```

These assertions are the port's substitute for a C oracle. They are not a
cross-check against upstream, they are a lock on this target.

### 3.4 The tagged union case, and why it does not reach geometry

One platform dependency upstream does not bind through `translate-c`. The
Windows `VARIANT` is a C tagged union. Zig has no direct equivalent, so
upstream wraps it:

| Item | Path |
|---|---|
| `pub(crate) struct Variant(VARIANT)`, a newtype over the C tagged union | `adapters/windows/src/util.rs:116` |
| `impl From<Variant> for VARIANT` | `adapters/windows/src/util.rs:118-122` |
| `Variant::empty` and `Variant::is_empty` | `adapters/windows/src/util.rs:124-132` |
| `From<BSTR> for Variant` | `adapters/windows/src/util.rs:134-138` |
| `From<WideString> for Variant` | `adapters/windows/src/util.rs:140-144` |
| a hand-built nested anonymous member set, field by field | `adapters/windows/src/util.rs:287-298` |

The block at `adapters/windows/src/util.rs:287-298` sets `vt`, three reserved
words and one anonymous payload member by hand. That is the shape of the
problem, and it is a Zig-side wrapper, not a C shim.

The port should follow the same pattern wherever a C type is a tagged union: a
Zig tagged union, or a Zig union plus an explicit discriminant, declared on the
Zig side of the `translate-c` boundary, with one constructor and one
destructor per variant.

This case does not reach the geometry types. Section 2.1 records that
`accesskit_affine`, `accesskit_rect`, `accesskit_opt_rect`, `accesskit_point`,
`accesskit_vec2` and `accesskit_size` contain no union, no enum, and no pointer.
All five bind directly, and all five use `extern struct` as section 3.2
requires.

### 3.5 Zig naming and defaults

Rust gives `Point` two constants with the same value: `ZERO`
(`accesskit/src/geometry.rs:221`) and `ORIGIN`
(`accesskit/src/geometry.rs:224`). The house rule in
`~/ozai/AGENTS.md` section 1 says "no aliases". The
port keeps one name, `Point.zero`, and migrates every use of `ORIGIN`.

Rust derives `Default` on `Point` (`accesskit/src/geometry.rs:208`) and on
`Rect` (`accesskit/src/geometry.rs:333`), which gives the all-zero value. It
also implements `Default for Affine` by hand (`accesskit/src/geometry.rs:149-152`)
and returns `IDENTITY`, not zeros. That inconsistency is a trap for any
Zig `default()` on a struct. The port must not implement `default`. It exposes
explicit constants:

```zig
pub const Point = extern struct { ... };
pub const point_zero: Point = .{ .x = 0, .y = 0 };
pub const Rect = extern struct { ... };
pub const rect_zero: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 0, .y1 = 0 };
pub const Size = extern struct { ... };
pub const size_zero: Size = .{ .width = 0, .height = 0 };
pub const Vec2 = extern struct { ... };
pub const vec2_zero: Vec2 = .{ .x = 0, .y = 0 };
pub const Affine = extern struct { ... };
pub const affine_identity: Affine = .{ .coeffs = .{ 1, 0, 0, 1, 0, 0 } };
pub const affine_flip_y: Affine = .{ .coeffs = .{ 1, 0, 0, -1, 0, 0 } };
pub const affine_flip_x: Affine = .{ .coeffs = .{ -1, 0, 0, 1, 0, 0 } };
```

Zig has no operator overloading, so every `impl Add`, `impl Sub`, `impl Mul`,
`impl Div` and `impl Neg` block in `geometry.rs` becomes a named function or a
named method. Section 8.2 lists the mapping.

## 4. Units and scaling

AccessKit has one internal unit: physical device pixels in a top-left origin
y-down space (`accesskit/src/lib.rs:2516-2518`). Every scale factor lives
outside that unit. No adapter stores a global DPI value. A scale factor is
either a per-window number read at the call site, or an `Affine` that the
application put on the root node.

| Boundary | Direction | Code | Evidence |
|---|---|---|---|
| Windows UIA screen coordinates to AccessKit client coordinates | subtract | `ClientToScreen` then negate the offset | `adapters/windows/src/util.rs:376-382`, used at `adapters/windows/src/node.rs:1113-1119`, `:1151-1152`, `:1459-1460`, `adapters/windows/src/text.rs:500-506` |
| Windows has no scale factor | none | UIA already reports physical pixels | no DPI or scale symbol occurs anywhere under `adapters/windows/` |
| macOS points to AccessKit pixels | multiply | `point.x * factor`, same for y | `adapters/macos/src/util.rs:44-53` |
| macOS y flip for a non-flipped view | mirror then scale | `view_bounds.size.height - point.y`, then `* factor` | `adapters/macos/src/util.rs:47-52` |
| AccessKit pixels to macOS points | divide | `rect.x0 / factor`, `rect.width() / factor`, and y flipped when the view is not flipped | `adapters/macos/src/util.rs:62-77` |
| macOS view to window to screen | convert | `convertRect_toView` then `convertRectToScreen` | `adapters/macos/src/util.rs:78-80` |
| iOS points to AccessKit pixels | multiply | `local_point.x * factor`, same for y | `adapters/ios/src/util.rs:41-42` |
| AccessKit pixels to iOS points | divide | `rect.x0 / factor`, `rect.width() / factor` | `adapters/ios/src/util.rs:51-61` |
| iOS view to screen | convert | `UIAccessibilityConvertFrameToScreenCoordinates` | `adapters/ios/src/util.rs:46-48` |
| Android density to AccessKit pixels | an `Affine` on the root node | `Affine::translate(safe_area) * Affine::scale(scale_factor)` | `example_common/src/lib.rs:114-116` |
| Android density source | read by the application | `getResources().getDisplayMetrics().density` | `adapters/android/examples/hello_world_app/app/src/main/java/dev/accesskit/helloworld/HelloWorldView.java:116` |
| AT-SPI screen, window, parent coordinates | add or subtract an origin | `accesskit_point_to_atspi_point` and `atspi_point_to_accesskit_point` | `adapters/atspi-common/src/util.rs:23-41`, origin rules at `:43-56` |
| AT-SPI wire rect | narrow `f64` to `i32` | `value.x0 as i32`, `value.width() as i32` | `adapters/atspi-common/src/rect.rs:28-37` |
| Android wire rect | narrow `f64` to `jint` | `rect.x0 as jint` and the same for the other corners | `adapters/android/src/node.rs:247-250` |

The winit examples feed `window.scale_factor()` into the same `set_viewport`
call as Android (`adapters/winit/examples/simple.rs:59`, `:81-83`, and
`adapters/winit/examples/mixed_handlers.rs:73`, `:103-105`). The adapter
itself never sees it. The scale reaches the tree only as the root `Transform`
property.

A case-insensitive grep for `scale_factor|density|device_pixel|dpi|logical_?size|physical_?size`
over `adapters/` returns hits only in `adapters/android/examples/`,
`adapters/macos/src/util.rs`, `adapters/macos/CHANGELOG.md` and
`adapters/winit/examples/`. It returns no hit under `adapters/windows/`,
`adapters/atspi-common/`, `adapters/unix/`, `adapters/ios/` or
`adapters/android/src/`. So there is no per-monitor DPI handling anywhere
upstream. Each window gets one factor.

`[INFERENCE]` A port that must handle per-monitor scale factors should keep the
factor in the adapter, not in the geometry module, because the geometry module
is unit-free by design. The tree already carries the scale as an `Affine` on the
root node, and that is the shape the port should keep.

### 4.1 What the port must do at each boundary

1. Keep the conversion at the adapter edge. `geometry.zig` must contain no DPI,
   no window handle, and no platform type. It takes `f64` pixels and returns
   `f64` pixels.
2. Make the narrowings explicit and checked. Rust narrows `f64` to `i32` with
   `as` (`adapters/atspi-common/src/rect.rs:31-34`,
   `adapters/android/src/node.rs:247-250`). Zig's `@intFromFloat` rejects an
   out-of-range value that it can see at compile time. Probe output:

   ```
   oob.zig:5:34: error: float value '10000000000000000000' cannot be stored in integer type 'i32'
       const i: i32 = @intFromFloat(v);
                                    ^
   ```

   `[INFERENCE]` At run time an out-of-range `@intFromFloat` is undefined
   behaviour under `ReleaseFast` and a panic under `Debug` and `ReleaseSafe`. I
   did not produce a run-time probe for this, so the port must not rely on the
   behaviour either way. The port writes one checked helper,
   `toI32Checked`, with an explicit error, and uses it at both narrowing sites.
   Section 7 gives the values it must produce.
3. Decide the rounding rule once. Both upstream narrowings truncate toward zero,
   so `-0.9` becomes `0` and `9.75` becomes `9` (section 7). A Zig port that
   wants nearest-integer rounding would produce different platform rects and
   would need a written reason. This document keeps truncation.
4. Never store a scale factor in a global. The house rule forbids it. macOS
   reads `backingScaleFactor()` per call (`adapters/macos/src/util.rs:44`,
   `:62`), iOS reads `contentScaleFactor()` per call
   (`adapters/ios/src/util.rs:41`, `:51`). The port reads its per-window factor
   from an adapter struct passed in by pointer.

## 5. The text algorithm on Windows

The file is `adapters/windows/src/text.rs`, 652 lines. It implements the COM
interface `ITextRangeProvider` for a client (Narrator, Quorum, JUCE). It is a
provider, not a consumer: the application supplies the text, and this file
answers the assistive technology.

The short version: this file never converts an offset. It normalises ranges
over text units. Section 5.2 gives the evidence.

### 5.1 Step by step

| Step | What happens | Path |
|---|---|---|
| 1 | The COM object holds no text. It holds a `Weak<Context>` and an `RwLock<WeakRange>`, where `WeakRange` is a downgraded handle into the live `TreeState` | `adapters/windows/src/text.rs:209-213` |
| 2 | Every call first re-resolves the node from the live tree. `upgrade_range` turns a dead handle into `element_not_available()` | `adapters/windows/src/text.rs:24-30`, `:32-37` |
| 3 | The context is upgraded the same way, then a read lock on the tree is taken and the closure runs with `(&TreeState, &Context)` | `adapters/windows/src/text.rs:223-241` |
| 4 | A range endpoint is mapped to a position. `TextPatternRangeEndpoint_Start` becomes `range.start()`, `End` becomes `range.end()`, anything else is `invalid_arg()` | `adapters/windows/src/text.rs:51-59`, and the write side at `:62-78` |
| 5 | A `TextUnit` is mapped to a boundary walk. Seven units exist: Character, Format, Word, Line, Paragraph, Page, Document | `adapters/windows/src/text.rs:81-133`, `:135-146`, `:148-159`, `:161-172` |
| 6 | `back_to_unit_start` snaps a position back to the start of its unit. For `TextUnit_Character` it returns the position unchanged, because a non-degenerate range start is already a character start | `adapters/windows/src/text.rs:81-88` and the comment at `:84-85` |
| 7 | `move_position` runs the unit walk `count.abs()` times in a loop, stops early at the document start or end, and returns the number of steps actually taken | `adapters/windows/src/text.rs:174-203`. The loop bound is `for _ in 0..count` at `:183`, after `let count = count.abs();` at `:181`. The early break is at `:189-191` |
| 8 | `ExpandToEnclosingUnit` special-cases `TextUnit_Document` by jumping straight to `node.document_range()`, so the range survives invalid endpoints. The comment at `:367-369` says Narrator needs this | `adapters/windows/src/text.rs:365-394`, the special case at `:366-376` |
| 9 | `ExpandToEnclosingUnit` also refuses to do anything for `TextUnit_Character` when the start is already at the document end. The comment at `:380-383` records that this came from experiments with Windows ATs | `adapters/windows/src/text.rs:379-385` |
| 10 | `Move` handles a degenerate range differently. It records `is_degenerate()`, then either keeps the start or snaps it to the unit start, walks, and rewrites both endpoints unless the range was degenerate | `adapters/windows/src/text.rs:531-552` |
| 11 | `MoveEndpointByUnit` moves exactly one endpoint. The `to_end` flag is `endpoint == TextPatternRangeEndpoint_End` | `adapters/windows/src/text.rs:554-567` |
| 12 | `MoveEndpointByRange` copies one endpoint from another range. It takes a fixed lock order to avoid deadlock: the other range read first, then this range write | `adapters/windows/src/text.rs:569-592`, the lock order note at `:577-579` |
| 13 | `CompareEndpoints` compares two endpoints. Both are `accesskit_consumer::TextPosition` values, and the comparison is `pos.partial_cmp(&other_pos).unwrap()` cast to `i32`. There is no numeric offset anywhere in this path. When both endpoints belong to the same range it compares the cheap comparable keys without upgrading either range, so an assistive technology can still tell that an old range is degenerate | `adapters/windows/src/text.rs:332-363`. The short-circuit test is at `:339`, the comment at `:340-343`, and `partial_cmp` at `:360` |
| 14 | `GetText` ignores `max_length` on purpose. The comment cites the Microsoft documentation | `adapters/windows/src/text.rs:520-522` |
| 15 | `GetBoundingRectangles` asks the consumer for `range.bounding_boxes()`. An empty result becomes a null pointer | `adapters/windows/src/text.rs:494-510`, the empty check at `:497-499` |
| 16 | Each `Rect` becomes four `f64` values in the SAFEARRAY: `x0 + client_top_left.x`, `y0 + client_top_left.y`, `width()`, `height()`. Note this is x, y, width, height order, not min/max order | `adapters/windows/src/text.rs:502-507`, the flatten loop at `:502`, the capacity reservation at `:501` |
| 17 | `RangeFromPoint` on the text pattern subtracts the client origin, applies `node.transform().inverse()`, and calls `node.text_position_at_point(point)`. The result is a degenerate range | `adapters/windows/src/node.rs:1457-1466` |
| 18 | `Select` emits `ActionRequest { action: Action::SetTextSelection, data: ActionData::SetTextSelection(...) }` back to the application | `adapters/windows/src/text.rs:594-604` |
| 19 | `ScrollIntoView` picks `range.start()` or `range.end()` and maps to `ScrollHint::TopEdge` or `ScrollHint::BottomEdge` | `adapters/windows/src/text.rs:616-638` |
| 20 | `AddToSelection` and `RemoveFromSelection` both fail with `UIA_E_INVALIDOPERATION`, because AccessKit has one selection | `adapters/windows/src/text.rs:606-614` |
| 21 | `FindAttribute` and `FindText` both fail with an empty error, with the justification written in the source | `adapters/windows/src/text.rs:396-417` |
| 22 | `GetAttributeValue` maps 18 UIA attribute identifiers to AccessKit node properties and returns the reserved not-supported `VARIANT` for anything else | `adapters/windows/src/text.rs:419-492`, the fallback at `:485-489` |
| 23 | `GetVisibleRanges` is not implemented. The comment says the Quorum toolkit does not implement it | `adapters/windows/src/node.rs:1445-1450` |
| 24 | `GetChildren` returns an empty array, because embedded objects are not supported in text | `adapters/windows/src/text.rs:640-643` |
| 25 | A test asserts the COM object is `Send + Sync`, because the provider advertises free-threaded use | `adapters/windows/src/text.rs:648-652` |

### 5.2 What this file does not do

It performs no encoding conversion. A grep of
`adapters/windows/src/text.rs` for `u16`, `char16`, `utf16` and `WCHAR` returns
no hit. `accesskit_consumer` exports the type as `TextPosition`, an alias for
`Position` (`accesskit_consumer/src/lib.rs:22-25`). A `Position` holds a
`root_node` and an `InnerPosition`
(`accesskit_consumer/src/text.rs:160-164`), and an `InnerPosition` holds a
`NodeRef` plus a `character_index: usize` (`accesskit_consumer/src/text.rs:15-19`).
Every method here either moves such a position or compares two of them. The
`count` in `Move` and in `MoveEndpointByUnit` is a count of text units, not a
count of code units.

The one place a UTF-16 encoding appears in the whole Windows adapter is the
other direction. `WideString::new` takes a `&mut Vec<u16>`
(`adapters/windows/src/util.rs:76-79`), `StrWrapper` holds a `&'a str` beside a
`&'a mut Vec<u16>` (`adapters/windows/src/util.rs:147-150`), and
`window_title` builds a `Vec<u16>` for the `WM_GETTEXT` message
(`adapters/windows/src/util.rs:394-404`). Those are Rust string to `u16` buffer
conversions at the Windows API boundary. They never reach a position.

So the algorithm in `text.rs` is not an offset conversion. It is range
normalisation over text units: snap an endpoint back to the start of its unit,
walk forward to the end of the unit, move by a counted number of units, and keep
a degenerate range degenerate.

### 5.3 Why a simple property read is not enough

An assistive technology asks for positions, not for strings. Three examples from
the code above:

1. `GetBoundingRectangles` must return a rectangle per text run, in container
   coordinates. The consumer computes that from four separate properties per
   run: `bounds`, `character_positions`, `character_widths` and `text_direction`.
   If any one is missing, `bounding_boxes` returns an empty list
   (`accesskit_consumer/src/text.rs:743-769`, each missing field takes a
   `return Some(Vec::new())` path). The `bounds` property alone cannot answer
   the question.
2. `ExpandToEnclosingUnit(TextUnit_Word)` needs to know where words start. That
   is the `word_starts` property (`accesskit/src/lib.rs:2384`) plus
   `character_lengths` (`accesskit/src/lib.rs:2353`). There is no string search
   in the path.
3. `GetAttributeValue(UIA_FontSizeAttributeId)` must report a single value for
   the whole range, or the mixed state. The consumer walks the runs and compares
   (`accesskit_consumer/src/text.rs:823-840`). Reading one node property would
   give the wrong answer for a multi-run range.

AccessKit stores text as one string per `TextRun` node, plus the geometry
vectors. The consumer builds positions from that. A port that only exposed a
string would have to re-derive all of this, so the consumer text model is a
required part of the port, not an optional extra.

### 5.4 Portable and Windows-only

| Part | Where it lives | Portable |
|---|---|---|
| Position and range algebra, granularity walkers | `accesskit_consumer/src/text.rs` | yes |
| Global USV index | `accesskit_consumer/src/text.rs:241-257` | yes |
| Global UTF-16 index | `accesskit_consumer/src/text.rs:259-279` | yes, but the Windows adapter never calls it. macOS and Android do |
| Bounding box per text run | `accesskit_consumer/src/text.rs:740-821` | yes |
| Text selection to `TextSelection` | `accesskit_consumer/src/text.rs:870-874` | yes |
| COM `ITextRangeProvider` vtable | `adapters/windows/src/text.rs:320-643` | no |
| `SAFEARRAY` of doubles | `adapters/windows/src/text.rs:502-507` | no |
| `BSTR` and `WideString` | `adapters/windows/src/text.rs:523-528` | no |
| `TextUnit` enum of seven values | `adapters/windows/src/text.rs:81-172` | no |
| Rejection of multiple selections | `adapters/windows/src/text.rs:606-614` | the rejection is portable, the HRESULT is not |
| `ClientToScreen` offset | `adapters/windows/src/util.rs:376-382` | no |

The portable part is the whole algorithm. The Windows part is a translation
layer that maps seven unit names and two endpoint names onto that algorithm.

## 6. Text on the other platforms

### 6.1 macOS

macOS has the full `NSAccessibility` text protocol. This adapter is the one a
Zig port should copy first, because it is the only one where every text
operation has a direct, well-documented counterpart.

| Operation | Method | Path |
|---|---|---|
| Number of characters | `accessibilityNumberOfCharacters` | `adapters/macos/src/node.rs:755-765` |
| Selected substring | `accessibilitySelectedText` | `adapters/macos/src/node.rs:767-779` |
| Selected range | `accessibilitySelectedTextRange` | `adapters/macos/src/node.rs:781-792` |
| Caret line number | `accessibilityInsertionPointLineNumber` | `adapters/macos/src/node.rs:794-805` |
| Range for a line | `accessibilityRangeForLine:` | `adapters/macos/src/node.rs:807-818` |
| Character at a point | `accessibilityRangeForPosition:` | `adapters/macos/src/node.rs:820-838` |
| Styled text for a range | `accessibilityAttributedStringForRange:` | `adapters/macos/src/node.rs:854-958` |
| Bounding box for a range | `accessibilityFrameForRange:` | `adapters/macos/src/node.rs:960-983` |
| Line number for an index | `accessibilityLineForIndex:` | `adapters/macos/src/node.rs:985-996` |
| Range for an index | `accessibilityRangeForIndex:` | `adapters/macos/src/node.rs:998-1009` |
| Formatting run for an index | `accessibilityStyleRangeForIndex:` | `adapters/macos/src/node.rs:1011-1029` |
| Write the selection | `setAccessibilitySelectedTextRange:` | `adapters/macos/src/node.rs:1031-1047` |
| Bounds | `accessibilityFrame` | `adapters/macos/src/node.rs:477-499` |
| Offset conversion in | `from_ns_range` | `adapters/macos/src/util.rs:13-22` |
| Offset conversion out | `to_ns_range` | `adapters/macos/src/util.rs:24-28` |
| One-character range out | `to_ns_range_for_character` | `adapters/macos/src/util.rs:30-36` |
| Point in | `from_ns_point` | `adapters/macos/src/util.rs:38-55` |
| Rect out | `to_ns_rect` | `adapters/macos/src/util.rs:57-81` |

Three details carry over to any port.

1. The offset unit is UTF-16 code units. `to_ns_range` calls
   `to_global_utf16_index()` (`adapters/macos/src/util.rs:25-26`).
2. `accessibilityFrameForRange:` unions the per-run boxes into one rectangle
   before answering, at `adapters/macos/src/node.rs:972-977`. macOS asks for one
   rect, so the per-line detail is lost at the boundary.
3. A failed resolution returns `NSRect::ZERO` rather than an error, at
   `adapters/macos/src/node.rs:966` and `:980`.

### 6.2 AT-SPI on Linux

The assignment named `adapters/atspi-common/src/text.rs`. That file does not
exist. `adapters/atspi-common/src/` contains `node.rs`, `rect.rs`,
`simplified.rs`, `text_attributes.rs`, `util.rs`, `action.rs`, `adapter.rs`,
`callback.rs`, `context.rs`, `error.rs`, `events.rs`, `filters.rs` and
`lib.rs`. The text logic is in `adapters/atspi-common/src/node.rs`, and the
D-Bus surface is in `adapters/unix/src/atspi/interfaces/text.rs`, 163 lines.

This adapter is a server. It exports the AccessKit tree over D-Bus for
accessibility clients such as Orca. It does not read an external application.

| Operation | Path |
|---|---|
| Interface name `org.a11y.atspi.Text` | `adapters/unix/src/atspi/interfaces/text.rs:25` |
| `CharacterCount` property | `adapters/unix/src/atspi/interfaces/text.rs:27-30` |
| `CaretOffset` property | `adapters/unix/src/atspi/interfaces/text.rs:32-35` |
| `GetStringAtOffset` | `adapters/unix/src/atspi/interfaces/text.rs:37-45` |
| `GetText` | `adapters/unix/src/atspi/interfaces/text.rs:47-51` |
| `SetCaretOffset` | `adapters/unix/src/atspi/interfaces/text.rs:53-55` |
| `GetAttributeValue` | `adapters/unix/src/atspi/interfaces/text.rs:57-61` |
| `GetCharacterExtents` | `adapters/unix/src/atspi/interfaces/text.rs:76-80` |
| `GetOffsetAtPoint` | `adapters/unix/src/atspi/interfaces/text.rs:82-86` |
| `GetNSelections` and `GetSelection` | `adapters/unix/src/atspi/interfaces/text.rs:88-94` |
| `SetSelection` | `adapters/unix/src/atspi/interfaces/text.rs:108-117` |
| `GetRangeExtents` | `adapters/unix/src/atspi/interfaces/text.rs:119-128` |
| Character count implementation | `adapters/atspi-common/src/node.rs:1415-1423` |
| Caret offset implementation | `adapters/atspi-common/src/node.rs:1425-1434` |
| String at offset, with granularity | `adapters/atspi-common/src/node.rs:1436-1457` |
| Selection read, start and end only | `adapters/atspi-common/src/node.rs:1546-1578` |
| Selection write | `adapters/atspi-common/src/node.rs:1610-1633` |
| Caret write | `adapters/atspi-common/src/node.rs:1467-1482` |
| Character extents | `adapters/atspi-common/src/node.rs:1513-1528` |
| Offset at point | `adapters/atspi-common/src/node.rs:1530-1544` |
| Range extents | `adapters/atspi-common/src/node.rs:1635-1653` |
| Granularity expansion | `adapters/atspi-common/src/util.rs:67-94` |
| Offset to position | `adapters/atspi-common/src/util.rs:59-65` |
| Document-end sentinel, `end_offset == -1` | `adapters/atspi-common/src/util.rs:96-111` |
| Union of per-run boxes | `adapters/atspi-common/src/util.rs:113-122` |
| Screen, window and parent coordinate mapping | `adapters/atspi-common/src/util.rs:23-56` |
| The `i32` wire rectangle | `adapters/atspi-common/src/rect.rs:11-37` |
| Text attributes, ten supported names | `adapters/atspi-common/src/text_attributes.rs:68-79` |

Four differences a port must decide on:

1. The offset unit is a global Unicode scalar value index, not UTF-16.
   `character_count` calls `to_global_usv_index()`
   (`adapters/atspi-common/src/node.rs:1419`). A non-BMP character costs 1 on
   AT-SPI and 2 on macOS and Android.
2. There is no per-word and no per-line extents method. A client composes it by
   calling `GetStringAtOffset(offset, Word or Line)` and then
   `GetRangeExtents(start, end)`. `[INFERENCE]` This follows from the method
   list at `adapters/unix/src/atspi/interfaces/text.rs:25-163`.
3. `Sentence` granularity is a hard error, not a fallback. Both the start side
   and the end side return `Error::UnsupportedTextGranularity`
   (`adapters/atspi-common/src/util.rs:79` and `:88`).
4. Backward selections cannot round-trip. `GetSelection` returns start and end
   only (`adapters/atspi-common/src/node.rs:1555-1578`), and the write path
   always maps start to anchor and end to focus
   (`accesskit_consumer/src/text.rs:870-874`).

There is no text cache. Every call re-resolves the node from the tree, and the
AT-SPI object cache `CacheNode` holds no text field. That is good news for a
port: there is no cache to invalidate.

### 6.3 iOS

The iOS adapter implements none of the `UIAccessibility` text protocol. Text
reaches VoiceOver as one flat `accessibilityValue` string.

| What exists | Path |
|---|---|
| `accessibilityValue` returns the node value as a string | `adapters/ios/src/node.rs:256-265` |
| `accessibilityFrame` in screen coordinates | `adapters/ios/src/node.rs:273-285` |
| `accessibilityTraits` | `adapters/ios/src/node.rs:267-271` |
| Point in, screen to AccessKit | `adapters/ios/src/util.rs:37-44` |
| Rect out, to screen | `adapters/ios/src/util.rs:46-63` |

| What does not exist | Evidence |
|---|---|
| No character count | no `accessibilityNumberOfCharacters` in `adapters/ios/src/` |
| No selection read or write | no `accessibilitySelectedTextRange` in `adapters/ios/src/` |
| No caret | no `accessibilityInsertionPointLineNumber` in `adapters/ios/src/` |
| No range for index, line or point | no `accessibilityRangeForIndex:` in `adapters/ios/src/` |
| No per-character or per-line rect | no `accessibilityFrameForRange:` in `adapters/ios/src/` |
| No `UITextInput`, `UITextRange`, `UITextPosition`, `UITextView` | the `objc2-ui-kit` feature list at `adapters/ios/Cargo.toml:31-43` enables only `UIAccessibility`, `UIAccessibilityConstants`, `UIAccessibilityContainer`, `UIAccessibilityElement`, `UIAccessibilityIdentification`, `UIGeometry`, `UIResponder`, `UIScreen`, `UIView`, `UIViewController` and `UIWindow` |

The iOS adapter also has no y-flip handling, because UIKit is y-down like
AccessKit. It has no `accessibilityFrameInContainerSpace`. Geometry is emitted
in screen space only, through `UIAccessibilityConvertFrameToScreenCoordinates`
(`adapters/ios/src/util.rs:46-48`).

`[INFERENCE]` A pure-Zig iOS adapter must build its text layer from scratch.
The macOS adapter is the only usable template.

### 6.4 Android

Android is a producer. It reads the AccessKit tree and writes an
`AccessibilityNodeInfo`. It never reads a widget's text.

| Operation | Path |
|---|---|
| Text value, value wins over document text | `adapters/android/src/node.rs:101-110` |
| Text written with `setText` | `adapters/android/src/node.rs:323-331` |
| Selection read, focused nodes only | `adapters/android/src/node.rs:112-122` |
| Selection written with `setTextSelection`, direction lost | `adapters/android/src/node.rs:332-340` |
| Granularities advertised | `adapters/android/src/node.rs:378-393` |
| Bounds, with a `getLocationOnScreen` offset and an `f64` to `jint` cast | `adapters/android/src/node.rs:232-261` |
| Movement by granularity, character to paragraph | `adapters/android/src/adapter.rs:647-791` |
| Set selection, optimistic local write then `ActionRequest` | `adapters/android/src/adapter.rs:561-614` |
| `ACTION_SET_SELECTION` and granularity arguments decoded | `adapters/android/src/action.rs:38-71` |
| Text change event, UTF-16 prefix and suffix diff | `adapters/android/src/event.rs:89-154` |
| Selection change event | `adapters/android/src/event.rs:157-197` |

| What does not exist | Evidence |
|---|---|
| No per-character, per-word or per-line rectangle | `RangeInfo` in this adapter is the numeric range control, built at `adapters/android/src/util.rs:73-82` and attached at `adapters/android/src/node.rs:407-415`. It is not text range info |
| No `getTextAtTraversalGranularity` | no occurrence under `adapters/android/src/` |
| No density or dp code in the adapter | the only density reference in the whole adapter tree is the example app at `adapters/android/examples/hello_world_app/app/src/main/java/dev/accesskit/helloworld/HelloWorldView.java:116` |

The offset unit on Android is UTF-16 code units, the same as macOS. The
selection direction is dropped, because `setTextSelection(int start, int end)`
takes an ordered pair (`adapters/android/src/node.rs:332-338`).

### 6.5 Summary of what each platform can answer

| Capability | Windows | macOS | AT-SPI | iOS | Android |
|---|---|---|---|---|---|
| Plain text | yes | yes | yes | yes | yes |
| Character count | yes | yes | yes | no | no |
| Caret position | yes | yes | yes | no | yes |
| Selection read | yes | yes | yes, start and end only | no | yes |
| Selection write | yes | yes | yes | no | yes |
| Offset to character box | yes | yes | yes | no | no |
| Word or line box | yes, via `GetBoundingRectangles` | no, macOS asks for one rect | no, client composes it | no | no |
| Offset unit crossing the platform boundary | none, positions stay `TextPosition` | UTF-16 | USV | not applicable | UTF-16 |

## 7. Test vectors

These are the geometry cases a port must pass. Every expected value was
computed by hand from the Rust source at the cited lines, then checked by a Zig
probe that encodes the same arithmetic. Probe at
`/tmp/scratch/GeometryAndText/vectors.zig`, run with
`zig run vectors.zig` under Zig 0.16.0.

### 7.1 Case 1, negative coordinates

Input `Rect` from `new(-10, -20, 30, 40)`.

| Operation | Expected | Where the expectation comes from |
|---|---|---|
| `width()` | `40` | `x1 - x0` at `accesskit/src/geometry.rs:442-444`, so `30 - (-10)` |
| `height()` | `60` | `y1 - y0` at `accesskit/src/geometry.rs:450-452`, so `40 - (-20)` |
| `area()` | `2400` | `width() * height()` at `accesskit/src/geometry.rs:505-507` |
| `is_empty()` | `false` | `area() == 0.0` at `accesskit/src/geometry.rs:513-515`, and `2400 != 0` |
| `min_x()` | `-10` | `min(x0, x1)` at `accesskit/src/geometry.rs:456-458` |
| `max_y()` | `40` | `max(y0, y1)` at `accesskit/src/geometry.rs:474-476` |
| `contains(-10, -20)` | `true` | `>= x0` and `>= y0` at `accesskit/src/geometry.rs:519-521` |
| `contains(30, 40)` | `false` | `< x1` and `< y1`, so the far edge is exclusive |
| `contains(29.999, 39.999)` | `true` | same rule |

Probe output:

```
1 negative x0=-10 y0=-20 x1=30 y1=40 width=40 height=60 area=2400 is_empty=false
  contains(-10,-20)=true contains(30,40)=false contains(29.999,39.999)=true
```

### 7.2 Case 2, zero size

Input `Rect` from `new(5, 7, 5, 7)`.

| Operation | Expected | Where the expectation comes from |
|---|---|---|
| `width()` | `0` | `accesskit/src/geometry.rs:442-444` |
| `height()` | `0` | `accesskit/src/geometry.rs:450-452` |
| `area()` | `0` | `accesskit/src/geometry.rs:505-507` |
| `is_empty()` | `true` | `accesskit/src/geometry.rs:513-515` |
| `origin()` | `(5, 7)` | stored `x0` and `y0` at `accesskit/src/geometry.rs:483-485` |
| AT-SPI wire rect | `{x: 5, y: 7, width: 0, height: 0}` | `value.x0 as i32` and `value.width() as i32` at `adapters/atspi-common/src/rect.rs:31-34` |
| `union_pt((5, 7))` | unchanged | `min(x0, 5), min(y0, 7), max(x1, 5), max(y1, 7)` at `accesskit/src/geometry.rs:543-553` |
| `contains((5, 7))` | `false` | `5 >= 5` passes, `5 < 5` fails, at `accesskit/src/geometry.rs:519-521` |

Probe output:

```
2 zero size x0=5 y0=7 x1=5 y1=7 width=0 height=0 area=0 is_empty=true
  f64->i32: x=5 y=7 w=0 h=0
```

The last row of `contains` matters. A zero-area rectangle contains no point,
not even its own origin. A port that writes `p.x <= self.x1` will fail this.

### 7.3 Case 3, an inverted rectangle

Input `Rect` from `new(80, 60, 20, 10)`, so `x1 < x0` and `y1 < y0`.

| Operation | Expected | Where the expectation comes from |
|---|---|---|
| `width()` | `-60` | `20 - 80` at `accesskit/src/geometry.rs:442-444`. The source says nothing forbids it, at `accesskit/src/geometry.rs:440` |
| `height()` | `-50` | `10 - 60`, same rule at `:448` |
| `area()` | `3000` | `(-60) * (-50)`, positive. `accesskit/src/geometry.rs:505-507` |
| `is_empty()` | `false` | `3000 != 0`. The source says a negative area is not empty, at `accesskit/src/geometry.rs:511` |
| `origin()` | `(80, 60)` | the stored `x0`, `y0`, **not** the minimum. `accesskit/src/geometry.rs:483-485` |
| `size()` | `(-60, -50)` | `accesskit/src/geometry.rs:489-491` |
| `abs()` | `(20, 10, 80, 60)` | `min` then `max` per axis at `accesskit/src/geometry.rs:498-501` |
| `from_points((80,60), (20,10))` | `(20, 10, 80, 60)` | `new(...).abs()` at `accesskit/src/geometry.rs:411-417` |
| `intersect` with `(-10,-20,30,40)` | `(80, 60, 80, 60)` | `x0 = max(80, -10) = 80`, `x1 = min(20, 30) = 20`, then `x1 = max(20, 80) = 80`. `accesskit/src/geometry.rs:557-563` |
| that intersection `is_empty()` | `true` | clamped to zero area, then `area() == 0.0` |

Probe output:

```
3a inverted raw x0=80 y0=60 x1=20 y1=10 width=-60 height=-50 area=3000 is_empty=false
3b inverted abs x0=20 y0=10 x1=80 y1=60 width=60 height=50 area=3000 is_empty=false
3c from_points x0=20 y0=10 x1=80 y1=60 width=60 height=50 area=3000 is_empty=false
3d inv.unite(neg) x0=-10 y0=-20 x1=30 y1=40 width=40 height=60 area=2400 is_empty=false
3e neg.intersect(inv) x0=80 y0=60 x1=80 y1=60 width=0 height=0 area=0 is_empty=true
```

Line `3d` shows `union` with an inverted rectangle. The union takes
`min(x0, other.x0)` and `max(x1, other.x1)` without normalising
(`accesskit/src/geometry.rs:527-539`), and the result here is the other
rectangle. The source warns the result is valid only for non-negative extents,
at `accesskit/src/geometry.rs:525`.

### 7.4 Case 4, a rectangle that overflows the parent

Parent `new(0, 0, 100, 50)`. Child `new(90, 40, 140, 90)`.

| Operation | Expected | Where the expectation comes from |
|---|---|---|
| child `area()` | `2500` | `(140 - 90) * (90 - 40)` |
| `child.intersect(parent)` | `(90, 40, 100, 50)`, width `10`, height `10`, area `100` | per-axis `max` on the min corners and `min` on the max corners, `accesskit/src/geometry.rs:557-563` |
| `parent.union(child)` | `(0, 0, 140, 90)`, width `140`, height `90`, area `12600` | `accesskit/src/geometry.rs:527-539` |
| AT-SPI `extents` clamp | `(90, 40, 100, 50)` | `bounds.x1 = bounds.x1.min(window_bounds.x1)` and the same for y, at `adapters/atspi-common/src/node.rs:551-554` |
| `parent.contains((95, 45))` | `true` | `accesskit/src/geometry.rs:519-521` |
| `parent.contains((105, 45))` | `false` | `105 < 100` fails |
| `child.contains((95, 45))` | `true` | the child still claims the point, because `Rect` does not clip |

Probe output:

```
4a parent x0=0 y0=0 x1=100 y1=50 width=100 height=50 area=5000 is_empty=false
4b child x0=90 y0=40 x1=140 y1=90 width=50 height=50 area=2500 is_empty=false
4c child.intersect(parent) x0=90 y0=40 x1=100 y1=50 width=10 height=10 area=100 is_empty=false
4d parent.unite(child) x0=0 y0=0 x1=140 y1=90 width=140 height=90 area=12600 is_empty=false
4e atspi clamp x0=90 y0=40 x1=100 y1=50 width=10 height=10 area=100 is_empty=false
```

The important design fact is in the last two rows of the table. `Rect` itself
does not clip to a parent. Clipping is a separate step, and upstream performs it
in two different places with two different rules: `intersect` for geometry, and
a hand-written clamp in the AT-SPI adapter at
`adapters/atspi-common/src/node.rs:551-554`. A port must expose the clamp as its
own named function rather than hoping every caller calls `intersect`.

### 7.5 Case 5, a very large coordinate

| Input | Expected | Where the expectation comes from |
|---|---|---|
| `Rect` from `new(0, 0, 3.0e7, 3.0e7)` | `width` `30000000`, `area` `900000000000000` | `accesskit/src/geometry.rs:442` and `:505` |
| that to `i32` | `0, 0, 30000000, 30000000` | fits, since `i32` max is `2147483647` |
| `Rect` from `new(0, 0, 1.0e19, 1.0e19)` | `area` `100000000000000000000000000000000000000` | `f64` holds it. `f64` max is about `1.8e308` |
| that to `i32` | must be rejected, not wrapped | Rust `as` saturates. Zig `@intFromFloat` is a compile error when the value is visible at compile time, as shown in section 4.1 |
| `-0.9` narrowed to `i32` | `0` | truncation toward zero, same as Rust `as` |
| `9.75` narrowed to `i32` | `9` | truncation toward zero |

Probe output:

```
5 large x0=0 y0=0 x1=30000000 y1=30000000 width=30000000 height=30000000 area=900000000000000 is_empty=false
  f64->i32: 0 0 30000000 30000000 (i32 max = 2147483647)
  -0.9 -> 0
  9.75 -> 9
5b beyond i32 x0=0 y0=0 x1=10000000000000000000 y1=10000000000000000000 width=10000000000000000000 height=10000000000000000000 area=100000000000000000000000000000000000000 is_empty=false
  1.0e19 -> -2147483648 (saturate marker)
  area of 1.0e19 square = 100000000000000000000000000000000000000
```

The `saturate marker` line is the probe's own guard, not a Zig result. The probe
returns `i32` min when the value is out of range. Rust's `as i32` saturates
instead, at `i32::MAX` for a large positive value. `[INFERENCE]` The port must
not depend on either. It returns an explicit error, and `docs/50-verification.md`
records that error as the expected result for the out-of-range case.

### 7.6 The transform cases a port must also pass

| Case | Input | Expected | Where it comes from |
|---|---|---|---|
| Identity of identity | `Affine.identity() * Point(3, 4)` | `(3, 4)` | `c0*3 + c2*4 + c4` with `c = [1,0,0,1,0,0]` at `accesskit/src/geometry.rs:156-165` |
| Flip y | `Affine.flipY() * Point(3, 4)` | `(3, -4)` | `c3 = -1` at `accesskit/src/geometry.rs:30`, applied at `:159-163` |
| Inverse of a scale | `Affine.scale(2.0).inverse()` | `scale(0.5)` | `inv_det = 1/4`, then `0.25 * 2 = 0.5`, at `accesskit/src/geometry.rs:99-113` |
| Inverse of a singular map | `Affine.new([0,0,0,0,0,0]).inverse()` | all NaN | `0.0.recip()` is NaN, and the doc at `accesskit/src/geometry.rs:98` says so |
| Bounding box under identity | `Affine.identity().transformRectBbox(Rect(1,2,3,4))` | `(1,2,3,4)` | `from_points(p00,p01).union(from_points(p10,p11))` at `accesskit/src/geometry.rs:118-125`, and `abs()` orders the corners |
| Bounding box under flip y | `Affine.flipY().transformRectBbox(Rect(1,2,3,4))` | `(1, -4, 3, -2)`, width `2`, height `2` | the corners become `(1,-2)`, `(1,-4)`, `(3,-2)`, `(3,-4)`. `from_points` at `accesskit/src/geometry.rs:411` calls `abs()` at `:498-501`, which orders x to `1..3` and y to `-4..-2`. Then `union` at `:527-539` takes the per-axis min and max of the two boxes |
| `is_nan` after a singular inverse | `Affine.new([0,0,0,0,0,0]).inverse().isNan()` | `true` | `accesskit/src/geometry.rs:139-146` |
| Composition order | `Affine.scale(2.0) * Affine.translate(Point(1,1))` maps `(1,1)` to `(4, 4)` | `4, 4` | `accesskit/src/geometry.rs:168-182` computes `A * B` as "apply B first", so the translate runs first and the scale doubles the result |

The last row is the one a port is most likely to get wrong. `A * B * v` equals
`A * (B * v)`, as the source states at `accesskit/src/geometry.rs:45-46`. A port
that stores the rows in Direct2D order and multiplies in the other order will
pass every other test and still place every window at the wrong position.
Probe output, from `zig run transforms.zig` under Zig 0.16.0:

```
identity*(3,4) = (3,4)
flipY*(3,4)    = (3,-4)
inverse(scale2) = [0.5,-0,-0,0.5,0,0]
inverse(zero)   = [-nan,-nan,-nan,-nan,-nan,-nan]
inverse(zero) isNaN = true
identity bbox(1,2,3,4) = (1,2,3,4) w=2 h=2
flipY    bbox(1,2,3,4) = (1,-4,3,-2) w=2 h=2
scale(2)*translate(1,1) applied to (1,1) = (4,4)
translate(1,1)*scale(2) applied to (1,1) = (3,3)
```

The last two lines are the reason the composition row exists. Both products are
valid affine maps. Only one of them places the point where AccessKit expects.

## 8. House-rule fit

The rules are in `~/ozai/AGENTS.md` sections 1 and 2.

### 8.1 Purity

Every operation in `geometry.rs` is a pure function of its arguments. No
global, no `io`, no clock, no allocator, no error. The largest function is
`Affine.inverse` at `accesskit/src/geometry.rs:99-113`, which is eleven lines of
arithmetic. The Zig port keeps that property. Nothing in the geometry module
takes a `std.mem.Allocator`, and nothing takes an error set, because nothing
can fail.

The text side is not pure, and the house rules say so. `Range::bounding_boxes`
(`accesskit_consumer/src/text.rs:740`) allocates a `Vec`, and `Range::text`
(`accesskit_consumer/src/text.rs:727`) allocates a `String`. Those two are the
only geometry-adjacent functions that allocate, and the port keeps an explicit
allocator parameter on both. `Rect::union`, `Rect::intersect`,
`Rect::transform_rect_bbox` and every other operation stay allocator-free and
return by value.

### 8.2 Rust operator to Zig function

Zig has no operator overloading, so every trait impl in `geometry.rs` becomes a
named function or a named method. `grep -n '^impl ' accesskit/src/geometry.rs`
returns 51 blocks. Five are inherent: `accesskit/src/geometry.rs:24` (`Affine`),
`:219` (`Point`), `:397` (`Rect`), `:578` (`Size`) and `:724` (`Vec2`). Their
named methods are already listed in section 1. The other 46 are trait impls.
Every one appears below. No operation is dropped.

| Rust | Path | Zig |
|---|---|---|
| `Affine * Point` | `accesskit/src/geometry.rs:156-165` | `pub fn transformPoint(self: Affine, p: Point) Point` |
| `Affine * Affine` | `accesskit/src/geometry.rs:168-182` | `pub fn mul(self: Affine, other: Affine) Affine` |
| `Affine *= Affine` | `accesskit/src/geometry.rs:184-189` | delete. Assign `a = a.mul(b)` |
| `f64 * Affine` | `accesskit/src/geometry.rs:191-205` | `pub fn scale(scalar: f64, a: Affine) Affine` |
| `Point + Vec2` | `accesskit/src/geometry.rs:253-260` | `pub fn add(self: Point, v: Vec2) Point` |
| `Point += Vec2` | `accesskit/src/geometry.rs:262-267` | delete. Assign |
| `Point - Vec2` | `accesskit/src/geometry.rs:269-276` | `pub fn sub(self: Point, v: Vec2) Point` |
| `Point -= Vec2` | `accesskit/src/geometry.rs:278-283` | delete. Assign |
| `Point + (f64, f64)` | `accesskit/src/geometry.rs:285-292` | delete. Call `Vec2` first |
| `Point += (f64, f64)` | `accesskit/src/geometry.rs:294-299` | delete |
| `Point - (f64, f64)` | `accesskit/src/geometry.rs:301-308` | delete |
| `Point -= (f64, f64)` | `accesskit/src/geometry.rs:310-315` | delete |
| `Point - Point` | `accesskit/src/geometry.rs:317-324` | `pub fn sub(self: Point, other: Point) Vec2` |
| `From<(f64,f64)> for Point` and the reverse | `accesskit/src/geometry.rs:239-251` | delete both. A `Point` literal is enough |
| `From<(Point,Point)> for Rect` | `accesskit/src/geometry.rs:348-352` | `pub fn fromPoints(p0: Point, p1: Point) Rect` |
| `From<(Point,Size)> for Rect` | `accesskit/src/geometry.rs:354-358` | `pub fn fromOriginSize(o: Point, s: Size) Rect` |
| `Rect + Vec2` | `accesskit/src/geometry.rs:360-367` | `pub fn translate(self: Rect, v: Vec2) Rect` |
| `Rect - Vec2` | `accesskit/src/geometry.rs:369-376` | `pub fn translateBy(self: Rect, v: Vec2) Rect` |
| `Size * f64` | `accesskit/src/geometry.rs:621-631` | `pub fn scale(self: Size, s: f64) Size` |
| `Size *= f64` | `accesskit/src/geometry.rs:602-610` | delete. Assign |
| `f64 * Size` | `accesskit/src/geometry.rs:612-619` | delete. Call `Size.scale` |
| `Size / f64` | `accesskit/src/geometry.rs:643-653` | `pub fn divide(self: Size, s: f64) Size`, a true divide |
| `Size /= f64` | `accesskit/src/geometry.rs:633-641` | delete. Assign |
| `Size + Size` | `accesskit/src/geometry.rs:655-664` | `pub fn add(self: Size, other: Size) Size` |
| `Size += Size` | `accesskit/src/geometry.rs:666-671` | delete. Assign |
| `Size - Size` | `accesskit/src/geometry.rs:673-682` | `pub fn sub(self: Size, other: Size) Size` |
| `Size -= Size` | `accesskit/src/geometry.rs:684-689` | delete. Assign |
| `From<(f64,f64)> for Size` and the reverse | `accesskit/src/geometry.rs:691-706` | delete both |
| `Vec2 + Vec2` | `accesskit/src/geometry.rs:761-771` | `pub fn add(self: Vec2, other: Vec2) Vec2` |
| `Vec2 += Vec2` | `accesskit/src/geometry.rs:773-781` | delete. Assign |
| `Vec2 - Vec2` | `accesskit/src/geometry.rs:783-793` | `pub fn sub(self: Vec2, other: Vec2) Vec2` |
| `Vec2 -= Vec2` | `accesskit/src/geometry.rs:795-803` | delete. Assign |
| `Vec2 * f64` | `accesskit/src/geometry.rs:805-815` | `pub fn scale(self: Vec2, s: f64) Vec2` |
| `Vec2 *= f64` | `accesskit/src/geometry.rs:817-825` | delete. Assign |
| `f64 * Vec2` | `accesskit/src/geometry.rs:827-834` | delete. Call `Vec2.scale` |
| `Vec2 / f64` | `accesskit/src/geometry.rs:836-847` | `pub fn divide(self: Vec2, s: f64) Vec2`. Keep the reciprocal multiply, and keep the roundoff note |
| `Vec2 /= f64` | `accesskit/src/geometry.rs:849-854` | delete. Assign |
| `-Vec2` | `accesskit/src/geometry.rs:856-866` | `pub fn negate(self: Vec2) Vec2` |
| `From<(f64,f64)> for Vec2` and the reverse | `accesskit/src/geometry.rs:747-759` | delete both |
| `Default for Affine` | `accesskit/src/geometry.rs:149-153` | delete. Use `affine_identity` from section 3.5 |
| `fmt::Debug` for the five types | `accesskit/src/geometry.rs:326-330`, `:378-395`, `:596-600` | one `format` function per type, or `std.debug.print` with `{d}` fields |

Four `delete` rows deserve a reason. The `AddAssign` family exists in Rust
only because Rust cannot write into a field of a temporary. Zig assigns to a
mutable local, so the whole family goes. The tuple `From` impls exist because
Rust has no named-field struct literal for a tuple struct. Zig has one, so they
go too.

`Vec2.divide` and `Size.divide` must stay different. `Vec2` multiplies by the
reciprocal (`accesskit/src/geometry.rs:836-847`) and `Size` divides
(`accesskit/src/geometry.rs:643-653`). Merging them changes rounding.

### 8.3 Rule by rule

| Rule | Geometry module | Text module |
|---|---|---|
| `io` threaded explicitly, never global | satisfied. No I/O at all | satisfied. The tree arrives as a parameter, and the platform bridge reads `io` only at the adapter edge |
| State is a parameter, not a capture | satisfied. `Rect` operations take `self` by value and return a new `Rect` | partially. A `TextPosition` borrows the tree, so the borrow is the state. The port passes the tree in, it does not capture it |
| Pure function over decoded input | satisfied | satisfied for `boundingBoxes`, `toGlobalUtf16Index`, `toGlobalUsvIndex` and the granularity walkers |
| Allocators are parameters | satisfied, no allocator needed | required on `text()` and `boundingBoxes()` |
| Explicit error sets | satisfied, no errors | required on the global index conversions, which upstream ends with `panic!("invalid position")` at `accesskit_consumer/src/text.rs:256` and `:278` |
| Loops have a fixed upper bound | satisfied, no loops except the compile-time `inline for` over an enumerable domain | satisfied. `to_line_index` at `accesskit_consumer/src/text.rs:281-292` walks backward to the document start with a loop bound that is the text length. The port must take the length as a parameter rather than recomputing it inside the loop condition |
| Event and platform logic is pure over decoded input | satisfied | the Windows `ITextRangeProvider` methods are pure over `(TreeState, TextUnit, count)`. The COM object holds no text |
| No backwards compatibility | delete `Point::ORIGIN` (`accesskit/src/geometry.rs:224`), delete the `Affine([f64;6])` tuple shape, delete the C `double _0[6]` field name, delete the `Add` and `AddAssign` duplication, drop `Default` and use the named constants from section 3.5 | keep only one narrowing helper, and rename `Rect::origin()` to `topLeft()` so the name says that it returns the stored `x0` and not `min_x()` |

### 8.4 Two places the port must push harder than upstream

1. `accesskit_consumer/src/text.rs:256` and `:278` end with
   `panic!("invalid position")`. A house port returns an explicit error. The
   two call sites that depend on this are the adapter boundaries, so the error
   becomes a platform error there.
2. Upstream narrows `f64` to `i32` with `as` in two places
   (`adapters/atspi-common/src/rect.rs:31-34`,
   `adapters/android/src/node.rs:247-250`). Both saturate silently. A house port
   uses one named checked conversion with an explicit error, because the
   alternative is a silent wrong rectangle on a large display.

### 8.5 What this document does not settle

1. Whether `geometry.zig` is one module or three. The split is `types.zig` for
   the five value types and the C assertions, `ops.zig` for the arithmetic, and
   `narrow.zig` for the two checked `f64` to `i32` conversions. `docs/30-port-design.md`
   decides.
2. Whether the C ABI lives in the same file as the Zig types or in a separate
   `abi.zig`. `docs/31-c-abi-design.md` decides.
3. The sign and width of the `f64` to `i32` narrowing error. Section 7 fixes the
   values it produces, not the error name.

