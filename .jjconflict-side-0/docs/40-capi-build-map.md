# 40 — C ABI build map

**What this document is.** The working list for `src/capi/`. It is not a design
argument: `docs/31-c-abi-design.md` owns the shape of the ABI and
`docs/30-port-design.md` section 3.3 owns the three-module split. This file owns
the census — what has to be written, in what order, against which Zig symbol,
through which conversion — and the build wiring that has to exist before any of
it can be exercised.

**How every number here was produced.** Nothing is transcribed from a prior
document. The function census comes from a lexical scan of
`include/zaccesskit.h` that masks comments and string literals first, then
recovers each declaration and its line; section 1.2 states the method in full
and cross-checks it against `cc -E`. The layouts come from compiling a C11
fixture against the header and printing `sizeof`, `_Alignof` and `offsetof` at
run time. The `lib/std` line numbers come from the installed toolchain's own
sources. Where this document contradicts `docs/31`, it says so and gives the
measurement. Where it *used* to contradict `docs/31`, the contradiction was its
own classifier's: section 1.2 and section 3.4 record the withdrawal, and
`docs/31` section 2.5 and section 9.3 carry the matching correction.

**Scratch tree.** The layout probes ran under
`/tmp/scratch/capi-map/`; the aggregate-passing re-measurement
under `/tmp/scratch/by-value/`. Nothing in the repository was
modified and no build step was run.

---

## 1. The header census, verified

`include/zaccesskit.h` is 6596 lines. The header states its own function count at
line 1779: *"Functions. 496 of them, plus two this port adds."* The two it adds
are `accesskit_set_allocator` at line 6487 and `accesskit_last_error` at line
6499. **496 + 2 = 498, and a lexical scan finds exactly 498 unique function
declarations with zero duplicates.**

| What | Count | How it was checked |
|---|---:|---|
| Function declarations | **498** | Lexical scan, then a C fixture that takes the address of all 446 Linux-visible ones — compiles clean |
| Duplicate declarations | **0** | Each name appears exactly once in the scan |
| Enum declarations | **19** | See the note below |
| Enum variants | **272** | Counted per body: 262 + 8 + 2 |
| Laid-out structs | **40** | `typedef struct NAME { … } NAME;` — 39 portable, 1 Windows-only |
| Opaque structs | **18** | `typedef struct NAME NAME;` forward declarations |
| Function-pointer typedefs | **4** | `accesskit_tree_update_factory`, `…_activation_handler_callback`, `…_action_handler_callback`, `…_deactivation_handler_callback` |
| Exported data object | **1** | `extern const struct accesskit_tree_id ACCESSKIT_TREE_ID_ROOT;` |

**The enum count is 19, and the variant count is 272.** These two come from
different places and mixing them produces the number 18 enums with 272 variants,
which is not a census of anything. The 19 break down as:

- **17** bare-tag enums, each with a `typedef uint8_t` alias under
  `#ifndef __cplusplus`, carrying **262** variants. `accesskit_role` alone
  carries 182.
- **1** payload-carrying enum, `accesskit_action_data_Tag` at line 1606, with
  **8** variants and no alias.
- **1** that this port adds: `accesskit_error` at line 1774, with **2**
  variants (`ACCESSKIT_ERROR_NONE`, `ACCESSKIT_ERROR_OUT_OF_MEMORY`).

`docs/31-c-abi-design.md` section 4.0 counts 18 enums and 270 variants. That is
correct *for upstream*, which has no `accesskit_error`; the port header is that
plus the port's own enum. Both numbers describe a real file, so the build map
uses the port's: **19 declarations, 272 variants**. An implementer generating
`enum(u8)` mirrors should emit 17; the eighteenth type on the boundary is
`CActionData`, already written in `src/schema/update.zig:340`.

### 1.1 Platform gating — what a build actually has to produce

The 498 are not all declared on every target. Fifty-two sit behind a preprocessor
guard and the export surface differs per platform.

| Guard in the header | Functions | Total on this target (Linux) |
|---|---:|---:|
| none (portable) | 440 | 440 |
| `__linux__` / BSD family | 6 | 6 |
| `ACCESSKIT_MACOS` | 16 | 0 |
| `__ANDROID__` | 13 | 0 |
| `ACCESSKIT_IOS` / `TVOS` / `VISIONOS` / `WATCHOS` | 13 | 0 |
| `_WIN32` | 10 | 0 |
| **Total** | **498** | **446** |

This is the number the build has to agree with: **`zig build` for
`x86_64-linux` must produce a shared library exporting 446 `accesskit_*`
symbols.** A sweep that compares the library's symbol table against the header
must gate the expectation the same way, or it will report 52 false misses.

### 1.2 Aggregate passing — the census the classifier cares about

**By value and by pointer are different facts and are counted apart.** A struct
passed **by value** crosses the boundary in a register or on the stack, so its
size, its layout and its alignment are part of the contract and a mismatch is a
crash. A struct passed **by pointer** crosses as an address; the pointer is what
is part of the contract and the pointee's layout is the callee's problem. A
declaration that does both is counted in both columns, and there are 16 of them.

| Measurement | By value | By pointer |
|---|---:|---:|
| Declarations with at least one struct parameter of this kind | **42** | **444** |
| Struct parameters of this kind, in all | **58** | **449** |
| Distinct struct types in this position | **9** | **22** |
| Declarations that both return and take a struct **by value** | **28** | — |
| Declarations that return a struct by value and take a struct by pointer | — | **72** |
| Declarations that return a struct by value | **103** | — |

The by-value column is what section 6.2 turns on, and it is what `docs/31`
section 2.5 already reported: **42 declarations, 58 parameters, 9 types**. This
document's earlier figures for the same column — **57, 77 and 11** — were *by
value plus by pointer*, not by value. Section 3.4 gives the derivation of each
of the three, and the correction there is what produced this table.

**There is no divergence from `docs/31` in the by-value figures.** This document
was written to measure one and reported the gap as uniform across all four
parameter figures; the gap is an artefact of its own classifier, which was
blind to `*`. A record that claims to have found a difference and did not is
worse than one that never looked, so the finding is withdrawn here rather than
quietly restated.

**How the numbers were produced, so a reader can re-derive them.** Mask the
comments and string literals in `include/zaccesskit.h` (665 `/*` openers, all
masked), recover each declaration by walking back from its name to the previous
`;`, `{` or `}` and forward through its balanced parentheses, and split the
parameter list on top-level commas. That yields **498 unique declarations, zero
duplicates**. Classify a parameter as a struct *by value* when its type names
one of the 58 struct typedefs in the header and the declarator carries no `*`;
as a struct *by pointer* when it names one and carries a `*`. A struct typedef
is either `typedef struct NAME { … } NAME;` — 40 of them — or
`typedef struct NAME NAME;` — 18. Cross-checked against the preprocessor:
`cc -E -P include/zaccesskit.h` yields exactly the **446** declarations section
1.1 says a Linux target has, and re-running the classifier over the
preprocessed text returns the same **42 / 58 / 9** for by-value parameters and
**405 / 409 / 9** for by-pointer ones. Scratch tree:
`/tmp/scratch/by-value/`.

Three facts the table depends on, each measured:

- **No by-value parameter sits behind a guard.** The 42 / 58 / 9 is identical on
  the full 498 and on the 446 a Linux build sees. Excluding every
  `accesskit_opt_*` from the parameter set changes nothing, because no optional
  is ever passed by value in this header.
- **One by-value return sits behind a guard.**
  `accesskit_windows_adapter_handle_wm_getobject` returns
  `accesskit_opt_lresult` and is the only `_WIN32` by-value return, so the 103
  are 102 on Linux and 103 on Windows.
- **`accesskit_last_error` is not one of the 103.** It returns
  `accesskit_error`, a bare-tag C enum of two variants, not a struct. Any count
  that folds it into a struct figure is counting something else.

Nine of the 103 return `accesskit_affine` by value. The tenth appearance of the
name in a return type is at line 4933, `accesskit_node_transform`, which returns
`const struct accesskit_affine *` — a pointer, not a value, and counted under
by-pointer. The header's own prose at line 112 says "nine return a 48-byte
`accesskit_affine`", and that is right.

The upstream half of this table is not re-measured here.
`accesskit-c/include/accesskit.h` is not in this tree, so the `104 / 57 / 77 /
11 / 31` figure this document and `docs/31` both attribute to upstream at
`8b6ed37c20ed4c59390e253407983333053662ba` **cannot be confirmed from this
checkout**. It also cannot be the upstream of a correct port-side number while
it carries the same pointer-blind rule, so it is withdrawn as evidence rather
than restated.

---

## 2. The export census

Every one of the 498 declarations, grouped by family. This is the table an
implementer works from: a row missing here is a function nobody writes.

**How a row becomes Zig code.** Two mechanisms exist and both were compiled and
linked to confirm the emitted symbol name:

```zig
// Mechanism 1 — the export identifier IS the C symbol. This is the one
// docs/31-c-abi-design.md section 2.2 record B writes, and the one to use.
export fn accesskit_node_label(node: *const accesskit_node) callconv(.c) [*c]u8 {
    return labelZig(declared_allocator(), node) catch null;
}
fn labelZig(gpa: std.mem.Allocator, node: *const Node) error{OutOfMemory}![]const u8 { … }

// Mechanism 2 — camelCase implementation, @export renames it.
fn rectWidth(r: ExternRect) callconv(.c) f64 { return rectWidthImpl(r); }
comptime { @export(&rectWidth, .{ .name = "accesskit_rect_width", .linkage = .strong }); }
```

Both produce the symbol `accesskit_rect_width` in `nm -D`. Mechanism 1 is
preferred: it is what record B specifies, it needs no `comptime` block, and it
makes a missing export a link error rather than a silent omission.
**Mechanism 2 has a precondition that is easy to miss:** `@export` on a function
without `callconv(.c)` fails to compile with `unable to export type 'fn (u32)
u32' / extern function must specify calling convention`. That was measured, not
inferred.

**Column notes.** `hdr` is the line in `include/zaccesskit.h`. The Zig
implementation name is the camelCase body behind the export. The conversion
column names the `marshal.zig` helper the export calls; `identity` means the
value is an `extern struct` on both sides and no conversion happens at all.
`docs/33-consumer-interface-contract.md:322-326` gives the module that owns them, and
`src/schema/update.zig:408-539` already implements four of them —
`actionDataToC`, `actionDataFromC`, `cActionDataDeinit`, `cActionRequestDeinit`
— so section 3.3 treats those as written rather than as work to do.

**Family counts, checked against the table below:**

| Family | Exports |
|---|---:|
| `accesskit_node_*` — builder and getters | 358 |
| `accesskit_rect_*` | 21 |
| `accesskit_macos_*` | 16 |
| `accesskit_affine_*` | 14 |
| `accesskit_android_*` | 13 |
| `accesskit_ios_*` | 13 |
| `accesskit_tree_info_*` | 11 |
| `accesskit_tree_update_*` | 10 |
| `accesskit_windows_*` | 10 |
| `accesskit_custom_action*` | 8 |
| `accesskit_vec2_*` | 6 |
| `accesskit_unix_*` | 6 |
| `accesskit_point_*` | 4 |
| `accesskit_size_*` | 4 |
| runtime channel (`string_free`, `set_allocator`, `last_error`) | 3 |
| `accesskit_action_request*` | 1 |
| **Total** | **498** |



#### Runtime channel: the string release and the two port-added functions — 3 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 1 | 2837 | `accesskit_string_free` | `stringFree` | — (none: scalar/void/pointer only) | `src/capi/root.zig` |
| 2 | 6487 | `accesskit_set_allocator` | `setAllocator` | scalar tag pass | none (owns the channel) |
| 3 | 6499 | `accesskit_last_error` | `lastError` | scalar tag pass | none (owns the channel) |


