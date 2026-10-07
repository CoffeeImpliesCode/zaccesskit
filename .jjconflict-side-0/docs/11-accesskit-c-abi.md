# 11 — The AccessKit C ABI

**Consumer.** `docs/31-c-abi-design.md` reads this document and writes the Zig C
seam. `docs/30-port-design.md` reads sections 2, 4, 5 and 9 of this document and
decides the module layout.

## Sources

| Item | Path |
|---|---|
| Header | `/tmp/scratch/accesskit-c/include/accesskit.h`, 3154 lines |
| Shim | `/tmp/scratch/accesskit-c/src/{lib,common,geometry,unix,windows,macos,ios,android}.rs`, 2733 lines total |
| Generator config | `/tmp/scratch/accesskit-c/cbindgen.toml`, 138 lines |
| Build | `CMakeLists.txt`, `accesskit.cmake`, `accesskit-config.cmake`, `meson.build`, `meson/`, `meson_options.txt` |
| Examples | `examples/sdl/hello_world.c` (479 lines), `examples/windows/hello_world.c` (291 lines) |
| Release record | `CHANGELOG.md`, `README.md` |
| Pre-move tree | `git -C /tmp/scratch/accesskit show 553d9c1`, `bindings/c/` |

Checkout under read. Commands in this document were run against that checkout
and against the target project. The target project was not built, formatted,
linted or tested. No build gate was run.

---

## 1. Where the ABI lives and why it moved

### 1.1 The move

```
$ git -C /tmp/scratch/accesskit show -s \
    --format='%H%n%ad%n%s%n%b' 553d9c1
553d9c161e7ea59e858f2aa14e4c8a952cc94321
Sun Jul 21 22:21:57 2024 +0200
chore: Move the language bindings to standalone repositories (#442)
```

```
$ git -C /tmp/scratch/accesskit show --stat 553d9c1 | tail -3
 49 files changed, 4 insertions(+), 9072 deletions(-)
```

The commit deleted `bindings/c/**` and `bindings/python/**`. The C ABI left
the AccessKit repository on 2024-07-21. It now lives in a second repository.

### 1.2 The two repositories

| | Core | C bindings |
|---|---|---|
| Checkout | `/tmp/scratch/accesskit` | `/tmp/scratch/accesskit-c` |
| Commit | `466e24e252103f4d82bd6fbab98141b551e46e0c` | `8b6ed37c20ed4c59390e253407983333053662ba` |
| Version | `accesskit` crate `0.25.1` | `accesskit-c` `0.23.1` |
| Release manifest | `.release-please-manifest.json` | `.release-please-manifest.json` = `{".":"0.23.1"}` |

`accesskit-c` depends on the core crate by version, not by path:

```
$ cat /tmp/scratch/accesskit-c/Cargo.toml
[package]
name = "accesskit-c"
version = "0.23.1"

[dependencies]
accesskit = "0.25.1"
```

### 1.3 Version lines

The core manifest lists each adapter crate on its own version line. These
versions do not move together.

```
$ cat /tmp/scratch/accesskit/.release-please-manifest.json
{"accesskit":"0.25.1","accesskit_consumer":"0.39.1","adapters/macos":"0.27.1",
 "adapters/windows":"0.35.1","adapters/winit":"0.34.1","adapters/unix":"0.24.0",
 "adapters/atspi-common":"0.21.0","adapters/android":"0.9.0","adapters/ios":"0.2.1",
 "example_common":"0.0.1"}
```

| Component | Version at both checkouts |
|---|---|
| `accesskit` core | 0.25.1 |
| `accesskit-c` | 0.23.1 |
| `adapters/macos` | 0.27.1 |
| `adapters/windows` | 0.35.1 |
| `adapters/unix` | 0.24.0 |
| `adapters/atspi-common` | 0.21.0 |
| `adapters/android` | 0.9.0 |
| `adapters/ios` | 0.2.1 |
| `adapters/winit` | 0.34.1 |

### 1.4 What the move means for a port

1. A port must read two upstream repositories. `docs/10-accesskit-core.md` covers
   the first. This document covers the second.
2. The bindings crate carries its own version, 0.23.1. Its `Cargo.toml:20`
   pins the core at 0.25.1, and the header is generated from the pinned core.
   A schema change in the core lands in the header only when the bindings crate
   is regenerated. A port that reads both repositories must pin both.
3. The C header is not a subset of the core. It adds `accesskit_string_free`
   (1472), `accesskit_action_request_free` (2412) and the per-platform adapter
   entry points (2538–3148). None of these exist in the core crate.
4. The header removed 253 lines of platform coverage relative to the core
   before the move and gained 52 platform functions after it.

### 1.5 Growth since the move

```
$ git -C /tmp/scratch/accesskit show 553d9c1^:bindings/c/include/accesskit.h | grep -c ''
2901
```

| File | Pre-move | Now | Change |
|---|---|---|---|
| `include/accesskit.h` | 2901 | 3154 | +253 |
| `src/common.rs` | 1156 | 1234 | +78 |
| `src/geometry.rs` | 185 | 247 | +62 |
| `src/lib.rs` | 178 | 224 | +46 |
| `src/unix.rs` | 81 | 96 | +15 |
| `src/windows.rs` | 154 | 174 | +20 |
| `src/macos.rs` | 247 | 276 | +29 |
| `src/android.rs` | absent | 230 | new |
| `src/ios.rs` | absent | 252 | new |

The pre-move shim had no Android and no iOS file. The pre-move header had an
`accesskit_default_action_verb` enum and a `accesskit_text_decoration` struct;
both are gone. `accesskit_text_decoration_style` (559) replaced the former, and
`accesskit_text_decoration` (774) is now a struct.

```
$ git -C /tmp/scratch/accesskit log --oneline -- bindings/c/ | wc -l
71
```

---

## 2. The header, declaration by declaration

Every line number in this section is a line in
`/tmp/scratch/accesskit-c/include/accesskit.h`.

### 2.0 Counts

| Kind | Count |
|---|---|
| Enum types | 18 |
| Enum variants, all enums | 270 |
| Enum variants, excluding `accesskit_action_data_Tag` | 262 |
| Enum aliases, `typedef uint8_t accesskit_*` | 17 |
| Struct types with a layout | 40 |
| Opaque struct types, forward declared | 18 |
| Struct types in total | 58 |
| Anonymous unions | 1 |
| Function pointer typedefs | 4 |
| Plain scalar typedefs | 2 |
| Exported data objects | 1 |
| Exported function declarations | 496 |
| Exported functions visible on a Linux target | 444 |

The two function counts were obtained two ways that agree.

```
$ grep -oE 'accesskit_[a-z_0-9]+\(' include/accesskit.h | sort -u | wc -l
496
```

496 is the function declaration count, and the regular expression gives it
directly. The four function pointer typedefs at 1110, 1113, 1120 and 1123 are
not in that count and never were: each is written as
`typedef struct accesskit_tree_update *(*accesskit_tree_update_factory)(`, with
the name inside parentheses, so `accesskit_[a-z_0-9]+\(` does not match it.

```
$ gcc -x c -fsyntax-only -aux-info decl.txt include/accesskit.h
$ grep -c 'accesskit.h:.*extern .*accesskit_' decl.txt
444
```

444 is the Linux-visible set. The 52 declarations hidden behind `#if` blocks
are 13 Android, 13 iOS, 16 macOS and 10 Windows. 444 + 52 = 496.

### 2.1 Enums

Each enum is a C++-style scoped enum with an explicit `: uint8_t` base under
`__cplusplus`, and a separate `typedef uint8_t` alias under `#ifndef __cplusplus`.
The cbindgen setting `[enum] prefix_with_name = true` with
`rename_variants = "ScreamingSnakeCase"` produced that shape.

| Enum | Enum line | Alias line | Variants | First variant line | Last variant line |
|---|---|---|---|---|---|
| `accesskit_action` | 64 | 149 | 22 | 72 | 146 |
| `accesskit_aria_current` | 152 | 166 | 7 | 157 | 163 |
| `accesskit_auto_complete` | 169 | 179 | 3 | 174 | 176 |
| `accesskit_has_popup` | 182 | 194 | 5 | 187 | 191 |
| `accesskit_invalid` | 203 | 213 | 3 | 208 | 210 |
| `accesskit_list_style` | 216 | 232 | 6 | 221 | 229 |
| `accesskit_live` | 235 | 245 | 3 | 240 | 242 |
| `accesskit_orientation` | 248 | 263 | 2 | 256 | 260 |
| `accesskit_role` | 278 | 485 | 182 | 283 | 482 |
| `accesskit_scroll_hint` | 492 | 505 | 6 | 497 | 502 |
| `accesskit_scroll_unit` | 512 | 529 | 2 | 522 | 526 |
| `accesskit_sort_direction` | 532 | 542 | 3 | 537 | 539 |
| `accesskit_text_align` | 545 | 556 | 4 | 550 | 553 |
| `accesskit_text_decoration_style` | 559 | 571 | 5 | 564 | 568 |
| `accesskit_text_direction` | 574 | 585 | 4 | 579 | 582 |
| `accesskit_toggled` | 588 | 598 | 3 | 593 | 595 |
| `accesskit_vertical_offset` | 601 | 610 | 2 | 606 | 607 |
| `accesskit_action_data_Tag` | 1009 | none | 8 | 1010 | 1022 |

`accesskit_action_data_Tag` is the only enum written as `typedef enum NAME {`
with a trailing `_Tag` name. It has no `uint8_t` alias. Its variants are the
tag names, not domain values.

#### 2.1.1 `accesskit_action` variants, line by line

| Line | Variant |
|---|---|
| 72 | `ACCESSKIT_ACTION_CLICK` |
| 73 | `ACCESSKIT_ACTION_FOCUS` |
| 74 | `ACCESSKIT_ACTION_BLUR` |
| 75 | `ACCESSKIT_ACTION_COLLAPSE` |
| 76 | `ACCESSKIT_ACTION_EXPAND` |
| 80 | `ACCESSKIT_ACTION_CUSTOM_ACTION` |
| 84 | `ACCESSKIT_ACTION_DECREMENT` |
| 88 | `ACCESSKIT_ACTION_INCREMENT` |
| 89 | `ACCESSKIT_ACTION_HIDE_TOOLTIP` |
| 90 | `ACCESSKIT_ACTION_SHOW_TOOLTIP` |
| 96 | `ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT` |
| 100 | `ACCESSKIT_ACTION_SCROLL_DOWN` |
| 104 | `ACCESSKIT_ACTION_SCROLL_LEFT` |
| 108 | `ACCESSKIT_ACTION_SCROLL_RIGHT` |
| 112 | `ACCESSKIT_ACTION_SCROLL_UP` |
| 117 | `ACCESSKIT_ACTION_SCROLL_INTO_VIEW` |
| 123 | `ACCESSKIT_ACTION_SCROLL_TO_POINT` |
| 128 | `ACCESSKIT_ACTION_SET_SCROLL_OFFSET` |
| 133 | `ACCESSKIT_ACTION_SET_TEXT_SELECTION` |
| 139 | `ACCESSKIT_ACTION_SET_SEQUENTIAL_FOCUS_NAVIGATION_STARTING_POINT` |
| 145 | `ACCESSKIT_ACTION_SET_VALUE` |
| 146 | `ACCESSKIT_ACTION_SHOW_CONTEXT_MENU` |

Four variants carry a data requirement, stated in the header comments at 78,
94, 115, 120, 125 and 141. They are listed in section 5.4.

#### 2.1.2 `accesskit_action_data_Tag` variants, line by line

| Line | Variant | Payload field in the union |
|---|---|---|
| 1010 | `ACCESSKIT_ACTION_DATA_CUSTOM_ACTION` | `int32_t custom_action` (1029) |
| 1011 | `ACCESSKIT_ACTION_DATA_VALUE` | `char *value` (1032) |
| 1012 | `ACCESSKIT_ACTION_DATA_NUMERIC_VALUE` | `double numeric_value` (1035) |
| 1013 | `ACCESSKIT_ACTION_DATA_SCROLL_UNIT` | `accesskit_scroll_unit scroll_unit` (1038) |
| 1019 | `ACCESSKIT_ACTION_DATA_SCROLL_HINT` | `accesskit_scroll_hint scroll_hint` (1041) |
| 1020 | `ACCESSKIT_ACTION_DATA_SCROLL_TO_POINT` | `struct accesskit_point scroll_to_point` (1044) |
| 1021 | `ACCESSKIT_ACTION_DATA_SET_SCROLL_OFFSET` | `struct accesskit_point set_scroll_offset` (1047) |
| 1022 | `ACCESSKIT_ACTION_DATA_SET_TEXT_SELECTION` | `struct accesskit_text_selection set_text_selection` (1050) |

#### 2.1.3 Remaining enums, all variants