#### `accesskit_node_*` — the builder half (`src/schema/node.zig`) and the getter half (`src/consumer/node_ref/`) — 358 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 4 | 1799 | `accesskit_node_role` | `nodeRole` | scalar tag pass | src/consumer/node_ref/ + src/schema/node.zig |
| 5 | 1806 | `accesskit_node_set_role` | `nodeSetRole` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 6 | 1815 | `accesskit_node_supports_action` | `nodeSupportsAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 7 | 1824 | `accesskit_node_add_action` | `nodeAddAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 8 | 1833 | `accesskit_node_remove_action` | `nodeRemoveAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 9 | 1841 | `accesskit_node_clear_actions` | `nodeClearActions` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 10 | 1849 | `accesskit_node_child_supports_action` | `nodeChildSupportsAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 11 | 1859 | `accesskit_node_add_child_action` | `nodeAddChildAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 12 | 1869 | `accesskit_node_remove_child_action` | `nodeRemoveChildAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 13 | 1878 | `accesskit_node_clear_child_actions` | `nodeClearChildActions` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 14 | 1886 | `accesskit_node_is_hidden` | `nodeIsHidden` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 15 | 1894 | `accesskit_node_set_hidden` | `nodeSetHidden` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 16 | 1901 | `accesskit_node_clear_hidden` | `nodeClearHidden` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 17 | 1909 | `accesskit_node_is_multiselectable` | `nodeIsMultiselectable` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 18 | 1917 | `accesskit_node_set_multiselectable` | `nodeSetMultiselectable` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 19 | 1925 | `accesskit_node_clear_multiselectable` | `nodeClearMultiselectable` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 20 | 1933 | `accesskit_node_is_required` | `nodeIsRequired` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 21 | 1941 | `accesskit_node_set_required` | `nodeSetRequired` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 22 | 1949 | `accesskit_node_clear_required` | `nodeClearRequired` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 23 | 1957 | `accesskit_node_is_visited` | `nodeIsVisited` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 24 | 1965 | `accesskit_node_set_visited` | `nodeSetVisited` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 25 | 1972 | `accesskit_node_clear_visited` | `nodeClearVisited` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 26 | 1980 | `accesskit_node_is_busy` | `nodeIsBusy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 27 | 1988 | `accesskit_node_set_busy` | `nodeSetBusy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 28 | 1995 | `accesskit_node_clear_busy` | `nodeClearBusy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 29 | 2003 | `accesskit_node_is_live_atomic` | `nodeIsLiveAtomic` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 30 | 2011 | `accesskit_node_set_live_atomic` | `nodeSetLiveAtomic` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 31 | 2019 | `accesskit_node_clear_live_atomic` | `nodeClearLiveAtomic` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 32 | 2027 | `accesskit_node_is_modal` | `nodeIsModal` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 33 | 2035 | `accesskit_node_set_modal` | `nodeSetModal` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 34 | 2042 | `accesskit_node_clear_modal` | `nodeClearModal` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 35 | 2050 | `accesskit_node_is_touch_transparent` | `nodeIsTouchTransparent` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 36 | 2058 | `accesskit_node_set_touch_transparent` | `nodeSetTouchTransparent` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 37 | 2066 | `accesskit_node_clear_touch_transparent` | `nodeClearTouchTransparent` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 38 | 2074 | `accesskit_node_is_read_only` | `nodeIsReadOnly` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 39 | 2082 | `accesskit_node_set_read_only` | `nodeSetReadOnly` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 40 | 2090 | `accesskit_node_clear_read_only` | `nodeClearReadOnly` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 41 | 2098 | `accesskit_node_is_disabled` | `nodeIsDisabled` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 42 | 2106 | `accesskit_node_set_disabled` | `nodeSetDisabled` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 43 | 2114 | `accesskit_node_clear_disabled` | `nodeClearDisabled` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 44 | 2122 | `accesskit_node_is_italic` | `nodeIsItalic` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 45 | 2130 | `accesskit_node_set_italic` | `nodeSetItalic` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 46 | 2137 | `accesskit_node_clear_italic` | `nodeClearItalic` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 47 | 2145 | `accesskit_node_clips_children` | `nodeClipsChildren` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 48 | 2153 | `accesskit_node_set_clips_children` | `nodeSetClipsChildren` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 49 | 2161 | `accesskit_node_clear_clips_children` | `nodeClearClipsChildren` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 50 | 2170 | `accesskit_node_is_line_breaking_object` | `nodeIsLineBreakingObject` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 51 | 2178 | `accesskit_node_set_is_line_breaking_object` | `nodeSetIsLineBreakingObject` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 52 | 2187 | `accesskit_node_clear_is_line_breaking_object` | `nodeClearIsLineBreakingObject` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 53 | 2196 | `accesskit_node_is_page_breaking_object` | `nodeIsPageBreakingObject` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 54 | 2204 | `accesskit_node_set_is_page_breaking_object` | `nodeSetIsPageBreakingObject` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 55 | 2213 | `accesskit_node_clear_is_page_breaking_object` | `nodeClearIsPageBreakingObject` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 56 | 2221 | `accesskit_node_is_spelling_error` | `nodeIsSpellingError` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 57 | 2229 | `accesskit_node_set_is_spelling_error` | `nodeSetIsSpellingError` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 58 | 2237 | `accesskit_node_clear_is_spelling_error` | `nodeClearIsSpellingError` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 59 | 2245 | `accesskit_node_is_grammar_error` | `nodeIsGrammarError` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 60 | 2253 | `accesskit_node_set_is_grammar_error` | `nodeSetIsGrammarError` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 61 | 2261 | `accesskit_node_clear_is_grammar_error` | `nodeClearIsGrammarError` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 62 | 2269 | `accesskit_node_is_search_match` | `nodeIsSearchMatch` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 63 | 2277 | `accesskit_node_set_is_search_match` | `nodeSetIsSearchMatch` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 64 | 2285 | `accesskit_node_clear_is_search_match` | `nodeClearIsSearchMatch` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 65 | 2293 | `accesskit_node_is_suggestion` | `nodeIsSuggestion` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 66 | 2301 | `accesskit_node_set_is_suggestion` | `nodeSetIsSuggestion` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 67 | 2309 | `accesskit_node_clear_is_suggestion` | `nodeClearIsSuggestion` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 68 | 2320 | `accesskit_node_children` | `nodeChildren` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 69 | 2331 | `accesskit_node_set_children` | `nodeSetChildren` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 70 | 2339 | `accesskit_node_push_child` | `nodePushChild` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 71 | 2348 | `accesskit_node_clear_children` | `nodeClearChildren` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 72 | 2359 | `accesskit_node_controls` | `nodeControls` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 73 | 2370 | `accesskit_node_set_controls` | `nodeSetControls` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 74 | 2378 | `accesskit_node_push_controlled` | `nodePushControlled` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 75 | 2387 | `accesskit_node_clear_controls` | `nodeClearControls` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 76 | 2398 | `accesskit_node_details` | `nodeDetails` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 77 | 2409 | `accesskit_node_set_details` | `nodeSetDetails` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 78 | 2417 | `accesskit_node_push_detail` | `nodePushDetail` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 79 | 2425 | `accesskit_node_clear_details` | `nodeClearDetails` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 80 | 2436 | `accesskit_node_described_by` | `nodeDescribedBy` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 81 | 2447 | `accesskit_node_set_described_by` | `nodeSetDescribedBy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 82 | 2456 | `accesskit_node_push_described_by` | `nodePushDescribedBy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 83 | 2465 | `accesskit_node_clear_described_by` | `nodeClearDescribedBy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 84 | 2476 | `accesskit_node_flow_to` | `nodeFlowTo` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 85 | 2487 | `accesskit_node_set_flow_to` | `nodeSetFlowTo` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 86 | 2495 | `accesskit_node_push_flow_to` | `nodePushFlowTo` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 87 | 2503 | `accesskit_node_clear_flow_to` | `nodeClearFlowTo` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 88 | 2514 | `accesskit_node_labelled_by` | `nodeLabelledBy` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 89 | 2525 | `accesskit_node_set_labelled_by` | `nodeSetLabelledBy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 90 | 2534 | `accesskit_node_push_labelled_by` | `nodePushLabelledBy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 91 | 2543 | `accesskit_node_clear_labelled_by` | `nodeClearLabelledBy` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 92 | 2554 | `accesskit_node_owns` | `nodeOwns` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 93 | 2564 | `accesskit_node_set_owns` | `nodeSetOwns` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 94 | 2572 | `accesskit_node_push_owned` | `nodePushOwned` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 95 | 2580 | `accesskit_node_clear_owns` | `nodeClearOwns` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 96 | 2591 | `accesskit_node_radio_group` | `nodeRadioGroup` | nodeIdsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 97 | 2602 | `accesskit_node_set_radio_group` | `nodeSetRadioGroup` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 98 | 2611 | `accesskit_node_push_to_radio_group` | `nodePushToRadioGroup` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 99 | 2620 | `accesskit_node_clear_radio_group` | `nodeClearRadioGroup` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 100 | 2629 | `accesskit_node_active_descendant` | `nodeActiveDescendant` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 101 | 2637 | `accesskit_node_set_active_descendant` | `nodeSetActiveDescendant` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 102 | 2646 | `accesskit_node_clear_active_descendant` | `nodeClearActiveDescendant` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 103 | 2655 | `accesskit_node_error_message` | `nodeErrorMessage` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 104 | 2663 | `accesskit_node_set_error_message` | `nodeSetErrorMessage` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 105 | 2672 | `accesskit_node_clear_error_message` | `nodeClearErrorMessage` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 106 | 2681 | `accesskit_node_in_page_link_target` | `nodeInPageLinkTarget` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 107 | 2689 | `accesskit_node_set_in_page_link_target` | `nodeSetInPageLinkTarget` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 108 | 2698 | `accesskit_node_clear_in_page_link_target` | `nodeClearInPageLinkTarget` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 109 | 2707 | `accesskit_node_member_of` | `nodeMemberOf` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 110 | 2715 | `accesskit_node_set_member_of` | `nodeSetMemberOf` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 111 | 2724 | `accesskit_node_clear_member_of` | `nodeClearMemberOf` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 112 | 2733 | `accesskit_node_next_on_line` | `nodeNextOnLine` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 113 | 2741 | `accesskit_node_set_next_on_line` | `nodeSetNextOnLine` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 114 | 2750 | `accesskit_node_clear_next_on_line` | `nodeClearNextOnLine` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 115 | 2759 | `accesskit_node_previous_on_line` | `nodePreviousOnLine` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 116 | 2767 | `accesskit_node_set_previous_on_line` | `nodeSetPreviousOnLine` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 117 | 2776 | `accesskit_node_clear_previous_on_line` | `nodeClearPreviousOnLine` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 118 | 2785 | `accesskit_node_popup_for` | `nodePopupFor` | opt_node_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 119 | 2793 | `accesskit_node_set_popup_for` | `nodeSetPopupFor` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 120 | 2802 | `accesskit_node_clear_popup_for` | `nodeClearPopupFor` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 121 | 2811 | `accesskit_node_tree_id` | `nodeTreeId` | opt_tree_id_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 122 | 2819 | `accesskit_node_set_tree_id` | `nodeSetTreeId` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 123 | 2827 | `accesskit_node_clear_tree_id` | `nodeClearTreeId` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 124 | 2849 | `accesskit_node_label` | `nodeLabel` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 125 | 2857 | `accesskit_node_set_label` | `nodeSetLabel` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 126 | 2868 | `accesskit_node_set_label_with_length` | `nodeSetLabelWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 127 | 2876 | `accesskit_node_clear_label` | `nodeClearLabel` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 128 | 2888 | `accesskit_node_description` | `nodeDescription` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 129 | 2896 | `accesskit_node_set_description` | `nodeSetDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 130 | 2908 | `accesskit_node_set_description_with_length` | `nodeSetDescriptionWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 131 | 2918 | `accesskit_node_clear_description` | `nodeClearDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 132 | 2930 | `accesskit_node_value` | `nodeValue` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 133 | 2938 | `accesskit_node_set_value` | `nodeSetValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 134 | 2949 | `accesskit_node_set_value_with_length` | `nodeSetValueWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 135 | 2957 | `accesskit_node_clear_value` | `nodeClearValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 136 | 2969 | `accesskit_node_access_key` | `nodeAccessKey` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 137 | 2977 | `accesskit_node_set_access_key` | `nodeSetAccessKey` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 138 | 2989 | `accesskit_node_set_access_key_with_length` | `nodeSetAccessKeyWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 139 | 2999 | `accesskit_node_clear_access_key` | `nodeClearAccessKey` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 140 | 3011 | `accesskit_node_author_id` | `nodeAuthorId` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 141 | 3019 | `accesskit_node_set_author_id` | `nodeSetAuthorId` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 142 | 3031 | `accesskit_node_set_author_id_with_length` | `nodeSetAuthorIdWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 143 | 3041 | `accesskit_node_clear_author_id` | `nodeClearAuthorId` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 144 | 3053 | `accesskit_node_class_name` | `nodeClassName` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 145 | 3061 | `accesskit_node_set_class_name` | `nodeSetClassName` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 146 | 3073 | `accesskit_node_set_class_name_with_length` | `nodeSetClassNameWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 147 | 3083 | `accesskit_node_clear_class_name` | `nodeClearClassName` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 148 | 3095 | `accesskit_node_font_family` | `nodeFontFamily` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 149 | 3103 | `accesskit_node_set_font_family` | `nodeSetFontFamily` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 150 | 3115 | `accesskit_node_set_font_family_with_length` | `nodeSetFontFamilyWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 151 | 3125 | `accesskit_node_clear_font_family` | `nodeClearFontFamily` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 152 | 3137 | `accesskit_node_html_id` | `nodeHtmlId` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 153 | 3145 | `accesskit_node_set_html_id` | `nodeSetHtmlId` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 154 | 3157 | `accesskit_node_set_html_id_with_length` | `nodeSetHtmlIdWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 155 | 3165 | `accesskit_node_clear_html_id` | `nodeClearHtmlId` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 156 | 3177 | `accesskit_node_html_tag` | `nodeHtmlTag` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 157 | 3185 | `accesskit_node_set_html_tag` | `nodeSetHtmlTag` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 158 | 3197 | `accesskit_node_set_html_tag_with_length` | `nodeSetHtmlTagWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 159 | 3207 | `accesskit_node_clear_html_tag` | `nodeClearHtmlTag` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 160 | 3219 | `accesskit_node_inner_html` | `nodeInnerHtml` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 161 | 3227 | `accesskit_node_set_inner_html` | `nodeSetInnerHtml` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 162 | 3239 | `accesskit_node_set_inner_html_with_length` | `nodeSetInnerHtmlWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 163 | 3249 | `accesskit_node_clear_inner_html` | `nodeClearInnerHtml` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 164 | 3261 | `accesskit_node_keyboard_shortcut` | `nodeKeyboardShortcut` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 165 | 3270 | `accesskit_node_set_keyboard_shortcut` | `nodeSetKeyboardShortcut` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 166 | 3283 | `accesskit_node_set_keyboard_shortcut_with_length` | `nodeSetKeyboardShortcutWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 167 | 3292 | `accesskit_node_clear_keyboard_shortcut` | `nodeClearKeyboardShortcut` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 168 | 3304 | `accesskit_node_language` | `nodeLanguage` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 169 | 3312 | `accesskit_node_set_language` | `nodeSetLanguage` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 170 | 3324 | `accesskit_node_set_language_with_length` | `nodeSetLanguageWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 171 | 3334 | `accesskit_node_clear_language` | `nodeClearLanguage` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 172 | 3346 | `accesskit_node_placeholder` | `nodePlaceholder` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 173 | 3354 | `accesskit_node_set_placeholder` | `nodeSetPlaceholder` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 174 | 3366 | `accesskit_node_set_placeholder_with_length` | `nodeSetPlaceholderWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 175 | 3376 | `accesskit_node_clear_placeholder` | `nodeClearPlaceholder` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 176 | 3388 | `accesskit_node_role_description` | `nodeRoleDescription` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 177 | 3397 | `accesskit_node_set_role_description` | `nodeSetRoleDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 178 | 3410 | `accesskit_node_set_role_description_with_length` | `nodeSetRoleDescriptionWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 179 | 3419 | `accesskit_node_clear_role_description` | `nodeClearRoleDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 180 | 3431 | `accesskit_node_state_description` | `nodeStateDescription` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 181 | 3440 | `accesskit_node_set_state_description` | `nodeSetStateDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 182 | 3453 | `accesskit_node_set_state_description_with_length` | `nodeSetStateDescriptionWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 183 | 3462 | `accesskit_node_clear_state_description` | `nodeClearStateDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 184 | 3474 | `accesskit_node_tooltip` | `nodeTooltip` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 185 | 3482 | `accesskit_node_set_tooltip` | `nodeSetTooltip` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 186 | 3494 | `accesskit_node_set_tooltip_with_length` | `nodeSetTooltipWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 187 | 3502 | `accesskit_node_clear_tooltip` | `nodeClearTooltip` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 188 | 3513 | `accesskit_node_url` | `nodeUrl` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 189 | 3521 | `accesskit_node_set_url` | `nodeSetUrl` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 190 | 3532 | `accesskit_node_set_url_with_length` | `nodeSetUrlWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 191 | 3540 | `accesskit_node_clear_url` | `nodeClearUrl` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 192 | 3552 | `accesskit_node_row_index_text` | `nodeRowIndexText` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 193 | 3560 | `accesskit_node_set_row_index_text` | `nodeSetRowIndexText` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 194 | 3573 | `accesskit_node_set_row_index_text_with_length` | `nodeSetRowIndexTextWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 195 | 3582 | `accesskit_node_clear_row_index_text` | `nodeClearRowIndexText` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 196 | 3594 | `accesskit_node_column_index_text` | `nodeColumnIndexText` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 197 | 3603 | `accesskit_node_set_column_index_text` | `nodeSetColumnIndexText` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 198 | 3616 | `accesskit_node_set_column_index_text_with_length` | `nodeSetColumnIndexTextWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 199 | 3625 | `accesskit_node_clear_column_index_text` | `nodeClearColumnIndexText` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 200 | 3637 | `accesskit_node_braille_label` | `nodeBrailleLabel` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 201 | 3645 | `accesskit_node_set_braille_label` | `nodeSetBrailleLabel` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 202 | 3657 | `accesskit_node_set_braille_label_with_length` | `nodeSetBrailleLabelWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 203 | 3667 | `accesskit_node_clear_braille_label` | `nodeClearBrailleLabel` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 204 | 3680 | `accesskit_node_braille_role_description` | `nodeBrailleRoleDescription` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |
| 205 | 3689 | `accesskit_node_set_braille_role_description` | `nodeSetBrailleRoleDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 206 | 3702 | `accesskit_node_set_braille_role_description_with_length` | `nodeSetBrailleRoleDescriptionWithLength` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 207 | 3714 | `accesskit_node_clear_braille_role_description` | `nodeClearBrailleRoleDescription` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 208 | 3723 | `accesskit_node_scroll_x` | `nodeScrollX` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 209 | 3731 | `accesskit_node_set_scroll_x` | `nodeSetScrollX` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 210 | 3739 | `accesskit_node_clear_scroll_x` | `nodeClearScrollX` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 211 | 3748 | `accesskit_node_scroll_x_min` | `nodeScrollXMin` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 212 | 3756 | `accesskit_node_set_scroll_x_min` | `nodeSetScrollXMin` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 213 | 3765 | `accesskit_node_clear_scroll_x_min` | `nodeClearScrollXMin` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 214 | 3774 | `accesskit_node_scroll_x_max` | `nodeScrollXMax` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 215 | 3782 | `accesskit_node_set_scroll_x_max` | `nodeSetScrollXMax` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 216 | 3791 | `accesskit_node_clear_scroll_x_max` | `nodeClearScrollXMax` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 217 | 3800 | `accesskit_node_scroll_y` | `nodeScrollY` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 218 | 3808 | `accesskit_node_set_scroll_y` | `nodeSetScrollY` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 219 | 3816 | `accesskit_node_clear_scroll_y` | `nodeClearScrollY` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 220 | 3825 | `accesskit_node_scroll_y_min` | `nodeScrollYMin` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 221 | 3833 | `accesskit_node_set_scroll_y_min` | `nodeSetScrollYMin` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 222 | 3842 | `accesskit_node_clear_scroll_y_min` | `nodeClearScrollYMin` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 223 | 3851 | `accesskit_node_scroll_y_max` | `nodeScrollYMax` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 224 | 3859 | `accesskit_node_set_scroll_y_max` | `nodeSetScrollYMax` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 225 | 3868 | `accesskit_node_clear_scroll_y_max` | `nodeClearScrollYMax` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 226 | 3877 | `accesskit_node_numeric_value` | `nodeNumericValue` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 227 | 3885 | `accesskit_node_set_numeric_value` | `nodeSetNumericValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 228 | 3894 | `accesskit_node_clear_numeric_value` | `nodeClearNumericValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 229 | 3903 | `accesskit_node_min_numeric_value` | `nodeMinNumericValue` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 230 | 3911 | `accesskit_node_set_min_numeric_value` | `nodeSetMinNumericValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 231 | 3920 | `accesskit_node_clear_min_numeric_value` | `nodeClearMinNumericValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 232 | 3929 | `accesskit_node_max_numeric_value` | `nodeMaxNumericValue` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 233 | 3937 | `accesskit_node_set_max_numeric_value` | `nodeSetMaxNumericValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 234 | 3946 | `accesskit_node_clear_max_numeric_value` | `nodeClearMaxNumericValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 235 | 3955 | `accesskit_node_numeric_value_step` | `nodeNumericValueStep` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 236 | 3963 | `accesskit_node_set_numeric_value_step` | `nodeSetNumericValueStep` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 237 | 3972 | `accesskit_node_clear_numeric_value_step` | `nodeClearNumericValueStep` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 238 | 3981 | `accesskit_node_numeric_value_jump` | `nodeNumericValueJump` | opt_double_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 239 | 3989 | `accesskit_node_set_numeric_value_jump` | `nodeSetNumericValueJump` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 240 | 3998 | `accesskit_node_clear_numeric_value_jump` | `nodeClearNumericValueJump` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 241 | 4007 | `accesskit_node_font_size` | `nodeFontSize` | opt_float_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 242 | 4015 | `accesskit_node_set_font_size` | `nodeSetFontSize` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 243 | 4023 | `accesskit_node_clear_font_size` | `nodeClearFontSize` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 244 | 4032 | `accesskit_node_font_weight` | `nodeFontWeight` | opt_float_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 245 | 4040 | `accesskit_node_set_font_weight` | `nodeSetFontWeight` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 246 | 4048 | `accesskit_node_clear_font_weight` | `nodeClearFontWeight` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 247 | 4057 | `accesskit_node_row_count` | `nodeRowCount` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 248 | 4065 | `accesskit_node_set_row_count` | `nodeSetRowCount` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 249 | 4073 | `accesskit_node_clear_row_count` | `nodeClearRowCount` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 250 | 4082 | `accesskit_node_column_count` | `nodeColumnCount` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 251 | 4090 | `accesskit_node_set_column_count` | `nodeSetColumnCount` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 252 | 4099 | `accesskit_node_clear_column_count` | `nodeClearColumnCount` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 253 | 4108 | `accesskit_node_row_index` | `nodeRowIndex` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 254 | 4116 | `accesskit_node_set_row_index` | `nodeSetRowIndex` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 255 | 4124 | `accesskit_node_clear_row_index` | `nodeClearRowIndex` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 256 | 4133 | `accesskit_node_column_index` | `nodeColumnIndex` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 257 | 4141 | `accesskit_node_set_column_index` | `nodeSetColumnIndex` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 258 | 4150 | `accesskit_node_clear_column_index` | `nodeClearColumnIndex` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 259 | 4159 | `accesskit_node_row_span` | `nodeRowSpan` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 260 | 4167 | `accesskit_node_set_row_span` | `nodeSetRowSpan` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 261 | 4175 | `accesskit_node_clear_row_span` | `nodeClearRowSpan` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 262 | 4184 | `accesskit_node_column_span` | `nodeColumnSpan` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 263 | 4192 | `accesskit_node_set_column_span` | `nodeSetColumnSpan` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 264 | 4201 | `accesskit_node_clear_column_span` | `nodeClearColumnSpan` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 265 | 4210 | `accesskit_node_level` | `nodeLevel` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 266 | 4218 | `accesskit_node_set_level` | `nodeSetLevel` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 267 | 4225 | `accesskit_node_clear_level` | `nodeClearLevel` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 268 | 4234 | `accesskit_node_size_of_set` | `nodeSizeOfSet` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 269 | 4242 | `accesskit_node_set_size_of_set` | `nodeSetSizeOfSet` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 270 | 4251 | `accesskit_node_clear_size_of_set` | `nodeClearSizeOfSet` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 271 | 4260 | `accesskit_node_position_in_set` | `nodePositionInSet` | opt_index_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 272 | 4268 | `accesskit_node_set_position_in_set` | `nodeSetPositionInSet` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 273 | 4277 | `accesskit_node_clear_position_in_set` | `nodeClearPositionInSet` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 274 | 4286 | `accesskit_node_color_value` | `nodeColorValue` | opt_color_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 275 | 4294 | `accesskit_node_set_color_value` | `nodeSetColorValue` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 276 | 4303 | `accesskit_node_clear_color_value` | `nodeClearColorValue` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 277 | 4312 | `accesskit_node_background_color` | `nodeBackgroundColor` | opt_color_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 278 | 4320 | `accesskit_node_set_background_color` | `nodeSetBackgroundColor` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 279 | 4329 | `accesskit_node_clear_background_color` | `nodeClearBackgroundColor` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 280 | 4338 | `accesskit_node_foreground_color` | `nodeForegroundColor` | opt_color_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 281 | 4346 | `accesskit_node_set_foreground_color` | `nodeSetForegroundColor` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 282 | 4355 | `accesskit_node_clear_foreground_color` | `nodeClearForegroundColor` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 283 | 4364 | `accesskit_node_overline` | `nodeOverline` | opt_text_decoration_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 284 | 4372 | `accesskit_node_set_overline` | `nodeSetOverline` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 285 | 4381 | `accesskit_node_clear_overline` | `nodeClearOverline` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 286 | 4390 | `accesskit_node_strikethrough` | `nodeStrikethrough` | opt_text_decoration_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 287 | 4398 | `accesskit_node_set_strikethrough` | `nodeSetStrikethrough` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 288 | 4407 | `accesskit_node_clear_strikethrough` | `nodeClearStrikethrough` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 289 | 4416 | `accesskit_node_underline` | `nodeUnderline` | opt_text_decoration_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 290 | 4424 | `accesskit_node_set_underline` | `nodeSetUnderline` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 291 | 4433 | `accesskit_node_clear_underline` | `nodeClearUnderline` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 292 | 4445 | `accesskit_node_character_lengths` | `nodeCharacterLengths` | lengthsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 293 | 4456 | `accesskit_node_set_character_lengths` | `nodeSetCharacterLengths` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 294 | 4466 | `accesskit_node_clear_character_lengths` | `nodeClearCharacterLengths` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 295 | 4477 | `accesskit_node_word_starts` | `nodeWordStarts` | lengthsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 296 | 4488 | `accesskit_node_set_word_starts` | `nodeSetWordStarts` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 297 | 4497 | `accesskit_node_clear_word_starts` | `nodeClearWordStarts` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 298 | 4510 | `accesskit_node_character_positions` | `nodeCharacterPositions` | optCoordsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 299 | 4521 | `accesskit_node_set_character_positions` | `nodeSetCharacterPositions` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 300 | 4531 | `accesskit_node_clear_character_positions` | `nodeClearCharacterPositions` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 301 | 4543 | `accesskit_node_character_widths` | `nodeCharacterWidths` | optCoordsToC | src/consumer/node_ref/ + src/schema/node.zig |
| 302 | 4554 | `accesskit_node_set_character_widths` | `nodeSetCharacterWidths` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 303 | 4563 | `accesskit_node_clear_character_widths` | `nodeClearCharacterWidths` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 304 | 4572 | `accesskit_node_is_expanded` | `nodeIsExpanded` | opt_bool_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 305 | 4580 | `accesskit_node_set_expanded` | `nodeSetExpanded` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 306 | 4588 | `accesskit_node_clear_expanded` | `nodeClearExpanded` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 307 | 4597 | `accesskit_node_is_selected` | `nodeIsSelected` | opt_bool_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 308 | 4605 | `accesskit_node_set_selected` | `nodeSetSelected` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 309 | 4613 | `accesskit_node_clear_selected` | `nodeClearSelected` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 310 | 4622 | `accesskit_node_invalid` | `nodeInvalid` | opt_invalid_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 311 | 4630 | `accesskit_node_set_invalid` | `nodeSetInvalid` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 312 | 4638 | `accesskit_node_clear_invalid` | `nodeClearInvalid` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 313 | 4647 | `accesskit_node_toggled` | `nodeToggled` | opt_toggled_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 314 | 4655 | `accesskit_node_set_toggled` | `nodeSetToggled` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 315 | 4663 | `accesskit_node_clear_toggled` | `nodeClearToggled` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 316 | 4672 | `accesskit_node_live` | `nodeLive` | opt_live_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 317 | 4680 | `accesskit_node_set_live` | `nodeSetLive` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 318 | 4688 | `accesskit_node_clear_live` | `nodeClearLive` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 319 | 4697 | `accesskit_node_text_direction` | `nodeTextDirection` | opt_text_direction_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 320 | 4705 | `accesskit_node_set_text_direction` | `nodeSetTextDirection` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 321 | 4714 | `accesskit_node_clear_text_direction` | `nodeClearTextDirection` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 322 | 4723 | `accesskit_node_orientation` | `nodeOrientation` | opt_orientation_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 323 | 4731 | `accesskit_node_set_orientation` | `nodeSetOrientation` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 324 | 4740 | `accesskit_node_clear_orientation` | `nodeClearOrientation` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 325 | 4749 | `accesskit_node_sort_direction` | `nodeSortDirection` | opt_sort_direction_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 326 | 4757 | `accesskit_node_set_sort_direction` | `nodeSetSortDirection` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 327 | 4766 | `accesskit_node_clear_sort_direction` | `nodeClearSortDirection` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 328 | 4775 | `accesskit_node_aria_current` | `nodeAriaCurrent` | opt_aria_current_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 329 | 4783 | `accesskit_node_set_aria_current` | `nodeSetAriaCurrent` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 330 | 4792 | `accesskit_node_clear_aria_current` | `nodeClearAriaCurrent` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 331 | 4801 | `accesskit_node_auto_complete` | `nodeAutoComplete` | opt_auto_complete_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 332 | 4809 | `accesskit_node_set_auto_complete` | `nodeSetAutoComplete` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 333 | 4818 | `accesskit_node_clear_auto_complete` | `nodeClearAutoComplete` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 334 | 4827 | `accesskit_node_has_popup` | `nodeHasPopup` | opt_has_popup_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 335 | 4835 | `accesskit_node_set_has_popup` | `nodeSetHasPopup` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 336 | 4844 | `accesskit_node_clear_has_popup` | `nodeClearHasPopup` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 337 | 4853 | `accesskit_node_list_style` | `nodeListStyle` | opt_list_style_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 338 | 4861 | `accesskit_node_set_list_style` | `nodeSetListStyle` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 339 | 4870 | `accesskit_node_clear_list_style` | `nodeClearListStyle` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 340 | 4879 | `accesskit_node_text_align` | `nodeTextAlign` | opt_text_align_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 341 | 4887 | `accesskit_node_set_text_align` | `nodeSetTextAlign` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 342 | 4896 | `accesskit_node_clear_text_align` | `nodeClearTextAlign` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 343 | 4905 | `accesskit_node_vertical_offset` | `nodeVerticalOffset` | opt_vertical_offset_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 344 | 4913 | `accesskit_node_set_vertical_offset` | `nodeSetVerticalOffset` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 345 | 4922 | `accesskit_node_clear_vertical_offset` | `nodeClearVerticalOffset` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 346 | 4933 | `accesskit_node_transform` | `nodeTransform` | identity (both sides extern) | src/consumer/node_ref/ + src/schema/node.zig |
| 347 | 4941 | `accesskit_node_set_transform` | `nodeSetTransform` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 348 | 4950 | `accesskit_node_clear_transform` | `nodeClearTransform` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 349 | 4959 | `accesskit_node_bounds` | `nodeBounds` | opt_rect_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 350 | 4967 | `accesskit_node_set_bounds` | `nodeSetBounds` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 351 | 4975 | `accesskit_node_clear_bounds` | `nodeClearBounds` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 352 | 4984 | `accesskit_node_text_selection` | `nodeTextSelection` | opt_text_selection_toC | src/consumer/node_ref/ + src/schema/node.zig |
| 353 | 4992 | `accesskit_node_set_text_selection` | `nodeSetTextSelection` | identity | src/consumer/node_ref/ + src/schema/node.zig |
| 354 | 5001 | `accesskit_node_clear_text_selection` | `nodeClearTextSelection` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 355 | 5094 | `accesskit_node_custom_actions` | `nodeCustomActions` | scalar tag pass | src/consumer/node_ref/ + src/schema/node.zig |
| 356 | 5104 | `accesskit_node_set_custom_actions` | `nodeSetCustomActions` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 357 | 5115 | `accesskit_node_push_custom_action` | `nodePushCustomAction` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 358 | 5124 | `accesskit_node_clear_custom_actions` | `nodeClearCustomActions` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 359 | 5134 | `accesskit_node_new` | `nodeNew` | scalar tag pass | src/consumer/node_ref/ + src/schema/node.zig |
| 360 | 5143 | `accesskit_node_free` | `nodeFree` | — (none: scalar/void/pointer only) | src/consumer/node_ref/ + src/schema/node.zig |
| 361 | 5153 | `accesskit_node_debug` | `nodeDebug` | dupCString | src/consumer/node_ref/ + src/schema/node.zig |


#### `accesskit_tree_info_*` — 11 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 362 | 5164 | `accesskit_tree_info_new` | `treeInfoNew` | scalar tag pass | src/schema/update.zig |
| 363 | 5172 | `accesskit_tree_info_free` | `treeInfoFree` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 364 | 5185 | `accesskit_tree_info_get_toolkit_name` | `treeInfoGetToolkitName` | dupCString | src/schema/update.zig |
| 365 | 5193 | `accesskit_tree_info_set_toolkit_name` | `treeInfoSetToolkitName` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 366 | 5206 | `accesskit_tree_info_set_toolkit_name_with_length` | `treeInfoSetToolkitNameWithLength` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 367 | 5217 | `accesskit_tree_info_clear_toolkit_name` | `treeInfoClearToolkitName` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 368 | 5230 | `accesskit_tree_info_get_toolkit_version` | `treeInfoGetToolkitVersion` | dupCString | src/schema/update.zig |
| 369 | 5239 | `accesskit_tree_info_set_toolkit_version` | `treeInfoSetToolkitVersion` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 370 | 5252 | `accesskit_tree_info_set_toolkit_version_with_length` | `treeInfoSetToolkitVersionWithLength` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 371 | 5264 | `accesskit_tree_info_clear_toolkit_version` | `treeInfoClearToolkitVersion` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 372 | 5274 | `accesskit_tree_info_debug` | `treeInfoDebug` | dupCString | src/schema/update.zig |


#### `accesskit_tree_update_*` — 10 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 373 | 5286 | `accesskit_tree_update_with_focus` | `treeUpdateWithFocus` | scalar tag pass | src/schema/update.zig |
| 374 | 5298 | `accesskit_tree_update_with_capacity_and_focus` | `treeUpdateWithCapacityAndFocus` | scalar tag pass | src/schema/update.zig |
| 375 | 5309 | `accesskit_tree_update_free` | `treeUpdateFree` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 376 | 5318 | `accesskit_tree_update_push_node` | `treeUpdatePushNode` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 377 | 5331 | `accesskit_tree_update_set_tree_info` | `treeUpdateSetTreeInfo` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 378 | 5341 | `accesskit_tree_update_clear_tree_info` | `treeUpdateClearTreeInfo` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 379 | 5348 | `accesskit_tree_update_set_focus` | `treeUpdateSetFocus` | — (none: scalar/void/pointer only) | src/schema/update.zig |
| 380 | 5357 | `accesskit_tree_update_get_tree_id` | `treeUpdateGetTreeId` | identity (both sides extern) | src/schema/update.zig |
| 381 | 5364 | `accesskit_tree_update_set_tree_id` | `treeUpdateSetTreeId` | identity | src/schema/update.zig |
| 382 | 5376 | `accesskit_tree_update_debug` | `treeUpdateDebug` | dupCString | src/schema/update.zig |


#### `accesskit_custom_action*` — 8 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 383 | 5012 | `accesskit_custom_action_new` | `customActionNew` | scalar tag pass | src/schema/values.zig |
| 384 | 5021 | `accesskit_custom_action_free` | `customActionFree` | — (none: scalar/void/pointer only) | src/schema/values.zig |
| 385 | 5027 | `accesskit_custom_action_id` | `customActionId` | — (none: scalar/void/pointer only) | src/schema/values.zig |
| 386 | 5034 | `accesskit_custom_action_set_id` | `customActionSetId` | — (none: scalar/void/pointer only) | src/schema/values.zig |
| 387 | 5048 | `accesskit_custom_action_description` | `customActionDescription` | dupCString | src/schema/values.zig |
| 388 | 5058 | `accesskit_custom_action_set_description` | `customActionSetDescription` | — (none: scalar/void/pointer only) | src/schema/values.zig |
| 389 | 5072 | `accesskit_custom_action_set_description_with_length` | `customActionSetDescriptionWithLength` | — (none: scalar/void/pointer only) | src/schema/values.zig |
| 390 | 5083 | `accesskit_custom_actions_free` | `customActionsFree` | — (none: scalar/void/pointer only) | src/schema/values.zig |


#### `accesskit_action_request*` — 1 export

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 391 | 5387 | `accesskit_action_request_free` | `actionRequestFree` | actionRequestFromC | src/schema/update.zig |


#### `accesskit_affine_*` — 14 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 392 | 5392 | `accesskit_affine_identity` | `affineIdentity` | identity (both sides extern) | src/schema/geometry/affine.zig |
| 393 | 5397 | `accesskit_affine_flip_y` | `affineFlipY` | identity (both sides extern) | src/schema/geometry/affine.zig |
| 394 | 5402 | `accesskit_affine_flip_x` | `affineFlipX` | identity (both sides extern) | src/schema/geometry/affine.zig |
| 395 | 5407 | `accesskit_affine_scale` | `affineScale` | identity (both sides extern) | src/schema/geometry/affine.zig |
| 396 | 5413 | `accesskit_affine_scale_non_uniform` | `affineScaleNonUniform` | identity (both sides extern) | src/schema/geometry/affine.zig |
| 397 | 5419 | `accesskit_affine_translate` | `affineTranslate` | identity (both sides extern) + identity | src/schema/geometry/affine.zig |
| 398 | 5425 | `accesskit_affine_map_unit_square` | `affineMapUnitSquare` | identity (both sides extern) + identity | src/schema/geometry/affine.zig |
| 399 | 5430 | `accesskit_affine_determinant` | `affineDeterminant` | identity | src/schema/geometry/affine.zig |
| 400 | 5439 | `accesskit_affine_inverse` | `affineInverse` | identity (both sides extern) + identity | src/schema/geometry/affine.zig |
| 401 | 5446 | `accesskit_affine_transform_rect_bbox` | `affineTransformRectBbox` | identity (both sides extern) + identity | src/schema/geometry/affine.zig |
| 402 | 5454 | `accesskit_affine_is_finite` | `affineIsFinite` | identity | src/schema/geometry/affine.zig |
| 403 | 5461 | `accesskit_affine_is_nan` | `affineIsNan` | identity | src/schema/geometry/affine.zig |
| 404 | 5470 | `accesskit_affine_mul` | `affineMul` | identity (both sides extern) + identity | src/schema/geometry/affine.zig |
| 405 | 5477 | `accesskit_affine_transform_point` | `affineTransformPoint` | identity (both sides extern) + identity | src/schema/geometry/affine.zig |


#### `accesskit_rect_*` — 21 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 406 | 5506 | `accesskit_rect_new` | `rectNew` | identity (both sides extern) | src/schema/geometry/rect.zig |
| 407 | 5512 | `accesskit_rect_from_points` | `rectFromPoints` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 408 | 5520 | `accesskit_rect_from_origin_size` | `rectFromOriginSize` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 409 | 5528 | `accesskit_rect_with_origin` | `rectWithOrigin` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 410 | 5534 | `accesskit_rect_with_size` | `rectWithSize` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 411 | 5542 | `accesskit_rect_width` | `rectWidth` | identity | src/schema/geometry/rect.zig |
| 412 | 5549 | `accesskit_rect_height` | `rectHeight` | identity | src/schema/geometry/rect.zig |
| 413 | 5556 | `accesskit_rect_min_x` | `rectMinX` | identity | src/schema/geometry/rect.zig |
| 414 | 5563 | `accesskit_rect_max_x` | `rectMaxX` | identity | src/schema/geometry/rect.zig |
| 415 | 5570 | `accesskit_rect_min_y` | `rectMinY` | identity | src/schema/geometry/rect.zig |
| 416 | 5577 | `accesskit_rect_max_y` | `rectMaxY` | identity | src/schema/geometry/rect.zig |
| 417 | 5585 | `accesskit_rect_origin` | `rectOrigin` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 418 | 5592 | `accesskit_rect_size` | `rectSize` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 419 | 5600 | `accesskit_rect_abs` | `rectAbs` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 420 | 5607 | `accesskit_rect_area` | `rectArea` | identity | src/schema/geometry/rect.zig |
| 421 | 5614 | `accesskit_rect_is_empty` | `rectIsEmpty` | identity | src/schema/geometry/rect.zig |
| 422 | 5621 | `accesskit_rect_contains` | `rectContains` | identity | src/schema/geometry/rect.zig |
| 423 | 5629 | `accesskit_rect_union` | `rectUnion` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 424 | 5638 | `accesskit_rect_union_pt` | `rectUnionPt` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 425 | 5648 | `accesskit_rect_intersect` | `rectIntersect` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |
| 426 | 5655 | `accesskit_rect_translate` | `rectTranslate` | identity (both sides extern) + identity | src/schema/geometry/rect.zig |


#### `accesskit_point_*` — 4 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 427 | 5483 | `accesskit_point_to_vec2` | `pointToVec2` | identity (both sides extern) + identity | src/schema/geometry/point.zig |
| 428 | 5488 | `accesskit_point_add_vec2` | `pointAddVec2` | identity (both sides extern) + identity | src/schema/geometry/point.zig |
| 429 | 5494 | `accesskit_point_sub_vec2` | `pointSubVec2` | identity (both sides extern) + identity | src/schema/geometry/point.zig |
| 430 | 5500 | `accesskit_point_sub_point` | `pointSubPoint` | identity (both sides extern) + identity | src/schema/geometry/point.zig |


#### `accesskit_vec2_*` — 6 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 431 | 5685 | `accesskit_vec2_to_point` | `vec2ToPoint` | identity (both sides extern) + identity | src/schema/geometry/vec2.zig |
| 432 | 5690 | `accesskit_vec2_to_size` | `vec2ToSize` | identity (both sides extern) + identity | src/schema/geometry/vec2.zig |
| 433 | 5695 | `accesskit_vec2_add` | `vec2Add` | identity (both sides extern) + identity | src/schema/geometry/vec2.zig |
| 434 | 5701 | `accesskit_vec2_sub` | `vec2Sub` | identity (both sides extern) + identity | src/schema/geometry/vec2.zig |
| 435 | 5707 | `accesskit_vec2_scale` | `vec2Scale` | identity (both sides extern) + identity | src/schema/geometry/vec2.zig |
| 436 | 5713 | `accesskit_vec2_neg` | `vec2Neg` | identity (both sides extern) + identity | src/schema/geometry/vec2.zig |


#### `accesskit_size_*` — 4 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 437 | 5662 | `accesskit_size_to_vec2` | `sizeToVec2` | identity (both sides extern) + identity | src/schema/geometry/size.zig |
| 438 | 5667 | `accesskit_size_scale` | `sizeScale` | identity (both sides extern) + identity | src/schema/geometry/size.zig |
| 439 | 5673 | `accesskit_size_add` | `sizeAdd` | identity (both sides extern) + identity | src/schema/geometry/size.zig |
| 440 | 5679 | `accesskit_size_sub` | `sizeSub` | identity (both sides extern) + identity | src/schema/geometry/size.zig |


#### `accesskit_unix_*` — Linux/BSD adapter — 6 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 441 | 6275 | `accesskit_unix_adapter_new` | `unixAdapterNew` | scalar tag pass | src/adapters/unix |
| 442 | 6288 | `accesskit_unix_adapter_free` | `unixAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/unix |
| 443 | 6297 | `accesskit_unix_adapter_set_root_window_bounds` | `unixAdapterSetRootWindowBounds` | identity | src/adapters/unix |
| 444 | 6312 | `accesskit_unix_adapter_update_if_active` | `unixAdapterUpdateIfActive` | — (none: scalar/void/pointer only) | src/adapters/unix |
| 445 | 6323 | `accesskit_unix_adapter_update_window_focus_state` | `unixAdapterUpdateWindowFocusState` | — (none: scalar/void/pointer only) | src/adapters/unix |
| 446 | 6336 | `accesskit_unix_adapter_debug` | `unixAdapterDebug` | dupCString | src/adapters/unix |


#### `accesskit_windows_*` — Win32 adapter — 10 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 447 | 6350 | `accesskit_windows_queued_events_raise` | `windowsQueuedEventsRaise` | scalar tag pass | src/adapters/windows |
| 448 | 6361 | `accesskit_windows_adapter_new` | `windowsAdapterNew` | scalar tag pass | src/adapters/windows |
| 449 | 6371 | `accesskit_windows_adapter_free` | `windowsAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/windows |
| 450 | 6383 | `accesskit_windows_adapter_update_if_active` | `windowsAdapterUpdateIfActive` | scalar tag pass | src/adapters/windows |
| 451 | 6396 | `accesskit_windows_adapter_update_window_focus_state` | `windowsAdapterUpdateWindowFocusState` | scalar tag pass | src/adapters/windows |
| 452 | 6411 | `accesskit_windows_adapter_handle_wm_getobject` | `windowsAdapterHandleWmGetobject` | opt_lresult_toC | src/adapters/windows |
| 453 | 6427 | `accesskit_windows_adapter_debug` | `windowsAdapterDebug` | dupCString | src/adapters/windows |
| 454 | 6439 | `accesskit_windows_subclassing_adapter_new` | `windowsSubclassingAdapterNew` | scalar tag pass | src/adapters/windows |
| 455 | 6451 | `accesskit_windows_subclassing_adapter_free` | `windowsSubclassingAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/windows |
| 456 | 6464 | `accesskit_windows_subclassing_adapter_update_if_active` | `windowsSubclassingAdapterUpdateIfActive` | scalar tag pass | src/adapters/windows |