| Enum | Line | Variants |
|---|---|---|
| `accesskit_aria_current` | 157, 158, 159, 160, 161, 162, 163 | `_FALSE`, `_TRUE`, `_PAGE`, `_STEP`, `_LOCATION`, `_DATE`, `_TIME` |
| `accesskit_auto_complete` | 174, 175, 176 | `_INLINE`, `_LIST`, `_BOTH` |
| `accesskit_has_popup` | 187, 188, 189, 190, 191 | `_MENU`, `_LISTBOX`, `_TREE`, `_GRID`, `_DIALOG` |
| `accesskit_invalid` | 208, 209, 210 | `_TRUE`, `_GRAMMAR`, `_SPELLING` |
| `accesskit_list_style` | 221, 222, 223, 224, 225, 229 | `_CIRCLE`, `_DISC`, `_IMAGE`, `_NUMERIC`, `_SQUARE`, `_OTHER` |
| `accesskit_live` | 240, 241, 242 | `_OFF`, `_POLITE`, `_ASSERTIVE` |
| `accesskit_orientation` | 256, 260 | `_HORIZONTAL`, `_VERTICAL` |
| `accesskit_scroll_hint` | 497, 498, 499, 500, 501, 502 | `_TOP_LEFT`, `_BOTTOM_RIGHT`, `_TOP_EDGE`, `_BOTTOM_EDGE`, `_LEFT_EDGE`, `_RIGHT_EDGE` |
| `accesskit_scroll_unit` | 522, 526 | `_ITEM`, `_PAGE` |
| `accesskit_sort_direction` | 537, 538, 539 | `_ASCENDING`, `_DESCENDING`, `_OTHER` |
| `accesskit_text_align` | 550, 551, 552, 553 | `_LEFT`, `_RIGHT`, `_CENTER`, `_JUSTIFY` |
| `accesskit_text_decoration_style` | 564, 565, 566, 567, 568 | `_SOLID`, `_DOTTED`, `_DASHED`, `_DOUBLE`, `_WAVY` |
| `accesskit_text_direction` | 579, 580, 581, 582 | `_LEFT_TO_RIGHT`, `_RIGHT_TO_LEFT`, `_TOP_TO_BOTTOM`, `_BOTTOM_TO_TOP` |
| `accesskit_toggled` | 593, 594, 595 | `_FALSE`, `_TRUE`, `_MIXED` |
| `accesskit_vertical_offset` | 606, 607 | `_SUBSCRIPT`, `_SUPERSCRIPT` |

#### 2.1.4 `accesskit_role`, 182 variants

`accesskit_role` runs from line 283 (`ACCESSKIT_ROLE_UNKNOWN`) to line 482
(`ACCESSKIT_ROLE_TERMINAL`). Six variants carry a header comment:

| Line | Variant | Header comment lines |
|---|---|---|
| 294 | `ACCESSKIT_ROLE_LIST_MARKER` | 291–293 |
| 305 | `ACCESSKIT_ROLE_GENERIC_CONTAINER` | 300–304 |
| 476 | `ACCESSKIT_ROLE_LIST_GRID` | 471–475 |
| 482 | `ACCESSKIT_ROLE_TERMINAL` | 477–481 |

The enum header comment at 266–277 states the ordering rule:

> Like the AccessKit schema as a whole, this list is largely taken from
> Chromium. However, unlike Chromium's alphabetized list, this list is ordered
> roughly by expected usage frequency (with the notable exception of
> [`Role::Unknown`]). This is more efficient in serialization formats where
> integers use a variable-length encoding.

That comment is a wire-format constraint on the integer values. A Zig port that
reorders the enum changes the serialized role numbers. See section 9.2.

### 2.2 Opaque struct types

Eighteen struct types are forward declared with no body. C callers can hold
pointers to them and cannot read or write their contents.

| Type | Typedef line | Guard |
|---|---|---|
| `accesskit_android_adapter` | 614 | `__ANDROID__` |
| `accesskit_android_injecting_adapter` | 618 | `__ANDROID__` |
| `accesskit_android_platform_action` | 623 | `__ANDROID__` |
| `accesskit_android_queued_events` | 628 | `__ANDROID__` |
| `accesskit_custom_action` | 631 | none |
| `accesskit_ios_adapter` | 635 | `ACCESSKIT_IOS` \| `TVOS` \| `VISIONOS` \| `WATCHOS` |
| `accesskit_ios_queued_events` | 640 | same |
| `accesskit_ios_subclassing_adapter` | 645 | same |
| `accesskit_macos_adapter` | 650 | `ACCESSKIT_MACOS` |
| `accesskit_macos_queued_events` | 654 | `ACCESSKIT_MACOS` |
| `accesskit_macos_subclassing_adapter` | 658 | `ACCESSKIT_MACOS` |
| `accesskit_node` | 662 | none |
| `accesskit_tree_info` | 664 | none |
| `accesskit_tree_update` | 666 | none |
| `accesskit_unix_adapter` | 670 | Linux, DragonFly, FreeBSD, NetBSD, OpenBSD |
| `accesskit_windows_adapter` | 674 | `_WIN32` |
| `accesskit_windows_queued_events` | 678 | `_WIN32` |
| `accesskit_windows_subclassing_adapter` | 682 | `_WIN32` |

Four of the 18 are unconditional: `accesskit_custom_action`, `accesskit_node`,
`accesskit_tree_info` and `accesskit_tree_update`. The other 14 sit behind a
platform guard. A machine count over the guard block gives the same 18:

```
$ sed -n '613,684p' include/accesskit.h | grep -cE '^typedef struct accesskit_'
18
```

### 2.3 Struct types with a layout

All 40 are `#[repr(C)]`-equivalent. Optional structs share one comment, quoted
verbatim from the header:

> Represents an optional value.
>
> If `has_value` is false, do not read the `value` field.

That comment appears at 693, 711, 721, 731, 741, 761, 779, 800, 810, 820, 830,
840, 850, 860, 870, 880, 890, 900, 910, 920, 960, 980 and 1055.

| Struct | Line | Fields, in order |
|---|---|---|
| `accesskit_node_ids` | 688 | `size_t length;` (689), `const accesskit_node_id *values;` (690) |
| `accesskit_opt_node_id` | 698 | `bool has_value;` (699), `accesskit_node_id value;` (700) |
| `accesskit_tree_id` | 707 | `uint8_t bytes[16];` (708) |
| `accesskit_opt_tree_id` | 716 | `bool has_value;` (717), `struct accesskit_tree_id value;` (718) |
| `accesskit_opt_double` | 726 | `bool has_value;` (727), `double value;` (728) |
| `accesskit_opt_float` | 736 | `bool has_value;` (737), `float value;` (738) |
| `accesskit_opt_index` | 746 | `bool has_value;` (747), `size_t value;` (748) |
| `accesskit_color` | 754 | `uint8_t red;` (755), `green` (756), `blue` (757), `alpha` (758) |
| `accesskit_opt_color` | 766 | `bool has_value;` (767), `struct accesskit_color value;` (768) |
| `accesskit_text_decoration` | 774 | `accesskit_text_decoration_style style;` (775), `struct accesskit_color color;` (776) |
| `accesskit_opt_text_decoration` | 784 | `bool has_value;` (785), `struct accesskit_text_decoration value;` (786) |
| `accesskit_lengths` | 789 | `size_t length;` (790), `const uint8_t *values;` (791) |
| `accesskit_opt_coords` | 794 | `bool has_value;` (795), `size_t length;` (796), `const float *values;` (797) |
| `accesskit_opt_bool` | 805 | `bool has_value;` (806), `bool value;` (807) |
| `accesskit_opt_invalid` | 815 | `bool has_value;` (816), `accesskit_invalid value;` (817) |
| `accesskit_opt_toggled` | 825 | `bool has_value;` (826), `accesskit_toggled value;` (827) |
| `accesskit_opt_live` | 835 | `bool has_value;` (836), `accesskit_live value;` (837) |
| `accesskit_opt_text_direction` | 845 | `bool has_value;` (846), `accesskit_text_direction value;` (847) |
| `accesskit_opt_orientation` | 855 | `bool has_value;` (856), `accesskit_orientation value;` (857) |
| `accesskit_opt_sort_direction` | 865 | `bool has_value;` (866), `accesskit_sort_direction value;` (867) |
| `accesskit_opt_aria_current` | 875 | `bool has_value;` (876), `accesskit_aria_current value;` (877) |
| `accesskit_opt_auto_complete` | 885 | `bool has_value;` (886), `accesskit_auto_complete value;` (887) |
| `accesskit_opt_has_popup` | 895 | `bool has_value;` (896), `accesskit_has_popup value;` (897) |
| `accesskit_opt_list_style` | 905 | `bool has_value;` (906), `accesskit_list_style value;` (907) |
| `accesskit_opt_text_align` | 915 | `bool has_value;` (916), `accesskit_text_align value;` (917) |
| `accesskit_opt_vertical_offset` | 925 | `bool has_value;` (926), `accesskit_vertical_offset value;` (927) |
| `accesskit_affine` | 934 | `double _0[6];` (935) |
| `accesskit_rect` | 941 | `double x0;` (945), `y0` (949), `x1` (953), `y1` (957) |
| `accesskit_opt_rect` | 965 | `bool has_value;` (966), `struct accesskit_rect value;` (967) |
| `accesskit_text_position` | 970 | `accesskit_node_id node;` (971), `size_t character_index;` (972) |
| `accesskit_text_selection` | 975 | `struct accesskit_text_position anchor;` (976), `focus` (977) |
| `accesskit_opt_text_selection` | 985 | `bool has_value;` (986), `struct accesskit_text_selection value;` (987) |
| `accesskit_custom_actions` | 990 | `size_t length;` (991), `struct accesskit_custom_action **values;` (992) |
| `accesskit_point` | 998 | `double x;` (1002), `double y;` (1006) |
| `accesskit_action_data` | 1025 | `accesskit_action_data_Tag tag;` (1026), anonymous union (1027–1052) |
| `accesskit_opt_action_data` | 1060 | `bool has_value;` (1061), `struct accesskit_action_data value;` (1062) |
| `accesskit_action_request` | 1065 | `accesskit_action action;` (1066), `struct accesskit_tree_id target_tree;` (1067), `accesskit_node_id target_node;` (1068), `struct accesskit_opt_action_data data;` (1069) |
| `accesskit_vec2` | 1079 | `double x;` (1083), `double y;` (1087) |
| `accesskit_size` | 1093 | `double width;` (1097), `double height;` (1101) |
| `accesskit_opt_lresult` | 1131 | `bool has_value;` (1132), `LRESULT value;` (1133), `_WIN32` only |

Three of these deserve a note for a port.

`accesskit_opt_*` structs. The header declares 25. Exactly one is platform-gated,
`accesskit_opt_lresult` at 1131, under `#if defined(_WIN32)` at 1125, so 24 are
ungated. The Rust shim stores the value in a `std::mem::MaybeUninit`, so every
one of the 25 carries an uninitialised payload when `has_value` is false. A Zig
port uses `?T` with a plain optional payload and no uninitialised memory. See
section 6.2.

`accesskit_affine`. The only field is `double _0[6]`. The `_0` name is what
cbindgen emits for a Rust tuple struct. The header comment at 930–933:

> A 2D affine transform. Derived from
> [kurbo](https://github.com/linebender/kurbo).

The six coefficients have no names in C. The Rust type is `Affine([f64; 6])`.
Row-major order with the last row implicit is the kurbo convention; see
`src/geometry.rs:9-33` for the constructors that fix the order.

`accesskit_opt_lresult` at 1131. This is the only struct that depends on a host
SDK type. It is inside `#if defined(_WIN32)` at 1125 and needs `windows.h`,
which `accesskit.h` includes at 17. A Zig port on a non-Windows target cannot
compile this struct from the header as written.

### 2.4 The one union

`accesskit_action_data` (1025) holds one anonymous union at 1027. The union has
eight anonymous structs, one per tag. Anonymous members with `#[repr(C)]` do
not change the union layout, so the eight payloads overlay.

| Union member | Line | Payload |
|---|---|---|
| 1 | 1028–1030 | `int32_t custom_action;` (1029) |
| 2 | 1031–1033 | `char *value;` (1032) |
| 3 | 1034–1036 | `double numeric_value;` (1035) |
| 4 | 1037–1039 | `accesskit_scroll_unit scroll_unit;` (1038) |
| 5 | 1040–1042 | `accesskit_scroll_hint scroll_hint;` (1041) |
| 6 | 1043–1045 | `struct accesskit_point scroll_to_point;` (1044) |
| 7 | 1046–1048 | `struct accesskit_point set_scroll_offset;` (1047) |
| 8 | 1049–1051 | `struct accesskit_text_selection set_text_selection;` (1050) |

Member 2 holds a `char *`. Its ownership is the only pointer in the union. See
section 4.6.

### 2.5 Function pointer typedefs

Four typedefs. Each is the complete seam between the library and the adapter
author.

| Typedef | Line | Signature |
|---|---|---|
| `accesskit_tree_update_factory` | 1110 | `struct accesskit_tree_update *(*)(accesskit_tree_update_factory_userdata)` |
| `accesskit_activation_handler_callback` | 1113 | `struct accesskit_tree_update *(*)(void *userdata)` |
| `accesskit_action_handler_callback` | 1120 | `void (*)(struct accesskit_action_request *request, void *userdata)` |
| `accesskit_deactivation_handler_callback` | 1123 | `void (*)(void *userdata)` |

Ownership comments, quoted verbatim:

1110, comment at 1106–1109:

> This function can't return a null pointer. Ownership of the returned value
> will be transferred to the caller.

1120, comment at 1116–1119:

> Ownership of `request` is transferred to the callback. `request` must
> be freed using `accesskit_action_request_free`.

1113 and 1123 have no comment in the header.

Section 3 gives the per-parameter detail for each of the four.

### 2.6 Plain scalar typedefs

| Typedef | Line | Definition |
|---|---|---|
| `accesskit_node_id` | 686 | `typedef uint64_t accesskit_node_id;` |
| `accesskit_tree_update_factory_userdata` | 1104 | `typedef void *accesskit_tree_update_factory_userdata;` |

`accesskit_tree_update_factory_userdata` is a distinct typedef from a plain
`void *`. cbindgen emits the `#[repr(transparent)]` newtype at
`src/common.rs:1227-1230` as a bare `void *`. The distinct name buys nothing in
C. In Zig it is noise. See section 6.2.

### 2.7 Exported data object

| Object | Line | Definition |
|---|---|---|
| `ACCESSKIT_TREE_ID_ROOT` | 1141 | `extern const struct accesskit_tree_id ACCESSKIT_TREE_ID_ROOT;` |

Defined in Rust at `src/common.rs:226-227` as
`tree_id { bytes: [0; 16] }`.

### 2.8 Exported functions, node family

358 functions carry the `accesskit_node_` prefix. They are grouped by the
property they act on. Each row gives the header line of the function name.

#### 2.8.1 Role

| Line | Function |
|---|---|
| 1143 | `accesskit_node_role` |
| 1145 | `accesskit_node_set_role` |

#### 2.8.2 Action sets

| Line | Function | Header comment |
|---|---|---|
| 1147 | `accesskit_node_supports_action` | none |
| 1150 | `accesskit_node_add_action` | none |
| 1153 | `accesskit_node_remove_action` | none |
| 1156 | `accesskit_node_clear_actions` | none |
| 1162 | `accesskit_node_child_supports_action` | 1158–1161 |
| 1169 | `accesskit_node_add_child_action` | 1165–1168 |
| 1176 | `accesskit_node_remove_child_action` | 1172–1175 |
| 1183 | `accesskit_node_clear_child_actions` | 1179–1182 |

#### 2.8.3 Boolean flags, 18 properties, 54 functions

Each property has a getter taking `const struct accesskit_node *`, a setter
taking `struct accesskit_node *` with no value, and a clearer.

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| hidden | 1185 `is_hidden` | 1187 `set_hidden` | 1189 `clear_hidden` |
| multiselectable | 1191 | 1193 | 1195 |
| required | 1197 | 1199 | 1201 |
| visited | 1203 | 1205 | 1207 |
| busy | 1209 | 1211 | 1213 |
| live_atomic | 1215 | 1217 | 1219 |
| modal | 1221 | 1223 | 1225 |
| touch_transparent | 1227 | 1229 | 1231 |
| read_only | 1233 | 1235 | 1237 |
| disabled | 1239 | 1241 | 1243 |
| italic | 1245 | 1247 | 1249 |
| clips_children | 1251 `clips_children` | 1253 | 1255 |
| is_line_breaking_object | 1257 | 1259 `set_is_line_breaking_object` | 1261 |
| is_page_breaking_object | 1263 | 1265 | 1267 |
| is_spelling_error | 1269 | 1271 | 1273 |
| is_grammar_error | 1275 | 1277 | 1279 |
| is_search_match | 1281 | 1283 | 1285 |
| is_suggestion | 1287 | 1289 | 1291 |

#### 2.8.4 Node identifier lists, 8 properties, 32 functions

Every setter in this group carries the comment at 1296–1298 or a copy of it:
`Caller is responsible for freeing `values`.` Every getter returns
`struct accesskit_node_ids` **by value**.

| Property | Getter | Setter | Pusher | Clearer |
|---|---|---|---|---|
| children | 1293 | 1299 | 1302 `push_child` | 1305 |
| controls | 1307 | 1313 | 1316 `push_controlled` | 1319 |
| details | 1321 | 1327 | 1330 `push_detail` | 1333 |
| described_by | 1335 | 1341 | 1344 | 1347 |
| flow_to | 1349 | 1355 | 1358 | 1361 |
| labelled_by | 1363 | 1369 | 1372 | 1375 |
| owns | 1377 | 1383 | 1386 `push_owned` | 1389 |
| radio_group | 1391 | 1397 | 1400 `push_to_radio_group` | 1403 |

#### 2.8.5 Scalar node identifier properties, 7 properties, 21 functions

Each returns `struct accesskit_opt_node_id` by value.

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| active_descendant | 1405 | 1408 | 1411 |
| error_message | 1413 | 1416 | 1419 |
| in_page_link_target | 1421 | 1424 | 1427 |
| member_of | 1429 | 1432 | 1435 |
| next_on_line | 1437 | 1440 | 1443 |
| previous_on_line | 1445 | 1448 | 1451 |
| popup_for | 1453 | 1456 | 1459 |

#### 2.8.6 Tree identifier property, 3 functions

| Line | Function |
|---|---|
| 1461 | `accesskit_node_tree_id` |
| 1464 | `accesskit_node_set_tree_id` |
| 1467 | `accesskit_node_clear_tree_id` |

#### 2.8.7 String properties, 21 properties, 84 functions

Each property has four functions. The getter comment is `Caller must call
`accesskit_string_free` with the return value.` Both setters carry
`Caller is responsible for freeing the memory pointed by `value`.` Only these
21 properties have a `_with_length` setter. That set was added in release
0.18.0 as a non-breaking addition (section 7.4).

| Property | Getter | Setter | Setter with length | Clearer |
|---|---|---|---|---|
| label | 1477 | 1482 | 1487 | 1490 |
| description | 1495 | 1500 | 1506 | 1510 |
| value | 1515 | 1520 | 1525 | 1528 |
| access_key | 1533 | 1538 | 1544 | 1548 |
| author_id | 1553 | 1558 | 1564 | 1567 |
| class_name | 1572 | 1577 | 1583 | 1587 |
| font_family | 1592 | 1597 | 1603 | 1607 |
| html_id | 1612 | 1617 | 1622 | 1625 |
| html_tag | 1630 | 1635 | 1641 | 1644 |
| inner_html | 1649 | 1654 | 1660 | 1664 |
| keyboard_shortcut | 1669 | 1674 | 1680 | 1683 |
| language | 1688 | 1693 | 1699 | 1702 |
| placeholder | 1707 | 1712 | 1718 | 1722 |
| role_description | 1727 | 1732 | 1738 | 1741 |
| state_description | 1746 | 1751 | 1757 | 1760 |
| tooltip | 1765 | 1770 | 1775 | 1778 |
| url | 1783 | 1788 | 1793 | 1796 |
| row_index_text | 1801 | 1806 | 1812 | 1816 |
| column_index_text | 1821 | 1826 | 1832 | 1835 |
| braille_label | 1840 | 1845 | 1851 | 1855 |
| braille_role_description | 1860 | 1866 | 1872 | 1875 |

`accesskit_string_free` at 1472 sits between this group and the numeric group.
Its comment at 1469–1471:

> Only call this function with a string that originated from AccessKit.

#### 2.8.8 Double properties, 11 properties, 33 functions

Each returns `struct accesskit_opt_double` by value.

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| scroll_x | 1877 | 1880 | 1882 |
| scroll_x_min | 1884 | 1887 | 1889 |
| scroll_x_max | 1891 | 1894 | 1896 |
| scroll_y | 1898 | 1901 | 1903 |
| scroll_y_min | 1905 | 1908 | 1910 |
| scroll_y_max | 1912 | 1915 | 1917 |
| numeric_value | 1919 | 1922 | 1925 |
| min_numeric_value | 1927 | 1930 | 1933 |
| max_numeric_value | 1935 | 1938 | 1941 |
| numeric_value_step | 1943 | 1946 | 1949 |
| numeric_value_jump | 1951 | 1954 | 1957 |

#### 2.8.9 Float properties, 2 properties, 6 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| font_size | 1959 | 1962 | 1964 |
| font_weight | 1966 | 1969 | 1971 |

#### 2.8.10 Index properties, 9 properties, 27 functions

Each returns `struct accesskit_opt_index` by value. The setter parameter is
`size_t`.

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| row_count | 1973 | 1976 | 1978 |
| column_count | 1980 | 1983 | 1985 |
| row_index | 1987 | 1990 | 1992 |
| column_index | 1994 | 1997 | 1999 |
| row_span | 2001 | 2004 | 2006 |
| column_span | 2008 | 2011 | 2013 |
| level | 2015 | 2018 | 2020 |
| size_of_set | 2022 | 2025 | 2027 |
| position_in_set | 2029 | 2032 | 2035 |

#### 2.8.11 Colour properties, 3 properties, 9 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| color_value | 2037 | 2040 | 2043 |
| background_color | 2045 | 2048 | 2051 |
| foreground_color | 2053 | 2056 | 2059 |

#### 2.8.12 Text decoration properties, 3 properties, 9 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| overline | 2061 | 2064 | 2067 |
| strikethrough | 2069 | 2072 | 2075 |
| underline | 2077 | 2080 | 2083 |

#### 2.8.13 Byte-slice properties, 2 properties, 6 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| character_lengths | 2085 | 2091 | 2094 |
| word_starts | 2096 | 2102 | 2105 |

The getters return `struct accesskit_lengths` by value. The setters carry
`Caller is responsible for freeing `values`.` at 2088–2090 and 2099–2101.

#### 2.8.14 Float-slice properties, 2 properties, 6 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| character_positions | 2107 | 2113 | 2116 |
| character_widths | 2118 | 2124 | 2127 |

The getters return `struct accesskit_opt_coords` by value. The setters carry
`Caller is responsible for freeing `values`.` at 2110–2112 and 2121–2123.

#### 2.8.15 Optional boolean properties, 2 properties, 6 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| is_expanded | 2129 | 2132 `set_expanded` | 2134 |
| is_selected | 2136 | 2139 `set_selected` | 2141 |

#### 2.8.16 Unique-enum properties, 12 properties, 36 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| invalid | 2143 | 2146 | 2149 |
| toggled | 2151 | 2154 | 2157 |
| live | 2159 | 2162 | 2164 |
| text_direction | 2166 | 2169 | 2172 |
| orientation | 2174 | 2177 | 2180 |
| sort_direction | 2182 | 2185 | 2188 |
| aria_current | 2190 | 2193 | 2196 |
| auto_complete | 2198 | 2201 | 2204 |
| has_popup | 2206 | 2209 | 2212 |
| list_style | 2214 | 2217 | 2220 |
| text_align | 2222 | 2225 | 2228 |
| vertical_offset | 2230 | 2233 | 2236 |

#### 2.8.17 Geometry properties, 3 properties, 9 functions

| Property | Getter | Setter | Clearer |
|---|---|---|---|
| transform | 2238 | 2241 | 2244 |
| bounds | 2246 | 2249 | 2252 |
| text_selection | 2254 | 2257 | 2260 |

`accesskit_node_transform` at 2238 is the only node getter in the header that
returns a raw pointer: `const struct accesskit_affine *`. It returns null when
the property is absent.

#### 2.8.18 Custom action list on a node, 4 functions

| Line | Function | Header comment |
|---|---|---|
| 2296 | `accesskit_node_custom_actions` | 2293–2295 |
| 2303 | `accesskit_node_set_custom_actions` | 2299–2302 |
| 2310 | `accesskit_node_push_custom_action` | 2307–2309 |
| 2313 | `accesskit_node_clear_custom_actions` | none |

#### 2.8.19 Node lifetime, 3 functions

| Line | Function | Header comment |
|---|---|---|
| 2315 | `accesskit_node_new` | none |
| 2317 | `accesskit_node_free` | none |
| 2322 | `accesskit_node_debug` | 2319–2321 |

### 2.9 Exported functions, custom action family

| Line | Function | Header comment |
|---|---|---|
| 2262 | `accesskit_custom_action_new` | none |
| 2264 | `accesskit_custom_action_free` | none |
| 2266 | `accesskit_custom_action_id` | none |
| 2269 | `accesskit_custom_action_set_id` | none |
| 2275 | `accesskit_custom_action_description` | 2272–2274 |
| 2281 | `accesskit_custom_action_set_description` | 2278–2280 |
| 2287 | `accesskit_custom_action_set_description_with_length` | 2284–2286 |
| 2291 | `accesskit_custom_actions_free` | none |

`accesskit_custom_action_new` and `accesskit_custom_action_free` were added in
release 0.18.0, when the type became opaque. Before that release the type had a
public layout. See section 7.4.

### 2.10 Exported functions, tree info family

| Line | Function | Header comment |
|---|---|---|
| 2324 | `accesskit_tree_info_new` | none |
| 2326 | `accesskit_tree_info_free` | none |
| 2331 | `accesskit_tree_info_get_toolkit_name` | 2328–2330 |
| 2337 | `accesskit_tree_info_set_toolkit_name` | 2334–2336 |
| 2343 | `accesskit_tree_info_set_toolkit_name_with_length` | 2340–2342 |
| 2346 | `accesskit_tree_info_clear_toolkit_name` | none |
| 2351 | `accesskit_tree_info_get_toolkit_version` | 2348–2350 |
| 2357 | `accesskit_tree_info_set_toolkit_version` | 2354–2356 |
| 2363 | `accesskit_tree_info_set_toolkit_version_with_length` | 2360–2362 |
| 2367 | `accesskit_tree_info_clear_toolkit_version` | none |
| 2373 | `accesskit_tree_info_debug` | 2370–2372 |

### 2.11 Exported functions, tree update family

| Line | Function | Header comment |
|---|---|---|
| 2375 | `accesskit_tree_update_with_focus` | none |
| 2378 | `accesskit_tree_update_with_capacity_and_focus` | none |
| 2381 | `accesskit_tree_update_free` | none |
| 2387 | `accesskit_tree_update_push_node` | 2383–2386 |
| 2391 | `accesskit_tree_update_set_tree_info` | none |
| 2394 | `accesskit_tree_update_clear_tree_info` | none |
| 2397 | `accesskit_tree_update_set_focus` | none |
| 2400 | `accesskit_tree_update_get_tree_id` | none |
| 2403 | `accesskit_tree_update_set_tree_id` | none |
| 2409 | `accesskit_tree_update_debug` | 2406–2408 |
| 2412 | `accesskit_action_request_free` | none |

`accesskit_tree_update_set_tree_info` at 2391 has no ownership comment. The shim
consumes the pointer. See section 4.5.

### 2.12 Exported functions, geometry family, 49 functions

These functions take and return geometry values by value. None of them takes a
pointer to allocate, and none of them returns a pointer that the caller frees.

| Line | Function | Line | Function |
|---|---|---|---|
| 2414 | `accesskit_affine_identity` | 2486 | `accesskit_rect_origin` |
| 2416 | `accesskit_affine_flip_y` | 2488 | `accesskit_rect_size` |
| 2418 | `accesskit_affine_flip_x` | 2490 | `accesskit_rect_abs` |
| 2420 | `accesskit_affine_scale` | 2492 | `accesskit_rect_area` |
| 2422 | `accesskit_affine_scale_non_uniform` | 2494 | `accesskit_rect_is_empty` |
| 2425 | `accesskit_affine_translate` | 2496 | `accesskit_rect_contains` |
| 2427 | `accesskit_affine_map_unit_square` | 2499 | `accesskit_rect_union` |
| 2430 | `accesskit_affine_determinant` | 2502 | `accesskit_rect_union_pt` |
| 2432 | `accesskit_affine_inverse` | 2505 | `accesskit_rect_intersect` |
| 2435 | `accesskit_affine_transform_rect_bbox` | 2508 | `accesskit_rect_translate` |
| 2438 | `accesskit_affine_is_finite` | 2511 | `accesskit_size_to_vec2` |
| 2440 | `accesskit_affine_is_nan` | 2513 | `accesskit_size_scale` |
| 2442 | `accesskit_affine_mul` | 2516 | `accesskit_size_add` |
| 2445 | `accesskit_affine_transform_point` | 2519 | `accesskit_size_sub` |
| 2448 | `accesskit_point_to_vec2` | 2522 | `accesskit_vec2_to_point` |
| 2450 | `accesskit_point_add_vec2` | 2524 | `accesskit_vec2_to_size` |
| 2453 | `accesskit_point_sub_vec2` | 2526 | `accesskit_vec2_add` |
| 2456 | `accesskit_point_sub_point` | 2529 | `accesskit_vec2_sub` |
| 2459 | `accesskit_rect_new` | 2532 | `accesskit_vec2_scale` |
| 2462 | `accesskit_rect_from_points` | 2535 | `accesskit_vec2_neg` |
| 2465 | `accesskit_rect_from_origin_size` | 2474 | `accesskit_rect_width` |
| 2468 | `accesskit_rect_with_origin` | 2476 | `accesskit_rect_height` |
| 2471 | `accesskit_rect_with_size` | 2478 | `accesskit_rect_min_x` |
| 2480 | `accesskit_rect_max_x` | 2482 | `accesskit_rect_min_y` |
| 2484 | `accesskit_rect_max_y` | | |

### 2.13 Exported functions, platform family, 58 functions

All 58 sit behind `#if` guards. Their lines are the header line of the function
name, not of the return type.

#### 2.13.1 Android, 13 functions, guard `__ANDROID__`

| Line | Function |
|---|---|
| 2539 | `accesskit_android_platform_action_from_java` |
| 2544 | `accesskit_android_platform_action_free` |
| 2552 | `accesskit_android_queued_events_raise` |
| 2557 | `accesskit_android_adapter_new` |
| 2561 | `accesskit_android_adapter_free` |
| 2570 | `accesskit_android_adapter_update_if_active` |
| 2577 | `accesskit_android_adapter_create_accessibility_node_info` |
| 2585 | `accesskit_android_adapter_find_focus` |
| 2598 | `accesskit_android_adapter_perform_action` |
| 2611 | `accesskit_android_adapter_on_hover_event` |
| 2619 | `accesskit_android_injecting_adapter_new` |
| 2628 | `accesskit_android_injecting_adapter_free` |
| 2633 | `accesskit_android_injecting_adapter_update_if_active` |

#### 2.13.2 iOS family, 13 functions, guard `ACCESSKIT_IOS` or `TVOS` or `VISIONOS` or `WATCHOS`

| Line | Function |
|---|---|
| 2644 | `accesskit_ios_queued_events_raise` |
| 2658 | `accesskit_ios_adapter_new` |
| 2669 | `accesskit_ios_adapter_free` |
| 2678 | `accesskit_ios_adapter_update_if_active` |
| 2694 | `accesskit_ios_adapter_view_did_appear` |
| 2704 | `accesskit_ios_adapter_is_accessibility_element` |
| 2715 | `accesskit_ios_adapter_accessibility_elements` |
| 2726 | `accesskit_ios_adapter_hit_test` |
| 2735 | `accesskit_ios_adapter_debug` |
| 2747 | `accesskit_ios_subclassing_adapter_new` |
| 2771 | `accesskit_ios_subclassing_adapter_for_window` |
| 2782 | `accesskit_ios_subclassing_adapter_free` |
| 2793 | `accesskit_ios_subclassing_adapter_update_if_active` |

#### 2.13.3 macOS, 16 functions, guard `ACCESSKIT_MACOS`

| Line | Function |
|---|---|
| 2803 | `accesskit_macos_queued_events_raise` |
| 2813 | `accesskit_macos_adapter_new` |
| 2820 | `accesskit_macos_adapter_free` |
| 2828 | `accesskit_macos_adapter_update_if_active` |
| 2842 | `accesskit_macos_adapter_update_view_focus_state` |
| 2851 | `accesskit_macos_adapter_view_children` |
| 2862 | `accesskit_macos_adapter_focus` |
| 2873 | `accesskit_macos_adapter_hit_test` |
| 2883 | `accesskit_macos_adapter_debug` |
| 2894 | `accesskit_macos_subclassing_adapter_new` |
| 2913 | `accesskit_macos_subclassing_adapter_for_window` |
| 2921 | `accesskit_macos_subclassing_adapter_free` |
| 2931 | `accesskit_macos_subclassing_adapter_update_if_active` |
| 2945 | `accesskit_macos_subclassing_adapter_update_view_focus_state` |
| 2966 | `accesskit_macos_add_focus_forwarder_to_window_class` |
| 2988 | `accesskit_macos_add_focus_forwarder_to_window_class_with_length` |

#### 2.13.4 Unix, 6 functions, guard Linux or DragonFly or FreeBSD or NetBSD or OpenBSD

| Line | Function |
|---|---|
| 2997 | `accesskit_unix_adapter_new` |
| 3008 | `accesskit_unix_adapter_free` |
| 3022 | `accesskit_unix_adapter_set_root_window_bounds` |
| 3029 | `accesskit_unix_adapter_update_if_active` |
| 3040 | `accesskit_unix_adapter_update_window_focus_state` |
| 3049 | `accesskit_unix_adapter_debug` |

#### 2.13.5 Windows, 10 functions, guard `_WIN32`

| Line | Function |
|---|---|
| 3057 | `accesskit_windows_queued_events_raise` |
| 3062 | `accesskit_windows_adapter_new` |
| 3069 | `accesskit_windows_adapter_free` |
| 3078 | `accesskit_windows_adapter_update_if_active` |
| 3092 | `accesskit_windows_adapter_update_window_focus_state` |
| 3097 | `accesskit_windows_adapter_handle_wm_getobject` |
| 3107 | `accesskit_windows_adapter_debug` |
| 3126 | `accesskit_windows_subclassing_adapter_new` |
| 3134 | `accesskit_windows_subclassing_adapter_free` |
| 3144 | `accesskit_windows_subclassing_adapter_update_if_active` |

### 2.14 Preprocessor conditionals in the header

| Lines | Condition | Sets |
|---|---|---|
| 16–18 | `_WIN32` | includes `<windows.h>`, so `HWND`, `WPARAM`, `LPARAM` and `LRESULT` exist |
| 19–21 | `__ANDROID__` | includes `<jni.h>`, so `JNIEnv`, `jint`, `jobject`, `jfloat` exist |
| 22–59 | `__APPLE__` | includes `<TargetConditionals.h>`, forces six `TARGET_OS_*` macros to 0, then defines `ACCESSKIT_MACOS`, `ACCESSKIT_IOS`, `ACCESSKIT_TVOS`, `ACCESSKIT_WATCHOS`, `ACCESSKIT_VISIONOS` |
| 613–684 | per-platform | the 18 opaque struct typedefs |
| 1125–1135 | `_WIN32` | `accesskit_opt_lresult` |
| 1137–1139 | `__cplusplus` | opens `extern "C" {` |
| 3150–3152 | `__cplusplus` | closes `extern "C"` |

The `__APPLE__` block exists only because the header is compiled by cbindgen
for a macOS target as well as by a C compiler. The six `TARGET_OS_*` defaults
at 26–43 are copied verbatim from `cbindgen.toml:19-38`.

---

## 3. The two vtables

### 3.1 Neither named type exists

The task names `accesskit_platform_adapter_vtable` and
`accesskit_platform_application_vtable`. Neither is in this header, and neither
is anywhere in the `accesskit-c` checkout.

```
$ cd /tmp/scratch/accesskit-c && grep -rn "vtable" \
    --include=*.h --include=*.rs --include=*.toml --include=*.md .
(no output)
```

```
$ grep -c vtable /tmp/scratch/accesskit-c/include/accesskit.h
0
```

The Rust core does not name them either.

```
$ grep -rn "trait PlatformAdapter\|vtable\|PlatformApplication" \
    /tmp/scratch/accesskit/accesskit/src/lib.rs
(no output)
```

There is no struct-of-function-pointers in the C ABI. The seam that the C ABI
actually offers has three parts:

1. Four function pointer typedefs, listed in section 2.5. These are what a
   third-party adapter author fills in.
2. Per-platform adapter constructors and methods, listed in section 2.13. These
   are concrete, not virtual. The library links the platform adapter directly.
3. One out-of-band value, `accesskit_tree_update`, that crosses the seam in the
   opposite direction.

A C caller cannot register a platform of its own. The header exports concrete
entry points for five platforms and no mechanism to add a sixth. A Zig port that
wants a vtable has to design one. That is an open decision; section 9.1 sets it
out.

The rest of this section gives the per-parameter tables for the four function
pointer typedefs, which are the closest thing the ABI has to a vtable field.

### 3.2 `accesskit_tree_update_factory`, line 1110

Declared as `typedef struct accesskit_tree_update *(*accesskit_tree_update_factory)(accesskit_tree_update_factory_userdata);`

| Field | Header line | Type | Meaning |
|---|---|---|---|
| return | 1111 | `struct accesskit_tree_update *` | a freshly allocated update. The comment at 1106–1109 forbids null |
| context | 1111 | `accesskit_tree_update_factory_userdata` | opaque `void *` supplied by the adapter author |

| Question | Answer | Evidence |
|---|---|---|
| Who calls it | the platform adapter, inside `*_update_if_active` | `src/unix.rs:78`, `src/windows.rs:75`, `src/macos.rs:78`, `src/ios.rs:94`, `src/android.rs:102` |
| Who implements it | the adapter author. Every example implements it as a plain `extern "C"` function | `examples/sdl/hello_world.c:265`, `290`, `327`; `examples/windows/hello_world.c:98`, `116` |
| Arbitrary thread | Unix: yes, the adapter runs its own thread. Windows: the window-owning thread. macOS and iOS: the main thread. Android: not stated | `accesskit.h:2994-2996` |
| Context pointer | `accesskit_tree_update_factory_userdata`, passed unchanged through `*_update_if_active` | `accesskit.h:3031-3032`, `3079-3080`, `2830-2831`, `2680-2681`, `2572-2573` |
| Ownership of the result | the adapter takes it | `accesskit.h:1106-1109` |

The header comment at 1106–1109, quoted verbatim:

> This function can't return a null pointer. Ownership of the returned value
> will be transferred to the caller.

The Rust type is `Option<extern "C" fn(tree_update_factory_userdata) -> *mut tree_update>`
at `src/common.rs:1233-1234`. The `Option` is unwrapped at every call site
without a check, for example `src/unix.rs:75`. A null function pointer
therefore aborts the process. See section 5.3.

### 3.3 `accesskit_activation_handler_callback`, line 1113

Declared as `typedef struct accesskit_tree_update *(*accesskit_activation_handler_callback)(void *userdata);`

| Field | Header line | Type | Meaning |
|---|---|---|---|
| return | 1114 | `struct accesskit_tree_update *` | a tree update, or null for none |
| context | 1114 | `void *` | opaque |

| Question | Answer | Evidence |
|---|---|---|
| Who calls it | the platform adapter, when the platform first needs a tree. Rust maps it to `ActivationHandler::request_initial_tree` | `src/common.rs:1155-1164` |
| Who implements it | the adapter author | `examples/windows/hello_world.c:67`, `examples/sdl/hello_world.c:327` |
| Arbitrary thread | Unix: yes, another thread. Windows subclassing: always the window-owning thread. iOS and tvOS: always the main thread. macOS, Android and the plain Windows adapter: not stated | `accesskit.h:2994-2996`, `3117-3119`, `2650-2652` |
| Context pointer | `void *`, passed through the constructor | `accesskit.h:2998-2999`, `3127-3128`, `2659-2660` |
| Ownership of the result | the adapter takes the box. Null means no tree | `src/common.rs:1157-1163` |

The header has no comment for this typedef. The Rust implementation returns
`None` when the callback returns null:

```
1158:        if result.is_null() {
1159:            None
1160:        } else {
1161:            Some(*box_from_ptr(result))
1162:        }
```

`src/common.rs:1158-1162`.

This is the one callback where the header's stated contract and the
implementation disagree in strength. The `tree_update_factory` comment at
1106 forbids null. This one has no comment and the implementation accepts null.
[INFERENCE] A port that documents both callbacks the same way removes the
inconsistency.

### 3.4 `accesskit_action_handler_callback`, line 1120

Declared as `typedef void (*accesskit_action_handler_callback)(struct accesskit_action_request *request, void *userdata);`

| Field | Header line | Type | Meaning |
|---|---|---|---|
| request | 1121 | `struct accesskit_action_request *` | the action the platform asked for. Ownership transfers to the callback |
| context | 1121 | `void *` | opaque |

The payload struct `accesskit_action_request` is at 1065–1070:

| Field | Line | Type |
|---|---|---|
| `action` | 1066 | `accesskit_action` |
| `target_tree` | 1067 | `struct accesskit_tree_id` |
| `target_node` | 1068 | `accesskit_node_id` |
| `data` | 1069 | `struct accesskit_opt_action_data` |

The header comment at 1116–1119, quoted verbatim:

> Ownership of `request` is transferred to the callback. `request` must
> be freed using `accesskit_action_request_free`.

| Question | Answer | Evidence |
|---|---|---|
| Who calls it | the platform adapter. Rust maps it to `ActionHandler::do_action` | `src/common.rs:1192-1197` |
| Who implements it | the adapter author | `examples/sdl/hello_world.c:310`, `examples/windows/hello_world.c:86` |
| Arbitrary thread | Unix: yes, another thread. Windows subclassing: "The action handler may or may not be called on that thread." iOS and tvOS: the main thread. macOS, Android and the plain Windows adapter: not stated | `accesskit.h:3117-3119`, `2650-2652`, `2740-2741`, `2994-2996` |
| Context pointer | `void *`, passed through the constructor | `accesskit.h:2658-2663`, `3062-3065`, `2813-2816`, `2997-3003` |
| Who frees the request | the callback, with `accesskit_action_request_free` | `accesskit.h:1116-1119`, `2412` |

The Rust side box-allocates the request and hands over the raw pointer:

```
1193:    fn do_action(&mut self, request: ActionRequest) {
1194:        let request = Box::new(action_request::from(request));
1195:        (self.callback)(Box::into_raw(request), self.userdata.0);
1196:    }
```

`src/common.rs:1193-1196`. Both examples call the free function at the end of
the handler: `examples/sdl/hello_world.c:324`,
`examples/windows/hello_world.c:95`. A handler that forgets leaks the whole
request including the `char *` in the union. See section 4.6.

### 3.5 `accesskit_deactivation_handler_callback`, line 1123

Declared as `typedef void (*accesskit_deactivation_handler_callback)(void *userdata);`

| Field | Header line | Type | Meaning |
|---|---|---|---|
| context | 1123 | `void *` | opaque |

| Question | Answer | Evidence |
|---|---|---|
| Who calls it | the platform adapter. Rust maps it to `DeactivationHandler::deactivate_accessibility` | `src/common.rs:1221-1225` |
| Who implements it | the adapter author. The SDL example supplies an empty function | `examples/sdl/hello_world.c:335-338` |
| Arbitrary thread | same as the activation handler on the same platform | `accesskit.h:2994-2996`, `2650-2652`, `3117-3119` |
| Context pointer | `void *`, passed through the constructor | `accesskit.h:2663-2664`, `3002-3003` |
| Platforms that accept it | Unix, iOS, and the two subclassing adapters. macOS `accesskit_macos_adapter_new` (2813) and the plain Windows adapter (3062) do not take one | `accesskit.h:2813-2816`, `3062-3065` |

`FfiDeactivationHandler::new` carries `#[allow(dead_code)]` at
`src/common.rs:1212`, because the macOS and plain Windows adapters never
construct one.

### 3.6 Platform adapter entry points that receive a callback

Every constructor that takes a callback is listed here. The context pointer is
always the `void *` that follows the callback in the signature.

| Adapter | Line | Activation | Activation userdata | Action | Action userdata | Deactivation | Deactivation userdata |
|---|---|---|---|---|---|---|---|
| `accesskit_unix_adapter_new` | 2997 | yes 2998 | 2999 | yes 3000 | 3001 | yes 3002 | 3003 |
| `accesskit_windows_subclassing_adapter_new` | 3126 | yes 3127 | 3128 | yes 3129 | 3130 | no | no |
| `accesskit_ios_adapter_new` | 2658 | yes 2659 | 2660 | yes 2661 | 2662 | yes 2663 | 2664 |
| `accesskit_ios_subclassing_adapter_new` | 2747 | yes 2748 | 2749 | yes 2750 | 2751 | yes 2752 | 2753 |
| `accesskit_ios_subclassing_adapter_for_window` | 2771 | yes 2772 | 2773 | yes 2774 | 2775 | yes 2776 | 2777 |
| `accesskit_macos_subclassing_adapter_new` | 2894 | yes 2895 | 2896 | yes 2897 | 2898 | no | no |
| `accesskit_macos_subclassing_adapter_for_window` | 2913 | yes 2914 | 2915 | yes 2916 | 2917 | no | no |
| `accesskit_macos_adapter_new` | 2813 | no | no | yes 2815 | 2816 | no | no |
| `accesskit_windows_adapter_new` | 3062 | no | no | yes 3064 | 3065 | no | no |
| `accesskit_android_injecting_adapter_new` | 2619 | yes 2621 | 2622 | yes 2623 | 2624 | no | no |
| `accesskit_android_adapter_new` | 2557 | no | no | no | no | no | no |

Three of these take the activation handler per call rather than at
construction. The caller supplies it on each call and the library drops it when
the call returns.

| Call | Line | Activation | userdata |
|---|---|---|---|
| `accesskit_windows_adapter_handle_wm_getobject` | 3097 | yes 3099 | 3100 |
| `accesskit_android_adapter_create_accessibility_node_info` | 2577 | yes 2579 | 2580 |
| `accesskit_android_adapter_find_focus` | 2585 | yes 2587 | 2588 |
| `accesskit_android_adapter_on_hover_event` | 2611 | yes 2613 | 2614 |
| `accesskit_macos_adapter_view_children` | 2851 | yes 2853 | 2854 |
| `accesskit_macos_adapter_focus` | 2862 | yes 2864 | 2865 |
| `accesskit_macos_adapter_hit_test` | 2873 | yes 2875 | 2876 |

`accesskit_android_adapter_perform_action` (2598) takes an action handler per
call instead, at 2600 with userdata at 2601.

### 3.7 Thread affinity statements in the header

Four statements exist. Three more platforms say nothing.

| Line | Platform | Statement, verbatim |
|---|---|---|
| 2994–2996 | Unix | "All of the handlers will always be called from another thread." |
| 2650–2652 | iOS adapter | "This function must be called on the main thread. All handlers will always be called on the main thread." |
| 2740–2741 | iOS subclassing, new | "All handlers will always be called on the main thread." |
| 2758–2759 | iOS subclassing, for_window | "All handlers will always be called on the main thread." |
| 3117–3119 | Windows subclassing | "This must be called on the thread that owns the window. The activation handler will always be called on that thread. The action handler may or may not be called on that thread." |

macOS, Android, the plain Windows adapter and `accesskit_windows_adapter_new`
carry no thread statement. [INFERENCE] macOS handlers run on the main thread,
because AppKit requires it and `docs/12-accesskit-adapters.md` covers that
side. This document records only that the header does not promise it.

---

## 4. Lifetime and ownership across the boundary

### 4.1 The rule the header states

Three ownership verbs appear in the header comments.

| Verb | Header wording | Applies to |
|---|---|---|
| caller must free | "Caller must call `accesskit_string_free` with the return value." | every `char *` getter |
| caller keeps ownership | "Caller is responsible for freeing the memory pointed by `value`." | every string setter, every slice setter |
| library takes ownership | "Takes ownership of `node`." / "Takes ownership of `action`." | `accesskit_tree_update_push_node` (2385), `accesskit_node_push_custom_action` (2308) |

The second wording is the one a reader misreads. "Caller is responsible for
freeing" means the caller still owns the memory after the call. The shim
confirms this: `array_setter!` at `src/common.rs:59-81` copies the slice with
`.iter().cloned().map(From::from).collect()` and never frees the caller's
array. `accesskit_node_set_custom_actions` at `src/common.rs:811-828` clones
each `custom_action` the same way.

### 4.2 Node identifier arrays

| Direction | Type | Frees it | Evidence |
|---|---|---|---|
| C to library | `const accesskit_node_id *values` in `accesskit_node_set_children` (1299) and the 7 sibling setters | the caller | `accesskit.h:1296-1298`, `src/common.rs:59-81` |
| Library to C | `struct accesskit_node_ids` returned by value at 1293 and the 7 sibling getters | nobody | `src/common.rs:177-202`, second arm of `vec_property_methods!` |

The getters return `{length, values}` where `values` points into the node's
internal `Vec`. The node must outlive the caller's use of the array. **The
header never says this.** There is no free function for `accesskit_node_ids`
because there does not need to be one, but a reader has to derive that. [INFERENCE]
A port should state it.

The same applies to `accesskit_lengths` (2085, 2096) and
`accesskit_opt_coords` (2107, 2118).

### 4.3 String arrays and strings

| Direction | Type | Frees it | Evidence |
|---|---|---|---|
| C to library | `const char *value` in the 21 setters | the caller | `accesskit.h:1479-1481` and 20 copies |
| C to library | `const char *value, size_t length` in the 21 `_with_length` setters | the caller | `accesskit.h:1484-1486` and 20 copies |
| Library to C | `char *` from the 21 getters | the caller, with `accesskit_string_free` | `accesskit.h:1474-1476` and 20 copies |
| Library to C | `char *` from `accesskit_node_debug` (2322) | the caller, with `accesskit_string_free` | `accesskit.h:2319-2321` |
| Library to C | `char *` from `accesskit_tree_info_debug` (2373) | the caller | `accesskit.h:2370-2372` |
| Library to C | `char *` from `accesskit_tree_update_debug` (2409) | the caller | `accesskit.h:2406-2408` |
| Library to C | `char *` from the 5 `*_debug` adapter functions | the caller | `accesskit.h:3046-3048`, `2880-2882`, `2732-2734`, `3104-3106` |
| Library to C | `char *` from `accesskit_custom_action_description` (2275) | the caller | `accesskit.h:2272-2274` |
| Library to C | `char *` from `accesskit_tree_info_get_toolkit_name` (2331) and `get_toolkit_version` (2351) | the caller | `accesskit.h:2328-2330`, `2348-2350` |

`accesskit_string_free` at 1472, comment at 1469–1471, quoted verbatim:

> Only call this function with a string that originated from AccessKit.

The implementation asserts non-null and reconstructs a `CString`:

```
511: pub extern "C" fn accesskit_string_free(string: *mut c_char) {
512:     assert!(!string.is_null());
513:     drop(unsafe { CString::from_raw(string) });
514: }
```

`src/common.rs:511-514`.

A `char *` returned for an absent property is null, not an empty string. See
section 5.1.

### 4.4 Custom actions

| Item | Rule | Header line | Evidence |
|---|---|---|---|
| `accesskit_custom_action_new` returns | library-owned; free with `accesskit_custom_action_free` | 2262 | `src/common.rs:701-707` |
| `accesskit_node_push_custom_action` takes | "Takes ownership of `action`." | 2308 | `src/common.rs:832-839` |
| `accesskit_node_set_custom_actions` takes | nothing. "Caller is responsible for freeing each `custom_action` in the array as well as the `values` array itself." | 2300–2302 | `src/common.rs:811-828`, clones each action |
| `accesskit_node_custom_actions` returns | caller-owned; free with `accesskit_custom_actions_free` | 2294 | `src/common.rs:803-806` |
| `accesskit_custom_actions_free` frees | the pointer array, each element, and the outer struct | 2291 | `src/common.rs:773-780` |

The getter is the only node property getter in the whole header that returns a
heap pointer the caller must release. It deep-copies every action:

```
786:        let mut ffi_values: Vec<*mut custom_action> = values
787:            .iter()
788:            .map(|action| BoxCastPtr::to_mut_ptr(action.clone()))
789:            .collect();
790:        ffi_values.shrink_to_fit();
```

`src/common.rs:786-790`. The `shrink_to_fit` on 790 matters: the free function
calls `Vec::from_raw_parts` with `length` for the capacity, so a mismatched
capacity is undefined behaviour. Release 0.21.0 carried that as a bug fix,
quoted in section 7.4.

### 4.5 The tree update

| Step | Rule | Header line | Evidence |
|---|---|---|---|
| factory returns an update | library takes it | 1106–1109 | `src/unix.rs:78` |
| activation handler returns an update | library takes it; null means none | none | `src/common.rs:1158-1162` |
| `accesskit_tree_update_with_focus` | returns library-owned | 2375 | `src/common.rs:984-992` |
| `accesskit_tree_update_with_capacity_and_focus` | returns library-owned | 2378 | `src/common.rs:995-1006` |
| `accesskit_tree_update_push_node` | "Takes ownership of `node`." | 2385 | `src/common.rs:1016-1024`, moves the box out and drops it |
| `accesskit_tree_update_set_tree_info` | takes ownership; **no header comment** | 2391 | `src/common.rs:1027-1033`, `Some(*box_from_ptr(tree))` |
| `accesskit_tree_update_free` | frees the update and every node still in it | 2381 | `src/common.rs:1009-1011` |

`accesskit_tree_update_set_tree_info` is the one gap. The implementation
consumes the box, so the caller must not free the `accesskit_tree_info`, but
the header does not say so. [INFERENCE] A port must document it.

### 4.6 The action request

| Step | Rule | Header line | Evidence |
|---|---|---|---|
| adapter hands the request to the callback | "Ownership of `request` is transferred to the callback." | 1117 | `src/common.rs:1193-1196` |
| callback frees the request | "`request` must be freed using `accesskit_action_request_free`." | 1118 | `accesskit.h:2412` |
| the `char *` inside `data` | freed with the request | none | `src/common.rs:1084-1090` |

The `Drop` implementation for the union's `Value` variant:

```
1084: impl Drop for action_data {
1085:     fn drop(&mut self) {
1086:         if let Self::Value(value) = *self {
1087:             accesskit_string_free(value);
1088:         }
1089:     }
1090: }
```

`src/common.rs:1084-1090`. So `accesskit_action_request_free` releases the
string too. The header does not mention it. [INFERENCE] A port should.

### 4.7 Platform interface handles

| Handle | Who creates it | Who frees it | Evidence |
|---|---|---|---|
| `accesskit_android_adapter` | `accesskit_android_adapter_new` (2557) | `accesskit_android_adapter_free` (2561) | `src/android.rs:81-89` |
| `accesskit_android_injecting_adapter` | `accesskit_android_injecting_adapter_new` (2619) | `accesskit_android_injecting_adapter_free` (2628) | `src/android.rs:195-217` |
| `accesskit_android_platform_action` | `accesskit_android_platform_action_from_java` (2539) | `accesskit_android_platform_action_free` (2544) | `src/android.rs:27-41` |
| `accesskit_android_queued_events` | the four `*_update_if_active`-style calls | `accesskit_android_queued_events_raise` (2552) | `src/android.rs:57-66` |
| `accesskit_ios_adapter` | `accesskit_ios_adapter_new` (2658) | `accesskit_ios_adapter_free` (2669) | `src/ios.rs:53-81` |
| `accesskit_ios_subclassing_adapter` | 2747 or 2771 | `accesskit_ios_subclassing_adapter_free` (2782) | `src/ios.rs:170-236` |
| `accesskit_ios_queued_events` | `accesskit_ios_adapter_update_if_active` (2678), `accesskit_ios_adapter_view_did_appear` (2694), `accesskit_ios_subclassing_adapter_update_if_active` (2793) | `accesskit_ios_queued_events_raise` (2644) | `src/ios.rs:29-32` |
| `accesskit_macos_adapter` | `accesskit_macos_adapter_new` (2813) | `accesskit_macos_adapter_free` (2820) | `src/macos.rs:51-65` |
| `accesskit_macos_subclassing_adapter` | 2894 or 2913 | `accesskit_macos_subclassing_adapter_free` (2921) | `src/macos.rs:158-201` |
| `accesskit_macos_queued_events` | 2828, 2842, 2931, 2945 | `accesskit_macos_queued_events_raise` (2803) | `src/macos.rs:28-31` |
| `accesskit_unix_adapter` | `accesskit_unix_adapter_new` (2997) | `accesskit_unix_adapter_free` (3008) | `src/unix.rs:30-50` |
| `accesskit_windows_adapter` | `accesskit_windows_adapter_new` (3062) | `accesskit_windows_adapter_free` (3069) | `src/windows.rs:48-62` |
| `accesskit_windows_subclassing_adapter` | `accesskit_windows_subclassing_adapter_new` (3126) | `accesskit_windows_subclassing_adapter_free` (3134) | `src/windows.rs:139-158` |
| `accesskit_windows_queued_events` | 3078, 3092, 3144 | `accesskit_windows_queued_events_raise` (3057) | `src/windows.rs:28-31` |

The queued-events handles are the only handles the library hands out. Four
header comments describe them, and all four are identical in substance.

`accesskit_ios_queued_events_raise`, comment at 2641–2643:

> Memory is also freed when calling this function.

`accesskit_macos_queued_events_raise`, comment at 2800–2802:

> Memory is also freed when calling this function.

`accesskit_windows_queued_events_raise`, comment at 3054–3056:

> Memory is also freed when calling this function.

`accesskit_android_queued_events_raise`, comment at 2549–2551:

> Memory is also freed when calling this function.

So `*_queued_events_raise` is a consume-and-raise function. Calling it twice on
the same pointer is a use-after-free. The header does not forbid a second call.

### 4.8 Handle returned by the object-returning accessors

| Function | Line | Returned type | Ownership, quoted from the header |
|---|---|---|---|
| `accesskit_ios_adapter_accessibility_elements` | 2715 | `void *` | "Returns a pointer to an `NSArray` of accessibility elements contained in the view. Ownership of the pointer is not transferred. This corresponds to `accessibilityElements`." (2710–2713) |
| `accesskit_ios_adapter_hit_test` | 2726 | `void *` | "Returns a pointer to the accessibility element at the specified point, or null if none. Ownership of the pointer is not transferred. This corresponds to `accessibilityHitTest:`." (2721–2724) |
| `accesskit_macos_adapter_view_children` | 2851 | `void *` | "Returns a pointer to an `NSArray`. Ownership of the pointer is not transferred." (2846–2849) |
| `accesskit_macos_adapter_focus` | 2862 | `void *` | "Returns a pointer to an `NSObject`. Ownership of the pointer is not transferred." (2857–2860) |
| `accesskit_macos_adapter_hit_test` | 2873 | `void *` | "Returns a pointer to an `NSObject`. Ownership of the pointer is not transferred." (2868–2871) |

These five are the only places in the header that state "Ownership of the
pointer is not transferred". Every other `void *` parameter is an opaque
context the caller owns.

`accesskit_macos_add_focus_forwarder_to_window_class_with_length` at 2988 is
the odd one. Its comment at 2977 says, verbatim:

> Caller is responsible for freeing `class_name`.

The parameter is `const char *class_name` at 2977 and 2989. The implementation
reads it as a slice and never frees it:

```
274:    let class_name = unsafe { string_from_c_slice(class_name, length) };
275:    unsafe { add_focus_forwarder_to_window_class(&class_name) };
```

`src/macos.rs:274-275`. The comment is wrong. It is the only such comment in
the header and it contradicts the signature. A port must not copy it.

### 4.9 Ownership summary

| Item | Owner after the call | Freeing function |
|---|---|---|
| `accesskit_node` from `accesskit_node_new` (2315) | C | `accesskit_node_free` (2317) |
| `accesskit_node` pushed into a tree update (2387) | the tree update | `accesskit_tree_update_free` (2381) |
| `accesskit_tree_info` set on an update (2391) | the tree update | `accesskit_tree_update_free` (2381) |
| `accesskit_tree_update` from the factory (1110) | the library | internal |
| `accesskit_tree_update` from the activation handler (1113) | the library | internal |
| `accesskit_action_request` in the callback (1120) | the callback | `accesskit_action_request_free` (2412) |
| `char *` in `action_data.Value` (1032) | the request | with `accesskit_action_request_free` |
| `accesskit_custom_action` pushed (2310) | the node | internal |
| `accesskit_custom_actions` from the getter (2296) | C | `accesskit_custom_actions_free` (2291) |
| `accesskit_node_ids`, `accesskit_lengths`, `accesskit_opt_coords` from getters | C, but the interior pointer belongs to the node | none |
| every platform adapter handle | C | the matching `*_free` |
| every queued-events handle | C | the matching `*_queued_events_raise`, which also frees it |

---

## 5. Error reporting

### 5.1 There is no error type

The header defines no error enum, no status code and no error-returning
function. The complete list of failure signals is:

| Signal | Where | Meaning |
|---|---|---|
| null pointer return | 1477 and 20 sibling getters, 2296, 2238, 2715, 2726, 2851, 2862, 2873 | the property is absent, or there is no hit |
| `has_value == false` | every `accesskit_opt_*` struct | the property is absent |
| null `accesskit_action_request` fields | none | not possible |
| `false` return | 1147, 1162, 2129, 2136, 2438, 2440, 2494, 2704 | a predicate answered no |
| process abort | see 5.3 | a precondition was violated |

```
$ grep -n 'accesskit_error\|ACCESSKIT_ERROR' include/accesskit.h
(no output)
```

### 5.2 What a platform adapter must do on each

| Situation | Required adapter behaviour | Evidence |
|---|---|---|
| getter returns null | treat the property as absent. Do not call `accesskit_string_free` on it | `src/common.rs:255-258` |
| `opt_*` has `has_value == false` | do not read `value`. The header says so at every one of the 24 optional-struct comments | `accesskit.h:696`, `714`, `724`, `734`, `744`, `764`, `782`, `803`, `813`, `823`, `833`, `843`, `853`, `863`, `873`, `883`, `893`, `903`, `913`, `923`, `963`, `983`, `1058`, `1129` |
| `*_update_if_active` returns null | the adapter is not active. Build nothing. The header says "It can be null if the adapter is not active." at 2567, 2595, 2608, 2676, 2692, 2826, 2839, 2928, 2942, 3075, 3089, 3141 | quoted in section 5.5 |
| `*_update_if_active` returns non-null | call the matching `*_queued_events_raise` once | `examples/sdl/hello_world.c:147-149`, `examples/windows/hello_world.c:111-113` |
| `accesskit_windows_adapter_handle_wm_getobject` has `has_value == false` | fall through to `DefWindowProc` | `examples/windows/hello_world.c:191-198` |
| an adapter cannot build a tree | return null from the activation handler, not an error code | `src/common.rs:1158-1160` |

### 5.3 Aborts

The `accesskit-c` crate compiles with `panic = "abort"`.

```
$ grep -n panic Cargo.toml
41:panic = "abort"
```

A Rust panic in this crate terminates the process. There is no unwinding
across the C boundary to catch. The code has these panic sites:

| Site | Condition | Evidence |
|---|---|---|
| `accesskit_string_free` (1472) | null argument | `src/common.rs:512` |
| `box_from_ptr` on every `*_free` and every box-consuming call | null argument | `src/lib.rs:115` |
| all 21 string getters, `custom_action_description`, both `tree_info` getters, `action_data` conversion | a string with an interior NUL byte | `src/common.rs:256`, `732`, `890`, `931`, `1098` |
| `FfiActivationHandler::new` (1147, 1149 in the shim) | null function pointer | `src/common.rs:1149`, `1186`, `1215` |
| every `*_update_if_active` | null `tree_update_factory` | `src/unix.rs:75`, `src/windows.rs:71`, `src/macos.rs:74`, `src/ios.rs:90`, `src/android.rs:98`, `android.rs:225` |
| `accesskit_ios_subclassing_adapter_for_window` (2771) | window without a root view controller. The header says "This function panics if the specified window doesn't currently have a root view controller with a view." at 2766–2768 | `src/ios.rs:203-204` |
| `accesskit_macos_subclassing_adapter_for_window` (2913) | window without a content view. The header says "This function panics if the specified window doesn't currently have a content view." at 2907–2910 | `src/macos.rs:178-179` |
| `accesskit_windows_subclassing_adapter_new` (3126) | window already visible. The header says "Panics if the window is already visible." at 3121–3123 | `src/windows.rs:135-137` |
| six `jni::JNIEnv::from_raw(env).unwrap()` | null `JNIEnv` | `src/android.rs:32`, `63`, `118`, `142`, `203` |

The last column in the second group is the header text of each panic, quoted in
the same cell. No function returns an error code for any of these conditions.

### 5.4 Actions that require data

Five enum variants in `accesskit_action` carry a data requirement in their
header comment. A platform adapter that receives one of these actions without
its payload must not guess.

| Action | Line | Header requirement, verbatim |
|---|---|---|
| `ACCESSKIT_ACTION_CUSTOM_ACTION` | 80 | "Requires [`ActionRequest::data`] to be set to [`ActionData::CustomAction`]." (78) |
| `ACCESSKIT_ACTION_REPLACE_SELECTED_TEXT` | 96 | "Requires [`ActionRequest::data`] to be set to [`ActionData::Value`]." (94) |
| `ACCESSKIT_ACTION_SCROLL_INTO_VIEW` | 117 | "Optionally set [`ActionRequest::data`] to [`ActionData::ScrollHint`]." (115) |
| `ACCESSKIT_ACTION_SCROLL_TO_POINT` | 123 | "Requires [`ActionRequest::data`] to be set to [`ActionData::ScrollToPoint`]." (120–121) |
| `ACCESSKIT_ACTION_SET_SCROLL_OFFSET` | 128 | "Requires [`ActionRequest::data`] to be set to [`ActionData::SetScrollOffset`]." (125–126) |
| `ACCESSKIT_ACTION_SET_TEXT_SELECTION` | 133 | "Requires [`ActionRequest::data`] to be set to [`ActionData::SetTextSelection`]." (130–131) |
| `ACCESSKIT_ACTION_SET_VALUE` | 145 | "Requires [`ActionRequest::data`] to be set to [`ActionData::Value`] or [`ActionData::NumericValue`]." (141–143) |

### 5.5 Partially built trees

The question was: what happens when an adapter returns an error in the middle of
a partially built tree.

**The case does not arise in this ABI, because an adapter cannot return an
error.** The tree update is built entirely on the C side, from the adapter
author's own code, before it crosses the boundary. The boundary crossing is
`accesskit_tree_update_factory` at 1110, and its contract at 1106–1109 forbids
a null return. There is no partial state visible to the library.

The failure modes that do exist are:

| Failure mode | Result | Evidence |
|---|---|---|
| the factory returns null | process abort | `src/unix.rs:75` unwrap on the function pointer, then `box_from_ptr` at `src/lib.rs:115` asserts non-null |
| the factory panics partway through | process abort, nothing sent | `panic = "abort"`, `Cargo.toml:41` |
| an adapter leaks a node it pushed | the library frees it with the update | `src/common.rs:1016-1024` moves the box out and drops it, so the `Node` value lands in `update.nodes` |
| the tree is structurally wrong, for example a dangling child id | the library has no check. The adapter author finds out at run time | no validation call exists in the shim |

A Zig port has one design choice here. It can keep the "the factory cannot
fail" rule and provide no error path, or it can give the factory an error
return. Section 9.1 sets out both.

---

## 6. The Rust shim

### 6.1 What the shim adds over the generated header

`src/lib.rs` and `src/common.rs` together add 1458 lines of code that do not
appear in the header.

| Construct | Location | Purpose |
|---|---|---|
| `CastPtr` trait | `lib.rs:83-89` | maps a snake_case C type name to its Rust type |
| `CastConstPtr` trait | `lib.rs:93-99` | the const-only variant |
| blanket `CastConstPtr` impl | `lib.rs:104-109` | every `CastPtr` is also `CastConstPtr` |
| `BoxCastPtr` trait | `lib.rs:113-130` | `to_box`, `to_mut_ptr`, `to_nullable_mut_ptr` |
| `ref_from_ptr` | `lib.rs:136-141` | `*const T` to `&T`, with an unwrap |
| `mut_from_ptr` | `lib.rs:144-149` | `*mut T` to `&mut T`, with an unwrap |
| `box_from_ptr` | `lib.rs:151-156` | `*mut T` to `Box<T>`, with an assert |
| `opt_struct!` macro | `lib.rs:160-204` | generates the 24 optional structs |
| `debug_repr_from_ptr` | `lib.rs:206-214` | `format!("{:?}")` into a leaked `CString` |
| `string_from_c_slice` | `lib.rs:216-223` | C bytes to `String`, lossily |
| 14 property macros | `common.rs:29-389` | generate the 358 node functions |
| `opt_slice_struct!` | `common.rs:323-353` | generates `accesskit_opt_coords` |
| `FfiActivationHandler` | `common.rs:1141-1164` | adapts the C callback to the Rust trait |
| `FfiActionHandler` | `common.rs:1178-1197` | same, for actions |
| `FfiDeactivationHandler` | `common.rs:1206-1225` | same, for deactivation |

### 6.2 What exists only to satisfy the Rust borrow checker

These constructs have no counterpart in Zig and must be deleted, not ported.

| Construct | Why it exists | Zig replacement |
|---|---|---|
| `CastPtr` (83–89) | Rust needs the C typedef name and the Rust type name to be related by a trait impl. C gets the name, Rust gets the type, and cbindgen can read both | `const`/`enum` in Zig. A function pointer cast |
| `CastConstPtr` (93–109) | stops `Arc` values from being cast to a mutable pointer | Not needed. Zig has no aliasing cast to police |
| `ref_from_ptr` / `mut_from_ptr` (136–149) | raw pointers must be turned into references with an explicit lifetime `'a` that the signature invents | `const Node` and `*Node` directly |
| `box_from_ptr` (151–156) | `Box::from_raw` needs the concrete Rust type, which the `CastPtr` impl supplies | `@ptrCast(@alignCast(p))` |
| `opt_struct!` (160–204) | `Option<T>` has no stable layout, so the macro wraps it in `MaybeUninit` to get `has_value` plus a payload | `?T` or an explicit tagged union |
| `unsafe impl Send for FfiActivationHandlerUserdata` (1139) | the userdata pointer is `*mut c_void`, which is not `Send`, but the callback may run on another thread | Declare the parameter as a thread-safe pointer type. This is a real requirement, not a checker artefact |
| `unsafe impl Send for FfiActionHandlerUserdata` (1176) | same | same |
| `unsafe impl Send for FfiDeactivationHandlerUserdata` (1204) | same | same |
| `unsafe impl Send for tree_update_factory_userdata` (1230) | same | same |
| `#[repr(transparent)] tree_update_factory_userdata` (1227) | makes the newtype layout-compatible with `void *` so cbindgen emits `typedef void *` | not needed |
| `Option<extern "C" fn>` (1134, 1172, 1200, 1233) | cbindgen emits nullable function pointers, which C cannot express, so the Rust side uses `Option` and unwraps at every call | `?*const fn` or a required non-null parameter |

The four `unsafe impl Send` lines are the ones that carry a real constraint
across the boundary. They are not borrow-checker noise. A Zig port must state
the thread rule in the type, or assert it at the call. Section 3.7 lists the
rules the header gives.

### 6.3 Pure plumbing a Zig port does not need

| Item | Location | Reason |
|---|---|---|
| `debug_repr_from_ptr` and the 7 `*_debug` functions | `lib.rs:206-214`, `common.rs:858`, `967`, `1064`, `unix.rs:93`, `windows.rs:109`, `macos.rs:138`, `ios.rs:148` | Rust's `Debug` derive. A Zig port can produce the same text with `std.fmt`, or drop the functions |
| the 14 property macros | `common.rs:29-389` | each one is 20 to 60 lines of Rust that expands to a getter, a setter and a clearer. In Zig the property is one field of a struct |
| `slice_struct!` and its `From` impls | `common.rs:147-175` | `{length, values}` is `[]const T` in Zig |
| `string_from_c_slice` | `lib.rs:216-223` | lossy UTF-8 conversion. A Zig port does this once, at the boundary, with an explicit error |
| the `From` impls for `tree_id`, `text_position`, `text_selection` | `common.rs:212-224`, `627-676` | field-for-field copies |

### 6.4 Things a Zig port must keep doing

| Item | Location | Reason |
|---|---|---|
| copy-in on every slice setter | `common.rs:59-81` | the C array does not outlive the call |
| deep copy on `accesskit_node_custom_actions` | `common.rs:783-798` | the returned actions must outlive the node |
| `Vec::from_raw_parts` with matched capacity | `common.rs:775` | the free path must match the allocation |
| `impl Drop for action_data` | `common.rs:1084-1090` | the union's `char *` must be released |
| the `has_value` discriminants | `lib.rs:164`, `178`, `197` in `opt_struct!`, and `common.rs:327`, `335`, `346` in `opt_slice_struct!` | the header's 25 optional structs depend on them |

---

## 7. The build and packaging story

### 7.1 What generates the header

`cbindgen` generates `accesskit.h` from the Rust shim types. Three build files
drive it.

`CMakeLists.txt:28-43`:

```cmake
add_custom_target(headers ALL
    COMMAND ${RUSTUP} run nightly-2025-03-27 ${CBINDGEN} --crate accesskit-c --output accesskit.hpp "${CMAKE_SOURCE_DIR}"
    COMMAND ${CLANG_FORMAT} -i accesskit.hpp
    COMMAND ${CMAKE_COMMAND} -E rename accesskit.hpp accesskit.h
    BYPRODUCTS accesskit.h
)
```

`meson.build:287-320` does the same through `custom_target`. Both gate on all
three tools being found:

```meson
if rustup.found() and cbindgen.found() and clang_format.found()
```

The toolchain is pinned twice. `README.md:86-88` names `nightly-2025-03-27`,
`cbindgen 0.28.0` and `clang-format 14 or higher`. The CI job repeats the
nightly pin at `.github/workflows/ci.yml:144-146`.

The generated header is committed. `README.md:84` says:

> If you modify the C bindings, you need to regenerate the header file and
> commit it.

CI enforces that the committed header matches the generator output:

```
$ sed -n '134,155p' .github/workflows/ci.yml
  check-c-header:
    runs-on: ubuntu-latest
    name: Check committed C header
    ...
    - run: meson setup build
    - run: meson compile -C build accesskit.h
    - run: cmp build/accesskit.h include/accesskit.h
```

The comparison is a literal `cmp` at `.github/workflows/ci.yml:155`. So the
build has one source of truth, the Rust shim, and one generated artifact, the
header.

### 7.2 What cbindgen.toml controls

| Setting | Line | Effect on the header |
|---|---|---|
| `language = "C"` | 1 | C output |
| `header` | 2–7 | the 6-line Apache/MIT banner at lines 1–6 |
| `include_guard = "ACCESSKIT_H"` | 9 | `#define ACCESSKIT_H` at 9, `#ifndef` at 8 |
| `cpp_compat = true` | 10 | the `extern "C"` block at 1137 and 3150 |
| `after_includes` | 11–54 | the verbatim platform includes and `TARGET_OS_*` defaults at 16–59 |
| `usize_is_size_t = true` | 56 | `size_t` instead of `uint64_t` in every length field |
| `[export] prefix = "accesskit_"` | 60 | the `accesskit_` prefix on every name |
| `[export] renaming_overrides_prefixing = true` | 61 | the 51 explicit renames at 77–126 win over the prefix |
| `[defines]` | 63–75 | 12 Rust `target_os` names mapped to C preprocessor symbols |
| `[enum] prefix_with_name = true` | 130 | `ACCESSKIT_ROLE_BUTTON`, not `BUTTON` |
| `[enum] rename_variants = "ScreamingSnakeCase"` | 129 | the variant spelling |
| `[parse] include = ["accesskit"]` | 134 | the core crate types are pulled in by name |
| `[parse.expand] features = ["cbindgen"]` | 138 | the `cbindgen` feature turns on every platform module at once. `lib.rs:18-73` gates each module on `target_os` **or** `feature = "cbindgen"` |

Two of these matter for a port. The `[export.rename]` table at 77–126 is a
hand-maintained map of 51 Rust names to C names. That is the list a Zig port
would otherwise have to invent, and it is the reason the header is not a
mechanical transform of the Rust names.

### 7.3 What the packaging produces

`accesskit-config.cmake` defines three imported targets and per-platform link
libraries.

| Line | Item |
|---|---|
| 3 | `add_library(accesskit INTERFACE)` |
| 5–14 | `accesskit-static`, found under `lib/<os>/<arch>/static` |
| 27–49 | `accesskit-shared`, with `IMPORTED_IMPLIB` on Windows |
| 51–55 | `accesskit` links `accesskit-shared` if `BUILD_SHARED_LIBS`, else `accesskit-static` |
| 16 | macOS links `AppKit`, `Foundation`, `CoreFoundation`, `objc`, `c++` |
| 18 | iOS links `UIKit`, `Foundation`, `CoreFoundation`, `objc`, `c++` |
| 20 | Android links `android`, `log` |
| 22 | Linux links `-static-libgcc`, `m` |
| 24 | Windows links `bcrypt`, `ntdll`, `propsys`, `runtimeobject`, `uiautomationcore`, `userenv`, `ws2_32` |

`accesskit.cmake:56` builds the search path:
`lib/<_accesskit_os>/<_accesskit_arch>[/<toolchain>]`.

`meson.build:222-229` computes the ABI version from the project version:

```meson
version_parts = project_version.split('.')
if version_parts[0] == '0'
  api_version = '@0@.@1@'.format(version_parts[0], version_parts[1])
```

For `0.23.1` that gives library name `accesskit-c-0.23` and soname
`accesskit-c-0.23`. So the soname carries the major and minor version. A
consumer pinned to `0.23` will not load `0.24` without a rebuild.

`meson.build:382-397` writes a symbol list from the built archive and feeds it
to the linker as `-Wl,--version-script` on Linux, `-exported_symbols_list` on
Apple, and `vs_module_defs` on Windows. Only `accesskit_*` symbols are
exported.

### 7.4 Is the header stable across releases

**No.** The changelog records six explicit ABI breaks in the enumerated
`accesskit-c` history.

| Release | Date | Break, verbatim | Header effect |
|---|---|---|---|
| 0.18.0 | 2025-12-10 | "Make `accesskit_custom_action` an opaque type" (190) | `accesskit_custom_action` loses its public layout. Adds `accesskit_custom_action_new` (2262), `accesskit_custom_action_free` (2264), `accesskit_custom_action_id` (2266) and the description functions at 2275–2289 |
| 0.17.0 | 2025-07-18 | "Remove `NodeClassSet`" | pre-move commit `1b153ed` |
| 0.16.0 | 2025-04-24 | "Rename the `StaticText` role to `Label`" (316) | `ACCESSKIT_ROLE_STATIC_TEXT` becomes `ACCESSKIT_ROLE_LABEL` |
| earlier | pre-move | "Rename `accesskit_builder_set_text_selection` to `accesskit_node_builder_set_text_selection`" (368) | function rename |
| earlier | pre-move | "Rename `hierarchical_level` to `level`" (391) | property rename |
| earlier | pre-move | "Rename `Checked` to `Toggled`; drop `ToggleButton` role" (393) | enum rename and a role removal |

The 0.17.0 and 0.16.0 rows come from the pre-move section of the changelog,
which release-please copied from the core repository. The core-side commits
are `1b153ed`, `7086bc0`, `79eb0a4`, `2d61e01` and `6bc040b`, all visible in
`git log --oneline -- bindings/c/`.

Non-breaking additions in the same range:

| Release | Addition | Header effect |
|---|---|---|
| 0.18.0 | "Allow usage of char slices in addition to null-terminated strings" (199) | adds the 21 `_with_length` setters, 1487 through 1872 |
| 0.18.0 | "Add functions to get string representation of opaque types" (196) | adds the 5 `*_debug` functions |
| 0.18.0 | "Add missing functions to geometry types" (197) | adds `accesskit_rect_area` (2492) and others |
| 0.22.0 | "Add iOS adapters" (125) | adds 13 functions |
| 0.21.0 | "Add Android support" (156) | adds 13 functions |
| 0.21.0 | "Allow null pointers as empty slices" (162) | relaxations only |

The 0.19.0, 0.20.0 and 0.23.0 releases carry the marker "⚠ BREAKING CHANGES"
but the text under it names dependency bumps, not header changes.

The soname convention at `meson.build:222-229` gives a weak signal: it holds at
`0.X`, so a within-`0.X` break does not change the soname.

### 7.5 What a Zig port must reproduce

| Deliverable | Upstream mechanism | Port mechanism |
|---|---|---|
| A C header | cbindgen, pinned toolchain, committed output, `cmp` in CI | Section 7.6 |
| A C static library | Corrosion at `CMakeLists.txt:12-22`, or `meson/cargo_wrapper.py` | `b.addStaticLibrary` |
| A C shared library | same, plus a generated symbol list | `b.addSharedLibrary` |
| A `find_package` config | `accesskit-config.cmake`, 55 lines | `b.addCMakePkgConfigDir` and `b.addCMakeLibraryConfig`, or a checked-in config |
| A Meson subproject | `meson.build`, 470 lines plus 5 helper scripts | not required |
| Platform link libraries | `accesskit-config.cmake:16-24` | `b.linkSystemLibrary` |
| Exported symbols limited to `accesskit_*` | `meson.build:382-397` | a version script or `export`ed symbols in Zig |
| Soname | `meson.build:222-229` | `b.addSharedLibrary(.{ .version = .{ .major = 0, .minor = 23 } })` |

### 7.6 How the header becomes a checked-in artifact without cbindgen

The port must not require `cargo`, `rustc`, `cbindgen` or `rust-toolchain`
files. The Zig standard library ships no Zig-to-C header emitter. `lib/std/zig/`
contains `c_translation`, `Parse.zig` and `Client.zig`, which is the C-to-Zig
direction only.

Three options exist. Cost is given for each.

**Option A, hand-written header plus `translate-c`.** Write `include/accesskit.h`
by hand and let `@cImport` produce the Zig declarations from it. One artifact,
one direction, nothing to keep in sync. `installHeader` exists in
`std.Build.Step.Compile` at line 523, so a checked-in header installs from
`build.zig` without a codegen step. The cost is the hand-written header must
stay correct on its own, with no generator to catch drift. The mitigation is a
comptime sweep in Zig that asserts `@sizeOf` and `@offsetOf` for every struct
against the values the header promises, plus a fixture that calls one function
of every shape.

**Option B, one declaration table, two emitters.** Keep the 496 function
signatures and 75 type layouts in a Zig comptime table. A comptime generator
emits the C header from it, and `std.zig` AST generation emits the Zig
`extern` declarations from the same table. One source of truth, drift is
impossible. The cost is a generator to write and maintain, and generated
`.zig` files, which the house rule disfavours. A comptime-only variant avoids
the checked-in generated `.zig` by building the extern blocks at comptime inside
a single `@compileLog`-checked `comptime` block.

**Option C, checked-in header plus a conformance test.** Write the header by
hand, and write a Zig test that compiles a C file which `static_assert`s every
struct size and offset against the Zig side. The header stays the single source
of truth for C consumers, and the test is the guard. The cost is 40 struct
assertions and 496 function-pointer compatibility checks written by hand, and
that they only run when the test runs.

All three remove `cbindgen`. Options A and C leave a hand-written artifact.
Option B adds a generator. The choice is a `docs/31-c-abi-design.md` decision.

---

## 8. Third-party adapters

### 8.1 What the SDL example writes

`examples/sdl/hello_world.c`, 479 lines. What an adapter author writes:

| Task | Lines | Count |
|---|---|---|
| Node builder functions | 40–61 | 2 |
| Platform dispatch struct and functions | 63–209 | 5 |
| Application state and locking | 211–233 | 5 |
| Tree builders | 235–303 | 5 |
| Action handler | 305–325 | 1 |
| Activation handler | 327–333 | 1 |
| Deactivation handler | 335–338 | 1 |
| Android JNI marshalling | 340–364 | 4 |
| `main` and event loop | 366–479 | 1 |

The five functions at 63–209 are pure platform dispatch. Each has the same
shape: an `#if` chain over `__APPLE__`, `UNIX`, `_WIN32`, `__ANDROID__`, with a
null check on the queued-events return. That is boilerplate a port could
generate or replace with a compile-time branch.

The three handlers are the minimum an author must write.

### 8.2 What the Windows example writes

`examples/windows/hello_world.c`, 291 lines.

| Task | Lines | Count |
|---|---|---|
| Node builders | 23–44 | 2 |
| State and lifetime | 46–65 | 3 |
| Tree builders | 67–125 | 3 |
| Action handler | 86–96 | 1 |
| Focus state | 148–156 | 1 |
| `WndProc` | 162–234 | 1 |

The plain `accesskit_windows_adapter` (3062) takes no activation handler.
The activation handler is supplied per call at
`accesskit_windows_adapter_handle_wm_getobject` (3097), which the example wires
directly to `WM_GETOBJECT` at 192–193. The `accesskit_windows_subclassing_adapter`
(3126) takes the activation handler at construction instead.

### 8.3 Boilerplate a port could remove

| Item | Upstream form | Port option |
|---|---|---|
| Platform `#if` chains | 12–16 in the SDL example, four arms each | a comptime `switch` on the target |
| Queued-events null check and raise | SDL 144–149, 154–159, 174–179; Windows 108–113, 150–155, 136–141 | one helper function per platform |
| Locking around the tree builder | SDL 329–331, 327 | `io`-threaded state. See `docs/20-zio-and-zig-io.md` |
| Android global state for JNI | SDL 340–360 | not a portable problem. Keep it |
| `accesskit_macos_add_focus_forwarder_to_window_class` | SDL 86 | Objective-C runtime class patching. Not a Zig decision |
| Node construction boilerplate | 40–61 in both examples | unchanged. This is the schema |

### 8.4 What stays irreducible

| Item | Reason |
|---|---|
| mapping application state to the 182 roles | application logic |
| the action handler | application logic |
| the deactivation handler | application logic |
| window-class patching on macOS | needs the Objective-C runtime |

---

## 9. Port decision input

### 9.1 The seam itself

| Option | Description | Cost |
|---|---|---|
| Keep the four callbacks, add nothing | the adapter author fills in the same four function pointers | lowest. One `docs/31-c-abi-design.md` header, four Zig function-pointer types, no dispatch table |
| Replace with a platform adapter vtable | one struct of function pointers that the library calls through, in place of five concrete adapters | highest. Every one of the 58 platform functions at 2538–3148 becomes a vtable slot or a default. The library gains an indirect call on every tree update |
| Replace with a Zig interface and keep a thin C header | the adapter is a Zig interface; the C header exposes only the four callbacks | medium. Cleanest in Zig, but it cannot serve a C adapter author |

The upstream ABI chose the first option and hard-coded five platforms. A port
that wants a sixth platform, or a ZLS window server, needs the second. That is
the largest single design decision in this document, and it belongs to
`docs/31-c-abi-design.md`.

### 9.2 What must stay byte compatible

| Item | Lines | Why |
|---|---|---|
| `accesskit_role` variant values | 283–482 | the enum comment at 266–277 ties the integers to the serialization format |
| `accesskit_action` variant values | 72–146 | same. `ACCESSKIT_ACTION_CUSTOM_ACTION` at 80 and the scroll actions at 100–128 are wire values |
| `accesskit_action_data_Tag` values | 1010–1022 | wire values |
| `accesskit_tree_id` layout | 708 | `uint8_t bytes[16]`, big-endian UUID, stated at 703–706 |
| `accesskit_rect`, `accesskit_point`, `accesskit_vec2`, `accesskit_size`, `accesskit_affine` layouts | 941, 998, 1079, 1093, 934 | geometry handed to and from host APIs |
| `accesskit_node_ids`, `accesskit_lengths`, `accesskit_opt_coords` layouts | 688, 789, 794 | pointer plus length pairs shared with C callers |
| `accesskit_action_request` layout | 1065 | read field by field by C handlers |
| `accesskit_opt_*` `has_value`-first layout | 25 structs, 24 of them ungated | every optional |

### 9.3 What can be redesigned

| Item | Upstream form | Proposed form | Cost |
|---|---|---|---|
| `accesskit_opt_*` structs | 25 structs, 24 ungated, each with `bool` plus a `MaybeUninit` payload | one `?T` per property, expressed to C as the same struct if a C header survives | low internally. A rewrite of 25 struct definitions and 358 accessors |
| Node accessors | 358 functions | a property table plus one generic accessor | high. The functions are the public API |
| `accesskit_string_free` (1472) plus `char *` returns | allocate and free per string | a caller-supplied allocator, or borrowed slices with a lifetime | medium. Changes the ownership contract that section 4.3 documents |
| `accesskit_tree_update_factory` returning a raw pointer (1110) | raw pointer | return an owned Zig value with an explicit error set | medium. Changes the "can't return null" contract at 1106 |
| `*_update_if_active` returning a nullable handle | nullable handle | an explicit "inactive" result, or an error union | medium |
| `accesskit_tree_update_factory_userdata` (1104) | a typedef | plain `*anyopaque` | zero |
| The 5 `*_debug` functions | Rust `Debug` output | keep, or drop | zero either way |
| `accesskit_affine._0[6]` (935) | unnamed array | a named 6-field struct | low. Changes the ABI for 14 geometry functions |
| `accesskit_opt_lresult` (1131) | Windows SDK type in a public struct | a Zig-side only type | low |

### 9.4 House rules

The rules are from `~/ozai/AGENTS.md` section 2.

| Rule | How the subject satisfies it | How it fights it |
|---|---|---|
| `io` threaded explicitly, never global | the ABI already passes every context as a parameter: `update_factory_userdata` at 1104, and `userdata` at 1114, 1121, 1123 | the four contexts are separate, so a port that unifies them into one `Context` pointer changes the signature. Section 3.2 |
| state is a parameter, not a capture | `accesskit_node` (662) is an explicit handle in every one of the 358 accessors | the 358 functions take a pointer, so the state is already explicit. Good |
| network and event logic is pure over decoded input | the ABI carries decoded values only: `accesskit_rect` (941), `accesskit_color` (754), the enums at 64–610 | the platform adapters are the impure half and they are not in this document. See `docs/12-accesskit-adapters.md` |
| allocators are parameters | **the ABI fights this hardest.** `accesskit_node_new` (2315), `accesskit_tree_update_with_focus` (2375), every string getter and `accesskit_custom_actions_free` (2291) use the global Rust allocator. No allocator appears in any signature | the fix is in section 9.3: thread an allocator through the constructors and the string getters. That is a real ABI change |
| error sets are explicit | **the ABI fights this too.** No function returns an error. Failure is null, `has_value == false`, or abort | section 5 lists the abort sites. A port that adds error returns to `accesskit_tree_update_factory` and to the `update_if_active` family fixes it |
| loops have fixed upper bounds | not applicable to the header. No function loops | the shim has `.iter().cloned().collect()` at `common.rs:70-74` and `822-824`, which allocate an unbounded `Vec` from an attacker-supplied `length`. A port must bound these |
| no backwards compatibility | the header has six recorded ABI breaks in section 7.4, so upstream does not hold the line either | a port may clean-cut to the section 9.3 shapes. The house rule and the upstream precedent agree |

### 9.5 Zero Rust toolchain

The port carries no `Cargo.toml`, no `Cargo.lock`, no `build.rs`, no
`cbindgen`, no `rust-toolchain`, and no step that shells out to `cargo`.

| Upstream item | Replacement | Rung |
|---|---|---|
| `cbindgen` generating `accesskit.h` | section 7.6, options A, B or C. All three are Zig or a checked-in C file | 1, Zig standard library plus a comptime generator |
| `Corrosion` at `CMakeLists.txt:12-22` | `b.addStaticLibrary` and `b.addSharedLibrary` | 1 |
| `meson/cargo_wrapper.py` | not needed | n/a |
| `rustup run nightly-2025-03-27 cbindgen` | not needed | n/a |
| `cmp build/accesskit.h include/accesskit.h` in CI | a Zig test, or a comptime assertion | 1 |
| `uuid` crate, via `accesskit`'s `TreeId` | `std.uuid` if the Zig version has it, else a 16-byte struct with a comptime-checked layout | 1 |
| `jni` crate in `src/android.rs` | the JNI C API through `translate-c` against `<jni.h>` | 3. The JNI API is a C API with opaque handles and it binds cleanly |
| `kurbo` crate behind `accesskit_affine`, `accesskit_rect`, `accesskit_point`, `accesskit_size`, `accesskit_vec2` | these are 49 pure functions over 6 doubles. Write them | 1 |
| `serde`, `postcard`, `zbus` in the core crate | out of scope for this document. See `docs/10-accesskit-core.md` | n/a |

For the header-generation question the ladder is: rung 1, `std.Build.Step.Compile.installHeader`
at `Step/Compile.zig:523` installs a checked-in header, so no C shim is needed;
rung 2, no Zig package was found in the local package cache, which holds only
`zio-0.18.0`; rung 3, not applicable; rung 4, not applicable, because no macro
or varargs appear in the ABI.

---

## Appendix A. Evidence index

| Claim | Command or path |
|---|---|
| Move commit, date, author | `git -C /tmp/scratch/accesskit show -s --format='%H%n%ad%n%s%n%b' 553d9c1` |
| Pre-move layout and file sizes | `git -C /tmp/scratch/accesskit show --stat 553d9c1` |
| Pre-move history | `git -C /tmp/scratch/accesskit log --oneline -- bindings/c/` |
| Header line count | `wc -l /tmp/scratch/accesskit-c/include/accesskit.h` = 3154 |
| No vtable | `grep -rn "vtable" --include=*.h --include=*.rs --include=*.toml --include=*.md .` in `accesskit-c` |
| No error enum | `grep -n 'accesskit_error\|ACCESSKIT_ERROR' include/accesskit.h` |
| 496 functions | `grep -oE 'accesskit_[a-z_0-9]+\(' include/accesskit.h \| sort -u \| wc -l` = 500, minus 4 typedefs |
| 444 Linux functions | `gcc -x c -fsyntax-only -aux-info decl.txt include/accesskit.h`, then `grep -c 'accesskit.h:.*extern .*accesskit_' decl.txt` |
| Enum variant counts | parsed from the header text |
| Crate version and dependency | `cat accesskit-c/Cargo.toml` |
| `panic = "abort"` | `grep -n panic accesskit-c/Cargo.toml` = line 41 |
| Core version | `grep -n version accesskit/accesskit/Cargo.toml` = 0.25.1 |
| Adapter versions | `cat accesskit/.release-please-manifest.json` |
| Header generator config | `cbindgen.toml`, 138 lines |
| CI header check | `.github/workflows/ci.yml:134-155` |
| CMake packaging | `accesskit-config.cmake`, 55 lines; `accesskit.cmake`, 59 lines |
| Meson soname rule | `meson.build:222-229` |
| Meson symbol export | `meson.build:382-397` |
| Release history | `accesskit-c/CHANGELOG.md`, 29.2 KB |
| Toolchain pins | `accesskit-c/README.md:82-104` |
| Shim macros | `accesskit-c/src/common.rs:29-389` |
| Shim box plumbing | `accesskit-c/src/lib.rs:83-156` |
| Shim optional structs | `accesskit-c/src/lib.rs:160-204` |
| Callback adapters | `accesskit-c/src/common.rs:1133-1234` |
| Custom-action deep copy | `accesskit-c/src/common.rs:783-798` |
| Action-data `Drop` | `accesskit-c/src/common.rs:1084-1090` |
| SDL example | `accesskit-c/examples/sdl/hello_world.c`, 479 lines |
| Windows example | `accesskit-c/examples/windows/hello_world.c`, 291 lines |
| `installHeader` in the Zig standard library | `lib/std/Build/Step/Compile.zig:523` |
| No Zig-to-C header emitter | `lib/std/zig/` listing: `c_translation`, `Parse.zig`, `Client.zig` only |
| House rules | `~/ozai/AGENTS.md`, section 2, lines 55–94 |