#### `accesskit_macos_*` — macOS adapter — 16 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 457 | 6063 | `accesskit_macos_queued_events_raise` | `macosQueuedEventsRaise` | scalar tag pass | src/adapters/macos |
| 458 | 6074 | `accesskit_macos_adapter_new` | `macosAdapterNew` | scalar tag pass | src/adapters/macos |
| 459 | 6083 | `accesskit_macos_adapter_free` | `macosAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/macos |
| 460 | 6095 | `accesskit_macos_adapter_update_if_active` | `macosAdapterUpdateIfActive` | scalar tag pass | src/adapters/macos |
| 461 | 6108 | `accesskit_macos_adapter_update_view_focus_state` | `macosAdapterUpdateViewFocusState` | scalar tag pass | src/adapters/macos |
| 462 | 6122 | `accesskit_macos_adapter_view_children` | `macosAdapterViewChildren` | scalar tag pass | src/adapters/macos |
| 463 | 6136 | `accesskit_macos_adapter_focus` | `macosAdapterFocus` | scalar tag pass | src/adapters/macos |
| 464 | 6150 | `accesskit_macos_adapter_hit_test` | `macosAdapterHitTest` | scalar tag pass | src/adapters/macos |
| 465 | 6164 | `accesskit_macos_adapter_debug` | `macosAdapterDebug` | dupCString | src/adapters/macos |
| 466 | 6175 | `accesskit_macos_subclassing_adapter_new` | `macosSubclassingAdapterNew` | scalar tag pass | src/adapters/macos |
| 467 | 6189 | `accesskit_macos_subclassing_adapter_for_window` | `macosSubclassingAdapterForWindow` | scalar tag pass | src/adapters/macos |
| 468 | 6201 | `accesskit_macos_subclassing_adapter_free` | `macosSubclassingAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/macos |
| 469 | 6214 | `accesskit_macos_subclassing_adapter_update_if_active` | `macosSubclassingAdapterUpdateIfActive` | scalar tag pass | src/adapters/macos |
| 470 | 6227 | `accesskit_macos_subclassing_adapter_update_view_focus_state` | `macosSubclassingAdapterUpdateViewFocusState` | scalar tag pass | src/adapters/macos |
| 471 | 6243 | `accesskit_macos_add_focus_forwarder_to_window_class` | `macosAddFocusForwarderToWindowClass` | — (none: scalar/void/pointer only) | src/adapters/macos |
| 472 | 6257 | `accesskit_macos_add_focus_forwarder_to_window_class_with_length` | `macosAddFocusForwarderToWindowClassWithLength` | — (none: scalar/void/pointer only) | src/adapters/macos |


#### `accesskit_ios_*` — iOS/tvOS/visionOS/watchOS adapter — 13 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 473 | 5901 | `accesskit_ios_queued_events_raise` | `iosQueuedEventsRaise` | scalar tag pass | src/adapters/ios |
| 474 | 5912 | `accesskit_ios_adapter_new` | `iosAdapterNew` | scalar tag pass | src/adapters/ios |
| 475 | 5925 | `accesskit_ios_adapter_free` | `iosAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/ios |
| 476 | 5937 | `accesskit_ios_adapter_update_if_active` | `iosAdapterUpdateIfActive` | scalar tag pass | src/adapters/ios |
| 477 | 5949 | `accesskit_ios_adapter_view_did_appear` | `iosAdapterViewDidAppear` | scalar tag pass | src/adapters/ios |
| 478 | 5955 | `accesskit_ios_adapter_is_accessibility_element` | `iosAdapterIsAccessibilityElement` | — (none: scalar/void/pointer only) | src/adapters/ios |
| 479 | 5968 | `accesskit_ios_adapter_accessibility_elements` | `iosAdapterAccessibilityElements` | scalar tag pass | src/adapters/ios |
| 480 | 5980 | `accesskit_ios_adapter_hit_test` | `iosAdapterHitTest` | scalar tag pass | src/adapters/ios |
| 481 | 5992 | `accesskit_ios_adapter_debug` | `iosAdapterDebug` | dupCString | src/adapters/ios |
| 482 | 6004 | `accesskit_ios_subclassing_adapter_new` | `iosSubclassingAdapterNew` | scalar tag pass | src/adapters/ios |
| 483 | 6019 | `accesskit_ios_subclassing_adapter_for_window` | `iosSubclassingAdapterForWindow` | scalar tag pass | src/adapters/ios |
| 484 | 6033 | `accesskit_ios_subclassing_adapter_free` | `iosSubclassingAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/ios |
| 485 | 6046 | `accesskit_ios_subclassing_adapter_update_if_active` | `iosSubclassingAdapterUpdateIfActive` | scalar tag pass | src/adapters/ios |


#### `accesskit_android_*` — JNI adapter — 13 exports

| # | hdr | C symbol = Zig `export fn` name | Zig implementation | `marshal.zig` conversion | Zig target |
|---:|---:|---|---|---|---|
| 486 | 5726 | `accesskit_android_platform_action_from_java` | `androidPlatformActionFromJava` | scalar tag pass | src/adapters/android |
| 487 | 5735 | `accesskit_android_platform_action_free` | `androidPlatformActionFree` | — (none: scalar/void/pointer only) | src/adapters/android |
| 488 | 5747 | `accesskit_android_queued_events_raise` | `androidQueuedEventsRaise` | — (none: scalar/void/pointer only) | src/adapters/android |
| 489 | 5759 | `accesskit_android_adapter_new` | `androidAdapterNew` | scalar tag pass | src/adapters/android |
| 490 | 5768 | `accesskit_android_adapter_free` | `androidAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/android |
| 491 | 5780 | `accesskit_android_adapter_update_if_active` | `androidAdapterUpdateIfActive` | scalar tag pass | src/adapters/android |
| 492 | 5793 | `accesskit_android_adapter_create_accessibility_node_info` | `androidAdapterCreateAccessibilityNodeInfo` | — (none: scalar/void/pointer only) | src/adapters/android |
| 493 | 5809 | `accesskit_android_adapter_find_focus` | `androidAdapterFindFocus` | — (none: scalar/void/pointer only) | src/adapters/android |
| 494 | 5826 | `accesskit_android_adapter_perform_action` | `androidAdapterPerformAction` | scalar tag pass | src/adapters/android |
| 495 | 5841 | `accesskit_android_adapter_on_hover_event` | `androidAdapterOnHoverEvent` | scalar tag pass | src/adapters/android |
| 496 | 5858 | `accesskit_android_injecting_adapter_new` | `androidInjectingAdapterNew` | scalar tag pass | src/adapters/android |
| 497 | 5870 | `accesskit_android_injecting_adapter_free` | `androidInjectingAdapterFree` | — (none: scalar/void/pointer only) | src/adapters/android |
| 498 | 5883 | `accesskit_android_injecting_adapter_update_if_active` | `androidInjectingAdapterUpdateIfActive` | — (none: scalar/void/pointer only) | src/adapters/android |

---

## 3. The boundary types

Every type that crosses. The C declaration is the header's, verbatim; the Zig
form is what the port must declare. Sizes and alignments were printed at run
time from a C11 program compiled against this header on x86-64 Linux with
`cc (SUSE Linux) 15.3.0`, and every one of them matches the table the header
publishes at lines 6524-6564. **Nothing in that table is wrong.** Three of its
*prose* column labels need care, noted in 3.2.

### 3.1 Scalars and the one data object

| C declaration | hdr | Zig form | Size / align | Which form |
|---|---:|---|---|---|
| `typedef uint64_t accesskit_node_id;` | 190 | `pub const NodeId = extern struct { … }` (`src/schema/ids.zig:41`) | 8 / 8 | ergonomic |
| `typedef void *accesskit_tree_update_factory_userdata;` | 201 | `?*anyopaque` | 8 / 8 | ergonomic |
| `typedef uint8_t accesskit_role;` (and 16 siblings) | 687 (the 17 aliases span 274-885) | `pub const Role = enum(u8)` (`src/schema/role.zig`) | 1 / 1 | ergonomic |
| `extern const struct accesskit_tree_id ACCESSKIT_TREE_ID_ROOT;` | 1791 | `pub const tree_id_root: TreeId` (`src/schema/ids.zig`, re-exported as `schema.tree_id_root`) | 16 / 1 | ergonomic |

The 17 aliases are `enum(u8)` in Zig and the C compiler agrees they are one
byte. **A bare `enum accesskit_role` is 4 bytes on this host** — the header says
so at lines 475-476 — so the C side must spell the typedef, never the tag.

### 3.2 The 40 laid-out structs

`extern` form means the port declares the type as `extern struct` and the
conversion in both directions is the identity. `ergonomic` means the port's own
type already crosses and only a conversion is needed. Fourteen are already
`extern struct` in `src/schema/`.

| C type | hdr | Zig form | Size | Align | Payload offset | Which form |
|---|---:|---|---:|---:|---:|---|
| `accesskit_node_ids` | 1059 | `extern struct` | 16 | 8 | 8 (`values`) | extern |
| `accesskit_opt_node_id` | 1082 | `extern struct` | 16 | 8 | 8 (`value`) | extern |
| `accesskit_tree_id` | 1091 | `TreeId` | 16 | 1 | — | **ergonomic** |
| `accesskit_opt_tree_id` | 1105 | `extern struct` | 17 | 1 | 1 | extern |
| `accesskit_opt_double` | 1120 | `extern struct` | 16 | 8 | 8 | extern |
| `accesskit_opt_float` | 1135 | `extern struct` | 8 | 4 | 4 | extern |
| `accesskit_opt_index` | 1150 | `extern struct` | 16 | 8 | 8 | extern |
| `accesskit_color` | 1162 | `Color` | 4 | 1 | — | **ergonomic** |
| `accesskit_opt_color` | 1179 | `extern struct` | 5 | 1 | 1 | extern |
| `accesskit_text_decoration` | 1187 | `TextDecoration` | 5 | 1 | — | **ergonomic** |
| `accesskit_opt_text_decoration` | 1209 | `extern struct` | 6 | 1 | 1 | extern |
| `accesskit_lengths` | 1217 | `extern struct` | 16 | 8 | 8 (`values`) | extern |
| `accesskit_opt_coords` | 1242 | `extern struct` | 24 | 8 | 16 (`values`) | extern |
| `accesskit_opt_bool` | 1258 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_invalid` | 1273 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_toggled` | 1288 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_live` | 1303 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_text_direction` | 1318 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_orientation` | 1333 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_sort_direction` | 1348 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_aria_current` | 1363 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_auto_complete` | 1378 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_has_popup` | 1393 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_list_style` | 1408 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_text_align` | 1423 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_opt_vertical_offset` | 1438 | `extern struct` | 2 | 1 | 1 | extern |
| `accesskit_affine` | 1453 | `Affine` | 48 | 8 | — | **ergonomic** |
| `accesskit_rect` | 1464 | `Rect` | 32 | 8 | — | **ergonomic** |
| `accesskit_opt_rect` | 1481 | `extern struct` | 40 | 8 | 8 | extern |
| `accesskit_text_position` | 1490 | `TextPosition` | 16 | 8 | — | **ergonomic** |
| `accesskit_text_selection` | 1502 | `TextSelection` | 32 | 8 | 16 (`focus`) | **ergonomic** |
| `accesskit_opt_text_selection` | 1517 | `extern struct` | 40 | 8 | 8 | extern |
| `accesskit_custom_actions` | 1525 | `extern struct` | 16 | 8 | 8 (`values`) | extern |
| `accesskit_point` | 1546 | `Point` | 16 | 8 | — | **ergonomic** |
| `accesskit_vec2` | 1558 | `Vec2` | 16 | 8 | — | **ergonomic** |
| `accesskit_size` | 1570 | `Size` | 16 | 8 | — | **ergonomic** |
| `accesskit_opt_lresult` | 1586 | `extern struct` | 16 | 8 | 8 | extern, `_WIN32` only |
| `accesskit_action_data` | 1634 | `CActionData` | 40 | 8 | 8 (`payload`) | **already written** |
| `accesskit_opt_action_data` | 1674 | `COptActionData` | 48 | 8 | 8 (`value`) | **already written** |
| `accesskit_action_request` | 1688 | `CActionRequest` | 80 | 8 | 32 (`data`) | **already written** |

Three payload-column labels in the header's prose need correcting, because an
implementer reading that column literally would look for a field that does not
exist. They are not size errors — every size and alignment is right:

- **`accesskit_text_selection`, listed as payload 16.** The type has no `value`
  field. Offset 16 is `focus`; `anchor` is at 0. The prose rule at lines 6520-6522 says
  the column is "`value` on an optional, `values` on a list, and `-` where the
  type has no payload field", and by that rule this row should read `-`.
- **`accesskit_action_request`, listed as payload 1.** The type has no payload
  field at offset 1 either. `action` is 1 byte at offset 0, and
  `target_tree` — a `uint8_t[16]`, alignment 1 — therefore lands at offset 1,
  which is why the column reads 1. The actual payload field `data` is at
  **32**. Measured and confirmed.
- **`accesskit_opt_coords`, listed as payload 16.** This one is correct as
  written: `values` is at 16. It is listed with `-` nowhere and needs no note;
  it is called out only because it is a *list-shaped* optional — it carries
  `length` and a `const float *`, not a single value — so it borrows like row 2
  of the ownership table rather than copying like the other optionals.

### 3.3 The two payload unions

`docs/31-c-abi-design.md` section 4.0 owns the shape. Confirmed from the header,
the union lives inside `accesskit_action_data` at lines 1634-1662 and has eight
members, all at offset 0:

```c
typedef struct accesskit_action_data {
  accesskit_action_data_Tag tag;   /* 4 bytes, offset 0 */
  union {
    struct { int32_t custom_action; };
    struct { char *value; };
    struct { double numeric_value; };
    struct { accesskit_scroll_unit scroll_unit; };
    struct { accesskit_scroll_hint scroll_hint; };
    struct { struct accesskit_point scroll_to_point; };
    struct { struct accesskit_point set_scroll_offset; };
    struct { struct accesskit_text_selection set_text_selection; };
  };
} accesskit_action_data;
```

The Zig side already has this. `src/schema/update.zig:313` declares
`ActionDataPayload = extern union` with those eight members, and
`src/schema/update.zig:340-373` declares `CActionData`, `COptActionData` and
`CActionRequest` as `extern struct`. The measured numbers agree with the
`comptime` assertions at `src/schema/update.zig:542`: tag 4/4, payload 32/8,
action data 40/8, opt 48/8, request 80/8. **This is the one part of the boundary
that is already implemented and already checked.**

### 3.4 The aggregate types, by value and by pointer

Which types the calling-convention question actually applies to, from the counts
in section 1.2.

**Returned by value — 103 declarations, 32 types.** `opt_double` 11, `rect` 11,
`opt_index` 9, `affine` **9**, `node_ids` 8, `opt_node_id` 7, `vec2` 7,
`point` 5, `size` 5, `opt_color` 3, `opt_text_decoration` 3, `opt_float` 2,
`lengths` 2, `opt_coords` 2, `opt_bool` 2, and one each of `opt_tree_id`,
`opt_invalid`, `opt_toggled`, `opt_live`, `opt_text_direction`,
`opt_orientation`, `opt_sort_direction`, `opt_aria_current`,
`opt_auto_complete`, `opt_has_popup`, `opt_list_style`, `opt_text_align`,
`opt_vertical_offset`, `opt_rect`, `opt_text_selection`, `tree_id`,
`opt_lresult`.

**The two "marginal cases" this section used to name are resolved, and neither
survives as stated.**

- **`custom_actions` is not returned by value, and is not on this list at all.**
  `accesskit_node_custom_actions` at `include/zaccesskit.h:5094` is declared
  `struct accesskit_custom_actions *accesskit_node_custom_actions(const struct
  accesskit_node *node)` — a pointer. The type appears in exactly two positions
  in the whole header, the `accesskit_custom_actions_free` parameter at line
  5083 and that return, and in neither is it a value. It was in the old list
  because the old classifier counted a declaration whose return type *named* a
  laid-out struct, ignoring the `*`. Deleted from the by-value set.
- **`tree_id` is counted, correctly, and was never marginal.**
  `accesskit_tree_update_get_tree_id` at `include/zaccesskit.h:5357` is declared
  `struct accesskit_tree_id accesskit_tree_update_get_tree_id(struct
  accesskit_tree_update *update)` — a value — and it is inside the 103 above.
  Two further declarations pass `accesskit_tree_id` by value, at lines 2819
  (`accesskit_node_set_tree_id`) and 5364 (`accesskit_tree_update_set_tree_id`),
  and both are inside the 42 below. Kept, relabelled: an ordinary member of the
  by-value set on both sides, not an edge case.

The one return-side marginal case the old classifier created and this section
never named is `accesskit_node_transform` at line 4933, which returns
`const struct accesskit_affine *`. Counting it is what turned the 103 into the
105; `affine` is 9, not 10.

**Passed by value — 58 parameters across 42 declarations, 9 types.** `vec2` 12,
`point` 12, `rect` 10, `size` 8, `affine` 7, `color` 3, `text_decoration` 3,
`tree_id` 2, `text_selection` 1.

**Passed by pointer — 449 parameters across 444 declarations, 22 types**, and
these are *not* part of the calling-convention question section 6.2 asks.
`accesskit_node` 358, `accesskit_rect` 15, `accesskit_tree_info` 11,
`accesskit_custom_action` 8, `accesskit_tree_update` 8, `accesskit_ios_adapter`
7, `accesskit_macos_adapter` 7, `accesskit_android_adapter` 6,
`accesskit_unix_adapter` 5, `accesskit_windows_adapter` 5,
`accesskit_macos_subclassing_adapter` 3, `accesskit_affine` 2,
`accesskit_android_platform_action` 2, `accesskit_android_injecting_adapter` 2,
`accesskit_ios_subclassing_adapter` 2, `accesskit_windows_subclassing_adapter`
2, and one each of `accesskit_custom_actions`, `accesskit_action_request`,
`accesskit_android_queued_events`, `accesskit_ios_queued_events`,
`accesskit_macos_queued_events`, `accesskit_windows_queued_events`.

**Where 57, 77 and 11 came from, so the error cannot recur.** They are this
document's own by-value figures with the by-pointer figures of four types folded
in, and the arithmetic closes exactly:

| Old figure | Measured decomposition |
|---|---|
| 77 parameters | 58 by value **+ 19 by pointer** of `rect` 15, `affine` 2, `custom_actions` 1, `action_request` 1 |
| 57 declarations | 42 by value **+ 15** that take one of those 19 by pointer and take nothing by value |
| 11 types | 9 by-value types **+ `custom_actions` + `action_request`**; `rect` and `affine` were already in the 9 |
| 31 both return and take | 28 by value on both sides **+ 3** that take by pointer and return by value: `accesskit_rect_abs` (5600), `_origin` (5585), `_size` (5592) |
| 105 returning | 103 by value **+ `accesskit_node_transform` (4933) + `accesskit_node_custom_actions` (5094)**, both pointers |

The 19 folded-in parameters are all in the by-pointer census above. Fifteen of
them sit in the `accesskit_rect_*` family — `accesskit_rect_width` (5542),
`_height` (5549), `_min_x` (5556), `_max_x` (5563), `_min_y` (5570),
`_max_y` (5577), `_origin` (5585), `_size` (5592), `_abs` (5600), `_area`
(5607), `_is_empty` (5614), `_contains` (5621), `_union` (5629), `_union_pt`
(5638), `_intersect` (5648) — plus `accesskit_affine_is_finite` (5454),
`accesskit_affine_is_nan` (5461), `accesskit_custom_actions_free` (5083) and
`accesskit_action_request_free` (5387). Four of the nineteen —
`accesskit_rect_contains`, `_union`, `_union_pt` and `_intersect` — are in the
42 as well, because they also take a struct by value; that is why 19 folded
parameters add only 15 declarations.

### 3.5 The 18 opaque handles

`typedef struct NAME NAME;` — the C caller holds the pointer, the library owns
the object.

| C type | hdr | Zig side |
|---|---:|---|
| `accesskit_node` | 997 | `*Node` (`src/schema/node.zig:98`) |
| `accesskit_tree_info` | 1007 | `*TreeInfo` (`src/schema/update.zig:97`) |
| `accesskit_tree_update` | 1016 | `*TreeUpdate` (`src/schema/update.zig:148`) |
| `accesskit_custom_action` | 933 | `*CustomAction` (`src/schema/values.zig`) |
| `accesskit_unix_adapter` | 1025 | `src/adapters/unix/` — **not started** |
| `accesskit_windows_adapter` | 1033 | `src/adapters/windows/` — **not started** |
| `accesskit_windows_queued_events` | 1041 | not started |
| `accesskit_windows_subclassing_adapter` | 1050 | not started |
| `accesskit_macos_adapter` | 968 | `src/adapters/macos/` — not started |
| `accesskit_macos_queued_events` | 976 | not started |
| `accesskit_macos_subclassing_adapter` | 984 | not started |
| `accesskit_ios_adapter` | 941 | `src/adapters/ios/` — not started |
| `accesskit_ios_queued_events` | 950 | not started |
| `accesskit_ios_subclassing_adapter` | 959 | not started |
| `accesskit_android_adapter` | 896 | `src/adapters/android/` — not started |
| `accesskit_android_queued_events` | 922 | not started |
| `accesskit_android_injecting_adapter` | 904 | not started |
| `accesskit_android_platform_action` | 913 | not started |

**Five of the 18 are implementable today** and 13 are blocked on adapters that do
not exist. A C ABI that exports all 498 symbols cannot link on Linux without
the five platform families, so the first milestone must either ship the Linux
family or export only the 446 the host declares.

### 3.6 The four function-pointer typedefs

| C declaration | hdr | Zig form |
|---|---:|---|
| `typedef struct accesskit_tree_update *(*accesskit_tree_update_factory)(accesskit_tree_update_factory_userdata);` | 1720 | `*const fn (?*anyopaque) callconv(.c) ?*CActionTreeUpdate` |
| `typedef struct accesskit_tree_update *(*accesskit_activation_handler_callback)(void *userdata);` | 1733 | `*const fn (?*anyopaque) callconv(.c) ?*CActionTreeUpdate` |
| `typedef void (*accesskit_action_handler_callback)(struct accesskit_action_request *request, void *userdata);` | 1750 | `*const fn (*CActionRequest, ?*anyopaque) callconv(.c) void` |
| `typedef void (*accesskit_deactivation_handler_callback)(void *userdata);` | 1761 | `*const fn (?*anyopaque) callconv(.c) void` |

Note the first two are **textually identical** and the header keeps both names
because upstream does. One Zig function can be given both symbols; the
`@export` route in section 2 is the mechanism, and it is why mechanism 1 is
preferred everywhere else.

---

## 4. The ownership table, verified against the header

`docs/31-c-abi-design.md` section 3 has a 19-row table at lines 119-152. It was
checked against `include/zaccesskit.h` rather than copied. **Eighteen of the
nineteen rows hold. One row is wrong: row 16, the `*_free` count.** Row 1 was
previously marked wrong by this document on a count that was itself wrong; it is
restored below.

| # | Category | Verdict |
|---:|---|---|
| 1 | Aggregates returned by value; "all 103" | **Holds as written; no correction to the row is needed.** The header has **103** declarations returning a struct by value, across 32 types. This document's "105" was its own classifier counting `accesskit_node_transform` (4933) and `accesskit_node_custom_actions` (5094), which return pointers; `docs/31` section 9.3 adopted the same two. `accesskit_last_error` is not among the 103 — it returns the C enum `accesskit_error`. The row's *rule* — borrows nothing, nothing to release — is unaffected either way |
| 2 | 8 node-id-list, 2 byte-slice, 2 float-slice getters whose `values` borrows | **Holds.** `node_ids` returned 8×, `lengths` 2×, `opt_coords` 2×; all three carry a borrowing `values`, and none has a free function |
| 3 | Array or `char *` a setter receives; the setter copies | Holds |
| 4 | `char *` from a string getter → `accesskit_string_free` | **Holds.** Free function at line 2837; 31 `char *` getters |
| 5 | `accesskit_custom_action_new` → `accesskit_custom_action_free` | **Holds.** Constructor at 5012, free at 5021 |
| 6 | `accesskit_node_push_custom_action` transfers to the node | **Holds.** Push at 5115 |
| 7 | `accesskit_node_set_custom_actions` deep-copies; free each action and the array | **Holds.** Setter at 5104, `accesskit_custom_actions_free` at 5083 |
| 8 | `accesskit_node_new` and the two tree-update constructors → `*_free` | **Holds.** 5134, 5286, 5298 |
| 9 | `accesskit_tree_update_push_node` transfers to the update | **Holds.** 5318 |
| 10 | `accesskit_tree_update_set_tree_info` **consumes** its argument | **Holds.** 5331 — and the header says so at line 35 in the change notice |
| 11 | A tree info already on an update | Holds |
| 12 | The update a factory returns belongs to the library | Holds |
| 13 | The update an activation handler returns, `null` meaning "no tree" | Holds |
| 14 | `accesskit_action_request` → `accesskit_action_request_free` before returning | **Holds.** Free at 5387; the header states it at the callback typedef, line 1740 |
| 15 | The `char *` at `request->data.value.value` goes with the request | **Holds.** Implemented as `cActionRequestDeinit`, `src/schema/update.zig:514` |
| 16 | "Every `*_free`: **2 node, 2 tree-info**, 1 tree-update, 2 custom-action, 1 action-request, 1 string, 10 platform" | **CONTRADICTED. See below.** |
| 17 | Four `*_queued_events` handles, released by `*_queued_events_raise` | **Holds.** Four types (922, 950, 976, 1041) and four raisers (5747, 5901, 6063, 6350) |
| 18 | The `void *` from **5** object-returning platform accessors | **Holds.** Exactly 5: `ios_adapter_accessibility_elements`, `ios_adapter_hit_test`, `macos_adapter_view_children`, `macos_adapter_focus`, `macos_adapter_hit_test` |
| 19 | The macOS `class_name` stays with the caller | Holds |

### 4.1 Row 16 is wrong, and it is wrong against upstream too

The header declares **17** `*_free` functions, not the 19 the row enumerates:

| Category | Row 16 says | Header has |
|---|---:|---:|
| node | 2 | **1** — `accesskit_node_free` (5143) |
| tree-info | 2 | **1** — `accesskit_tree_info_free` (5172) |
| tree-update | 1 | 1 (5309) |
| custom-action | 2 | 2 (5021, 5083) |
| action-request | 1 | 1 (5387) |
| string | 1 | 1 (2837) |
| platform | 10 | 10 |
| **Total** | **19** | **17** |

Upstream's `include/accesskit.h` at the pinned revision `8b6ed37` declares the
**same 17**, with the same names. So the extra node and tree-info rows are not a
divergence the port introduced and not a name the port renamed; they are two rows
with no declaration behind them. An implementer following row 16 literally will
write a second `accesskit_node_free` and a second `accesskit_tree_info_free`, and
the second pair is a duplicate symbol at link time.

**What a second release does**, for each category, taken from the header and
from the semantics `src/schema/update.zig:478-539` already implements:

| Handle | Released by | A second call |
|---|---|---|
| `char *` from a string getter | `accesskit_string_free` | Double free |
| `accesskit_custom_action` | `accesskit_custom_action_free` | Double free |
| `accesskit_custom_actions` (pointer form) | `accesskit_custom_actions_free` | Double free |
| `accesskit_node` | `accesskit_node_free` | Double free |
| `accesskit_tree_info` | `accesskit_tree_info_free` | Double free |
| `accesskit_tree_update` | `accesskit_tree_update_free` | Double free, and every node still held goes with it |
| `accesskit_action_request` | `accesskit_action_request_free` | Double free |
| Any of the 10 platform adapters | its `*_free` | Double free |
| Any `*_queued_events` | its `*_queued_events_raise` | Use after free |

**A `null` argument is not handled by any of these.** Row 16 says "`null`
terminates the process", which matches `docs/31`'s reading of upstream's aborting
build. The port must reproduce that, not soften it: a null check would be a
behaviour change against a contract both headers already state.

---

---

## 5. The build wiring

`build.zig` is 141 lines and publishes exactly one module. It contains **no**
`addLibrary`, no `b.option`, no `installArtifact`, no `installHeader` and no
`installFile`. Everything in this section is new. Every call below carries the
line in the installed toolchain — Zig **0.16.0** at
`lib/std/Build.zig` and `lib/std/Build/Step/Compile.zig` — that defines its
signature.

### 5.1 The shared library

There is no `addSharedLibrary` in Zig 0.16.0. A shared library is
`addLibrary` with `linkage = .shared`; `std.builtin.LinkMode` is at
`lib/std/builtin.zig:870` and `.shared` is its dynamic member.

```zig
// lib/std/Build.zig:842   pub fn addLibrary(b: *Build, options: LibraryOptions) *Step.Compile
// lib/std/Build.zig:823   pub const LibraryOptions = struct {
//                             linkage: std.builtin.LinkMode = .static,
//                             name: []const u8,
//                             root_module: *Module,
//                             version: ?std.SemanticVersion = null,
//                             ...
const capi_mod = b.createModule(.{
    .root_source_file = b.path("src/capi/root.zig"),
    .target = target,
    .optimize = .ReleaseSafe,
    .link_libc = true,          // lib/std/Build/Module.zig:234
    .imports = &.{
        .{ .name = "zaccesskit", .module = mod },
        .{ .name = "zio",        .module = zio.module("zio") },
        .{ .name = "build_options", .module = options.createModule() },
    },
});
const capi = b.addLibrary(.{
    .name = "zaccesskit",
    .linkage = .shared,
    .root_module = capi_mod,
    .version = .{ .major = 0, .minor = 0, .patch = 0 },  // mirrors build.zig.zon
});
b.installArtifact(capi);   // lib/std/Build.zig:1660
```

`lib/std/Build/Module.zig:216` is `CreateOptions`; `link_libc` is at line 234.

### 5.2 The soname, and why there is no soname option

**`std.Build` in Zig 0.16.0 has no `soname` field, option or function.** A search
for `soname` across the whole of `lib/std/Build/` returns nothing. The SONAME
is not something the build sets; it follows from the name and the version.

What `version` does is set at `lib/std/Build/Step/Compile.zig:489-504`:

```zig
} else {
    compile.major_only_filename = owner.fmt("lib{s}.so.{d}", .{ compile.name, version.major });
    compile.name_only_filename  = owner.fmt("lib{s}.so",      .{ compile.name });
    compile.out_lib_filename    = compile.out_filename;
}
```

and `installArtifact` lays down the two symlinks at
`lib/std/Build/Step/Compile.zig:1825-1833`, gated on
`std.Build.wantSharedLibSymLinks` (`lib/std/Build.zig:2717`). The resulting
`zig-out/lib` is:

```
libzaccesskit.so.0.1.2 -> libzaccesskit.so.0 -> libzaccesskit.so
```

**The `DT_SONAME` recorded in the ELF is `libzaccesskit.so`** — the unversioned
name — which was measured by building a versioned shared library from this
toolchain and reading `readelf -d`. That is the correct ELF convention and it is
what a C consumer's runtime linker will resolve against, so
`LibraryOptions.name` must be exactly `zaccesskit` and the header must be
`zaccesskit.h`, matching record D in `docs/31-c-abi-design.md` section 2.4. The
`version` field decides the symlink names and nothing a C consumer observes; it
still has to be set, because without it `Compile.zig:505-515` skips the
`major_only_filename` entirely and no `.so.0` link exists.

On Windows, `Compile.zig:500` emits `{name}.lib` and the import library comes
from `getEmittedImplib` (`Compile.zig:862`), installed by
`InstallArtifact.zig:125`. On Darwin, `Compile.zig:493` emits
`lib{name}.{major}.dylib` plus a `lib{name}.dylib` symlink.

### 5.3 The header installation

There is no generated header. The checked-in `include/zaccesskit.h` is the
header, and it installs through `installHeader`:

```zig
// lib/std/Build/Step/Compile.zig:523
//   pub fn installHeader(cs: *Compile, source: LazyPath, dest_rel_path: []const u8) void
capi.installHeader(b.path("include/zaccesskit.h"), "zaccesskit.h");
```

`installHeader` appends to `cs.installed_headers` and calls
`addHeaderInstallationToIncludeTree` (`Compile.zig:570`), so a Zig module that
links this artefact automatically gets `include/` on its search path.
`installHeadersDirectory` is at `Compile.zig:537` and is the wrong call for one
file.

### 5.4 There is no generated header, and this is measured three ways

| Probe | Result |
|---|---|
| `zig build-obj -femit-h -c probe.c` | `error: -femit-h is currently broken, see https://github.com/ziglang/zig/issues/9698` |
| `zig build-lib -femit-h -c probe.c` | same error |
| `zig cc -femit-h=probe.h -c probe.c` | `error: Unknown Clang option: '-femit-h=probe.h'` — exit 1, no file produced |

And the standard library agrees, in the place it would have to work:

```
lib/std/Build/Step/InstallArtifact.zig:123    // https://github.com/ziglang/zig/issues/9698
lib/std/Build/Step/InstallArtifact.zig:124    //if (install_artifact.h_dir != null) install_artifact.emitted_h = artifact.getEmittedH();
```

The call is commented out with the issue URL directly above it.
`Step.Compile.getEmittedH` still exists at `Compile.zig:869`, but nothing ever
populates `generated_h`, and `InstallArtifact.zig:168-173` guards its install on
`if (install_artifact.emitted_h) |emitted_h|`. **So `h_dir`
(`InstallArtifact.zig:24` and `:43`) installs nothing for a generated header and
must be left unset.** The only header that installs is the one registered by
`installHeader`, at `InstallArtifact.zig:175-179`. There is no workaround to
search for; ship the checked-in header.

### 5.5 `zig translate-c` works here, and the parity sweep can run

The premise that `translate-c` is unverified in this environment is **no longer
true**. It was run on this host against this header:

```
zig 0.16.0 translate-c -Iinclude include/zaccesskit.h -lc > zaccesskit.zig
```

Exit 0. **3408 lines of Zig, zero diagnostics** — the two lines on stderr are the
`anyzig` shim's own progress output, not the translator. The sweep was then run
against the census:

| Check | Result |
|---|---:|
| `pub extern fn` declarations emitted | 446 |
| Of the 498 header declarations, those the translator carries | **446** |
| Names in the translator that the header does not declare | **0** |
| Names in the header the translator omits | **52 — exactly the platform-gated set** |

So the translator is faithful and complete on everything this host declares, and
it omits precisely the 52 declarations behind `_WIN32`, `__ANDROID__`,
`ACCESSKIT_MACOS` and the Apple-mobile family, because none of those macros is
defined when translating on Linux. **The parity sweep runs, and its pass
criterion is 446 of 446 on Linux** — the same gate the header applies in
section 1.1. It cannot cover the other 52 here; see section 7.

Two consequences for the implementer:

1. `zig translate-c` is a **generating oracle for the `extern struct`
   declarations**, not for the exports. It emits `struct_accesskit_node_ids`
   style tags rather than the port's names, so `capi/header_check.zig` cannot use
   it as a reflection source; it can use it as a diff to prove no layout moved.
2. It gives no opinion on aggregate lowering. Every function it emits is a
   declaration, and none of that settles the calling convention. See 6.2.

### 5.6 The options each piece needs

| Call | Needs | Why |
|---|---|---|
| `b.addLibrary` (`:842`) | `.version` non-null | Otherwise no `.so.0` symlink; `Compile.zig:505` |
| `Module.CreateOptions.link_libc` (`Module.zig:234`) | `true` | `accesskit_set_allocator`'s default is the C allocator, and the header's `extern "C"` block is meaningless without libc |
| `b.addOptions` (`Build.zig:766`) + `Options.addOption` (`Options.zig:39`) | the existing `version` and `minimum_zig_version` | The shared library's version symbol and the header's version macro both read them; `build.zig:57-59` already builds this module |
| `capi.installHeader` (`Compile.zig:523`) | nothing | A checked-in path and a destination name |
| `b.step` (`Build.zig:1355`) | a new `capi-check` step | Carries the `translate-c` diff and the C fixture, neither of which is a compile |
| `b.addSystemCommand` (`Build.zig:927`) | — | Runs `translate-c` and `cc -std=c11 …` as build steps |

A C conformance fixture is **not** a Zig test. `b.addTest` (`Build.zig:881`)
compiles Zig; it cannot compile C. The fixture belongs in
`b.addSystemCommand`, and the header's own conformance note at lines 6578-6593
names the three checks and says checks 2 and 3 "cannot run yet: this repository
has no C artefact". This wiring is what makes them runnable.

---

## 6. The two known blockers, and their status

### 6.1 The `O_NONBLOCK` defect

**Status: unfixed, and unfixable in this repository as it stands.**

The defect is recorded in `docs/26-goose-live-bus-probe.md` sections 7.1 and 7.4
and in `docs/30-port-design.md` sections 7.2 and 7.3. The defect is that goose
folds `EAGAIN` into its normal result rather than surfacing it, so a caller
cannot distinguish "would block" from "not ready", and the AT-SPI socket must
therefore be driven with `O_NONBLOCK` set and the readiness handled by the port
instead.

**The blocker is a dependency, not a code path.** `build.zig.zon` declares
exactly one dependency, `zio` at `2662fdc4…`. **goose is not a dependency of this
package.** There is therefore no goose source in the build graph for a patch to
apply to, and `docs/30` section 7.3 record R5 names the build-time patch carrier
as the thing that has to exist first.

**What a build step would have to do, and what it would prove:**

1. Add goose as a dependency in `build.zig.zon`.
2. Obtain the four-line patch from `docs/26-goose-live-bus-probe.md` section 7.4.
3. Carry it through `docs/30` section 7.3's record-R5 mechanism — a build step
   that copies the goose tree into the cache and applies the patch before
   `addLibrary` consumes it. `b.addSystemCommand` (`Build.zig:927`) plus
   `Step.Run.addFileArg` is the shape; nothing in `std.Build` patches sources.
4. **What it would prove:** that a patched goose returns a distinguishable
   `EAGAIN`, and only that. It would prove nothing about AT-SPI, nothing about
   the C ABI, and nothing about any other platform.

**What it cannot prove:** anything about this boundary. No C ABI export touches a
socket. The two subjects are independent, and a green `O_NONBLOCK` fix must not
be read as movement on `src/capi/`.

**Dependency to report:** the goose fork or patch at
`/tmp/scratch/goose` tag `v3.3.0`, specifically the four lines in
`docs/26-goose-live-bus-probe.md` section 7.4, and a `build.zig.zon` entry for it.

### 6.2 The aggregate-passing convention

**Status: undecided. The header's layout is verified; the *lowering* is not.**

The risk, stated in `docs/31-c-abi-design.md` section 2.5: an `extern struct` has
the right in-memory layout, but a caller compiled with a different **aggregate
classification** corrupts its own stack rather than receiving a wrong number.
`accesskit_affine` is 48 bytes, past the x86-64 System V return budget, so it
travels through a hidden pointer and every named argument shifts.

**Which declarations this decision actually covers, and which it does not.** A
struct passed by value is classified: its layout is contract. A struct passed by
pointer is not classified at all — the callee dereferences an address, and only
the address crosses. Section 1.2 measures the two sets apart: **42
declarations, 58 parameters, 9 types** cross by value, against **444
declarations, 449 parameters, 22 types** by pointer, with **16 declarations in
both sets**. The consequence for this decision is concrete, and `rect` is where
it bites. `rect` is the most frequent by-value parameter in the header at **10
parameters across 9 declarations** — not the 25 the old figure implied — while
**15 parameters of it cross by pointer**, in 15 declarations. Of the 21
`accesskit_rect_*` exports:

- **9 take a struct by value**: `accesskit_rect_from_points` (5512),
  `_from_origin_size` (5520), `_with_origin` (5528), `_with_size` (5534) and
  `_translate` (5655) by value only; `_contains` (5621), `_union` (5629),
  `_union_pt` (5638) and `_intersect` (5648) in both directions.
- **11 take a `rect` by pointer and nothing by value**: `accesskit_rect_width`
  (5542), `_height` (5549), `_min_x` (5556), `_max_x` (5563), `_min_y` (5570),
  `_max_y` (5577), `_origin` (5585), `_size` (5592), `_abs` (5600), `_area`
  (5607) and `_is_empty` (5614). A change to `CRect`'s layout cannot corrupt a
  call to any of these through the calling convention; the address does not
  change.
- **1 takes no struct at all**: `accesskit_rect_new` (5506).

An implementer who reads the old figure of 57 by-value declarations will treat
those eleven as convention-sensitive when they are not, and will go looking for
a lowering hazard in `accesskit_rect_width` that the header does not have.

**What is established.** The header's 40 layouts are correct — verified by
compilation and run-time measurement, section 3.2. Fourteen types are already
`extern struct` in `src/schema/`, and `src/schema/update.zig` proves an
`extern union` payload works, with `comptime` assertions at line 542 pinning all
of it.

**What is not established.** How Zig 0.16.0 lowers a 48-byte aggregate return.
`docs/31` section 2.5 records this explicitly: *"The installed toolchain ships
`lib/` and the `zig` binary but not the compiler's `src/`, so the ABI classifier
and the per-architecture generators cannot be cited from this checkout."* I did
not find an ABI classifier in `lib/std` either. `zig translate-c` (section 5.5)
produces declarations only and says nothing about lowering.

**What a build step would have to do:**

1. Build the shared library for `x86_64-linux` (`Compile.zig:489-504` picks the
   ELF branch; nothing special is needed).
2. Compile a C fixture that calls **one function of each shape**, which by
   section 1.2 means at minimum: `accesskit_affine_inverse` (48-byte in, 48-byte
   out), `accesskit_affine_mul` (two 48-byte in, one out), `accesskit_rect_area`
   (32 out), `accesskit_rect_translate` (32 in), `accesskit_point_add_vec2` (16
   in), `accesskit_opt_double` returns, and a `char *` return.
3. Link it against the artefact. `b.addSystemCommand` (`Build.zig:927`) with the
   artefact as a `addFileArg`; `b.addRunArtifact` (`Build.zig:936`) will not do
   it, because it runs an artefact, not a foreign object.
4. **What it would prove:** that the classifier agrees for `x86_64-linux` in the
   mode built. That is real, and it is one row of one column.

**What it cannot prove:** anything about `aarch64-linux`, `powerpc64-linux`,
Windows, macOS or Android, and nothing about a different optimize mode. The
`cross-test.profile.sh` matrix is `x86_64-linux`, `aarch64-linux` and
`powerpc64-linux`; the last two run under `qemu_user`, which is the only way
this reaches them.

**The fallback is named and not yet needed.** `docs/31` section 2.5 names a
hand-written C shim owning the nine affine entry points, and record D's
counterchoice names a version script for a prefix change. Neither is in scope
until check 5 in `docs/31` section 6 has run. **Record the decision in
`docs/31`, not here** — this document does not own it.

---

## 7. What cannot be verified here

This host is x86-64 Linux with `cc (SUSE Linux) 15.3.0` 15.3.0 and
`clang` 19.1.7. Everything below was exercised here unless stated.

### 7.1 What was actually run

| Check | Where | Result |
|---|---|---|
| Header parses as C11, `-Wall -Wextra -Wpedantic` | this host | **Clean, zero diagnostics** — both gcc and clang |
| Header parses as C99, same flags | this host | **10 diagnostics, not clean.** Anonymous structs are a C11 extension; gcc emits `-Wpedantic` at 1636-1661, clang `-Wc11-extensions` at the same lines |
| Header parses as C++17, same flags | this host | **8 diagnostics with g++, 16 with clang++.** Anonymous structs are a GNU extension, `-Wgnu-anonymous-struct` |
| All 37 sizes and alignments | this host | **Match the header's table exactly** |
| All 28 payload offsets | this host | **Match** |
| 446 exported names take their address | this host | **Compiles clean** |
| `zig translate-c` | this host | **Works, 3408 lines, 446 of 446** |
| `zig build-obj -femit-h` | this host | **Broken, issue 9698** |

**The C99 and C++17 claims do not hold as stated.** The header is clean as C11
and **is not** clean as C99 or C++17 with `-Wpedantic`, because
`accesskit_action_data` at lines 1634-1662 uses the anonymous struct extension
eight times. This is a real, reproducible finding and it belongs to the header's
owner. It does not block the port — GCC and Clang both accept the extension and
emit only a warning, and the C11 path is the one the library targets — but the
conformance claim in the header's preamble has to be corrected or the anonymous
structs have to go.

### 7.2 Rows that need another host

| Row | What cannot be checked here | Host needed |
|---|---|---|
| `ACCESSKIT_MACOS` — 16 exports | Cannot execute. `translate-c` will not parse `TargetConditionals.h` (`docs/16` §9.5) | macOS with the Xcode SDK |
| `__ANDROID__` — 13 exports | `jni.h` parses (`docs/16` §9.9) but no JNI runtime, no `JNIEnv`, no device | Android device or emulator, NDK toolchain |
| `ACCESSKIT_IOS`/`TVOS`/`VISIONOS`/`WATCHOS` — 13 exports | Objective-C headers do not translate-c | macOS with the iOS SDK |
| `_WIN32` — 10 exports | `windows.h` unavailable; `accesskit_opt_lresult` needs `LRESULT` | Windows with the MSVC SDK |
| `accesskit_unix_*` — 6 exports | **Compilable and linkable here.** Not runnable: no AT-SPI bus, no `O_NONBLOCK` fix | Linux with a live D-Bus session |
| `aarch64-linux`, `powerpc64-linux` | Not in `cross-test.profile.sh` yet for the C ABI; the Zig matrix has no C half | `qemu_user`, as the profile already uses |
| Aggregate lowering on aarch64 | Cannot execute a C fixture | `qemu_user` on this host |
| A foreign C compiler's own layout answers | Only gcc and clang 19.1.7 are installed | The three Linux toolchains, then each platform SDK |

### 7.3 The conformance checks the header names

The header's own note at lines 6578-6593 names three checks and says checks 2
and 3 cannot run because the repository has no C artefact. Wiring section 5
makes both runnable, and here is what each would prove:

1. `cc -std=c11 -fsyntax-only -I include -xc include/zaccesskit.h` — **already
   run, already green.** Proves the file is C11 and parses. Proves nothing about
   the library and nothing about a link.
2. A C fixture with `_Static_assert` on every size, alignment and offset — **the
   fixture in section 3.2 is this check and it passes.** Proves the C
   compiler's answers agree with the header. Proves nothing about how an argument
   is passed.
3. A C fixture linked against the shipped shared library, calling one function of
   each shape — **needs the build wiring from section 5, and this is check 5 in
   `docs/31` section 6.** Proves the calling conventions agree and the symbols
   resolve. Proves nothing about the logic behind a call.

Check 3 is the one that decides 6.2, and it is the first thing to build.

---

## 8. What to write, in order

1. `src/capi/root.zig` — the 3 runtime exports and the 440 portable ones the
   host declares. Start with the geometry families: 14 affine, 21 rect, 6 vec2,
   4 point, 4 size. They are the most mechanical, they exercise the aggregate
   convention, and they are the ones check 3 needs.
2. `src/capi/marshal.zig` — 33 distinct conversion recipes, section 2's column.
   Four already exist in `src/schema/update.zig`; move or re-export them, do not
   write them twice.
3. `build.zig` — section 5, in this order: `addLibrary` with a version, then
   `installHeader`, then `installArtifact`. That is the minimum that makes check
   2 and check 3 runnable.
4. The `capi-check` step — `translate-c` diff (446) and the C fixture.
5. Then the 358 `accesskit_node_*` exports, which split across two Zig modules:
   the builder half is `src/schema/node.zig`, the getter half is
   `src/consumer/node_ref/`. They are not one family, and treating them as one
   will produce an import cycle.
6. The 58 platform exports only after `src/adapters/` exists. Nothing in
   section 2's table for those 58 can be written today, and a Linux build that
   declares them will not link.

**One row to fix before writing anything:** `docs/31` section 3 row 16 names 19
`*_free` functions and the header declares 17. Correct the row, not the header.
